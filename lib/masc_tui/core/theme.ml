type rgb = int

type oklab = {
  l : float;
  a : float;
  b : float;
}

type preset =
  | Midnight
  | Arcade_hi
  | Paper_light
  | Mono

type status_token =
  | Status_ok
  | Status_active
  | Status_attention
  | Status_critical
  | Status_ai
  | Status_historical

type gradient_kind =
  | Thermal
  | Cool_flow
  | Warm_flow
  | Efficiency
  | Ai_flow

type typography_tier =
  | Tier_anchor
  | Tier_primary
  | Tier_structure
  | Tier_whisper

type t = {
  preset : preset;
  surface_0 : rgb;
  surface_1 : rgb;
  surface_2 : rgb;
  border_subtle : rgb;
  border_inactive : rgb;
  border_focused : rgb;
  text_bright : rgb;
  text_primary : rgb;
  text_secondary : rgb;
  text_muted : rgb;
  status_ok : rgb;
  status_active : rgb;
  status_attention : rgb;
  status_critical : rgb;
  status_ai : rgb;
  status_historical : rgb;
  accent : rgb;
  selection_bg : rgb;
  selection_fg : rgb;
  gradient_thermal : rgb array;
  gradient_cool_flow : rgb array;
  gradient_warm_flow : rgb array;
  gradient_efficiency : rgb array;
  gradient_ai_flow : rgb array;
}

let clamp_byte v = Int.max 0 (Int.min 255 v)

let make_rgb ~r ~g ~b =
  ((clamp_byte r) lsl 16) lor ((clamp_byte g) lsl 8) lor (clamp_byte b)

let red c = (c lsr 16) land 0xFF
let green c = (c lsr 8) land 0xFF
let blue c = c land 0xFF

let channel_max = 255.
let of_byte value = float_of_int value /. channel_max

let to_byte value =
  let clamped = Float.max 0. (Float.min 1. value) in
  clamp_byte (int_of_float (Float.round (clamped *. channel_max)))

let srgb_threshold = 0.04045
let srgb_linear_slope = 12.92
let srgb_exponent = 2.4
let srgb_offset = 0.055

let to_linear value =
  if value <= srgb_threshold then value /. srgb_linear_slope
  else ((value +. srgb_offset) /. (1. +. srgb_offset)) ** srgb_exponent

let of_linear value =
  let v = Float.max 0. (Float.min 1. value) in
  if v <= srgb_threshold /. srgb_linear_slope then v *. srgb_linear_slope
  else ((1. +. srgb_offset) *. (v ** (1. /. srgb_exponent))) -. srgb_offset

let wcag_threshold = 0.03928
let wcag_flare = 0.05

let relative_luminance color =
  let channel value =
    let v = of_byte value in
    if v <= wcag_threshold then v /. srgb_linear_slope
    else ((v +. srgb_offset) /. (1. +. srgb_offset)) ** srgb_exponent
  in
  (0.2126 *. channel (red color))
  +. (0.7152 *. channel (green color))
  +. (0.0722 *. channel (blue color))

let contrast_ratio first second =
  let a = relative_luminance first and b = relative_luminance second in
  (Float.max a b +. wcag_flare) /. (Float.min a b +. wcag_flare)

(* Oklab reference matrices (Björn Ottosson, 2020). *)
let to_oklab color =
  let r = to_linear (of_byte (red color))
  and g = to_linear (of_byte (green color))
  and b = to_linear (of_byte (blue color)) in
  let long =
    Float.cbrt ((0.4122214708 *. r) +. (0.5363325363 *. g) +. (0.0514459929 *. b))
  and medium =
    Float.cbrt ((0.2119034982 *. r) +. (0.6806995451 *. g) +. (0.1073969566 *. b))
  and short =
    Float.cbrt ((0.0883024619 *. r) +. (0.2817188376 *. g) +. (0.6299787005 *. b))
  in
  {
    l = (0.2104542553 *. long) +. (0.7936177850 *. medium) -. (0.0040720468 *. short);
    a = (1.9779984951 *. long) -. (2.4285922050 *. medium) +. (0.4505937099 *. short);
    b = (0.0259040371 *. long) +. (0.7827717662 *. medium) -. (0.8086757660 *. short);
  }

