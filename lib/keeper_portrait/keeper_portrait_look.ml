type wax = Ivory | Peach | Mint | Lavender | Sky | Butter | Rose | Charcoal
type flame = Ember | Azure | Jade | Violet | Pink | Gold
type horn_style = Nub | Long | One | Ram
type horn_colour = Crimson | Soot | Brass | Bone | Blossom
type eyes = Bean | Dot | Happy | Sleepy | Sparkle | Wink
type mouth = W | Smile | O | Flat | Fang

type drip = { drip_x : float; drip_length : float; drip_width : float }

type body = {
  wax : wax;
  half_width : float;
  half_height : float;
  corner : float;
  drips : drip list;
  flame : flame;
  flame_size : float;
  flame_lean : float;
  twin_flame : bool;
  horns : horn_style;
  horn_colour : horn_colour;
  horn_length : float;
  eyes : eyes;
  mouth : mouth;
  blush : bool;
  backdrop_hue : float;
}

type face_item = Bare_face | Glasses | Shades | Eye_patch | Plaster | Freckles | Beard
type neck_item = Bare_neck | Scarf
type head_item = Bare_head | Bow
type hand_item = Empty_hand
type dish = Gilt | Silver | Oak
type base_item = No_dish | Dish of dish

type equipment = {
  face : face_item;
  neck : neck_item;
  head : head_item;
  hand : hand_item;
  base : base_item;
}

let bare = { face = Bare_face; neck = Bare_neck; head = Bare_head; hand = Empty_hand; base = No_dish }

let all_wax = [ Ivory; Peach; Mint; Lavender; Sky; Butter; Rose; Charcoal ]
let all_flames = [ Ember; Azure; Jade; Violet; Pink; Gold ]
let all_horn_styles = [ Nub; Long; One; Ram ]
let all_horn_colours = [ Crimson; Soot; Brass; Bone; Blossom ]
let all_eyes = [ Bean; Dot; Happy; Sleepy; Sparkle; Wink ]
let all_mouths = [ W; Smile; O; Flat; Fang ]
let all_face_items = [ Bare_face; Glasses; Shades; Eye_patch; Plaster; Freckles; Beard ]
let all_neck_items = [ Bare_neck; Scarf ]
let all_head_items = [ Bare_head; Bow ]
let all_hand_items = [ Empty_hand ]
let all_base_items = [ No_dish; Dish Gilt; Dish Silver; Dish Oak ]

