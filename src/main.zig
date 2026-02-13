const std = @import("std");
const Bus = @import("bus.zig").Bus;
const Cpu = @import("cpu.zig").CPU;
const Timer = @import("timer.zig").Timer;
const Ppu = @import("ppu.zig").Ppu;
const Display = @import("display.zig").Display;
const Joypad = @import("joypad.zig").Joypad;
const posix = std.posix;
const c = @cImport({
    @cInclude("SDL.h");
});

const SCALE: c_int = 3;

pub fn main() !void {
    std.log.info("Starting GameBoy emulator..", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse arguments
    var rom_path: []const u8 = "roms/tetris.gb";
    var boot_rom_path: []const u8 = "dmg_boot.bin";
    var headless = false;
    var max_cycles: u64 = 0; // 0 = unlimited

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--headless")) {
            headless = true;
        } else if (std.mem.eql(u8, args[i], "--max-cycles")) {
            i += 1;
            if (i < args.len) {
                max_cycles = std.fmt.parseInt(u64, args[i], 10) catch 0;
            }
        } else if (std.mem.eql(u8, args[i], "--boot-rom")) {
            i += 1;
            if (i < args.len) boot_rom_path = args[i];
        } else {
            rom_path = args[i];
        }
    }

    std.log.info("Loading ROM from: {s}", .{rom_path});
    if (headless) std.log.info("Running in headless mode", .{});

    var file = try std.fs.cwd().openFile(rom_path, .{ .mode = .read_only });
    defer file.close();
    const file_size = try file.getEndPos();
    const fd = file.handle;

    const map_ptr = try std.posix.mmap(null, file_size, posix.PROT.READ, .{ .TYPE = .SHARED }, fd, 0);
    const rom_bytes = std.mem.sliceAsBytes(map_ptr);
    defer posix.munmap(rom_bytes);

    // Load boot ROM (optional)
    const boot_rom_result = std.fs.cwd().openFile(boot_rom_path, .{ .mode = .read_only });
    var boot_rom_bytes: []u8 = undefined;
    var boot_rom_allocated = false;
    var skip_boot_rom = false;
    if (boot_rom_result) |boot_file| {
        boot_rom_bytes = try boot_file.readToEndAlloc(allocator, 256);
        boot_rom_allocated = true;
        boot_file.close();
    } else |_| {
        std.log.warn("Boot ROM not found, starting at 0x0100", .{});
        boot_rom_bytes = try allocator.alloc(u8, 256);
        boot_rom_allocated = true;
        @memset(boot_rom_bytes, 0);
        skip_boot_rom = true;
    }
    defer if (boot_rom_allocated) allocator.free(boot_rom_bytes);

    // Initialize emulator components
    var display = Display.init();
    var ppu = Ppu.init();
    ppu.display = &display;
    var timer = Timer.init();
    var joypad = Joypad.init();
    var bus = Bus.init(rom_bytes, boot_rom_bytes, &timer, &ppu, &joypad);
    var cpu = Cpu.init();

    if (skip_boot_rom) {
        bus.boot_rom_active = false;
        cpu.a = 0x01;
        cpu.f = 0xB0;
        cpu.b = 0x00;
        cpu.c = 0x13;
        cpu.d = 0x00;
        cpu.e = 0xD8;
        cpu.h = 0x01;
        cpu.l = 0x4D;
        cpu.sp = 0xFFFE;
        cpu.pc = 0x0100;
        ppu.enabled = true;
    }

    if (headless) {
        return run_headless(&cpu, &bus, &timer, &ppu, max_cycles);
    } else {
        return run_with_sdl(&cpu, &bus, &timer, &ppu, &display, &joypad);
    }
}

/// Headless mode: run without SDL, output serial to stdout, exit after max_cycles
fn run_headless(cpu: *Cpu, bus: *Bus, timer: *Timer, ppu: *Ppu, max_cycles: u64) void {
    std.log.info("--- start emulation loop (headless) ---", .{});
    var total_cycles: u64 = 0;

    while (max_cycles == 0 or total_cycles < max_cycles) {
        const cycles = cpu.step(bus);
        timer.step(bus, @intCast(cycles));
        ppu.step(bus, @intCast(cycles));
        total_cycles += cycles;
    }
}

/// SDL mode: run with display window and input handling
fn run_with_sdl(cpu: *Cpu, bus: *Bus, timer: *Timer, ppu: *Ppu, display: *Display, joypad: *Joypad) !void {
    // Initialize SDL
    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "gbemu",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        160 * SCALE,
        144 * SCALE,
        c.SDL_WINDOW_SHOWN,
    ) orelse return error.SDLWindowFailed;
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(
        window,
        -1,
        c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC,
    ) orelse return error.SDLRendererFailed;
    defer c.SDL_DestroyRenderer(renderer);

    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_ARGB8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        160,
        144,
    ) orelse return error.SDLTextureFailed;
    defer c.SDL_DestroyTexture(texture);

    std.log.info("--- start emulation loop ---", .{});

    const cycles_per_frame: u32 = 70224;
    var running = true;

    while (running) {
        // Poll SDL events
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_QUIT) {
                running = false;
            } else if (event.type == c.SDL_KEYDOWN or event.type == c.SDL_KEYUP) {
                const pressed = event.type == c.SDL_KEYDOWN;
                const key = sdl_to_gb_key(event.key.keysym.sym);
                if (key) |k| {
                    joypad.set_key(k, pressed);
                } else if (event.key.keysym.sym == c.SDLK_ESCAPE) {
                    running = false;
                }
            }
        }

        // Run one frame
        var frame_cycles: u32 = 0;
        while (frame_cycles < cycles_per_frame) {
            const cycles = cpu.step(bus);
            timer.step(bus, @intCast(cycles));
            ppu.step(bus, @intCast(cycles));
            frame_cycles += cycles;
        }

        // Present frame if ready
        if (display.frame_ready) {
            _ = c.SDL_UpdateTexture(
                texture,
                null,
                @ptrCast(&display.framebuffer),
                160 * @sizeOf(u32),
            );
            _ = c.SDL_RenderClear(renderer);
            _ = c.SDL_RenderCopy(renderer, texture, null, null);
            c.SDL_RenderPresent(renderer);
            display.frame_ready = false;
        }
    }
}

fn sdl_to_gb_key(sym: i32) ?Joypad.Key {
    return switch (sym) {
        c.SDLK_RIGHT => .right,
        c.SDLK_LEFT => .left,
        c.SDLK_UP => .up,
        c.SDLK_DOWN => .down,
        c.SDLK_z => .a,
        c.SDLK_x => .b,
        c.SDLK_BACKSPACE => .select,
        c.SDLK_RETURN => .start,
        else => null,
    };
}
