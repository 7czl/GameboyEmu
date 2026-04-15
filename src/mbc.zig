// MBC (Memory Bank Controller) implementations
// Supports NoMbc, MBC1, MBC2, MBC3, and MBC5

const std = @import("std");

pub const MbcType = enum {
    none,
    mbc1,
    mbc2,
    mbc3,
    mbc5,
};

pub const Mbc = union(MbcType) {
    none: NoMbc,
    mbc1: Mbc1,
    mbc2: Mbc2,
    mbc3: Mbc3,
    mbc5: Mbc5,

    /// Detect MBC type from cartridge type byte at ROM offset 0x147
    pub fn from_cartridge_type(cart_type: u8, rom_size: usize) Mbc {
        return switch (cart_type) {
            0x00, 0x08, 0x09 => .{ .none = NoMbc.init() },
            0x01, 0x02, 0x03 => .{ .mbc1 = Mbc1.init(rom_size) },
            0x05, 0x06 => .{ .mbc2 = Mbc2.init(rom_size) },
            0x0F, 0x10, 0x11, 0x12, 0x13 => .{ .mbc3 = Mbc3.init(rom_size) },
            0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E => .{ .mbc5 = Mbc5.init(rom_size) },
            else => {
                std.log.warn("Unknown cartridge type 0x{X:0>2}, falling back to NoMbc", .{cart_type});
                return .{ .none = NoMbc.init() };
            },
        };
    }

    /// Read from ROM area (0x0000-0x7FFF)
    pub fn read_rom(self: *Mbc, rom: []const u8, address: u16) u8 {
        return switch (self.*) {
            .none => |*m| m.read_rom(rom, address),
            .mbc1 => |*m| m.read_rom(rom, address),
            .mbc2 => |*m| m.read_rom(rom, address),
            .mbc3 => |*m| m.read_rom(rom, address),
            .mbc5 => |*m| m.read_rom(rom, address),
        };
    }

    /// Read from external RAM area (0xA000-0xBFFF)
    pub fn read_ram(self: *Mbc, address: u16) u8 {
        return switch (self.*) {
            .none => 0xFF,
            .mbc1 => |*m| m.read_ram(address),
            .mbc2 => |*m| m.read_ram(address),
            .mbc3 => |*m| m.read_ram(address),
            .mbc5 => |*m| m.read_ram(address),
        };
    }

    /// Write to ROM area (0x0000-0x7FFF) — MBC register writes
    pub fn write_rom(self: *Mbc, address: u16, value: u8) void {
        switch (self.*) {
            .none => {},
            .mbc1 => |*m| m.write_rom(address, value),
            .mbc2 => |*m| m.write_rom(address, value),
            .mbc3 => |*m| m.write_rom(address, value),
            .mbc5 => |*m| m.write_rom(address, value),
        }
    }

    /// Write to external RAM area (0xA000-0xBFFF)
    pub fn write_ram(self: *Mbc, address: u16, value: u8) void {
        switch (self.*) {
            .none => {},
            .mbc1 => |*m| m.write_ram(address, value),
            .mbc2 => |*m| m.write_ram(address, value),
            .mbc3 => |*m| m.write_ram(address, value),
            .mbc5 => |*m| m.write_ram(address, value),
        }
    }

    /// Check if cartridge has battery-backed RAM (needs save file)
    pub fn has_battery(cart_type: u8) bool {
        return switch (cart_type) {
            0x03 => true, // MBC1+RAM+BATTERY
            0x06 => true, // MBC2+BATTERY
            0x09 => true, // ROM+RAM+BATTERY
            0x0D => true, // MMM01+RAM+BATTERY
            0x0F, 0x10, 0x13 => true, // MBC3+TIMER+BATTERY, MBC3+TIMER+RAM+BATTERY, MBC3+RAM+BATTERY
            0x1B, 0x1E => true, // MBC5+RAM+BATTERY, MBC5+RUMBLE+RAM+BATTERY
            0x22 => true, // MBC7+SENSOR+RUMBLE+RAM+BATTERY
            0xFF => true, // HuC1+RAM+BATTERY
            else => false,
        };
    }

    /// Get a slice of the entire RAM for saving
    pub fn get_ram_data(self: *Mbc) ?[]const u8 {
        return switch (self.*) {
            .none => null,
            .mbc1 => |*m| &m.ram,
            .mbc2 => |*m| &m.ram,
            .mbc3 => |*m| &m.ram,
            .mbc5 => |*m| &m.ram,
        };
    }

    /// Load RAM data from a save file
    pub fn load_ram_data(self: *Mbc, data: []const u8) void {
        switch (self.*) {
            .none => {},
            .mbc1 => |*m| {
                const len = @min(data.len, m.ram.len);
                @memcpy(m.ram[0..len], data[0..len]);
            },
            .mbc2 => |*m| {
                const len = @min(data.len, m.ram.len);
                @memcpy(m.ram[0..len], data[0..len]);
            },
            .mbc3 => |*m| {
                const ram_len = @min(data.len, m.ram.len);
                @memcpy(m.ram[0..ram_len], data[0..ram_len]);
                // Load RTC state appended after RAM (48 bytes)
                if (data.len >= m.ram.len + 48) {
                    m.load_rtc_save_data(data[m.ram.len .. m.ram.len + 48]);
                }
            },
            .mbc5 => |*m| {
                const len = @min(data.len, m.ram.len);
                @memcpy(m.ram[0..len], data[0..len]);
            },
        }
    }

    /// Tick RTC for MBC3 cartridges
    pub fn tick_rtc(self: *Mbc, t_cycles: u32) void {
        switch (self.*) {
            .mbc3 => |*m| m.tick_rtc(t_cycles),
            else => {},
        }
    }

    /// Check if this MBC has an RTC
    pub fn has_rtc(self: *Mbc) bool {
        return switch (self.*) {
            .mbc3 => true,
            else => false,
        };
    }

    /// Get save data including RTC state for MBC3
    pub fn get_save_data_with_rtc(self: *Mbc, allocator: std.mem.Allocator) ?[]u8 {
        return switch (self.*) {
            .mbc3 => |*m| {
                const rtc_data = m.get_rtc_save_data();
                const total = m.ram.len + 48;
                const buf = allocator.alloc(u8, total) catch return null;
                @memcpy(buf[0..m.ram.len], &m.ram);
                @memcpy(buf[m.ram.len..total], &rtc_data);
                return buf;
            },
            else => null,
        };
    }
};

