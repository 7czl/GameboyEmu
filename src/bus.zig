const Timer = @import("timer.zig").Timer;
const std = @import("std");
const Ppu = @import("ppu.zig").Ppu;
const Mbc = @import("mbc.zig").Mbc;
const Joypad = @import("joypad.zig").Joypad;
const Apu = @import("apu.zig").Apu;
pub const Bus = struct {
    rom: []const u8,
    boot_rom: []const u8,
    boot_rom_active: bool = true,
    // CGB: 2 VRAM banks × 8KB
    vram: [2][8192]u8,
    vram_bank: u1 = 0,
    // CGB: 8 WRAM banks × 4KB (bank 0 always at $C000, bank 1-7 switchable at $D000)
    wram: [8][4096]u8,
    wram_bank: u3 = 1, // writing 0 selects bank 1
    timer: *Timer,
    ppu: *Ppu,
    apu: *Apu,
    mbc: Mbc,
    joypad: *Joypad,
    joypad_select: u8 = 0x30,
    oam: [160]u8,
    io_registers: [128]u8,
    hram: [127]u8,
    interrupt_enable_register: u8,
    interrupt_flag: u8 = 0,
    // CGB mode
    cgb_mode: bool = false,
    // CGB color palette RAM
    bg_cram: [64]u8,
    obj_cram: [64]u8,
    bg_cram_index: u8 = 0, // BCPS ($FF68) — bit 0-5: index, bit 7: auto-increment
    obj_cram_index: u8 = 0, // OCPS ($FF6A)
    // CGB double speed
    double_speed: bool = false,
    speed_switch_armed: bool = false, // KEY1 bit 0
    // CGB HDMA
    hdma_src: u16 = 0,
    hdma_dst: u16 = 0,
    hdma_length: u8 = 0xFF, // $FF55 — remaining length (0xFF = inactive)
    hdma_active: bool = false, // true = HBlank DMA in progress

    pub const Interrupt = enum(u8) {
        VBlank = 1 << 0,
        LCD_STAT = 1 << 1,
        Timer = 1 << 2,
        Serial = 1 << 3,
        Joypad = 1 << 4,
    };

    pub fn init(rom: []const u8, boot_rom: []const u8, timer_ptr: *Timer, ppu_ptr: *Ppu, joypad_ptr: *Joypad, apu_ptr: *Apu) Bus {
        const cart_type = if (rom.len > 0x147) rom[0x147] else 0;
        const mbc = Mbc.from_cartridge_type(cart_type, rom.len);
        std.log.info("MBC: cartridge type=0x{X:0>2}, using {s}", .{
            cart_type,
            switch (mbc) {
                .none => "NoMbc",
                .mbc1 => "MBC1",
                .mbc3 => "MBC3",
                .mbc5 => "MBC5",
            },
        });
        // Detect CGB mode from ROM header byte 0x143
        const cgb_flag = if (rom.len > 0x143) rom[0x143] else 0;
        const cgb_mode = (cgb_flag == 0x80 or cgb_flag == 0xC0);
        if (cgb_mode) {
            std.log.info("CGB mode detected (flag=0x{X:0>2})", .{cgb_flag});
        }
        return Bus{
            .rom = rom,
            .boot_rom = boot_rom,
            .vram = .{ .{0} ** 8192, .{0} ** 8192 },
            .vram_bank = 0,
            .wram = .{.{0} ** 4096} ** 8,
            .wram_bank = 1,
            .timer = timer_ptr,
            .ppu = ppu_ptr,
            .apu = apu_ptr,
            .mbc = mbc,
            .joypad = joypad_ptr,
            .oam = .{0} ** 160,
            .io_registers = .{0} ** 128,
            .hram = .{0} ** 127,
            .interrupt_enable_register = 0,
            .interrupt_flag = 0,
            .cgb_mode = cgb_mode,
            .bg_cram = .{0xFF} ** 64,
            .obj_cram = .{0xFF} ** 64,
            .bg_cram_index = 0,
            .obj_cram_index = 0,
            .double_speed = false,
            .speed_switch_armed = false,
            .hdma_src = 0,
            .hdma_dst = 0,
            .hdma_length = 0xFF,
            .hdma_active = false,
        };
    }

    pub fn read(self: *Bus, address: u16) u8 {
        switch (address) {
            0x0000...0x00FF => if (self.boot_rom_active) return self.boot_rom[address] else return self.mbc.read_rom(self.rom, address),
            0x0100...0x7FFF => return self.mbc.read_rom(self.rom, address),
            0x8000...0x9FFF => return self.vram[self.vram_bank][address - 0x8000],
            0xA000...0xBFFF => return self.mbc.read_ram(address),
            0xC000...0xCFFF => return self.wram[0][address - 0xC000],
            0xD000...0xDFFF => return self.wram[self.wram_bank][address - 0xD000],
            0xE000...0xEFFF => return self.wram[0][address - 0xE000],
            0xF000...0xFDFF => return self.wram[self.wram_bank][address - 0xF000],
            0xFE00...0xFE9F => return self.oam[address - 0xFE00],
            0xFEA0...0xFEFF => return 0xFF,
            0xFF80...0xFFFE => return self.hram[address - 0xFF80],
            0xFFFF => return self.interrupt_enable_register,
            0xFF00...0xFF7F => {
                return self.read_io(address);
            },
        }
    }

    fn read_io(self: *Bus, address: u16) u8 {
        switch (address) {
            0xFF00 => return self.joypad.read(self.joypad_select),
            0xFF04 => return @truncate(self.timer.div_counter >> 8),
            0xFF05 => return self.timer.tima,
            0xFF06 => return self.timer.tma,
            0xFF07 => return self.timer.tac,
            0xFF0F => return self.interrupt_flag | 0xE0,
            0xFF10...0xFF3F => return self.apu.read(address),
            0xFF01 => return self.io_registers[0x01],
            0xFF02 => return self.io_registers[0x02],
            0xFF40 => return self.ppu.lcdc,
            0xFF41 => return self.ppu.stat,
            0xFF42 => return self.ppu.scy,
            0xFF43 => return self.ppu.scx,
            0xFF44 => return self.ppu.ly,
            0xFF45 => return self.ppu.lyc,
            0xFF47 => return self.ppu.bgp,
            0xFF48 => return self.ppu.obp0,
            0xFF49 => return self.ppu.obp1,
            0xFF4A => return self.ppu.wy,
            0xFF4B => return self.ppu.wx,
            // CGB registers
            0xFF4D => { // KEY1 — speed switch
                if (!self.cgb_mode) return 0xFF;
                return (@as(u8, if (self.double_speed) 0x80 else 0x00)) | (if (self.speed_switch_armed) @as(u8, 0x01) else @as(u8, 0x00)) | 0x7E;
            },
            0xFF4F => { // VBK — VRAM bank
                if (!self.cgb_mode) return 0xFF;
                return @as(u8, self.vram_bank) | 0xFE;
            },
            0xFF51...0xFF54 => return 0xFF, // HDMA src/dst (write-only)
            0xFF55 => { // HDMA5 — HDMA length/mode/start
                if (!self.cgb_mode) return 0xFF;
                if (self.hdma_active) {
                    return self.hdma_length & 0x7F; // bit 7 = 0 means active
                } else {
                    return 0xFF; // bit 7 = 1 means inactive
                }
            },
            0xFF68 => { // BCPS — BG palette index
                if (!self.cgb_mode) return 0xFF;
                return self.bg_cram_index;
            },
            0xFF69 => { // BCPD — BG palette data
                if (!self.cgb_mode) return 0xFF;
                return self.bg_cram[self.bg_cram_index & 0x3F];
            },
            0xFF6A => { // OCPS — OBJ palette index
                if (!self.cgb_mode) return 0xFF;
                return self.obj_cram_index;
            },
            0xFF6B => { // OCPD — OBJ palette data
                if (!self.cgb_mode) return 0xFF;
                return self.obj_cram[self.obj_cram_index & 0x3F];
            },
            0xFF70 => { // SVBK — WRAM bank
                if (!self.cgb_mode) return 0xFF;
                return @as(u8, self.wram_bank) | 0xF8;
            },
            else => {
                const offset = address - 0xFF00;
                if (offset < self.io_registers.len) {
                    return self.io_registers[offset];
                }
                return 0xFF;
            },
        }
    }

    pub fn write(self: *Bus, address: u16, value: u8) void {
        switch (address) {
            0x0000...0x7FFF => self.mbc.write_rom(address, value),
            0x8000...0x9FFF => self.vram[self.vram_bank][address - 0x8000] = value,
            0xA000...0xBFFF => self.mbc.write_ram(address, value),
            0xC000...0xCFFF => self.wram[0][address - 0xC000] = value,
            0xD000...0xDFFF => self.wram[self.wram_bank][address - 0xD000] = value,
            0xE000...0xEFFF => self.wram[0][address - 0xE000] = value,
            0xF000...0xFDFF => self.wram[self.wram_bank][address - 0xF000] = value,
            0xFE00...0xFE9F => self.oam[address - 0xFE00] = value,
            0xFEA0...0xFEFF => {},
            0xFF80...0xFFFE => self.hram[address - 0xFF80] = value,
            0xFFFF => self.interrupt_enable_register = value,
            0xFF00...0xFF7F => {
                self.write_io(address, value);
            },
        }
    }

    fn write_io(self: *Bus, address: u16, value: u8) void {
        switch (address) {
            0xFF00 => {
                self.joypad_select = value & 0x30;
            },
            0xFF04 => {
                self.timer.div_counter = 0;
            },
            0xFF05 => {
                self.timer.tima = value;
            },
            0xFF06 => {
                self.timer.tma = value;
            },
            0xFF07 => {
                self.timer.tac = value;
            },
            0xFF0F => {
                self.interrupt_flag = value & 0x1F;
            },
            0xFF10...0xFF3F => {
                self.apu.write(address, value);
            },
            0xFF01 => {
                self.io_registers[0x01] = value;
            },
            0xFF02 => {
                if (value == 0x81) {
                    const char = self.io_registers[0x01];
                    const stdout_file = std.fs.File.stdout();
                    stdout_file.writeAll(&[_]u8{char}) catch {};
                    self.io_registers[address - 0xFF00] = value & 0x7F;
                } else {
                    self.io_registers[address - 0xFF00] = value;
                }
            },
            0xFF40 => {
                const old_enabled = (self.ppu.lcdc & 0x80) != 0;
                self.ppu.lcdc = value;
                const new_enabled = (value & 0x80) != 0;
                if (!old_enabled and new_enabled) {
                    self.ppu.enabled = true;
                } else if (old_enabled and !new_enabled) {
                    self.ppu.reset();
                }
            },
            0xFF41 => {
                self.ppu.stat = (value & 0xF8) | (self.ppu.stat & 0x07);
                self.ppu.update_stat_irq(self);
            },
            0xFF42 => {
                self.ppu.scy = value;
            },
            0xFF43 => {
                self.ppu.scx = value;
            },
            0xFF44 => {},
            0xFF45 => {
                self.ppu.lyc = value;
            },
            0xFF46 => {
                self.dma_transfer(value);
            },
            0xFF47 => {
                self.ppu.bgp = value;
            },
            0xFF48 => {
                self.ppu.obp0 = value;
            },
            0xFF49 => {
                self.ppu.obp1 = value;
            },
            0xFF4A => {
                self.ppu.wy = value;
            },
            0xFF4B => {
                self.ppu.wx = value;
            },
            0xFF4D => { // KEY1 — speed switch arm
                if (self.cgb_mode) {
                    self.speed_switch_armed = (value & 0x01) != 0;
                }
            },
            0xFF4F => { // VBK — VRAM bank select
                if (self.cgb_mode) {
                    self.vram_bank = @truncate(value & 0x01);
                }
            },
            0xFF50 => {
                if (value != 0) {
                    self.boot_rom_active = false;
                    std.log.info("BUS: Boot ROM disabled.", .{});
                }
            },
            0xFF51 => { // HDMA1 — src high
                if (self.cgb_mode) self.hdma_src = (self.hdma_src & 0x00F0) | (@as(u16, value) << 8);
            },
            0xFF52 => { // HDMA2 — src low (lower 4 bits ignored)
                if (self.cgb_mode) self.hdma_src = (self.hdma_src & 0xFF00) | (@as(u16, value) & 0xF0);
            },
            0xFF53 => { // HDMA3 — dst high (only bits 0-4, ORed with 0x8000)
                if (self.cgb_mode) self.hdma_dst = (self.hdma_dst & 0x00F0) | (@as(u16, value & 0x1F) << 8);
            },
            0xFF54 => { // HDMA4 — dst low (lower 4 bits ignored)
                if (self.cgb_mode) self.hdma_dst = (self.hdma_dst & 0xFF00) | (@as(u16, value) & 0xF0);
            },
            0xFF55 => { // HDMA5 — start HDMA
                if (self.cgb_mode) {
                    self.start_hdma(value);
                }
            },
            0xFF68 => { // BCPS — BG palette index
                if (self.cgb_mode) self.bg_cram_index = value;
            },
            0xFF69 => { // BCPD — BG palette data
                if (self.cgb_mode) {
                    self.bg_cram[self.bg_cram_index & 0x3F] = value;
                    if (self.bg_cram_index & 0x80 != 0) {
                        self.bg_cram_index = (self.bg_cram_index & 0x80) | (((self.bg_cram_index & 0x3F) + 1) & 0x3F);
                    }
                }
            },
            0xFF6A => { // OCPS — OBJ palette index
                if (self.cgb_mode) self.obj_cram_index = value;
            },
            0xFF6B => { // OCPD — OBJ palette data
                if (self.cgb_mode) {
                    self.obj_cram[self.obj_cram_index & 0x3F] = value;
                    if (self.obj_cram_index & 0x80 != 0) {
                        self.obj_cram_index = (self.obj_cram_index & 0x80) | (((self.obj_cram_index & 0x3F) + 1) & 0x3F);
                    }
                }
            },
            0xFF70 => { // SVBK — WRAM bank select
                if (self.cgb_mode) {
                    const bank = value & 0x07;
                    self.wram_bank = if (bank == 0) 1 else @truncate(bank);
                }
            },
            else => {
                self.io_registers[address - 0xFF00] = value;
            },
        }
    }

    pub fn request_interrupt(self: *Bus, interrupt: Interrupt) void {
        self.interrupt_flag |= @intFromEnum(interrupt);
    }

    fn dma_transfer(self: *Bus, source_prefix: u8) void {
        const source_start_addr = @as(u16, source_prefix) << 8;
        for (0..160) |i| {
            const offset: u16 = @intCast(i);
            const current_source_addr: u16 = source_start_addr +% offset;
            const value = switch (current_source_addr) {
                0x0000...0x7FFF => self.mbc.read_rom(self.rom, current_source_addr),
                0x8000...0x9FFF => self.vram[self.vram_bank][current_source_addr - 0x8000],
                0xA000...0xBFFF => self.mbc.read_ram(current_source_addr),
                0xC000...0xCFFF => self.wram[0][current_source_addr - 0xC000],
                0xD000...0xDFFF => self.wram[self.wram_bank][current_source_addr - 0xD000],
                0xE000...0xFDFF => self.wram[self.wram_bank][current_source_addr - 0xE000],
                else => 0xFF,
            };
            self.oam[i] = value;
        }
    }

    /// Start HDMA transfer (General Purpose or HBlank)
    fn start_hdma(self: *Bus, value: u8) void {
        const length = ((@as(u16, value & 0x7F) + 1) * 16);
        const mode_hblank = (value & 0x80) != 0;

        if (self.hdma_active and !mode_hblank) {
            // Writing bit 7 = 0 while HBlank DMA is active cancels it
            self.hdma_active = false;
            self.hdma_length = 0xFF;
            return;
        }

        if (mode_hblank) {
            // HBlank DMA — transfer 16 bytes per HBlank
            self.hdma_length = value & 0x7F;
            self.hdma_active = true;
        } else {
            // General Purpose DMA — transfer all at once
            self.do_hdma_block(length);
            self.hdma_length = 0xFF;
            self.hdma_active = false;
        }
    }

    /// Execute one HBlank DMA block (16 bytes) — called by PPU at HBlank
    pub fn do_hblank_hdma(self: *Bus) void {
        if (!self.hdma_active) return;
        self.do_hdma_block(16);
        if (self.hdma_length == 0) {
            self.hdma_length = 0xFF;
            self.hdma_active = false;
        } else {
            self.hdma_length -= 1;
        }
    }

    /// Transfer `length` bytes from hdma_src to VRAM at hdma_dst
    fn do_hdma_block(self: *Bus, length: u16) void {
        const src_base = self.hdma_src;
        const dst_base = self.hdma_dst;
        var i: u16 = 0;
        while (i < length) : (i += 1) {
            const src_addr = src_base +% i;
            const byte = switch (src_addr) {
                0x0000...0x7FFF => self.mbc.read_rom(self.rom, src_addr),
                0xA000...0xBFFF => self.mbc.read_ram(src_addr),
                0xC000...0xCFFF => self.wram[0][src_addr - 0xC000],
                0xD000...0xDFFF => self.wram[self.wram_bank][src_addr - 0xD000],
                else => 0xFF,
            };
            const dst_addr = (0x8000 | (dst_base +% i)) & 0x9FFF;
            self.vram[self.vram_bank][dst_addr - 0x8000] = byte;
        }
        self.hdma_src +%= length;
        self.hdma_dst +%= length;
    }

    /// Read VRAM with explicit bank selection (used by PPU for CGB tile attributes)
    pub fn vram_bank_read(self: *Bus, bank: u1, address: u16) u8 {
        return self.vram[bank][address - 0x8000];
    }
};
