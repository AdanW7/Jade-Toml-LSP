const std = @import("std");
const lsp = @import("lsp");
const jade = @import("jade_toml_lsp");
const toml = @import("toml");

const types = lsp.types;
const FormatCommand = "jade_toml_lsp.formatToml";

const DiagnosticsSeverity = enum {
    off,
    err,
    warn,
    info,
    hint,
};

const DiagnosticsSettings = struct {
    enabled: bool = false,
    severity: DiagnosticsSeverity = .err,
    templates: TemplateDiagnosticsSettings = .{},
};

const FormatSettings = struct {
    enabled: bool = true,
    respect_trailing_commas: bool = false,
};

const InlayHintsSettings = struct {
    enabled: bool = false,
};

const TemplateDiagnosticsSettings = struct {
    outside_quotes: DiagnosticsRule = .{ .severity = .err },
    missing_key: DiagnosticsRule = .{ .severity = .warn },
    cycle: DiagnosticsRule = .{ .severity = .warn },
    in_keys: DiagnosticsRule = .{ .severity = .err },
    inline_keys: DiagnosticsRule = .{ .severity = .err },
    in_headers: DiagnosticsRule = .{ .severity = .err },
};

const DiagnosticsRule = struct {
    enabled: bool = true,
    severity: DiagnosticsSeverity = .warn,
};

const Settings = struct {
    diagnostics: DiagnosticsSettings = .{},
    format: FormatSettings = .{},
    inlay_hints: InlayHintsSettings = .{},
};

const Server = struct {
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    docs: *jade.DocumentStore,
    settings: Settings,

    pub fn initialize(
        handler: *Server,
        arena: std.mem.Allocator,
        params: types.InitializeParams,
    ) types.InitializeResult {
        _ = arena;

        handler.settings = .{};
        if (params.initializationOptions) |options| {
            applyJsonSettings(&handler.settings, options);
        }

        return .{
            .capabilities = .{
                .textDocumentSync = .{ .TextDocumentSyncKind = .Full },
                .documentFormattingProvider = .{ .bool = true },
                .codeActionProvider = .{ .bool = true },
                .executeCommandProvider = .{
                    .commands = &.{FormatCommand},
                },
                .completionProvider = .{
                    .triggerCharacters = &.{ "{", ".", " " },
                },
                .hoverProvider = .{ .bool = true },
                .definitionProvider = .{ .bool = true },
                .referencesProvider = .{ .bool = true },
                .inlayHintProvider = .{ .bool = true },
            },
            .serverInfo = .{
                .name = "jade_toml_lsp",
                .version = "0.0.1",
            },
        };
    }

    pub fn @"initialized"(handler: *Server, arena: std.mem.Allocator, params: types.InitializedParams) void {
        _ = handler;
        _ = arena;
        _ = params;
    }

    pub fn @"workspace/didChangeConfiguration"(
        handler: *Server,
        arena: std.mem.Allocator,
        params: types.DidChangeConfigurationParams,
    ) void {
        _ = arena;
        handler.settings = .{};
        applyJsonSettings(&handler.settings, params.settings);
    }

    pub fn @"textDocument/didOpen"(
        handler: *Server,
        arena: std.mem.Allocator,
        params: types.DidOpenTextDocumentParams,
    ) void {
        _ = arena;
        handler.handleText(params.textDocument.uri, params.textDocument.text);
    }

    pub fn @"textDocument/didChange"(
        handler: *Server,
        arena: std.mem.Allocator,
        params: types.DidChangeTextDocumentParams,
    ) void {
        _ = arena;
        if (params.contentChanges.len == 0) return;
        const text = extractChangeText(params.contentChanges[0]) orelse return;
        handler.handleText(params.textDocument.uri, text);
    }

    pub fn @"textDocument/formatting"(
        handler: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/formatting"),
    ) lsp.ResultType("textDocument/formatting") {
        const uri = params.textDocument.uri;
        if (!isTomlUri(uri)) return null;
        var settings = handler.settings;
        applyTomlSettingsForUri(handler.allocator, uri, &settings);
        if (!settings.format.enabled) return null;

        const text = handler.docs.get(uri) orelse return null;
        const formatted = handler.formatToml(arena, text, settings.format) orelse return null;

        const range = fullDocumentRange(text);
        const edit: types.TextEdit = .{
            .range = range,
            .newText = formatted,
        };
        return &.{edit};
    }

    pub fn @"textDocument/codeAction"(
        handler: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/codeAction"),
    ) lsp.ResultType("textDocument/codeAction") {
        const uri = params.textDocument.uri;
        if (!isTomlUri(uri)) return null;
        var settings = handler.settings;
        applyTomlSettingsForUri(handler.allocator, uri, &settings);
        if (!settings.format.enabled) return null;

        const text = handler.docs.get(uri) orelse return null;
        const formatted = handler.formatToml(arena, text, settings.format) orelse return null;

        const range = fullDocumentRange(text);
        const edit: types.TextEdit = .{
            .range = range,
            .newText = formatted,
        };

        var changes: std.json.ArrayHashMap([]const types.TextEdit) = .{};
        const edits = makeEditSlice(arena, edit) orelse return null;
        changes.map.put(arena, uri, edits) catch return null;

        const workspace_edit: types.WorkspaceEdit = .{
            .changes = changes,
        };

        const command: types.Command = .{
            .title = "Format TOML",
            .command = FormatCommand,
            .arguments = &.{std.json.Value{ .string = uri }},
        };

        const action: types.CodeAction = .{
            .title = "Format TOML",
            .kind = .{ .custom_value = "source.format" },
            .edit = workspace_edit,
            .command = command,
            .isPreferred = true,
        };

        return makeCodeActionResult(arena, action);
    }

    pub fn @"workspace/executeCommand"(
        handler: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("workspace/executeCommand"),
    ) lsp.ResultType("workspace/executeCommand") {
        const command = params.command;
        if (!std.mem.eql(u8, command, FormatCommand)) return null;

        const uri = extractUriFromArgs(params.arguments) orelse return null;
        if (!isTomlUri(uri)) return null;
        var settings = handler.settings;
        applyTomlSettingsForUri(handler.allocator, uri, &settings);
        if (!settings.format.enabled) return null;

        const text = handler.docs.get(uri) orelse return null;
        const formatted = handler.formatToml(arena, text, settings.format) orelse return null;

        const range = fullDocumentRange(text);
        const edit: types.TextEdit = .{
            .range = range,
            .newText = formatted,
        };

        var changes: std.json.ArrayHashMap([]const types.TextEdit) = .{};
        const edits = makeEditSlice(arena, edit) orelse return null;
        changes.map.put(arena, uri, edits) catch return null;

        const workspace_edit: types.WorkspaceEdit = .{
            .changes = changes,
        };

        handler.transport.writeNotification(
            handler.allocator,
            "workspace/applyEdit",
            types.ApplyWorkspaceEditParams,
            .{ .edit = workspace_edit },
            .{ .emit_null_optional_fields = false },
        ) catch {};

        return null;
    }

    pub fn @"textDocument/hover"(
        handler: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/hover"),
    ) lsp.ResultType("textDocument/hover") {
        const uri = params.textDocument.uri;
        if (!isTomlUri(uri)) return null;

        const text = handler.docs.get(uri) orelse return null;
        const line = params.position.line;
        const character = params.position.character;

        const line_text = jade.lineSlice(text, line) orelse return null;
        const span_mask = jade.maskJinja(arena, text) catch return null;
        defer arena.free(span_mask.masked);
        defer arena.free(span_mask.spans);

        const ml_mask = maskMultilineStrings(arena, text) catch return null;
        defer arena.free(ml_mask.masked);
        defer {
            for (ml_mask.placeholders) |ph| {
                arena.free(ph.token);
                arena.free(ph.original);
            }
            arena.free(ml_mask.placeholders);
        }

        const format_mask = jade.maskJinjaForFormatLenient(arena, ml_mask.masked) catch return null;
        defer arena.free(format_mask.masked);
        defer {
            for (format_mask.placeholders) |ph| {
                arena.free(ph.token);
                arena.free(ph.original);
            }
            arena.free(format_mask.placeholders);
        }

        const float_mask = maskSpecialFloats(arena, format_mask.masked) catch return null;
        defer arena.free(float_mask.masked);
        defer {
            for (float_mask.placeholders) |ph| {
                arena.free(ph.token);
                arena.free(ph.original);
            }
            arena.free(float_mask.placeholders);
        }

        const unicode_masked = normalizeUnicodeEscapes(arena, float_mask.masked) catch return null;
        defer arena.free(unicode_masked);

        const combined_placeholders = mergePlaceholders(arena, format_mask.placeholders, float_mask.placeholders) catch return null;
        const combined_placeholders2 = mergePlaceholders(arena, combined_placeholders, ml_mask.placeholders) catch return null;
        defer arena.free(combined_placeholders);
        defer arena.free(combined_placeholders2);

        const span = jade.errorSpan(line_text, character);
        const hover = handler.resolveHoverInfo(
            arena,
            unicode_masked,
            text,
            line,
            character,
            span_mask.spans,
            combined_placeholders2,
        ) orelse return null;
        const message = std.fmt.allocPrint(
            arena,
            "type: {s}\nvalue: {s}\nkey: {s}\ntable: {s}",
            .{ hover.ty, hover.value, hover.key, hover.table },
        ) catch return null;

        return .{
            .contents = .{
                .MarkupContent = .{
                    .kind = .plaintext,
                    .value = message,
                },
            },
            .range = .{
                .start = .{ .line = @intCast(line), .character = @intCast(span.start) },
                .end = .{ .line = @intCast(line), .character = @intCast(span.end) },
            },
        };
    }

    pub fn @"textDocument/completion"(
        handler: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/completion"),
    ) lsp.ResultType("textDocument/completion") {
        const uri = params.textDocument.uri;
        if (!isTomlUri(uri)) return null;

        const text = handler.docs.get(uri) orelse return null;
        const line = params.position.line;
        const character = params.position.character;

        const spans = jade.templateSpans(arena, text) catch return null;
        defer arena.free(spans);

        const ctx = templateCompletionContext(arena, text, spans, line, character) orelse return null;
        defer arena.free(ctx.base_path);

        const ml_mask = maskMultilineStrings(arena, text) catch return null;
        defer arena.free(ml_mask.masked);
        defer {
            for (ml_mask.placeholders) |ph| {
                arena.free(ph.token);
                arena.free(ph.original);
            }
            arena.free(ml_mask.placeholders);
        }

        const masked_lenient = jade.maskJinjaForFormatLenient(arena, ml_mask.masked) catch return null;
        defer arena.free(masked_lenient.masked);
        defer {
            for (masked_lenient.placeholders) |ph| {
                arena.free(ph.token);
                arena.free(ph.original);
            }
            arena.free(masked_lenient.placeholders);
        }

        const float_mask = maskSpecialFloats(arena, masked_lenient.masked) catch return null;
        defer arena.free(float_mask.masked);
        defer {
            for (float_mask.placeholders) |ph| {
                arena.free(ph.token);
                arena.free(ph.original);
            }
            arena.free(float_mask.placeholders);
        }

        const unicode_masked = normalizeUnicodeEscapes(arena, float_mask.masked) catch return null;
        defer arena.free(unicode_masked);

        var parser = toml.Parser(toml.Table).init(arena);
        defer parser.deinit();
        const parsed = parser.parseString(unicode_masked) catch return null;
        defer parsed.deinit();

        const table = completionTableForPath(parsed.value, ctx.base_path) orelse return null;
        const items = buildCompletionItems(arena, table, ctx.prefix) orelse return null;

        const list: types.CompletionList = .{
            .isIncomplete = false,
            .items = items,
        };

        return .{ .CompletionList = list };
    }

    pub fn @"textDocument/inlayHint"(
        handler: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/inlayHint"),
    ) lsp.ResultType("textDocument/inlayHint") {
        const uri = params.textDocument.uri;
        if (!isTomlUri(uri)) return null;

        var settings = handler.settings;
        applyTomlSettingsForUri(handler.allocator, uri, &settings);
        if (!settings.inlay_hints.enabled) return null;

        const text = handler.docs.get(uri) orelse return null;

        const spans = jade.templateSpans(arena, text) catch return null;
        defer arena.free(spans);

        const ml_mask = maskMultilineStrings(arena, text) catch return null;
        defer arena.free(ml_mask.masked);
        defer {
            for (ml_mask.placeholders) |ph| {
                arena.free(ph.token);
                arena.free(ph.original);
            }
            arena.free(ml_mask.placeholders);
        }

        const masked_lenient = jade.maskJinjaForFormatLenient(arena, ml_mask.masked) catch return null;
        defer arena.free(masked_lenient.masked);
        defer {
            for (masked_lenient.placeholders) |ph| {
                arena.free(ph.token);
                arena.free(ph.original);
            }
            arena.free(masked_lenient.placeholders);
        }

        const float_mask = maskSpecialFloats(arena, masked_lenient.masked) catch return null;
        defer arena.free(float_mask.masked);
        defer {
            for (float_mask.placeholders) |ph| {
                arena.free(ph.token);
                arena.free(ph.original);
            }
            arena.free(float_mask.placeholders);
        }

        const unicode_masked = normalizeUnicodeEscapes(arena, float_mask.masked) catch return null;
        defer arena.free(unicode_masked);

        const combined_placeholders = mergePlaceholders(arena, masked_lenient.placeholders, float_mask.placeholders) catch return null;
        const combined_placeholders2 = mergePlaceholders(arena, combined_placeholders, ml_mask.placeholders) catch return null;
        defer arena.free(combined_placeholders);
        defer arena.free(combined_placeholders2);

        var parser = toml.Parser(toml.Table).init(arena);
        defer parser.deinit();
        const parsed = parser.parseString(unicode_masked) catch return null;
        defer parsed.deinit();

        var hints: std.ArrayList(types.InlayHint) = .empty;
        defer hints.deinit(arena);

        for (spans) |span| {
            if (!span.in_quotes) continue;
            if (spanInLineComment(text, span)) continue;

            const insert_idx = templateInlayIndex(text, span) orelse continue;
            const insert_pos = positionFromIndex(text, insert_idx);
            if (!positionInRange(insert_pos, params.range)) continue;

            const path = extractTemplatePath(arena, text, span) orelse continue;
            defer arena.free(path);
            const value = lookupTomlValue(parsed.value, path) orelse continue;

            const display_value = inlayValueText(arena, value, combined_placeholders2, parsed.value) orelse continue;
            const label = std.fmt.allocPrint(arena, ": {s}", .{display_value}) catch return null;

            hints.append(arena, .{
                .position = .{
                    .line = @intCast(insert_pos.line),
                    .character = @intCast(insert_pos.character),
                },
                .label = .{ .string = label },
                .kind = .Type,
                .paddingLeft = true,
                .paddingRight = true,
            }) catch return null;
        }

        if (hints.items.len == 0) return null;
        return hints.toOwnedSlice(arena) catch null;
    }

    pub fn @"textDocument/definition"(
        handler: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/definition"),
    ) lsp.ResultType("textDocument/definition") {
        const uri = params.textDocument.uri;
        if (!isTomlUri(uri)) return null;

        const text = handler.docs.get(uri) orelse return null;
        const line = params.position.line;
        const character = params.position.character;

        const spans = jade.templateSpans(arena, text) catch return null;
        defer arena.free(spans);

        const idx = positionToIndex(text, line, character);
        const span = findTemplateSpanAtIndex(spans, idx) orelse return null;
        if (!span.in_quotes) return null;

        const path = extractTemplatePath(arena, text, span) orelse return null;
        defer arena.free(path);

        const range = findKeyDefinitionRange(arena, text, path) orelse return null;

        const location: types.Location = .{
            .uri = uri,
            .range = range,
        };

        return makeDefinitionResult(arena, location);
    }

    pub fn @"textDocument/references"(
        handler: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/references"),
    ) lsp.ResultType("textDocument/references") {
        const uri = params.textDocument.uri;
        if (!isTomlUri(uri)) return null;

        const text = handler.docs.get(uri) orelse return null;
        const line = params.position.line;
        const character = params.position.character;

        const spans = jade.templateSpans(arena, text) catch return null;
        defer arena.free(spans);

        var path: [][]const u8 = undefined;
        if (inTemplateAtFromSpans(spans, text, @intCast(line), @intCast(character))) |span| {
            path = extractTemplatePath(arena, text, span) orelse return null;
        } else if (inlineTableHoverInfo(arena, text, line, character)) |inline_info| {
            path = inline_info.path;
        } else {
            path = resolveKeyPathAt(arena, text, line, character) orelse return null;
        }
        defer arena.free(path);

        var locations: std.ArrayList(types.Location) = .empty;
        defer locations.deinit(arena);

        if (collectKeyReferenceRanges(arena, text, path)) |ranges| {
            defer arena.free(ranges);
            for (ranges) |range| {
                locations.append(arena, .{ .uri = uri, .range = range }) catch {};
            }
        }

        if (collectTemplateReferenceRanges(arena, text, spans, path)) |ranges| {
            defer arena.free(ranges);
            for (ranges) |range| {
                locations.append(arena, .{ .uri = uri, .range = range }) catch {};
            }
        }

        if (locations.items.len == 0) return null;
        return locations.toOwnedSlice(arena) catch null;
    }

    fn handleText(handler: *Server, uri: []const u8, text: []const u8) void {
        handler.docs.set(uri, text) catch return;

        var settings = handler.settings;
        applyTomlSettingsForUri(handler.allocator, uri, &settings);
        if (!settings.diagnostics.enabled or settings.diagnostics.severity == .off) {
            handler.publishDiagnostics(uri, &.{});
            return;
        }

        const masked = jade.maskJinja(handler.allocator, text) catch return;
        defer handler.allocator.free(masked.masked);
        defer handler.allocator.free(masked.spans);

        const ml_mask = maskMultilineStrings(handler.allocator, text) catch return;
        defer handler.allocator.free(ml_mask.masked);
        defer {
            for (ml_mask.placeholders) |ph| {
                handler.allocator.free(ph.token);
                handler.allocator.free(ph.original);
            }
            handler.allocator.free(ml_mask.placeholders);
        }

        const masked_lenient = jade.maskJinjaForFormatLenient(handler.allocator, ml_mask.masked) catch return;
        defer handler.allocator.free(masked_lenient.masked);
        defer {
            for (masked_lenient.placeholders) |ph| {
                handler.allocator.free(ph.token);
                handler.allocator.free(ph.original);
            }
            handler.allocator.free(masked_lenient.placeholders);
        }

        const float_mask = maskSpecialFloats(handler.allocator, masked_lenient.masked) catch return;
        defer handler.allocator.free(float_mask.masked);
        defer {
            for (float_mask.placeholders) |ph| {
                handler.allocator.free(ph.token);
                handler.allocator.free(ph.original);
            }
            handler.allocator.free(float_mask.placeholders);
        }

        const unicode_masked = normalizeUnicodeEscapes(handler.allocator, float_mask.masked) catch return;
        defer handler.allocator.free(unicode_masked);

        const combined_placeholders = mergePlaceholders(handler.allocator, masked_lenient.placeholders, float_mask.placeholders) catch return;
        const combined_placeholders2 = mergePlaceholders(handler.allocator, combined_placeholders, ml_mask.placeholders) catch return;
        defer handler.allocator.free(combined_placeholders);
        defer handler.allocator.free(combined_placeholders2);

        const template_spans = jade.templateSpans(handler.allocator, text) catch return;
        defer handler.allocator.free(template_spans);

        var diagnostics: std.ArrayList(types.Diagnostic) = .empty;
        defer diagnostics.deinit(handler.allocator);
        var allocated_messages: std.ArrayList([]u8) = .empty;
        defer {
            for (allocated_messages.items) |msg| {
                handler.allocator.free(msg);
            }
            allocated_messages.deinit(handler.allocator);
        }

        if (envFlagEnabled(handler.allocator, "JADE_DEBUG_DIAGNOSTICS")) {
            std.debug.print("jade_toml_lsp diagnostics: spans={d} uri={s}\n", .{ template_spans.len, uri });
            if (jade.lineSlice(text, 0)) |lt| {
                const span = jade.errorSpan(lt, 0);
                const message = std.fmt.allocPrint(handler.allocator, "jade_toml_lsp debug diagnostic", .{}) catch return;
                allocated_messages.append(handler.allocator, message) catch return;
                diagnostics.append(handler.allocator, .{
                    .range = .{
                        .start = .{ .line = 0, .character = @intCast(span.start) },
                        .end = .{ .line = 0, .character = @intCast(span.end) },
                    },
                    .severity = .Information,
                    .source = "jade_toml_lsp",
                    .message = message,
                }) catch {};
            }
        }

        if (isTomlUri(uri)) {
            if (settings.diagnostics.templates.outside_quotes.enabled) {
                for (template_spans) |span| {
                    if (span.in_quotes) continue;
                    if (spanInLineComment(text, span)) continue;
                    if (templateOutsideQuotesDiagnostic(
                        handler.allocator,
                        text,
                        span,
                        settings.diagnostics.templates.outside_quotes.severity,
                        &allocated_messages,
                    )) |diag| {
                        diagnostics.append(handler.allocator, diag) catch {};
                    }
                }
            }

            if (settings.diagnostics.templates.in_headers.enabled or settings.diagnostics.templates.inline_keys.enabled or settings.diagnostics.templates.in_keys.enabled) {
                for (template_spans) |span| {
                    if (spanInLineComment(text, span)) continue;
                    if (settings.diagnostics.templates.in_headers.enabled and templateSpanInTableHeader(text, span)) {
                        if (templateHeaderDiagnostic(
                            handler.allocator,
                            text,
                            span,
                            settings.diagnostics.templates.in_headers.severity,
                            &allocated_messages,
                        )) |diag| {
                            diagnostics.append(handler.allocator, diag) catch {};
                        }
                        continue;
                    }
                    if (settings.diagnostics.templates.inline_keys.enabled and templateSpanInInlineTableKey(handler.allocator, text, span)) {
                        if (templateInlineKeyDiagnostic(
                            handler.allocator,
                            text,
                            span,
                            settings.diagnostics.templates.inline_keys.severity,
                            &allocated_messages,
                        )) |diag| {
                            diagnostics.append(handler.allocator, diag) catch {};
                        }
                        continue;
                    }
                    if (settings.diagnostics.templates.in_keys.enabled and templateSpanInAssignmentKey(text, span)) {
                        if (templateKeyDiagnostic(
                            handler.allocator,
                            text,
                            span,
                            settings.diagnostics.templates.in_keys.severity,
                            &allocated_messages,
                        )) |diag| {
                            diagnostics.append(handler.allocator, diag) catch {};
                        }
                    }
                }
            }

            var parser = toml.Parser(toml.Table).init(handler.allocator);
            defer parser.deinit();

            const parsed = parser.parseString(unicode_masked) catch |err| {
                if (parser.error_info) |info| {
                    switch (info) {
                        .parse => |pos| {
                            if (jade.isMaskedPosition(masked.spans, text, pos.line, pos.pos)) {
                                handler.publishDiagnostics(uri, diagnostics.items);
                                return;
                            }

                            const diag = templatedTomlDiagnostic(
                                handler.allocator,
                                pos,
                                text,
                                err,
                                &allocated_messages,
                                settings.diagnostics.severity,
                            ) catch null;
                            if (diag) |d| diagnostics.append(handler.allocator, d) catch {};
                        },
                        .struct_mapping => {},
                    }
                }
                handler.publishDiagnostics(uri, diagnostics.items);
                return;
            };
            defer parsed.deinit();

            if (settings.diagnostics.templates.missing_key.enabled) {
                for (template_spans) |span| {
                    if (!span.in_quotes) continue;
                    if (spanInLineComment(text, span)) continue;
                    if (templateSpanInTableHeader(text, span)) continue;
                    if (templateSpanInAssignmentKey(text, span)) continue;
                    if (templateSpanInInlineTableKey(handler.allocator, text, span)) continue;
                    if (templateMissingKeyDiagnostic(
                        handler.allocator,
                        text,
                        span,
                        parsed.value,
                        settings.diagnostics.templates.missing_key.severity,
                        &allocated_messages,
                    )) |diag| {
                        diagnostics.append(handler.allocator, diag) catch {};
                    }
                }
            }

            if (settings.diagnostics.templates.cycle.enabled) {
                var cycle_parser = toml.Parser(toml.Table).init(handler.allocator);
                defer cycle_parser.deinit();
                const cycle_parsed = cycle_parser.parseString(unicode_masked) catch {
                    handler.publishDiagnostics(uri, diagnostics.items);
                    return;
                };
                defer cycle_parsed.deinit();

                for (template_spans) |span| {
                    if (!span.in_quotes) continue;
                    if (spanInLineComment(text, span)) continue;
                    if (templateCycleDiagnostic(
                        handler.allocator,
                        text,
                        span,
                        cycle_parsed.value,
                        combined_placeholders2,
                        settings.diagnostics.templates.cycle.severity,
                        &allocated_messages,
                    )) |diag| {
                        diagnostics.append(handler.allocator, diag) catch {};
                    }
                }
            }

            if (collectKeyConflictDiagnostics(
                handler.allocator,
                text,
                settings.diagnostics.severity,
                &allocated_messages,
            )) |conflicts| {
                defer handler.allocator.free(conflicts);
                for (conflicts) |diag| {
                    diagnostics.append(handler.allocator, diag) catch {};
                }
            }

            if (collectInlineTableDiagnostics(
                handler.allocator,
                text,
                settings.diagnostics.severity,
                &allocated_messages,
            )) |inline_diags| {
                defer handler.allocator.free(inline_diags);
                for (inline_diags) |diag| {
                    diagnostics.append(handler.allocator, diag) catch {};
                }
            }

            if (collectCommentControlCharDiagnostics(
                handler.allocator,
                text,
                settings.diagnostics.severity,
                &allocated_messages,
            )) |comment_diags| {
                defer handler.allocator.free(comment_diags);
                for (comment_diags) |diag| {
                    diagnostics.append(handler.allocator, diag) catch {};
                }
            }

            if (collectArrayTableOrderingDiagnostics(
                handler.allocator,
                text,
                settings.diagnostics.severity,
                &allocated_messages,
            )) |order_diags| {
                defer handler.allocator.free(order_diags);
                for (order_diags) |diag| {
                    diagnostics.append(handler.allocator, diag) catch {};
                }
            }
        }

        if (envFlagEnabled(handler.allocator, "JADE_DEBUG_DIAGNOSTICS")) {
            std.debug.print("jade_toml_lsp diagnostics: count={d} uri={s}\n", .{ diagnostics.items.len, uri });
        }

        handler.publishDiagnostics(uri, diagnostics.items);
    }

fn publishDiagnostics(handler: *Server, uri: []const u8, diagnostics: []const types.Diagnostic) void {
        const payload: types.PublishDiagnosticsParams = .{
            .uri = uri,
            .diagnostics = diagnostics,
        };

        handler.transport.writeNotification(
            handler.allocator,
            "textDocument/publishDiagnostics",
            types.PublishDiagnosticsParams,
            payload,
            .{ .emit_null_optional_fields = false },
        ) catch |err| {
            if (envFlagEnabled(handler.allocator, "JADE_DEBUG_DIAGNOSTICS")) {
                std.debug.print("jade_toml_lsp publish diagnostics error: {s}\n", .{@errorName(err)});
            }
        };
    }

    fn formatToml(handler: *Server, allocator: std.mem.Allocator, text: []const u8, format_settings: FormatSettings) ?[]u8 {
        _ = handler;
        return formatTomlText(allocator, text, format_settings);
    }

    fn resolveHoverInfo(
        handler: *Server,
        arena: std.mem.Allocator,
        masked_text: []const u8,
        full_text: []const u8,
        line: usize,
        character: usize,
        spans: []const jade.Span,
        placeholders: []const jade.Placeholder,
    ) ?HoverInfo {
        _ = handler;
        var parser = toml.Parser(toml.Table).init(arena);
        defer parser.deinit();

        const parsed = parser.parseString(masked_text) catch return null;
        defer parsed.deinit();

        if (tableHeaderInfo(arena, full_text, line)) |header| {
            const name = header.name;
            const value_text = if (header.index) |idx|
                std.fmt.allocPrint(arena, "{s}[{d}]", .{ name, idx }) catch return null
            else
                name;
        return .{
            .ty = "table",
            .value = value_text,
            .key = value_text,
            .table = value_text,
        };
        }

        const template_span = inTemplateAt(spans, full_text, @intCast(line), @intCast(character));

        const array_ctx = arrayHeaderContext(arena, full_text, line);

        if (arrayItemInfo(arena, full_text, line, character)) |array_info| {
            defer arena.free(array_info.path);
            const value = lookupTomlValueWithContext(parsed.value, array_info.path, array_ctx) orelse return null;
            if (value == .array) {
                const ar = value.array;
                if (array_info.index < ar.items.len) {
                    const item = ar.items[array_info.index];
                    var value_text: []const u8 = undefined;
                    if (template_span) |span| {
                        if (extractTemplatePath(arena, full_text, span)) |template_path| {
                            defer arena.free(template_path);
                            if (lookupTomlValue(parsed.value, template_path)) |expanded| {
                                value_text = tomlValueString(arena, expanded) orelse return null;
                            } else {
                                value_text = tomlValueString(arena, item) orelse return null;
                            }
                        } else {
                            value_text = tomlValueString(arena, item) orelse return null;
                        }
                    } else {
                        value_text = tomlValueStringExpanded(arena, item, placeholders, parsed.value) catch return null;
                    }
                    const key_name = formatArrayKeyName(arena, array_info.path, array_info.index) orelse "";
                    const table_name = tableNameWithArrayContext(arena, array_info.path, array_ctx) orelse "";
                    return .{
                        .ty = tomlValueTypeExpanded(item, placeholders),
                        .value = value_text,
                        .key = key_name,
                        .table = table_name,
                    };
                }
            }
        }

        if (inlineTableHoverInfo(arena, full_text, line, character)) |inline_info| {
            defer arena.free(inline_info.path);
            const value = lookupTomlValueWithContext(parsed.value, inline_info.path, array_ctx) orelse return null;
            const value_text = if (template_span) |span|
                blk: {
                    if (extractTemplatePath(arena, full_text, span)) |template_path| {
                        defer arena.free(template_path);
                        if (lookupTomlValue(parsed.value, template_path)) |expanded| {
                            break :blk tomlValueString(arena, expanded) orelse return null;
                        }
                    }
                    break :blk tomlValueStringExpanded(arena, value, placeholders, parsed.value) catch return null;
                }
            else
                tomlValueStringExpanded(arena, value, placeholders, parsed.value) catch return null;

            const key_name = pathToKeyName(arena, inline_info.path) orelse "";
            const table_name = tableNameWithArrayContext(arena, inline_info.path, array_ctx) orelse "";
            return .{
                .ty = tomlValueTypeExpanded(value, placeholders),
                .value = value_text,
                .key = key_name,
                .table = table_name,
            };
        }

        const key_path = resolveKeyPathAt(arena, full_text, line, character) orelse return null;
        defer arena.free(key_path);

        const value = lookupTomlValueWithContext(parsed.value, key_path, array_ctx) orelse return null;
        const value_text = tomlValueStringExpanded(arena, value, placeholders, parsed.value) catch return null;

        const key_name = pathToKeyName(arena, key_path) orelse "";
        const table_name = tableNameWithArrayContext(arena, key_path, array_ctx) orelse "";

        if (template_span) |span| {
            if (extractTemplatePath(arena, full_text, span)) |template_path| {
                defer arena.free(template_path);
                if (lookupTomlValue(parsed.value, template_path)) |expanded| {
                    const expanded_text = tomlValueStringExpanded(arena, expanded, placeholders, parsed.value) catch return null;
                    return .{
                        .ty = tomlValueTypeExpanded(value, placeholders),
                        .value = expanded_text,
                        .key = key_name,
                        .table = table_name,
                    };
                }
            }
        }

        return .{
            .ty = tomlValueTypeExpanded(value, placeholders),
            .value = value_text,
            .key = key_name,
            .table = table_name,
        };
    }

    pub fn onResponse(handler: *Server, arena: std.mem.Allocator, response: lsp.JsonRPCMessage.Response) void {
        _ = handler;
        _ = arena;
        _ = response;
    }
};

