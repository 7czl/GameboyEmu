const std = @import("std");
const Bus = @import("bus.zig").Bus;

pub const Timer = struct {
    div_counter: u16 = 0,
    tima_counter: u16 = 0,
    // div: u8 = 0,
    tima: u8 = 0,
    tma: u8 = 0,
    tac: u8 = 0,
    pub fn init() Timer {
        return Timer{};
    }
    pub fn step(self: *Timer, bus: *Bus, cycles: u8) void {
        self.div_counter +%= @as(u16, cycles);
        // std.log.debug("TIMER: div_counter={d}, cycles={d}", .{ self.div_counter, cycles });

        if (self.tac & 0b100 != 0) {
            self.tima_counter +%= cycles;
            const freq_cycles: u16 = switch (self.tac & 0b11) {
                0b00 => 1024,
                0b01 => 16,
                0b10 => 64,
                0b11 => 256,
                else => unreachable,
            };
            // std.log.debug("TIMER: tima_counter={d}, tima={d}, tma={d}, tac={d}", .{ self.tima_counter, self.tima, self.tma, self.tac });
            while (self.tima_counter >= freq_cycles) {
                self.tima_counter -= freq_cycles;
                if (self.tima == 0xFF) {
                    self.tima = self.tma;
                    bus.request_interrupt(Bus.Interrupt.Timer);
                    std.log.debug("TIMER: Timer overflow, requesting Timer interrupt", .{});
                } else {
                    self.tima += 1;
                }
                std.log.debug("TIMER: Incremented tima to {d}", .{self.tima});
            }
        } else {
            // std.log.debug("TIMER: Timer not enabled, skipping step", .{});
        }
    }
};
