const std = @import("std");
const Bus = @import("bus.zig").Bus;
const Cpu = @import("cpu.zig").CPU;
const Timer = @import("timer.zig").Timer;
const Ppu = @import("ppu.zig").Ppu;
const ppu_mod = @import("ppu.zig");
const Display = @import("display.zig").Display;
const Joypad = @import("joypad.zig").Joypad;
const Apu = @import("apu.zig").Apu;
const Mbc = @import("mbc.zig").Mbc;
const savestate = @import("savestate.zig");
const posix = std.posix;
const c = @cImport({
    @cInclude("SDL.h");
});

const SCALE: c_int = 3;

/// SDL context that persists across ROM reloads
const SdlContext = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    texture: *c.SDL_Texture,
    audio_dev: c.SDL_AudioDeviceID,
    controller: ?*c.SDL_GameController,

    fn init() !SdlContext {
        if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO | c.SDL_INIT_GAMECONTROLLER) != 0) {
            std.log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
            return error.SDLInitFailed;
        }
        errdefer c.SDL_Quit();

        const window = c.SDL_CreateWindow(
            "gbemu",
            c.SDL_WINDOWPOS_CENTERED,
            c.SDL_WINDOWPOS_CENTERED,
            160 * SCALE,
            144 * SCALE,
            c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_RESIZABLE,
        ) orelse return error.SDLWindowFailed;
        errdefer c.SDL_DestroyWindow(window);

        const renderer = c.SDL_CreateRenderer(
            window,
            -1,
            c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC,
        ) orelse return error.SDLRendererFailed;
        errdefer c.SDL_DestroyRenderer(renderer);

        _ = c.SDL_SetHint(c.SDL_HINT_RENDER_SCALE_QUALITY, "0");
        _ = c.SDL_RenderSetLogicalSize(renderer, 160, 144);

        const texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_ARGB8888,
            c.SDL_TEXTUREACCESS_STREAMING,
            160,
            144,
        ) orelse return error.SDLTextureFailed;
        errdefer c.SDL_DestroyTexture(texture);

        // Open audio device
        var want: c.SDL_AudioSpec = std.mem.zeroes(c.SDL_AudioSpec);
        want.freq = 44100;
        want.format = c.AUDIO_S16SYS;
        want.channels = 1;
        want.samples = 1024;
        want.callback = null;
        var have: c.SDL_AudioSpec = std.mem.zeroes(c.SDL_AudioSpec);
        const audio_dev = c.SDL_OpenAudioDevice(null, 0, &want, &have, 0);
        if (audio_dev == 0) {
            std.log.warn("SDL audio failed: {s}, running without sound", .{c.SDL_GetError()});
        } else {
            c.SDL_PauseAudioDevice(audio_dev, 0);
        }

        // Open first available game controller
        var controller: ?*c.SDL_GameController = null;
        var i: c_int = 0;
        while (i < c.SDL_NumJoysticks()) : (i += 1) {
            if (c.SDL_IsGameController(i) != 0) {
                controller = c.SDL_GameControllerOpen(i);
                if (controller != null) {
                    std.log.info("Controller connected: {s}", .{c.SDL_GameControllerName(controller)});
                    break;
                }
            }
        }

        return SdlContext{
            .window = window,
            .renderer = renderer,
            .texture = texture,
            .audio_dev = audio_dev,
            .controller = controller,
        };
    }

    fn deinit(self: *SdlContext) void {
        if (self.controller) |ctrl| c.SDL_GameControllerClose(ctrl);
        if (self.audio_dev != 0) c.SDL_CloseAudioDevice(self.audio_dev);
        c.SDL_DestroyTexture(self.texture);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    fn setTitle(self: *SdlContext, title: [:0]const u8) void {
        c.SDL_SetWindowTitle(self.window, title.ptr);
    }
};

