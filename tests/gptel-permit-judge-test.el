;;; gptel-permit-judge-test.el --- Tests for the LLM judge -*- lexical-binding: t; -*-

(require 'ert)
(require 'gptel-permit)
(require 'gptel-permit-judge)

;; -------------------------------------------------------------------
;; Verdict parser (pure)
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-judge-parse-safe ()
  (should (equal (gptel-permit--judge-parse-verdict "SAFE\nWrites only in project")
                 '(safe . "Writes only in project"))))

(ert-deftest gptel-permit-judge-parse-safe-no-rationale ()
  (should (equal (gptel-permit--judge-parse-verdict "SAFE")
                 '(safe . ""))))

(ert-deftest gptel-permit-judge-parse-unsafe ()
  (should (equal (gptel-permit--judge-parse-verdict "UNSAFE\nTouches /etc")
                 '(unsafe . "Touches /etc"))))

(ert-deftest gptel-permit-judge-parse-garbage-is-nil ()
  (should (null (gptel-permit--judge-parse-verdict "I think it's fine")))
  (should (null (gptel-permit--judge-parse-verdict "")))
  (should (null (gptel-permit--judge-parse-verdict nil))))

;; -------------------------------------------------------------------
;; Prompt builder (pure)
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-judge-prompt-contains-call-details ()
  (let ((prompt (gptel-permit--judge-build-prompt
                 "ls -la"
                 (list :name "Bash" :args '(:command "ls -la") :checked-arg :command))))
    (should (string-match-p "Tool: Bash" prompt))
    (should (string-match-p "Key: :command" prompt))
    (should (string-match-p "ls -la" prompt))))

(ert-deftest gptel-permit-judge-prompt-no-history-by-default ()
  (let ((gptel-permit-judge-history-entries 0))
    (should-not (string-match-p
                 "Recent context:"
                 (gptel-permit--judge-build-prompt
                  "ls" (list :name "Bash" :args '(:command "ls") :buffer "x"))))))

(ert-deftest gptel-permit-judge-prompt-includes-user-policy ()
  (let ((gptel-permit-judge-policy "Never touch /etc."))
    (should (string-match-p
             "Never touch /etc."
             (gptel-permit--judge-build-prompt "rm -rf /etc"
                                               (list :name "Bash"))))))

;; -------------------------------------------------------------------
;; Sync request with stubbed gptel-request
;; -------------------------------------------------------------------

(defmacro gptel-permit-judge-test--with-request (response &rest body)
  "Run BODY with `gptel-request' stubbed to deliver RESPONSE.
Also stubs `gptel-get-backend' and `gptel--known-backends' so a fake
backend name resolves without needing real credentials."
  `(cl-letf (((symbol-function 'gptel-request)
              (lambda (_prompt &rest keys)
                (let ((cb (plist-get keys :callback)))
                  (when cb (funcall cb ,response nil))
                  nil)))
             ((symbol-function 'gptel-get-backend)
              (lambda (_name) 'fake-judge-backend)))
     ,@body))

(ert-deftest gptel-permit-judge-sync-safe ()
  (gptel-permit-judge-test--with-request "SAFE\nok"
    (should (equal (gptel-permit--judge-request-sync "p") "SAFE\nok"))))

(ert-deftest gptel-permit-judge-sync-nil-on-nil-response ()
  (gptel-permit-judge-test--with-request nil
    (should (null (gptel-permit--judge-request-sync "p")))))

;; -------------------------------------------------------------------
;; gptel-permit-judge-safe-p (the condition)
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-judge-safe-p-returns-t-on-safe ()
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-model "model"))
    (gptel-permit-judge-test--with-request "SAFE\nfine"
      (should (gptel-permit-judge-safe-p
               "ls" (list :name "Bash" :args '(:command "ls") :checked-arg :command)))
      (should (equal gptel-permit--last-judge-rationale "fine")))))

(ert-deftest gptel-permit-judge-safe-p-returns-nil-on-unsafe ()
  (let ((gptel-permit-judge-backend "stub"))
    (gptel-permit-judge-test--with-request "UNSAFE\ntouches /etc"
      (should (null (gptel-permit-judge-safe-p
                     "rm -rf /etc" (list :name "Bash" :args '(:command "rm -rf /etc")))))
      (should (equal gptel-permit--last-judge-rationale "touches /etc")))))

(ert-deftest gptel-permit-judge-safe-p-nil-when-backend-unconfigured ()
  (let ((gptel-permit-judge-backend nil))
    (gptel-permit-judge-test--with-request "SAFE\n"
      (should (null (gptel-permit-judge-safe-p "ls" (list :name "Bash" :args '(:command "ls"))))))))

(ert-deftest gptel-permit-judge-safe-p-nil-on-unparseable ()
  (let ((gptel-permit-judge-backend "stub"))
    (gptel-permit-judge-test--with-request "maybe"
      (should (null (gptel-permit-judge-safe-p "ls" (list :name "Bash" :args '(:command "ls"))))))))

(ert-deftest gptel-permit-judge-safe-p-nil-on-request-error-response ()
  (let ((gptel-permit-judge-backend "stub"))
    (gptel-permit-judge-test--with-request nil
      (should (null (gptel-permit-judge-safe-p "ls" (list :name "Bash" :args '(:command "ls"))))))))

;; -------------------------------------------------------------------
;; Integration: judge as a rule condition
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-judge-rule-fires-only-when-safe ()
  "A rule with the judge condition fires its action only when judge says SAFE."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-rules nil)
        (gptel-permit-global-rules
         `((:tool "Bash"
                  :conditions ((:command . gptel-permit-judge-safe-p))
                  :action allow)
           (:tool "Bash" :action ask))))
    (gptel-permit-judge-test--with-request "SAFE\nlocal only"
      (should (equal (gptel-permit--rule-action
                      (gptel-permit--enrich-tool-call (list :name "Bash" :args '(:command "ls ./src"))))
                     'allow)))
    (gptel-permit-judge-test--with-request "UNSAFE\nsystem-wide"
      (should (equal (gptel-permit--rule-action
                      (gptel-permit--enrich-tool-call (list :name "Bash" :args '(:command "apt install x"))))
                     'ask)))))

(provide 'gptel-permit-judge-test)
;;; gptel-permit-judge-test.el ends here
