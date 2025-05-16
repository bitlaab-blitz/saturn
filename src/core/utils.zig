//! # Utility Module

const std = @import("std");
const log = std.log;
const linux = std.os.linux;
const Tag = std.Target.Os.Tag;
const SrcLoc = std.builtin.SourceLocation;

const builtin = @import("builtin");


/// # Verifies Intended OS For The Codebase
/// - `comptime` on `os_tag` avoids function body being semantically checked
/// - `@compileError()` doc has more info on this
pub fn targetPlatform(comptime tag: std.Target.Os.Tag) void {
    const target = builtin.os.tag;
    if (tag != target) @compileError("Unsupported OS for this codebase!");
}

/// # Logs Syscall Error Number
/// - e.g., `utils.syscallError(9, @src());`
pub fn syscallError(code: i32, src: SrcLoc) void {
    const err: linux.E = @enumFromInt(@as(u16, @truncate(@abs(code))));
    const fmt_str = "Syscall - Errno {d} E{s} occurred in {s} at line {d}";
    log.err(fmt_str, .{code, @tagName(err), src.file, src.line});
}

/// # Std SemanticVersion Alternative
/// - `std.SemanticVersion` requires there be no extra characters after the
/// major/minor/patch numbers. But when we try to parse `uname --kernel-release`
/// some distros have extra characters, such as Fedora: 6.3.8-100.fc37.x86_64,
/// and the WSL has more than three dots: 5.15.90.1-microsoft-standard-WSL2.
/// - Linux doesn't follow semantic versioning, but doesn't violate it either.
pub fn parseDirtySemver(dirty_release: []const u8) !std.SemanticVersion {
    const release = blk: {
        var last_valid_version_character_index: usize = 0;
        var dots_found: u8 = 0;
        for (dirty_release) |c| {
            if (c == '.') dots_found += 1;

            if (dots_found == 3) break;

            if (c == '.' or (c >= '0' and c <= '9')) {
                last_valid_version_character_index += 1;
                continue;
            }

            break;
        }

        break :blk dirty_release[0..last_valid_version_character_index];
    };

    return std.SemanticVersion.parse(release);
}

test parseDirtySemver {
    const SemverTestCase = struct {
        dirty_release: []const u8,
        expected_version: std.SemanticVersion,
    };

    const cases = &[_]SemverTestCase{
        .{
            .dirty_release = "1.2.3",
            .expected_version = std.SemanticVersion{ .major = 1, .minor = 2, .patch = 3 },
        },
        .{
            .dirty_release = "1001.843.909",
            .expected_version = std.SemanticVersion{ .major = 1001, .minor = 843, .patch = 909 },
        },
        .{
            .dirty_release = "6.3.8-100.fc37.x86_64",
            .expected_version = std.SemanticVersion{ .major = 6, .minor = 3, .patch = 8 },
        },
        .{
            .dirty_release = "5.15.90.1-microsoft-standard-WSL2",
            .expected_version = std.SemanticVersion{ .major = 5, .minor = 15, .patch = 90 },
        },
        .{
            .dirty_release = "6.8.0-39-generic",
            .expected_version = std.SemanticVersion{ .major = 6, .minor = 8, .patch = 0 },
        }
    };

    for (cases) |case| {
        const version = try parseDirtySemver(case.dirty_release);
        try std.testing.expectEqual(case.expected_version, version);
    }
}