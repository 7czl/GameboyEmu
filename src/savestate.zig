// Save State serialization/deserialization
// Binary format: header + CPU + Bus + MBC + Timer + PPU + APU
// Triggered by F5 (save) and F8 (load) in SDL mode

const std = @import("std");
const CPU = @import("cpu.zig").CPU;
const Bus = @import("bus.zig").Bus;
const Ppu = @import("ppu.zig").Ppu;
const Timer = @import("timer.zig").Timer;
const Apu = @import("apu.zig").Apu;
const Mbc = @import("mbc.zig").Mbc;
const Display = @import("display.zig").Display;

const MAGIC = [4]u8{ 'G', 'B', 'S', 'T' };
const VERSION: u8 = 1;

/// Writer helper: appends bytes to an ArrayList
const StateWriter = struct {
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    fn write_u8(self: *StateWriter, v: u8) void {
        self.buf.append(self.gpa, v) catch {};
    }
    fn write_u16(self: *StateWriter, v: u16) void {
        self.buf.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u16, v))) catch {};
    }
    fn write_u32(self: *StateWriter, v: u32) void {
        self.buf.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, v))) catch {};
    }
    fn write_u64(self: *StateWriter, v: u64) void {
        self.buf.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u64, v))) catch {};
    }
    fn write_i64(self: *StateWriter, v: i64) void {
        self.buf.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeToLittle(i64, v))) catch {};
    }
    fn write_bool(self: *StateWriter, v: bool) void {
        self.write_u8(if (v) 1 else 0);
    }
    fn write_bytes(self: *StateWriter, data: []const u8) void {
        self.buf.appendSlice(self.gpa, data) catch {};
    }
};

/// Reader helper: reads from a byte slice with bounds checking
const StateReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn read_u8(self: *StateReader) ?u8 {
        if (self.pos >= self.data.len) return null;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }
    fn read_u16(self: *StateReader) ?u16 {
        if (self.pos + 2 > self.data.len) return null;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }
    fn read_u32(self: *StateReader) ?u32 {
        if (self.pos + 4 > self.data.len) return null;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn read_u64(self: *StateReader) ?u64 {
        if (self.pos + 8 > self.data.len) return null;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }
    fn read_i64(self: *StateReader) ?i64 {
        if (self.pos + 8 > self.data.len) return null;
        const v = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }
    fn read_bool(self: *StateReader) ?bool {
        const v = self.read_u8() orelse return null;
        return v != 0;
    }
    fn read_bytes(self: *StateReader, dest: []u8) bool {
        if (self.pos + dest.len > self.data.len) return false;
        @memcpy(dest, self.data[self.pos .. self.pos + dest.len]);
        self.pos += dest.len;
        return true;
    }
    fn skip(self: *StateReader, n: usize) bool {
        if (self.pos + n > self.data.len) return false;
        self.pos += n;
        return true;
    }
};

