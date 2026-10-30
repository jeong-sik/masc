(** MASC's candle ({!Keeper_portrait_look.mascot}) as a small 3D figure drawn
    in dots.

    A ray-marched scene: a rounded wax cylinder with two drips, two horns, a
    wick and a flame, and a face on the front -- eyes with a glint, a mouth,
    blush. It sways on its upright axis so the face stays in view, and the
    flame flickers. Parts are cel-shaded in three bands with a light from the
    upper left, the flame gives light instead of taking it, and an ink line
    runs round the silhouette. The figure stands on a round backdrop in the
    body's colour; outside it everything is transparent.

    Dots, not pixels: the scene is sampled once per dot on a coarse grid with
    no antialiasing, and each dot is scaled up to a square of whole pixels,
    so it stays square however large the picture is drawn. Colours come from
    {!Keeper_portrait_draw.palette}, the table the 2D renderer paints with. *)

val grid : int
(** About how many dots the figure spans across: the coarsest grid it reads
    at, eyes and flame included. A picture is drawn on the grid of about this
    many dots that fits its edge in whole pixels. *)

val sway_period_ms : int
(** One sway, left and back and right and back, in milliseconds. *)

val mascot : milliseconds:int -> Keeper_portrait_draw.size -> Keeper_portrait_draw.image
(** The mascot at that moment of its sway and flicker, [size] pixels square.
    Each dot is a square of [k] pixels for the whole [k] that puts the grid
    nearest {!grid} dots; what [k] does not divide is a transparent margin,
    split evenly. Pure: the same moment and size always give the same bytes,
    and moments {!sway_period_ms} apart give the same picture. *)
