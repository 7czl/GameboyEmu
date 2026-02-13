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
    vram: [8192]u8,
    wram: [8192]u8,
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
        return Bus{
            .rom = rom,
            .boot_rom = boot_rom,
            .vram = .{0} ** 8192,
            .wram = .{0} ** 8192,
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
        };
    }

    pub fn read(self: *Bus, address: u16) u8 {
        switch (address) {
            0x0000...0x00FF => if (self.boot_rom_active) return self.boot_rom[address] else return self.mbc.read_rom(self.rom, address),
            0x0100...0x7FFF => return self.mbc.read_rom(self.rom, address),
            0x8000...0x9FFF => return self.vram[address - 0x8000],
            0xA000...0xBFFF => return self.mbc.read_ram(address),
            0xC000...0xDFFF => return self.wram[address - 0xC000],
            0xE000...0xFDFF => return self.read(address - 0x2000),
            0xFE00...0xFE9F => return self.oam[address - 0xFE00],
            0xFEA0...0xFEFF => return 0xFF,
            0xFF80...0xFFFE => return self.hram[address - 0xFF80],
            0xFFFF => return self.interrupt_enable_register,
            0xFF00...0xFF7F => {
                switch (address) {
                    0xFF00 => return self.joypad.read(self.joypad_select),
                    0xFF04 => return @truncate(self.timer.div_counter >> 8),
                    0xFF05 => return self.timer.tima,
                    0xFF06 => return self.timer.tma,
                    0xFF07 => return self.timer.tac,
                    0xFF0F => return self.interrupt_flag | 0xE0,
                    0xFF10...0xFF14, 0xFF16...0xFF19, 0xFF1A...0xFF1E, 0xFF20...0xFF26, 0xFF30...0xFF3F => return self.apu.read(address),
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
                    else => {
                        const offset = address - 0xFF00;
                        if (offset < self.io_registers.len) {
                            return self.io_registers[offset];
                        }
                        return 0xFF;
                    },
                }
            },
        }
    }

    pub fn write(self: *Bus, address: u16, value: u8) void {
        switch (address) {
            0x0000...0x7FFF => self.mbc.write_rom(address, value),
            0x8000...0x9FFF => self.vram[address - 0x8000] = value,
            0xA000...0xBFFF => self.mbc.write_ram(address, value),
            0xC000...0xDFFF => self.wram[address - 0xC000] = value,
            0xE000...0xFDFF => self.write(address - 0x2000, value),
            0xFE00...0xFE9F => self.oam[address - 0xFE00] = value,
            0xFEA0...0xFEFF => {},
            0xFF80...0xFFFE => self.hram[address - 0xFF80] = value,
            0xFFFF => self.interrupt_enable_register = value,
            0xFF00...0xFF7F => {
                switch (address) {
                    0xFF00 => {
                        self.joypad_select = value & 0x30;
                        return;
                    },
                    0xFF04 => {
                        self.timer.div_counter = 0;
                        return;
                    },
                    0xFF05 => {
                        self.timer.tima = value;
                        return;
                    },
                    0xFF06 => {
                        self.timer.tma = value;
                        return;
                    },
                    0xFF07 => {
                        self.timer.tac = value;
                        return;
                    },
                    0xFF0F => {
                        self.interrupt_flag = value & 0x1F;
                        return;
                    },
                    0xFF10...0xFF14, 0xFF16...0xFF19, 0xFF1A...0xFF1E, 0xFF20...0xFF26, 0xFF30...0xFF3F => {
                        self.apu.write(address, value);
                        return;
                    },
                    0xFF01 => {
                        self.io_registers[0x01] = value;
                        return;
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
                        return;
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
                        return;
                    },
                    0xFF41 => {
                        self.ppu.stat = (value & 0xF8) | (self.ppu.stat & 0x07);
                        return;
                    },
                    0xFF42 => {
                        self.ppu.scy = value;
                        return;
                    },
                    0xFF43 => {
                        self.ppu.scx = value;
                        return;
                    },
                    0xFF44 => {
                        return;
                    },
                    0xFF45 => {
                        self.ppu.lyc = value;
                        return;
                    },
                    0xFF46 => {
                        self.dma_transfer(value);
                        return;
                    },
                    0xFF47 => {
                        self.ppu.bgp = value;
                        return;
                    },
                    0xFF48 => {
                        self.ppu.obp0 = value;
                        return;
                    },
                    0xFF49 => {
                        self.ppu.obp1 = value;
                        return;
                    },
                    0xFF4A => {
                        self.ppu.wy = value;
                        return;
                    },
                    0xFF4B => {
                        self.ppu.wx = value;
                        return;
                    },
                    0xFF50 => {
                        if (value != 0) {
                            self.boot_rom_active = false;
                            std.log.info("BUS: Boot ROM disabled.", .{});
                        }
                        return;
                    },
                    else => {
                        self.io_registers[address - 0xFF00] = value;
                        return;
                    },
                }
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
                0x8000...0x9FFF => self.vram[current_source_addr - 0x8000],
                0xA000...0xBFFF => self.mbc.read_ram(current_source_addr),
                0xC000...0xDFFF => self.wram[current_source_addr - 0xC000],
                0xE000...0xFDFF => self.wram[current_source_addr - 0xE000],
                else => 0xFF,
            };
            self.oam[i] = value;
        }
    }
};
