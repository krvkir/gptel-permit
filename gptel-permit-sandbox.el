;;; gptel-permit-sandbox.el --- Sandbox action for gptel-permit -*- lexical-binding: t; -*-

;; Copyright (C) 2026 krvkir

;; Author: krvkir <krvkir@gmail.com>
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9") (gptel-permit "0.0.1"))
;; Keywords: convenience, tools, agents, security
;; URL: https://github.com/krvkir/gptel-permit

;; This file is NOT part of GNU Emacs.

;;; Commentary:
;; The `sandbox' rule action for gptel-permit.  When a rule with
;; `:action sandbox' matches, the tool call's `:command' is rewritten
;; through a sandbox wrapper and the hook returns
;; `(:confirm nil :args (:command WRAPPED))' using gptel's officially
;; supported args-rewrite return.  Rules, the judge, and validation always
;; see the original, unwrapped command; wrapping happens last.
;;
;; Two backends behind `gptel-permit-sandbox-backend':
;; - `builtin': a pure-elisp bubblewrap (bwrap) wrapper — read-only root,
;;   private tmpfs, project root writable, network off by default,
;;   environment scrubbed, mandatory read-only binds for sensitive paths.
;; - `srt' (opt-in): Anthropic sandbox-runtime; defcustoms are mapped to
;;   its settings JSON and the command runs as `srt --settings FILE ...'.
;;
;; The action fails closed with `(:confirm t)' when the backend binary is
;; unavailable.  This is a best-effort boundary, not a guarantee: see the
;; threat-model notes in README.org.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'gptel)
(require 'gptel-permit)

(defgroup gptel-permit-sandbox nil
  "Sandbox action for gptel-permit rules."
  :group 'gptel-permit
  :prefix "gptel-permit-sandbox-")

(defcustom gptel-permit-sandbox-backend 'auto
  "Sandbox backend for the `sandbox' rule action.
`auto' and `builtin' use the pure-elisp bubblewrap wrapper;
`srt' runs the Anthropic sandbox-runtime CLI (opt-in, requires the srt
binary plus node/socat/ripgrep on Linux)."
  :type '(choice (const :tag "Auto (builtin wrapper)" auto)
                 (const :tag "Builtin bubblewrap wrapper" builtin)
                 (const :tag "Anthropic sandbox-runtime (srt)" srt))
  :group 'gptel-permit-sandbox)

(defcustom gptel-permit-sandbox-command "bwrap"
  "Bubblewrap binary used by the builtin backend.
An absolute path or a name resolved via `executable-find'."
  :type 'string
  :group 'gptel-permit-sandbox)

