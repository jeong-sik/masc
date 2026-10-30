// Shared sparkline SVG dimensions for the keeper-detail surface.
//
// keeper-detail-charts, keeper-detail-telemetry, and
// keeper-detail-ctx-composition each render small inline charts using
// the same viewBox so they stack visually in the right-rail. Keep these
// in one place so a width/height/padding adjustment lands everywhere
// at once instead of drifting between components.

/** Viewbox width in SVG units. */
export const SPARKLINE_W = 200

/** Viewbox height in SVG units. */
export const SPARKLINE_H = 40

/** Inner padding (top/bottom and left/right) in SVG units. */
export const SPARKLINE_PAD = 2
