const std = @import("std");
const Romheader = @import("header.zig").RomHeader;
const Bus = @import("bus.zig").Bus;
const Cpu = @import("cpu.zig").CPU;
const Timer = @import("timer.zig").Timer;
const Ppu = @import("ppu.zig").Ppu;
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
    var ppu = Ppu.init();
    var timer = Timer.init();
    var bus = Bus.init(rom_bytes, &timer, &ppu);

    // debug
    var instruction_count: u64 = 0;
    // var last_pc: u16 = 0;
    // var same_pc_count: u32 = 0;
    // var pc_frequencies = std.HashMap(u16, u32, std.hash_map.AutoContext(u16), 80).init(allocator);
    // defer pc_frequencies.deinit();

    var cpu = Cpu.init();
    std.log.info("--- start emulation loop ---", .{});
    while (true) {
        // const current_pc = cpu.pc;
        instruction_count += 1;
        // const result = try pc_frequencies.getOrPut(current_pc);
        // if (!result.found_existing) {
        //     result.value_ptr.* = 0;
        // }
        // result.value_ptr.* += 1;

        // if (current_pc == last_pc) {
        //     same_pc_count += 1;
        //     if (same_pc_count > 5000) {
        //         std.log.err("=== STUCK IN SINGLE INSTRUCTION ===", .{});
        //         std.log.err("PC: 0x{X:0>4} executed {d} times in a row", .{ current_pc, same_pc_count });
        //         const opcode = bus.read(current_pc);
        //         std.log.err("Opcode: 0x{X:0>2}", .{opcode});
        //         break;
        //     }
        // } else {
        //     same_pc_count = 0;
        // }
        // if (instruction_count % 1000 == 0) {
        //     std.log.info("Instructions: {d}, PC: 0x{X:0>4}", .{ instruction_count, current_pc });

        //     // 找出最频繁执行的PC地址
        //     var max_frequency: u32 = 0;
        //     var most_frequent_pc: u16 = 0;
        //     var iterator = pc_frequencies.iterator();
        //     while (iterator.next()) |entry| {
        //         if (entry.value_ptr.* > max_frequency) {
        //             max_frequency = entry.value_ptr.*;
        //             most_frequent_pc = entry.key_ptr.*;
        //         }
        //     }

        //     if (max_frequency > 100) {
        //         std.log.warn("Hotspot detected: PC 0x{X:0>4} executed {d} times", .{ most_frequent_pc, max_frequency });
        //     }
        // }
        if (instruction_count > 1000000000) { // 1 billion
            // std.log.err("=== EXECUTION LIMIT REACHED ===", .{});
            // std.log.err("Total instructions: {d}", .{instruction_count});

            // // 打印最频繁的PC地址
            // std.log.err("Top hotspots:", .{});
            // var iterator = pc_frequencies.iterator();
            // var hotspots: [10]struct { pc: u16, count: u32 } = undefined;
            // var hotspot_count: usize = 0;

            // while (iterator.next()) |entry| {
            //     if (entry.value_ptr.* > 50 and hotspot_count < 10) {
            //         hotspots[hotspot_count] = .{ .pc = entry.key_ptr.*, .count = entry.value_ptr.* };
            //         hotspot_count += 1;
            //     }
            // }
            // for (0..hotspot_count) |i| {
            //     const opcode = bus.read(hotspots[i].pc);
            //     std.log.err("  PC 0x{X:0>4}: {d} times (opcode: 0x{X:0>2})", .{ hotspots[i].pc, hotspots[i].count, opcode });
            // }
            break;
        }

        const cycles = cpu.step(&bus);
        timer.step(&bus, @intCast(cycles));
        ppu.step(&bus, @intCast(cycles));
        // last_pc = current_pc;
    }

    return;
}
