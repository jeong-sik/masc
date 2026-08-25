(* Colour arithmetic the terminal does not do for us. See the interface. *)

module Palette = Masc_tui_terminal_palette

let channel_max = 255.
let of_byte value = float_of_int value /. channel_max

let to_byte value =
  value *. channel_max |> Float.round |> int_of_float |> max 0 |> min 255
;;

(* sRGB transfer function, IEC 61966-2-1. The linear segment covers the toe
   where the power curve would be too steep to quantise. *)
let srgb_threshold = 0.04045
let srgb_linear_slope = 12.92
let srgb_exponent = 2.4
let srgb_offset = 0.055

let to_linear value =
  if value <= srgb_threshold then value /. srgb_linear_slope
  else ((value +. srgb_offset) /. (1. +. srgb_offset)) ** srgb_exponent
;;

let of_linear value =
  if value <= srgb_threshold /. srgb_linear_slope then value *. srgb_linear_slope
  else ((1. +. srgb_offset) *. (value ** (1. /. srgb_exponent))) -. srgb_offset
;;

let linear_of color =
  ( to_linear (of_byte (Palette.red color))
  , to_linear (of_byte (Palette.green color))
  , to_linear (of_byte (Palette.blue color)) )
;;

let of_linear_triple (red, green, blue) =
  Palette.make_rgb ~red:(to_byte (of_linear red))
    ~green:(to_byte (of_linear green)) ~blue:(to_byte (of_linear blue))
;;

(* WCAG 2 relative luminance. Its own toe threshold differs from the sRGB
   transfer function's by a rounding the specification never corrected, and
   the number is defined by the specification rather than by the colour, so
   it is written as the specification writes it. *)
let wcag_threshold = 0.03928

let relative_luminance color =
  let channel value =
    let value = of_byte value in
    if value <= wcag_threshold then value /. srgb_linear_slope
    else ((value +. srgb_offset) /. (1. +. srgb_offset)) ** srgb_exponent
  in
  (0.2126 *. channel (Palette.red color))
  +. (0.7152 *. channel (Palette.green color))
  +. (0.0722 *. channel (Palette.blue color))
;;

(* The 0.05 is the specification's flare term: it models the light a real
   screen reflects, which is why two blacks are 1:1 rather than undefined. *)
let wcag_flare = 0.05

let contrast_ratio first second =
  let a = relative_luminance first and b = relative_luminance second in
  (Float.max a b +. wcag_flare) /. (Float.min a b +. wcag_flare)
;;

(* Oklab, Björn Ottosson 2020. The matrices are his reference values. *)
let to_oklab color =
  let red, green, blue = linear_of color in
  let long =
    Float.cbrt
      ((0.4122214708 *. red) +. (0.5363325363 *. green) +. (0.0514459929 *. blue))
  and medium =
    Float.cbrt
      ((0.2119034982 *. red) +. (0.6806995451 *. green) +. (0.1073969566 *. blue))
  and short =
    Float.cbrt
      ((0.0883024619 *. red) +. (0.2817188376 *. green) +. (0.6299787005 *. blue))
  in
  ( (0.2104542553 *. long) +. (0.7936177850 *. medium) -. (0.0040720468 *. short)
  , (1.9779984951 *. long) -. (2.4285922050 *. medium) +. (0.4505937099 *. short)
  , (0.0259040371 *. long) +. (0.7827717662 *. medium) -. (0.8086757660 *. short)
  )
;;

let of_oklab (lightness, green_red, blue_yellow) =
  let cube value = value *. value *. value in
  let long =
    cube
      (lightness +. (0.3963377774 *. green_red) +. (0.2158037573 *. blue_yellow))
  and medium =
    cube
      (lightness -. (0.1055613458 *. green_red) -. (0.0638541728 *. blue_yellow))
  and short =
    cube
      (lightness -. (0.0894841775 *. green_red) -. (1.2914855480 *. blue_yellow))
  in
  of_linear_triple
    ( (4.0767416621 *. long) -. (3.3077115913 *. medium) +. (0.2309699292 *. short)
    , (-1.2684380046 *. long) +. (2.6097574011 *. medium)
      -. (0.3413193965 *. short)
    , (-0.0041960863 *. long) -. (0.7034186147 *. medium)
      +. (1.7076147010 *. short) )
;;

let oklab_lightness color =
  let lightness, _, _ = to_oklab color in
  lightness
;;

let with_oklab_lightness color lightness =
  let _, green_red, blue_yellow = to_oklab color in
  of_oklab (lightness, green_red, blue_yellow)
;;

let clamp_byte value =
  value |> Float.round |> int_of_float |> max 0 |> min 255
;;

let blend ~toward ~ratio color =
  let channel select =
    let source = float_of_int (select color)
    and target = float_of_int (select toward) in
    clamp_byte ((target *. ratio) +. (source *. (1. -. ratio)))
  in
  Palette.make_rgb ~red:(channel Palette.red) ~green:(channel Palette.green)
    ~blue:(channel Palette.blue)
;;

(* Bisection depth. Eight halvings settle a unit range inside 1/256, finer
   than one step of an 8-bit channel. *)
let search_steps = 8

(* Both searches walk a range where the predicate flips exactly once. *)

(* Largest value that still clears, with [low] known to clear. *)
let rec largest_clearing ~clears ~low ~high steps =
  if steps = 0 then low
  else
    let mid = (low +. high) /. 2. in
    if clears mid then largest_clearing ~clears ~low:mid ~high (steps - 1)
    else largest_clearing ~clears ~low ~high:mid (steps - 1)
;;

(* Smallest value that clears, with [high] known to clear. *)
let rec smallest_clearing ~clears ~low ~high steps =
  if steps = 0 then high
  else
    let mid = (low +. high) /. 2. in
    if clears mid then smallest_clearing ~clears ~low ~high:mid (steps - 1)
    else smallest_clearing ~clears ~low:mid ~high (steps - 1)
;;

let lightness_range = 1.0

(* Halfway up perceived lightness. One definition of "is this page light",
   used both to decide which way a colour has to move to be read and how a
   row is set apart from the page, so the two cannot disagree about the same
   terminal. *)
let light_lightness = 0.5
let is_light color = oklab_lightness color >= light_lightness

let lift_for_contrast ~background ~floor color =
  if contrast_ratio color background >= floor then color
  else begin
    (* Away from the background, so a colour on a dark terminal brightens and
       one on a light terminal darkens. Only lightness moves: a step in Oklab
       lightness is the same perceived step at every hue, so the colour comes
       back readable while staying the colour it was. *)
    let start = oklab_lightness color in
    let brighten =
      not (is_light background)
    in
    let limit = if brighten then lightness_range -. start else start in
    let at distance =
      with_oklab_lightness color
        (if brighten then start +. distance else start -. distance)
    in
    let clears distance = contrast_ratio (at distance) background >= floor in
    if not (clears limit) then
      (* The whole range is not enough: black text on black, or a theme that
         put a colour where no lightness of it can be read. Ending is all
         that is left, and it is still the most readable point available. *)
      at limit
    else
      (* The smallest move that clears, so the colour travels no further from
         what the theme chose than it has to. *)
      at (smallest_clearing ~clears ~low:0. ~high:limit search_steps)
  end
;;

let recede_toward ~background ~floor ~max_ratio color =
  let stepped ratio = blend ~toward:background ~ratio color in
  let clears ratio = contrast_ratio (stepped ratio) background >= floor in
  if clears max_ratio then Some (stepped max_ratio)
  else if not (clears 0.) then None
  else
    Some (stepped (largest_clearing ~clears ~low:0. ~high:max_ratio search_steps))
;;
