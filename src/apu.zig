// APU (Audio Processing Unit) for DMG/CGB Game Boy
// 4 channels: CH1 (pulse+sweep), CH2 (pulse), CH3 (wave), CH4 (noise)
// Frame sequencer at 512 Hz clocks length, envelope, and sweep

const std = @import("std");

const SAMPLE_RATE: u32 = 44100;
const CPU_CLOCK: u32 = 4194304;
const DUTY_TABLE = [4][8]u8{
    .{ 0, 0, 0, 0, 0, 0, 0, 1 }, // 12.5%
    .{ 1, 0, 0, 0, 0, 0, 0, 1 }, // 25%
    .{ 1, 0, 0, 0, 0, 1, 1, 1 }, // 50%
    .{ 0, 1, 1, 1, 1, 1, 1, 0 }, // 75%
};

pub const Apu = struct {
    enabled: bool = true,
    nr50: u8 = 0x77,
    nr51: u8 = 0xF3,

    ch1: PulseChannel = .{},
    ch1_sweep_period: u8 = 0,
    ch1_sweep_negate: bool = false,
    ch1_sweep_shift: u8 = 0,
    ch1_sweep_timer: u8 = 0,
    ch1_sweep_enabled: bool = false,
    ch1_sweep_shadow: u16 = 0,
    ch1_sweep_negate_used: bool = false,

    ch2: PulseChannel = .{},

    ch3_enabled: bool = false,
    ch3_dac_enabled: bool = false,
    ch3_length_counter: u16 = 0,
    ch3_volume_code: u2 = 0,
    ch3_frequency: u16 = 0,
    ch3_length_enable: bool = false,
    ch3_timer: u16 = 0,
    ch3_position: u8 = 0,
    ch3_sample_buffer: u8 = 0,
    wave_ram: [16]u8 = .{0} ** 16,

    ch4_enabled: bool = false,
    ch4_dac_enabled: bool = false,
    ch4_length_counter: u8 = 0,
    ch4_volume: u8 = 0,
    ch4_volume_init: u8 = 0,
    ch4_envelope_add: bool = false,
    ch4_envelope_period: u8 = 0,
    ch4_envelope_timer: u8 = 0,
    ch4_length_enable: bool = false,
    ch4_clock_shift: u8 = 0,
    ch4_width_mode: bool = false,
    ch4_divisor_code: u8 = 0,
    ch4_timer: u32 = 0,
    ch4_lfsr: u16 = 0x7FFF,

    frame_seq_step: u8 = 0,
    prev_div_bit: bool = false,

    sample_timer: u32 = 0,
    sample_buffer: [4096]i16 = .{0} ** 4096,
    sample_count: u32 = 0,

    pub fn init() Apu {
        return Apu{};
    }

    pub fn step(self: *Apu, t_cycles: u32, div_counter: u16, double_speed: bool) void {
        // Frame sequencer: clocked by falling edge of DIV bit 4 (512 Hz)
        // In CGB double speed, DIV counter runs at 2x, so check bit 5 instead
        const div_bit = if (double_speed)
            (div_counter & 0x2000) != 0
        else
            (div_counter & 0x1000) != 0;
        if (self.prev_div_bit and !div_bit) {
            if (self.enabled) self.clock_frame_sequencer();
        }
        self.prev_div_bit = div_bit;

        var i: u32 = 0;
        while (i < t_cycles) : (i += 1) {
            if (self.enabled) {
                self.ch1.tick_timer();
                self.ch2.tick_timer();
                self.tick_ch3_timer();
                self.tick_ch4_timer();
            }
            self.sample_timer += SAMPLE_RATE;
            if (self.sample_timer >= CPU_CLOCK) {
                self.sample_timer -= CPU_CLOCK;
                if (self.sample_count < self.sample_buffer.len) {
                    self.sample_buffer[self.sample_count] = if (self.enabled) self.mix_sample() else 0;
                    self.sample_count += 1;
                }
            }
        }
    }

    fn clock_frame_sequencer(self: *Apu) void {
        switch (self.frame_seq_step) {
            0 => self.clock_length(),
            2 => {
                self.clock_length();
                self.clock_sweep();
            },
            4 => self.clock_length(),
            6 => {
                self.clock_length();
                self.clock_sweep();
            },
            7 => self.clock_envelope(),
            else => {},
        }
        self.frame_seq_step = (self.frame_seq_step + 1) & 7;
    }

    /// Returns true if the frame sequencer's next step will NOT clock length.
    /// This is the "first half" of the length period — the window where
    /// enabling length_enable causes an extra clock.
    fn in_length_first_half(self: *const Apu) bool {
        // Length is clocked on steps 0,2,4,6. After clocking, step increments.
        // So frame_seq_step is odd (1,3,5,7) means we just clocked length
        // and are in the "first half" before the next length clock.
        // Blargg: "first half should clock, second half shouldn't"
        return (self.frame_seq_step & 1) != 0;
    }

    fn clock_length(self: *Apu) void {
        if (self.ch1.length_enable and self.ch1.length_counter > 0) {
            self.ch1.length_counter -= 1;
            if (self.ch1.length_counter == 0) self.ch1.enabled = false;
        }
        if (self.ch2.length_enable and self.ch2.length_counter > 0) {
            self.ch2.length_counter -= 1;
            if (self.ch2.length_counter == 0) self.ch2.enabled = false;
        }
        if (self.ch3_length_enable and self.ch3_length_counter > 0) {
            self.ch3_length_counter -= 1;
            if (self.ch3_length_counter == 0) self.ch3_enabled = false;
        }
        if (self.ch4_length_enable and self.ch4_length_counter > 0) {
            self.ch4_length_counter -= 1;
            if (self.ch4_length_counter == 0) self.ch4_enabled = false;
        }
    }

    fn clock_envelope(self: *Apu) void {
        self.ch1.clock_envelope();
        self.ch2.clock_envelope();
        if (self.ch4_envelope_period != 0) {
            if (self.ch4_envelope_timer > 0) self.ch4_envelope_timer -= 1;
            if (self.ch4_envelope_timer == 0) {
                self.ch4_envelope_timer = self.ch4_envelope_period;
                if (self.ch4_envelope_add and self.ch4_volume < 15) {
                    self.ch4_volume += 1;
                } else if (!self.ch4_envelope_add and self.ch4_volume > 0) {
                    self.ch4_volume -= 1;
                }
            }
        }
    }

    fn clock_sweep(self: *Apu) void {
        if (self.ch1_sweep_timer > 0) self.ch1_sweep_timer -= 1;
        if (self.ch1_sweep_timer == 0) {
            self.ch1_sweep_timer = if (self.ch1_sweep_period != 0) self.ch1_sweep_period else 8;
            if (self.ch1_sweep_enabled and self.ch1_sweep_period != 0) {
                const new_freq = self.calc_sweep_freq();
                if (new_freq <= 2047 and self.ch1_sweep_shift != 0) {
                    self.ch1_sweep_shadow = new_freq;
                    self.ch1.frequency = new_freq;
                    _ = self.calc_sweep_freq();
                }
            }
        }
    }

    fn calc_sweep_freq(self: *Apu) u16 {
        const delta = self.ch1_sweep_shadow >> @intCast(self.ch1_sweep_shift);
        var new_freq: u16 = undefined;
        if (self.ch1_sweep_negate) {
            // Two's complement subtraction
            new_freq = self.ch1_sweep_shadow -% delta;
            self.ch1_sweep_negate_used = true;
        } else {
            new_freq = self.ch1_sweep_shadow + delta;
        }
        if (new_freq > 2047) {
            self.ch1.enabled = false;
        }
        return new_freq;
    }

    fn tick_ch3_timer(self: *Apu) void {
        if (self.ch3_timer > 0) self.ch3_timer -= 1;
        if (self.ch3_timer == 0) {
            self.ch3_timer = (2048 - self.ch3_frequency) * 2;
            self.ch3_position = (self.ch3_position + 1) & 31;
            const byte = self.wave_ram[self.ch3_position >> 1];
            self.ch3_sample_buffer = if (self.ch3_position & 1 == 0) (byte >> 4) else (byte & 0x0F);
        }
    }

    fn tick_ch4_timer(self: *Apu) void {
        if (self.ch4_timer > 0) self.ch4_timer -= 1;
        if (self.ch4_timer == 0) {
            const divisor: u32 = if (self.ch4_divisor_code == 0) 8 else @as(u32, self.ch4_divisor_code) * 16;
            self.ch4_timer = divisor << @intCast(self.ch4_clock_shift);
            const xor_bit: u16 = (self.ch4_lfsr & 1) ^ ((self.ch4_lfsr >> 1) & 1);
            self.ch4_lfsr = (self.ch4_lfsr >> 1) | (xor_bit << 14);
            if (self.ch4_width_mode) {
                self.ch4_lfsr &= ~@as(u16, 1 << 6);
                self.ch4_lfsr |= xor_bit << 6;
            }
        }
    }

    fn mix_sample(self: *Apu) i16 {
        var left: i32 = 0;
        var right: i32 = 0;
        const ch1_out: i32 = if (self.ch1.enabled and self.ch1.dac_enabled) @as(i32, self.ch1.get_output()) * 2 - 15 else 0;
        const ch2_out: i32 = if (self.ch2.enabled and self.ch2.dac_enabled) @as(i32, self.ch2.get_output()) * 2 - 15 else 0;
        const ch3_out: i32 = if (self.ch3_enabled and self.ch3_dac_enabled) blk: {
            const shifted: u8 = switch (self.ch3_volume_code) {
                0 => self.ch3_sample_buffer >> 4,
                1 => self.ch3_sample_buffer,
                2 => self.ch3_sample_buffer >> 1,
                3 => self.ch3_sample_buffer >> 2,
            };
            break :blk @as(i32, shifted) * 2 - 15;
        } else 0;
        const ch4_out: i32 = if (self.ch4_enabled and self.ch4_dac_enabled)
            (if (self.ch4_lfsr & 1 == 0) @as(i32, self.ch4_volume) * 2 - 15 else -15)
        else
            0;

        if (self.nr51 & 0x10 != 0) left += ch1_out;
        if (self.nr51 & 0x20 != 0) left += ch2_out;
        if (self.nr51 & 0x40 != 0) left += ch3_out;
        if (self.nr51 & 0x80 != 0) left += ch4_out;
        if (self.nr51 & 0x01 != 0) right += ch1_out;
        if (self.nr51 & 0x02 != 0) right += ch2_out;
        if (self.nr51 & 0x04 != 0) right += ch3_out;
        if (self.nr51 & 0x08 != 0) right += ch4_out;

        const left_vol: i32 = ((self.nr50 >> 4) & 7) + 1;
        const right_vol: i32 = (self.nr50 & 7) + 1;
        left = @divTrunc(left * left_vol, 4);
        right = @divTrunc(right * right_vol, 4);
        const mono = @divTrunc((left + right) * 256, 2);
        return @intCast(std.math.clamp(mono, -32768, 32767));
    }

    pub fn read(self: *Apu, address: u16) u8 {
        return switch (address) {
            0xFF10 => 0x80 | (@as(u8, self.ch1_sweep_period) << 4) |
                (if (self.ch1_sweep_negate) @as(u8, 0x08) else @as(u8, 0)) | self.ch1_sweep_shift,
            0xFF11 => (@as(u8, self.ch1.duty) << 6) | 0x3F,
            0xFF12 => (@as(u8, self.ch1.volume_init) << 4) |
                (if (self.ch1.envelope_add) @as(u8, 0x08) else @as(u8, 0)) | self.ch1.envelope_period,
            0xFF13 => 0xFF,
            0xFF14 => (if (self.ch1.length_enable) @as(u8, 0x40) else @as(u8, 0)) | 0xBF,
            0xFF15 => 0xFF,
            0xFF16 => (@as(u8, self.ch2.duty) << 6) | 0x3F,
            0xFF17 => (@as(u8, self.ch2.volume_init) << 4) |
                (if (self.ch2.envelope_add) @as(u8, 0x08) else @as(u8, 0)) | self.ch2.envelope_period,
            0xFF18 => 0xFF,
            0xFF19 => (if (self.ch2.length_enable) @as(u8, 0x40) else @as(u8, 0)) | 0xBF,
            0xFF1A => (if (self.ch3_dac_enabled) @as(u8, 0x80) else @as(u8, 0)) | 0x7F,
            0xFF1B => 0xFF,
            0xFF1C => (@as(u8, self.ch3_volume_code) << 5) | 0x9F,
            0xFF1D => 0xFF,
            0xFF1E => (if (self.ch3_length_enable) @as(u8, 0x40) else @as(u8, 0)) | 0xBF,
            0xFF1F => 0xFF,
            0xFF20 => 0xFF,
            0xFF21 => (@as(u8, self.ch4_volume_init) << 4) |
                (if (self.ch4_envelope_add) @as(u8, 0x08) else @as(u8, 0)) | self.ch4_envelope_period,
            0xFF22 => (@as(u8, self.ch4_clock_shift) << 4) |
                (if (self.ch4_width_mode) @as(u8, 0x08) else @as(u8, 0)) | self.ch4_divisor_code,
            0xFF23 => (if (self.ch4_length_enable) @as(u8, 0x40) else @as(u8, 0)) | 0xBF,
            0xFF24 => self.nr50,
            0xFF25 => self.nr51,
            0xFF26 => (if (self.enabled) @as(u8, 0x80) else @as(u8, 0)) | 0x70 |
                (if (self.ch1.enabled) @as(u8, 1) else @as(u8, 0)) |
                (if (self.ch2.enabled) @as(u8, 2) else @as(u8, 0)) |
                (if (self.ch3_enabled) @as(u8, 4) else @as(u8, 0)) |
                (if (self.ch4_enabled) @as(u8, 8) else @as(u8, 0)),
            0xFF27...0xFF2F => 0xFF,
            0xFF30...0xFF3F => {
                if (self.ch3_enabled) {
                    // When CH3 is active, reads return the byte currently being played
                    return self.wave_ram[self.ch3_position >> 1];
                }
                return self.wave_ram[address - 0xFF30];
            },
            else => 0xFF,
        };
    }

    pub fn write(self: *Apu, address: u16, value: u8) void {
        // Wave RAM is always accessible
        if (address >= 0xFF30 and address <= 0xFF3F) {
            if (self.ch3_enabled) {
                self.wave_ram[self.ch3_position >> 1] = value;
            } else {
                self.wave_ram[address - 0xFF30] = value;
            }
            return;
        }
        // NR52 power control
        if (address == 0xFF26) {
            const was_enabled = self.enabled;
            self.enabled = (value & 0x80) != 0;
            if (was_enabled and !self.enabled) {
                self.power_off();
            } else if (!was_enabled and self.enabled) {
                self.frame_seq_step = 0;
            }
            return;
        }
        // When APU is off, ignore all writes (CGB behavior)
        // On DMG, length counters would still be writable, but cgb_sound tests expect CGB behavior
        if (!self.enabled) return;

        switch (address) {
            0xFF10 => {
                self.ch1_sweep_period = @truncate((value >> 4) & 7);
                const new_negate = (value & 0x08) != 0;
                self.ch1_sweep_shift = @truncate(value & 7);
                if (!new_negate and self.ch1_sweep_negate_used) {
                    self.ch1.enabled = false;
                }
                self.ch1_sweep_negate = new_negate;
            },
            0xFF11 => {
                self.ch1.duty = @truncate(value >> 6);
                self.ch1.length_counter = 64 - @as(u16, value & 0x3F);
            },
            0xFF12 => {
                self.ch1.volume_init = @truncate(value >> 4);
                self.ch1.envelope_add = (value & 0x08) != 0;
                self.ch1.envelope_period = @truncate(value & 7);
                self.ch1.dac_enabled = (value & 0xF8) != 0;
                if (!self.ch1.dac_enabled) self.ch1.enabled = false;
            },
            0xFF13 => self.ch1.frequency = (self.ch1.frequency & 0x700) | value,
            0xFF14 => {
                self.ch1.frequency = (self.ch1.frequency & 0xFF) | (@as(u16, value & 7) << 8);
                const old_le = self.ch1.length_enable;
                self.ch1.length_enable = (value & 0x40) != 0;
                // Extra length clock when enabling length in first half
                if (!old_le and self.ch1.length_enable and self.in_length_first_half()) {
                    if (self.ch1.length_counter > 0) {
                        self.ch1.length_counter -= 1;
                        if (self.ch1.length_counter == 0 and (value & 0x80) == 0) {
                            self.ch1.enabled = false;
                        }
                    }
                }
                if (value & 0x80 != 0) self.trigger_ch1();
            },
            0xFF16 => {
                self.ch2.duty = @truncate(value >> 6);
                self.ch2.length_counter = 64 - @as(u16, value & 0x3F);
            },
            0xFF17 => {
                self.ch2.volume_init = @truncate(value >> 4);
                self.ch2.envelope_add = (value & 0x08) != 0;
                self.ch2.envelope_period = @truncate(value & 7);
                self.ch2.dac_enabled = (value & 0xF8) != 0;
                if (!self.ch2.dac_enabled) self.ch2.enabled = false;
            },
            0xFF18 => self.ch2.frequency = (self.ch2.frequency & 0x700) | value,
            0xFF19 => {
                self.ch2.frequency = (self.ch2.frequency & 0xFF) | (@as(u16, value & 7) << 8);
                const old_le = self.ch2.length_enable;
                self.ch2.length_enable = (value & 0x40) != 0;
                if (!old_le and self.ch2.length_enable and self.in_length_first_half()) {
                    if (self.ch2.length_counter > 0) {
                        self.ch2.length_counter -= 1;
                        if (self.ch2.length_counter == 0 and (value & 0x80) == 0) {
                            self.ch2.enabled = false;
                        }
                    }
                }
                if (value & 0x80 != 0) self.trigger_ch2();
            },
            0xFF1A => {
                self.ch3_dac_enabled = (value & 0x80) != 0;
                if (!self.ch3_dac_enabled) self.ch3_enabled = false;
            },
            0xFF1B => self.ch3_length_counter = 256 - @as(u16, value),
            0xFF1C => self.ch3_volume_code = @truncate((value >> 5) & 3),
            0xFF1D => self.ch3_frequency = (self.ch3_frequency & 0x700) | value,
            0xFF1E => {
                self.ch3_frequency = (self.ch3_frequency & 0xFF) | (@as(u16, value & 7) << 8);
                const old_le = self.ch3_length_enable;
                self.ch3_length_enable = (value & 0x40) != 0;
                if (!old_le and self.ch3_length_enable and self.in_length_first_half()) {
                    if (self.ch3_length_counter > 0) {
                        self.ch3_length_counter -= 1;
                        if (self.ch3_length_counter == 0 and (value & 0x80) == 0) {
                            self.ch3_enabled = false;
                        }
                    }
                }
                if (value & 0x80 != 0) self.trigger_ch3();
            },
            0xFF20 => self.ch4_length_counter = @truncate(64 - @as(u8, value & 0x3F)),
            0xFF21 => {
                self.ch4_volume_init = @truncate(value >> 4);
                self.ch4_envelope_add = (value & 0x08) != 0;
                self.ch4_envelope_period = @truncate(value & 7);
                self.ch4_dac_enabled = (value & 0xF8) != 0;
                if (!self.ch4_dac_enabled) self.ch4_enabled = false;
            },
            0xFF22 => {
                self.ch4_clock_shift = @truncate(value >> 4);
                self.ch4_width_mode = (value & 0x08) != 0;
                self.ch4_divisor_code = @truncate(value & 7);
            },
            0xFF23 => {
                const old_le = self.ch4_length_enable;
                self.ch4_length_enable = (value & 0x40) != 0;
                if (!old_le and self.ch4_length_enable and self.in_length_first_half()) {
                    if (self.ch4_length_counter > 0) {
                        self.ch4_length_counter -= 1;
                        if (self.ch4_length_counter == 0 and (value & 0x80) == 0) {
                            self.ch4_enabled = false;
                        }
                    }
                }
                if (value & 0x80 != 0) self.trigger_ch4();
            },
            0xFF24 => self.nr50 = value,
            0xFF25 => self.nr51 = value,
            else => {},
        }
    }

    fn trigger_ch1(self: *Apu) void {
        self.ch1.enabled = true;
        if (self.ch1.length_counter == 0) {
            self.ch1.length_counter = 64;
            // If length_enable and in first half, extra clock the freshly-loaded counter
            if (self.ch1.length_enable and self.in_length_first_half()) {
                self.ch1.length_counter -= 1;
            }
        }
        self.ch1.timer = (2048 - self.ch1.frequency) * 4;
        self.ch1.volume = self.ch1.volume_init;
        self.ch1.envelope_timer = self.ch1.envelope_period;
        self.ch1_sweep_shadow = self.ch1.frequency;
        self.ch1_sweep_timer = if (self.ch1_sweep_period != 0) self.ch1_sweep_period else 8;
        self.ch1_sweep_enabled = (self.ch1_sweep_period != 0 or self.ch1_sweep_shift != 0);
        self.ch1_sweep_negate_used = false;
        if (self.ch1_sweep_shift != 0) _ = self.calc_sweep_freq();
        if (!self.ch1.dac_enabled) self.ch1.enabled = false;
    }

    fn trigger_ch2(self: *Apu) void {
        self.ch2.enabled = true;
        if (self.ch2.length_counter == 0) {
            self.ch2.length_counter = 64;
            if (self.ch2.length_enable and self.in_length_first_half()) {
                self.ch2.length_counter -= 1;
            }
        }
        self.ch2.timer = (2048 - self.ch2.frequency) * 4;
        self.ch2.volume = self.ch2.volume_init;
        self.ch2.envelope_timer = self.ch2.envelope_period;
        if (!self.ch2.dac_enabled) self.ch2.enabled = false;
    }

    fn trigger_ch3(self: *Apu) void {
        self.ch3_enabled = true;
        if (self.ch3_length_counter == 0) {
            self.ch3_length_counter = 256;
            if (self.ch3_length_enable and self.in_length_first_half()) {
                self.ch3_length_counter -= 1;
            }
        }
        self.ch3_timer = (2048 - self.ch3_frequency) * 2 + 6;
        self.ch3_position = 0;
        if (!self.ch3_dac_enabled) self.ch3_enabled = false;
    }

    fn trigger_ch4(self: *Apu) void {
        self.ch4_enabled = true;
        if (self.ch4_length_counter == 0) {
            self.ch4_length_counter = 64;
            if (self.ch4_length_enable and self.in_length_first_half()) {
                self.ch4_length_counter -= 1;
            }
        }
        const divisor: u32 = if (self.ch4_divisor_code == 0) 8 else @as(u32, self.ch4_divisor_code) * 16;
        self.ch4_timer = divisor << @intCast(self.ch4_clock_shift);
        self.ch4_volume = self.ch4_volume_init;
        self.ch4_envelope_timer = self.ch4_envelope_period;
        self.ch4_lfsr = 0x7FFF;
        if (!self.ch4_dac_enabled) self.ch4_enabled = false;
    }

    fn power_off(self: *Apu) void {
        // Clear all registers and internal state
        // Length counters are also cleared on CGB
        self.ch1 = .{};
        self.ch2 = .{};
        self.ch1_sweep_period = 0;
        self.ch1_sweep_negate = false;
        self.ch1_sweep_shift = 0;
        self.ch1_sweep_timer = 0;
        self.ch1_sweep_enabled = false;
        self.ch1_sweep_negate_used = false;
        self.ch3_dac_enabled = false;
        self.ch3_enabled = false;
        self.ch3_volume_code = 0;
        self.ch3_frequency = 0;
        self.ch3_length_enable = false;
        self.ch3_length_counter = 0;
        self.ch4_enabled = false;
        self.ch4_dac_enabled = false;
        self.ch4_volume = 0;
        self.ch4_volume_init = 0;
        self.ch4_envelope_add = false;
        self.ch4_envelope_period = 0;
        self.ch4_clock_shift = 0;
        self.ch4_width_mode = false;
        self.ch4_divisor_code = 0;
        self.ch4_length_enable = false;
        self.ch4_length_counter = 0;
        self.nr50 = 0;
        self.nr51 = 0;
    }

    pub fn get_samples(self: *Apu) []const i16 {
        const count = self.sample_count;
        self.sample_count = 0;
        return self.sample_buffer[0..count];
    }
};

