const std = @import("std");

/// Returned by FixedString when a result would exceed its capacity.
pub const OverflowError = error{Overflow};

/// Union of every error a mutation through `AnyString` can produce.
pub const Error = OverflowError || std.mem.Allocator.Error;