fn templatedTomlDiagnostic(
    allocator: std.mem.Allocator,
    pos: toml.Position,
    text: []const u8,
    err: anyerror,
    allocated_messages: *std.ArrayList([]u8),
    severity: DiagnosticsSeverity,
) !types.Diagnostic {
    const line = if (pos.line > 0) pos.line - 1 else 0;
    const character = if (pos.pos > 0) pos.pos - 1 else 0;
    const line_text = jade.lineSlice(text, line) orelse "";
    const span = jade.errorSpan(line_text, character);
    const message = try std.fmt.allocPrint(allocator, "TOML parse error: {s}", .{parseErrorMessage(err)});
    try allocated_messages.append(allocator, message);

    return .{
        .range = .{
            .start = .{ .line = @intCast(line), .character = @intCast(span.start) },
            .end = .{ .line = @intCast(line), .character = @intCast(span.end) },
        },
        .severity = diagnosticSeverityToLsp(severity),
        .source = "jade_toml_lsp",
        .message = message,
    };
}

fn parseErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnexpectedToken => "Unexpected token",
        error.UnexpectedEOF => "Unexpected end of file",
        error.InvalidCharacter => "Invalid character",
        error.InvalidEscape => "Invalid escape sequence",
        error.InvalidUnicode => "Invalid unicode escape",
        error.UnexpectedMultilineString => "Unexpected multiline string",
        error.CannotParseValue => "Cannot parse value",
        error.FieldTypeRedifinition => "Key redefined with a different type",
        error.InvalidTimeOffset => "Invalid time offset",
        error.InvalidTime => "Invalid time",
        error.InvalidYear => "Invalid year",
        error.InvalidMonth => "Invalid month",
        error.InvalidDay => "Invalid day",
        error.InvalidHour => "Invalid hour",
        error.InvalidMinute => "Invalid minute",
        error.InvalidSecond => "Invalid second",
        error.InvalidNanoSecond => "Invalid fractional seconds",
        else => @errorName(err),
    };
}

fn templateOutsideQuotesDiagnostic(
    allocator: std.mem.Allocator,
    text: []const u8,
    span: jade.TemplateSpan,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?types.Diagnostic {
    const range = rangeFromSpan(text, span.start, span.end);
    const message = std.fmt.allocPrint(allocator, "Template must be inside quotes", .{}) catch return null;
    allocated_messages.append(allocator, message) catch return null;

    return .{
        .range = range,
        .severity = diagnosticSeverityToLsp(severity),
        .source = "jade_toml_lsp",
        .message = message,
    };
}

fn templateMissingKeyDiagnostic(
    allocator: std.mem.Allocator,
    text: []const u8,
    span: jade.TemplateSpan,
    root: toml.Table,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?types.Diagnostic {
    const path = extractTemplatePath(allocator, text, span) orelse return null;
    defer allocator.free(path);

    if (lookupTomlValue(root, path) != null) return null;

    const range = rangeFromSpan(text, span.start, span.end);
    const path_string = joinPathForMessage(allocator, path) catch return null;
    defer allocator.free(path_string);

    const message = std.fmt.allocPrint(allocator, "Template reference not found: {s}", .{path_string}) catch return null;
    allocated_messages.append(allocator, message) catch return null;

    return .{
        .range = range,
        .severity = diagnosticSeverityToLsp(severity),
        .source = "jade_toml_lsp",
        .message = message,
    };
}

fn templateCycleDiagnostic(
    allocator: std.mem.Allocator,
    text: []const u8,
    span: jade.TemplateSpan,
    root: toml.Table,
    placeholders: []const jade.Placeholder,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?types.Diagnostic {
    const path = extractTemplatePath(allocator, text, span) orelse return null;
    defer allocator.free(path);

    if (!templatePathHasCycle(allocator, path, root, placeholders)) return null;

    const range = rangeFromSpan(text, span.start, span.end);
    const path_string = joinPathForMessage(allocator, path) catch return null;
    defer allocator.free(path_string);

    const message = std.fmt.allocPrint(allocator, "Template reference is cyclic: {s}", .{path_string}) catch return null;
    allocated_messages.append(allocator, message) catch return null;

    return .{
        .range = range,
        .severity = diagnosticSeverityToLsp(severity),
        .source = "jade_toml_lsp",
        .message = message,
    };
}

fn isTomlUri(uri: []const u8) bool {
    return std.mem.endsWith(u8, uri, ".toml");
}

fn spanInLineComment(text: []const u8, span: jade.TemplateSpan) bool {
    if (span.start >= text.len) return false;

    const last_nl = std.mem.lastIndexOfScalar(u8, text[0..span.start], '\n');
    const line_start: usize = if (last_nl) |pos| pos + 1 else 0;
    var line_end: usize = span.start;
    while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}

    var state: jade.QuoteState = .none;
    var i: usize = 0;
    while (i < line_start and i < text.len) : (i += 1) {
        jade.updateQuoteState(text, &i, &state);
    }

    if (state == .multi_double or state == .multi_single) {
        return false;
    }

    // If the first non-whitespace char on the line is '#', the whole line is a comment.
    i = line_start;
    while (i < line_end) : (i += 1) {
        if (text[i] == ' ' or text[i] == '\t') continue;
        if (text[i] == '#') return true;
        break;
    }

    // Otherwise, look for an inline comment before the span.
    i = line_start;
    while (i < span.start) : (i += 1) {
        jade.updateQuoteState(text, &i, &state);
        if (state == .none and text[i] == '#') return true;
    }

    return false;
}

fn fullDocumentRange(text: []const u8) types.Range {
    const info = jade.lineInfo(text);
    const end_line = if (info.lines > 0) info.lines - 1 else 0;
    return .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = @intCast(end_line), .character = @intCast(info.last_line_len) },
    };
}

const PathKind = enum { table, array, value };
fn pathHasPrefix(path: []const []const u8, prefix: []const []const u8) bool {
    if (prefix.len > path.len) return false;
    for (prefix, 0..) |part, idx| {
        if (!std.mem.eql(u8, part, path[idx])) return false;
    }
    return true;
}

const SpecialFloatMask = struct {
    masked: []u8,
    placeholders: []const jade.Placeholder,
};

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-'
        or c == '.';
}

fn normalizeUnicodeEscapes(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var state: jade.QuoteState = .none;
    var in_comment = false;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (in_comment) {
            try out.append(allocator, input[i]);
            if (input[i] == '\n') in_comment = false;
            continue;
        }

        jade.updateQuoteState(input, &i, &state);
        if (state == .none and input[i] == '#') {
            in_comment = true;
            try out.append(allocator, input[i]);
            continue;
        }

        if ((state == .double or state == .multi_double) and input[i] == '\\' and i + 1 < input.len) {
            const esc = input[i + 1];
            if (esc == 'u' or esc == 'U') {
                const digits: usize = if (esc == 'u') 4 else 8;
                if (i + 1 + digits < input.len) {
                    var cp: u21 = 0;
                    var ok = true;
                    var j: usize = 0;
                    while (j < digits) : (j += 1) {
                        const d = input[i + 2 + j];
                        const v = hexValue(d) orelse {
                            ok = false;
                            break;
                        };
                        cp = (cp << 4) | @as(u21, v);
                    }
                    if (ok and std.unicode.utf8ValidCodepoint(cp)) {
                        var buf: [4]u8 = undefined;
                        var len: usize = 0;
                        if (std.unicode.utf8Encode(cp, &buf)) |n| {
                            len = n;
                        } else |_| {
                            ok = false;
                        }
                        if (ok) {
                            try out.appendSlice(allocator, buf[0..len]);
                            i += 1 + digits;
                            continue;
                        }
                    }
                }
            }
        }

        try out.append(allocator, input[i]);
    }

    return out.toOwnedSlice(allocator);
}

fn maskMultilineStrings(allocator: std.mem.Allocator, input: []const u8) !SpecialFloatMask {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var placeholders: std.ArrayList(jade.Placeholder) = .empty;
    errdefer placeholders.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (i + 2 < input.len and c == '"' and input[i + 1] == '"' and input[i + 2] == '"') {
            const start = i;
            i += 3;
            while (i + 2 < input.len) : (i += 1) {
                if (input[i] == '"' and input[i + 1] == '"' and input[i + 2] == '"') {
                    const end = i + 3;
                    const token = try std.fmt.allocPrint(allocator, "__JADE_ML_{d}__", .{placeholders.items.len});
                    const original = try allocator.dupe(u8, input[start..end]);
                    try placeholders.append(allocator, .{ .token = token, .original = original });
                    try out.append(allocator, '"');
                    try out.appendSlice(allocator, token);
                    try out.append(allocator, '"');
                    i = end - 1;
                    break;
                }
            }
            continue;
        }

        if (i + 2 < input.len and c == '\'' and input[i + 1] == '\'' and input[i + 2] == '\'') {
            const start = i;
            i += 3;
            while (i + 2 < input.len) : (i += 1) {
                if (input[i] == '\'' and input[i + 1] == '\'' and input[i + 2] == '\'') {
                    const end = i + 3;
                    const token = try std.fmt.allocPrint(allocator, "__JADE_ML_{d}__", .{placeholders.items.len});
                    const original = try allocator.dupe(u8, input[start..end]);
                    try placeholders.append(allocator, .{ .token = token, .original = original });
                    try out.append(allocator, '"');
                    try out.appendSlice(allocator, token);
                    try out.append(allocator, '"');
                    i = end - 1;
                    break;
                }
            }
            continue;
        }

        try out.append(allocator, c);
    }

    return .{
        .masked = try out.toOwnedSlice(allocator),
        .placeholders = try placeholders.toOwnedSlice(allocator),
    };
}

fn matchSpecialFloatToken(input: []const u8, index: usize) ?struct { len: usize, token: []const u8 } {
    if (index >= input.len) return null;
    var start = index;
    if (input[start] == '+' or input[start] == '-') {
        if (start + 1 >= input.len) return null;
        start += 1;
    }
    const slice = input[start..];
    if (std.mem.startsWith(u8, slice, "inf")) {
        return .{ .len = (start - index) + 3, .token = input[index .. index + (start - index) + 3] };
    }
    if (std.mem.startsWith(u8, slice, "nan")) {
        return .{ .len = (start - index) + 3, .token = input[index .. index + (start - index) + 3] };
    }
    return null;
}

fn isSpecialFloatLiteral(text: []const u8) bool {
    if (text.len == 0) return false;
    var start: usize = 0;
    if (text[0] == '+' or text[0] == '-') {
        if (text.len == 1) return false;
        start = 1;
    }
    const rest = text[start..];
    return std.mem.eql(u8, rest, "inf") or std.mem.eql(u8, rest, "nan");
}

fn maskSpecialFloats(allocator: std.mem.Allocator, input: []const u8) !SpecialFloatMask {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var placeholders: std.ArrayList(jade.Placeholder) = .empty;
    errdefer placeholders.deinit(allocator);

    var state: jade.QuoteState = .none;
    var in_comment = false;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (in_comment) {
            try out.append(allocator, input[i]);
            if (input[i] == '\n') in_comment = false;
            continue;
        }

        jade.updateQuoteState(input, &i, &state);
        if (state == .none and input[i] == '#') {
            in_comment = true;
            try out.append(allocator, input[i]);
            continue;
        }

        if (state == .none) {
            if (matchSpecialFloatToken(input, i)) |match| {
                const prev_ok = if (i == 0) true else !isIdentChar(input[i - 1]);
                const next_index = i + match.len;
                const next_ok = if (next_index >= input.len) true else !isIdentChar(input[next_index]);
                if (prev_ok and next_ok) {
                    const token = try std.fmt.allocPrint(allocator, "__JADE_FLOAT_{d}__", .{placeholders.items.len});
                    const original = try allocator.dupe(u8, match.token);
                    try placeholders.append(allocator, .{ .token = token, .original = original });
                    try out.append(allocator, '"');
                    try out.appendSlice(allocator, token);
                    try out.append(allocator, '"');
                    i += match.len - 1;
                    continue;
                }
            }
        }

        try out.append(allocator, input[i]);
    }

    return .{
        .masked = try out.toOwnedSlice(allocator),
        .placeholders = try placeholders.toOwnedSlice(allocator),
    };
}