(defcustom gptel-permit-sandbox-network nil
  "Whether sandboxed commands may use the network.
Non-nil leaves the network namespace intact; nil (default) passes
`--unshare-net'.  The builtin backend has no domain allowlist — network is
binary on/off.  Domain allowlists require the opt-in srt backend."
  :type 'boolean
  :group 'gptel-permit-sandbox)

(defcustom gptel-permit-sandbox-writable-dirs nil
  "Directories sandboxed commands may write to, or nil for the project root.
Only existing directories are bound."
  :type '(repeat directory)
  :group 'gptel-permit-sandbox)

(defcustom gptel-permit-sandbox-env-keep
  '("PATH" "HOME" "LANG" "LC_ALL" "TERM" "TMPDIR")
  "Environment variables passed through to sandboxed commands.
The environment is first cleared with `--clearenv', then only the listed
variables that are set in the Emacs environment are restored with
`--setenv'."
  :type '(repeat string)
  :group 'gptel-permit-sandbox)

(defcustom gptel-permit-sandbox-allowed-domains nil
  "Network domains allowed in the srt backend, mapped to
`network.allowedDomains'.  Ignored by the builtin backend."
  :type '(repeat string)
  :group 'gptel-permit-sandbox)

(defcustom gptel-permit-sandbox-extra-args nil
  "Extra argv elements inserted right after the sandbox binary.
Escape hatch for flags the wrappers do not cover (e.g. \"--dev-bind-try\")."
  :type '(repeat string)
  :group 'gptel-permit-sandbox)

(defcustom gptel-permit-sandbox-retry-limit 3
  "Consecutive sandboxed-command failures tolerated before forcing a
manual confirmation for the next sandboxed call.  Reset on any successful
sandboxed command or when the human confirms."
  :type 'integer
  :group 'gptel-permit-sandbox)

(defconst gptel-permit-sandbox--rc-files
  '("~/.bashrc" "~/.bash_profile" "~/.profile" "~/.zshrc")
  "Shell rc files protected by mandatory read-only binds.")

(defconst gptel-permit-sandbox--boundary-error-regexps
  '("Permission denied" "Read-only file system" "Operation not permitted"
    "\\bEPERM\\b" "\\bEROFS\\b")
  "Substrings in a tool result treated as sandbox-boundary failures.")

(defvar-local gptel-permit--sandbox-fail-streak 0
  "Consecutive sandboxed-command failures in this buffer.")

(defvar-local gptel-permit--sandbox-wrapped-commands nil
  "Most recently sandbox-wrapped command strings in this buffer.")

(defun gptel-permit-sandbox--posix-quote (s)
  "Return S single-quoted for a POSIX shell.
Single quotes inside S are escaped the standard '\"'\"' way."
  (concat "'" (string-replace "'" "'\"'\"'" s) "'"))

(defun gptel-permit-sandbox--argv-elt (s)
  "Return S shell-safe for inclusion in the wrapper command string.
The element is only quoted again when it contains characters that would
break out of an unquoted word (whitespace, quotes, shell operators).
The final command element is built with
`gptel-permit-sandbox--posix-quote' and starts with an apostrophe, which
is recognized and returned as-is to avoid double quoting."
  (if (and (> (length s) 1)
           (eq (aref s 0) ?\')
           (eq (aref s (1- (length s))) ?\'))
      s
    (if (string-match-p "[[:space:]\"'`$;|&()<>{\\}*?\\[]" s)
        (gptel-permit-sandbox--posix-quote s)
      s)))

(defun gptel-permit-sandbox--resolve-binary (name)
  "Return the executable path for NAME, or nil when unavailable."
  (cond
   ((file-name-absolute-p name)
    (and (file-executable-p name) name))
   (t (executable-find name))))

(defun gptel-permit--sandbox-protected-paths (&optional root)
  "Return existing sensitive paths to read-only bind in the sandbox.
ROOT is the project root (default `gptel-permit--project-root').
Includes ROOT/.git, ~/.ssh, ~/.gnupg, shell rc files and every entry of
`gptel-permit-protected-dirs'.  Nonexistent paths are skipped: bwrap can
only bind paths that exist (documented limitation)."
  (let* ((root (or root (gptel-permit--project-root)))
         (candidates
          (append
           (when root (list (expand-file-name ".git" root)))
           (mapcar #'expand-file-name gptel-permit-protected-dirs)
           (list (expand-file-name "~/.ssh")
                 (expand-file-name "~/.gnupg"))
           (mapcar #'expand-file-name gptel-permit-sandbox--rc-files))))
    (cl-delete-duplicates
     (cl-loop for p in candidates
              when (and p (file-exists-p p))
              collect (directory-file-name p))
     :test #'equal)))

(defun gptel-permit-sandbox--writable-dirs (root)
  "Resolve writable directories for the sandbox.
Returns `gptel-permit-sandbox-writable-dirs' expanded, or a one-element
list of ROOT (or `default-directory' when ROOT is nil)."
  (or (cl-delete-duplicates
       (mapcar #'expand-file-name gptel-permit-sandbox-writable-dirs)
       :test #'equal)
      (list (or root (expand-file-name default-directory)))))

(defun gptel-permit-sandbox--env-argv ()
  "Return the --clearenv whitelist as a flat --setenv argv fragment.
Only variables with a non-nil value in the Emacs environment are set."
  (cl-loop for var in gptel-permit-sandbox-env-keep
           for val = (getenv var)
           when val
           append (list "--setenv" var val)))

(defun gptel-permit-sandbox--pairs (flag dirs)
  "Return a flat argv fragment binding each of DIRS with FLAG twice."
  (apply #'append
         (mapcar (lambda (d) (list flag d d)) dirs)))

(defun gptel-permit--sandbox-wrap-bwrap (command &optional root)
  "Return COMMAND wrapped in a bubblewrap invocation string.
ROOT is the project root (default `gptel-permit--project-root').  Shape:
BINARY --die-with-parent --new-session --clearenv [--setenv V v]...
--ro-bind / / --dev /dev --proc /proc --tmpfs /tmp [--unshare-net]
[--bind DIR DIR]... [--ro-bind P P]... -- bash -c QUOTED, where QUOTED is
COMMAND quoted exactly once."
  (let* ((writable (gptel-permit-sandbox--writable-dirs root))
         (protected (gptel-permit--sandbox-protected-paths root))
         (argv (append
                (list gptel-permit-sandbox-command)
                gptel-permit-sandbox-extra-args
                (list "--die-with-parent" "--new-session" "--clearenv")
                (gptel-permit-sandbox--env-argv)
                (list "--ro-bind" "/" "/" "--dev" "/dev" "--proc" "/proc"
                      "--tmpfs" "/tmp")
                (unless gptel-permit-sandbox-network '("--unshare-net"))
                (gptel-permit-sandbox--pairs "--bind" writable)
                (gptel-permit-sandbox--pairs "--ro-bind" protected)
                (list "--" "bash" "-c"
                      (gptel-permit-sandbox--posix-quote command)))))
    (mapconcat #'gptel-permit-sandbox--argv-elt argv " ")))

(defun gptel-permit--sandbox-settings-json (&optional root)
  "Return the srt settings JSON string for the current config.
ROOT is the project root used when writable dirs are unset.  Writable
dirs map to filesystem.allowWrite, protected paths to filesystem
denyRead/denyWrite, allowed domains to network.allowedDomains.  Values
are used as given (srt resolves ~ itself)."
  (let* ((protected (gptel-permit--sandbox-protected-paths root))
         (writable (or gptel-permit-sandbox-writable-dirs
                       (list (or root (expand-file-name default-directory))))))
    (json-encode
     `((filesystem . ((allowWrite . ,(vconcat writable))
                      (denyRead . ,(vconcat protected))
                      (denyWrite . ,(vconcat protected))))
       (network . ((allowedDomains
                    . ,(vconcat (or gptel-permit-sandbox-allowed-domains
                                    '())))))))))

(defun gptel-permit-sandbox--write-settings (&optional root)
  "Write the srt settings JSON to a cache file; return its path."
  (let ((file (expand-file-name "gptel-permit-srt-settings.json"
                                temporary-file-directory)))
    (with-temp-file file
      (insert (gptel-permit--sandbox-settings-json root)))
    file))

(defun gptel-permit--sandbox-wrap-srt (command &optional root)
  "Return COMMAND wrapped as `srt --settings FILE bash -c QUOTED'."
  (let ((file (gptel-permit-sandbox--write-settings root)))
    (mapconcat #'gptel-permit-sandbox--argv-elt
               (list "srt" "--settings" file
                     "bash" "-c"
                     (gptel-permit-sandbox--posix-quote command))
               " ")))

(defun gptel-permit-sandbox--backend-available-p ()
  "Return non-nil when the configured backend's binary is available."
  (pcase (or gptel-permit-sandbox-backend 'auto)
    ('srt (gptel-permit-sandbox--resolve-binary "srt"))
    (_ (gptel-permit-sandbox--resolve-binary gptel-permit-sandbox-command))))

(defun gptel-permit-sandbox--remember (wrapped)
  "Record WRAPPED in the buffer's sandboxed-command registry (bounded)."
  (setq gptel-permit--sandbox-wrapped-commands
        (cons wrapped
              (if (length> gptel-permit--sandbox-wrapped-commands 100)
                  (butlast gptel-permit--sandbox-wrapped-commands)
                gptel-permit--sandbox-wrapped-commands))))

(defun gptel-permit-sandbox--boundary-error-p (result)
  "Return non-nil if RESULT looks like a sandbox-boundary failure."
  (and (stringp result)
       (cl-some (lambda (re) (string-match-p re result))
                gptel-permit-sandbox--boundary-error-regexps)))

(defun gptel-permit--sandbox-action (_id tool-call)
  "Return the sandbox verdict for the enriched TOOL-CALL.
_ID is the tool-call id minted by the rule engine; it is ignored today and
reserved for judge-async event correlation.  On success:
`(:confirm nil :args (:command WRAPPED))' with other arguments
preserved.  Fail closed with `(:confirm t)' when the tool has no
:command, when the configured backend's binary is missing, or when
`gptel-permit-sandbox-retry-limit' consecutive sandboxed failures are
reached (human triage; the counter resets)."
  (let ((args (plist-get tool-call :args))
        (command (plist-get (plist-get tool-call :args) :command)))
    (cond
     ((not (stringp command))
      (gptel-permit--log "Sandbox: no :command on %s — failing closed"
                         (plist-get tool-call :name))
      (list :confirm t))
     ((>= gptel-permit--sandbox-fail-streak gptel-permit-sandbox-retry-limit)
      (setq gptel-permit--sandbox-fail-streak 0)
      (gptel-permit--log "Sandbox: retry limit hit; forcing manual confirm")
      (message "gptel-permit: %d consecutive sandboxed failures; confirming manually"
               gptel-permit-sandbox-retry-limit)
      (list :confirm t))
     ((not (gptel-permit-sandbox--backend-available-p))
      (gptel-permit--log "Sandbox: backend unavailable — failing closed")
      (list :confirm t))
     (t
      (let* ((backend (or gptel-permit-sandbox-backend 'auto))
             (wrapped (if (eq backend 'srt)
                          (gptel-permit--sandbox-wrap-srt command)
                        (gptel-permit--sandbox-wrap-bwrap command))))
        (gptel-permit-sandbox--remember wrapped)
        (gptel-permit--log "Sandbox (%s): %s -> %s" backend
                           (gptel-permit--truncate-arg command)
                           (gptel-permit--truncate-arg wrapped))
        (list :confirm nil
              :args (plist-put (copy-sequence args) :command wrapped)))))))

(defun gptel-permit-sandbox--post-tool (tool-call)
  "Track boundary failures of sandbox-wrapped commands.
Called from `gptel-post-tool-call-functions'; TOOL-CALL carries :name,
:args, :result.  A wrapped command whose result matches a boundary error
increments the buffer-local failure counter; any other wrapped outcome
resets it.  Returns nil."
  (let* ((command (plist-get (plist-get tool-call :args) :command))
         (result (plist-get tool-call :result)))
    (when (and (stringp command)
               (member command gptel-permit--sandbox-wrapped-commands))
      (if (gptel-permit-sandbox--boundary-error-p result)
          (progn
            (cl-incf gptel-permit--sandbox-fail-streak)
            (gptel-permit--log "Sandbox: boundary failure %d/%d"
                               gptel-permit--sandbox-fail-streak
                               gptel-permit-sandbox-retry-limit))
        (setq gptel-permit--sandbox-fail-streak 0)
        (gptel-permit--log "Sandbox: command OK; failure counter reset"))))
  nil)

;; Self-registration at load time: the sandbox action goes into the
;; core's action registry and the boundary-failure tracker goes onto
;; gptel's post-tool hook directly — the core knows nothing about the
;; sandbox.  Both registrations are idempotent across reloads (the setf
;; overwrites an existing entry; `add-hook' with a named function adds
;; once).  The post-tool tracker is inert while the mode never wrapped a
;; command (the remember-registry is empty), so loading with
;; `gptel-permit-mode' off is harmless; removal is not tied to the mode.
(setf (alist-get 'sandbox gptel-permit-action-handlers)
      #'gptel-permit--sandbox-action)
(add-hook 'gptel-post-tool-call-functions
          #'gptel-permit-sandbox--post-tool)


(provide 'gptel-permit-sandbox)
;;; gptel-permit-sandbox.el ends here
