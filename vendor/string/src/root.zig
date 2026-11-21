//! string: a small string library in three layers.
//!
//!   str            Free functions over `[]const u8`. Every read-only operation
//!                  lives here once and is shared by everything else.
//!   FixedString(N) Stack string with a comptime capacity of N bytes. Never
//!                  allocates; growth past N returns `error.Overflow`.
//!   String         Heap string that owns its buffer through an Allocator.
//!   AnyString      Tagged union over both. Exposes the shared API, so code
//!                  can take an `AnyString` and not care where bytes live.
//!
//! Conventions
//!   * All indices and lengths are in bytes. UTF-8 is handled explicitly by
//!     `codepoints`, `utf8Len` and `isValidUtf8`.
//!   * Index arguments (insert, remove, truncate) are asserted, not returned
//!     as errors: a bad index is a programmer bug, like slicing out of range.
//!   * Slices passed to mutating functions must not alias the string's own
//!     buffer (same rule as std.ArrayList): a mutation may move or overwrite it.
//!   * Every mutation is all-or-nothing: on error the string is unchanged.
//!
//! Example
//!   const string = @import("string");
//!
//!   var name = try string.FixedString(32).from("hello");
//!   try name.append(" world");
//!
//!   var msg = string.String.init(gpa);
//!   defer msg.deinit();
//!   try msg.appendFmt("{s}! {d}", .{ name.slice(), 42 });
//!
//!   const a = name.any();
//!   const b = msg.any();
//!   _ = a.startsWith("hello") and b.contains("42");

const errors = @import("errors.zig");

pub const str = @import("str.zig");
pub const FixedString = @import("fixed_string.zig").FixedString;
pub const String = @import("String.zig");
pub const AnyString = @import("any_string.zig").AnyString;

pub const OverflowError = errors.OverflowError;
pub const Error = errors.Error;

test {
    _ = @import("str.zig");
    _ = @import("buffer.zig");
    _ = @import("fixed_string.zig");
    _ = @import("String.zig");
    _ = @import("any_string.zig");
}