let of_oklab { l; a; b } =
  let cube v = v *. v *. v in
  let long = cube (l +. (0.3963377774 *. a) +. (0.2158037573 *. b))
  and medium = cube (l -. (0.1055613458 *. a) -. (0.0638541728 *. b))
  and short = cube (l -. (0.0894841775 *. a) -. (1.2914855480 *. b)) in
  let r = (4.0767416621 *. long) -. (3.3077115913 *. medium) +. (0.2309699292 *. short)
  and g = (-1.2684380046 *. long) +. (2.6097574011 *. medium) -. (0.3413193965 *. short)
  and bl = (-0.0041960863 *. long) -. (0.7034186147 *. medium) +. (1.7076147010 *. short) in
  make_rgb ~r:(to_byte (of_linear r)) ~g:(to_byte (of_linear g)) ~b:(to_byte (of_linear bl))

let oklab_lightness color = (to_oklab color).l

let with_oklab_lightness color l =
  let lab = to_oklab color in
  of_oklab { l = Float.max 0. (Float.min 1. l); a = lab.a; b = lab.b }

let is_light color = oklab_lightness color >= 0.5

let search_steps = 12

let rec smallest_clearing ~clears ~low ~high steps =
  if steps = 0 then high
  else
    let mid = (low +. high) /. 2. in
    if clears mid then smallest_clearing ~clears ~low ~high:mid (steps - 1)
    else smallest_clearing ~clears ~low:mid ~high (steps - 1)

let lift_for_contrast ~background ~floor color =
  if contrast_ratio color background >= floor then color
  else
    let start = oklab_lightness color in
    let brighten = not (is_light background) in
    let limit = if brighten then 1.0 -. start else start in
    let at distance =
      with_oklab_lightness color
        (if brighten then start +. distance else start -. distance)
    in
    let clears distance = contrast_ratio (at distance) background >= floor in
    let candidate =
      if not (clears limit) then at limit
      else at (smallest_clearing ~clears ~low:0. ~high:limit search_steps)
    in
    if contrast_ratio candidate background >= floor then candidate
    else
      (* Handle 8-bit quantization boundary by nudging toward pure white/black. *)
      let rec nudge step =
        if step > 20 then if brighten then 0xFFFFFF else 0x000000
        else
          let frac = float_of_int step *. 0.05 in
          let lab = to_oklab candidate in
          let target_l = if brighten then 1.0 else 0.0 in
          let next =
            of_oklab
              {
                l = lab.l +. ((target_l -. lab.l) *. frac);
                a = lab.a *. (1. -. frac);
                b = lab.b *. (1. -. frac);
              }
          in
          if contrast_ratio next background >= floor then next
          else nudge (step + 1)
      in
      nudge 1

let lerp_oklab ~background ~floor ~t first second =
  let t =
    if Float.is_nan t then 0. else Float.max 0. (Float.min 1. t)
  in
  let first = lift_for_contrast ~background ~floor first in
  let second = lift_for_contrast ~background ~floor second in
  if t <= 0. then first
  else if t >= 1. then second
  else
    let c1 = to_oklab first in
    let c2 = to_oklab second in
    let lerped =
      of_oklab
        {
          l = c1.l +. ((c2.l -. c1.l) *. t);
          a = c1.a +. ((c2.a -. c1.a) *. t);
          b = c1.b +. ((c2.b -. c1.b) *. t);
        }
    in
    lift_for_contrast ~background ~floor lerped

let min_text_contrast = 4.5

let gradient_steps = 64

let lift_across_surfaces ~surfaces ~floor color =
  List.fold_left
    (fun acc bg -> lift_for_contrast ~background:bg ~floor acc)
    color surfaces