// ============================================================
// NoMbc — ROM_ONLY (no bank switching)
// ============================================================
const NoMbc = struct {
    pub fn init() NoMbc {
        return NoMbc{};
    }

    pub fn read_rom(_: *NoMbc, rom: []const u8, address: u16) u8 {
        if (address < rom.len) return rom[address];
        return 0xFF;
    }
};

// ============================================================
// MBC1 — up to 2MB ROM / 32KB RAM
// ============================================================
const Mbc1 = struct {
    rom_bank: u8 = 1,
    ram_bank: u8 = 0,
    ram_enabled: bool = false,
    banking_mode: u1 = 0, // 0 = ROM mode, 1 = RAM mode
    rom_bank_count: u16,
    multicart: bool = false, // true for multicart ROMs (1MB MBC1)
    ram: [4 * 8192]u8 = .{0} ** (4 * 8192), // 4 banks × 8KB

    pub fn init(rom_size: usize) Mbc1 {
        const bank_count: u16 = @intCast(@max(2, rom_size / 0x4000));
        // Detect multicart: MBC1 with exactly 1MB (64 banks) ROM.
        // Real multicarts use a different wiring where the upper 2 bits
        // select a 256KB sub-game instead of extending the bank number.
        const is_multicart = (bank_count == 64);
        return Mbc1{ .rom_bank_count = bank_count, .multicart = is_multicart };
    }

    /// Number of bits used for the lower ROM bank register.
    /// Standard MBC1: 5 bits (banks 0-31 per sub-bank).
    /// Multicart: 4 bits (banks 0-15 per sub-game).
    fn romBankBits(self: *const Mbc1) u5 {
        return if (self.multicart) 4 else 5;
    }

    fn romBankMask(self: *const Mbc1) u8 {
        return if (self.multicart) 0x0F else 0x1F;
    }

    pub fn read_rom(self: *Mbc1, rom: []const u8, address: u16) u8 {
        switch (address) {
            0x0000...0x3FFF => {
                if (self.banking_mode == 1) {
                    // In mode 1, bank 0 area uses upper bits to select sub-bank
                    const shift = self.romBankBits();
                    const bank: u32 = (@as(u32, self.ram_bank) << shift) % self.rom_bank_count;
                    const offset = bank * 0x4000 + address;
                    if (offset < rom.len) return rom[offset];
                    return 0xFF;
                }
                return rom[address];
            },
            0x4000...0x7FFF => {
                const shift = self.romBankBits();
                const mask = self.romBankMask();
                const low_bank: u8 = self.rom_bank & mask;
                // In multicart mode 0, upper bits (ram_bank) don't affect $4000 area.
                // In standard MBC1, upper bits always apply to $4000.
                const upper: u32 = if (self.multicart and self.banking_mode == 0)
                    0
                else
                    @as(u32, self.ram_bank) << shift;
                var bank: u32 = @as(u32, low_bank) | upper;
                // Bank 0 → 1 fix: only when the full composed bank is 0
                if (bank == 0) bank = 1;
                bank %= self.rom_bank_count;
                const offset = bank * 0x4000 + (address - 0x4000);
                if (offset < rom.len) return rom[offset];
                return 0xFF;
            },
            else => return 0xFF,
        }
    }

    pub fn read_ram(self: *Mbc1, address: u16) u8 {
        if (!self.ram_enabled) return 0xFF;
        const bank: u16 = if (self.banking_mode == 1) self.ram_bank else 0;
        const offset = @as(u32, bank) * 0x2000 + (address - 0xA000);
        if (offset < self.ram.len) return self.ram[offset];
        return 0xFF;
    }

    pub fn write_rom(self: *Mbc1, address: u16, value: u8) void {
        switch (address) {
            0x0000...0x1FFF => {
                self.ram_enabled = (value & 0x0F) == 0x0A;
            },
            0x2000...0x3FFF => {
                // ROM bank number (lower 5 bits for standard, 4 for multicart)
                const mask = self.romBankMask();
                var bank = value & mask;
                if (bank == 0) bank = 1;
                self.rom_bank = bank;
            },
            0x4000...0x5FFF => {
                self.ram_bank = value & 0x03;
            },
            0x6000...0x7FFF => {
                self.banking_mode = @truncate(value & 0x01);
            },
            else => {},
        }
    }

    pub fn write_ram(self: *Mbc1, address: u16, value: u8) void {
        if (!self.ram_enabled) return;
        const bank: u16 = if (self.banking_mode == 1) self.ram_bank else 0;
        const offset = @as(u32, bank) * 0x2000 + (address - 0xA000);
        if (offset < self.ram.len) self.ram[offset] = value;
    }
};