fn mergePlaceholders(
    allocator: std.mem.Allocator,
    left: []const jade.Placeholder,
    right: []const jade.Placeholder,
) ![]jade.Placeholder {
    if (left.len == 0 and right.len == 0) return allocator.alloc(jade.Placeholder, 0);
    var out = try allocator.alloc(jade.Placeholder, left.len + right.len);
    if (left.len > 0) @memcpy(out[0..left.len], left);
    if (right.len > 0) @memcpy(out[left.len..], right);
    return out;
}

fn collectKeyConflictDiagnostics(
    allocator: std.mem.Allocator,
    text: []const u8,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?[]types.Diagnostic {
    var diags: std.ArrayList(types.Diagnostic) = .empty;
    errdefer diags.deinit(allocator);

    var kinds = std.StringHashMap(PathKind).init(allocator);
    defer {
        var it = kinds.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        kinds.deinit();
    }

    var array_element_maps = std.StringHashMap(*std.StringHashMap(PathKind)).init(allocator);
    defer {
        var it = array_element_maps.iterator();
        while (it.next()) |entry| {
            const map_ptr = entry.value_ptr.*;
            var mit = map_ptr.iterator();
            while (mit.next()) |mentry| {
                allocator.free(mentry.key_ptr.*);
            }
            map_ptr.deinit();
            allocator.destroy(map_ptr);
            allocator.free(entry.key_ptr.*);
        }
        array_element_maps.deinit();
    }

    var current_path: [][]const u8 = allocator.alloc([]const u8, 0) catch return null;
    defer allocator.free(current_path);
    var current_array_path: ?[][]const u8 = null;
    defer if (current_array_path) |path| allocator.free(path);
    var current_array_map: ?*std.StringHashMap(PathKind) = null;

    var line_index: usize = 0;
    while (true) {
        const line_text = jade.lineSlice(text, line_index) orelse break;
        const trimmed = std.mem.trim(u8, line_text, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            line_index += 1;
            continue;
        }

        if (trimmed[0] == '[') {
            if (parseTableHeaderPath(allocator, trimmed)) |header_path| {
                const is_array = trimmed.len >= 4 and trimmed[0] == '[' and trimmed[1] == '[' and trimmed[trimmed.len - 2] == ']';
                defer allocator.free(header_path);

                if (current_array_path) |path| {
                    if (!pathHasPrefix(header_path, path)) {
                        allocator.free(path);
                        current_array_path = null;
                        current_array_map = null;
                    }
                }

                allocator.free(current_path);
                current_path = allocator.alloc([]const u8, header_path.len) catch return null;
                @memcpy(current_path, header_path);
                if (is_array) {
                    if (current_array_path) |path| allocator.free(path);
                    current_array_path = allocator.alloc([]const u8, header_path.len) catch return null;
                    @memcpy(current_array_path.?, header_path);

                    const array_key = joinPathForMessage(allocator, header_path) catch return null;
                    defer allocator.free(array_key);
                    if (array_element_maps.getEntry(array_key)) |entry| {
                        const map_ptr = entry.value_ptr.*;
                        var mit = map_ptr.iterator();
                        while (mit.next()) |mentry| {
                            allocator.free(mentry.key_ptr.*);
                        }
                        map_ptr.deinit();
                        map_ptr.* = std.StringHashMap(PathKind).init(allocator);
                        current_array_map = map_ptr;
                    } else {
                        const map_ptr = allocator.create(std.StringHashMap(PathKind)) catch return null;
                        map_ptr.* = std.StringHashMap(PathKind).init(allocator);
                        const stored_key = allocator.dupe(u8, array_key) catch return null;
                        array_element_maps.put(stored_key, map_ptr) catch return null;
                        current_array_map = map_ptr;
                    }
                } else if (current_array_path != null and pathHasPrefix(header_path, current_array_path.?)) {
                    // stay in current array context for subtables
                    current_array_map = current_array_map;
                } else {
                    current_array_map = null;
                }

                // Ensure parent paths are not values
                if (header_path.len > 1) {
                    var pidx: usize = 0;
                    while (pidx + 1 < header_path.len) : (pidx += 1) {
                        const prefix = header_path[0 .. pidx + 1];
                        const prefix_key = joinPathForMessage(allocator, prefix) catch return null;
                        defer allocator.free(prefix_key);
                        const map_ref = if (current_array_path != null and pathHasPrefix(prefix, current_array_path.?))
                            current_array_map orelse &kinds
                        else
                            &kinds;
                        if (map_ref.get(prefix_key)) |kind| {
                            if (kind == .value) {
                                const diag = keyConflictRangeDiagnostic(
                                    allocator,
                                    .{ .line = line_index, .start = 0, .end = line_text.len },
                                    prefix,
                                    "Table conflicts with non-table value",
                                    severity,
                                    allocated_messages,
                                ) orelse return null;
                                diags.append(allocator, diag) catch {};
                            }
                        } else {
                            map_ref.put(allocator.dupe(u8, prefix_key) catch return null, .table) catch return null;
                        }
                }
                }

                const header_key = joinPathForMessage(allocator, header_path) catch return null;
                defer allocator.free(header_key);
                const header_kind = if (is_array) PathKind.array else PathKind.table;

                const header_map = if (current_array_path != null and !is_array and pathHasPrefix(header_path, current_array_path.?))
                    current_array_map orelse &kinds
                else
                    &kinds;

                if (recordPathKind(
                    allocator,
                    header_map,
                    header_key,
                    header_kind,
                    header_path,
                    .{
                        .line = line_index,
                        .start = 0,
                        .end = line_text.len,
                    },
                    severity,
                    allocated_messages,
                )) |conflict_diag| {
                    diags.append(allocator, conflict_diag) catch {};
                }

                line_index += 1;
                continue;
            }
        }

        if (parseKeySegments(allocator, line_text)) |segments| {
            defer allocator.free(segments);
            if (segments.len == 0) {
                line_index += 1;
                continue;
            }
            const key_path = segmentsToPath(allocator, segments) orelse return null;
            defer allocator.free(key_path);
            const combined = joinPaths(allocator, current_path, key_path) orelse return null;
            defer allocator.free(combined);

            const in_array = current_array_path != null and pathHasPrefix(combined, current_array_path.?);
            const map_ref = if (in_array) current_array_map orelse &kinds else &kinds;

            // Ensure parents are tables (or arrays for current array context)
            var idx: usize = 0;
            while (idx + 1 < combined.len) : (idx += 1) {
                const prefix = combined[0 .. idx + 1];
                const prefix_key = joinPathForMessage(allocator, prefix) catch return null;
                defer allocator.free(prefix_key);

                if (map_ref.get(prefix_key)) |kind| {
                    if (kind == .value) {
                        const diag = keyConflictDiagnostic(
                            allocator,
                            line_index,
                            segments[segments.len - 1],
                            prefix,
                            "Key conflicts with non-table value",
                            severity,
                            allocated_messages,
                        ) orelse return null;
                        diags.append(allocator, diag) catch {};
                    }
                } else {
                    map_ref.put(allocator.dupe(u8, prefix_key) catch return null, .table) catch return null;
                }
            }

            const last = segments[segments.len - 1];
            const final_key = joinPathForMessage(allocator, combined) catch return null;
            defer allocator.free(final_key);
    if (map_ref.get(final_key)) |kind| {
        const msg = switch (kind) {
            .value => "Duplicate key",
            .table => "Key conflicts with existing table",
            .array => "Key conflicts with existing array-of-tables",
        };
        const diag = keyConflictDiagnostic(
            allocator,
            line_index,
            last,
            combined,
                    msg,
                    severity,
                    allocated_messages,
                ) orelse return null;
                diags.append(allocator, diag) catch {};
            } else {
                map_ref.put(allocator.dupe(u8, final_key) catch return null, .value) catch return null;
            }
        }

        line_index += 1;
    }

    return diags.toOwnedSlice(allocator) catch null;
}

const LineRange = struct {
    line: usize,
    start: usize,
    end: usize,
};

fn recordPathKind(
    allocator: std.mem.Allocator,
    kinds: *std.StringHashMap(PathKind),
    key: []const u8,
    kind: PathKind,
    path: []const []const u8,
    range: LineRange,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?types.Diagnostic {
    if (kinds.get(key)) |existing| {
        if (kind == .array and existing == .array) {
            return null;
        }
        const msg = switch (kind) {
            .table => if (existing == .array) "Table conflicts with existing array-of-tables" else "Duplicate table definition",
            .array => if (existing == .table) "Array-of-tables conflicts with existing table" else "Duplicate array-of-tables definition",
            .value => "Duplicate key",
        };
        return keyConflictRangeDiagnostic(allocator, range, path, msg, severity, allocated_messages);
    }
    kinds.put(allocator.dupe(u8, key) catch return null, kind) catch return null;
    return null;
}

fn keyConflictDiagnostic(
    allocator: std.mem.Allocator,
    line_index: usize,
    seg: KeySegment,
    path: []const []const u8,
    msg: []const u8,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?types.Diagnostic {
    return keyConflictRangeDiagnostic(allocator, .{ .line = line_index, .start = seg.start, .end = seg.end }, path, msg, severity, allocated_messages);
}

fn keyConflictRangeDiagnostic(
    allocator: std.mem.Allocator,
    range: LineRange,
    path: []const []const u8,
    msg: []const u8,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?types.Diagnostic {
    const path_string = joinPathForMessage(allocator, path) catch return null;
    defer allocator.free(path_string);
    const message = std.fmt.allocPrint(allocator, "{s}: {s}", .{ msg, path_string }) catch return null;
    allocated_messages.append(allocator, message) catch return null;
    return .{
        .range = .{
            .start = .{ .line = @intCast(range.line), .character = @intCast(range.start) },
            .end = .{ .line = @intCast(range.line), .character = @intCast(range.end) },
        },
        .severity = diagnosticSeverityToLsp(severity),
        .source = "jade_toml_lsp",
        .message = message,
    };
}

fn collectInlineTableDiagnostics(
    allocator: std.mem.Allocator,
    text: []const u8,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?[]types.Diagnostic {
    var diags: std.ArrayList(types.Diagnostic) = .empty;
    errdefer diags.deinit(allocator);

    var line_index: usize = 0;
    while (true) {
        const line_text = jade.lineSlice(text, line_index) orelse break;
        const trimmed = std.mem.trim(u8, line_text, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            line_index += 1;
            continue;
        }

        const eq_index = std.mem.indexOfScalar(u8, line_text, '=') orelse {
            line_index += 1;
            continue;
        };
        var val_pos = eq_index + 1;
        while (val_pos < line_text.len and (line_text[val_pos] == ' ' or line_text[val_pos] == '\t')) : (val_pos += 1) {}
        if (val_pos >= line_text.len or line_text[val_pos] != '{') {
            line_index += 1;
            continue;
        }

        if (scanInlineTableIssues(allocator, text, line_index, val_pos, severity, allocated_messages)) |diag| {
            diags.append(allocator, diag) catch {};
        }

        line_index += 1;
    }

    return diags.toOwnedSlice(allocator) catch null;
}

fn scanInlineTableIssues(
    allocator: std.mem.Allocator,
    text: []const u8,
    line_index: usize,
    start_col: usize,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?types.Diagnostic {
    var state: jade.QuoteState = .none;
    var brace_depth: usize = 0;
    var last_non_ws: ?u8 = null;

    var line_cursor = line_index;
    while (true) {
        const line_text = jade.lineSlice(text, line_cursor) orelse break;
        var idx: usize = if (line_cursor == line_index) start_col else 0;
        while (idx < line_text.len) : (idx += 1) {
            jade.updateQuoteState(line_text, &idx, &state);
            if (state != .none) continue;

            const c = line_text[idx];
            if (c == '#') break;
            if (c == '{') {
                brace_depth += 1;
                continue;
            }
            if (c == '}') {
                if (brace_depth == 1) {
                    if (last_non_ws != null and last_non_ws.? == ',') {
                        return inlineTableDiagnostic(
                            allocator,
                            line_cursor,
                            idx,
                            "Inline table cannot have a trailing comma",
                            severity,
                            allocated_messages,
                        );
                    }
                    return null;
                }
                if (brace_depth > 0) brace_depth -= 1;
            }
            if (brace_depth >= 1) {
                if (c == ',' or (c != ' ' and c != '\t' and c != '\r')) {
                    last_non_ws = c;
                }
            }
        }

        if (line_cursor != line_index) {
            return inlineTableDiagnostic(
                allocator,
                line_cursor,
                0,
                "Inline table cannot span multiple lines",
                severity,
                allocated_messages,
            );
        }

        line_cursor += 1;
        if (line_cursor >= jade.lineInfo(text).lines) break;
    }
    return null;
}

fn inlineTableDiagnostic(
    allocator: std.mem.Allocator,
    line: usize,
    col: usize,
    msg: []const u8,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?types.Diagnostic {
    const message = std.fmt.allocPrint(allocator, "{s}", .{msg}) catch return null;
    allocated_messages.append(allocator, message) catch return null;
    return .{
        .range = .{
            .start = .{ .line = @intCast(line), .character = @intCast(col) },
            .end = .{ .line = @intCast(line), .character = @intCast(col + 1) },
        },
        .severity = diagnosticSeverityToLsp(severity),
        .source = "jade_toml_lsp",
        .message = message,
    };
}

fn collectArrayTableOrderingDiagnostics(
    allocator: std.mem.Allocator,
    text: []const u8,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?[]types.Diagnostic {
    var diags: std.ArrayList(types.Diagnostic) = .empty;
    errdefer diags.deinit(allocator);

    const HeaderInfo = struct {
        path: [][]const u8,
        line: usize,
        start: usize,
        end: usize,
        is_array: bool,
    };

    var headers: std.ArrayList(HeaderInfo) = .empty;
    errdefer headers.deinit(allocator);
    defer headers.deinit(allocator);

    var array_headers = std.StringHashMap(usize).init(allocator);
    defer {
        var it = array_headers.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        array_headers.deinit();
    }

    var line_index: usize = 0;
    while (true) {
        const line_text = jade.lineSlice(text, line_index) orelse break;
        const trimmed = std.mem.trim(u8, line_text, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            line_index += 1;
            continue;
        }
        if (trimmed[0] == '[') {
            if (parseTableHeaderPath(allocator, trimmed)) |header_path| {
                const is_array = trimmed.len >= 4 and trimmed[0] == '[' and trimmed[1] == '[' and trimmed[trimmed.len - 2] == ']';
                headers.append(allocator, .{
                    .path = header_path,
                    .line = line_index,
                    .start = 0,
                    .end = line_text.len,
                    .is_array = is_array,
                }) catch return null;
                if (is_array) {
                    const key = joinPathForMessage(allocator, header_path) catch return null;
                    if (!array_headers.contains(key)) {
                        array_headers.put(allocator.dupe(u8, key) catch return null, line_index) catch return null;
                    }
                    allocator.free(key);
                }
            }
        }
        line_index += 1;
    }

    defer {
        for (headers.items) |entry| allocator.free(entry.path);
    }

    for (headers.items) |hdr| {
        if (hdr.is_array) continue;
        if (hdr.path.len <= 1) continue;
        var idx: usize = 0;
        while (idx + 1 < hdr.path.len) : (idx += 1) {
            const prefix = hdr.path[0 .. idx + 1];
            const key = joinPathForMessage(allocator, prefix) catch return null;
            defer allocator.free(key);
            if (array_headers.get(key)) |array_line| {
                if (array_line > hdr.line) {
                    const diag = keyConflictRangeDiagnostic(
                        allocator,
                        .{ .line = hdr.line, .start = hdr.start, .end = hdr.end },
                        hdr.path,
                        "Array-of-tables must be defined before its child tables",
                        severity,
                        allocated_messages,
                    ) orelse return null;
                    diags.append(allocator, diag) catch {};
                    break;
                }
            }
        }
    }

    return diags.toOwnedSlice(allocator) catch null;
}

fn extractUriFromArgs(arguments: ?[]const std.json.Value) ?[]const u8 {
    const args = arguments orelse return null;
    if (args.len == 0) return null;
    return switch (args[0]) {
        .string => |s| s,
        else => null,
    };
}

fn extractChangeText(change: types.TextDocumentContentChangeEvent) ?[]const u8 {
    return switch (change) {
        .literal_0 => |v| v.text,
        .literal_1 => |v| v.text,
    };
}

fn diagnosticSeverityToLsp(severity: DiagnosticsSeverity) types.DiagnosticSeverity {
    return switch (severity) {
        .off => .Error,
        .err => .Error,
        .warn => .Warning,
        .info => .Information,
        .hint => .Hint,
    };
}

fn rangeFromSpan(text: []const u8, start: usize, end: usize) types.Range {
    const start_pos = positionFromIndex(text, start);
    const end_pos = positionFromIndex(text, end);
    return .{
        .start = .{ .line = @intCast(start_pos.line), .character = @intCast(start_pos.character) },
        .end = .{ .line = @intCast(end_pos.line), .character = @intCast(end_pos.character) },
    };
}

const TextPosition = struct {
    line: usize,
    character: usize,
};

const HoverInfo = struct {
    ty: []const u8,
    value: []const u8,
    key: []const u8,
    table: []const u8,
};

fn positionToIndex(text: []const u8, line: u32, character: u32) usize {
    var idx: usize = 0;
    var current_line: usize = 0;
    var current_col: usize = 0;
    while (idx < text.len) : (idx += 1) {
        if (current_line == line and current_col == character) return idx;
        if (text[idx] == '\n') {
            current_line += 1;
            current_col = 0;
        } else {
            current_col += 1;
        }
    }
    return idx;
}

fn findTemplateSpanAtIndex(spans: []const jade.TemplateSpan, idx: usize) ?jade.TemplateSpan {
    for (spans) |span| {
        if (idx >= span.start and idx < span.end) return span;
    }
    return null;
}

fn inTemplateAt(spans: []const jade.Span, text: []const u8, line: u32, character: u32) ?jade.TemplateSpan {
    const idx = positionToIndex(text, line, character);
    for (spans) |span| {
        if (idx >= span.start and idx < span.end) {
            return .{ .start = span.start, .end = span.end, .in_quotes = true };
        }
    }
    return null;
}

fn inTemplateAtFromSpans(spans: []const jade.TemplateSpan, text: []const u8, line: u32, character: u32) ?jade.TemplateSpan {
    const idx = positionToIndex(text, line, character);
    for (spans) |span| {
        if (idx >= span.start and idx < span.end) return span;
    }
    return null;
}

fn positionFromIndex(text: []const u8, index: usize) TextPosition {
    var line: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    while (i < text.len and i < index) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .character = col };
}

fn positionInRange(pos: TextPosition, range: types.Range) bool {
    if (pos.line < range.start.line) return false;
    if (pos.line > range.end.line) return false;
    if (pos.line == range.start.line and pos.character < range.start.character) return false;
    if (pos.line == range.end.line and pos.character > range.end.character) return false;
    return true;
}

fn templateInlayIndex(text: []const u8, span: jade.TemplateSpan) ?usize {
    if (span.end <= span.start + 4) return null;
    const inner_full = text[span.start + 2 .. span.end - 2];
    var offset: usize = 0;
    while (offset < inner_full.len and (inner_full[offset] == ' ' or inner_full[offset] == '\t' or inner_full[offset] == '\r' or inner_full[offset] == '\n')) {
        offset += 1;
    }
    if (offset >= inner_full.len) return null;
    const token = inner_full[offset..];
    const token_end = findTemplateTokenEnd(token);
    if (token_end == 0) return null;
    return span.start + 2 + offset + token_end;
}

fn inlayValueText(
    allocator: std.mem.Allocator,
    value: toml.Value,
    placeholders: []const jade.Placeholder,
    root: toml.Table,
) ?[]const u8 {
    switch (value) {
        .string => {
            if (expandPlaceholderValueDepth(allocator, placeholders, root, value, 0)) |expanded| {
                defer allocator.free(expanded);
                if (expanded.len >= 2 and expanded[0] == '"' and expanded[expanded.len - 1] == '"') {
                    return allocator.dupe(u8, expanded[1 .. expanded.len - 1]) catch null;
                }
                return allocator.dupe(u8, expanded) catch null;
            }
            return allocator.dupe(u8, value.string) catch null;
        },
        else => return tomlValueStringExpanded(allocator, value, placeholders, root) catch null,
    }
}

fn extractTemplatePath(allocator: std.mem.Allocator, text: []const u8, span: jade.TemplateSpan) ?[][]const u8 {
    if (span.end <= span.start + 4) return null;
    const inner = std.mem.trim(u8, text[span.start + 2 .. span.end - 2], " \t\r\n");
    if (inner.len == 0) return null;

    const token_end = findTemplateTokenEnd(inner);
    if (token_end == 0) return null;

    const token = inner[0..token_end];
    return splitDottedPath(allocator, token);
}

fn extractTemplatePathFromString(allocator: std.mem.Allocator, original: []const u8) ?[][]const u8 {
    if (original.len < 4) return null;
    const trimmed = std.mem.trim(u8, original, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "{{") or !std.mem.endsWith(u8, trimmed, "}}")) return null;
    const inner = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t\r\n");
    if (inner.len == 0) return null;
    const token_end = findTemplateTokenEnd(inner);
    if (token_end == 0) return null;
    return splitDottedPath(allocator, inner[0..token_end]);
}

fn expandPlaceholderValueDepth(
    allocator: std.mem.Allocator,
    placeholders: []const jade.Placeholder,
    root: toml.Table,
    value: toml.Value,
    depth: usize,
) ?[]const u8 {
    if (value != .string) return null;
    const s = value.string;
    for (placeholders) |ph| {
        if (std.mem.eql(u8, ph.token, s)) {
            if (extractTemplatePathFromString(allocator, ph.original)) |path| {
                defer allocator.free(path);
                if (lookupTomlValue(root, path)) |expanded| {
                    return tomlValueStringExpandedDepth(allocator, expanded, placeholders, root, depth + 1) catch null;
                }
            }
            return allocator.dupe(u8, ph.original) catch null;
        }
    }
    return null;
}

fn tomlValueStringExpanded(
    allocator: std.mem.Allocator,
    value: toml.Value,
    placeholders: []const jade.Placeholder,
    root: toml.Table,
) anyerror![]const u8 {
    return tomlValueStringExpandedDepth(allocator, value, placeholders, root, 0);
}

fn tomlValueStringExpandedDepth(
    allocator: std.mem.Allocator,
    value: toml.Value,
    placeholders: []const jade.Placeholder,
    root: toml.Table,
    depth: usize,
) anyerror![]const u8 {
    if (depth > 8) {
        return tomlValueString(allocator, value) orelse return error.OutOfMemory;
    }
    switch (value) {
        .array => |ar| {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, "[ ");
            for (ar.items, 0..) |item, idx| {
                if (idx > 0) try out.appendSlice(allocator, ", ");
                if (expandPlaceholderValueDepth(allocator, placeholders, root, item, depth)) |expanded| {
                    defer allocator.free(expanded);
                    try out.appendSlice(allocator, expanded);
                } else {
                    const rendered = tomlValueString(allocator, item) orelse return error.OutOfMemory;
                    defer allocator.free(rendered);
                    try out.appendSlice(allocator, rendered);
                }
            }
            try out.appendSlice(allocator, " ]");
            return out.toOwnedSlice(allocator);
        },
        .table => |_| return tomlValueString(allocator, value) orelse return error.OutOfMemory,
        else => {
            if (expandPlaceholderValueDepth(allocator, placeholders, root, value, depth)) |expanded| {
                return expanded;
            }
            return tomlValueString(allocator, value) orelse return error.OutOfMemory;
        },
    }
}

fn envFlagEnabled(allocator: std.mem.Allocator, name: []const u8) bool {
    const value = std.process.getEnvVarOwned(allocator, name) catch return false;
    defer allocator.free(value);
    return value.len > 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

const CompletionContext = struct {
    base_path: [][]const u8,
    prefix: []const u8,
};

fn templateCompletionContext(
    allocator: std.mem.Allocator,
    text: []const u8,
    spans: []const jade.TemplateSpan,
    line: u32,
    character: u32,
) ?CompletionContext {
    const span = inTemplateAtFromSpans(spans, text, line, character) orelse return null;
    if (!span.in_quotes) return null;

    const cursor = positionToIndex(text, line, character);
    const inner_start = span.start + 2;
    const inner_end = span.end - 2;
    if (cursor < inner_start) return null;
    const bounded = if (cursor > inner_end) inner_end else cursor;
    var inner = text[inner_start..bounded];

    // Trim leading spaces.
    inner = std.mem.trimLeft(u8, inner, " \t\r\n");
    if (inner.len == 0) {
        return .{ .base_path = allocator.alloc([]const u8, 0) catch return null, .prefix = "" };
    }

    // Stop at first pipe to ignore filters.
    if (std.mem.indexOfScalar(u8, inner, '|')) |pipe_idx| {
        inner = inner[0..pipe_idx];
    }

    // Trim trailing spaces.
    inner = std.mem.trimRight(u8, inner, " \t\r\n");
    if (inner.len == 0) {
        return .{ .base_path = allocator.alloc([]const u8, 0) catch return null, .prefix = "" };
    }

    // Use last token after delimiter.
    var end = inner.len;
    while (end > 0 and (inner[end - 1] == ' ' or inner[end - 1] == '\t')) : (end -= 1) {}
    var start = end;
    while (start > 0) {
        const c = inner[start - 1];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '|' or c == ')' or c == '}' or c == ',') break;
        start -= 1;
    }
    const token = inner[start..end];

    if (token.len == 0) {
        return .{ .base_path = allocator.alloc([]const u8, 0) catch return null, .prefix = "" };
    }

    if (std.mem.lastIndexOfScalar(u8, token, '.')) |dot_idx| {
        const base = token[0..dot_idx];
        const prefix = token[dot_idx + 1 ..];
        if (base.len == 0) {
            return .{ .base_path = allocator.alloc([]const u8, 0) catch return null, .prefix = prefix };
        }
        const base_path = splitDottedPath(allocator, base) orelse return null;
        return .{ .base_path = base_path, .prefix = prefix };
    }

    return .{ .base_path = allocator.alloc([]const u8, 0) catch return null, .prefix = token };
}

fn completionTableForPath(root: toml.Table, path: []const []const u8) ?toml.Table {
    if (path.len == 0) return root;
    const value = lookupTomlValue(root, path) orelse return null;
    return switch (value) {
        .table => |t| t.*,
        .array => |ar| tableFromArray(ar) orelse return null,
        else => null,
    };
}

fn completionItemKindForValue(value: toml.Value) types.CompletionItemKind {
    return switch (value) {
        .table => .Module,
        .array => .Field,
        else => .Value,
    };
}

fn buildCompletionItems(
    allocator: std.mem.Allocator,
    table: toml.Table,
    prefix: []const u8,
) ?[]types.CompletionItem {
    var items: std.ArrayList(types.CompletionItem) = .empty;
    errdefer items.deinit(allocator);

    var it = table.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (prefix.len > 0 and !std.mem.startsWith(u8, key, prefix)) continue;
        const value = entry.value_ptr.*;
        items.append(allocator, .{
            .label = key,
            .kind = completionItemKindForValue(value),
            .detail = tomlValueType(value),
            .insertText = key,
        }) catch return null;
    }

    return items.toOwnedSlice(allocator) catch null;
}

const ArrayScan = struct {
    end_line: usize,
    has_trailing: bool,
};

fn scanArrayTrailingComma(text: []const u8, start_line: usize, start_col: usize) ArrayScan {
    var line_index = start_line;
    var started = false;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var state: jade.QuoteState = .none;
    var last_non_ws: ?u8 = null;

    while (true) {
        const line_text = jade.lineSlice(text, line_index) orelse break;
        var i: usize = if (line_index == start_line) start_col else 0;
        while (i < line_text.len) : (i += 1) {
            jade.updateQuoteState(line_text, &i, &state);
            if (state != .none) continue;

            const c = line_text[i];
            if (!started) {
                if (c == '[') {
                    started = true;
                    bracket_depth = 1;
                }
                continue;
            }

            if (c == '#') break;
            if (c == '[') bracket_depth += 1;
            if (c == ']') {
                if (bracket_depth == 1 and brace_depth == 0) {
                    return .{
                        .end_line = line_index,
                        .has_trailing = last_non_ws != null and last_non_ws.? == ',',
                    };
                }
                if (bracket_depth > 0) bracket_depth -= 1;
                continue;
            }
            if (c == '{') brace_depth += 1;
            if (c == '}' and brace_depth > 0) brace_depth -= 1;

            if (bracket_depth == 1 and brace_depth == 0) {
                if (c == ',' or (c != ' ' and c != '\t' and c != '\r')) {
                    last_non_ws = c;
                }
            }
        }
        line_index += 1;
    }

    return .{ .end_line = line_index, .has_trailing = false };
}

fn safeFormatTrailingCommaArrays(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    var line_index: usize = 0;
    while (true) {
        const line_text = jade.lineSlice(text, line_index) orelse break;
        const line_start = index;
        const line_len = line_text.len;
        const trimmed = std.mem.trim(u8, line_text, " \t");

        if (trimmed.len != 0 and trimmed[0] == '[') {
            // table header line
            try out.appendSlice(allocator, text[line_start .. line_start + line_len]);
            try out.appendSlice(allocator, "\n");
            index = line_start + line_len + 1;
            line_index += 1;
            continue;
        }

        const eq_index = std.mem.indexOfScalar(u8, line_text, '=') orelse {
            try out.appendSlice(allocator, text[line_start .. line_start + line_len]);
            try out.appendSlice(allocator, "\n");
            index = line_start + line_len + 1;
            line_index += 1;
            continue;
        };

        var val_pos = eq_index + 1;
        while (val_pos < line_text.len and (line_text[val_pos] == ' ' or line_text[val_pos] == '\t')) : (val_pos += 1) {}
        if (val_pos >= line_text.len or line_text[val_pos] != '[') {
            try out.appendSlice(allocator, text[line_start .. line_start + line_len]);
            try out.appendSlice(allocator, "\n");
            index = line_start + line_len + 1;
            line_index += 1;
            continue;
        }

        const scan = scanArrayTrailingComma(text, line_index, val_pos);
        if (!scan.has_trailing) {
            try out.appendSlice(allocator, text[line_start .. line_start + line_len]);
            try out.appendSlice(allocator, "\n");
            index = line_start + line_len + 1;
            line_index += 1;
            continue;
        }

        const start_index = line_start + val_pos;
        const end_index = findMatchingArrayEnd(text, start_index);
        const indent = leadingIndentCount(line_text);
        const header = text[line_start..start_index];

        try out.appendSlice(allocator, header);
        try out.appendSlice(allocator, "[\n");

        var items = try parseArrayItems(allocator, text[start_index + 1 .. end_index]);
        defer {
            for (items.items) |item| allocator.free(item);
            items.deinit(allocator);
        }

        for (items.items) |item| {
            try writeIndent(&out, allocator, indent + 4);
            try out.appendSlice(allocator, item);
            try out.appendSlice(allocator, ",\n");
        }
        try writeIndent(&out, allocator, indent);
        try out.appendSlice(allocator, "]");

        index = end_index + 1;
        line_index = scan.end_line + 1;
        if (index < text.len and text[index] == '\n') {
            try out.appendSlice(allocator, "\n");
            index += 1;
        } else {
            try out.appendSlice(allocator, "\n");
        }
    }

    if (index < text.len) {
        try out.appendSlice(allocator, text[index..]);
    }

    return out.toOwnedSlice(allocator);
}

fn leadingIndentCount(line_text: []const u8) usize {
    var count: usize = 0;
    while (count < line_text.len and (line_text[count] == ' ' or line_text[count] == '\t')) : (count += 1) {}
    return count;
}

fn writeIndent(out: *std.ArrayList(u8), allocator: std.mem.Allocator, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try out.append(allocator, ' ');
    }
}

fn findMatchingArrayEnd(text: []const u8, start_index: usize) usize {
    var idx = start_index;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var state: jade.QuoteState = .none;
    while (idx < text.len) : (idx += 1) {
        jade.updateQuoteState(text, &idx, &state);
        if (state != .none) continue;
        const c = text[idx];
        if (c == '[') bracket_depth += 1;
        if (c == ']') {
            if (bracket_depth == 1 and brace_depth == 0) return idx;
            if (bracket_depth > 0) bracket_depth -= 1;
        }
        if (c == '{') brace_depth += 1;
        if (c == '}' and brace_depth > 0) brace_depth -= 1;
    }
    return text.len - 1;
}

fn parseArrayItems(allocator: std.mem.Allocator, slice: []const u8) !std.ArrayList([]const u8) {
    var items: std.ArrayList([]const u8) = .empty;
    errdefer items.deinit(allocator);

    var state: jade.QuoteState = .none;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var start: usize = 0;
    var idx: usize = 0;

    while (idx < slice.len) : (idx += 1) {
        jade.updateQuoteState(slice, &idx, &state);
        if (state != .none) continue;

        const c = slice[idx];
        if (c == '#') {
            while (idx < slice.len and slice[idx] != '\n') : (idx += 1) {}
            continue;
        }
        if (c == '[') bracket_depth += 1;
        if (c == ']') {
            if (bracket_depth > 0) bracket_depth -= 1;
        }
        if (c == '{') brace_depth += 1;
        if (c == '}' and brace_depth > 0) brace_depth -= 1;

        if (c == ',' and bracket_depth == 0 and brace_depth == 0) {
            const item = std.mem.trim(u8, slice[start..idx], " \t\r\n");
            if (item.len != 0) {
                const copy = try allocator.dupe(u8, item);
                try items.append(allocator, copy);
            }
            start = idx + 1;
        }
    }

    const tail = std.mem.trim(u8, slice[start..], " \t\r\n");
    if (tail.len != 0) {
        const copy = try allocator.dupe(u8, tail);
        try items.append(allocator, copy);
    }

    return items;
}

fn templatePathHasCycle(
    allocator: std.mem.Allocator,
    path: []const []const u8,
    root: toml.Table,
    placeholders: []const jade.Placeholder,
) bool {
    var visited: std.ArrayList([]const u8) = .empty;
    defer {
        for (visited.items) |entry| allocator.free(entry);
        visited.deinit(allocator);
    }

    return templatePathHasCycleRec(allocator, path, root, placeholders, &visited);
}

fn templatePathHasCycleRec(
    allocator: std.mem.Allocator,
    path: []const []const u8,
    root: toml.Table,
    placeholders: []const jade.Placeholder,
    visited: *std.ArrayList([]const u8),
) bool {
    const key = joinPathForMessage(allocator, path) catch return false;
    for (visited.items) |entry| {
        if (std.mem.eql(u8, entry, key)) {
            allocator.free(key);
            return true;
        }
    }
    visited.append(allocator, key) catch {
        allocator.free(key);
        return false;
    };

    const value = lookupTomlValue(root, path) orelse return false;
    if (value != .string) return false;

    for (placeholders) |ph| {
        if (!std.mem.eql(u8, ph.token, value.string)) continue;
        if (extractTemplatePathFromString(allocator, ph.original)) |next_path| {
            defer allocator.free(next_path);
            return templatePathHasCycleRec(allocator, next_path, root, placeholders, visited);
        }
    }
    return false;
}

const LineBounds = struct {
    line_index: usize,
    line_start: usize,
    line_end: usize,
    column: usize,
    line_text: []const u8,
};

fn lineBoundsForIndex(text: []const u8, index: usize) ?LineBounds {
    const pos = positionFromIndex(text, index);
    const line_text = jade.lineSlice(text, pos.line) orelse return null;
    const line_start = positionToIndex(text, @intCast(pos.line), 0);
    return .{
        .line_index = pos.line,
        .line_start = line_start,
        .line_end = line_start + line_text.len,
        .column = pos.character,
        .line_text = line_text,
    };
}

fn findAssignmentEqIndex(line_text: []const u8) ?usize {
    var state: jade.QuoteState = .none;
    var i: usize = 0;
    while (i < line_text.len) : (i += 1) {
        jade.updateQuoteState(line_text, &i, &state);
        if (state == .none) {
            if (line_text[i] == '#') return null;
            if (line_text[i] == '=') return i;
        }
    }
    return null;
}

fn assignmentKeyRangeForLine(line_text: []const u8) ?jade.Span {
    const eq_index = findAssignmentEqIndex(line_text) orelse return null;
    var left: usize = 0;
    while (left < eq_index and (line_text[left] == ' ' or line_text[left] == '\t')) : (left += 1) {}
    var right: usize = eq_index;
    while (right > left and (line_text[right - 1] == ' ' or line_text[right - 1] == '\t')) : (right -= 1) {}
    if (right <= left) return null;
    return .{ .start = left, .end = right };
}

fn tableHeaderRangeForLine(line_text: []const u8) ?jade.Span {
    var i: usize = 0;
    while (i < line_text.len and (line_text[i] == ' ' or line_text[i] == '\t')) : (i += 1) {}
    if (i >= line_text.len or line_text[i] != '[') return null;

    var state: jade.QuoteState = .none;
    var idx: usize = i;
    while (idx < line_text.len) : (idx += 1) {
        jade.updateQuoteState(line_text, &idx, &state);
        if (state == .none and line_text[idx] == ']') {
            return .{ .start = i, .end = idx + 1 };
        }
        if (state == .none and line_text[idx] == '#') {
            return null;
        }
    }
    return null;
}

fn inlineKeyRangesInLine(allocator: std.mem.Allocator, line_text: []const u8) ?[]jade.Span {
    const eq_index = findAssignmentEqIndex(line_text) orelse return null;
    var state: jade.QuoteState = .none;
    var i: usize = eq_index + 1;
    var brace_open: ?usize = null;
    while (i < line_text.len) : (i += 1) {
        jade.updateQuoteState(line_text, &i, &state);
        if (state == .none and line_text[i] == '{') {
            brace_open = i;
            break;
        }
    }
    const open = brace_open orelse return null;

    state = .none;
    var depth: usize = 0;
    var close: ?usize = null;
    i = open;
    while (i < line_text.len) : (i += 1) {
        jade.updateQuoteState(line_text, &i, &state);
        if (state == .none) {
            if (line_text[i] == '{') depth += 1;
            if (line_text[i] == '}') {
                if (depth == 0) break;
                depth -= 1;
                if (depth == 0) {
                    close = i;
                    break;
                }
            }
        }
    }
    const end = close orelse return null;
    if (end <= open + 1) return null;
    const inside = line_text[open + 1 .. end];

    var ranges: std.ArrayList(jade.Span) = .empty;
    errdefer ranges.deinit(allocator);

    state = .none;
    depth = 0;
    var seg_start: usize = 0;
    var idx: usize = 0;
    while (idx <= inside.len) : (idx += 1) {
        const at_end = idx == inside.len;
        if (!at_end) {
            jade.updateQuoteState(inside, &idx, &state);
        }
        const ch = if (at_end) ',' else inside[idx];
        if (state == .none) {
            if (!at_end) {
                if (ch == '{') depth += 1;
                if (ch == '}') {
                    if (depth > 0) depth -= 1;
                }
            }
            if (at_end or (ch == ',' and depth == 0)) {
                const seg_raw = inside[seg_start..idx];
                const seg = std.mem.trim(u8, seg_raw, " \t");
                if (seg.len > 0) {
                    var seg_state: jade.QuoteState = .none;
                    var seg_idx: usize = 0;
                    var seg_eq: ?usize = null;
                    while (seg_idx < seg.len) : (seg_idx += 1) {
                        jade.updateQuoteState(seg, &seg_idx, &seg_state);
                        if (seg_state == .none and seg[seg_idx] == '=') {
                            seg_eq = seg_idx;
                            break;
                        }
                    }
                    if (seg_eq) |eq_pos| {
                        const key_raw = std.mem.trim(u8, seg[0..eq_pos], " \t");
                        if (key_raw.len > 0) {
                            var lead: usize = 0;
                            while (lead < seg_raw.len and (seg_raw[lead] == ' ' or seg_raw[lead] == '\t')) : (lead += 1) {}
                            const key_start = open + 1 + seg_start + lead;
                            const key_end = key_start + key_raw.len;
                            ranges.append(allocator, .{ .start = key_start, .end = key_end }) catch {};
                        }
                    }
                }
                seg_start = idx + 1;
            }
        }
    }

    if (ranges.items.len == 0) return null;
    return ranges.toOwnedSlice(allocator) catch null;
}

fn templateSpanInTableHeader(text: []const u8, span: jade.TemplateSpan) bool {
    const bounds = lineBoundsForIndex(text, span.start) orelse return false;
    if (tableHeaderRangeForLine(bounds.line_text)) |range| {
        return span.start >= bounds.line_start + range.start and span.end <= bounds.line_start + range.end;
    }
    return false;
}

fn templateSpanInAssignmentKey(text: []const u8, span: jade.TemplateSpan) bool {
    const bounds = lineBoundsForIndex(text, span.start) orelse return false;
    const range = assignmentKeyRangeForLine(bounds.line_text) orelse return false;
    return span.start >= bounds.line_start + range.start and span.end <= bounds.line_start + range.end;
}

fn templateSpanInInlineTableKey(allocator: std.mem.Allocator, text: []const u8, span: jade.TemplateSpan) bool {
    const bounds = lineBoundsForIndex(text, span.start) orelse return false;
    const ranges = inlineKeyRangesInLine(allocator, bounds.line_text) orelse return false;
    defer allocator.free(ranges);
    for (ranges) |range| {
        if (span.start >= bounds.line_start + range.start and span.end <= bounds.line_start + range.end) {
            return true;
        }
    }
    return false;
}

fn templateKeyDiagnostic(
    allocator: std.mem.Allocator,
    text: []const u8,
    span: jade.TemplateSpan,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?types.Diagnostic {
    const range = rangeFromSpan(text, span.start, span.end);
    const message = std.fmt.allocPrint(allocator, "Templates are not allowed in keys", .{}) catch return null;
    allocated_messages.append(allocator, message) catch return null;
    return .{
        .range = range,
        .severity = diagnosticSeverityToLsp(severity),
        .source = "jade_toml_lsp",
        .message = message,
    };
}

fn templateInlineKeyDiagnostic(
    allocator: std.mem.Allocator,
    text: []const u8,
    span: jade.TemplateSpan,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?types.Diagnostic {
    const range = rangeFromSpan(text, span.start, span.end);
    const message = std.fmt.allocPrint(allocator, "Templates are not allowed in inline table keys", .{}) catch return null;
    allocated_messages.append(allocator, message) catch return null;
    return .{
        .range = range,
        .severity = diagnosticSeverityToLsp(severity),
        .source = "jade_toml_lsp",
        .message = message,
    };
}

fn templateHeaderDiagnostic(
    allocator: std.mem.Allocator,
    text: []const u8,
    span: jade.TemplateSpan,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?types.Diagnostic {
    const range = rangeFromSpan(text, span.start, span.end);
    const message = std.fmt.allocPrint(allocator, "Templates are not allowed in table headers", .{}) catch return null;
    allocated_messages.append(allocator, message) catch return null;
    return .{
        .range = range,
        .severity = diagnosticSeverityToLsp(severity),
        .source = "jade_toml_lsp",
        .message = message,
    };
}

fn collectCommentControlCharDiagnostics(
    allocator: std.mem.Allocator,
    text: []const u8,
    severity: DiagnosticsSeverity,
    allocated_messages: *std.ArrayList([]u8),
) ?[]types.Diagnostic {
    var diagnostics: std.ArrayList(types.Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);

    var state: jade.QuoteState = .none;
    var comment_start: ?usize = null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\n') {
            comment_start = null;
            continue;
        }

        if (comment_start) |start| {
            _ = start;
            if ((ch < 0x20 and ch != '\t') or ch == 0x7F) {
                const range = rangeFromSpan(text, i, i + 1);
                const message = std.fmt.allocPrint(allocator, "Control characters are not allowed in comments", .{}) catch return null;
                allocated_messages.append(allocator, message) catch return null;
                diagnostics.append(allocator, .{
                    .range = range,
                    .severity = diagnosticSeverityToLsp(severity),
                    .source = "jade_toml_lsp",
                    .message = message,
                }) catch {};
            }
            continue;
        }

        jade.updateQuoteState(text, &i, &state);
        if (state == .none and text[i] == '#') {
            comment_start = i + 1;
        }
    }

    if (diagnostics.items.len == 0) return null;
    return diagnostics.toOwnedSlice(allocator) catch null;
}

fn tomlValueString(allocator: std.mem.Allocator, value: toml.Value) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    appendTomlValueInline(allocator, &out, value) catch return null;
    return out.toOwnedSlice(allocator) catch null;
}

fn appendTomlValueInline(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: toml.Value) !void {
    switch (value) {
        .string => |s| {
            const tmp = try std.fmt.allocPrint(allocator, "\"{s}\"", .{s});
            defer allocator.free(tmp);
            try out.appendSlice(allocator, tmp);
        },
        .integer => |i| {
            const tmp = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(tmp);
            try out.appendSlice(allocator, tmp);
        },
        .float => |f| {
            const tmp = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(tmp);
            try out.appendSlice(allocator, tmp);
        },
        .boolean => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .date => |d| {
            const tmp = try std.fmt.allocPrint(allocator, "{d}-{d:02}-{d:02}", .{ d.year, d.month, d.day });
            defer allocator.free(tmp);
            try out.appendSlice(allocator, tmp);
        },
        .time => |t| {
            const tmp = try std.fmt.allocPrint(allocator, "{d:02}:{d:02}:{d:02}", .{ t.hour, t.minute, t.second });
            defer allocator.free(tmp);
            try out.appendSlice(allocator, tmp);
        },
        .datetime => |dt| {
            const tmp = try std.fmt.allocPrint(allocator, "{d}-{d:02}-{d:02}T{d:02}:{d:02}:{d:02}", .{ dt.date.year, dt.date.month, dt.date.day, dt.time.hour, dt.time.minute, dt.time.second });
            defer allocator.free(tmp);
            try out.appendSlice(allocator, tmp);
        },
        .array => |ar| {
            try out.appendSlice(allocator, "[ ");
            for (ar.items, 0..) |item, idx| {
                if (idx > 0) try out.appendSlice(allocator, ", ");
                try appendTomlValueInline(allocator, out, item);
            }
            try out.appendSlice(allocator, " ]");
        },
        .table => |_| try out.appendSlice(allocator, "table"),
    }
}

const TableHeaderInfo = struct {
    name: []const u8,
    index: ?usize,
};

fn tableHeaderHasTemplate(line_text: []const u8) bool {
    if (tableHeaderRangeForLine(line_text)) |range| {
        if (range.end > range.start) {
            const slice = line_text[range.start..range.end];
            return std.mem.indexOf(u8, slice, "{{") != null;
        }
    }
    return false;
}

fn tableHeaderInfo(allocator: std.mem.Allocator, text: []const u8, line: usize) ?TableHeaderInfo {
    const line_text = jade.lineSlice(text, line) orelse return null;
    const trimmed = std.mem.trim(u8, line_text, " \t\r");
    if (trimmed.len < 3 or trimmed[0] != '[') return null;

    const is_array = trimmed.len >= 4 and trimmed[0] == '[' and trimmed[1] == '[';
    if (!is_array and trimmed[0] != '[') return null;
    if (is_array and trimmed[trimmed.len - 2] != ']') return null;
    if (tableHeaderHasTemplate(line_text)) return null;

    const header_path = parseTableHeaderPath(allocator, trimmed) orelse return null;
    defer allocator.free(header_path);
    if (header_path.len == 0) return null;

    const name = header_path[header_path.len - 1];
    if (!is_array) {
        return .{ .name = name, .index = null };
    }

    const target_path = header_path;
    const idx = countArrayHeaderIndex(allocator, text, line, target_path) orelse return null;
    return .{ .name = name, .index = idx };
}

fn arrayHeaderContext(allocator: std.mem.Allocator, text: []const u8, line: usize) ?ArrayContext {
    if (line == 0) return null;
    var idx: usize = line;
    while (idx > 0) : (idx -= 1) {
        const line_text = jade.lineSlice(text, idx - 1) orelse "";
        const trimmed = std.mem.trim(u8, line_text, " \t");
        if (trimmed.len >= 4 and trimmed[0] == '[' and trimmed[1] == '[' and trimmed[trimmed.len - 2] == ']') {
            if (tableHeaderInfo(allocator, text, idx - 1)) |header| {
                if (header.index) |index| {
                    return .{ .name = header.name, .index = index };
                }
            }
        }
    }
    return null;
}

fn countArrayHeaderIndex(allocator: std.mem.Allocator, text: []const u8, line: usize, target_path: []const []const u8) ?usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (idx <= line) : (idx += 1) {
        const line_text = jade.lineSlice(text, idx) orelse "";
        const trimmed = std.mem.trim(u8, line_text, " \t");
        if (trimmed.len >= 4 and trimmed[0] == '[' and trimmed[1] == '[' and trimmed[trimmed.len - 2] == ']') {
            if (parseTableHeaderPath(allocator, trimmed)) |path| {
                defer allocator.free(path);
                if (pathEquals(path, target_path)) {
                    if (idx == line) return count;
                    count += 1;
                }
            }
        }
    }
    return null;
}

const ArrayItemInfo = struct {
    path: [][]const u8,
    index: usize,
    key: ?[]const u8 = null,
    table: ?[]const u8 = null,
};

const InlineKeyInfo = struct {
    path: [][]const u8,
    key: ?[]const u8 = null,
    table: ?[]const u8 = null,
};

fn arrayItemInfo(allocator: std.mem.Allocator, text: []const u8, line: usize, character: usize) ?ArrayItemInfo {
    const line_text = jade.lineSlice(text, line) orelse return null;
    if (std.mem.indexOfScalar(u8, line_text, '[') == null) {
        // check multiline array
        if (nearestArrayKeyBefore(allocator, text, line)) |info| {
            const table_path = tablePathForLine(allocator, text, line) orelse {
                allocator.free(info.path);
                return null;
            };
            defer allocator.free(table_path);
            const combined = joinPaths(allocator, table_path, info.path) orelse {
                allocator.free(info.path);
                return null;
            };
            allocator.free(info.path);
            return .{
                .path = combined,
                .index = info.index,
                .key = null,
                .table = null,
            };
        }
        return null;
    }

    const eq_index = std.mem.indexOfScalar(u8, line_text, '=') orelse return null;
    const key_path = extractKeyPath(allocator, line_text) orelse return null;
    const bracket_index = std.mem.indexOfScalarPos(u8, line_text, eq_index, '[') orelse {
        allocator.free(key_path);
        return null;
    };
    if (character <= bracket_index) {
        allocator.free(key_path);
        return null;
    }
    if (std.mem.indexOfScalarPos(u8, line_text, bracket_index, ']')) |close_idx| {
        if (character >= close_idx) {
            allocator.free(key_path);
            return null;
        }
    }
    const idx = arrayIndexInLine(line_text, bracket_index + 1, character) orelse {
        allocator.free(key_path);
        return null;
    };
    const table_path = tablePathForLine(allocator, text, line) orelse {
        allocator.free(key_path);
        return null;
    };
    defer allocator.free(table_path);
    const combined = joinPaths(allocator, table_path, key_path) orelse {
        allocator.free(key_path);
        return null;
    };
    allocator.free(key_path);
    return .{
        .path = combined,
        .index = idx,
        .key = null,
        .table = null,
    };
}

fn nearestArrayKeyBefore(allocator: std.mem.Allocator, text: []const u8, line: usize) ?ArrayItemInfo {
    if (line == 0) return null;
    var idx: usize = line;
    while (idx > 0) : (idx -= 1) {
        const lt = jade.lineSlice(text, idx - 1) orelse "";
        if (isCommentOrEmpty(lt)) continue;
        if (std.mem.indexOfScalar(u8, lt, '[') == null) continue;
        const key_path = extractKeyPath(allocator, lt) orelse continue;
        const array_index = arrayIndexAcrossLines(text, idx - 1, line) orelse {
            allocator.free(key_path);
            return null;
        };
        return .{ .path = key_path, .index = array_index };
    }
    return null;
}

fn arrayIndexInLine(line_text: []const u8, start: usize, character: usize) ?usize {
    var count: usize = 0;
    var i: usize = start;
    var state: jade.QuoteState = .none;
    while (i < line_text.len) : (i += 1) {
        jade.updateQuoteState(line_text, &i, &state);
        if (state == .none) {
            if (line_text[i] == ',') count += 1;
            if (line_text[i] == ']' and i >= character) break;
        }
        if (i >= character) break;
    }
    return count;
}

fn arrayIndexAcrossLines(text: []const u8, start_line: usize, target_line: usize) ?usize {
    var count: usize = 0;
    var line_idx: usize = start_line;
    var started = false;
    var state: jade.QuoteState = .none;
    while (line_idx <= target_line) : (line_idx += 1) {
        const line_text = jade.lineSlice(text, line_idx) orelse "";
        var i: usize = 0;
        while (i < line_text.len) : (i += 1) {
            jade.updateQuoteState(line_text, &i, &state);
            if (!started) {
                if (line_text[i] == '[') {
                    started = true;
                }
                continue;
            }
            if (state == .none and line_text[i] == ',') count += 1;
            if (state == .none and line_text[i] == ']') {
                if (line_idx < target_line) return null;
                return count;
            }
        }
    }
    return count;
}

const KeySegment = struct {
    text: []const u8,
    start: usize,
    end: usize,
};

fn parseKeySegments(allocator: std.mem.Allocator, line_text: []const u8) ?[]KeySegment {
    const eq_index = std.mem.indexOfScalar(u8, line_text, '=') orelse return null;
    const key_part = line_text[0..eq_index];

    var segments: std.ArrayList(KeySegment) = .empty;
    var i: usize = 0;
    while (i < key_part.len) {
        while (i < key_part.len and (key_part[i] == ' ' or key_part[i] == '\t')) : (i += 1) {}
        if (i >= key_part.len) break;

        const seg_start = i;
        var seg_end = i;
        if (key_part[i] == '"' or key_part[i] == '\'') {
            const quote = key_part[i];
            i += 1;
            while (i < key_part.len and key_part[i] != quote) : (i += 1) {}
            seg_end = if (i < key_part.len) i + 1 else i;
            i = seg_end;
        } else {
            while (i < key_part.len and key_part[i] != '.' and key_part[i] != ' ' and key_part[i] != '\t') : (i += 1) {}
            seg_end = i;
        }

        var seg_text = std.mem.trim(u8, key_part[seg_start..seg_end], " \t");
        var text_start = seg_start;
        var text_end = seg_end;
        if (seg_text.len >= 2) {
            if ((seg_text[0] == '"' and seg_text[seg_text.len - 1] == '"') or (seg_text[0] == '\'' and seg_text[seg_text.len - 1] == '\'')) {
                seg_text = seg_text[1 .. seg_text.len - 1];
                text_start += 1;
                text_end -= 1;
            }
        }

        if (seg_text.len != 0) {
            segments.append(allocator, .{
                .text = seg_text,
                .start = text_start,
                .end = text_end,
            }) catch return null;
        }

        while (i < key_part.len and (key_part[i] == ' ' or key_part[i] == '\t')) : (i += 1) {}
        if (i < key_part.len and key_part[i] == '.') i += 1;
    }

    return segments.toOwnedSlice(allocator) catch null;
}

const ElementRange = struct {
    start: usize,
    end: usize,
};

fn parseArrayElementRange(line_text: []const u8, index: usize) ?ElementRange {
    var in_double = false;
    var in_single = false;
    var escape = false;

    var eq_index: ?usize = null;
    var i: usize = 0;
    while (i < line_text.len) : (i += 1) {
        const ch = line_text[i];
        if (escape) {
            escape = false;
        } else if (in_double and ch == '\\') {
            escape = true;
        } else if (in_double) {
            if (ch == '"') in_double = false;
        } else if (in_single) {
            if (ch == '\'') in_single = false;
        } else {
            if (ch == '"') {
                in_double = true;
            } else if (ch == '\'') {
                in_single = true;
            } else if (ch == '=') {
                eq_index = i;
                break;
            }
        }
    }
    if (eq_index == null) return null;
    i = eq_index.? + 1;
    while (i < line_text.len and (line_text[i] == ' ' or line_text[i] == '\t')) : (i += 1) {}
    if (i >= line_text.len or line_text[i] != '[') return null;

    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    in_double = false;
    in_single = false;
    escape = false;

    var elem_index: usize = 0;
    var elem_start: ?usize = null;
    var elem_end: ?usize = null;

    var j: usize = i;
    while (j < line_text.len) : (j += 1) {
        const ch = line_text[j];
        if (escape) {
            escape = false;
            continue;
        }
        if (in_double) {
            if (ch == '\\') {
                escape = true;
            } else if (ch == '"') {
                in_double = false;
            }
            continue;
        }
        if (in_single) {
            if (ch == '\'') in_single = false;
            continue;
        }

        switch (ch) {
            '"' => {
                in_double = true;
            },
            '\'' => {
                in_single = true;
            },
            '[' => {
                bracket_depth += 1;
                if (bracket_depth == 1) {
                    elem_start = null;
                    elem_end = null;
                }
            },
            ']' => {
                if (bracket_depth == 1) {
                    if (elem_start != null) {
                        elem_end = j;
                    }
                    if (elem_start != null and elem_end != null and elem_index == index) {
                        return trimmedElementRange(line_text, elem_start.?, elem_end.?);
                    }
                }
                if (bracket_depth > 0) bracket_depth -= 1;
                if (bracket_depth == 0) break;
            },
            '{' => {
                if (bracket_depth >= 1) brace_depth += 1;
            },
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            ',' => {
                if (bracket_depth == 1 and brace_depth == 0) {
                    if (elem_start != null) {
                        elem_end = j;
                    }
                    if (elem_start != null and elem_end != null and elem_index == index) {
                        return trimmedElementRange(line_text, elem_start.?, elem_end.?);
                    }
                    elem_index += 1;
                    elem_start = null;
                    elem_end = null;
                }
            },
            else => {},
        }

        if (bracket_depth == 1 and brace_depth == 0 and elem_start == null) {
            if (ch != ' ' and ch != '\t' and ch != ',' and ch != ']') {
                elem_start = j;
            }
        }
    }
    return null;
}

fn trimmedElementRange(line_text: []const u8, start: usize, end: usize) ElementRange {
    var s = start;
    var e = end;
    while (s < e and (line_text[s] == ' ' or line_text[s] == '\t')) : (s += 1) {}
    while (e > s and (line_text[e - 1] == ' ' or line_text[e - 1] == '\t')) : (e -= 1) {}
    return .{ .start = s, .end = e };
}

fn findArrayElementRange(
    allocator: std.mem.Allocator,
    text: []const u8,
    array_path: []const []const u8,
    index: usize,
) ?types.Range {
    var current_path: [][]const u8 = allocator.alloc([]const u8, 0) catch return null;
    defer allocator.free(current_path);

    var line_index: usize = 0;
    while (true) {
        const line_text = jade.lineSlice(text, line_index) orelse break;
        const trimmed = std.mem.trim(u8, line_text, " \t");
        if (trimmed.len != 0 and trimmed[0] == '[') {
            if (parseTableHeaderPath(allocator, trimmed)) |table_path| {
                allocator.free(current_path);
                current_path = table_path;
            }
        } else if (!isCommentOrEmpty(line_text)) {
            if (parseKeySegments(allocator, line_text)) |segments| {
                defer allocator.free(segments);
                if (segments.len > 0) {
                    const seg_path = segmentsToPath(allocator, segments) orelse return null;
                    defer allocator.free(seg_path);
                    const combined = joinPaths(allocator, current_path, seg_path) orelse return null;
                    defer allocator.free(combined);
                    if (pathEquals(combined, array_path)) {
                        if (parseArrayElementRange(line_text, index)) |range| {
                            return .{
                                .start = .{ .line = @intCast(line_index), .character = @intCast(range.start) },
                                .end = .{ .line = @intCast(line_index), .character = @intCast(range.end) },
                            };
                        }
                    }
                }
            }
        }
        line_index += 1;
    }
    return null;
}

fn findKeyDefinitionRange(allocator: std.mem.Allocator, text: []const u8, path: []const []const u8) ?types.Range {
    if (arrayElementTarget(path)) |target| {
        return findArrayElementRange(allocator, text, target.path, target.index);
    }

    var current_path: [][]const u8 = allocator.alloc([]const u8, 0) catch return null;
    defer allocator.free(current_path);

    var line_index: usize = 0;
    while (true) {
        const line_text = jade.lineSlice(text, line_index) orelse break;
        const trimmed = std.mem.trim(u8, line_text, " \t");
        if (trimmed.len != 0 and trimmed[0] == '[') {
            if (parseTableHeaderPath(allocator, trimmed)) |table_path| {
                allocator.free(current_path);
                current_path = table_path;
            }
        } else if (!isCommentOrEmpty(line_text)) {
            if (parseKeySegments(allocator, line_text)) |segments| {
                defer allocator.free(segments);
                if (segments.len > 0) {
                    const seg_path = segmentsToPath(allocator, segments) orelse return null;
                    defer allocator.free(seg_path);
                    const combined = joinPaths(allocator, current_path, seg_path) orelse return null;
                    defer allocator.free(combined);
                    if (pathEquals(combined, path)) {
                        const last = segments[segments.len - 1];
                        return .{
                            .start = .{ .line = @intCast(line_index), .character = @intCast(last.start) },
                            .end = .{ .line = @intCast(line_index), .character = @intCast(last.end) },
                        };
                    }
                    if (inlineKeyRangesForLine(allocator, line_text, line_index, current_path, seg_path)) |inline_ranges| {
                        defer freeInlineKeyRanges(allocator, inline_ranges);
                        for (inline_ranges) |entry| {
                            if (pathEquals(entry.path, path)) {
                                return entry.range;
                            }
                        }
                    }
                }
            }
        }
        line_index += 1;
    }
    return null;
}

fn collectKeyReferenceRanges(allocator: std.mem.Allocator, text: []const u8, path: []const []const u8) ?[]types.Range {
    if (arrayElementTarget(path)) |target| {
        return collectArrayElementReferenceRanges(allocator, text, target.path, target.index);
    }

    var ranges: std.ArrayList(types.Range) = .empty;
    errdefer ranges.deinit(allocator);

    var current_path: [][]const u8 = allocator.alloc([]const u8, 0) catch return null;
    defer allocator.free(current_path);

    var line_index: usize = 0;
    while (true) {
        const line_text = jade.lineSlice(text, line_index) orelse break;
        const trimmed = std.mem.trim(u8, line_text, " \t");
        if (trimmed.len != 0 and trimmed[0] == '[') {
            if (parseTableHeaderPath(allocator, trimmed)) |table_path| {
                allocator.free(current_path);
                current_path = table_path;
            }
        } else if (!isCommentOrEmpty(line_text)) {
            if (parseKeySegments(allocator, line_text)) |segments| {
                defer allocator.free(segments);
                if (segments.len > 0) {
                    const seg_path = segmentsToPath(allocator, segments) orelse return null;
                    defer allocator.free(seg_path);
                    const combined = joinPaths(allocator, current_path, seg_path) orelse return null;
                    defer allocator.free(combined);
                    if (pathEquals(combined, path)) {
                        const last = segments[segments.len - 1];
                        ranges.append(allocator, .{
                            .start = .{ .line = @intCast(line_index), .character = @intCast(last.start) },
                            .end = .{ .line = @intCast(line_index), .character = @intCast(last.end) },
                        }) catch {};
                    }

                    if (inlineKeyRangesForLine(allocator, line_text, line_index, current_path, seg_path)) |inline_ranges| {
                        defer freeInlineKeyRanges(allocator, inline_ranges);
                        for (inline_ranges) |entry| {
                            if (pathEquals(entry.path, path)) {
                                ranges.append(allocator, entry.range) catch {};
                            }
                        }
                    }
                }
            }
        }
        line_index += 1;
    }

    return ranges.toOwnedSlice(allocator) catch null;
}

fn collectArrayElementReferenceRanges(
    allocator: std.mem.Allocator,
    text: []const u8,
    array_path: []const []const u8,
    index: usize,
) ?[]types.Range {
    var ranges: std.ArrayList(types.Range) = .empty;
    errdefer ranges.deinit(allocator);

    var current_path: [][]const u8 = allocator.alloc([]const u8, 0) catch return null;
    defer allocator.free(current_path);

    var line_index: usize = 0;
    while (true) {
        const line_text = jade.lineSlice(text, line_index) orelse break;
        const trimmed = std.mem.trim(u8, line_text, " \t");
        if (trimmed.len != 0 and trimmed[0] == '[') {
            if (parseTableHeaderPath(allocator, trimmed)) |table_path| {
                allocator.free(current_path);
                current_path = table_path;
            }
        } else if (!isCommentOrEmpty(line_text)) {
            if (parseKeySegments(allocator, line_text)) |segments| {
                defer allocator.free(segments);
                if (segments.len > 0) {
                    const seg_path = segmentsToPath(allocator, segments) orelse return null;
                    defer allocator.free(seg_path);
                    const combined = joinPaths(allocator, current_path, seg_path) orelse return null;
                    defer allocator.free(combined);
                    if (pathEquals(combined, array_path)) {
                        if (parseArrayElementRange(line_text, index)) |range| {
                            ranges.append(allocator, .{
                                .start = .{ .line = @intCast(line_index), .character = @intCast(range.start) },
                                .end = .{ .line = @intCast(line_index), .character = @intCast(range.end) },
                            }) catch return null;
                        }
                    }
                }
            }
        }
        line_index += 1;
    }

    return ranges.toOwnedSlice(allocator) catch null;
}

const InlineKeyRange = struct {
    path: [][]const u8,
    range: types.Range,
};

fn freeInlineKeyRanges(allocator: std.mem.Allocator, ranges: []InlineKeyRange) void {
    for (ranges) |entry| {
        allocator.free(entry.path);
    }
    allocator.free(ranges);
}

fn inlineKeyRangesForLine(
    allocator: std.mem.Allocator,
    line_text: []const u8,
    line_index: usize,
    table_path: []const []const u8,
    outer_path: []const []const u8,
) ?[]InlineKeyRange {
    const eq_index = std.mem.indexOfScalar(u8, line_text, '=') orelse return null;
    const value_part = line_text[eq_index + 1 ..];
    const brace_open_rel = std.mem.indexOfScalar(u8, value_part, '{') orelse return null;
    const brace_close_rel = std.mem.lastIndexOfScalar(u8, value_part, '}') orelse return null;
    if (brace_close_rel <= brace_open_rel) return null;

    const brace_open = eq_index + 1 + brace_open_rel;
    const inside = value_part[brace_open_rel + 1 .. brace_close_rel];

    var ranges: std.ArrayList(InlineKeyRange) = .empty;
    errdefer ranges.deinit(allocator);

    var depth: usize = 0;
    var seg_start: usize = 0;
    var idx: usize = 0;
    while (idx <= inside.len) : (idx += 1) {
        const at_end = idx == inside.len;
        const ch = if (at_end) ',' else inside[idx];
        if (!at_end) {
            if (ch == '{') depth += 1;
            if (ch == '}') {
                if (depth > 0) depth -= 1;
            }
        }
        if (at_end or (ch == ',' and depth == 0)) {
            const seg_raw = inside[seg_start..idx];
            const seg = std.mem.trim(u8, seg_raw, " \t");
            if (seg.len > 0) {
                const seg_eq = std.mem.indexOfScalar(u8, seg, '=') orelse {
                    seg_start = idx + 1;
                    continue;
                };
                const key_part = std.mem.trim(u8, seg[0..seg_eq], " \t");
                const key_path = splitDottedPath(allocator, key_part) orelse {
                    seg_start = idx + 1;
                    continue;
                };
                defer allocator.free(key_path);

                const combined_outer = joinPaths(allocator, table_path, outer_path) orelse return null;
                defer allocator.free(combined_outer);
                const combined = joinPaths(allocator, combined_outer, key_path) orelse return null;

                var lead: usize = 0;
                while (lead < seg_raw.len and (seg_raw[lead] == ' ' or seg_raw[lead] == '\t')) : (lead += 1) {}
                const key_start = brace_open + seg_start + lead;
                const key_end = key_start + key_part.len;
                ranges.append(allocator, .{
                    .path = combined,
                    .range = .{
                        .start = .{ .line = @intCast(line_index), .character = @intCast(key_start) },
                        .end = .{ .line = @intCast(line_index), .character = @intCast(key_end) },
                    },
                }) catch {};
            }
            seg_start = idx + 1;
        }
    }

    if (ranges.items.len == 0) return null;
    return ranges.toOwnedSlice(allocator) catch null;
}

fn collectTemplateReferenceRanges(
    allocator: std.mem.Allocator,
    text: []const u8,
    spans: []const jade.TemplateSpan,
    path: []const []const u8,
) ?[]types.Range {
    var ranges: std.ArrayList(types.Range) = .empty;
    errdefer ranges.deinit(allocator);

    for (spans) |span| {
        if (extractTemplatePath(allocator, text, span)) |tpl_path| {
            defer allocator.free(tpl_path);
            if (pathEquals(tpl_path, path)) {
                ranges.append(allocator, rangeFromSpan(text, span.start, span.end)) catch {};
            }
        }
    }

    return ranges.toOwnedSlice(allocator) catch null;
}

fn segmentsToPath(allocator: std.mem.Allocator, segments: []const KeySegment) ?[][]const u8 {
    const out = allocator.alloc([]const u8, segments.len) catch return null;
    for (segments, 0..) |seg, idx| {
        out[idx] = seg.text;
    }
    return out;
}

fn pathEquals(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |seg, idx| {
        if (!std.mem.eql(u8, seg, b[idx])) return false;
    }
    return true;
}

fn pathToTableName(allocator: std.mem.Allocator, path: []const []const u8) ?[]const u8 {
    if (path.len <= 1) {
        return allocator.dupe(u8, "root") catch null;
    }
    return joinPathForMessage(allocator, path[0 .. path.len - 1]) catch null;
}

fn pathToKeyName(allocator: std.mem.Allocator, path: []const []const u8) ?[]const u8 {
    if (path.len == 0) return allocator.dupe(u8, "") catch null;
    return allocator.dupe(u8, path[path.len - 1]) catch null;
}

fn pathLastSegment(allocator: std.mem.Allocator, path: []const []const u8) ?[]const u8 {
    return pathToKeyName(allocator, path);
}

fn formatArrayKeyName(allocator: std.mem.Allocator, path: []const []const u8, index: usize) ?[]const u8 {
    if (path.len == 0) return allocator.dupe(u8, "") catch null;
    return std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path[path.len - 1], index }) catch null;
}