let build_gradient ~backgrounds ~floor c0 c1 c2 =
  let primary_bg = match backgrounds with bg :: _ -> bg | [] -> 0x000000 in
  let c0 = lift_across_surfaces ~surfaces:backgrounds ~floor c0 in
  let c1 = lift_across_surfaces ~surfaces:backgrounds ~floor c1 in
  let c2 = lift_across_surfaces ~surfaces:backgrounds ~floor c2 in
  Array.init gradient_steps (fun idx ->
      let pos = float_of_int idx /. float_of_int (gradient_steps - 1) in
      let raw =
        if pos <= 0.5 then
          lerp_oklab ~background:primary_bg ~floor ~t:(pos *. 2.) c0 c1
        else
          lerp_oklab ~background:primary_bg ~floor ~t:((pos -. 0.5) *. 2.) c1 c2
      in
      lift_across_surfaces ~surfaces:backgrounds ~floor raw)

let build_theme ~preset ~surface_0 ~surface_1 ~surface_2
    ~border_subtle ~border_inactive ~border_focused
    ~text_bright ~text_primary ~text_secondary ~text_muted
    ~status_ok ~status_active ~status_attention ~status_critical ~status_ai ~status_historical
    ~accent ~selection_bg ~selection_fg
    ~cool_stops ~warm_stops ~ai_stops =
  let surfaces = [ surface_0; surface_1; surface_2; selection_bg ] in
  let text_bright = lift_across_surfaces ~surfaces ~floor:12.0 text_bright in
  let text_primary = lift_across_surfaces ~surfaces ~floor:9.0 text_primary in
  let text_secondary = lift_across_surfaces ~surfaces ~floor:6.5 text_secondary in
  let text_muted = lift_across_surfaces ~surfaces ~floor:min_text_contrast text_muted in
  let status_ok = lift_across_surfaces ~surfaces ~floor:min_text_contrast status_ok in
  let status_active = lift_across_surfaces ~surfaces ~floor:min_text_contrast status_active in
  let status_attention = lift_across_surfaces ~surfaces ~floor:min_text_contrast status_attention in
  let status_critical = lift_across_surfaces ~surfaces ~floor:min_text_contrast status_critical in
  let status_ai = lift_across_surfaces ~surfaces ~floor:min_text_contrast status_ai in
  let status_historical = lift_across_surfaces ~surfaces ~floor:min_text_contrast status_historical in
  let accent = lift_across_surfaces ~surfaces ~floor:min_text_contrast accent in
  let selection_fg = lift_across_surfaces ~surfaces ~floor:12.0 selection_fg in
  let grad_bgs = [ surface_1; selection_bg ] in
  let c_cool0, c_cool1, c_cool2 = cool_stops in
  let c_warm0, c_warm1, c_warm2 = warm_stops in
  let c_ai0, c_ai1, c_ai2 = ai_stops in
  let gradient_thermal =
    build_gradient ~backgrounds:grad_bgs ~floor:min_text_contrast
      status_ok status_attention status_critical
  in
  let gradient_efficiency =
    build_gradient ~backgrounds:grad_bgs ~floor:min_text_contrast
      status_critical status_attention status_ok
  in
  let gradient_cool_flow =
    build_gradient ~backgrounds:grad_bgs ~floor:min_text_contrast
      c_cool0 c_cool1 c_cool2
  in
  let gradient_warm_flow =
    build_gradient ~backgrounds:grad_bgs ~floor:min_text_contrast
      c_warm0 c_warm1 c_warm2
  in
  let gradient_ai_flow =
    build_gradient ~backgrounds:grad_bgs ~floor:min_text_contrast
      c_ai0 c_ai1 c_ai2
  in
  {
    preset;
    surface_0;
    surface_1;
    surface_2;
    border_subtle;
    border_inactive;
    border_focused;
    text_bright;
    text_primary;
    text_secondary;
    text_muted;
    status_ok;
    status_active;
    status_attention;
    status_critical;
    status_ai;
    status_historical;
    accent;
    selection_bg;
    selection_fg;
    gradient_thermal;
    gradient_cool_flow;
    gradient_warm_flow;
    gradient_efficiency;
    gradient_ai_flow;
  }

