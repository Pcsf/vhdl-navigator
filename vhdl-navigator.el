;;; vhdl-navigator.el --- VHDL record visualizer & go-to-definition -*- lexical-binding: t; -*-

;; Author: Paulo (generated with Claude)
;; Version: 0.3.0
;; Package-Requires: ((emacs "28.1") (project "0.9"))
;; Keywords: languages, vhdl, navigation, completion
;; URL: https://github.com/your-user/vhdl-navigator

;;; Commentary:
;;
;; A lightweight VHDL navigation package providing:
;;
;;   1. Dot-completion for record fields (capf-based, works with Corfu/Vertico)
;;   2. Go-to-definition via xref (M-. or gd in Evil) for:
;;      - Record types and their fields
;;      - Entity and architecture declarations
;;      - Signal, constant, and variable declarations
;;      - Function, procedure, and package declarations
;;   3. Eldoc integration showing record field types in the minibuffer
;;   4. Project-wide indexing with automatic cache invalidation
;;
;; Designed for Gaisler two-process VHDL style where records are pervasive.

;;; Code:

(require 'cl-lib)
(require 'xref)
(require 'project)
(require 'seq)

;; ---------------------------------------------------------------------------
;; Customization
;; ---------------------------------------------------------------------------

(defgroup vhdl-navigator nil
  "VHDL record visualizer and go-to-definition."
  :group 'languages
  :prefix "vhdl-nav-")

(defcustom vhdl-nav-file-extensions '("vhd" "vhdl")
  "File extensions to scan for VHDL definitions."
  :type '(repeat string)
  :group 'vhdl-navigator)

(defcustom vhdl-nav-auto-reindex-on-save t
  "When non-nil, re-index the saved file automatically on save."
  :type 'boolean
  :group 'vhdl-navigator)

(defcustom vhdl-nav-completion-annotation t
  "When non-nil, show type annotations in completion candidates."
  :type 'boolean
  :group 'vhdl-navigator)

(defcustom vhdl-nav-debug nil
  "When non-nil, log detailed parse information to *Messages*."
  :type 'boolean
  :group 'vhdl-navigator)

(defcustom vhdl-nav-index-batch-size 20
  "Number of files to parse per idle cycle during async indexing.
Larger values finish faster but may cause brief UI pauses.
Set to 0 to use synchronous (blocking) indexing."
  :type 'integer
  :group 'vhdl-navigator)

(defcustom vhdl-nav-cache-directory
  (expand-file-name "vhdl-navigator/" user-emacs-directory)
  "Directory for persistent index cache files.
Each project gets its own cache file (named by MD5 of root path).
Set to nil to disable persistent caching."
  :type '(choice directory (const nil))
  :group 'vhdl-navigator)

(defcustom vhdl-nav-startup-check t
  "When non-nil, verify cache freshness during idle time on startup.
The check runs asynchronously after the cache is already loaded and
active, so Emacs never blocks.  Set to nil to skip it entirely and
rely solely on file-notification events and `after-save-hook' for
index updates — useful on network-mounted file-systems where even an
idle-time scan is undesirably slow."
  :type 'boolean
  :group 'vhdl-navigator)

;; ---------------------------------------------------------------------------
;; Internal data structures
;; ---------------------------------------------------------------------------

(cl-defstruct (vhdl-nav-def (:constructor vhdl-nav-def-create))
  "A VHDL definition entry."
  name          ; symbol name (downcased)
  kind          ; one of: record field entity architecture signal
                ;         constant variable function procedure package type
  type-name     ; type string
  parent        ; parent record name for fields, entity for architectures
  file          ; absolute file path
  line          ; line number (1-based)
  fields        ; for records: list of (field-name . type-string)
  extra)        ; alist for misc metadata

;; Per-project index
(defvar vhdl-nav--project-indices (make-hash-table :test 'equal)
  "Cache mapping project root to VHDL definition index.")

;; Per-project file mtimes
(defvar vhdl-nav--file-mtimes (make-hash-table :test 'equal)
  "Cache mapping project root to (file -> mtime) hash-table.")

;; Async indexing state
(defvar vhdl-nav--async-timer nil
  "Idle timer for async indexing, or nil when not indexing.")

(defvar vhdl-nav--async-queue nil
  "List of files remaining to be parsed in the current async run.")

(defvar vhdl-nav--async-root nil
  "Project root for the current async indexing run.")

(defvar vhdl-nav--async-total 0
  "Total number of files in the current async run (for progress).")

(defvar vhdl-nav--async-count 0
  "Number of definitions found so far in the current async run.")

;; Per-project file-system watchers (filenotify)
(defvar vhdl-nav--watchers (make-hash-table :test 'equal)
  "Map from project root to list of filenotify watch descriptors.")

(defvar vhdl-nav--watcher-debounces (make-hash-table :test 'equal)
  "Map from project root to per-project debounce timer for file events.")

(defvar vhdl-nav--watcher-queue (make-hash-table :test 'equal)
  "Map from project root to hash of file→action pairs pending processing.")

;; ---------------------------------------------------------------------------
;; Project root detection
;; ---------------------------------------------------------------------------

(defun vhdl-nav--project-root ()
  "Find the project root, falling back to default-directory."
  (or (when-let ((proj (project-current)))
        (if (fboundp 'project-root)
            (project-root proj)
          (car (project-roots proj))))
      (when (fboundp 'projectile-project-root)
        (projectile-project-root))
      default-directory))

;; ---------------------------------------------------------------------------
;; File discovery
;; ---------------------------------------------------------------------------

(defun vhdl-nav--find-vhdl-files (root)
  "Find all VHDL files under ROOT."
  (when (and root (stringp root) (file-directory-p root))
    (let ((re (concat "\\." (regexp-opt vhdl-nav-file-extensions) "\\'")))
      (directory-files-recursively root re nil))))

;; ---------------------------------------------------------------------------
;; VHDL Parsing -- plain regex strings, NO rx macros
;; ---------------------------------------------------------------------------

(defconst vhdl-nav--re-record
  "^[ \t]*type[ \t]+\\([A-Za-z0-9_]+\\)[ \t]+is[ \t]+record"
  "Match: type NAME is record.  Group 1 = type name.")

(defconst vhdl-nav--re-record-field
  "^[ \t]*\\([A-Za-z][A-Za-z0-9_]*\\)[ \t]*:[ \t]*\\(.+\\);"
  "Match: FIELD : TYPE;  Group 1 = field name, Group 2 = type (includes trailing spaces).")

(defconst vhdl-nav--re-end-record
  "^[ \t]*end[ \t]+record"
  "Match: end record")

(defconst vhdl-nav--re-entity
  "^[ \t]*entity[ \t]+\\([A-Za-z0-9_]+\\)[ \t]+is"
  "Match: entity NAME is.  Group 1 = entity name.")

(defconst vhdl-nav--re-architecture
  "^[ \t]*architecture[ \t]+\\([A-Za-z0-9_]+\\)[ \t]+of[ \t]+\\([A-Za-z0-9_]+\\)[ \t]+is"
  "Match: architecture NAME of ENTITY is.  Groups 1,2.")

(defconst vhdl-nav--re-signal
  "^[ \t]*signal[ \t]+\\([^:]+\\):[ \t]*\\([^;:]+\\)"
  "Match: signal NAMES : TYPE.  Groups 1,2.")

(defconst vhdl-nav--re-constant
  "^[ \t]*constant[ \t]+\\([A-Za-z0-9_]+\\)[ \t]*:[ \t]*\\([^;:]+\\)"
  "Match: constant NAME : TYPE.  Groups 1,2.")

(defconst vhdl-nav--re-variable
  "^[ \t]*\\(?:shared[ \t]+\\)?variable[ \t]+\\([^:]+\\):[ \t]*\\([^;:]+\\)"
  "Match: [shared] variable NAMES : TYPE.  Groups 1,2.")

(defconst vhdl-nav--re-function
  "^[ \t]*\\(?:pure[ \t]+\\|impure[ \t]+\\)?function[ \t]+\\([A-Za-z0-9_]+\\)"
  "Match: [pure|impure] function NAME.  Group 1.")

(defconst vhdl-nav--re-procedure
  "^[ \t]*procedure[ \t]+\\([A-Za-z0-9_]+\\)"
  "Match: procedure NAME.  Group 1.")

(defconst vhdl-nav--re-package
  "^[ \t]*package[ \t]+\\([A-Za-z0-9_]+\\)[ \t]+is"
  "Match: package NAME is.  Group 1.")

(defconst vhdl-nav--re-package-body
  "^[ \t]*package[ \t]+body[ \t]"
  "Match: package body.")

(defconst vhdl-nav--re-type-alias
  "^[ \t]*\\(?:type\\|subtype\\)[ \t]+\\([A-Za-z0-9_]+\\)[ \t]+is[ \t]+\\(.+\\);"
  "Match: type/subtype NAME is DEF;  Groups 1,2.")

;; ---------------------------------------------------------------------------
;; Safe string helpers
;; ---------------------------------------------------------------------------

(defsubst vhdl-nav--safe-match (n s)
  "Return match group N from string S, or nil.  Never signals."
  (ignore-errors (when (stringp s) (match-string n s))))

(defsubst vhdl-nav--strim (s)
  "Trim whitespace from S.  Returns empty string if S is nil."
  (if (stringp s) (string-trim s) ""))

(defun vhdl-nav--split-names (s)
  "Split comma-separated names string S into list of trimmed non-empty names."
  (when (stringp s)
    (let ((parts (split-string s ",")))
      (seq-filter (lambda (x) (> (length x) 0))
                  (mapcar #'string-trim parts)))))

;; ---------------------------------------------------------------------------
;; File parser
;; ---------------------------------------------------------------------------

(defun vhdl-nav--read-lines (filepath)
  "Read FILEPATH and return a list of clean line strings.
Handles Windows/Unix line endings.  Never signals."
  (condition-case err
      (with-temp-buffer
        (insert-file-contents filepath)
        ;; Kill all carriage returns
        (goto-char (point-min))
        (while (search-forward "\r" nil t)
          (replace-match "" nil t))
        ;; Collect lines
        (goto-char (point-min))
        (let ((lines '()))
          (while (not (eobp))
            (push (buffer-substring-no-properties
                   (line-beginning-position) (line-end-position))
                  lines)
            (forward-line 1))
          (nreverse lines)))
    (error
     (message "vhdl-navigator: cannot read %s: %s" filepath err)
     nil)))

(defun vhdl-nav--parse-file (filepath)
  "Parse FILEPATH and return a list of vhdl-nav-def structs.
Never signals -- returns nil on any fatal error."
  (condition-case top-err
      (let* ((raw-lines (vhdl-nav--read-lines filepath))
             (defs '())
             (in-record nil)
             (record-name nil)
             (record-line nil)
             (record-fields '())
             (line-num 0))
        (unless raw-lines
          (message "vhdl-navigator: no lines read from %s" filepath))
        (dolist (raw-line (or raw-lines '()))
          (setq line-num (1+ line-num))
          (let* ((line (if (stringp raw-line) raw-line ""))
                 (trimmed (string-trim line)))

            ;; Skip blanks and comments
            (when (and (> (length trimmed) 0)
                       (not (string-prefix-p "--" trimmed)))
              (let ((ll (downcase line)))

                (condition-case line-err
                    (cond
                     ;; --- Inside record ---
                     (in-record
                      (cond
                       ;; end record
                       ((string-match-p vhdl-nav--re-end-record ll)
                        (push (vhdl-nav-def-create
                               :name record-name
                               :kind 'record
                               :file filepath
                               :line record-line
                               :fields (nreverse record-fields))
                              defs)
                        (when vhdl-nav-debug
                          (message "  [rec] %s %d fields" record-name (length record-fields)))
                        (setq in-record nil record-name nil record-fields nil))

                       ;; field line
                       ((string-match vhdl-nav--re-record-field ll)
                        (let ((fname (vhdl-nav--safe-match 1 ll))
                              (ftype (vhdl-nav--strim (vhdl-nav--safe-match 2 ll))))
                          (when (and (stringp fname) (> (length fname) 0))
                            (push (cons fname ftype) record-fields)
                            (push (vhdl-nav-def-create
                                   :name (downcase fname)
                                   :kind 'field
                                   :type-name ftype
                                   :parent record-name
                                   :file filepath
                                   :line line-num)
                                  defs))))))

                     ;; --- Record start ---
                     ((string-match vhdl-nav--re-record ll)
                      (let ((rn (vhdl-nav--safe-match 1 ll)))
                        (when (and (stringp rn) (> (length rn) 0))
                          (setq in-record t
                                record-name (downcase rn)
                                record-line line-num
                                record-fields nil)
                          (when vhdl-nav-debug
                            (message "  [rec-start] %s L%d" rn line-num)))))

                     ;; --- Entity ---
                     ((string-match vhdl-nav--re-entity ll)
                      (let ((n (vhdl-nav--safe-match 1 ll)))
                        (when (and (stringp n) (> (length n) 0))
                          (push (vhdl-nav-def-create
                                 :name (downcase n) :kind 'entity
                                 :file filepath :line line-num)
                                defs))))

                     ;; --- Architecture ---
                     ((string-match vhdl-nav--re-architecture ll)
                      (let ((an (vhdl-nav--safe-match 1 ll))
                            (en (vhdl-nav--safe-match 2 ll)))
                        (when (and (stringp an) (stringp en)
                                   (> (length an) 0) (> (length en) 0))
                          (push (vhdl-nav-def-create
                                 :name (downcase an) :kind 'architecture
                                 :parent (downcase en)
                                 :file filepath :line line-num)
                                defs))))

                     ;; --- Package (not body) ---
                     ((and (string-match vhdl-nav--re-package ll)
                           (not (string-match-p vhdl-nav--re-package-body ll)))
                      ;; Re-match to restore match data
                      (when (string-match vhdl-nav--re-package ll)
                        (let ((n (vhdl-nav--safe-match 1 ll)))
                          (when (and (stringp n) (> (length n) 0))
                            (push (vhdl-nav-def-create
                                   :name (downcase n) :kind 'package
                                   :file filepath :line line-num)
                                  defs)))))

                     ;; --- Signal ---
                     ((string-match vhdl-nav--re-signal ll)
                      (let ((ns (vhdl-nav--safe-match 1 ll))
                            (ts (vhdl-nav--strim (vhdl-nav--safe-match 2 ll))))
                        (when (stringp ns)
                          (dolist (n (vhdl-nav--split-names ns))
                            (push (vhdl-nav-def-create
                                   :name (downcase n) :kind 'signal
                                   :type-name ts
                                   :file filepath :line line-num)
                                  defs)))))

                     ;; --- Constant ---
                     ((string-match vhdl-nav--re-constant ll)
                      (let ((n (vhdl-nav--safe-match 1 ll))
                            (ts (vhdl-nav--strim (vhdl-nav--safe-match 2 ll))))
                        (when (and (stringp n) (> (length n) 0))
                          (push (vhdl-nav-def-create
                                 :name (downcase n) :kind 'constant
                                 :type-name ts
                                 :file filepath :line line-num)
                                defs))))

                     ;; --- Variable ---
                     ((string-match vhdl-nav--re-variable ll)
                      (let ((ns (vhdl-nav--safe-match 1 ll))
                            (ts (vhdl-nav--strim (vhdl-nav--safe-match 2 ll))))
                        (when (stringp ns)
                          (dolist (n (vhdl-nav--split-names ns))
                            (push (vhdl-nav-def-create
                                   :name (downcase n) :kind 'variable
                                   :type-name ts
                                   :file filepath :line line-num)
                                  defs)))))

                     ;; --- Function ---
                     ((string-match vhdl-nav--re-function ll)
                      (let ((n (vhdl-nav--safe-match 1 ll)))
                        (when (and (stringp n) (> (length n) 0))
                          (push (vhdl-nav-def-create
                                 :name (downcase n) :kind 'function
                                 :file filepath :line line-num)
                                defs))))

                     ;; --- Procedure ---
                     ((string-match vhdl-nav--re-procedure ll)
                      (let ((n (vhdl-nav--safe-match 1 ll)))
                        (when (and (stringp n) (> (length n) 0))
                          (push (vhdl-nav-def-create
                                 :name (downcase n) :kind 'procedure
                                 :file filepath :line line-num)
                                defs))))

                     ;; --- Type/subtype (non-record) ---
                     ((and (string-match vhdl-nav--re-type-alias ll)
                           (not (string-match-p "\\brecord\\b" ll)))
                      (when (string-match vhdl-nav--re-type-alias ll)
                        (let ((n (vhdl-nav--safe-match 1 ll))
                              (td (vhdl-nav--strim (vhdl-nav--safe-match 2 ll))))
                          (when (and (stringp n) (> (length n) 0))
                            (push (vhdl-nav-def-create
                                   :name (downcase n) :kind 'type
                                   :type-name td
                                   :file filepath :line line-num)
                                  defs))))))

                  ;; Per-line error handler
                  (error
                   (message "vhdl-navigator: L%d error %s  line=[%.60s]"
                            line-num line-err trimmed)))))))
        (nreverse defs))

    ;; Top-level error handler
    (error
     (message "vhdl-navigator: FATAL parse error in %s: %s"
              (ignore-errors (file-name-nondirectory filepath))
              top-err)
     nil)))

;; ---------------------------------------------------------------------------
;; Persistent cache
;; ---------------------------------------------------------------------------

(defun vhdl-nav--cache-file (root)
  "Return the cache file path for project ROOT."
  (when vhdl-nav-cache-directory
    (expand-file-name (concat (md5 root) ".el")
                      vhdl-nav-cache-directory)))

(defun vhdl-nav--save-cache (root)
  "Save the index and mtimes for ROOT to disk."
  (condition-case err
      (let ((cache-file (vhdl-nav--cache-file root)))
        (when cache-file
          (let ((index (gethash root vhdl-nav--project-indices))
                (mtimes (gethash root vhdl-nav--file-mtimes)))
            (when (and index mtimes)
              (unless (file-directory-p vhdl-nav-cache-directory)
                (make-directory vhdl-nav-cache-directory t))
              ;; Convert index hash → alist of (name . list-of-defs)
              (let ((index-alist '())
                    (mtimes-alist '()))
                (maphash (lambda (k v) (push (cons k v) index-alist)) index)
                (maphash (lambda (k v) (push (cons k v) mtimes-alist)) mtimes)
                (with-temp-file cache-file
                  (let ((print-level nil)
                        (print-length nil))
                    (prin1 (list :version 2
                                 :root root
                                 :mtimes mtimes-alist
                                 :index index-alist)
                           (current-buffer))))
                (when vhdl-nav-debug
                  (message "vhdl-navigator: cache saved to %s" cache-file)))))))
    (error
     (message "vhdl-navigator: failed to save cache: %s" err))))

(defun vhdl-nav--load-cache (root)
  "Load cached index and mtimes for ROOT from disk.
Returns (index-hash . mtimes-hash) or nil if no valid cache."
  (condition-case err
      (let ((cache-file (vhdl-nav--cache-file root)))
        (when (and cache-file (file-exists-p cache-file))
          (let* ((data (with-temp-buffer
                         (insert-file-contents cache-file)
                         (read (current-buffer))))
                 (version (plist-get data :version))
                 (cached-root (plist-get data :root)))
            (when (and (eq version 2)
                       (equal cached-root root))
              (let ((index (make-hash-table :test 'equal))
                    (mtimes (make-hash-table :test 'equal))
                    (index-alist (plist-get data :index))
                    (mtimes-alist (plist-get data :mtimes)))
                (dolist (entry mtimes-alist)
                  (puthash (car entry) (cdr entry) mtimes))
                (dolist (entry index-alist)
                  (let ((name (car entry))
                        (defs (cdr entry)))
                    ;; Validate that all defs are proper structs
                    (when (cl-every #'vhdl-nav-def-p defs)
                      (puthash name defs index))))
                (when vhdl-nav-debug
                  (message "vhdl-navigator: cache loaded from %s" cache-file))
                (cons index mtimes))))))
    (error
     (message "vhdl-navigator: failed to load cache: %s" err)
     nil)))

(defun vhdl-nav--diff-files (root cached-mtimes)
  "Compare files on disk with CACHED-MTIMES for project ROOT.
Returns a plist (:stale FILES-TO-REPARSE :deleted FILES-TO-REMOVE)."
  (let ((disk-files (vhdl-nav--find-vhdl-files root))
        (stale '())
        (seen (make-hash-table :test 'equal)))
    ;; Find new or modified files
    (dolist (f disk-files)
      (puthash f t seen)
      (let ((cached-mtime (gethash f cached-mtimes))
            (current-mtime (ignore-errors
                             (float-time
                              (file-attribute-modification-time
                               (file-attributes f))))))
        (when (or (null cached-mtime)
                  (null current-mtime)
                  (/= cached-mtime current-mtime))
          (push f stale))))
    ;; Find deleted files (in cache but not on disk)
    (let ((deleted '()))
      (maphash (lambda (f _mtime)
                 (unless (gethash f seen)
                   (push f deleted)))
               cached-mtimes)
      (list :stale stale :deleted deleted))))

;; ---------------------------------------------------------------------------
;; File-system watcher (filenotify)
;; ---------------------------------------------------------------------------

(defun vhdl-nav--watcher-callback (root event)
  "Handle a filenotify EVENT belonging to project ROOT."
  (let* ((action (nth 1 event))
         (file   (nth 2 event))
         (file2  (nth 3 event))
         (vhd-re (concat "\\." (regexp-opt vhdl-nav-file-extensions t) "\\'")))
    (when (or (and (stringp file)  (string-match-p vhd-re file))
              (and (stringp file2) (string-match-p vhd-re file2)))
      (let ((queue (or (gethash root vhdl-nav--watcher-queue)
                       (let ((h (make-hash-table :test 'equal)))
                         (puthash root h vhdl-nav--watcher-queue)
                         h))))
        (pcase action
          ('deleted (puthash file  'deleted queue))
          ('renamed (puthash file  'deleted queue)
                    (when file2 (puthash file2 'changed queue)))
          (_        (puthash file  'changed queue))))
      ;; Per-project debounce: accumulate events then flush after 1 s of quiet
      (let ((existing (gethash root vhdl-nav--watcher-debounces)))
        (when existing (cancel-timer existing)))
      (puthash root
               (run-with-idle-timer 1.0 nil #'vhdl-nav--flush-watcher-queue root)
               vhdl-nav--watcher-debounces))))

(defun vhdl-nav--flush-watcher-queue (root)
  "Process all queued file-change events for project ROOT."
  (remhash root vhdl-nav--watcher-debounces)
  (let* ((queue  (gethash root vhdl-nav--watcher-queue))
         (index  (gethash root vhdl-nav--project-indices))
         (mtimes (gethash root vhdl-nav--file-mtimes))
         (reparse '())
         (purge '()))
    (when (and queue index mtimes)
      (maphash (lambda (f action)
                 (if (eq action 'deleted) (push f purge) (push f reparse)))
               queue)
      (remhash root vhdl-nav--watcher-queue)
      (dolist (f purge)
        (vhdl-nav--purge-file-from-index index f)
        (remhash f mtimes))
      (when reparse
        (vhdl-nav--build-index-async-files root reparse)))))

(defun vhdl-nav--watch-dirs (root dirs)
  "Add filenotify watchers for DIRS belonging to project ROOT.
Silently does nothing if filenotify is unavailable or ROOT is already watched."
  (when (and (featurep 'filenotify)
             (not (gethash root vhdl-nav--watchers)))
    (condition-case err
        (let ((descs
               (delq nil
                     (mapcar
                      (lambda (d)
                        (when (file-directory-p d)
                          (ignore-errors
                            (file-notify-add-watch
                             d '(change)
                             (lambda (ev)
                               (vhdl-nav--watcher-callback root ev))))))
                      dirs))))
          (when descs
            (puthash root descs vhdl-nav--watchers)
            (when vhdl-nav-debug
              (message "vhdl-navigator: watching %d dir(s) under %s"
                       (length descs) (abbreviate-file-name root)))))
      (error
       (when vhdl-nav-debug
         (message "vhdl-navigator: filenotify setup failed: %s" err))))))

(defun vhdl-nav--setup-watchers-from-index (root)
  "Derive watched directories from the current mtimes table and start watchers."
  (let ((mtimes  (gethash root vhdl-nav--file-mtimes))
        (dir-set (make-hash-table :test 'equal)))
    (puthash root t dir-set)
    (when mtimes
      (maphash (lambda (f _) (puthash (file-name-directory f) t dir-set)) mtimes))
    (let ((dirs '()))
      (maphash (lambda (d _) (push d dirs)) dir-set)
      (vhdl-nav--watch-dirs root dirs))))

(defun vhdl-nav--stop-watchers (root)
  "Remove all filenotify watchers for project ROOT."
  (dolist (d (gethash root vhdl-nav--watchers))
    (condition-case _ (file-notify-rm-watch d) (error nil)))
  (remhash root vhdl-nav--watchers))

;; ---------------------------------------------------------------------------
;; Deferred startup freshness check
;; ---------------------------------------------------------------------------

(defun vhdl-nav--deferred-startup-check (root)
  "Update stale cache entries, running only when Emacs has been idle ≥ 2 s.
This catches files modified between sessions without blocking startup.
Because it runs after the cache is already active, features work
immediately with the cached data while the refresh happens silently."
  (if (null (current-idle-time))
      ;; User became active before we ran — reschedule
      (run-with-idle-timer 2.0 nil #'vhdl-nav--deferred-startup-check root)
    (let* ((cached-mtimes (gethash root vhdl-nav--file-mtimes))
           (diff    (when cached-mtimes (vhdl-nav--diff-files root cached-mtimes)))
           (stale   (plist-get diff :stale))
           (deleted (plist-get diff :deleted)))
      ;; Purge deleted files — cheap hash-table operations
      (dolist (f deleted)
        (let ((index (gethash root vhdl-nav--project-indices)))
          (when index (vhdl-nav--purge-file-from-index index f)))
        (remhash f cached-mtimes))
      ;; Async re-parse of changed/new files
      (if stale
          (progn
            (message "vhdl-navigator: %d file(s) changed since last session, updating..."
                     (length stale))
            (vhdl-nav--build-index-async-files root stale))
        (when vhdl-nav-debug
          (message "vhdl-navigator: index is up to date")))
      ;; Refresh watchers to cover any new directories
      (when (or stale deleted)
        (vhdl-nav--stop-watchers root)
        (vhdl-nav--setup-watchers-from-index root)))))

;; ---------------------------------------------------------------------------
;; Index management
;; ---------------------------------------------------------------------------

(defun vhdl-nav--get-index (&optional force)
  "Get or build the VHDL index for the current project.
When FORCE is non-nil, rebuild from scratch (ignoring cache)."
  (let* ((root  (vhdl-nav--project-root))
         (index (gethash root vhdl-nav--project-indices)))
    (when (or force (not index))
      (if force
          ;; Forced: synchronous full rebuild, then save cache
          (progn
            (vhdl-nav--async-cancel)
            (setq index (vhdl-nav--build-index-sync root))
            (puthash root index vhdl-nav--project-indices)
            (vhdl-nav--save-cache root)
            (vhdl-nav--setup-watchers-from-index root))
        ;; First access: try loading from persistent cache
        (let ((cached (vhdl-nav--load-cache root)))
          (if cached
              (let ((cached-index  (car cached))
                    (cached-mtimes (cdr cached)))
                ;; Install cache immediately — zero scanning, zero blocking
                (puthash root cached-index  vhdl-nav--project-indices)
                (puthash root cached-mtimes vhdl-nav--file-mtimes)
                (setq index cached-index)
                (message "vhdl-navigator: cache loaded for %s"
                         (abbreviate-file-name root))
                ;; Start watching dirs already known from cached mtimes
                (vhdl-nav--setup-watchers-from-index root)
                ;; Defer mtime freshness check to idle time — never blocks startup
                (when vhdl-nav-startup-check
                  (run-with-idle-timer
                   2.0 nil #'vhdl-nav--deferred-startup-check root)))
            ;; No cache: empty index + full async build
            (setq index (make-hash-table :test 'equal))
            (puthash root index vhdl-nav--project-indices)
            (vhdl-nav--build-index-async root)))))
    index))

(defun vhdl-nav--purge-file-from-index (index filepath)
  "Remove all defs belonging to FILEPATH from INDEX hash-table."
  (maphash (lambda (key defs)
             (let ((filtered (seq-remove
                              (lambda (d)
                                (and (vhdl-nav-def-p d)
                                     (string= (vhdl-nav-def-file d) filepath)))
                              defs)))
               (if filtered
                   (puthash key filtered index)
                 (remhash key index))))
           index))

(defun vhdl-nav--index-file-into (index mtimes filepath)
  "Parse FILEPATH and merge its defs into INDEX, updating MTIMES.
Returns the number of defs added."
  (condition-case err
      (let ((defs (vhdl-nav--parse-file filepath))
            (count 0))
        (when (listp defs)
          (ignore-errors
            (puthash filepath (float-time
                               (file-attribute-modification-time
                                (file-attributes filepath)))
                     mtimes))
          (dolist (d defs)
            (when (and (vhdl-nav-def-p d)
                       (stringp (vhdl-nav-def-name d)))
              (let* ((name (vhdl-nav-def-name d))
                     (existing (gethash name index)))
                (puthash name (cons d existing) index))
              (setq count (1+ count)))))
        count)
    (error
     (message "vhdl-navigator: error on %s: %s" filepath err)
     0)))

(defun vhdl-nav--build-index-sync (root)
  "Build a fresh index for project at ROOT synchronously."
  (message "vhdl-navigator: indexing %s..." (abbreviate-file-name root))
  (let ((index (make-hash-table :test 'equal))
        (files (vhdl-nav--find-vhdl-files root))
        (mtimes (make-hash-table :test 'equal))
        (count 0))
    (dolist (f (or files '()))
      (setq count (+ count (vhdl-nav--index-file-into index mtimes f))))
    (puthash root mtimes vhdl-nav--file-mtimes)
    (message "vhdl-navigator: indexed %d definitions from %d files"
             count (length (or files '())))
    index))

(defun vhdl-nav--async-cancel ()
  "Cancel any in-progress async indexing."
  (when vhdl-nav--async-timer
    (cancel-timer vhdl-nav--async-timer)
    (setq vhdl-nav--async-timer nil
          vhdl-nav--async-queue nil)))

(defun vhdl-nav--build-index-async (root)
  "Start full async indexing for project at ROOT."
  (let ((files (vhdl-nav--find-vhdl-files root)))
    (vhdl-nav--build-index-async-files root files)))

(defun vhdl-nav--build-index-async-files (root files)
  "Start async indexing of FILES for project at ROOT.
Parses `vhdl-nav-index-batch-size' files per idle cycle.
Stale files are purged from the index before re-parsing."
  (vhdl-nav--async-cancel)
  (if (or (null files) (<= vhdl-nav-index-batch-size 0))
      ;; No files or sync mode: fall back to sync for just these files
      (when files
        (let ((index (or (gethash root vhdl-nav--project-indices)
                         (make-hash-table :test 'equal)))
              (mtimes (or (gethash root vhdl-nav--file-mtimes)
                          (make-hash-table :test 'equal)))
              (count 0))
          (dolist (f files)
            (vhdl-nav--purge-file-from-index index f)
            (setq count (+ count (vhdl-nav--index-file-into index mtimes f))))
          (puthash root index vhdl-nav--project-indices)
          (puthash root mtimes vhdl-nav--file-mtimes)
          (message "vhdl-navigator: updated %d definitions from %d files"
                   count (length files))
          (vhdl-nav--save-cache root)
          (vhdl-nav--setup-watchers-from-index root)))
    ;; Ensure mtimes table exists
    (unless (gethash root vhdl-nav--file-mtimes)
      (puthash root (make-hash-table :test 'equal) vhdl-nav--file-mtimes))
    (setq vhdl-nav--async-root root
          vhdl-nav--async-queue files
          vhdl-nav--async-total (length files)
          vhdl-nav--async-count 0)
    (message "vhdl-navigator: async indexing %d file(s) in %s..."
             vhdl-nav--async-total (abbreviate-file-name root))
    ;; Wait until user is idle before starting
    (setq vhdl-nav--async-timer
          (run-with-idle-timer 0.5 nil #'vhdl-nav--async-index-batch))))

(defun vhdl-nav--async-schedule-next ()
  "Schedule the next async batch.
Uses a short regular timer to chain quickly while the user is idle.
If the user becomes active before it fires, the batch itself will
detect this and defer until the next idle period."
  (setq vhdl-nav--async-timer
        (run-with-timer 0.05 nil #'vhdl-nav--async-index-batch)))

(defun vhdl-nav--async-index-batch ()
  "Parse one batch of files from the async queue.
If the user is actively typing, defers until they are idle for 0.5s.
Otherwise processes one batch and schedules the next."
  (setq vhdl-nav--async-timer nil)
  ;; If user is active, wait until they are idle
  (if (null (current-idle-time))
      (setq vhdl-nav--async-timer
            (run-with-idle-timer 0.5 nil #'vhdl-nav--async-index-batch))
    ;; User is idle — do work
    (if (null vhdl-nav--async-queue)
        ;; Done — save cache and clean up
        (let ((root vhdl-nav--async-root))
          (message "vhdl-navigator: async indexing complete — %d definitions from %d file(s)"
                   vhdl-nav--async-count vhdl-nav--async-total)
          (vhdl-nav--save-cache root)
          (vhdl-nav--setup-watchers-from-index root))
      ;; Parse a batch
      (let* ((root vhdl-nav--async-root)
             (index (gethash root vhdl-nav--project-indices))
             (mtimes (gethash root vhdl-nav--file-mtimes))
             (batch-size vhdl-nav-index-batch-size)
             (processed 0))
        (while (and vhdl-nav--async-queue (< processed batch-size))
          (let ((f (pop vhdl-nav--async-queue)))
            ;; Purge old defs for this file before re-parsing
            (vhdl-nav--purge-file-from-index index f)
            (setq vhdl-nav--async-count
                  (+ vhdl-nav--async-count
                     (vhdl-nav--index-file-into index mtimes f))))
          (setq processed (1+ processed)))
        ;; Progress message
        (let ((remaining (length vhdl-nav--async-queue)))
          (when (> remaining 0)
            (message "vhdl-navigator: indexing... %d/%d files remaining"
                     remaining vhdl-nav--async-total)))
        ;; Schedule next batch
        (vhdl-nav--async-schedule-next)))))

(defun vhdl-nav--reindex-file (filepath)
  "Re-index a single FILEPATH and merge into the project index."
  (let* ((root (vhdl-nav--project-root))
         (index (gethash root vhdl-nav--project-indices))
         (mtimes (or (gethash root vhdl-nav--file-mtimes)
                     (let ((ht (make-hash-table :test 'equal)))
                       (puthash root ht vhdl-nav--file-mtimes)
                       ht))))
    (when index
      (vhdl-nav--purge-file-from-index index filepath)
      (vhdl-nav--index-file-into index mtimes filepath)
      (vhdl-nav--save-cache root))))

(defun vhdl-nav--after-save-hook ()
  "Re-index the current file on save."
  (when (and vhdl-nav-auto-reindex-on-save
             (derived-mode-p 'vhdl-mode)
             buffer-file-name)
    (vhdl-nav--reindex-file buffer-file-name)))

;; ---------------------------------------------------------------------------
;; Lookup helpers
;; ---------------------------------------------------------------------------

(defun vhdl-nav--lookup (name &optional kind)
  "Look up NAME in the index, optionally filtering by KIND."
  (let* ((index (vhdl-nav--get-index))
         (defs (gethash (downcase name) index)))
    (if kind
        (seq-filter (lambda (d) (eq (vhdl-nav-def-kind d) kind)) defs)
      defs)))

(defun vhdl-nav--find-record (name)
  "Find the record definition for NAME."
  (car (vhdl-nav--lookup name 'record)))

(defun vhdl-nav--resolve-type (symbol-name)
  "Resolve the type of SYMBOL-NAME by looking it up in the index."
  (let ((defs (vhdl-nav--lookup symbol-name)))
    (when defs
      (let ((sorted (sort (copy-sequence defs)
                          (lambda (a b)
                            (let ((order '((signal . 0) (variable . 1)
                                           (constant . 2) (port . 3))))
                              (< (or (cdr (assq (vhdl-nav-def-kind a) order)) 99)
                                 (or (cdr (assq (vhdl-nav-def-kind b) order)) 99)))))))
        (vhdl-nav-def-type-name (car sorted))))))

(defun vhdl-nav--strip-type-qualifiers (type-str)
  "Strip library/package prefix from TYPE-STR to get bare type name."
  (when (and type-str (stringp type-str))
    (let ((s (string-trim type-str)))
      (when (string-match "[A-Za-z0-9_]+\\.[A-Za-z0-9_]+\\.\\([A-Za-z0-9_]+\\)" s)
        (setq s (match-string 1 s)))
      (when (string-match "[A-Za-z0-9_]+\\.\\([A-Za-z0-9_]+\\)\\'" s)
        (setq s (match-string 1 s)))
      (downcase (string-trim s)))))

;; ---------------------------------------------------------------------------
;; Record field completion (capf)
;; ---------------------------------------------------------------------------

(defun vhdl-nav--dot-prefix ()
  "If point is right after IDENT. return (field-start . identifier)."
  (save-excursion
    (let ((pt (point)))
      (when (or
             (and (> (point) 1) (eq (char-before) ?.))
             (and (skip-chars-backward "a-zA-Z0-9_")
                  (> (point) 1) (eq (char-before) ?.)))
        (let ((field-start (point)))
          (backward-char 1)
          (let ((id-end (point)))
            (skip-chars-backward "a-zA-Z0-9_")
            (let ((identifier (buffer-substring-no-properties (point) id-end)))
              (when (> (length identifier) 0)
                (cons field-start identifier)))))))))

(defun vhdl-nav--resolve-record-chain ()
  "Walk backward over dotted chain and resolve to final record type name."
  (save-excursion
    (let ((chain '())
          (continue t))
      (skip-chars-backward "a-zA-Z0-9_")
      (while continue
        (if (and (> (point) 1) (eq (char-before) ?.))
            (progn
              (backward-char 1)
              (let ((end (point)))
                (skip-chars-backward "a-zA-Z0-9_")
                (let ((id (buffer-substring-no-properties (point) end)))
                  (if (> (length id) 0)
                      (push id chain)
                    (setq continue nil)))))
          (setq continue nil)))
      (when chain
        (let* ((base (downcase (car chain)))
               (type-str (vhdl-nav--resolve-type base))
               (resolved (vhdl-nav--strip-type-qualifiers type-str)))
          (dolist (field-name (cdr chain))
            (when resolved
              (let ((rec (vhdl-nav--find-record resolved)))
                (if rec
                    (let* ((field (assoc (downcase field-name)
                                         (vhdl-nav-def-fields rec)))
                           (field-type (when field (cdr field))))
                      (setq resolved (vhdl-nav--strip-type-qualifiers field-type)))
                  (setq resolved nil)))))
          resolved)))))

(defun vhdl-nav-completion-at-point ()
  "Completion-at-point for VHDL record fields after dot."
  (let ((dot-info (vhdl-nav--dot-prefix)))
    (when dot-info
      (let* ((field-start (car dot-info))
             (record-type (vhdl-nav--resolve-record-chain)))
        (when record-type
          (let ((rec-def (vhdl-nav--find-record record-type)))
            (when (and rec-def (vhdl-nav-def-fields rec-def))
              (let ((candidates
                     (mapcar (lambda (f)
                               (let ((name (car f))
                                     (type (cdr f)))
                                 (if vhdl-nav-completion-annotation
                                     (propertize name 'vhdl-nav-type type)
                                   name)))
                             (vhdl-nav-def-fields rec-def))))
                (list field-start (point)
                      candidates
                      :annotation-function
                      (when vhdl-nav-completion-annotation
                        (lambda (cand)
                          (let ((type (get-text-property 0 'vhdl-nav-type cand)))
                            (when type (format " : %s" type)))))
                      :company-kind (lambda (_) 'field)
                      :exclusive 'no)))))))))

;; ---------------------------------------------------------------------------
;; Eldoc integration
;; ---------------------------------------------------------------------------

(defun vhdl-nav-eldoc-function (callback &rest _)
  "Eldoc function: show record field type in minibuffer."
  (let ((dot-info (vhdl-nav--dot-prefix)))
    (when dot-info
      (let* ((record-type (vhdl-nav--resolve-record-chain))
             (rec-def (when record-type (vhdl-nav--find-record record-type))))
        (when (and rec-def (vhdl-nav-def-fields rec-def))
          (let* ((field-name (save-excursion
                               (let ((end (point)))
                                 (skip-chars-backward "a-zA-Z0-9_")
                                 (buffer-substring-no-properties (point) end))))
                 (field (assoc (downcase field-name)
                               (vhdl-nav-def-fields rec-def))))
            (if field
                (funcall callback
                         (format "%s.%s : %s"
                                 (vhdl-nav-def-name rec-def)
                                 (car field) (cdr field))
                         :thing (car field)
                         :face 'font-lock-variable-name-face)
              (funcall callback
                       (format "%s { %s }"
                               (vhdl-nav-def-name rec-def)
                               (mapconcat (lambda (f)
                                            (format "%s: %s" (car f) (cdr f)))
                                          (vhdl-nav-def-fields rec-def) ", "))
                       :thing (vhdl-nav-def-name rec-def)
                       :face 'font-lock-type-face))))))))

;; ---------------------------------------------------------------------------
;; Xref backend -- go-to-definition
;; ---------------------------------------------------------------------------

(defun vhdl-nav--xref-backend ()
  "Return the vhdl-navigator xref backend."
  'vhdl-navigator)

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql 'vhdl-navigator)))
  "Return the VHDL identifier at point."
  (let ((bounds (bounds-of-thing-at-point 'symbol)))
    (when bounds
      (buffer-substring-no-properties (car bounds) (cdr bounds)))))

(cl-defmethod xref-backend-definitions ((_backend (eql 'vhdl-navigator)) identifier)
  "Find definitions for IDENTIFIER."
  (vhdl-nav--get-index)
  (let* ((name (downcase identifier))
         (defs (gethash name (vhdl-nav--get-index)))
         (primary (or (seq-filter (lambda (d)
                                    (not (eq (vhdl-nav-def-kind d) 'field)))
                                  defs)
                      defs)))
    (mapcar (lambda (d)
              (xref-make
               (format "[%s] %s%s"
                       (vhdl-nav-def-kind d)
                       (vhdl-nav-def-name d)
                       (if (vhdl-nav-def-type-name d)
                           (format " : %s" (vhdl-nav-def-type-name d))
                         ""))
               (xref-make-file-location
                (vhdl-nav-def-file d)
                (vhdl-nav-def-line d)
                0)))
            primary)))

(cl-defmethod xref-backend-identifier-completion-table ((_backend (eql 'vhdl-navigator)))
  "Return completion table of all known VHDL identifiers."
  (let ((index (vhdl-nav--get-index))
        (names '()))
    (maphash (lambda (key _val) (push key names)) index)
    names))

;; ---------------------------------------------------------------------------
;; Interactive commands
;; ---------------------------------------------------------------------------

(defun vhdl-nav-reindex ()
  "Force a full re-index of the current project."
  (interactive)
  (vhdl-nav--get-index t)
  (message "vhdl-navigator: reindex complete"))

(defun vhdl-nav-show-record (name)
  "Display the fields of record NAME in a help buffer."
  (interactive
   (let* ((index (vhdl-nav--get-index))
          (records (let (recs)
                     (maphash (lambda (_k defs)
                                (dolist (d defs)
                                  (when (eq (vhdl-nav-def-kind d) 'record)
                                    (push (vhdl-nav-def-name d) recs))))
                              index)
                     recs)))
     (list (completing-read "Record type: " records nil t))))
  (let ((rec (vhdl-nav--find-record name)))
    (if (not rec)
        (message "Record '%s' not found" name)
      (with-help-window "*VHDL Record*"
        (with-current-buffer "*VHDL Record*"
          (insert (propertize (format "type %s is record\n" (vhdl-nav-def-name rec))
                              'face 'font-lock-type-face))
          (dolist (f (vhdl-nav-def-fields rec))
            (insert (format "  %-24s : %s;\n"
                            (propertize (car f) 'face 'font-lock-variable-name-face)
                            (propertize (cdr f) 'face 'font-lock-type-face))))
          (insert (propertize "end record;\n" 'face 'font-lock-type-face))
          (insert (format "\nDefined in: %s:%d\n"
                          (abbreviate-file-name (vhdl-nav-def-file rec))
                          (vhdl-nav-def-line rec))))))))

(defun vhdl-nav-list-definitions ()
  "List all indexed definitions in a searchable buffer."
  (interactive)
  (let ((index (vhdl-nav--get-index))
        (entries '()))
    (maphash (lambda (_key defs)
               (dolist (d defs)
                 (push (format "%-12s %-30s %-30s %s:%d"
                               (vhdl-nav-def-kind d)
                               (vhdl-nav-def-name d)
                               (or (vhdl-nav-def-type-name d) "")
                               (abbreviate-file-name (vhdl-nav-def-file d))
                               (vhdl-nav-def-line d))
                       entries)))
             index)
    (setq entries (sort entries #'string<))
    (with-help-window "*VHDL Definitions*"
      (with-current-buffer "*VHDL Definitions*"
        (insert (format "%-12s %-30s %-30s %s\n" "KIND" "NAME" "TYPE" "LOCATION"))
        (insert (make-string 100 ?-) "\n")
        (dolist (e entries) (insert e "\n"))))))

(defun vhdl-nav-jump-to-record-field ()
  "Interactively select a record then a field, and jump to it."
  (interactive)
  (let* ((index (vhdl-nav--get-index))
         (records (let (recs)
                    (maphash (lambda (_k defs)
                               (dolist (d defs)
                                 (when (eq (vhdl-nav-def-kind d) 'record)
                                   (push d recs))))
                             index)
                    recs))
         (rec-name (completing-read "Record: "
                                    (mapcar #'vhdl-nav-def-name records) nil t))
         (rec (vhdl-nav--find-record rec-name))
         (field-name (completing-read
                      (format "%s field: " rec-name)
                      (mapcar #'car (vhdl-nav-def-fields rec)) nil t))
         (field-defs (seq-filter
                      (lambda (d)
                        (and (eq (vhdl-nav-def-kind d) 'field)
                             (string= (vhdl-nav-def-parent d) (downcase rec-name))))
                      (gethash (downcase field-name) index))))
    (if field-defs
        (let ((d (car field-defs)))
          (find-file (vhdl-nav-def-file d))
          (goto-char (point-min))
          (forward-line (1- (vhdl-nav-def-line d))))
      (message "Field '%s' not found in record '%s'" field-name rec-name))))

;; ---------------------------------------------------------------------------
;; Diagnostic command
;; ---------------------------------------------------------------------------

(defun vhdl-nav-diagnose ()
  "Run parser diagnostics on the current buffer file."
  (interactive)
  (let* ((file (or buffer-file-name
                   (read-file-name "VHDL file to diagnose: ")))
         (vhdl-nav-debug t)
         (defs (vhdl-nav--parse-file file)))
    (with-help-window "*VHDL Diagnose*"
      (with-current-buffer "*VHDL Diagnose*"
        (insert (format "File: %s\n" file))
        (insert (format "Emacs: %s  System: %s\n" emacs-version system-type))
        (insert (make-string 60 ?-) "\n")
        (if (null defs)
            (insert "NO DEFINITIONS FOUND -- check *Messages* for errors\n")
          (insert (format "Found %d definitions:\n\n" (length defs)))
          (dolist (d defs)
            (insert (format "  %-12s %-25s" (vhdl-nav-def-kind d) (vhdl-nav-def-name d)))
            (when (vhdl-nav-def-type-name d)
              (insert (format " : %s" (vhdl-nav-def-type-name d))))
            (when (vhdl-nav-def-parent d)
              (insert (format " [in %s]" (vhdl-nav-def-parent d))))
            (when (and (eq (vhdl-nav-def-kind d) 'record) (vhdl-nav-def-fields d))
              (insert "\n")
              (dolist (f (vhdl-nav-def-fields d))
                (insert (format "    .%-20s : %s\n" (car f) (cdr f)))))
            (insert (format "  L%d\n" (vhdl-nav-def-line d)))))))))

;; ---------------------------------------------------------------------------
;; Dot-triggered completion
;; ---------------------------------------------------------------------------

(defun vhdl-nav--post-dot-completion ()
  "Trigger field completion immediately after '.' is typed.
Most completion frontends (Corfu, Company) only auto-trigger after word
characters, so they miss the dot.  This hook calls `completion-at-point'
right after insertion — but only when the dot follows an identifier that
we can resolve, and only outside comments and string literals."
  (when (and (eq last-command-event ?.)
             (let ((ppss (syntax-ppss)))
               (not (or (nth 4 ppss)   ; inside comment
                        (nth 3 ppss)))) ; inside string
             (vhdl-nav--dot-prefix))   ; looks like a dot-chain we can resolve
    (ignore-errors (completion-at-point))))

;; ---------------------------------------------------------------------------
;; Minor mode
;; ---------------------------------------------------------------------------

;;;###autoload
(define-minor-mode vhdl-navigator-mode
  "Minor mode for VHDL record visualization and go-to-definition."
  :lighter " VNav"
  :group 'vhdl-navigator
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c v r") #'vhdl-nav-show-record)
            (define-key map (kbd "C-c v l") #'vhdl-nav-list-definitions)
            (define-key map (kbd "C-c v j") #'vhdl-nav-jump-to-record-field)
            (define-key map (kbd "C-c v i") #'vhdl-nav-reindex)
            (define-key map (kbd "C-c v d") #'vhdl-nav-diagnose)
            map)
  (if vhdl-navigator-mode
      (progn
        (add-hook 'completion-at-point-functions
                  #'vhdl-nav-completion-at-point nil t)
        (add-hook 'xref-backend-functions
                  #'vhdl-nav--xref-backend nil t)
        (add-hook 'eldoc-documentation-functions
                  #'vhdl-nav-eldoc-function nil t)
        (add-hook 'after-save-hook
                  #'vhdl-nav--after-save-hook nil t)
        (add-hook 'post-self-insert-hook
                  #'vhdl-nav--post-dot-completion nil t)
        ;; Defer index loading to idle time so the buffer opens instantly
        (run-with-idle-timer 0.3 nil #'vhdl-nav--get-index))
    (remove-hook 'completion-at-point-functions
                 #'vhdl-nav-completion-at-point t)
    (remove-hook 'xref-backend-functions
                 #'vhdl-nav--xref-backend t)
    (remove-hook 'eldoc-documentation-functions
                 #'vhdl-nav-eldoc-function t)
    (remove-hook 'after-save-hook
                 #'vhdl-nav--after-save-hook t)
    (remove-hook 'post-self-insert-hook
                 #'vhdl-nav--post-dot-completion t)
    ;; Stop watchers only when no other vhdl-navigator buffer is open for this project
    (let* ((root (vhdl-nav--project-root))
           (still-active
            (cl-some (lambda (b)
                       (and (not (eq b (current-buffer)))
                            (buffer-local-value 'vhdl-navigator-mode b)
                            (with-current-buffer b
                              (equal (vhdl-nav--project-root) root))))
                     (buffer-list))))
      (unless still-active
        (vhdl-nav--stop-watchers root)))))

;;;###autoload
(defun vhdl-navigator-setup ()
  "Enable vhdl-navigator-mode in vhdl-mode buffers."
  (add-hook 'vhdl-mode-hook #'vhdl-navigator-mode))

(provide 'vhdl-navigator)
;;; vhdl-navigator.el ends here
