// Joypad input handling
// FF00 register: bits 4-5 select button group, bits 0-3 return state
// Active low: 0 = pressed, 1 = not pressed

pub const Joypad = struct {
    // Button state: true = pressed
    right: bool = false,
    left: bool = false,
    up: bool = false,
    down: bool = false,
    a: bool = false,
    b: bool = false,
    select: bool = false,
    start: bool = false,

    pub fn init() Joypad {
        return Joypad{};
    }

    /// Read joypad register (FF00)
    pub fn read(self: *const Joypad, select_byte: u8) u8 {
        var result: u8 = 0x0F;

        // Bit 4 = 0: select direction keys
        if (select_byte & 0x10 == 0) {
            if (self.right) result &= ~@as(u8, 0x01);
            if (self.left) result &= ~@as(u8, 0x02);
            if (self.up) result &= ~@as(u8, 0x04);
            if (self.down) result &= ~@as(u8, 0x08);
        }

        // Bit 5 = 0: select button keys
        if (select_byte & 0x20 == 0) {
            if (self.a) result &= ~@as(u8, 0x01);
            if (self.b) result &= ~@as(u8, 0x02);
            if (self.select) result &= ~@as(u8, 0x04);
            if (self.start) result &= ~@as(u8, 0x08);
        }

        return (select_byte & 0x30) | result;
    }

    /// Set key state by scancode
    pub fn set_key(self: *Joypad, key: Key, pressed: bool) void {
        switch (key) {
            .right => self.right = pressed,
            .left => self.left = pressed,
            .up => self.up = pressed,
            .down => self.down = pressed,
            .a => self.a = pressed,
            .b => self.b = pressed,
            .select => self.select = pressed,
            .start => self.start = pressed,
        }
    }

    pub const Key = enum {
        right,
        left,
        up,
        down,
        a,
        b,
        select,
        start,
    };
};
