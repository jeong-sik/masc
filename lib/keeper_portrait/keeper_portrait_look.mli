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

type body = {
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

val bare : equipment
(** Every slot empty. *)

val body_of_name : string -> body
(** The keeper's candle, drawn from SHA-256 of a domain-separated key and the
    name. Total and deterministic: the same name always gives the same body,
    on every platform and compiler version (the generator is SplitMix64, not
    [Stdlib.Random]). *)

val equipment_of_name : string -> equipment
(** The keeper's starting items, from a hash separate from the body's, so
    changing which items are handed out never changes a keeper's body. *)

(** Every constructor, in declaration order. Generation picks from these lists;
    tests hold them against exhaustive matches. *)

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