const PulseChannel = struct {
    enabled: bool = false,
    dac_enabled: bool = false,
    duty: u2 = 0,
    length_counter: u16 = 0,
    length_enable: bool = false,
    volume: u8 = 0,
    volume_init: u8 = 0,
    envelope_add: bool = false,
    envelope_period: u8 = 0,
    envelope_timer: u8 = 0,
    frequency: u16 = 0,
    timer: u16 = 0,
    duty_pos: u3 = 0,

    fn tick_timer(self: *PulseChannel) void {
        if (self.timer > 0) self.timer -= 1;
        if (self.timer == 0) {
            self.timer = (2048 - self.frequency) * 4;
            self.duty_pos +%= 1;
        }
    }

    fn clock_envelope(self: *PulseChannel) void {
        if (self.envelope_period != 0) {
            if (self.envelope_timer > 0) self.envelope_timer -= 1;
            if (self.envelope_timer == 0) {
                self.envelope_timer = self.envelope_period;
                if (self.envelope_add and self.volume < 15) {
                    self.volume += 1;
                } else if (!self.envelope_add and self.volume > 0) {
                    self.volume -= 1;
                }
            }
        }
    }

    fn get_output(self: *const PulseChannel) u8 {
        return DUTY_TABLE[self.duty][self.duty_pos] * self.volume;
    }
};
