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
  | Muted
  | Muted_warm
  | Muted_green
  | Muted_dusk
  | Muted_graphite
  | Solarized_dark
  | Nord
  | Dracula
  | Gruvbox_dark
  | Catppuccin_mocha

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

module Palette = struct
  type t = {
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
    cool_stops : rgb * rgb * rgb;
    warm_stops : rgb * rgb * rgb;
    ai_stops : rgb * rgb * rgb;
  }
end

let clamp_byte v = Int.max 0 (Int.min 255 v)

let make_rgb ~r ~g ~b =
  ((clamp_byte r) lsl 16) lor ((clamp_byte g) lsl 8) lor (clamp_byte b)

let red c = (c lsr 16) land 0xFF
let green c = (c lsr 8) land 0xFF
let blue c = c land 0xFF

let rgb_to_hex color = Printf.sprintf "#%06X" (color land 0xFFFFFF)

let hex_nibble = function
  | '0'..'9' as ch -> Char.code ch - Char.code '0'
  | 'a'..'f' as ch -> 10 + (Char.code ch - Char.code 'a')
  | 'A'..'F' as ch -> 10 + (Char.code ch - Char.code 'A')
  | _ -> -1

let rgb_of_hex raw =
  let s = String.trim raw in
  let hex =
    if String.length s > 0 && Char.equal s.[0] '#'
    then String.sub s 1 (String.length s - 1)
    else s
  in
  if String.length hex <> 6 then
    Error (Printf.sprintf "expected #RRGGBB, got %S" raw)
  else
    let nibbles = Array.init 6 (fun i -> hex_nibble hex.[i]) in
    if Array.exists (fun n -> n < 0) nibbles then
      Error (Printf.sprintf "non-hex digit in %S" raw)
    else
      let digit i = nibbles.(i) in
      Ok
        ((digit 0 * 16 + digit 1) lsl 16
        lor ((digit 2 * 16 + digit 3) lsl 8)
        lor (digit 4 * 16 + digit 5))

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

type text_floors = {
  bright : float;
  primary : float;
  secondary : float;
  muted : float;
  selection : float;
}

(* The contrast each text tier keeps on every surface of its preset, the
   selection background included. [build_theme] lifts a color up to its floor.
   The four original presets share the standard set. The down-tone presets
   share a lower one: body text stays at WCAG 2.1 AAA (7:1) and the other
   tiers sit lower, so their text is dimmer. The named palettes (Solarized,
   Nord, Dracula, Gruvbox, Catppuccin) share [aa_floors]: they keep the colors
   their authors published, so each tier only has to clear WCAG AA. *)
let standard_floors =
  {
    bright = 12.0;
    primary = 9.0;
    secondary = 6.5;
    muted = min_text_contrast;
    selection = 12.0;
  }

let down_tone_floors =
  {
    bright = 8.5;
    primary = 7.0;
    secondary = 5.5;
    muted = min_text_contrast;
    selection = 8.5;
  }

let aa_floors =
  {
    bright = min_text_contrast;
    primary = min_text_contrast;
    secondary = min_text_contrast;
    muted = min_text_contrast;
    selection = min_text_contrast;
  }

let text_floors = function
  | Midnight | Arcade_hi | Paper_light | Mono -> standard_floors
  | Muted | Muted_warm | Muted_green | Muted_dusk | Muted_graphite ->
      down_tone_floors
  | Solarized_dark | Nord | Dracula | Gruvbox_dark | Catppuccin_mocha ->
      aa_floors

