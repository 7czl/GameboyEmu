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
    // CGB object priority mode: true = by OAM position (CGB default), false = by X coordinate (DMG compat)
    obj_priority_by_oam: bool = true,
    // CGB double speed
    double_speed: bool = false,
    speed_switch_armed: bool = false, // KEY1 bit 0
    // CGB HDMA
    hdma_src: u16 = 0,
    hdma_dst: u16 = 0,
    hdma_length: u8 = 0xFF, // $FF55 — remaining length (0xFF = inactive)
    hdma_active: bool = false, // true = HBlank DMA in progress
    // Battery-backed RAM dirty flag — set when external RAM is written
    ram_dirty: bool = false,
    // OAM DMA state
    oam_dma_active: bool = false,
    oam_dma_byte: u8 = 0, // current byte being transferred (0-159)
    oam_dma_source: u16 = 0, // source base address
    oam_dma_restarting: bool = false, // DMA restart pending
    oam_dma_restart_source: u16 = 0, // source for restart
    oam_dma_delay: u8 = 0, // setup delay cycles before transfer starts
    oam_dma_bus_conflict: bool = false, // true when OAM bus is blocked by DMA

    pub const Interrupt = enum(u8) {
        VBlank = 1 << 0,
        LCD_STAT = 1 << 1,
        Timer = 1 << 2,
        Serial = 1 << 3,
        Joypad = 1 << 4,
    };

    pub fn init(rom: []const u8, boot_rom: []const u8, timer_ptr: *Timer, ppu_ptr: *Ppu, joypad_ptr: *Joypad, apu_ptr: *Apu, force_dmg: bool) Bus {
        const cart_type = if (rom.len > 0x147) rom[0x147] else 0;
        const mbc = Mbc.from_cartridge_type(cart_type, rom.len);
        std.log.info("MBC: cartridge type=0x{X:0>2}, using {s}", .{
            cart_type,
            switch (mbc) {
                .none => "NoMbc",
                .mbc1 => "MBC1",
                .mbc2 => "MBC2",
                .mbc3 => "MBC3",
                .mbc5 => "MBC5",
            },
        });
        // Detect CGB mode from ROM header byte 0x143
        const cgb_flag = if (rom.len > 0x143) rom[0x143] else 0;
        const cgb_mode = if (force_dmg) false else (cgb_flag == 0x80 or cgb_flag == 0xC0);
        if (force_dmg) {
            std.log.info("Forced DMG mode (--dmg)", .{});
        } else if (cgb_mode) {
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
        // During OAM DMA transfer, OAM reads return $FF (bus conflict)
        if (self.oam_dma_bus_conflict and address >= 0xFE00 and address <= 0xFE9F) {
            return 0xFF;
        }
        // PPU blocks OAM access during mode 2 (OAM scan) and mode 3 (Drawing)
        // Also blocks OAM 4 dots before scanline boundary (cc >= 452 in HBlank/VBlank)
        // when the next mode will be OAM scan — this is the "early OAM lock".
        if (address >= 0xFE00 and address <= 0xFE9F and self.ppu.enabled) {
            const mode = @intFromEnum(self.ppu.mode);
            if (mode == 2 or mode == 3) {
                return 0xFF;
            }
            // Early OAM lock: 4 dots before scanline boundary
            if ((mode == 0 or mode == 1) and self.ppu.cycle_counter >= 452) {
                // In HBlank: next mode is OAM scan (if ly < 144) or VBlank
                // In VBlank on last line: next mode is OAM scan for line 0
                if (mode == 0 and self.ppu.ly < 144) return 0xFF;
                if (mode == 1 and self.ppu.ly == 0) return 0xFF;
            }
        }
        // PPU blocks VRAM access during mode 3 (Drawing)
        // Also early VRAM lock: 4 dots before Drawing transition (cc >= 76 in OAM scan)
        if (address >= 0x8000 and address <= 0x9FFF and self.ppu.enabled) {
            if (self.ppu.mode == .Drawing) return 0xFF;
            if (self.ppu.mode == .OAMScan and self.ppu.cycle_counter >= 76) return 0xFF;
        }
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
            0xFF04 => {
                // In CGB double speed, DIV counter runs at 2x CPU clock,
                // so shift right by 9 instead of 8 to maintain same wall-clock rate
                if (self.double_speed) {
                    return @truncate(self.timer.div_counter >> 9);
                }
                return @truncate(self.timer.div_counter >> 8);
            },
            0xFF05 => return self.timer.tima,
            0xFF06 => return self.timer.tma,
            0xFF07 => return self.timer.tac | 0xF8, // bits 3-7 unused, read as 1,
            0xFF0F => return self.interrupt_flag | 0xE0,
            0xFF10...0xFF3F => return self.apu.read(address),
            // Unmapped IO registers return $FF
            0xFF03, 0xFF08...0xFF0E => return 0xFF,
            0xFF01 => return self.io_registers[0x01],
            0xFF02 => return self.io_registers[0x02] | 0x7E, // bits 1-6 unused, read as 1,
            0xFF40 => return self.ppu.lcdc,
            0xFF41 => return self.ppu.stat | 0x80, // bit 7 unused, reads as 1
            0xFF42 => return self.ppu.scy,
            0xFF43 => return self.ppu.scx,
            0xFF44 => {
                return self.ppu.ly;
            },
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
            0xFF6C => { // OPRI — Object priority mode
                if (!self.cgb_mode) return 0xFF;
                return if (self.obj_priority_by_oam) @as(u8, 0xFE) else @as(u8, 0xFF);
            },
            0xFF70 => { // SVBK — WRAM bank
                if (!self.cgb_mode) return 0xFF;
                return @as(u8, self.wram_bank) | 0xF8;
            },
            else => {
                const offset = address - 0xFF00;
                // On DMG, CGB-only registers ($FF4C-$FF7F) return $FF
                if (!self.cgb_mode and address >= 0xFF4C and address <= 0xFF7F) {
                    return 0xFF;
                }
                if (offset < self.io_registers.len) {
                    return self.io_registers[offset];
                }
                return 0xFF;
            },
        }
    }

    pub fn write(self: *Bus, address: u16, value: u8) void {
        // During OAM DMA transfer, OAM writes are blocked
        if (self.oam_dma_bus_conflict and address >= 0xFE00 and address <= 0xFE9F) {
            return;
        }
        // PPU blocks OAM writes during mode 2 (OAM scan) and mode 3 (Drawing)
        // Exception: OAM writes succeed in the last 4 dots of mode 2 (cc >= 76)
        if (address >= 0xFE00 and address <= 0xFE9F and self.ppu.enabled) {
            const mode = @intFromEnum(self.ppu.mode);
            if (mode == 3) return;
            if (mode == 2 and self.ppu.cycle_counter < 76) return;
        }
        // PPU blocks VRAM writes during mode 3 (Drawing)
        if (address >= 0x8000 and address <= 0x9FFF and self.ppu.enabled) {
            if (self.ppu.mode == .Drawing) return;
        }
        switch (address) {
            0x0000...0x7FFF => self.mbc.write_rom(address, value),
            0x8000...0x9FFF => self.vram[self.vram_bank][address - 0x8000] = value,
            0xA000...0xBFFF => {
                self.mbc.write_ram(address, value);
                self.ram_dirty = true;
            },
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
                self.timer.write_div();
            },
            0xFF05 => {
                self.timer.write_tima(value);
            },
            0xFF06 => {
                self.timer.write_tma(value);
            },
            0xFF07 => {
                self.timer.write_tac(value);
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
                    // LCD turn-on: line 0 starts in mode 0 (HBlank) and goes
                    // straight to mode 3 (Drawing) at dot 80, skipping mode 2.
                    self.ppu.mode = .HBlank;
                    self.ppu.stat = (self.ppu.stat & 0xFC) | 0; // mode 0 = HBlank
                    self.ppu.cycle_counter = 0;
                    self.ppu.lcd_just_enabled = true;
                    self.ppu.ly = 0;
                    // Check WY condition on line 0
                    if (self.ppu.wy == 0) {
                        self.ppu.wy_latch = true;
                    }
                    // Perform LYC comparison
                    self.ppu.check_lyc(self);
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
            0xFF44 => {
                self.ppu.ly = 0;
                // Only update LYC comparison if PPU is enabled
                if (self.ppu.enabled) self.ppu.check_lyc(self);
            },
            0xFF45 => {
                self.ppu.lyc = value;
                // Only update LYC comparison if PPU is enabled
                if (self.ppu.enabled) self.ppu.check_lyc(self);
            },
            0xFF46 => {
                self.dma_transfer(value);
                self.io_registers[0x46] = value; // Store for readback
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
            0xFF6C => { // OPRI — Object priority mode
                if (self.cgb_mode) {
                    self.obj_priority_by_oam = (value & 0x01) == 0;
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
        // OAM DMA: starts transferring 1 byte per M-cycle after a 2 M-cycle delay.
        // Timing from FF46 write:
        //   M+0: write happens (tick after write decrements delay)
        //   M+1: OAM still accessible (delay > 0)
        //   M+2: DMA active, OAM reads return $FF
        // Total: 160 M-cycles (640 T-cycles) of transfer + 2 M-cycle setup.
        const source_start_addr = @as(u16, source_prefix) << 8;
        if (self.oam_dma_active) {
            // Restarting DMA while one is in progress.
            // The old DMA keeps running (OAM stays blocked) until the new one
            // actually starts after a 2 M-cycle delay from this write.
            self.oam_dma_restarting = true;
            self.oam_dma_restart_source = source_start_addr;
        } else {
            self.oam_dma_active = true;
            self.oam_dma_source = source_start_addr;
            self.oam_dma_byte = 0;
            self.oam_dma_delay = 2; // 2 M-cycle setup delay before first transfer
        }
    }

    /// Read a byte for OAM DMA (bypasses bus conflict logic).
    /// DMA uses the external bus, so $FE00-$FFFF maps to echo RAM,
    /// not to OAM, IO registers, or HRAM.
    fn dma_read(self: *Bus, address: u16) u8 {
        return switch (address) {
            0x0000...0x7FFF => if (self.boot_rom_active and address <= 0xFF)
                self.boot_rom[address]
            else
                self.mbc.read_rom(self.rom, address),
            0x8000...0x9FFF => self.vram[self.vram_bank][address - 0x8000],
            0xA000...0xBFFF => self.mbc.read_ram(address),
            0xC000...0xCFFF => self.wram[0][address - 0xC000],
            0xD000...0xDFFF => self.wram[self.wram_bank][address - 0xD000],
            0xE000...0xEFFF => self.wram[0][address - 0xE000],
            // $F000-$FFFF: echo RAM maps to WRAM switchable bank
            0xF000...0xFFFF => self.wram[self.wram_bank][address - 0xF000],
        };
    }

    /// Tick OAM DMA by one M-cycle (4 T-cycles). Called from CPU tick.
    pub fn tick_oam_dma(self: *Bus) void {
        if (!self.oam_dma_active) return;

        // Handle restart: previous DMA was running so bus conflict stays active.
        // We just reset the transfer to start from the new source after a delay.
        // Use delay=1 (not 2) because the restart handler tick itself acts as
        // the first delay cycle — fresh DMA gets delay=2 decremented to 1 in
        // the same write_tick, but restart consumes this tick in the handler.
        if (self.oam_dma_restarting) {
            self.oam_dma_restarting = false;
            self.oam_dma_source = self.oam_dma_restart_source;
            self.oam_dma_byte = 0;
            self.oam_dma_delay = 1;
            // bus_conflict stays true — old DMA was already blocking OAM
            return;
        }

        // Setup delay before first transfer
        if (self.oam_dma_delay > 0) {
            self.oam_dma_delay -= 1;
            if (self.oam_dma_delay == 0) {
                // Delay just expired — OAM bus is now blocked
                self.oam_dma_bus_conflict = true;
            }
            return;
        }

        if (self.oam_dma_byte < 160) {
            const src_addr = self.oam_dma_source +% @as(u16, self.oam_dma_byte);
            self.oam[self.oam_dma_byte] = self.dma_read(src_addr);
            self.oam_dma_byte += 1;
        }

        if (self.oam_dma_byte >= 160) {
            self.oam_dma_active = false;
            self.oam_dma_bus_conflict = false;
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

    // --- DMG OAM Corruption Bug ---
    // On DMG hardware, certain 16-bit register operations touching the OAM
    // range ($FE00-$FEFF) during PPU mode 2 (OAM scan) corrupt OAM data.
    // CGB/AGB hardware is not affected.

    /// Read a 16-bit word from OAM at the given byte offset.
    fn oam_read_word(self: *Bus, offset: usize) u16 {
        return @as(u16, self.oam[offset + 1]) << 8 | self.oam[offset];
    }

    /// Write a 16-bit word to OAM at the given byte offset.
    fn oam_write_word(self: *Bus, offset: usize, val: u16) void {
        self.oam[offset] = @truncate(val);
        self.oam[offset + 1] = @truncate(val >> 8);
    }

    /// Returns the OAM row (0-19) currently being accessed by the PPU,
    /// or null if the PPU is not in OAM scan mode.
    fn oam_scan_row(self: *Bus) ?usize {
        if (!self.ppu.enabled) return null;
        if (self.ppu.mode != .OAMScan) return null;
        if (self.ppu.cycle_counter > 79) return null;
        // PPU reads one OAM row per M-cycle (4 T-cycles).
        // cycle_counter 0-3 = row 0, 4-7 = row 1, etc.
        return @as(usize, @intCast(self.ppu.cycle_counter)) / 4;
    }

    /// Apply write corruption to the given OAM row.
    /// row[0] = ((a ^ c) & (b ^ c)) ^ c; row[1..3] copied from preceding row.
    fn oam_write_corruption(self: *Bus, row: usize) void {
        if (row == 0) return; // first row (sprites 1&2) unaffected
        const cur = row * 8;
        const prev = (row - 1) * 8;
        const a = self.oam_read_word(cur);
        const b = self.oam_read_word(prev);
        const c = self.oam_read_word(prev + 4);
        self.oam_write_word(cur, ((a ^ c) & (b ^ c)) ^ c);
        // Copy last 3 words from preceding row
        self.oam_write_word(cur + 2, self.oam_read_word(prev + 2));
        self.oam_write_word(cur + 4, self.oam_read_word(prev + 4));
        self.oam_write_word(cur + 6, self.oam_read_word(prev + 6));
    }

    /// Apply read corruption to the given OAM row.
    /// row[0] = b | (a & c); row[1..3] copied from preceding row.
    fn oam_read_corruption(self: *Bus, row: usize) void {
        if (row == 0) return;
        const cur = row * 8;
        const prev = (row - 1) * 8;
        const a = self.oam_read_word(cur);
        const b = self.oam_read_word(prev);
        const c = self.oam_read_word(prev + 4);
        self.oam_write_word(cur, b | (a & c));
        self.oam_write_word(cur + 2, self.oam_read_word(prev + 2));
        self.oam_write_word(cur + 4, self.oam_read_word(prev + 4));
        self.oam_write_word(cur + 6, self.oam_read_word(prev + 6));
    }

    /// Apply the "read during increase/decrease" corruption pattern.
    /// This is the complex pattern triggered by INC/DEC rr when rr is in OAM.
    fn oam_inc_dec_corruption(self: *Bus, row: usize) void {
        // Complex corruption only for rows 4-18 (not first four, not last)
        if (row >= 4 and row < 19) {
            const cur = row * 8;
            const prev = (row - 1) * 8;
            const prev2 = (row - 2) * 8;
            const a = self.oam_read_word(prev2); // two rows before
            const b = self.oam_read_word(prev); // preceding row (being corrupted)
            const c = self.oam_read_word(cur); // current row
            const d = self.oam_read_word(prev + 4); // third word of preceding row
            self.oam_write_word(prev, (b & (a | c | d)) | (a & c & d));
            // Copy preceding row (after corruption) to current row and two rows before
            var i: usize = 0;
            while (i < 8) : (i += 2) {
                const val = self.oam_read_word(prev + i);
                self.oam_write_word(cur + i, val);
                self.oam_write_word(prev2 + i, val);
            }
        }
        // Always apply normal read corruption (rows 1+)
        self.oam_read_corruption(row);
    }

    /// Called by CPU for INC rr / DEC rr when rr is in OAM range.
    /// "Write During Increase/Decrease" — behaves like a single write corruption.
    pub fn oam_bug_inc_dec(self: *Bus, addr: u16) void {
        if (self.cgb_mode) return;
        if (addr < 0xFE00 or addr > 0xFEFF) return;
        const row = self.oam_scan_row() orelse return;
        self.oam_write_corruption(row);
    }

    /// Called by CPU for ld a,[hli] / ld a,[hld] when HL is in OAM range.
    /// "Read During Increase/Decrease" — the read from OAM triggers read
    /// corruption, and the HL increment/decrement triggers write corruption.
    pub fn oam_bug_read_inc_dec(self: *Bus, addr: u16) void {
        if (self.cgb_mode) return;
        if (addr < 0xFE00 or addr > 0xFEFF) return;
        const row = self.oam_scan_row() orelse return;
        self.oam_write_corruption(row);
        self.oam_read_corruption(row);
    }

    /// Called by CPU for POP rr: each byte read involves a read + SP increment
    /// in the same M-cycle, similar to LDI/LDD. This triggers the complex
    /// "read during increase" corruption pattern.
    pub fn oam_bug_pop(self: *Bus, addr: u16) void {
        if (self.cgb_mode) return;
        if (addr < 0xFE00 or addr > 0xFEFF) return;
        const row = self.oam_scan_row() orelse return;
        self.oam_inc_dec_corruption(row);
    }

    /// Called by CPU for PUSH rr / CALL / RST when SP is in OAM range.
    /// Triggers effectively 3 write corruptions (4 total but one overlaps).
    pub fn oam_bug_push(self: *Bus, addr: u16) void {
        if (self.cgb_mode) return;
        if (addr < 0xFE00 or addr > 0xFEFF) return;
        const row = self.oam_scan_row() orelse return;
        self.oam_write_corruption(row);
        self.oam_write_corruption(row);
        self.oam_write_corruption(row);
    }

    /// Called by CPU when OAM is read during mode 2. DMG only.
    pub fn oam_bug_read(self: *Bus) void {
        if (self.cgb_mode) return;
        const row = self.oam_scan_row() orelse return;
        self.oam_read_corruption(row);
    }

    /// Called by CPU when OAM is written during mode 2. DMG only.
    pub fn oam_bug_write(self: *Bus) void {
        if (self.cgb_mode) return;
        const row = self.oam_scan_row() orelse return;
        self.oam_write_corruption(row);
    }
};