/// Save complete emulator state to a byte buffer
pub fn save(allocator: std.mem.Allocator, cpu: *CPU, bus: *Bus) ?[]u8 {
    var buf: std.ArrayList(u8) = .{};
    var w = StateWriter{ .buf = &buf, .gpa = allocator };

    // Header
    w.write_bytes(&MAGIC);
    w.write_u8(VERSION);

    // CPU
    w.write_u8(cpu.a);
    w.write_u8(cpu.f);
    w.write_u8(cpu.b);
    w.write_u8(cpu.c);
    w.write_u8(cpu.d);
    w.write_u8(cpu.e);
    w.write_u8(cpu.h);
    w.write_u8(cpu.l);
    w.write_u16(cpu.pc);
    w.write_u16(cpu.sp);
    w.write_u64(cpu.cycles);
    w.write_bool(cpu.interrupt_master_enable);
    w.write_bool(cpu.halted);
    w.write_bool(cpu.ime_scheduled);
    w.write_bool(cpu.halt_bug_active);

    // Bus scalar state
    w.write_bool(bus.boot_rom_active);
    w.write_u8(@as(u8, bus.vram_bank));
    w.write_u8(@as(u8, bus.wram_bank));
    w.write_u8(bus.joypad_select);
    w.write_u8(bus.interrupt_enable_register);
    w.write_u8(bus.interrupt_flag);
    w.write_bool(bus.cgb_mode);
    w.write_u8(bus.bg_cram_index);
    w.write_u8(bus.obj_cram_index);
    w.write_bool(bus.obj_priority_by_oam);
    w.write_bool(bus.double_speed);
    w.write_bool(bus.speed_switch_armed);
    w.write_u16(bus.hdma_src);
    w.write_u16(bus.hdma_dst);
    w.write_u8(bus.hdma_length);
    w.write_bool(bus.hdma_active);

    // Bus memory arrays
    w.write_bytes(&bus.vram[0]);
    w.write_bytes(&bus.vram[1]);
    for (&bus.wram) |*bank| w.write_bytes(bank);
    w.write_bytes(&bus.oam);
    w.write_bytes(&bus.io_registers);
    w.write_bytes(&bus.hram);
    w.write_bytes(&bus.bg_cram);
    w.write_bytes(&bus.obj_cram);

    // MBC state
    save_mbc(&w, &bus.mbc);

    // Timer
    w.write_u16(bus.timer.div_counter);
    w.write_u8(bus.timer.tima);
    w.write_u8(bus.timer.tma);
    w.write_u8(bus.timer.tac);
    w.write_bool(bus.timer.prev_and_result);
    w.write_u8(bus.timer.overflow_cycles);
    w.write_bool(bus.timer.overflow_cancelled);
    w.write_bool(bus.timer.tima_just_reloaded);

    // PPU
    save_ppu(&w, bus.ppu);

    // APU
    save_apu(&w, bus.apu);

    return buf.toOwnedSlice(allocator) catch null;
}

/// Load complete emulator state from a byte buffer
pub fn load(data: []const u8, cpu: *CPU, bus: *Bus) bool {
    var r = StateReader{ .data = data };

    // Header
    var magic: [4]u8 = undefined;
    if (!r.read_bytes(&magic)) return false;
    if (!std.mem.eql(u8, &magic, &MAGIC)) return false;
    const version = r.read_u8() orelse return false;
    if (version != VERSION) return false;

    // CPU
    cpu.a = r.read_u8() orelse return false;
    cpu.f = r.read_u8() orelse return false;
    cpu.b = r.read_u8() orelse return false;
    cpu.c = r.read_u8() orelse return false;
    cpu.d = r.read_u8() orelse return false;
    cpu.e = r.read_u8() orelse return false;
    cpu.h = r.read_u8() orelse return false;
    cpu.l = r.read_u8() orelse return false;
    cpu.pc = r.read_u16() orelse return false;
    cpu.sp = r.read_u16() orelse return false;
    cpu.cycles = r.read_u64() orelse return false;
    cpu.interrupt_master_enable = r.read_bool() orelse return false;
    cpu.halted = r.read_bool() orelse return false;
    cpu.ime_scheduled = r.read_bool() orelse return false;
    cpu.halt_bug_active = r.read_bool() orelse return false;

    // Bus scalar state
    bus.boot_rom_active = r.read_bool() orelse return false;
    bus.vram_bank = @truncate(r.read_u8() orelse return false);
    bus.wram_bank = @truncate(r.read_u8() orelse return false);
    bus.joypad_select = r.read_u8() orelse return false;
    bus.interrupt_enable_register = r.read_u8() orelse return false;
    bus.interrupt_flag = r.read_u8() orelse return false;
    bus.cgb_mode = r.read_bool() orelse return false;
    bus.bg_cram_index = r.read_u8() orelse return false;
    bus.obj_cram_index = r.read_u8() orelse return false;
    bus.obj_priority_by_oam = r.read_bool() orelse return false;
    bus.double_speed = r.read_bool() orelse return false;
    bus.speed_switch_armed = r.read_bool() orelse return false;
    bus.hdma_src = r.read_u16() orelse return false;
    bus.hdma_dst = r.read_u16() orelse return false;
    bus.hdma_length = r.read_u8() orelse return false;
    bus.hdma_active = r.read_bool() orelse return false;

    // Bus memory arrays
    if (!r.read_bytes(&bus.vram[0])) return false;
    if (!r.read_bytes(&bus.vram[1])) return false;
    for (&bus.wram) |*bank| if (!r.read_bytes(bank)) return false;
    if (!r.read_bytes(&bus.oam)) return false;
    if (!r.read_bytes(&bus.io_registers)) return false;
    if (!r.read_bytes(&bus.hram)) return false;
    if (!r.read_bytes(&bus.bg_cram)) return false;
    if (!r.read_bytes(&bus.obj_cram)) return false;

    // MBC state
    if (!load_mbc(&r, &bus.mbc)) return false;

    // Timer
    bus.timer.div_counter = r.read_u16() orelse return false;
    bus.timer.tima = r.read_u8() orelse return false;
    bus.timer.tma = r.read_u8() orelse return false;
    bus.timer.tac = r.read_u8() orelse return false;
    bus.timer.prev_and_result = r.read_bool() orelse return false;
    bus.timer.overflow_cycles = r.read_u8() orelse return false;
    bus.timer.overflow_cancelled = r.read_bool() orelse return false;
    bus.timer.tima_just_reloaded = r.read_bool() orelse return false;

    // PPU
    if (!load_ppu(&r, bus.ppu)) return false;

    // APU
    if (!load_apu(&r, bus.apu)) return false;

    return true;
}

