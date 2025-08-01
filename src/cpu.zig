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
    halted: bool = false,
    ime_scheduled: bool = false,

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
        if (self.ime_scheduled) {
            self.interrupt_master_enable = true;
            self.ime_scheduled = false;
        }
        if (self.halted and (bus.interrupt_flag & bus.read(0xFFFF) != 0)) {
            self.halted = false;
            std.log.debug("Exiting HALT due to IF=0x{x:0>2} & IE=0x{x:0>2}", .{ bus.interrupt_flag, bus.read(0xFFFF) });
        }
        const cycles = self.execute_instruction(bus);
        self.handle_interrupts(bus);
        return cycles;
    }
    fn execute_instruction(self: *CPU, bus: *Bus) u8 {
        if (self.halted) {
            std.log.debug("CPU Halted at PC=0x{x:0>4}, IF=0x{x:0>2}, IE=0x{x:0>2}, IME={}", .{ self.pc, bus.interrupt_flag, bus.read(0xFFFF), self.interrupt_master_enable });
            return 4;
        }
        const opcode = bus.read(self.pc);
        // std.log.info("PC: 0x{x:0>4} | opcode: 0x{x:0>2}", .{ self.pc, opcode });

        switch (opcode) {
            0x00 => { //  NOP
                self.pc +%= 1;
                return 4;
            },
            0x01 => { // LD BC, u16
                const lsb = bus.read(self.pc + 1);
                const msb = bus.read(self.pc + 2);
                self.c = lsb;
                self.b = msb;
                self.pc += 3;
                return 12;
            },
            0x02 => { // LD (BC), A
                const addr = self.get_bc();
                bus.write(addr, self.a);
                self.pc += 1;
                return 8;
            },
            0x03 => { // inc bc
                var bc = self.get_bc();
                bc +%= 1;
                self.set_bc(bc);
                self.pc += 1;
                return 8;
            },
            0x04 => { // INC B
                const original_b = self.b;
                const c_flag_preserved = self.f & C_FLAG;
                self.b +%= 1;
                self.f = 0;
                self.set_zero_flag(self.b == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_b & 0x0F) == 0x0F);
                self.f |= c_flag_preserved;
                self.pc += 1;
                return 4;
            },
            0x05 => { // DEC B
                const original_b = self.b;
                const c_flag_preserved = self.f & C_FLAG;
                self.b -%= 1;
                self.f = 0;
                self.set_zero_flag(self.b == 0);
                self.set_half_carry_flag((original_b & 0x0F) == 0x00);
                self.set_substract_flag(true);
                self.f |= c_flag_preserved;
                self.pc += 1;
                return 4;
            },
            0x06 => { // LD B, u8
                const v = bus.read(self.pc + 1);
                self.b = v;
                self.pc += 2;
                return 8;
            },
            0x07 => { // RLCA
                const original_a = self.a;
                self.f = 0;
                const carry_out = (original_a >> 7) & 1;
                self.set_carry_flag(carry_out != 0);
                self.a = original_a << 1;
                self.a |= @truncate(carry_out);
                self.pc += 1;
                return 4;
            },
            0x08 => { // LD (u16), SP
                const lsb = bus.read(self.pc + 1);
                const msb = bus.read(self.pc + 2);
                const addr = (@as(u16, msb) << 8) | @as(u16, lsb);
                bus.write(addr, @truncate(self.sp));
                bus.write(addr + 1, @truncate(self.sp >> 8));
                self.pc += 3;
                return 20;
            },
            0x09 => { //ADD HL, BC
                const z_flag_preserved = self.f & Z_FLAG;
                const hl = self.get_hl();
                const bc = self.get_bc();
                const res = @as(u32, hl) + @as(u32, bc);
                self.f = 0;
                self.set_substract_flag(false);
                self.set_half_carry_flag((hl & 0x0FFF) + (bc & 0x0FFF) > 0x0FFF);
                self.set_carry_flag(res > 0xFFFF);
                self.f |= z_flag_preserved;
                self.set_hl(@truncate(res));
                self.pc += 1;
                return 8;
            },
            0x0A => { // LD A (BC)
                const addr = self.get_bc();
                self.a = bus.read(addr);
                self.pc += 1;
                return 8;
            },
            0x0B => { // DEC BC
                var bc = self.get_bc();
                bc -%= 1;
                self.set_bc(bc);
                self.pc += 1;
                return 8;
            },
            0x0C => { // INC C
                const original_c = self.c;
                const c_flag_preserved = self.f & C_FLAG;
                self.c +%= 1;
                self.f = 0;
                self.set_zero_flag(self.c == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_c & 0x0F) == 0x0F);
                self.f |= c_flag_preserved;
                self.pc += 1;
                return 4;
            },
            0x0D => { // DEC C
                const original_c = self.c;
                const c_flag_preserved = self.f & C_FLAG;
                self.c -%= 1;
                self.f = 0;
                self.set_zero_flag(self.c == 0);
                self.set_half_carry_flag((original_c & 0x0F) == 0x00);
                self.set_substract_flag(true);
                self.f |= c_flag_preserved;
                self.pc += 1;
                return 4;
            },
            0x0E => { // LD C, u8
                const v = bus.read(self.pc + 1);
                self.c = v;
                self.pc += 2;
                return 8;
            },
            0x0F => { //RR A
                const orignal_a = self.a;
                self.f = 0;
                const carry = orignal_a & 1;
                self.set_carry_flag(carry != 0);
                self.a = (orignal_a >> 1) | (carry << 7);
                self.pc += 1;
                return 4;
            },
            0x10 => { // STOP
                self.pc += 2; // 注意这里是2
                return 4;
            },
            0x11 => { // LD DE, u16
                const lsb = bus.read(self.pc + 1);
                const msb = bus.read(self.pc + 2);
                self.e = lsb;
                self.d = msb;
                self.pc += 3;
                return 12;
            },
            0x12 => { // LD (DE),A
                const addr = self.get_de();
                bus.write(addr, self.a);
                self.pc += 1;
                return 8;
            },
            0x13 => { // INC DE
                var de = self.get_de();
                de +%= 1;
                self.set_de(de);
                self.pc += 1;
                return 8;
            },
            0x14 => { // INC D
                const original_d = self.d;
                const c_flag_preserved = self.f & C_FLAG;
                self.d +%= 1;
                self.f = 0;
                self.set_zero_flag(self.d == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_d & 0x0F) == 0x0F);
                self.f |= c_flag_preserved;
                self.pc += 1;
                return 4;
            },
            0x15 => {
                const original_d = self.d;
                const c_flag_preserved = self.f & C_FLAG;
                self.d -%= 1;
                self.f = 0;
                self.set_zero_flag(self.d == 0);
                self.set_half_carry_flag((original_d & 0x0F) == 0x00);
                self.set_substract_flag(true);
                self.f |= c_flag_preserved;
                self.pc += 1;
                return 4;
            },
            0x16 => { // LD D, u8
                const v = bus.read(self.pc + 1);
                self.d = v;
                self.pc += 2;
                return 8;
            },
            0x17 => { // RLA
                const original_a = self.a;
                const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                const carry_out = (original_a >> 7) & 1;
                self.a = (original_a << 1) | carry_in;
                self.f = 0;
                self.set_carry_flag(carry_out != 0);
                self.pc += 1;
                return 4;
            },
            0x18 => { // JR i8
                const offset = bus.read(self.pc + 1);
                const next_pc = self.pc + 2;
                self.pc = @as(u16, @bitCast(@as(i16, @bitCast(next_pc)) + @as(i8, @bitCast(offset))));
                return 12;
            },
            0x19 => { // ADD HL, DE
                const z_flag_preserved = self.f & Z_FLAG;
                const hl = self.get_hl();
                const de = self.get_de();
                const res: u32 = @as(u32, hl) + @as(u32, de);
                self.f = 0;
                self.set_substract_flag(false);
                self.set_half_carry_flag((hl & 0x0FFF) + (de & 0x0FFF) > 0x0FFF);
                self.set_carry_flag(res > 0xFFFF);
                self.f |= z_flag_preserved;
                self.set_hl(@truncate(res));
                self.pc += 1;
                return 8;
            },
            0x1A => { // LD A, (DE)
                const addr = @as(u16, self.d) << 8 | @as(u16, self.e);
                self.a = bus.read(addr);
                self.pc += 1;
                return 8;
            },
            0x1B => { // DEC DE
                var de = self.get_de();
                de -%= 1;
                self.set_de(de);
                self.pc += 1;
                return 8;
            },
            0x1C => { // INC E
                const orignal_e = self.e;
                const c_flag_preserve = self.f & C_FLAG;
                self.e +%= 1;
                self.f = 0;
                self.set_zero_flag(self.e == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((orignal_e & 0x0F) == 0x0F);
                self.f |= c_flag_preserve;

                self.pc += 1;
                return 4;
            },
            0x1D => {
                const orignal_e = self.e;
                const c_flag_preserve = self.f & C_FLAG;
                self.e -%= 1;
                self.f = 0;
                self.set_zero_flag(self.e == 0);
                self.set_substract_flag(true);
                self.set_half_carry_flag((orignal_e & 0x0F) == 0x0);
                self.f |= c_flag_preserve;
                self.pc += 1;
                return 4;
            },
            0x1E => { // LD E, u8
                const v = bus.read(self.pc + 1);
                self.e = v;
                self.pc += 2;
                return 8;
            },
            0x1F => { //RR A
                const orignal_a = self.a;
                const carry_out = orignal_a & 1;
                const carry: u8 = if ((self.f & C_FLAG) != 0) 1 else 0;
                self.a = orignal_a >> 1 | carry << 7;
                self.f = 0;
                self.set_carry_flag(carry_out != 0);
                self.pc += 1;
                return 4;
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
            0x21 => { // LD HL, u16
                const lsb = bus.read(self.pc + 1);
                const msb = bus.read(self.pc + 2);
                self.l = lsb;
                self.h = msb;
                self.pc += 3;
                return 12;
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
                const c_flag_preserved = self.f & C_FLAG;
                self.h +%= 1;
                self.f = 0;
                self.set_zero_flag(self.h == 0);
                self.set_half_carry_flag((original_h & 0x0F) == 0x0F);
                self.set_substract_flag(false);
                self.f |= c_flag_preserved;
                self.pc += 1;
                return 4;
            },
            0x25 => { // DEC H
                const orignal_h = self.h;
                const c_flag_preserved = self.f & C_FLAG;
                self.h -%= 1;
                self.f = 0;
                self.set_zero_flag(self.h == 0);
                self.set_half_carry_flag((orignal_h & 0x0F) == 0x00);
                self.set_substract_flag(true);
                self.f |= c_flag_preserved;
                self.pc += 1;
                return 4;
            },
            0x26 => { // LD H, u8
                const v = bus.read(self.pc + 1);
                self.h = v;
                self.pc += 2;
                return 8;
            },
            0x27 => { // DAA
                var a_val: u16 = self.a;
                const n_flag = (self.f & N_FLAG) != 0;
                const h_flag = (self.f & H_FLAG) != 0;
                const c_flag = (self.f & C_FLAG) != 0;
                var correction: u8 = 0;
                var set_carry = c_flag;

                if (!n_flag) { // After addition
                    if (h_flag or (a_val & 0x0F) > 0x09) {
                        correction |= 0x06;
                    }
                    if (c_flag or a_val > 0x99) {
                        correction |= 0x60;
                        set_carry = true;
                    }
                    a_val +%= correction;
                } else { // After subtraction
                    if (h_flag) {
                        correction |= 0x06;
                    }
                    if (c_flag) {
                        correction |= 0x60;
                    }
                    a_val -%= correction;
                }

                self.a = @truncate(a_val);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(n_flag);
                self.set_half_carry_flag(false);
                self.set_carry_flag(set_carry);
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
            0x29 => { // ADD HL, HL
                const z_flag_preserved = self.f & Z_FLAG;
                const hl = self.get_hl();
                const res = @as(u32, hl) + @as(u32, hl);
                self.f = 0;
                self.set_substract_flag(false);
                self.set_half_carry_flag((hl & 0x0FFF) + (hl & 0x0FFF) > 0x0FFF);
                self.set_carry_flag(res > 0xFFFF);
                self.f |= z_flag_preserved;
                self.set_hl(@truncate(res));
                self.pc += 1;
                return 8;
            },
            0x2A => { // LD A, (HL+)
                var hl = self.get_hl();
                self.a = bus.read(hl);
                hl +%= 1;
                self.set_hl(hl);
                self.pc += 1;
                return 8;
            },
            0x2B => { // DEC HL
                var hl = self.get_hl();
                hl -%= 1;
                self.set_hl(hl);
                self.pc += 1;
                return 8;
            },
            0x2C => { // INC L
                const original_l = self.l;
                const c_flag_preserved = self.f & C_FLAG;
                self.l +%= 1;
                self.f = 0;
                self.set_zero_flag(self.l == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_l & 0x0F) == 0x0F);
                self.f |= c_flag_preserved;
                self.pc += 1;
                return 4;
            },
            0x2D => { //DEC L
                const original_l = self.l;
                const c_flag_preserved = self.f & C_FLAG;
                self.l -%= 1;
                self.f = 0;
                self.set_zero_flag(self.l == 0x0);
                self.set_substract_flag(true);
                self.set_half_carry_flag((original_l & 0x0F) == 0x0);
                self.f |= c_flag_preserved;
                self.pc += 1;
                return 4;
            },
            0x2E => { // LD L, u8
                const v = bus.read(self.pc + 1);
                self.l = v;
                self.pc += 2;
                return 8;
            },
            0x2F => { //CPL
                self.a = ~self.a;
                self.set_substract_flag(true);
                self.set_half_carry_flag(true);
                self.pc += 1;
                return 4;
            },
            0x30 => { // JR NC, i8
                // 相对PC跳转，carry 是0 则跳转
                const offset = bus.read(self.pc + 1);
                if ((self.f & C_FLAG) == 0) {
                    const next_pc = self.pc + 2;
                    self.pc = @as(u16, @bitCast(@as(i16, @bitCast(next_pc)) + @as(i8, @bitCast(offset))));
                    return 12;
                } else {
                    self.pc += 2;
                    return 8;
                }
            },
            0x31 => { // LD SP, u16
                const lsb = bus.read(self.pc + 1);
                const msb = bus.read(self.pc + 2);
                const imm_v = @as(u16, lsb) | (@as(u16, msb) << 8);
                self.sp = imm_v;
                self.pc += 3;
                return 12;
            },
            0x32 => { // LD (HL-), A
                var hl = self.get_hl();
                bus.write(hl, self.a);
                hl -%= 1;
                self.set_hl(hl);
                self.pc += 1;
                return 8;
            },
            0x33 => { // INC SP
                self.sp +%= 1;
                self.pc += 1;
                return 8;
            },
            0x34 => { //INC (HL)
                const addr = self.get_hl();
                const original_val = bus.read(addr);
                const c_flag_preserved = self.f & C_FLAG;

                const new_val = original_val +% 1;
                bus.write(addr, new_val);

                self.f = 0;
                self.set_zero_flag(new_val == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_val & 0x0F) == 0x0F);
                self.f |= c_flag_preserved;
                self.pc += 1;
                return 12;
            },
            0x35 => { // DEC (HL)
                const addr = self.get_hl();
                const orignal_val = bus.read(addr);
                const new_val = orignal_val -% 1;
                bus.write(addr, new_val);
                const c_flag_preserved = self.f & C_FLAG;
                self.f = 0;
                self.set_zero_flag(new_val == 0);
                self.set_substract_flag(true);
                self.set_half_carry_flag((orignal_val & 0x0F) == 0);
                self.f |= c_flag_preserved;
                self.pc += 1;
                return 12;
            },
            0x36 => { // LD (HL), u8
                const val = bus.read(self.pc + 1);
                const addr = self.get_hl();
                bus.write(addr, val);
                self.pc += 2;
                return 12;
            },
            0x37 => { //SCF Set Carry Flag
                const z_flag_preserved = self.f & Z_FLAG;
                self.f = 0;
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(true);
                self.f |= z_flag_preserved;
                self.pc += 1;
                return 4;
            },
            0x38 => { // JR C, i8
                const offset = bus.read(self.pc + 1);
                if ((self.f & C_FLAG) != 0) {
                    const next_pc = self.pc + 2;
                    self.pc = @as(u16, @bitCast(@as(i16, @bitCast(next_pc)) + @as(i8, @bitCast(offset))));
                    return 12;
                } else {
                    self.pc += 2;
                    return 8;
                }
            },
            0x39 => { //ADD HL,SP - 0x39
                const hl = self.get_hl();
                const sp = self.sp;
                const result = @as(u32, hl) + @as(u32, sp);
                const z_flag_preserved = self.f & Z_FLAG;
                self.f = 0;
                self.set_substract_flag(false);
                self.set_carry_flag(result > 0xFFFF);
                self.set_half_carry_flag((hl & 0x0FFF) + (sp & 0x0FFF) > 0x0FFF);
                self.f |= z_flag_preserved;
                self.set_hl(@truncate(result));
                self.pc += 1;
                return 8;
            },
            0x3A => { //LD A, (HL-)
                var hl = self.get_hl();
                self.a = bus.read(hl);
                hl -%= 1;
                self.set_hl(hl);
                self.pc += 1;
                return 8;
            },
            0x3B => { // DEC SP
                self.sp -%= 1;
                self.pc += 1;
                return 8;
            },
            0x3C => { // INC A
                const orignal_a = self.a;
                const c_flag_preserved = self.f & C_FLAG;
                self.a +%= 1;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((orignal_a & 0x0F) == 0x0F);
                self.f |= c_flag_preserved;
                self.pc += 1;
                return 4;
            },
            0x3D => { // DEC A
                const original_a = self.a;
                const c_flag_preserved = self.f & C_FLAG;
                self.a -%= 1;
                self.f = 0;
                self.set_zero_flag(self.a == 0x0);
                self.set_substract_flag(true);
                self.set_half_carry_flag((original_a & 0x0F) == 0x0);
                self.f |= c_flag_preserved;
                self.pc += 1;
                return 4;
            },
            0x3E => { // LD A, u8
                const v = bus.read(self.pc + 1);
                self.a = v;
                std.log.debug("LD A, 0x{x:0>2}", .{v});
                self.pc += 2;
                return 8;
            },
            0x3F => { // CCF
                const z_flag_preserved = self.f & Z_FLAG;
                const current_carry = self.get_carry_flag();
                self.f = 0;
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(!current_carry);
                self.f |= z_flag_preserved;
                self.pc += 1;
                return 4;
            },
            0x40 => { // LD B, B
                self.pc += 1;
                return 4;
            },
            0x41 => { // LD B, C
                self.b = self.c;
                self.pc += 1;
                return 4;
            },
            0x42 => { // LD B, D
                self.b = self.d;
                self.pc += 1;
                return 4;
            },
            0x43 => { // LD B, E
                self.b = self.e;
                self.pc += 1;
                return 4;
            },
            0x44 => { // LD B, D
                self.b = self.d;
                self.pc += 1;
                return 4;
            },
            0x45 => { //LD B, L
                self.b = self.l;
                self.pc += 1;
                return 4;
            },
            0x46 => { // LD B, (HL)
                const addr = self.get_hl();
                self.b = bus.read(addr);
                self.pc += 1;
                return 8;
            },
            0x47 => { // LD B, A
                self.b = self.a;
                self.pc += 1;
                return 4;
            },
            0x48 => { // LD C, B
                self.c = self.b;
                self.pc += 1;
                return 4;
            },
            0x49 => { // LD C, C
                self.pc += 1;
                return 4;
            },
            0x4A => { // LD C, D
                self.c = self.d;
                self.pc += 1;
                return 4;
            },
            0x4B => {
                self.c = self.e;
                self.pc += 1;
                return 4;
            },
            0x4C => { // LD C, H
                self.c = self.h;
                self.pc += 1;
                return 4;
            },
            0x4D => { // LD C, L
                self.c = self.l;
                self.pc += 1;
                return 4;
            },
            0x4E => { // LD C,(HL)
                const addr = self.get_hl();
                self.c = bus.read(addr);
                self.pc += 1;
                return 8;
            },
            0x4F => { // LD C, A
                self.c = self.a;
                self.pc += 1;
                return 4;
            },
            0x50 => { // LD D, B
                self.d = self.b;
                self.pc += 1;
                return 4;
            },
            0x51 => { // LD D, C
                self.d = self.c;
                self.pc += 1;
                return 4;
            },
            0x52 => { // LD D, D
                self.pc += 1;
                return 4;
            },
            0x53 => { // LD D, E
                self.d = self.e;
                self.pc += 1;
                return 4;
            },
            0x54 => { // LD D, H
                self.d = self.h;
                self.pc += 1;
                return 4;
            },
            0x55 => { // LD D, L
                self.d = self.l;
                self.pc += 1;
                return 4;
            },
            0x56 => { // LD D, (HL)
                const addr = self.get_hl();
                self.d = bus.read(addr);
                self.pc += 1;
                return 8;
            },
            0x57 => { // LD D, A
                self.d = self.a;
                self.pc += 1;
                return 4;
            },
            0x58 => { // LD E, B
                self.e = self.b;
                self.pc += 1;
                return 4;
            },
            0x59 => { // LD E, C
                self.e = self.c;
                self.pc += 1;
                return 4;
            },
            0x5A => { // LD E, D
                self.e = self.d;
                self.pc += 1;
                return 4;
            },
            0x5B => { // LD E, E
                self.pc += 1;
                return 4;
            },
            0x5C => { // LD E, H
                self.e = self.h;
                self.pc += 1;
                return 4;
            },
            0x5D => { // LD E, L
                self.e = self.l;
                self.pc += 1;
                return 4;
            },
            0x5E => { // LD E, (HL)
                const addr = self.get_hl();
                self.e = bus.read(addr);
                self.pc += 1;
                return 8;
            },
            0x5F => { // LD E,A
                self.e = self.a;
                self.pc += 1;
                return 4;
            },
            0x60 => { // LD H, B
                self.h = self.b;
                self.pc += 1;
                return 4;
            },
            0x61 => { // LD H, C
                self.h = self.c;
                self.pc += 1;
                return 4;
            },
            0x62 => { // LD H, D
                self.h = self.d;
                self.pc += 1;
                return 4;
            },
            0x63 => { // LD H, E
                self.h = self.e;
                self.pc += 1;
                return 4;
            },
            0x64 => { // LD H, H
                self.pc += 1;
                return 4;
            },
            0x65 => { // LD H L
                self.h = self.l;
                self.pc += 1;
                return 4;
            },
            0x66 => { // LD H, (HL)
                const addr = self.get_hl();
                self.h = bus.read(addr);
                self.pc += 1;
                return 8;
            },
            0x67 => { // LD H, A
                self.h = self.a;
                self.pc += 1;
                return 4;
            },
            0x68 => { // LD L, B
                self.l = self.b;
                self.pc += 1;
                return 4;
            },
            0x69 => { // LD L, C
                self.l = self.c;
                self.pc += 1;
                return 4;
            },
            0x6A => { // LD L, D
                self.l = self.d;
                self.pc += 1;
                return 4;
            },
            0x6B => { // LD L, E
                self.l = self.e;
                self.pc += 1;
                return 4;
            },
            0x6C => { // LD L, H
                self.l = self.h;
                self.pc += 1;
                return 4;
            },
            0x6D => { // LD L, L
                self.pc += 1;
                return 4;
            },
            0x6E => { // LD L, (HL)
                const addr = self.get_hl();
                self.l = bus.read(addr);
                self.pc += 1;
                return 8;
            },
            0x6F => { // LD L, A
                self.l = self.a;
                self.pc += 1;
                return 4;
            },
            0x70 => { //LD (HL), B
                const addr = self.get_hl();
                bus.write(addr, self.b);
                self.pc += 1;
                return 8;
            },
            0x71 => { // LD (HL), C
                const addr = self.get_hl();
                bus.write(addr, self.c);
                self.pc += 1;
                return 8;
            },
            0x72 => { // LD (HL), D
                const addr = self.get_hl();
                bus.write(addr, self.d);
                self.pc += 1;
                return 8;
            },
            0x73 => { // LD (HL), E
                const addr = self.get_hl();
                bus.write(addr, self.e);
                self.pc += 1;
                return 8;
            },
            0x74 => { // LD (HL), H
                const addr = self.get_hl();
                bus.write(addr, self.h);
                self.pc += 1;
                return 8;
            },
            0x75 => { // LD (HL), L
                const addr = self.get_hl();
                bus.write(addr, self.l);
                self.pc += 1;
                return 8;
            },
            0x76 => { //HALT
                const interrupt_enable = bus.read(0xFFFF);
                if (!self.interrupt_master_enable and (interrupt_enable & bus.interrupt_flag) != 0) {} else {
                    self.halted = true;
                }
                self.pc += 1;
                std.log.debug("HALT at PC=0x{x:0>4}, IF=0x{x:0>2}, IE=0x{x:0>2}", .{ self.pc, bus.interrupt_flag, bus.read(0xFFFF) });
                return 4;
            },
            0x77 => { // LD (HL), A
                const hl = self.get_hl();
                bus.write(hl, self.a);
                self.pc += 1;
                return 8;
            },
            0x78 => { // LD A, B
                self.a = self.b;
                self.pc += 1;
                return 4;
            },
            0x79 => { // LD A, C
                self.a = self.c;
                self.pc += 1;
                return 4;
            },
            0x7A => { // LD A, D
                self.a = self.d;
                self.pc += 1;
                return 4;
            },
            0x7B => { // LD A, E
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
            0x7E => { // LD A, (HL)
                const addr = self.get_hl();
                self.a = bus.read(addr);
                self.pc += 1;
                return 8;
            },
            0x7F => { // LD A, A
                self.pc += 1;
                return 4;
            },
            0x80 => { // ADD A, B
                const value = self.b;
                const result = @as(u16, self.a) + @as(u16, value);
                self.f = 0;
                self.set_zero_flag(result & 0xFF == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((self.a & 0x0F) + (value & 0x0F) > 0x0F);
                self.set_carry_flag(result > 0xFF);
                self.a = @truncate(result);
                self.pc += 1;
                return 4;
            },
            0x81 => { // ADD A, C
                const orignal_a = self.a;
                const val = self.c;
                const res: u16 = @as(u16, orignal_a) + @as(u16, val);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_carry_flag(res > 0xFF);
                self.set_half_carry_flag((orignal_a & 0x0F) + (val & 0x0F) > 0x0F);
                self.pc += 1;
                return 4;
            },
            0x82 => { // ADD A, D
                const orignal_a = self.a;
                const val = self.d;
                const res: u16 = @as(u16, orignal_a) + @as(u16, val);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_carry_flag(res > 0xFF);
                self.set_half_carry_flag((orignal_a & 0x0F) + (val & 0x0F) > 0x0F);
                self.pc += 1;
                return 4;
            },
            0x83 => { // ADD, A, E
                const orignal_a = self.a;
                const val = self.e;
                const res: u16 = @as(u16, orignal_a) + @as(u16, val);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_carry_flag(res > 0xFF);
                self.set_half_carry_flag((orignal_a & 0x0F) + (val & 0x0F) > 0x0F);
                self.pc += 1;
                return 4;
            },
            0x84 => { // ADD, A, H
                const orignal_a = self.a;
                const val = self.h;
                const res: u16 = @as(u16, orignal_a) + @as(u16, val);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_carry_flag(res > 0xFF);
                self.set_half_carry_flag((orignal_a & 0x0F) + (val & 0x0F) > 0x0F);
                self.pc += 1;
                return 4;
            },
            0x85 => { // ADD A, L
                const orignal_a = self.a;
                const val = self.l;
                const res: u16 = @as(u16, orignal_a) + @as(u16, val);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_carry_flag(res > 0xFF);
                self.set_half_carry_flag((orignal_a & 0x0F) + (val & 0x0F) > 0x0F);
                self.pc += 1;
                return 4;
            },
            0x86 => { // ADD A, (HL)
                const orignal_a = self.a;
                const addr = self.get_hl();
                const val = bus.read(addr);
                const res: u16 = @as(u16, orignal_a) + @as(u16, val);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_carry_flag(res > 0xFF);
                self.set_half_carry_flag((orignal_a & 0x0F) + (val & 0x0F) > 0x0F);
                self.pc += 1;
                return 8;
            },
            0x87 => { // ADD A, A
                const orignal_a = self.a;
                const val = self.a;
                const res: u16 = @as(u16, orignal_a) + @as(u16, val);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_carry_flag(res > 0xFF);
                self.set_half_carry_flag((orignal_a & 0x0F) + (val & 0x0F) > 0x0F);
                self.pc += 1;
                return 4;
            },
            0x88 => { // ADC A, B
                const original_a = self.a;
                const val = self.b;
                const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                const res = @as(u16, original_a) + @as(u16, val) + @as(u16, carry_in);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_a & 0x0F) + (val & 0x0F) + carry_in > 0x0F);
                self.set_carry_flag(res > 0xFF);
                self.pc += 1;
                return 4;
            },
            0x89 => { // ADC A, C
                const original_a = self.a;
                const val = self.c;
                const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                const res = @as(u16, original_a) + @as(u16, val) + @as(u16, carry_in);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_a & 0x0F) + (val & 0x0F) + carry_in > 0x0F);
                self.set_carry_flag(res > 0xFF);
                self.pc += 1;
                return 4;
            },
            0x8A => { //ADC A, D

                const original_a = self.a;
                const val = self.d;
                const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                const res = @as(u16, original_a) + @as(u16, val) + @as(u16, carry_in);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_a & 0x0F) + (val & 0x0F) + carry_in > 0x0F);
                self.set_carry_flag(res > 0xFF);
                self.pc += 1;
                return 4;
            },
            0x8B => { // ADC A, E
                const original_a = self.a;
                const val = self.e;
                const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                const res = @as(u16, original_a) + @as(u16, val) + @as(u16, carry_in);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_a & 0x0F) + (val & 0x0F) + carry_in > 0x0F);
                self.set_carry_flag(res > 0xFF);
                self.pc += 1;
                return 4;
            },
            0x8C => { // ADC A, H
                const original_a = self.a;
                const val = self.h;
                const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                const res = @as(u16, original_a) + @as(u16, val) + @as(u16, carry_in);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_a & 0x0F) + (val & 0x0F) + carry_in > 0x0F);
                self.set_carry_flag(res > 0xFF);
                self.pc += 1;
                return 4;
            },
            0x8D => { // ADC A, L
                const original_a = self.a;
                const val = self.l;
                const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                const res = @as(u16, original_a) + @as(u16, val) + @as(u16, carry_in);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_a & 0x0F) + (val & 0x0F) + carry_in > 0x0F);
                self.set_carry_flag(res > 0xFF);
                self.pc += 1;
                return 4;
            },
            0x8E => { // ADC A, (HL)
                const original_a = self.a;
                const val = bus.read(self.get_hl());
                const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                const res = @as(u16, original_a) + @as(u16, val) + @as(u16, carry_in);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_a & 0x0F) + (val & 0x0F) + carry_in > 0x0F);
                self.set_carry_flag(res > 0xFF);
                self.pc += 1;
                return 8;
            },
            0x8F => { // ADC A, A
                const original_a = self.a;
                const val = self.a;
                const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                const res = @as(u16, original_a) + @as(u16, val) + @as(u16, carry_in);
                self.a = @truncate(res);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_a & 0x0F) + (val & 0x0F) + carry_in > 0x0F);
                self.set_carry_flag(res > 0xFF);
                self.pc += 1;
                return 4;
            },
            0x90 => { // SUB A, B
                const original_a = self.a;
                const val = self.b;
                self.a -%= val;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_carry_flag(original_a < val);
                self.set_substract_flag(true);
                self.set_half_carry_flag((original_a & 0x0F) < (val & 0x0F));
                self.pc += 1;
                return 4;
            },
            0x91 => { // SUB A, C
                const original_a = self.a;
                const val = self.c;
                self.a -%= val;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_carry_flag(original_a < val);
                self.set_substract_flag(true);
                self.set_half_carry_flag((original_a & 0x0F) < (val & 0x0F));
                self.pc += 1;
                return 4;
            },
            0x92 => { // SUB A,D
                const original_a = self.a;
                const val = self.d;
                self.a -%= val;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_carry_flag(original_a < val);
                self.set_substract_flag(true);
                self.set_half_carry_flag((original_a & 0x0F) < (val & 0x0F));
                self.pc += 1;
                return 4;
            },
            0x93 => { // SUB A, E
                const original_a = self.a;
                const val = self.e;
                self.a -%= val;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_carry_flag(original_a < val);
                self.set_substract_flag(true);
                self.set_half_carry_flag((original_a & 0x0F) < (val & 0x0F));
                self.pc += 1;
                return 4;
            },
            0x94 => { // SUB A, H
                const original_a = self.a;
                const val = self.h;
                self.a -%= val;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_carry_flag(original_a < val);
                self.set_substract_flag(true);
                self.set_half_carry_flag((original_a & 0x0F) < (val & 0x0F));
                self.pc += 1;
                return 4;
            },
            0x95 => { // SUB A, L
                const original_a = self.a;
                const val = self.l;
                self.a -%= val;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_carry_flag(original_a < val);
                self.set_substract_flag(true);
                self.set_half_carry_flag((original_a & 0x0F) < (val & 0x0F));
                self.pc += 1;
                return 4;
            },
            0x96 => { // SUB A, (HL)
                const original_a = self.a;
                const val = bus.read(self.get_hl());
                self.a -%= val;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_carry_flag(original_a < val);
                self.set_substract_flag(true);
                self.set_half_carry_flag((original_a & 0x0F) < (val & 0x0F));
                self.pc += 1;
                return 8;
            },
            0x97 => { // SUB A, A
                const original_a = self.a;
                const val = self.a;
                self.a -%= val;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_carry_flag(original_a < val);
                self.set_substract_flag(true);
                self.set_half_carry_flag((original_a & 0x0F) < (val & 0x0F));
                self.pc += 1;
                return 4;
            },
            0x98 => { // SBC A, B
                const orignal_a = self.a;
                const val = self.b;
                const carry: u8 = if (self.get_carry_flag()) 1 else 0;
                const result = @as(u16, orignal_a) -% @as(u16, val) -% @as(u16, carry);
                self.a = @truncate(result);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(true);
                self.set_half_carry_flag((orignal_a & 0x0F) < (val & 0x0F) + carry);
                self.set_carry_flag(@as(u16, orignal_a) < @as(u16, val) + @as(u16, carry));
                self.pc += 1;
                return 4;
            },
            0x99 => { // SBC A, C
                const orignal_a = self.a;
                const val = self.c;
                const carry: u8 = if (self.get_carry_flag()) 1 else 0;
                const result = @as(u16, orignal_a) -% @as(u16, val) -% @as(u16, carry);
                self.a = @truncate(result);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(true);
                self.set_half_carry_flag((orignal_a & 0x0F) < (val & 0x0F) + carry);
                self.set_carry_flag(@as(u16, orignal_a) < @as(u16, val) + @as(u16, carry));
                self.pc += 1;
                return 4;
            },
            0x9A => { // SBC A, D
                const orignal_a = self.a;
                const val = self.d;
                const carry: u8 = if (self.get_carry_flag()) 1 else 0;
                const result = @as(u16, orignal_a) -% @as(u16, val) -% @as(u16, carry);
                self.a = @truncate(result);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(true);
                self.set_half_carry_flag((orignal_a & 0x0F) < (val & 0x0F) + carry);
                self.set_carry_flag(@as(u16, orignal_a) < @as(u16, val) + @as(u16, carry));
                self.pc += 1;
                return 4;
            },
            0x9B => { // SBC A, E
                const orignal_a = self.a;
                const val = self.e;
                const carry: u8 = if (self.get_carry_flag()) 1 else 0;
                const result = @as(u16, orignal_a) -% @as(u16, val) -% @as(u16, carry);
                self.a = @truncate(result);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(true);
                self.set_half_carry_flag((orignal_a & 0x0F) < (val & 0x0F) + carry);
                self.set_carry_flag(@as(u16, orignal_a) < @as(u16, val) + @as(u16, carry));
                self.pc += 1;
                return 4;
            },
            0x9C => { // SBC A, H
                const orignal_a = self.a;
                const val = self.h;
                const carry: u8 = if (self.get_carry_flag()) 1 else 0;
                const result = @as(u16, orignal_a) -% @as(u16, val) -% @as(u16, carry);
                self.a = @truncate(result);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(true);
                self.set_half_carry_flag((orignal_a & 0x0F) < (val & 0x0F) + carry);
                self.set_carry_flag(@as(u16, orignal_a) < @as(u16, val) + @as(u16, carry));
                self.pc += 1;
                return 4;
            },
            0x9D => { // SBC A, L
                const orignal_a = self.a;
                const val = self.l;
                const carry: u8 = if (self.get_carry_flag()) 1 else 0;
                const result = @as(u16, orignal_a) -% @as(u16, val) -% @as(u16, carry);
                self.a = @truncate(result);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(true);
                self.set_half_carry_flag((orignal_a & 0x0F) < (val & 0x0F) + carry);
                self.set_carry_flag(@as(u16, orignal_a) < @as(u16, val) + @as(u16, carry));
                self.pc += 1;
                return 4;
            },
            0x9E => { // SBC A,(HL)
                const orignal_a = self.a;
                const val = bus.read(self.get_hl());
                const carry: u8 = if (self.get_carry_flag()) 1 else 0;
                const result = @as(u16, orignal_a) -% @as(u16, val) -% @as(u16, carry);
                self.a = @truncate(result);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(true);
                self.set_half_carry_flag((orignal_a & 0x0F) < (val & 0x0F) + carry);
                self.set_carry_flag(@as(u16, orignal_a) < @as(u16, val) + @as(u16, carry));
                self.pc += 1;
                return 8;
            },
            0x9F => { //SBC A,A
                const orignal_a = self.a;
                const val = self.a;
                const carry: u8 = if (self.get_carry_flag()) 1 else 0;
                const result = @as(u16, orignal_a) -% @as(u16, val) -% @as(u16, carry);
                self.a = @truncate(result);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(true);
                self.set_half_carry_flag((orignal_a & 0x0F) < (val & 0x0F) + carry);
                self.set_carry_flag(@as(u16, orignal_a) < @as(u16, val) + @as(u16, carry));
                self.pc += 1;
                return 4;
            },
            0xA0 => { // AND A, B
                self.a &= self.b;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(true);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xA1 => { //AND A,C
                self.a &= self.c;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(true);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xA2 => { // AND A, D
                self.a &= self.d;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(true);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xA3 => { // AND A, E
                self.a &= self.e;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(true);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xA4 => {
                self.a &= self.h;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(true);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xA5 => {
                self.a &= self.l;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(true);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xA6 => {
                const addr = self.get_hl();
                self.a &= bus.read(addr);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(true);
                self.set_carry_flag(false);
                self.pc += 1;
                return 8;
            },
            0xA7 => {
                self.a &= self.a;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(true);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xA8 => { // XOR A, B
                self.a ^= self.b;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xA9 => { // XOR A, C
                self.a ^= self.c;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xAA => { //XOR A, D
                self.a ^= self.d;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xAB => { //XOR A, E
                self.a ^= self.e;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xAC => { //XOR A, H
                self.a ^= self.h;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xAD => { // XOR A, L
                self.a ^= self.l;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xAE => { // XOR A, (HL)
                const addr = self.get_hl();
                self.a ^= bus.read(addr);
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_carry_flag(false);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.pc += 1;
                return 8;
            },
            0xAF => { // XOR A, A
                self.a = 0x0;
                self.f = 0;
                self.set_zero_flag(true);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xB0 => { // OR A, B
                self.a = self.a | self.b;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xB1 => { // OR A, C
                self.a = self.a | self.c;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xB2 => { // OR A, D
                self.a = self.a | self.d;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xB3 => { // OR A, E
                self.a = self.a | self.e;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xB4 => { //OR A,H - 0xB4
                self.a = self.a | self.h;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xB5 => { // OR A, L
                self.a = self.a | self.l;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xB6 => { // OR A, (HL)
                const addr = self.get_hl();
                const val = bus.read(addr);
                self.a |= val;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 8;
            },
            0xB7 => { // OR A, A
                self.a = self.a | self.a;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 1;
                return 4;
            },
            0xB8 => { // CP A,B
                const val = self.b;
                self.f = 0;
                self.set_substract_flag(true);
                self.set_zero_flag(self.a == val);
                self.set_half_carry_flag((self.a & 0x0F) < (val & 0x0F));
                self.set_carry_flag(self.a < val);
                self.pc += 1;
                return 4;
            },
            0xB9 => { // CP A, C
                const val = self.c;
                self.f = 0;
                self.set_substract_flag(true);
                self.set_zero_flag(self.a == val);
                self.set_half_carry_flag((self.a & 0x0F) < (val & 0x0F));
                self.set_carry_flag(self.a < val);
                self.pc += 1;
                return 4;
            },
            0xBA => { // CP A, D
                const val = self.d;
                self.f = 0;
                self.set_substract_flag(true);
                self.set_zero_flag(self.a == val);
                self.set_half_carry_flag((self.a & 0x0F) < (val & 0x0F));
                self.set_carry_flag(self.a < val);
                self.pc += 1;
                return 4;
            },
            0xBB => { // CP A, E
                const val = self.e;
                self.f = 0;
                self.set_substract_flag(true);
                self.set_zero_flag(self.a == val);
                self.set_half_carry_flag((self.a & 0x0F) < (val & 0x0F));
                self.set_carry_flag(self.a < val);
                self.pc += 1;
                return 4;
            },
            0xBC => { // CP A, H
                const val = self.h;
                self.f = 0;
                self.set_substract_flag(true);
                self.set_zero_flag(self.a == val);
                self.set_half_carry_flag((self.a & 0x0F) < (val & 0x0F));
                self.set_carry_flag(self.a < val);
                self.pc += 1;
                return 4;
            },
            0xBD => { // CP A, L
                const val = self.l;
                self.f = 0;
                self.set_substract_flag(true);
                self.set_zero_flag(self.a == val);
                self.set_half_carry_flag((self.a & 0x0F) < (val & 0x0F));
                self.set_carry_flag(self.a < val);
                self.pc += 1;
                return 4;
            },
            0xBE => { // CP A, (HL)
                const addr = self.get_hl();
                const val = bus.read(addr);
                const original_a = self.a;
                self.f = 0;
                self.set_zero_flag(original_a == val);
                self.set_substract_flag(true);
                self.set_half_carry_flag((original_a & 0x0F) < (val & 0x0F));
                self.set_carry_flag(original_a < val);
                self.pc += 1;
                return 8;
            },
            0xBF => { // CP A,A
                const val = self.a;
                const original_a = self.a;
                self.f = 0;
                self.set_zero_flag(original_a == val);
                self.set_substract_flag(true);
                self.set_half_carry_flag((original_a & 0x0F) < (val & 0x0F));
                self.set_carry_flag(original_a < val);
                self.pc += 1;
                return 4;
            },
            0xC1 => { // POP BC
                self.c = bus.read(self.sp);
                self.sp +%= 1;
                self.b = bus.read(self.sp);
                self.sp +%= 1;
                self.pc += 1;
                return 12;
            },
            0xC2 => { // JP NZ, u16
                const low = bus.read(self.pc + 1);
                const high = bus.read(self.pc + 2);

                if (!self.get_zero_flag()) {
                    const addr = (@as(u16, high) << 8) | @as(u16, low);
                    self.pc = addr;
                    return 16;
                } else {
                    self.pc += 3;
                    return 12;
                }
            },
            0xC3 => { // JP u16
                const lo = bus.read(self.pc + 1);
                const hi = bus.read(self.pc + 2);
                self.pc = @as(u16, lo) | (@as(u16, hi) << 8);
                return 16;
            },
            0xC4 => { // CALL NZ, u16
                const lo = bus.read(self.pc + 1);
                const hi = bus.read(self.pc + 2);
                if (!self.get_zero_flag()) {
                    const ret_addr = self.pc + 3;
                    self.sp -%= 1;
                    bus.write(self.sp, @truncate(ret_addr >> 8));
                    self.sp -%= 1;
                    bus.write(self.sp, @truncate(ret_addr));
                    self.pc = @as(u16, hi) << 8 | lo;
                    return 24;
                } else {
                    self.pc += 3;
                    return 12;
                }
            },
            0xC5 => { // PUSH BC
                self.sp -%= 1;
                bus.write(self.sp, self.b);
                self.sp -%= 1;
                bus.write(self.sp, self.c);
                self.pc += 1;
                return 16;
            },
            0xC6 => { // ADD A, u8
                const val = bus.read(self.pc + 1);
                const original_a = self.a;
                const res = @as(u16, original_a) + @as(u16, val);
                self.f = 0;
                self.set_zero_flag((res & 0xFF) == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag((original_a & 0x0F) + (val & 0x0F) > 0x0F);
                self.set_carry_flag(res > 0xFF);
                self.a = @truncate(res);
                self.pc += 2;
                return 8;
            },
            0xC7 => { // RST 00h
                const ret_addr = self.pc + 1;
                const pc_hi: u8 = @truncate(ret_addr >> 8);
                const pc_lo: u8 = @truncate(ret_addr);
                self.sp -%= 1;
                bus.write(self.sp, pc_hi);
                self.sp -%= 1;
                bus.write(self.sp, pc_lo);
                self.pc = 0x0000;
                return 16;
            },
            0xC8 => { // RET Z
                if (self.get_zero_flag()) {
                    const lo = bus.read(self.sp);
                    self.sp +%= 1;
                    const hi = bus.read(self.sp);
                    self.sp +%= 1;
                    self.pc = (@as(u16, hi) << 8) | @as(u16, lo);
                    return 20;
                } else {
                    self.pc += 1;
                    return 8;
                }
            },
            0xC9 => { // RET
                const low = bus.read(self.sp);
                self.sp +%= 1;
                const hi = bus.read(self.sp);
                self.sp +%= 1;
                self.pc = (@as(u16, hi) << 8) | @as(u16, low);
                return 16;
            },
            0xCA => { // JP Z, u16
                std.log.debug("JP Z, u16: Z={d}, PC=0x{x:0>4}, Target=0x{x:0>4}", .{ @intFromBool(self.get_zero_flag()), self.pc, self.read_u16(bus) });
                const target_addr = self.read_u16(bus);
                if (self.get_zero_flag()) {
                    self.pc = target_addr;
                    return 16;
                } else {
                    self.pc += 3;
                    return 12;
                }
            },
            0xCB => { // CB prefix instructions
                const cb_opcode = bus.read(self.pc + 1);
                self.pc += 2;
                switch (cb_opcode) {
                    0x1B => { // RR E
                        const orignal_e = self.e;
                        const carry = (self.f & C_FLAG) != 0;
                        self.f = 0;
                        self.set_carry_flag((orignal_e & 0x01) != 0);
                        self.e = orignal_e >> 1;
                        if (carry) {
                            self.e |= 0x80;
                        }
                        self.set_zero_flag(self.e == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x7C => { // BIT 7, H
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        const bit_is_zero = ((self.h & (1 << 7)) == 0);
                        self.set_zero_flag(bit_is_zero);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x37 => { // SWAP A 交换A寄存器的高4位和低4位
                        const orignal_a = self.a;
                        const high = orignal_a >> 4;
                        const low = orignal_a & 0x0F;
                        self.a = (low << 4) | high;
                        self.f = 0;
                        self.set_zero_flag(self.a == 0);
                        return 8;
                    },
                    0x38 => { // SRL B
                        const original_b = self.b;
                        self.f = 0;
                        self.set_carry_flag((original_b & 0x01) != 0);
                        self.b = original_b >> 1;
                        self.set_zero_flag(self.b == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x3F => { // SRL A
                        const orignal_a = self.a;
                        self.f = 0;
                        self.set_carry_flag((orignal_a & 0x01) != 0);
                        self.a = orignal_a >> 1;
                        self.set_zero_flag(self.a == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x19 => { // RR C
                        const original_c = self.c;
                        const carry_is_set = (self.f & C_FLAG) != 0;
                        self.f = 0;
                        self.set_carry_flag((original_c & 0x01) != 0);
                        self.c = original_c >> 1;
                        if (carry_is_set) self.c |= 0x80;
                        self.set_zero_flag(self.c == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x1A => { // RR D
                        const original_d = self.d;
                        const carry_is_set = (self.f & C_FLAG) != 0;
                        self.f = 0;
                        self.set_carry_flag((original_d & 0x01) != 0);
                        self.d = original_d >> 1;
                        if (carry_is_set) self.d |= 0x80;
                        self.set_zero_flag(self.d == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },

                    else => |cb_op| {
                        std.log.err("FATAL: Unimplemented CB opcode 0x{x:0>2} at PC=0x{x:0>4}", .{ cb_op, self.pc - 2 });
                        unreachable;
                    },
                }
            },
            0xCC => {
                const addr_lo: u8 = bus.read(self.pc + 1);
                const addr_hi: u8 = bus.read(self.pc + 2);
                const target_addr: u16 = (@as(u16, addr_hi) << 8) | addr_lo;
                self.pc += 3;

                if (self.f & 0x40 != 0) { // 检查 Z 标志
                    self.sp -%= 1;
                    bus.write(self.sp, @truncate(self.pc >> 8));
                    self.sp -%= 1;
                    bus.write(self.sp, @truncate(self.pc));
                    self.pc = target_addr;
                    return 24; // Z=1，24 个 T 周期
                }

                return 12; // Z=0，12 个 T 周期
            },
            0xCD => { // CALL u16
                const low = bus.read(self.pc + 1);
                const high = bus.read(self.pc + 2);
                const target_addr = (@as(u16, high) << 8) | @as(u16, low);
                const return_addr = self.pc + 3;
                self.sp -%= 1;
                bus.write(self.sp, @truncate(return_addr >> 8));
                self.sp -%= 1;
                bus.write(self.sp, @truncate(return_addr));
                self.pc = target_addr;
                return 24;
            },
            0xCE => { // ADC A, u8
                const val = bus.read(self.pc + 1);
                const orignal_a = self.a;
                const carry_in: u8 = if ((self.f & C_FLAG) != 0) 1 else 0;
                const result = @as(u16, orignal_a) + @as(u16, val) + @as(u16, carry_in);
                self.f = 0;
                self.set_zero_flag((result & 0xFF) == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(((orignal_a & 0x0F) + (val & 0x0F) + carry_in) > 0x0F);
                self.set_carry_flag(result > 0xFF);
                self.a = @truncate(result);
                self.pc += 2;
                return 8;
            },
            0xD0 => { // RET NC
                if ((self.f & C_FLAG) == 0) {
                    const low = bus.read(self.sp);
                    self.sp +%= 1;
                    const high = bus.read(self.sp);
                    self.sp +%= 1;
                    self.pc = (@as(u16, high) << 8) | @as(u16, low);
                    return 20;
                } else {
                    self.pc += 1;
                    return 8;
                }
            },
            0xD1 => { // POP DE
                const lo = bus.read(self.sp);
                self.sp +%= 1;
                const hi = bus.read(self.sp);
                self.sp +%= 1;
                self.e = lo;
                self.d = hi;
                self.pc += 1;
                return 12;
            },
            0xD5 => { // PUSH DE
                self.sp -%= 1;
                bus.write(self.sp, self.d);
                self.sp -%= 1;
                bus.write(self.sp, self.e);
                self.pc += 1;
                return 16;
            },
            0xD6 => { // SUB A, u8
                const val = bus.read(self.pc + 1);
                const original_a = self.a;
                self.a -%= val;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(true);
                self.set_carry_flag(original_a < val);
                self.set_half_carry_flag((original_a & 0x0F) < (val & 0x0F));
                self.pc += 2;
                return 8;
            },
            0xD8 => { //RET C
                if ((self.f & C_FLAG) != 0) {
                    const lo = bus.read(self.sp);
                    self.sp +%= 1;
                    const hi = bus.read(self.sp);
                    self.sp +%= 1;
                    self.pc = (@as(u16, hi) << 8) | @as(u16, lo);
                    return 20;
                } else {
                    self.pc += 1;
                    return 8;
                }
            },
            0xDE => { //SBC A,u8
                const val = bus.read(self.pc + 1);
                const carry: u8 = if ((self.f & C_FLAG) != 0) 1 else 0;
                const a = self.a;
                const res = a -% val -% carry;
                self.a = res;
                self.f = 0;
                self.set_zero_flag(res == 0);
                self.set_substract_flag(true);
                self.set_half_carry_flag((a & 0x0F) < (val & 0x0F) + carry);
                self.set_carry_flag(@as(u16, a) < @as(u16, val) + @as(u16, carry));
                self.pc += 2;
                return 8;
            },
            0xE0 => { // LD (FF00+U8), A
                const offset = bus.read(self.pc + 1);
                const target_addr = 0xFF00 + @as(u16, offset);
                bus.write(target_addr, self.a);
                std.log.debug("LD (0x{x:0>4}), A=0x{x:0>2}", .{ target_addr, self.a });
                self.pc += 2;
                return 12;
            },
            0xE1 => { // POP HL
                self.l = bus.read(self.sp);
                self.sp +%= 1;
                self.h = bus.read(self.sp);
                self.sp +%= 1;
                self.pc += 1;
                return 12;
            },
            0xE2 => { // LD (FF00 +C), A
                const addr = 0xFF00 + @as(u16, self.c);
                bus.write(addr, self.a);
                self.pc += 1;
                return 8;
            },

            0xE5 => { // PUSH HL
                self.sp -%= 1;
                bus.write(self.sp, self.h);
                self.sp -%= 1;
                bus.write(self.sp, self.l);
                self.pc += 1;
                return 16;
            },
            0xE6 => { // AND A, u8
                const val = bus.read(self.pc + 1);
                self.a &= val;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(true);
                self.set_carry_flag(false);
                self.pc += 2;
                return 8;
            },
            0xE8 => { // ADD SP, i8
                const imm_u8 = bus.read(self.pc + 1);
                const imm_i8: i8 = @bitCast(imm_u8);
                const original_sp = self.sp;

                // The main operation is a signed addition. SP must be treated as a signed 16-bit value.
                // We use @bitCast to reinterpret the bits of the u16 SP as an i16,
                // then perform wrapping addition.
                const sp_i16: i16 = @bitCast(original_sp);
                const result_i16 = sp_i16 +% imm_i8;
                const new_sp: u16 = @bitCast(result_i16);

                self.f = 0;
                self.set_substract_flag(false);
                self.set_zero_flag(false);

                // Flags are calculated based on the *unsigned* addition of the lower byte of SP and the immediate value.
                self.set_half_carry_flag((original_sp & 0x0F) + (imm_u8 & 0x0F) > 0x0F);
                self.set_carry_flag((original_sp & 0xFF) + imm_u8 > 0xFF);

                self.sp = new_sp;
                self.pc += 2;
                return 16;
            },
            0xE9 => { //  JP HL
                const addr = self.get_hl();
                self.pc = addr;
                return 4;
            },
            0xEA => { // LD (nn), A
                const addr_low = bus.read(self.pc + 1);
                const addr_high = bus.read(self.pc + 2);
                const composite_addr = @as(u16, addr_high) << 8 | addr_low;
                bus.write(composite_addr, self.a);
                self.pc += 3;
                return 16;
            },
            0xEE => { // XOR A, u8
                const val = bus.read(self.pc + 1);
                self.a ^= val;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_carry_flag(false);
                self.set_half_carry_flag(false);
                self.set_substract_flag(false);
                self.pc += 2;
                return 8;
            },
            0xEF => {
                const ret_addr = self.pc + 1;
                const pc_hi: u8 = @truncate(ret_addr >> 8);
                const pc_lo: u8 = @truncate(ret_addr);
                self.sp -%= 1;
                bus.write(self.sp, pc_hi);
                self.sp -%= 1;
                bus.write(self.sp, pc_lo);
                self.pc = 0x0028;
                return 16;
            },
            0xF0 => { // LD A, (FF00 + u8)
                const offset = bus.read(self.pc + 1);
                const target_addr = 0xFF00 + @as(u16, offset);
                self.a = bus.read(target_addr);
                self.pc += 2;
                return 12;
            },
            0xF1 => { // POP AF
                const val = bus.read(self.sp);
                self.f = val & 0xF0; // lower 4 bits of F are always 0
                self.sp +%= 1;
                self.a = bus.read(self.sp);
                self.sp +%= 1;
                self.pc += 1;
                return 12;
            },
            0xF3 => { // DI
                self.interrupt_master_enable = false;
                self.ime_scheduled = false;
                self.pc += 1;
                return 4;
            },
            0xF5 => { // PUSH AF
                self.sp -%= 1;
                bus.write(self.sp, self.a);
                self.sp -%= 1;
                bus.write(self.sp, self.f);
                self.pc += 1;
                return 16;
            },
            0xF6 => { // OR A, u8
                const val = bus.read(self.pc + 1);
                self.a |= val;
                self.f = 0;
                self.set_zero_flag(self.a == 0);
                self.set_substract_flag(false);
                self.set_half_carry_flag(false);
                self.set_carry_flag(false);
                self.pc += 2;
                return 8;
            },
            0xF7 => { // RST 30h
                const ret_addr = self.pc + 1;
                const pc_hi: u8 = @truncate(ret_addr >> 8);
                const pc_lo: u8 = @truncate(ret_addr);
                self.sp -%= 1;
                bus.write(self.sp, pc_hi);
                self.sp -%= 1;
                bus.write(self.sp, pc_lo);
                self.pc = 0x0030;
                return 16;
            },
            0xF8 => { // LD HL, SP+i8
                const offset: i8 = @bitCast(bus.read(self.pc + 1));
                const sp = self.sp;
                const res = @as(u16, @bitCast(@as(i16, @bitCast(sp)) +% offset));
                self.set_hl(res);
                const offset_u8: u8 = @bitCast(offset);
                self.f = 0;
                self.set_half_carry_flag(((sp & 0x0F) +% (@as(u8, @bitCast(offset_u8)) & 0x0F)) > 0x0F);
                self.set_carry_flag(((sp & 0xFF) +% (@as(u8, @bitCast(offset_u8)) & 0xFF)) > 0xFF);
                self.pc += 2;
                return 12;
            },
            0xF9 => { // LD SP, HL
                self.sp = self.get_hl();
                self.pc += 1;
                return 8;
            },
            0xFA => { // LD A, (nn)
                const lsb = bus.read(self.pc + 1);
                const msb = bus.read(self.pc + 2);
                const imm_v = @as(u16, lsb) | (@as(u16, msb) << 8);
                self.a = bus.read(imm_v);
                self.pc += 3;
                return 16;
            },
            0xFB => { // EI (Enable Interrupts)
                self.ime_scheduled = true;
                self.pc += 1;
                return 4;
            },

            0xFE => { // CP A, u8
                const imm_v = bus.read(self.pc + 1);
                self.f = 0;
                self.set_zero_flag(self.a == imm_v);
                self.set_substract_flag(true);
                self.set_half_carry_flag((self.a & 0x0F) < (imm_v & 0x0F));
                self.set_carry_flag(self.a < imm_v);
                self.pc += 2;
                return 8;
            },
            else => |op| {
                std.log.err("FATAL: Unimplemented opcode 0x{X:0>2} at PC=0x{X:0>4}", .{ op, self.pc });
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
    pub fn get_carry_flag(self: *const CPU) bool {
        return self.f & C_FLAG != 0;
    }
    pub fn get_zero_flag(self: *const CPU) bool {
        return self.f & Z_FLAG != 0;
    }
    fn read_u16(self: *const CPU, bus: *Bus) u16 {
        const lo = bus.read(self.pc + 1);
        const hi = bus.read(self.pc + 2);
        return (@as(u16, hi) << 8) | @as(u16, lo);
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

    pub fn handle_interrupts(self: *CPU, bus: *Bus) void {
        const fired_interrupts = bus.interrupt_flag & bus.interrupt_enable_register;
        if (fired_interrupts == 0) return;

        if (self.halted) {
            self.halted = false;
        }

        if (!self.interrupt_master_enable) return;

        for (0..5) |i| {
            const interrupt_mask = @as(u8, 1) << @intCast(i);
            if (fired_interrupts & interrupt_mask != 0) {
                self.interrupt_master_enable = false;
                bus.interrupt_flag &= ~interrupt_mask;

                // Push PC to stack
                self.sp -%= 1;
                bus.write(self.sp, @truncate(self.pc >> 8));
                self.sp -%= 1;
                bus.write(self.sp, @truncate(self.pc));

                // Jump to interrupt vector
                self.pc = switch (i) {
                    0 => 0x40, // V-Blank
                    1 => 0x48, // LCD STAT
                    2 => 0x50, // Timer
                    3 => 0x58, // Serial
                    4 => 0x60, // Joypad
                    else => unreachable,
                };
                return;
            }
        }
    }
};
