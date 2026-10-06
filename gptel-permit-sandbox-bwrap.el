;;; gptel-permit-sandbox-bwrap.el --- Bubblewrap sandbox backend -*- lexical-binding: t; -*-

;; Copyright (C) 2026 krvkir

;; Author: krvkir <krvkir@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9") (gptel-permit "0.1.0"))
;; Keywords: convenience, tools, agents, security
;; URL: https://github.com/krvkir/gptel-permit

;; This file is NOT part of GNU Emacs.

;;; Commentary:
;; The bubblewrap (bwrap) sandbox backend for gptel-permit's `sandbox'
;; rule action.  A pure-command-line wrapper: read-only root, private
;; tmpfs, project root (or `gptel-permit-sandbox-writable-dirs') writable,
;; network off by default, environment scrubbed, and read-only binds for
;; every protected path.  The class is the copy-paste template for
;; third-party backends; see `gptel-permit-sandbox' for the contract.
;;
;; This module self-registers at load (`bwrap' in
;; `gptel-permit-sandbox-backends'); the sandbox core loads it lazily on
;; first use, or earlier if you `(require 'gptel-permit-sandbox-bwrap)'.

;;; Code:

(require 'gptel-permit-sandbox)

(defclass gptel-permit-sandbox-backend-bwrap
  (gptel-permit-sandbox-backend-base) ()
  "Bubblewrap sandbox backend: read-only root and opt-in writable dirs.
SECURITY-RELEVANT: the wrap method's output runs without further
confirmation.")

(defcustom gptel-permit-sandbox-command "bwrap"
  "Bubblewrap binary used by the bwrap backend.
An absolute path or a name resolved via `executable-find'."
  :type 'string
  :group 'gptel-permit-sandbox)

(defcustom gptel-permit-sandbox-network nil
  "Whether sandboxed commands may use the network.
Non-nil leaves the network namespace intact; nil (default) passes
`--unshare-net'.  The bwrap backend has no domain allowlist — network is
binary on/off.  Domain allowlists require the srt backend."
  :type 'boolean
  :group 'gptel-permit-sandbox)

(defcustom gptel-permit-sandbox-env-keep
  '("PATH" "HOME" "LANG" "LC_ALL" "TERM" "TMPDIR")
  "Environment variables passed through to sandboxed commands.
The environment is first cleared with `--clearenv', then only the listed
variables that are set in the Emacs environment are restored with
`--setenv'."
  :type '(repeat string)
  :group 'gptel-permit-sandbox)

(defcustom gptel-permit-sandbox-extra-args nil
  "Extra argv elements inserted right after the sandbox binary.
Escape hatch for flags the wrappers do not cover (e.g. \"--dev-bind-try\")."
  :type '(repeat string)
  :group 'gptel-permit-sandbox)

(cl-defmethod gptel-permit-sandbox-available-p
  ((_ gptel-permit-sandbox-backend-bwrap))
  "Non-nil when bubblewrap can run here: GNU/Linux plus the binary."
  (and (memq system-type '(gnu/linux))
       (gptel-permit-sandbox--resolve-binary gptel-permit-sandbox-command)))

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


(defun gptel-permit-sandbox--bind-dests (paths)
  "Return PATHS as bwrap bind destinations.
A path whose final component is a symbolic link is replaced by its
target.  bwrap refuses to mount onto a symlink destination
(\"Can't mount on symlink destination\") and aborts the whole
invocation, so a single symlinked protected path — a stow- or
chezmoi-managed ~/.zshrc, a symlinked ~/.ssh — would silently break
every sandboxed command.  Binding the target is also the correct
protection: that is the file a write through the link would touch.
Only the destination's final component matters to bwrap, so symlinked
parents and sources are left alone; non-symlinks are returned
unchanged."
  (cl-remove-duplicates
   (mapcar (lambda (path)
             (if (file-symlink-p path) (file-truename path) path))
           paths)
   :test #'equal))



(cl-defmethod gptel-permit-sandbox-wrap
  ((_ gptel-permit-sandbox-backend-bwrap) command root)
  "Wrap COMMAND in a bubblewrap invocation string (project ROOT).
Shape:
BINARY --die-with-parent --new-session --clearenv [--setenv V v]...
--ro-bind / / --dev /dev --proc /proc --tmpfs /tmp [--unshare-net]
[--bind DIR DIR]... [--ro-bind P P]... -- bash -c QUOTED, where the
writable binds come from `gptel-permit-sandbox-writable-dirs' (default
the project root), the read-only binds from the protected paths, and
QUOTED is COMMAND quoted exactly once.  Every bind destination goes
through `gptel-permit-sandbox--bind-dests', since bubblewrap refuses
to mount on a symlink destination."
  (let* ((writable (gptel-permit-sandbox--bind-dests
                    (gptel-permit-sandbox--writable-dirs root)))
         (protected (gptel-permit-sandbox--bind-dests
                     (gptel-permit--sandbox-protected-paths root)))
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

;; Self-registration: `add-to-list' keeps the position stable across
;; reloads (idempotent by construction).
(add-to-list 'gptel-permit-sandbox-backends
             '(bwrap . gptel-permit-sandbox-backend-bwrap))

(provide 'gptel-permit-sandbox-bwrap)
;;; gptel-permit-sandbox-bwrap.el ends here
