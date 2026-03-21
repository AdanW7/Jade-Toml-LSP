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
[format]
enabled = true
respect_trailing_commas = false

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

[diagnostics.templates.in_keys]
enabled = true
severity = "error"

[diagnostics.templates.inline_keys]
enabled = true
severity = "error"

[diagnostics.templates.in_headers]
enabled = true
severity = "error"
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
      format = {
        enabled = true,
        respect_trailing_commas = false,
      },
      diagnostics = {
        enabled = true,
        severity = "info",
        templates = {
          outside_quotes = { enabled = true, severity = "error" },
          missing_key = { enabled = true, severity = "warning" },
          cycle = { enabled = true, severity = "warning" },
          in_keys = { enabled = true, severity = "error" },
          inline_keys = { enabled = true, severity = "error" },
          in_headers = { enabled = true, severity = "error" },
        },
        templateOutsideQuotes = "error",
        templateMissingKey = "warning",
        templateCycle = "warning",
        templateInKeys = "error",
        templateInlineKeys = "error",
        templateInHeaders = "error",
      },
    },
  },
})
```

JSON settings mirror the TOML keys:

- `format.enabled`
- `format.respect_trailing_commas`
- `diagnostics.enabled`
- `diagnostics.severity`
- `diagnostics.templates.outside_quotes`
- `diagnostics.templates.missing_key`
- `diagnostics.templates.cycle`
- `diagnostics.templates.in_keys`
- `diagnostics.templates.inline_keys`
- `diagnostics.templates.in_headers`
- `diagnostics.templateOutsideQuotes`
- `diagnostics.templateMissingKey`
- `diagnostics.templateCycle`
- `diagnostics.templateInKeys`
- `diagnostics.templateInlineKeys`
- `diagnostics.templateInHeaders`
