const Bus = @import("bus.zig").Bus;
const std = @import("std");
pub const CPU = struct {
    a: u8 = 0,
    f: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    d: u8 = 0,
    e: u8 = 0,
    h: u8 = 0,
    l: u8 = 0,
    pc: u16 = 0x0100,
    sp: u16 = 0xFFFE,
    cycles: u64 = 0,
    interrupt_master_enable: bool = false,
    const Z_FLAG: u8 = 1 << 7; // 0b10000000
    const N_FLAG: u8 = 1 << 6; // 0b01000000
    const H_FLAG: u8 = 1 << 5; // 0b00100000
    const C_FLAG: u8 = 1 << 4; // 0b00010000
    pub fn init() CPU {
        return CPU{
            .a = 0x01,
            .f = 0xB0,
            .b = 0x00,
            .c = 0x13,
            .d = 0x00,
            .e = 0xD8,
            .h = 0x01,
            .l = 0x4D,
            .pc = 0x0100,
            .sp = 0xFFFE,
        };
    }
    pub fn step(self: *CPU, bus: *Bus) u8 {
        const current_op = bus.read(self.pc);
        std.log.info("PC: 0x{x:0>4} | opcode: 0x{x:0>2}", .{ self.pc, current_op });

        const opcode = bus.read(self.pc);
        switch (opcode) {
            0x00 => { //  NOP
                self.pc +%= 1;
                return 4;
            },
            0x03 => { // inc bc
                var bc = self.get_bc();
                bc +%= 1;
                self.set_bc(bc);
                self.pc += 1;
                return 8;
            },
            0x05 => {
                const original_b = self.b;
                self.b -%= 1;
                self.set_zero_flag(self.b == 0);
                self.set_half_carry_flag((original_b & 0x0F) == 0x00);
                self.set_substract_flag(true);
                self.f &= 0xF0;
                self.pc += 1;
                return 4;
            },
            0x31 => { // LD SP, u16
                const lsb = bus.read(self.pc + 1);
                const msb = bus.read(self.pc + 2);
                const imm_v = @as(u16, lsb) | (@as(u16, msb) << 8);
                self.sp = imm_v;
                self.pc += 3;
                return 12;
            },
            0x06 => { // LD B, u8
                const v = bus.read(self.pc + 1);
                self.b = v;
                self.pc += 2;
                return 8;
            },
            0x0E => { // LD C, u8
                const v = bus.read(self.pc + 1);
                self.c = v;
                self.pc += 2;
                return 8;
            },
            0x13 => { // INC DE
                var de = self.get_de();
                de +%= 1;
                self.set_de(de);
                self.pc += 1;
                return 8;
            },
            0x16 => { // LD D, u8
                const v = bus.read(self.pc + 1);
                self.d = v;
                self.pc += 2;
                return 8;
            },
            0x18 => { // JR i8
                const offset = bus.read(self.pc + 1);
                const next_pc = self.pc + 2;
                self.pc = @as(u16, @bitCast(@as(i16, @bitCast(next_pc)) + @as(i8, @bitCast(offset))));
                return 12;
            },
            0x1A => { // LD A, (DE)
                const addr = @as(u16, self.d) << 8 | @as(u16, self.e);
                self.a = bus.read(addr);
                self.pc += 1;
                return 8;
            },
            0x20 => { //JR NZ, r8
                const offset = bus.read(self.pc + 1);
                if (!self.get_zero_flag()) {
                    const next_pc = self.pc + 2;
                    self.pc = @as(u16, @bitCast(@as(i16, @bitCast(next_pc)) + @as(i8, @bitCast(offset))));
                    return 12;
                } else {
                    self.pc += 2;
                    return 8;
                }
            },
            0x22 => { // LD (HL+), A
                var hl = self.get_hl();
                bus.write(hl, self.a);
                hl +%= 1;
                self.set_hl(hl);
                self.pc += 1;
                return 8;
            },
            0x23 => { // INC HL
                var hl_val = self.get_hl();
                hl_val +%= 1;
                self.set_hl(hl_val);
                self.pc += 1;
                return 8;
            },
            0x24 => { // INC H
                const original_h = self.h;
                self.h +%= 1;
                self.set_zero_flag(self.h == 0);
                self.set_half_carry_flag((original_h & 0x0F) == 0x0F);
                self.set_substract_flag(false);
                self.f &= 0xF0;
                self.pc += 1;
                return 4;
            },
            0x28 => { //JR Z, i8
                const offset = bus.read(self.pc + 1);
                if (self.get_zero_flag()) {
                    const next_pc = self.pc + 2;
                    self.pc = @as(u16, @bitCast(@as(i16, @bitCast(next_pc)) + @as(i8, @bitCast(offset))));
                    return 12;
                } else {
                    self.pc += 2;
                    return 8;
                }
            },
            0x2A => { // LD A, (HL+)
                var hl = self.get_hl();
                self.a = bus.read(hl);
                hl +%= 1;
                self.set_hl(hl);
                self.pc += 1;
                return 8;
            },
            0x2C => { // INC L
                const original_l = self.l;
                self.l +%= 1;
                self.set_zero_flag(self.l == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_l & 0x0F) == 0x0F);
                self.f &= 0xF0;
                self.pc += 1;
                return 4;
            },
            0x1E => { // LD E, u8
                const v = bus.read(self.pc + 1);
                self.e = v;
                self.pc += 2;
                return 8;
            },
            0x26 => { // LD H, u8
                const v = bus.read(self.pc + 1);
                self.h = v;
                self.pc += 2;
                return 8;
            },
            0x2E => { // LD L, u8
                const v = bus.read(self.pc + 1);
                self.l = v;
                self.pc += 2;
                return 8;
            },
            0x3E => { // LD A, u8
                const v = bus.read(self.pc + 1);
                self.a = v;
                self.pc += 2;
                return 8;
            },
            0x01 => { // LD BC, u16
                const lsb = bus.read(self.pc + 1);
                const msb = bus.read(self.pc + 2);
                self.c = lsb;
                self.b = msb;
                self.pc += 3;
                return 12;
            },
            0x11 => { // LD DE, u16
                const lsb = bus.read(self.pc + 1);
                const msb = bus.read(self.pc + 2);
                self.e = lsb;
                self.d = msb;
                self.pc += 3;
                return 12;
            },
            0x21 => { // LD HL, u16
                const lsb = bus.read(self.pc + 1);
                const msb = bus.read(self.pc + 2);
                self.l = lsb;
                self.h = msb;
                self.pc += 3;
                return 12;
            },
            0x77 => {
                const hl = self.get_hl();
                bus.write(hl, self.a);
                self.pc += 1;
                return 8;
            },
            0x78 => {
                self.a = self.b;
                self.pc += 1;
                return 4;
            },
            0x79 => {
                self.a = self.c;
                self.pc += 1;
                return 4;
            },
            0x7A => {
                self.a = self.d;
                self.pc += 1;
                return 4;
            },
            0x7B => {
                self.a = self.e;
                self.pc += 1;
                return 4;
            },
            0x7C => { // LD A, H
                self.a = self.h;
                self.pc += 1;
                return 4;
            },
            0x7D => { // LD A, L
                self.a = self.l;
                self.pc += 1;
                return 4;
            },
            0xA9 => { // XOR A, C
                self.a ^= self.c;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.f &= 0xF0;
                self.pc += 1;
                return 4;
            },
            0x80 => {
                const value = self.b;
                const result = @as(u16, self.a) + @as(u16, value);
                self.set_zero_flag(result & 0xFF == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((self.a & 0x0F) + (value & 0x0F) > 0x0F);
                self.set_carry_flag(result > 0xFF);
                self.a = @truncate(result);
                self.pc += 1;
                return 4;
            },

            0xAF => {
                self.a = 0x0;
                self.f &= 0xF0;
                self.set_carry_flag(false);
                self.set_half_carry_flag(false);
                self.set_substract_flag(false);
                self.set_zero_flag(true);
                self.pc += 1;
                return 4;
            },
            0xB1 => { // OR A, C
                self.a = self.a | self.c;
                self.set_zero_flag(self.a == 0);
                self.set_half_carry_flag(false);
                self.set_substract_flag(false);
                self.set_carry_flag(false);
                self.f &= 0xF0;
                self.pc += 1;
                return 4;
            },
            0xBE => { // CP A,(HL)
                const addr = self.get_hl();
                const val = bus.read(addr);
                const original_a = self.a;
                self.set_zero_flag(original_a == val);
                self.set_substract_flag(true);
                self.set_half_carry_flag((original_a & 0x0F) < (val & 0x0F));
                self.set_carry_flag(original_a < val);
                self.f &= 0xF0;
                self.pc += 1;
                return 8;
            },
            0xB7 => {
                self.a |= self.a;
                self.set_zero_flag(self.a == 0);
                self.set_carry_flag(false);
                self.set_half_carry_flag(false);
                self.set_substract_flag(false);
                self.f &= 0xF0;
                self.pc += 1;
                return 4;
            },
            0xFE => { // CP A, u8
                // 比较A和u8的值
                const imm_v = bus.read(self.pc + 1);
                self.set_zero_flag(self.a == imm_v);
                self.set_half_carry_flag((self.a & 0x0F) < (imm_v & 0x0F));
                self.set_carry_flag(self.a < imm_v);
                self.set_substract_flag(true);
                self.f &= 0xF0;
                self.pc += 2;
                return 8;
            },
            0x32 => {
                var hl = self.get_hl();
                bus.write(hl, self.a);
                hl -%= 1;
                self.set_hl(hl);
                self.pc += 1;
                return 8;
            },
            0x3D => {
                const original_a = self.a;
                self.a -%= 1;
                self.set_zero_flag(self.a == 0x0);
                self.set_substract_flag(true);
                self.set_half_carry_flag((original_a & 0x0F) == 0x0);
                self.f &= 0xF0;
                self.pc += 1;
                return 4;
            },
            0xC5 => { // PUSH BC
                self.sp -%= 1;
                bus.write(self.sp, self.b);
                self.sp -%= 1;
                bus.write(self.sp, self.c);
                self.pc += 1;
                return 16;
            },
            0xC6 => {
                const val = bus.read(self.pc + 1);
                const original_a = self.a;
                const res = @as(u16, original_a) + @as(u16, val);
                self.set_zero_flag((res & 0xFF) == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_a & 0x0F) + (val & 0x0F) > 0x0F);
                self.set_carry_flag(res > 0xFF);
                self.f &= 0xF0;
                self.a = @truncate(res);
                self.pc += 2;
                return 8;
            },

            0xCD => { // CALL u16
                const low = bus.read(self.pc + 1);
                const high = bus.read(self.pc + 2);
                const target_addr = @as(u16, high) << 8 | @as(u16, low);
                const return_addr = self.pc + 3;
                self.sp -%= 1;
                bus.write(self.sp, @truncate(return_addr >> 8));
                self.sp -%= 1;
                bus.write(self.sp, @truncate(return_addr));
                self.pc = target_addr;
                return 24;
            },
            0xC9 => {
                const low = bus.read(self.sp);
                self.sp +%= 1;
                const hi = bus.read(self.sp);
                self.sp +%= 1;
                const ret_addr = @as(u16, hi) << 8 | @as(u16, low);
                self.pc = ret_addr;
                return 16;
            },

            0xEA => { // LD (nn), A
                const addr_low = bus.read(self.pc + 1);
                const addr_high = bus.read(self.pc + 2);
                const composite_addr = @as(u16, addr_high) << 8 | @as(u16, addr_low);
                bus.write(composite_addr, self.a);
                self.pc += 3;
                return 16;
            },
            0xE0 => { // LD (FF00+U8), A
                const offset = bus.read(self.pc + 1);
                const target_addr = 0xFF00 + @as(u16, offset);
                bus.write(target_addr, self.a);
                self.pc += 2;
                return 12;
            },
            0xE1 => { // POP HL
                self.l = bus.read(self.sp);
                self.sp += 1;
                self.h = bus.read(self.sp);
                self.sp += 1;
                self.pc += 1;
                return 12;
            },
            0xE5 => { // PUSH HL
                self.sp -%= 1;
                bus.write(self.sp, self.h);
                self.sp -%= 1;
                bus.write(self.sp, self.l);
                self.pc += 1;
                return 16;
            },
            0xE6 => { // AND A, u8k
                const val = bus.read(self.pc + 1);
                self.a &= val;
                self.pc += 2;
                self.set_carry_flag(false);
                self.set_half_carry_flag(true);
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.f &= 0xF0;
                return 8;
            },
            0xC1 => { // POP BC
                self.c = bus.read(self.sp);
                self.sp +%= 1;
                self.b = bus.read(self.sp);
                self.sp +%= 1;
                self.pc += 1;
                return 12;
            },
            0xC3 => { // JP u16,
                const lo = bus.read(self.pc + 1);
                const hi = bus.read(self.pc + 2);
                self.pc = @as(u16, lo) | @as(u16, hi) << 8;
                return 16;
            },
            0xC4 => { // CALL NZ, u16
                const lo = bus.read(self.pc + 1);
                const hi = bus.read(self.pc + 2);
                if (!self.get_zero_flag()) {
                    const ret_addr = self.pc + 3;
                    const return_hi: u8 = @truncate(ret_addr >> 8);
                    const return_lo: u8 = @truncate(ret_addr);
                    self.sp -%= 1;
                    bus.write(self.sp, return_hi);
                    self.sp -%= 1;
                    bus.write(self.sp, return_lo);
                    const target_addr = @as(u16, hi) | @as(u16, lo);
                    self.pc = target_addr;
                    return 24;
                } else {
                    self.pc += 3;
                    return 12;
                }
            },
            0xD5 => {
                self.sp -%= 1;
                bus.write(self.sp, self.d);
                self.sp -%= 1;
                bus.write(self.sp, self.e);
                self.pc += 1;
                return 16;
            },
            0xD6 => {
                const val = bus.read(self.pc + 1);
                const original_a = self.a;
                self.a -%= val;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(true);
                self.set_carry_flag(original_a < val);
                self.set_half_carry_flag((original_a & 0x0F) < (val & 0x0F));

                self.f &= 0xF0;
                self.pc += 2;
                return 8;
            },
            0xF3 => {
                self.interrupt_master_enable = false;
                self.pc += 1;
                return 4;
            },
            0xF0 => { // LD A, (FF00 + u8)
                const offset = bus.read(self.pc + 1);
                const target_addr = 0xFF00 + @as(u16, offset);
                self.a = bus.read(target_addr);
                self.pc += 2;
                return 12;
            },
            0xF1 => { // POP AF
                self.f = bus.read(self.sp);
                self.f &= 0xF0; // lower 4 bits set to 0
                self.sp +%= 1;
                self.a = bus.read(self.sp);
                self.sp +%= 1;
                self.pc += 1;
                return 12;
            },
            0xF5 => { // PUSH AF
                self.sp -%= 1;
                bus.write(self.sp, self.a);
                self.sp -%= 1;
                bus.write(self.sp, self.f);
                self.pc += 1;
                return 16;
            },
            0xFA => {
                const lsb = bus.read(self.pc + 1);
                const msb = bus.read(self.pc + 2);
                const imm_v = @as(u16, lsb) | (@as(u16, msb) << 8);
                self.a = bus.read(imm_v);
                self.pc += 3;
                return 16;
            },
            else => |op| {
                std.log.err("FATAL: Unimplemented opcode 0x{X:0>2} at PC=0x{X:0>4}", .{ op, self.pc - 1 });
                std.log.err("AF={X:0>2}{X:0>2} BC={X:0>2}{X:0>2} DE={X:0>2}{X:0>2} HL={X:0>2}{X:0>2} SP={X:0>4}", .{ self.a, self.f, self.b, self.c, self.d, self.e, self.h, self.l, self.sp });
                unreachable;
            },
        }
    }
    pub fn set_zero_flag(self: *CPU, set: bool) void {
        if (set) {
            self.f |= Z_FLAG;
        } else self.f &= ~Z_FLAG;
    }
    pub fn set_substract_flag(self: *CPU, set: bool) void {
        if (set) {
            self.f |= N_FLAG;
        } else self.f &= ~N_FLAG;
    }
    pub fn set_half_carry_flag(self: *CPU, set: bool) void {
        if (set) {
            self.f |= H_FLAG;
        } else self.f &= ~H_FLAG;
    }
    pub fn set_carry_flag(self: *CPU, set: bool) void {
        if (set) {
            self.f |= C_FLAG;
        } else self.f &= ~C_FLAG;
    }
    pub fn get_zero_flag(self: *CPU) bool {
        return self.f & Z_FLAG != 0;
    }
    fn get_hl(self: *const CPU) u16 {
        return @as(u16, self.h) << 8 | @as(u16, self.l);
    }
    fn set_hl(self: *CPU, value: u16) void {
        self.h = @truncate(value >> 8);
        self.l = @truncate(value);
    }
    fn get_bc(self: *const CPU) u16 {
        return @as(u16, self.b) << 8 | @as(u16, self.c);
    }
    fn set_bc(self: *CPU, value: u16) void {
        self.b = @truncate(value >> 8);
        self.c = @truncate(value);
    }
    fn get_de(self: *const CPU) u16 {
        return @as(u16, self.d) << 8 | @as(u16, self.e);
    }
    fn set_de(self: *CPU, value: u16) void {
        self.d = @truncate(value >> 8);
        self.e = @truncate(value);
    }
};
