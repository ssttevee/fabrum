# Shared bitmap content

`layout.Image` describes decoded bitmap pixels, independently of a renderer.
It embeds `layout.Content`, so apps append `&image.content` just as they do
text. Quartz, Cairo, z2d and ThorVG recognize this shared type. Existing
renderer-specific picture APIs remain available for native resources and vectors.

## Interface and ownership

The renderer interface (`Text`, `surfaces`, `render`) and render-command
union stay unchanged. An image is an ordinary `.content` command, identified
by `Image.asImageContent`. Shared content standardizes the input and its
meaning; a renderer still chooses how to draw it. There is no shared canvas
callback, backend handle or file decoder in layout.

`Image.init(source, style)` validates a borrowed `[]const u8` plus width,
height, byte stride, format and source scale. The formats reuse
`layout.PixelFormat`: opaque `gray8`, premultiplied RGBA8 and premultiplied
BGRA8. Rows run from top to bottom and pixels from left to right. Padding
is allowed on every row, and no source alignment is required. Dimensions
must be nonzero, scale positive and finite, stride large enough for a row,
and data at least `stride * height` bytes. Validation checks arithmetic in
64 bits before indexing. Four-channel bytes must already be premultiplied;
validation does not scan or convert them.

The owner retains both the content object and its pixels until commands
have been consumed, including any asynchronous drawing. Layout never owns
or frees them. `content.deinit()` has no work to do. Loading, decoding,
pixel conversion and cache ownership belong to the app or backend.

## Measurement and placement

Natural size in points is `(width, height) / source.scale`. Measurement
uses `.parent` limits, like existing picture content. With no constraints,
every fit mode returns the natural size. Uniform fitting under one finite
axis derives the other axis by aspect ratio; it never substitutes
`floatMax` for an absent constraint.

- `contain` scales uniformly to fit both supplied limits.
- `cover` scales uniformly to cover both supplied limits. Like the existing
  picture API, this measured size may exceed one limit; clip the parent if
  that overflow must be hidden.
- `crop` keeps natural size, clamped independently to the supplied limits.
- `stretch` uses each supplied limit, with natural size on an absent axis.

Zero limits produce zero extent on that axis (`contain` and `cover` return
zero on both axes); negative or nonfinite constraints fail measurement.
There is no extra intrinsic minimum; layout uses the measured size.

`image.placement(box, device_scale)` returns the image's rectangle in
points, before clipping. Renderers use this helper to share fit and
alignment calculations. In a final box, contain and cover use its size,
crop uses natural size, and stretch fills it. Alignment places either
remaining space or overflow on both axes. Drawing must clip to the content
box as well as active scissors, in command order. Empty boxes draw nothing.

`snap_to_pixels` rounds the placed origin to the nearest device pixel,
leaving its size and layout measurement unchanged. It can move an edge
outside the box; that edge is still clipped. Exact 1:1 placement uses crop,
nearest sampling and a source scale equal to the surface scale, in a box
large enough for the image. Snapping alone does not imply 1:1 sampling.

## Sampling and compositing

`nearest` selects the nearest source pixel center without interpolation;
backends may resolve exact halfway ties differently. `smooth` interpolates
premultiplied channels using the backend filter. z2d and ThorVG use the shared
`image.sample(x, y)` bilinear helper, Cairo uses its bilinear filter, and
Quartz uses Core Graphics low interpolation. Smooth is the default. Native
filters can produce different pixels when scaling, so cross-backend
bit-for-bit matching is not promised. Filtering must not interpolate
straight color and then multiply by alpha; that gives incorrect colors
around transparent edges.

z2d composites samples with premultiplied source-over into the current
layer, before later commands. Fractional image and box edges multiply the
sample by pixel coverage. Sampling uses viewport coordinates, independent
of a damage region's or clip layer's origin. Existing output conversion
handles RGBA, BGRA and gray surfaces. Opaque gray stays exact at 1:1.

## Damage and mutation

The fingerprint includes source address, slice length, dimensions, stride,
format, source scale, every style field and `revision`. It hashes fields,
excluding struct padding, and never scans pixel data. Recreating the
content wrapper around the same source produces the same fingerprint.

After an in-place pixel edit, increment `image.revision` before the next
frame. Treat replacement data at a reused allocation address as a new
revision too. Mutation during command consumption is unsupported. Geometry
changes are already tracked by `Damage`. Backend caches must also key on
source metadata and revision rather than the wrapper address alone.

## Adoption

The z2d companion recognizes shared images alongside its text. The existing
custom-content hook remains compatible, but image drawing no longer needs
it. Local development uses `zig build test --fork ../zig-layout` in either
companion checkout. Their standalone test dependencies, plus ThorVG's
consumer dependency, must be repinned after the shared API is published.

Quartz copies source bytes into an sRGB Core Graphics image provider,
including a scanline flip for y-down contexts. Cairo copies into a native
ARGB32 image surface, with pad extension and the selected filter. Both snap
in device space through the context transform, including translations.
Damage clips expand to whole device pixels to keep fractional-scale partial
redraws consistent with full redraws. Hosts still prepare the background.

ThorVG's current binding offers no sampling selector. Its adapter samples
the image's intersection with the current damage region into an aligned
bitmap, then inserts that bitmap into the scene at 1:1 device scale. The
engine owns a copy until scene consumption, avoiding stale address-based
loader caching after revisions. Only the visible region is allocated.
ThorVG still requires a color output surface; gray image sources are supported.

The first implementation converts/copies pixels on each draw instead of
keeping backend image caches. SVG and other backend-specific content remain
separate. Migrating existing picture APIs and declaring content capabilities
are follow-up work; image support is not implied by accepting `.pixels`,
and `checkRenderer` still checks only the existing renderer contract.

Tests cover finite measurement, invalid sources, fit and alignment,
revision-driven damage, source byte order and padding, both sampling modes,
premultiplied alpha, clipping and overlays, exact gray placement, and
partial/full redraw equivalence at 1x, 1.5x and 2x in every output format.
