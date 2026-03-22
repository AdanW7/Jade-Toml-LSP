# Jade TOML LSP

Repository: https://github.com/AdanW7/Jade-Toml-LSP

Jade TOML LSP brings language-server features for templated TOML

## What this extension provides
- TOML language registration and basic syntax highlighting.
- LSP features backed by the bundled `jade_toml_lsp` binary:
  - diagnostics
  - formatting
  - hover with types and resolved template values
  - completion inside `{{ ... }}` template blocks
  - references + go-to-definition for template references
  - inlay hints for templated values (optional)

## Configuration
Settings map directly to Jade’s LSP settings and `jade.toml`:

- `jade_toml_lsp.inlayHints.enabled`
- `jade_toml_lsp.format.enabled`
- `jade_toml_lsp.format.respect_trailing_commas`
- `jade_toml_lsp.diagnostics.enabled` (default: false)
- `jade_toml_lsp.diagnostics.severity`
- `jade_toml_lsp.diagnostics.templates.*`