pub fn main() !void {
    std.log.info("Starting GameBoy emulator..", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse arguments
    var rom_path: ?[]const u8 = null;
    var boot_rom_path: []const u8 = "dmg_boot.bin";
    var headless = false;
    var max_cycles: u64 = 0;
    var force_dmg = false;

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
        } else if (std.mem.eql(u8, args[i], "--dmg")) {
            force_dmg = true;
        } else {
            rom_path = args[i];
        }
    }

    // Headless mode - no SDL needed
    if (headless) {
        const actual_rom_path = rom_path orelse "roms/tetris.gb";
        try run_headless_rom(allocator, actual_rom_path, boot_rom_path, max_cycles, force_dmg);
        return;
    }

    // Initialize SDL once for the entire session
    var sdl = try SdlContext.init();
    defer sdl.deinit();

    // If no ROM specified, show welcome screen and wait for drop
    if (rom_path == null) {
        const dropped = try show_welcome_screen(&sdl, allocator);
        if (dropped) |path| {
            rom_path = path;
        } else {
            return;
        }
    }

    // Track ROM path ownership
    var rom_path_owned = false;
    if (rom_path != null) {
        var is_from_args = false;
        for (args) |arg| {
            if (rom_path.?.ptr == arg.ptr) {
                is_from_args = true;
                break;
            }
        }
        rom_path_owned = !is_from_args;
    }

    var current_rom_path = rom_path orelse "roms/tetris.gb";

    // Main emulator loop with hot-reload support
    while (true) {
        const result = try run_single_rom(&sdl, allocator, current_rom_path, boot_rom_path, force_dmg);
        if (result) |new_path| {
            if (rom_path_owned) allocator.free(current_rom_path);
            current_rom_path = new_path;
            rom_path_owned = true;
            std.log.info("Hot-reloading ROM: {s}", .{new_path});
        } else {
            if (rom_path_owned) allocator.free(current_rom_path);
            break;
        }
    }
}