let build_theme ~preset ~surface_0 ~surface_1 ~surface_2
    ~border_subtle ~border_inactive ~border_focused
    ~text_bright ~text_primary ~text_secondary ~text_muted
    ~status_ok ~status_active ~status_attention ~status_critical ~status_ai ~status_historical
    ~accent ~selection_bg ~selection_fg
    ~cool_stops ~warm_stops ~ai_stops =
  let floors = text_floors preset in
  let surfaces = [ surface_0; surface_1; surface_2; selection_bg ] in
  let text_bright = lift_across_surfaces ~surfaces ~floor:floors.bright text_bright in
  let text_primary = lift_across_surfaces ~surfaces ~floor:floors.primary text_primary in
  let text_secondary = lift_across_surfaces ~surfaces ~floor:floors.secondary text_secondary in
  let text_muted = lift_across_surfaces ~surfaces ~floor:floors.muted text_muted in
  let status_ok = lift_across_surfaces ~surfaces ~floor:min_text_contrast status_ok in
  let status_active = lift_across_surfaces ~surfaces ~floor:min_text_contrast status_active in
  let status_attention = lift_across_surfaces ~surfaces ~floor:min_text_contrast status_attention in
  let status_critical = lift_across_surfaces ~surfaces ~floor:min_text_contrast status_critical in
  let status_ai = lift_across_surfaces ~surfaces ~floor:min_text_contrast status_ai in
  let status_historical = lift_across_surfaces ~surfaces ~floor:min_text_contrast status_historical in
  let accent = lift_across_surfaces ~surfaces ~floor:min_text_contrast accent in
  let selection_fg = lift_across_surfaces ~surfaces ~floor:floors.selection selection_fg in
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

let of_palette preset (palette : Palette.t) =
  let open Palette in
  build_theme ~preset
    ~surface_0:palette.surface_0
    ~surface_1:palette.surface_1
    ~surface_2:palette.surface_2
    ~border_subtle:palette.border_subtle
    ~border_inactive:palette.border_inactive
    ~border_focused:palette.border_focused
    ~text_bright:palette.text_bright
    ~text_primary:palette.text_primary
    ~text_secondary:palette.text_secondary
    ~text_muted:palette.text_muted
    ~status_ok:palette.status_ok
    ~status_active:palette.status_active
    ~status_attention:palette.status_attention
    ~status_critical:palette.status_critical
    ~status_ai:palette.status_ai
    ~status_historical:palette.status_historical
    ~accent:palette.accent
    ~selection_bg:palette.selection_bg
    ~selection_fg:palette.selection_fg
    ~cool_stops:palette.cool_stops
    ~warm_stops:palette.warm_stops
    ~ai_stops:palette.ai_stops

let equal_palette (a : Palette.t) (b : Palette.t) =
  let open Palette in
  Int.equal a.surface_0 b.surface_0
  && Int.equal a.surface_1 b.surface_1
  && Int.equal a.surface_2 b.surface_2
  && Int.equal a.border_subtle b.border_subtle
  && Int.equal a.border_inactive b.border_inactive
  && Int.equal a.border_focused b.border_focused
  && Int.equal a.text_bright b.text_bright
  && Int.equal a.text_primary b.text_primary
  && Int.equal a.text_secondary b.text_secondary
  && Int.equal a.text_muted b.text_muted
  && Int.equal a.status_ok b.status_ok
  && Int.equal a.status_active b.status_active
  && Int.equal a.status_attention b.status_attention
  && Int.equal a.status_critical b.status_critical
  && Int.equal a.status_ai b.status_ai
  && Int.equal a.status_historical b.status_historical
  && Int.equal a.accent b.accent
  && Int.equal a.selection_bg b.selection_bg
  && Int.equal a.selection_fg b.selection_fg
  && (let c, c1, c2 = a.cool_stops and d, d1, d2 = b.cool_stops in
      Int.equal c d && Int.equal c1 d1 && Int.equal c2 d2)
  && (let c, c1, c2 = a.warm_stops and d, d1, d2 = b.warm_stops in
      Int.equal c d && Int.equal c1 d1 && Int.equal c2 d2)
  && (let c, c1, c2 = a.ai_stops and d, d1, d2 = b.ai_stops in
      Int.equal c d && Int.equal c1 d1 && Int.equal c2 d2)

(* TOML override registry. Set once at startup by the app layer; [of_preset]
   reads it on every call. [Stdlib.Mutex] because the locked section is a
   short table lookup with no I/O, and tests call [of_preset] outside
   [Eio_main.run] (see the OCaml checklist §4). *)
let overrides_table : (preset, Palette.t) Hashtbl.t = Hashtbl.create 16
let overrides_mutex = Mutex.create ()

let with_overrides_locked fn =
  Mutex.lock overrides_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock overrides_mutex) fn