fn save_mbc(w: *StateWriter, mbc: *Mbc) void {
    // Write MBC type tag
    const tag: u8 = switch (mbc.*) {
        .none => 0,
        .mbc1 => 1,
        .mbc2 => 2,
        .mbc3 => 3,
        .mbc5 => 5,
    };
    w.write_u8(tag);

    switch (mbc.*) {
        .none => {},
        .mbc1 => |*m| {
            w.write_u8(m.rom_bank);
            w.write_u8(m.ram_bank);
            w.write_bool(m.ram_enabled);
            w.write_u8(@as(u8, m.banking_mode));
            w.write_u16(m.rom_bank_count);
            w.write_bytes(&m.ram);
        },
        .mbc2 => |*m| {
            w.write_u8(m.rom_bank);
            w.write_bool(m.ram_enabled);
            w.write_u16(m.rom_bank_count);
            w.write_bytes(&m.ram);
        },
        .mbc3 => |*m| {
            w.write_u8(m.rom_bank);
            w.write_u8(m.ram_bank);
            w.write_bool(m.ram_enabled);
            w.write_u16(m.rom_bank_count);
            w.write_bytes(&m.ram);
            // RTC state
            w.write_u8(m.rtc_s);
            w.write_u8(m.rtc_m);
            w.write_u8(m.rtc_h);
            w.write_u8(m.rtc_dl);
            w.write_u8(m.rtc_dh);
            w.write_u8(m.latched_s);
            w.write_u8(m.latched_m);
            w.write_u8(m.latched_h);
            w.write_u8(m.latched_dl);
            w.write_u8(m.latched_dh);
            w.write_bool(m.latch_ready);
            w.write_u32(m.rtc_cycles);
            w.write_i64(m.rtc_timestamp);
        },
        .mbc5 => |*m| {
            w.write_u8(m.rom_bank_lo);
            w.write_u8(@as(u8, m.rom_bank_hi));
            w.write_u8(m.ram_bank);
            w.write_bool(m.ram_enabled);
            w.write_u16(m.rom_bank_count);
            w.write_bytes(&m.ram);
        },
    }
}