(* Preset 1: Midnight — Linear Dark x Obsidian Slate (v2.5 verified WCAG 2.1 AA) *)
let midnight_theme =
  build_theme
    ~preset:Midnight
    ~surface_0:0x0B0E14
    ~surface_1:0x11161F
    ~surface_2:0x18202C
    ~border_subtle:0x232D3D
    ~border_inactive:0x323F54
    ~border_focused:0x58A6FF
    ~text_bright:0xF3F6FA
    ~text_primary:0xDCE3EC
    ~text_secondary:0xA4B5C9
    ~text_muted:0x8698AE
    ~status_ok:0x34D399
    ~status_active:0x60B5FF
    ~status_attention:0xFBBF24
    ~status_critical:0xFB7185
    ~status_ai:0xC084FC
    ~status_historical:0x8E9FB5
    ~accent:0x60B5FF
    ~selection_bg:0x1D2C42
    ~selection_fg:0xF3F6FA
    ~cool_stops:(0x38BDF8, 0x60B5FF, 0xBAE6FD)
    ~warm_stops:(0xA78BFA, 0xE879F9, 0xFDA4AF)
    ~ai_stops:(0xA78BFA, 0xC084FC, 0xE9D5FF)

(* Preset 2: Arcade_hi — High-Contrast Neon Midnight (v2.5 verified WCAG 2.1 AA) *)
let arcade_hi_theme =
  build_theme
    ~preset:Arcade_hi
    ~surface_0:0x070810
    ~surface_1:0x0E1020
    ~surface_2:0x171A32
    ~border_subtle:0x252A4A
    ~border_inactive:0x363E69
    ~border_focused:0x38E8FF
    ~text_bright:0xF6F8FF
    ~text_primary:0xE0E5FA
    ~text_secondary:0xA8B1D9
    ~text_muted:0x8F99C4
    ~status_ok:0x34F58C
    ~status_active:0x38E8FF
    ~status_attention:0xFFBF3C
    ~status_critical:0xFF6B8A
    ~status_ai:0xD28EFF
    ~status_historical:0x97A1CA
    ~accent:0x38E8FF
    ~selection_bg:0x1D254A
    ~selection_fg:0xF6F8FF
    ~cool_stops:(0x00C2E0, 0x38E8FF, 0xCCF8FF)
    ~warm_stops:(0xB86BFF, 0xFF55CC, 0xFFB3E6)
    ~ai_stops:(0xB86BFF, 0xD28EFF, 0xF2D4FF)

(* Preset 3: Paper_light — Daylight Editorial (v2.5 verified WCAG 2.1 AA) *)
let paper_light_theme =
  build_theme
    ~preset:Paper_light
    ~surface_0:0xF7F8FA
    ~surface_1:0xFFFFFF
    ~surface_2:0xECEFF5
    ~border_subtle:0xDDE3EC
    ~border_inactive:0xBCC6D6
    ~border_focused:0x0369A1
    ~text_bright:0x0B1220
    ~text_primary:0x1E293B
    ~text_secondary:0x435064
    ~text_muted:0x556275
    ~status_ok:0x0F7645
    ~status_active:0x0369A1
    ~status_attention:0xA15206
    ~status_critical:0xBE123C
    ~status_ai:0x7C3AED
    ~status_historical:0x556275
    ~accent:0x0369A1
    ~selection_bg:0xE2ECF9
    ~selection_fg:0x0B1220
    ~cool_stops:(0x075985, 0x0369A1, 0x0284C7)
    ~warm_stops:(0x6D28D9, 0xA21CAF, 0xBE123C)
    ~ai_stops:(0x5B21B6, 0x7C3AED, 0x9333EA)

