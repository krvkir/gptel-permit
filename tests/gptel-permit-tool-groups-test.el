;;; gptel-permit-tool-groups-test.el --- Tests for tool/arg group mapping -*- lexical-binding: t; -*-

(require 'ert)
(require 'gptel-permit)

;; -------------------------------------------------------------------
;; Tool-group and arg-group resolution
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-tool-groups-mapping-defaults ()
  "Default tool-group mapping covers known gptel-agent tools."
  (should gptel-permit-tool-groups)
  ;; Read, Glob, Grep → "read" group
  (should (equal (gptel-permit--resolve-tool-group "Read") 'read))
  (should (equal (gptel-permit--resolve-tool-group "Glob") 'read))
  (should (equal (gptel-permit--resolve-tool-group "Grep") 'read))
  ;; Write, Edit, Insert, Mkdir → "write" group
  (should (equal (gptel-permit--resolve-tool-group "Write") 'write))
  (should (equal (gptel-permit--resolve-tool-group "Edit") 'write))
  (should (equal (gptel-permit--resolve-tool-group "Insert") 'write))
  (should (equal (gptel-permit--resolve-tool-group "Mkdir") 'write))
  ;; Bash → "execute" group
  (should (equal (gptel-permit--resolve-tool-group "Bash") 'execute)))

(ert-deftest gptel-permit-tool-groups-unknown-tool ()
  "Unknown tool returns nil for tool-group."
  (should (null (gptel-permit--resolve-tool-group "InventedTool"))))

(ert-deftest gptel-permit-tool-groups-arg-resolution ()
  "Arg-group resolution maps argument keys correctly."
  ;; Read: :file_path → path
  (let ((groups (gptel-permit--resolve-arg-groups "Read")))
    (should (equal (alist-get :file_path groups) 'path)))
  ;; Write: :filename → path, :path → path
  (let ((groups (gptel-permit--resolve-arg-groups "Write")))
    (should (equal (alist-get :filename groups) 'path))
    (should (equal (alist-get :path groups) 'path)))
  ;; Mkdir: :parent → path
  (let ((groups (gptel-permit--resolve-arg-groups "Mkdir")))
    (should (equal (alist-get :parent groups) 'path))))

(ert-deftest gptel-permit-tool-groups-arg-no-group ()
  "Argument without a group mapping returns nil; code args map to code."
  (let ((groups (gptel-permit--resolve-arg-groups "Read")))
    (should (null (alist-get :start_line groups))))
  ;; :command and :expression belong to the `code' arg-group (matched raw,
  ;; no path expansion).
  (let ((groups (gptel-permit--resolve-arg-groups "Bash")))
    (should (equal (alist-get :command groups) 'code)))
  (let ((groups (gptel-permit--resolve-arg-groups "Eval")))
    (should (equal (alist-get :expression groups) 'code))))



(ert-deftest gptel-permit-tool-groups-user-extension ()
  "User can add custom tools to the mapping."
  (let ((gptel-permit-tool-groups
         (cons '("UploadFile" :tool-group upload :arg-groups ((:target_path . path) (:content . body)))
               gptel-permit-tool-groups)))
    (should (equal (gptel-permit--resolve-tool-group "UploadFile") 'upload))
    (let ((groups (gptel-permit--resolve-arg-groups "UploadFile")))
      (should (equal (alist-get :target_path groups) 'path))
      (should (equal (alist-get :content groups) 'body)))))

(ert-deftest gptel-permit-tool-groups-missing-tool-group ()
  "A tool with no :tool-group in the mapping returns nil for tool-group."
  (let ((gptel-permit-tool-groups
         (cons '("HeadlessTool" :arg-groups ((:data . payload)))
               gptel-permit-tool-groups)))
    (should (null (gptel-permit--resolve-tool-group "HeadlessTool")))
    ;; But arg-groups still work
    (let ((groups (gptel-permit--resolve-arg-groups "HeadlessTool")))
      (should (equal (alist-get :data groups) 'payload)))))

(provide 'gptel-permit-tool-groups-test)
;;; gptel-permit-tool-groups-test.el ends here
