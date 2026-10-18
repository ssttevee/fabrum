//! Uses `fabrum.app`, for building against a platform that doesn't exist
//! yet, which must be a compile error that names it.
const fabrum = @import("fabrum");

comptime {
    _ = fabrum.app.platform.kind;
}
