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
;; `:action sandbox' matches, the tool call's arguments are rewritten
;; through a sandbox *tool adapter* (see
;; `gptel-permit-sandbox-adapters') and the hook returns
;; `(:confirm nil :args REWRITTEN)' using gptel's officially supported
;; args-rewrite return.  Rules, the judge, and validation always see the
;; original arguments; wrapping happens last.
;;
;; Backends live behind a registry (`gptel-permit-sandbox-backends'): a
;; backend is a subclass of `gptel-permit-sandbox-backend-base'
;; implementing two generics, `gptel-permit-sandbox-available-p' and
;; `gptel-permit-sandbox-wrap'.  This file contains no backend-specific
;; command construction: the shipped backends are the separate modules
;; gptel-permit-sandbox-bwrap.el (bubblewrap) and
;; gptel-permit-sandbox-srt.el (Anthropic sandbox-runtime), loaded
;; lazily on first use via `gptel-permit--sandbox-backend-features' —
;; or eagerly by a `(require ...)' in your configuration.
;;
;; `gptel-permit-sandbox-backend' selects the backend: the default
;; `auto' is a per-call platform-table resolution (Linux → `bwrap',
;; macOS/Windows → `srt' — no cross-fallback: an unavailable backend
;; means fail-closed, not a fallback), and any registered backend
;; symbol may be set explicitly.
;;
;; Failure handling is a buffer-local sticky latch: when
;; `gptel-permit-sandbox-retry-limit' consecutive boundary failures
;; accumulate, every sandbox verdict is `(:confirm t)' until a
;; sandboxed command succeeds or `gptel-permit-sandbox-reset' is run.
;; The interactive `gptel-permit-accept-tool-calls-sandboxed' (bound to
;; `C-c C-s' in gptel's tool-call overlay keymap at load) accepts pending
;; calls with sandboxed args, all-or-nothing.
;;
;; The action fails closed whenever anything is missing; see the
;; threat-model notes in README.org.

;;; Code:

