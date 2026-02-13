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
};
