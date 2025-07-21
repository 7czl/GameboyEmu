const std = @import("std");
const RomeErrpr = error{
    UnknownCartridgeType,
};
pub const RomHeader = packed struct {
    entry_point: @Vector(4, u8), // 0x100-0103
    nintendo_logo: @Vector(48, u8), // 0x104-0x133
    title: @Vector(16, u8), // 0x134-0x143
    // manufacturer_code: @Vector(4, u8), //0x13F-0x142
    new_licensee_code: @Vector(2, u8), //0x144-0x145
    sgb_flag: u8, //0x146
    cartridge_type: u8, //0x147
    rom_size: u8, // 0x148
    ram_size: u8, //ox149
    destination_code: u8, //0x14A
    old_licensee_code: u8,
    rom_version: u8,
    header_checksum: u8,
    global_checksum: u16,
    pub fn isCgb(self: *const RomHeader) bool {
        const cgb_flag = self.title[15];
        return cgb_flag == 0x80 or cgb_flag == 0xc0;
    }
    pub fn getCartridgeType(self: *const RomHeader) !CatridgeType {
        return @as(CatridgeType, @enumFromInt(self.cartridge_type));
    }
    pub fn getTitle(self: *const RomHeader) []const u8 {
        const max_len: usize = if (self.isCgb()) 11 else 16;
        const array_ptr: *const [16]u8 = @ptrCast(&self.title);
        const title_slice = array_ptr[0..max_len];
        return std.mem.trimRight(u8, title_slice[0..max_len], &[_]u8{0x00});
    }
    pub fn getRomSize(self: *const RomHeader) []const u8 {
        std.debug.print("rom size:{x}\n", .{self.rom_size});
        return switch (self.rom_size) {
            0x00 => "32KB",
            0x01 => "64KB",
            0x02 => "128KB",
            0x03 => "256KB",
            0x04 => "512KB",
            0x05 => "1MB",
            0x06 => "2MB",
            0x07 => "4MB",
            0x08 => "8MB",
            0x52 => "1.1MB",
            0x53 => "1.1MB",
            0x54 => "1.2MB",
            else => "Unknown ROM Size",
        };
    }
    pub fn printDestination(self: *const RomHeader) void {
        std.debug.print("destination: {}\n", .{self.destination_code});
    }
    pub fn printRamSize(self: *const RomHeader) void {
        std.debug.print("{0x}\n", .{self.ram_size});
    }
};

pub const CatridgeType = enum(u8) {
    ROM_ONLY = 0x00,
    MBC1 = 0x01,
    MBC1_RAM = 0x02,
    MBC1_RAM_BATTERY = 0x03,
    MBC2 = 0x05,
    MBC2_BATTERY = 0x06,
    ROM_RAM = 0x08,
    ROM_RAM_BATTERY = 0x09,
    MMM01 = 0x0B,
    MMM01_RAM = 0x0C,
    MMM01_RAM_BATTERY = 0x0D,
    MBC3_TIMER_BATTERY = 0x0F,
    MBC3_TIMER_RAM_BATTERY = 0x10,
    MBC3 = 0x11,
    MBC3_RAM = 0x12,
    MBC3_RAM_BATTERY = 0x13,
    MBC5 = 0x19,
    MBC5_RAM = 0x1A,
    MBC5_RAM_BATTERY = 0x1B,
    MBC5_RUMBLE = 0x1C,
    MBC5_RUMBLE_RAM = 0x1D,
    MBC5_RUMBLE_RAM_BATTERY = 0x1E,
    MBC6 = 0x20,
    MBC7_SENSOR_RUMBLE_RAM_BATTERY = 0x22,
    POCKET_CAMERA = 0xFC,
    BANDAI_TAMA5 = 0xFD,
    HUC3 = 0xFE,
    HUC1_RAM_BATTERY = 0xFF,
};
comptime {
    std.debug.assert(@sizeOf(RomHeader) == 80);
}
