;;; gptel-permit-judge-test.el --- Tests for the LLM judge -*- lexical-binding: t; -*-

(require 'ert)
(require 'gptel-permit)
(require 'gptel-permit-judge)
(require 'gptel-anthropic)
(require 'gptel-openai)
(require 'gptel-gemini)
(require 'gptel-ollama)

;; -------------------------------------------------------------------
;; Verdict parser (pure)
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-judge-parse-safe ()
  (should (equal (gptel-permit--judge-parse-verdict "SAFE\nWrites only in project")
                 '(safe . "Writes only in project"))))

(ert-deftest gptel-permit-judge-strip-thinking-removes-blocks ()
  "Think blocks (ollama and deepseek delimiters) are stripped, lazily."
  (should (equal (gptel-permit--judge-strip-thinking
                  "a​Could this be\nUNSAFE\n? No.\n​\nSAFE\nRead-only")
                 "a\nSAFE\nRead-only"))
  (should (equal (gptel-permit--judge-strip-thinking
                  "x<THINKING>y</tHiNkInG>z") "xz"))
  (should (equal (gptel-permit--judge-strip-thinking "a​b") "a​b")))


(ert-deftest gptel-permit-judge-parse-safe-no-rationale ()
  (should (equal (gptel-permit--judge-parse-verdict "SAFE")
                 '(safe . ""))))

(ert-deftest gptel-permit-judge-parse-leaked-deliberation-parses ()
  "Reasoning before the verdict no longer hides it: last standalone line wins."
  (should (equal (gptel-permit--judge-parse-verdict
                  "The user asks me to classify a tool call.\nAnalysis: read-only inside the project.\nSAFE\nRead-only ls inside the project.")
                 '(safe . "Read-only ls inside the project.")))
  (should (equal (gptel-permit--judge-parse-verdict
                  "Deliberation text.\nUNSAFE\nTouches system-wide state.")
                 '(unsafe . "Touches system-wide state."))))


(ert-deftest gptel-permit-judge-parse-unsafe ()
  (should (equal (gptel-permit--judge-parse-verdict "UNSAFE\nTouches /etc")
                 '(unsafe . "Touches /etc"))))

(ert-deftest gptel-permit-judge-parse-think-blocks-stripped-before-verdict ()
  "A verdict drafted inside a think block does not conflict with the final one."
  (should (equal (gptel-permit--judge-parse-verdict
                  "​Could this be\nUNSAFE\n? No, it is local.\n​\nSAFE\nRead-only")
                 '(safe . "Read-only"))))


(ert-deftest gptel-permit-judge-parse-garbage-is-nil ()
  (should (null (gptel-permit--judge-parse-verdict "I think it's fine")))
  (should (null (gptel-permit--judge-parse-verdict "")))
  (should (null (gptel-permit--judge-parse-verdict nil))))

(ert-deftest gptel-permit-judge-parse-glued-verdict-is-not-a-line ()
  "A verdict word glued mid-line (server thinking/content concatenation) does not count."
  (should (null (gptel-permit--judge-parse-verdict
                 "Read-only ls confined to the project directory, no writes, network, or execution.SAFE\nRationale line."))))


(ert-deftest gptel-permit-judge-parse-conflicting-verdicts-unparseable ()
  "Exploratory draft disagreeing with the conclusion is fail-closed."
  (should (null (gptel-permit--judge-parse-verdict
                 "Could this be\nUNSAFE\n? No, it stays inside.\nSAFE\nRead-only")))
  (should (null (gptel-permit--judge-parse-verdict
                 "Might be fine.\nSAFE\nActually no.\nUNSAFE\nTouches /etc"))))


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

(defmacro gptel-permit-judge-test--with-silent-request (&rest body)
  "Run BODY with `gptel-request' stubbed to never deliver a response."
  `(cl-letf (((symbol-function 'gptel-request) (lambda (&rest _) nil))
             ((symbol-function 'gptel-get-backend)
              (lambda (_name) 'fake-judge-backend)))
     ,@body))

(defun gptel-permit-judge-test--clear-log ()
  "Erase the `*gptel-permit-log*' buffer."
  (with-current-buffer (get-buffer-create "*gptel-permit-log*")
    (erase-buffer)))

(defun gptel-permit-judge-test--log-string ()
  "Return the current contents of the `*gptel-permit-log*' buffer."
  (with-current-buffer (get-buffer-create "*gptel-permit-log*")
    (buffer-string)))

(ert-deftest gptel-permit-judge-sync-safe ()
  (gptel-permit-judge-test--with-request "SAFE\nok"
    (should (equal (gptel-permit--judge-request-sync "p")
                   '(:class ok :response "SAFE\nok")))))

(ert-deftest gptel-permit-judge-sync-nil-response-is-request-fail ()
  (gptel-permit-judge-test--with-request nil
    (should (equal (gptel-permit--judge-request-sync "p")
                   '(:class request-fail :response nil)))))

(ert-deftest gptel-permit-judge-sync-timeout ()
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-timeout 0))
    (gptel-permit-judge-test--with-silent-request
      (should (equal (gptel-permit--judge-request-sync "p")
                     '(:class timeout :response nil))))))

;; -------------------------------------------------------------------
;; gptel-permit-judge-safe-p (the condition)
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-judge-safe-p-returns-t-on-safe ()
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-model "model"))
    (gptel-permit-judge-test--with-request "SAFE\nfine"
      (should (gptel-permit-judge-safe-p
               "ls" (list :name "Bash" :args '(:command "ls") :checked-arg :command)))
      (should (eq gptel-permit--last-judge-verdict 'safe))
      (should (equal gptel-permit--last-judge-rationale "fine")))))

(ert-deftest gptel-permit-judge-safe-p-returns-nil-on-unsafe ()
  (let ((gptel-permit-judge-backend "stub"))
    (gptel-permit-judge-test--with-request "UNSAFE\ntouches /etc"
      (should (null (gptel-permit-judge-safe-p
                     "rm -rf /etc" (list :name "Bash" :args '(:command "rm -rf /etc")))))
      (should (eq gptel-permit--last-judge-verdict 'unsafe))
      (should (equal gptel-permit--last-judge-rationale "touches /etc")))))

(ert-deftest gptel-permit-judge-safe-p-nil-when-backend-unconfigured ()
  (let ((gptel-permit-judge-backend nil))
    (gptel-permit-judge-test--with-request "SAFE\n"
      (should (null (gptel-permit-judge-safe-p "ls" (list :name "Bash" :args '(:command "ls")))))
      (should (null gptel-permit--last-judge-verdict)))))

(ert-deftest gptel-permit-judge-safe-p-nil-on-unparseable ()
  (let ((gptel-permit-judge-backend "stub"))
    (gptel-permit-judge-test--with-request "maybe"
      (should (null (gptel-permit-judge-safe-p "ls" (list :name "Bash" :args '(:command "ls"))))))))

(ert-deftest gptel-permit-judge-safe-p-parse-fail-records-class ()
  "An unparseable response records `parse-fail' with the raw text."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-log-enabled t))
    (gptel-permit-judge-test--clear-log)
    (gptel-permit-judge-test--with-request "maybe it is fine"
      (should (null (gptel-permit-judge-safe-p
                     "ls" (list :name "Bash" :args '(:command "ls")))))
      (should (eq gptel-permit--last-judge-verdict 'parse-fail))
      (should (equal gptel-permit--last-judge-rationale "maybe it is fine"))
      (should (string-match-p "Judge response unparseable: maybe it is fine"
                              (gptel-permit-judge-test--log-string))))))

(ert-deftest gptel-permit-judge-parse-fail-rationale-is-truncated ()
  "The raw response stored and logged on parse-fail is truncate-arg sized."
  (let* ((gptel-permit-judge-backend "stub")
         (gptel-permit-log-enabled t)
         (raw (make-string 200 ?x)))
    (gptel-permit-judge-test--clear-log)
    (gptel-permit-judge-test--with-request raw
      (should (null (gptel-permit-judge-safe-p
                     "ls" (list :name "Bash" :args '(:command "ls")))))
      (should (eq gptel-permit--last-judge-verdict 'parse-fail))
      (should (equal gptel-permit--last-judge-rationale
                     (gptel-permit--truncate-arg raw)))
      (should (< (length gptel-permit--last-judge-rationale) 70))
      (should (string-match-p (regexp-quote (gptel-permit--truncate-arg raw))
                              (gptel-permit-judge-test--log-string))))))


(ert-deftest gptel-permit-judge-safe-p-timeout-records-class ()
  "A request that outlives the timeout records `timeout' and logs it."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-timeout 0)
        (gptel-permit-log-enabled t))
    (gptel-permit-judge-test--clear-log)
    (gptel-permit-judge-test--with-silent-request
      (should (null (gptel-permit-judge-safe-p
                     "ls" (list :name "Bash" :args '(:command "ls")))))
      (should (eq gptel-permit--last-judge-verdict 'timeout))
      (should (null gptel-permit--last-judge-rationale))
      (should (string-match-p "Judge timeout after 0s"
                              (gptel-permit-judge-test--log-string))))))

(ert-deftest gptel-permit-judge-safe-p-request-fail-on-unknown-backend ()
  "An unknown backend name records `request-fail' and logs the error."
  (let ((gptel-permit-judge-backend "gptel-permit-no-such-backend")
        (gptel-permit-log-enabled t))
    (gptel-permit-judge-test--clear-log)
    (cl-letf (((symbol-function 'gptel-request) (lambda (&rest _) nil)))
      (should (null (gptel-permit-judge-safe-p
                     "ls" (list :name "Bash" :args '(:command "ls")))))
      (should (eq gptel-permit--last-judge-verdict 'request-fail))
      (should (string-match-p "Judge request failed:"
                              (gptel-permit-judge-test--log-string))))))

(ert-deftest gptel-permit-judge-safe-p-request-fail-on-nil-response ()
  "A failed request delivering no response records `request-fail'."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-log-enabled t))
    (gptel-permit-judge-test--clear-log)
    (gptel-permit-judge-test--with-request nil
      (should (null (gptel-permit-judge-safe-p
                     "ls" (list :name "Bash" :args '(:command "ls")))))
      (should (eq gptel-permit--last-judge-verdict 'request-fail))
      (should (null gptel-permit--last-judge-rationale))
      (should (string-match-p "Judge request failed: no response"
                              (gptel-permit-judge-test--log-string))))))

(ert-deftest gptel-permit-judge-evaluate-interrupted-maps-to-timeout ()
  "C-g interruption is recorded as the `timeout' failure class."
  (should (eq (gptel-permit--judge-evaluate
               '(:class interrupted :response nil))
              'timeout))
  (should (null gptel-permit--last-judge-rationale)))

;; -------------------------------------------------------------------
;; Judge request tuning (gptel-permit-judge-request-params)
;; -------------------------------------------------------------------

(defvar gptel-permit-judge-test--captured-params :unset
  "Params seen by the stubbed `gptel-request' in the current test.")

(defmacro gptel-permit-judge-test--with-capture (backend &rest body)
  "Run BODY with `gptel-request' stubbed to capture request params.
BACKEND is what the stubbed `gptel-get-backend' returns; the captured
value is in `gptel-permit-judge-test--captured-params'."
  `(let ((gptel-permit-judge-test--captured-params :unset))
     (cl-letf (((symbol-function 'gptel-request)
                (lambda (&rest _)
                  (setq gptel-permit-judge-test--captured-params
                        gptel--request-params)
                  nil))
               ((symbol-function 'gptel-get-backend)
                (lambda (_name) ,backend)))
       ,@body)))

(ert-deftest gptel-permit-judge-thinking-off-params-table ()
  "Thinking is disabled per backend struct type."
  (should (equal (gptel-permit--judge-thinking-off-params
                  (gptel--make-anthropic :name "a"))
                 '(:thinking (:type "disabled"))))
  (should (equal (gptel-permit--judge-thinking-off-params
                  (gptel--make-openai :name "o"))
                 '(:reasoning_effort "minimal")))
  (should (equal (gptel-permit--judge-thinking-off-params
                  (gptel--make-gemini :name "g"))
                 '(:generationConfig (:thinkingConfig (:thinkingBudget 0)))))
  (should (equal (gptel-permit--judge-thinking-off-params
                  (gptel--make-ollama :name "l"))
                 '(:think :json-false))))

(ert-deftest gptel-permit-judge-thinking-off-unknown-backend ()
  "Unrecognized backends (symbols, plain structs, nil) derive nil."
  (should (null (gptel-permit--judge-thinking-off-params 'fake-judge-backend)))
  (should (null (gptel-permit--judge-thinking-off-params
                 (gptel--make-backend :name "third-party"))))
  (should (null (gptel-permit--judge-thinking-off-params nil))))

(ert-deftest gptel-permit-judge-user-request-params-win ()
  "A non-nil `gptel-permit-judge-request-params' overrides the derived default."
  (let ((gptel-permit-judge-request-params '(:reasoning_effort "low"))
        (gptel-permit-judge-backend "stub")
        (gptel-permit-judge-timeout 0)
        (gptel-permit-log-enabled t))
    (gptel-permit-judge-test--clear-log)
    (gptel-permit-judge-test--with-capture (gptel--make-openai :name "stub")
      (gptel-permit--judge-request-sync "p")
      (should (equal gptel-permit-judge-test--captured-params
                     '(:reasoning_effort "low")))
      (should (string-match-p "Judge request params: (:reasoning_effort \"low\")"
                              (gptel-permit-judge-test--log-string))))))

(ert-deftest gptel-permit-judge-derives-thinking-off-by-default ()
  "With nil user params the judge derives and logs thinking-off params."
  (let ((gptel-permit-judge-request-params nil)
        (gptel-permit-judge-backend "stub")
        (gptel-permit-judge-timeout 0)
        (gptel-permit-log-enabled t))
    (gptel-permit-judge-test--clear-log)
    (gptel-permit-judge-test--with-capture (gptel--make-anthropic :name "stub")
      (gptel-permit--judge-request-sync "p")
      (should (equal gptel-permit-judge-test--captured-params
                     '(:thinking (:type "disabled"))))
      (should (string-match-p
               "Judge request params: (:thinking (:type \"disabled\"))"
               (gptel-permit-judge-test--log-string))))))

(ert-deftest gptel-permit-judge-request-params-empty-list-is-nil ()
  "An \"explicitly empty\" plist is nil in Emacs Lisp, so it derives.
'() and nil are the same object: there is no distinguishable
empty-list state, and the thinking-off default applies.  To
suppress injection entirely, set a non-nil plist re-enabling
what you want, or use an unrecognized backend (nil derivation)."
  (let ((gptel-permit-judge-request-params '())
        (gptel-permit-judge-backend "stub")
        (gptel-permit-judge-timeout 0))
    (gptel-permit-judge-test--with-capture (gptel--make-ollama :name "stub")
      (gptel-permit--judge-request-sync "p")
      (should (equal gptel-permit-judge-test--captured-params
                     '(:think :json-false))))))

(ert-deftest gptel-permit-judge-sync-sends-system-nil ()
  "The judge request carries an explicit :system nil keyword argument."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-timeout 0)
        (captured-keys :unset))
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest keys)
                 (setq captured-keys keys)
                 nil))
              ((symbol-function 'gptel-get-backend)
               (lambda (_name) 'fake-judge-backend)))
      (gptel-permit--judge-request-sync "p")
      (should (plist-member captured-keys :system))
      (should (null (plist-get captured-keys :system))))))


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

(ert-deftest gptel-permit-judge-payload-isolated-from-session-system-prompt ()
  "End-to-end gptel dry-run: a buffer-local session system prompt
never reaches the judge payload; derived thinking-off params do."
  (let* ((gptel-permit-judge-backend "gptel-permit-test-ollama")
         (gptel-permit-judge-model "test-model")
         (gptel-permit-judge-timeout 0)
         (backend (gptel--make-ollama :name "gptel-permit-test-ollama"
                                       :models '(test-model)))
         (real-request (symbol-function 'gptel-request))
         (fsm nil))
    (with-temp-buffer
      (set (make-local-variable 'gptel-system-prompt) "SESSION CANARY PROMPT")
      (cl-letf (((symbol-function 'gptel-get-backend)
                 (lambda (_name) backend))
                ((symbol-function 'gptel-request)
                 (lambda (&rest args)
                   (setq fsm (apply real-request
                                    (append args (list :dry-run t)))))))
        (gptel-permit--judge-request-sync "probe"))
      (let* ((data (plist-get (gptel-fsm-info fsm) :data))
             (messages (append (plist-get data :messages) nil)))
        (should-not (cl-some (lambda (m) (string= (plist-get m :role) "system"))
                             messages))
        (should (cl-some (lambda (m) (string= (plist-get m :role) "user"))
                         messages))
        (should (equal (plist-get data :think) :json-false))))))


(provide 'gptel-permit-judge-test)
;;; gptel-permit-judge-test.el ends here
