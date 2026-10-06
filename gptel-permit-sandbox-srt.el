;;; gptel-permit-sandbox-srt.el --- Anthropic sandbox-runtime backend -*- lexical-binding: t; -*-

;; Copyright (C) 2026 krvkir

;; Author: krvkir <krvkir@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9") (gptel-permit "0.1.0"))
;; Keywords: convenience, tools, agents, security
;; URL: https://github.com/krvkir/gptel-permit

;; This file is NOT part of GNU Emacs.

;;; Commentary:
;; The Anthropic sandbox-runtime (srt) backend for gptel-permit's
;; `sandbox' rule action: gptel-permit's defcustoms are mapped to srt's
;; settings JSON and commands run as `srt --settings FILE bash -c QUOTED'.
;; Requires the srt binary (on Linux, also node, socat and ripgrep for
;; its network proxy layer).  Ships documented-but-untested.
;;
;; This module self-registers at load (`srt' in
;; `gptel-permit-sandbox-backends'); the sandbox core loads it lazily on
;; first use, or earlier if you `(require 'gptel-permit-sandbox-srt)'.

;;; Code:

(require 'json)
(require 'gptel-permit-sandbox)

(defclass gptel-permit-sandbox-backend-srt
  (gptel-permit-sandbox-backend-base) ()
  "Anthropic sandbox-runtime backend.
Maps the writable/protected/domain defcustoms to srt's settings file.
SECURITY-RELEVANT: the wrap method's output runs without further
confirmation.")

(defcustom gptel-permit-sandbox-allowed-domains nil
  "Network domains allowed in the srt backend, mapped to
`network.allowedDomains'.  Ignored by the bwrap backend."
  :type '(repeat string)
  :group 'gptel-permit-sandbox)

(cl-defmethod gptel-permit-sandbox-available-p
  ((_ gptel-permit-sandbox-backend-srt))
  "Non-nil when the srt binary is on exec-path (any platform)."
  (gptel-permit-sandbox--resolve-binary "srt"))

(defun gptel-permit-sandbox--settings-json (&optional root)
  "Return the srt settings JSON string for the current config.
ROOT is the project root used when writable dirs are unset.  Writable
dirs map to filesystem.allowWrite, protected paths to filesystem
denyRead/denyWrite, allowed domains to network.allowedDomains.  Values
are used as given (srt resolves ~ itself)."
  (let* ((protected (gptel-permit--sandbox-protected-paths root))
         (writable (gptel-permit-sandbox--writable-dirs root)))
    (json-encode
     `((filesystem . ((allowWrite . ,(vconcat writable))
                      (denyRead . ,(vconcat protected))
                      (denyWrite . ,(vconcat protected))))
       (network . ((allowedDomains
                    . ,(vconcat (or gptel-permit-sandbox-allowed-domains
                                    '())))))))))

(defun gptel-permit-sandbox--write-settings (&optional root)
  "Write the srt settings JSON to a cache file; return its path."
  (let ((file (expand-file-name "gptel-permit-srt-settings.json"
                                temporary-file-directory)))
    (with-temp-file file
      (insert (gptel-permit-sandbox--settings-json root)))
    file))

(cl-defmethod gptel-permit-sandbox-wrap
  ((_ gptel-permit-sandbox-backend-srt) command root)
  "Wrap COMMAND as `srt --settings FILE bash -c QUOTED' (project ROOT)."
  (let ((file (gptel-permit-sandbox--write-settings root)))
    (mapconcat #'gptel-permit-sandbox--argv-elt
               (list "srt" "--settings" file
                     "bash" "-c"
                     (gptel-permit-sandbox--posix-quote command))
               " ")))

(add-to-list 'gptel-permit-sandbox-backends
             '(srt . gptel-permit-sandbox-backend-srt))

(provide 'gptel-permit-sandbox-srt)
;;; gptel-permit-sandbox-srt.el ends here
