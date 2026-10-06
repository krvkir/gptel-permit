;;; gptel-permit-analytics.el --- Local decision analytics for gptel-permit -*- lexical-binding: t; -*-

;; Copyright (C) 2026 krvkir

;; Author: krvkir <krvkir@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9") (gptel-permit "0.1.0"))
;; Keywords: convenience, tools, agents, security
;; URL: https://github.com/krvkir/gptel-permit

;; This file is NOT part of GNU Emacs.

;;; Commentary:
;; Opt-in, local-only analytics for gptel-permit: an append-only JSONL log
;; of the complete tool-call decision chain (tool-call, rule-match, verdict
;; including judge verdict and rationale, confirm shown, user decision with
;; wait time, audit marker), audit sampling that up-ranks a configurable
;; fraction of automation-allowed calls to a human confirmation, and
;; reporting over that log.
;;
;; Data never leaves the machine — hence "analytics", not telemetry.  The
;; module is inert until `gptel-permit-register-analytics-hooks' is called
;; (intended for a `use-package' :config section); the effect can be undone
;; by `gptel-permit-unregister-analytics-hooks'.  Statistics are split into
;; the pure calculator `gptel-permit-analytics-compute' and the interactive
;; renderer `gptel-permit-analytics-report'.

;;; Code:

(require 'cl-lib)
(require 'iso8601)
(require 'json)
(require 'gptel)
(require 'gptel-permit)

(defgroup gptel-permit-analytics nil
  "Local decision analytics for gptel-permit."
  :group 'gptel-permit
  :prefix "gptel-permit-analytics-"
  :package-version '("gptel-permit-analytics" . "0.1.0"))

(defcustom gptel-permit-analytics-enabled nil
  "When non-nil, gptel-permit analytics event capture is active.
Setting this variable alone does nothing: capture also requires a call
to `gptel-permit-register-analytics-hooks', which installs the decision
advice and sets this variable to t.  Setting it to nil suspends capture
without uninstalling the advice."
  :type 'boolean
  :group 'gptel-permit-analytics)