fn tableNameWithArrayContext(
    allocator: std.mem.Allocator,
    path: []const []const u8,
    ctx: ?ArrayContext,
) ?[]const u8 {
    if (path.len <= 1) {
        return allocator.dupe(u8, "root") catch null;
    }
    const end_index = path.len - 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var used_ctx = false;
    for (path[0..end_index], 0..) |segment, idx| {
        if (idx > 0) out.append(allocator, '.') catch return null;
        if (ctx) |c| {
            if (!used_ctx and std.mem.eql(u8, c.name, segment)) {
                const seg = std.fmt.allocPrint(allocator, "{s}[{d}]", .{ segment, c.index }) catch return null;
                defer allocator.free(seg);
                out.appendSlice(allocator, seg) catch return null;
                used_ctx = true;
                continue;
            }
        }
        out.appendSlice(allocator, segment) catch return null;
    }
    return out.toOwnedSlice(allocator) catch null;
}

fn inlineTableHoverInfo(allocator: std.mem.Allocator, text: []const u8, line: usize, character: usize) ?InlineKeyInfo {
    const line_text = jade.lineSlice(text, line) orelse return null;
    const eq_index = std.mem.indexOfScalar(u8, line_text, '=') orelse return null;
    const value_part = line_text[eq_index + 1 ..];
    const brace_open_rel = std.mem.indexOfScalar(u8, value_part, '{') orelse return null;
    const brace_close_rel = std.mem.lastIndexOfScalar(u8, value_part, '}') orelse return null;
    if (brace_close_rel <= brace_open_rel) return null;

    const brace_open = eq_index + 1 + brace_open_rel;
    const brace_close = eq_index + 1 + brace_close_rel;
    if (character < brace_open + 1 or character > brace_close) return null;

    const outer_path = extractKeyPath(allocator, line_text) orelse return null;
    defer allocator.free(outer_path);

    const inside = value_part[brace_open_rel + 1 .. brace_close_rel];
    const rel_char = character - (brace_open + 1);
    const inline_path = inlineKeyPathInTable(allocator, inside, rel_char) orelse return null;
    defer allocator.free(inline_path);

    const table_path = tablePathForLine(allocator, text, line) orelse return null;
    defer allocator.free(table_path);

    const combined_outer = joinPaths(allocator, table_path, outer_path) orelse return null;
    defer allocator.free(combined_outer);

    const combined = joinPaths(allocator, combined_outer, inline_path) orelse return null;
    return .{
        .path = combined,
        .key = null,
        .table = null,
    };
}

