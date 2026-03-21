# Jade TOML LSP

Jade is a TOML LSP for templated configs.

uses Zig 0.15.2 and lsp-kit lib

Repository: https://github.com/AdanW7/Jade-Toml-LSP
Marketplace: https://marketplace.visualstudio.com/items?itemName=AdanW7.jade-toml-lsp



## Config (jade.toml)

Create a `jade.toml` in your project root to configure the LSP:

```toml
[format]
enabled = true
respect_trailing_commas = false

[diagnostics]
enabled = false
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

[inlay_hints]
enabled = false
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
vim.lsp.config("jade_toml_lsp", {
  cmd = { "jade_toml_lsp" },
  filetypes = { "toml" },
  root_markers = { "jade.toml", ".git" },
})

vim.lsp.enable("jade_toml_lsp")
```

If you want to pass LSP settings instead of `jade.toml`, use:

```lua
vim.lsp.config("jade_toml_lsp", {
  cmd = { "jade_toml_lsp" },
  filetypes = { "toml" },
  root_markers = { "jade.toml", ".git" },
  settings = {
    jade_toml_lsp = {
      format = {
        enabled = true,
        respect_trailing_commas = false,
      },
      diagnostics = {
        enabled = false,
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
      inlayHints = {
        enabled = false,
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
- `inlay_hints.enabled`
- `inlayHints.enabled`
