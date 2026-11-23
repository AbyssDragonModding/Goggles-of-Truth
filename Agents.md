# AI Agent Guidelines & Development Rules

This document outlines the mandatory architecture, coding standards, performance rules, and translation strategies for developing this project in Zig.

---

## 1. Zig Idioms & Code Style

- **Strict Explicitness:**
  - Avoid implicit behaviors, implicit casts, or undisclosed allocations.
  - All allocations must explicitly accept an `Allocator` parameter.
  - Never suppress errors using `catch unreachable` unless mathematically proven impossible, and document the reason.

- **Struct Method Signatures & Instantiation:**
  - Method calls must explicitly use struct namespace or explicit method receiver syntax.
  - Use explicit field names when initializing structs (no positional struct initialization).
  ```zig
  // Preferred
  const config = GenerationConfig{
      .seed = 12345,
      .thread_count = 6,
  };
  GenerationConfig.init(allocator, config);
  ```

- **String Handling:**
  - Direct primitive slice types like `[]u8` and `[]const u8` are forbidden for high-level string handling.
  - Always use the project's dedicated String library/wrapper for string manipulations, ownership management, and formatting.

- **Readability & Intent-Driven Naming:**
  - High human readability and future maintainability are **top priorities**.
  - Variable and function names must explicitly describe their business logic/intent (e.g., `calculateOptimalItemPlacement` over `calcPlacement`).
  - Code must be self-documenting. Use clear comment blocks for non-obvious logic decisions.

---

## 2. High Performance Architecture (Priority Rules)

- **Multithreading & Core Utilization (PRIORITY):**
  - Concurrency must be utilized wherever possible (e.g., seed generation, logic checking, asset processing).
  - Do not hardcode fixed thread limits. Dynamically calculate CPU threads to utilize approximately **75% of available CPU cores**.
  - Formula: `target_threads = max(1, @as(usize, @floatToInt(usize, @intToFloat(f32, std.Thread.getCpuCount() catch 1) * 0.75)))`
  - Leave ~25% headroom to maintain system responsiveness during intensive generation.

- **Caching Strategy (PRIORITY):**
  - Implement aggressive memoization and cache layers for repetitive operations (e.g., world reachability graphs, parsed XML layout trees, static rom tables).
  - Invalidate caches cleanly when generation parameters change.

- **Build Configuration:**
  - Default build targets must always default to **Release** mode (`ReleaseFast` or `ReleaseSafe`) unless an active debug session is explicitly requested.

---

## 3. Platform & Target Support

- **Cross-Platform Compatibility:**
  - Code must compile natively for:
    - **Linux** (`x86_64`, `aarch64`)
    - **Windows** (`x86_64`, `aarch64`)
    - **macOS** (`x86_64`, `aarch64`)
  - Avoid OS-specific conditional code unless isolated inside dedicated platform abstraction modules.

---

## 4. GUI Architecture (ELM & XML-Driven)

- **Architecture:**
  - GUI implementation strictly follows the **ELM Architecture** (Model-View-Update pattern).
    - **Model:** Represents state deterministically.
    - **Update:** Pure functions returning updated state given a message.
    - **View:** Declarative rendering based on Model state.

- **Modular Page Definitions:**
  - Every UI page/screen must be fully defined in its own independent XML file.
  - The UI framework loads and parses XML modularly to construct the view components.

---

## 5. Python-to-Zig Translation & Reference Resolution

- **Explicit Type & Logic Translation:**
  - When porting logic from Python reference implementations, retain exact algorithmic behavior while converting dynamically-typed logic into explicit, strongly-typed Zig types.
  - Map Python primitives to explicit Zig types (`i32`, `u32`, `usize`, etc.). Avoid generic untyped representations.

- **Reference Repositories:**
  - Reference 1 (Primary): [OotrR (Mozencaz/OotrR)](https://github.com/Mozencaz/OotrR)
  - Reference 2 (Secondary): [Clawshot (hiKareeem/Clawshot)](https://github.com/hiKareeem/Clawshot)

- **Conflict & Logic Resolution Standard:**
  1. **Feature Alignment:** If a feature exists in both references, analyze both Python implementations.
  2. **Averaging Logic:** Determine the common/average behavioral logic between both implementations.
  3. **Priority Tie-Breaker:** Prioritize **OotrR** whenever discrepancies or architectural conflicts arise between the two.