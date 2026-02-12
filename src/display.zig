// Display framebuffer — SDL rendering is handled in main.zig

pub const SCREEN_WIDTH: u32 = 160;
pub const SCREEN_HEIGHT: u32 = 144;

pub const Display = struct {
    framebuffer: [SCREEN_WIDTH * SCREEN_HEIGHT]u32,
    frame_ready: bool = false,

    pub fn init() Display {
        return Display{
            .framebuffer = .{0xFF_FF_FF_FF} ** (SCREEN_WIDTH * SCREEN_HEIGHT),
        };
    }

    /// Set a pixel in the framebuffer (ARGB8888)
    pub fn set_pixel(self: *Display, x: u32, y: u32, color: u32) void {
        if (x < SCREEN_WIDTH and y < SCREEN_HEIGHT) {
            self.framebuffer[y * SCREEN_WIDTH + x] = color;
        }
    }

    /// Signal that a frame is ready to be presented
    pub fn update(self: *Display) void {
        self.frame_ready = true;
    }
};
