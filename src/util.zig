pub fn detectEdge(prev: *bool, state: bool) ?enum { rising, falling } {
    if (prev.* == state) {
        return null;
    }

    defer prev.* = state;

    if (prev.*) {
        return .falling;
    }

    return .rising;
}