// ============================================================
// MBC2 — up to 256KB ROM / 512×4-bit internal RAM
// ============================================================
const Mbc2 = struct {
    rom_bank: u8 = 1,
    ram_enabled: bool = false,
    rom_bank_count: u16,
    ram: [512]u8 = .{0} ** 512, // 512 × 4-bit (only lower nibble used)

    pub fn init(rom_size: usize) Mbc2 {
        const bank_count: u16 = @intCast(@max(2, rom_size / 0x4000));
        return Mbc2{ .rom_bank_count = bank_count };
    }

    pub fn read_rom(self: *Mbc2, rom: []const u8, address: u16) u8 {
        switch (address) {
            0x0000...0x3FFF => return rom[address],
            0x4000...0x7FFF => {
                const bank: u32 = @as(u32, self.rom_bank) % self.rom_bank_count;
                const offset = bank * 0x4000 + (address - 0x4000);
                if (offset < rom.len) return rom[offset];
                return 0xFF;
            },
            else => return 0xFF,
        }
    }

    pub fn read_ram(self: *Mbc2, address: u16) u8 {
        if (!self.ram_enabled) return 0xFF;
        // MBC2 RAM is 512 bytes at 0xA000-0xA1FF, mirrored across 0xA000-0xBFFF
        const offset = (address - 0xA000) & 0x1FF;
        return self.ram[offset] | 0xF0; // upper nibble reads as 1s
    }

    pub fn write_rom(self: *Mbc2, address: u16, value: u8) void {
        switch (address) {
            // Bit 8 of address distinguishes RAM enable vs ROM bank
            0x0000...0x3FFF => {
                if (address & 0x0100 == 0) {
                    // RAM enable (bit 8 == 0)
                    self.ram_enabled = (value & 0x0F) == 0x0A;
                } else {
                    // ROM bank (bit 8 == 1)
                    var bank = value & 0x0F;
                    if (bank == 0) bank = 1;
                    self.rom_bank = bank;
                }
            },
            else => {},
        }
    }

    pub fn write_ram(self: *Mbc2, address: u16, value: u8) void {
        if (!self.ram_enabled) return;
        const offset = (address - 0xA000) & 0x1FF;
        self.ram[offset] = value & 0x0F; // only lower 4 bits stored
    }
};

