;;; gptel-permit-validation-test.el --- Tests for tool-call validation -*- lexical-binding: t; -*-

(require 'ert)
(require 'gptel-permit)

;; -------------------------------------------------------------------
;; Test helper: register a minimal tool spec for validation testing
;; -------------------------------------------------------------------

(defun gptel-permit-test--make-tool (name &rest args)
  "Create a minimal gptel tool for testing validation."
  (gptel-make-tool
   :name name
   :description (format "Test tool %s" name)
   :function #'ignore
   :args (cl-loop for (nm opt) on args by #'cddr
                  collect (nconc (list :name nm :type 'string)
                                 (when opt (list :optional t))))
   :confirm nil
   :include nil
   :category "gptel-permit-test"))

(gptel-permit-test--make-tool "TestRead" "file_path" nil "start_line" t "end_line" t)
(gptel-permit-test--make-tool "TestBash" "command" nil "workdir" t)

;; -------------------------------------------------------------------
;; Unknown tool detection
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-validation-unknown-tool ()
  "Unknown tool call returns :block."
  (let ((result (gptel-permit--validate-args
                 (list :name "InventedTool" :args '(:x 1)))))
    (should result)
    (should (plist-get result :block))
    (should (string-match-p "Unknown tool" (plist-get result :block)))))

(ert-deftest gptel-permit-validation-known-tool-passes ()
  "Known tool call with valid args passes validation."
  (let ((result (gptel-permit--validate-args
                 (list :name "TestRead" :args '(:file_path "foo.txt" :start_line 10)))))
    (should (null result))))

;; -------------------------------------------------------------------
;; Missing required arguments
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-validation-missing-required-arg ()
  "Missing required argument returns :block with descriptive error."
  (let ((result (gptel-permit--validate-args
                 (list :name "TestRead" :args '(:start_line 10 :end_line 20)))))
    (should result)
    (should (plist-get result :block))
    (should (string-match-p "Missing required argument" (plist-get result :block)))
    (should (string-match-p "file_path" (plist-get result :block)))))

(ert-deftest gptel-permit-validation-nil-required-arg-counts-as-missing ()
  "A nil value for a required arg counts as missing."
  (let ((result (gptel-permit--validate-args
                 (list :name "TestBash" :args '(:command nil)))))
    (should result)
    (should (plist-get result :block))
    (should (string-match-p "Missing required argument" (plist-get result :block)))))

(ert-deftest gptel-permit-validation-all-required-present ()
  "When all required args are present, no blocking for missing args."
  (let ((result (gptel-permit--validate-args
                 (list :name "TestBash" :args '(:command "ls -la")))))
    (should (null result))))

;; -------------------------------------------------------------------
;; Unknown argument detection with fuzzy hints
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-validation-typo-detection ()
  "A typo in an argument name returns :block with fuzzy hint."
  (let ((result (gptel-permit--validate-args
                 (list :name "TestRead" :args '(:file_paht "foo.txt" :start_line 1)))))
    (should result)
    (should (plist-get result :block))
    (should (string-match-p "Unknown argument" (plist-get result :block)))
    (should (string-match-p "file_paht" (plist-get result :block)))
    ;; Fuzzy hint: suggests file_path
    (should (string-match-p "file_path" (plist-get result :block)))))

(ert-deftest gptel-permit-validation-multiple-typos ()
  "Multiple unknown args are all reported."
  (let ((result (gptel-permit--validate-args
                 (list :name "TestRead" :args '(:file_paht "foo.txt" :star_line 1 :end_line 20)))))
    (should result)
    (should (plist-get result :block))
    (let ((msg (plist-get result :block)))
      (should (string-match-p "file_paht" msg))
      (should (string-match-p "star_line" msg)))))

(ert-deftest gptel-permit-validation-all-args-valid ()
  "All provided arg names matching spec → no block."
  (let ((result (gptel-permit--validate-args
                 (list :name "TestRead" :args '(:file_path "foo.txt" :start_line 1 :end_line 20)))))
    (should (null result))))

(ert-deftest gptel-permit-validation-optional-args-ok ()
  "Optional args are not required."
  (let ((result (gptel-permit--validate-args
                 (list :name "TestRead" :args '(:file_path "foo.txt")))))
    (should (null result))))

(ert-deftest gptel-permit-validation-empty-args-with-required ()
  "Empty args on a tool with required args triggers both missing and no typos."
  (let ((result (gptel-permit--validate-args
                 (list :name "TestRead" :args '()))))
    (should result)
    (should (plist-get result :block))
    (should (string-match-p "Missing required argument" (plist-get result :block)))))

(provide 'gptel-permit-validation-test)
;;; gptel-permit-validation-test.el ends here