(defcustom gptel-permit-analytics-file
  (expand-file-name "gptel-permit-analytics.jsonl" user-emacs-directory)
  "JSONL file receiving gptel-permit analytics events.
One JSON object per line, created with 0600 permissions.  The file
records tool names, truncated argument values and your decisions —
keep it local."
  :type 'file
  :group 'gptel-permit-analytics)

(defcustom gptel-permit-analytics-sample-rate 0.2
  "Fraction of automation-allowed calls audited by forced confirmation.
While analytics is active, this fraction of auto-allowed calls (rule
allow or successful sandbox) is randomly upgraded to a manual prompt;
the user's decision measures the false-allow rate.  Deny verdicts are
never sampled.  Only active while analytics is registered and enabled."
  :type 'number
  :group 'gptel-permit-analytics)

;; Judge state variables, defined in `gptel-permit-judge' and consulted
;; when that package is loaded.  Declarations only, for the compiler.
(defvar gptel-permit-judge-model)
(defvar gptel-permit--last-judge-rationale)
(defvar gptel-permit--last-judge-verdict)

;; The sandbox's sandboxed-acceptance binding (alist of rewritten args
;; → original args), defined in `gptel-permit-sandbox' and read on the
;; accept-time pop path above.  Declaration only, for the compiler.
;; ABI declare: in an analytics-without-sandbox install the variable
;; exists with value nil — the symbol is part of the cross-module
;; dynamic-scope contract, this `defvar' merely documents it, and nil
;; reads as "no rewrite happened".
(defvar gptel-permit-sandbox--rewritten-args)

(defconst gptel-permit-analytics--pending-limit 64
  "Maximum pending confirmations kept per (buffer tool args) key.")

(defvar gptel-permit-analytics--registered nil
  "Non-nil once `gptel-permit-register-analytics-hooks' has run.")





(defvar gptel-permit-analytics--pending nil
  "Alist of (BUFFER TOOL ARGS) -> FIFO queue of (ID . CONFIRM-TIME).
Pending confirmations awaiting a user decision, oldest first.")

(defun gptel-permit-analytics--active-p ()
  "Return non-nil when analytics capture is active.
Requires registration AND `gptel-permit-analytics-enabled': the
defcustom alone never enables anything."
  (and gptel-permit-analytics--registered
       gptel-permit-analytics-enabled))

(defun gptel-permit-analytics--now ()
  "Current time as a float, for wait-time measurement."
  (float-time))

(defun gptel-permit-analytics--ts ()
  "Current time as an ISO-8601 string with millisecond precision."
  (format-time-string "%Y-%m-%dT%H:%M:%S.%3N%z"))

(defun gptel-permit-analytics--period-plist (ts)
  "Return (:day D :week W :month M) derived from the timestamp TS.
Events do not store period fields; statistics derive the daily,
weekly and monthly grouping from each event's `ts' (ISO-8601,
millisecond precision, timezone-aware).  Returns nil when TS is
missing or unparseable."
  (when-let* ((time (and ts
                         (ignore-errors
                          (encode-time (iso8601-parse ts))))))
    (list :day (format-time-string "%Y-%m-%d" time)
          :week (format-time-string "%G-W%V" time)
          :month (format-time-string "%Y-%m" time))))

(defun gptel-permit-analytics--tool-info (tool-call)
  "Return (TOOL BUFFER BACKEND MODEL) strings for TOOL-CALL.
Any element is nil when the tool call carries no such information."
  (list (plist-get tool-call :name)
        (let ((buf (plist-get tool-call :buffer)))
          (and buf (if (bufferp buf) (buffer-name buf) (format "%s" buf))))
        (let ((backend (plist-get tool-call :backend)))
          (cond ((and backend (gptel-backend-p backend))
                 (gptel-backend-name backend))
                (backend (format "%s" backend))))
        (let ((model (plist-get tool-call :model)))
          (and model (format "%s" model)))))

(defun gptel-permit-analytics--args-alist (args)
  "Return the ARGS plist as an association list of truncated strings."
  (cl-loop for (k v) on args by #'cddr
           collect (cons (substring (symbol-name k) 1)
                         (gptel-permit-truncate-arg v))))

(defun gptel-permit-analytics--action-string (action)
  "Return the rule ACTION as a string, or \"none\" when nil.
List-form actions serialize distinctly — (judge sandbox deny)
becomes \"judge:sandbox/deny\" — so rule-match and verdict events
stay well-formed for list actions."
  (cond ((null action) "none")
        ((consp action)
         (concat (symbol-name (car action))
                 (when (cdr action)
                   (concat ":"
                           (mapconcat (lambda (a) (format "%s" a))
                                      (cdr action) "/")))))
        (t (symbol-name action))))

(defun gptel-permit-analytics--base-event (type tool id &optional extra)
  "Return the common event fields for TYPE, TOOL and tool-call ID.
EXTRA holds the event-specific fields.  Period grouping is derived
from `ts' when statistics are computed, not stored in the events."
  (append
   `((id . ,id)
     (ts . ,(gptel-permit-analytics--ts))
     (type . ,type))
   (when tool `((tool . ,tool)))
   extra))

(defun gptel-permit-analytics--append-line (event-alist)
  "Append EVENT-ALIST to `gptel-permit-analytics-file' as one JSON line.
Creates the file with 0600 permissions when missing.  Errors are the
caller's business: the observer (`gptel-permit-analytics--observe')
catches them; the audit predicate lets them fail the call closed."
  (let* ((file (expand-file-name gptel-permit-analytics-file))
         (newly-created (not (file-exists-p file))))
    (write-region (concat (json-encode event-alist) "\n")
                  nil file (not newly-created) 'silent)
    (when newly-created
      (set-file-modes file #o600))))



(defun gptel-permit-analytics--emit-tool-call (tool-call id)
  "Append a tool-call event for TOOL-CALL with tool-call ID.
The id is minted by the rule engine (`gptel-permit--mint-tool-call-id');
the analytics module allocates no ids of its own."
  (cl-destructuring-bind (tool buffer backend model)
      (gptel-permit-analytics--tool-info tool-call)
    (gptel-permit-analytics--append-line
     (gptel-permit-analytics--base-event
      "tool-call" tool id
      `((buffer . ,buffer)
        (backend . ,backend)
        (model . ,model)
        (args . ,(gptel-permit-analytics--args-alist
                  (plist-get tool-call :args))))))))

(defun gptel-permit-analytics--scope-fields (tool-call)
  "Return the `scope' field alist for TOOL-CALL, or nil when absent.
The scope is read off the enriched tool call's `:rule-scope'
annotation (the rule engine's match annotation) at emission time, and
serialized as a string with `symbol-name'.  Omitted — not empty —
when no rule matched, which is exactly the shape of every record
written before scopes existed."
  (when-let* ((scope (plist-get tool-call :rule-scope)))
    `((scope . ,(symbol-name scope)))))

(defun gptel-permit-analytics--emit-rule-match (tool-call id action)
  "Append a rule-match event when a rule with ACTION matched TOOL-CALL.
The record carries the matched rule's scope when one matched."
  (when (and id action)
    (gptel-permit-analytics--append-line
     (gptel-permit-analytics--base-event
      "rule-match" (plist-get tool-call :name) id
      `((action . ,(gptel-permit-analytics--action-string action))
        ,@(gptel-permit-analytics--scope-fields tool-call))))))

(defun gptel-permit-analytics--judge-fields ()
  "Return judge fields for the verdict event, or nil when absent.
The judge runs as a rule condition during matching; the state of its
most recent verdict for this call is read from its buffer-local
variables (see `gptel-permit-judge')."
  (when (and (featurep 'gptel-permit-judge)
             (or gptel-permit--last-judge-verdict
                 gptel-permit--last-judge-rationale))
    `((judge-model . ,(and gptel-permit-judge-model
                           (format "%s" gptel-permit-judge-model)))
      ,@(when gptel-permit--last-judge-verdict
          `((judge-verdict . ,(symbol-name gptel-permit--last-judge-verdict))))
      (judge-rationale . ,(or gptel-permit--last-judge-rationale "")))))

(defun gptel-permit-analytics--emit-verdict (tool-call id action verdict)
  "Append a verdict event for TOOL-CALL with tool-call ID.
ACTION is the matched rule's action symbol (nil when no rule matched)
and VERDICT is the verdict plist computed from it."
  (when id
    (gptel-permit-analytics--append-line
     (gptel-permit-analytics--base-event
      "verdict" (plist-get tool-call :name) id
      `((action . ,(gptel-permit-analytics--action-string action))
        ,@(gptel-permit-analytics--scope-fields tool-call)
        ,@(when (and (consp verdict) (plist-get verdict :confirm))
            '((confirm . t)))
        ,@(when-let* ((blocked (and (consp verdict) (plist-get verdict :block))))
            `((block . ,blocked)))
        ,@(gptel-permit-analytics--judge-fields))))))

(defun gptel-permit-analytics--push-pending (buffer tool args id t0)
  "Record a pending confirmation (ID . T0) for (BUFFER TOOL ARGS)."
  (let* ((key (list buffer tool args))
         (entry (assoc key gptel-permit-analytics--pending #'equal)))
    (if entry
        (let ((queue (append (cdr entry) (list (cons id t0)))))
          (setcdr entry
                  (if (length> queue gptel-permit-analytics--pending-limit)
                      (nthcdr (- (length queue)
                                 gptel-permit-analytics--pending-limit)
                              queue)
                    queue)))
      (push (cons key (list (cons id t0)))
            gptel-permit-analytics--pending))))

(defun gptel-permit-analytics--pop-pending (buffer tool args)
  "Pop the oldest pending confirmation for (BUFFER TOOL ARGS).
When no exact entry exists, fall back to matching TOOL and ARGS in any
buffer.  A third fallback consults the sandbox's
`gptel-permit-sandbox--rewritten-args' binding: a sandboxed acceptance
arrives with rewritten args, and the (NEW-ARGS . OLD-ARGS) pair
resolves the entry pended under the ORIGINAL args.  Returns
(ID . CONFIRM-TIME) or nil."
  (let* ((key (list buffer tool args))
         (entry (or (assoc key gptel-permit-analytics--pending #'equal)
                    (cl-find-if
                     (lambda (e)
                       (and (equal (cadr (car e)) tool)
                            (equal (caddr (car e)) args)))
                     gptel-permit-analytics--pending)
                    ;; A sandboxed acceptance arrives with rewritten
                    ;; args; the sandbox binds (NEW . OLD) pairs, so
                    ;; the entry may be pended under the ORIGINAL args.
                    (let ((original
                           (cdr-safe
                            (assoc args
                                   gptel-permit-sandbox--rewritten-args
                                   #'equal))))
                      (and original
                           (let* ((orig-key (list buffer tool original)))
                             (or (assoc orig-key
                                        gptel-permit-analytics--pending
                                        #'equal)
                                 (cl-find-if
                                  (lambda (e)
                                    (and (equal (cadr (car e)) tool)
                                         (equal (caddr (car e)) original)))
                                  gptel-permit-analytics--pending))))))))
    (when entry
      (let ((head (cadr entry)))
        (setcdr entry (cddr entry))
        (unless (cdr entry)
          (setq gptel-permit-analytics--pending
                (delq entry gptel-permit-analytics--pending)))
        head))))

(defun gptel-permit-analytics--emit-confirm (tool-call id)
  "Append a confirm event for TOOL-CALL (tool-call ID) and enqueue
the pending confirmation used to correlate the later decision."
  (when id
    (cl-destructuring-bind (_tool buffer _backend _model)
        (gptel-permit-analytics--tool-info tool-call)
      (gptel-permit-analytics--append-line
       (gptel-permit-analytics--base-event
        "confirm" (plist-get tool-call :name) id nil))
      (gptel-permit-analytics--push-pending
       buffer (plist-get tool-call :name) (plist-get tool-call :args) id
       (gptel-permit-analytics--now)))))

(defun gptel-permit-analytics--emit-audit (tool-call id)
  "Append an audit event for the sampled automation allow of TOOL-CALL."
  (when id
    (gptel-permit-analytics--append-line
     (gptel-permit-analytics--base-event
      "audit" (plist-get tool-call :name) id
      `((rate . ,gptel-permit-analytics-sample-rate))))))

(defun gptel-permit-analytics--emit-decision (tool id wait-ms choice)
  "Append a decision event for TOOL with tool-call ID.
WAIT-MS is the milliseconds between the confirm event and this
decision, or nil when the decision could not be correlated."
  (gptel-permit-analytics--append-line
   (gptel-permit-analytics--base-event
    "decision" tool id
    `((choice . ,choice)
      ,@(when wait-ms `((wait-ms . ,wait-ms)))))))

(defun gptel-permit-analytics--emit-judge-verdict (tool-call id payload)
  "Append a judge-verdict event for TOOL-CALL with tool-call ID.
PAYLOAD is the plist the judge emits: :verdict (including the failure
classes parse-fail, request-fail, timeout), :rationale, :arg (the
judged argument string) and :latency-ms."
  (when id
    (gptel-permit-analytics--append-line
     (gptel-permit-analytics--base-event
      "judge-verdict" (plist-get tool-call :name) id
      `(,@(when (plist-get payload :verdict)
            `((judge-verdict . ,(symbol-name (plist-get payload :verdict)))))
        (judge-rationale . ,(or (plist-get payload :rationale) ""))
        ,@(when (plist-get payload :arg)
            `((judge-arg . ,(gptel-permit-truncate-arg
                             (plist-get payload :arg)))))
        ,@(when (plist-get payload :latency-ms)
            `((judge-latency-ms . ,(plist-get payload :latency-ms)))))))))

(defun gptel-permit-analytics--observe (id tool-call type payload)
  "Adapter from `gptel-permit-events-functions' to the event emitters.
Receives the uniform engine callback signature: the tool-call id,
the enriched TOOL-CALL, the event TYPE (:tool-call, :rule-match, :verdict,
:confirm, or :judge-verdict emitted by the judge module) and the event
PAYLOAD (nil, the matched action, (ACTION . VERDICT), nil, or the
judge-verdict plist respectively).  Inert unless analytics is
active.  Never signals: analytics failures are logged and never
propagate into the permission hook (the core also isolates observers
per function — belt and braces)."
  (when (gptel-permit-analytics--active-p)
    (condition-case err
        (pcase type
          (:tool-call  (gptel-permit-analytics--emit-tool-call tool-call id))
          (:rule-match (gptel-permit-analytics--emit-rule-match
                        tool-call id payload))
          (:verdict    (gptel-permit-analytics--emit-verdict
                        tool-call id (car payload) (cdr payload)))
          (:confirm    (gptel-permit-analytics--emit-confirm tool-call id))
          (:judge-verdict (gptel-permit-analytics--emit-judge-verdict
                           tool-call id payload)))
      (error (gptel-permit-log "Analytics: %s event failed: %S" type err)))))

(defun gptel-permit-analytics--automation-allow-p (verdict)
  "Return non-nil if VERDICT is an automation-allow.
That is a plist with a nil :confirm and no :block (rule allow or a
successful sandbox); such verdicts may be audited by sampling."
  (and (consp verdict)
       (plist-member verdict :confirm)
       (null (plist-get verdict :confirm))
       (not (plist-get verdict :block))))

(defun gptel-permit-analytics--audit-p (id tool-call verdict)
  "Audit predicate on `gptel-permit-veto-functions'.
Return non-nil when VERDICT is an automation allow selected for audit
sampling; the rule engine then upgrades the verdict to (:confirm t),
preserving any args rewrite.  Emits the audit event itself when a call
is selected.  Sampling applies only to automation-allow verdicts,
never to blocks, and only while analytics is active.  Errors are not
caught: they propagate into the permission hook and fail the call
closed, exactly as sampling errors did before this rode the veto hook."
  (and (gptel-permit-analytics--active-p)
       (gptel-permit-analytics--automation-allow-p verdict)
       (< (random 100) (* gptel-permit-analytics-sample-rate 100))
       (progn (gptel-permit-analytics--emit-audit tool-call id) t)))

(defun gptel-permit-analytics--record-decision (choice tool-calls ov)
  "Record decision events for CHOICE resolving the pending TOOL-CALLS.
OV is the tool-call dispatch overlay, possibly nil.  Called as :before
advice on gptel's `gptel--accept-tool-calls', `gptel--reject-tool-calls'
and `gptel--steer-tool-calls'.  A cancel is recorded as an event, not a
terminal outcome: gptel permits resuming canceled calls.  Calls made
under a `gptel-permit--programmatic-call' binding are programmatic
resolutions, not interactive approvals: the advice skips them (the
programmatic resolver records its own decision events)."
  (when (and (not gptel-permit--programmatic-call)
             (gptel-permit-analytics--active-p))
    (condition-case err
        (let ((buffer (and (overlayp ov) (overlay-buffer ov)
                           (buffer-name (overlay-buffer ov)))))
          (if tool-calls
              (dolist (call tool-calls)
                (pcase-let* ((`(,tool-spec ,arg-plist _) call)
                             (tool (and tool-spec (gptel-tool-name tool-spec)))
                             (pending (gptel-permit-analytics--pop-pending
                                       buffer tool arg-plist))
                             (wait-ms (and pending
                                           (max 0 (round
                                                   (* 1000
                                                      (- (gptel-permit-analytics--now)
                                                         (cdr pending))))))))
                  (gptel-permit-analytics--emit-decision
                   tool (car pending) wait-ms choice)))
          ;; Minibuffer-path cancel: gptel passes no tool calls, so the
          ;; resolution cannot be correlated; record it id-less.
          (gptel-permit-analytics--emit-decision nil nil nil choice)))
      (error
       (gptel-permit-log "Analytics: decision capture failed: %S" err)))))

