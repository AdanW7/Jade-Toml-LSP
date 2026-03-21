# Jade

Zig 0.15.2 LSP scaffold using lsp-kit (0.15.x branch) for templated YAML/TOML.

## Goals
- Handle plain `.yaml`, `.yml`, and `.toml` files.
- Tolerate Jinja-style `{{ ... }}` blocks by masking them before parse.
- Provide diagnostics and (eventually) completions inside template blocks.

## Status
Minimal LSP loop (initialize + didOpen/didChange), document store, Jinja masking, TOML parsing diagnostics (via zig-toml), safe TOML formatting with template re-injection, and hover types from the parsed TOML AST.

Inspired by the structure of ZLS and superhtml, and built on lsp-kit.

## Config (jade.toml)
Create a `jade.toml` in your project root to configure the LSP:

```toml
format = true

[diagnostics]
enabled = true
severity = "warning" # "error" | "warning" | "info" | "hint" | "off"

[diagnostics.templates.outside_quotes]
enabled = true
severity = "error"

[diagnostics.templates.missing_key]
enabled = true
severity = "warning"

[diagnostics.templates.cycle]
enabled = true
severity = "warning"
```

The server searches upward from the file’s directory to find `jade.toml`.

## Build
```bash
zig build
```

## Run (stdio)
```bash
zig build run
```

## Neovim (local testing)
Build the binary once:

```bash
zig build
```

Then point `vim.lsp.config` to the built executable (adjust path if needed):

```lua
vim.lsp.config("jade", {
  cmd = { "/Users/adan/dotfiles/tools/jade/zig-out/bin/jade" },
  filetypes = { "toml", "yaml", "yml" },
  root_markers = { "jade.toml", ".git" },
})

vim.lsp.enable("jade")
```

If you want to pass LSP settings instead of `jade.toml`, use:

```lua
vim.lsp.config("jade", {
  cmd = { "/Users/adan/dotfiles/tools/jade/zig-out/bin/jade" },
  filetypes = { "toml", "yaml", "yml" },
  root_markers = { "jade.toml", ".git" },
  settings = {
    jade = {
      format = true,
      diagnostics = {
        enabled = true,
        severity = "info",
        templates = {
          outside_quotes = { enabled = true, severity = "error" },
          missing_key = { enabled = true, severity = "warning" },
          cycle = { enabled = true, severity = "warning" },
        },
        templateOutsideQuotes = "error",
        templateMissingKey = "warning",
        templateCycle = "warning",
      },
    },
  },
})
```