(* Preset 4: Mono — Pure Typographic Grayscale (v2.5 verified WCAG 2.1 AA) *)
let mono_theme =
  build_theme
    ~preset:Mono
    ~surface_0:0x0A0A0B
    ~surface_1:0x121214
    ~surface_2:0x1B1B1F
    ~border_subtle:0x2A2A30
    ~border_inactive:0x3D3D46
    ~border_focused:0xE4E4E7
    ~text_bright:0xFAFAFA
    ~text_primary:0xE4E4E7
    ~text_secondary:0xB4B4BC
    ~text_muted:0x9898A3
    ~status_ok:0xE4E4E7
    ~status_active:0xD4D4DC
    ~status_attention:0xF4F4F5
    ~status_critical:0xFFFFFF
    ~status_ai:0xC8C8D2
    ~status_historical:0x9A9AA5
    ~accent:0xFAFAFA
    ~selection_bg:0x24242A
    ~selection_fg:0xFAFAFA
    ~cool_stops:(0xA1A1AA, 0xD4D4D8, 0xFAFAFA)
    ~warm_stops:(0xB4B4BC, 0xE4E4E7, 0xFFFFFF)
    ~ai_stops:(0x9A9AA5, 0xC8C8D2, 0xF4F4F5)

let all_presets = [ Midnight; Arcade_hi; Paper_light; Mono ]

let all_status_tokens =
  [
    Status_ok;
    Status_active;
    Status_attention;
    Status_critical;
    Status_ai;
    Status_historical;
  ]

let all_gradients = [ Thermal; Cool_flow; Warm_flow; Efficiency; Ai_flow ]

let preset_name = function
  | Midnight -> "midnight"
  | Arcade_hi -> "arcade_hi"
  | Paper_light -> "paper_light"
  | Mono -> "mono"

let preset_label = function
  | Midnight -> Say.make ~ko:"미드나잇" ~en:"Midnight"
  | Arcade_hi -> Say.make ~ko:"아케이드 하이" ~en:"Arcade Hi"
  | Paper_light -> Say.make ~ko:"페이퍼 라이트" ~en:"Paper Light"
  | Mono -> Say.make ~ko:"모노크롬" ~en:"Mono"

let preset_of_name name =
  match String.lowercase_ascii (String.trim name) with
  | "midnight" -> Some Midnight
  | "arcade_hi" | "arcade-hi" -> Some Arcade_hi
  | "paper_light" | "paper-light" -> Some Paper_light
  | "mono" -> Some Mono
  | _ -> None

let preset_index = function
  | Midnight -> 0
  | Arcade_hi -> 1
  | Paper_light -> 2
  | Mono -> 3

let equal_preset a b = Int.equal (preset_index a) (preset_index b)

let of_preset = function
  | Midnight -> midnight_theme
  | Arcade_hi -> arcade_hi_theme
  | Paper_light -> paper_light_theme
  | Mono -> mono_theme

let default = midnight_theme

let tier_fg theme = function
  | Tier_anchor -> theme.text_bright
  | Tier_primary -> theme.text_primary
  | Tier_structure -> theme.text_secondary
  | Tier_whisper -> theme.text_muted

let status_color theme = function
  | Status_ok -> theme.status_ok
  | Status_active -> theme.status_active
  | Status_attention -> theme.status_attention
  | Status_critical -> theme.status_critical
  | Status_ai -> theme.status_ai
  | Status_historical -> theme.status_historical

let gradient_lut theme = function
  | Thermal -> theme.gradient_thermal
  | Cool_flow -> theme.gradient_cool_flow
  | Warm_flow -> theme.gradient_warm_flow
  | Efficiency -> theme.gradient_efficiency
  | Ai_flow -> theme.gradient_ai_flow

let gradient_sample theme kind ratio =
  let lut = gradient_lut theme kind in
  let len = Array.length lut in
  let clamped =
    if Float.is_nan ratio then 0. else Float.max 0. (Float.min 1. ratio)
  in
  let idx =
    Int.max 0 (Int.min (len - 1) (int_of_float (Float.round (clamped *. float_of_int (len - 1)))))
  in
  lut.(idx)