let set_palette_overrides overrides =
  with_overrides_locked (fun () ->
      Hashtbl.clear overrides_table;
      List.iter
        (fun (preset, palette) -> Hashtbl.replace overrides_table preset palette)
        overrides)

let palette_override preset =
  with_overrides_locked (fun () -> Hashtbl.find_opt overrides_table preset)

let clear_palette_overrides () = with_overrides_locked (fun () -> Hashtbl.clear overrides_table)

(* Built-in palettes. The editable copies live in [config/themes/<preset>.toml]
   with the same values; this is the fallback when the file is absent. *)
let down_tone_cool_stops = (0x69AABA, 0x7DB1DD, 0xAFD4EA)
let down_tone_warm_stops = (0xA693C9, 0xD494B8, 0xEFBBC2)
let down_tone_ai_stops = (0x9F92C8, 0xB89DD9, 0xDBC8EA)

let builtin_palette =
  let open Palette in
  function
  (* Preset 1: Midnight — Linear Dark x Obsidian Slate (v2.5 verified WCAG 2.1 AA) *)
  | Midnight ->
      {
        surface_0 = 0x0B0E14;
        surface_1 = 0x11161F;
        surface_2 = 0x18202C;
        border_subtle = 0x232D3D;
        border_inactive = 0x323F54;
        border_focused = 0x58A6FF;
        text_bright = 0xF3F6FA;
        text_primary = 0xDCE3EC;
        text_secondary = 0xA4B5C9;
        text_muted = 0x8698AE;
        status_ok = 0x34D399;
        status_active = 0x60B5FF;
        status_attention = 0xFBBF24;
        status_critical = 0xFB7185;
        status_ai = 0xC084FC;
        status_historical = 0x8E9FB5;
        accent = 0x60B5FF;
        selection_bg = 0x1D2C42;
        selection_fg = 0xF3F6FA;
        cool_stops = (0x38BDF8, 0x60B5FF, 0xBAE6FD);
        warm_stops = (0xA78BFA, 0xE879F9, 0xFDA4AF);
        ai_stops = (0xA78BFA, 0xC084FC, 0xE9D5FF);
      }
  (* Preset 2: Arcade_hi — High-Contrast Neon Midnight (v2.5 verified WCAG 2.1 AA) *)
  | Arcade_hi ->
      {
        surface_0 = 0x070810;
        surface_1 = 0x0E1020;
        surface_2 = 0x171A32;
        border_subtle = 0x252A4A;
        border_inactive = 0x363E69;
        border_focused = 0x38E8FF;
        text_bright = 0xF6F8FF;
        text_primary = 0xE0E5FA;
        text_secondary = 0xA8B1D9;
        text_muted = 0x8F99C4;
        status_ok = 0x34F58C;
        status_active = 0x38E8FF;
        status_attention = 0xFFBF3C;
        status_critical = 0xFF6B8A;
        status_ai = 0xD28EFF;
        status_historical = 0x97A1CA;
        accent = 0x38E8FF;
        selection_bg = 0x1D254A;
        selection_fg = 0xF6F8FF;
        cool_stops = (0x00C2E0, 0x38E8FF, 0xCCF8FF);
        warm_stops = (0xB86BFF, 0xFF55CC, 0xFFB3E6);
        ai_stops = (0xB86BFF, 0xD28EFF, 0xF2D4FF);
      }
  (* Preset 3: Paper_light — Daylight Editorial (v2.5 verified WCAG 2.1 AA) *)
  | Paper_light ->
      {
        surface_0 = 0xF7F8FA;
        surface_1 = 0xFFFFFF;
        surface_2 = 0xECEFF5;
        border_subtle = 0xDDE3EC;
        border_inactive = 0xBCC6D6;
        border_focused = 0x0369A1;
        text_bright = 0x0B1220;
        text_primary = 0x1E293B;
        text_secondary = 0x435064;
        text_muted = 0x556275;
        status_ok = 0x0F7645;
        status_active = 0x0369A1;
        status_attention = 0xA15206;
        status_critical = 0xBE123C;
        status_ai = 0x7C3AED;
        status_historical = 0x556275;
        accent = 0x0369A1;
        selection_bg = 0xE2ECF9;
        selection_fg = 0x0B1220;
        cool_stops = (0x075985, 0x0369A1, 0x0284C7);
        warm_stops = (0x6D28D9, 0xA21CAF, 0xBE123C);
        ai_stops = (0x5B21B6, 0x7C3AED, 0x9333EA);
      }
  (* Preset 4: Mono — Pure Typographic Grayscale (v2.5 verified WCAG 2.1 AA) *)
  | Mono ->
      {
        surface_0 = 0x0A0A0B;
        surface_1 = 0x121214;
        surface_2 = 0x1B1B1F;
        border_subtle = 0x2A2A30;
        border_inactive = 0x3D3D46;
        border_focused = 0xE4E4E7;
        text_bright = 0xFAFAFA;
        text_primary = 0xE4E4E7;
        text_secondary = 0xB4B4BC;
        text_muted = 0x9898A3;
        status_ok = 0xE4E4E7;
        status_active = 0xD4D4DC;
        status_attention = 0xF4F4F5;
        status_critical = 0xFFFFFF;
        status_ai = 0xC8C8D2;
        status_historical = 0x9A9AA5;
        accent = 0xFAFAFA;
        selection_bg = 0x24242A;
        selection_fg = 0xFAFAFA;
        cool_stops = (0xA1A1AA, 0xD4D4D8, 0xFAFAFA);
        warm_stops = (0xB4B4BC, 0xE4E4E7, 0xFFFFFF);
        ai_stops = (0x9A9AA5, 0xC8C8D2, 0xF4F4F5);
      }

  (* Presets 5 to 9: the down-tone family. All five use [down_tone_floors] and
     differ in the hue of surfaces, borders, text and accent. Gradient stops carry
     a meaning (cool, warm, AI flow) and no surface tint, so the family shares
     them. *)
  (* Preset 5: Muted: slate blue-gray, the Midnight family with lower chroma and
     dimmer text. *)
  | Muted ->
      {
        surface_0 = 0x13181D;
        surface_1 = 0x181D23;
        surface_2 = 0x1F252C;
        border_subtle = 0x272F37;
        border_inactive = 0x3B4550;
        border_focused = 0x70A4D0;
        text_bright = 0xCDD3D8;
        text_primary = 0xBAC0C8;
        text_secondary = 0xA2ACB7;
        text_muted = 0x8F9CAB;
        status_ok = 0x70B08B;
        status_active = 0x74A7D4;
        status_attention = 0xC19D5A;
        status_critical = 0xE08B8D;
        status_ai = 0xB297D2;
        status_historical = 0x94A4B4;
        accent = 0x74A7D4;
        selection_bg = 0x23313E;
        selection_fg = 0xCDD3D8;
        cool_stops = down_tone_cool_stops;
        warm_stops = down_tone_warm_stops;
        ai_stops = down_tone_ai_stops;
      }
  (* Preset 6: Muted Warm: warm gray-brown with a teal accent *)
  | Muted_warm ->
      {
        surface_0 = 0x1B1611;
        surface_1 = 0x211C16;
        surface_2 = 0x2A231C;
        border_subtle = 0x342C24;
        border_inactive = 0x4C4136;
        border_focused = 0x62ACB5;
        text_bright = 0xD5D0CA;
        text_primary = 0xC4BDB7;
        text_secondary = 0xB2A89C;
        text_muted = 0xA59889;
        status_ok = 0x6FAF8A;
        status_active = 0x62ADB5;
        status_attention = 0xBF9C59;
        status_critical = 0xDF8A8C;
        status_ai = 0xB196D1;
        status_historical = 0xAF9F8E;
        accent = 0x62ADB5;
        selection_bg = 0x3A2C1F;
        selection_fg = 0xD5D0CA;
        cool_stops = down_tone_cool_stops;
        warm_stops = down_tone_warm_stops;
        ai_stops = down_tone_ai_stops;
      }

  (* Preset 7: Muted Green: moss gray-green with a teal accent *)
  | Muted_green ->
      {
        surface_0 = 0x121916;
        surface_1 = 0x171F1C;
        surface_2 = 0x1D2723;
        border_subtle = 0x25312C;
        border_inactive = 0x374841;
        border_focused = 0x62ADAD;
        text_bright = 0xCCD5D1;
        text_primary = 0xB9C3BE;
        text_secondary = 0x9FAFA8;
        text_muted = 0x8BA097;
        status_ok = 0x82AE78;
        status_active = 0x63AFAE;
        status_attention = 0xC19E5B;
        status_critical = 0xE18B8D;
        status_ai = 0xB397D3;
        status_historical = 0x90A89D;
        accent = 0x63AFAE;
        selection_bg = 0x21342B;
        selection_fg = 0xCCD5D1;
        cool_stops = down_tone_cool_stops;
        warm_stops = down_tone_warm_stops;
        ai_stops = down_tone_ai_stops;
      }

  (* Preset 8: Muted Dusk: purple-gray with a periwinkle accent *)
  | Muted_dusk ->
      {
        surface_0 = 0x18161C;
        surface_1 = 0x1E1B22;
        surface_2 = 0x26232B;
        border_subtle = 0x302C35;
        border_inactive = 0x47414E;
        border_focused = 0x829FD4;
        text_bright = 0xD2CFD6;
        text_primary = 0xC0BDC5;
        text_secondary = 0xADA7B4;
        text_muted = 0x9E97A8;
        status_ok = 0x6FAE8A;
        status_active = 0x84A2D7;
        status_attention = 0xBF9C59;
        status_critical = 0xDF898C;
        status_ai = 0xB196D1;
        status_historical = 0xA69EB1;
        accent = 0x84A2D7;
        selection_bg = 0x312C3C;
        selection_fg = 0xD2CFD6;
        cool_stops = down_tone_cool_stops;
        warm_stops = down_tone_warm_stops;
        ai_stops = down_tone_ai_stops;
      }

  (* Preset 9: Muted Graphite: neutral graphite with a soft blue accent *)
  | Muted_graphite ->
      {
        surface_0 = 0x161718;
        surface_1 = 0x1C1D1E;
        surface_2 = 0x232526;
        border_subtle = 0x2C2E30;
        border_inactive = 0x424446;
        border_focused = 0x70A4D0;
        text_bright = 0xD0D2D3;
        text_primary = 0xBEC0C1;
        text_secondary = 0xA8ABAD;
        text_muted = 0x979B9E;
        status_ok = 0x70B08B;
        status_active = 0x74A7D3;
        status_attention = 0xC09D5A;
        status_critical = 0xE08B8D;
        status_ai = 0xB297D2;
        status_historical = 0x9BA3AB;
        accent = 0x74A7D3;
        selection_bg = 0x2B3035;
        selection_fg = 0xD0D2D3;
        cool_stops = down_tone_cool_stops;
        warm_stops = down_tone_warm_stops;
        ai_stops = down_tone_ai_stops;
      }

