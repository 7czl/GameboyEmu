const std = @import("std");
const Bus = @import("bus.zig").Bus;

pub const Timer = struct {
    /// Full 16-bit internal counter. DIV register = upper 8 bits (div_counter >> 8).
    div_counter: u16 = 0,
    tima: u8 = 0,
    tma: u8 = 0,
    tac: u8 = 0,

    /// Tracks the previous AND result of (selected DIV bit & timer enable)
    /// for falling edge detection.
    prev_and_result: bool = false,

    /// TIMA overflow state machine (counts in T-cycles):
    /// 0 = normal
    /// 4 = TIMA just overflowed (cycle A, TIMA reads 0x00)
    /// Decrements each T-cycle. When it reaches 0, TMA→TIMA + interrupt.
    overflow_cycles: u8 = 0,

    /// Set when TIMA was written during cycle A (cancels reload entirely)
    overflow_cancelled: bool = false,

    /// True during the M-cycle when TMA was just loaded into TIMA.
    /// During this M-cycle:
    ///   - writes to TIMA are overwritten by TMA
    ///   - writes to TMA also update TIMA
    tima_just_reloaded: bool = false,

    pub fn init() Timer {
        return Timer{};
    }

    /// Tick the timer by one T-cycle.
    pub fn tick(self: *Timer, bus: *Bus) void {
        // Handle TIMA overflow delay
        if (self.overflow_cycles > 0) {
            self.overflow_cycles -= 1;
            if (self.overflow_cycles == 0) {
                if (!self.overflow_cancelled) {
                    self.tima = self.tma;
                    bus.request_interrupt(Bus.Interrupt.Timer);
                    self.tima_just_reloaded = true;
                }
                self.overflow_cancelled = false;
            }
        }

        // Increment the internal 16-bit counter
        self.div_counter +%= 1;

        // Check for falling edge on the selected bit ANDed with enable
        self.check_falling_edge();
    }

    fn selected_bit(self: *const Timer) u4 {
        return switch (self.tac & 0b11) {
            0b00 => 9,
            0b01 => 3,
            0b10 => 5,
            0b11 => 7,
            else => unreachable,
        };
    }

    fn current_and_result(self: *const Timer) bool {
        const timer_enabled = (self.tac & 0b100) != 0;
        const bit = self.selected_bit();
        const div_bit = (self.div_counter >> bit) & 1 != 0;
        return timer_enabled and div_bit;
    }

    fn check_falling_edge(self: *Timer) void {
        const current = self.current_and_result();
        if (self.prev_and_result and !current) {
            if (self.tima == 0xFF) {
                self.tima = 0x00;
                self.overflow_cycles = 4;
                self.overflow_cancelled = false;
            } else {
                self.tima += 1;
            }
        }
        self.prev_and_result = current;
    }

    pub fn write_div(self: *Timer) void {
        self.div_counter = 0;
        self.check_falling_edge();
    }

    pub fn write_tac(self: *Timer, value: u8) void {
        self.tac = value;
        self.check_falling_edge();
    }

    /// Write to TIMA (0xFF05).
    /// Cycle A (overflow pending): cancels reload and interrupt.
    /// Cycle B (just reloaded): write is overwritten by TMA at end of cycle.
    pub fn write_tima(self: *Timer, value: u8) void {
        if (self.overflow_cycles > 0) {
            self.overflow_cancelled = true;
            self.tima = value;
        } else if (self.tima_just_reloaded) {
            // During reload M-cycle, TIMA constantly copies from TMA.
            // CPU write goes through but is immediately overwritten.
            // Effectively: TIMA = TMA at end of this M-cycle.
        } else {
            self.tima = value;
        }
    }

    /// Write to TMA (0xFF06).
    /// During reload M-cycle, new TMA value is also copied to TIMA.
    pub fn write_tma(self: *Timer, value: u8) void {
        self.tma = value;
        if (self.tima_just_reloaded) {
            self.tima = value;
        }
    }

    /// Step by the given number of T-cycles (called per M-cycle from CPU).
    pub fn step(self: *Timer, bus: *Bus, cycles: u8) void {
        // Clear the reload flag at the start of each new M-cycle
        self.tima_just_reloaded = false;

        var i: u8 = 0;
        while (i < cycles) : (i += 1) {
            self.tick(bus);
        }
    }
};
