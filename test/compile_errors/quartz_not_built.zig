//! Uses the Quartz renderer from a fabrum built for the `none` platform
//! without the `quartz` option, which must be a compile error that says how
//! to get it.
const fabrum = @import("fabrum");

export fn makeRenderer() usize {
    return @sizeOf(fabrum.render.Quartz);
}
