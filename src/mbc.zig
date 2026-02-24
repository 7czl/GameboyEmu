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
                const len = @min(data.len, m.ram.len);
                @memcpy(m.ram[0..len], data[0..len]);
            },
            .mbc5 => |*m| {
                const len = @min(data.len, m.ram.len);
                @memcpy(m.ram[0..len], data[0..len]);
            },
        }
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
    ram: [4 * 8192]u8 = .{0} ** (4 * 8192), // 4 banks × 8KB

    pub fn init(rom_size: usize) Mbc1 {
        const bank_count: u16 = @intCast(@max(2, rom_size / 0x4000));
        return Mbc1{ .rom_bank_count = bank_count };
    }

    pub fn read_rom(self: *Mbc1, rom: []const u8, address: u16) u8 {
        switch (address) {
            0x0000...0x3FFF => {
                if (self.banking_mode == 1) {
                    // In RAM banking mode, bank 0 area uses upper bits
                    const bank: u32 = (@as(u32, self.ram_bank) << 5) % self.rom_bank_count;
                    const offset = bank * 0x4000 + address;
                    if (offset < rom.len) return rom[offset];
                    return 0xFF;
                }
                return rom[address];
            },
            0x4000...0x7FFF => {
                var bank: u32 = self.rom_bank;
                bank |= @as(u32, self.ram_bank) << 5;
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
                // RAM enable: lower nibble == 0x0A enables
                self.ram_enabled = (value & 0x0F) == 0x0A;
            },
            0x2000...0x3FFF => {
                // ROM bank number (lower 5 bits)
                var bank = value & 0x1F;
                if (bank == 0) bank = 1; // Bank 0 maps to 1
                self.rom_bank = bank;
            },
            0x4000...0x5FFF => {
                // RAM bank / upper ROM bank bits
                self.ram_bank = value & 0x03;
            },
            0x6000...0x7FFF => {
                // Banking mode select
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
    // RTC registers (simplified — no latching)
    rtc_s: u8 = 0,
    rtc_m: u8 = 0,
    rtc_h: u8 = 0,
    rtc_dl: u8 = 0,
    rtc_dh: u8 = 0,

    pub fn init(rom_size: usize) Mbc3 {
        const bank_count: u16 = @intCast(@max(2, rom_size / 0x4000));
        return Mbc3{ .rom_bank_count = bank_count };
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
        // RTC register read
        return switch (self.ram_bank) {
            0x08 => self.rtc_s,
            0x09 => self.rtc_m,
            0x0A => self.rtc_h,
            0x0B => self.rtc_dl,
            0x0C => self.rtc_dh,
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
                // RTC latch — simplified, no-op for now
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
            // RTC register write
            switch (self.ram_bank) {
                0x08 => self.rtc_s = value,
                0x09 => self.rtc_m = value,
                0x0A => self.rtc_h = value,
                0x0B => self.rtc_dl = value,
                0x0C => self.rtc_dh = value,
                else => {},
            }
        }
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
