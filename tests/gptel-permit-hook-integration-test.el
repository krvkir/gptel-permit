;;; gptel-permit-hook-integration-test.el --- Tests for hook integration and minor mode -*- lexical-binding: t; -*-

(require 'ert)
(require 'gptel-permit)

;; -------------------------------------------------------------------
;; Minor mode: hook registration and cleanup
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-mode-enable-adds-hooks ()
  "Enabling gptel-permit-mode adds hook functions in correct order."
  (gptel-permit-mode -1)
  (unwind-protect
      (progn
        (gptel-permit-mode 1)
        (should (memq #'gptel-permit--validate-args
                      gptel-pre-tool-call-functions))
        (should (memq #'gptel-permit--apply-rules
                      gptel-pre-tool-call-functions))
        (let ((pos-validate (cl-position #'gptel-permit--validate-args
                                         gptel-pre-tool-call-functions))
              (pos-security (cl-position #'gptel-permit--apply-rules
                                         gptel-pre-tool-call-functions)))
          (should pos-validate)
          (should pos-security)
          (should (< pos-validate pos-security))))
    (gptel-permit-mode -1)))

(ert-deftest gptel-permit-mode-disable-removes-hooks ()
  "Disabling gptel-permit-mode removes hook functions."
  (gptel-permit-mode -1)
  (gptel-permit-mode 1)
  (gptel-permit-mode -1)
  (should (not (memq #'gptel-permit--validate-args
                     gptel-pre-tool-call-functions)))
  (should (not (memq #'gptel-permit--apply-rules
                     gptel-pre-tool-call-functions))))

(ert-deftest gptel-permit-mode-enable-binds-key ()
  "Enabling gptel-permit-mode binds C-c C-b in gptel-tool-call-actions-map."
  (gptel-permit-mode -1)
  (unwind-protect
      (progn
        (gptel-permit-mode 1)
        (should (eq (lookup-key gptel-tool-call-actions-map (kbd "C-c C-b"))
                    #'gptel-permit-add-rule)))
    (gptel-permit-mode -1)))

(ert-deftest gptel-permit-mode-disable-unbinds-key ()
  "Disabling gptel-permit-mode removes the keybinding."
  (gptel-permit-mode -1)
  (gptel-permit-mode 1)
  (gptel-permit-mode -1)
  (should (not (eq (lookup-key gptel-tool-call-actions-map (kbd "C-c C-b"))
                   #'gptel-permit-add-rule))))

(ert-deftest gptel-permit-mode-idempotent ()
  "Enabling twice does not duplicate hooks."
  (gptel-permit-mode -1)
  (unwind-protect
      (progn
        (gptel-permit-mode 1)
        (gptel-permit-mode 1)
        (let ((count-validate
               (cl-count #'gptel-permit--validate-args
                         gptel-pre-tool-call-functions))
              (count-security
               (cl-count #'gptel-permit--apply-rules
                         gptel-pre-tool-call-functions)))
          (should (= count-validate 1))
          (should (= count-security 1))))
    (gptel-permit-mode -1)))

;; -------------------------------------------------------------------
;; Hook return-value protocol
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-hook-return-confirm-nil ()
  "Hook returning (:confirm nil) auto-approves the tool."
  (let ((gptel-permit-rules
         '((:tool "Bash" :conditions ((:command . "ls")) :action allow))))
    (let ((result (gptel-permit--apply-rules
                   (list :name "Bash" :args '(:command "ls")))))
      (should (equal result '(:confirm nil))))))

(ert-deftest gptel-permit-hook-return-block ()
  "Hook returning :block stops the tool call with an error message."
  (let ((gptel-permit-rules
         '((:tool "Bash" :conditions ((:command . "rm -rf")) :action deny))))
    (let ((result (gptel-permit--apply-rules
                   (list :name "Bash" :args '(:command "rm -rf /")))))
      (should result)
      (should (plist-get result :block))
      (should (string-match-p "auto-denied" (plist-get result :block))))))

(ert-deftest gptel-permit-hook-return-confirm-t ()
  "Hook returning (:confirm t) forces user prompt."
  (let ((gptel-permit-rules
         '((:tool "Bash" :conditions ((:command . "dangerous")) :action ask))))
    (let ((result (gptel-permit--apply-rules
                   (list :name "Bash" :args '(:command "dangerous stuff")))))
      (should (equal result '(:confirm t))))))

(ert-deftest gptel-permit-hook-return-nil-fallback ()
  "Hook returning nil defers to the tool's :confirm slot."
  (let ((gptel-permit-rules nil)
        (gptel-permit-global-rules nil))
    (should (null (gptel-permit--apply-rules
                   (list :name "Read" :args '(:file_path "any.txt")))))))

(ert-deftest gptel-permit-hook-return-confirm-overrides-tool-confirm ()
  "Hook :confirm return overrides whatever the tool's :confirm slot says."
  (let ((gptel-permit-rules
         '((:tool "Read" :conditions ((:file_path . ".*")) :action allow))))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Read" :args '(:file_path "foo.txt")))
                   '(:confirm nil)))))

;; -------------------------------------------------------------------
;; Early return guard: skip already-processed tool calls
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-hook-early-return-on-result ()
  "Hook skips tool calls that already have :result set."
  (let ((tool-call (list :name "Read" :args '(:file_path "x.txt") :result "error")))
    (should (null (gptel-permit--apply-rules tool-call)))))

(ert-deftest gptel-permit-hook-early-return-on-error ()
  "Hook skips tool calls that already have :error set."
  (let ((tool-call (list :name "Read" :args '(:file_path "x.txt") :error t)))
    (should (null (gptel-permit--apply-rules tool-call)))))

;; -------------------------------------------------------------------
;; Rule wizard: the scope question (last question, default `session')
;; -------------------------------------------------------------------

(defvar gptel-permit-hook-integration-test--prompts nil
  "Prompts shown by the wizard-stub completing-read/y-or-n-p.")

(defvar gptel-permit-hook-integration-test--scope-collections nil
  "The COLLECTION offered by the stub's scope prompt, in order.")

(defvar gptel-permit-hook-integration-test--answers '(allow session)
  "Answers the wizard stub gives: (ACTION-ANSWER . SCOPE-ANSWER) —
held as a list (ACTION SCOPE).")

(defun gptel-permit-hook-integration-test--fake-tool-calls ()
  "A one-call pack for the wizard tests: Bash run of make test."
  (list (list (gptel--make-tool-internal
               :name "Bash" :function #'ignore :description "wizard test")
              '(:command "make test")
              #'ignore)))

(defun gptel-permit-hook-integration-test--stub-completing-read
    (prompt collection &optional _pred _req _init _hist _def)
  "Stub completing-read for the wizard: route by the prompt prefix."
  (push prompt gptel-permit-hook-integration-test--prompts)
  (when (string-prefix-p "Store rule in scope" prompt)
    (push collection gptel-permit-hook-integration-test--scope-collections))
  (cond ((string-prefix-p "Select argument" prompt) "DONE")
        ((string= prompt "Action: ")
         (symbol-name (car gptel-permit-hook-integration-test--answers)))
        ((string-prefix-p "Store rule in scope" prompt)
         (symbol-name (cadr gptel-permit-hook-integration-test--answers)))
        (t "DONE")))

(defmacro gptel-permit-hook-integration-test--with-wizard (action scope &rest body)
  "Run BODY with the wizard's prompts stubbed to answer ACTION and SCOPE."
  (declare (indent 2))
  `(let ((gptel-permit-hook-integration-test--prompts nil)
         (gptel-permit-hook-integration-test--scope-collections nil)
         (gptel-permit-hook-integration-test--answers '(,action ,scope)))
     (cl-letf (((symbol-function 'completing-read)
                #'gptel-permit-hook-integration-test--stub-completing-read)
               ((symbol-function 'y-or-n-p)
                (lambda (_q) (push "y-or-n-p: group target" t-answers) t))
               ((symbol-function 'gptel--accept-tool-calls)
                (lambda (_tc _ov) (setq accepted t))))
       ,@body)))

(ert-deftest gptel-permit-wizard-scope-question-last-and-default-session ()
  "The scope question is asked after the action prompt, over the
configured scopes; answering the default `session' pushes the rule
into `gptel-permit-rules' as before and resolves the pending calls."
  (with-temp-buffer
    (let* ((gptel-permit-hook-integration-test--prompts nil)
           (gptel-permit-hook-integration-test--scope-collections nil)
           (gptel-permit-hook-integration-test--answers '(allow session))
           (gptel-permit-rules nil)
           (gptel-permit-global-rules nil)
           (accepted nil))
      (cl-letf (((symbol-function 'completing-read)
                 #'gptel-permit-hook-integration-test--stub-completing-read)
                ((symbol-function 'y-or-n-p)
                 (lambda (q)
                   (push q gptel-permit-hook-integration-test--prompts)
                   t))
                ((symbol-function 'gptel--accept-tool-calls)
                 (lambda (_tc _ov) (setq accepted t))))
        (gptel-permit-add-rule
         (gptel-permit-hook-integration-test--fake-tool-calls) nil)
        (let ((order (nreverse gptel-permit-hook-integration-test--prompts)))
          (should (string-prefix-p "Tool 'Bash' belongs" (car order)))
          (should (string-prefix-p "Select argument" (nth 1 order)))
          (should (string= "Action: " (nth 2 order)))
          (should (string-prefix-p "Store rule in scope" (nth 3 order))))
        ;; The offered scopes are the registry's, in order:
        (should (equal (car gptel-permit-hook-integration-test--scope-collections)
                       '(session notebook project global)))
        ;; Default answer: previous behavior exactly (empty conditions
        ;; rule pushed to the session, pack accepted).
        (should (equal gptel-permit-rules
                       '((:tool-group execute :conditions nil :action allow))))
        (should accepted)))))

(ert-deftest gptel-permit-writer-dispatch-non-session-success ()
  "A non-session answer calls that scope's `:writer' with the rule;
the session variable gains no copy."
  (with-temp-buffer
    (let* ((writer-args nil)
           (recording-writer (lambda (rule) (setq writer-args (list rule)) rule))
           (gptel-permit-rules nil)
           (gptel-permit-global-rules nil)
           (gptel-permit-hook-integration-test--answers '(allow project))
           (gptel-permit-rule-scopes
           `((session :reader gptel-permit--read-session-rules
                      :writer gptel-permit--write-session-rule)
             (project :reader ,(lambda () nil)
                      :writer ,recording-writer)
             (global :reader gptel-permit--read-global-rules
                     :writer gptel-permit--write-global-rule))))
      (cl-letf (((symbol-function 'completing-read)
                 #'gptel-permit-hook-integration-test--stub-completing-read)
                ((symbol-function 'y-or-n-p) (lambda (_q) t))
                ((symbol-function 'gptel--accept-tool-calls)
                 (lambda (_tc _ov) nil)))
        (gptel-permit-add-rule
         (gptel-permit-hook-integration-test--fake-tool-calls) nil)
        ;; (a) The writer was called with the rule:
        (should (equal writer-args
                       '((:tool-group execute :conditions nil :action allow))))
        ;; (b) The session copy is absent on success:
        (should (null gptel-permit-rules))))))

(ert-deftest gptel-permit-writer-dispatch-non-session-failure ()
  "On writer failure the error is caught and the rule is kept for the
session through `gptel-permit-rules' (c)."
  (with-temp-buffer
    (let* ((gptel-permit-rules nil)
           (gptel-permit-global-rules nil)
           (gptel-permit-hook-integration-test--answers '(allow project))
           (gptel-permit-rule-scopes
           `((session :reader gptel-permit--read-session-rules
                      :writer gptel-permit--write-session-rule)
             (project :reader ,(lambda () nil)
                      :writer ,(lambda (_rule) (error "disk broke")))
             (global :reader gptel-permit--read-global-rules
                     :writer gptel-permit--write-global-rule))))
      (cl-letf (((symbol-function 'completing-read)
                 #'gptel-permit-hook-integration-test--stub-completing-read)
                ((symbol-function 'y-or-n-p) (lambda (_q) t))
                ((symbol-function 'gptel--accept-tool-calls)
                 (lambda (_tc _ov) nil)))
        (gptel-permit-add-rule
         (gptel-permit-hook-integration-test--fake-tool-calls) nil)
        ;; (c) The session copy is present on writer error:
        (should (equal gptel-permit-rules
                       '((:tool-group execute :conditions nil :action allow))))))))

(ert-deftest gptel-permit-wizard-notebook-answer-writes-org-property ()
  "Answering `notebook' in an Org notebook writes the GPTEL_PERMIT_RULES
property; `gptel-permit-rules' gains no copy."
  (let ((nb (make-temp-file "gptel-permit-wiz-" nil ".org")))
    (unwind-protect
        (let ((buf (find-file-noselect nb)))
          (unwind-protect
              (with-current-buffer buf
                (org-mode)
                (let ((gptel-permit-rules nil)
                      (gptel-permit-global-rules nil)
                      (gptel-permit-hook-integration-test--answers '(allow notebook)))
                  (cl-letf (((symbol-function 'completing-read)
                             #'gptel-permit-hook-integration-test--stub-completing-read)
                            ((symbol-function 'y-or-n-p) (lambda (_q) t))
                            ((symbol-function 'gptel--accept-tool-calls)
                             (lambda (_tc _ov) nil)))
                    (gptel-permit-add-rule
                     (gptel-permit-hook-integration-test--fake-tool-calls) nil))
                  ;; The property holds the rule; the session has no copy.
                  (should (equal (read (gptel-permit--notebook-org-file-level-value))
                                 '((:tool-group execute
                                                :conditions nil :action allow))))
                  (should (null gptel-permit-rules))))
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))
      (delete-file nb))))

(ert-deftest gptel-permit-wizard-notebook-answer-writes-markdown-variable ()
  "Answering `notebook' in a markdown notebook stores into
`gptel-permit-notebook-rules' and the file's local variables block."
  (let ((nb (make-temp-file "gptel-permit-wiz-" nil ".md")))
    (unwind-protect
        (let ((buf (find-file-noselect nb)))
          (unwind-protect
              (with-current-buffer buf
                (text-mode)
                (let ((gptel-permit-rules nil)
                      (gptel-permit-global-rules nil)
                      (gptel-permit-hook-integration-test--answers '(allow notebook)))
                  (cl-letf (((symbol-function 'completing-read)
                             #'gptel-permit-hook-integration-test--stub-completing-read)
                            ((symbol-function 'y-or-n-p) (lambda (_q) t))
                            ((symbol-function 'gptel--accept-tool-calls)
                             (lambda (_tc _ov) nil)))
                    (gptel-permit-add-rule
                     (gptel-permit-hook-integration-test--fake-tool-calls) nil))
                  (should (equal gptel-permit-notebook-rules
                                 '((:tool-group execute
                                                :conditions nil :action allow))))
                  (should (string-match-p "Local Variables:" (buffer-string)))
                  (should (null gptel-permit-rules))))
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))
      (delete-file nb))))

(ert-deftest gptel-permit-wizard-global-answer-goes-through-customize ()
  "Answering `global' persists through `customize-save-variable'."
  (let* ((tmp-custom (make-temp-file "gptel-permit-wiz-custom-" nil ".el")))
    (unwind-protect
        (with-temp-buffer
          (let ((custom-file tmp-custom)
                (user-init-file tmp-custom)
                (gptel-permit-global-rules nil)
                (gptel-permit-rules nil)
                (gptel-permit-hook-integration-test--answers '(allow global)))
            (cl-letf (((symbol-function 'completing-read)
                       #'gptel-permit-hook-integration-test--stub-completing-read)
                      ((symbol-function 'y-or-n-p) (lambda (_q) t))
                      ((symbol-function 'gptel--accept-tool-calls)
                       (lambda (_tc _ov) nil)))
              (gptel-permit-add-rule
               (gptel-permit-hook-integration-test--fake-tool-calls) nil))
            (should (equal gptel-permit-global-rules
                           '((:tool-group execute :conditions nil :action allow))))
            (should (null gptel-permit-rules))
            (should (file-exists-p tmp-custom))
            (with-temp-buffer
              (insert-file-contents tmp-custom)
              (should (string-match-p "gptel-permit-global-rules" (buffer-string))))))
      (when (file-exists-p tmp-custom) (delete-file tmp-custom)))))

(ert-deftest gptel-permit-wizard-project-answer-appends-to-store ()
  "Answering `project' appends to the project root's store; the
session variable gains no copy; the store is readable immediately."
  (let ((root (make-temp-file "gptel-permit-proj-wiz-" t)))
    (unwind-protect
        (let ((gptel-permit--project-rules-cache nil))
          (with-temp-buffer
            (setq default-directory root)
            (cl-letf (((symbol-function 'project-current)
                       (lambda (&optional _m _d)
                         (cons 'transient (directory-file-name root))))
                      ((symbol-function 'completing-read)
                       #'gptel-permit-hook-integration-test--stub-completing-read)
                      ((symbol-function 'y-or-n-p) (lambda (_q) t))
                      ((symbol-function 'gptel--accept-tool-calls)
                       (lambda (_tc _ov) nil)))
              (let ((gptel-permit-rules nil)
                    (gptel-permit-global-rules nil)
                    (gptel-permit-hook-integration-test--answers '(allow project)))
                (gptel-permit-add-rule
                 (gptel-permit-hook-integration-test--fake-tool-calls) nil)
                ;; The project store holds the rule; the session none:
                (let ((store (expand-file-name gptel-permit-store-file-name root)))
                  (should (file-exists-p store))
                  (with-temp-buffer
                    (insert-file-contents store)
                    (goto-char (point-min))
                    ;; the printed first line parses to the rule
                    (should (equal (read (current-buffer))
                                   '(:tool-group execute :conditions nil :action allow)))))
                (should (null gptel-permit-rules))
                ;; ... and the next call already sees the rule in its
                ;; own scope:
                (let ((result (gptel-permit--find-action
                               "id"
                               (gptel-permit--enrich-tool-call
                                (list :name "Bash" :args '(:command "make test"))))))
                  (should (eq (cdr result) 'project)))))))
      (delete-directory root t))))

(ert-deftest gptel-permit-wizard-disabled-scope-not-offered ()
  "A scope removed from the registry is not offered by the prompt."
  (with-temp-buffer
    (let ((gptel-permit-hook-integration-test--scope-collections nil)
          (gptel-permit-hook-integration-test--answers '(allow project))
          (gptel-permit-rules nil)
          (gptel-permit-global-rules nil)
          (gptel-permit-rule-scopes
           (cl-remove-if (pcase-lambda (`(,scope . ,_)) (eq scope 'project))
                         (copy-sequence gptel-permit-rule-scopes))))
      (cl-letf (((symbol-function 'completing-read)
                 #'gptel-permit-hook-integration-test--stub-completing-read)
                ((symbol-function 'y-or-n-p) (lambda (_q) t))
                ((symbol-function 'gptel--accept-tool-calls)
                 (lambda (_tc _ov) nil)))
        (gptel-permit-add-rule
         (gptel-permit-hook-integration-test--fake-tool-calls) nil)
        (let ((offered
               (car gptel-permit-hook-integration-test--scope-collections)))
          (should (member 'session offered))
          (should-not (member 'project offered)))))))

(provide 'gptel-permit-hook-integration-test)
;;; gptel-permit-hook-integration-test.el ends here
