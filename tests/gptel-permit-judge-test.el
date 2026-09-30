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

(ert-deftest gptel-permit-judge-parse-safe-no-rationale ()
  (should (equal (gptel-permit--judge-parse-verdict "SAFE")
                 '(safe . ""))))

(ert-deftest gptel-permit-judge-parse-divider-keeps-text-below-first ()
  "The divider is the first standalone verdict line; later duplicate
verdict lines are part of the rationale text below it."
  (should (equal (gptel-permit--judge-parse-verdict
                  "SAFE\nPart one.\nSAFE\nPart two.")
                 '(safe . "Part one.\nSAFE\nPart two."))))


(ert-deftest gptel-permit-judge-parse-leaked-deliberation-parses ()
  "Reasoning before the verdict no longer hides it: the first standalone verdict line divides reasoning from rationale."
  (should (equal (gptel-permit--judge-parse-verdict
                  "The user asks me to classify a tool call.\nAnalysis: read-only inside the project.\nSAFE\nRead-only ls inside the project.")
                 '(safe . "Read-only ls inside the project.")))
  (should (equal (gptel-permit--judge-parse-verdict
                  "Deliberation text.\nUNSAFE\nTouches system-wide state.")
                 '(unsafe . "Touches system-wide state."))))


(ert-deftest gptel-permit-judge-parse-unsafe ()
  (should (equal (gptel-permit--judge-parse-verdict "UNSAFE\nTouches /etc")
                 '(unsafe . "Touches /etc"))))

(ert-deftest gptel-permit-judge-parse-divider-drops-thinking-above ()
  "Text above the first standalone verdict line is dropped as reasoning;
a verdict word inside a prose line does not count."
  (should (equal (gptel-permit--judge-parse-verdict
                  "Analyzing the command.\nThis seems SAFE to me in prose.\nSAFE\nRead-only ls in project.")
                 '(safe . "Read-only ls in project."))))


(ert-deftest gptel-permit-judge-parse-garbage-is-nil ()
  (should (null (gptel-permit--judge-parse-verdict "I think it's fine")))
  (should (null (gptel-permit--judge-parse-verdict "")))
  (should (null (gptel-permit--judge-parse-verdict nil))))

(ert-deftest gptel-permit-judge-parse-reasoning-markers-are-ordinary-text ()
  "Markers that are not closing think tags — pseudo-blocks, fences,
an UNCLOSED think block — are ordinary text above the divider; only
a closing think tag triggers the drop-through heuristic."
  (should (equal (gptel-permit--judge-parse-verdict
                  "[[reasoning]]\nLet me consider the blast radius.\n[[/reasoning]]\n\nSAFE\nRead-only inside project.")
                 '(safe . "Read-only inside project.")))
  (should (equal (gptel-permit--judge-parse-verdict
                  (concat "<" "think" ">Still reasoning out loud.\n"
                          "SAFE\nRead-only inside project."))
                 '(safe . "Read-only inside project."))))


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

(ert-deftest gptel-permit-judge-parse-unclosed-think-draft-conflict-is-unparseable ()
  "A verdict word drafted as a standalone line inside UNCLOSED leaked
reasoning conflicts with the conclusion, so the response
fail-closes: without a closing tag there is no trustworthy
boundary, and no stripping decides which word was meant."
  (let ((open (concat "<" "think" ">")))
    (should (null (gptel-permit--judge-parse-verdict
                   (concat open "Could this be\nUNSAFE\n? No, it is local.\n\nSAFE\nRead-only"))))
    (should (null (gptel-permit--judge-parse-verdict
                   (concat open "\nSAFE\nRead-only draft.\n\nUNSAFE\nTouches /etc"))))))

(ert-deftest gptel-permit-judge-drop-thinking-drops-through-last-closing-tag ()
  "A closing think tag cuts; the LAST one wins; unclosed stays whole."
  (let ((close (concat "<" "/think" ">"))
        (close-long (concat "<" "/thinking" ">"))
        (open (concat "<" "think" ">")))
    (should (equal (gptel-permit--judge-drop-thinking
                    (concat "Reasoning prose." close "SAFE\nReason"))
                   "SAFE\nReason"))
    (should (equal (gptel-permit--judge-drop-thinking
                    (concat "One" close "Two" close "Three"))
                   "Three"))
    (should (equal (gptel-permit--judge-drop-thinking
                    (concat "Pondering" close-long "SAFE\nFine"))
                   "SAFE\nFine"))
    (should (equal (gptel-permit--judge-drop-thinking
                    (concat open "Still reasoning out loud"))
                   (concat open "Still reasoning out loud")))
    (should (equal (gptel-permit--judge-drop-thinking "Plain answer")
                   "Plain answer"))))

(ert-deftest gptel-permit-judge-parse-closing-tag-glued-verdict-parses ()
  "Observed cloud-model failure shape: deliberation, then a closing
think tag glued between prose and the verdict on one line.  Dropping
through the tag leaves a standalone verdict line."
  (should (equal (gptel-permit--judge-parse-verdict
                  (concat "Let me analyze the command.\n"
                          "Read-only ls inside the project.\n"
                          "Answer: SAFE with short rationale."
                          "<" "/think" ">" "SAFE\n"
                          "Read-only project-local operations."))
                 '(safe . "Read-only project-local operations."))))

(ert-deftest gptel-permit-judge-parse-draft-inside-closed-block-resolves ()
  "A verdict word drafted inside a CLOSED reasoning block is dropped
with the block; only the conclusion counts."
  (let ((close (concat "<" "/think" ">")))
    (should (equal (gptel-permit--judge-parse-verdict
                    (concat "Thinking...\nUNSAFE\n" close "\nSAFE\nRead-only"))
                   '(safe . "Read-only")))
    (should (equal (gptel-permit--judge-parse-verdict
                    (concat "Thinking...\nSAFE\n" close "\nUNSAFE\nTouches /etc"))
                   '(unsafe . "Touches /etc")))))




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

(ert-deftest gptel-permit-judge-parse-fail-rationale-is-untruncated ()
  "The raw response stored and logged on parse-fail is kept in full:
truncation hinders debugging."
  (let* ((gptel-permit-judge-backend "stub")
         (gptel-permit-log-enabled t)
         (raw (make-string 200 ?x)))
    (gptel-permit-judge-test--clear-log)
    (gptel-permit-judge-test--with-request raw
      (should (null (gptel-permit-judge-safe-p
                     "ls" (list :name "Bash" :args '(:command "ls")))))
      (should (eq gptel-permit--last-judge-verdict 'parse-fail))
      (should (equal gptel-permit--last-judge-rationale raw))
      (should (= (length gptel-permit--last-judge-rationale) 200))
      (should (string-match-p (regexp-quote raw)
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
                  (gptel--make-ollama :name "l") "qwen3:4b")
                 '(:think :json-false))))

(ert-deftest gptel-permit-judge-ollama-gpt-oss-derives-level ()
  "GPT-OSS models ignore boolean think; they derive the low level."
  (should (equal (gptel-permit--judge-thinking-off-params
                  (gptel--make-ollama :name "l") "gpt-oss:20b")
                 '(:think "low")))
  (should (equal (gptel-permit--judge-thinking-off-params
                  (gptel--make-ollama :name "l") "gpt-oss")
                 '(:think "low")))
  ;; No model or a non-gpt-oss model: the boolean is a harmless no-op
  ;; for models without a thinking capability.
  (should (equal (gptel-permit--judge-thinking-off-params
                  (gptel--make-ollama :name "l") nil)
                 '(:think :json-false)))
  (should (equal (gptel-permit--judge-thinking-off-params
                  (gptel--make-ollama :name "l") "gpt-ossx:8b")
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

(ert-deftest gptel-permit-judge-control-thinking-nil-gates-derivation ()
  "`gptel-permit-judge-control-thinking' nil: no thinking-related
parameters are derived or injected.  Explicit request params still
go through verbatim, and non-nil restores the derived default."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-model "qwen3:4b")
        (gptel-permit-judge-timeout 0)
        (gptel-permit-log-enabled t))
    (gptel-permit-judge-test--clear-log)
    (let ((gptel-permit-judge-control-thinking nil))
      (gptel-permit-judge-test--with-capture (gptel--make-ollama :name "stub")
        (gptel-permit--judge-request-sync "p")
        (should (null gptel-permit-judge-test--captured-params))))
    (let ((gptel-permit-judge-control-thinking t))
      (gptel-permit-judge-test--with-capture (gptel--make-ollama :name "stub")
        (gptel-permit--judge-request-sync "p")
        (should (equal gptel-permit-judge-test--captured-params
                       '(:think :json-false)))))
    (let ((gptel-permit-judge-control-thinking nil)
          (gptel-permit-judge-request-params '(:think t)))
      (gptel-permit-judge-test--with-capture (gptel--make-ollama :name "stub")
        (gptel-permit--judge-request-sync "p")
        (should (equal gptel-permit-judge-test--captured-params
                       '(:think t)))))))


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
      (should (equal (gptel-permit--find-action
                      "test-id"
                      (gptel-permit--enrich-tool-call
                       (list :name "Bash" :args '(:command "ls ./src"))))
                     'allow)))
    (gptel-permit-judge-test--with-request "UNSAFE\nsystem-wide"
      (should (equal (gptel-permit--find-action
                      "test-id"
                      (gptel-permit--enrich-tool-call
                       (list :name "Bash" :args '(:command "apt install x"))))
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

;; -------------------------------------------------------------------
;; Self-registration at load: per-call state lifecycle
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-judge-load-registers-reset-state ()
  "Requiring the module adds its state reset to the engine's lifecycle
hook, so the core needs no judge knowledge."
  (should (memq #'gptel-permit-judge--reset-state
                gptel-permit-before-rule-match-functions)))

;; -------------------------------------------------------------------
;; Judging status line: per-call verdicts inside a pack indicator
;; -------------------------------------------------------------------

(defmacro gptel-permit-judge-test--with-pack (entries &rest body)
  "Set up a fake gptel tool pack overlay for ENTRIES and run BODY.
ENTRIES is a list of (TOOL-NAME ARGS RESOLVED); every entry gets a
stash record and contributes a pending-call triple to one shared pack
overlay.  That overlay also carries a live prompt overlay, which is
the shape gptel builds: triples and prompt live on the same dispatch
overlay (`gptel-permit--judge-find-pending-overlay' scans overlays for
the triple).  Binds PACK-OV (the pack overlay) around BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (insert "context text")
     (let* ((pack-ov (make-overlay 1 2 nil nil t))
            (prompt-ov (make-overlay 1 2 nil nil t))
            (entries ,entries))
       (overlay-put pack-ov 'prompt (list prompt-ov))
       (overlay-put pack-ov 'gptel-tool
                    (mapcar (pcase-lambda (`(,name ,args ,_resolved))
                              (list (gptel--make-tool-internal
                                     :name name :function #'ignore
                                     :description "d" :args-type 'plist)
                                    args #'ignore))
                            entries))
       (setf gptel-permit--judge-pending
             (mapcar (pcase-lambda (`(,name ,args ,resolved))
                       (cons (cons name args)
                             (list :on-safe '(:confirm nil)
                                   :on-unsafe '(:confirm t)
                                   :tool-call (list :name name :args args)
                                   :issued-at (current-time)
                                   :timeout-timer nil
                                   :resolved resolved
                                   :pack-ov pack-ov
                                   :buffer (current-buffer))))
                     entries))
       ,@body
       (setf gptel-permit--judge-pending nil))))

(ert-deftest gptel-permit-judge-test/status-line-mixed-pack ()
  "A verdict on one call shows in the pack's status line while its
unjudged sibling keeps waiting; the indicator overlay stays live."
  (gptel-permit-judge-test--with-pack
      '(("Bash" (:command "df") safe)
        ("Glob" (:path "/tmp/x") nil))
    (let ((ind (gptel-permit--judge-refresh-indicator pack-ov)))
      (should (overlayp ind))
      (let ((line (overlay-get ind 'before-string)))
        (should (string-match-p "Bash" line))
        (should (string-match-p "✅" line))
        (should (string-match-p "Glob" line))
        (should (string-match-p "⏳" line))
        (should-not (string-match-p "manual confirm required" line))))))

(ert-deftest gptel-permit-judge-test/status-line-all-judged ()
  "When every judged call still awaits a manual decision (e.g. the
pack had a non-judged sibling that forces =ask=), the line says so."
  (gptel-permit-judge-test--with-pack
      '(("Bash" (:command "df") safe)
        ("Glob" (:path "/tmp/x") t))
    (let ((ind (gptel-permit--judge-refresh-indicator pack-ov)))
      (should (overlayp ind))
      (should (string-match-p "manual confirm required"
                              (overlay-get ind 'before-string))))))

(ert-deftest gptel-permit-judge-test/status-line-drops-when-nothing-pends ()
  "With no judge-gated entries left on the pack, refreshing deletes
the indicator instead of leaving a stale line."
  (gptel-permit-judge-test--with-pack '(("Bash" (:command "df") safe))
    (let ((ind (gptel-permit--judge-refresh-indicator pack-ov)))
      (should (overlayp ind))
      (setf gptel-permit--judge-pending nil)
      (should-not (gptel-permit--judge-refresh-indicator pack-ov))
      (should-not (overlay-buffer ind)))))



(provide 'gptel-permit-judge-test)
;;; gptel-permit-judge-test.el ends here