fn findTemplateTokenEnd(inner: []const u8) usize {
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '|' or c == ')' or c == '}' or c == ',') {
            break;
        }
    }
    return i;
}

fn joinPathForMessage(allocator: std.mem.Allocator, path: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (path, 0..) |part, idx| {
        if (idx > 0) try out.append(allocator, '.');
        try out.appendSlice(allocator, part);
    }
    return out.toOwnedSlice(allocator);
}

fn applyJsonSettings(settings: *Settings, value: std.json.Value) void {
    if (value != .object) return;
    const obj = value.object;
    if (obj.get("jade")) |inner| {
        applyJsonSettings(settings, inner);
        return;
    }
    if (obj.get("jade_toml_lsp")) |inner| {
        applyJsonSettings(settings, inner);
        return;
    }
    if (obj.get("jade-lsp")) |inner| {
        applyJsonSettings(settings, inner);
        return;
    }
    if (obj.get("jade-toml-lsp")) |inner| {
        applyJsonSettings(settings, inner);
        return;
    }

    if (obj.get("diagnostics")) |diag| {
        if (diag == .object) {
            if (diag.object.get("enabled")) |enabled| {
                if (enabled == .bool) settings.diagnostics.enabled = enabled.bool;
            }
            if (diag.object.get("severity")) |sev| {
                if (sev == .string) {
                    settings.diagnostics.severity = parseSeverity(sev.string);
                }
            }
            if (diag.object.get("templates")) |templates| {
                applyJsonTemplateSettings(&settings.diagnostics.templates, templates);
            }
            if (diag.object.get("templateOutsideQuotes")) |outside| {
                applyJsonRule(&settings.diagnostics.templates.outside_quotes, outside);
            }
            if (diag.object.get("templateMissingKey")) |missing| {
                applyJsonRule(&settings.diagnostics.templates.missing_key, missing);
            }
            if (diag.object.get("templateCycle")) |cycle| {
                applyJsonRule(&settings.diagnostics.templates.cycle, cycle);
            }
            if (diag.object.get("templateInKeys")) |in_keys| {
                applyJsonRule(&settings.diagnostics.templates.in_keys, in_keys);
            }
            if (diag.object.get("templateInlineKeys")) |inline_keys| {
                applyJsonRule(&settings.diagnostics.templates.inline_keys, inline_keys);
            }
            if (diag.object.get("templateInHeaders")) |in_headers| {
                applyJsonRule(&settings.diagnostics.templates.in_headers, in_headers);
            }
        }
    }

    if (obj.get("format")) |fmt| {
        switch (fmt) {
            .bool => |b| settings.format.enabled = b,
            .object => |fmt_obj| {
                if (fmt_obj.get("enabled")) |enabled| {
                    if (enabled == .bool) settings.format.enabled = enabled.bool;
                }
                if (fmt_obj.get("respect_trailing_commas")) |rtc| {
                    if (rtc == .bool) settings.format.respect_trailing_commas = rtc.bool;
                }
            },
            else => {},
        }
    }

    if (obj.get("inlayHints")) |inlay| {
        switch (inlay) {
            .bool => |b| settings.inlay_hints.enabled = b,
            .object => |inlay_obj| {
                if (inlay_obj.get("enabled")) |enabled| {
                    if (enabled == .bool) settings.inlay_hints.enabled = enabled.bool;
                }
            },
            else => {},
        }
    }
    if (obj.get("inlay_hints")) |inlay| {
        switch (inlay) {
            .bool => |b| settings.inlay_hints.enabled = b,
            .object => |inlay_obj| {
                if (inlay_obj.get("enabled")) |enabled| {
                    if (enabled == .bool) settings.inlay_hints.enabled = enabled.bool;
                }
            },
            else => {},
        }
    }
}