/// Run emulator for a single ROM with existing SDL context
fn run_single_rom(sdl: *SdlContext, allocator: std.mem.Allocator, actual_rom_path: []const u8, boot_rom_path: []const u8, force_dmg: bool) !?[]u8 {
    std.log.info("Loading ROM from: {s}", .{actual_rom_path});

    var file = try std.fs.cwd().openFile(actual_rom_path, .{ .mode = .read_only });
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
    var apu = Apu.init(!force_dmg and rom_bytes.len > 0x143 and (rom_bytes[0x143] == 0x80 or rom_bytes[0x143] == 0xC0));
    var bus = Bus.init(rom_bytes, boot_rom_bytes, &timer, &ppu, &joypad, &apu, force_dmg);
    var cpu = Cpu.init();

    // Determine save file path and load if battery-backed
    const cart_type = if (rom_bytes.len > 0x147) rom_bytes[0x147] else 0;
    const battery = Mbc.has_battery(cart_type);
    var sav_path_buf: [512]u8 = undefined;
    var sav_path_len: usize = 0;
    if (battery) {
        const rom_name = actual_rom_path;
        var base_len = rom_name.len;
        const lower3 = if (base_len > 3) blk: {
            var buf: [3]u8 = undefined;
            for (rom_name[base_len - 3 ..][0..3], 0..) |ch, idx| {
                buf[idx] = std.ascii.toLower(ch);
            }
            break :blk buf;
        } else [3]u8{ 0, 0, 0 };
        const lower4 = if (base_len > 4) blk: {
            var buf: [4]u8 = undefined;
            for (rom_name[base_len - 4 ..][0..4], 0..) |ch, idx| {
                buf[idx] = std.ascii.toLower(ch);
            }
            break :blk buf;
        } else [4]u8{ 0, 0, 0, 0 };
        if (base_len > 3 and std.mem.eql(u8, &lower3, ".gb")) {
            base_len -= 3;
        } else if (base_len > 4 and std.mem.eql(u8, &lower4, ".gbc")) {
            base_len -= 4;
        }
        const ext = ".sav";
        if (base_len + ext.len <= sav_path_buf.len) {
            @memcpy(sav_path_buf[0..base_len], rom_name[0..base_len]);
            @memcpy(sav_path_buf[base_len .. base_len + ext.len], ext);
            sav_path_len = base_len + ext.len;

            const sav_path = sav_path_buf[0..sav_path_len];
            std.log.info("Save file path: {s}", .{sav_path});
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
        init_post_boot_state(&cpu, &bus, &timer, &ppu);
    }

    // Compute save state base path
    var state_base_buf: [512]u8 = undefined;
    var state_base_len: usize = 0;
    {
        var base_len = actual_rom_path.len;
        const lower3 = if (base_len > 3) blk: {
            var buf3: [3]u8 = undefined;
            for (actual_rom_path[base_len - 3 ..][0..3], 0..) |ch, idx| buf3[idx] = std.ascii.toLower(ch);
            break :blk buf3;
        } else [3]u8{ 0, 0, 0 };
        const lower4 = if (base_len > 4) blk: {
            var buf4: [4]u8 = undefined;
            for (actual_rom_path[base_len - 4 ..][0..4], 0..) |ch, idx| buf4[idx] = std.ascii.toLower(ch);
            break :blk buf4;
        } else [4]u8{ 0, 0, 0, 0 };
        if (base_len > 3 and std.mem.eql(u8, &lower3, ".gb")) {
            base_len -= 3;
        } else if (base_len > 4 and std.mem.eql(u8, &lower4, ".gbc")) {
            base_len -= 4;
        }
        if (base_len <= state_base_buf.len) {
            @memcpy(state_base_buf[0..base_len], actual_rom_path[0..base_len]);
            state_base_len = base_len;
        }
    }

    // Extract ROM title for window
    var rom_title_buf: [17]u8 = undefined;
    var rom_title_len: usize = 0;
    if (rom_bytes.len > 0x143) {
        var end: usize = 0x134;
        while (end < 0x144 and rom_bytes[end] != 0) : (end += 1) {}
        rom_title_len = end - 0x134;
        @memcpy(rom_title_buf[0..rom_title_len], rom_bytes[0x134..end]);
    }
    rom_title_buf[rom_title_len] = 0;
    const rom_title: [:0]const u8 = rom_title_buf[0..rom_title_len :0];

    // Run SDL loop
    const result = try run_sdl_loop(sdl, &cpu, &bus, &display, &joypad, allocator, if (battery and sav_path_len > 0) sav_path_buf[0..sav_path_len] else null, if (state_base_len > 0) state_base_buf[0..state_base_len] else null, rom_title);

    if (result) |new_path| {
        // Save current ROM's battery RAM before switching
        if (battery and sav_path_len > 0) {
            save_battery_ram(&bus, allocator, sav_path_buf[0..sav_path_len]);
        }
        return new_path;
    }

    // Save battery-backed RAM on exit
    if (battery and sav_path_len > 0) {
        save_battery_ram(&bus, allocator, sav_path_buf[0..sav_path_len]);
    }
    return null;
}

fn save_battery_ram(bus: *Bus, allocator: std.mem.Allocator, sav_path: []const u8) void {
    if (bus.mbc.has_rtc()) {
        if (bus.mbc.get_save_data_with_rtc(allocator)) |save_data| {
            defer allocator.free(save_data);
            if (std.fs.cwd().createFile(sav_path, .{})) |f| {
                defer f.close();
                f.writeAll(save_data) catch {};
                std.log.info("Saved to: {s} (with RTC)", .{sav_path});
            } else |_| {}
        }
    } else if (bus.mbc.get_ram_data()) |ram_data| {
        if (std.fs.cwd().createFile(sav_path, .{})) |f| {
            defer f.close();
            f.writeAll(ram_data) catch {};
            std.log.info("Saved to: {s}", .{sav_path});
        } else |_| {}
    }
}

fn init_post_boot_state(cpu: *Cpu, bus: *Bus, timer: *Timer, ppu: *Ppu) void {
    bus.boot_rom_active = false;
    if (bus.cgb_mode) {
        cpu.a = 0x11;
        cpu.f = 0x80;
        cpu.b = 0x00;
        cpu.c = 0x00;
        cpu.d = 0xFF;
        cpu.e = 0x56;
        cpu.h = 0x00;
        cpu.l = 0x0D;
    } else {
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
    bus.interrupt_flag = 0xE1;
    timer.div_counter = 0xAB00;
    timer.tac = 0xF8;
    ppu.lcdc = 0x91;
    ppu.stat = 0x85;
    ppu.bgp = 0xFC;
    ppu.obp0 = 0x00;
    ppu.obp1 = 0x00;
    ppu.enabled = true;
    bus.write(0xFF26, 0xF1);
    bus.write(0xFF10, 0x80);
    bus.write(0xFF11, 0xBF);
    bus.write(0xFF12, 0xF3);
    bus.write(0xFF13, 0xFF);
    bus.write(0xFF14, 0xBF);
    bus.write(0xFF16, 0x3F);
    bus.write(0xFF17, 0x00);
    bus.write(0xFF18, 0xFF);
    bus.write(0xFF19, 0xBF);
    bus.write(0xFF1A, 0x7F);
    bus.write(0xFF1B, 0xFF);
    bus.write(0xFF1C, 0x9F);
    bus.write(0xFF1D, 0xFF);
    bus.write(0xFF1E, 0xBF);
    bus.write(0xFF20, 0xFF);
    bus.write(0xFF21, 0x00);
    bus.write(0xFF22, 0x00);
    bus.write(0xFF23, 0xBF);
    bus.write(0xFF24, 0x77);
    bus.write(0xFF25, 0xF3);
    bus.io_registers[0x46] = 0xFF;
}

/// Headless mode for a single ROM
fn run_headless_rom(allocator: std.mem.Allocator, actual_rom_path: []const u8, boot_rom_path: []const u8, max_cycles: u64, force_dmg: bool) !void {
    std.log.info("Loading ROM from: {s}", .{actual_rom_path});
    std.log.info("Running in headless mode", .{});

    var file = try std.fs.cwd().openFile(actual_rom_path, .{ .mode = .read_only });
    defer file.close();
    const file_size = try file.getEndPos();
    const fd = file.handle;

    const map_ptr = try std.posix.mmap(null, file_size, posix.PROT.READ, .{ .TYPE = .SHARED }, fd, 0);
    const rom_bytes = std.mem.sliceAsBytes(map_ptr);
    defer posix.munmap(rom_bytes);

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

    var display = Display.init();
    var ppu = Ppu.init();
    ppu.display = &display;
    var timer = Timer.init();
    var joypad = Joypad.init();
    var apu = Apu.init(!force_dmg and rom_bytes.len > 0x143 and (rom_bytes[0x143] == 0x80 or rom_bytes[0x143] == 0xC0));
    var bus = Bus.init(rom_bytes, boot_rom_bytes, &timer, &ppu, &joypad, &apu, force_dmg);
    var cpu = Cpu.init();

    if (skip_boot_rom) {
        init_post_boot_state(&cpu, &bus, &timer, &ppu);
    }

    run_headless(&cpu, &bus, max_cycles);
}

fn run_headless(cpu: *Cpu, bus: *Bus, max_cycles: u64) void {
    std.log.info("--- start emulation loop (headless) ---", .{});

    const start_ns = std.time.nanoTimestamp();
    var last_check: u64 = 0;
    while (max_cycles == 0 or cpu.cycles < max_cycles) {
        _ = cpu.step(bus);

        if (max_cycles != 0 and cpu.cycles - last_check >= 70224) {
            last_check = cpu.cycles;
            if (check_memory_output(bus)) break;
        }
    }

    _ = check_memory_output(bus);

    const end_ns = std.time.nanoTimestamp();
    const elapsed_ns: u64 = @intCast(end_ns - start_ns);
    const elapsed_ms = elapsed_ns / 1_000_000;
    const cycles = cpu.cycles;
    const real_time_ms = cycles * 1000 / 4_194_304;
    const speedup = if (elapsed_ms > 0) real_time_ms * 100 / elapsed_ms else 0;
    std.log.info("Performance: {d} cycles in {d}ms (GB real time: {d}ms, speed: {d}.{d:0>2}x)", .{
        cycles,
        elapsed_ms,
        real_time_ms,
        speedup / 100,
        speedup % 100,
    });
}

fn check_memory_output(bus: *Bus) bool {
    const sig1 = bus.read(0xA001);
    const sig2 = bus.read(0xA002);
    const sig3 = bus.read(0xA003);
    if (sig1 == 0xDE and sig2 == 0xB0 and sig3 == 0x61) {
        const status = bus.read(0xA000);
        if (status == 0x80) return false;
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

/// SDL main loop - returns new ROM path for hot-reload, or null for exit
fn run_sdl_loop(sdl: *SdlContext, cpu: *Cpu, bus: *Bus, display: *Display, joypad: *Joypad, allocator: std.mem.Allocator, sav_path: ?[]const u8, state_base: ?[]const u8, rom_title: [:0]const u8) !?[]u8 {
    std.log.info("--- start emulation loop ---", .{});

    const cycles_per_frame: u32 = 70224;
    var running = true;
    var excess_cycles: u32 = 0;
    var frame_count: u32 = 0;
    const save_interval: u32 = 60;
    var fast_forward = false;
    const ff_multiplier: u32 = 4;
    var paused = false;
    const osd_duration: u16 = 120;
    var osd_buf: [160 * 144]u32 = undefined;
    var state_slot: u8 = 0;
    var volume: u8 = 100;
    var palette_idx: u8 = 0;
    var fps_timer = std.time.nanoTimestamp();
    var fps_frames: u32 = 0;
    var title_buf: [128]u8 = .{0} ** 128;

    var slot_path_buf: [520]u8 = undefined;
    const build_slot_path = struct {
        fn call(base: ?[]const u8, slot: u8, buf: []u8) ?[]const u8 {
            const b = base orelse return null;
            const exts = [4][]const u8{ ".ss0", ".ss1", ".ss2", ".ss3" };
            const ext = exts[slot];
            if (b.len + ext.len > buf.len) return null;
            @memcpy(buf[0..b.len], b);
            @memcpy(buf[b.len .. b.len + ext.len], ext);
            return buf[0 .. b.len + ext.len];
        }
    }.call;

    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_QUIT) {
                running = false;
            } else if (event.type == c.SDL_KEYDOWN or event.type == c.SDL_KEYUP) {
                const pressed = event.type == c.SDL_KEYDOWN;
                const sym = event.key.keysym.sym;
                if (pressed) {
                    if (sym == c.SDLK_F5) {
                        if (build_slot_path(state_base, state_slot, &slot_path_buf)) |sp| {
                            if (savestate.save(allocator, cpu, bus)) |data| {
                                defer allocator.free(data);
                                if (std.fs.cwd().createFile(sp, .{})) |f| {
                                    defer f.close();
                                    f.writeAll(data) catch {};
                                    std.log.info("State saved to: {s}", .{sp});
                                    display.show_osd("STATE SAVED", osd_duration);
                                } else |_| {}
                            }
                        }
                    }
                    if (sym == c.SDLK_F8) {
                        if (build_slot_path(state_base, state_slot, &slot_path_buf)) |sp| {
                            if (std.fs.cwd().openFile(sp, .{ .mode = .read_only })) |f| {
                                defer f.close();
                                if (f.readToEndAlloc(allocator, 4 * 1024 * 1024)) |data| {
                                    defer allocator.free(data);
                                    if (savestate.load(data, cpu, bus)) {
                                        std.log.info("State loaded from: {s}", .{sp});
                                        display.show_osd("STATE LOADED", osd_duration);
                                    } else {
                                        std.log.err("Invalid save state: {s}", .{sp});
                                    }
                                } else |_| {}
                            } else |_| {
                                std.log.warn("No save state found: {s}", .{sp});
                            }
                        }
                    }
                    if (sym == c.SDLK_F11) {
                        const flags = c.SDL_GetWindowFlags(sdl.window);
                        if (flags & c.SDL_WINDOW_FULLSCREEN_DESKTOP != 0) {
                            _ = c.SDL_SetWindowFullscreen(sdl.window, 0);
                        } else {
                            _ = c.SDL_SetWindowFullscreen(sdl.window, c.SDL_WINDOW_FULLSCREEN_DESKTOP);
                        }
                    }
                    if (sym >= c.SDLK_F1 and sym <= c.SDLK_F4) {
                        state_slot = @intCast(sym - c.SDLK_F1);
                        const slot_names = [4][]const u8{ "SLOT 1", "SLOT 2", "SLOT 3", "SLOT 4" };
                        display.show_osd(slot_names[state_slot], osd_duration);
                    }
                    if (sym == c.SDLK_EQUALS or sym == c.SDLK_PLUS) {
                        if (volume <= 90) volume += 10 else volume = 100;
                        var vol_msg: [7]u8 = "VOL    ".*;
                        const d1 = volume / 100;
                        const d2 = (volume / 10) % 10;
                        const d3 = volume % 10;
                        if (d1 > 0) {
                            vol_msg[4] = '0' + d1;
                            vol_msg[5] = '0' + d2;
                            vol_msg[6] = '0' + d3;
                            display.show_osd(vol_msg[0..7], osd_duration);
                        } else if (d2 > 0) {
                            vol_msg[4] = '0' + d2;
                            vol_msg[5] = '0' + d3;
                            vol_msg[6] = ' ';
                            display.show_osd(vol_msg[0..6], osd_duration);
                        } else {
                            vol_msg[4] = '0' + d3;
                            vol_msg[5] = ' ';
                            vol_msg[6] = ' ';
                            display.show_osd(vol_msg[0..5], osd_duration);
                        }
                    }
                    if (sym == c.SDLK_MINUS) {
                        if (volume >= 10) volume -= 10 else volume = 0;
                        var vol_msg: [7]u8 = "VOL    ".*;
                        const d1 = volume / 100;
                        const d2 = (volume / 10) % 10;
                        const d3 = volume % 10;
                        if (d1 > 0) {
                            vol_msg[4] = '0' + d1;
                            vol_msg[5] = '0' + d2;
                            vol_msg[6] = '0' + d3;
                            display.show_osd(vol_msg[0..7], osd_duration);
                        } else if (d2 > 0) {
                            vol_msg[4] = '0' + d2;
                            vol_msg[5] = '0' + d3;
                            vol_msg[6] = ' ';
                            display.show_osd(vol_msg[0..6], osd_duration);
                        } else {
                            vol_msg[4] = '0' + d3;
                            vol_msg[5] = ' ';
                            vol_msg[6] = ' ';
                            display.show_osd(vol_msg[0..5], osd_duration);
                        }
                    }
                    if (sym == c.SDLK_c) {
                        if (!bus.cgb_mode) {
                            palette_idx = (palette_idx + 1) % 4;
                            bus.ppu.dmg_colors = ppu_mod.DMG_PALETTES[palette_idx];
                            display.show_osd(ppu_mod.DMG_PALETTE_NAMES[palette_idx], osd_duration);
                        }
                    }
                    if (sym >= c.SDLK_1 and sym <= c.SDLK_5) {
                        const scale: c_int = sym - c.SDLK_1 + 1;
                        _ = c.SDL_SetWindowFullscreen(sdl.window, 0);
                        c.SDL_SetWindowSize(sdl.window, 160 * scale, 144 * scale);
                        c.SDL_SetWindowPosition(sdl.window, c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED);
                    }
                }
                const key = sdl_to_gb_key(sym);
                if (key) |k| {
                    joypad.set_key(k, pressed);
                } else if (sym == c.SDLK_ESCAPE) {
                    running = false;
                } else if (sym == c.SDLK_SPACE) {
                    if (!paused) {
                        fast_forward = pressed;
                        if (pressed and sdl.audio_dev != 0) {
                            c.SDL_ClearQueuedAudio(sdl.audio_dev);
                        }
                    }
                } else if (sym == c.SDLK_p and pressed) {
                    paused = !paused;
                    if (paused) {
                        display.show_osd("PAUSED", 0xFFFF);
                        if (sdl.audio_dev != 0) c.SDL_PauseAudioDevice(sdl.audio_dev, 1);
                    } else {
                        display.osd_frames = 0;
                        if (sdl.audio_dev != 0) {
                            c.SDL_ClearQueuedAudio(sdl.audio_dev);
                            c.SDL_PauseAudioDevice(sdl.audio_dev, 0);
                        }
                    }
                } else if (sym == c.SDLK_r and pressed) {
                    soft_reset(cpu, bus, display, sdl.audio_dev, osd_duration);
                }
            } else if (event.type == c.SDL_DROPFILE) {
                const dropped_file = event.drop.file;
                if (dropped_file != null) {
                    const file_path = std.mem.span(dropped_file);
                    std.log.info("ROM dropped: {s}", .{file_path});

                    if (sav_path) |path| {
                        save_battery_ram(bus, allocator, path);
                    }

                    const new_path = allocator.dupe(u8, file_path) catch {
                        c.SDL_free(dropped_file);
                        continue;
                    };
                    c.SDL_free(dropped_file);
                    return new_path;
                }
            } else if (event.type == c.SDL_CONTROLLERDEVICEADDED) {
                if (sdl.controller == null) {
                    sdl.controller = c.SDL_GameControllerOpen(event.cdevice.which);
                    if (sdl.controller != null) {
                        std.log.info("Controller connected: {s}", .{c.SDL_GameControllerName(sdl.controller)});
                    }
                }
            } else if (event.type == c.SDL_CONTROLLERDEVICEREMOVED) {
                if (sdl.controller != null) {
                    const joy = c.SDL_GameControllerGetJoystick(sdl.controller);
                    if (joy != null and c.SDL_JoystickInstanceID(joy) == event.cdevice.which) {
                        std.log.info("Controller disconnected", .{});
                        c.SDL_GameControllerClose(sdl.controller);
                        sdl.controller = null;
                    }
                }
            } else if (event.type == c.SDL_CONTROLLERBUTTONDOWN or event.type == c.SDL_CONTROLLERBUTTONUP) {
                const btn_pressed = event.type == c.SDL_CONTROLLERBUTTONDOWN;
                const btn = event.cbutton.button;
                const gb_key = controller_to_gb_key(btn);
                if (gb_key) |k| {
                    joypad.set_key(k, btn_pressed);
                } else if (btn == c.SDL_CONTROLLER_BUTTON_RIGHTSHOULDER) {
                    fast_forward = btn_pressed;
                    if (btn_pressed and sdl.audio_dev != 0) {
                        c.SDL_ClearQueuedAudio(sdl.audio_dev);
                    }
                }
            }
        }

        if (!paused) {
            const frames_to_run: u32 = if (fast_forward) ff_multiplier else 1;
            var ff_i: u32 = 0;
            while (ff_i < frames_to_run) : (ff_i += 1) {
                var frame_cycles: u32 = excess_cycles;
                while (frame_cycles < cycles_per_frame) {
                    const step_cycles = cpu.step(bus);
                    frame_cycles += step_cycles;
                }
                excess_cycles = frame_cycles - cycles_per_frame;
            }
        }

        if (display.frame_ready or (paused and display.osd_frames > 0)) {
            const front = display.front_buffer();
            @memcpy(&osd_buf, front);
            display.render_osd(&osd_buf);
            _ = c.SDL_UpdateTexture(sdl.texture, null, @ptrCast(&osd_buf), 160 * @sizeOf(u32));
            _ = c.SDL_RenderClear(sdl.renderer);
            _ = c.SDL_RenderCopy(sdl.renderer, sdl.texture, null, null);
            c.SDL_RenderPresent(sdl.renderer);
            display.frame_ready = false;
        } else if (display.osd_frames > 0) {
            const front = display.front_buffer();
            @memcpy(&osd_buf, front);
            display.render_osd(&osd_buf);
            _ = c.SDL_UpdateTexture(sdl.texture, null, @ptrCast(&osd_buf), 160 * @sizeOf(u32));
            _ = c.SDL_RenderClear(sdl.renderer);
            _ = c.SDL_RenderCopy(sdl.renderer, sdl.texture, null, null);
            c.SDL_RenderPresent(sdl.renderer);
        }

        if (sdl.audio_dev != 0 and !paused) {
            const samples = bus.apu.get_samples();
            if (samples.len > 0) {
                if (volume == 100) {
                    if (fast_forward) {
                        var ds_i: usize = 0;
                        while (ds_i < samples.len) : (ds_i += ff_multiplier) {
                            const s = [1]i16{samples[ds_i]};
                            _ = c.SDL_QueueAudio(sdl.audio_dev, @ptrCast(&s), @sizeOf(i16));
                        }
                    } else {
                        _ = c.SDL_QueueAudio(sdl.audio_dev, @ptrCast(samples.ptr), @intCast(samples.len * @sizeOf(i16)));
                    }
                } else {
                    const vol: i32 = @intCast(volume);
                    const step: usize = if (fast_forward) ff_multiplier else 1;
                    var si: usize = 0;
                    while (si < samples.len) : (si += step) {
                        const scaled: i16 = @intCast(@divTrunc(@as(i32, samples[si]) * vol, 100));
                        const s = [1]i16{scaled};
                        _ = c.SDL_QueueAudio(sdl.audio_dev, @ptrCast(&s), @sizeOf(i16));
                    }
                }
            }
            if (!fast_forward) {
                while (c.SDL_GetQueuedAudioSize(sdl.audio_dev) > 1478 * 2 * 2) {
                    c.SDL_Delay(1);
                }
            }
        }

        if (paused) {
            c.SDL_Delay(16);
        }

        frame_count += 1;
        if (bus.ram_dirty and frame_count >= save_interval) {
            frame_count = 0;
            bus.ram_dirty = false;
            if (sav_path) |path| {
                save_battery_ram(bus, allocator, path);
            }
        } else if (!bus.ram_dirty and frame_count >= save_interval) {
            frame_count = 0;
        }

        fps_frames += 1;
        const now_ns = std.time.nanoTimestamp();
        const elapsed_ns = now_ns - fps_timer;
        if (elapsed_ns >= 1_000_000_000) {
            const elapsed_u64: u64 = @intCast(elapsed_ns);
            const fps = @as(u64, fps_frames) * 1_000_000_000 / elapsed_u64;
            const written = std.fmt.bufPrint(&title_buf, "gbemu - {s} | {d} fps", .{ rom_title, fps }) catch "";
            if (written.len > 0 and written.len < title_buf.len) {
                title_buf[written.len] = 0;
                c.SDL_SetWindowTitle(sdl.window, @ptrCast(&title_buf));
            }
            fps_frames = 0;
            fps_timer = now_ns;
        }
    }
    return null;
}

fn soft_reset(cpu: *Cpu, bus: *Bus, display: *Display, audio_dev: c.SDL_AudioDeviceID, osd_duration: u16) void {
    cpu.* = Cpu.init();
    bus.ppu.reset();
    bus.timer.* = Timer.init();
    bus.joypad.* = Joypad.init();
    bus.apu.* = Apu.init(bus.cgb_mode);
    bus.interrupt_enable_register = 0;
    bus.interrupt_flag = 0xE1;
    bus.boot_rom_active = false;
    for (&bus.wram) |*bank| {
        @memset(bank, 0);
    }
    @memset(&bus.hram, 0);
    @memset(&bus.io_registers, 0);
    if (bus.cgb_mode) {
        cpu.a = 0x11;
        cpu.f = 0x80;
        cpu.b = 0x00;
        cpu.c = 0x00;
        cpu.d = 0xFF;
        cpu.e = 0x56;
        cpu.h = 0x00;
        cpu.l = 0x0D;
    } else {
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
    cpu.cycles = 0;
    bus.timer.div_counter = 0xAB00;
    bus.timer.tac = 0xF8;
    bus.ppu.lcdc = 0x91;
    bus.ppu.stat = 0x85;
    bus.ppu.bgp = 0xFC;
    bus.ppu.obp0 = 0x00;
    bus.ppu.obp1 = 0x00;
    bus.ppu.enabled = true;
    bus.write(0xFF26, 0xF1);
    bus.write(0xFF10, 0x80);
    bus.write(0xFF11, 0xBF);
    bus.write(0xFF12, 0xF3);
    bus.write(0xFF13, 0xFF);
    bus.write(0xFF14, 0xBF);
    bus.write(0xFF16, 0x3F);
    bus.write(0xFF17, 0x00);
    bus.write(0xFF18, 0xFF);
    bus.write(0xFF19, 0xBF);
    bus.write(0xFF1A, 0x7F);
    bus.write(0xFF1B, 0xFF);
    bus.write(0xFF1C, 0x9F);
    bus.write(0xFF1D, 0xFF);
    bus.write(0xFF1E, 0xBF);
    bus.write(0xFF20, 0xFF);
    bus.write(0xFF21, 0x00);
    bus.write(0xFF22, 0x00);
    bus.write(0xFF23, 0xBF);
    bus.write(0xFF24, 0x77);
    bus.write(0xFF25, 0xF3);
    bus.io_registers[0x46] = 0xFF;
    display.show_osd("RESET", osd_duration);
    if (audio_dev != 0) c.SDL_ClearQueuedAudio(audio_dev);
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

fn controller_to_gb_key(btn: u8) ?Joypad.Key {
    return switch (btn) {
        c.SDL_CONTROLLER_BUTTON_A => .a,
        c.SDL_CONTROLLER_BUTTON_B => .b,
        c.SDL_CONTROLLER_BUTTON_X => .a,
        c.SDL_CONTROLLER_BUTTON_Y => .b,
        c.SDL_CONTROLLER_BUTTON_BACK => .select,
        c.SDL_CONTROLLER_BUTTON_START => .start,
        c.SDL_CONTROLLER_BUTTON_DPAD_UP => .up,
        c.SDL_CONTROLLER_BUTTON_DPAD_DOWN => .down,
        c.SDL_CONTROLLER_BUTTON_DPAD_LEFT => .left,
        c.SDL_CONTROLLER_BUTTON_DPAD_RIGHT => .right,
        else => null,
    };
}

/// Show welcome screen with instructions. Returns ROM path if dropped, null if closed.
fn show_welcome_screen(sdl: *SdlContext, allocator: std.mem.Allocator) !?[]u8 {
    var display = Display.init();

    const welcome_lines = [_][]const u8{
        "GBEMU",
        "",
        "DRAG ROM HERE",
        "OR RUN:",
        "ZIG BUILD RUN",
        "-- ROM.GB",
    };

    var y: u32 = 40;
    for (welcome_lines) |line| {
        display.draw_text(line, 20, y);
        y += 12;
    }

    display.show_osd("PRESS ESC TO EXIT", 0xFFFF);

    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_QUIT) {
                running = false;
            } else if (event.type == c.SDL_KEYDOWN) {
                if (event.key.keysym.sym == c.SDLK_ESCAPE) {
                    running = false;
                }
            } else if (event.type == c.SDL_DROPFILE) {
                const dropped_file = event.drop.file;
                if (dropped_file != null) {
                    const file_path = std.mem.span(dropped_file);
                    std.log.info("ROM dropped: {s}", .{file_path});

                    const path_copy = allocator.dupe(u8, file_path) catch {
                        c.SDL_free(dropped_file);
                        continue;
                    };
                    c.SDL_free(dropped_file);
                    return path_copy;
                }
            }
        }

        const front = display.front_buffer();
        var osd_buf: [160 * 144]u32 = undefined;
        @memcpy(&osd_buf, front);
        display.render_osd(&osd_buf);

        _ = c.SDL_SetRenderDrawColor(sdl.renderer, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(sdl.renderer);
        _ = c.SDL_UpdateTexture(sdl.texture, null, @ptrCast(&osd_buf), 160 * @sizeOf(u32));
        _ = c.SDL_RenderCopy(sdl.renderer, sdl.texture, null, null);
        c.SDL_RenderPresent(sdl.renderer);

        c.SDL_Delay(16);
    }
    return null;
}
