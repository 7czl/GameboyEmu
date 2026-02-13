const std = @import("std");
const Bus = @import("bus.zig").Bus;
const Cpu = @import("cpu.zig").CPU;
const Timer = @import("timer.zig").Timer;
const Ppu = @import("ppu.zig").Ppu;
const Display = @import("display.zig").Display;
const Joypad = @import("joypad.zig").Joypad;
const Apu = @import("apu.zig").Apu;
const Mbc = @import("mbc.zig").Mbc;
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
    var apu = Apu.init();
    var bus = Bus.init(rom_bytes, boot_rom_bytes, &timer, &ppu, &joypad, &apu);
    var cpu = Cpu.init();

    // Determine save file path and load if battery-backed
    const cart_type = if (rom_bytes.len > 0x147) rom_bytes[0x147] else 0;
    const battery = Mbc.has_battery(cart_type);
    var sav_path_buf: [512]u8 = undefined;
    var sav_path_len: usize = 0;
    if (battery) {
        // Replace .gb/.gbc extension with .sav
        const rom_name = rom_path;
        var base_len = rom_name.len;
        if (base_len > 3 and (std.mem.eql(u8, rom_name[base_len - 3 ..], ".gb"))) {
            base_len -= 3;
        } else if (base_len > 4 and (std.mem.eql(u8, rom_name[base_len - 4 ..], ".gbc"))) {
            base_len -= 4;
        }
        const ext = ".sav";
        if (base_len + ext.len <= sav_path_buf.len) {
            @memcpy(sav_path_buf[0..base_len], rom_name[0..base_len]);
            @memcpy(sav_path_buf[base_len .. base_len + ext.len], ext);
            sav_path_len = base_len + ext.len;

            // Try to load existing save
            const sav_path = sav_path_buf[0..sav_path_len];
            if (std.fs.cwd().openFile(sav_path, .{ .mode = .read_only })) |sav_file| {
                defer sav_file.close();
                const sav_data = sav_file.readToEndAlloc(allocator, 128 * 1024) catch null;
                if (sav_data) |data| {
                    defer allocator.free(data);
                    bus.mbc.load_ram_data(data);
                    std.log.info("Loaded save from: {s}", .{sav_path});
                }
            } else |_| {
                std.log.info("No save file found: {s}", .{sav_path});
            }
        }
    }

    if (skip_boot_rom) {
        bus.boot_rom_active = false;
        if (bus.cgb_mode) {
            // CGB post-boot register values
            cpu.a = 0x11;
            cpu.f = 0x80;
            cpu.b = 0x00;
            cpu.c = 0x00;
            cpu.d = 0xFF;
            cpu.e = 0x56;
            cpu.h = 0x00;
            cpu.l = 0x0D;
        } else {
            // DMG post-boot values from pandocs
            cpu.a = 0x01;
            cpu.f = 0xB0;
            cpu.b = 0x00;
            cpu.c = 0x13;
            cpu.d = 0x00;
            cpu.e = 0xD8;
            cpu.h = 0x01;
            cpu.l = 0x4D;
        }
        cpu.sp = 0xFFFE;
        cpu.pc = 0x0100;
        // IO registers (DMG post-boot values from pandocs)
        bus.interrupt_flag = 0xE1; // IF = 0xE1
        timer.div_counter = 0xAB00; // DIV reads as 0xAB (high byte of div_counter)
        timer.tac = 0xF8; // TAC = 0xF8
        ppu.lcdc = 0x91; // LCDC = 0x91
        ppu.stat = 0x85; // STAT = 0x85
        ppu.bgp = 0xFC; // BGP = 0xFC
        ppu.obp0 = 0x00; // OBP0 (uninitialized, use 0x00)
        ppu.obp1 = 0x00; // OBP1 (uninitialized, use 0x00)
        ppu.enabled = true;
        // Audio registers (routed through bus to APU)
        bus.write(0xFF26, 0xF1); // NR52 - must be first (enables APU)
        bus.write(0xFF10, 0x80); // NR10
        bus.write(0xFF11, 0xBF); // NR11
        bus.write(0xFF12, 0xF3); // NR12
        bus.write(0xFF13, 0xFF); // NR13
        bus.write(0xFF14, 0xBF); // NR14
        bus.write(0xFF16, 0x3F); // NR21
        bus.write(0xFF17, 0x00); // NR22
        bus.write(0xFF18, 0xFF); // NR23
        bus.write(0xFF19, 0xBF); // NR24
        bus.write(0xFF1A, 0x7F); // NR30
        bus.write(0xFF1B, 0xFF); // NR31
        bus.write(0xFF1C, 0x9F); // NR32
        bus.write(0xFF1D, 0xFF); // NR33
        bus.write(0xFF1E, 0xBF); // NR34
        bus.write(0xFF20, 0xFF); // NR41
        bus.write(0xFF21, 0x00); // NR42
        bus.write(0xFF22, 0x00); // NR43
        bus.write(0xFF23, 0xBF); // NR44
        bus.write(0xFF24, 0x77); // NR50
        bus.write(0xFF25, 0xF3); // NR51
        bus.io_registers[0x46] = 0xFF; // DMA
    }

    if (headless) {
        run_headless(&cpu, &bus, max_cycles);
    } else {
        try run_with_sdl(&cpu, &bus, &display, &joypad);
    }

    // Save battery-backed RAM on exit
    if (battery and sav_path_len > 0) {
        const sav_path = sav_path_buf[0..sav_path_len];
        if (bus.mbc.get_ram_data()) |ram_data| {
            if (std.fs.cwd().createFile(sav_path, .{})) |sav_file| {
                defer sav_file.close();
                sav_file.writeAll(ram_data) catch |err| {
                    std.log.err("Failed to write save: {}", .{err});
                };
                std.log.info("Saved to: {s}", .{sav_path});
            } else |err| {
                std.log.err("Failed to create save file: {}", .{err});
            }
        }
    }
}

