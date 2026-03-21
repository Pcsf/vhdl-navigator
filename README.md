# vhdl-navigator

A lightweight Emacs package for VHDL record field completion and go-to-definition.
Designed for Gaisler two-process style where records are pervasive.

## Features

- **Dot-completion for record fields** — type `r.` and get field candidates with type annotations via your completion framework (Corfu, Vertico, Company)
- **Nested record resolution** — `uarti.cfg.` resolves through `uart_in_type → cfg : uart_config_type → fields`
- **Go-to-definition** (`gd` / `M-.`) — jumps to the source of records, entities, architectures, signals, constants, variables, functions, procedures, and packages
- **Eldoc** — automatic minibuffer display of field types when cursor is after `.`
- **Project-wide indexing** — scans multi-level `src/` hierarchies, caches per-project, auto-reindexes on save

## Doom Emacs Installation

See `doom-integration.org` for copy-paste config blocks.

Quick version:

```
~/.config/doom/lisp/vhdl-navigator/
└── vhdl-navigator.el
```

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

| Action                   | Evil    | Emacs        |
|--------------------------|---------|--------------|
| Go to definition         | `gd`    | `M-.`        |
| Go back                  | `C-o`   | `M-,`        |
| Show record fields       | `SPC m r` | `C-c v r`  |
| Jump to record → field   | `SPC m j` | `C-c v j`  |
| List all definitions     | `SPC m l` | `C-c v l`  |
| Force reindex            | `SPC m i` | `C-c v i`  |
| Record field completion  | `.` then TAB | `.` then `C-M-i` |

## How It Works

On first activation, the package scans all `.vhd` / `.vhdl` files under the
project root, building a hash-table index of definitions. On each file save, only
that file is re-parsed (incremental). The index maps symbol names to location +
type metadata, which powers both the xref backend and the capf completion.

For dot-completion, the package walks backward from the cursor over the dot-chain
(`r.sub.field.`), resolves each segment's type through the index, and offers the
final record's fields as candidates.
