// Test root for the wire layer + errors. Subdir files cannot be standalone
// test roots because their `../` imports escape a module rooted at their own
// directory; rooting here at src/ keeps every relative import in-bounds.
test {
    _ = @import("errors.zig");
    _ = @import("wire/xml.zig");
    _ = @import("wire/chunked.zig");
    _ = @import("wire/headers.zig");
    _ = @import("wire/envelope.zig");
    _ = @import("wire/route.zig");
    _ = @import("wire/handlers.zig");
}
