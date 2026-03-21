const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const mode = b.option([]const u8, "mode", "Build mode: debug|release|safe|small (defaults to -Doptimize)") orelse "default";
    const platform = b.option([]const u8, "platform", "Target platform: native|windows|linux|macos") orelse "native";
    const arch_opt = b.option([]const u8, "arch", "Target arch: x86_64|aarch64 (defaults to host)");
    const release_matrix = b.option(bool, "release_matrix", "Build ReleaseFast binaries for windows/macos/linux (x86_64 + aarch64)") orelse false;

    const optimize: std.builtin.OptimizeMode = if (std.mem.eql(u8, mode, "default"))
        b.standardOptimizeOption(.{})
    else if (std.mem.eql(u8, mode, "debug"))
        .Debug
    else if (std.mem.eql(u8, mode, "release"))
        .ReleaseFast
    else if (std.mem.eql(u8, mode, "safe"))
        .ReleaseSafe
    else if (std.mem.eql(u8, mode, "small"))
        .ReleaseSmall
    else {
        std.debug.print("Unknown -Dmode='{s}'. Expected debug|release|safe|small.\n", .{mode});
        std.process.exit(1);
    };

    const target = if (std.mem.eql(u8, platform, "native"))
        b.standardTargetOptions(.{})
    else blk: {
        var query: std.Target.Query = .{};
        const arch = if (arch_opt) |arch_name|
            parseArch(arch_name) orelse {
                std.debug.print("Unknown -Darch='{s}'. Expected x86_64|aarch64.\n", .{arch_name});
                std.process.exit(1);
            }
        else
            builtin.cpu.arch;

        query.cpu_arch = arch;
        query.os_tag = parseOsTag(platform) orelse {
            std.debug.print("Unknown -Dplatform='{s}'. Expected native|windows|linux|macos.\n", .{platform});
            std.process.exit(1);
        };
        query.abi = builtin.abi;
        break :blk b.resolveTargetQuery(query);
    };
    const mod = b.addModule("jade_toml_lsp", .{
        .root_source_file = b.path("src/jade.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    const lsp_module = b.dependency("lsp_kit", .{}).module("lsp");
    const toml_module = b.dependency("toml", .{}).module("toml");

    const exe = b.addExecutable(.{
        .name = "jade_toml_lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "jade_toml_lsp", .module = mod },
                .{ .name = "lsp", .module = lsp_module },
                .{ .name = "toml", .module = toml_module },
            },
        }),
    });

    const exe_sub_path = b.fmt("{s}/{s}/{s}/{s}", .{
        osTagName(exe.rootModuleTarget().os.tag),
        archName(exe.rootModuleTarget().cpu.arch),
        optimizeName(optimize),
        exe.out_filename,
    });
    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .bin },
        .dest_sub_path = exe_sub_path,
    }).step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const matrix_step = addReleaseMatrix(b, mod, lsp_module, toml_module);
    const release_all = b.step("release-matrix", "Build ReleaseFast binaries for windows/macos/linux (x86_64 + aarch64)");
    release_all.dependOn(matrix_step);
    const release_alias = b.step("release-all", "Alias for release-matrix");
    release_alias.dependOn(matrix_step);
    if (release_matrix) {
        b.getInstallStep().dependOn(matrix_step);
    }
}

fn parseArch(name: []const u8) ?std.Target.Cpu.Arch {
    if (std.mem.eql(u8, name, "x86_64")) return .x86_64;
    if (std.mem.eql(u8, name, "aarch64")) return .aarch64;
    return null;
}

fn parseOsTag(name: []const u8) ?std.Target.Os.Tag {
    if (std.mem.eql(u8, name, "windows")) return .windows;
    if (std.mem.eql(u8, name, "linux")) return .linux;
    if (std.mem.eql(u8, name, "macos")) return .macos;
    return null;
}

fn osTagName(tag: std.Target.Os.Tag) []const u8 {
    return switch (tag) {
        .windows => "windows",
        .linux => "linux",
        .macos => "macos",
        else => "unknown",
    };
}

fn archName(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => "unknown",
    };
}

fn optimizeName(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "debug",
        .ReleaseFast => "release",
        .ReleaseSafe => "safe",
        .ReleaseSmall => "small",
    };
}

fn addReleaseMatrix(
    b: *std.Build,
    mod: *std.Build.Module,
    lsp_module: *std.Build.Module,
    toml_module: *std.Build.Module,
) *std.Build.Step {
    const matrix_step = b.step("release-matrix-internal", "internal");

    const targets = [_]struct { os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch }{
        .{ .os = .windows, .arch = .x86_64 },
        .{ .os = .windows, .arch = .aarch64 },
        .{ .os = .linux, .arch = .x86_64 },
        .{ .os = .linux, .arch = .aarch64 },
        .{ .os = .macos, .arch = .x86_64 },
        .{ .os = .macos, .arch = .aarch64 },
    };

    for (targets) |t| {
        const query: std.Target.Query = .{
            .cpu_arch = t.arch,
            .os_tag = t.os,
            .abi = builtin.abi,
        };
        const target = b.resolveTargetQuery(query);
        const exe = b.addExecutable(.{
            .name = "jade_toml_lsp",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "jade_toml_lsp", .module = mod },
                    .{ .name = "lsp", .module = lsp_module },
                    .{ .name = "toml", .module = toml_module },
                },
            }),
        });

        const sub_path = b.fmt("{s}/{s}/{s}/{s}", .{
            osTagName(t.os),
            archName(t.arch),
            optimizeName(.ReleaseFast),
            exe.out_filename,
        });

        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .bin },
            .dest_sub_path = sub_path,
        });
        matrix_step.dependOn(&install.step);
    }

    return matrix_step;
}
