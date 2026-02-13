# AGENTS.md - Agentic Coding Guide for gbemu

## Build, Lint, and Test Commands

### Build Commands
- **Build the project**: `zig build`
- **Install the project**: `zig build install`
- **Run the emulator**: `zig build run` (or directly `./zig-out/bin/gbemu`)

### Test Commands
- **Run all unit tests**: `zig build test`
- **Run specific test suite**: `zig build test --test-suite=<suite_name>`
- **Run a single test** (example): `zig build test --test-file=src/cpu.zig --test-name=test_add_hl_bc`

### Lint Commands
- **Format code**: `zig fmt -i src/**/*.zig`
- **Run static analysis**: `zig build-lib --strip`

## Code Style Guidelines

### General Principles
- **Consistency**: Follow existing patterns in the codebase
- **Readability**: Prioritize clear, maintainable code over clever shortcuts
- **Error Handling**: Use Zig's error handling mechanisms appropriately
- **Memory Safety**: Leverage Zig's memory safety features

### Imports and Structure
- **Local imports**: Use relative paths (e.g., `@import("bus.zig")`)
- **Standard library**: Import via `@import("std")`
- **Module organization**: Keep related functionality together in logical modules

### Formatting
- **Indentation**: Use 4 spaces per indentation level
- **Line length**: Aim for 80-120 characters per line
- **Braces**: Place opening brace on same line as declaration
- **Whitespace**: Consistent spacing around operators and after commas

### Types
- **Prefer explicit types**: Especially for function parameters and return values
- **Use appropriate primitives**: `u8`, `u16`, `u32`, etc., based on data size needs
- **Struct layout**: Organize fields logically within structures

### Naming Conventions
- **Variables**: `camelCase` for local variables, `snake_case` for constants
- **Functions**: `snake_case`
- **Structs**: `PascalCase`
- **Enums**: `PascalCase` with `UPPER_CASE` for enum values
- **Flags**: Use `const` with bit flags and descriptive names

### Error Handling
- **Use error sets**: Define appropriate error sets for functions
- **Propagate errors**: Use `!` return type and propagate errors upward
- **Handle edge cases**: Validate inputs and handle boundary conditions
- **Use `catch` blocks**: For unrecoverable error handling

### Testing
- **Unit tests**: Place test functions in same file as implementation
- **Test structure**: Use `test` keyword followed by descriptive test name
- **Assertions**: Use `std.testing.expect` and related functions
- **Test coverage**: Aim for high coverage of critical functionality

### Documentation
- **Function documentation**: Add brief comments above public functions
- **Inline comments**: Explain complex logic where appropriate
- **File headers**: Include brief description of file's purpose

### Performance
- **Avoid unnecessary allocations**: Reuse memory where possible
- **Use appropriate data structures**: Choose containers that match access patterns
- **Profile critical paths**: Identify and optimize hotspots

### Concurrency
- **Single-threaded design**: This project currently runs in single thread
- **Future expansion**: Design interfaces to support potential parallel execution

## Project Specific Notes

### GameBoy Emulator Architecture
- **CPU**: Implemented in `cpu.zig` with instruction cycle-accurate emulation
- **Memory Bus**: Central bus implementation in `bus.zig` handling memory access
- **PPU**: Graphics processing unit in `ppu.zig`
- **Timer**: System timer in `timer.zig`
- **Header Parsing**: ROM header handling in `header.zig`

### ROM Loading
- **Boot ROM**: Loaded from `dmg_boot.bin` on startup
- **Game ROM**: Loaded from user-specified file or default path
- **Memory mapping**: ROM is memory-mapped at specific addresses

### Development Workflow
1. Make changes to source files in `src/`
2. Run `zig build` to compile
3. Test with `zig build test`
4. Run emulator with `zig build run`
5. Format code with `zig fmt -i src/**/*.zig`

## Agent-Specific Instructions

When working with this repository, agents should:
- **Preserve existing patterns**: Match the style and structure of surrounding code
- **Use Zig idioms**: Leverage Zig's safety and performance features
- **Test thoroughly**: Add tests for new functionality and verify existing tests pass
- **Document changes**: Update comments and documentation as needed
- **Follow Git workflow**: Make atomic commits with clear messages

## Cursor/Copilot Rules

No specific rules found in `.cursor/rules/` or `.github/copilot-instructions.md`. Follow general Zig best practices.