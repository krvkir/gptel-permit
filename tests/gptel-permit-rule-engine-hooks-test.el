;;; gptel-permit-rule-engine-hooks-test.el --- Tests for engine hooks -*- lexical-binding: t; -*-

;; Tests for the core engine extension points: action registry,
;; tool-call id minting, and the events/veto/before-match hooks.

(require 'ert)
(require 'gptel-permit)

;; -------------------------------------------------------------------
;; Tool-call id minting
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-mint-tool-call-id-format ()
  "Minted tool-call ids are TIMESTAMP.PID.SERIAL with millisecond precision."
  (let ((id (gptel-permit--mint-tool-call-id)))
    (should (stringp id))
    (should (string-match-p
             (rx bos (= 8 digit) "T" (= 6 digit) "." (= 3 digit)
                 "." (+ digit) "." (+ digit) eos)
             id))
    ;; The middle component is the current Emacs pid.
    (should (string-match-p (format "\\`[^.]*\\.[^.]*\\.%d\\." (emacs-pid))
                            id))))

(ert-deftest gptel-permit-mint-tool-call-id-unique-within-session ()
  "Consecutively minted tool-call ids are pairwise distinct."
  (let ((ids (cl-loop repeat 50 collect (gptel-permit--mint-tool-call-id))))
    (should (= 50 (length (delete-dups ids))))))

;; -------------------------------------------------------------------
;; Action registry
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-action-handlers-builtin-entries ()
  "The registry pre-registers allow, deny and ask handlers."
  (should (eq (cdr (assq 'allow gptel-permit-action-handlers))
              #'gptel-permit--action-allow))
  (should (eq (cdr (assq 'deny gptel-permit-action-handlers))
              #'gptel-permit--action-deny))
  (should (eq (cdr (assq 'ask gptel-permit-action-handlers))
              #'gptel-permit--action-ask)))

(ert-deftest gptel-permit-action-handlers-builtin-verdicts ()
  "Built-in handlers return the documented verdicts under (ID TOOL-CALL)."
  (should (equal (funcall (cdr (assq 'allow gptel-permit-action-handlers))
                          "test-id" nil)
                 '(:confirm nil)))
  (should (equal (funcall (cdr (assq 'deny gptel-permit-action-handlers))
                          "test-id" nil)
                 '(:block "auto-denied")))
  (should (equal (funcall (cdr (assq 'ask gptel-permit-action-handlers))
                          "test-id" nil)
                 '(:confirm t))))

;; -------------------------------------------------------------------
;; Events hook error isolation
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-emit-event-isolates-errors ()
  "An erroring observer is skipped; later observers still run."
  (let* ((seen nil)
         (gptel-permit-events-functions
          (list (lambda (&rest _)
                  (error "observer boom"))
                (lambda (_id _tc type payload)
                  (push (cons type payload) seen)))))
    ;; No error escapes; the return value is nil.
    (should (null (gptel-permit--emit-event "id" nil :rule-match 'allow)))
    (should (equal seen '((:rule-match . allow))))))

(ert-deftest gptel-permit-emit-event-no-observers ()
  "Emitting an event with no observers is a harmless no-op."
  (let ((gptel-permit-events-functions nil))
    (should (null (gptel-permit--emit-event "id" nil :tool-call nil)))))

;; -------------------------------------------------------------------
;; Registry dispatch behavior
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-registry-dispatches-custom-action ()
  "A module-registered custom action is invoked with (ID TOOL-CALL)
— the id a string, the tool call enriched — and its verdict wins."
  (let* ((seen nil)
         (handler (lambda (id tool-call)
                    (push (list id (plist-get tool-call :tool-group)) seen)
                    '(:confirm nil)))
         (gptel-permit-action-handlers
          (cons (cons 'my-action handler) gptel-permit-action-handlers))
         (gptel-permit-rules '((:tool "Bash" :action my-action)))
         (gptel-permit-global-rules nil))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "ls")))
                   '(:confirm nil)))
    (should (= 1 (length seen)))
    (should (stringp (car (car seen))))
    ;; The tool call arrived enriched: Bash resolves to the execute group.
    (should (eq (cadr (car seen)) 'execute))))

(ert-deftest gptel-permit-registry-unregistered-action-fails-closed ()
  "A matched action with no registered handler returns (:confirm t),
never nil (defer) — an unresolved rule must not auto-run a tool whose
:confirm slot is nil."
  (let ((gptel-permit-rules '((:tool "Bash" :action frobnicate)))
        (gptel-permit-global-rules nil))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "ls")))
                   '(:confirm t)))))

(ert-deftest gptel-permit-registry-handler-nil-defers ()
  "A registered handler returning nil defers like a non-matching call."
  (let* ((handler (lambda (_id _tc) nil))
         (gptel-permit-action-handlers
          (cons (cons 'maybe handler) gptel-permit-action-handlers))
         (gptel-permit-rules '((:tool "Bash" :action maybe)))
         (gptel-permit-global-rules nil))
    (should (null (gptel-permit--apply-rules
                   (list :name "Bash" :args '(:command "ls")))))))

(ert-deftest gptel-permit-registry-session-over-global ()
  "Session rules take precedence over global rules through the chain."
  (let ((gptel-permit-rules '((:tool "Bash" :action allow)))
        (gptel-permit-global-rules '((:tool "Bash" :action ask))))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "ls")))
                   '(:confirm nil)))))

;; -------------------------------------------------------------------
;; Before-match hook behavior
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-before-match-hook-runs-between-event-and-matching ()
  "Ordering probe: the :tool-call event is observed first, the
before-match hook runs second, matching begins third."
  (let* ((log nil)
         (gptel-permit-events-functions
          (list (lambda (_id _tc type _pl)
                  (when (eq type :tool-call)
                    (push 'observed-tool-call log)))))
         (gptel-permit-before-rule-match-functions
          (list (lambda (_id _tc)
                  (push 'ran-hook log))))
         (gptel-permit-rules
          `((:tool "Bash"
                   :conditions ((:command . ,(lambda (_v _tc)
                                               (push 'started-matching log)
                                               nil)))
                   :action ask)))
         (gptel-permit-global-rules nil))
    (should (null (gptel-permit--apply-rules
                   (list :name "Bash" :args '(:command "ls")))))
    (should (equal (nreverse log)
                   '(observed-tool-call ran-hook started-matching)))))

(ert-deftest gptel-permit-before-match-hook-error-fails-closed ()
  "An erroring before-match function fails the call closed."
  (let ((gptel-permit-before-rule-match-functions
         (list (lambda (_id _tc) (error "lifecycle boom"))))
        (gptel-permit-rules '((:tool "Bash" :action allow)))
        (gptel-permit-global-rules nil))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "ls")))
                   '(:confirm t)))))

;; -------------------------------------------------------------------
;; Veto hook behavior
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-veto-error-fails-closed ()
  "An erroring veto function fails the call closed."
  (let ((gptel-permit-veto-functions
         (list (lambda (_id _tc _v) (error "veto boom"))))
        (gptel-permit-rules '((:tool "Bash" :action allow)))
        (gptel-permit-global-rules nil))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "ls")))
                   '(:confirm t)))))

(ert-deftest gptel-permit-veto-upgrade-preserves-args ()
  "A vetoed verdict is upgraded to (:confirm t) keeping its args
rewrite — the user confirms the rewritten call."
  (let* ((handler (lambda (_id tool-call)
                    (list :confirm nil
                          :args (plist-put (copy-sequence
                                            (plist-get tool-call :args))
                                           :command "rewritten"))))
         (gptel-permit-action-handlers
          (cons (cons 'rewriter handler) gptel-permit-action-handlers))
         (gptel-permit-veto-functions
          (list (lambda (_id _tc _v) t)))
         (gptel-permit-rules '((:tool "Bash" :action rewriter)))
         (gptel-permit-global-rules nil))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "ls")))
                   '(:confirm t :args (:command "rewritten"))))))

(ert-deftest gptel-permit-veto-first-wins-and-short-circuits ()
  "The first positive veto wins; later veto functions are not consulted."
  (let* ((calls nil)
         (gptel-permit-veto-functions
          (list (lambda (_id _tc _v) (push 1 calls) t)
                (lambda (_id _tc _v) (push 2 calls) t)))
         (gptel-permit-rules '((:tool "Bash" :action allow)))
         (gptel-permit-global-rules nil))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "ls")))
                   '(:confirm t)))
    (should (equal calls '(1)))))

(ert-deftest gptel-permit-veto-not-consulted-on-defer ()
  "With no matching rule the veto functions are not consulted and the
hook returns nil (defer)."
  (let* ((vetoed nil)
         (gptel-permit-veto-functions
          (list (lambda (_id _tc _v) (setq vetoed t) t)))
         (gptel-permit-rules nil)
         (gptel-permit-global-rules nil))
    (should (null (gptel-permit--apply-rules
                   (list :name "Read" :args '(:file_path "x.txt")))))
    (should-not vetoed)))

;; -------------------------------------------------------------------
;; Events chains
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-events-allow-chain-order ()
  "An allow chain observes :tool-call, :rule-match, :verdict — no
:confirm — all with the same id and the enriched tool call."
  (let* ((seen nil)
         (ids nil)
         (gptel-permit-events-functions
          (list (lambda (id tc type payload)
                  (push (list type payload (plist-get tc :tool-group)) seen)
                  (push id ids))))
         (gptel-permit-rules '((:tool "Bash" :action allow)))
         (gptel-permit-global-rules nil))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "ls")))
                   '(:confirm nil)))
    (should (equal (nreverse seen)
                   '((:tool-call nil execute)
                     (:rule-match allow execute)
                     (:verdict (allow :confirm nil) execute))))
    (should (= 1 (length (delete-dups ids))))))

(ert-deftest gptel-permit-events-ask-chain-ends-with-confirm ()
  "An ask chain ends with :verdict followed by :confirm for one id."
  (let* ((seen nil)
         (ids nil)
         (gptel-permit-events-functions
          (list (lambda (id _tc type _pl)
                  (push type seen)
                  (push id ids))))
         (gptel-permit-rules '((:tool "Bash" :action ask)))
         (gptel-permit-global-rules nil))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "ls")))
                   '(:confirm t)))
    (should (equal (nreverse seen)
                   '(:tool-call :rule-match :verdict :confirm)))
    (should (= 1 (length (delete-dups ids))))))

(ert-deftest gptel-permit-events-no-match-chain ()
  "A no-match chain observes :rule-match with nil action and a :verdict
whose action and verdict are both nil — no :confirm."
  (let* ((seen nil)
         (gptel-permit-events-functions
          (list (lambda (_id _tc type payload)
                  (push (cons type payload) seen))))
         (gptel-permit-rules nil)
         (gptel-permit-global-rules nil))
    (should (null (gptel-permit--apply-rules
                   (list :name "Read" :args '(:file_path "x.txt")))))
    ;; The :verdict payload is (cons action verdict) = (nil . nil).
    (should (equal (nreverse seen)
                   '((:tool-call) (:rule-match) (:verdict nil))))))

(ert-deftest gptel-permit-events-unknown-type-passes-through ()
  "A future event type outside today's enumeration reaches observers
verbatim; observers treat an unknown TYPE as data."
  (let* ((seen nil)
         (gptel-permit-events-functions
          (list (lambda (_id _tc type payload)
                  (push (cons type payload) seen)))))
    (gptel-permit--emit-event "id" nil :future-event 'whatever)
    (should (equal (car seen) '(:future-event . whatever)))))

;; -------------------------------------------------------------------
;; No observers: engine behavior unchanged
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-engine-no-hooks-behavior-unchanged ()
  "With all three engine hooks empty, verdicts are exactly the classic
protocol — no observers needed for meaningful operation."
  (let ((gptel-permit-events-functions nil)
        (gptel-permit-veto-functions nil)
        (gptel-permit-before-rule-match-functions nil)
        (gptel-permit-rules
         '((:tool "Bash" :conditions ((:command . "^allow")) :action allow)
           (:tool "Bash" :conditions ((:command . "^deny")) :action deny)
           (:tool "Bash" :conditions ((:command . "^ask")) :action ask)))
        (gptel-permit-global-rules nil))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "allow me")))
                   '(:confirm nil)))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "deny me")))
                   '(:block "auto-denied")))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "ask me")))
                   '(:confirm t)))
    (should (null (gptel-permit--apply-rules
                   (list :name "Bash" :args '(:command "no rule")))))))


(provide 'gptel-permit-rule-engine-hooks-test)
;;; gptel-permit-rule-engine-hooks-test.el ends here