(* Presets 10 to 14: palettes published by their authors. Each color is the
   author's hex value, or an Oklab mix of two of them for a role the palette
   has no value for (surface_1, surface_2, selection_bg, some text tiers, border
   tints and gradient stops). The comment on a line names the source color, or
   the two colors and the share of the second.

   - Solarized, Ethan Schoonover, MIT: https://github.com/altercation/solarized
   - Nord, Sven Greb, MIT: https://github.com/nordtheme/nord
   - Dracula, Dracula Theme, MIT: https://github.com/dracula/dracula-theme
   - Gruvbox, morhetz, MIT/X11: https://github.com/morhetz/gruvbox
   - Catppuccin Mocha, Catppuccin, MIT: https://github.com/catppuccin/palette

   docs/legal/THIRD-PARTY-TUI-PALETTES.md lists the copyright lines. All five
   use [aa_floors]: a color below WCAG AA on one of the four surfaces is lifted
   by [build_theme], so the color on screen can be lighter than the one written
   here. *)

  (* Preset 10: Solarized Dark. The text tiers are base2, base1, base0 and base01,
     one step brighter than Solarized's own roles (base1 emphasis, base0 body,
     base01 comments). Solarized's body and comment colors are below AA on the
     lighter surfaces, so [build_theme] lifts primary, secondary and muted to
     about 4.5:1 and the three end up close in brightness. *)
  | Solarized_dark ->
      {
        surface_0 = 0x002B36 (* base03 *);
        surface_1 = 0x012E39 (* base03 to base02, 25% *);
        surface_2 = 0x03313D (* base03 to base02, 55% *);
        border_subtle = 0x234651 (* base02 to base01, 30% *);
        border_inactive = 0x586E75 (* base01 *);
        border_focused = 0x268BD2 (* blue *);
        text_bright = 0xEEE8D5 (* base2 *);
        text_primary = 0x93A1A1 (* base1 *);
        text_secondary = 0x839496 (* base0 *);
        text_muted = 0x586E75 (* base01 *);
        status_ok = 0x859900 (* green *);
        status_active = 0x268BD2 (* blue *);
        status_attention = 0xB58900 (* yellow *);
        status_critical = 0xDC322F (* red *);
        status_ai = 0x6C71C4 (* violet *);
        status_historical = 0x657B83 (* base00 *);
        accent = 0x268BD2 (* blue *);
        selection_bg = 0x093E4F (* base02 to blue, 10% *);
        selection_fg = 0xEEE8D5 (* base2 *);
        cool_stops = (0x2AA198, 0x268BD2, 0x93BBD7); (* cyan; blue; blue to base2, 50% *)
        warm_stops = (0x6C71C4, 0xD33682, 0xEA7D6B); (* violet; magenta; red to base2, 35% *)
        ai_stops = (0x6C71C4, 0xA55EA4, 0xA3A7CF); (* violet; violet to magenta, 50%; violet to base2, 45% *)
      }

  (* Preset 11: Nord. Polar Night surfaces, Snow Storm text, Frost and Aurora accents. *)
  | Nord ->
      {
        surface_0 = 0x2E3440 (* nord0 *);
        surface_1 = 0x313744 (* nord0 to nord1, 25% *);
        surface_2 = 0x353C4A (* nord0 to nord1, 55% *);
        border_subtle = 0x434C5E (* nord2 *);
        border_inactive = 0x4C566A (* nord3 *);
        border_focused = 0x88C0D0 (* nord8 *);
        text_bright = 0xECEFF4 (* nord6 *);
        text_primary = 0xD8DEE9 (* nord4 *);
        text_secondary = 0xBDC4D1 (* nord4 to nord3, 18% *);
        text_muted = 0xA0A8B7 (* nord4 to nord3, 38% *);
        status_ok = 0xA3BE8C (* nord14 *);
        status_active = 0x88C0D0 (* nord8 *);
        status_attention = 0xEBCB8B (* nord13 *);
        status_critical = 0xBF616A (* nord11 *);
        status_ai = 0xB48EAD (* nord15 *);
        status_historical = 0x8F97A7 (* nord4 to nord3, 50% *);
        accent = 0x88C0D0 (* nord8 *);
        selection_bg = 0x3F4758 (* nord1 to nord2, 50% *);
        selection_fg = 0xECEFF4 (* nord6 *);
        cool_stops = (0x8FBCBB, 0x88C0D0, 0xBBD8E2); (* nord7; nord8; nord8 to nord6, 50% *)
        warm_stops = (0xB48EAD, 0xBF616A, 0xD08770); (* nord15; nord11; nord12 *)
        ai_stops = (0x5E81AC, 0xB48EAD, 0xCEB9CD); (* nord10; nord15; nord15 to nord6, 45% *)
      }

  (* Preset 12: Dracula. The comment color is below AA, so muted text and the
     historical status are lifted. *)
  | Dracula ->
      {
        surface_0 = 0x282A36 (* background *);
        surface_1 = 0x2D303D (* background to current_line, 20% *);
        surface_2 = 0x333544 (* background to current_line, 40% *);
        border_subtle = 0x3D4051 (* background to current_line, 75% *);
        border_inactive = 0x4E5673 (* current_line to comment, 35% *);
        border_focused = 0xBD93F9 (* purple *);
        text_bright = 0xF8F8F2 (* foreground *);
        text_primary = 0xE1E1DD (* foreground to background, 10% *);
        text_secondary = 0xB1BAD0 (* foreground to comment, 45% *);
        text_muted = 0x7E8CB4 (* comment to foreground, 20% *);
        status_ok = 0x50FA7B (* green *);
        status_active = 0x8BE9FD (* cyan *);
        status_attention = 0xFFB86C (* orange *);
        status_critical = 0xFF5555 (* red *);
        status_ai = 0xBD93F9 (* purple *);
        status_historical = 0x7E8CB4 (* comment to foreground, 20% *);
        accent = 0x8BE9FD (* cyan *);
        selection_bg = 0x404354 (* background to current_line, 85% *);
        selection_fg = 0xF8F8F2 (* foreground *);
        cool_stops = (0x72B5C7, 0x8BE9FD, 0xC6F1F8); (* cyan to background, 25%; cyan; cyan to foreground, 50% *)
        warm_stops = (0xBD93F9, 0xFF79C6, 0xFF9C9F); (* purple; pink; pink to orange, 50% *)
        ai_stops = (0xA582D9, 0xBD93F9, 0xD7C1F8); (* purple to background, 15%; purple; purple to foreground, 45% *)
      }

  (* Preset 13: Gruvbox Dark (medium contrast). Surfaces are dark0, dark0_soft and
     dark1, text is light0 to light3. *)
  | Gruvbox_dark ->
      {
        surface_0 = 0x282828 (* dark0 *);
        surface_1 = 0x32302F (* dark0_soft *);
        surface_2 = 0x3C3836 (* dark1 *);
        border_subtle = 0x504945 (* dark2 *);
        border_inactive = 0x665C54 (* dark3 *);
        border_focused = 0xFE8019 (* bright_orange *);
        text_bright = 0xFBF1C7 (* light0 *);
        text_primary = 0xEBDBB2 (* light1 *);
        text_secondary = 0xD5C4A1 (* light2 *);
        text_muted = 0xBDAE93 (* light3 *);
        status_ok = 0xB8BB26 (* bright_green *);
        status_active = 0x83A598 (* bright_blue *);
        status_attention = 0xFABD2F (* bright_yellow *);
        status_critical = 0xFB4934 (* bright_red *);
        status_ai = 0xD3869B (* bright_purple *);
        status_historical = 0xBDAE93 (* light3 *);
        accent = 0x83A598 (* bright_blue *);
        selection_bg = 0x46403D (* dark1 to dark2, 50% *);
        selection_fg = 0xFBF1C7 (* light0 *);
        cool_stops = (0x8EC07C, 0x83A598, 0xB8C7AD); (* bright_aqua; bright_blue; bright_blue to light0, 45% *)
        warm_stops = (0xD3869B, 0xFB4934, 0xFE8019); (* bright_purple; bright_red; bright_orange *)
        ai_stops = (0xD3869B, 0xDBA0A2, 0xE9BBB1); (* bright_purple; bright_purple to light1, 30%; bright_purple to light0, 50% *)
      }

  (* Preset 14: Catppuccin Mocha. The canvas is base, the published background. *)
  | Catppuccin_mocha ->
      {
        surface_0 = 0x1E1E2E (* base *);
        surface_1 = 0x232333 (* base to surface0, 25% *);
        surface_2 = 0x28293A (* base to surface0, 55% *);
        border_subtle = 0x313244 (* surface0 *);
        border_inactive = 0x585B70 (* surface2 *);
        border_focused = 0xB4BEFE (* lavender *);
        text_bright = 0xCDD6F4 (* text *);
        text_primary = 0xBAC2DE (* subtext1 *);
        text_secondary = 0xA6ADC8 (* subtext0 *);
        text_muted = 0x9399B2 (* overlay2 *);
        status_ok = 0xA6E3A1 (* green *);
        status_active = 0x89B4FA (* blue *);
        status_attention = 0xF9E2AF (* yellow *);
        status_critical = 0xF38BA8 (* red *);
        status_ai = 0xCBA6F7 (* mauve *);
        status_historical = 0x7F849C (* overlay1 *);
        accent = 0x89B4FA (* blue *);
        selection_bg = 0x343547 (* surface0 to surface1, 15% *);
        selection_fg = 0xCDD6F4 (* text *);
        cool_stops = (0x74C7EC, 0x89B4FA, 0xABC5F8); (* sapphire; blue; blue to text, 50% *)
        warm_stops = (0xCBA6F7, 0xF5C2E7, 0xF2CDCD); (* mauve; pink; flamingo *)
        ai_stops = (0xB4BEFE, 0xCBA6F7, 0xF5C2E7); (* lavender; mauve; pink *)
      }