fn applyJsonTemplateSettings(settings: *TemplateDiagnosticsSettings, value: std.json.Value) void {
    if (value != .object) return;
    if (value.object.get("outside_quotes")) |outside| {
        applyJsonRule(&settings.outside_quotes, outside);
    }
    if (value.object.get("missing_key")) |missing| {
        applyJsonRule(&settings.missing_key, missing);
    }
    if (value.object.get("cycle")) |cycle| {
        applyJsonRule(&settings.cycle, cycle);
    }
    if (value.object.get("in_keys")) |in_keys| {
        applyJsonRule(&settings.in_keys, in_keys);
    }
    if (value.object.get("inline_keys")) |inline_keys| {
        applyJsonRule(&settings.inline_keys, inline_keys);
    }
    if (value.object.get("in_headers")) |in_headers| {
        applyJsonRule(&settings.in_headers, in_headers);
    }
}

fn applyJsonRule(rule: *DiagnosticsRule, value: std.json.Value) void {
    switch (value) {
        .bool => |b| rule.enabled = b,
        .string => |s| rule.severity = parseSeverity(s),
        .object => |obj| {
            if (obj.get("enabled")) |enabled| {
                if (enabled == .bool) rule.enabled = enabled.bool;
            }
            if (obj.get("severity")) |sev| {
                if (sev == .string) rule.severity = parseSeverity(sev.string);
            }
        },
        else => {},
    }
}

fn applyTomlSettingsForUri(allocator: std.mem.Allocator, uri: []const u8, settings: *Settings) void {
    const path = uriToPath(allocator, uri) orelse return;
    defer allocator.free(path);

    const dir = std.fs.path.dirname(path) orelse return;
    const config_path = findConfigUpwards(allocator, dir) orelse return;
    defer allocator.free(config_path);

    const config_text = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch return;
    defer allocator.free(config_text);

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();

    const parsed = parser.parseString(config_text) catch return;
    defer parsed.deinit();

    applyTomlSettings(settings, parsed.value);
}

fn applyTomlSettings(settings: *Settings, table: toml.Table) void {
    if (table.get("format")) |fmt| {
        switch (fmt) {
            .boolean => |b| settings.format.enabled = b,
            .table => |t| {
                const fmt_table = t.*;
                if (fmt_table.get("enabled")) |enabled| {
                    if (enabled == .boolean) settings.format.enabled = enabled.boolean;
                }
                if (fmt_table.get("respect_trailing_commas")) |rtc| {
                    if (rtc == .boolean) settings.format.respect_trailing_commas = rtc.boolean;
                }
            },
            else => {},
        }
    }
    if (table.get("inlay_hints")) |inlay| {
        switch (inlay) {
            .boolean => |b| settings.inlay_hints.enabled = b,
            .table => |t| {
                const inlay_table = t.*;
                if (inlay_table.get("enabled")) |enabled| {
                    if (enabled == .boolean) settings.inlay_hints.enabled = enabled.boolean;
                }
            },
            else => {},
        }
    }
    if (table.get("diagnostics")) |diag_value| {
        switch (diag_value) {
            .table => |t| {
                const diag_table = t.*;
                if (diag_table.get("enabled")) |enabled| {
                    if (enabled == .boolean) settings.diagnostics.enabled = enabled.boolean;
                }
                if (diag_table.get("severity")) |sev| {
                    if (sev == .string) settings.diagnostics.severity = parseSeverity(sev.string);
                }
                if (diag_table.get("templates")) |templates| {
                    applyTomlTemplateSettings(&settings.diagnostics.templates, templates);
                }
            },
            else => {},
        }
    }
}

fn applyTomlTemplateSettings(settings: *TemplateDiagnosticsSettings, value: toml.Value) void {
    switch (value) {
        .table => |t| {
            const tmpl_table = t.*;
            if (tmpl_table.get("outside_quotes")) |outside| {
                applyTomlRule(&settings.outside_quotes, outside);
            }
            if (tmpl_table.get("missing_key")) |missing| {
                applyTomlRule(&settings.missing_key, missing);
            }
            if (tmpl_table.get("cycle")) |cycle| {
                applyTomlRule(&settings.cycle, cycle);
            }
            if (tmpl_table.get("in_keys")) |in_keys| {
                applyTomlRule(&settings.in_keys, in_keys);
            }
            if (tmpl_table.get("inline_keys")) |inline_keys| {
                applyTomlRule(&settings.inline_keys, inline_keys);
            }
            if (tmpl_table.get("in_headers")) |in_headers| {
                applyTomlRule(&settings.in_headers, in_headers);
            }
        },
        else => {},
    }
}

fn applyTomlRule(rule: *DiagnosticsRule, value: toml.Value) void {
    switch (value) {
        .boolean => |b| rule.enabled = b,
        .string => |s| rule.severity = parseSeverity(s),
        .table => |t| {
            const table = t.*;
            if (table.get("enabled")) |enabled| {
                if (enabled == .boolean) rule.enabled = enabled.boolean;
            }
            if (table.get("severity")) |sev| {
                if (sev == .string) rule.severity = parseSeverity(sev.string);
            }
        },
        else => {},
    }
}

fn parseSeverity(value: []const u8) DiagnosticsSeverity {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "error")) return .err;
    if (std.mem.eql(u8, value, "warning")) return .warn;
    if (std.mem.eql(u8, value, "info")) return .info;
    if (std.mem.eql(u8, value, "hint")) return .hint;
    return .err;
}

fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) ?[]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    var path = uri["file://".len..];
    if (path.len >= 3 and path[0] == '/' and path[2] == ':') {
        path = path[1..];
    }
    return percentDecode(allocator, path);
}

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexValue(input[i + 1]) orelse return null;
            const lo = hexValue(input[i + 2]) orelse return null;
            out.append(allocator, @intCast((hi << 4) | lo)) catch return null;
            i += 2;
            continue;
        }
        out.append(allocator, input[i]) catch return null;
    }
    return out.toOwnedSlice(allocator) catch null;
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn findConfigUpwards(allocator: std.mem.Allocator, start_dir: []const u8) ?[]u8 {
    var current = allocator.dupe(u8, start_dir) catch return null;

    while (true) {
        const candidate = std.fs.path.join(allocator, &.{ current, "jade.toml" }) catch {
            allocator.free(current);
            return null;
        };
        defer allocator.free(candidate);

        if (fileExists(candidate)) {
            const found = allocator.dupe(u8, candidate) catch null;
            allocator.free(current);
            return found;
        }

        const parent = std.fs.path.dirname(current) orelse {
            allocator.free(current);
            return null;
        };
        if (std.mem.eql(u8, parent, current)) {
            allocator.free(current);
            return null;
        }
        const next = allocator.dupe(u8, parent) catch {
            allocator.free(current);
            return null;
        };
        allocator.free(current);
        current = next;
    }
}

fn fileExists(path: []const u8) bool {
    var file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

fn makeEditSlice(arena: std.mem.Allocator, edit: types.TextEdit) ?[]const types.TextEdit {
    const edits = arena.alloc(types.TextEdit, 1) catch return null;
    edits[0] = edit;
    return edits;
}

fn makeCodeActionResult(arena: std.mem.Allocator, action: types.CodeAction) lsp.ResultType("textDocument/codeAction") {
    const ResultType = lsp.ResultType("textDocument/codeAction");
    const slice_type = @typeInfo(ResultType).optional.child;
    const item_type = @typeInfo(slice_type).pointer.child;

    const items = arena.alloc(item_type, 1) catch return null;
    items[0] = .{ .CodeAction = action };
    return items;
}

fn makeDefinitionResult(arena: std.mem.Allocator, location: types.Location) lsp.ResultType("textDocument/definition") {
    _ = arena;
    const definition: types.Definition = .{ .Location = location };
    return .{ .Definition = definition };
}

fn extractKeyPath(allocator: std.mem.Allocator, line_text: []const u8) ?[][]const u8 {
    const eq_index = std.mem.indexOfScalar(u8, line_text, '=') orelse return null;
    const raw = std.mem.trim(u8, line_text[0..eq_index], " \t");
    if (raw.len == 0) return null;

    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, '.');
    while (it.next()) |part_raw| {
        var part = std.mem.trim(u8, part_raw, " \t");
        if (part.len >= 2) {
            if ((part[0] == '"' and part[part.len - 1] == '"') or (part[0] == '\'' and part[part.len - 1] == '\'')) {
                part = part[1 .. part.len - 1];
            }
        }
        if (part.len == 0) return null;
        parts.append(allocator, part) catch return null;
    }
    return parts.toOwnedSlice(allocator) catch null;
}

fn resolveKeyPathAt(
    allocator: std.mem.Allocator,
    text: []const u8,
    line: usize,
    character: usize,
) ?[][]const u8 {
    const line_text = jade.lineSlice(text, line) orelse return null;
    if (parseTableHeaderPathAt(allocator, line_text, character)) |header_path| {
        return header_path;
    }

    const table_path = tablePathForLine(allocator, text, line) orelse return null;

    if (std.mem.indexOfScalar(u8, line_text, '=')) |_| {
        if (inlineTableKeyPathAt(allocator, line_text, character)) |inline_path| {
            const outer_path = extractKeyPath(allocator, line_text) orelse {
                allocator.free(inline_path);
                allocator.free(table_path);
                return null;
            };
            const combined = joinPaths(allocator, outer_path, inline_path) orelse {
                allocator.free(inline_path);
                allocator.free(outer_path);
                allocator.free(table_path);
                return null;
            };
            allocator.free(inline_path);
            allocator.free(outer_path);
            const final = joinPaths(allocator, table_path, combined) orelse {
                allocator.free(combined);
                allocator.free(table_path);
                return null;
            };
            allocator.free(combined);
            allocator.free(table_path);
            return final;
        }

        if (extractKeyPathAt(allocator, line_text, character)) |key_path| {
            const final = joinPaths(allocator, table_path, key_path) orelse {
                allocator.free(key_path);
                allocator.free(table_path);
                return null;
            };
            allocator.free(key_path);
            allocator.free(table_path);
            return final;
        }
    }

    if (nearestKeyPathBefore(allocator, text, line)) |key_path| {
        const final = joinPaths(allocator, table_path, key_path) orelse {
            allocator.free(key_path);
            allocator.free(table_path);
            return null;
        };
        allocator.free(key_path);
        allocator.free(table_path);
        return final;
    }

    allocator.free(table_path);
    return null;
}

fn nearestKeyPathBefore(allocator: std.mem.Allocator, text: []const u8, line: usize) ?[][]const u8 {
    if (line == 0) return null;
    var idx: usize = line;
    while (idx > 0) : (idx -= 1) {
        const lt = jade.lineSlice(text, idx - 1) orelse "";
        if (isCommentOrEmpty(lt)) continue;
        if (parseTableHeaderPathAt(allocator, lt, 0)) |_| continue;
        if (std.mem.indexOfScalar(u8, lt, '=')) |_| {
            return extractKeyPathAt(allocator, lt, 0);
        }
    }
    return null;
}

