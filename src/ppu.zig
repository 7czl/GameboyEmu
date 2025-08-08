const Bus = @import("bus.zig").Bus;
const std = @import("std");

pub const Ppu = struct {
    ly: u8 = 0,
    cycle_counter: u16 = 0,
    enabled: bool = false,

    pub fn init() Ppu {
        return Ppu{
            .ly = 0,
            .cycle_counter = 0,
            .enabled = false,
        };
    }

    pub fn reset(self: *Ppu) void {
        self.ly = 0;
        self.cycle_counter = 0;
        self.enabled = false;
    }

    pub fn step(self: *Ppu, bus: *Bus, cycles: u16) void {
        if (!self.enabled) {
            // std.log.debug("PPU: Not enabled.", .{});
            return;
        }

        self.cycle_counter +%= cycles;
        // std.log.debug("PPU: cycles={d}, current_cycle_counter={d}, ly={d}", .{ cycles, self.cycle_counter, self.ly });

        if (self.cycle_counter >= 456) {
            self.cycle_counter -= 456;
            self.ly = (self.ly + 1) % 154;
            // std.log.debug("PPU: LY incremented to {d}, cycle_counter reset to {d}", .{ self.ly, self.cycle_counter });
            if (self.ly == 144) {
                bus.request_interrupt(Bus.Interrupt.VBlank);
                // std.log.debug("PPU: VBlank interrupt requested (LY=144)", .{});
            }
        }
    }
};
