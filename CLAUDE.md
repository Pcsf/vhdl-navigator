# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`vhdl-navigator.el` is a single-file Emacs Lisp package (minor mode) providing VHDL navigation for Doom Emacs. It targets projects written in the **Gaisler two-process style**, where records are pervasive and dot-chained field access is common.

Features: dot-completion for record fields (capf), go-to-definition via xref, Eldoc field-type display, and project-wide incremental indexing.

## Development

There are no build steps, test suite, or package manager. The package is pure Emacs Lisp — evaluate it directly or use Doom's `doom sync`.

**Load interactively for testing:**
```
M-x load-file RET /path/to/vhdl-navigator.el RET
```

**Enable debug logging:**
```elisp
(setq vhdl-nav-debug t)
```
This logs parse details to `*Messages*`.

**Force reindex:**
```
SPC m i  (or M-x vhdl-nav-reindex)
```

**Byte-compile to check for warnings:**
```
emacs --batch -f batch-byte-compile vhdl-navigator.el
```

## Architecture

The package is structured as a single file with these logical sections:

1. **Customization** — `defcustom` vars: `vhdl-nav-file-extensions`, `vhdl-nav-auto-reindex-on-save`, `vhdl-nav-completion-annotation`, `vhdl-nav-debug`, `vhdl-nav-index-batch-size`, `vhdl-nav-cache-directory`, `vhdl-nav-startup-check`.

2. **Data structure** — `vhdl-nav-def` (cl-defstruct) holds: `name`, `kind` (one of `record field entity architecture signal constant variable function procedure package type`), `type-name`, `parent`, `file`, `line`, `fields` (for records: list of `(field-name . type-string)`).

3. **Regex constants** — plain regex strings (no `rx` macro), all prefixed `vhdl-nav--re-*`. Matching is always done on the **downcased** line to handle VHDL case-insensitivity.

4. **Parser** (`vhdl-nav--parse-file`) — line-by-line state machine. The only stateful case is record parsing: `in-record` is set on `type NAME is record` and cleared on `end record`, accumulating fields in `record-fields`.

5. **Index** — two `make-hash-table :test 'equal` caches keyed by project root:
   - `vhdl-nav--project-indices`: root → index hash-table (name → list of `vhdl-nav-def`)
   - `vhdl-nav--file-mtimes`: root → (file → mtime) hash-table
   - Index stores *lists* of defs per name to handle duplicates across files.
   - Incremental reindex (`vhdl-nav--reindex-file`) removes all defs from a file then re-adds them.
   - **Persistent cache** (`vhdl-nav--save-cache` / `vhdl-nav--load-cache`): the full index + mtimes are serialized to `~/.emacs.d/vhdl-navigator/<md5>.el` via `prin1`/`read`. The cache is trusted immediately on load — no blocking scan. `vhdl-nav--diff-files` is only called later, from the deferred startup check. Cache is updated after async completion, sync rebuild, and single-file reindex.
   - **Async indexing** (`vhdl-nav--build-index-async-files`): files are parsed in batches of `vhdl-nav-index-batch-size` per idle timer tick (0.1s interval). This keeps the UI responsive for large projects. Features work with the partial index as it builds. A synchronous fallback (`vhdl-nav--build-index-sync`) is used for forced reindex or when batch size is 0.

6. **File-system watcher** (`vhdl-nav--watch-dirs` / `vhdl-nav--setup-watchers-from-index`): after the index is ready, `filenotify` watchers are registered on every directory that contains VHDL files. The callback (`vhdl-nav--watcher-callback`) filters events to VHDL files, writes them into a per-project queue, and schedules a 1 s per-project idle debounce. `vhdl-nav--flush-watcher-queue` then purges deleted files and calls `vhdl-nav--build-index-async-files` for changed/created ones. State: `vhdl-nav--watchers` (root → descriptor list), `vhdl-nav--watcher-debounces` (root → timer), `vhdl-nav--watcher-queue` (root → file→action hash).

7. **Deferred startup check** (`vhdl-nav--deferred-startup-check`): scheduled via `run-with-idle-timer` (2 s) after cache load to catch files changed between Emacs sessions. Calls `vhdl-nav--diff-files` only when idle; if the user starts typing it reschedules itself. Controlled by `vhdl-nav-startup-check` (set to nil to skip on slow mounts).

6. **Dot-chain resolver** — walks backward over `a.b.c.` from cursor, resolves each segment's type through the index via `vhdl-nav--resolve-type` → `vhdl-nav--strip-type-qualifiers` → `vhdl-nav--find-record`, then returns the final record's fields as capf candidates.

8. **xref backend** (`vhdl-nav--xref-backend`, `cl-defmethod xref-backend-definitions`) — looks up the symbol at point in the index and returns `xref-make` locations.

9. **Eldoc** — `vhdl-nav--eldoc-function` fires when cursor is after `.`, resolves the chain, and returns a field-type string.

10. **Dot-triggered completion** (`vhdl-nav--post-dot-completion`): a `post-self-insert-hook` that fires `completion-at-point` immediately after `.` is typed, but only when `vhdl-nav--dot-prefix` confirms the dot follows a resolvable identifier and the cursor is outside a comment or string. This is needed because most completion frontends (Corfu, Company) only auto-trigger after word characters and would otherwise ignore `.`.

11. **Minor mode** (`vhdl-navigator-mode`) — adds capf, xref backend, Eldoc function, `after-save-hook`, and the `post-self-insert-hook` for dot-triggered completion; removes them on disable. On enable, defers `vhdl-nav--get-index` to a 0.3 s idle timer (so the buffer opens instantly). On disable, tears down filenotify watchers only if no other `vhdl-navigator-mode` buffer in the same project remains open.

## Doom Emacs Installation

Copy `vhdl-navigator.el` to `~/.config/doom/lisp/vhdl-navigator/`, declare it in `packages.el` with `:local-repo`, configure in `config.el`, then `doom sync`. See `doom-integration.org` for complete copy-paste blocks.

## Key Design Decisions

- **No external dependencies** beyond `cl-lib`, `xref`, `project`, `seq` (all built-in since Emacs 28).
- **All parsing on downcased lines** — VHDL is case-insensitive; the index stores lowercase names.
- **Per-name lists in the index** — `(gethash name index)` returns a list, not a single def, to handle the same name in multiple files or kinds (e.g., a signal and a type with the same name).
- **`condition-case` at every level** — the parser never signals; errors are logged to `*Messages*` and parsing continues.
- **Project root via `project.el`** with fallback to `projectile-project-root` then `default-directory`.
