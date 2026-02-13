// PPU (Pixel Processing Unit) with scanline rendering
// Renders BG, Window, and Sprites to a 160x144 framebuffer
// Supports both DMG and CGB modes

const Bus = @import("bus.zig").Bus;
const Display = @import("display.zig").Display;
const std = @import("std");

pub const PpuMode = enum(u8) {
    HBlank = 0,
    VBlank = 1,
    OAMScan = 2,
    Drawing = 3,
};

// DMG palette: white, light gray, dark gray, black (ARGB8888)
const DMG_COLORS = [4]u32{
    0xFF_E0_F8_D0, // lightest (greenish white)
    0xFF_88_C0_70, // light
    0xFF_34_68_56, // dark
    0xFF_08_18_20, // darkest
};

pub const Ppu = struct {
    ly: u8 = 0,
    cycle_counter: u16 = 0,
    enabled: bool = false,
    mode: PpuMode = .OAMScan,
    display: ?*Display = null,
    // Registers
    lcdc: u8 = 0x91,
    stat: u8 = 0,
    scy: u8 = 0,
    scx: u8 = 0,
    lyc: u8 = 0,
    bgp: u8 = 0xFC,
    obp0: u8 = 0xFF,
    obp1: u8 = 0xFF,
    wy: u8 = 0,
    wx: u8 = 0,
    // Internal window line counter
    window_line_counter: u8 = 0,
    window_was_active: bool = false,
    // STAT interrupt line state for rising-edge detection (STAT blocking)
    stat_irq_line: bool = false,
    // Per-pixel BG color index buffer for sprite priority (CGB BG-to-OBJ priority)
    bg_color_indices: [160]u8 = .{0} ** 160,
    // Per-pixel BG priority from tile attribute (CGB bit 7)
    bg_priority_flags: [160]bool = .{false} ** 160,

    pub fn init() Ppu {
        return Ppu{};
    }

    pub fn reset(self: *Ppu) void {
        self.ly = 0;
        self.cycle_counter = 0;
        self.enabled = false;
        self.mode = .OAMScan;
        self.stat &= 0xF8;
        self.window_line_counter = 0;
        self.window_was_active = false;
        self.stat_irq_line = false;
    }

    /// Evaluate the STAT interrupt line and fire on rising edge.
    pub fn update_stat_irq(self: *Ppu, bus: *Bus) void {
        const mode_val = @intFromEnum(self.mode);
        var line = false;
        if ((self.stat & 0x08 != 0) and mode_val == 0) line = true;
        if ((self.stat & 0x10 != 0) and mode_val == 1) line = true;
        if ((self.stat & 0x20 != 0) and mode_val == 2) line = true;
        if ((self.stat & 0x40 != 0) and (self.stat & 0x04 != 0)) line = true;
        if (line and !self.stat_irq_line) {
            bus.request_interrupt(.LCD_STAT);
        }
        self.stat_irq_line = line;
    }

    fn set_mode(self: *Ppu, bus: *Bus) void {
        const new_mode = @intFromEnum(self.mode);
        self.stat = (self.stat & 0xFC) | new_mode;
        self.update_stat_irq(bus);
    }

    fn check_lyc(self: *Ppu, bus: *Bus) void {
        if (self.ly == self.lyc) {
            self.stat |= 0x04;
        } else {
            self.stat &= ~@as(u8, 0x04);
        }
        self.update_stat_irq(bus);
    }

    /// Resolve a 2-bit color index through a DMG palette register
    fn palette_color(palette: u8, color_id: u2) u32 {
        const shade: u2 = @truncate((palette >> (@as(u3, color_id) * 2)) & 0x03);
        return DMG_COLORS[shade];
    }

    /// Convert CGB RGB555 to ARGB8888
    fn rgb555_to_argb(color_lo: u8, color_hi: u8) u32 {
        const raw = @as(u16, color_lo) | (@as(u16, color_hi) << 8);
        const r5: u8 = @truncate(raw & 0x1F);
        const g5: u8 = @truncate((raw >> 5) & 0x1F);
        const b5: u8 = @truncate((raw >> 10) & 0x1F);
        // Accurate color correction: (x << 3) | (x >> 2)
        const r8 = (r5 << 3) | (r5 >> 2);
        const g8 = (g5 << 3) | (g5 >> 2);
        const b8 = (b5 << 3) | (b5 >> 2);
        return (@as(u32, 0xFF) << 24) | (@as(u32, r8) << 16) | (@as(u32, g8) << 8) | @as(u32, b8);
    }

    /// Get CGB palette color from CRAM
    fn cgb_palette_color(cram: *const [64]u8, palette_num: u3, color_id: u2) u32 {
        const offset = @as(u8, palette_num) * 8 + @as(u8, color_id) * 2;
        return rgb555_to_argb(cram[offset], cram[offset + 1]);
    }

    /// Direct VRAM read from bank 0 (default)
    fn vram_read(bus: *Bus, address: u16) u8 {
        return bus.vram[0][address - 0x8000];
    }

    /// Direct VRAM read from specific bank
    fn vram_bank_read(bus: *Bus, bank: u1, address: u16) u8 {
        return bus.vram[bank][address - 0x8000];
    }

    /// Render one scanline of the background layer
    fn render_bg_scanline(self: *Ppu, bus: *Bus) void {
        const display = self.display orelse return;
        const cgb = bus.cgb_mode;

        if (!cgb and self.lcdc & 0x01 == 0) {
            // DMG: BG disabled — fill with color 0
            const color = DMG_COLORS[0];
            for (0..160) |x| {
                display.set_pixel(@intCast(x), self.ly, color);
                self.bg_color_indices[x] = 0;
                self.bg_priority_flags[x] = false;
            }
            return;
        }

        const tile_map_base: u16 = if (self.lcdc & 0x08 != 0) 0x9C00 else 0x9800;
        const tile_data_unsigned = (self.lcdc & 0x10) != 0;
        const y = @as(u16, self.ly) +% @as(u16, self.scy);

        for (0..160) |screen_x| {
            const x = @as(u16, @intCast(screen_x)) +% @as(u16, self.scx);
            const tile_col = (x >> 3) & 0x1F;
            const tile_row = (y >> 3) & 0x1F;
            const map_addr = tile_map_base + @as(u16, tile_row) * 32 + tile_col;

            // Tile ID always from VRAM bank 0
            const tile_id = vram_read(bus, map_addr);

            // CGB tile attributes from VRAM bank 1
            var bg_palette: u3 = 0;
            var tile_vram_bank: u1 = 0;
            var x_flip = false;
            var y_flip = false;
            var bg_prio = false;
            if (cgb) {
                const attrs = vram_bank_read(bus, 1, map_addr);
                bg_palette = @truncate(attrs & 0x07);
                tile_vram_bank = @truncate((attrs >> 3) & 0x01);
                x_flip = (attrs & 0x20) != 0;
                y_flip = (attrs & 0x40) != 0;
                bg_prio = (attrs & 0x80) != 0;
            }

            // Tile data address
            const tile_addr: u16 = if (tile_data_unsigned)
                0x8000 + @as(u16, tile_id) * 16
            else blk: {
                const signed_id: i8 = @bitCast(tile_id);
                const base: i32 = 0x9000;
                break :blk @intCast(@as(u32, @bitCast(base + @as(i32, signed_id) * 16)));
            };

            var tile_y: u16 = y & 0x07;
            if (y_flip) tile_y = 7 - tile_y;
            const data_addr = tile_addr + tile_y * 2;

            const lo = vram_bank_read(bus, tile_vram_bank, data_addr);
            const hi = vram_bank_read(bus, tile_vram_bank, data_addr + 1);

            var bit_x: u3 = @intCast(7 - (x & 0x07));
            if (x_flip) bit_x = @intCast(x & 0x07);

            const color_id: u2 = @truncate(
                ((@as(u8, hi) >> bit_x) & 1) << 1 | ((@as(u8, lo) >> bit_x) & 1),
            );

            self.bg_color_indices[screen_x] = color_id;
            self.bg_priority_flags[screen_x] = bg_prio;

            if (cgb) {
                display.set_pixel(@intCast(screen_x), self.ly, cgb_palette_color(&bus.bg_cram, bg_palette, color_id));
            } else {
                display.set_pixel(@intCast(screen_x), self.ly, palette_color(self.bgp, color_id));
            }
        }
    }

    /// Render one scanline of the window layer
    fn render_window_scanline(self: *Ppu, bus: *Bus) void {
        const display = self.display orelse return;
        const cgb = bus.cgb_mode;
        if (self.lcdc & 0x20 == 0) return;
        if (!cgb and self.lcdc & 0x01 == 0) return;
        if (self.ly < self.wy or self.wx > 166) return;

        const tile_map_base: u16 = if (self.lcdc & 0x40 != 0) 0x9C00 else 0x9800;
        const tile_data_unsigned = (self.lcdc & 0x10) != 0;
        const win_y: u16 = self.window_line_counter;
        var drew_pixel = false;

        for (0..160) |screen_x| {
            const wx_offset: i16 = @as(i16, @intCast(screen_x)) - (@as(i16, self.wx) - 7);
            if (wx_offset < 0) continue;
            const win_x: u16 = @intCast(wx_offset);

            const tile_col = (win_x >> 3) & 0x1F;
            const tile_row = (win_y >> 3) & 0x1F;
            const map_addr = tile_map_base + @as(u16, tile_row) * 32 + tile_col;
            const tile_id = vram_read(bus, map_addr);

            var bg_palette: u3 = 0;
            var tile_vram_bank: u1 = 0;
            var x_flip = false;
            var y_flip = false;
            var bg_prio = false;
            if (cgb) {
                const attrs = vram_bank_read(bus, 1, map_addr);
                bg_palette = @truncate(attrs & 0x07);
                tile_vram_bank = @truncate((attrs >> 3) & 0x01);
                x_flip = (attrs & 0x20) != 0;
                y_flip = (attrs & 0x40) != 0;
                bg_prio = (attrs & 0x80) != 0;
            }

            const tile_addr: u16 = if (tile_data_unsigned)
                0x8000 + @as(u16, tile_id) * 16
            else blk: {
                const signed_id: i8 = @bitCast(tile_id);
                const base: i32 = 0x9000;
                break :blk @intCast(@as(u32, @bitCast(base + @as(i32, signed_id) * 16)));
            };

            var tile_y: u16 = win_y & 0x07;
            if (y_flip) tile_y = 7 - tile_y;
            const data_addr = tile_addr + tile_y * 2;
            const lo = vram_bank_read(bus, tile_vram_bank, data_addr);
            const hi = vram_bank_read(bus, tile_vram_bank, data_addr + 1);

            var bit: u3 = @intCast(7 - (win_x & 0x07));
            if (x_flip) bit = @intCast(win_x & 0x07);

            const color_id: u2 = @truncate(
                ((@as(u8, hi) >> bit) & 1) << 1 | ((@as(u8, lo) >> bit) & 1),
            );

            self.bg_color_indices[screen_x] = color_id;
            self.bg_priority_flags[screen_x] = bg_prio;

            if (cgb) {
                display.set_pixel(@intCast(screen_x), self.ly, cgb_palette_color(&bus.bg_cram, bg_palette, color_id));
            } else {
                display.set_pixel(@intCast(screen_x), self.ly, palette_color(self.bgp, color_id));
            }
            drew_pixel = true;
        }

        if (drew_pixel) {
            self.window_line_counter += 1;
            self.window_was_active = true;
        }
    }

    /// Render sprites (OBJ) for the current scanline
    fn render_sprite_scanline(self: *Ppu, bus: *Bus) void {
        const display = self.display orelse return;
        const cgb = bus.cgb_mode;
        if (self.lcdc & 0x02 == 0) return;

        const tall_sprites = (self.lcdc & 0x04) != 0;
        const sprite_height: i16 = if (tall_sprites) 16 else 8;

        // Collect sprites on this scanline (max 10)
        var sprite_indices: [10]u8 = undefined;
        var sprite_count: u8 = 0;

        for (0..40) |i| {
            const oam_offset: u16 = @intCast(i * 4);
            const sprite_y = @as(i16, bus.oam[oam_offset]) - 16;
            const ly_i16: i16 = @intCast(self.ly);
            if (ly_i16 >= sprite_y and ly_i16 < sprite_y + sprite_height) {
                sprite_indices[sprite_count] = @intCast(i);
                sprite_count += 1;
                if (sprite_count >= 10) break;
            }
        }

        // Render in reverse order (lower OAM index = higher priority)
        var idx: u8 = sprite_count;
        while (idx > 0) {
            idx -= 1;
            const i = sprite_indices[idx];
            const oam_base: u16 = @as(u16, i) * 4;
            const sprite_y = @as(i16, bus.oam[oam_base]) - 16;
            const sprite_x = @as(i16, bus.oam[oam_base + 1]) - 8;
            var tile_id = bus.oam[oam_base + 2];
            const attrs = bus.oam[oam_base + 3];

            const obj_bg_priority = (attrs & 0x80) != 0;
            const y_flip = (attrs & 0x40) != 0;
            const x_flip = (attrs & 0x20) != 0;

            // CGB: palette from attr bits 0-2, VRAM bank from bit 3
            var obj_palette_num: u3 = 0;
            var obj_vram_bank: u1 = 0;
            if (cgb) {
                obj_palette_num = @truncate(attrs & 0x07);
                obj_vram_bank = @truncate((attrs >> 3) & 0x01);
            }
            const dmg_palette = if (attrs & 0x10 != 0) self.obp1 else self.obp0;

            if (tall_sprites) tile_id &= 0xFE;

            var line: i16 = @as(i16, self.ly) - sprite_y;
            if (line < 0 or line >= sprite_height) continue;
            if (y_flip) line = sprite_height - 1 - line;

            const line_u16: u16 = @intCast(line);
            const tile_addr: u16 = 0x8000 + @as(u16, tile_id) * 16 + line_u16 * 2;
            const lo = vram_bank_read(bus, if (cgb) obj_vram_bank else 0, tile_addr);
            const hi = vram_bank_read(bus, if (cgb) obj_vram_bank else 0, tile_addr + 1);

            for (0..8) |px| {
                const screen_x = sprite_x + @as(i16, @intCast(px));
                if (screen_x < 0 or screen_x >= 160) continue;
                const sx: u32 = @intCast(screen_x);

                const bit: u3 = if (x_flip)
                    @intCast(px)
                else
                    @intCast(7 - px);

                const color_id: u2 = @truncate(
                    ((@as(u8, hi) >> bit) & 1) << 1 | ((@as(u8, lo) >> bit) & 1),
                );

                if (color_id == 0) continue; // transparent

                // Priority logic
                if (cgb) {
                    // CGB priority: LCDC bit 0 acts as master priority
                    // If LCDC.0 = 1: BG tile attr bit 7 or OAM attr bit 7 can hide sprite
                    if (self.lcdc & 0x01 != 0) {
                        // BG tile has priority flag set
                        if (self.bg_priority_flags[sx] and self.bg_color_indices[sx] != 0) continue;
                        // OAM priority flag set and BG is non-zero
                        if (obj_bg_priority and self.bg_color_indices[sx] != 0) continue;
                    }
                    display.set_pixel(sx, self.ly, cgb_palette_color(&bus.obj_cram, obj_palette_num, color_id));
                } else {
                    // DMG priority
                    if (obj_bg_priority) {
                        if (self.bg_color_indices[sx] != 0) continue;
                    }
                    display.set_pixel(sx, self.ly, palette_color(dmg_palette, color_id));
                }
            }
        }
    }

    /// Render a complete scanline (BG + Window + Sprites)
    fn render_scanline(self: *Ppu, bus: *Bus) void {
        self.render_bg_scanline(bus);
        self.render_window_scanline(bus);
        self.render_sprite_scanline(bus);
    }

    pub fn step(self: *Ppu, bus: *Bus, cycles: u16) void {
        if (!self.enabled) return;

        self.cycle_counter += cycles;

        switch (self.mode) {
            .OAMScan => {
                if (self.cycle_counter >= 80) {
                    self.cycle_counter -= 80;
                    self.mode = .Drawing;
                    self.set_mode(bus);
                }
            },
            .Drawing => {
                if (self.cycle_counter >= 172) {
                    self.cycle_counter -= 172;
                    self.render_scanline(bus);
                    self.mode = .HBlank;
                    self.set_mode(bus);
                    // CGB HBlank DMA
                    if (bus.cgb_mode) {
                        bus.do_hblank_hdma();
                    }
                }
            },
            .HBlank => {
                if (self.cycle_counter >= 204) {
                    self.cycle_counter -= 204;
                    self.ly += 1;

                    if (self.ly == 144) {
                        self.mode = .VBlank;
                        bus.request_interrupt(.VBlank);
                        self.set_mode(bus);
                        self.check_lyc(bus);
                        if (self.display) |d| d.update();
                    } else {
                        self.mode = .OAMScan;
                        self.check_lyc(bus);
                        self.set_mode(bus);
                    }
                }
            },
            .VBlank => {
                if (self.cycle_counter >= 456) {
                    self.cycle_counter -= 456;
                    self.ly += 1;
                    if (self.ly > 153) {
                        self.ly = 0;
                        self.window_line_counter = 0;
                        self.window_was_active = false;
                        self.mode = .OAMScan;
                        self.check_lyc(bus);
                        self.set_mode(bus);
                    } else {
                        self.check_lyc(bus);
                    }
                }
            },
        }
    }
};