let all_presets =
  [
    Midnight;
    Arcade_hi;
    Paper_light;
    Mono;
    Muted;
    Muted_warm;
    Muted_green;
    Muted_dusk;
    Muted_graphite;
    Solarized_dark;
    Nord;
    Dracula;
    Gruvbox_dark;
    Catppuccin_mocha;
  ]

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
  | Muted -> "muted"
  | Muted_warm -> "muted_warm"
  | Muted_green -> "muted_green"
  | Muted_dusk -> "muted_dusk"
  | Muted_graphite -> "muted_graphite"
  | Solarized_dark -> "solarized_dark"
  | Nord -> "nord"
  | Dracula -> "dracula"
  | Gruvbox_dark -> "gruvbox_dark"
  | Catppuccin_mocha -> "catppuccin_mocha"

let preset_label = function
  | Midnight -> Say.make ~ko:"미드나잇" ~en:"Midnight"
  | Arcade_hi -> Say.make ~ko:"아케이드 하이" ~en:"Arcade Hi"
  | Paper_light -> Say.make ~ko:"페이퍼 라이트" ~en:"Paper Light"
  | Mono -> Say.make ~ko:"모노크롬" ~en:"Mono"
  | Muted -> Say.make ~ko:"다운톤 청회색" ~en:"Muted Slate"
  | Muted_warm -> Say.make ~ko:"다운톤 회갈색" ~en:"Muted Warm"
  | Muted_green -> Say.make ~ko:"다운톤 녹회색" ~en:"Muted Green"
  | Muted_dusk -> Say.make ~ko:"다운톤 보라회색" ~en:"Muted Dusk"
  | Muted_graphite -> Say.make ~ko:"다운톤 흑연" ~en:"Muted Graphite"
  | Solarized_dark -> Say.make ~ko:"Solarized Dark" ~en:"Solarized Dark"
  | Nord -> Say.make ~ko:"Nord" ~en:"Nord"
  | Dracula -> Say.make ~ko:"Dracula" ~en:"Dracula"
  | Gruvbox_dark -> Say.make ~ko:"Gruvbox Dark" ~en:"Gruvbox Dark"
  | Catppuccin_mocha -> Say.make ~ko:"Catppuccin Mocha" ~en:"Catppuccin Mocha"

