(** What a keeper's portrait shows: a candle imp.

    The look has two layers. The {!body} is the keeper itself -- wax, flame,
    horns, face -- and comes from the keeper's name, so the same name always
    gives the same candle and nothing has to be stored. The {!equipment} is
    what the candle wears, one item per slot (face, neck, head, hand, base);
    {!equipment_of_name} gives a keeper its starting item from the name as
    well, and later work can equip other items without changing the body. *)

type wax = Ivory | Peach | Mint | Lavender | Sky | Butter | Rose | Charcoal

type flame = Ember | Azure | Jade | Violet | Pink | Gold

type horn_style =
  | Nub  (** two short knobs *)
  | Long  (** two tall horns *)
  | One  (** a single horn on the left corner *)
  | Ram  (** two hooks that curl outward and back down *)

type horn_colour = Crimson | Soot | Brass | Bone | Blossom

type eyes =
  | Bean  (** tall ovals with a sparkle *)
  | Dot  (** small round dots with a sparkle *)
  | Happy  (** both eyes closed in an upward arc *)
  | Sleepy  (** half-lidded *)
  | Sparkle  (** bigger ovals with two sparkles *)
  | Wink  (** left eye open, right eye closed *)

type mouth = W | Smile | O | Flat | Fang

type drip = {
  drip_x : float;  (** horizontal position, shape units from the centre *)
  drip_length : float;  (** how far it runs down from the top edge *)
  drip_width : float;  (** radius where it leaves the top edge *)
}

type body = private {
  wax : wax;
  half_width : float;  (** half the wax block's width, shape units *)
  half_height : float;  (** half the wax block's height, shape units *)
  corner : float;  (** rounding radius of the wax block's corners *)
  drips : drip list;  (** zero to three runs of wax down the front *)
  flame : flame;
  flame_size : float;  (** 1.0 is the reference flame *)
  flame_lean : float;  (** horizontal offset of the flame's tip *)
  twin_flame : bool;  (** two wicks instead of one *)
  horns : horn_style;
  horn_colour : horn_colour;
  horn_length : float;  (** 1.0 is the reference length *)
  eyes : eyes;
  mouth : mouth;
  blush : bool;
  backdrop_hue : float;  (** hue of the round backdrop, in [0, 1) *)
}

type face_item = Bare_face | Glasses | Shades | Eye_patch | Plaster | Freckles | Beard
type neck_item = Bare_neck | Scarf | Bow_tie | Medal
type head_item = Bare_head | Bow | Crown | Beanie
type hand_item = Empty_hand | Book | Mug | Quill
type dish = Gilt | Silver | Oak
type base_item = No_dish | Dish of dish

type equipment = {
  face : face_item;
  neck : neck_item;
  head : head_item;
  hand : hand_item;
  base : base_item;
}

val bare : equipment
(** Every slot empty. *)

(** {2 Ranges}

    Every body lies within these, whether it came from a name or from
    {!body}. The renderer relies on them: its framing and the regions it skips
    are sized for them. Closed at both ends except the hue, which wraps. *)

val half_width_range : float * float
val half_height_range : float * float
val corner_range : float * float
val max_drips : int

val drip_edge_margin : float
(** A drip's centre stays this far inside the wax's sides. *)

val drip_length_range : float * float
val drip_width_range : float * float
val flame_size_range : float * float
val flame_lean_range : float * float
val horn_length_range : float * float

val backdrop_hue_range : float * float
(** [lo <= hue < hi]. *)

val body_of_name : string -> body
(** The keeper's candle, drawn from SHA-256 of a domain-separated key and the
    name. Total and deterministic: the same name always gives the same body,
    on every platform and compiler version (the generator is SplitMix64, not
    [Stdlib.Random]). *)

type invalid_body =
  | Half_width_out_of_range
  | Half_height_out_of_range
  | Corner_out_of_range
  | Too_many_drips
  | Drip_out_of_range  (** a drip's position, length or width *)
  | Flame_size_out_of_range
  | Flame_lean_out_of_range
  | Horn_length_out_of_range
  | Backdrop_hue_out_of_range

val body :
  wax:wax ->
  half_width:float ->
  half_height:float ->
  corner:float ->
  drips:drip list ->
  flame:flame ->
  flame_size:float ->
  flame_lean:float ->
  twin_flame:bool ->
  horns:horn_style ->
  horn_colour:horn_colour ->
  horn_length:float ->
  eyes:eyes ->
  mouth:mouth ->
  blush:bool ->
  backdrop_hue:float ->
  (body, invalid_body) result
(** A body other than a name's, for items and tests. [Error] names the first
    field outside its range (NaN and the infinities are always outside). *)

val equipment_of_name : string -> equipment
(** The keeper's starting items, from a hash separate from the body's, so
    changing which items are handed out never changes a keeper's body. *)

val mascot : body * equipment
(** MASC's own candle: the one the TUI shows on [/about]. Chosen by hand
    rather than drawn from a name -- an ivory candle with an ember flame,
    long crimson horns, bean eyes, a small "w" mouth and a blush, standing
    on a gilt dish, wearing nothing. *)

val flame_weight : flame -> int
(** How often a name gets this flame, relative to the others. Every flame
    has one, so a new flame is generated as soon as it has a weight. *)

val starting_equipment : equipment list
(** What {!equipment_of_name} picks from (before the dish, which is picked
    from {!all_base_items} on its own): a few bare sets and one set per item a
    face, neck, head or hand can hold. *)

(** Every constructor, in declaration order, generated from the type
    declarations by [ppx_enumerate], so a new constructor is listed without
    being added by hand. Generation picks wax, horns, horn colours, eyes,
    mouths and dishes from these lists directly; flames through
    {!flame_weight}; worn items through {!starting_equipment}. *)

val all_wax : wax list
val all_flames : flame list
val all_horn_styles : horn_style list
val all_horn_colours : horn_colour list
val all_eyes : eyes list
val all_mouths : mouth list
val all_face_items : face_item list
val all_neck_items : neck_item list
val all_head_items : head_item list
val all_hand_items : hand_item list
val all_base_items : base_item list
