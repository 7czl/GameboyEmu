// PPU (Pixel Processing Unit) with scanline rendering
// Renders BG, Window, and Sprites to a 160x144 framebuffer

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
    /// The various STAT sources are ORed together; an interrupt is
    /// requested only on a low-to-high transition (STAT blocking).
    pub fn update_stat_irq(self: *Ppu, bus: *Bus) void {
        const mode_val = @intFromEnum(self.mode);
        var line = false;

        // Mode 0 (HBlank) interrupt source
        if ((self.stat & 0x08 != 0) and mode_val == 0) line = true;
        // Mode 1 (VBlank) interrupt source
        if ((self.stat & 0x10 != 0) and mode_val == 1) line = true;
        // Mode 2 (OAM Scan) interrupt source
        if ((self.stat & 0x20 != 0) and mode_val == 2) line = true;
        // LYC=LY interrupt source
        if ((self.stat & 0x40 != 0) and (self.stat & 0x04 != 0)) line = true;

        // Rising edge detection
        if (line and !self.stat_irq_line) {
            bus.request_interrupt(.LCD_STAT);
        }
        self.stat_irq_line = line;
    }

    /// Update mode bits in STAT register
    fn set_mode(self: *Ppu, bus: *Bus) void {
        const new_mode = @intFromEnum(self.mode);
        self.stat = (self.stat & 0xFC) | new_mode;
        self.update_stat_irq(bus);
    }

    /// Check LY=LYC coincidence flag and update STAT interrupt line
    fn check_lyc(self: *Ppu, bus: *Bus) void {
        if (self.ly == self.lyc) {
            self.stat |= 0x04;
        } else {
            self.stat &= ~@as(u8, 0x04);
        }
        self.update_stat_irq(bus);
    }

    /// Resolve a 2-bit color index through a palette register
    fn palette_color(palette: u8, color_id: u2) u32 {
        const shade: u2 = @truncate((palette >> (@as(u3, color_id) * 2)) & 0x03);
        return DMG_COLORS[shade];
    }

    /// Direct VRAM/OAM read — avoids calling bus methods (Zig 0.15 circular dep workaround)
    fn vram_read(bus: *Bus, address: u16) u8 {
        return switch (address) {
            0x8000...0x9FFF => bus.vram[address - 0x8000],
            0xFE00...0xFE9F => bus.oam[address - 0xFE00],
            else => 0xFF,
        };
    }

    /// Render one scanline of the background layer
    fn render_bg_scanline(self: *Ppu, bus: *Bus) void {
        const display = self.display orelse return;
        if (self.lcdc & 0x01 == 0) {
            // BG disabled — fill with color 0
            const color = DMG_COLORS[0];
            for (0..160) |x| {
                display.set_pixel(@intCast(x), self.ly, color);
            }
            return;
        }

        // Tile map base: bit 3 of LCDC
        const tile_map_base: u16 = if (self.lcdc & 0x08 != 0) 0x9C00 else 0x9800;
        // Tile data base: bit 4 of LCDC
        const tile_data_unsigned = (self.lcdc & 0x10) != 0;

        const y = @as(u16, self.ly) +% @as(u16, self.scy);

        for (0..160) |screen_x| {
            const x = @as(u16, @intCast(screen_x)) +% @as(u16, self.scx);

            // Which tile in the 32x32 map
            const tile_col = (x >> 3) & 0x1F;
            const tile_row = (y >> 3) & 0x1F;
            const map_addr = tile_map_base + @as(u16, tile_row) * 32 + tile_col;
            const tile_id = vram_read(bus, map_addr);

            // Tile data address
            const tile_addr: u16 = if (tile_data_unsigned)
                0x8000 + @as(u16, tile_id) * 16
            else blk: {
                const signed_id: i8 = @bitCast(tile_id);
                const base: i32 = 0x9000;
                break :blk @intCast(@as(u32, @bitCast(base + @as(i32, signed_id) * 16)));
            };

            // Row within the tile (0-7)
            const tile_y: u16 = y & 0x07;
            const data_addr = tile_addr + tile_y * 2;
            const lo = vram_read(bus, data_addr);
            const hi = vram_read(bus, data_addr + 1);

            // Bit within the row (7 = leftmost pixel)
            const bit: u3 = @intCast(7 - (x & 0x07));
            const color_id: u2 = @truncate(
                ((@as(u8, hi) >> bit) & 1) << 1 | ((@as(u8, lo) >> bit) & 1),
            );

            display.set_pixel(@intCast(screen_x), self.ly, palette_color(self.bgp, color_id));
        }
    }

    /// Render one scanline of the window layer
    fn render_window_scanline(self: *Ppu, bus: *Bus) void {
        const display = self.display orelse return;
        // Window enable: LCDC bit 5, BG must also be enabled (bit 0)
        if (self.lcdc & 0x20 == 0 or self.lcdc & 0x01 == 0) return;
        // Window is only visible if WY <= current LY and WX <= 166
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

            const tile_addr: u16 = if (tile_data_unsigned)
                0x8000 + @as(u16, tile_id) * 16
            else blk: {
                const signed_id: i8 = @bitCast(tile_id);
                const base: i32 = 0x9000;
                break :blk @intCast(@as(u32, @bitCast(base + @as(i32, signed_id) * 16)));
            };

            const tile_y: u16 = win_y & 0x07;
            const data_addr = tile_addr + tile_y * 2;
            const lo = vram_read(bus, data_addr);
            const hi = vram_read(bus, data_addr + 1);

            const bit: u3 = @intCast(7 - (win_x & 0x07));
            const color_id: u2 = @truncate(
                ((@as(u8, hi) >> bit) & 1) << 1 | ((@as(u8, lo) >> bit) & 1),
            );

            display.set_pixel(@intCast(screen_x), self.ly, palette_color(self.bgp, color_id));
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
        // OBJ enable: LCDC bit 1
        if (self.lcdc & 0x02 == 0) return;

        const tall_sprites = (self.lcdc & 0x04) != 0; // 8x16 mode
        const sprite_height: i16 = if (tall_sprites) 16 else 8;

        // Collect sprites on this scanline (max 10)
        var sprite_indices: [10]u8 = undefined;
        var sprite_count: u8 = 0;

        for (0..40) |i| {
            const oam_offset: u16 = @intCast(i * 4);
            const sprite_y = @as(i16, vram_read(bus, 0xFE00 + oam_offset)) - 16;
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
            const oam_base: u16 = 0xFE00 + @as(u16, i) * 4;
            const sprite_y = @as(i16, vram_read(bus, oam_base)) - 16;
            const sprite_x = @as(i16, vram_read(bus, oam_base + 1)) - 8;
            var tile_id = vram_read(bus, oam_base + 2);
            const attrs = vram_read(bus, oam_base + 3);

            const bg_priority = (attrs & 0x80) != 0;
            const y_flip = (attrs & 0x40) != 0;
            const x_flip = (attrs & 0x20) != 0;
            const palette = if (attrs & 0x10 != 0) self.obp1 else self.obp0;

            if (tall_sprites) tile_id &= 0xFE;

            var line: i16 = @as(i16, self.ly) - sprite_y;
            if (line < 0 or line >= sprite_height) continue;
            if (y_flip) line = sprite_height - 1 - line;

            const line_u16: u16 = @intCast(line);
            const tile_addr: u16 = 0x8000 + @as(u16, tile_id) * 16 + line_u16 * 2;
            const lo = vram_read(bus, tile_addr);
            const hi = vram_read(bus, tile_addr + 1);

            for (0..8) |px| {
                const screen_x = sprite_x + @as(i16, @intCast(px));
                if (screen_x < 0 or screen_x >= 160) continue;

                const bit: u3 = if (x_flip)
                    @intCast(px)
                else
                    @intCast(7 - px);

                const color_id: u2 = @truncate(
                    ((@as(u8, hi) >> bit) & 1) << 1 | ((@as(u8, lo) >> bit) & 1),
                );

                // Color 0 is transparent for sprites
                if (color_id == 0) continue;

                // BG priority: if set, sprite is behind non-zero BG colors
                if (bg_priority) {
                    const sx: u32 = @intCast(screen_x);
                    const fb_idx = @as(u32, self.ly) * 160 + sx;
                    const back_buf = &display.buffers[display.back];
                    if (fb_idx < back_buf.len) {
                        const existing = back_buf[fb_idx];
                        if (existing != palette_color(self.bgp, 0)) continue;
                    }
                }

                display.set_pixel(
                    @intCast(screen_x),
                    self.ly,
                    palette_color(palette, color_id),
                );
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
                    // Render scanline at end of Drawing, before HBlank fires
                    self.render_scanline(bus);
                    self.mode = .HBlank;
                    self.set_mode(bus);
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