(defun gptel-permit-analytics--advice-accept (tool-calls &optional ov &rest _)
  "Decision-capture advice for `gptel--accept-tool-calls'."
  (gptel-permit-analytics--record-decision "allow" tool-calls ov))

(defun gptel-permit-analytics--advice-reject (tool-calls &optional ov &rest _)
  "Decision-capture advice for `gptel--reject-tool-calls'."
  (gptel-permit-analytics--record-decision "cancel" tool-calls ov))

(defun gptel-permit-analytics--advice-steer (tool-calls &optional ov &rest _)
  "Decision-capture advice for `gptel--steer-tool-calls'."
  (gptel-permit-analytics--record-decision "steer" tool-calls ov))

(defun gptel-permit-register-analytics-hooks ()
  "Install decision-capture advice and enable analytics event capture.
Idempotent.  Intended for a `use-package' :config section:

  (use-package gptel-permit
    :config
    (gptel-permit-register-analytics-hooks))

This installs :before advice on the gptel internals
`gptel--accept-tool-calls', `gptel--reject-tool-calls' and
`gptel--steer-tool-calls' (fragile across gptel releases), adds the
event observer to `gptel-permit-events-functions' and the audit
predicate to `gptel-permit-veto-functions' (the core calls no analytics
functions by name), and sets `gptel-permit-analytics-enabled' to t.
Undo with `gptel-permit-unregister-analytics-hooks'."
  (interactive)
  (advice-add 'gptel--accept-tool-calls :before
              #'gptel-permit-analytics--advice-accept)
  (advice-add 'gptel--reject-tool-calls :before
              #'gptel-permit-analytics--advice-reject)
  (advice-add 'gptel--steer-tool-calls :before
              #'gptel-permit-analytics--advice-steer)
  (add-hook 'gptel-permit-events-functions
            #'gptel-permit-analytics--observe)
  (add-hook 'gptel-permit-veto-functions
            #'gptel-permit-analytics--audit-p)
  (setq gptel-permit-analytics--registered t
        gptel-permit-analytics-enabled t))

(defun gptel-permit-unregister-analytics-hooks ()
  "Remove analytics decision-capture advice and disable capture.
Restores the inert state: no advice, no hook functions, no events, no
audit sampling."
  (interactive)
  (advice-remove 'gptel--accept-tool-calls
                 #'gptel-permit-analytics--advice-accept)
  (advice-remove 'gptel--reject-tool-calls
                 #'gptel-permit-analytics--advice-reject)
  (advice-remove 'gptel--steer-tool-calls
                 #'gptel-permit-analytics--advice-steer)
  (remove-hook 'gptel-permit-events-functions
               #'gptel-permit-analytics--observe)
  (remove-hook 'gptel-permit-veto-functions
               #'gptel-permit-analytics--audit-p)
  (setq gptel-permit-analytics--registered nil
        gptel-permit-analytics-enabled nil
        gptel-permit-analytics--pending nil))

(defun gptel-permit-analytics--event-field (event key)
  "Return the value of KEY (a symbol) in the parsed EVENT alist."
  (cdr (assoc key event)))

(defun gptel-permit-analytics--read-events (file)
  "Return the parsed JSON events of the JSONL FILE, skipping bad lines.
Returns nil when FILE is missing."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (cl-loop for line in (split-string (buffer-string) "\n" t)
               for ev = (ignore-errors (json-read-from-string line))
               when (and (consp ev)
                         (gptel-permit-analytics--event-field ev 'type))
               collect ev))))

(defun gptel-permit-analytics--fold-event (row type event)
  "Fold the parsed event (TYPE, EVENT) into the outcome plist ROW."
  (pcase type
    ("verdict"
     (setq row (plist-put row :action
                          (gptel-permit-analytics--event-field event 'action)))
     (when (eq (gptel-permit-analytics--event-field event 'confirm) t)
       (setq row (plist-put row :confirm t)))
     (when-let* ((blocked (gptel-permit-analytics--event-field event 'block)))
       (setq row (plist-put row :block blocked))))
    ("confirm" (setq row (plist-put row :asked t)))
    ("audit"   (setq row (plist-put row :audited t)))
    ("decision"
     (setq row (plist-put row :choice
                          (gptel-permit-analytics--event-field event 'choice)))
     (when-let* ((wait-ms (gptel-permit-analytics--event-field event 'wait-ms)))
       (setq row (plist-put row :wait-ms wait-ms)))))
  row)

(defun gptel-permit-analytics--outcome-table (events)
  "Fold EVENTS into a hash table of per-call outcome plists keyed by id.
Each row's period fields are derived from the call's first event's
`ts' — events carry no period fields of their own.  Ids are strings
(TIMESTAMP.PID.SERIAL, minted by the rule engine); historical files
carry integer ids.  Both fold identically under `equal' semantics."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (event events table)
      (let ((id (gptel-permit-analytics--event-field event 'id))
            (type (gptel-permit-analytics--event-field event 'type)))
        (when id
          (let ((row (or (gethash id table)
                         (puthash id
                                  (nconc
                                   (list :tool
                                         (gptel-permit-analytics--event-field
                                          event 'tool))
                                   (gptel-permit-analytics--period-plist
                                    (gptel-permit-analytics--event-field
                                     event 'ts)))
                                  table))))
            (puthash id (gptel-permit-analytics--fold-event row type event)
                     table)))))))

(defun gptel-permit-analytics--outcome-rows (events)
  "Return the per-call outcome plists folded from EVENTS."
  (let ((rows nil))
    (maphash (lambda (_id row) (push row rows))
             (gptel-permit-analytics--outcome-table events))
    rows))

(defun gptel-permit-analytics--wilson (x n)
  "Return (LO HI), the Wilson 95% CI (z=1.96) for X successes of N trials.
Returns nil when N is zero."
  (when (> n 0)
    (let* ((z 1.96)
           (p (/ (float x) n))
           (z2 (* z z))
           (den (+ 1.0 (/ z2 n)))
           (center (/ (+ p (/ z2 (* 2 n))) den))
           (radius (/ (* (/ z den)
                         (sqrt (+ (/ (* p (- 1 p)) n)
                                  (/ z2 (* 4 n n)))))
                      1.0)))
      (list (max 0.0 (- center radius))
            (min 1.0 (+ center radius))))))

(defun gptel-permit-analytics--false-allow (rows)
  "Compute the false-allow statistics from the outcome ROWS.
A sampled (audited) call counts as overridden when the user's decision
was cancel or steer."
  (let* ((audited (cl-count-if (lambda (r) (plist-get r :audited)) rows))
         (overridden (cl-count-if
                      (lambda (r)
                        (and (plist-get r :audited)
                             (member (plist-get r :choice) '("cancel" "steer"))))
                      rows))
         (rate (if (> audited 0) (/ (float overridden) audited) 0.0)))
    (list :audited audited
          :overridden overridden
          :rate rate
          :ci (gptel-permit-analytics--wilson overridden audited))))

(defun gptel-permit-analytics--per-tool (rows)
  "Return the per-tool breakdown of the outcome ROWS."
  (let ((tools (sort (cl-delete-duplicates
                      (delq nil (mapcar (lambda (r) (plist-get r :tool)) rows))
                      :test #'equal)
                     #'string-lessp)))
    (cl-loop for tool in tools
             collect (let* ((rs (cl-remove-if-not
                                 (lambda (r) (equal (plist-get r :tool) tool))
                                 rows))
                            (calls (length rs))
                            (asked (cl-count-if
                                    (lambda (r) (plist-get r :asked)) rs))
                            (waits (delq nil
                                         (mapcar (lambda (r)
                                                   (plist-get r :wait-ms))
                                                 rs))))
                       (list tool
                             :calls calls
                             :asked asked
                             :ask-rate (if (> calls 0)
                                           (/ (float asked) calls)
                                         0.0)
                             :avg-wait-ms (when waits
                                            (/ (apply #'+ waits)
                                               (float (length waits)))))))))

(defun gptel-permit-analytics--periods (rows key)
  "Return the breakdown of the outcome ROWS by the KEY period field."
  (let ((periods (sort (cl-delete-duplicates
                        (delq nil (mapcar (lambda (r) (plist-get r key)) rows))
                        :test #'equal)
                       #'string-lessp)))
    (cl-loop for period in periods
             collect (let* ((rs (cl-remove-if-not
                                 (lambda (r) (equal (plist-get r key) period))
                                 rows)))
                       (list period
                             :calls (length rs)
                             :asked (cl-count-if
                                     (lambda (r) (plist-get r :asked)) rs)
                             :blocked (cl-count-if
                                       (lambda (r) (plist-get r :block)) rs))))))

(defun gptel-permit-analytics--auto-allowed-p (row)
  "Return non-nil if outcome ROW is an un-sampled automation allow.
Structural test, no action-name list to keep in sync: a matched action
other than \"none\", not asked, not blocked."
  (and (plist-get row :action)
       (not (equal (plist-get row :action) "none"))
       (not (plist-get row :asked))
       (not (plist-get row :block))))

(defun gptel-permit-analytics-compute (&optional file)
  "Compute statistics from the analytics events in the JSONL FILE.
FILE defaults to `gptel-permit-analytics-file'.  Returns a plist with
:file, :total-calls, :auto-allowed, :asked, :blocked, :deferred,
:per-tool, :daily, :weekly, :monthly and :false-allow.  Pure apart from
reading FILE."
  (let* ((file (expand-file-name (or file gptel-permit-analytics-file)))
         (events (gptel-permit-analytics--read-events file))
         (rows (gptel-permit-analytics--outcome-rows events)))
    (list :file file
          :total-calls (length rows)
          :auto-allowed (cl-count-if #'gptel-permit-analytics--auto-allowed-p
                                     rows)
          :asked (cl-count-if (lambda (r) (plist-get r :asked)) rows)
          :blocked (cl-count-if (lambda (r) (plist-get r :block)) rows)
          :deferred (cl-count-if (lambda (r)
                                   (equal (plist-get r :action) "none"))
                                 rows)
          :per-tool (gptel-permit-analytics--per-tool rows)
          :daily (gptel-permit-analytics--periods rows :day)
          :weekly (gptel-permit-analytics--periods rows :week)
          :monthly (gptel-permit-analytics--periods rows :month)
          :false-allow (gptel-permit-analytics--false-allow rows))))