fn load_mbc(r: *StateReader, mbc: *Mbc) bool {
    const tag = r.read_u8() orelse return false;

    // Verify tag matches current MBC type
    const expected: u8 = switch (mbc.*) {
        .none => 0,
        .mbc1 => 1,
        .mbc2 => 2,
        .mbc3 => 3,
        .mbc5 => 5,
    };
    if (tag != expected) return false;

    switch (mbc.*) {
        .none => {},
        .mbc1 => |*m| {
            m.rom_bank = r.read_u8() orelse return false;
            m.ram_bank = r.read_u8() orelse return false;
            m.ram_enabled = r.read_bool() orelse return false;
            m.banking_mode = @truncate(r.read_u8() orelse return false);
            m.rom_bank_count = r.read_u16() orelse return false;
            if (!r.read_bytes(&m.ram)) return false;
        },
        .mbc2 => |*m| {
            m.rom_bank = r.read_u8() orelse return false;
            m.ram_enabled = r.read_bool() orelse return false;
            m.rom_bank_count = r.read_u16() orelse return false;
            if (!r.read_bytes(&m.ram)) return false;
        },
        .mbc3 => |*m| {
            m.rom_bank = r.read_u8() orelse return false;
            m.ram_bank = r.read_u8() orelse return false;
            m.ram_enabled = r.read_bool() orelse return false;
            m.rom_bank_count = r.read_u16() orelse return false;
            if (!r.read_bytes(&m.ram)) return false;
            m.rtc_s = r.read_u8() orelse return false;
            m.rtc_m = r.read_u8() orelse return false;
            m.rtc_h = r.read_u8() orelse return false;
            m.rtc_dl = r.read_u8() orelse return false;
            m.rtc_dh = r.read_u8() orelse return false;
            m.latched_s = r.read_u8() orelse return false;
            m.latched_m = r.read_u8() orelse return false;
            m.latched_h = r.read_u8() orelse return false;
            m.latched_dl = r.read_u8() orelse return false;
            m.latched_dh = r.read_u8() orelse return false;
            m.latch_ready = r.read_bool() orelse return false;
            m.rtc_cycles = r.read_u32() orelse return false;
            m.rtc_timestamp = r.read_i64() orelse return false;
        },
        .mbc5 => |*m| {
            m.rom_bank_lo = r.read_u8() orelse return false;
            m.rom_bank_hi = @truncate(r.read_u8() orelse return false);
            m.ram_bank = r.read_u8() orelse return false;
            m.ram_enabled = r.read_bool() orelse return false;
            m.rom_bank_count = r.read_u16() orelse return false;
            if (!r.read_bytes(&m.ram)) return false;
        },
    }
    return true;
}

fn save_ppu(w: *StateWriter, ppu: *Ppu) void {
    w.write_u8(ppu.ly);
    w.write_u16(ppu.cycle_counter);
    w.write_bool(ppu.enabled);
    w.write_u8(@intFromEnum(ppu.mode));
    w.write_u8(ppu.lcdc);
    w.write_u8(ppu.stat);
    w.write_u8(ppu.scy);
    w.write_u8(ppu.scx);
    w.write_u8(ppu.lyc);
    w.write_u8(ppu.bgp);
    w.write_u8(ppu.obp0);
    w.write_u8(ppu.obp1);
    w.write_u8(ppu.wy);
    w.write_u8(ppu.wx);
    w.write_u8(ppu.window_line_counter);
    w.write_bool(ppu.window_was_active);
    w.write_bool(ppu.stat_irq_line);
    w.write_u8(ppu.pixels_pushed);
    w.write_u8(ppu.fetcher_x);
    w.write_u8(@intFromEnum(ppu.fetcher_state));
    w.write_u8(ppu.fetcher_ticks);
    w.write_u8(ppu.fetch_tile_id);
    w.write_u8(ppu.fetch_tile_lo);
    w.write_u8(ppu.fetch_tile_hi);
    w.write_u8(ppu.fetch_tile_attrs);
    w.write_u8(ppu.scx_discard);
    w.write_bool(ppu.in_window);
    w.write_bool(ppu.window_triggered);
    w.write_bool(ppu.initial_fetch_done);
    w.write_bool(ppu.wy_latch);
    w.write_u8(ppu.sprite_count);
    w.write_bool(ppu.sprite_fetch_active);
    w.write_u8(ppu.sprite_fetch_idx);
    w.write_u8(ppu.sprite_fetch_ticks);
    w.write_u8(ppu.sprite_tile_lo);
    w.write_u8(ppu.sprite_tile_hi);
    // BG FIFO state
    w.write_u8(@as(u8, ppu.bg_fifo.head));
    w.write_u8(@as(u8, ppu.bg_fifo.count));
}