let preset_of_name name =
  match String.lowercase_ascii (String.trim name) with
  | "midnight" -> Some Midnight
  | "arcade_hi" | "arcade-hi" -> Some Arcade_hi
  | "paper_light" | "paper-light" -> Some Paper_light
  | "mono" -> Some Mono
  | "muted" -> Some Muted
  | "muted_warm" | "muted-warm" -> Some Muted_warm
  | "muted_green" | "muted-green" -> Some Muted_green
  | "muted_dusk" | "muted-dusk" -> Some Muted_dusk
  | "muted_graphite" | "muted-graphite" -> Some Muted_graphite
  | "solarized_dark" | "solarized-dark" -> Some Solarized_dark
  | "nord" -> Some Nord
  | "dracula" -> Some Dracula
  | "gruvbox_dark" | "gruvbox-dark" -> Some Gruvbox_dark
  | "catppuccin_mocha" | "catppuccin-mocha" -> Some Catppuccin_mocha
  | _ -> None

let preset_index = function
  | Midnight -> 0
  | Arcade_hi -> 1
  | Paper_light -> 2
  | Mono -> 3
  | Muted -> 4
  | Muted_warm -> 5
  | Muted_green -> 6
  | Muted_dusk -> 7
  | Muted_graphite -> 8
  | Solarized_dark -> 9
  | Nord -> 10
  | Dracula -> 11
  | Gruvbox_dark -> 12
  | Catppuccin_mocha -> 13

let equal_preset a b = Int.equal (preset_index a) (preset_index b)

let of_preset preset =
  match palette_override preset with
  | Some palette -> of_palette preset palette
  | None -> of_palette preset (builtin_palette preset)

(* Built-in Midnight, ignoring overrides. Live rendering must use [of_preset]
   so a TOML override applies; this value exists for callers that need a
   compile-time sample theme. *)
let default = of_palette Midnight (builtin_palette Midnight)

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
