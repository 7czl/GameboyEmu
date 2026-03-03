# gbemu

A Game Boy (DMG) and Game Boy Color (CGB) emulator written in Zig.

![gbemu](https://img.shields.io/badge/zig-0.14.1+-orange) ![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-blue)

## Features

- Full DMG and CGB support
- Cycle-accurate CPU (Sharp LR35902)
- Pixel FIFO PPU rendering
- 4-channel APU with audio output
- MBC1, MBC2, MBC3 (with RTC), MBC5 support
- Battery-backed save files (.sav)
- Save states with multiple slots
- Game controller support with hot-plug
- Drag-and-drop ROM loading
- Fast-forward mode
- DMG palette customization

## Building

Requires Zig 0.14.1+ and SDL2.

```bash
# Install SDL2 (macOS)
brew install sdl2

# Install SDL2 (Ubuntu/Debian)
sudo apt install libsdl2-dev

# Build
zig build

# Run
zig build run -- path/to/rom.gb
```

## Controls

### Keyboard

| Key | Action |
|-----|--------|
| W/A/S/D | D-Pad |
| J | A Button |
| K | B Button |
| Enter | Start |
| Backspace | Select |
| Space | Fast Forward (hold) |
| P | Pause |
| R | Reset |
| C | Cycle DMG Palette |
| 1-5 | Window Scale |
| F11 | Toggle Fullscreen |
| Esc | Quit |

### Save States

| Key | Action |
|-----|--------|
| F1-F4 | Select Slot 1-4 |
| F5 | Save State |
| F8 | Load State |

### Audio

| Key | Action |
|-----|--------|
| + | Volume Up |
| - | Volume Down |

### Game Controller

- D-Pad / Left Stick: Movement
- A/X: A Button
- B/Y: B Button
- Start: Start
- Back/Select: Select
- Right Shoulder: Fast Forward

## Headless Mode

For automated testing (e.g., Blargg test ROMs):

```bash
zig build run -- --headless --max-cycles 500000000 rom.gb
```

## Command Line Options

| Option | Description |
|--------|-------------|
| `--headless` | Run without display |
| `--max-cycles N` | Exit after N CPU cycles |
| `--boot-rom FILE` | Use custom boot ROM |
| `--dmg` | Force DMG mode for CGB games |

## Project Structure

```
src/
├── main.zig      # Entry point, SDL, ROM loading
├── cpu.zig       # LR35902 CPU emulation
├── bus.zig       # Memory bus, I/O registers
├── ppu.zig       # Pixel Processing Unit
├── apu.zig       # Audio Processing Unit
├── timer.zig     # System timer
├── display.zig   # Framebuffer, OSD
├── joypad.zig    # Input handling
├── mbc.zig       # Memory Bank Controllers
├── savestate.zig # Save state serialization
└── header.zig    # ROM header parsing
```

## Test ROMs

Passes Blargg's cpu_instrs test suite.

```bash
zig build run -- --headless --max-cycles 500000000 gb-test-roms/cpu_instrs/cpu_instrs.gb
```

## License

MIT
