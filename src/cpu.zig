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
    halt_bug_active: bool = false,

    const Z_FLAG: u8 = 1 << 7; // 0b10000000
    const N_FLAG: u8 = 1 << 6; // 0b01000000
    const H_FLAG: u8 = 1 << 5; // 0b00100000
    const C_FLAG: u8 = 1 << 4; // 0b00010000
    pub fn init() CPU {
        return CPU{
            .a = 0,
            .f = 0,
            .b = 0,
            .c = 0,
            .d = 0,
            .e = 0,
            .h = 0,
            .l = 0,
            .pc = 0x0000,
            .sp = 0x0000,
            .cycles = 0,
            .interrupt_master_enable = false,
            .halted = false,
            .ime_scheduled = false,
            .halt_bug_active = false,
        };
    }
    pub fn step(self: *CPU, bus: *Bus) u8 {
        // std.log.debug("CPU Step: PC=0x{X:0>4}, SP=0x{X:0>4}, A={X:0>2} F={X:0>2} B={X:0>2} C={X:0>2} D={X:0>2} E={X:0>2} H={X:0>2} L={X:0>2}, IME={}, Haltd={}, HaltBug={}", .{ self.pc, self.sp, self.a, self.f, self.b, self.c, self.d, self.e, self.h, self.l, self.interrupt_master_enable, self.halted, self.halt_bug_active });

        // Handle scheduled IME enable (EI instruction)
        if (self.ime_scheduled) {
            self.interrupt_master_enable = true;
            self.ime_scheduled = false;
            // std.log.debug("CPU: IME enabled (scheduled)", .{});
        }

        // --- Interrupt Handling (before instruction fetch/execution) ---
        // This is crucial for correct interrupt timing and HALT behavior.
        // If CPU is halted and an interrupt is pending, exit HALT
        if (self.halted) {
            const interrupt_enable_reg = bus.read(0xFFFF);
            const pending_interrupts = bus.interrupt_flag & interrupt_enable_reg;
            if (pending_interrupts != 0) {
                self.halted = false;
            } else {
                return 4;
            }
        }

        const interrupt_enable_reg = bus.read(0xFFFF);
        const pending_interrupts = bus.interrupt_flag & interrupt_enable_reg;
        if (self.interrupt_master_enable and pending_interrupts != 0) {
            self.handle_interrupts(bus); // This will push PC and jump to vector
            return 20; // Cycles for interrupt handling (RST + push/pop)
        }

        // HALT bug: the instruction executes normally, but PC fails to
        // increment — effectively the next byte is read twice.
        const saved_pc = self.pc;
        const halt_bug = self.halt_bug_active;
        if (halt_bug) {
            self.halt_bug_active = false;
        }

        const cycles = self.execute_instruction(bus);

        if (halt_bug) {
            // Undo the PC advancement so the same opcode byte is fetched again
            self.pc = saved_pc;
        }

        return cycles;
    }
    fn execute_instruction(self: *CPU, bus: *Bus) u8 {
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
            0x44 => { // LD B, H
                self.b = self.h;
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
            0x76 => { // HALT
                const ie = bus.read(0xFFFF);
                const pending = bus.interrupt_flag & ie;
                if (!self.interrupt_master_enable and pending != 0) {
                    // HALT bug: IME is off but there's a pending interrupt.
                    // CPU does NOT halt; instead the next instruction's PC
                    // increment is skipped (the byte after HALT is read twice).
                    self.halt_bug_active = true;
                    self.pc += 1;
                } else {
                    self.halted = true;
                    self.pc += 1;
                }
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
            0xC0 => { // RET NZ
                if (!self.get_zero_flag()) {
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
                    0x00 => { // RLC B
                        const original_b = self.b;
                        self.f = 0;
                        self.set_carry_flag((original_b & 0x80) != 0);
                        self.b = (original_b << 1) | @as(u8, @intFromBool(self.get_carry_flag()));
                        self.set_zero_flag(self.b == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x01 => { // RLC C
                        const original_c = self.c;
                        self.f = 0;
                        self.set_carry_flag((original_c & 0x80) != 0);
                        self.c = (original_c << 1) | @as(u8, @intFromBool(self.get_carry_flag()));
                        self.set_zero_flag(self.c == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x02 => { // RLC D
                        const original_d = self.d;
                        self.f = 0;
                        self.set_carry_flag((original_d & 0x80) != 0);
                        self.d = (original_d << 1) | @as(u8, @intFromBool(self.get_carry_flag()));
                        self.set_zero_flag(self.d == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x03 => { //RLC E
                        const original_e = self.e;
                        self.f = 0;
                        self.set_carry_flag((original_e & 0x80) != 0);
                        self.e = (original_e << 1) | @as(u8, @intFromBool(self.get_carry_flag()));
                        self.set_zero_flag(self.e == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x04 => { // RLC H
                        const original_h = self.h;
                        self.f = 0;
                        self.set_carry_flag((original_h & 0x80) != 0);
                        self.h = (original_h << 1) | @as(u8, @intFromBool(self.get_carry_flag()));
                        self.set_zero_flag(self.h == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x05 => { // RLC L
                        const original_l = self.l;
                        self.f = 0;
                        self.set_carry_flag((original_l & 0x80) != 0);
                        self.l = (original_l << 1) | @as(u8, @intFromBool(self.get_carry_flag()));
                        self.set_zero_flag(self.l == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x06 => { // RLC (HL)
                        const addr = self.get_hl();
                        const original_value = bus.read(addr);
                        self.f = 0;
                        self.set_carry_flag((original_value & 0x80) != 0);
                        const new_value = (original_value << 1) | @as(u8, @intFromBool(self.get_carry_flag()));
                        bus.write(addr, new_value);
                        self.set_zero_flag(new_value == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 16;
                    },
                    0x07 => { // RLC A
                        const original_a = self.a;
                        self.f = 0;
                        self.set_carry_flag((original_a & 0x80) != 0);
                        self.a = (original_a << 1) | @as(u8, @intFromBool(self.get_carry_flag()));
                        self.set_zero_flag(self.a == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x08 => { // RRC B
                        const original_b = self.b;
                        self.f = 0;
                        self.set_carry_flag((original_b & 0x01) != 0);
                        self.b = (original_b >> 1) | @as(u8, @intFromBool(self.get_carry_flag())) << 7;
                        self.set_zero_flag(self.b == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x09 => { // RRC C
                        const original_c = self.c;
                        self.f = 0;
                        self.set_carry_flag((original_c & 0x01) != 0);
                        self.c = (original_c >> 1) | @as(u8, @intFromBool(self.get_carry_flag())) << 7;
                        self.set_zero_flag(self.c == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x0A => { // RRC D
                        const original_d = self.d;
                        self.f = 0;
                        self.set_carry_flag((original_d & 0x01) != 0);
                        self.d = (original_d >> 1) | @as(u8, @intFromBool(self.get_carry_flag())) << 7;
                        self.set_zero_flag(self.d == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x0B => { // RRC E
                        const original_e = self.e;
                        self.f = 0;
                        self.set_carry_flag((original_e & 0x01) != 0);
                        self.e = (original_e >> 1) | @as(u8, @intFromBool(self.get_carry_flag())) << 7;
                        self.set_zero_flag(self.e == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x0C => { // RRC H
                        const original_h = self.h;
                        self.f = 0;
                        self.set_carry_flag((original_h & 0x01) != 0);
                        self.h = (original_h >> 1) | @as(u8, @intFromBool(self.get_carry_flag())) << 7;
                        self.set_zero_flag(self.h == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x0D => { // RRC L
                        const original_l = self.l;
                        self.f = 0;
                        self.set_carry_flag((original_l & 0x01) != 0);
                        self.l = (original_l >> 1) | @as(u8, @intFromBool(self.get_carry_flag())) << 7;
                        self.set_zero_flag(self.l == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x0E => { // RRC (HL)
                        const addr = self.get_hl();
                        const original_value = bus.read(addr);
                        self.f = 0;
                        self.set_carry_flag((original_value & 0x01) != 0);
                        const new_value = (original_value >> 1) | @as(u8, @intFromBool(self.get_carry_flag())) << 7;
                        bus.write(addr, new_value);
                        self.set_zero_flag(new_value == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 16;
                    },
                    0x0F => { // RRC A
                        const original_a = self.a;
                        self.f = 0;
                        self.set_carry_flag((original_a & 0x01) != 0);
                        self.a = (original_a >> 1) | @as(u8, @intFromBool(self.get_carry_flag())) << 7;
                        self.set_zero_flag(self.a == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x10 => { // RL B
                        const original_b = self.b;
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_b & 0x80) != 0);
                        self.b = (original_b << 1) | carry_in;
                        self.set_zero_flag(self.b == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x11 => { // RL C
                        const original_c = self.c;
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_c & 0x80) != 0);
                        self.c = (original_c << 1) | carry_in;
                        self.set_zero_flag(self.c == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x12 => { // RL D
                        const original_d = self.d;
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_d & 0x80) != 0);
                        self.d = (original_d << 1) | carry_in;
                        self.set_zero_flag(self.d == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x13 => { // RL E
                        const original_e = self.e;
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_e & 0x80) != 0);
                        self.e = (original_e << 1) | carry_in;
                        self.set_zero_flag(self.e == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x14 => { // RL H
                        const original_h = self.h;
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_h & 0x80) != 0);
                        self.h = (original_h << 1) | carry_in;
                        self.set_zero_flag(self.h == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x15 => { // RL L
                        const original_l = self.l;
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_l & 0x80) != 0);
                        self.l = (original_l << 1) | carry_in;
                        self.set_zero_flag(self.l == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x16 => { // RL (HL)
                        const addr = self.get_hl();
                        const original_value = bus.read(addr);
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_value & 0x80) != 0);
                        const new_value = (original_value << 1) | carry_in;
                        bus.write(addr, new_value);
                        self.set_zero_flag(new_value == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 16;
                    },
                    0x17 => { // RL A
                        const original_a = self.a;
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_a & 0x80) != 0);
                        self.a = (original_a << 1) | carry_in;
                        self.set_zero_flag(self.a == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x18 => { // RR B
                        const original_b = self.b;
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_b & 0x01) != 0);
                        self.b = original_b >> 1 | (carry_in << 7);
                        self.set_zero_flag(self.b == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x19 => { // RR C
                        const original_c = self.c;
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_c & 0x01) != 0);
                        self.c = original_c >> 1 | (carry_in << 7);
                        self.set_zero_flag(self.c == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x1A => { // RR D
                        const original_d = self.d;
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_d & 0x01) != 0);
                        self.d = original_d >> 1 | (carry_in << 7);
                        self.set_zero_flag(self.d == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x1B => { // RR E
                        const original_e = self.e;
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_e & 0x01) != 0);
                        self.e = original_e >> 1 | (carry_in << 7);
                        self.set_zero_flag(self.e == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x1C => { // RR H
                        const original_h = self.h;
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_h & 0x01) != 0);
                        self.h = original_h >> 1 | (carry_in << 7);
                        self.set_zero_flag(self.h == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x1D => { // RR L
                        const original_l = self.l;
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_l & 0x01) != 0);
                        self.l = original_l >> 1 | (carry_in << 7);
                        self.set_zero_flag(self.l == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x1E => { // RR (HL)
                        const addr = self.get_hl();
                        const original_value = bus.read(addr);
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_value & 0x01) != 0);
                        const new_value = original_value >> 1 | (carry_in << 7);
                        bus.write(addr, new_value);
                        self.set_zero_flag(new_value == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 16;
                    },
                    0x1F => { // RR A
                        const original_a = self.a;
                        const carry_in: u8 = if (self.get_carry_flag()) 1 else 0;
                        self.f = 0;
                        self.set_carry_flag((original_a & 0x01) != 0);
                        self.a = original_a >> 1 | (carry_in << 7);
                        self.set_zero_flag(self.a == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x20 => { // SLA B
                        const original_b = self.b;
                        self.f = 0;
                        self.set_carry_flag((original_b & 0x80) != 0);
                        self.b = original_b << 1;
                        self.set_zero_flag(self.b == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x21 => { // SLA C
                        const original_c = self.c;
                        self.f = 0;
                        self.set_carry_flag((original_c & 0x80) != 0);
                        self.c = original_c << 1;
                        self.set_zero_flag(self.c == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x22 => { // SLA D
                        const original_d = self.d;
                        self.f = 0;
                        self.set_carry_flag((original_d & 0x80) != 0);
                        self.d = original_d << 1;
                        self.set_zero_flag(self.d == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x23 => { // SLA E
                        const original_e = self.e;
                        self.f = 0;
                        self.set_carry_flag((original_e & 0x80) != 0);
                        self.e = original_e << 1;
                        self.set_zero_flag(self.e == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },

                    0x24 => { // SLA H
                        const original_h = self.h;
                        self.f = 0;
                        self.set_carry_flag((original_h & 0x80) != 0);
                        self.h = original_h << 1;
                        self.set_zero_flag(self.h == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x25 => { // SLA L
                        const original_l = self.l;
                        self.f = 0;
                        self.set_carry_flag((original_l & 0x80) != 0);
                        self.l = original_l << 1;
                        self.set_zero_flag(self.l == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x26 => { // SLA (HL)
                        const addr = self.get_hl();
                        const original_val = bus.read(addr);
                        self.f = 0;
                        self.set_carry_flag((original_val & 0x80) != 0);
                        const new_val = original_val << 1;
                        bus.write(addr, new_val);
                        self.set_zero_flag(new_val == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 16;
                    },
                    0x27 => { // SLA A
                        const original_a = self.a;
                        self.f = 0;
                        self.set_carry_flag((original_a & 0x80) != 0);
                        self.a = original_a << 1;
                        self.set_zero_flag(self.a == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x28 => { // SRA B
                        const original_b = self.b;
                        self.f = 0;
                        self.set_carry_flag((original_b & 0x01) != 0);
                        self.b = (original_b >> 1) | (original_b & 0x80); // Preserve bit 7
                        self.set_zero_flag(self.b == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x29 => { // SRA C
                        const original_c = self.c;
                        self.f = 0;
                        self.set_carry_flag((original_c & 0x01) != 0);
                        self.c = (original_c >> 1) | (original_c & 0x80);
                        self.set_zero_flag(self.c == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x2A => { // SRA D
                        const original_d = self.d;
                        self.f = 0;
                        self.set_carry_flag((original_d & 0x01) != 0);
                        self.d = (original_d >> 1) | (original_d & 0x80);
                        self.set_zero_flag(self.d == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x2B => { // SRA E
                        const original_e = self.e;
                        self.f = 0;
                        self.set_carry_flag((original_e & 0x01) != 0);
                        self.e = (original_e >> 1) | (original_e & 0x80);
                        self.set_zero_flag(self.e == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x2C => { // SRA H
                        const original_h = self.h;
                        self.f = 0;
                        self.set_carry_flag((original_h & 0x01) != 0);
                        self.h = (original_h >> 1) | (original_h & 0x80);
                        self.set_zero_flag(self.h == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x2D => { // SRA L
                        const original_l = self.l;
                        self.f = 0;
                        self.set_carry_flag((original_l & 0x01) != 0);
                        self.l = (original_l >> 1) | (original_l & 0x80);
                        self.set_zero_flag(self.l == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x2E => { // SRA (HL)
                        const addr = self.get_hl();
                        const original_val = bus.read(addr);
                        self.f = 0;
                        self.set_carry_flag((original_val & 0x01) != 0);
                        const new_val = (original_val >> 1) | (original_val & 0x80);
                        bus.write(addr, new_val);
                        self.set_zero_flag(new_val == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 16;
                    },
                    0x2F => { // SRA A
                        const original_a = self.a;
                        self.f = 0;
                        self.set_carry_flag((original_a & 0x01) != 0);
                        self.a = (original_a >> 1) | (original_a & 0x80);
                        self.set_zero_flag(self.a == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x30 => { // SWAP B
                        const original_b = self.b;
                        self.b = (original_b << 4) | (original_b >> 4);
                        self.f = 0;
                        self.set_zero_flag(self.b == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        self.set_carry_flag(false);
                        return 8;
                    },
                    0x31 => { // SWAP C
                        const original_c = self.c;
                        self.c = (original_c << 4) | (original_c >> 4);
                        self.f = 0;
                        self.set_zero_flag(self.c == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        self.set_carry_flag(false);
                        return 8;
                    },
                    0x32 => { // SWAP D
                        const original_d = self.d;
                        self.d = (original_d << 4) | (original_d >> 4);
                        self.f = 0;
                        self.set_zero_flag(self.d == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        self.set_carry_flag(false);
                        return 8;
                    },
                    0x33 => { // SWAP E
                        const original_e = self.e;
                        self.e = (original_e << 4) | (original_e >> 4);
                        self.f = 0;
                        self.set_zero_flag(self.e == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        self.set_carry_flag(false);
                        return 8;
                    },
                    0x34 => { // SWAP H
                        const original_h = self.h;
                        self.h = (original_h << 4) | (original_h >> 4);
                        self.f = 0;
                        self.set_zero_flag(self.h == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        self.set_carry_flag(false);
                        return 8;
                    },
                    0x35 => { // SWAP L
                        const original_l = self.l;
                        self.l = (original_l << 4) | (original_l >> 4);
                        self.f = 0;
                        self.set_zero_flag(self.l == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        self.set_carry_flag(false);
                        return 8;
                    },
                    0x36 => { // SWAP (HL)
                        const addr = self.get_hl();
                        const original_val = bus.read(addr);
                        const new_val = (original_val << 4) | (original_val >> 4);
                        bus.write(addr, new_val);
                        self.f = 0;
                        self.set_zero_flag(new_val == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        self.set_carry_flag(false);
                        return 16;
                    },
                    0x37 => { // SWAP A
                        const original_a = self.a;
                        self.a = (original_a << 4) | (original_a >> 4);
                        self.f = 0;
                        self.set_zero_flag(self.a == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        self.set_carry_flag(false);
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
                    0x39 => { // SRL C
                        const original_c = self.c;
                        self.f = 0;
                        self.set_carry_flag((original_c & 0x01) != 0);
                        self.c = original_c >> 1;
                        self.set_zero_flag(self.c == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x3A => { // SRL D
                        const original_d = self.d;
                        self.f = 0;
                        self.set_carry_flag((original_d & 0x01) != 0);
                        self.d = original_d >> 1;
                        self.set_zero_flag(self.d == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x3B => { // SRL E
                        const original_e = self.e;
                        self.f = 0;
                        self.set_carry_flag((original_e & 0x01) != 0);
                        self.e = original_e >> 1;
                        self.set_zero_flag(self.e == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x3C => { // SRL H
                        const original_h = self.h;
                        self.f = 0;
                        self.set_carry_flag((original_h & 0x01) != 0);
                        self.h = original_h >> 1;
                        self.set_zero_flag(self.h == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x3D => { // SRL L
                        const original_l = self.l;
                        self.f = 0;
                        self.set_carry_flag((original_l & 0x01) != 0);
                        self.l = original_l >> 1;
                        self.set_zero_flag(self.l == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x3E => { // SRL (HL)
                        const addr = self.get_hl();
                        const original_val = bus.read(addr);
                        self.f = 0;
                        self.set_carry_flag((original_val & 0x01) != 0);
                        const new_val = original_val >> 1;
                        bus.write(addr, new_val);
                        self.set_zero_flag(new_val == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 16;
                    },
                    0x3F => { // SRL A
                        const original_a = self.a;
                        self.f = 0;
                        self.set_carry_flag((original_a & 0x01) != 0);
                        self.a = original_a >> 1;
                        self.set_zero_flag(self.a == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(false);
                        return 8;
                    },
                    0x40 => { // BIT 0, B
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.b & (1 << 0)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x41 => { // BIT 0, C
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.c & (1 << 0)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x42 => { // BIT 0, D
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.d & (1 << 0)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x43 => { // BIT 0, E
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.e & (1 << 0)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x44 => { // BIT 0, H
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.h & (1 << 0)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x45 => { // BIT 0, L
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.l & (1 << 0)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x46 => { // BIT 0, (HL)
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((bus.read(self.get_hl()) & (1 << 0)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 12;
                    },
                    0x47 => { // BIT 0, A
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.a & (1 << 0)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x48 => { // BIT 1, B
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.b & (1 << 1)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x49 => { // BIT 1, C
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.c & (1 << 1)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x4A => { // BIT 1, D
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.d & (1 << 1)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x4B => { // BIT 1, E
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.e & (1 << 1)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x4C => { // BIT 1, H
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.h & (1 << 1)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x4D => { // BIT 1, L
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.l & (1 << 1)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x4E => { // BIT 1, (HL)
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((bus.read(self.get_hl()) & (1 << 1)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 12;
                    },
                    0x4F => { // BIT 1, A
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.a & (1 << 1)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x50 => { // BIT 2, B
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.b & (1 << 2)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x51 => { // BIT 2, C
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.c & (1 << 2)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x52 => { // BIT 2, D
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.d & (1 << 2)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x53 => { // BIT 2, E
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.e & (1 << 2)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x54 => { // BIT 2, H
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.h & (1 << 2)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x55 => { // BIT 2, L
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.l & (1 << 2)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x56 => { // BIT 2, (HL)
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((bus.read(self.get_hl()) & (1 << 2)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 12;
                    },
                    0x57 => { // BIT 2, A
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.a & (1 << 2)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x58 => { // BIT 3, B
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.b & (1 << 3)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x59 => { // BIT 3, C
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.c & (1 << 3)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x5A => { // BIT 3, D
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.d & (1 << 3)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x5B => { // BIT 3, E
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.e & (1 << 3)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x5C => { // BIT 3, H
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.h & (1 << 3)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x5D => { // BIT 3, L
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.l & (1 << 3)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x5E => { // BIT 3, (HL)
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((bus.read(self.get_hl()) & (1 << 3)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 12;
                    },

                    0x5F => { // BIT 3, A
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.a & (1 << 3)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x60 => { // BIT 4, B
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.b & (1 << 4)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x61 => { // BIT 4, C
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.c & (1 << 4)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x62 => { // BIT 4, D
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.d & (1 << 4)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x63 => { // BIT 4, E
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.e & (1 << 4)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x64 => { // BIT 4, H
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.h & (1 << 4)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x65 => { // BIT 4, L
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.l & (1 << 4)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x66 => { // BIT 4, (HL)
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((bus.read(self.get_hl()) & (1 << 4)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 12;
                    },
                    0x67 => { // BIT 4, A
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.a & (1 << 4)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x68 => { // BIT 5, B
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.b & (1 << 5)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x69 => { // BIT 5, C
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.c & (1 << 5)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x6A => { // BIT 5, D
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.d & (1 << 5)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x6B => { // BIT 5, E
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.e & (1 << 5)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x6C => { // BIT 5, H
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.h & (1 << 5)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x6D => { // BIT 5, L
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.l & (1 << 5)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x6E => { // BIT 5, (HL)
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((bus.read(self.get_hl()) & (1 << 5)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 12;
                    },

                    0x6F => { // BIT 5, A
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.a & (1 << 5)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x70 => { // BIT 6, B
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.b & (1 << 6)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x71 => { // BIT 6, C
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.c & (1 << 6)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x72 => { // BIT 6, D
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.d & (1 << 6)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x73 => { // BIT 6, E
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.e & (1 << 6)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x74 => { // BIT 6, H
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.h & (1 << 6)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },
                    0x75 => { // BIT 6, L
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.l & (1 << 6)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x76 => { // BIT 6, (HL)
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((bus.read(self.get_hl()) & (1 << 6)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 12;
                    },

                    0x77 => { // BIT 6, A
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.a & (1 << 6)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x78 => { // BIT 7, B
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.b & (1 << 7)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x79 => { // BIT 7, C
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.c & (1 << 7)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x7A => { // BIT 7, D
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.d & (1 << 7)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x7B => { // BIT 7, E
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.e & (1 << 7)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x7C => { // BIT 7, H
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.h & (1 << 7)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x7D => { // BIT 7, L
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.l & (1 << 7)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x7E => { // BIT 7, (HL)
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((bus.read(self.get_hl()) & (1 << 7)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 12;
                    },
                    0x7F => { // BIT 7, A
                        const c_flag_preserved = self.f & C_FLAG;
                        self.f = 0;
                        self.set_zero_flag((self.a & (1 << 7)) == 0);
                        self.set_substract_flag(false);
                        self.set_half_carry_flag(true);
                        self.f |= c_flag_preserved;
                        return 8;
                    },

                    0x80 => { // RES 0, B
                        self.b &= ~@as(u8, 1 << 0);
                        return 8;
                    },

                    0x81 => { // RES 0, C
                        self.c &= ~@as(u8, 1 << 0);
                        return 8;
                    },

                    0x82 => { // RES 0, D
                        self.d &= ~@as(u8, 1 << 0);
                        return 8;
                    },
                    0x83 => { // RES 0, E
                        self.e &= ~@as(u8, 1 << 0);
                        return 8;
                    },
                    0x84 => { // RES 0, H
                        self.h &= ~@as(u8, 1 << 0);
                        return 8;
                    },
                    0x85 => { // RES 0, L
                        self.l &= ~@as(u8, 1 << 0);
                        return 8;
                    },
                    0x86 => { // RES 0, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) & ~@as(u8, 1 << 0));
                        return 16;
                    },
                    0x87 => { // RES 0, A
                        self.a &= ~@as(u8, 1 << 0);
                        return 8;
                    },
                    0x88 => { // RES 1, B
                        self.b &= ~@as(u8, 1 << 1);
                        return 8;
                    },

                    0x89 => { // RES 1, C
                        self.c &= ~@as(u8, 1 << 1);
                        return 8;
                    },
                    0x8A => { // RES 1, D
                        self.d &= ~@as(u8, 1 << 1);
                        return 8;
                    },
                    0x8B => { // RES 1, E
                        self.e &= ~@as(u8, 1 << 1);
                        return 8;
                    },
                    0x8C => { // RES 1, H
                        self.h &= ~@as(u8, 1 << 1);
                        return 8;
                    },
                    0x8D => { // RES 1, L
                        self.l &= ~@as(u8, 1 << 1);
                        return 8;
                    },
                    0x8E => { // RES 1, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) & ~@as(u8, 1 << 1));
                        return 16;
                    },
                    0x8F => { // RES 1, A
                        self.a &= ~@as(u8, 1 << 1);
                        return 8;
                    },
                    0x90 => { // RES 2, B
                        self.b &= ~@as(u8, 1 << 2);
                        return 8;
                    },
                    0x91 => { // RES 2, C
                        self.c &= ~@as(u8, 1 << 2);
                        return 8;
                    },
                    0x92 => { // RES 2, D
                        self.d &= ~@as(u8, 1 << 2);
                        return 8;
                    },
                    0x93 => { // RES 2, E
                        self.e &= ~@as(u8, 1 << 2);
                        return 8;
                    },
                    0x94 => { // RES 2, H
                        self.h &= ~@as(u8, 1 << 2);
                        return 8;
                    },

                    0x95 => { // RES 2, L
                        self.l &= ~@as(u8, 1 << 2);
                        return 8;
                    },
                    0x96 => { // RES 2, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) & ~@as(u8, 1 << 2));
                        return 16;
                    },
                    0x97 => { // RES 2, A
                        self.a &= ~@as(u8, 1 << 2);
                        return 8;
                    },
                    0x98 => { // RES 3, B
                        self.b &= ~@as(u8, 1 << 3);
                        return 8;
                    },
                    0x99 => { // RES 3, C
                        self.c &= ~@as(u8, 1 << 3);
                        return 8;
                    },
                    0x9A => { // RES 3, D
                        self.d &= ~@as(u8, 1 << 3);
                        return 8;
                    },
                    0x9B => { // RES 3, E
                        self.e &= ~@as(u8, 1 << 3);
                        return 8;
                    },
                    0x9C => { // RES 3, H
                        self.h &= ~@as(u8, 1 << 3);
                        return 8;
                    },
                    0x9D => { // RES 3, L
                        self.l &= ~@as(u8, 1 << 3);
                        return 8;
                    },
                    0x9E => { // RES 3, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) & ~@as(u8, 1 << 3));
                        return 16;
                    },
                    0x9F => { // RES 3, A
                        self.a &= ~@as(u8, 1 << 3);
                        return 8;
                    },
                    0xA0 => { // RES 4, B
                        self.b &= ~@as(u8, 1 << 4);
                        return 8;
                    },
                    0xA1 => { // RES 4, C
                        self.c &= ~@as(u8, 1 << 4);
                        return 8;
                    },
                    0xA2 => { // RES 4, D
                        self.d &= ~@as(u8, 1 << 4);
                        return 8;
                    },
                    0xA3 => { // RES 4, E
                        self.e &= ~@as(u8, 1 << 4);
                        return 8;
                    },
                    0xA4 => { // RES 4, H
                        self.h &= ~@as(u8, 1 << 4);
                        return 8;
                    },
                    0xA5 => { // RES 4, L
                        self.l &= ~@as(u8, 1 << 4);
                        return 8;
                    },
                    0xA6 => { // RES 4, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) & ~@as(u8, 1 << 4));
                        return 16;
                    },
                    0xA7 => { // RES 4, A
                        self.a &= ~@as(u8, 1 << 4);
                        return 8;
                    },
                    0xA8 => { // RES 5, B
                        self.b &= ~@as(u8, 1 << 5);
                        return 8;
                    },
                    0xA9 => { // RES 5, C
                        self.c &= ~@as(u8, 1 << 5);
                        return 8;
                    },
                    0xAA => { // RES 5, D
                        self.d &= ~@as(u8, 1 << 5);
                        return 8;
                    },
                    0xAB => { // RES 5, E
                        self.e &= ~@as(u8, 1 << 5);
                        return 8;
                    },
                    0xAC => { // RES 5, H
                        self.h &= ~@as(u8, 1 << 5);
                        return 8;
                    },
                    0xAD => { // RES 5, L
                        self.l &= ~@as(u8, 1 << 5);
                        return 8;
                    },
                    0xAE => { // RES 5, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) & ~@as(u8, 1 << 5));
                        return 16;
                    },
                    0xAF => { // RES 5, A
                        self.a &= ~@as(u8, 1 << 5);
                        return 8;
                    },
                    0xB0 => { // RES 6, B
                        self.b &= ~@as(u8, 1 << 6);
                        return 8;
                    },
                    0xB1 => { // RES 6, C
                        self.c &= ~@as(u8, 1 << 6);
                        return 8;
                    },
                    0xB2 => { // RES 6, D
                        self.d &= ~@as(u8, 1 << 6);
                        return 8;
                    },
                    0xB3 => { // RES 6, E
                        self.e &= ~@as(u8, 1 << 6);
                        return 8;
                    },
                    0xB4 => { // RES 6, H
                        self.h &= ~@as(u8, 1 << 6);
                        return 8;
                    },
                    0xB5 => { // RES 6, L
                        self.l &= ~@as(u8, 1 << 6);
                        return 8;
                    },
                    0xB6 => { // RES 6, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) & ~@as(u8, 1 << 6));
                        return 16;
                    },
                    0xB7 => { // RES 6, A
                        self.a &= ~@as(u8, 1 << 6);
                        return 8;
                    },
                    0xB8 => { // RES 7, B
                        self.b &= ~@as(u8, 1 << 7);
                        return 8;
                    },
                    0xB9 => { // RES 7, C
                        self.c &= ~@as(u8, 1 << 7);
                        return 8;
                    },
                    0xBA => { // RES 7, D
                        self.d &= ~@as(u8, 1 << 7);
                        return 8;
                    },
                    0xBB => { // RES 7, E
                        self.e &= ~@as(u8, 1 << 7);
                        return 8;
                    },
                    0xBC => { // RES 7, H
                        self.h &= ~@as(u8, 1 << 7);
                        return 8;
                    },
                    0xBD => { // RES 7, L
                        self.l &= ~@as(u8, 1 << 7);
                        return 8;
                    },

                    0xBE => { // RES 7, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) & ~@as(u8, 1 << 7));
                        return 16;
                    },
                    0xBF => { // RES 7, A
                        self.a &= ~@as(u8, 1 << 7);
                        return 8;
                    },
                    0xC0 => { // SET 0, B
                        self.b |= @as(u8, 1 << 0);
                        return 8;
                    },

                    0xC1 => { // SET 0, C
                        self.c |= @as(u8, 1 << 0);
                        return 8;
                    },
                    0xC2 => { // SET 0, D
                        self.d |= @as(u8, 1 << 0);
                        return 8;
                    },
                    0xC3 => { // SET 0, E
                        self.e |= @as(u8, 1 << 0);
                        return 8;
                    },
                    0xC4 => { // SET 0, H
                        self.h |= @as(u8, 1 << 0);
                        return 8;
                    },
                    0xC5 => { // SET 0, L
                        self.l |= @as(u8, 1 << 0);
                        return 8;
                    },
                    0xC6 => { // SET 0, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) | @as(u8, 1 << 0));
                        return 16;
                    },
                    0xC7 => { // SET 0, A
                        self.a |= @as(u8, 1 << 0);
                        return 8;
                    },
                    0xC8 => { // SET 1, B
                        self.b |= @as(u8, 1 << 1);
                        return 8;
                    },
                    0xC9 => { // SET 1, C
                        self.c |= @as(u8, 1 << 1);
                        return 8;
                    },
                    0xCA => { // SET 1, D
                        self.d |= @as(u8, 1 << 1);
                        return 8;
                    },
                    0xCB => { // SET 1, E
                        self.e |= @as(u8, 1 << 1);
                        return 8;
                    },
                    0xCC => { // SET 1, H
                        self.h |= @as(u8, 1 << 1);
                        return 8;
                    },
                    0xCD => { // SET 1, L
                        self.l |= @as(u8, 1 << 1);
                        return 8;
                    },
                    0xCE => { // SET 1, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) | @as(u8, 1 << 1));
                        return 16;
                    },
                    0xCF => { // SET 1, A
                        self.a |= @as(u8, 1 << 1);
                        return 8;
                    },
                    0xD0 => { // SET 2, B
                        self.b |= @as(u8, 1 << 2);
                        return 8;
                    },
                    0xD1 => { // SET 2, C
                        self.c |= @as(u8, 1 << 2);
                        return 8;
                    },
                    0xD2 => { // SET 2, D
                        self.d |= @as(u8, 1 << 2);
                        return 8;
                    },
                    0xD3 => { // SET 2, E
                        self.e |= @as(u8, 1 << 2);
                        return 8;
                    },
                    0xD4 => { // SET 2, H
                        self.h |= @as(u8, 1 << 2);
                        return 8;
                    },
                    0xD5 => { // SET 2, L
                        self.l |= @as(u8, 1 << 2);
                        return 8;
                    },
                    0xD6 => { // SET 2, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) | @as(u8, 1 << 2));
                        return 16;
                    },
                    0xD7 => { // SET 2, A
                        self.a |= @as(u8, 1 << 2);
                        return 8;
                    },
                    0xD8 => { // SET 3, B
                        self.b |= @as(u8, 1 << 3);
                        return 8;
                    },
                    0xD9 => { // SET 3, C
                        self.c |= @as(u8, 1 << 3);
                        return 8;
                    },
                    0xDA => { // SET 3, D
                        self.d |= @as(u8, 1 << 3);
                        return 8;
                    },
                    0xDB => { // SET 3, E
                        self.e |= @as(u8, 1 << 3);
                        return 8;
                    },
                    0xDC => { // SET 3, H
                        self.h |= @as(u8, 1 << 3);
                        return 8;
                    },
                    0xDD => { // SET 3, L
                        self.l |= @as(u8, 1 << 3);
                        return 8;
                    },
                    0xDE => { // SET 3, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) | @as(u8, 1 << 3));
                        return 16;
                    },
                    0xDF => { // SET 3, A
                        self.a |= @as(u8, 1 << 3);
                        return 8;
                    },
                    0xE0 => { // SET 4, B
                        self.b |= @as(u8, 1 << 4);
                        return 8;
                    },
                    0xE1 => { // SET 4, C
                        self.c |= @as(u8, 1 << 4);
                        return 8;
                    },
                    0xE2 => { // SET 4, D
                        self.d |= @as(u8, 1 << 4);
                        return 8;
                    },
                    0xE3 => { // SET 4, E
                        self.e |= @as(u8, 1 << 4);
                        return 8;
                    },
                    0xE4 => { // SET 4, H
                        self.h |= @as(u8, 1 << 4);
                        return 8;
                    },

                    0xE5 => { // SET 4, L
                        self.l |= @as(u8, 1 << 4);
                        return 8;
                    },
                    0xE6 => { // SET 4, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) | @as(u8, 1 << 4));
                        return 16;
                    },
                    0xE7 => { // SET 4, A
                        self.a |= @as(u8, 1 << 4);
                        return 8;
                    },
                    0xE8 => { // SET 5, B
                        self.b |= @as(u8, 1 << 5);
                        return 8;
                    },
                    0xE9 => { // SET 5, C
                        self.c |= @as(u8, 1 << 5);
                        return 8;
                    },
                    0xEA => { // SET 5, D
                        self.d |= @as(u8, 1 << 5);
                        return 8;
                    },
                    0xEB => { // SET 5, E
                        self.e |= @as(u8, 1 << 5);
                        return 8;
                    },
                    0xEC => { // SET 5, H
                        self.h |= @as(u8, 1 << 5);
                        return 8;
                    },
                    0xED => { // SET 5, L
                        self.l |= @as(u8, 1 << 5);
                        return 8;
                    },
                    0xEE => { // SET 5, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) | @as(u8, 1 << 5));
                        return 16;
                    },
                    0xEF => { // SET 5, A
                        self.a |= @as(u8, 1 << 5);
                        return 8;
                    },
                    0xF0 => { // SET 6, B
                        self.b |= @as(u8, 1 << 6);
                        return 8;
                    },
                    0xF1 => { // SET 6, C
                        self.c |= @as(u8, 1 << 6);
                        return 8;
                    },
                    0xF2 => { // SET 6, D
                        self.d |= @as(u8, 1 << 6);
                        return 8;
                    },
                    0xF3 => { // SET 6, E
                        self.e |= @as(u8, 1 << 6);
                        return 8;
                    },
                    0xF4 => { // SET 6, H
                        self.h |= @as(u8, 1 << 6);
                        return 8;
                    },
                    0xF5 => { // SET 6, L
                        self.l |= @as(u8, 1 << 6);
                        return 8;
                    },
                    0xF6 => { // SET 6, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) | @as(u8, 1 << 6));
                        return 16;
                    },
                    0xF7 => { // SET 6, A
                        self.a |= @as(u8, 1 << 6);
                        return 8;
                    },
                    0xF8 => { // SET 7, B
                        self.b |= @as(u8, 1 << 7);
                        return 8;
                    },
                    0xF9 => { // SET 7, C
                        self.c |= @as(u8, 1 << 7);
                        return 8;
                    },
                    0xFA => { // SET 7, D
                        self.d |= @as(u8, 1 << 7);
                        return 8;
                    },
                    0xFB => { // SET 7, E
                        self.e |= @as(u8, 1 << 7);
                        return 8;
                    },
                    0xFC => { // SET 7, H
                        self.h |= @as(u8, 1 << 7);
                        return 8;
                    },
                    0xFD => { // SET 7, L
                        self.l |= @as(u8, 1 << 7);
                        return 8;
                    },
                    0xFE => { // SET 7, (HL)
                        bus.write(self.get_hl(), bus.read(self.get_hl()) | @as(u8, 1 << 7));
                        return 16;
                    },
                    0xFF => { // SET 7, A
                        self.a |= @as(u8, 1 << 7);
                        return 8;
                    },
                    // else => |cb_op| {
                    //     std.log.err("FATAL: Unimplemented CB opcode 0x{x:0>2} at PC=0x{x:0>4}", .{ cb_op, self.pc - 2 });
                    //     unreachable;
                    // },
                }
            },
            0xCC => { // CALL Z, u16
                const addr_lo: u8 = bus.read(self.pc + 1);
                const addr_hi: u8 = bus.read(self.pc + 2);
                const target_addr: u16 = (@as(u16, addr_hi) << 8) | addr_lo;
                self.pc += 3;

                if (self.get_zero_flag()) {
                    self.sp -%= 1;
                    bus.write(self.sp, @truncate(self.pc >> 8));
                    self.sp -%= 1;
                    bus.write(self.sp, @truncate(self.pc));
                    self.pc = target_addr;
                    return 24;
                }

                return 12;
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
            0xCF => { // RST 08h
                const ret_addr = self.pc + 1;
                const pc_hi: u8 = @truncate(ret_addr >> 8);
                const pc_lo: u8 = @truncate(ret_addr);
                self.sp -%= 1;
                bus.write(self.sp, pc_hi);
                self.sp -%= 1;
                bus.write(self.sp, pc_lo);
                self.pc = 0x0008;
                return 16;
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
            0xD2 => { // JP NC, u16
                const low = bus.read(self.pc + 1);
                const high = bus.read(self.pc + 2);

                if ((self.f & C_FLAG) == 0) {
                    const addr = (@as(u16, high) << 8) | @as(u16, low);
                    self.pc = addr;
                    return 16;
                } else {
                    self.pc += 3;
                    return 12;
                }
            },
            0xD3 => {
                std.log.err("FATAL: Unimplemented opcode 0xD3 at PC=0x{x:0>4}", .{self.pc});
                unreachable;
            },
            0xD4 => { // CALL NC, u16
                const low = bus.read(self.pc + 1);
                const high = bus.read(self.pc + 2);
                if ((self.f & C_FLAG) == 0) {
                    const ret_addr = self.pc + 3;
                    self.sp -%= 1;
                    bus.write(self.sp, @truncate(ret_addr >> 8));
                    self.sp -%= 1;
                    bus.write(self.sp, @truncate(ret_addr));
                    self.pc = (@as(u16, high) << 8) | @as(u16, low);
                    return 24;
                } else {
                    self.pc += 3;
                    return 12;
                }
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
            0xD7 => { // RST 10h
                const ret_addr = self.pc + 1;
                const pc_hi: u8 = @truncate(ret_addr >> 8);
                const pc_lo: u8 = @truncate(ret_addr);
                self.sp -%= 1;
                bus.write(self.sp, pc_hi);
                self.sp -%= 1;
                bus.write(self.sp, pc_lo);
                self.pc = 0x0010;
                return 16;
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
            0xD9 => { // RETI
                const low = bus.read(self.sp);
                self.sp +%= 1;
                const high = bus.read(self.sp);
                self.sp +%= 1;
                self.pc = (@as(u16, high) << 8) | @as(u16, low);
                self.interrupt_master_enable = true; // Enable interrupts after RETI
                return 16;
            },
            0xDA => { // JP C, u16
                const low = bus.read(self.pc + 1);
                const high = bus.read(self.pc + 2);

                if ((self.f & C_FLAG) != 0) {
                    const addr = (@as(u16, high) << 8) | @as(u16, low);
                    self.pc = addr;
                    return 16;
                } else {
                    self.pc += 3;
                    return 12;
                }
            },
            0xDC => { // CALL C, u16
                const low = bus.read(self.pc + 1);
                const high = bus.read(self.pc + 2);
                if ((self.f & C_FLAG) != 0) {
                    const ret_addr = self.pc + 3;
                    self.sp -%= 1;
                    bus.write(self.sp, @truncate(ret_addr >> 8));
                    self.sp -%= 1;
                    bus.write(self.sp, @truncate(ret_addr));
                    self.pc = (@as(u16, high) << 8) | @as(u16, low);
                    return 24;
                } else {
                    self.pc += 3;
                    return 12;
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
            0xDF => { // RST 18h
                const ret_addr = self.pc + 1;
                const pc_hi: u8 = @truncate(ret_addr >> 8);
                const pc_lo: u8 = @truncate(ret_addr);
                self.sp -%= 1;
                bus.write(self.sp, pc_hi);
                self.sp -%= 1;
                bus.write(self.sp, pc_lo);
                self.pc = 0x0018;
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
            0xE7 => { // RST 20h
                const ret_addr = self.pc + 1;
                const pc_hi: u8 = @truncate(ret_addr >> 8);
                const pc_lo: u8 = @truncate(ret_addr);
                self.sp -%= 1;
                bus.write(self.sp, pc_hi);
                self.sp -%= 1;
                bus.write(self.sp, pc_lo);
                self.pc = 0x0020;
                return 16;
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
            0xF2 => { // LD A, (FF00 + C)
                const addr = 0xFF00 + @as(u16, self.c);
                self.a = bus.read(addr);
                self.pc += 1;
                return 8;
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
            0xFF => { // RST 38h
                const ret_addr = self.pc + 1;
                const pc_hi: u8 = @truncate(ret_addr >> 8);
                const pc_lo: u8 = @truncate(ret_addr);
                self.sp -%= 1;
                bus.write(self.sp, pc_hi);
                self.sp -%= 1;
                bus.write(self.sp, pc_lo);
                self.pc = 0x0038;
                return 16;
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
