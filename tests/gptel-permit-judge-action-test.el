;;; gptel-permit-judge-action-test.el --- Tests for judge action -*- lexical-binding: t; -*-
;;
;; Cross-module integration suite: requires core + judge + sandbox.
;; The `(judge sandbox ...)' on-unsafe fallback tests stub sandbox
;; internals because the two packages are installed separately; users
;; of judge alone never load this file's fixtures.

(require 'ert)
(require 'gptel-permit)
(require 'gptel-permit-judge)
(require 'gptel-permit-sandbox)

(defvar gptel-permit-judge-test--async-callback nil)

(defmacro gptel-permit-judge-test--with-async (&rest body)
  `(let ((gptel-permit-judge-test--async-callback nil))
     (cl-letf (((symbol-function 'gptel-request)
                (lambda (_prompt &rest keys)
                  (setq gptel-permit-judge-test--async-callback
                        (plist-get keys :callback))
                  nil))
               ((symbol-function 'gptel-get-backend)
                (lambda (_name) 'fake-judge-backend)))
       ,@body)))

(defun gptel-permit-judge-test--deliver-async (response)
  (when gptel-permit-judge-test--async-callback
    (funcall gptel-permit-judge-test--async-callback response nil)))

(defun gptel-permit-judge-test--make-overlay (tool-calls)
  (let* ((ov (make-overlay (point-min) (point-min)))
         (prompt-ov (make-overlay (point-min) (point-min))))
    (overlay-put ov 'gptel-tool tool-calls)
    (overlay-put ov 'prompt (list prompt-ov))
    ov))

(defun gptel-permit-judge-test--tool-triple (name args callback)
  "Return a pending-call triple (TOOL-SPEC ARGS CALLBACK) for tests.
TOOL-SPEC is a real minimal gptel tool struct, like the triples gptel
stores on the dispatch overlay's `gptel-tool' property."
  (list (gptel--make-tool-internal :name name :function #'ignore
                                   :description "test tool")
        args callback))

(ert-deftest gptel-permit-judge-action-grammar-defaults ()
  "Bare `judge' defaults to (allow ask); `(judge A)' defaults to (A ask)."
  (let ((gptel-permit-judge-backend nil)
        (gptel-permit-judge-async nil))
    (should (equal (gptel-permit--action-judge "id" (list :name "Bash"))
                   '(:confirm t)))))

(ert-deftest gptel-permit-judge-action-verdict-mapping ()
  "SAFE/UNSAFE map to the configured actions; failure maps to ask."
  (let ((id "id")
        (tc (list :name "Bash" :args '(:command "ls"))))
    (should (equal (gptel-permit--judge-action-verdict id tc 'safe 'allow 'deny)
                   '(:confirm nil)))
    (let ((gptel-permit--last-judge-rationale "touches /etc"))
      (should (equal (gptel-permit--judge-action-verdict id tc 'unsafe 'allow 'deny)
                     '(:block "Judge rejected: touches /etc"))))
    (should (equal (gptel-permit--judge-action-verdict id tc 'timeout 'allow 'deny)
                   '(:confirm t)))))

(ert-deftest gptel-permit-judge-action-sync-safe-allow ()
  "Sync judge action: SAFE -> allow."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async nil)
        (response "SAFE\nok"))
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest keys)
                 (when-let* ((cb (plist-get keys :callback)))
                   (funcall cb response nil))
                 nil))
              ((symbol-function 'gptel-get-backend)
               (lambda (_name) 'fake-judge-backend)))
      (should (equal (gptel-permit--action-judge
                      "id" (list :name "Bash" :args '(:command "ls")))
                     '(:confirm nil))))))

(ert-deftest gptel-permit-judge-action-sync-unsafe-deny ()
  "Sync judge action: UNSAFE -> deny with rationale."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async nil)
        (response "UNSAFE\ntouches /etc"))
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest keys)
                 (when-let* ((cb (plist-get keys :callback)))
                   (funcall cb response nil))
                 nil))
              ((symbol-function 'gptel-get-backend)
               (lambda (_name) 'fake-judge-backend)))
      (should (equal (gptel-permit--action-judge
                      "id"
                      (list :name "Bash" :args '(:command "rm -rf /etc"))
                      '(allow deny))
                     '(:block "Judge rejected: touches /etc"))))))

(ert-deftest gptel-permit-judge-action-malformed-form-fails-closed ()
  "A malformed judge form warns and behaves as ask."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async nil))
    (should (equal (gptel-permit--action-judge
                    "id" (list :name "Bash" :args '(:command "ls"))
                    '(allow deny extra))
                   '(:confirm t)))
    (should (equal (gptel-permit--action-judge
                    "id" (list :name "Bash" :args '(:command "ls"))
                    '(allow frobnicate))
                   '(:confirm t)))))

(ert-deftest gptel-permit-judge-sync-reasoning-then-verdict ()
  "Sync mode: an intermediate (reasoning . TEXT) delivery does not end
the wait; the final string resolves."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async nil)
        (deliveries '((reasoning . "hmm") "SAFE\nfine")))
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest keys)
                 (dolist (d deliveries)
                   (funcall (plist-get keys :callback) d nil))
                 nil))
              ((symbol-function 'gptel-get-backend)
               (lambda (_name) 'fake-judge-backend)))
      (should (equal (gptel-permit--action-judge
                      "id" (list :name "Bash" :args '(:command "ls")))
                     '(:confirm nil))))))

(ert-deftest gptel-permit-judge-sync-reasoning-then-failure ()
  "Sync mode: a terminal nil delivery after an intermediate reasoning
cons records request-fail (the empty-success t delivery likewise)."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async nil)
        ;; A short timeout: the reasoning-only iteration ends the wait
        ;; at the deadline, exercising the timeout path without delay.
        (gptel-permit-judge-timeout 0)
        (deliveries (list (list '(reasoning . "hmm")
                                (list :status "HTTP/1.1 500 Server Error"))
                          (list '(reasoning . "hmm") t))))
    (pcase-dolist (`(,response ,info) deliveries)
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (_prompt &rest keys)
                   (funcall (plist-get keys :callback) response info)
                   nil))
                ((symbol-function 'gptel-get-backend)
                 (lambda (_name) 'fake-judge-backend)))
        (should (equal (gptel-permit--action-judge
                        "id" (list :name "Bash" :args '(:command "ls")))
                       '(:confirm t)))))))

(ert-deftest gptel-permit-judge-action-sync-sandbox-safe-wraps ()
  "Sync (judge sandbox deny): SAFE returns the sandbox args rewrite."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async nil)
        (response "SAFE\nok"))
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest keys)
                 (when-let* ((cb (plist-get keys :callback)))
                   (funcall cb response nil))
                 nil))
              ((symbol-function 'gptel-get-backend)
               (lambda (_name) 'fake-judge-backend))
              ((symbol-function 'gptel-permit-sandbox--backend-available-p)
               (lambda () t))
              ((symbol-function 'gptel-permit-sandbox--resolve-binary)
               (lambda (_name) "/bin/true")))
      (let ((verd (gptel-permit--action-judge
                   "id" (list :name "Bash" :args '(:command "ls"))
                   '(sandbox deny))))
        (should (null (plist-get verd :confirm)))
        (should (string-match-p "bwrap"
                                (plist-get (plist-get verd :args) :command)))))))

(ert-deftest gptel-permit-judge-action-no-fall-through ()
  "A matched judge rule owns the call: UNSAFE -> ask never reaches a
later allow rule."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async nil)
        (response "UNSAFE\ntouches /etc")
        (gptel-permit-rules '((:tool "Bash" :action judge)
                              (:tool "Bash" :action allow)))
        (gptel-permit-global-rules nil))
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest keys)
                 (when-let* ((cb (plist-get keys :callback)))
                   (funcall cb response nil))
                 nil))
              ((symbol-function 'gptel-get-backend)
               (lambda (_name) 'fake-judge-backend)))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Bash" :args '(:command "rm -rf /")))
                     '(:confirm t))))))


(ert-deftest gptel-permit-judge-action-async-returns-confirm ()
  "Async judge action returns `(:confirm t)' and stashes the call."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        (gptel-permit-judge-timeout 60)
        (tc (list :name "Bash" :args '(:command "ls"))))
    (with-temp-buffer
      (gptel-permit-judge-test--with-async
       (should (equal (gptel-permit--action-judge "id" tc)
                      '(:confirm t)))
       (should gptel-permit-judge-test--async-callback)
       (should (assoc (cons "Bash" '(:command "ls"))
                      gptel-permit--judge-pending #'equal))))))

(ert-deftest gptel-permit-judge-async-safe-auto-accept ()
  "Async SAFE verdict auto-accepts a uniform pack."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        (gptel-permit-judge-timeout 60)
        (accepted nil)
        (tc (list :name "Bash" :args '(:command "ls"))))
    (with-temp-buffer
      (let ((ov (gptel-permit-judge-test--make-overlay
                 (list (gptel-permit-judge-test--tool-triple "Bash" '(:command "ls") (lambda (_)))))))
        (gptel-permit-judge-test--with-async
         (cl-letf (((symbol-function 'gptel--accept-tool-calls)
                    (lambda (tool-calls _ov)
                      (setq accepted tool-calls))))
           (gptel-permit--action-judge "id" tc)
           (gptel-permit-judge-test--deliver-async "SAFE\nok")
           (should accepted)
           (should (= (length accepted) 1))
           (should (equal (mapcar #'cadr accepted)
                          (list '(:command "ls"))))))))))

(ert-deftest gptel-permit-judge-async-unsafe-ask-leaves-prompt ()
  "Async UNSAFE -> ask leaves the prompt in place."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        (gptel-permit-judge-timeout 60)
        (accepted nil)
        (tc (list :name "Bash" :args '(:command "rm -rf /"))))
    (with-temp-buffer
      (let ((ov (gptel-permit-judge-test--make-overlay
                 (list (gptel-permit-judge-test--tool-triple "Bash" '(:command "rm -rf /") (lambda (_)))))))
        (gptel-permit-judge-test--with-async
         (cl-letf (((symbol-function 'gptel--accept-tool-calls)
                    (lambda (_tc _ov) (setq accepted t))))
           (gptel-permit--action-judge "id" tc '(allow ask))
           (gptel-permit-judge-test--deliver-async "UNSAFE\ntouches /etc")
           (should (overlay-buffer ov))
           (should-not accepted)))))))

(ert-deftest gptel-permit-judge-async-unsafe-deny-rejects ()
  "Async UNSAFE -> deny rejects the pack with rationale."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        (gptel-permit-judge-timeout 60)
        (rejected nil)
        (tc (list :name "Bash" :args '(:command "rm -rf /"))))
    (with-temp-buffer
      (let ((ov (gptel-permit-judge-test--make-overlay
                 (list (gptel-permit-judge-test--tool-triple "Bash" '(:command "rm -rf /")
                                                             (lambda (r) (setq rejected r)))))))
        (gptel-permit-judge-test--with-async
         (gptel-permit--action-judge "id" tc '(allow deny))
         (gptel-permit-judge-test--deliver-async "UNSAFE\ntouches /etc")
         (should (string-match-p "touches /etc" rejected))
         (should-not (overlay-buffer ov)))))))

(ert-deftest gptel-permit-judge-async-timeout-leaves-prompt ()
  "Async timeout leaves the prompt and discards late responses."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        (gptel-permit-judge-timeout 0)
        (accepted nil)
        (tc (list :name "Bash" :args '(:command "ls"))))
    (with-temp-buffer
      (let ((ov (gptel-permit-judge-test--make-overlay
                 (list (gptel-permit-judge-test--tool-triple "Bash" '(:command "ls") (lambda (_)))))))
        (gptel-permit-judge-test--with-async
         (cl-letf (((symbol-function 'gptel--accept-tool-calls)
                    (lambda (_tc _ov) (setq accepted t))))
           (gptel-permit--action-judge "id" tc)
           (sleep-for 0.1)
           (should (overlay-buffer ov))
           (gptel-permit-judge-test--deliver-async "SAFE\nok")
           (should (overlay-buffer ov))
           (should-not accepted)))))))

(ert-deftest gptel-permit-judge-async-user-race-noop ()
  "A manual accept before the callback makes the callback a no-op."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        (gptel-permit-judge-timeout 60)
        (accepted nil)
        (tc (list :name "Bash" :args '(:command "ls"))))
    (with-temp-buffer
      (let ((ov (gptel-permit-judge-test--make-overlay
                 (list (gptel-permit-judge-test--tool-triple "Bash" '(:command "ls") (lambda (_)))))))
        (gptel-permit-judge-test--with-async
         (gptel-permit--action-judge "id" tc)
         (delete-overlay ov)
         (gptel-permit-judge-test--deliver-async "SAFE\nok")
         (should-not accepted))))))

(ert-deftest gptel-permit-judge-async-mixed-pack-no-auto ()
  "A mixed-resolution pack is never auto-resolved."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        (gptel-permit-judge-timeout 60)
        (accepted nil)
        (rejected nil)
        (tc1 (list :name "Bash" :args '(:command "ls")))
        (tc2 (list :name "Bash" :args '(:command "rm -rf /"))))
    (with-temp-buffer
      (let ((ov (gptel-permit-judge-test--make-overlay
                 (list (gptel-permit-judge-test--tool-triple "Bash" '(:command "ls") (lambda (_)))
                       (gptel-permit-judge-test--tool-triple "Bash" '(:command "rm -rf /")
                                                             (lambda (r) (setq rejected r)))))))
        (gptel-permit-judge-test--with-async
         (cl-letf (((symbol-function 'gptel--accept-tool-calls)
                    (lambda (_tc _ov) (setq accepted t))))
           (gptel-permit--action-judge "id1" tc1 '(allow deny))
           (gptel-permit--action-judge "id2" tc2 '(allow deny))
           (gptel-permit-judge-test--deliver-async "SAFE\nok")
           (should (overlay-buffer ov))
           (should-not accepted)
           (should-not rejected)
           (gptel-permit-judge-test--deliver-async "UNSAFE\ntouches /etc")
           (should (overlay-buffer ov))
           (should-not accepted)
           (should-not rejected)))))))

(ert-deftest gptel-permit-judge-async-indicator-lifecycle ()
  "Judging indicator appears while pending and is removed on resolution."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        (gptel-permit-judge-timeout 60)
        (tc (list :name "Bash" :args '(:command "ls"))))
    (with-temp-buffer
      (let ((ov (gptel-permit-judge-test--make-overlay
                 (list (gptel-permit-judge-test--tool-triple "Bash" '(:command "ls") (lambda (_)))))))
        (gptel-permit-judge-test--with-async
         (gptel-permit--action-judge "id" tc)
         ;; The indicator is attached by a (run-at-time 0) timer, once the
         ;; prompt overlay exists — let the timer fire.
         (sleep-for 0.01)
         (let ((ind (cl-find-if (lambda (o)
                                  (overlay-get o 'gptel-permit-judge-indicator))
                                (overlays-in (point-min) (point-max)))))
           (should ind))
         (gptel-permit-judge-test--deliver-async "SAFE\nok")
         (let ((ind (cl-find-if (lambda (o)
                                  (overlay-get o 'gptel-permit-judge-indicator))
                                (overlays-in (point-min) (point-max)))))
           (should-not ind)))))))

(ert-deftest gptel-permit-judge-action-inspects-all-args ()
  "The judge action prompt contains all args, not a single :checked-arg."
  (let ((prompt (gptel-permit--judge-build-prompt
                 (gptel-permit--judge-format-args
                  (list :name "Bash" :args '(:command "ls" :path "/tmp")))
                 (list :name "Bash" :args '(:command "ls" :path "/tmp")))))
    (should (string-match-p "Args:" prompt))
    (should (string-match-p ":command ls" prompt))
    (should (string-match-p ":path /tmp" prompt))
    (should-not (string-match-p "Key:" prompt))))

(ert-deftest gptel-permit-judge-async-sandbox-safe-wraps ()
  "Async SAFE -> sandbox rewrites args through the sandbox handler."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        (gptel-permit-judge-timeout 60)
        (accepted nil)
        (tc (list :name "Bash" :args '(:command "ls"))))
    (with-temp-buffer
      (let ((ov (gptel-permit-judge-test--make-overlay
                 (list (gptel-permit-judge-test--tool-triple "Bash" '(:command "ls") (lambda (_)))))))
        (gptel-permit-judge-test--with-async
         (cl-letf (((symbol-function 'gptel--accept-tool-calls)
                    (lambda (tool-calls _ov)
                      (setq accepted tool-calls))))
           (cl-letf (((symbol-function 'gptel-permit-sandbox--backend-available-p)
                      (lambda () t))
                     ((symbol-function 'gptel-permit-sandbox--resolve-binary)
                      (lambda (_name) "/bin/true")))
             (gptel-permit--action-judge "id" tc '(sandbox deny))
             (gptel-permit-judge-test--deliver-async "SAFE\nok")
             (should accepted)
             (let ((args (cadr (car accepted))))
               (should (plist-get args :command))
               (should (string-match-p "bwrap" (plist-get args :command)))))))))))

(ert-deftest gptel-permit-judge-async-unsafe-sandbox-wraps ()
  "Async (judge allow sandbox): UNSAFE verdicts select the confinement,
not a rejection — the pack is accepted with rewritten args."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        (gptel-permit-judge-timeout 60)
        (accepted nil)
        (tc (list :name "Bash" :args '(:command "rm -rf /tmp/x"))))
    (with-temp-buffer
      (let ((ov (gptel-permit-judge-test--make-overlay
                 (list (gptel-permit-judge-test--tool-triple
                        "Bash" '(:command "rm -rf /tmp/x") (lambda (_)))))))
        (gptel-permit-judge-test--with-async
         (cl-letf (((symbol-function 'gptel--accept-tool-calls)
                    (lambda (tool-calls _ov)
                      (setq accepted tool-calls))))
           (cl-letf (((symbol-function 'gptel-permit-sandbox--backend-available-p)
                      (lambda () t))
                     ((symbol-function 'gptel-permit-sandbox--resolve-binary)
                      (lambda (_name) "/bin/true")))
             (gptel-permit--action-judge "id" tc '(allow sandbox))
             (gptel-permit-judge-test--deliver-async "UNSAFE\ntouches /etc")
             (should accepted)
             (let ((args (cadr (car accepted))))
               (should (string-match-p "bwrap" (plist-get args :command)))))))))))

(ert-deftest gptel-permit-judge-async-reasoning-then-verdict-resolves ()
  "gptel may deliver a (reasoning . TEXT) cons before the final string;
the intermediate delivery is ignored and the string resolves the call."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        (gptel-permit-judge-timeout 60)
        (accepted nil)
        (tc (list :name "Bash" :args '(:command "ls"))))
    (with-temp-buffer
      (let ((ov (gptel-permit-judge-test--make-overlay
                 (list (gptel-permit-judge-test--tool-triple
                        "Bash" '(:command "ls") (lambda (_)))))))
        (gptel-permit-judge-test--with-async
         (cl-letf (((symbol-function 'gptel--accept-tool-calls)
                    (lambda (_tc _ov) (setq accepted t))))
           (gptel-permit--action-judge "id" tc)
           (funcall gptel-permit-judge-test--async-callback
                    '(reasoning . "looks harmless to me") nil)
           ;; Intermediate delivery: nothing resolved, entry still in
           ;; flight.
           (should-not accepted)
           (should-not (plist-get (cdr (assoc (cons "Bash" '(:command "ls"))
                                              gptel-permit--judge-pending
                                              (lambda (a b) (equal a b))))
                                  :resolved))
           (funcall gptel-permit-judge-test--async-callback "SAFE\nfine" nil)
           (should accepted)))))))

(ert-deftest gptel-permit-judge-async-reasoning-then-failure-asks ()
  "A terminal failure delivery (nil) after an intermediate reasoning
cons resolves to the manual confirmation."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        (gptel-permit-judge-timeout 60)
        (accepted nil)
        (tc (list :name "Bash" :args '(:command "ls"))))
    (with-temp-buffer
      (let ((ov (gptel-permit-judge-test--make-overlay
                 (list (gptel-permit-judge-test--tool-triple
                        "Bash" '(:command "ls") (lambda (_)))))))
        (gptel-permit-judge-test--with-async
         (cl-letf (((symbol-function 'gptel--accept-tool-calls)
                    (lambda (_tc _ov) (setq accepted t))))
           (gptel-permit--action-judge "id" tc)
           (funcall gptel-permit-judge-test--async-callback
                    '(reasoning . "hmm") nil)
           (funcall gptel-permit-judge-test--async-callback nil
                    (list :status "HTTP/1.1 500 Server Error"))
           (should (overlay-buffer ov))
           (should-not accepted)
           ;; A third delivery (whatever it is) is discarded as resolved.
           (funcall gptel-permit-judge-test--async-callback "SAFE\nfine" nil)
           (should (overlay-buffer ov))
           (should-not accepted)))))))

(ert-deftest gptel-permit-judge-async-indicator-removed-by-user-teardown ()
  "The judging indicator is removed when gptel runs the preview
teardown handles (the user's manual accept / steer / reject path)."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        (gptel-permit-judge-timeout 60)
        (tc (list :name "Bash" :args '(:command "ls"))))
    (with-temp-buffer
      (let ((ov (gptel-permit-judge-test--make-overlay
                 (list (gptel-permit-judge-test--tool-triple
                        "Bash" '(:command "ls") (lambda (_)))))))
        (gptel-permit-judge-test--with-async
         (gptel-permit--action-judge "id" tc)
         (sleep-for 0.01)
         (should (cl-find-if (lambda (o)
                               (overlay-get o 'gptel-permit-judge-indicator))
                             (overlays-in (point-min) (point-max))))
         ;; Mirror gptel's cleanup: run the preview teardown handles,
         ;; exactly as gptel--accept-tool-calls does.
         (dolist (handle (overlay-get ov 'previews))
           (when (car handle) (apply handle)))
         (should-not (cl-find-if (lambda (o)
                                   (overlay-get o 'gptel-permit-judge-indicator))
                                 (overlays-in (point-min) (point-max)))))))))



(ert-deftest gptel-permit-judge-async-audit-sampling-suppresses ()
  "Audit sampling at resolution time forces manual confirmation."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        (gptel-permit-judge-timeout 60)
        (accepted nil)
        (veto-called nil)
        (tc (list :name "Bash" :args '(:command "ls"))))
    (with-temp-buffer
      (let ((ov (gptel-permit-judge-test--make-overlay
                 (list (gptel-permit-judge-test--tool-triple "Bash" '(:command "ls") (lambda (_)))))))
        (gptel-permit-judge-test--with-async
         (cl-letf (((symbol-function 'gptel--accept-tool-calls)
                    (lambda (_tc _ov) (setq accepted t)))
                   (gptel-permit-veto-functions
                    (list (lambda (_id _tc verdict)
                            (setq veto-called t)
                            (and (plist-member verdict :confirm)
                                 (null (plist-get verdict :confirm)))))))
           (gptel-permit--action-judge "id" tc)
           (gptel-permit-judge-test--deliver-async "SAFE\nok")
           (should veto-called)
           (should (overlay-buffer ov))
           (should-not accepted)))))))

(provide 'gptel-permit-judge-action-test)
;;; gptel-permit-judge-action-test.el ends here
(ert-deftest gptel-permit-judge-async-mixed-pack-status-line ()
  "A judged call in a mixed pack stays visible: the pack's status
indicator shows its verdict and names the manual confirm, no accept
happens, and the prompt survives."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t)
        accepted)
    (gptel-permit-judge-test--with-async
     (with-temp-buffer
       (let* ((ov (gptel-permit-judge-test--make-overlay
                   (list (gptel-permit-judge-test--tool-triple
                          "Bash" '(:command "df") (lambda (_r) (setq accepted t)))
                         (gptel-permit-judge-test--tool-triple
                          "Glob" '(:path "/tmp") (lambda (_r) (setq accepted t))))))
              (tc (list :name "Bash" :args '(:command "df"))))
         (gptel-permit--action-judge "id" tc)
         (gptel-permit-judge-test--deliver-async "SAFE\nok")
         (let ((ind (cl-find-if (lambda (o)
                                  (overlay-get o 'gptel-permit-judge-indicator))
                                (overlays-in (point-min) (point-max)))))
           (should ind)
           (should (string-match-p "Bash ✅" (overlay-get ind 'before-string)))
           (should (string-match-p "manual confirm"
                                   (overlay-get ind 'before-string))))
         ;; The pack was not accepted: the sibling call needs a human.
         (should (overlay-buffer ov))
         (should-not accepted))))))

(ert-deftest gptel-permit-judge-async-timeout-status-line ()
  "A watchdog timeout shows in the pack's status indicator, and the
prompt stays."
  (let ((gptel-permit-judge-backend "stub")
        (gptel-permit-judge-async t))
    (gptel-permit-judge-test--with-async
     (with-temp-buffer
       (let* ((ov (gptel-permit-judge-test--make-overlay
                   (list (gptel-permit-judge-test--tool-triple
                          "Bash" '(:command "df") (lambda (_r) nil)))))
              (tc (list :name "Bash" :args '(:command "df"))))
         (gptel-permit--action-judge "id" tc)
         (gptel-permit--judge-watchdog
          (current-buffer) (cons "Bash" '(:command "df")))
         (let ((ind (cl-find-if
                     (lambda (o)
                       (overlay-get o 'gptel-permit-judge-indicator))
                     (overlays-in (point-min) (point-max)))))
           (should ind)
           (should (string-match-p "Bash ⚠"
                                   (overlay-get ind 'before-string)))))))))

(provide 'gptel-permit-judge-action-test)
;;; gptel-permit-judge-action-test.el ends here