fn tablePathForLine(allocator: std.mem.Allocator, text: []const u8, line: usize) ?[][]const u8 {
    var current: [][]const u8 = allocator.alloc([]const u8, 0) catch return null;
    var idx: usize = 0;
    while (idx <= line) : (idx += 1) {
        const lt = jade.lineSlice(text, idx) orelse "";
        if (parseTableHeaderPath(allocator, lt)) |path| {
            allocator.free(current);
            current = path;
        }
    }
    return current;
}

fn parseTableHeaderPath(allocator: std.mem.Allocator, line_text: []const u8) ?[][]const u8 {
    return parseTableHeaderPathAt(allocator, line_text, 0);
}

fn parseTableHeaderPathAt(allocator: std.mem.Allocator, line_text: []const u8, character: usize) ?[][]const u8 {
    const trimmed = std.mem.trim(u8, line_text, " \t\r");
    if (trimmed.len < 3 or trimmed[0] != '[') return null;

    var start_index: usize = 1;
    var end_index: usize = trimmed.len;
    var is_array = false;

    if (trimmed.len >= 4 and trimmed[0] == '[' and trimmed[1] == '[') {
        is_array = true;
        start_index = 2;
    }

    if (trimmed.len < start_index + 1) return null;
    if (trimmed[trimmed.len - 1] != ']') return null;
    if (is_array and (trimmed.len < 4 or trimmed[trimmed.len - 2] != ']')) return null;
    end_index = if (is_array) trimmed.len - 2 else trimmed.len - 1;

    const inside = std.mem.trim(u8, trimmed[start_index..end_index], " \t");
    if (inside.len == 0) return null;

    if (character != 0) {
        const rel = if (character > start_index) character - start_index else 0;
        return extractKeyPathAt(allocator, inside, rel);
    }

    return splitDottedPath(allocator, inside);
}

fn inlineTableKeyPathAt(allocator: std.mem.Allocator, line_text: []const u8, character: usize) ?[][]const u8 {
    const eq_index = std.mem.indexOfScalar(u8, line_text, '=') orelse return null;
    const value_part = line_text[eq_index + 1 ..];
    const brace_open_rel = std.mem.indexOfScalar(u8, value_part, '{') orelse return null;
    const brace_close_rel = std.mem.lastIndexOfScalar(u8, value_part, '}') orelse return null;
    if (brace_close_rel <= brace_open_rel) return null;

    const brace_open = eq_index + 1 + brace_open_rel;
    const brace_close = eq_index + 1 + brace_close_rel;
    if (character < brace_open + 1 or character > brace_close) return null;

    const inside = value_part[brace_open_rel + 1 .. brace_close_rel];
    const rel_char = character - (brace_open + 1);

    return inlineKeyPathInTable(allocator, inside, rel_char);
}

fn inlineKeyPathInTable(allocator: std.mem.Allocator, inside: []const u8, rel_char: usize) ?[][]const u8 {
    var depth: usize = 0;
    var seg_start: usize = 0;
    var idx: usize = 0;
    while (idx <= inside.len) : (idx += 1) {
        const at_end = idx == inside.len;
        const ch = if (at_end) ',' else inside[idx];

        if (!at_end) {
            if (ch == '{') depth += 1;
            if (ch == '}') {
                if (depth > 0) depth -= 1;
            }
        }

        if (at_end or (ch == ',' and depth == 0)) {
            const seg_raw = inside[seg_start..idx];
            const seg = std.mem.trim(u8, seg_raw, " \t");
            if (seg.len > 0 and rel_char >= seg_start and rel_char <= idx) {
                var lead: usize = 0;
                while (lead < seg_raw.len and (seg_raw[lead] == ' ' or seg_raw[lead] == '\t')) : (lead += 1) {}
                const rel_trim = if (rel_char < seg_start + lead) 0 else rel_char - seg_start - lead;
                return inlineKeyPathInSegment(allocator, seg, rel_trim);
            }
            seg_start = idx + 1;
        }
    }
    return null;
}

fn inlineKeyPathInSegment(allocator: std.mem.Allocator, seg: []const u8, rel_char: usize) ?[][]const u8 {
    const eq_index = std.mem.indexOfScalar(u8, seg, '=') orelse return null;
    const key_part = std.mem.trim(u8, seg[0..eq_index], " \t");
    const value_part = std.mem.trim(u8, seg[eq_index + 1 ..], " \t");

    if (rel_char <= eq_index) {
        return splitDottedPath(allocator, key_part);
    }

    if (std.mem.indexOfScalar(u8, value_part, '{')) |open_rel| {
        if (std.mem.lastIndexOfScalar(u8, value_part, '}')) |close_rel| {
            if (close_rel > open_rel) {
                const value_start = eq_index + 1;
                const brace_open = value_start + open_rel;
                const brace_close = value_start + close_rel;
                if (rel_char >= brace_open + 1 and rel_char <= brace_close) {
                    const inner = value_part[open_rel + 1 .. close_rel];
                    const inner_rel = rel_char - (brace_open + 1);
                    if (inlineKeyPathInTable(allocator, inner, inner_rel)) |inner_path| {
                        const outer = splitDottedPath(allocator, key_part) orelse {
                            allocator.free(inner_path);
                            return null;
                        };
                        defer allocator.free(outer);
                        const combined = joinPaths(allocator, outer, inner_path) orelse {
                            allocator.free(inner_path);
                            return null;
                        };
                        allocator.free(inner_path);
                        return combined;
                    }
                }
            }
        }
    }

    return splitDottedPath(allocator, key_part);
}

fn splitDottedPath(allocator: std.mem.Allocator, text: []const u8) ?[][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |part_raw| {
        var part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) return null;
        if (part.len >= 2) {
            if ((part[0] == '"' and part[part.len - 1] == '"') or (part[0] == '\'' and part[part.len - 1] == '\'')) {
                const unquoted = part[1 .. part.len - 1];
                if (unquoted.len == 0) return null;
                parts.append(allocator, unquoted) catch return null;
                continue;
            }
        }

        var i: usize = 0;
        var saw_token = false;
        while (i < part.len) {
            if (part[i] == '[') {
                var end_idx = i + 1;
                while (end_idx < part.len and part[end_idx] != ']') : (end_idx += 1) {}
                if (end_idx >= part.len) return null;
                const inner = std.mem.trim(u8, part[i + 1 .. end_idx], " \t");
                if (inner.len == 0) return null;
                parts.append(allocator, inner) catch return null;
                saw_token = true;
                i = end_idx + 1;
                continue;
            }

            const start = i;
            while (i < part.len and part[i] != '[') : (i += 1) {}
            const token = std.mem.trim(u8, part[start..i], " \t");
            if (token.len != 0) {
                parts.append(allocator, token) catch return null;
                saw_token = true;
            }
        }

        if (!saw_token) return null;
    }
    return parts.toOwnedSlice(allocator) catch null;
}

fn isCommentOrEmpty(line_text: []const u8) bool {
    const trimmed = std.mem.trim(u8, line_text, " \t");
    return trimmed.len == 0 or trimmed[0] == '#';
}

fn joinPaths(allocator: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ?[][]const u8 {
    const out = allocator.alloc([]const u8, a.len + b.len) catch return null;
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

fn extractKeyPathAt(allocator: std.mem.Allocator, line_text: []const u8, character: usize) ?[][]const u8 {
    const eq_index = std.mem.indexOfScalar(u8, line_text, '=') orelse return null;
    const key_part = line_text[0..eq_index];

    var parts: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var segment_index: ?usize = null;

    while (i < key_part.len) {
        while (i < key_part.len and (key_part[i] == ' ' or key_part[i] == '\t')) : (i += 1) {}
        if (i >= key_part.len) break;

        const seg_start = i;
        var seg_end = i;
        if (key_part[i] == '"' or key_part[i] == '\'') {
            const quote = key_part[i];
            i += 1;
            while (i < key_part.len and key_part[i] != quote) : (i += 1) {}
            seg_end = i + 1;
            i = seg_end;
        } else {
            while (i < key_part.len and key_part[i] != '.' and key_part[i] != ' ' and key_part[i] != '\t') : (i += 1) {}
            seg_end = i;
        }

        var seg_text = std.mem.trim(u8, key_part[seg_start..seg_end], " \t");
        if (seg_text.len >= 2) {
            if ((seg_text[0] == '"' and seg_text[seg_text.len - 1] == '"') or (seg_text[0] == '\'' and seg_text[seg_text.len - 1] == '\'')) {
                seg_text = seg_text[1 .. seg_text.len - 1];
            }
        }

        if (seg_text.len != 0) {
            parts.append(allocator, seg_text) catch return null;
            if (segment_index == null and character <= eq_index and character >= seg_start and character <= seg_end) {
                segment_index = parts.items.len - 1;
            }
        }

        while (i < key_part.len and (key_part[i] == ' ' or key_part[i] == '\t')) : (i += 1) {}
        if (i < key_part.len and key_part[i] == '.') i += 1;
    }

    const slice = parts.toOwnedSlice(allocator) catch return null;
    if (segment_index) |idx| {
        const prefix = allocator.alloc([]const u8, idx + 1) catch {
            allocator.free(slice);
            return null;
        };
        @memcpy(prefix, slice[0 .. idx + 1]);
        allocator.free(slice);
        return prefix;
    }
    return slice;
}

fn parseIndexSegment(seg: []const u8) ?usize {
    if (seg.len == 0) return null;
    for (seg) |ch| {
        if (ch < '0' or ch > '9') return null;
    }
    return std.fmt.parseInt(usize, seg, 10) catch null;
}

fn lookupTomlValue(root: toml.Table, key_path: []const []const u8) ?toml.Value {
    var table = root;
    var idx: usize = 0;
    while (idx < key_path.len) : (idx += 1) {
        const key = key_path[idx];
        const value = table.get(key) orelse return null;
        if (idx == key_path.len - 1) return value;
        switch (value) {
            .table => |t| table = t.*,
            .array => |ar| {
                if (idx + 1 < key_path.len) {
                    if (parseIndexSegment(key_path[idx + 1])) |array_index| {
                        if (array_index >= ar.items.len) return null;
                        const item = ar.items[array_index];
                        if (idx + 1 == key_path.len - 1) return item;
                        switch (item) {
                            .table => |t| {
                                table = t.*;
                                idx += 1;
                                continue;
                            },
                            else => return null,
                        }
                    }
                }
                if (tableFromArray(ar)) |t| {
                    table = t;
                } else return null;
            },
            else => return null,
        }
    }
    return null;
}

const ArrayContext = struct {
    name: []const u8,
    index: usize,
};

fn lookupTomlValueWithContext(root: toml.Table, key_path: []const []const u8, ctx: ?ArrayContext) ?toml.Value {
    var table = root;
    var idx: usize = 0;
    while (idx < key_path.len) : (idx += 1) {
        const key = key_path[idx];
        const value = table.get(key) orelse return null;
        if (idx == key_path.len - 1) return value;
        switch (value) {
            .table => |t| table = t.*,
            .array => |ar| {
                if (idx + 1 < key_path.len) {
                    if (parseIndexSegment(key_path[idx + 1])) |array_index| {
                        if (array_index >= ar.items.len) return null;
                        const item = ar.items[array_index];
                        if (idx + 1 == key_path.len - 1) return item;
                        switch (item) {
                            .table => |t| {
                                table = t.*;
                                idx += 1;
                                continue;
                            },
                            else => return null,
                        }
                    }
                }
                if (ctx) |c| {
                    if (std.mem.eql(u8, c.name, key) and c.index < ar.items.len) {
                        const item = ar.items[c.index];
                        switch (item) {
                            .table => |t| {
                                table = t.*;
                                continue;
                            },
                            else => return null,
                        }
                    }
                }
                if (tableFromArray(ar)) |t| {
                    table = t;
                } else return null;
            },
            else => return null,
        }
    }
    return null;
}

const ArrayElementTarget = struct {
    path: []const []const u8,
    index: usize,
};

fn arrayElementTarget(path: []const []const u8) ?ArrayElementTarget {
    if (path.len == 0) return null;
    const index = parseIndexSegment(path[path.len - 1]) orelse return null;
    return .{ .path = path[0 .. path.len - 1], .index = index };
}

fn tableFromArray(ar: *toml.ValueList) ?toml.Table {
    if (ar.items.len == 0) return null;
    var idx: usize = ar.items.len;
    while (idx > 0) {
        idx -= 1;
        switch (ar.items[idx]) {
            .table => |t| return t.*,
            else => {},
        }
    }
    return null;
}

fn tomlValueType(value: toml.Value) []const u8 {
    return switch (value) {
        .string => "string",
        .integer => "integer",
        .float => "float",
        .boolean => "boolean",
        .date => "date",
        .time => "time",
        .datetime => "datetime",
        .array => "array",
        .table => "table",
    };
}

fn tomlValueTypeExpanded(value: toml.Value, placeholders: []const jade.Placeholder) []const u8 {
    if (value == .string) {
        for (placeholders) |ph| {
            if (std.mem.eql(u8, ph.token, value.string) and isSpecialFloatLiteral(ph.original)) {
                return "float";
            }
        }
    }
    return tomlValueType(value);
}

fn formatTomlText(allocator: std.mem.Allocator, text: []const u8, format_settings: FormatSettings) ?[]u8 {
    if (format_settings.respect_trailing_commas) {
        return safeFormatTrailingCommaArrays(allocator, text) catch null;
    }

    const ml_mask = maskMultilineStrings(allocator, text) catch return null;
    defer allocator.free(ml_mask.masked);
    defer {
        for (ml_mask.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(ml_mask.placeholders);
    }

    const mask = jade.maskJinjaForFormat(allocator, ml_mask.masked) catch return null;
    defer allocator.free(mask.masked);
    defer {
        for (mask.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(mask.placeholders);
    }

    const float_mask = maskSpecialFloats(allocator, mask.masked) catch return null;
    defer allocator.free(float_mask.masked);
    defer {
        for (float_mask.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(float_mask.placeholders);
    }

    const unicode_masked = normalizeUnicodeEscapes(allocator, float_mask.masked) catch return null;
    defer allocator.free(unicode_masked);

    const combined_placeholders = mergePlaceholders(allocator, mask.placeholders, float_mask.placeholders) catch return null;
    const combined_placeholders2 = mergePlaceholders(allocator, combined_placeholders, ml_mask.placeholders) catch return null;
    defer allocator.free(combined_placeholders);
    defer allocator.free(combined_placeholders2);

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();

    const parsed = parser.parseString(unicode_masked) catch return null;
    defer parsed.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    toml.serialize(allocator, parsed.value, &aw.writer) catch {
        aw.deinit();
        return null;
    };
    const formatted = aw.toOwnedSlice() catch null;
    if (formatted == null) return null;
    var current = formatted.?;

    for (combined_placeholders2) |ph| {
        if (isSpecialFloatLiteral(ph.original)) {
            const quoted = std.fmt.allocPrint(allocator, "\"{s}\"", .{ph.token}) catch {
                allocator.free(current);
                return null;
            };
            defer allocator.free(quoted);
            const replaced_quoted = jade.replaceAll(allocator, current, quoted, ph.original) catch {
                allocator.free(current);
                return null;
            };
            allocator.free(current);
            current = replaced_quoted;
        }

        const needle = std.fmt.allocPrint(allocator, "{s}", .{ph.token}) catch {
            allocator.free(current);
            return null;
        };
        defer allocator.free(needle);
        const replaced = jade.replaceAll(allocator, current, needle, ph.original) catch {
            allocator.free(current);
            return null;
        };
        allocator.free(current);
        current = replaced;
    }

    return current;
}

fn expectPathEq(path: [][]const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, path.len);
    for (expected, 0..) |exp, idx| {
        try std.testing.expectEqualStrings(exp, path[idx]);
    }
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (try runCli(allocator)) return;

    var read_buffer: [4096]u8 = undefined;
    var stdio = lsp.Transport.Stdio.init(&read_buffer, std.fs.File.stdin(), std.fs.File.stdout());

    var docs = jade.DocumentStore.init(allocator);
    defer docs.deinit();

    var server: Server = .{
        .allocator = allocator,
        .transport = &stdio.transport,
        .docs = &docs,
        .settings = .{},
    };

    try lsp.basic_server.run(allocator, &stdio.transport, &server, std.log.scoped(.jade_toml_lsp).err);
}

fn runCli(allocator: std.mem.Allocator) !bool {
    var arg_it: std.process.ArgIterator = try .initWithAllocator(allocator);
    defer arg_it.deinit();

    _ = arg_it.skip();
    const cmd = arg_it.next() orelse return false;
    if (!std.mem.eql(u8, cmd, "format")) return false;

    const path = arg_it.next() orelse return error.MissingPath;
    try formatTomlFile(allocator, path);
    return true;
}

fn formatTomlFile(allocator: std.mem.Allocator, path: []const u8) !void {
    const max_bytes = 16 * 1024 * 1024;
    const text = try std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
    defer allocator.free(text);

    const formatted = formatTomlText(allocator, text, .{}) orelse return error.FormatFailed;
    defer allocator.free(formatted);

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(formatted);
}

test "formatTomlText preserves template placeholders" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = "a = \"{{ params.value }}\"\n";
    const formatted = formatTomlText(allocator, input, .{}) orelse return error.TestFailed;
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "{{ params.value }}") != null);
}

test "formatTomlText preserves special float literals" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input =
        \\a = inf
        \\b = -nan
        \\
    ;
    const formatted = formatTomlText(allocator, input, .{}) orelse return error.TestFailed;
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "inf") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "-nan") != null);
}

test "formatTomlText handles unicode escapes" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = "name = \"Jos\\u00E9\"\n";
    const formatted = formatTomlText(allocator, input, .{}) orelse return error.TestFailed;
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "name") != null);
}

test "formatTomlText preserves multiline strings" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input =
        \\multiline_basic = """
        \\Roses are red
        \\Violets are blue"""
        \\
    ;
    const formatted = formatTomlText(allocator, input, .{}) orelse return error.TestFailed;
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "multiline_basic") != null);
}