fn load_ppu(r: *StateReader, ppu: *Ppu) bool {
    ppu.ly = r.read_u8() orelse return false;
    ppu.cycle_counter = r.read_u16() orelse return false;
    ppu.enabled = r.read_bool() orelse return false;
    const mode_val = r.read_u8() orelse return false;
    ppu.mode = @enumFromInt(mode_val);
    ppu.lcdc = r.read_u8() orelse return false;
    ppu.stat = r.read_u8() orelse return false;
    ppu.scy = r.read_u8() orelse return false;
    ppu.scx = r.read_u8() orelse return false;
    ppu.lyc = r.read_u8() orelse return false;
    ppu.bgp = r.read_u8() orelse return false;
    ppu.obp0 = r.read_u8() orelse return false;
    ppu.obp1 = r.read_u8() orelse return false;
    ppu.wy = r.read_u8() orelse return false;
    ppu.wx = r.read_u8() orelse return false;
    ppu.window_line_counter = r.read_u8() orelse return false;
    ppu.window_was_active = r.read_bool() orelse return false;
    ppu.stat_irq_line = r.read_bool() orelse return false;
    ppu.pixels_pushed = r.read_u8() orelse return false;
    ppu.fetcher_x = r.read_u8() orelse return false;
    const fs_val = r.read_u8() orelse return false;
    ppu.fetcher_state = @enumFromInt(fs_val);
    ppu.fetcher_ticks = r.read_u8() orelse return false;
    ppu.fetch_tile_id = r.read_u8() orelse return false;
    ppu.fetch_tile_lo = r.read_u8() orelse return false;
    ppu.fetch_tile_hi = r.read_u8() orelse return false;
    ppu.fetch_tile_attrs = r.read_u8() orelse return false;
    ppu.scx_discard = r.read_u8() orelse return false;
    ppu.in_window = r.read_bool() orelse return false;
    ppu.window_triggered = r.read_bool() orelse return false;
    ppu.initial_fetch_done = r.read_bool() orelse return false;
    ppu.wy_latch = r.read_bool() orelse return false;
    ppu.sprite_count = r.read_u8() orelse return false;
    ppu.sprite_fetch_active = r.read_bool() orelse return false;
    ppu.sprite_fetch_idx = r.read_u8() orelse return false;
    ppu.sprite_fetch_ticks = r.read_u8() orelse return false;
    ppu.sprite_tile_lo = r.read_u8() orelse return false;
    ppu.sprite_tile_hi = r.read_u8() orelse return false;
    // BG FIFO state
    ppu.bg_fifo.head = @truncate(r.read_u8() orelse return false);
    ppu.bg_fifo.count = @truncate(r.read_u8() orelse return false);
    return true;
}

fn save_pulse(w: *StateWriter, ch: anytype) void {
    w.write_bool(ch.enabled);
    w.write_bool(ch.dac_enabled);
    w.write_u8(@as(u8, ch.duty));
    w.write_u16(ch.length_counter);
    w.write_bool(ch.length_enable);
    w.write_u8(ch.volume);
    w.write_u8(ch.volume_init);
    w.write_bool(ch.envelope_add);
    w.write_u8(ch.envelope_period);
    w.write_u8(ch.envelope_timer);
    w.write_u16(ch.frequency);
    w.write_u16(ch.timer);
    w.write_u8(@as(u8, ch.duty_pos));
}

fn load_pulse(r: *StateReader, ch: anytype) bool {
    ch.enabled = r.read_bool() orelse return false;
    ch.dac_enabled = r.read_bool() orelse return false;
    ch.duty = @truncate(r.read_u8() orelse return false);
    ch.length_counter = r.read_u16() orelse return false;
    ch.length_enable = r.read_bool() orelse return false;
    ch.volume = r.read_u8() orelse return false;
    ch.volume_init = r.read_u8() orelse return false;
    ch.envelope_add = r.read_bool() orelse return false;
    ch.envelope_period = r.read_u8() orelse return false;
    ch.envelope_timer = r.read_u8() orelse return false;
    ch.frequency = r.read_u16() orelse return false;
    ch.timer = r.read_u16() orelse return false;
    ch.duty_pos = @truncate(r.read_u8() orelse return false);
    return true;
}

