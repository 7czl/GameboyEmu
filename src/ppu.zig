const Bus = @import("bus.zig").Bus;

pub const Ppu = struct {
    ly: u8 = 0,
    cycle_counter: u16 = 0,
    pub fn init() Ppu {
        return Ppu{};
    }
    pub fn step(self: *Ppu, bus: *Bus, cycles: u16) void {
        _ = bus;
        self.cycle_counter += cycles;
        if (self.cycle_counter >= 456) {
            self.cycle_counter -= 456;
            self.ly +%= 1;
            if (self.ly > 153) {
                self.ly = 0;
            }
        }
    }
};
