const std = @import("std");
const Romheader = @import("header.zig").RomHeader;
const Bus = @import("bus.zig").Bus;
const Cpu = @import("cpu.zig").CPU;

const posix = std.posix;

pub fn main() !void {
    std.log.info("Starting GameBoy emulator..", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const rom_path = if (args.len > 1) args[1] else "cpu_instrs.gb";
    std.log.info("Loading ROM from: {s}", .{rom_path});

    var file = try std.fs.cwd().openFile(rom_path, .{ .mode = .read_only });
    defer file.close();
    const file_size = try file.getEndPos();
    const fd = file.handle;

    const map_ptr = try std.posix.mmap(null, file_size, posix.PROT.READ, .{ .TYPE = .SHARED }, fd, 0);
    const rom_bytes = std.mem.sliceAsBytes(map_ptr);

    defer posix.munmap(rom_bytes);
    var bus = Bus.init(rom_bytes);
    var cpu = Cpu.init();
    std.log.info("--- start emulation loop ---", .{});
    while (true) {
        _ = cpu.step(&bus);
        if (cpu.pc == 0x005B) {
            std.log.debug("PC reached debug point. Halting", .{});
        }
    }

    // const header: *const Romheader = @ptrCast(&rom_bytes[0x100]);
    return;
}
