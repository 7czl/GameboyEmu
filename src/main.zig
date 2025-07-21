const std = @import("std");
const Romheader = @import("header.zig").RomHeader;
const posix = std.posix;

pub fn main() !void {
    // print_arg();
    args_check();
    const file_path = std.os.argv[1];
    var file = std.fs.cwd().openFile(std.mem.span(file_path), .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Rom file not found", .{});
            posix.exit(1);
        },
        else => {
            std.posix.exit(1);
        },
    };
    const file_size = try file.getEndPos();
    const fd = file.handle;
    defer file.close();
    const map_ptr = try std.posix.mmap(null, file_size, posix.PROT.READ, .{ .TYPE = .SHARED }, fd, 0);
    const rom_bytes = std.mem.sliceAsBytes(map_ptr);
    defer posix.munmap(rom_bytes);

    const header: *const Romheader = @ptrCast(&rom_bytes[0x100]);

    const cartridge_type = try header.getCartridgeType();
    std.debug.print("title:{s}\n", .{header.getTitle()});
    std.debug.print("rom size: {s}\n", .{header.getRomSize()});
    std.debug.print("type: {} (0x{x:0>2})\n", .{ cartridge_type, @intFromEnum(cartridge_type) });
    header.printRamSize();
    header.printDestination();

    return;
}

pub fn print_arg() void {
    for (std.os.argv, 0..) |arg, idx| {
        std.debug.print("arg{d}: {s}\n", .{ idx, arg });
    }
}

pub fn args_check() void {
    if (std.os.argv.len != 2) {
        std.debug.print("rom 参数必须由命令行的第一个参数传入\n", .{});
        std.posix.exit(1);
    }
}
