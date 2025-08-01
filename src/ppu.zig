const Bus = @import("bus.zig").Bus;

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
            return;
        }

        self.cycle_counter += cycles;
        if (self.cycle_counter >= 456) {
            self.cycle_counter -= 456;
            self.ly = (self.ly + 1) % 154;
            if (self.ly == 144) {
                bus.request_interrupt(Bus.Interrupt.VBlank);
            }
        }
    }
};