fn save_apu(w: *StateWriter, apu: *Apu) void {
    w.write_bool(apu.enabled);
    w.write_u8(apu.nr50);
    w.write_u8(apu.nr51);
    w.write_bool(apu.cgb_mode);

    // CH1 (pulse + sweep)
    save_pulse(w, &apu.ch1);
    w.write_u8(apu.ch1_sweep_period);
    w.write_bool(apu.ch1_sweep_negate);
    w.write_u8(apu.ch1_sweep_shift);
    w.write_u8(apu.ch1_sweep_timer);
    w.write_bool(apu.ch1_sweep_enabled);
    w.write_u16(apu.ch1_sweep_shadow);
    w.write_bool(apu.ch1_sweep_negate_used);

    // CH2 (pulse)
    save_pulse(w, &apu.ch2);

    // CH3 (wave)
    w.write_bool(apu.ch3_enabled);
    w.write_bool(apu.ch3_dac_enabled);
    w.write_u16(apu.ch3_length_counter);
    w.write_u8(@as(u8, apu.ch3_volume_code));
    w.write_u16(apu.ch3_frequency);
    w.write_bool(apu.ch3_length_enable);
    w.write_u16(apu.ch3_timer);
    w.write_u8(apu.ch3_position);
    w.write_u8(apu.ch3_sample_buffer);
    w.write_u8(apu.ch3_wave_recently_read);
    w.write_bytes(&apu.wave_ram);

    // CH4 (noise)
    w.write_bool(apu.ch4_enabled);
    w.write_bool(apu.ch4_dac_enabled);
    w.write_u8(apu.ch4_length_counter);
    w.write_u8(apu.ch4_volume);
    w.write_u8(apu.ch4_volume_init);
    w.write_bool(apu.ch4_envelope_add);
    w.write_u8(apu.ch4_envelope_period);
    w.write_u8(apu.ch4_envelope_timer);
    w.write_bool(apu.ch4_length_enable);
    w.write_u8(apu.ch4_clock_shift);
    w.write_bool(apu.ch4_width_mode);
    w.write_u8(apu.ch4_divisor_code);
    w.write_u32(apu.ch4_timer);
    w.write_u16(apu.ch4_lfsr);

    // Frame sequencer
    w.write_u8(apu.frame_seq_step);
    w.write_bool(apu.prev_div_bit);
    w.write_u32(apu.sample_timer);
}

fn load_apu(r: *StateReader, apu: *Apu) bool {
    apu.enabled = r.read_bool() orelse return false;
    apu.nr50 = r.read_u8() orelse return false;
    apu.nr51 = r.read_u8() orelse return false;
    apu.cgb_mode = r.read_bool() orelse return false;

    // CH1
    if (!load_pulse(r, &apu.ch1)) return false;
    apu.ch1_sweep_period = r.read_u8() orelse return false;
    apu.ch1_sweep_negate = r.read_bool() orelse return false;
    apu.ch1_sweep_shift = r.read_u8() orelse return false;
    apu.ch1_sweep_timer = r.read_u8() orelse return false;
    apu.ch1_sweep_enabled = r.read_bool() orelse return false;
    apu.ch1_sweep_shadow = r.read_u16() orelse return false;
    apu.ch1_sweep_negate_used = r.read_bool() orelse return false;

    // CH2
    if (!load_pulse(r, &apu.ch2)) return false;

    // CH3
    apu.ch3_enabled = r.read_bool() orelse return false;
    apu.ch3_dac_enabled = r.read_bool() orelse return false;
    apu.ch3_length_counter = r.read_u16() orelse return false;
    apu.ch3_volume_code = @truncate(r.read_u8() orelse return false);
    apu.ch3_frequency = r.read_u16() orelse return false;
    apu.ch3_length_enable = r.read_bool() orelse return false;
    apu.ch3_timer = r.read_u16() orelse return false;
    apu.ch3_position = r.read_u8() orelse return false;
    apu.ch3_sample_buffer = r.read_u8() orelse return false;
    apu.ch3_wave_recently_read = r.read_u8() orelse return false;
    if (!r.read_bytes(&apu.wave_ram)) return false;

    // CH4
    apu.ch4_enabled = r.read_bool() orelse return false;
    apu.ch4_dac_enabled = r.read_bool() orelse return false;
    apu.ch4_length_counter = r.read_u8() orelse return false;
    apu.ch4_volume = r.read_u8() orelse return false;
    apu.ch4_volume_init = r.read_u8() orelse return false;
    apu.ch4_envelope_add = r.read_bool() orelse return false;
    apu.ch4_envelope_period = r.read_u8() orelse return false;
    apu.ch4_envelope_timer = r.read_u8() orelse return false;
    apu.ch4_length_enable = r.read_bool() orelse return false;
    apu.ch4_clock_shift = r.read_u8() orelse return false;
    apu.ch4_width_mode = r.read_bool() orelse return false;
    apu.ch4_divisor_code = r.read_u8() orelse return false;
    apu.ch4_timer = r.read_u32() orelse return false;
    apu.ch4_lfsr = r.read_u16() orelse return false;

    // Frame sequencer
    apu.frame_seq_step = r.read_u8() orelse return false;
    apu.prev_div_bit = r.read_bool() orelse return false;
    apu.sample_timer = r.read_u32() orelse return false;

    // Clear sample buffer on load
    apu.sample_count = 0;
    return true;
}