/// Headless mode: run without SDL, output serial to stdout, exit after max_cycles
fn run_headless(cpu: *Cpu, bus: *Bus, max_cycles: u64) void {
    std.log.info("--- start emulation loop (headless) ---", .{});

    var last_check: u64 = 0;
    while (max_cycles == 0 or cpu.cycles < max_cycles) {
        _ = cpu.step(bus);

        // Check $A000 memory-mapped test output every ~1 frame (70224 cycles)
        if (max_cycles != 0 and cpu.cycles - last_check >= 70224) {
            last_check = cpu.cycles;
            if (check_memory_output(bus)) return;
        }
    }

    // Also check at end of max_cycles
    _ = check_memory_output(bus);
}

/// Check Blargg $A000 memory-mapped test output. Returns true if test finished.
fn check_memory_output(bus: *Bus) bool {
    // Signature: $A001=$DE, $A002=$B0, $A003=$61
    const sig1 = bus.read(0xA001);
    const sig2 = bus.read(0xA002);
    const sig3 = bus.read(0xA003);
    if (sig1 == 0xDE and sig2 == 0xB0 and sig3 == 0x61) {
        const status = bus.read(0xA000);
        if (status == 0x80) return false; // still running
        const stdout_file = std.fs.File.stdout();
        stdout_file.writeAll("\n[Memory output] Status: 0x") catch {};
        const hex_chars = "0123456789ABCDEF";
        stdout_file.writeAll(&[_]u8{ hex_chars[status >> 4], hex_chars[status & 0x0F] }) catch {};
        stdout_file.writeAll("\n") catch {};
        var addr: u16 = 0xA004;
        while (addr < 0xC000) : (addr += 1) {
            const ch = bus.read(addr);
            if (ch == 0) break;
            stdout_file.writeAll(&[_]u8{ch}) catch {};
        }
        stdout_file.writeAll("\n") catch {};
        return true;
    }
    return false;
}

/// SDL mode: run with display window and input handling
fn run_with_sdl(cpu: *Cpu, bus: *Bus, display: *Display, joypad: *Joypad) !void {
    // Initialize SDL (video + audio)
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO) != 0) {
        std.log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    // Open audio device
    var want: c.SDL_AudioSpec = std.mem.zeroes(c.SDL_AudioSpec);
    want.freq = 44100;
    want.format = c.AUDIO_S16SYS;
    want.channels = 1;
    want.samples = 1024;
    want.callback = null; // push mode
    var have: c.SDL_AudioSpec = std.mem.zeroes(c.SDL_AudioSpec);
    const audio_dev = c.SDL_OpenAudioDevice(null, 0, &want, &have, 0);
    if (audio_dev == 0) {
        std.log.warn("SDL audio failed: {s}, running without sound", .{c.SDL_GetError()});
    } else {
        c.SDL_PauseAudioDevice(audio_dev, 0); // unpause
    }
    defer if (audio_dev != 0) c.SDL_CloseAudioDevice(audio_dev);

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
    var excess_cycles: u32 = 0;

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

        // Run one frame, accounting for excess cycles from previous frame
        var frame_cycles: u32 = excess_cycles;
        while (frame_cycles < cycles_per_frame) {
            const step_cycles = cpu.step(bus);
            frame_cycles += step_cycles;
        }
        excess_cycles = frame_cycles - cycles_per_frame;

        // Present frame if ready
        if (display.frame_ready) {
            _ = c.SDL_UpdateTexture(
                texture,
                null,
                @ptrCast(display.front_buffer()),
                160 * @sizeOf(u32),
            );
            _ = c.SDL_RenderClear(renderer);
            _ = c.SDL_RenderCopy(renderer, texture, null, null);
            c.SDL_RenderPresent(renderer);
            display.frame_ready = false;
        }

        // Push audio samples and throttle to ~59.7 fps via audio sync
        if (audio_dev != 0) {
            const samples = bus.apu.get_samples();
            if (samples.len > 0) {
                _ = c.SDL_QueueAudio(
                    audio_dev,
                    @ptrCast(samples.ptr),
                    @intCast(samples.len * @sizeOf(i16)),
                );
            }
            // Throttle: wait until audio buffer drains below ~2 frames worth
            // 44100 Hz / 59.7 fps ≈ 739 samples/frame, 2 frames ≈ 1478 samples * 2 bytes
            while (c.SDL_GetQueuedAudioSize(audio_dev) > 1478 * 2 * 2) {
                c.SDL_Delay(1);
            }
        }
    }
}

fn sdl_to_gb_key(sym: i32) ?Joypad.Key {
    return switch (sym) {
        c.SDLK_d => .right,
        c.SDLK_a => .left,
        c.SDLK_w => .up,
        c.SDLK_s => .down,
        c.SDLK_j => .a,
        c.SDLK_k => .b,
        c.SDLK_BACKSPACE => .select,
        c.SDLK_RETURN => .start,
        else => null,
    };
}