(* ---- deterministic generator ---------------------------------------------

   SplitMix64 seeded from SHA-256. Written out rather than [Stdlib.Random] so
   a compiler upgrade can never change a keeper's face.
   https://prng.di.unimi.it/splitmix64.c *)

type generator = { mutable state : int64 }

let golden_gamma = 0x9E3779B97F4A7C15L
let mix_1 = 0xBF58476D1CE4E5B9L
let mix_2 = 0x94D049BB133111EBL

(* 53 bits fill a float's mantissa exactly. *)
let mantissa_bits = 53
let mantissa_scale = Float.ldexp 1.0 (-mantissa_bits)

let generator_of key =
  let digest = Digestif.SHA256.(digest_string key |> to_raw_string) in
  { state = String.get_int64_be digest 0 }

let next g =
  g.state <- Int64.add g.state golden_gamma;
  let z = g.state in
  let z = Int64.mul (Int64.logxor z (Int64.shift_right_logical z 30)) mix_1 in
  let z = Int64.mul (Int64.logxor z (Int64.shift_right_logical z 27)) mix_2 in
  Int64.logxor z (Int64.shift_right_logical z 31)

(* In [0, 1). *)
let unit_float g =
  Int64.to_float (Int64.shift_right_logical (next g) (64 - mantissa_bits)) *. mantissa_scale

let uniform g lo hi = lo +. ((hi -. lo) *. unit_float g)

(* In [0, n). The float route keeps the draw count fixed at one per call. *)
let below g n = min (n - 1) (int_of_float (unit_float g *. float_of_int n))

let chance g p = unit_float g < p

(* Every list handed to [pick] and [weighted] is one of the non-empty
   constants in this file; an empty one is a programming error. *)
let pick g items =
  match items with
  | [] -> invalid_arg "Keeper_portrait_look.pick: empty list"
  | _ :: _ -> List.nth items (below g (List.length items))

let weighted g items =
  let total = List.fold_left (fun acc (_, w) -> acc + w) 0 items in
  let target = below g total in
  let rec walk acc = function
    | [] -> invalid_arg "Keeper_portrait_look.weighted: empty list"
    | [ (item, _) ] -> item
    | (item, w) :: rest -> if target < acc + w then item else walk (acc + w) rest
  in
  walk 0 items

(* ---- body ---------------------------------------------------------------- *)

(* Domain separation: body and equipment use different hashes of the name, so
   changing how items are handed out never moves a keeper's body. *)
let body_key = "masc.keeper-portrait.body\000"
let equipment_key = "masc.keeper-portrait.equipment\000"

(* Ranges of the candle's proportions, in shape units (the portrait spans
   about -1..1). Chosen on the prototype sheet: narrower than 0.25 hides the
   face, wider than 0.34 hits the horns' room. *)
let half_width_range = (0.25, 0.34)
let half_height_range = (0.33, 0.46)
let corner_range = (0.05, 0.13)

(* Drips: at most three so the face stays readable; kept this far inside the
   side edges so a drip never looks like a torn corner. *)
let max_drips = 3
let drip_edge_margin = 0.07
let drip_length_range = (0.08, 0.26)
let drip_width_range = (0.035, 0.055)

(* Ember is the ordinary candle, so it comes up most; the magical colours
   stay special. Weights out of 12. *)
let flame_weights = [ (Ember, 5); (Azure, 2); (Jade, 1); (Violet, 1); (Pink, 1); (Gold, 2) ]
let flame_size_range = (0.85, 1.25)
let flame_lean_range = (-0.07, 0.07)
let twin_flame_chance = 0.12
let horn_length_range = (0.8, 1.2)
let blush_chance = 0.7

let between g (lo, hi) = uniform g lo hi

let body_of_name name =
  let g = generator_of (body_key ^ name) in
  let wax = pick g all_wax in
  let flame = weighted g flame_weights in
  let half_width = between g half_width_range in
  let half_height = between g half_height_range in
  let drip_count = below g (max_drips + 1) in
  let drips =
    List.init drip_count (fun _ ->
        let drip_x = uniform g (drip_edge_margin -. half_width) (half_width -. drip_edge_margin) in
        let drip_length = between g drip_length_range in
        let drip_width = between g drip_width_range in
        { drip_x; drip_length; drip_width })
  in
  let flame_size = between g flame_size_range in
  let flame_lean = between g flame_lean_range in
  let twin_flame = chance g twin_flame_chance in
  let corner = between g corner_range in
  let horns = pick g all_horn_styles in
  let horn_colour = pick g all_horn_colours in
  let horn_length = between g horn_length_range in
  let eyes = pick g all_eyes in
  let mouth = pick g all_mouths in
  let blush = chance g blush_chance in
  let backdrop_hue = unit_float g in
  {
    wax; half_width; half_height; corner; drips; flame; flame_size; flame_lean; twin_flame; horns;
    horn_colour; horn_length; eyes; mouth; blush; backdrop_hue;
  }

(* ---- starting equipment -------------------------------------------------- *)

(* One starting item, as on the prototype sheet: three in eleven keepers wear
   nothing, the rest one item in the slot it belongs to. *)
type starting_item = Nothing | On_face of face_item | On_neck of neck_item | On_head of head_item

let starting_items =
  [
    Nothing; Nothing; Nothing; On_face Glasses; On_face Shades; On_face Beard; On_neck Scarf; On_head Bow;
    On_face Freckles; On_face Plaster; On_face Eye_patch;
  ]

let equipment_of_name name =
  let g = generator_of (equipment_key ^ name) in
  let item = pick g starting_items in
  let base = pick g all_base_items in
  let with_item =
    match item with
    | Nothing -> bare
    | On_face face -> { bare with face }
    | On_neck neck -> { bare with neck }
    | On_head head -> { bare with head }
  in
  { with_item with base }

(* ---- the mascot ---------------------------------------------------------- *)

(* Hand-picked, not hashed: the candle that stands for MASC itself. The
   proportions are the ones the prototype sheet settled on; two drips and a
   plum backdrop so it does not read as a blank. *)
let mascot =
  ( {
      wax = Ivory;
      half_width = 0.30;
      half_height = 0.40;
      corner = 0.10;
      drips =
        [
          { drip_x = -0.16; drip_length = 0.20; drip_width = 0.050 };
          { drip_x = 0.17; drip_length = 0.12; drip_width = 0.042 };
        ];
      flame = Ember;
      flame_size = 1.0;
      flame_lean = 0.0;
      twin_flame = false;
      horns = Long;
      horn_colour = Crimson;
      horn_length = 1.0;
      eyes = Bean;
      mouth = W;
      blush = true;
      backdrop_hue = 0.83;
    },
    { bare with base = Dish Gilt } )
