const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap");
const common = @import("common.zig");

const mkdtemp = common.mkdtemp;
const extract_file = common.extract_file;

const debug = std.debug;

const io = std.io;

const skopeo_content = @embedFile("skopeo");
const umoci_content = @embedFile("umoci");

const policy_content = @embedFile("tools/policy.json");

fn get_runtime_content_len_u64(runtime_content: []const u8) [8]u8 {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, runtime_content.len, .big);
    return buf;
}

const runtime_content_x86_64 = @embedFile("runtime_x86_64");
const runtime_content_aarch64 = @embedFile("runtime_aarch64");

const runtime_content_len_u64_x86_64 = get_runtime_content_len_u64(runtime_content_x86_64);
const runtime_content_len_u64_aarch64 = get_runtime_content_len_u64(runtime_content_aarch64);

extern fn mksquashfs_main(argc: c_int, argv: [*:null]const ?[*:0]const u8) void;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var temp_dir_path = "/tmp/dockerc-XXXXXX".*;
    try mkdtemp(&temp_dir_path);

    const allocator = gpa.allocator();
    const skopeo_path = try extract_file(&temp_dir_path, "skopeo", skopeo_content, allocator);
    defer allocator.free(skopeo_path);

    const umoci_path = try extract_file(&temp_dir_path, "umoci", umoci_content, allocator);
    defer allocator.free(umoci_path);

    const policy_path = try extract_file(&temp_dir_path, "policy.json", policy_content, allocator);
    defer allocator.free(policy_path);

    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Display this help and exit.
        \\-i, --image <str>        Image to pull.
        \\-o, --output <str>       Output file.
        \\--arch <str>             Architecture (amd64, arm64).
        \\--rootfull               Do not use rootless container.
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        // Report useful error and exit
        diag.report(io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.help(io.getStdErr().writer(), clap.Help, &params, .{});
        return;
    }

    var missing_args = false;
    if (res.args.image == null) {
        debug.print("no --image specified\n", .{});
        missing_args = true;
    }

    if (res.args.output == null) {
        debug.print("no --output specified\n", .{});
        missing_args = true;
    }

    if (missing_args) {
        debug.print("--help for usage\n", .{});
        return;
    }

    // safe to assert because checked above
    const image = res.args.image.?;
    const output_path = try allocator.dupeZ(u8, res.args.output.?);
    defer allocator.free(output_path);

    const destination_arg = try std.fmt.allocPrint(allocator, "oci:{s}/image:latest", .{temp_dir_path});
    defer allocator.free(destination_arg);

    var skopeo_args = std.ArrayList([]const u8).init(allocator);
    defer skopeo_args.deinit();

    try skopeo_args.appendSlice(&[_][]const u8{
        skopeo_path,
        "copy",
        "--policy",
        policy_path,
    });

    var runtime_content: []const u8 = undefined;
    var runtime_content_len_u64: [8]u8 = undefined;

    if (res.args.arch) |arch| {
        try skopeo_args.append("--override-arch");
        try skopeo_args.append(arch);

        if (std.mem.eql(u8, arch, "amd64")) {
            runtime_content = runtime_content_x86_64;
            runtime_content_len_u64 = runtime_content_len_u64_x86_64;
        } else if (std.mem.eql(u8, arch, "arm64")) {
            runtime_content = runtime_content_aarch64;
            runtime_content_len_u64 = runtime_content_len_u64_aarch64;
        } else {
            std.debug.panic("unsupported arch: {s}\n", .{arch});
        }
    } else {
        switch (builtin.target.cpu.arch) {
            .x86_64 => {
                runtime_content = runtime_content_x86_64;
                runtime_content_len_u64 = runtime_content_len_u64_x86_64;
            },
            .aarch64 => {
                runtime_content = runtime_content_aarch64;
                runtime_content_len_u64 = runtime_content_len_u64_aarch64;
            },
            else => {
                std.debug.panic("unsupported arch: {}", .{builtin.target.cpu.arch});
            },
        }
    }

    try skopeo_args.append(image);
    try skopeo_args.append(destination_arg);

    var skopeoProcess = std.process.Child.init(skopeo_args.items, gpa.allocator());
    _ = try skopeoProcess.spawnAndWait();

    const umoci_image_layout_path = try std.fmt.allocPrint(allocator, "{s}/image:latest", .{temp_dir_path});
    defer allocator.free(umoci_image_layout_path);

    const bundle_destination = try std.fmt.allocPrintZ(allocator, "{s}/bundle", .{temp_dir_path});
    defer allocator.free(bundle_destination);

    const umoci_args = [_][]const u8{
        umoci_path,
        "unpack",
        "--image",
        umoci_image_layout_path,
        bundle_destination,
        "--rootless",
    };
    var umociProcess = std.process.Child.init(if (res.args.rootfull == 0) &umoci_args else umoci_args[0 .. umoci_args.len - 1], gpa.allocator());
    _ = try umociProcess.spawnAndWait();

    const offset_arg = try std.fmt.allocPrintZ(allocator, "{}", .{runtime_content.len});
    defer allocator.free(offset_arg);

    const mksquashfs_args = [_:null]?[*:0]const u8{
        "mksquashfs",
        bundle_destination,
        output_path,
        "-comp",
        "zstd",
        "-offset",
        offset_arg,
        "-noappend",
    };

    mksquashfs_main(
        mksquashfs_args.len,
        &mksquashfs_args,
    );

    const file = try std.fs.cwd().openFile(output_path, .{
        .mode = .write_only,
    });
    defer file.close();

    try file.writeAll(runtime_content);
    try file.seekFromEnd(0);
    try file.writeAll(&runtime_content_len_u64);
    try file.chmod(0o755);
}