test "maskMultilineStrings removes delimiters" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input =
        \\multiline_basic = """
        \\Roses are red
        \\Violets are blue"""
        \\
    ;
    const masked = try maskMultilineStrings(allocator, input);
    defer allocator.free(masked.masked);
    defer {
        for (masked.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(masked.placeholders);
    }

    try std.testing.expect(std.mem.indexOf(u8, masked.masked, "\"\"\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, masked.masked, "'''") == null);
}

test "tomlValueStringExpanded restores special float placeholders" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var root = toml.Table.init(allocator);
    defer root.deinit();

    const token = "__JADE_FLOAT_0__";
    const placeholder = jade.Placeholder{
        .token = token,
        .original = "inf",
    };
    const value = toml.Value{ .string = token };
    const rendered = tomlValueStringExpanded(allocator, value, &.{placeholder}, root) catch return error.TestFailed;
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("inf", rendered);
}

test "format respects trailing commas in arrays" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input =
        \\[server]
        \\ports = [8000, 8001,]
        \\
    ;
    const formatted = formatTomlText(allocator, input, .{ .respect_trailing_commas = true }) orelse
        return error.TestFailed;
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "ports = [\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "    8000,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "    8001,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "]") != null);
}

test "extractKeyPathAt picks prefix based on cursor position" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const line = "root.child.leaf = 1";
    const path = extractKeyPathAt(allocator, line, 8) orelse return error.TestFailed;
    defer allocator.free(path);

    try std.testing.expect(path.len >= 2);
    try std.testing.expectEqualStrings("root", path[0]);
}


test "resolveKeyPathAt handles inline tables" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = "root = { child = 1, other = 2 }\n";
    const pos = std.mem.indexOf(u8, text, "child") orelse return error.TestFailed;
    const path = resolveKeyPathAt(allocator, text, 0, pos) orelse return error.TestFailed;
    defer allocator.free(path);

    try expectPathEq(path, &.{ "root", "child" });
}

test "resolveKeyPathAt handles nested inline tables" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = "root = { child = { leaf = 3 } }\n";
    const pos = std.mem.indexOf(u8, text, "leaf") orelse return error.TestFailed;
    const path = resolveKeyPathAt(allocator, text, 0, pos) orelse return error.TestFailed;
    defer allocator.free(path);

    try expectPathEq(path, &.{ "root", "child", "leaf" });
}

test "resolveKeyPathAt handles arrays of tables" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = "[[servers]]\nname = \"a\"\n";
    const line_text = jade.lineSlice(text, 1) orelse return error.TestFailed;
    const pos = std.mem.indexOf(u8, line_text, "name") orelse return error.TestFailed;
    const path = resolveKeyPathAt(allocator, text, 1, pos) orelse return error.TestFailed;
    defer allocator.free(path);

    try expectPathEq(path, &.{ "servers", "name" });
}

test "resolveKeyPathAt handles multiline arrays" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = "values = [\n 1,\n 2,\n]\n";
    const path = resolveKeyPathAt(allocator, text, 1, 1) orelse return error.TestFailed;
    defer allocator.free(path);

    try expectPathEq(path, &.{ "values" });
}

test "lookupTomlValue resolves array-of-tables entries" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = "[[servers]]\nname = \"a\"\n[[servers]]\nname = \"b\"\n";
    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();
    const parsed = parser.parseString(text) catch return error.TestFailed;
    defer parsed.deinit();

    const path = [_][]const u8{ "servers", "name" };
    const value = lookupTomlValue(parsed.value, path[0..]) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("string", tomlValueType(value));
}

test "hover resolves actual type for inline table values" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = "root = { child = 42 }\n";
    const line_text = jade.lineSlice(text, 0) orelse return error.TestFailed;
    const pos = std.mem.indexOf(u8, line_text, "child") orelse return error.TestFailed;

    const masked = jade.maskJinjaForFormat(allocator, text) catch return error.TestFailed;
    defer allocator.free(masked.masked);
    defer {
        for (masked.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(masked.placeholders);
    }

    var server: Server = undefined;
    const info = server.resolveHoverInfo(allocator, masked.masked, text, 0, pos, &.{}, &.{}) orelse return error.TestFailed;
    defer allocator.free(info.value);
    defer allocator.free(info.key);
    defer allocator.free(info.table);
    try std.testing.expectEqualStrings("integer", info.ty);
}

test "hover marks templated values and resolves type" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = "title = \"{{ params.title }}\"\n";
    const line_text = jade.lineSlice(text, 0) orelse return error.TestFailed;
    const pos = std.mem.indexOf(u8, line_text, "{{") orelse return error.TestFailed;

    const span_mask = jade.maskJinja(allocator, text) catch return error.TestFailed;
    defer allocator.free(span_mask.masked);
    defer allocator.free(span_mask.spans);

    const masked = jade.maskJinjaForFormat(allocator, text) catch return error.TestFailed;
    defer allocator.free(masked.masked);
    defer {
        for (masked.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(masked.placeholders);
    }

    const in_template = jade.isMaskedPosition(span_mask.spans, text, 1, pos + 1);
    try std.testing.expect(in_template);

    var server: Server = undefined;
    const info = server.resolveHoverInfo(allocator, masked.masked, text, 0, pos, span_mask.spans, &.{}) orelse return error.TestFailed;
    defer allocator.free(info.value);
    defer allocator.free(info.key);
    defer allocator.free(info.table);
    try std.testing.expectEqualStrings("string", info.ty);
}

test "hover expands array values on key and shows array index on item" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        "[params]\n" ++
        "port = 9000\n" ++
        "[server]\n" ++
        "ports = [ 8000, 8001, \"{{ params.port }}\" ]\n";

    const span_mask = jade.maskJinja(allocator, text) catch return error.TestFailed;
    defer allocator.free(span_mask.masked);
    defer allocator.free(span_mask.spans);

    const masked = jade.maskJinjaForFormat(allocator, text) catch return error.TestFailed;
    defer allocator.free(masked.masked);
    defer {
        for (masked.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(masked.placeholders);
    }

    const line_text = jade.lineSlice(text, 3) orelse return error.TestFailed;
    const key_pos = std.mem.indexOf(u8, line_text, "ports") orelse return error.TestFailed;
    var server: Server = undefined;
    const key_hover = server.resolveHoverInfo(allocator, masked.masked, text, 3, key_pos, span_mask.spans, masked.placeholders) orelse return error.TestFailed;
    defer allocator.free(key_hover.value);
    defer allocator.free(key_hover.key);
    defer allocator.free(key_hover.table);
    try std.testing.expectEqualStrings("array", key_hover.ty);
    try std.testing.expect(std.mem.indexOf(u8, key_hover.value, "9000") != null);

    const item_pos = std.mem.indexOf(u8, line_text, "8001") orelse return error.TestFailed;
    const item_hover = server.resolveHoverInfo(allocator, masked.masked, text, 3, item_pos, span_mask.spans, masked.placeholders) orelse return error.TestFailed;
    defer allocator.free(item_hover.value);
    defer allocator.free(item_hover.key);
    defer allocator.free(item_hover.table);
    try std.testing.expect(std.mem.indexOf(u8, item_hover.key, "[") != null);
}

test "hover resolves inline table keys" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        "[params]\n" ++
        "retries = 2\n" ++
        "[[services]]\n" ++
        "config = { retries = \"{{ params.retries }}\", timeout = 30 }\n";

    const span_mask = jade.maskJinja(allocator, text) catch return error.TestFailed;
    defer allocator.free(span_mask.masked);
    defer allocator.free(span_mask.spans);

    const masked = jade.maskJinjaForFormat(allocator, text) catch return error.TestFailed;
    defer allocator.free(masked.masked);
    defer {
        for (masked.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(masked.placeholders);
    }

    const line_text = jade.lineSlice(text, 3) orelse return error.TestFailed;
    const pos = std.mem.indexOf(u8, line_text, "retries") orelse return error.TestFailed;
    var server: Server = undefined;
    const info = server.resolveHoverInfo(allocator, masked.masked, text, 3, pos, span_mask.spans, masked.placeholders) orelse return error.TestFailed;
    defer allocator.free(info.value);
    defer allocator.free(info.key);
    defer allocator.free(info.table);
    try std.testing.expectEqualStrings("string", info.ty);
    try std.testing.expect(std.mem.indexOf(u8, info.value, "2") != null);
}

test "collect references includes key and template usage" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        "title = \"{{ params.title }}\"\n" ++
        "[params]\n" ++
        "title = \"Example\"\n";

    const spans = jade.templateSpans(allocator, text) catch return error.TestFailed;
    defer allocator.free(spans);

    const path = splitDottedPath(allocator, "params.title") orelse return error.TestFailed;
    defer allocator.free(path);

    const key_ranges = collectKeyReferenceRanges(allocator, text, path) orelse return error.TestFailed;
    defer allocator.free(key_ranges);
    const tpl_ranges = collectTemplateReferenceRanges(allocator, text, spans, path) orelse return error.TestFailed;
    defer allocator.free(tpl_ranges);

    try std.testing.expect(key_ranges.len >= 1);
    try std.testing.expect(tpl_ranges.len >= 1);
}

test "lookupTomlValue resolves array index segments" {
    const allocator = std.testing.allocator;
    const text =
        \\[params]
        \\labels = ["alpha", "beta", "gamma"]
        \\
    ;
    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();
    const parsed = parser.parseString(text) catch return error.TestFailed;
    defer parsed.deinit();
    {
        const path = splitDottedPath(allocator, "params.labels.1") orelse return error.TestFailed;
        defer allocator.free(path);
        const value = lookupTomlValue(parsed.value, path) orelse return error.TestFailed;
        try std.testing.expectEqualStrings("beta", value.string);
    }
    {
        const path = splitDottedPath(allocator, "params.labels[2]") orelse return error.TestFailed;
        defer allocator.free(path);
        const value = lookupTomlValue(parsed.value, path) orelse return error.TestFailed;
        try std.testing.expectEqualStrings("gamma", value.string);
    }
}

test "definition finds inline table keys" {
    const allocator = std.testing.allocator;
    const text =
        \\[params]
        \\limits = { min = 1, max = 5 }
        \\[server]
        \\config = { min = "{{ params.limits.min }}" }
        \\
    ;
    const path = splitDottedPath(allocator, "params.limits.min") orelse return error.TestFailed;
    defer allocator.free(path);
    const range = findKeyDefinitionRange(allocator, text, path) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 1), range.start.line);
}

test "hover resolves template referencing same table values" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\[params]
        \\labels = ["alpha", "beta"]
        \\[server]
        \\aliases = ["{{ params.labels.0 }}", "edge"]
        \\self_alias = "{{ server.aliases.0 }}"
        \\
    ;

    const span_mask = jade.maskJinja(allocator, text) catch return error.TestFailed;
    defer allocator.free(span_mask.masked);
    defer allocator.free(span_mask.spans);

    const masked = jade.maskJinjaForFormat(allocator, text) catch return error.TestFailed;
    defer allocator.free(masked.masked);
    defer {
        for (masked.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(masked.placeholders);
    }

    var server: Server = undefined;
    const line_text = jade.lineSlice(text, 4) orelse return error.TestFailed;
    const pos = std.mem.indexOf(u8, line_text, "self_alias") orelse return error.TestFailed;
    const info = server.resolveHoverInfo(allocator, masked.masked, text, 4, pos, span_mask.spans, masked.placeholders) orelse
        return error.TestFailed;
    defer allocator.free(info.value);
    defer allocator.free(info.key);
    defer allocator.free(info.table);
    try std.testing.expect(std.mem.indexOf(u8, info.value, "alpha") != null);
}

test "hover survives template in header and key" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\["{{ params.section }}"]
        \\value = "ok"
        \\"{{ params.key }}" = "bad key"
        \\[server]
        \\host = "127.0.0.1"
        \\
    ;

    const span_mask = jade.maskJinja(allocator, text) catch return error.TestFailed;
    defer allocator.free(span_mask.masked);
    defer allocator.free(span_mask.spans);

    const masked = jade.maskJinjaForFormatLenient(allocator, text) catch return error.TestFailed;
    defer allocator.free(masked.masked);
    defer {
        for (masked.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(masked.placeholders);
    }

    var server: Server = undefined;
    const line_text = jade.lineSlice(text, 4) orelse return error.TestFailed;
    const pos = std.mem.indexOf(u8, line_text, "host") orelse return error.TestFailed;
    const info = server.resolveHoverInfo(allocator, masked.masked, text, 4, pos, span_mask.spans, masked.placeholders) orelse
        return error.TestFailed;
    defer allocator.free(info.value);
    defer allocator.free(info.key);
    defer allocator.free(info.table);
    try std.testing.expectEqualStrings("string", info.ty);
}

test "example file parses with hover mask" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = std.fs.cwd().readFileAlloc(allocator, "examples/jade_test.toml", 1024 * 1024) catch
        return error.TestFailed;
    defer allocator.free(text);

    const ml_mask = maskMultilineStrings(allocator, text) catch return error.TestFailed;
    defer allocator.free(ml_mask.masked);
    defer {
        for (ml_mask.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(ml_mask.placeholders);
    }

    const masked = jade.maskJinjaForFormatLenient(allocator, ml_mask.masked) catch return error.TestFailed;
    defer allocator.free(masked.masked);
    defer {
        for (masked.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(masked.placeholders);
    }

    const float_mask = maskSpecialFloats(allocator, masked.masked) catch return error.TestFailed;
    defer allocator.free(float_mask.masked);
    defer {
        for (float_mask.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(float_mask.placeholders);
    }

    const unicode_masked = normalizeUnicodeEscapes(allocator, float_mask.masked) catch return error.TestFailed;
    defer allocator.free(unicode_masked);

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();
    const parsed = parser.parseString(unicode_masked) catch return error.TestFailed;
    defer parsed.deinit();
}

test "example file masks multiline strings" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = std.fs.cwd().readFileAlloc(allocator, "examples/jade_test.toml", 1024 * 1024) catch
        return error.TestFailed;
    defer allocator.free(text);

    const ml_mask = try maskMultilineStrings(allocator, text);
    defer allocator.free(ml_mask.masked);
    defer {
        for (ml_mask.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(ml_mask.placeholders);
    }

    try std.testing.expect(std.mem.indexOf(u8, ml_mask.masked, "\"\"\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, ml_mask.masked, "'''") == null);
}

test "example file yields template spans" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = std.fs.cwd().readFileAlloc(allocator, "examples/jade_test.toml", 1024 * 1024) catch
        return error.TestFailed;
    defer allocator.free(text);

    const spans = jade.templateSpans(allocator, text) catch return error.TestFailed;
    defer allocator.free(spans);
    try std.testing.expect(spans.len > 0);
}

test "example file detects template header span" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = std.fs.cwd().readFileAlloc(allocator, "examples/jade_test.toml", 1024 * 1024) catch
        return error.TestFailed;
    defer allocator.free(text);

    const spans = jade.templateSpans(allocator, text) catch return error.TestFailed;
    defer allocator.free(spans);

    var found = false;
    for (spans) |span| {
        if (templateSpanInTableHeader(text, span)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "diagnostic detects template cycles" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\[params]
        \\a = "{{ params.b }}"
        \\b = "{{ params.a }}"
        \\
    ;

    const mask = jade.maskJinjaForFormat(allocator, text) catch return error.TestFailed;
    defer allocator.free(mask.masked);
    defer {
        for (mask.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(mask.placeholders);
    }

    const spans = jade.templateSpans(allocator, text) catch return error.TestFailed;
    defer allocator.free(spans);

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();
    const parsed = parser.parseString(mask.masked) catch return error.TestFailed;
    defer parsed.deinit();

    var messages: std.ArrayList([]u8) = .empty;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }

    var found = false;
    for (spans) |span| {
        if (templateCycleDiagnostic(allocator, text, span, parsed.value, mask.placeholders, .warn, &messages)) |_| {
            found = true;
            break;
        }
    }

    try std.testing.expect(found);
}

test "diagnostics ignore templates inside comments" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\# {{ params.missing }}
        \\# another {{ params.other }}
        \\
    ;
    const spans = jade.templateSpans(allocator, text) catch return error.TestFailed;
    defer allocator.free(spans);

    try std.testing.expect(spanInLineComment(text, spans[0]));
}

test "comment detection ignores hash inside strings" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\value = "# not a comment"
        \\# {{ params.missing }}
        \\
    ;
    const spans = jade.templateSpans(allocator, text) catch return error.TestFailed;
    defer allocator.free(spans);
    try std.testing.expect(spanInLineComment(text, spans[0]));
}

test "comment detection handles multiline strings" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\value = """
        \\# not a comment inside multiline
        \\still in string
        \\"""
        \\# {{ params.missing }}
        \\
    ;
    const spans = jade.templateSpans(allocator, text) catch return error.TestFailed;
    defer allocator.free(spans);
    try std.testing.expect(spanInLineComment(text, spans[0]));
}

test "comment detection handles full-line comments with leading whitespace" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\    # {{ params.missing }}
        \\value = "ok"
        \\
    ;
    const spans = jade.templateSpans(allocator, text) catch return error.TestFailed;
    defer allocator.free(spans);
    try std.testing.expect(spanInLineComment(text, spans[0]));
}

test "comment detection ignores quotes inside comment lines" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\# comment "{{ params.missing }}"
        \\value = "ok"
        \\
    ;
    const spans = jade.templateSpans(allocator, text) catch return error.TestFailed;
    defer allocator.free(spans);
    try std.testing.expect(spanInLineComment(text, spans[0]));
}

test "diagnostic detects template in keys" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\"{{ params.key }}" = "value"
        \\
    ;
    const spans = jade.templateSpans(allocator, text) catch return error.TestFailed;
    defer allocator.free(spans);

    try std.testing.expect(templateSpanInAssignmentKey(text, spans[0]));

    var messages: std.ArrayList([]u8) = .empty;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }

    const diag = templateKeyDiagnostic(allocator, text, spans[0], .err, &messages);
    try std.testing.expect(diag != null);
}

test "diagnostic detects template in table headers" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\["{{ params.section }}"]
        \\
    ;
    const spans = jade.templateSpans(allocator, text) catch return error.TestFailed;
    defer allocator.free(spans);

    try std.testing.expect(templateSpanInTableHeader(text, spans[0]));

    var messages: std.ArrayList([]u8) = .empty;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }

    const diag = templateHeaderDiagnostic(allocator, text, spans[0], .err, &messages);
    try std.testing.expect(diag != null);
}

test "diagnostic detects template in inline table keys" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\meta = { "{{ params.key }}" = 1 }
        \\
    ;
    const spans = jade.templateSpans(allocator, text) catch return error.TestFailed;
    defer allocator.free(spans);

    try std.testing.expect(templateSpanInInlineTableKey(allocator, text, spans[0]));

    var messages: std.ArrayList([]u8) = .empty;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }

    const diag = templateInlineKeyDiagnostic(allocator, text, spans[0], .err, &messages);
    try std.testing.expect(diag != null);
}

test "diagnostic detects control chars in comments" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = "a = 1 #\x01\n";

    var messages: std.ArrayList([]u8) = .empty;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }

    const diags = collectCommentControlCharDiagnostics(allocator, text, .err, &messages) orelse return error.TestFailed;
    defer allocator.free(diags);
    try std.testing.expect(diags.len >= 1);
}

test "diagnostic detects duplicate keys" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\name = "a"
        \\name = "b"
        \\
    ;

    var messages: std.ArrayList([]u8) = .empty;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }

    const diags = collectKeyConflictDiagnostics(allocator, text, .err, &messages) orelse return error.TestFailed;
    defer allocator.free(diags);
    try std.testing.expect(diags.len >= 1);
}

test "diagnostic detects table array conflicts" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\[fruit]
        \\[[fruit]]
        \\
    ;

    var messages: std.ArrayList([]u8) = .empty;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }

    const diags = collectKeyConflictDiagnostics(allocator, text, .err, &messages) orelse return error.TestFailed;
    defer allocator.free(diags);
    try std.testing.expect(diags.len >= 1);
}

test "array-of-tables allow duplicate keys per element" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\[[services]]
        \\name = "web"
        \\config = { timeout = 30 }
        \\[[services]]
        \\name = "worker"
        \\config = { timeout = 60 }
        \\
    ;

    var messages: std.ArrayList([]u8) = .empty;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }

    const diags = collectKeyConflictDiagnostics(allocator, text, .err, &messages) orelse return error.TestFailed;
    defer allocator.free(diags);
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "diagnostic detects inline table trailing comma" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\point = { x = 1, y = 2, }
        \\
    ;

    var messages: std.ArrayList([]u8) = .empty;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }

    const diags = collectInlineTableDiagnostics(allocator, text, .err, &messages) orelse return error.TestFailed;
    defer allocator.free(diags);
    try std.testing.expect(diags.len >= 1);
}

test "diagnostic detects array-of-tables ordering" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        \\[fruit.physical]
        \\color = "red"
        \\[[fruit]]
        \\name = "apple"
        \\
    ;

    var messages: std.ArrayList([]u8) = .empty;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }

    const diags = collectArrayTableOrderingDiagnostics(allocator, text, .err, &messages) orelse return error.TestFailed;
    defer allocator.free(diags);
    try std.testing.expect(diags.len >= 1);
}

test "parse error message mapping uses friendly text" {
    try std.testing.expect(std.mem.indexOf(u8, parseErrorMessage(error.UnexpectedToken), "Unexpected") != null);
    try std.testing.expect(std.mem.indexOf(u8, parseErrorMessage(error.InvalidCharacter), "Invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, parseErrorMessage(error.InvalidMonth), "Invalid") != null);
}

test "parser errors surface invalid values" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = "a =\n";
    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();
    const parsed = parser.parseString(text) catch return;
    defer parsed.deinit();
    try std.testing.expect(false);
}

test "formatting disabled returns null" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var store = jade.DocumentStore.init(allocator);
    defer store.deinit();

    var server = Server{
        .allocator = allocator,
        .transport = undefined,
        .docs = &store,
        .settings = .{ .format = .{ .enabled = false } },
    };

    const text = "b = 2\na = 1\n";
    try store.set("file:///test.toml", text);

    const params: lsp.ParamsType("textDocument/formatting") = .{
        .textDocument = .{ .uri = "file:///test.toml" },
        .options = .{
            .tabSize = 4,
            .insertSpaces = true,
        },
    };

    const result = server.@"textDocument/formatting"(allocator, params);
    try std.testing.expect(result == null);
}

test "array-of-tables hover resolves correct item per header" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        "[[services]]\n" ++
        "name = \"web\"\n" ++
        "[[services]]\n" ++
        "name = \"worker\"\n";

    const span_mask = jade.maskJinja(allocator, text) catch return error.TestFailed;
    defer allocator.free(span_mask.masked);
    defer allocator.free(span_mask.spans);

    const masked = jade.maskJinjaForFormat(allocator, text) catch return error.TestFailed;
    defer allocator.free(masked.masked);
    defer {
        for (masked.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(masked.placeholders);
    }

    var server: Server = undefined;
    const line0 = jade.lineSlice(text, 1) orelse return error.TestFailed;
    const pos0 = std.mem.indexOf(u8, line0, "name") orelse return error.TestFailed;
    const hover0 = server.resolveHoverInfo(allocator, masked.masked, text, 1, pos0, span_mask.spans, masked.placeholders) orelse return error.TestFailed;
    defer allocator.free(hover0.value);
    defer allocator.free(hover0.key);
    defer allocator.free(hover0.table);
    try std.testing.expect(std.mem.indexOf(u8, hover0.value, "web") != null);

    const line1 = jade.lineSlice(text, 3) orelse return error.TestFailed;
    const pos1 = std.mem.indexOf(u8, line1, "name") orelse return error.TestFailed;
    const hover1 = server.resolveHoverInfo(allocator, masked.masked, text, 3, pos1, span_mask.spans, masked.placeholders) orelse return error.TestFailed;
    defer allocator.free(hover1.value);
    defer allocator.free(hover1.key);
    defer allocator.free(hover1.table);
    try std.testing.expect(std.mem.indexOf(u8, hover1.value, "worker") != null);
}

test "inlay hints show expanded template values" {
    const allocator = std.testing.allocator;
    const text =
        \\title = "{{ params.title }}"
        \\
        \\[params]
        \\title = "Example"
    ;

    const spans = try jade.templateSpans(allocator, text);
    defer allocator.free(spans);
    try std.testing.expect(spans.len > 0);

    const ml_mask = try maskMultilineStrings(allocator, text);
    defer allocator.free(ml_mask.masked);
    defer {
        for (ml_mask.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(ml_mask.placeholders);
    }

    const masked_lenient = try jade.maskJinjaForFormatLenient(allocator, ml_mask.masked);
    defer allocator.free(masked_lenient.masked);
    defer {
        for (masked_lenient.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(masked_lenient.placeholders);
    }

    const float_mask = try maskSpecialFloats(allocator, masked_lenient.masked);
    defer allocator.free(float_mask.masked);
    defer {
        for (float_mask.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(float_mask.placeholders);
    }

    const unicode_masked = try normalizeUnicodeEscapes(allocator, float_mask.masked);
    defer allocator.free(unicode_masked);

    const combined_placeholders = try mergePlaceholders(allocator, masked_lenient.placeholders, float_mask.placeholders);
    const combined_placeholders2 = try mergePlaceholders(allocator, combined_placeholders, ml_mask.placeholders);
    defer allocator.free(combined_placeholders);
    defer allocator.free(combined_placeholders2);

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();
    const parsed = try parser.parseString(unicode_masked);
    defer parsed.deinit();

    const path = extractTemplatePath(allocator, text, spans[0]) orelse return error.TestFailed;
    defer allocator.free(path);

    const value = lookupTomlValue(parsed.value, path) orelse return error.TestFailed;
    const display = inlayValueText(allocator, value, combined_placeholders2, parsed.value) orelse return error.TestFailed;
    defer allocator.free(display);

    try std.testing.expectEqualStrings("Example", display);
}

test "table header parses with CRLF" {
    const allocator = std.testing.allocator;
    const line = "[a]\r";
    const path = parseTableHeaderPath(allocator, line) orelse return error.TestFailed;
    defer allocator.free(path);
    try std.testing.expectEqual(@as(usize, 1), path.len);
    try std.testing.expectEqualStrings("a", path[0]);
}