// ============================================================
// MBC3 — up to 2MB ROM / 32KB RAM + RTC
// ============================================================
const Mbc3 = struct {
    rom_bank: u8 = 1,
    ram_bank: u8 = 0,
    ram_enabled: bool = false,
    rom_bank_count: u16,
    ram: [4 * 8192]u8 = .{0} ** (4 * 8192),

    // RTC live registers (ticking)
    rtc_s: u8 = 0,
    rtc_m: u8 = 0,
    rtc_h: u8 = 0,
    rtc_dl: u8 = 0,
    rtc_dh: u8 = 0, // bit 0 = day counter MSB, bit 6 = halt, bit 7 = day overflow

    // RTC latched registers (snapshot when latch triggered)
    latched_s: u8 = 0,
    latched_m: u8 = 0,
    latched_h: u8 = 0,
    latched_dl: u8 = 0,
    latched_dh: u8 = 0,

    // Latch state: need 0x00 then 0x01 write to latch
    latch_ready: bool = false,

    // Sub-second counter: counts CPU T-cycles (4194304 per second)
    rtc_cycles: u32 = 0,

    // Timestamp of last save (for calculating elapsed time on load)
    rtc_timestamp: i64 = 0,

    const CYCLES_PER_SECOND: u32 = 4194304;

    pub fn init(rom_size: usize) Mbc3 {
        const bank_count: u16 = @intCast(@max(2, rom_size / 0x4000));
        return Mbc3{ .rom_bank_count = bank_count, .rtc_timestamp = std.time.timestamp() };
    }

    /// Advance RTC by the given number of T-cycles
    pub fn tick_rtc(self: *Mbc3, t_cycles: u32) void {
        // Don't tick if halted
        if (self.rtc_dh & 0x40 != 0) return;

        self.rtc_cycles += t_cycles;
        while (self.rtc_cycles >= CYCLES_PER_SECOND) {
            self.rtc_cycles -= CYCLES_PER_SECOND;
            self.increment_rtc_second();
        }
    }

    fn increment_rtc_second(self: *Mbc3) void {
        self.rtc_s +%= 1;
        if (self.rtc_s < 60) return;
        self.rtc_s = 0;

        self.rtc_m +%= 1;
        if (self.rtc_m < 60) return;
        self.rtc_m = 0;

        self.rtc_h +%= 1;
        if (self.rtc_h < 24) return;
        self.rtc_h = 0;

        // Increment 9-bit day counter (DL = low 8, DH bit 0 = high bit)
        var days: u16 = @as(u16, self.rtc_dl) | (@as(u16, self.rtc_dh & 1) << 8);
        days +%= 1;
        if (days > 511) {
            days = 0;
            self.rtc_dh |= 0x80; // set day overflow flag
        }
        self.rtc_dl = @truncate(days & 0xFF);
        self.rtc_dh = (self.rtc_dh & 0xFE) | @as(u8, @truncate((days >> 8) & 1));
    }

    /// Apply elapsed real-world seconds to RTC (used when loading save)
    pub fn advance_rtc_seconds(self: *Mbc3, seconds: u64) void {
        if (self.rtc_dh & 0x40 != 0) return; // halted
        var remaining = seconds;
        while (remaining > 0) : (remaining -= 1) {
            self.increment_rtc_second();
        }
    }

    fn latch_rtc(self: *Mbc3) void {
        self.latched_s = self.rtc_s;
        self.latched_m = self.rtc_m;
        self.latched_h = self.rtc_h;
        self.latched_dl = self.rtc_dl;
        self.latched_dh = self.rtc_dh;
    }

    pub fn read_rom(self: *Mbc3, rom: []const u8, address: u16) u8 {
        switch (address) {
            0x0000...0x3FFF => return rom[address],
            0x4000...0x7FFF => {
                const bank: u32 = @as(u32, self.rom_bank) % self.rom_bank_count;
                const offset = bank * 0x4000 + (address - 0x4000);
                if (offset < rom.len) return rom[offset];
                return 0xFF;
            },
            else => return 0xFF,
        }
    }

    pub fn read_ram(self: *Mbc3, address: u16) u8 {
        if (!self.ram_enabled) return 0xFF;
        if (self.ram_bank <= 0x03) {
            const offset = @as(u32, self.ram_bank) * 0x2000 + (address - 0xA000);
            if (offset < self.ram.len) return self.ram[offset];
            return 0xFF;
        }
        // RTC register read — returns latched values
        return switch (self.ram_bank) {
            0x08 => self.latched_s,
            0x09 => self.latched_m,
            0x0A => self.latched_h,
            0x0B => self.latched_dl,
            0x0C => self.latched_dh,
            else => 0xFF,
        };
    }

    pub fn write_rom(self: *Mbc3, address: u16, value: u8) void {
        switch (address) {
            0x0000...0x1FFF => {
                self.ram_enabled = (value & 0x0F) == 0x0A;
            },
            0x2000...0x3FFF => {
                var bank = value & 0x7F;
                if (bank == 0) bank = 1;
                self.rom_bank = bank;
            },
            0x4000...0x5FFF => {
                self.ram_bank = value;
            },
            0x6000...0x7FFF => {
                // RTC latch: write 0x00 then 0x01 to latch current time
                if (value == 0x00) {
                    self.latch_ready = true;
                } else if (value == 0x01 and self.latch_ready) {
                    self.latch_rtc();
                    self.latch_ready = false;
                } else {
                    self.latch_ready = false;
                }
            },
            else => {},
        }
    }

    pub fn write_ram(self: *Mbc3, address: u16, value: u8) void {
        if (!self.ram_enabled) return;
        if (self.ram_bank <= 0x03) {
            const offset = @as(u32, self.ram_bank) * 0x2000 + (address - 0xA000);
            if (offset < self.ram.len) self.ram[offset] = value;
        } else {
            // RTC register write — writes to live registers
            switch (self.ram_bank) {
                0x08 => {
                    self.rtc_s = value & 0x3F;
                    self.rtc_cycles = 0; // reset sub-second counter
                },
                0x09 => self.rtc_m = value & 0x3F,
                0x0A => self.rtc_h = value & 0x1F,
                0x0B => self.rtc_dl = value,
                0x0C => self.rtc_dh = value & 0xC1, // only bits 0, 6, 7 are meaningful
                else => {},
            }
        }
    }

    /// Get RTC state as 48 bytes for save file (compatible with VBA/BGB format)
    /// Format: 5 × u32 current regs + 5 × u32 latched regs + i64 timestamp
    pub fn get_rtc_save_data(self: *Mbc3) [48]u8 {
        var buf: [48]u8 = .{0} ** 48;
        // Current registers (little-endian u32 each)
        std.mem.writeInt(u32, buf[0..4], self.rtc_s, .little);
        std.mem.writeInt(u32, buf[4..8], self.rtc_m, .little);
        std.mem.writeInt(u32, buf[8..12], self.rtc_h, .little);
        std.mem.writeInt(u32, buf[12..16], self.rtc_dl, .little);
        std.mem.writeInt(u32, buf[16..20], self.rtc_dh, .little);
        // Latched registers
        std.mem.writeInt(u32, buf[20..24], self.latched_s, .little);
        std.mem.writeInt(u32, buf[24..28], self.latched_m, .little);
        std.mem.writeInt(u32, buf[28..32], self.latched_h, .little);
        std.mem.writeInt(u32, buf[32..36], self.latched_dl, .little);
        std.mem.writeInt(u32, buf[36..40], self.latched_dh, .little);
        // Unix timestamp
        const ts: i64 = std.time.timestamp();
        std.mem.writeInt(i64, buf[40..48], ts, .little);
        return buf;
    }

    /// Load RTC state from save file data and advance by elapsed real time
    pub fn load_rtc_save_data(self: *Mbc3, data: []const u8) void {
        if (data.len < 48) return;
        self.rtc_s = @truncate(std.mem.readInt(u32, data[0..4], .little));
        self.rtc_m = @truncate(std.mem.readInt(u32, data[4..8], .little));
        self.rtc_h = @truncate(std.mem.readInt(u32, data[8..12], .little));
        self.rtc_dl = @truncate(std.mem.readInt(u32, data[12..16], .little));
        self.rtc_dh = @truncate(std.mem.readInt(u32, data[16..20], .little));
        self.latched_s = @truncate(std.mem.readInt(u32, data[20..24], .little));
        self.latched_m = @truncate(std.mem.readInt(u32, data[24..28], .little));
        self.latched_h = @truncate(std.mem.readInt(u32, data[28..32], .little));
        self.latched_dl = @truncate(std.mem.readInt(u32, data[32..36], .little));
        self.latched_dh = @truncate(std.mem.readInt(u32, data[36..40], .little));
        const saved_ts = std.mem.readInt(i64, data[40..48], .little);
        // Advance RTC by elapsed real-world time since save
        const now = std.time.timestamp();
        if (now > saved_ts) {
            const elapsed: u64 = @intCast(now - saved_ts);
            self.advance_rtc_seconds(elapsed);
        }
        self.rtc_timestamp = now;
    }
};

