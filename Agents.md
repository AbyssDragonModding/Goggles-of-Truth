# AGENTS.md — Development Guidelines for AI Assistants

This document provides context, coding conventions, architectural rules, and cross-compilation workflows for AI agents (e.g., Claude, Cursor, Copilot) working on this repository.

---

## 1. Project Overview & Context

- **Language:** Zig (migrating from Python)
- **Domain:** Seed / Item Randomizer Engine with UI
- **Goal:** High-performance, deterministic seed generation with zero runtime dependencies and instant start times.
- **Priority:** Maintainability and readability above cleverness. The human maintainer must be able to manually edit and extend all generated code without wrestling with overly complex metaprogramming.

---

## 2. Core Architectural & Code Style Principles

### 2.1 Readability & Structure
- **Explicit over Implicit:** Prefer clear, step-by-step imperatively written logic over dense or trick-based implementations.
- **No Complex Metaprogramming (`comptime`):** Limit `comptime` to necessary type parameters or UI binding requirements. Avoid macro-style abstractions or heavy generic type metaprogramming.
- **Explicit Struct Method Call Signatures:** Always use clean, named structs with explicit `Self` pointer receiver syntax:
  ```zig
  pub const LogicSolver = struct {
      seed: u64,

      const Self = @This();

      pub fn init(seed: u64) Self {
          return Self{ .seed = seed };
      }

      pub fn generate(self: *Self) !void {
          // Explicit logic execution
      }
  };
  ```
- **Named Field Initialization:** Always use explicit field names when initializing structs:
  ```zig
  // PREFERRED
  const item = Item{ .id = 1, .name = "Hookshot", .flag = .key_item };

  // AVOID
  const item = Item{ 1, "Hookshot", .key_item };
  ```

### 2.2 Memory Management
- **Explicit Allocator Passing:** Pass an `std.mem.Allocator` parameter to any function or struct method that requires allocation. Never rely on hidden dynamic memory allocation.
- **Use Arena Allocators for Generation Passes:** Use `std.heap.ArenaAllocator` for seed generation routines so memory can be allocated rapidly during generation and freed in a single operation upon completion:
  ```zig
  pub fn generateSeed(base_allocator: std.mem.Allocator, config: Config) !SeedResult {
      var arena = std.heap.ArenaAllocator.init(base_allocator);
      defer arena.deinit(); // Clean up entire generation run easily
      const allocator = arena.allocator();

      // Generation logic using allocator...
  }
  ```

### 2.3 Error Handling
- **Explicit Custom Error Sets:** Avoid using `anyerror` in library code. Define concrete enum error sets for failure modes:
  ```zig
  pub const RandomizerError = error{
      InvalidSeed,
      UnsolvableLogic,
      ItemPoolExhausted,
      OutMemory,
  };
  ```
- **Visible Failure Paths:** Handle error propagation clearly with `try` or explicit `catch` blocks rather than hiding errors inside complex error-union chains.

---

## 3. Cross-Compilation & Build Instructions

Ensure all code remains fully compatible with Zig's built-in cross-compilation pipeline. Avoid non-standard OS-specific dependencies unless isolated behind `@import("builtin").target`.

### Build Targets Command Reference
```bash
# Debug Build (Host)
zig build

# ReleaseFast - Native
zig build -Doptimize=ReleaseFast

# Windows x86_64
zig build-exe src/main.zig -target x86_64-windows -O ReleaseFast

# macOS Apple Silicon (ARM64)
zig build-exe src/main.zig -target aarch64-macos -O ReleaseFast

# Linux x86_64
zig build-exe src/main.zig -target x86_64-linux -O ReleaseFast
```

---

## 4. Instructions for AI Code Edits

When adding new features or responding to refactoring requests:

1. **Preserve UI Bindings:** Do not break existing bindings between the main UI logic and the Zig solver engine.
2. **Comment Intent:** Write brief explanations above complex logic checks explaining *why* the check exists (especially when porting graph verification routines from Python).
3. **Avoid Pythonic Idioms in Zig:** Convert Python list comprehensions, runtime dynamic checks, and implicit dynamic dicts into fixed arrays, slices, explicit maps (`std.AutoHashMap`), or lookup structs.
4. **Deterministic PRNG:** Use explicit PRNG streams (such as `std.rand.DefaultPrng`) anchored strictly to the seed value to guarantee identical results across target OS platforms.