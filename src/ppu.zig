// PPU (Pixel Processing Unit) with pixel FIFO rendering
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
const DMG_COLORS = [4]u32{
    0xFF_E0_F8_D0,
    0xFF_88_C0_70,
    0xFF_34_68_56,
    0xFF_08_18_20,
};
const FifoPixel = struct {
    color: u2 = 0,
    palette: u3 = 0,
    bg_priority: bool = false,
    is_sprite: bool = false,
    sprite_dmg_palette: u8 = 0,
    oam_index: u8 = 0,
};
const PixelFifo = struct {
    pixels: [16]FifoPixel = @splat(FifoPixel{}),
    head: u4 = 0,
    count: u4 = 0,
    fn push(self: *PixelFifo, p: FifoPixel) void {
        if (self.count >= 15) return;
        const idx = (self.head +% self.count) & 0xF;
        self.pixels[idx] = p;
        self.count += 1;
    }
    fn pop(self: *PixelFifo) FifoPixel {
        const p = self.pixels[self.head];
        self.head = (self.head +% 1) & 0xF;
        self.count -= 1;
        return p;
    }
    fn clear(self: *PixelFifo) void {
        self.head = 0;
        self.count = 0;
    }
    fn len(self: *const PixelFifo) u4 {
        return self.count;
    }
    fn overlay_at(self: *PixelFifo, pos: u4, sp: FifoPixel, cgb_mode: bool, master_priority: bool, oam_priority: bool) void {
        const idx = (self.head +% pos) & 0xF;
        const existing = self.pixels[idx];
        if (existing.is_sprite) {
            // In CGB OAM priority mode, lower OAM index wins over higher
            if (cgb_mode and oam_priority and sp.oam_index < existing.oam_index) {
                // New sprite has lower OAM index — it wins
                self.pixels[idx] = sp;
            }
            return;
        }
        if (sp.color == 0) return;
        if (cgb_mode) {
            // CGB priority: LCDC bit 0 is "master priority"
            if (master_priority) {
                // Master priority enabled: check BG map attr bit 7 and OAM attr bit 7
                if (existing.bg_priority and existing.color != 0) return; // BG map attr bit 7 set
                if (sp.bg_priority and existing.color != 0) return; // OAM attr bit 7 set
            }
            // Master priority disabled (LCDC bit 0 = 0): sprites always on top
        } else {
            // DMG: OAM attr bit 7 only
            if (sp.bg_priority and existing.color != 0) return;
        }
        self.pixels[idx] = sp;
    }
};
const OamEntry = struct {
    y: i16,
    x: i16,
    tile: u8,
    attrs: u8,
    oam_index: u8,
};
const FetcherState = enum {
    read_tile_id,
    read_tile_data_lo,
    read_tile_data_hi,
    push,
};
pub const Ppu = struct {
    ly: u8 = 0,
    cycle_counter: u16 = 0,
    enabled: bool = false,
    mode: PpuMode = .OAMScan,
    display: ?*Display = null,
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
    window_line_counter: u8 = 0,
    window_was_active: bool = false,
    stat_irq_line: bool = false,
    bg_fifo: PixelFifo = .{},
    pixels_pushed: u8 = 0,
    fetcher_x: u8 = 0,
    fetcher_state: FetcherState = .read_tile_id,
    fetcher_ticks: u8 = 0,
    fetch_tile_id: u8 = 0,
    fetch_tile_lo: u8 = 0,
    fetch_tile_hi: u8 = 0,
    fetch_tile_attrs: u8 = 0,
    scx_discard: u8 = 0,
    in_window: bool = false,
    window_triggered: bool = false,
    initial_fetch_done: bool = false,
    wy_latch: bool = false,
    scanline_sprites: [10]OamEntry = undefined,
    sprite_count: u8 = 0,
    sprite_fetch_active: bool = false,
    sprite_fetch_idx: u8 = 0,
    sprite_fetch_ticks: u8 = 0,
    sprite_tile_lo: u8 = 0,
    sprite_tile_hi: u8 = 0,
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
        self.wy_latch = false;
    }
    pub fn update_stat_irq(self: *Ppu, bus: *Bus) void {
        const mode_val = @intFromEnum(self.mode);
        var line = false;
        if ((self.stat & 0x08 != 0) and mode_val == 0) line = true;
        if ((self.stat & 0x10 != 0) and mode_val == 1) line = true;
        if ((self.stat & 0x20 != 0) and mode_val == 2) line = true;
        if ((self.stat & 0x40 != 0) and (self.stat & 0x04 != 0)) line = true;
        if (line and !self.stat_irq_line) bus.request_interrupt(.LCD_STAT);
        self.stat_irq_line = line;
    }
    fn set_mode(self: *Ppu, bus: *Bus) void {
        self.stat = (self.stat & 0xFC) | @intFromEnum(self.mode);
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
    fn palette_color(palette: u8, color_id: u2) u32 {
        const shade: u2 = @truncate((palette >> (@as(u3, color_id) * 2)) & 0x03);
        return DMG_COLORS[shade];
    }
    fn rgb555_to_argb(color_lo: u8, color_hi: u8) u32 {
        const raw = @as(u16, color_lo) | (@as(u16, color_hi) << 8);
        const r5: u8 = @truncate(raw & 0x1F);
        const g5: u8 = @truncate((raw >> 5) & 0x1F);
        const b5: u8 = @truncate((raw >> 10) & 0x1F);
        return (@as(u32, 0xFF) << 24) | (@as(u32, (r5 << 3) | (r5 >> 2)) << 16) |
            (@as(u32, (g5 << 3) | (g5 >> 2)) << 8) | @as(u32, (b5 << 3) | (b5 >> 2));
    }
    fn cgb_palette_color(cram: *const [64]u8, palette_num: u3, color_id: u2) u32 {
        const offset = @as(u8, palette_num) * 8 + @as(u8, color_id) * 2;
        return rgb555_to_argb(cram[offset], cram[offset + 1]);
    }
    fn oam_scan(self: *Ppu, bus: *Bus) void {
        self.sprite_count = 0;
        const tall = (self.lcdc & 0x04) != 0;
        const h: i16 = if (tall) 16 else 8;
        const ly_i: i16 = @intCast(self.ly);
        for (0..40) |i| {
            const base: u16 = @intCast(i * 4);
            const sy = @as(i16, bus.oam[base]) - 16;
            if (ly_i >= sy and ly_i < sy + h) {
                self.scanline_sprites[self.sprite_count] = .{
                    .y = sy,
                    .x = @as(i16, bus.oam[base + 1]) - 8,
                    .tile = bus.oam[base + 2],
                    .attrs = bus.oam[base + 3],
                    .oam_index = @intCast(i),
                };
                self.sprite_count += 1;
                if (self.sprite_count >= 10) break;
            }
        }
    }
    fn start_drawing(self: *Ppu) void {
        self.bg_fifo.clear();
        self.pixels_pushed = 0;
        self.fetcher_x = 0;
        self.fetcher_state = .read_tile_id;
        self.fetcher_ticks = 0;
        self.scx_discard = self.scx & 0x07;
        self.in_window = false;
        self.window_triggered = false;
        self.sprite_fetch_active = false;
        self.initial_fetch_done = false;
    }
    fn check_sprite_at(self: *Ppu, screen_x: u8) ?u8 {
        if (self.lcdc & 0x02 == 0) return null;
        const sx: i16 = @intCast(screen_x);
        for (0..self.sprite_count) |i| {
            const sprite_x = self.scanline_sprites[i].x;
            if (sprite_x == sx) return @intCast(i);
            if (sx == 0 and sprite_x < 0 and sprite_x > -8) return @intCast(i);
        }
        return null;
    }
    fn fetch_sprite(self: *Ppu, bus: *Bus, sprite_idx: u8) void {
        const sprite = self.scanline_sprites[sprite_idx];
        const tall = (self.lcdc & 0x04) != 0;
        const y_flip = (sprite.attrs & 0x40) != 0;
        const x_flip = (sprite.attrs & 0x20) != 0;
        const cgb = bus.cgb_mode;
        var tile_id = sprite.tile;
        if (tall) tile_id &= 0xFE;
        var line: i16 = @as(i16, self.ly) - sprite.y;
        const sprite_h: i16 = if (tall) 16 else 8;
        // Guard against out-of-range line (can happen if OAM is modified between scan and draw)
        if (line < 0 or line >= sprite_h) return;
        if (y_flip) line = sprite_h - 1 - line;
        const line_u16: u16 = @intCast(line);
        const tile_addr: u16 = 0x8000 + @as(u16, tile_id) * 16 + line_u16 * 2;
        var vbank: u1 = 0;
        if (cgb) vbank = @truncate((sprite.attrs >> 3) & 0x01);
        const lo = bus.vram[vbank][tile_addr - 0x8000];
        const hi = bus.vram[vbank][tile_addr + 1 - 0x8000];
        const screen_x: i16 = @intCast(self.pixels_pushed);
        const fifo_len = self.bg_fifo.len();
        for (0..8) |px| {
            const px_screen = sprite.x + @as(i16, @intCast(px));
            if (px_screen < 0 or px_screen >= 160) continue;
            const fifo_pos_i = px_screen - screen_x;
            if (fifo_pos_i < 0 or fifo_pos_i >= fifo_len) continue;
            const fifo_pos: u4 = @intCast(fifo_pos_i);
            const bit: u3 = if (x_flip) @intCast(px) else @intCast(7 - px);
            const color_id: u2 = @truncate(
                ((@as(u8, hi) >> bit) & 1) << 1 | ((@as(u8, lo) >> bit) & 1),
            );
            if (color_id == 0) continue;
            var sp_pixel = FifoPixel{
                .color = color_id,
                .is_sprite = true,
                .bg_priority = (sprite.attrs & 0x80) != 0,
                .oam_index = sprite.oam_index,
            };
            if (cgb) {
                sp_pixel.palette = @truncate(sprite.attrs & 0x07);
            } else {
                sp_pixel.sprite_dmg_palette = if (sprite.attrs & 0x10 != 0) self.obp1 else self.obp0;
            }
            const master_priority = (self.lcdc & 0x01) != 0;
            self.bg_fifo.overlay_at(fifo_pos, sp_pixel, cgb, master_priority, bus.obj_priority_by_oam);
        }
    }
    fn bg_fetch_tick(self: *Ppu, bus: *Bus) void {
        self.fetcher_ticks += 1;
        if (self.fetcher_ticks < 2) return;
        self.fetcher_ticks = 0;
        switch (self.fetcher_state) {
            .read_tile_id => {
                var tile_map_base: u16 = undefined;
                var tile_x: u8 = undefined;
                var tile_y: u8 = undefined;
                if (self.in_window) {
                    tile_map_base = if (self.lcdc & 0x40 != 0) @as(u16, 0x9C00) else @as(u16, 0x9800);
                    tile_x = self.fetcher_x;
                    tile_y = self.window_line_counter / 8;
                } else {
                    tile_map_base = if (self.lcdc & 0x08 != 0) @as(u16, 0x9C00) else @as(u16, 0x9800);
                    tile_x = ((self.scx / 8) +% self.fetcher_x) & 0x1F;
                    tile_y = @truncate((@as(u16, self.ly) +% @as(u16, self.scy)) / 8 & 0x1F);
                }
                const map_addr = tile_map_base + @as(u16, tile_y) * 32 + @as(u16, tile_x);
                self.fetch_tile_id = bus.vram[0][map_addr - 0x8000];
                if (bus.cgb_mode) {
                    self.fetch_tile_attrs = bus.vram[1][map_addr - 0x8000];
                } else {
                    self.fetch_tile_attrs = 0;
                }
                self.fetcher_state = .read_tile_data_lo;
            },
            .read_tile_data_lo => {
                const addr = self.tile_data_address(bus);
                const vbank: u1 = if (bus.cgb_mode) @truncate((self.fetch_tile_attrs >> 3) & 1) else 0;
                self.fetch_tile_lo = bus.vram[vbank][addr - 0x8000];
                self.fetcher_state = .read_tile_data_hi;
            },
            .read_tile_data_hi => {
                const addr = self.tile_data_address(bus) + 1;
                const vbank: u1 = if (bus.cgb_mode) @truncate((self.fetch_tile_attrs >> 3) & 1) else 0;
                self.fetch_tile_hi = bus.vram[vbank][addr - 0x8000];
                self.fetcher_state = .push;
            },
            .push => {
                if (self.bg_fifo.len() <= 8) {
                    self.push_bg_row(bus);
                    self.fetcher_x +%= 1;
                    self.fetcher_state = .read_tile_id;
                    if (!self.initial_fetch_done) {
                        self.initial_fetch_done = true;
                    }
                }
            },
        }
    }
    fn tile_data_address(self: *Ppu, bus: *Bus) u16 {
        _ = bus;
        const y_flip = (self.fetch_tile_attrs & 0x40) != 0;
        var fine_y: u8 = undefined;
        if (self.in_window) {
            fine_y = self.window_line_counter & 0x07;
        } else {
            fine_y = @truncate((@as(u16, self.ly) +% @as(u16, self.scy)) & 0x07);
        }
        if (y_flip) fine_y = 7 - fine_y;
        if (self.lcdc & 0x10 != 0) {
            return 0x8000 + @as(u16, self.fetch_tile_id) * 16 + @as(u16, fine_y) * 2;
        } else {
            const signed_id: i32 = @as(i32, @as(i8, @bitCast(self.fetch_tile_id)));
            const base: i32 = 0x9000 + signed_id * 16 + @as(i32, fine_y) * 2;
            return @intCast(base);
        }
    }
    fn push_bg_row(self: *Ppu, bus: *Bus) void {
        const x_flip = (self.fetch_tile_attrs & 0x20) != 0;
        const bg_prio = (self.fetch_tile_attrs & 0x80) != 0;
        const cgb_palette: u3 = @truncate(self.fetch_tile_attrs & 0x07);
        for (0..8) |px| {
            const bit: u3 = if (x_flip) @intCast(px) else @intCast(7 - px);
            const color_id: u2 = @truncate(
                ((@as(u8, self.fetch_tile_hi) >> bit) & 1) << 1 |
                    ((@as(u8, self.fetch_tile_lo) >> bit) & 1),
            );
            var pixel = FifoPixel{
                .color = color_id,
                .bg_priority = bg_prio,
                .is_sprite = false,
            };
            if (bus.cgb_mode) {
                pixel.palette = cgb_palette;
            }
            self.bg_fifo.push(pixel);
        }
    }
    fn drawing_tick(self: *Ppu, bus: *Bus) void {
        // Sprite fetch pauses BG fetcher and pixel output
        if (self.sprite_fetch_active) {
            self.sprite_fetch_ticks += 1;
            if (self.sprite_fetch_ticks >= 6) {
                self.fetch_sprite(bus, self.sprite_fetch_idx);
                self.scanline_sprites[self.sprite_fetch_idx].x = -128;
                self.sprite_fetch_active = false;
                // After sprite fetch, restart BG fetcher from read_tile_id
                // This matches hardware behavior where sprite fetch resets the fetcher
                self.fetcher_state = .read_tile_id;
                self.fetcher_ticks = 0;
                if (self.check_sprite_at(self.pixels_pushed)) |idx| {
                    self.sprite_fetch_active = true;
                    self.sprite_fetch_idx = idx;
                    self.sprite_fetch_ticks = 0;
                }
            }
            return;
        }
        self.bg_fetch_tick(bus);
        if (!self.initial_fetch_done) return;
        if (self.bg_fifo.len() > 0) {
            self.try_pop_pixel(bus);
        }
    }
    fn try_pop_pixel(self: *Ppu, bus: *Bus) void {
        if (self.bg_fifo.len() == 0) return;
        // Discard SCX fine scroll pixels first
        if (self.scx_discard > 0) {
            _ = self.bg_fifo.pop();
            self.scx_discard -= 1;
            return;
        }
        // Window trigger: WY latched per-frame, WX checked per-pixel
        if (!self.in_window and !self.window_triggered) {
            if ((self.lcdc & 0x20 != 0) and self.wy_latch) {
                const wx_i: i16 = @as(i16, self.wx) - 7;
                const pp_i: i16 = @intCast(self.pixels_pushed);
                if (pp_i >= wx_i) {
                    self.in_window = true;
                    self.window_triggered = true;
                    self.bg_fifo.clear();
                    self.fetcher_x = 0;
                    self.fetcher_state = .read_tile_id;
                    self.fetcher_ticks = 0;
                    self.initial_fetch_done = false;
                    return;
                }
            }
        }
        // Sprite check — need FIFO >= 8 for correct overlay
        if (self.check_sprite_at(self.pixels_pushed)) |idx| {
            if (self.bg_fifo.len() >= 8) {
                self.sprite_fetch_active = true;
                self.sprite_fetch_idx = idx;
                self.sprite_fetch_ticks = 0;
                return;
            }
            // FIFO too small for overlay — stall pop, let fetcher fill it
            return;
        }
        const pixel = self.bg_fifo.pop();
        self.render_pixel(bus, pixel);
        self.pixels_pushed += 1;
    }
    fn render_pixel(self: *Ppu, bus: *Bus, pixel: FifoPixel) void {
        const disp = self.display orelse return;
        const x: u32 = @intCast(self.pixels_pushed);
        const y: u32 = @intCast(self.ly);
        if (bus.cgb_mode) {
            if (pixel.is_sprite) {
                const color = cgb_palette_color(&bus.obj_cram, pixel.palette, pixel.color);
                disp.set_pixel(x, y, color);
            } else {
                const color = cgb_palette_color(&bus.bg_cram, pixel.palette, pixel.color);
                disp.set_pixel(x, y, color);
            }
        } else {
            if (pixel.is_sprite) {
                const color = palette_color(pixel.sprite_dmg_palette, pixel.color);
                disp.set_pixel(x, y, color);
            } else {
                if (self.lcdc & 0x01 == 0) {
                    disp.set_pixel(x, y, DMG_COLORS[0]);
                } else {
                    const color = palette_color(self.bgp, pixel.color);
                    disp.set_pixel(x, y, color);
                }
            }
        }
    }
    pub fn step(self: *Ppu, bus: *Bus, cycles: u16) void {
        if (!self.enabled) return;
        var remaining = cycles;
        while (remaining > 0) : (remaining -= 1) {
            self.dot(bus);
        }
    }
    fn dot(self: *Ppu, bus: *Bus) void {
        self.cycle_counter += 1;
        switch (self.mode) {
            .OAMScan => {
                if (self.cycle_counter == 1) {
                    if (self.ly == self.wy) {
                        self.wy_latch = true;
                    }
                }
                if (self.cycle_counter == 4) {
                    self.oam_scan(bus);
                }
                if (self.cycle_counter >= 80) {
                    self.mode = .Drawing;
                    self.set_mode(bus);
                    self.start_drawing();
                }
            },
            .Drawing => {
                self.drawing_tick(bus);
                if (self.pixels_pushed >= 160) {
                    self.mode = .HBlank;
                    self.set_mode(bus);
                    bus.do_hblank_hdma();
                    if (self.window_triggered) {
                        self.window_line_counter += 1;
                        self.window_was_active = true;
                    }
                }
                if (self.cycle_counter >= 456 and self.pixels_pushed < 160) {
                    self.pixels_pushed = 160;
                    self.mode = .HBlank;
                    self.set_mode(bus);
                    bus.do_hblank_hdma();
                }
            },
            .HBlank => {
                if (self.cycle_counter >= 456) {
                    self.cycle_counter = 0;
                    self.ly += 1;
                    // Reset IRQ line to allow new rising edge on mode transition
                    self.stat_irq_line = false;
                    if (self.ly >= 144) {
                        self.mode = .VBlank;
                        if (self.ly == self.lyc) {
                            self.stat |= 0x04;
                        } else {
                            self.stat &= ~@as(u8, 0x04);
                        }
                        self.set_mode(bus);
                        bus.request_interrupt(.VBlank);
                        if (self.display) |disp| {
                            disp.update();
                        }
                    } else {
                        self.mode = .OAMScan;
                        if (self.ly == self.lyc) {
                            self.stat |= 0x04;
                        } else {
                            self.stat &= ~@as(u8, 0x04);
                        }
                        self.set_mode(bus);
                    }
                }
            },
            .VBlank => {
                if (self.cycle_counter >= 456) {
                    self.cycle_counter = 0;
                    self.ly += 1;
                    self.stat_irq_line = false;
                    if (self.ly > 153) {
                        self.ly = 0;
                        self.window_line_counter = 0;
                        self.window_was_active = false;
                        self.wy_latch = false;
                        self.mode = .OAMScan;
                        if (self.ly == self.lyc) {
                            self.stat |= 0x04;
                        } else {
                            self.stat &= ~@as(u8, 0x04);
                        }
                        self.set_mode(bus);
                    } else {
                        self.check_lyc(bus);
                    }
                }
            },
        }
    }
};
