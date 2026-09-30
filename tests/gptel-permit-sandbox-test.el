;;; gptel-permit-sandbox-test.el --- Tests for the sandbox action -*- lexical-binding: t; -*-

(require 'ert)
(require 'eieio)
(require 'cl-lib)
(require 'gptel)
(require 'gptel-permit)
(require 'gptel-permit-sandbox)
(require 'gptel-permit-sandbox-bwrap)
(require 'gptel-permit-sandbox-srt)

;; -------------------------------------------------------------------
;; Test helpers
;; -------------------------------------------------------------------

(defun gptel-permit-sandbox-test--fake-exists (paths)
  "Return a `file-exists-p' stub accepting only the expanded PATHS."
  (let ((accepted (mapcar (lambda (p) (directory-file-name (expand-file-name p)))
                          paths)))
    (lambda (p)
      (member (directory-file-name (expand-file-name p)) accepted))))

(defmacro gptel-permit-sandbox-test--with-bin (path &rest body)
  "Run BODY with `executable-find' stubbed to return PATH for bwrap."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'executable-find)
              (lambda (name &optional _remote)
                (and (equal name "bwrap") ,path))))
     ,@body))

(defmacro gptel-permit-sandbox-test--with-defaults (&rest body)
  "Run BODY with the sandbox options at a known-good bwrap config."
  (declare (indent 0))
  `(let ((gptel-permit-sandbox-backend 'bwrap)
         (gptel-permit-sandbox-command "bwrap")
         (gptel-permit-sandbox-network nil)
         (gptel-permit-sandbox-writable-dirs nil)
         (gptel-permit-sandbox-env-keep '("PATH" "HOME"))
         (gptel-permit-sandbox-extra-args nil)
         (gptel-permit-protected-dirs nil)
         (gptel-permit-sandbox--rc-files nil)
         (gptel-permit--sandbox-fail-streak 0)
         (gptel-permit--sandbox-latched nil)
         (gptel-permit--sandbox-wrapped-commands nil))
     ,@body))

(defmacro gptel-permit-sandbox-test--with-stub-backend (symbol &rest body)
  "Register a stub backend class for SYMBOL and run BODY.
The stub's binary is /usr/bin/stubbed-bwrap.  De-registers afterwards."
  (declare (indent 0))
  (let ((class (intern (format "gptel-permit-sandbox-test-%s-backend"
                               symbol))))
    `(unwind-protect
         (progn
          (defclass ,class (gptel-permit-sandbox-backend-base) ())
          (cl-defmethod gptel-permit-sandbox-available-p
            ((_this ,class)) t)
          (cl-defmethod gptel-permit-sandbox-wrap
            ((_this ,class) command _root)
            (format "stubbed-%s %s" (symbol-name ',symbol) command))
          (setf (alist-get ',symbol gptel-permit-sandbox-backends)
                ',class)
          ,@body)
       (setq gptel-permit-sandbox-backends
             (assq-delete-all ',symbol gptel-permit-sandbox-backends))
       (fmakunbound ',class))))

;; -------------------------------------------------------------------
;; Backend resolution: platform table, per-call, lazy loads
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-sandbox-auto-resolves-platform-table ()
  "With `auto', `system-type' maps through the platform table: GNU/Linux
to bwrap, darwin and windows-nt to srt, others to nil."
  (let ((gptel-permit-sandbox-backend 'auto))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) t))
              ((symbol-function 'gptel-permit-sandbox-available-p)
               (lambda (_) t)))
      (let ((system-type 'gnu/linux))
        (should (eq (gptel-permit--sandbox-resolve-backend) 'bwrap)))
      (let ((system-type 'darwin))
        (should (eq (gptel-permit-sandbox--backend-available-p) 'srt)))
      (let ((system-type 'windows-nt))
        (should (eq (gptel-permit--sandbox-resolve-backend) 'srt)))
      (let ((system-type 'berkeley-unix))
        (should (null (gptel-permit--sandbox-resolve-backend)))))))

(ert-deftest gptel-permit-sandbox-auto-no-cross-fallback ()
  "On Linux with bwrap missing but srt installed, `auto' resolves nil.
Deterministic platform beats availability hunting: user explicitly set
the table so no-fallback is the documented behavior."
  (let ((gptel-permit-sandbox-backend 'auto)
        (system-type 'gnu/linux))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (name &optional _r) (equal name "srt"))))
      (should (null (gptel-permit--sandbox-resolve-backend))))))


(ert-deftest gptel-permit-sandbox-default-option-is-auto ()
  "The option's default value is `auto' and resolves on the default path.
Regression guard for an EIEIO trap: `defclass' binds the class name as
a variable holding the class symbol, so a base class named exactly
`gptel-permit-sandbox-backend' silently rebinds that option — `auto'
then resolves to nothing and the shipped backends only work when the
option is set explicitly, which hides the bug from every test that
let-binds the option.  Hence the base class is
`gptel-permit-sandbox-backend-base'.  Nothing here may let-bind the
option: the global default is the point (the suite runs `-q', so the
default is the defcustom default)."
  (should (class-p 'gptel-permit-sandbox-backend-base))
  (should (eq (default-value 'gptel-permit-sandbox-backend) 'auto))
  (let ((system-type 'gnu/linux))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (&rest _) "/usr/bin/bwrap")))
      (with-temp-buffer
        (should (eq (gptel-permit--sandbox-resolve-backend) 'bwrap))))))



(ert-deftest gptel-permit-sandbox-explicit-backend-resolves ()
  "An explicit backend symbol resolves via the registry and lazy load."
  (let ((gptel-permit-sandbox-backend 'bwrap))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_n &optional _r) "/usr/bin/bwrap")))
      (with-temp-buffer
        (should (eq (gptel-permit--sandbox-resolve-backend) 'bwrap))
        ;; The registry entry names the class; the class only lives in
        ;; its module, loaded lazily by this resolution.
        (should (featurep 'gptel-permit-sandbox-bwrap))))))

(ert-deftest gptel-permit-sandbox-backend-modules-lazy ()
  "No backend module is loaded until a resolution needs it.
An unknown-platform `auto' resolves nil without loading anything; an
unknown backend symbol also loads nothing.  (Shipped modules may
already have loaded through other tests in this session; a nil
`gptel-permit-sandbox--loaded' flag on their symbols would only be
testable in a fresh session, so the observable core property tested
here is: resolutions that never name a backend require nothing.)"
  (let ((gptel-permit--sandbox-instances nil)
        (gptel-permit-sandbox-backend 'auto)
        (system-type 'berkeley-unix))
    (with-temp-buffer
      (should-not (gptel-permit--sandbox-resolve-backend))
      ;; Explicit unknown symbol with no registry entry and no feature
      ;; mapping: nothing loads, resolution is nil.
      (let ((gptel-permit-sandbox-backend 'definitely-not-here))
        (should-not (gptel-permit--sandbox-resolve-backend)))
      ;; No resolution in this test should have instantiated a backend.
      (should (null gptel-permit--sandbox-instances)))))

(ert-deftest gptel-permit-sandbox-unknown-symbol-fails-closed ()
  "A backend symbol with no registry entry resolves nil and fails
the action closed."
  (let ((gptel-permit-sandbox-backend 'missing-backend)
        (gptel-permit--sandbox-fail-streak 0)
        (gptel-permit-rules nil)
        (gptel-permit-global-rules '((:tool "Bash" :action sandbox))))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (&rest _) "/usr/bin/bwrap")))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Bash" :args '(:command "ls")))
                     '(:confirm t))))))

(ert-deftest gptel-permit-sandbox-per-call-re-resolution ()
  "Availability is re-verified per call: a binary that appears or
disappears mid-session is picked up without a restart."
  (let* ((installed (make-hash-table :test 'equal))
         (stub (lambda (_n &optional _r) (gethash 'bwrap installed))))
    (cl-letf (((symbol-function 'executable-find) stub))
      (let ((gptel-permit-sandbox-backend 'bwrap))
        (with-temp-buffer
          (should-not (gptel-permit--sandbox-resolve-backend))
          (puthash 'bwrap "/usr/bin/bwrap" installed)
          (should (eq (gptel-permit--sandbox-resolve-backend) 'bwrap))
          (remhash 'bwrap installed)
          (should-not (gptel-permit--sandbox-resolve-backend)))))))

(ert-deftest gptel-permit-sandbox-custom-backend-participates ()
  "A user-defined backend (subclass + 2 methods + registry entry) is
reachable via resolution and dispatch."
  (gptel-permit-sandbox-test--with-stub-backend nsjail
    (let ((gptel-permit-sandbox-backend 'nsjail))
      (should (eq (gptel-permit-sandbox--backend-available-p) 'nsjail))
      (should (equal (gptel-permit--sandbox-wrap-with-backend
                      'nsjail "ls" nil)
                     "stubbed-nsjail ls")))))

(ert-deftest gptel-permit-sandbox-custom-backend-auto-not-used ()
  "Third-party backends do not join `auto' (explicit option only)."
  (gptel-permit-sandbox-test--with-stub-backend nsjail
    (let ((gptel-permit-sandbox-backend 'auto)
          (system-type 'gnu/linux))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (&rest _) "/usr/bin/bwrap")))
        (should (eq (gptel-permit--sandbox-resolve-backend) 'bwrap))))))

(ert-deftest gptel-permit-sandbox-instance-caching ()
  "One stateless instance per backend class is shared."
  (with-temp-buffer
    (should (eq (gptel-permit-sandbox--instance
                 'gptel-permit-sandbox-backend-bwrap)
                (gptel-permit-sandbox--instance
                 'gptel-permit-sandbox-backend-bwrap)))))

(ert-deftest gptel-permit-sandbox-instance-unknown-class-nil ()
  "An unloadable class symbol yields nil instead of an error."
  (should (null (gptel-permit-sandbox--instance
                 'gptel-permit-sandbox-backend-does-not-exist))))

;; -------------------------------------------------------------------
;; bwrap wrapper (pure builder via the class)
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-sandbox-wrapper-shape ()
  "Default settings build the documented bwrap wrapper shape."
  (let ((gptel-permit-sandbox-command "bwrap")
        (gptel-permit-sandbox-network nil)
        (gptel-permit-sandbox-writable-dirs nil)
        (gptel-permit-sandbox-env-keep '("PATH" "HOME"))
        (gptel-permit-sandbox-extra-args nil)
        (gptel-permit-protected-dirs '("./.git"))
        (gptel-permit-sandbox--rc-files nil))
    (cl-letf (((symbol-function 'file-exists-p)
               (gptel-permit-sandbox-test--fake-exists
                '("/home/user/proj/.git"))))
      (let ((wrapper (gptel-permit-sandbox--instance
                      'gptel-permit-sandbox-backend-bwrap))
            (wrapped (gptel-permit-sandbox-wrap
                      (gptel-permit-sandbox--instance
                       'gptel-permit-sandbox-backend-bwrap)
                      "make test" "/home/user/proj/")))
        (should (gptel-permit-sandbox-available-p wrapper))
        (should (string-prefix-p "bwrap --die-with-parent --new-session --clearenv"
                                 wrapped))
        (should (string-match-p "--ro-bind / /" wrapped))
        (should (string-match-p "--dev /dev" wrapped))
        (should (string-match-p "--proc /proc" wrapped))
        (should (string-match-p "--tmpfs /tmp" wrapped))
        (should (string-match-p "--unshare-net" wrapped))
        (should (string-match-p "--bind /home/user/proj/ /home/user/proj/"
                                wrapped))
        (should (string-match-p "--ro-bind /home/user/proj/.git /home/user/proj/.git"
                                wrapped))
        (should (string-suffix-p "-- bash -c 'make test'" wrapped))))))

(ert-deftest gptel-permit-sandbox-git-robind-after-project-bind ()
  "The .git read-only bind comes after the writable project bind."
  (let ((gptel-permit-protected-dirs '("./.git"))
        (gptel-permit-sandbox-writable-dirs nil)
        (gptel-permit-sandbox-network t)
        (gptel-permit-sandbox--rc-files nil)
        (gptel-permit-sandbox-env-keep nil))
    (cl-letf (((symbol-function 'file-exists-p)
               (gptel-permit-sandbox-test--fake-exists '("/p/.git")))
              ((symbol-function 'getenv) (lambda (_v) nil)))
      (let* ((wrapped (gptel-permit-sandbox-wrap
                       (gptel-permit-sandbox--instance
                        'gptel-permit-sandbox-backend-bwrap)
                       "ls" "/p/"))
             (bind-pos (string-match-p "--bind /p/ /p/" wrapped))
             (robind-pos (string-match-p "--ro-bind /p/.git /p/.git" wrapped)))
        (should bind-pos)
        (should robind-pos)
        (should (< bind-pos robind-pos))))))


(ert-deftest gptel-permit-sandbox-symlinked-path-bound-at-target ()
  "A symlinked protected path is bound at its target, not at the link.
bwrap refuses to mount onto a symlink destination (\"Can't mount on
symlink destination\") and aborts the whole invocation, so one
symlinked entry — a stow- or chezmoi-managed ~/.zshrc, a symlinked
~/.ssh — would break every sandboxed command.  Binding the target both
keeps the invocation valid and protects the file a write through the
link would touch."
  (let ((gptel-permit-sandbox-command "bwrap")
        (gptel-permit-sandbox-network t)
        (gptel-permit-sandbox-writable-dirs '("/proj/"))
        (gptel-permit-sandbox-env-keep nil)
        (gptel-permit-sandbox-extra-args nil)
        (gptel-permit-protected-dirs '("~/.zshrc"))
        (gptel-permit-sandbox--rc-files nil)
        (link (expand-file-name "~/.zshrc")))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) t))
              ((symbol-function 'getenv) (lambda (_v) nil))
              ((symbol-function 'file-symlink-p)
               (lambda (p) (equal (expand-file-name p) link)))
              ((symbol-function 'file-truename)
               (lambda (p) (if (equal (expand-file-name p) link)
                               "/dotfiles/zshrc"
                             (expand-file-name p)))))
      (let ((wrapped (gptel-permit-sandbox-wrap
                      (gptel-permit-sandbox--instance
                       'gptel-permit-sandbox-backend-bwrap)
                      "ls" "/proj/")))
        (should (string-match-p "--ro-bind /dotfiles/zshrc /dotfiles/zshrc"
                                wrapped))
        (should-not (string-match-p (regexp-quote (concat link " " link))
                                    wrapped))))))



(ert-deftest gptel-permit-sandbox-network-flag-toggles-unshare ()
  "With network enabled there is no --unshare-net."
  (let ((gptel-permit-sandbox-writable-dirs '("/tmp"))
        (gptel-permit-protected-dirs nil)
        (gptel-permit-sandbox--rc-files nil)
        (gptel-permit-sandbox-env-keep nil))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil))
              ((symbol-function 'getenv) (lambda (_v) nil)))
      (let ((gptel-permit-sandbox-network t))
        (should-not (string-match-p
                     "--unshare-net"
                     (gptel-permit-sandbox-wrap
                      (gptel-permit-sandbox--instance
                       'gptel-permit-sandbox-backend-bwrap)
                      "ls" nil))))
      (let ((gptel-permit-sandbox-network nil))
        (should (string-match-p
                 "--unshare-net"
                 (gptel-permit-sandbox-wrap
                  (gptel-permit-sandbox--instance
                   'gptel-permit-sandbox-backend-bwrap)
                  "ls" nil)))))))

(ert-deftest gptel-permit-sandbox-writable-dirs-bind ()
  "Configured writable directories are bound read-write."
  (let ((gptel-permit-sandbox-writable-dirs '("/tmp/build"))
        (gptel-permit-sandbox-network t)
        (gptel-permit-protected-dirs nil)
        (gptel-permit-sandbox--rc-files nil)
        (gptel-permit-sandbox-env-keep nil))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil))
              ((symbol-function 'getenv) (lambda (_v) nil)))
      (should (string-match-p
               "--bind /tmp/build /tmp/build"
               (gptel-permit-sandbox-wrap
                (gptel-permit-sandbox--instance
                 'gptel-permit-sandbox-backend-bwrap)
                "ls" "/other/"))))))

(ert-deftest gptel-permit-sandbox-env-keep-honors-unset-vars ()
  "Only environment variables that are actually set get --setenv entries."
  (let ((gptel-permit-sandbox-writable-dirs '("/tmp"))
        (gptel-permit-sandbox-network t)
        (gptel-permit-protected-dirs nil)
        (gptel-permit-sandbox--rc-files nil))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil))
              ((symbol-function 'getenv)
               (lambda (v) (and (equal v "PATH") "/usr/bin:/bin"))))
      (let ((gptel-permit-sandbox-env-keep '("PATH" "HOME")))
        (let ((wrapped (gptel-permit-sandbox-wrap
                        (gptel-permit-sandbox--instance
                         'gptel-permit-sandbox-backend-bwrap)
                        "ls" nil)))
          (should (string-match-p "--clearenv" wrapped))
          (should (string-match-p "--setenv PATH /usr/bin:/bin" wrapped))
          (should-not (string-match-p "--setenv HOME" wrapped)))))))

(ert-deftest gptel-permit-sandbox-quoting ()
  "The original command is quoted exactly once as one argument."
  (let ((gptel-permit-sandbox-writable-dirs '("/tmp"))
        (gptel-permit-sandbox-network t)
        (gptel-permit-protected-dirs nil)
        (gptel-permit-sandbox--rc-files nil)
        (gptel-permit-sandbox-env-keep nil))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil))
              ((symbol-function 'getenv) (lambda (_v) nil)))
      ;; The wrapper embeds the POSIX single-quoted command.
      (should (equal (gptel-permit-sandbox--posix-quote "it's")
                     "'it'\"'\"'s'"))
      (let ((cmd "echo 'hello world'; grep \"a b\" .")
            (wrapped (gptel-permit-sandbox-wrap
                      (gptel-permit-sandbox--instance
                       'gptel-permit-sandbox-backend-bwrap)
                      "echo 'hello world'; grep \"a b\" ." nil)))
        (should (string-suffix-p
                 (concat "-- bash -c "
                         (gptel-permit-sandbox--posix-quote cmd))
                 wrapped))))))

(ert-deftest gptel-permit-sandbox-bwrap-available-needs-linux-and-binary ()
  "The bwrap backend is available on Linux with the binary, and
unavailable otherwise."
  (let ((gptel-permit-sandbox-command "bwrap"))
    (let ((system-type 'gnu/linux))
      (cl-letf (((symbol-function 'gptel-permit-sandbox--resolve-binary)
                 (lambda (_n) "/usr/bin/bwrap")))
        (should (gptel-permit-sandbox-available-p
                 (gptel-permit-sandbox--instance
                  'gptel-permit-sandbox-backend-bwrap)))))
    (let ((system-type 'darwin))
      (cl-letf (((symbol-function 'gptel-permit-sandbox--resolve-binary)
                 (lambda (_n) "/usr/bin/bwrap")))
        (should-not (gptel-permit-sandbox-available-p
                     (gptel-permit-sandbox--instance
                      'gptel-permit-sandbox-backend-bwrap)))))
    (let ((system-type 'gnu/linux))
      (cl-letf (((symbol-function 'gptel-permit-sandbox--resolve-binary)
                 (lambda (_n) nil)))
        (should-not (gptel-permit-sandbox-available-p
                     (gptel-permit-sandbox--instance
                      'gptel-permit-sandbox-backend-bwrap)))))))

;; -------------------------------------------------------------------
;; Mandatory protected paths (single-sourced)
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-sandbox-protected-paths-existing-only ()
  "Only existing sensitive paths are protected; missing ones are skipped."
  (let ((gptel-permit-protected-dirs '("/opt/real-protected/"
                                       "/opt/missing/")))
    (cl-letf (((symbol-function 'file-exists-p)
               (gptel-permit-sandbox-test--fake-exists
                '("/opt/real-protected/"))))
      (let ((paths (gptel-permit--sandbox-protected-paths nil)))
        (should (member "/opt/real-protected" paths))
        ;; Neither real nor fake rc files exist under this stub.
        (should-not (cl-some (lambda (p) (string-match-p "bashrc\\|zshrc\\|profile" p))
                             paths))
        (should-not (member "/opt/missing" paths))))))

(ert-deftest gptel-permit-sandbox-protected-paths-deduplicates ()
  "Reconfigured entries pointing at the same path collapse."
  (let ((gptel-permit-protected-dirs '("~/.ssh/" "~/.ssh")))
    (cl-letf (((symbol-function 'file-exists-p)
               (gptel-permit-sandbox-test--fake-exists '("~/.ssh/"))))
      (let ((paths (gptel-permit--sandbox-protected-paths nil)))
        (should (equal (length (cl-remove-if-not
                                (lambda (p) (string-suffix-p ".ssh" p))
                                paths))
                       1))))))

(ert-deftest gptel-permit-sandbox-protected-paths-project-relative ()
  "The shared `./' semantics apply: `./.git' resolves against the
project root and binds read-only."
  (let ((gptel-permit-protected-dirs '("./.git"))
        (gptel-permit-sandbox--rc-files nil))
    (cl-letf (((symbol-function 'file-exists-p)
               (gptel-permit-sandbox-test--fake-exists '("/proj/.git"))))
      (let ((paths (gptel-permit--sandbox-protected-paths "/proj/")))
        (should (member "/proj/.git" paths))))))

(ert-deftest gptel-permit-sandbox-protected-paths-driven-by-option ()
  "Candidates come from the option (+ rc files): nothing else is added."
  (let ((gptel-permit-protected-dirs '("/only/this"))
        (gptel-permit-sandbox--rc-files nil))
    (cl-letf (((symbol-function 'file-exists-p)
               (gptel-permit-sandbox-test--fake-exists '("/only/this"))))
      (should (equal (gptel-permit--sandbox-protected-paths "/elsewhere/")
                     (list "/only/this"))))))

;; -------------------------------------------------------------------
;; srt backend
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-sandbox-srt-settings-json ()
  "Settings JSON maps writable dirs and allowed domains per spec.
Writable dirs are resolved with the shared helper: a tilde entry is
expanded against the caller's home, so the stored value is absolute."
  (let ((gptel-permit-sandbox-writable-dirs '("~/proj/"))
        (gptel-permit-sandbox-allowed-domains '("github.com"))
        (gptel-permit-protected-dirs nil)
        (gptel-permit-sandbox--rc-files nil))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil)))
      (let ((json (gptel-permit-sandbox--settings-json "/elsewhere/")))
        (should (string-match-p "\"filesystem\"" json))
        (should (string-match-p "\"allowedDomains\":\\[\"github.com\"\\]" json))))))

(ert-deftest gptel-permit-sandbox-srt-command-shape ()
  "The srt wrapper writes settings and wraps as srt --settings FILE."
  (let ((gptel-permit-sandbox-writable-dirs '("/tmp"))
        (gptel-permit-sandbox-allowed-domains nil)
        (gptel-permit-protected-dirs nil)
        (gptel-permit-sandbox--rc-files nil)
        (settings-file (expand-file-name "gptel-permit-srt-settings.json"
                                         temporary-file-directory)))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil)))
      (let ((wrapped (gptel-permit-sandbox-wrap
                      (gptel-permit-sandbox--instance
                       'gptel-permit-sandbox-backend-srt)
                      "make test" nil)))
        (should (string-prefix-p "srt --settings " wrapped))
        (should (string-match-p (regexp-quote settings-file) wrapped))
        (should (string-suffix-p "bash -c 'make test'" wrapped))
        ;; The settings file has been written and reflects the mapping.
        (should (string-match-p "\"allowWrite\":\\[\"/tmp\"\\]"
                                (with-temp-buffer
                                  (insert-file-contents settings-file)
                                  (buffer-string))))))))

(ert-deftest gptel-permit-sandbox-srt-backend-resolves ()
  "Backend `srt' wraps with srt; missing binary fails closed."
  (let ((gptel-permit-sandbox-backend 'srt)
        (gptel-permit-sandbox-writable-dirs '("/tmp"))
        (gptel-permit-protected-dirs nil)
        (gptel-permit-sandbox--rc-files nil)
        (gptel-permit--sandbox-fail-streak 0))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil))
              ((symbol-function 'executable-find)
               (lambda (name &optional _r) (and (equal name "srt")
                                               "/usr/bin/srt"))))
      (let ((result (gptel-permit--sandbox-action
                     "sandbox-test-id"
                     (gptel-permit--enrich-tool-call
                      (list :name "Bash" :args '(:command "make test"))))))
        (should (eq (plist-get result :confirm) nil))
        (should (string-prefix-p "srt --settings "
                                 (plist-get (plist-get result :args)
                                            :command)))))
    (cl-letf (((symbol-function 'executable-find) (lambda (_name) nil)))
      (should (equal (gptel-permit--sandbox-action
                      "sandbox-test-id"
                      (gptel-permit--enrich-tool-call
                       (list :name "Bash" :args '(:command "make test"))))
                     '(:confirm t))))))

(ert-deftest gptel-permit-sandbox-srt-unavailable-on-missing-binary ()
  "The srt class declares itself unavailable without the binary."
  (cl-letf (((symbol-function 'gptel-permit-sandbox--resolve-binary)
             (lambda (_n) nil)))
    (should-not (gptel-permit-sandbox-available-p
                 (gptel-permit-sandbox--instance
                  'gptel-permit-sandbox-backend-srt)))))

;; -------------------------------------------------------------------
;; Action verdicts
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-sandbox-action-wraps-and-allows ()
  "A sandbox rule wraps the command and auto-accepts."
  (gptel-permit-sandbox-test--with-defaults
    (let ((gptel-permit-sandbox-writable-dirs '("/tmp"))
          (gptel-permit-rules nil)
          (gptel-permit-global-rules
           '((:tool "Bash" :conditions ((:command . "^make test$")) :action sandbox))))
      (gptel-permit-sandbox-test--with-bin "/usr/bin/bwrap"
        (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil)))
          (let* ((result (gptel-permit--apply-rules
                          (list :name "Bash" :args '(:command "make test"))))
                 (cmd (plist-get (plist-get result :args) :command)))
            (should (eq (plist-get result :confirm) nil))
            (should (string-prefix-p "bwrap" cmd))
            (should (string-suffix-p "'make test'" cmd))
            ;; The original command was registered for post-tool tracking.
            (should (member cmd gptel-permit--sandbox-wrapped-commands))))))))

(ert-deftest gptel-permit-sandbox-action-rule-matches-original-command ()
  "Rules match the original command; only returned args are wrapped."
  (gptel-permit-sandbox-test--with-defaults
    (let ((gptel-permit-sandbox-writable-dirs '("/tmp"))
          (gptel-permit-rules nil)
          (gptel-permit-global-rules
           '((:tool "Bash" :conditions ((:command . "\\`bwrap")) :action deny)
             (:tool "Bash" :action sandbox))))
      ;; A bwrap-quoted command would match the deny rule; the original
      ;; "ls" does not, so the sandbox rule fires instead.
      (gptel-permit-sandbox-test--with-bin "/usr/bin/bwrap"
        (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil)))
          (let ((result (gptel-permit--apply-rules
                         (list :name "Bash" :args '(:command "ls")))))
            (should (eq (plist-get result :confirm) nil))
            (should (string-prefix-p "bwrap"
                                     (plist-get (plist-get result :args)
                                                :command)))))))))

(ert-deftest gptel-permit-sandbox-action-wrapped-verdict-preserves-args ()
  "A wrapped Bash call keeps its other arguments verbatim."
  (let ((gptel-permit-sandbox-backend 'bwrap)
        (gptel-permit-sandbox-writable-dirs '("/tmp"))
        (gptel-permit--sandbox-fail-streak 0)
        (gptel-permit--sandbox-wrapped-commands nil)
        (gptel-permit-rules nil)
        (gptel-permit-global-rules
         '((:tool "Bash" :action sandbox))))
    (gptel-permit-sandbox-test--with-bin "/usr/bin/bwrap"
      (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil))
                ((symbol-function 'getenv) (lambda (_v) nil))
                (gptel-permit-tool-groups
                 (cons '("Bash"
                         :tool-group execute
                         :arg-groups ((:command . code)))
                       gptel-permit-tool-groups)))
        (with-temp-buffer
          (let ((result (gptel-permit--apply-rules
                         (list :name "Bash"
                               :args '(:command "make test" :timeout 30)))))
            (should (eq (plist-get result :confirm) nil))
            (should (= (plist-get (plist-get result :args) :timeout) 30))))))))

(ert-deftest gptel-permit-sandbox-action-fails-closed-without-binary ()
  "A missing backend binary yields (:confirm t)."
  (gptel-permit-sandbox-test--with-defaults
    (let ((gptel-permit-rules nil)
          (gptel-permit-global-rules '((:tool "Bash" :action sandbox))))
      (cl-letf (((symbol-function 'gptel-permit-sandbox--resolve-binary)
                 (lambda (_n) nil)))
        (should (equal (gptel-permit--apply-rules
                        (list :name "Bash" :args '(:command "ls")))
                       '(:confirm t)))))))

(ert-deftest gptel-permit-sandbox-action-fails-closed-without-command-arg ()
  "A matched tool without `:command' fails closed (e.g. Eval):
no adapter for its mechanics."
  (gptel-permit-sandbox-test--with-defaults
    (let ((gptel-permit-rules nil)
          (gptel-permit-global-rules
           '((:tool-group execute :action sandbox))))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (_name) "/usr/bin/bwrap")))
        (with-temp-buffer
          (should (equal (gptel-permit--apply-rules
                          (list :name "Eval" :args '(:expression "(+ 1 2)")))
                         '(:confirm t))))))))

(ert-deftest gptel-permit-sandbox-ask-rule-above-sandbox-wins ()
  "An ask rule before the sandbox rule runs the original command unsandboxed."
  (gptel-permit-sandbox-test--with-defaults
    (let ((gptel-permit-rules
           '((:tool "Bash" :conditions ((:command . "^ssh ")) :action ask)
             (:tool-group execute :action sandbox)))
          (gptel-permit-global-rules nil))
      (gptel-permit-sandbox-test--with-bin "/usr/bin/bwrap"
        (let ((result (gptel-permit--apply-rules
                       (list :name "Bash" :args '(:command "ssh prod uptime")))))
          (should (equal result '(:confirm t)))
          (should (null (plist-get result :args))))))))

(ert-deftest gptel-permit-sandbox-adapter-declining-fails-closed ()
  "An adapter returning nil (no command, no backend) fails closed."
  (gptel-permit-sandbox-test--with-defaults
    (let ((gptel-permit-rules nil)
          (gptel-permit-global-rules '((:tool "Bash" :action sandbox))))
      ;; No executable bwrap: the shipped Bash adapter returns nil and
      ;; the action confirms manually.
      (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
        (should (equal (gptel-permit--apply-rules
                        (list :name "Bash" :args '(:command "ls")))
                       '(:confirm t)))))))

(ert-deftest gptel-permit-sandbox-custom-adapter-participates ()
  "A user-added adapter entry is enough — no core change."
  (gptel-permit-sandbox-test--with-defaults
    (let ((gptel-permit-sandbox-adapters
           (append gptel-permit-sandbox-adapters
                   (list '("Eval" :wrap-args
                           (lambda (args _tc _root)
                             (plist-put (copy-sequence args)
                                        :expression "sandboxed"))))))
          (gptel-permit-rules nil)
          (gptel-permit-global-rules
           '((:tool "Eval" :action sandbox))))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (&rest _) "/usr/bin/bwrap")))
        (let ((result (gptel-permit--apply-rules
                       (list :name "Eval" :args '(:expression "(+ 1 2)")))))
          (should (eq (plist-get result :confirm) nil))
          (should (equal (plist-get (plist-get result :args) :expression)
                         "sandboxed")))))))

;; -------------------------------------------------------------------
;; Boundary-failure latch
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-sandbox-retry-limit-latches-sticky ()
  "Reaching the limit latches the buffer: further sandbox calls confirm
with the reset-command message, and the latch does not auto-clear."
  (with-temp-buffer
    (let ((gptel-permit-sandbox-retry-limit 3))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (&rest _) "/usr/bin/bwrap"))
                ((symbol-function 'file-exists-p) (lambda (_p) nil))
                ((symbol-function 'message) (lambda (_f &rest _))))
        ;; Reach the limit via actual failures (buffer-local vars are
        ;; naturally in the temp buffer); the next action must latch.
        (let ((wrapped "bwrap --die-with-parent -- bash -c 'ls'"))
          (setq gptel-permit--sandbox-wrapped-commands (list wrapped))
          (dolist (_ '(1 2 3))
            (gptel-permit-sandbox--post-tool
             (list :name "Bash" :args (list :command wrapped)
                   :result "Read-only file system")))
          (should gptel-permit--sandbox-latched)
          (should (eq gptel-permit--sandbox-fail-streak 3)))
        (should (equal (gptel-permit--sandbox-action
                        "sandbox-test-id"
                        (gptel-permit--enrich-tool-call
                         (list :name "Bash" :args '(:command "ls"))))
                       '(:confirm t)))
        (should gptel-permit--sandbox-latched)
        ;; The counter is NOT auto-reset on the trip.
        (should (eq gptel-permit--sandbox-fail-streak 3))
        ;; Still latched: the next call also confirms.
        (should (equal (gptel-permit--sandbox-action
                        "sandbox-test-id-2"
                        (gptel-permit--enrich-tool-call
                         (list :name "Bash" :args '(:command "ls"))))
                       '(:confirm t)))
        (should gptel-permit--sandbox-latched)))))

(ert-deftest gptel-permit-sandbox-post-tool-counts-and-resets ()
  "A failed sandboxed command increments the streak; success resets it
and clears the latch."
  (with-temp-buffer
    (let ((gptel-permit--sandbox-wrapped-commands
           '("bwrap ... -- bash -c 'touch /etc/x'"))
          (gptel-permit--sandbox-fail-streak 0)
          (gptel-permit--sandbox-latched t)
          (gptel-permit-sandbox-retry-limit 3))
      (gptel-permit-sandbox--post-tool
       (list :name "Bash"
             :args '(:command "bwrap ... -- bash -c 'touch /etc/x'")
             :result "Command failed with exit code 1:\n...: Permission denied"))
      (should (eq gptel-permit--sandbox-fail-streak 1))
      (should gptel-permit--sandbox-latched)
      (gptel-permit-sandbox--post-tool
       (list :name "Bash"
             :args '(:command "bwrap ... -- bash -c 'touch /etc/x'")
             :result "all good"))
      (should (eq gptel-permit--sandbox-fail-streak 0))
      (should-not gptel-permit--sandbox-latched))))

(ert-deftest gptel-permit-sandbox-latch-set-at-limit ()
  "Third consecutive failure latches the buffer."
  (with-temp-buffer
    (let ((wrapped "bwrap ... -- bash -c 'touch /etc/x'")
          (gptel-permit--sandbox-fail-streak 0)
          (gptel-permit--sandbox-latched nil)
          (gptel-permit-sandbox-retry-limit 3))
      (cl-letf (((symbol-function 'message) (lambda (_f &rest _))))
        ;; Seed the attribution registry: the tracker only counts
        ;; commands this module wrapped.
        (let ((gptel-permit--sandbox-wrapped-commands (list wrapped)))
          (dolist (_ '(1 2 3))
            (gptel-permit-sandbox--post-tool
             (list :name "Bash" :args (list :command wrapped)
                   :result "Read-only file system")))
          (should (eq gptel-permit--sandbox-fail-streak 3))
          (should gptel-permit--sandbox-latched))))))

(ert-deftest gptel-permit-sandbox-post-tool-ignores-unwrapped ()
  "Results of non-sandboxed commands leave the streak untouched."
  (with-temp-buffer
    (let ((gptel-permit--sandbox-wrapped-commands '("bwrap wrapped"))
          (gptel-permit--sandbox-fail-streak 2))
      (gptel-permit-sandbox--post-tool
       (list :name "Bash"
             :args '(:command "plain command")
             :result "Command failed with exit code 1:\nPermission denied"))
      (should (eq gptel-permit--sandbox-fail-streak 2)))))

(ert-deftest gptel-permit-sandbox-reset-clears-latch ()
  "`gptel-permit-sandbox-reset' clears the latch and counter."
  (with-temp-buffer
    (let ((gptel-permit--sandbox-fail-streak 3)
          (gptel-permit--sandbox-latched t))
      (gptel-permit-sandbox-reset)
      (should (null gptel-permit--sandbox-latched))
      (should (eq gptel-permit--sandbox-fail-streak 0)))))

(ert-deftest gptel-permit-sandbox-remember-docstring-purpose ()
  "The wrapped-command registry stays bounded, serving the post-tool
attribution."
  (with-temp-buffer
    (let ((gptel-permit--sandbox-wrapped-commands))
      (dotimes (i 105)
        (gptel-permit-sandbox--remember (format "cmd-%d" i)))
      ;; Only the youngest 100 entries remain.
      (should (= (length gptel-permit--sandbox-wrapped-commands) 100))
      (should (member "cmd-99" gptel-permit--sandbox-wrapped-commands))
      (should-not (member "cmd-0" gptel-permit--sandbox-wrapped-commands)))))

;; -------------------------------------------------------------------
;; Interactive sandboxed acceptance (C-c C-s)
;; -------------------------------------------------------------------

(defun gptel-permit-sandbox-test--overlay (triples)
  "Return a test overlay carrying the pending TRIPLES."
  (let ((ov (make-overlay (point-min) (point-min)))
        (prompt-ov (make-overlay (point-min) (point-min))))
    (overlay-put ov 'gptel-tool triples)
    (overlay-put ov 'prompt (list prompt-ov))
    ov))

(defun gptel-permit-sandbox-test--triple (name args)
  "Return a pending triple (SPEC ARGS CB) for NAME with ARGS."
  (list (gptel--make-tool-internal :name name :function #'ignore
                                   :description "test tool")
        args
        (lambda (_r) nil)))

(ert-deftest gptel-permit-accept-tool-calls-sandboxed-wraps-and-accepts ()
  "A pending Bash call is wrapped via its adapter and accepted."
  (let ((accepted nil))
    (gptel-permit-sandbox-test--with-defaults
      (gptel-permit-sandbox-test--with-bin "/usr/bin/bwrap"
        (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil))
                  ((symbol-function 'gptel--accept-tool-calls)
                   (lambda (tool-calls _ov) (setq accepted tool-calls))))
          (with-temp-buffer
            (let ((ov (gptel-permit-sandbox-test--overlay
                       (list (gptel-permit-sandbox-test--triple
                              "Bash" '(:command "make test"))))))
              (goto-char (point-min))
              (let ((triples (overlay-get ov 'gptel-tool)))
                (gptel-permit-accept-tool-calls-sandboxed triples ov))
              (should accepted)
              (should (= (length accepted) 1))
              (let ((cmd (plist-get (cadr (car accepted)) :command)))
                (should (string-prefix-p "bwrap" cmd))
                (should (string-suffix-p "'make test'" cmd))))))))))

(ert-deftest gptel-permit-accept-tool-calls-sandboxed-mixed-pack-refuses ()
  "An adapterless tool in the pack refuses the entire acceptance."
  (let ((accepted nil))
    (gptel-permit-sandbox-test--with-defaults
      (gptel-permit-sandbox-test--with-bin "/usr/bin/bwrap"
        (with-temp-buffer
          (let ((ov (gptel-permit-sandbox-test--overlay
                     (list (gptel-permit-sandbox-test--triple
                            "Bash" '(:command "ls"))
                           (gptel-permit-sandbox-test--triple
                            "Eval" '(:expression "(+ 1 2)"))))))
            (let ((triples (overlay-get ov 'gptel-tool)))
              (should-error
               (gptel-permit-accept-tool-calls-sandboxed triples ov)
               :type 'user-error))
            (should-not accepted)
            ;; The prompt survives.
            (should (overlay-buffer ov))))))))

(ert-deftest gptel-permit-accept-tool-calls-sandboxed-no-backend-refuses ()
  "No available backend refuses the acceptance before any rewrite."
  (let ((accepted nil))
    (gptel-permit-sandbox-test--with-defaults
      (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
        (with-temp-buffer
          (let ((ov (gptel-permit-sandbox-test--overlay
                     (list (gptel-permit-sandbox-test--triple
                            "Bash" '(:command "ls"))))))
            (let ((triples (overlay-get ov 'gptel-tool)))
              (should-error
               (gptel-permit-accept-tool-calls-sandboxed triples ov)
               :type 'user-error))
            (should-not accepted)))))))

(ert-deftest gptel-permit-accept-tool-calls-sandboxed-no-pending ()
  "No pending tool calls here is a user-error, not an accept."
  (gptel-permit-sandbox-test--with-defaults
    (with-temp-buffer
      (should-error (gptel-permit-accept-tool-calls-sandboxed nil nil)
                    :type 'user-error))))

(ert-deftest gptel-permit-accept-tool-calls-sandboxed-no-overlay-arg ()
  "The command works without an overlay: it rewrites the given calls."
  (let ((accepted nil))
    (gptel-permit-sandbox-test--with-defaults
      (gptel-permit-sandbox-test--with-bin "/usr/bin/bwrap"
        (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil))
                  ((symbol-function 'gptel--accept-tool-calls)
                   (lambda (tool-calls _ov) (setq accepted tool-calls))))
          (let ((triples (list (gptel-permit-sandbox-test--triple
                                "Bash" '(:command "make test")))))
            (gptel-permit-accept-tool-calls-sandboxed triples nil)
            (should (string-prefix-p "bwrap"
                                     (plist-get (cadr (car accepted))
                                                :command)))))))))

(ert-deftest gptel-permit-accept-tool-calls-sandboxed-binds-rewrites ()
  "The accept binds the rewritten→original association for analytics."
  (let ((seen-originals nil) (seen-pairs nil) (accept-ran nil))
    (gptel-permit-sandbox-test--with-defaults
      (gptel-permit-sandbox-test--with-bin "/usr/bin/bwrap"
        (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil))
                  ((symbol-function 'gptel--accept-tool-calls)
                   (lambda (_tc _ov)
                     (setq accept-ran t
                           seen-originals
                           gptel-permit-sandbox--accepted-originally
                           seen-pairs
                           gptel-permit-sandbox--rewritten-args))))
          (let ((triples (list (gptel-permit-sandbox-test--triple
                                "Bash" '(:command "make test")))))
            (gptel-permit-accept-tool-calls-sandboxed triples nil)
            ;; The originals were the pre-rewrite args (one per call).
            (should accept-ran)
            (should (equal seen-originals
                           (list (list :command "make test"))))
            (should (= (length seen-pairs) 1))
            (should (equal (cdr (car seen-pairs))
                           (list :command "make test")))))))))

(ert-deftest gptel-permit-accept-tool-calls-sandboxed-overlays-key ()
  "The C-c C-s key is registered in gptel's tool-call actions keymap at
load."
  (should (eq (keymap-lookup gptel-tool-call-actions-map "C-c C-s")
              #'gptel-permit-accept-tool-calls-sandboxed)))

;; -------------------------------------------------------------------
;; Self-registration at load
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-sandbox-bwrap-srt-loaded-by-require ()
  "The backend modules register their classes in the registry."
  (should (eq (cdr (assq 'bwrap gptel-permit-sandbox-backends))
              'gptel-permit-sandbox-backend-bwrap))
  (should (eq (cdr (assq 'srt gptel-permit-sandbox-backends))
              'gptel-permit-sandbox-backend-srt)))

(ert-deftest gptel-permit-sandbox-load-registers-action-handler ()
  "Requiring the module registers the sandbox action in the registry."
  (should (eq (cdr (assq 'sandbox gptel-permit-action-handlers))
              #'gptel-permit--sandbox-action)))

(ert-deftest gptel-permit-sandbox-load-registers-post-tool-tracker ()
  "Requiring the module adds the boundary tracker to gptel's post-tool hook."
  (should (memq #'gptel-permit-sandbox--post-tool
                gptel-post-tool-call-functions)))

(ert-deftest gptel-permit-sandbox-reload-stays-single-registered ()
  "Loading the module twice leaves one registry entry and one hook fn."
  (load "gptel-permit-sandbox" nil t)
  (load "gptel-permit-sandbox" nil t)
  (should (= 1 (cl-count-if (lambda (entry)
                              (eq (car entry) 'sandbox))
                            gptel-permit-action-handlers)))
  (should (= 1 (cl-count #'gptel-permit-sandbox--post-tool
                         gptel-post-tool-call-functions))))


(provide 'gptel-permit-sandbox-test)
;;; gptel-permit-sandbox-test.el ends here