// ============================================================
// MBC5 — up to 8MB ROM / 128KB RAM
// ============================================================
const Mbc5 = struct {
    rom_bank_lo: u8 = 1,
    rom_bank_hi: u1 = 0,
    ram_bank: u8 = 0,
    ram_enabled: bool = false,
    rom_bank_count: u16,
    ram: [16 * 8192]u8 = .{0} ** (16 * 8192), // 16 banks × 8KB

    pub fn init(rom_size: usize) Mbc5 {
        const bank_count: u16 = @intCast(@max(2, rom_size / 0x4000));
        return Mbc5{ .rom_bank_count = bank_count };
    }

    pub fn read_rom(self: *Mbc5, rom: []const u8, address: u16) u8 {
        switch (address) {
            0x0000...0x3FFF => return rom[address],
            0x4000...0x7FFF => {
                const bank: u32 = (@as(u32, self.rom_bank_hi) << 8) | @as(u32, self.rom_bank_lo);
                const effective_bank = bank % self.rom_bank_count;
                const offset = effective_bank * 0x4000 + (address - 0x4000);
                if (offset < rom.len) return rom[offset];
                return 0xFF;
            },
            else => return 0xFF,
        }
    }

    pub fn read_ram(self: *Mbc5, address: u16) u8 {
        if (!self.ram_enabled) return 0xFF;
        const offset = @as(u32, self.ram_bank) * 0x2000 + (address - 0xA000);
        if (offset < self.ram.len) return self.ram[offset];
        return 0xFF;
    }

    pub fn write_rom(self: *Mbc5, address: u16, value: u8) void {
        switch (address) {
            0x0000...0x1FFF => {
                self.ram_enabled = (value & 0x0F) == 0x0A;
            },
            0x2000...0x2FFF => {
                self.rom_bank_lo = value;
            },
            0x3000...0x3FFF => {
                self.rom_bank_hi = @truncate(value & 0x01);
            },
            0x4000...0x5FFF => {
                self.ram_bank = value & 0x0F;
            },
            else => {},
        }
    }

    pub fn write_ram(self: *Mbc5, address: u16, value: u8) void {
        if (!self.ram_enabled) return;
        const offset = @as(u32, self.ram_bank) * 0x2000 + (address - 0xA000);
        if (offset < self.ram.len) self.ram[offset] = value;
    }
};
