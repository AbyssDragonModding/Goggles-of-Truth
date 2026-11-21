# string

A small Zig string library with one API over two storage models.

| Type             | Storage                     | Grows?               | Mutation errors     |
|------------------|-----------------------------|----------------------|---------------------|
| `FixedString(N)` | Inline `[N]u8` (stack/field) | No, capped at N      | `error.Overflow`    |
| `String`         | Heap, via an `Allocator`    | Yes, ~1.5x amortized | `error.OutOfMemory` |
| `AnyString`      | Handle to either            | Depends on backing   | `string.Error`      |
| `str`            | Free functions on `[]const u8` | n/a (read-only)   | n/a                 |

Requires Zig 0.17.1.

## Install

```sh
zig fetch --save git+https://<your-host>/string
```

or point at a local checkout in `build.zig.zon`:

```zig
.dependencies = .{ .string = .{ .path = "../string" } },
```

Then in `build.zig`:

```zig
const string = b.dependency("string", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("string", string.module("string"));
```

## Usage

```zig
const string = @import("string");

var name = try string.FixedString(32).from("hello");
try name.append(" world");                      // error.Overflow past 32 bytes

var msg = string.String.init(gpa);
defer msg.deinit();
try msg.appendFmt("{s}! {d}", .{ name.slice(), 42 });

// One function, either backing:
fn shout(s: string.AnyString) string.Error!void {
    s.toUpper();
    try s.append("!");
}
try shout(name.any());
try shout(msg.any());

// std.Io.Writer adapter (keep `w` in place while writing):
var w = msg.writer();
try w.interface.print(" {x}", .{255});
```

## Rules

- **Bytes, not codepoints.** Every index and length is in bytes. For UTF-8,
  use `codepoints`, `utf8Len` and `isValidUtf8`. `fromTruncate` never cuts a
  codepoint in half.
- **All-or-nothing mutations.** If a mutation fails, the string is unchanged.
- **Indices are asserted.** A bad index passed to `insert`, `remove` or
  `truncate` panics in Debug and ReleaseSafe, like an out-of-range slice.
- **No aliasing.** Don't pass a slice of a string's own buffer to its own
  mutations, because the buffer may move or be overwritten (same rule as
  `std.ArrayList`).
- **Handles point at the original.** `AnyString` and `Writer` hold pointers
  into the original string, so it must not move while they're in use.

## Build steps

```sh
zig build test          # unit tests (21)
zig build run-example   # examples/basic.zig
zig build docs          # zig-out/docs/index.html
zig build check         # compile-only, for editor integration
```

## Layout

```
src/
  root.zig          public exports
  str.zig           read-only ops on []const u8
  any_string.zig    AnyString union, FixedRef, Writer
  fixed_string.zig  FixedString(N)
  String.zig        heap String (file-as-struct)
  buffer.zig        internal insert/remove/replace on (buf, len)
  errors.zig        OverflowError, Error
examples/basic.zig
```
