const Timer = @import("timer.zig").Timer;
const std = @import("std");
const Ppu = @import("ppu.zig").Ppu;
pub const Bus = struct {
    rom: []const u8,
    vram: [8192]u8,
    external_ram: [8192]u8,
    wram: [8192]u8,
    timer: *Timer,
    ppu: *Ppu,
    // TODO APU
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
    pub fn init(rom: []const u8, timer_ptr: *Timer, ppu_ptr: *Ppu) Bus {
        return Bus{
            .rom = rom,
            .vram = .{0} ** 8192,
            .external_ram = .{0} ** 8192,
            .wram = .{0} ** 8192,
            .timer = timer_ptr,
            .ppu = ppu_ptr,
            .oam = .{0} ** 160,
            .io_registers = .{0} ** 128,
            .hram = .{0} ** 127,
            .interrupt_enable_register = 0,
            .interrupt_flag = 0,
        };
    }

    pub fn read(self: *Bus, address: u16) u8 {
        switch (address) {
            0x0000...0x7FFF => return self.rom[address],
            0x8000...0x9FFF => return self.vram[address - 0x8000],
            0xA000...0xBFFF => return self.external_ram[address - 0xA000],
            0xC000...0xDFFF => return self.wram[address - 0xC000],
            0xE000...0xFDFF => return self.read(address - 0x2000),
            0xFE00...0xFE9F => return self.oam[address - 0xFE00],
            0xFEA0...0xFEFF => return 0xFF,
            0xFF80...0xFFFE => return self.hram[address - 0xFF80],
            0xFFFF => return self.interrupt_enable_register,
            0xFF04 => return self.timer.div,
            0xFF05 => return self.timer.tima,
            0xFF06 => return self.timer.tma,
            0xFF07 => return self.timer.tac,
            0xFF44 => return self.ppu.ly,
            0xFF0F => return self.interrupt_flag,
            else => return self.io_registers[address - 0xFF00],
        }
    }
    pub fn write(self: *Bus, address: u16, value: u8) void {
        switch (address) {
            0x0000...0x7FFF => {}, // MBC control
            0x8000...0x9FFF => self.vram[address - 0x8000] = value,
            0xA000...0xBFFF => self.external_ram[address - 0xA000] = value,
            0xC000...0xDFFF => self.wram[address - 0xC000] = value,
            0xE000...0xFDFF => self.write(address - 0x2000, value),
            0xFE00...0xFE9F => self.oam[address - 0xFE00] = value,
            0xFEA0...0xFEFF => {},
            0xFF80...0xFFFE => self.hram[address - 0xFF80] = value,
            0xFFFF => self.interrupt_enable_register = value,
            0xFF00...0xFF7F => {
                switch (address) {
                    0xFF04 => {
                        self.timer.div = 0;
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
                        self.interrupt_flag = value;
                        return;
                    },
                    0xFF01 => {
                        self.io_registers[0x01] = value;
                        return;
                    },
                    0xFF02 => {
                        if (value == 0x81) {
                            const char = self.io_registers[0x01];
                            std.debug.print("{c}", .{char});
                            // Transfer complete, clear bit 7
                            self.io_registers[0x02] = 0x01;
                        } else {
                            self.io_registers[0x02] = value;
                        }
                        return;
                    },
                    0xFF44 => {},
                    0xFF46 => {
                        self.dma_transfer(value);
                    },
                    else => {},
                }
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
            const offset: u16 = @intCast(i); // 使用 @intCast 更安全，因为它会检查溢出
            const current_source_addr: u16 = source_start_addr +% offset;
            const value = switch (current_source_addr) {
                0x0000...0x7FFF => self.rom[current_source_addr],
                0x8000...0x9FFF => self.vram[current_source_addr - 0x8000],
                0xA000...0xBFFF => self.external_ram[current_source_addr - 0xA000],
                0xC000...0xDFFF => self.wram[current_source_addr - 0xC000],
                0xE000...0xFDFF => self.wram[current_source_addr - 0x2000],
                else => 0xFF,
            };
            self.oam[i] = value;
        }
    }
};