(require 'eieio)
(require 'cl-lib)
(require 'gptel)
(require 'gptel-permit)

(defgroup gptel-permit-sandbox nil
  "Sandbox action for gptel-permit rules."
  :group 'gptel-permit
  :prefix "gptel-permit-sandbox-")

;;;; Backend contract (CLOS)

(defclass gptel-permit-sandbox-backend-base () ()
  "Base class of sandbox backends.
Subclasses implement the two generics below; they carry no slots, so
a backend is stateless and one shared instance serves every call.

The name ends in `-base' because EIEIO binds a class's name as a
variable (to the class symbol), so no class may share its name with a
variable: `gptel-permit-sandbox-backend' is taken by the option that
selects the backend.

SECURITY-RELEVANT: the string returned by
`gptel-permit-sandbox-wrap' runs without further confirmation — a
broken wrap method is a missing sandbox, not a bug.")

(cl-defgeneric gptel-permit-sandbox-available-p (backend)
  "Return non-nil when BACKEND can run on this system.
Typically a platform check plus an `executable-find' of the backend's
binary; called with the backend instance.")

(cl-defgeneric gptel-permit-sandbox-wrap (backend command root)
  "Return the sandboxed invocation string for COMMAND (project ROOT).
Implementations return a single shell command line that executes
COMMAND inside the backend's boundary, or nil when it cannot be
built — every nil propagates as a fail-closed manual confirm in
`gptel-permit--sandbox-action'.")

;;;; Registries

(defcustom gptel-permit-sandbox-backends
  '((bwrap . gptel-permit-sandbox-backend-bwrap)
    (srt . gptel-permit-sandbox-backend-srt))
  "Registry of sandbox backends: backend symbol → backend class symbol.
Every class must be a subclass of `gptel-permit-sandbox-backend-base'
implementing `gptel-permit-sandbox-available-p' and
`gptel-permit-sandbox-wrap'.  The shipped entries' defining modules
are loaded lazily on first use (see
`gptel-permit--sandbox-backend-features'); user-registered backends
must be required by the user's configuration.

SECURITY-RELEVANT: a backend whose wrap method produces
non-sandboxing commands effectively disables the boundary for the
calls it wraps."
  :type '(repeat (cons (symbol :tag "Backend symbol")
                       (symbol :tag "Backend class")))
  :group 'gptel-permit-sandbox)

(defconst gptel-permit--sandbox-backend-features
  '((bwrap . gptel-permit-sandbox-bwrap)
    (srt . gptel-permit-sandbox-srt))
  "Shipped backend symbols whose defining module is loaded on first use.
Maps backend symbols to feature names so the sandbox core loads no
backend module until a sandboxed call needs it.  Third-party backends
have no entry here: their defining files are required by the user.")

(defcustom gptel-permit-sandbox-adapters
  '(("Bash" :wrap-args gptel-permit-sandbox--wrap-bash-args))
  "Registry of per-tool adapters for the `sandbox' rule action.
An alist keyed by tool name (string), each entry a plist with
:wrap-args, a function called (ARGS TOOL-CALL ROOT) — the call's
argument plist, the enriched tool call, and the project root (or
nil).  An adapter returns a rewritten argument plist (then the action
returns `(:confirm nil :args ...)'), a full verdict plist
(`(:confirm t)' when its own mechanics are unavailable), or nil (fail
closed).

Adapters rewrite arguments only and SHALL NOT execute anything:
execution stays gptel's, after the args rewrite.  A tool without a
registered adapter fails closed with a message naming it.  The
contract is args-in/args-out on purpose, so a whole-call adapter
(e.g. a future \"Eval\" adapter spawning a sandboxed Emacs) fits the
same registry."
  :type '(repeat (cons (string :tag "Tool name")
                       (plist :key-type symbol
                              :options ((:wrap-args function)))))
  :group 'gptel-permit-sandbox)

(defcustom gptel-permit-sandbox-backend 'auto
  "Sandbox backend for the `sandbox' rule action.
The default `auto' resolves from a static platform table
(`gptel-permit--sandbox-auto-prefs') on every call: on GNU/Linux the
`bwrap' backend, on macOS/Windows the `srt' backend, elsewhere nil.
There is no cross-fallback: if the table-picked backend is
unavailable, `auto' resolves to nothing and the action fails closed —
set this option explicitly to prefer another registered backend
(overriding the platform default)."
  :type '(choice (const :tag "Auto (platform table)" auto)
                 (symbol :tag "Registered backend symbol"))
  :group 'gptel-permit-sandbox)

(defconst gptel-permit--sandbox-auto-prefs
  '((gnu/linux . bwrap) (darwin . srt) (windows-nt . srt))
  "Platform → backend symbol table behind the `auto' setting.

Static and deterministic: no registry walk, no fallback across
backends.  An unavailable backend resolves the `auto' setting to nil
(a manual-confirm verdict) instead of trying the next candidate; users
who disagree with the platform default set
`gptel-permit-sandbox-backend' explicitly.")

(defcustom gptel-permit-sandbox-retry-limit 3
  "Consecutive sandboxed-command boundary failures tolerated before
this buffer's sandbox automation latches.  While latched, every
sandbox verdict is a manual confirm; the latch clears when a
sandboxed command succeeds (see
`gptel-permit-sandbox--post-tool') or `gptel-permit-sandbox-reset' is
run."
  :type 'integer
  :group 'gptel-permit-sandbox)

(defcustom gptel-permit-sandbox-writable-dirs nil
  "Directories sandboxed commands may write to, or nil for the project root.
Only existing directories are bound or allowed."
  :type '(repeat directory)
  :group 'gptel-permit-sandbox)

;;;; Shared infrastructure

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

(defun gptel-permit-sandbox--writable-dirs (root)
  "Resolve writable directories for the sandbox.
Returns `gptel-permit-sandbox-writable-dirs' expanded, or a one-element
list of ROOT (or `default-directory' when ROOT is nil)."
  (or (cl-delete-duplicates
       (mapcar #'expand-file-name gptel-permit-sandbox-writable-dirs)
       :test #'equal)
      (list (or root (expand-file-name default-directory)))))

;;;; Backend resolution and dispatch

(defvar gptel-permit--sandbox-instances nil
  "Cache of instantiated backend objects, keyed by class symbol.
Backends are stateless; one shared instance per class.")

(defun gptel-permit--sandbox-backend-class (symbol)
  "Return the registry's class symbol for backend SYMBOL.
A shipped backend whose defining module has not loaded yet is loaded
here with an idempotent `require' before the registry lookup; the
`gptel-permit-sandbox-backends' entries are inert class-name data
until then.  Third-party symbols must have their defining file
required by the user's configuration; an absent class yields nil and
the dispatch fails closed on it."
  (when (symbolp symbol)
    (when (and (assq symbol gptel-permit-sandbox-backends)
               (null (get symbol 'gptel-permit-sandbox--loaded)))
      (let ((feature (cdr (assq symbol
                                gptel-permit--sandbox-backend-features))))
        (when feature
          (require feature nil t)
          (put symbol 'gptel-permit-sandbox--loaded t))))
    (cdr (assq symbol gptel-permit-sandbox-backends))))

(defun gptel-permit-sandbox--instance (class)
  "Return the shared instance of backend CLASS, or nil when unknown.
A CLASS symbol with no loaded EIEIO class definition yields nil; the
caller fails closed."
  (if-let* ((cached (assq class gptel-permit--sandbox-instances)))
      (cdr cached)
    (and (class-p class)
         (let ((instance (make-instance class)))
           (push (cons class instance)
                 gptel-permit--sandbox-instances)
           instance))))

(defun gptel-permit--sandbox-resolve-backend ()
  "Resolve the available backend symbol for the current configuration.
`auto' means the platform table plus availability of that one
backend; any other (nil-able) value is used directly.  Returns the
backend symbol or nil.  Deliberately recomputed on every call: no
memoization — a binary installed during this session is picked up,
and a removed one stops being picked up — the handful of stat calls
are negligible next to a tool-call round-trip.  Logs the outcome."
  (let ((wanted (if (eq gptel-permit-sandbox-backend 'auto)
                    (cdr (assq system-type
                               gptel-permit--sandbox-auto-prefs))
                  gptel-permit-sandbox-backend)))
    (when (symbolp wanted)
      (let* ((class (gptel-permit--sandbox-backend-class wanted))
             (instance (and class
                            (gptel-permit-sandbox--instance class)))
             (available (and instance
                             (gptel-permit-sandbox-available-p instance))))
        (cond
         (available
          (gptel-permit--log "Sandbox: backend resolved: %s" wanted)
          wanted)
         (t
          (gptel-permit--log
           "Sandbox: backend %s unavailable (class %S, platform %S)"
           wanted class system-type)
          nil))))))

(defun gptel-permit--sandbox-wrap-with-backend (backend command root)
  "Wrap COMMAND with the backend instance of its symbol BACKEND.
ROOT is the project root.  Returns the wrapped command string, or nil
when BACKEND cannot be dispatched or its wrap method declines or
errors — all the caller's fail-closed paths."
  (if-let* ((class (gptel-permit--sandbox-backend-class backend))
            (instance (gptel-permit-sandbox--instance class)))
      (condition-case err
          (gptel-permit-sandbox-wrap instance command root)
        (error
         (gptel-permit--log "Sandbox: wrap via %s errored: %S"
                            backend err)
         nil))))

(defun gptel-permit-sandbox--backend-available-p ()
  "Return the available backend symbol, or nil.
Same resolution as `gptel-permit--sandbox-resolve-backend'; kept as
the stub point other modules' tests rely on."
  (gptel-permit--sandbox-resolve-backend))

;;;; The shipped "Bash" adapter

(defun gptel-permit-sandbox--wrap-bash-args (args _tool-call root)
  "Rewrite Bash-style ARGS: wrap `:command' via the resolved backend.
ROOT is the project root.  Returns the rewritten plist, or nil when
there is no `:command' string (a tool without one), no available
backend, or the backend declined — all fail closed in the action."
  (let ((command (plist-get args :command)))
    (when (stringp command)
      (let* ((backend (gptel-permit--sandbox-resolve-backend))
             (wrapped (and backend
                           (gptel-permit--sandbox-wrap-with-backend
                            backend command root))))
        (and (stringp wrapped)
             (plist-put (copy-sequence args) :command wrapped))))))

;;;; Protected paths

(defconst gptel-permit-sandbox--rc-files
  '("~/.bashrc" "~/.bash_profile" "~/.profile" "~/.zshrc")
  "Shell rc files protected by mandatory read-only binds.")

(defconst gptel-permit-sandbox--boundary-error-regexps
  '("Permission denied" "Read-only file system" "Operation not permitted"
    "\\bEPERM\\b" "\\bEROFS\\b")
  "Substrings in a tool result treated as sandbox-boundary failures.")

(defun gptel-permit--sandbox-protected-paths (&optional root)
  "Return existing sensitive paths to read-only bind in the sandbox.
ROOT is the project root (default `gptel-permit--project-root').
Every entry of `gptel-permit-protected-dirs' — including its
project-relative `./' entries, resolved by the shared core helper
`gptel-permit--expand-protected-dir' — plus the shell rc files.
Nonexistent paths are skipped: bwrap can only bind paths that exist
(documented limitation).  The bwrap backend additionally binds a path
whose final component is a symlink at its target, because bubblewrap
refuses to mount on a symlink destination.  The sandbox adds no
hardcoded paths of its own beyond the rc-file constant."
  (let* ((candidates (append (mapcar (lambda (dir)
                                       (gptel-permit--expand-protected-dir
                                        dir root))
                                     gptel-permit-protected-dirs)
                             (mapcar #'expand-file-name
                                     gptel-permit-sandbox--rc-files))))
    (cl-delete-duplicates
     (cl-loop for p in candidates
              when (and p (file-exists-p p))
              collect (directory-file-name p))
     :test #'equal)))

;;;; Failure latch

(defvar-local gptel-permit--sandbox-fail-streak 0
  "Consecutive sandboxed-command boundary failures in this buffer.")

(defvar-local gptel-permit--sandbox-wrapped-commands nil
  "Most recently sandbox-wrapped command strings in this buffer.
Exists so the post-tool hook can attribute a tool result to the
(sandbox-wrapped) command that produced it: gptel delivers the result
against the args the tool ran with.  Bounded to the last 100 entries
by `gptel-permit-sandbox--remember'.")

(defvar-local gptel-permit--sandbox-latched nil
  "Non-nil while this buffer's sandbox automation is off for triage.
Set when `gptel-permit-sandbox-retry-limit' consecutive boundary
failures accumulate; cleared only by a succeeding or user-confirmed
sandboxed command (the post-tool hook) or by
`gptel-permit-sandbox-reset'.")

(defvar gptel-permit-sandbox--accepted-originally nil
  "Bound to the pre-rewrite args plists of a sandboxed acceptance.
`gptel-permit-accept-tool-calls-sandboxed' runs
`gptel--accept-tool-calls' with this bound so decision capture
(analytics) can pop a pending confirmation recorded under the
ORIGINAL arguments when the accept arrives with the rewritten ones.
The analytics module declares this variable for the compiler and
reads it; the sandbox never names analytics.")

(defvar gptel-permit-sandbox--rewritten-args nil
  "Dynamically bound alist (NEW-ARGS . OLD-ARGS) of sandbox rewrites.
`gptel-permit-accept-tool-calls-sandboxed' binds it around
`gptel--accept-tool-calls': decision capture (analytics) matches a
rewritten accept back to its original args through it.  The analytics
module declares this variable for the compiler and reads it; the
sandbox never names analytics.")

(defun gptel-permit-sandbox--remember (wrapped)
  "Record WRAPPED in the buffer's sandboxed-command registry (bounded).
The registry exists for result attribution: the post-tool tracker
matches a tool result's command argument against it, so boundary
failures are only counted for commands this module actually wrapped.
The registry carries no more than the youngest 100 commands."
  (let ((bounded
         (if (length> gptel-permit--sandbox-wrapped-commands 99)
             (butlast gptel-permit--sandbox-wrapped-commands
                      (- (length gptel-permit--sandbox-wrapped-commands) 99))
           gptel-permit--sandbox-wrapped-commands)))
    (setq gptel-permit--sandbox-wrapped-commands
          (cons wrapped bounded))))

(defun gptel-permit-sandbox--boundary-error-p (result)
  "Return non-nil if RESULT looks like a sandbox-boundary failure."
  (and (stringp result)
       (cl-some (lambda (re) (string-match-p re result))
                gptel-permit-sandbox--boundary-error-regexps)))

(defun gptel-permit-sandbox--post-tool (tool-call)
  "Track boundary failures of sandbox-wrapped commands.
Called from `gptel-post-tool-call-functions'; TOOL-CALL carries :name,
:args, :result.  A wrapped command whose result matches a boundary
error increments the buffer-local failure counter — reaching
`gptel-permit-sandbox-retry-limit' sets
`gptel-permit--sandbox-latched' without touching the counter — and
any other wrapped outcome clears both.  Returns nil."
  (let* ((command (plist-get (plist-get tool-call :args) :command))
         (result (plist-get tool-call :result)))
    (when (and (stringp command)
               (member command gptel-permit--sandbox-wrapped-commands))
      (if (gptel-permit-sandbox--boundary-error-p result)
          (progn
            (cl-incf gptel-permit--sandbox-fail-streak)
            (gptel-permit--log "Sandbox: boundary failure %d/%d"
                               gptel-permit--sandbox-fail-streak
                               gptel-permit-sandbox-retry-limit)
            (when (>= gptel-permit--sandbox-fail-streak
                      gptel-permit-sandbox-retry-limit)
              (setq gptel-permit--sandbox-latched t)
              (gptel-permit--log
               "Sandbox: latched; sandboxing stays off until reset")
              (message "gptel-permit: %d consecutive sandboxed failures; \
sandboxing off, reset with M-x gptel-permit-sandbox-reset"
                       gptel-permit-sandbox-retry-limit)))
        (setq gptel-permit--sandbox-fail-streak 0
              gptel-permit--sandbox-latched nil)
        (gptel-permit--log "Sandbox: command OK; failure state cleared"))))
  nil)

(defun gptel-permit-sandbox-reset ()
  "Clear the sandbox failure latch of the current buffer.
Resets the latch and the failure counter so the `sandbox' action
auto-runs again; meant for the moment you have triaged the
boundary-failure cause."
  (interactive)
  (setq gptel-permit--sandbox-latched nil
        gptel-permit--sandbox-fail-streak 0)
  (gptel-permit--log "Sandbox: latch and failure counter reset")
  (message "gptel-permit: sandbox failure state cleared"))

;;;; The sandbox action

(defun gptel-permit-sandbox--fail-closed (format &rest args)
  "Log the fail-closed reason (built with `format' from FORMAT and ARGS)."
  (gptel-permit--log "Sandbox: failing closed: %s" (apply #'format format args)))

(defun gptel-permit--sandbox-action (_id tool-call)
  "Return the sandbox verdict for the enriched TOOL-CALL.
_ID is the tool-call id minted by the rule engine; ignored today and
reserved for judge-async event correlation.  Dispatch, in order: the
latch, the tool's adapter, the adapter's rewrite.  Fail closed
`(:confirm t)' when the latch is set, the tool has no registered
adapter, or the adapter returns no rewritten args (which also covers
an unavailable backend and missing `:command' for the shipped Bash
adapter).  On success: `(:confirm nil :args REWRITTEN)' with other
arguments preserved."
  (let ((args (plist-get tool-call :args))
        (name (plist-get tool-call :name)))
    (cond
     (gptel-permit--sandbox-latched
      (gptel-permit-sandbox--fail-closed
       "latched: M-x gptel-permit-sandbox-reset clears it")
      (message "gptel-permit: sandbox latched in this buffer; \
reset with M-x gptel-permit-sandbox-reset")
      (list :confirm t))
     ((or (not (stringp name))
          (not (assoc name gptel-permit-sandbox-adapters)))
      (gptel-permit-sandbox--fail-closed
       "no sandbox adapter for %S (see `gptel-permit-sandbox-adapters')"
       name)
      (message "gptel-permit: sandbox: no adapter for %S" name)
      (list :confirm t))
     (t
      (let* ((adapter (cdr (assoc name gptel-permit-sandbox-adapters)))
             (fn (plist-get adapter :wrap-args))
             (result
              (condition-case err
                  (and (functionp fn)
                       (funcall fn args tool-call
                                (gptel-permit--project-root)))
                (error
                 (gptel-permit--log "Sandbox: adapter %S errored: %S"
                                    name err)
                 nil))))
        (cond
         ((and (consp result) (plist-get result :confirm))
          ;; Verdict-class result (e.g. an adapter refusing its
          ;; mechanics); keep it and attribute the rewritten commands.
          (gptel-permit-sandbox--remember-args
           (plist-get result :args) args)
          result)
         ((consp result)
          (gptel-permit-sandbox--remember-args result args)
          (gptel-permit--log "Sandbox: %S -> %s"
                             (gptel-permit--truncate-arg
                              (plist-get args :command))
                             (gptel-permit--truncate-arg
                              (plist-get result :command)))
          (list :confirm nil :args result))
         (t
          (gptel-permit-sandbox--fail-closed
           "the adapter for %S returned nothing useable" name)
          (message "gptel-permit: sandbox for %S failed; confirming"
                   name)
          (list :confirm t))))))))

(defun gptel-permit-sandbox--remember-args (rewritten original)
  "Attribute the REWRITTEN args plist to its ORIGINAL plist.
When both carry a string `:command' that differs, the new string is
remembered for post-tool result attribution.  Runs in the dynamic
scope of `gptel-permit-sandbox--rewritten-args' when binding."
  (let ((command (plist-get original :command))
        (wrapped (plist-get rewritten :command)))
    (when (and (stringp command) (stringp wrapped)
               (not (equal command wrapped)))
      (gptel-permit-sandbox--remember wrapped))))

;;;; Interactive sandboxed acceptance

(defun gptel-permit-sandbox--rewrite-triple (triple)
  "Return (SPEC NEW-ARGS OLD-ARGS) for the pending-call TRIPLE.
NEW-ARGS is the adapter's rewrite of the triple's args.  A tool
without an adapter, or one whose adapter declines, signals a
`user-error' naming the tool: the interactive command's
all-or-nothing refusals are built from this."
  (pcase-let* ((`(,spec ,arg-plist _cb) triple)
               (name (and spec (gptel-tool-name spec)))
               (adapter (and name (assoc name
                                         gptel-permit-sandbox-adapters))))
    (unless name
      (user-error "gptel-permit: pending call without a tool name"))
    (unless adapter
      (user-error "gptel-permit: sandbox: no adapter for \"%s\"" name))
    (let ((new-args (funcall (plist-get (cdr adapter) :wrap-args)
                             arg-plist
                             (list :name name)
                             (gptel-permit--project-root))))
      (unless (and (consp new-args)
                   (not (equal new-args arg-plist)))
        (user-error "gptel-permit: sandbox for \"%s\" was refused" name))
      (list spec new-args arg-plist))))

(defun gptel-permit-accept-tool-calls-sandboxed (&optional tool-calls ov)
  "Accept pending TOOL-CALLS after rewriting their args for the sandbox.
Reads the pending triples from OV (or the overlay at point), rewrites
each call's args through its registered adapter, and delegates to
`gptel--accept-tool-calls'.  All-or-nothing: when any call lacks an
adapter or refuses, or no backend is available, or there are no
pending calls here, nothing is accepted and the message names the
problem — plain `C-c C-c' still accepts unwrapped.  The originals are
bound for decision capture (`gptel-permit-sandbox--accepted-originally')."
  (interactive (pcase-let ((`(,resp . ,o) (get-char-property-and-overlay
                                           (point) 'gptel-tool)))
                 (list resp o)))
  (unless (and tool-calls (listp tool-calls))
    (user-error "gptel-permit: no pending tool calls here"))
  (unless (fboundp 'gptel--accept-tool-calls)
    (user-error "gptel--accept-tool-calls is unavailable"))
  (let* ((triples (and (overlayp ov)
                       (overlay-buffer ov)
                       (overlay-get ov 'gptel-tool)))
         (targets (if (and triples
                           (gptel-permit-sandbox--triple-p
                            triples))
                      triples
                    tool-calls)))
    (let ((backend (gptel-permit--sandbox-resolve-backend)))
      (unless backend
        (user-error (concat "gptel-permit: no sandbox backend available "
                            "(%S; platform %S picks %S)")
                    gptel-permit-sandbox-backend
                    system-type
                    (cdr (assq system-type
                               gptel-permit--sandbox-auto-prefs))))
      ;; Every pack member must rewrite; the first adapterless or
      ;; refused call aborts with its tool named and nothing accepted.
      (let ((rewritten (mapcar
                        #'gptel-permit-sandbox--rewrite-triple
                        targets)))
        (let ((gptel-permit-sandbox--rewritten-args
               (mapcar (pcase-lambda (`(_spec ,new-args ,old-args))
                         (cons new-args old-args))
                       rewritten))
              (gptel-permit-sandbox--accepted-originally
               (mapcar #'caddr rewritten)))
          (gptel--accept-tool-calls
           (mapcar (pcase-lambda (`(,spec ,new-args ,_old))
                     (list spec new-args))
                   rewritten)
           ov))))))

(defun gptel-permit-sandbox--triple-p (list)
  "Return non-nil if LIST looks like a pending tool-call list.
Each element is a (TOOL-SPEC ARGS CALLBACK) triple — the shape gptel
stores on the dispatch overlay's `gptel-tool' property."
  (and (listp list)
       (cl-every (lambda (elt)
                   (and (consp elt) (>= (length elt) 2)
                        (listp (cadr elt))))
                 list)))

;;;; Self-registration

;; The sandbox action goes into the core's action registry along with
;; the boundary-failure tracker onto gptel's post-tool hook directly:
;; the core knows nothing about the sandbox.  Both are idempotent
;; across reloads (setf overwrites; `add-hook' adds a named function
;; once).  The tracker is inert while no command was wrapped (empty
;; remember-registry), so loading with `gptel-permit-mode' off is
;; harmless.  The key must also live in gptel's tool-call overlay
;; keymap at load; unload reverses all three.
(setf (alist-get 'sandbox gptel-permit-action-handlers)
      #'gptel-permit--sandbox-action)
(add-hook 'gptel-post-tool-call-functions
          #'gptel-permit-sandbox--post-tool)
(when (boundp 'gptel-tool-call-actions-map)
  (keymap-set gptel-tool-call-actions-map "C-c C-s"
              #'gptel-permit-accept-tool-calls-sandboxed))

(defun gptel-permit-sandbox-unload-function ()
  "Undo the sandbox module's load-time registrations."
  (setf (alist-get 'sandbox gptel-permit-action-handlers nil t #'eq)
        nil)
  (remove-hook 'gptel-post-tool-call-functions
               #'gptel-permit-sandbox--post-tool)
  (when (boundp 'gptel-tool-call-actions-map)
    (keymap-unset gptel-tool-call-actions-map "C-c C-s"))
  nil)

(provide 'gptel-permit-sandbox)
;;; gptel-permit-sandbox.el ends here
