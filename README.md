# vhdl-navigator

A lightweight Emacs package for VHDL record field completion and go-to-definition.
Designed for Gaisler two-process style where records are pervasive.

## Features

- **Dot-completion for record fields** — type `r.` and get field candidates with type annotations; requires a completion frontend (Corfu or Company) for the inline popup — see [Installation](#installation)
- **Nested record resolution** — `uarti.cfg.` resolves through `uart_in_type → cfg : uart_config_type → fields`
- **Go-to-definition** (`gd` / `M-.`) — jumps to the source of records, entities, architectures, signals, constants, variables, functions, procedures, and packages
- **Eldoc** — automatic minibuffer display of field types when cursor is after `.`
- **Project-wide indexing** — scans multi-level `src/` hierarchies, caches per-project, auto-reindexes on save

## Installation

### Required: completion frontend for the inline popup

This package provides candidates through Emacs's standard
`completion-at-point` mechanism (capf). What renders those candidates as
an **inline dropdown** is a separate completion frontend. Without one,
Emacs shows the built-in `*Completions*` buffer instead of a popup.

**Doom Emacs** ships Corfu pre-configured — no extra steps needed.

**Vanilla Emacs** — install one of these:

```elisp
;; Option A: Corfu (lightweight, recommended)
(use-package corfu
  :ensure t
  :init (global-corfu-mode))

;; Option B: Company (classic, heavier)
(use-package company
  :ensure t
  :hook (vhdl-mode . company-mode))
```

`M-x package-install RET corfu RET` is enough if you do not use
`use-package`. Either one integrates with `completion-at-point`
automatically — no further configuration is needed for the dot-completion
to produce a popup.

### Vanilla Emacs (Linux, macOS, Windows)

See `emacs-integration.org` for full instructions (manual, use-package, straight.el).

Quick version — add to your `init.el`:
```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/vhdl-navigator/")
(require 'vhdl-navigator)
(add-hook 'vhdl-mode-hook #'vhdl-navigator-mode)
```

### Doom Emacs

See `doom-integration.org` for copy-paste config blocks.

Quick version:

`packages.el`:
```elisp
(package! vhdl-navigator
  :recipe (:local-repo "~/.config/doom/lisp/vhdl-navigator"
           :files ("*.el")))
```

`config.el`:
```elisp
(use-package! vhdl-navigator
  :after vhdl-mode
  :hook (vhdl-mode . vhdl-navigator-mode))
```

Then `doom sync` and restart the daemon.

## Key Bindings

The `C-c v` prefix works everywhere (vanilla Emacs, Doom, Windows, Linux).
Doom Evil users also get `SPC m` local-leader bindings via `doom-integration.org`.

| Action                   | Emacs        | Doom Evil (extra) |
|--------------------------|--------------|-------------------|
| Go to definition         | `M-.`        | `gd`              |
| Go back                  | `M-,`        | `C-o`             |
| Show record fields       | `C-c v r`    | `SPC m r`         |
| Jump to record → field   | `C-c v j`    | `SPC m j`         |
| List all definitions     | `C-c v l`    | `SPC m l`         |
| Force reindex            | `C-c v i`    | `SPC m i`         |
| Run diagnostics          | `C-c v d`    |                   |
| Record field completion  | `C-M-i`      | `.` then TAB      |

## How It Works

On first activation the package looks for a **persistent cache** on disk. If one
exists it is loaded and made active immediately — Emacs never scans the project
tree at startup. Features (completion, xref, Eldoc) are available from the first
keypress with whatever the cache contains.

**Three layers keep the index fresh without ever blocking the UI:**

1. **filenotify watchers** — as soon as the cache is installed the package
   registers OS-level file-system watchers on every directory that contains VHDL
   files. When a file is created, modified, or deleted (including by external tools
   such as git or a build system) the OS event is received, debounced for 1 second
   of idle quiet, and only the affected files are re-parsed in the background.
   This covers all changes that happen while Emacs is running.

2. **Deferred startup check** — to catch files that changed *between* Emacs
   sessions, a background idle-timer task runs after 2 seconds of idle time on
   startup. It compares on-disk modification times against the cached values and
   queues only the changed files for async re-indexing. If the user starts typing
   before it fires it reschedules itself. On network file-systems this check can
   be disabled entirely (see `vhdl-nav-startup-check` below).

3. **After-save hook** — any file edited and saved inside Emacs is always
   re-indexed immediately, regardless of the above two layers.

If no cache exists (first run), an empty index is installed and all project files
are parsed asynchronously in the background using idle timers (default 20 files
per idle cycle). Features work with whatever has been indexed so far.

The cache is stored under `~/.emacs.d/vhdl-navigator/` (one file per project,
named by MD5 of the project root). Set `vhdl-nav-cache-directory` to nil to
disable persistence.

## Configuration

| Variable                          | Default                            | Description                                                       |
|-----------------------------------|------------------------------------|-------------------------------------------------------------------|
| `vhdl-nav-file-extensions`        | `("vhd" "vhdl")`                  | File extensions to scan                                           |
| `vhdl-nav-auto-reindex-on-save`   | `t`                                | Re-index current file on save                                     |
| `vhdl-nav-completion-annotation`   | `t`                                | Show type annotations in completion candidates                    |
| `vhdl-nav-index-batch-size`        | `20`                               | Files parsed per idle cycle (0 = sync/blocking)                   |
| `vhdl-nav-cache-directory`         | `~/.emacs.d/vhdl-navigator/`      | Cache directory (nil = no persistence)                            |
| `vhdl-nav-startup-check`           | `t`                                | Check for between-session changes during idle time at startup     |
| `vhdl-nav-debug`                   | `nil`                              | Log parse details to `*Messages*`                                 |

Example tuning in `config.el`:
```elisp
;; Parse 50 files per idle tick (faster, slightly choppier)
(setq vhdl-nav-index-batch-size 50)

;; On NFS or other slow mounts: skip the idle-time mtime scan entirely.
;; filenotify and after-save-hook still keep the index up to date.
(setq vhdl-nav-startup-check nil)

;; Disable persistent cache
(setq vhdl-nav-cache-directory nil)
```
