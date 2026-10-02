;;; gptel-permit.el --- Rule-based tool-call permissions for gptel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 krvkir

;; Author: krvkir <krvkir@gmail.com>
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9"))
;; Keywords: convenience, tools, agents, hypermedia
;; URL: https://github.com/krvkir/gptel-permit

;; This file is NOT part of GNU Emacs.

;;; Commentary:
;; This file provides a permission rule system for gptel tools.
;; Rules can be defined globally via custom variables or interactively
;; per session (buffer-local).

;;; Code:

(require 'cl-lib)
(require 'gptel)
(require 'project)

(declare-function gptel-tool-p "gptel-request" (object))
(declare-function gptel-tool-name "gptel-request" (tool))

;; Org is used only inside org-mode notebook buffers and is required
;; lazily at run time.  The compile-time require below is load-time
;; inert: it only makes Org's macros (`org-with-wide-buffer')
;; expandable when this file is byte-compiled.
(eval-when-compile (require 'org nil t))

(declare-function org-entry-get "org"
                  (pom property &optional inherit literal-nil))
(declare-function org-entry-put "org" (pom property value))
(declare-function org-with-wide-buffer "org-macs" (&rest body))
(declare-function org-at-heading-p "org" (&optional anything))
(declare-function org-open-line "org" (n))
(declare-function org-get-heading "org"
                  (&optional no-tags no-prefix no-todo no-comment))
(declare-function outline-next-heading "outline" (&optional invisible-ok))

(defgroup gptel-permit nil
  "Rule-based tool-call permissions for gptel."
  :group 'gptel
  :prefix "gptel-permit-")

(defcustom gptel-permit-log-enabled nil
  "If non-nil, enable extensive logging for gptel-permit permissions check."
  :type 'boolean
  :group 'gptel-permit)

(defun gptel-permit--log (format-string &rest args)
  "Log a message to the `*gptel-permit-log*' buffer if logging is enabled.
FORMAT-STRING and ARGS are passed to `format'."
  (when gptel-permit-log-enabled
    (let ((msg (apply #'format format-string args))
          (buf (get-buffer-create "*gptel-permit-log*")))
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-max))
          (let ((inhibit-read-only t))
            (insert (format-time-string "[%Y-%m-%d %H:%M:%S] ") msg "\n")))))))

(defun gptel-permit--truncate-arg (arg)
  "Truncate string representation of ARG to first 30 and last 30 characters if it's longer than 60."
  (let ((s (format "%s" arg)))
    (if (> (length s) 60)
        (concat (substring s 0 30) "..." (substring s -30))
      s)))

(defconst gptel-permit-store-file-name ".gptel-permit-rules"
  "File name of a project store holding project-scoped permission rules.
One store per directory; every store on the chain from the notebook's
directory up to the project root is read, nearest first.

Each rule is one printed plist per line:
  (:tool \"Bash\" :conditions ((:command . \"^make test\")) :action allow)
`;'-comment lines and blank lines are allowed.  Rules are read as
data, never evaluated (see `gptel-permit--valid-persisted-rule-p').")

(defcustom gptel-permit-global-rules
  `((:tool-group write
                 :conditions ((path . ,gptel-permit-store-file-name))
                 :action block)
    (:conditions ((path . :inside-protected-dirs))
                 :action ask)
    (:tool-group read
                 :conditions ((path . :inside-project))
                 :action allow)
    (:tool-group write
                 :conditions ((path . :inside-project))
                 :action ask)
    (:tool-group write
                 :conditions ((path . :path-traversal))
                 :action ask)
    (:tool-group search :action allow)
    (:tool-group inform :action allow)
    (:tool "Bash"
           :conditions ((:command . ".* rm .*"))
           :action ask)
    (:action ask))
  "Global permission rules for gptel tools.

Each rule is a plist specifying matching conditions for a tool
call.  If all conditions of a rule are met, its action is
performed.  Global rules are checked after session-local rules
(see `gptel-permit-rules').

A rule may contain the following keys:
  :tool         A concrete tool name (string).
  :tool-group   A tool group symbol (e.g. read, write, shell).
  :conditions   An alist of (KEY . PATTERN) pairs.
  :action       One of allow, deny, ask, or any action symbol
                registered in `gptel-permit-action-handlers'
                (e.g. sandbox, provided by the optional sandbox
                module); or a list whose car is a registered action
                symbol — the cdr is passed to the handler as a third
                argument (e.g. (judge allow deny), provided by the
                optional judge module).

If both :tool and :tool-group are present, :tool takes
precedence and a warning is emitted.  If neither :tool nor
:tool-group is present, the rule matches ANY tool.

Each condition KEY can be:
  - A concrete argument name keyword (e.g. :file_path, :command).
  - An argument group symbol
    (e.g. (path . \"regexp\")).

Each condition PATTERN can be:
  - A regexp string tested against the normalized argument value.
  - A predicate keyword (:inside-project, :outside-project,
    :inside-protected-dirs, :path-traversal) — looked up in
    `gptel-permit--condition-predicates'.
  - A function called as (FUNC VALUE TOOL-CALL); non-nil return
    means the condition matches.

Default rules:
  - Auto-allow read tools accessing paths inside the project.
  - Ask for write tools accessing paths inside the project.
  - Ask for write tools with path-traversal (.. or absolute).
  - Ask for any tool accessing protected directories
    (`gptel-permit-protected-dirs'; the default includes the
    project-relative `./.git').

The rules in this variable are the `global' rule scope: the broadest
of the four scopes of `gptel-permit-rule-scopes', consulted last after
the session (`gptel-permit-rules'), notebook and project scopes.  The
rule wizard can persist a rule into this variable through the
Customize machinery by answering its scope question with `global'.

Customize this variable or override it in your init file."
  :type '(repeat
          (plist
           :key-type symbol
           :value-type sexp
           :options ((:tool string)
                     (:tool-group symbol)
                     (:conditions (repeat
                                   (cons
                                    (choice (symbol :tag "Argument group")
                                            (symbol :tag "Argument name"))
                                    (choice :tag "Rule condition"
                                            (string :tag "Regexp")
                                            (const :inside-project)
                                            (const :outside-project)
                                            (const :inside-protected-dirs)
                                            (const :path-traversal)
                                            (function :tag "Custom checker")))))
                     (:action
                      (choice (const :tag "Allow (auto-approve)" allow)
                              (const :tag "Deny (auto-block)" deny)
                              (const :tag "Ask (prompt user)" ask)
                              (symbol :tag "Registered action")
                              (cons :tag "Action form (list)"
                                    (symbol :tag "Action")
                                    (repeat sexp)))))))
  :group 'gptel-permit)

(defvar-local gptel-permit-rules nil
  "Session-scoped permission rules for gptel tools in the current buffer.
Each rule is a plist of the form:
  (:tool <tool-name> :conditions ((<arg-name> . <regexp>) ...) :action <allow/deny/ask>)

This is the `session' rule scope: the narrowest of the four scopes of
`gptel-permit-rule-scopes'.  Rules here govern only this buffer, are
checked first, and never outlive the buffer — they are not written to
any file and are not restored when the notebook is reopened.  Rules
created for other scopes go to the notebook file (the `notebook'
scope), the project's `.gptel-permit-rules' store (the `project'
scope) or the Customize option of the global scope.")

(defvar-local gptel-permit-notebook-rules nil
  "Notebook-scoped permission rules, persisted in a markdown notebook's file.
The value is a list of rule plists in the usual format (see
`gptel-permit-rules'); it is the file-local storage of the `notebook'
rule scope (`gptel-permit-rule-scopes') for notebooks not in
`org-mode' — Org notebooks use the `GPTEL_PERMIT_RULES' property
instead and never touch this variable or the local variables
mechanism.

gptel-permit writes the variable into the file's standard
`Local Variables:' block with `add-file-local-variable', and Emacs
applies it during its `hack-local-variables' pass when the file is
next visited.  The `safe-local-variable' property (a list predicate,
registered below and in the package's autoloads) keeps visiting a
rules-bearing notebook from prompting about local variables.

Because that machinery does the applying, the markdown notebook scope
works only while `enable-local-variables' is non-nil, its default.
A user who sets it to nil gets no markdown notebook scope at all:
the variable is never set on visit, `gptel-permit--read-notebook-rules'
returns no rules and the notebook scope contributes nothing.")

;;;###autoload
(put 'gptel-permit-notebook-rules 'safe-local-variable #'listp)

(defcustom gptel-permit-project-rules-enabled t
  "Whether to read project rule stores (`.gptel-permit-rules' files).
A project's rules live in `.gptel-permit-rules' files — one printed
rule plist per line, `;' comments allowed — along the directory chain
from the notebook's directory up to the project root; see
`gptel-permit--read-project-rules'.

These files are read without confirmation, which trusts them the same
way Emacs trusts a repository's `.dir-locals.el': a cloned repository
can ship a policy that auto-approves its own tool calls.  Set this
option to nil to disable the project scope entirely — no store is
read, no repository-shipped rule influences a verdict, and the rule
wizard refuses to store project rules while it is off."
  :type 'boolean
  :group 'gptel-permit)

(defvar gptel-permit-rule-scopes
  '((session  :reader gptel-permit--read-session-rules
              :writer gptel-permit--write-session-rule)
    (notebook :reader gptel-permit--read-notebook-rules
              :writer gptel-permit--write-notebook-rule)
    (project  :reader gptel-permit--read-project-rules
              :writer gptel-permit--write-project-rule)
    (global   :reader gptel-permit--read-global-rules
              :writer gptel-permit--write-global-rule))
  "Rule scopes, their storage and their order — most specific first.

The order of this alist IS the match order of the rule engine: rules
collected from `session' through `global' are tried in that order and
the first match wins.  Each entry is (SCOPE-SYMBOL . PLIST) with:

  :reader Function called with no arguments in the session buffer —
          which is already the notebook buffer, since gptel runs its
          pre-tool hook inside `with-current-buffer' — returning the
          scope's rule list, or nil when the scope has no storage in
          the current context (a scope with no readable storage
          contributes nothing).
  :writer Function called as (RULE) to persist one rule; returns the
          stored rule, or signals an error on failure (the rule
          wizard then keeps a session copy).

Removing an entry disables that scope entirely: its rules do not
apply and its store is not even read.  Adding an entry adds a scope
with no other configuration or code change; third-party code may
register a new scope (e.g. a \"workspace\" scope above `project').
The scope order is the sole determinant of precedence — no other
setting alters which rule wins.  A rule's scope is the user's choice
at creation time through the rule wizard's last question
(`gptel-permit-add-rule').")

(defun gptel-permit--strip-origin (rule)
  "Return a copy of RULE without its `:origin' key.
Origins are bookkeeping attached at read time (see
`gptel-permit--scoped-rules') and are never written back into a
store.  Returns RULE unchanged when it carries none."
  (if (plist-member rule :origin)
      (cl-loop for (k v) on rule by #'cddr
               unless (eq k :origin)
               append (list k v))
    rule))

(defun gptel-permit--rule-with-origin (rule origin)
  "Return a fresh copy of RULE with ORIGIN as its `:origin'.
Any store-supplied `:origin' field is discarded: a rule's origin is
attested by whoever reads it, never part of the store's data.  A copy
is made rather than mutating RULE — session and global rules are the
user's own configuration and must not gain keys by side effect."
  (append (gptel-permit--strip-origin rule) (list :origin origin)))

(defun gptel-permit--ensure-origin (rule scope)
  "Return RULE with an origin attached when it arrived without one.
Session and global rules are returned by their trivial readers
un-attested, so the collector records what read them; rules whose
reader already attested an origin (notebook, project) keep it."
  (if (plist-get rule :origin)
      rule
    (plist-put (copy-sequence rule) :origin (list :scope scope))))

(defun gptel-permit--format-origin (origin)
  "Return the ORIGIN plist formatted for a log line, e.g.
\"scope=project file=/proj/.gptel-permit-rules\".  nil when ORIGIN
carries no scope."
  (when (plist-get origin :scope)
    (mapconcat #'identity
               (delq nil
                     (list (format "scope=%s" (plist-get origin :scope))
                           (and (plist-get origin :file)
                                (format "file=%s" (plist-get origin :file)))
                           (and (plist-get origin :heading)
                                (format "heading=%s" (plist-get origin :heading)))))
               " ")))

(defun gptel-permit--valid-persisted-condition-p (value)
  "Return non-nil when VALUE may serve as a persisted rule condition.
Persisted rules are data, not code: the value may be a regexp string,
a predicate keyword, or a symbol naming a defined function — never a
lambda or other cons form; see `gptel-permit--valid-persisted-rule-p'."
  (or (stringp value)
      (keywordp value)
      (and (symbolp value) (fboundp value))))

(defun gptel-permit--valid-persisted-rule-p (rule)
  "Return non-nil when RULE is a valid persisted rule plist.
A rule read from a persisted scope (notebook, project) must be a
non-empty plist whose keys are all keywords and whose condition
values are strings, predicate keywords, or symbols naming functions
(see `gptel-permit--valid-persisted-condition-p').  Lambda and other
cons-shaped condition values are rejected: persisted rules are data,
not code.  Session and global rules are not validated — they are the
user's own configuration and keep callable conditions written as
lambdas."
  (let ((n (proper-list-p rule)))
    (and n (> n 0) (cl-evenp n)
         (cl-every #'keywordp
                   (cl-loop for (k _v) on rule by #'cddr collect k))
         (let ((conditions (plist-get rule :conditions)))
           (or (null conditions)
               (and (proper-list-p conditions)
                    (cl-every (lambda (pair)
                                (and (consp pair)
                                     (gptel-permit--valid-persisted-condition-p
                                      (cdr pair))))
                              conditions)))))))

(defun gptel-permit--validate-origin-rules (forms scope origin)
  "Return the well-formed persisted rules of FORMS, attested with ORIGIN.
FORMS are the rule plists read from a SCOPE store.  A rule failing
`gptel-permit--valid-persisted-rule-p' is skipped with a log line
naming SCOPE — a malformed rule is a user error, not an attack, and
must not fail the store or the call.  Each surviving rule carries
ORIGIN as its `:origin', overwriting any store-supplied origin."
  (cl-loop for rule in forms
           if (gptel-permit--valid-persisted-rule-p rule)
           collect (gptel-permit--rule-with-origin rule origin)
           else
           do (gptel-permit--log "Skipped invalid %s rule: %S" scope rule)))

(defcustom gptel-permit-protected-dirs '("~/.ssh/" "~/.gnupg/")
  "Directories that always require confirmation for tool-call access.
Used by the `:inside-protected-dirs' predicate in permission rules and
by the sandbox's mandatory read-only binds.

An entry starting with \"./\" is resolved relative to the project root
(`gptel-permit--project-root', falling back to `default-directory'), so
the default `./.git' protects the current project's repository with the
same single option that guards home-directory paths.  All other entries
are resolved with `expand-file-name' (`~' etc.)."
  :type '(repeat directory)
  :group 'gptel-permit)

(defcustom gptel-permit-tool-groups
  '(("Read" :tool-group read :arg-groups ((:file_path . path)))
    ("Glob" :tool-group read :arg-groups ((:path . path)))
    ("Grep" :tool-group read :arg-groups ((:path . path)))
    ("Write" :tool-group write :arg-groups ((:path . path) (:filename . path)))
    ("Edit" :tool-group write :arg-groups ((:path . path)))
    ("Insert" :tool-group write :arg-groups ((:path . path)))
    ("Mkdir" :tool-group write :arg-groups ((:parent . path) (:name . path)))
    ("Bash" :tool-group execute :arg-groups ((:command . code)))
    ("Eval" :tool-group execute :arg-groups ((:expression . code)))
    ("WebSearch" :tool-group search)
    ("WebFetch" :tool-group search)
    ("YouTube" :tool-group search)
    ("TodoWrite" :tool-group inform)
    ("Skill" :tool-group search)
    ("symbol_exists" :tool-group search)
    ("load_paths" :tool-group search)
    ("features" :tool-group search)
    ("manual_names" :tool-group search)
    ("manual_nodes" :tool-group search)
    ("manual_node_contents" :tool-group search)
    ("library_source" :tool-group search)
    ("symbol_manual_section" :tool-group search)
    ("function_source" :tool-group search)
    ("variable_source" :tool-group search)
    ("variable_value" :tool-group read)
    ("function_documentation" :tool-group search)
    ("variable_documentation" :tool-group search)
    ("variable_completions" :tool-group search)
    ("function_completions" :tool-group search)
    ("command_completions" :tool-group search)
    ("variable_prefix" :tool-group search))
  "Mapping of tool names to tool-groups and argument-groups.

Each entry is a list: (TOOL-NAME :tool-group GROUP :arg-groups ((ARG . GROUP) ...)).
Both :tool-group and :arg-groups are optional.

When a rule targets a tool-group, it matches any tool belonging to that group.
When a rule targets an arg-group, it matches any argument of the tool
belonging to that group."
  :type '(alist :key-type string
                :value-type (plist :key-type symbol
                                   :options ((:tool-group symbol)
                                             (:arg-groups (alist :key-type symbol
                                                                 :value-type symbol)))))
  :group 'gptel-permit)

(defun gptel-permit--resolve-tool-group (tool-name)
  "Resolve TOOL-NAME to its :tool-group."
  (plist-get (cdr (assoc tool-name gptel-permit-tool-groups)) :tool-group))

(defun gptel-permit--resolve-arg-groups (tool-name)
  "Resolve TOOL-NAME to its :arg-groups."
  (plist-get (cdr (assoc tool-name gptel-permit-tool-groups)) :arg-groups))

(defun gptel-permit--get-tool (name)
  "Retrieve the gptel tool spec for NAME, fallback to `gptel-tools`."
  (ignore-errors
    (if (fboundp 'gptel-get-tool)
        (gptel-get-tool name)
      (alist-get name gptel-tools nil nil #'equal))))

(defun gptel-permit--project-root ()
  "Get the current project root or active buffer's directory."
  (let ((pr (project-current))
        (bfn (buffer-file-name)))
    (or (and pr (project-root pr))
        (and bfn (file-name-directory bfn)))))

(defun gptel-permit--expand-protected-dir (dir &optional root)
  "Expand a protected-dirs entry DIR, or nil when DIR is not a string.
An entry starting with \"./\" resolves against the project root ROOT,
else `gptel-permit--project-root', else `default-directory'; every
other entry goes through `expand-file-name' (`~', absolute paths)."
  (when (stringp dir)
    (let ((root (or root (gptel-permit--project-root))))
      (if (string-prefix-p "./" dir)
          (cond (root (directory-file-name
                       (expand-file-name (substring dir 2) root)))
                ;; No project context: fall back to `default-directory',
                ;; keeping the entry's meaning as "relative to where we run".
                (t (directory-file-name (expand-file-name
                                         (substring dir 1)
                                         default-directory))))
        (expand-file-name dir)))))

(defun gptel-permit--processed-p (tool-call)
  "Return non-nil if TOOL-CALL has already been processed or errored."
  (or (plist-member tool-call :result)
      (plist-member tool-call :error)
      (plist-get tool-call :result)
      (plist-get tool-call :error)))

(defun gptel-permit--path-arg-p (arg-key arg-groups)
  "Return non-nil if ARG-KEY belongs to the `path' arg-group."
  (eq (alist-get arg-key arg-groups) 'path))

(defun gptel-permit--tool-path-args (tool-name arg-groups)
  "Get all argument keywords (as strings) that are path arguments for TOOL-NAME."
  (let* ((tool (gptel-permit--get-tool tool-name))
         (spec-args (and tool (gptel-tool-args tool))))
    (cl-loop for spec-arg in spec-args
             for arg-str = (plist-get spec-arg :name)
             for arg-kw = (intern (concat ":" arg-str))
             when (gptel-permit--path-arg-p arg-kw arg-groups)
             collect (concat ":" arg-str))))

(defun gptel-permit--normalize-tool-call (tool-call)
  "Normalize TOOL-CALL from overlay format to plist format."
  (if (and (listp tool-call)
           (not (keywordp (car tool-call)))
           (fboundp 'gptel-tool-p)
           (gptel-tool-p (car tool-call)))
      (list :name (gptel-tool-name (car tool-call))
            :args (cadr tool-call))
    tool-call))

(defun gptel-permit--enrich-tool-call (tool-call)
  "Enrich TOOL-CALL with :tool-group and :arg-groups."
  (let* ((name (plist-get tool-call :name))
         (group-info (cdr (assoc name gptel-permit-tool-groups)))
         (tool-group (plist-get group-info :tool-group))
         (arg-groups (plist-get group-info :arg-groups)))
    (append tool-call (list :tool-group tool-group :arg-groups arg-groups))))

(defun gptel-permit--validate-args (tool-call)
  "Validate TOOL-CALL before permission rules are evaluated.
TOOL-CALL is the plist passed to `gptel-pre-tool-call-functions',
containing at minimum :name and :args.  Checks for unknown tool
names, missing required arguments, and unknown argument names."
  (unless (gptel-permit--processed-p tool-call)
    (let* ((name (plist-get tool-call :name))
           (args (plist-get tool-call :args))
           (trunc-args (cl-loop for (k v) on args by #'cddr
                                collect k collect (gptel-permit--truncate-arg v))))
      (gptel-permit--log "Started validation for tool: %s with args: %S" name trunc-args)
      (let ((tool (gptel-permit--get-tool name)))
        (if (not tool)
            (progn
              (gptel-permit--log "Verdict: Blocked (Unknown tool: %s)" name)
              (list :block (format "Unknown tool: %s" name)))
          (let* ((spec-args (gptel-tool-args tool))
                 (spec-arg-names (mapcar (lambda (a) (intern (concat ":" (plist-get a :name)))) spec-args))
                 (missing nil)
                 (unknown nil))
            (cl-loop for (k _v) on args by #'cddr do
                     (if (memq k spec-arg-names)
                         (gptel-permit--log "Argument %s provided: ok" k)
                       (progn
                         (gptel-permit--log "Argument %s provided: wrong (unknown argument)" k)
                         (push (symbol-name k) unknown))))
            (dolist (spec-arg spec-args)
              (let* ((arg-name (intern (concat ":" (plist-get spec-arg :name))))
                     (optional (plist-get spec-arg :optional))
                     (val (plist-get args arg-name)))
                (when (and (not optional)
                           (or (not (plist-member args arg-name))
                               (null val)))
                  (gptel-permit--log "Argument %s missing (required)" arg-name)
                  (push (plist-get spec-arg :name) missing))))
            (let ((msg-parts nil))
              (when missing
                (push (format "Missing required argument(s): %s" (mapconcat #'identity missing ", ")) msg-parts))
              (when unknown
                (push (format "Unknown argument(s): %s (Did you mean %s?)" 
                              (mapconcat #'identity unknown ", ")
                              (mapconcat (lambda (a) (plist-get a :name)) spec-args ", "))
                      msg-parts))
              (if msg-parts
                  (let ((msg (mapconcat #'identity (nreverse msg-parts) "; ")))
                    (gptel-permit--log "Verdict: Blocked (%s)" msg)
                    (list :block msg))
                (progn
                  (gptel-permit--log "Verdict: Validation passed")
                  nil)))))))))

(defun gptel-permit--inside-project-p (expanded _raw _tool-call)
  "Return non-nil if expanded path EXPANDED is inside the project root."
  (let ((root (gptel-permit--project-root)))
    (and root (file-in-directory-p (format "%s" expanded) root))))

(defun gptel-permit--outside-project-p (expanded _raw _tool-call)
  "Return non-nil if expanded path EXPANDED is outside the project root."
  (let ((root (gptel-permit--project-root)))
    (and root (not (file-in-directory-p (format "%s" expanded) root)))))

(defun gptel-permit--inside-protected-dirs-p (expanded _raw _tool-call)
  "Return non-nil if expanded path EXPANDED is inside a protected directory.
Protected-dirs entries are expanded with
`gptel-permit--expand-protected-dir' (the `./' prefix is
project-root-relative), shared verbatim with the sandbox."
  (cl-some (lambda (d)
             (let ((pd (gptel-permit--expand-protected-dir d))
                   (tg (format "%s" expanded)))
               (or (file-in-directory-p tg pd)
                   (file-in-directory-p pd tg))))
           gptel-permit-protected-dirs))

(defun gptel-permit--path-traversal-p (_expanded raw _tool-call)
  "Return non-nil if RAW (unexpanded) value contains `..' or is absolute."
  (string-match-p "\\(?:^/\\|\\.\\.\\)" raw))

(defvar gptel-permit--condition-predicates
  '((:inside-project        . gptel-permit--inside-project-p)
    (:outside-project       . gptel-permit--outside-project-p)
    (:inside-protected-dirs . gptel-permit--inside-protected-dirs-p)
    (:path-traversal        . gptel-permit--path-traversal-p))
  "Alist mapping condition predicate keywords to functions.
Each function is called as (FUNC EXPANDED RAW TOOL-CALL) and returns
non-nil if the condition matches.  EXPANDED is the expand-file-name'd
value for path arguments; RAW is the original value before expansion.
Users may extend this alist with custom keywords.")

(defun gptel-permit--dispatch-condition (key val arg-val tool-call arg-groups)
  "Evaluate a single condition (KEY . VAL) against ARG-VAL from TOOL-CALL.
KEY is the condition target keyword (argument name or arg-group symbol).
VAL is the condition value: a string (regexp), a keyword (lookup in
`gptel-permit--condition-predicates'), or a function.
ARG-GROUPS is the tool's arg-group alist.
Returns non-nil if the condition matches.  A nil path argument is coerced
to \"\" and expanded against `default-directory'; a nil non-path argument
fails the condition."
  (let* ((is-path (or (eq key 'path)
                      (gptel-permit--path-arg-p key arg-groups)))
         (effective (if (and is-path (null arg-val)) "" arg-val)))
    (and effective
         (let ((expanded (if is-path (expand-file-name effective) effective)))
           (cond
            ((stringp val) (string-match-p val (format "%s" expanded)))
            ((keywordp val)
             (let ((fn (cdr (assoc val gptel-permit--condition-predicates))))
               (if fn (funcall fn (format "%s" expanded) (format "%s" effective) tool-call)
                 (progn (gptel-permit--log "Unknown condition predicate: %s" val) nil))))
            ((functionp val) (funcall val (format "%s" expanded) tool-call))
            (t (gptel-permit--log "Unknown condition type: %S" val) nil))))))

(defun gptel-permit--match-rule-p (rule tool-call)
  "Match RULE against enriched TOOL-CALL.
Returns the rule's :action if matched, otherwise nil."
  (let ((name (plist-get tool-call :name))
        (args (plist-get tool-call :args))
        (tool-group (plist-get tool-call :tool-group))
        (arg-groups (plist-get tool-call :arg-groups))
        (rule-tool (plist-get rule :tool))
        (rule-tool-group (plist-get rule :tool-group))
        (conditions (plist-get rule :conditions))
        (action (plist-get rule :action)))
    (when (and rule-tool rule-tool-group)
      (gptel-permit--log "Warning: Both :tool and :tool-group present in rule."))
    (let ((reason (cond ((and rule-tool (equal rule-tool name)) "tool name match")
                        ((and (not rule-tool) rule-tool-group (equal rule-tool-group tool-group)) "tool group match")
                        ((and (not rule-tool) (not rule-tool-group)) "universal rule"))))
      (when reason
        (gptel-permit--log "Testing rule (reason: %s): %S" reason rule)
        (let ((match (cl-every
                      (lambda (cond-pair)
                        (let* ((key (car cond-pair))
                               (val (cdr cond-pair))
                               (arg-keys (if (keywordp key) (list key)
                                           (cl-loop for (k . g) in arg-groups if (eq g key) collect k))))
                          (and arg-keys
                               (cl-some
                                (lambda (ak)
                                  (let ((arg-val (plist-get args ak)))
                                    (gptel-permit--dispatch-condition key val arg-val tool-call arg-groups)))
                                arg-keys))))
                      conditions)))
          (when match
            (gptel-permit--log "Rule matched!")
            action))))))

(defun gptel-permit--action-allow (_id _tool-call)
  "Built-in `allow' action handler: return `(:confirm nil)' (auto-approve)."
  (list :confirm nil))

(defun gptel-permit--action-deny (_id _tool-call)
  "Built-in `deny' action handler: return `(:block \"auto-denied\")' (reject)."
  (list :block "auto-denied"))

(defun gptel-permit--action-ask (_id _tool-call)
  "Built-in `ask' action handler: return `(:confirm t)' (force prompt)."
  (list :confirm t))

(defvar gptel-permit-action-handlers
  '((allow . gptel-permit--action-allow)
    (deny  . gptel-permit--action-deny)
    (ask   . gptel-permit--action-ask))
  "Alist mapping rule action symbols to handler functions.
A handler is called with (ID TOOL-CALL) — the tool-call id minted by
`gptel-permit--mint-tool-call-id' and the enriched tool call — and returns a
verdict plist per `gptel-pre-tool-call-functions', or nil to defer.
When the matched action is a cons cell (a list form), the engine
dispatches on its car and calls the handler with the action's cdr as a
third argument: (funcall handler ID TOOL-CALL (cdr action)); a handler
that cannot take the third argument errors and the engine fails closed.
The built-in actions (allow, deny, ask) are registered here like any
other; optional modules register their entries at load time, e.g. the
sandbox module adds \(sandbox . gptel-permit--sandbox-action).  A
matched action with no registered handler fails closed: see
`gptel-permit--apply-rules'.")

(defvar gptel-permit--programmatic-call nil
  "Non-nil while a rule action programmatically resolves prompted tool calls.
Action implementations bind this around programmatic acceptance or
rejection of tool calls (e.g. around a programmatic
`gptel--accept-tool-calls').  Advice and hooks may use it to
distinguish programmatic resolutions from interactive user approvals.
The core never binds it; it only provides the default of nil.")


(defvar gptel-permit--tool-call-serial 0
  "Serial component of tool-call ids minted in this Emacs session.")

(defun gptel-permit--mint-tool-call-id ()
  "Return a fresh tool-call id (a string).
Format TIMESTAMP.PID.SERIAL — unique across sessions (timestamp,
millisecond precision), concurrent Emacs processes (pid) and calls
within a process (serial), without any coordination with consumers.
All events of one tool call share the id minted for that call.  The
id is minted here and unrelated to the backend tool-call ids gptel
attaches to tool calls internally, which never reach the tool-call
hooks."
  (format "%s.%d.%d"
          (format-time-string "%Y%m%dT%H%M%S.%3N")
          (emacs-pid)
          (cl-incf gptel-permit--tool-call-serial)))

(defvar gptel-permit-before-rule-match-functions nil
  "Abnormal hook run once per tool call before rule matching.
Called with (ID TOOL-CALL); return values are ignored.  Modules use it
for per-call state lifecycle (e.g. the judge clears its per-call verdict
state here).  Errors are not caught: they fail the call closed.")

(defvar gptel-permit-events-functions nil
  "Abnormal hook observing the engine's events.
Called with (ID TOOL-CALL TYPE PAYLOAD) where TYPE is one of :tool-call,
:rule-match, :verdict or :confirm and PAYLOAD is nil, the matched action
symbol (nil when no rule matched), (ACTION . VERDICT) or nil
respectively.  The event type set is open: future engine versions may
emit additional event types through this hook with the same signature.
Each function runs isolated in `condition-case' (see
`gptel-permit--emit-event'): an erroring observer is logged and can
never alter a verdict.")

(defvar gptel-permit-veto-functions nil
  "Abnormal hook run after a verdict is computed, before it is returned.
Called with (ID TOOL-CALL VERDICT) via `run-hook-with-args-until-success'
and only when a rule matched.  A non-nil return upgrades the verdict to
`(:confirm t)', preserving any :args rewrite; the engine — not the veto
function — performs the upgrade.  Veto functions inspect VERDICT and can
only veto: they never return modified verdicts.  Errors are not caught:
they fail the call closed.")

(defun gptel-permit--emit-event (id tool-call type payload)
  "Emit an engine event (ID TOOL-CALL TYPE PAYLOAD).
Delivery to the observers on `gptel-permit-events-functions' is an
implementation detail of no concern to the caller: each observer runs
isolated in `condition-case', an erroring observer is logged and
skipped, and later observers still run.  Never signals; observers can
never alter a verdict."
  (dolist (fn gptel-permit-events-functions)
    (condition-case err
        (funcall fn id tool-call type payload)
      (error (gptel-permit--log "Event observer %S failed: %S" fn err)))))


;;; Rule scope storage
;;
;; One reader and one writer per scope of `gptel-permit-rule-scopes'.
;; The engine knows no scope by name; no reader knows another scope's
;; format.

(defun gptel-permit--read-session-rules ()
  "Session-scope `:reader' (see `gptel-permit-rule-scopes').
Returns `gptel-permit-rules': the user's own buffer configuration,
never validated and never persisted.  The collector attaches the
(:scope session) origin to the rules it returns."
  gptel-permit-rules)

(defun gptel-permit--write-session-rule (rule)
  "Session-scope `:writer' (see `gptel-permit-rule-scopes').
Pushes the origin-stripped RULE onto `gptel-permit-rules' — the
registry's session entry and the rule wizard's storage-failure
fallback (the wizard's session path keeps its own literal push)."
  (push (gptel-permit--strip-origin rule) gptel-permit-rules))

(defun gptel-permit--read-global-rules ()
  "Global-scope `:reader' (see `gptel-permit-rule-scopes').
Returns `gptel-permit-global-rules' unchanged, as before scopes
existed; the collector attaches the (:scope global) origin."
  gptel-permit-global-rules)

(defun gptel-permit--write-global-rule (rule)
  "Global-scope `:writer' (see `gptel-permit-rule-scopes').
Persists RULE through the Customize machinery: updates the running
value of `gptel-permit-global-rules' and saves it to the user's
custom file, as if the user had saved the option themself.  Never
touches any project or notebook file."
  (customize-save-variable 'gptel-permit-global-rules
                           (cons (gptel-permit--strip-origin rule)
                                 gptel-permit-global-rules)))

(defun gptel-permit--project-rules-file ()
  "The project root's `.gptel-permit-rules' store path, or nil.
The project scope's `:writer' appends here only — never to a store in
a deeper hand-chosen directory."
  (when-let* ((root (gptel-permit--project-root)))
    (expand-file-name gptel-permit-store-file-name root)))

(defun gptel-permit--dir-parent (dir)
  "The parent directory of DIR (with trailing slash), or nil at the root."
  (let* ((base (directory-file-name dir))
         (parent (file-name-directory base)))
    (and parent (file-name-as-directory parent))))

(defun gptel-permit--dir-chain (dir top)
  "Directories from DIR up to and including TOP, nearest first.
nil when DIR is neither TOP nor below it."
  (when (and dir (file-in-directory-p dir top))
    (if (equal dir top)
        (list dir)
      (cons dir
            (gptel-permit--dir-chain (gptel-permit--dir-parent dir) top)))))

(defun gptel-permit--project-rules-chain ()
  "The store directories of the project scope, nearest first.
Every directory from the notebook's directory up to and including
`gptel-permit--project-root' may hold a `.gptel-permit-rules' store.
nil when no project root resolves — no project and no visited file —
in which case the project scope contributes nothing.  The walk stops
at the project root: nothing above it is read, so a store in a
directory above the root (e.g. the user's home directory) cannot
govern the project; policy spanning several projects is the global
scope's business."
  (when-let* ((top (gptel-permit--project-root)))
    (let ((start (file-name-as-directory
                  (expand-file-name
                   (or (and (buffer-file-name)
                            (file-name-directory (buffer-file-name)))
                       default-directory))))
          (top-dir (file-name-as-directory (expand-file-name top))))
      (gptel-permit--dir-chain start top-dir))))

(defvar gptel-permit--project-rules-cache nil
  "Parse cache for `.gptel-permit-rules' stores: (FILE . (MTIME . FORMS)).
Keeps re-parsing off the tool-call path; an entry is reused only while
the store's modification time equals the cached one, so a store edited
wherever it sits on the chain is picked up on the next tool call.")

(defun gptel-permit--store-tail-junk-p (beg end)
  "Return non-nil when [BEG, END) of the current buffer holds input
the reader could not turn into a complete form: anything but
whitespace and comment lines (a truncated trailing form, an
unterminated string)."
  (save-excursion
    (goto-char beg)
    (catch 'junk
      (while (< (point) end)
        (skip-chars-forward " \t\n\r" end)
        (when (and (< (point) end)
                   (not (eq (char-after) ?\;)))
          (throw 'junk t))
        (forward-line 1))
      nil)))

(defun gptel-permit--parse-project-rules (file)
  "Parse the top-level forms of the `.gptel-permit-rules' store FILE.
Returns the forms in file order; comments and blank lines are skipped
by the reader itself.  `read-circle' is bound to nil — no circular
structure may be exercised from a store — and there is no read-eval:
persisted rules are inert data.

A syntax error signals and is never caught by the callers, so the
engine fails the call closed.  `read' signals the same `end-of-file'
for a clean list end and for a TRUNCATED trailing form (a store whose
last form never closes); the latter is a syntax error, so it is
detected here — a remaining tail holding anything but whitespace and
comments re-signals instead of being mistaken for an empty store.
Per-rule shape checking is the validation pass
(`gptel-permit--valid-persisted-rule-p'), not the parser's job."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((read-circle nil)
          (forms nil)
          (progress (point)))
      (condition-case nil
          (while t
            (push (read (current-buffer)) forms)
            (setq progress (point)))
        (end-of-file
         (when (gptel-permit--store-tail-junk-p progress (point-max))
           (signal 'end-of-file
                   (list (format "truncated form at end of %s" file))))))
      (nreverse forms))))

(defun gptel-permit--project-store-forms (store)
  "Return the parsed FORMS of the store file STORE through the mtime cache."
  (let* ((store (expand-file-name store))
         (mtime (file-attribute-modification-time
                 (file-attributes store)))
         (entry (assoc store gptel-permit--project-rules-cache)))
    (if (and entry (equal (car (cdr entry)) mtime))
        (cdr (cdr entry))
      (let ((forms (gptel-permit--parse-project-rules store)))
        (if entry
            (setcdr entry (cons mtime forms))
          (push (cons store (cons mtime forms))
                gptel-permit--project-rules-cache))
        forms))))

(defun gptel-permit--project-store-rules (store)
  "The validated, origin-attested rules of the `.gptel-permit-rules' STORE.
nil when STORE does not exist.  Reading errors are never caught — they
propagate into the engine's fail-closed `condition-case'."
  (when (file-exists-p store)
    (gptel-permit--validate-origin-rules
     (gptel-permit--project-store-forms store)
     'project
     (list :scope 'project :file store))))

(defun gptel-permit--read-project-rules ()
  "Project-scope `:reader' (see `gptel-permit-rule-scopes').
Walks `gptel-permit--project-rules-chain' nearest-first, concatenating
the validated rules of every existing `.gptel-permit-rules' store: for
a given call the store closest to the notebook decides and stores
further up fill wherever the closer ones are silent (first match wins
over the concatenation).  Each rule carries an origin naming its store
file, overwriting any store-supplied origin.

Returns nil with no project, and while
`gptel-permit-project-rules-enabled' is off — no store is read and
the cache is dropped, so disabling and re-enabling the option forgets
nothing stale.  Reading a store that cannot be parsed fails the call
closed (the error propagates)."
  (if (not gptel-permit-project-rules-enabled)
      (setq gptel-permit--project-rules-cache nil)
    (apply #'append
           (mapcar (lambda (dir)
                     (gptel-permit--project-store-rules
                      (expand-file-name gptel-permit-store-file-name dir)))
                   (gptel-permit--project-rules-chain)))))

(defun gptel-permit--write-project-rule (rule)
  "Project-scope `:writer' (see `gptel-permit-rule-scopes').
Appends the printed, origin-stripped RULE plus a newline to the
project root store (`gptel-permit--project-rules-file'), creating the
file when missing; no file outside the project root is ever written,
and there is no temp-file rename — concurrent readers see the old
content until the append lands.  The store's cache entry is dropped
so the next tool call parses the new content.

Signals an error — which the wizard catches, keeping a session copy —
when `gptel-permit-project-rules-enabled' is off (a disabled project
scope accepts no rules) or no project root resolves."
  (unless gptel-permit-project-rules-enabled
    (user-error "Project rules are disabled (`gptel-permit-project-rules-enabled' is nil)"))
  (let* ((file (or (gptel-permit--project-rules-file)
                   (user-error "No project root under which to store a rule")))
         ;; prin1-to-string, not %s: the form on the store's one-line
         ;; record must round-trip through `read' (strings quoted).
         (content (concat (prin1-to-string (gptel-permit--strip-origin rule))
                          "\n")))
    (append-to-file content nil file)
    (setq gptel-permit--project-rules-cache
          (assoc-delete-all (expand-file-name file)
                            gptel-permit--project-rules-cache))
    rule))

(defconst gptel-permit--notebook-org-property "GPTEL_PERMIT_RULES"
  "Org notebook property storing the notebook-scoped rules.
The value is the rules' printed Lisp form, read back with `read'.  A
file-level property governs calls from anywhere in the notebook; a
heading's own property governs calls made with point inside its
subtree, and subtrees that set none inherit the nearest ancestor's
value and ultimately the file-level one.  The rule wizard always
writes at file level.")

(defun gptel-permit--notebook-org-file-level-search ()
  "Find the file-level `GPTEL_PERMIT_RULES' property line, or nil.
Returns (VALUE-STRING . LINE-START).  This is the lookup
`org-entry-get' cannot do: it misses a properties drawer that follows
a keyword line such as `#+TITLE:' (verified on this Emacs), so the
value of the first property line before the first headline is found
by a direct search instead.  Widened and point-independent."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (unless (org-at-heading-p)
        (outline-next-heading))
      (let ((limit (line-beginning-position)))
        (goto-char (point-min))
        (when (re-search-forward
               (format "^[ \t]*:%s:[ \t]*\\(.*?\\)[ \t]*$" gptel-permit--notebook-org-property)
               limit t)
          (cons (match-string-no-properties 1)
                (line-beginning-position)))))))

(defun gptel-permit--notebook-org-file-level-value ()
  "The file-level `GPTEL_PERMIT_RULES' value string, or nil.
See `gptel-permit--notebook-org-file-level-search'."
  (car (gptel-permit--notebook-org-file-level-search)))

(defun gptel-permit--notebook-org-file-level-line ()
  "The line-start position of the file-level `GPTEL_PERMIT_RULES'
property line, or nil.  The notebook writer's in-place branch
rewrites from here."
  (cdr (gptel-permit--notebook-org-file-level-search)))

(defun gptel-permit--notebook-org-entry-source ()
  "Return (VALUE-STRING . HEADING) of the `GPTEL_PERMIT_RULES' value
governing the entry under point, or nil.
With inheritance t, the value of the entry under point or of its
nearest ancestor heading wins — that is where per-heading rules come
from.  When a value is found this way, HEADING names the heading
whose property supplied it (per `org-entry-property-inherited-from')."
  (org-with-wide-buffer
   (when-let* ((value (org-entry-get (point) gptel-permit--notebook-org-property t)))
     (let ((from (and (markerp org-entry-property-inherited-from)
                      (marker-position org-entry-property-inherited-from))))
       (cons value
             (or (when from
                   (save-excursion
                     (goto-char from)
                     (org-get-heading t t t t)))
                 (org-get-heading t t t t)))))))

(defun gptel-permit--notebook-normalize-rules (value)
  "Return the rule list of a read notebook VALUE.
A cons whose car is a keyword is a single rule and is wrapped; nil
and other non-cons values yield no rules.  A value shaped like a list
of rules is returned as-is — per-rule shape checking is the
validation pass, not this normalizer's job."
  (when (consp value)
    (if (keywordp (car value))
        (list value)
      value)))

(defun gptel-permit--read-notebook-org-rules ()
  "The Org branch of the notebook reader (see `gptel-permit--read-notebook-rules').
When the entry under point supplies no value, the file-level property
applies (`gptel-permit--notebook-org-file-level-value'), because
`org-entry-get' misses a file-level drawer that follows a keyword
line.  The property value is read with `read' — not caught: an
unreadable or unbalanced value propagates into the engine's
fail-closed `condition-case'.  Rules are validated as data and
attested with an origin naming the notebook and the heading or file
level the rules came from."
  (let* ((entry (gptel-permit--notebook-org-entry-source))
         (value (or (car entry)
                    (gptel-permit--notebook-org-file-level-value)))
         (heading (or (and entry (cdr entry)) "file level")))
    (when value
      (gptel-permit--validate-origin-rules
       (let ((read-circle nil))
         (gptel-permit--notebook-normalize-rules (read value)))
       'notebook
       (list :scope 'notebook :file (buffer-file-name) :heading heading)))))

(defun gptel-permit--read-notebook-markdown-rules ()
  "The markdown/text branch of the notebook reader (see
`gptel-permit--read-notebook-rules').
The rules are the `gptel-permit-notebook-rules' file-local variable,
applied by Emacs on visit; nil when it was never set (e.g. with
`enable-local-variables' nil).  Rules are validated as data and
attested with an origin naming the notebook file."
  (when (listp gptel-permit-notebook-rules)
    (gptel-permit--validate-origin-rules
     gptel-permit-notebook-rules
     'notebook
     (list :scope 'notebook :file (buffer-file-name)))))

(defun gptel-permit--read-notebook-rules ()
  "Notebook-scope `:reader' (see `gptel-permit-rule-scopes').
Returns the rules stored in the current notebook, or nil when the
scope has no storage here — no `GPTEL_PERMIT_RULES' property under
point nor at file level in an Org notebook, no
`gptel-permit-notebook-rules' file-local variable otherwise.

In an Org notebook the value of the entry under point or its nearest
ancestor heading wins (per-heading rules), and otherwise the
file-level property applies — looked up explicitly, because
`org-entry-get' misses a drawer that follows a keyword line such as
`#+TITLE:'.  Unreadable property values are not caught: they
propagate into `gptel-permit--apply-rules', which fails the call
closed.

Every returned rule is validated as data, not code
(`gptel-permit--valid-persisted-rule-p', skipping and logging invalid
shapes) and carries an `:origin' naming the notebook and — in Org —
the heading or file level the rule came from."
  (cond
   ((not (derived-mode-p 'org-mode))
    (gptel-permit--read-notebook-markdown-rules))
   ((require 'org nil t)
    (gptel-permit--read-notebook-org-rules))
   (t nil)))

(defun gptel-permit--notebook-org-merged-value (rule)
  "Return the printed file-level property value with RULE appended.
The merged list is built from the FILE-level value alone — never the
reader's full value, which may be a heading override — so a heading's
own rules are neither copied into the notebook-wide list nor silently
promoted.  Every rule's `:origin' fields are stripped: origins never
persist."
  (let ((existing
         (when-let* ((value-string (gptel-permit--notebook-org-file-level-value)))
           ;; Read the stored form (an error here means the value cannot
           ;; be merged either and will fail the write into the wizard's
           ;; session fallback — fail-closed, never lost or corrupted).
           (let ((read-circle nil))
             (gptel-permit--notebook-normalize-rules
              (read value-string))))))
    (prin1-to-string
     (mapcar #'gptel-permit--strip-origin (append existing (list rule))))))

(defun gptel-permit--write-notebook-org (rule)
  "Write RULE into the current Org notebook's file-level rules.
An existing file-level `GPTEL_PERMIT_RULES' property line is replaced
in place — `org-entry-put' at `point-min' would create a SECOND
property block when the existing drawer follows a keyword line, so
the line is edited by search position instead.  With no file-level
line yet, the drawer is stored with `org-entry-put' at `point-min'
after gptel's own `org-open-line' dance (which applies when the
notebook starts with a heading).  A heading's own property is never
touched and the buffer is not saved."
  (require 'org)
  (let ((value (gptel-permit--notebook-org-merged-value rule))
        (line (gptel-permit--notebook-org-file-level-line)))
    (save-excursion
      (save-restriction
        (widen)
        (let ((inhibit-read-only t))
          (if line
              (save-excursion
                (goto-char line)
                (delete-region (line-beginning-position)
                               (if (< (line-end-position) (point-max))
                                   (1+ (line-end-position))
                                 (line-end-position)))
                (insert (format "  :%s: %s\n"
                                gptel-permit--notebook-org-property value)))
            (goto-char (point-min))
            (when (org-at-heading-p)
              (org-open-line 1))
            (org-entry-put (point-min)
                           gptel-permit--notebook-org-property value)))))))

(defun gptel-permit--write-notebook-rule (rule)
  "Notebook-scope `:writer' (see `gptel-permit-rule-scopes').
Persists the created RULE into the current notebook's file-level
storage, in the notebook's own format: the `GPTEL_PERMIT_RULES'
property in an Org notebook (`gptel-permit--write-notebook-org'), the
`gptel-permit-notebook-rules' file-local variable elsewhere —
written with `add-file-local-variable' and set buffer-locally so the
next call in this session already sees it.  The buffer is never
saved.  An Org-not-found failure signals; the wizard catches errors
and keeps a session copy."
  (if (derived-mode-p 'org-mode)
      (gptel-permit--write-notebook-org rule)
    (let ((rules (mapcar #'gptel-permit--strip-origin
                         (append (gptel-permit--notebook-normalize-rules
                                  gptel-permit-notebook-rules)
                                 (list rule)))))
      (add-file-local-variable 'gptel-permit-notebook-rules rules)
      (setq-local gptel-permit-notebook-rules rules)
      rule)))

(defun gptel-permit--scoped-rules ()
  "Return every collected rule as (RULE . SCOPE), in registry order.
One walk over `gptel-permit-rule-scopes': the scope's `:reader' is
called with no arguments in the session buffer — which is already the
notebook buffer, since gptel runs the pre-tool hook inside
`with-current-buffer' — and each returned rule is paired with its
scope.  Readers are called in registry order, most specific first.

Every returned rule carries an `:origin' plist attested by whoever
read it: the notebook and project readers attach their own (naming
the store file and, in Org, the heading or the file level), and the
collector attaches a bare (:scope session) / (:scope global) to the
un-attested rules the trivial session and global readers return.  A
scope in the registry whose reader returns un-attested rules gets a
bare (:scope SCOPE) origin from the collector as well.

Origins are inert during matching — matching reads only a rule's own
keys — are stripped by every writer before persisting, and are never
read by analytics, which keeps its coarse scope field.  Reader errors
are deliberately NOT caught here: they propagate into
`gptel-permit--apply-rules', which fails the call closed."
  (apply #'append
         (mapcar
          (lambda (entry)
            (pcase-let ((`(,scope . ,spec) entry))
              (mapcar (lambda (rule)
                        (cons (gptel-permit--ensure-origin rule scope)
                              scope))
                      (funcall (plist-get spec :reader)))))
          gptel-permit-rule-scopes)))

(defun gptel-permit--find-action (id tool-call)
  "Return (RULE . SCOPE) for the first matching rule, or nil.
ID is the tool-call id.  Rules come from `gptel-permit--scoped-rules'
— the scopes of `gptel-permit-rule-scopes', most specific first — and
first match wins; no further rules are evaluated after a match.

A :rule-match event is emitted through `gptel-permit--emit-event' at
the moment the match is decided: on the first matching rule (after the
enriched TOOL-CALL has been annotated with the matching scope,
:rule-scope, and the rule's reader-attested origin, :rule-origin), or
once with nil action after all scopes' rules failed.  The emission
point stays inside the loop; callers that read the annotations see
them on the same plist object they passed in."
  (catch 'found
    (dolist (scoped (gptel-permit--scoped-rules))
      (let ((rule (car scoped)))
        (when-let* ((action (gptel-permit--match-rule-p rule tool-call)))
          (setq tool-call
                (plist-put tool-call :rule-scope (cdr scoped))
                tool-call
                (plist-put tool-call :rule-origin (plist-get rule :origin)))
          (gptel-permit--log "Matched rule: action=%s %s"
                             action
                             (gptel-permit--format-origin
                              (plist-get rule :origin)))
          (gptel-permit--emit-event id tool-call :rule-match action)
          (throw 'found scoped))))
    (gptel-permit--emit-event id tool-call :rule-match nil)
    nil))

(defun gptel-permit--apply-rules (tool-call)
  "Enforce permission rules for TOOL-CALL.
Rules are collected over the scopes of `gptel-permit-rule-scopes',
most specific first; first match wins.  A matched rule's :action
dispatches through `gptel-permit-action-handlers'; an action with no
registered handler fails closed with (:confirm t), so no unresolved
rule can silently auto-run a tool.  No match returns nil (defer).  On
unexpected error anywhere — including a scope reader that cannot read
its store — fail closed with (:confirm t).

Events: the call's tool-call id is minted
(`gptel-permit--mint-tool-call-id') and the call's events are emitted
through `gptel-permit--emit-event' —
:tool-call, then :rule-match (from `gptel-permit--find-action'), then
:verdict, then :confirm when the final verdict asks.  When a rule
matched, the enriched call carries the matching scope `:rule-scope'
and the rule's origin `:rule-origin' from the match moment onward;
the payloads are unchanged.  Before matching,
`gptel-permit-before-rule-match-functions' runs; after the verdict,
`gptel-permit-veto-functions' is consulted: a non-nil veto upgrades
the verdict to (:confirm t), preserving any :args rewrite."
  (condition-case err
      (unless (gptel-permit--processed-p tool-call)
        (let* ((enriched (gptel-permit--enrich-tool-call tool-call))
               (id (gptel-permit--mint-tool-call-id))
               (name (plist-get enriched :name))
               (args (plist-get enriched :args))
               (trunc-args (cl-loop for (k v) on args by #'cddr
                                    collect k collect (gptel-permit--truncate-arg v))))
          (gptel-permit--log "Started rule checks for tool: %s with args: %S" name trunc-args)
          (gptel-permit--emit-event id enriched :tool-call nil)
          (run-hook-with-args
           'gptel-permit-before-rule-match-functions id enriched)
          (let* ((matched (gptel-permit--find-action id enriched))
                 (rule (car matched))
                 (action (and rule (plist-get rule :action)))
                 (handler (and action
                               (cdr (assq (if (consp action) (car action) action)
                                          gptel-permit-action-handlers))))
                 (verdict
                  (cond ((null action) nil)
                        ((null handler)
                         (gptel-permit--log
                          "No handler for action %S — failing closed" action)
                         (list :confirm t))
                        ((consp action)
                         (funcall handler id enriched (cdr action)))
                        (t (funcall handler id enriched)))))
            (gptel-permit--log "Verdict: %s" (or action "none (fallback)"))
            (gptel-permit--emit-event id enriched :verdict (cons action verdict))
            (when (and action
                       (run-hook-with-args-until-success
                        'gptel-permit-veto-functions id enriched verdict))
              (setq verdict
                    (if (plist-get verdict :args)
                        (list :confirm t :args (plist-get verdict :args))
                      (list :confirm t))))
            (when (and (consp verdict) (plist-get verdict :confirm))
              (gptel-permit--emit-event id enriched :confirm nil))
            verdict)))
    (error
     (gptel-permit--log "Error in --apply-rules: %S — failing closed" err)
     (list :confirm t))))

;;;###autoload
(defun gptel-permit--scope-writer (scope)
  "Return the `:writer' of SCOPE in `gptel-permit-rule-scopes', or nil."
  (plist-get (cdr (assq scope gptel-permit-rule-scopes)) :writer))

(defun gptel-permit--wizard-read-scope ()
  "Ask for the scope to store the rule being created in.
The prompt offers the scopes of `gptel-permit-rule-scopes' in their
configuration order — a scope whose entry was removed is not offered —
and defaults to `session'.

This is the wizard's last question, after the tool target, the
conditions and the action.  Answering the default keeps the previous
behavior exactly: the rule goes into `gptel-permit-rules' and the
pending calls are resolved as before."
  (intern (completing-read "Store rule in scope: "
                           (mapcar #'car gptel-permit-rule-scopes)
                           nil t nil nil "session")))

(defun gptel-permit--store-and-resolve (rule scope tool-calls ov)
  "Store the wizard-created RULE into SCOPE, then resolve the pending
TOOL-CALLS (dispatch overlay OV).
The scope answer only affects where the rule is stored, never the
resolution of the pending calls: they are accepted or rejected exactly
as for a session rule.

`session' keeps the previous behavior: the rule is pushed onto
`gptel-permit-rules'.  A non-session scope is stored through that
scope's registered `:writer' — and no session copy is pushed, so the
next calls' log lines and every analytics record report the scope the
user chose (a shadow copy would make every later call report scope
`session'; the pending calls resolve without re-running matching
anyway).  A writer failure is caught, logged and reported, and the
rule is pushed onto `gptel-permit-rules', so the user's decision is
not lost."
  (pcase scope
    (`session (push rule gptel-permit-rules))
    (_
     (condition-case err
         (funcall (gptel-permit--scope-writer scope) rule)
       (error
        (gptel-permit--log
         "Storing rule into %S failed: %S — keeping a session copy"
         scope err)
        (message "Could not store the rule in scope %s (%s) — kept for this session"
                 scope (error-message-string err))
        (push rule gptel-permit-rules)))))
  (gptel-permit--log "Resulting rule: %S (scope %S)" rule scope)
  (message "Rule added (%s): %S" scope rule)
  (pcase (plist-get rule :action)
    (`deny (when (fboundp 'gptel--reject-tool-calls)
             (gptel--reject-tool-calls tool-calls ov)))
    (_ (when (fboundp 'gptel--accept-tool-calls)
         (gptel--accept-tool-calls tool-calls ov)))))

(defun gptel-permit-add-rule (&optional tool-calls ov)
  "Create a rule interactively, then apply it to the TOOL-CALLS in the pack.
Called on a tool-call confirmation overlay (keybinding `C-c C-b').

The wizard asks for the tool target (concrete tool or its
`gptel-permit-tool-groups' group), the conditions, and the action —
then, as its last question, for the target scope among the scopes of
`gptel-permit-rule-scopes' (`gptel-permit--wizard-read-scope'),
defaulting to `session':
  - session :: the rule is pushed onto `gptel-permit-rules' — today's
    behavior; it governs this buffer only and dies with the buffer.
  - notebook :: persisted into the notebook's own file — the
    `GPTEL_PERMIT_RULES' property of an Org notebook, the
    `gptel-permit-notebook-rules' file-local variable of a markdown
    notebook — via the notebook scope's registered writer.
  - project :: appended to the project root's `.gptel-permit-rules'
    store (`gptel-permit--write-project-rule').
  - global :: persisted into `gptel-permit-global-rules' through the
    Customize machinery (`gptel-permit--write-global-rule').

A non-default answer stores the rule in that scope /only/ — it is not
duplicated into the session's rules, so the reported scope is the one
the user chose.  A storage failure is reported and keeps the rule in
effect for the session through `gptel-permit-rules'.  Either way the
pending TOOL-CALLS are accepted or rejected immediately per the rule's
action (`gptel-permit--store-and-resolve'), exactly as before."
  (interactive (pcase-let ((`(,resp . ,o) (get-char-property-and-overlay
                                           (point) 'gptel-tool)))
                 (list resp o)))
  (unless tool-calls
    ;; Fallback for interactive use outside the overlay, though normally called via keymap
    (user-error "No tool-calls provided to create a rule for"))
  (let* ((normalized-tool-calls (mapcar #'gptel-permit--normalize-tool-call tool-calls)))
    (gptel-permit--log "Started rule addition. Active tool calls: %S"
                       (mapcar (lambda (tc) (plist-get tc :name)) normalized-tool-calls))
    (let* ((tool-call (car normalized-tool-calls))
           (enriched (gptel-permit--enrich-tool-call tool-call))
           (name (plist-get enriched :name))
           (args (plist-get enriched :args))
           (tool-group (plist-get enriched :tool-group))
           (arg-groups (plist-get enriched :arg-groups))
           (rule (list))
           (conditions nil))
      (gptel-permit--log "Using tool call: %s (group: %s). Args found: %S. Arg groups: %S"
                         name tool-group
                         (cl-loop for (k v) on args by #'cddr collect k
                                  collect (gptel-permit--truncate-arg v)) arg-groups)
      (if (and tool-group
               (y-or-n-p (format "Tool '%s' belongs to group '%s'. Target the entire group?"
                                 name tool-group)))
          (setq rule (plist-put rule :tool-group tool-group))
        (setq rule (plist-put rule :tool name)))
      (catch 'done
        (while t
          (let* ((arg-keys (cl-loop for (k _v) on args by #'cddr collect (symbol-name k)))
                 (path-spec-args (gptel-permit--tool-path-args name arg-groups))
                 (all-possible-args (cl-delete-duplicates
                                     (append arg-keys path-spec-args)
                                     :test #'string=))
                 (choices (append all-possible-args '("DONE")))
                 (choice (completing-read "Select argument to match (or DONE): " choices)))
            (if (string= choice "DONE")
                (throw 'done t)
              (let* ((arg-kw (intern choice))
                     (arg-val (plist-get args arg-kw))
                     (arg-group (alist-get arg-kw arg-groups))
                     (target arg-kw))
                (when (and arg-group
                           (y-or-n-p (format "Argument '%s' belongs to group '%s'. Target the entire group?" choice arg-group)))
                  (setq target arg-group))
                (let* ((is-path (or (eq target 'path) (gptel-permit--path-arg-p arg-kw arg-groups)))
                       (effective-val (if is-path
                                          (expand-file-name (or arg-val ""))
                                        arg-val))
                       (default-re (if effective-val (format "^%s$" (regexp-quote (format "%s" effective-val))) ""))
                       (re (read-string (format "Regexp for %s: " target) default-re)))
                  (push (cons target re) conditions)
                  (gptel-permit--log "Added condition: %s matches %S" target re)))))))
      (setq rule (plist-put rule :conditions (nreverse conditions)))
      (let ((action (intern (completing-read "Action: " '("allow" "ask" "deny") nil t))))
        (setq rule (plist-put rule :action action))
        ;; The rule is complete; the scope question is the wizard's
        ;; last question (`gptel-permit--wizard-read-scope'), and its
        ;; default keeps previous behavior exactly.
        (gptel-permit--store-and-resolve
         rule (gptel-permit--wizard-read-scope) tool-calls ov)))))

;;;###autoload
(define-minor-mode gptel-permit-mode
  "Minor mode for rule-based tool-call permissions in gptel.
When enabled, registers validation and permission hooks on
`gptel-pre-tool-call-functions' and binds `C-c C-b' in
`gptel-tool-call-actions-map' for interactive rule creation.
Optional modules integrate through the core's extension points (see
`gptel-permit-action-handlers' and the engine hooks), not through this
mode."
  :global t
  :lighter " Permit"
  (if gptel-permit-mode
      (progn
        (add-hook 'gptel-pre-tool-call-functions #'gptel-permit--validate-args t)
        (add-hook 'gptel-pre-tool-call-functions #'gptel-permit--apply-rules t)
        (keymap-set gptel-tool-call-actions-map "C-c C-b" #'gptel-permit-add-rule))
    (remove-hook 'gptel-pre-tool-call-functions #'gptel-permit--validate-args)
    (remove-hook 'gptel-pre-tool-call-functions #'gptel-permit--apply-rules)
    (keymap-unset gptel-tool-call-actions-map "C-c C-b")))

(provide 'gptel-permit)
;;; gptel-permit.el ends here