(defun gptel-permit-analytics--render (stats)
  "Insert a human-readable rendering of the computed STATS."
  (let* ((false-allow (plist-get stats :false-allow))
         (ci (plist-get false-allow :ci)))
    (insert
     (format "gptel-permit analytics — %s\n\n" (plist-get stats :file))
     (format "Calls: %d (auto-allowed %d, asked %d, blocked %d, deferred %d)\n\n"
             (plist-get stats :total-calls)
             (plist-get stats :auto-allowed)
             (plist-get stats :asked)
             (plist-get stats :blocked)
             (plist-get stats :deferred))
     (format "False-allow audit: %d audited, %d overridden, rate %.1f%%\n"
             (plist-get false-allow :audited)
             (plist-get false-allow :overridden)
             (* 100.0 (plist-get false-allow :rate))))
    (when ci
      (insert (format "  Wilson 95%% CI: [%.3f, %.3f]\n"
                      (car ci) (cadr ci))))
    (insert "\nPer tool:\n")
    (dolist (row (plist-get stats :per-tool))
      (cl-destructuring-bind (tool &key calls asked ask-rate avg-wait-ms) row
        (insert (format "  %-24s calls %-5d asked %-4d (%4.1f%%) avg-wait %s\n"
                        tool calls asked (* 100.0 ask-rate)
                        (if avg-wait-ms (format "%.0fms" avg-wait-ms) "n/a")))))
    (dolist (spec '((:daily . "Daily") (:weekly . "Weekly")
                    (:monthly . "Monthly")))
      (insert (format "\n%s:\n" (cdr spec)))
      (dolist (row (plist-get stats (car spec)))
        (cl-destructuring-bind (period &key calls asked blocked) row
          (insert (format "  %-12s calls %-5d asked %-4d blocked %d\n"
                          period calls asked blocked)))))))

(defun gptel-permit-analytics-report (&optional file)
  "Render analytics statistics for FILE in a *gptel-permit-analytics* buffer.
FILE defaults to `gptel-permit-analytics-file'.  Returns the statistics
plist returned by `gptel-permit-analytics-compute'."
  (interactive)
  (let ((stats (gptel-permit-analytics-compute file)))
    (with-current-buffer (get-buffer-create "*gptel-permit-analytics*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (gptel-permit-analytics--render stats))
      (special-mode)
      (goto-char (point-min))
      (display-buffer (current-buffer)))
    stats))

(provide 'gptel-permit-analytics)
;;; gptel-permit-analytics.el ends here
