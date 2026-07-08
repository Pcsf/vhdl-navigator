;;; vhdl-navigator.el --- VHDL record visualizer & go-to-definition -*- lexical-binding: t; -*-

;; Author: Paulo (generated with Claude)
;; Version: 0.4.0
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
(require 'subr-x)

(defconst vhdl-nav--library-file (or load-file-name buffer-file-name)
  "Location of this library, captured at load time.
Worker subprocesses load this exact file so they run the same parser.")

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
index updates - useful on network-mounted file-systems where even an
idle-time scan is undesirably slow."
  :type 'boolean
  :group 'vhdl-navigator)

(defcustom vhdl-nav-worker-count 0
  "Number of `emacs --batch' subprocesses used for project indexing.
0 means auto: one per CPU core (capped at 8), leaving one core for the
interactive Emacs.  A negative value or nil disables subprocess
indexing entirely; the slower in-process idle-timer indexer is used
instead."
  :type '(choice integer (const :tag "Disabled" nil))
  :group 'vhdl-navigator)

(defcustom vhdl-nav-worker-min-files 10
  "Minimum number of files before worker subprocesses are used.
Smaller updates (single saves, watcher events) are parsed in-process,
which is faster than paying the subprocess startup cost."
  :type 'integer
  :group 'vhdl-navigator)

;; ---------------------------------------------------------------------------

(defcustom vhdl-nav-folders-file ".vhdl-nav-folders"
  "File name in project root containing folders to index.
Each line should contain a folder path relative to project root.
Only these folders and their subdirectories will be scanned for VHDL files.
If the file does not exist, the entire project is scanned."
  :type 'string
  :group 'vhdl-navigator)

(defcustom vhdl-nav-ignore-file ".vhdl-nav-ignore"
  "File name in project root with glob patterns to exclude from indexing.
Each line should contain a pattern (for example, \"build/*\" or \"*.cache\").
Lines starting with ';' or '#' are treated as comments."
  :type 'string
  :group 'vhdl-navigator)
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
  "Map from project root to hash of file/action pairs pending processing.")

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
;; Folder filtering
;; ---------------------------------------------------------------------------

(defun vhdl-nav--read-config-lines (file)
  "Return non-empty, non-comment lines from FILE."
  (when (and (file-exists-p file)
             (file-regular-p file)
             (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (let (lines)
        (while (not (eobp))
          (let ((line (string-trim (buffer-substring-no-properties
                                    (point) (line-end-position)))))
            (unless (or (string-empty-p line)
                        (string-prefix-p ";" line)
                        (string-prefix-p "#" line))
              (push line lines)))
          (forward-line))
        (nreverse lines)))))

(defun vhdl-nav--search-roots (project-root)
  "Return absolute directories to scan for PROJECT-ROOT."
  (let ((folders-file (expand-file-name vhdl-nav-folders-file project-root)))
    (if (file-exists-p folders-file)
        (delq nil
              (mapcar (lambda (folder)
                        (let ((abs-path (expand-file-name folder project-root)))
                          (when (file-directory-p abs-path)
                            (file-name-as-directory abs-path))))
                      (vhdl-nav--read-config-lines folders-file)))
      (list project-root))))

(defun vhdl-nav--should-ignore-p (project-root file)
  "Return non-nil if FILE should be ignored for PROJECT-ROOT."
  (when vhdl-nav-ignore-file
    (let* ((ignore-file (expand-file-name vhdl-nav-ignore-file project-root))
           (relative-file (file-relative-name file project-root))
           (patterns (vhdl-nav--read-config-lines ignore-file)))
      (cl-some (lambda (pattern)
                 (or (string-match-p (wildcard-to-regexp pattern) relative-file)
                     (string-match-p (wildcard-to-regexp pattern) file)))
               patterns))))

;; ---------------------------------------------------------------------------
;; File discovery
;; ---------------------------------------------------------------------------

(defun vhdl-nav--find-vhdl-files (root)
  "Find all VHDL files under ROOT or specified subfolders."
  (when (and root (stringp root) (file-directory-p root))
    (let* ((re (concat "\\." (regexp-opt vhdl-nav-file-extensions) "\\'"))
           (search-roots (vhdl-nav--search-roots root))
           (all-files nil))
      (dolist (search-root search-roots all-files)
        (let ((files (directory-files-recursively search-root re nil)))
          (setq all-files (append all-files files))))
      (seq-filter (lambda (f) (not (vhdl-nav--should-ignore-p root f))) all-files))))

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
              ;; Convert index hash to alist of (name . list-of-defs)
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
                    (when file2
                      (puthash file2
                               (if (vhdl-nav--should-ignore-p root file2)
                                   'deleted
                                 'changed)
                               queue)))
          (_        (when file
                      (puthash file
                               (if (vhdl-nav--should-ignore-p root file)
                                   'deleted
                                 'changed)
                               queue)))))
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
         (mtimes (gethash root vhdl-nav--file-mtimes)))
    (cond
     ;; Nothing queued - nothing to do
     ((null queue))
     ;; Index not yet loaded - reschedule so events are not lost
     ((or (null index) (null mtimes))
      (puthash root
               (run-with-idle-timer 2.0 nil #'vhdl-nav--flush-watcher-queue root)
               vhdl-nav--watcher-debounces))
     ;; Index ready - process the queue
     (t
      (let ((reparse '())
            (purge '()))
        (maphash (lambda (f action)
                   (if (eq action 'deleted) (push f purge) (push f reparse)))
                 queue)
        (remhash root vhdl-nav--watcher-queue)
        (dolist (f purge)
          (vhdl-nav--purge-file-from-index index f)
          (remhash f mtimes))
        (when reparse
          (vhdl-nav--build-index-async-files root reparse)))))))

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
  "Update stale cache entries, running only when Emacs has been idle for 2s.
This catches files modified between sessions without blocking startup.
Because it runs after the cache is already active, features work
immediately with the cached data while the refresh happens silently."
  (if (null (current-idle-time))
      ;; User became active before we ran - reschedule
      (run-with-idle-timer 2.0 nil #'vhdl-nav--deferred-startup-check root)
    (let* ((cached-mtimes (gethash root vhdl-nav--file-mtimes))
           (diff    (when cached-mtimes (vhdl-nav--diff-files root cached-mtimes)))
           (stale   (plist-get diff :stale))
           (deleted (plist-get diff :deleted)))
      ;; Purge deleted files - cheap hash-table operations
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
          ;; Forced: full rebuild from scratch.  Prefer worker subprocesses
          ;; (non-blocking); fall back to the synchronous rebuild.
          (progn
            (vhdl-nav--async-cancel)
            (setq index (make-hash-table :test 'equal))
            (puthash root index vhdl-nav--project-indices)
            (puthash root (make-hash-table :test 'equal)
                     vhdl-nav--file-mtimes)
            (unless (and (vhdl-nav--parallel-available-p root)
                         (vhdl-nav--build-index-parallel
                          root nil (vhdl-nav--priority-dir)))
              (setq index (vhdl-nav--build-index-sync root))
              (puthash root index vhdl-nav--project-indices)
              (vhdl-nav--save-cache root)
              (vhdl-nav--setup-watchers-from-index root)))
        ;; First access: try loading from persistent cache
        (let ((cached (vhdl-nav--load-cache root)))
          (if cached
              (let ((cached-index  (car cached))
                    (cached-mtimes (cdr cached)))
                ;; Install cache immediately - zero scanning, zero blocking
                (puthash root cached-index  vhdl-nav--project-indices)
                (puthash root cached-mtimes vhdl-nav--file-mtimes)
                (setq index cached-index)
                (message "vhdl-navigator: cache loaded for %s"
                         (abbreviate-file-name root))
                ;; Start watching dirs already known from cached mtimes
                (vhdl-nav--setup-watchers-from-index root)
                ;; Defer mtime freshness check to idle time - never blocks startup
                (when vhdl-nav-startup-check
                  (run-with-idle-timer
                   2.0 nil #'vhdl-nav--deferred-startup-check root)))
            ;; No cache: empty index + warm start + full async build
            (setq index (make-hash-table :test 'equal))
            (puthash root index vhdl-nav--project-indices)
            (unless (gethash root vhdl-nav--file-mtimes)
              (puthash root (make-hash-table :test 'equal)
                       vhdl-nav--file-mtimes))
            ;; Warm start: parse the visited file synchronously (a single
            ;; file - milliseconds) so completion, Eldoc, and xref work
            ;; immediately while the project-wide scan runs in the background.
            (when-let ((file (vhdl-nav--current-vhdl-file)))
              (vhdl-nav--index-file-into
               index (gethash root vhdl-nav--file-mtimes) file))
            (vhdl-nav--build-index-async root)))))
    index))

(defun vhdl-nav--purge-if-indexed (index mtimes filepath)
  "Purge FILEPATH from INDEX only when it was indexed before.
MTIMES records every indexed file, so absence means there is nothing to
purge - crucial on first-time builds, where purging every incoming file
would scan the whole index each time (O(n^2))."
  (when (and index mtimes (gethash filepath mtimes))
    (vhdl-nav--purge-file-from-index index filepath)))

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

(defun vhdl-nav--merge-defs (index defs)
  "Merge the list DEFS into INDEX.  Return the number of defs added."
  (let ((count 0))
    (dolist (d defs)
      (when (and (vhdl-nav-def-p d)
                 (stringp (vhdl-nav-def-name d)))
        (let* ((name (vhdl-nav-def-name d))
               (existing (gethash name index)))
          (puthash name (cons d existing) index))
        (setq count (1+ count))))
    count))

(defun vhdl-nav--index-file-into (index mtimes filepath)
  "Parse FILEPATH and merge its defs into INDEX, updating MTIMES.
Returns the number of defs added."
  (condition-case err
      (let ((defs (vhdl-nav--parse-file filepath)))
        (if (not (listp defs))
            0
          (ignore-errors
            (puthash filepath (float-time
                               (file-attribute-modification-time
                                (file-attributes filepath)))
                     mtimes))
          (vhdl-nav--merge-defs index defs)))
    (error
     (message "vhdl-navigator: error on %s: %s" filepath err)
     0)))

;; ---------------------------------------------------------------------------
;; Parallel subprocess indexing
;; ---------------------------------------------------------------------------
;;
;; Emacs Lisp is single-threaded, so large first-time scans are offloaded to
;; `emacs --batch' worker subprocesses.  Each worker loads this very library,
;; reuses `vhdl-nav--parse-file', and streams printed result forms back on
;; stdout, where the parent merges them into the index (cheap hash-table work
;; only).  Workers run fully parallel on Linux and Windows with no dependency
;; beyond the Emacs binary itself.
;;
;; Protocol: the parent writes a job plist to a temp file (avoids Windows
;; command-line length limits and all shell quoting) and spawns
;;   emacs -Q --batch -l vhdl-navigator.el -f vhdl-nav--worker-main JOB-FILE
;; A discovery job (:discover t) answers with one (:files (...)) form; a
;; parse job (:files ...) answers with one (:file F :mtime M :defs (...))
;; form per file.  Structs print as #s(...), the same readable format the
;; persistent cache uses.

(cl-defstruct (vhdl-nav--run (:constructor vhdl-nav--run-create))
  "State of one parallel indexing run."
  root          ; project root
  procs         ; live worker process objects
  files         ; full ordered file list (once known)
  total         ; total files to parse (0 until discovery completes)
  done          ; files merged so far
  dispatched    ; non-nil once parse workers have been spawned
  start-time    ; for the completion message
  last-progress ; float-time of last progress message (throttle)
  priority-dir) ; directory whose files are parsed first, or nil

(defvar vhdl-nav--parallel-run nil
  "Current `vhdl-nav--run' struct, or nil when no workers are active.")

(defun vhdl-nav--effective-worker-count ()
  "Number of worker subprocesses to use, honoring `vhdl-nav-worker-count'."
  (cond ((or (null vhdl-nav-worker-count) (< vhdl-nav-worker-count 0)) 0)
        ((= vhdl-nav-worker-count 0) (max 1 (min 8 (1- (num-processors)))))
        (t vhdl-nav-worker-count)))

(defun vhdl-nav--emacs-binary ()
  "Path of the Emacs executable to use for worker subprocesses.
Prefers the running binary.  On Windows `invocation-name' may lack the
.exe suffix, or be runemacs.exe (the GUI launcher, which cannot run
batch jobs over pipes), so emacs.exe next to the running binary is
tried as well; PATH is only a last resort."
  (seq-find #'file-executable-p
            (delq nil
                  (list
                   (unless (string-prefix-p "runemacs"
                                            (downcase invocation-name))
                     (expand-file-name invocation-name invocation-directory))
                   (expand-file-name "emacs.exe" invocation-directory)
                   (expand-file-name "emacs" invocation-directory)
                   (executable-find "emacs")))))

(defun vhdl-nav--library ()
  "Path of this library, for workers to load."
  (or vhdl-nav--library-file (locate-library "vhdl-navigator")))

(defun vhdl-nav--parallel-available-p (root)
  "Return non-nil when subprocess indexing can be used for ROOT."
  (and (> (vhdl-nav--effective-worker-count) 0)
       (stringp root)
       (not (file-remote-p root))
       (vhdl-nav--library)
       (vhdl-nav--emacs-binary)))

(defvar vhdl-nav--worker-hint-shown nil
  "Non-nil once the worker-unavailable hint has been shown this session.")

(defun vhdl-nav--worker-unavailable-hint ()
  "Tell the user (once) that indexing fell back to the slow path."
  (unless vhdl-nav--worker-hint-shown
    (setq vhdl-nav--worker-hint-shown t)
    (message "vhdl-navigator: worker subprocesses unavailable - using slower in-process indexing (M-x vhdl-nav-worker-status to see why)")))

(defun vhdl-nav--current-vhdl-file ()
  "Return function `buffer-file-name' when visiting a VHDL file, else nil."
  (when (and buffer-file-name
             (let ((ext (file-name-extension buffer-file-name)))
               (and ext (member (downcase ext) vhdl-nav-file-extensions))))
    buffer-file-name))

(defun vhdl-nav--priority-dir ()
  "Directory of the current VHDL buffer, to be indexed first, or nil."
  (when-let ((f (vhdl-nav--current-vhdl-file)))
    (file-name-directory (expand-file-name f))))

(defun vhdl-nav--order-files (files priority-dir)
  "Return FILES with the ones under PRIORITY-DIR first."
  (if (not priority-dir)
      files
    (nconc (seq-filter (lambda (f) (string-prefix-p priority-dir f)) files)
           (seq-remove (lambda (f) (string-prefix-p priority-dir f)) files))))

(defun vhdl-nav--chunk-list (list n)
  "Split LIST into at most N contiguous chunks of nearly equal size."
  (let* ((size (max 1 (ceiling (length list) (max 1 n))))
         (chunks '()))
    (while list
      (push (seq-take list size) chunks)
      (setq list (nthcdr size list)))
    (nreverse chunks)))

(defun vhdl-nav--job-config (root)
  "Configuration plist shared by all worker jobs for ROOT."
  (list :root root
        :extensions vhdl-nav-file-extensions
        :folders-file vhdl-nav-folders-file
        :ignore-file vhdl-nav-ignore-file))

(defun vhdl-nav--write-job-file (job)
  "Write the JOB plist to a temp file and return its path."
  (let ((file (make-temp-file "vhdl-nav-job-" nil ".el"))
        (coding-system-for-write 'utf-8-unix)
        (print-level nil)
        (print-length nil))
    (with-temp-file file (prin1 job (current-buffer)))
    file))

(defun vhdl-nav--worker-main ()
  "Batch-mode entry point for indexing worker subprocesses.
Reads a job plist from the file named on the command line and prints
result forms on stdout for the parent Emacs to `read'."
  (let* ((job-file (car command-line-args-left))
         (job (let ((coding-system-for-read 'utf-8))
                (with-temp-buffer
                  (insert-file-contents job-file)
                  (read (current-buffer)))))
         (vhdl-nav-file-extensions (or (plist-get job :extensions)
                                       vhdl-nav-file-extensions))
         (vhdl-nav-folders-file (or (plist-get job :folders-file)
                                    vhdl-nav-folders-file))
         (vhdl-nav-ignore-file (or (plist-get job :ignore-file)
                                   vhdl-nav-ignore-file))
         (vhdl-nav-debug nil)
         (print-level nil)
         (print-length nil)
         (locale-coding-system 'utf-8))
    (setq command-line-args-left nil)
    (if (plist-get job :discover)
        (prin1 (list :files (vhdl-nav--find-vhdl-files (plist-get job :root))))
      (dolist (f (plist-get job :files))
        (prin1 (list :file f
                     :mtime (ignore-errors
                              (float-time
                               (file-attribute-modification-time
                                (file-attributes f))))
                     :defs (vhdl-nav--parse-file f)))
        (terpri)))
    (terpri)))

(defun vhdl-nav--spawn-worker (run job files kind)
  "Spawn one KIND worker subprocess for RUN, handing it the JOB plist.
FILES is the chunk this worker parses (nil for discovery).  Signals on
spawn failure so callers can fall back."
  (let* ((job-file (vhdl-nav--write-job-file job))
         (default-directory (vhdl-nav--run-root run))
         (errbuf (get-buffer-create " *vhdl-nav-worker-log*"))
         (proc (make-process
                :name (format "vhdl-nav-%s" kind)
                :command (list (vhdl-nav--emacs-binary) "-Q" "--batch"
                               "-l" (vhdl-nav--library)
                               "-f" "vhdl-nav--worker-main" job-file)
                :connection-type 'pipe
                :coding '(utf-8 . utf-8)
                :noquery t
                :stderr errbuf
                :filter #'vhdl-nav--worker-filter
                :sentinel #'vhdl-nav--worker-sentinel)))
    (when-let ((ep (get-buffer-process errbuf)))
      (set-process-query-on-exit-flag ep nil))
    (process-put proc 'vhdl-nav-run run)
    (process-put proc 'vhdl-nav-files files)
    (process-put proc 'vhdl-nav-job-file job-file)
    (push proc (vhdl-nav--run-procs run))
    proc))

(defun vhdl-nav--worker-filter (proc output)
  "Accumulate worker OUTPUT for PROC and merge complete printed forms.
Output is buffered in a hidden per-process buffer; forms are only read
once their terminating newline has arrived, so a large form split
across many pipe chunks is parsed exactly once.  Any read error is
treated as \"form still incomplete\" - a worker that truly produced
garbage simply never completes its forms, and the sentinel re-queues
its unreported files."
  (let ((buf (process-get proc 'vhdl-nav-buf)))
    (unless (buffer-live-p buf)
      (setq buf (generate-new-buffer " *vhdl-nav-worker-out*"))
      (process-put proc 'vhdl-nav-buf buf))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert output)
      ;; Each form is followed by a newline; don't even attempt a read
      ;; until one shows up.
      (when (string-match-p "\n" output)
        (let ((read-pos (point-min))
              (done nil))
          (goto-char read-pos)
          (while (not done)
            (condition-case nil
                (let ((form (read buf)))
                  (setq read-pos (point))
                  (vhdl-nav--worker-handle-form proc form))
              (error (setq done t))))
          ;; Drop consumed text so the buffer stays small.
          (delete-region (point-min) read-pos))))))

(defun vhdl-nav--worker-handle-form (proc form)
  "Dispatch one FORM read from worker PROC."
  (let ((run (process-get proc 'vhdl-nav-run)))
    (when (and (listp form)
               (vhdl-nav--run-p run)
               (eq run vhdl-nav--parallel-run))
      (cond
       ((plist-member form :file)
        (vhdl-nav--parallel-merge-file run proc form))
       ((plist-member form :files)
        (vhdl-nav--parallel-dispatch run (plist-get form :files)))))))

(defun vhdl-nav--parallel-merge-file (run proc form)
  "Merge one parsed-file FORM from PROC into RUN's project index."
  (let* ((root (vhdl-nav--run-root run))
         (index (gethash root vhdl-nav--project-indices))
         (mtimes (gethash root vhdl-nav--file-mtimes))
         (file (plist-get form :file))
         (mtime (plist-get form :mtime))
         (defs (plist-get form :defs)))
    (when (and index mtimes (stringp file))
      (vhdl-nav--purge-if-indexed index mtimes file)
      (when (numberp mtime) (puthash file mtime mtimes))
      (vhdl-nav--merge-defs index defs)
      (process-put proc 'vhdl-nav-files
                   (delete file (process-get proc 'vhdl-nav-files)))
      (cl-incf (vhdl-nav--run-done run))
      (let ((now (float-time)))
        (when (> (- now (vhdl-nav--run-last-progress run)) 1.0)
          (setf (vhdl-nav--run-last-progress run) now)
          (message "vhdl-navigator: indexing... %d/%d files"
                   (vhdl-nav--run-done run) (vhdl-nav--run-total run)))))))

(defun vhdl-nav--parallel-dispatch (run files)
  "Order FILES, set totals, and spawn the parse workers for RUN.
Signals on spawn failure; callers handle the fallback."
  (let* ((root (vhdl-nav--run-root run))
         (files (vhdl-nav--order-files files (vhdl-nav--run-priority-dir run))))
    (setf (vhdl-nav--run-files run) files
          (vhdl-nav--run-total run) (length files))
    (if (null files)
        (setf (vhdl-nav--run-dispatched run) t)
      (let ((chunks (vhdl-nav--chunk-list
                     files (min (vhdl-nav--effective-worker-count)
                                (length files))))
            (config (vhdl-nav--job-config root)))
        (dolist (chunk chunks)
          (vhdl-nav--spawn-worker run (append config (list :files chunk))
                                  chunk "parse"))
        (message "vhdl-navigator: indexing %d file(s) with %d worker process(es)..."
                 (length files) (length chunks))
        (setf (vhdl-nav--run-dispatched run) t)))))

(defun vhdl-nav--worker-sentinel (proc _event)
  "Clean up after worker PROC exits; finish or repair the run."
  (unless (process-live-p proc)
    (let ((run (process-get proc 'vhdl-nav-run))
          (job-file (process-get proc 'vhdl-nav-job-file))
          (remaining (process-get proc 'vhdl-nav-files))
          (buf (process-get proc 'vhdl-nav-buf)))
      (when job-file (ignore-errors (delete-file job-file)))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (and (vhdl-nav--run-p run) (eq run vhdl-nav--parallel-run))
        (setf (vhdl-nav--run-procs run)
              (delq proc (vhdl-nav--run-procs run)))
        ;; Files the worker never reported: hand them to the in-process
        ;; indexer so nothing is silently lost.
        (when remaining
          (message "vhdl-navigator: worker exited early, re-queueing %d file(s)"
                   (length remaining))
          (cl-decf (vhdl-nav--run-total run) (length remaining))
          (vhdl-nav--build-index-idle-files (vhdl-nav--run-root run) remaining))
        (unless (vhdl-nav--run-procs run)
          (if (vhdl-nav--run-dispatched run)
              (vhdl-nav--parallel-finish run)
            ;; Discovery worker died without delivering a file list.
            (setq vhdl-nav--parallel-run nil)
            (message "vhdl-navigator: background scan failed, falling back to in-process indexing")
            (let ((root (vhdl-nav--run-root run)))
              (vhdl-nav--build-index-idle-files
               root (or (vhdl-nav--run-files run)
                        (vhdl-nav--find-vhdl-files root))))))))))

(defun vhdl-nav--parallel-finish (run)
  "Finalize RUN: persist the cache and start file watchers."
  (when (eq run vhdl-nav--parallel-run)
    (setq vhdl-nav--parallel-run nil))
  (let ((root (vhdl-nav--run-root run)))
    (message "vhdl-navigator: indexing complete - %d file(s) in %.1fs"
             (vhdl-nav--run-done run)
             (float-time (time-since (vhdl-nav--run-start-time run))))
    (vhdl-nav--save-cache root)
    (vhdl-nav--setup-watchers-from-index root)))

(defun vhdl-nav--parallel-cancel ()
  "Kill any live worker subprocesses and discard the current run."
  (when vhdl-nav--parallel-run
    (let ((run vhdl-nav--parallel-run))
      ;; Clear first so sentinels see a stale run and do nothing.
      (setq vhdl-nav--parallel-run nil)
      (dolist (proc (vhdl-nav--run-procs run))
        (let ((jf (process-get proc 'vhdl-nav-job-file))
              (buf (process-get proc 'vhdl-nav-buf)))
          (when jf (ignore-errors (delete-file jf)))
          (when (buffer-live-p buf) (kill-buffer buf)))
        (when (process-live-p proc)
          (ignore-errors (delete-process proc)))))))

(defun vhdl-nav--build-index-parallel (root &optional files priority-dir)
  "Index ROOT using worker subprocesses.
With FILES, parse exactly those; otherwise a discovery worker scans
ROOT first so even the directory walk never blocks Emacs.  Files under
PRIORITY-DIR are parsed first.  Returns non-nil when the run started,
nil on spawn failure so callers can fall back to in-process indexing."
  (condition-case err
      (progn
        (vhdl-nav--parallel-cancel)
        (unless (gethash root vhdl-nav--project-indices)
          (puthash root (make-hash-table :test 'equal)
                   vhdl-nav--project-indices))
        (unless (gethash root vhdl-nav--file-mtimes)
          (puthash root (make-hash-table :test 'equal)
                   vhdl-nav--file-mtimes))
        (let ((run (vhdl-nav--run-create
                    :root root :total 0 :done 0
                    :start-time (current-time) :last-progress 0.0
                    :priority-dir priority-dir)))
          (setq vhdl-nav--parallel-run run)
          (if files
              (vhdl-nav--parallel-dispatch run files)
            (message "vhdl-navigator: scanning %s in the background..."
                     (abbreviate-file-name root))
            (vhdl-nav--spawn-worker
             run (append (vhdl-nav--job-config root) (list :discover t))
             nil "discover"))
          t))
    (error
     (message "vhdl-navigator: cannot start worker processes: %s" err)
     (vhdl-nav--parallel-cancel)
     nil)))

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

(defun vhdl-nav--idle-cancel ()
  "Cancel the in-process idle-timer indexing run, if any."
  (when vhdl-nav--async-timer
    (cancel-timer vhdl-nav--async-timer)
    (setq vhdl-nav--async-timer nil
          vhdl-nav--async-queue nil)))

(defun vhdl-nav--async-cancel ()
  "Cancel all in-progress indexing, idle-timer and subprocess based."
  (vhdl-nav--parallel-cancel)
  (vhdl-nav--idle-cancel))

(defun vhdl-nav--build-index-async (root)
  "Start full async indexing for project at ROOT.
File discovery itself is offloaded to a subprocess when possible,
because scanning a large tree can block Emacs for seconds."
  (unless (and (vhdl-nav--parallel-available-p root)
               (vhdl-nav--build-index-parallel root nil (vhdl-nav--priority-dir)))
    (vhdl-nav--build-index-async-files
     root
     (vhdl-nav--order-files (vhdl-nav--find-vhdl-files root)
                            (vhdl-nav--priority-dir)))))

(defun vhdl-nav--build-index-async-files (root files)
  "Index FILES for project at ROOT without blocking Emacs.
Routes large batches to parallel worker subprocesses when available;
small batches (and systems without workers) use the in-process
idle-timer indexer."
  (when files
    (unless (and (>= (length files) vhdl-nav-worker-min-files)
                 ;; Never stack a second parallel run onto the same root;
                 ;; extra files just take the in-process path meanwhile.
                 (not (and vhdl-nav--parallel-run
                           (equal (vhdl-nav--run-root vhdl-nav--parallel-run)
                                  root)))
                 (vhdl-nav--parallel-available-p root)
                 (vhdl-nav--build-index-parallel root files
                                                 (vhdl-nav--priority-dir)))
      (when (and (>= (length files) vhdl-nav-worker-min-files)
                 (not (vhdl-nav--parallel-available-p root)))
        (vhdl-nav--worker-unavailable-hint))
      (vhdl-nav--build-index-idle-files root files))))

(defun vhdl-nav--build-index-idle-files (root files)
  "In-process fallback: index FILES for ROOT in idle-timer batches.
Parses `vhdl-nav-index-batch-size' files per idle cycle.
Stale files are purged from the index before re-parsing.
If an async run for ROOT is already in progress, the new files are merged
into the existing queue rather than cancelling the ongoing work."
  (if (or (null files) (<= vhdl-nav-index-batch-size 0))
      ;; No files or sync mode: fall back to sync for just these files
      (when files
        (vhdl-nav--idle-cancel)
        (let ((index (or (gethash root vhdl-nav--project-indices)
                         (make-hash-table :test 'equal)))
              (mtimes (or (gethash root vhdl-nav--file-mtimes)
                          (make-hash-table :test 'equal)))
              (count 0))
          (dolist (f files)
            (vhdl-nav--purge-if-indexed index mtimes f)
            (setq count (+ count (vhdl-nav--index-file-into index mtimes f))))
          (puthash root index vhdl-nav--project-indices)
          (puthash root mtimes vhdl-nav--file-mtimes)
          (message "vhdl-navigator: updated %d definitions from %d files"
                   count (length files))
          (vhdl-nav--save-cache root)
          (vhdl-nav--setup-watchers-from-index root)))
    ;; Async path
    (if (and (equal vhdl-nav--async-root root) vhdl-nav--async-queue)
        ;; Same project already indexing - merge new files in to avoid
        ;; cancelling in-progress work.  Prepend so recent changes are
        ;; picked up in the next batch.
        (let ((new-files (seq-remove
                          (lambda (f) (member f vhdl-nav--async-queue))
                          files)))
          (when new-files
            (setq vhdl-nav--async-queue (append new-files vhdl-nav--async-queue))
            (cl-incf vhdl-nav--async-total (length new-files)))
          ;; Restart timer if it expired between batches
          (unless vhdl-nav--async-timer
            (setq vhdl-nav--async-timer
                  (run-with-idle-timer 0.5 nil #'vhdl-nav--async-index-batch))))
      ;; Different project or idle queue - start fresh
      (vhdl-nav--idle-cancel)
      (unless (gethash root vhdl-nav--file-mtimes)
        (puthash root (make-hash-table :test 'equal) vhdl-nav--file-mtimes))
      (setq vhdl-nav--async-root root
            vhdl-nav--async-queue files
            vhdl-nav--async-total (length files)
            vhdl-nav--async-count 0)
      (message "vhdl-navigator: async indexing %d file(s) in %s..."
               vhdl-nav--async-total (abbreviate-file-name root))
      (setq vhdl-nav--async-timer
            (run-with-idle-timer 0.5 nil #'vhdl-nav--async-index-batch)))))

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
    ;; User is idle - do work
    (if (null vhdl-nav--async-queue)
        ;; Done - save cache and clean up
        (let ((root vhdl-nav--async-root))
          (message "vhdl-navigator: async indexing complete - %d definitions from %d file(s)"
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
            (vhdl-nav--purge-if-indexed index mtimes f)
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
      (if (vhdl-nav--should-ignore-p root filepath)
          (remhash filepath mtimes)
        (vhdl-nav--index-file-into index mtimes filepath))
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
  (if vhdl-nav--parallel-run
      (message "vhdl-navigator: re-indexing in the background...")
    (message "vhdl-navigator: reindex complete")))

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

(defun vhdl-nav-worker-status ()
  "Report whether parallel worker indexing is available, and why not."
  (interactive)
  (let* ((root (vhdl-nav--project-root))
         (count (vhdl-nav--effective-worker-count))
         (bin (vhdl-nav--emacs-binary))
         (lib (vhdl-nav--library))
         (remote (and (stringp root) (file-remote-p root))))
    (message
     (concat "vhdl-navigator workers: %s\n"
             "  worker count : %d%s\n"
             "  emacs binary : %s\n"
             "  library      : %s\n"
             "  project root : %s%s")
     (if (vhdl-nav--parallel-available-p root) "AVAILABLE" "NOT AVAILABLE")
     count
     (if (zerop count) "  (disabled by vhdl-nav-worker-count)" "")
     (or bin "NOT FOUND - no emacs executable next to the running one or in PATH")
     (or lib "NOT FOUND - vhdl-navigator.el location unknown")
     root
     (if remote "  (remote - workers disabled)" ""))))

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
right after insertion - but only when the dot follows an identifier that
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
            (define-key map (kbd "C-c v w") #'vhdl-nav-worker-status)
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
