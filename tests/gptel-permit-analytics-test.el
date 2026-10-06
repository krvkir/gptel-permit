;;; gptel-permit-analytics-test.el --- Tests for analytics -*- lexical-binding: t; -*-
;;
;; Cross-module integration suite: requires core + judge + sandbox +
;; analytics (the full-chain scenarios read judge state and sandbox
;; rewrites through the documented dynamic-scope contracts).

(require 'ert)
(require 'json)
(require 'gptel)
(require 'gptel-permit)
(require 'gptel-permit-judge)
(require 'gptel-permit-sandbox)
(require 'gptel-permit-analytics)

;; -------------------------------------------------------------------
;; Helpers
;; -------------------------------------------------------------------

(defun gptel-permit-analytics-test--fresh-file ()
  "Return the path of a not-yet-existing temp analytics file."
  (concat (file-name-as-directory temporary-file-directory)
          (make-temp-name "gptel-permit-analytics-test-") ".jsonl"))

(defmacro gptel-permit-analytics-test--with-file (&rest body)
  "Run BODY against a fresh analytics file path with pristine state.
Installs the analytics observer and audit predicate on the core engine
hooks for the duration of BODY (as registration would) and removes
them afterwards; BODY activates capture itself by setting the
registered/enabled flags or calling the register function."
  (declare (indent 0))
  `(let ((gptel-permit-analytics-file (gptel-permit-analytics-test--fresh-file))
         ;; Ambient rate 0.0: the audit predicate is installed for every
         ;; test, so a nonzero default here would let sampling fire at
         ;; random and break tests that expect an auto-allow to survive.
         ;; Tests that exercise sampling bind their own rate (and pin
         ;; `random') explicitly.
         (gptel-permit-analytics-sample-rate 0.0)
         (gptel-permit-analytics-enabled nil)
         (gptel-permit-analytics--registered nil)
         (gptel-permit-analytics--pending nil))
     (add-hook 'gptel-permit-events-functions
               #'gptel-permit-analytics--observe)
     (add-hook 'gptel-permit-veto-functions
               #'gptel-permit-analytics--audit-p)
     (unwind-protect
         (progn ,@body)
       (remove-hook 'gptel-permit-events-functions
                    #'gptel-permit-analytics--observe)
       (remove-hook 'gptel-permit-veto-functions
                    #'gptel-permit-analytics--audit-p)
       (gptel-permit-unregister-analytics-hooks)
       (when (and gptel-permit-analytics-file
                  (file-exists-p gptel-permit-analytics-file))
         (delete-file gptel-permit-analytics-file)))))

(defun gptel-permit-analytics-test--events (file)
  "Return the parsed JSON events of FILE as alists."
  (with-temp-buffer
    (insert-file-contents file)
    (mapcar #'json-read-from-string (split-string (buffer-string) "\n" t))))

(defun gptel-permit-analytics-test--field (event key)
  "Return the value of KEY in parsed EVENT."
  (cdr (assoc key event)))

(defun gptel-permit-analytics-test--types (file)
  "Return the list of event types in FILE, in file order."
  (mapcar (lambda (e) (gptel-permit-analytics-test--field e 'type))
          (gptel-permit-analytics-test--events file)))

(defun gptel-permit-analytics-test--fake-tool (name)
  "Return a gptel tool spec named NAME."
  (gptel-make-tool :name name :function #'ignore
                   :description "analytics test tool" :args nil))

(defmacro gptel-permit-analytics-test--with-judge-response (response &rest body)
  "Run BODY with `gptel-request' stubbed to deliver RESPONSE to the judge."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'gptel-request)
              (lambda (_prompt &rest keys)
                (let ((cb (plist-get keys :callback)))
                  (when cb (funcall cb ,response nil)))
                nil))
             ((symbol-function 'gptel-get-backend)
              (lambda (_name) 'fake-judge-backend)))
     ,@body))

;; -------------------------------------------------------------------
;; Off by default
;; -------------------------------------------------------------------

;; -------------------------------------------------------------------
;; Judge action integration (judge-verdict events, programmatic
;; decisions, resolution-time audit sampling, action serialization)
;; -------------------------------------------------------------------

(defvar gptel-permit-analytics-test--async-callback nil)

(defmacro gptel-permit-analytics-test--with-async-judge (&rest body)
  "Run BODY with the judge's request stubbed to capture its callback."
  (declare (indent 0))
  `(let ((gptel-permit-analytics-test--async-callback nil))
     (cl-letf (((symbol-function 'gptel-request)
                (lambda (_prompt &rest keys)
                  (setq gptel-permit-analytics-test--async-callback
                        (plist-get keys :callback))
                  nil))
               ((symbol-function 'gptel-get-backend)
                (lambda (_name) 'fake-judge-backend)))
       ,@body)))

(ert-deftest gptel-permit-analytics-judge-action-string-serializes ()
  "List-form judge actions serialize distinctly."
  (should (equal (gptel-permit-analytics--action-string '(judge sandbox deny))
                 "judge:sandbox/deny"))
  (should (equal (gptel-permit-analytics--action-string 'judge) "judge"))
  (should (equal (gptel-permit-analytics--action-string '(judge)) "judge"))
  (should (equal (gptel-permit-analytics--action-string nil) "none")))

(ert-deftest gptel-permit-analytics-async-safe-chain-one-id ()
  "Async SAFE: all events share the call's id."
  (gptel-permit-analytics-test--with-file
    (let ((gptel-permit-analytics--registered t)
          (gptel-permit-analytics-enabled t)
          (gptel-permit-judge-backend "stub")
          (gptel-permit-judge-async t)
          (gptel-permit-judge-timeout 60)
          (gptel-permit-rules '((:tool "Bash" :action judge)))
          (gptel-permit-global-rules nil)
          ;; The veto hook is global: another test file may have left
          ;; functions on it — start from a known state.
          (gptel-permit-veto-functions
           (list #'gptel-permit-analytics--audit-p))
          (accepted nil))
      (with-temp-buffer
        (let* ((spec (gptel--make-tool-internal
                      :name "Bash" :function #'ignore :description "t"))
               (triple (list spec '(:command "ls") (lambda (_))))
               (ov (make-overlay (point-min) (point-min)))
               (prompt-ov (make-overlay (point-min) (point-min))))
          (overlay-put ov 'gptel-tool (list triple))
          (overlay-put ov 'prompt (list prompt-ov))
          (gptel-permit-analytics-test--with-async-judge
            (cl-letf (((symbol-function 'gptel--accept-tool-calls)
                       (lambda (_tc _ov) (setq accepted t))))
              (should (equal (gptel-permit--apply-rules
                              (list :name "Bash" :args '(:command "ls")
                                    :buffer (buffer-name)))
                             '(:confirm t)))
              (funcall gptel-permit-analytics-test--async-callback
                       "SAFE\nfine" nil)
              (should accepted)))))
      (let* ((events (gptel-permit-analytics-test--events
                      gptel-permit-analytics-file))
             (types (mapcar (lambda (e)
                              (gptel-permit-analytics-test--field e 'type))
                            events))
             (ids (delete-dups
                   (mapcar (lambda (e)
                             (gptel-permit-analytics-test--field e 'id))
                           events))))
        (should (equal types '("tool-call" "rule-match" "verdict" "confirm"
                               "judge-verdict" "decision")))
        (should (= (length ids) 1))
        (let ((jv (nth 4 events))
              (dec (nth 5 events)))
          (should (equal (gptel-permit-analytics-test--field jv 'judge-verdict)
                         "safe"))
          (should (equal (gptel-permit-analytics-test--field jv 'judge-rationale)
                         "fine"))
          (should (numberp (gptel-permit-analytics-test--field
                            jv 'judge-latency-ms)))
          (should (equal (gptel-permit-analytics-test--field dec 'choice)
                         "auto-allow")))))))

(ert-deftest gptel-permit-analytics-async-unsafe-manual-decision ()
  "Async UNSAFE to ask: judge-verdict records unsafe, the pack stays,
and the user's later manual decision carries the wait."
  (gptel-permit-analytics-test--with-file
    (let ((gptel-permit-analytics--registered t)
          (gptel-permit-analytics-enabled t)
          (gptel-permit-judge-backend "stub")
          (gptel-permit-judge-async t)
          (gptel-permit-judge-timeout 60)
          (gptel-permit-rules '((:tool "Bash" :action judge)))
          (gptel-permit-global-rules nil)
          (gptel-permit-veto-functions
           (list #'gptel-permit-analytics--audit-p))
          (accepted nil))
      (with-temp-buffer
        (let* ((spec (gptel--make-tool-internal
                      :name "Bash" :function #'ignore :description "t"))
               (triple (list spec '(:command "rm -rf /") (lambda (_))))
               (ov (make-overlay (point-min) (point-min)))
               (prompt-ov (make-overlay (point-min) (point-min))))
          (overlay-put ov 'gptel-tool (list triple))
          (overlay-put ov 'prompt (list prompt-ov))
          (gptel-permit-analytics-test--with-async-judge
            (cl-letf (((symbol-function 'gptel--accept-tool-calls)
                       (lambda (_tc _ov) (setq accepted t))))
              (gptel-permit--apply-rules
               (list :name "Bash" :args '(:command "rm -rf /")
                     :buffer (buffer-name)))
              (funcall gptel-permit-analytics-test--async-callback
                       "UNSAFE\ntouches /etc" nil)
              (should (overlay-buffer ov))
              (should-not accepted)
              ;; The user answers the prompt manually: the advice fires
              ;; outside any programmatic binding and records "allow".
              (gptel-permit-analytics--record-decision
               "allow" (list triple) ov)))))
      (let* ((events (gptel-permit-analytics-test--events
                      gptel-permit-analytics-file))
             (types (mapcar (lambda (e)
                              (gptel-permit-analytics-test--field e 'type))
                            events))
             (jv (cl-find "judge-verdict" events
                          :key (lambda (e)
                                 (gptel-permit-analytics-test--field e 'type))
                          :test #'equal))
             (dec (cl-find "decision" events
                           :key (lambda (e)
                                  (gptel-permit-analytics-test--field e 'type))
                           :test #'equal)))
        (should (equal types '("tool-call" "rule-match" "verdict" "confirm"
                               "judge-verdict" "decision")))
        (should (equal (gptel-permit-analytics-test--field jv 'judge-verdict)
                       "unsafe"))
        (should (equal (gptel-permit-analytics-test--field dec 'choice)
                       "allow"))
        (should (numberp (gptel-permit-analytics-test--field dec 'wait-ms)))))))

(ert-deftest gptel-permit-analytics-sampled-judge-never-auto-resolves ()
  "Sample-rate 1.0: the audit event is emitted, the judge verdict is
recorded, and the pack stays on the prompt."
  (gptel-permit-analytics-test--with-file
    (let ((gptel-permit-analytics--registered t)
          (gptel-permit-analytics-enabled t)
          (gptel-permit-analytics-sample-rate 1.0)
          (gptel-permit-judge-backend "stub")
          (gptel-permit-judge-async t)
          (gptel-permit-judge-timeout 60)
          (gptel-permit-rules '((:tool "Bash" :action judge)))
          (gptel-permit-global-rules nil)
          (gptel-permit-veto-functions
           (list #'gptel-permit-analytics--audit-p))
          (accepted nil))
      (with-temp-buffer
        (let* ((spec (gptel--make-tool-internal
                      :name "Bash" :function #'ignore :description "t"))
               (triple (list spec '(:command "ls") (lambda (_))))
               (ov (make-overlay (point-min) (point-min)))
               (prompt-ov (make-overlay (point-min) (point-min))))
          (overlay-put ov 'gptel-tool (list triple))
          (overlay-put ov 'prompt (list prompt-ov))
          (gptel-permit-analytics-test--with-async-judge
            (cl-letf (((symbol-function 'gptel--accept-tool-calls)
                       (lambda (_tc _ov) (setq accepted t))))
              (gptel-permit--apply-rules
               (list :name "Bash" :args '(:command "ls")
                     :buffer (buffer-name)))
              (funcall gptel-permit-analytics-test--async-callback
                       "SAFE\nfine" nil)
              ;; Sampled: the resolution-time veto forced the manual
              ;; resolution — no programmatic accept.
              (should (overlay-buffer ov))
              (should-not accepted)))))
      (let* ((events (gptel-permit-analytics-test--events
                      gptel-permit-analytics-file))
             (types (mapcar (lambda (e)
                              (gptel-permit-analytics-test--field e 'type))
                            events)))
        (should (member "audit" types))
        (should (member "judge-verdict" types))
        (should-not (member "decision" types))))))



(ert-deftest gptel-permit-analytics-defaults-off ()
  "Analytics is disabled until registered."
  (should (null (default-value 'gptel-permit-analytics-enabled))))

(ert-deftest gptel-permit-analytics-off-by-default-is-inert ()
  "Without registration: no file, no advice, no sampling."
  (gptel-permit-analytics-test--with-file
    (let ((gptel-permit-rules '((:tool "Bash" :action allow)))
          (gptel-permit-global-rules nil))
      (cl-letf (((symbol-function 'random)
                 (lambda (_n) (error "random must not be called"))))
        (should (equal (gptel-permit--apply-rules
                        (list :name "Bash" :args '(:command "ls")))
                       '(:confirm nil))))
      (should-not (file-exists-p gptel-permit-analytics-file))
      (should-not (advice-member-p #'gptel-permit-analytics--advice-accept
                                   'gptel--accept-tool-calls))
      (should-not (advice-member-p #'gptel-permit-analytics--advice-reject
                                   'gptel--reject-tool-calls))
      (should-not (advice-member-p #'gptel-permit-analytics--advice-steer
                                   'gptel--steer-tool-calls))
      (should-not gptel-permit-analytics-enabled))))

(ert-deftest gptel-permit-analytics-enabled-without-registration-is-inert ()
  "Setting the defcustom alone does nothing (no defcustom-only path)."
  (gptel-permit-analytics-test--with-file
    (let ((gptel-permit-analytics-enabled t)
          (gptel-permit-analytics-sample-rate 1.0)
          (gptel-permit-rules '((:tool "Bash" :action allow)))
          (gptel-permit-global-rules nil))
      (cl-letf (((symbol-function 'random)
                 (lambda (_n) (error "random must not be called"))))
        (should (equal (gptel-permit--apply-rules
                        (list :name "Bash" :args '(:command "ls")))
                       '(:confirm nil))))
      (should-not (file-exists-p gptel-permit-analytics-file)))))

;; -------------------------------------------------------------------
;; Event chain
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-analytics-asked-call-writes-full-chain ()
  "An asked call writes tool-call, rule-match, verdict, confirm events
sharing one id, with monotonic timestamps."
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t)
    (let ((gptel-permit-rules
           '((:tool "Bash" :conditions ((:command . "ls")) :action ask)))
          (gptel-permit-global-rules nil))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Bash" :args '(:command "ls")))
                     '(:confirm t))))
    (let* ((events (gptel-permit-analytics-test--events
                    gptel-permit-analytics-file))
           (types (mapcar (lambda (e)
                            (gptel-permit-analytics-test--field e 'type))
                          events))
           (ids (cl-delete-duplicates
                 (mapcar (lambda (e)
                           (gptel-permit-analytics-test--field e 'id))
                         events)
                 :test #'equal)))
      (should (equal types '("tool-call" "rule-match" "verdict" "confirm")))
      (should (equal (length ids) 1))
      (should (equal (gptel-permit-analytics-test--field (nth 0 events) 'tool)
                     "Bash"))
      (should (equal (gptel-permit-analytics-test--field (nth 0 events) 'args)
                     '((command . "ls"))))
      (should (eq (gptel-permit-analytics-test--field (nth 2 events) 'confirm)
                  t))
      (let ((tss (mapcar (lambda (e)
                           (gptel-permit-analytics-test--field e 'ts))
                         events)))
        ;; Non-strictly monotonic timestamps: sorting must not change them.
        (should (equal tss (sort (copy-sequence tss) #'string-lessp)))))))

(ert-deftest gptel-permit-analytics-auto-allowed-writes-no-confirm ()
  "An un-sampled auto-allow writes no confirm event."
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t)
    (let ((gptel-permit-rules '((:tool "Bash" :action allow)))
          (gptel-permit-global-rules nil))
      (cl-letf (((symbol-function 'random) (lambda (_n) 99)))
        (should (equal (gptel-permit--apply-rules
                        (list :name "Bash" :args '(:command "ls")))
                       '(:confirm nil))))
      (let ((types (gptel-permit-analytics-test--types
                    gptel-permit-analytics-file)))
        (should (equal types '("tool-call" "rule-match" "verdict")))
        (should-not (member "confirm" types))
        (should-not (member "audit" types))))))

(ert-deftest gptel-permit-analytics-file-created-0600 ()
  "The analytics file is created with 0600 permissions."
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t)
    (let ((gptel-permit-rules '((:tool "Bash" :action ask)))
          (gptel-permit-global-rules nil))
      (gptel-permit--apply-rules (list :name "Bash" :args '(:command "ls"))))
    (should (= (logand (file-modes gptel-permit-analytics-file) #o777)
               #o600))))

(ert-deftest gptel-permit-analytics-ids-are-core-minted-strings ()
  "Ids come from the core as strings, independent of any file seeding;
all events of one call share the id."
  (gptel-permit-analytics-test--with-file
    (with-temp-file gptel-permit-analytics-file
      (insert "{\"id\":3,\"ts\":\"x\",\"type\":\"tool-call\"}\n"))
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t)
    (let ((gptel-permit-rules '((:tool "Bash" :action allow)))
          (gptel-permit-global-rules nil))
      (cl-letf (((symbol-function 'random)
                 (lambda (_n) (error "random must not be called"))))
        (gptel-permit--apply-rules (list :name "Bash" :args '(:command "ls")))))
    ;; The new chain's events carry one fresh string id, distinct from
    ;; any id in the pre-existing file — no seeding, no coordination.
    (let* ((events (gptel-permit-analytics-test--events
                    gptel-permit-analytics-file))
           (new-events (cl-remove-if
                        (lambda (e)
                          (eq (gptel-permit-analytics-test--field e 'id) 3))
                        events))
           (ids (cl-delete-duplicates
                 (mapcar (lambda (e)
                           (gptel-permit-analytics-test--field e 'id))
                         new-events)
                 :test #'equal)))
      (should (= 3 (length new-events)))
      (should (= 1 (length ids)))
      (should (stringp (car ids)))
      (should (string-match-p
               (rx bos (= 8 digit) "T" (= 6 digit) "." (= 3 digit)
                   "." (+ digit) "." (+ digit) eos)
               (car ids))))))

;; -------------------------------------------------------------------
;; Decision capture
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-analytics-decision-allow-with-wait-ms ()
  "Accepting a prompted call records a decision with the wait time."
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t)
    (let ((clock (list 100.0 102.5))
          (gptel-permit-rules '((:tool "Bash" :action ask)))
          (gptel-permit-global-rules nil))
      (cl-letf (((symbol-function 'gptel-permit-analytics--now)
                 (lambda () (pop clock))))
        (should (equal (gptel-permit--apply-rules
                        (list :name "Bash" :args '(:command "ls")))
                       '(:confirm t)))
        (gptel-permit-analytics--advice-accept
         (list (list (gptel-permit-analytics-test--fake-tool "Bash")
                     '(:command "ls") #'ignore))
         nil)))
    (let* ((events (gptel-permit-analytics-test--events
                    gptel-permit-analytics-file))
           (decision (car (last events)))
           (id (gptel-permit-analytics-test--field decision 'id)))
      (should (equal (gptel-permit-analytics-test--field decision 'type)
                     "decision"))
      (should (equal (gptel-permit-analytics-test--field decision 'choice)
                     "allow"))
      (should (equal (gptel-permit-analytics-test--field decision 'wait-ms)
                     2500))
      ;; The decision shares the id with the earlier events of the chain.
      (should (member id (mapcar (lambda (e)
                                   (gptel-permit-analytics-test--field e 'id))
                                 events))))))

(ert-deftest gptel-permit-analytics-decision-cancel-and-steer ()
  "Reject and steer decisions are recorded, cancel non-terminal."
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t)
    (let* ((tool (gptel-permit-analytics-test--fake-tool "Bash"))
           (calls (list (list tool '(:command "ls") #'ignore)))
           (gptel-permit-rules '((:tool "Bash" :action ask)))
           (gptel-permit-global-rules nil))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Bash" :args '(:command "ls")))
                     '(:confirm t)))
      (gptel-permit-analytics--advice-reject calls nil)
      (should (equal (gptel-permit--apply-rules
                      (list :name "Bash" :args '(:command "ls")))
                     '(:confirm t)))
      (gptel-permit-analytics--advice-steer calls nil))
    (let ((decisions (cl-remove-if-not
                      (lambda (e)
                        (equal (gptel-permit-analytics-test--field e 'type)
                               "decision"))
                      (gptel-permit-analytics-test--events
                       gptel-permit-analytics-file))))
      (should (equal (mapcar (lambda (e)
                               (gptel-permit-analytics-test--field e 'choice))
                             decisions)
                     '("cancel" "steer")))
      ;; Decisions share the chain's core-minted string id.
      (should (cl-every #'stringp
                        (mapcar (lambda (e)
                                  (gptel-permit-analytics-test--field e 'id))
                                decisions))))))

(ert-deftest gptel-permit-analytics-decision-through-real-commands ()
  "The installed advice captures decisions through gptel's commands."
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t)
    (gptel-permit-register-analytics-hooks)
    (let ((gptel-permit-rules '((:tool "Bash" :action ask)))
          (gptel-permit-global-rules nil))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Bash" :args '(:command "ls")))
                     '(:confirm t)))
      (gptel--accept-tool-calls
       (list (list (gptel-permit-analytics-test--fake-tool "Bash")
                   '(:command "ls") #'ignore))
       nil))
    (should (member "decision"
                    (gptel-permit-analytics-test--types
                     gptel-permit-analytics-file)))))

(ert-deftest gptel-permit-analytics-decision-inert-when-disabled ()
  "With capture disabled the decision advice records nothing."
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled nil)
    (gptel-permit-analytics--advice-accept
     (list (list (gptel-permit-analytics-test--fake-tool "Bash")
                 '(:command "ls") #'ignore))
     nil)
    (should-not (file-exists-p gptel-permit-analytics-file))))

;; -------------------------------------------------------------------
;; Audit sampling
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-analytics-sampling-upgrades-and-audits ()
  "With rate 1.0 a forced sample upgrades the allow and records audit."
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t
          gptel-permit-analytics-sample-rate 1.0)
    (let ((gptel-permit-rules '((:tool "Bash" :action allow)))
          (gptel-permit-global-rules nil))
      (cl-letf (((symbol-function 'random) (lambda (_n) 0)))
        (should (equal (gptel-permit--apply-rules
                        (list :name "Bash" :args '(:command "ls")))
                       '(:confirm t))))
      (should (equal (gptel-permit-analytics-test--types
                      gptel-permit-analytics-file)
                     '("tool-call" "rule-match" "verdict" "audit"
                       "confirm"))))))

(ert-deftest gptel-permit-analytics-sampling-skips ()
  "A high random draw leaves the auto-allow untouched."
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t
          gptel-permit-analytics-sample-rate 0.2)
    (let ((gptel-permit-rules '((:tool "Bash" :action allow)))
          (gptel-permit-global-rules nil))
      (cl-letf (((symbol-function 'random) (lambda (_n) 99)))
        (should (equal (gptel-permit--apply-rules
                        (list :name "Bash" :args '(:command "ls")))
                       '(:confirm nil))))
      (should-not (member "audit"
                          (gptel-permit-analytics-test--types
                           gptel-permit-analytics-file))))))

(ert-deftest gptel-permit-analytics-never-samples-blocks ()
  "Deny verdicts are never sampled, whatever the sample rate."
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t
          gptel-permit-analytics-sample-rate 1.0)
    (let ((gptel-permit-rules
           '((:tool "Bash" :conditions ((:command . "rm")) :action deny)))
          (gptel-permit-global-rules nil))
      (cl-letf (((symbol-function 'random) (lambda (_n) 0)))
        (should (equal (gptel-permit--apply-rules
                        (list :name "Bash" :args '(:command "rm -rf /")))
                       '(:block "auto-denied"))))
      (let ((types (gptel-permit-analytics-test--types
                    gptel-permit-analytics-file)))
        (should (equal types '("tool-call" "rule-match" "verdict")))
        (should-not (member "audit" types))
        (should-not (member "confirm" types))))))

(ert-deftest gptel-permit-analytics-sampling-keeps-sandbox-args ()
  "A sampled sandbox keeps the args rewrite so a confirmed call still
runs sandboxed."
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t
          gptel-permit-analytics-sample-rate 1.0)
    (let ((gptel-permit-sandbox-backend 'bwrap)
          (gptel-permit-sandbox-command "bwrap")
          (gptel-permit-sandbox-writable-dirs '("/tmp"))
          (gptel-permit-sandbox-network t)
          (gptel-permit-sandbox-env-keep nil)
          (gptel-permit-protected-dirs nil)
          (gptel-permit-sandbox--rc-files nil)
          (gptel-permit--sandbox-fail-streak 0)
          (gptel-permit--sandbox-wrapped-commands nil)
          (gptel-permit-rules '((:tool "Bash" :action sandbox)))
          (gptel-permit-global-rules nil))
      (cl-letf (((symbol-function 'random) (lambda (_n) 0))
                ((symbol-function 'file-exists-p) (lambda (_p) nil))
                ((symbol-function 'executable-find)
                 (lambda (_n) "/usr/bin/bwrap")))
        (let ((result (gptel-permit--apply-rules
                       (list :name "Bash" :args '(:command "make test")))))
          (should (eq (plist-get result :confirm) t))
          (should (string-prefix-p "bwrap"
                                   (plist-get (plist-get result :args)
                                              :command))))))))

;; -------------------------------------------------------------------
;; Register / unregister
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-analytics-register-unregister ()
  "Registration installs advice and the two core hook functions;
unregister removes everything; both are idempotent."
  (gptel-permit-analytics-test--with-file
    (gptel-permit-register-analytics-hooks)
    (gptel-permit-register-analytics-hooks)
    (should gptel-permit-analytics-enabled)
    (should (= 1 (let ((count 0))
                   (advice-mapc
                    (lambda (ad _props)
                      (when (eq ad #'gptel-permit-analytics--advice-accept)
                        (cl-incf count)))
                    'gptel--accept-tool-calls)
                   count)))
    (should (advice-member-p #'gptel-permit-analytics--advice-reject
                             'gptel--reject-tool-calls))
    (should (advice-member-p #'gptel-permit-analytics--advice-steer
                             'gptel--steer-tool-calls))
    ;; The core engine hooks carry the observer and the audit predicate,
    ;; exactly once.
    (should (= 1 (cl-count #'gptel-permit-analytics--observe
                            gptel-permit-events-functions)))
    (should (= 1 (cl-count #'gptel-permit-analytics--audit-p
                           gptel-permit-veto-functions)))
    (gptel-permit-unregister-analytics-hooks)
    (should-not gptel-permit-analytics-enabled)
    (should-not (advice-member-p #'gptel-permit-analytics--advice-accept
                                 'gptel--accept-tool-calls))
    (should-not (advice-member-p #'gptel-permit-analytics--advice-reject
                                 'gptel--reject-tool-calls))
    (should-not (advice-member-p #'gptel-permit-analytics--advice-steer
                                 'gptel--steer-tool-calls))
    (should-not (memq #'gptel-permit-analytics--observe
                      gptel-permit-events-functions))
    (should-not (memq #'gptel-permit-analytics--audit-p
                      gptel-permit-veto-functions))
    ;; Unregistering twice is harmless.
    (gptel-permit-unregister-analytics-hooks)))

;; -------------------------------------------------------------------
;; Judge integration on the verdict event
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-analytics-verdict-includes-judge-fields ()
  "A judged call's verdict event carries judge model, verdict, rationale."
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t)
    (let ((gptel-permit-judge-backend "stub")
          (gptel-permit-judge-model "qwen3")
          (gptel-permit-rules nil)
          (gptel-permit-global-rules
           '((:tool "Bash"
                    :conditions ((:command . gptel-permit-judge-safe-p))
                    :action ask)
             (:tool "Bash" :action ask))))
      (gptel-permit-analytics-test--with-judge-response "SAFE\nconfined"
        (should (equal (gptel-permit--apply-rules
                        (list :name "Bash" :args '(:command "ls")))
                       '(:confirm t))))
      (let* ((events (gptel-permit-analytics-test--events
                      gptel-permit-analytics-file))
             (verdict (cl-find "verdict" events
                               :key (lambda (e)
                                      (gptel-permit-analytics-test--field
                                       e 'type))
                               :test #'equal)))
        (should (equal (gptel-permit-analytics-test--field verdict
                                                          'judge-model)
                       "qwen3"))
        (should (equal (gptel-permit-analytics-test--field verdict
                                                          'judge-verdict)
                       "safe"))
        (should (equal (gptel-permit-analytics-test--field verdict
                                                          'judge-rationale)
                       "confined"))))))

(ert-deftest gptel-permit-analytics-judge-state-reset-per-call ()
  "A stale judge verdict must not leak into another call's event."
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t)
    (let ((gptel-permit-judge-backend "stub")
          (gptel-permit-judge-model "qwen3")
          (gptel-permit-rules nil)
          (gptel-permit-global-rules
           '((:tool "Bash" :conditions ((:command . gptel-permit-judge-safe-p))
                    :action ask)
             (:tool "Read" :action ask))))
      (gptel-permit-analytics-test--with-judge-response "SAFE\nlocal"
        (should (equal (gptel-permit--apply-rules
                        (list :name "Bash" :args '(:command "ls")))
                       '(:confirm t))))
      (should gptel-permit--last-judge-rationale)
      ;; Second call: a different tool; no judge condition is evaluated.
      (gptel-permit--apply-rules (list :name "Read" :args '(:file_path "x.txt")))
      (should-not gptel-permit--last-judge-rationale)
      (let* ((events (gptel-permit-analytics-test--events
                      gptel-permit-analytics-file))
             (verdicts (cl-remove-if-not
                        (lambda (e)
                          (equal (gptel-permit-analytics-test--field e 'type)
                                 "verdict"))
                        events))
             (second (nth 1 verdicts)))
        (should-not (assoc 'judge-rationale second))
        (should-not (assoc 'judge-verdict second))))))

;; -------------------------------------------------------------------
;; Compute and report
;; -------------------------------------------------------------------

(defun gptel-permit-analytics-test--write-fixture (file)
  "Write a deterministic analytics fixture to FILE.
Ten audited Bash calls (2 overridden), two asks, one allow, one
sandbox, one deny and one deferred call.  Events carry only schema
fields; the compute tests rely on period grouping being derived
from `ts'."
  (with-temp-file file
    (cl-flet ((emit (id type tool &rest fields)
                (insert (json-encode
                         `((id . ,id) (ts . "2026-09-14T12:00:00.000+0000")
                           (type . ,type) ,@(when tool `((tool . ,tool)))
                           ,@fields))
                        "\n")))
      (cl-loop for id from 1 to 10 do
               (let ((choice (if (memq id '(3 7)) "cancel" "allow")))
                 (emit id "tool-call" "Bash")
                 (emit id "verdict" "Bash" '(action . "allow"))
                 (emit id "audit" "Bash" '(rate . 0.2))
                 (emit id "confirm" "Bash")
                 (emit id "decision" "Bash" `(choice . ,choice)
                       '(wait-ms . 1000))))
      (emit 11 "tool-call" "Read")
      (emit 11 "verdict" "Read" '(action . "ask") '(confirm . t))
      (emit 11 "confirm" "Read")
      (emit 11 "decision" "Read" '(choice . "allow") '(wait-ms . 500))
      (emit 12 "tool-call" "Read")
      (emit 12 "verdict" "Read" '(action . "ask") '(confirm . t))
      (emit 12 "confirm" "Read")
      (emit 12 "decision" "Read" '(choice . "cancel") '(wait-ms . 1500))
      (emit 13 "tool-call" "Grep")
      (emit 13 "verdict" "Grep" '(action . "allow"))
      (emit 14 "tool-call" "Bash")
      (emit 14 "verdict" "Bash" '(action . "deny") '(block . "auto-denied"))
      (emit 15 "tool-call" "Bash")
      (emit 15 "verdict" "Bash" '(action . "sandbox"))
      (emit 16 "tool-call" "Eval")
      (emit 16 "verdict" "Eval" '(action . "none")))))

;; -------------------------------------------------------------------
;; Scope field on rule-match and verdict events
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-analytics-scope-recorded-on-matched-events ()
  "The rule-match and verdict records carry `scope' with the matched
rule's scope (a string); a no-match call carries no scope field."
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t)
    (let ((gptel-permit-rules nil)
          (gptel-permit-global-rules nil)
          (gptel-permit-rule-scopes
           `((session :reader gptel-permit--read-session-rules
                      :writer gptel-permit--write-session-rule)
             (notebook :reader ,(lambda () '((:tool "Bash" :action ask)))
                       :writer gptel-permit--write-notebook-rule)
             (global :reader gptel-permit--read-global-rules
                     :writer gptel-permit--write-global-rule))))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Bash" :args '(:command "ls")))
                     '(:confirm t))))
    (let* ((events (gptel-permit-analytics-test--events
                    gptel-permit-analytics-file))
           (rm (cl-find "rule-match" events
                        :key (lambda (e)
                               (gptel-permit-analytics-test--field e 'type))
                        :test #'equal))
           (vd (cl-find "verdict" events
                        :key (lambda (e)
                               (gptel-permit-analytics-test--field e 'type))
                        :test #'equal)))
      (should (equal (gptel-permit-analytics-test--field rm 'scope) "notebook"))
      (should (equal (gptel-permit-analytics-test--field vd 'scope) "notebook"))))
  ;; No match: neither event carries scope; verdict action stays "none".
  (gptel-permit-analytics-test--with-file
    (setq gptel-permit-analytics--registered t
          gptel-permit-analytics-enabled t)
    (let ((gptel-permit-rules nil)
          (gptel-permit-global-rules nil)
          (gptel-permit-rule-scopes
           `((session :reader gptel-permit--read-session-rules
                      :writer gptel-permit--write-session-rule)
             (global :reader gptel-permit--read-global-rules
                     :writer gptel-permit--write-global-rule))))
      (should (null (gptel-permit--apply-rules
                     (list :name "Read" :args '(:file_path "x.txt"))))))
    (let* ((events (gptel-permit-analytics-test--events
                    gptel-permit-analytics-file))
           (rm (cl-find "rule-match" events
                        :key (lambda (e)
                               (gptel-permit-analytics-test--field e 'type))
                        :test #'equal))
           (vd (cl-find "verdict" events
                        :key (lambda (e)
                               (gptel-permit-analytics-test--field e 'type))
                        :test #'equal)))
      (should (null (gptel-permit-analytics-test--field rm 'scope)))
      (should (null (gptel-permit-analytics-test--field vd 'scope)))
      (should (equal (gptel-permit-analytics-test--field vd 'action)
                     "none")))))

(ert-deftest gptel-permit-analytics-scope-and-legacy-fold ()
  "Records without a `scope' field (pre-scope logs) fold into outcome
rows with equal semantics, alongside scoped ones; the compute path is
unchanged."
  (let* ((file (gptel-permit-analytics-test--fresh-file))
         (stats (unwind-protect
                    (progn
                      ;; Legacy chain (no scope): audited, cancelled.
                      (gptel-permit-analytics-test--emit-fixture
                       file 1 "tool-call" "Bash")
                      (gptel-permit-analytics-test--emit-fixture
                       file 1 "rule-match" "Bash" '(action . "allow"))
                      (gptel-permit-analytics-test--emit-fixture
                       file 1 "verdict" "Bash" '(action . "allow"))
                      (gptel-permit-analytics-test--emit-fixture
                       file 1 "audit" "Bash" '(rate . 0.2))
                      (gptel-permit-analytics-test--emit-fixture
                       file 1 "confirm" "Bash")
                      (gptel-permit-analytics-test--emit-fixture
                       file 1 "decision" "Bash"
                       '(choice . "cancel") '(wait-ms . 100))
                      ;; Scoped chain: notebook allow.
                      (gptel-permit-analytics-test--emit-fixture
                       file 2 "tool-call" "Read")
                      (gptel-permit-analytics-test--emit-fixture
                       file 2 "rule-match" "Read"
                       '(action . "allow") '(scope . "notebook"))
                      (gptel-permit-analytics-test--emit-fixture
                       file 2 "verdict" "Read"
                       '(action . "allow") '(scope . "notebook"))
                      (gptel-permit-analytics-compute file))
                  (delete-file file))))
    (should (= (plist-get stats :total-calls) 2))
    (should (= (plist-get stats :auto-allowed) 1))
    (should (= (plist-get stats :asked) 1))
    (should (= (plist-get stats :blocked) 0))
    (should (= (plist-get (plist-get stats :false-allow) :audited) 1))
    (should (= (plist-get (plist-get stats :false-allow) :overridden) 1))))

(ert-deftest gptel-permit-analytics-compute-fixture ()
  "Compute derives totals, per-tool rows and the Wilson interval."
  (let* ((file (gptel-permit-analytics-test--fresh-file))
         (stats (unwind-protect
                    (progn
                      (gptel-permit-analytics-test--write-fixture file)
                      (gptel-permit-analytics-compute file))
                  (delete-file file)))
         (false-allow (plist-get stats :false-allow))
         (ci (plist-get false-allow :ci))
         (bash (cdr (assoc "Bash" (plist-get stats :per-tool) #'equal)))
         (grep (cdr (assoc "Grep" (plist-get stats :per-tool) #'equal)))
         (daily (cdr (assoc "2026-09-14" (plist-get stats :daily) #'equal))))
    (should (= (plist-get stats :total-calls) 16))
    (should (= (plist-get stats :auto-allowed) 2))
    (should (= (plist-get stats :asked) 12))
    (should (= (plist-get stats :blocked) 1))
    (should (= (plist-get stats :deferred) 1))
    (should (= (plist-get false-allow :audited) 10))
    (should (= (plist-get false-allow :overridden) 2))
    (should (= (plist-get false-allow :rate) 0.2))
    (should ci)
    (should (< (car ci) 0.2 (cadr ci)))
    (should (< (abs (- (car ci) 0.0567)) 1e-3))
    (should (< (abs (- (cadr ci) 0.5098)) 1e-3))
    (should (= (plist-get bash :calls) 12))
    (should (= (plist-get bash :asked) 10))
    (should (< (abs (- (plist-get bash :ask-rate) (/ 10.0 12))) 1e-12))
    (should (= (plist-get bash :avg-wait-ms) 1000))
    (should (= (plist-get grep :ask-rate) 0.0))
    (should-not (plist-get grep :avg-wait-ms))
    (should (= (plist-get daily :calls) 16))
    (should (= (plist-get daily :asked) 12))
    (should (= (plist-get daily :blocked) 1))))

(ert-deftest gptel-permit-analytics-compute-missing-file ()
  "A missing file yields empty statistics instead of an error."
  (let ((stats (gptel-permit-analytics-compute
                (gptel-permit-analytics-test--fresh-file))))
    (should (= (plist-get stats :total-calls) 0))
    (should (= (plist-get stats :asked) 0))
    (should (= (plist-get (plist-get stats :false-allow) :audited) 0))))

(defun gptel-permit-analytics-test--emit-fixture (file id type tool &rest fields)
  "Append one JSON fixture line to FILE with ID, TYPE, TOOL and FIELDS."
  (with-temp-buffer
    (insert (json-encode
             `((id . ,id) (ts . "2026-09-14T12:00:00.000+0000")
               (type . ,type) (tool . ,tool) ,@fields))
            "\n")
    (append-to-file (point-min) (point-max) file)))

(ert-deftest gptel-permit-analytics-compute-mixed-legacy-and-string-ids ()
  "A log containing integer-id (legacy) and string-id (new) chains
folds every chain into one outcome row, both shapes counted the same."
  (let* ((file (gptel-permit-analytics-test--fresh-file))
         (stats (unwind-protect
                    (progn
                      ;; Legacy chain with an integer id: audited allow,
                      ;; cancelled by the user.
                      (gptel-permit-analytics-test--emit-fixture
                       file 1 "tool-call" "Bash")
                      (gptel-permit-analytics-test--emit-fixture
                       file 1 "verdict" "Bash" '(action . "allow"))
                      (gptel-permit-analytics-test--emit-fixture
                       file 1 "audit" "Bash" '(rate . 0.2))
                      (gptel-permit-analytics-test--emit-fixture
                       file 1 "confirm" "Bash")
                      (gptel-permit-analytics-test--emit-fixture
                       file 1 "decision" "Bash"
                       '(choice . "cancel") '(wait-ms . 100))
                      ;; New chain with a string id: un-sampled allow.
                      (gptel-permit-analytics-test--emit-fixture
                       file "20260914T120000.000.123.5" "tool-call" "Bash")
                      (gptel-permit-analytics-test--emit-fixture
                       file "20260914T120000.000.123.5" "verdict" "Bash"
                       '(action . "allow"))
                      (gptel-permit-analytics-compute file))
                  (delete-file file))))
    (should (= (plist-get stats :total-calls) 2))
    (should (= (plist-get stats :auto-allowed) 1))
    (should (= (plist-get stats :asked) 1))
    (should (= (plist-get stats :blocked) 0))
    (should (= (plist-get (plist-get stats :false-allow) :audited) 1))
    (should (= (plist-get (plist-get stats :false-allow) :overridden) 1))))


(ert-deftest gptel-permit-analytics-report-renders-buffer ()
  "The report renders the computed statistics into a buffer."
  (unwind-protect
      (gptel-permit-analytics-test--with-file
        (gptel-permit-analytics-report gptel-permit-analytics-file)
        (with-current-buffer "*gptel-permit-analytics*"
          (let ((text (buffer-substring-no-properties
                       (point-min) (point-max))))
            (should (string-match-p "Calls: 0" text))
            (should (string-match-p "False-allow audit" text)))))
    (when (get-buffer "*gptel-permit-analytics*")
      (kill-buffer "*gptel-permit-analytics*"))))

(provide 'gptel-permit-analytics-test)
;;; gptel-permit-analytics-test.el ends here
