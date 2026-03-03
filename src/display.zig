// Display framebuffer with double buffering — SDL rendering is handled in main.zig

pub const SCREEN_WIDTH: u32 = 160;
pub const SCREEN_HEIGHT: u32 = 144;
const FB_SIZE = SCREEN_WIDTH * SCREEN_HEIGHT;

pub const Display = struct {
    // Double buffer: PPU writes to back, SDL reads from front
    buffers: [2][FB_SIZE]u32 = .{
        .{0xFF_FF_FF_FF} ** FB_SIZE,
        .{0xFF_FF_FF_FF} ** FB_SIZE,
    },
    back: u1 = 0, // index PPU writes to
    frame_ready: bool = false,

    // OSD overlay
    osd_message: [32]u8 = .{0} ** 32,
    osd_len: u8 = 0,
    osd_frames: u16 = 0, // frames remaining to show

    pub fn init() Display {
        return Display{};
    }

    /// Set a pixel in the back buffer (ARGB8888)
    pub fn set_pixel(self: *Display, x: u32, y: u32, color: u32) void {
        if (x < SCREEN_WIDTH and y < SCREEN_HEIGHT) {
            self.buffers[self.back][y * SCREEN_WIDTH + x] = color;
        }
    }

    /// Swap buffers and signal frame ready
    pub fn update(self: *Display) void {
        self.back ^= 1; // swap
        self.frame_ready = true;
    }

    /// Get the front buffer (the completed frame) for SDL to read
    pub fn front_buffer(self: *Display) *const [FB_SIZE]u32 {
        return &self.buffers[self.back ^ 1];
    }

    pub fn show_osd(self: *Display, msg: []const u8, frames: u16) void {
        const n: u8 = @intCast(@min(msg.len, 32));
        @memcpy(self.osd_message[0..n], msg[0..n]);
        self.osd_len = n;
        self.osd_frames = frames;
    }

    /// Draw OSD text onto a mutable copy buffer. Call after getting front_buffer.
    pub fn render_osd(self: *Display, buf: []u32) void {
        if (self.osd_frames == 0 or self.osd_len == 0) return;

        const msg = self.osd_message[0..self.osd_len];
        // Center horizontally, position near top (y=4)
        const char_w: u32 = 4; // 3px char + 1px gap
        const text_w: u32 = @as(u32, self.osd_len) * char_w;
        const start_x: u32 = if (text_w < SCREEN_WIDTH) (SCREEN_WIDTH - text_w) / 2 else 0;
        const start_y: u32 = 4;

        // Draw background bar (semi-transparent dark)
        const bar_y0: u32 = if (start_y >= 1) start_y - 1 else 0;
        const bar_y1: u32 = start_y + 6;
        const bar_x0: u32 = if (start_x >= 2) start_x - 2 else 0;
        const bar_x1: u32 = @min(start_x + text_w + 1, SCREEN_WIDTH);
        var by: u32 = bar_y0;
        while (by < bar_y1 and by < SCREEN_HEIGHT) : (by += 1) {
            var bx: u32 = bar_x0;
            while (bx < bar_x1) : (bx += 1) {
                // Darken existing pixel
                const idx = by * SCREEN_WIDTH + bx;
                const orig = buf[idx];
                const r = ((orig >> 16) & 0xFF) / 3;
                const g = ((orig >> 8) & 0xFF) / 3;
                const b = (orig & 0xFF) / 3;
                buf[idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
            }
        }

        // Draw each character
        for (msg, 0..) |ch, ci| {
            const glyph = font_glyph(ch);
            const cx: u32 = start_x + @as(u32, @intCast(ci)) * char_w;
            for (glyph, 0..) |row, ry| {
                var bit: u3 = 2;
                while (true) {
                    if (row & (@as(u8, 1) << bit) != 0) {
                        const px = cx + (2 - @as(u32, bit));
                        const py = start_y + @as(u32, @intCast(ry));
                        if (px < SCREEN_WIDTH and py < SCREEN_HEIGHT) {
                            buf[py * SCREEN_WIDTH + px] = 0xFFFFFFFF;
                        }
                    }
                    if (bit == 0) break;
                    bit -= 1;
                }
            }
        }

        self.osd_frames -= 1;
    }
};

// 3x5 pixel font for OSD — covers A-Z, 0-9, space, and common punctuation
// Each glyph is 5 bytes (rows top to bottom), 3 bits wide (bit2=left, bit0=right)
fn font_glyph(ch: u8) [5]u8 {
    return switch (ch) {
        'A', 'a' => .{ 0b010, 0b101, 0b111, 0b101, 0b101 },
        'B', 'b' => .{ 0b110, 0b101, 0b110, 0b101, 0b110 },
        'C', 'c' => .{ 0b011, 0b100, 0b100, 0b100, 0b011 },
        'D', 'd' => .{ 0b110, 0b101, 0b101, 0b101, 0b110 },
        'E', 'e' => .{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'F', 'f' => .{ 0b111, 0b100, 0b110, 0b100, 0b100 },
        'G', 'g' => .{ 0b011, 0b100, 0b101, 0b101, 0b011 },
        'H', 'h' => .{ 0b101, 0b101, 0b111, 0b101, 0b101 },
        'I', 'i' => .{ 0b111, 0b010, 0b010, 0b010, 0b111 },
        'J', 'j' => .{ 0b001, 0b001, 0b001, 0b101, 0b010 },
        'K', 'k' => .{ 0b101, 0b101, 0b110, 0b101, 0b101 },
        'L', 'l' => .{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'M', 'm' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
        'N', 'n' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
        'O', 'o' => .{ 0b010, 0b101, 0b101, 0b101, 0b010 },
        'P', 'p' => .{ 0b110, 0b101, 0b110, 0b100, 0b100 },
        'Q', 'q' => .{ 0b010, 0b101, 0b101, 0b110, 0b011 },
        'R', 'r' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S', 's' => .{ 0b011, 0b100, 0b010, 0b001, 0b110 },
        'T', 't' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
        'U', 'u' => .{ 0b101, 0b101, 0b101, 0b101, 0b010 },
        'V', 'v' => .{ 0b101, 0b101, 0b101, 0b010, 0b010 },
        'W', 'w' => .{ 0b101, 0b101, 0b111, 0b111, 0b101 },
        'X', 'x' => .{ 0b101, 0b101, 0b010, 0b101, 0b101 },
        'Y', 'y' => .{ 0b101, 0b101, 0b010, 0b010, 0b010 },
        'Z', 'z' => .{ 0b111, 0b001, 0b010, 0b100, 0b111 },
        '0' => .{ 0b010, 0b101, 0b101, 0b101, 0b010 },
        '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => .{ 0b110, 0b001, 0b010, 0b100, 0b111 },
        '3' => .{ 0b110, 0b001, 0b010, 0b001, 0b110 },
        '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '5' => .{ 0b111, 0b100, 0b110, 0b001, 0b110 },
        '6' => .{ 0b011, 0b100, 0b110, 0b101, 0b010 },
        '7' => .{ 0b111, 0b001, 0b010, 0b010, 0b010 },
        '8' => .{ 0b010, 0b101, 0b010, 0b101, 0b010 },
        '9' => .{ 0b010, 0b101, 0b011, 0b001, 0b110 },
        ' ' => .{ 0b000, 0b000, 0b000, 0b000, 0b000 },
        ':' => .{ 0b000, 0b010, 0b000, 0b010, 0b000 },
        '.' => .{ 0b000, 0b000, 0b000, 0b000, 0b010 },
        '!' => .{ 0b010, 0b010, 0b010, 0b000, 0b010 },
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        else => .{ 0b000, 0b000, 0b000, 0b000, 0b000 },
    };
}
