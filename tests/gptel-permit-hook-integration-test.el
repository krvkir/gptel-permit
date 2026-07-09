;;; gptel-permit-hook-integration-test.el --- Tests for hook integration and minor mode -*- lexical-binding: t; -*-

(require 'ert)
(require 'gptel-permit)

;; -------------------------------------------------------------------
;; Minor mode: hook registration and cleanup
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-mode-enable-adds-hooks ()
  "Enabling gptel-permit-mode adds hook functions."
  (unwind-protect
      (progn
        (gptel-permit-mode 1)
        (should (memq #'gptel-permit--validate-tool-args
                      gptel-pre-tool-call-functions))
        (should (memq #'gptel-permit-pre-tool-security-hook
                      gptel-pre-tool-call-functions))
        ;; Validation must come before security in the hook list
        (let ((pos-validate (cl-position #'gptel-permit--validate-tool-args
                                         gptel-pre-tool-call-functions))
              (pos-security (cl-position #'gptel-permit-pre-tool-security-hook
                                         gptel-pre-tool-call-functions)))
          (should pos-validate)
          (should pos-security)
          (should (< pos-validate pos-security))))
    (gptel-permit-mode -1)))

(ert-deftest gptel-permit-mode-disable-removes-hooks ()
  "Disabling gptel-permit-mode removes hook functions."
  (gptel-permit-mode 1)
  (gptel-permit-mode -1)
  (should (not (memq #'gptel-permit--validate-tool-args
                     gptel-pre-tool-call-functions)))
  (should (not (memq #'gptel-permit-pre-tool-security-hook
                     gptel-pre-tool-call-functions))))

(ert-deftest gptel-permit-mode-enable-binds-key ()
  "Enabling gptel-permit-mode binds C-c C-b in gptel-tool-call-actions-map."
  (unwind-protect
      (progn
        (gptel-permit-mode 1)
        (should (eq (lookup-key gptel-tool-call-actions-map (kbd "C-c C-b"))
                    #'gptel-permit-confirm-or-add-rule)))
    (gptel-permit-mode -1)))

(ert-deftest gptel-permit-mode-disable-unbinds-key ()
  "Disabling gptel-permit-mode removes the keybinding."
  (gptel-permit-mode 1)
  (gptel-permit-mode -1)
  (should (not (eq (lookup-key gptel-tool-call-actions-map (kbd "C-c C-b"))
                   #'gptel-permit-confirm-or-add-rule))))

(ert-deftest gptel-permit-mode-idempotent ()
  "Enabling twice does not duplicate hooks."
  (unwind-protect
      (progn
        (gptel-permit-mode 1)
        (gptel-permit-mode 1)
        (let ((count-validate
               (cl-count #'gptel-permit--validate-tool-args
                         gptel-pre-tool-call-functions))
              (count-security
               (cl-count #'gptel-permit-pre-tool-security-hook
                         gptel-pre-tool-call-functions)))
          (should (= count-validate 1))
          (should (= count-security 1))))
    (gptel-permit-mode -1)))

;; -------------------------------------------------------------------
;; Hook return-value protocol
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-hook-return-confirm-nil ()
  "Hook returning (:confirm nil) auto-approves the tool."
  (let ((result (gptel-permit-pre-tool-security-hook
                 (list :name "Bash" :args '(:command "ls")))))
    (should (equal result '(:confirm nil)))))

(ert-deftest gptel-permit-hook-return-block ()
  "Hook returning :block stops the tool call with an error message."
  (let ((gptel-permit-rules
         '((:tool "Bash" :conditions ((:command . "rm -rf")) :action deny))))
    (let ((result (gptel-permit-pre-tool-security-hook
                   (list :name "Bash" :args '(:command "rm -rf /")))))
      (should result)
      (should (plist-get result :block))
      (should (string-match-p "auto-denied" (plist-get result :block))))))

(ert-deftest gptel-permit-hook-return-confirm-t ()
  "Hook returning (:confirm t) forces user prompt."
  (let ((gptel-permit-rules
         '((:tool "Bash" :conditions ((:command . "dangerous")) :action ask))))
    (let ((result (gptel-permit-pre-tool-security-hook
                   (list :name "Bash" :args '(:command "dangerous stuff")))))
      (should (equal result '(:confirm t))))))

(ert-deftest gptel-permit-hook-return-nil-fallback ()
  "Hook returning nil defers to the tool's :confirm slot."
  (let ((gptel-permit-rules nil)
        (gptel-permit-global-rules nil))
    (should (null (gptel-permit-pre-tool-security-hook
                   (list :name "Read" :args '(:file_path "any.txt")))))))

(ert-deftest gptel-permit-hook-return-confirm-overrides-tool-confirm ()
  "Hook :confirm return overrides whatever the tool's :confirm slot says."
  (let ((gptel-permit-rules
         '((:tool "Read" :conditions ((:file_path . ".*")) :action allow))))
    ;; Even though Read tool might have :confirm t in gptel-agent,
    ;; the hook returning (:confirm nil) must win.
    (should (equal (gptel-permit-pre-tool-security-hook
                    (list :name "Read" :args '(:file_path "foo.txt")))
                   '(:confirm nil)))))

;; -------------------------------------------------------------------
;; Early return guard: skip already-processed tool calls
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-hook-early-return-on-result ()
  "Hook skips tool calls that already have :result set."
  (let ((tool-call (list :name "Read" :args '(:file_path "x.txt") :result "error")))
    (should (null (gptel-permit-pre-tool-security-hook tool-call)))))

(ert-deftest gptel-permit-hook-early-return-on-error ()
  "Hook skips tool calls that already have :error set."
  (let ((tool-call (list :name "Read" :args '(:file_path "x.txt") :error t)))
    (should (null (gptel-permit-pre-tool-security-hook tool-call)))))

(provide 'gptel-permit-hook-integration-test)
;;; gptel-permit-hook-integration-test.el ends here
