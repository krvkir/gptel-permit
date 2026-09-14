;;; gptel-permit-sandbox-test.el --- Tests for the sandbox action -*- lexical-binding: t; -*-

(require 'ert)
(require 'gptel)
(require 'gptel-permit)
(require 'gptel-permit-sandbox)

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
  "Run BODY with `executable-find' stubbed to return PATH."
  `(cl-letf (((symbol-function 'executable-find)
              (lambda (name &optional _remote)
                (and (equal name "bwrap") ,path))))
     ,@body))

;; -------------------------------------------------------------------
;; Builtin bwrap wrapper (pure builder)
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-sandbox-wrapper-shape ()
  "Default settings build the documented bwrap wrapper shape."
  (let ((gptel-permit-sandbox-backend 'builtin)
        (gptel-permit-sandbox-command "bwrap")
        (gptel-permit-sandbox-network nil)
        (gptel-permit-sandbox-writable-dirs nil)
        (gptel-permit-sandbox-env-keep '("PATH" "HOME"))
        (gptel-permit-sandbox-extra-args nil)
        (gptel-permit-protected-dirs nil)
        (gptel-permit-sandbox--rc-files nil))
    (cl-letf (((symbol-function 'file-exists-p)
               (gptel-permit-sandbox-test--fake-exists
                '("/home/user/proj/.git"))))
      (let ((wrapped (gptel-permit--sandbox-wrap-bwrap "make test"
                                                       "/home/user/proj/")))
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
  (let ((gptel-permit-sandbox-writable-dirs nil)
        (gptel-permit-sandbox-network t)
        (gptel-permit-protected-dirs nil)
        (gptel-permit-sandbox--rc-files nil)
        (gptel-permit-sandbox-env-keep nil))
    (cl-letf (((symbol-function 'file-exists-p)
               (gptel-permit-sandbox-test--fake-exists
                '("/p/.git")))
              ((symbol-function 'getenv) (lambda (_v) nil)))
      (let* ((wrapped (gptel-permit--sandbox-wrap-bwrap "ls" "/p/"))
             (bind-pos (string-match-p "--bind /p/ /p/" wrapped))
             (robind-pos (string-match-p "--ro-bind /p/.git /p/.git" wrapped)))
        (should bind-pos)
        (should robind-pos)
        (should (< bind-pos robind-pos))))))

(ert-deftest gptel-permit-sandbox-network-flag-toggles-unshare ()
  "With network enabled there is no --unshare-net."
  (let ((gptel-permit-sandbox-writable-dirs '("/tmp"))
        (gptel-permit-protected-dirs nil)
        (gptel-permit-sandbox--rc-files nil)
        (gptel-permit-sandbox-env-keep nil))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil))
              ((symbol-function 'getenv) (lambda (_v) nil)))
      (let ((gptel-permit-sandbox-network t))
        (should-not (string-match-p "--unshare-net"
                                    (gptel-permit--sandbox-wrap-bwrap "ls"))))
      (let ((gptel-permit-sandbox-network nil))
        (should (string-match-p "--unshare-net"
                                (gptel-permit--sandbox-wrap-bwrap "ls")))))))

(ert-deftest gptel-permit-sandbox-writable-dirs-bind ()
  "Configured writable directories are bound read-write."
  (let ((gptel-permit-sandbox-writable-dirs '("/tmp/build"))
        (gptel-permit-sandbox-network t)
        (gptel-permit-protected-dirs nil)
        (gptel-permit-sandbox--rc-files nil)
        (gptel-permit-sandbox-env-keep nil))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil))
              ((symbol-function 'getenv) (lambda (_v) nil)))
      (should (string-match-p "--bind /tmp/build /tmp/build"
                              (gptel-permit--sandbox-wrap-bwrap "ls" "/other/"))))))

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
        (let ((wrapped (gptel-permit--sandbox-wrap-bwrap "ls")))
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
            (wrapped (gptel-permit--sandbox-wrap-bwrap
                      "echo 'hello world'; grep \"a b\" .")))
        (should (string-suffix-p
                 (concat "-- bash -c "
                         (gptel-permit-sandbox--posix-quote cmd))
                 wrapped))))))

;; -------------------------------------------------------------------
;; Mandatory protected paths
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-sandbox-protected-paths-existing-only ()
  "Only existing sensitive paths are protected; missing ones are skipped."
  (let ((gptel-permit-protected-dirs '("/opt/real-protected/" "/opt/missing/")))
    (cl-letf (((symbol-function 'file-exists-p)
               (gptel-permit-sandbox-test--fake-exists
                '("/proj/.git" "/opt/real-protected/"))))
      (let ((paths (gptel-permit--sandbox-protected-paths "/proj/")))
        (should (member "/proj/.git" paths))
        (should (member "/opt/real-protected" paths))
        ;; Neither real nor fake rc files exist under this stub.
        (should-not (cl-some (lambda (p) (string-match-p "bashrc\\|zshrc\\|profile" p))
                             paths))
        (should-not (member "/opt/missing/" paths))))))

(ert-deftest gptel-permit-sandbox-protected-paths-deduplicates ()
  "Explicit and configured entries pointing at the same path collapse."
  (let ((gptel-permit-protected-dirs '("~/.ssh/")))
    (cl-letf (((symbol-function 'file-exists-p)
               (gptel-permit-sandbox-test--fake-exists '("~/.ssh/"))))
      (let ((paths (gptel-permit--sandbox-protected-paths nil)))
        ;; ~/.ssh appears once, whether from the explicit candidate or
        ;; the protected-dirs entry.
        (should (equal (length (cl-remove-if-not
                                (lambda (p) (string-suffix-p ".ssh" p))
                                paths))
                       1))))))

;; -------------------------------------------------------------------
;; srt backend
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-sandbox-srt-settings-json ()
  "Settings JSON maps writable dirs and allowed domains per spec."
  (let ((gptel-permit-sandbox-writable-dirs '("~/proj/"))
        (gptel-permit-sandbox-allowed-domains '("github.com"))
        (gptel-permit-protected-dirs nil)
        (gptel-permit-sandbox--rc-files nil))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil)))
      (let ((json (gptel-permit--sandbox-settings-json "/elsewhere/")))
        (should (string-match-p "\"filesystem\"" json))
        (should (string-match-p "\"allowWrite\":\\[\"~/proj/\"\\]" json))
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
      (let ((wrapped (gptel-permit--sandbox-wrap-srt "make test")))
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
        (gptel-permit-sandbox-env-keep nil)
        (gptel-permit--sandbox-fail-streak 0))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_p) nil))
              ((symbol-function 'executable-find)
               (lambda (name &optional _r) (and (equal name "srt") "/usr/bin/srt"))))
      (let ((result (gptel-permit--sandbox-action
                     (gptel-permit--enrich-tool-call
                      (list :name "Bash" :args '(:command "make test"))))))
        (should (eq (plist-get result :confirm) nil))
        (should (string-prefix-p "srt --settings "
                                 (plist-get (plist-get result :args) :command)))))
    (cl-letf (((symbol-function 'executable-find) (lambda (_name) nil)))
      (should (equal (gptel-permit--sandbox-action
                      (gptel-permit--enrich-tool-call
                       (list :name "Bash" :args '(:command "make test"))))
                     '(:confirm t))))))

;; -------------------------------------------------------------------
;; Action verdicts
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-sandbox-action-wraps-and-allows ()
  "A sandbox rule wraps the command and auto-accepts."
  (let ((gptel-permit-sandbox-backend 'builtin)
        (gptel-permit-sandbox-command "bwrap")
        (gptel-permit-sandbox-writable-dirs '("/tmp"))
        (gptel-permit-sandbox-network t)
        (gptel-permit-protected-dirs nil)
        (gptel-permit-sandbox--rc-files nil)
        (gptel-permit-sandbox-env-keep '("PATH"))
        (gptel-permit--sandbox-fail-streak 0)
        (gptel-permit--sandbox-wrapped-commands nil)
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
          (should (member cmd gptel-permit--sandbox-wrapped-commands)))))))

(ert-deftest gptel-permit-sandbox-action-rule-matches-original-command ()
  "Rules match the original command; only returned args are wrapped."
  (let ((gptel-permit-sandbox-backend 'builtin)
        (gptel-permit-sandbox-writable-dirs '("/tmp"))
        (gptel-permit-sandbox-protected-dirs nil)
        (gptel-permit--sandbox-fail-streak 0)
        (gptel-permit--sandbox-wrapped-commands nil)
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
                                   (plist-get (plist-get result :args) :command))))))))

(ert-deftest gptel-permit-sandbox-action-fails-closed-without-binary ()
  "A missing backend binary yields (:confirm t)."
  (let ((gptel-permit-sandbox-backend 'builtin)
        (gptel-permit--sandbox-fail-streak 0)
        (gptel-permit-rules nil)
        (gptel-permit-global-rules
         '((:tool "Bash" :action sandbox))))
    (cl-letf (((symbol-function 'executable-find) (lambda (_name) nil)))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Bash" :args '(:command "ls")))
                     '(:confirm t))))))

(ert-deftest gptel-permit-sandbox-action-fails-closed-without-command-arg ()
  "A matched tool without :command fails closed (e.g. Eval)."
  (let ((gptel-permit-sandbox-backend 'builtin)
        (gptel-permit--sandbox-fail-streak 0)
        (gptel-permit-rules nil)
        (gptel-permit-global-rules
         '((:tool-group execute :action sandbox))))
    (cl-letf (((symbol-function 'executable-find) (lambda (_name) "/usr/bin/bwrap")))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Eval" :args '(:expression "(+ 1 2)")))
                     '(:confirm t))))))

(ert-deftest gptel-permit-sandbox-ask-rule-above-sandbox-wins ()
  "An ask rule before the sandbox rule runs the original command unsandboxed."
  (let ((gptel-permit-sandbox-backend 'builtin)
        (gptel-permit--sandbox-fail-streak 0)
        (gptel-permit-rules
         '((:tool "Bash" :conditions ((:command . "^ssh ")) :action ask)
           (:tool-group execute :action sandbox)))
        (gptel-permit-global-rules nil))
    (gptel-permit-sandbox-test--with-bin "/usr/bin/bwrap"
      (let ((result (gptel-permit--apply-rules
                     (list :name "Bash" :args '(:command "ssh prod uptime")))))
        (should (equal result '(:confirm t)))
        (should (null (plist-get result :args)))))))

;; -------------------------------------------------------------------
;; Boundary-failure retry counter
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-sandbox-retry-limit-forces-confirm ()
  "When the failure streak reaches the limit the action forces a prompt
and resets the counter."
  (let ((gptel-permit-sandbox-backend 'builtin)
        (gptel-permit-sandbox-writable-dirs '("/tmp"))
        (gptel-permit-sandbox-retry-limit 3)
        (gptel-permit-protected-dirs nil)
        (gptel-permit-sandbox--rc-files nil)
        (gptel-permit--sandbox-fail-streak 3)
        (gptel-permit--sandbox-wrapped-commands nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_name) "/usr/bin/bwrap"))
              ((symbol-function 'file-exists-p) (lambda (_p) nil)))
      (should (equal (gptel-permit--sandbox-action
                      (gptel-permit--enrich-tool-call
                       (list :name "Bash" :args '(:command "ls"))))
                     '(:confirm t)))
      (should (eq gptel-permit--sandbox-fail-streak 0)))))

(ert-deftest gptel-permit-sandbox-post-tool-counts-and-resets ()
  "A failed sandboxed command increments the streak; success resets it."
  (let ((gptel-permit--sandbox-wrapped-commands '("bwrap ... -- bash -c 'touch /etc/x'"))
        (gptel-permit--sandbox-fail-streak 0))
    (gptel-permit-sandbox--post-tool
     (list :name "Bash"
           :args '(:command "bwrap ... -- bash -c 'touch /etc/x'")
           :result "Command failed with exit code 1:\n...: Permission denied"))
    (should (eq gptel-permit--sandbox-fail-streak 1))
    (gptel-permit-sandbox--post-tool
     (list :name "Bash"
           :args '(:command "bwrap ... -- bash -c 'touch /etc/x'")
           :result "all good"))
    (should (eq gptel-permit--sandbox-fail-streak 0))))

(ert-deftest gptel-permit-sandbox-post-tool-ignores-unwrapped ()
  "Results of non-sandboxed commands leave the streak untouched."
  (let ((gptel-permit--sandbox-wrapped-commands '("bwrap wrapped"))
        (gptel-permit--sandbox-fail-streak 2))
    (gptel-permit-sandbox--post-tool
     (list :name "Bash"
           :args '(:command "plain command")
           :result "Command failed with exit code 1:\nPermission denied"))
    (should (eq gptel-permit--sandbox-fail-streak 2))))

(provide 'gptel-permit-sandbox-test)
;;; gptel-permit-sandbox-test.el ends here
