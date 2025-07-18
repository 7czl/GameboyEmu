//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const posix = std.posix;
pub fn main() !void {
    var file = try std.fs.cwd().openFile("Baby's Day Out (USA) (Proto).gb", .{ .mode = .read_only });

    const file_size = try file.getEndPos();
    const fd = file.handle;
    defer file.close();
    const map_ptr = try std.posix.mmap(null, file_size, posix.PROT.READ, .{ .TYPE = .SHARED }, fd, 0);
    const rom_bytes = std.mem.sliceAsBytes(map_ptr);
    defer posix.munmap(rom_bytes);
    const title = rom_bytes[0x134..0x143];
    std.debug.print("title: {s}\n", .{title});

    std.debug.print("rom size: {d}\n", .{rom_bytes.len});
    return;
}
