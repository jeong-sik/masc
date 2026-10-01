(** The nonempty accessories the portrait renderer can show.

    Membership comes from {!Keeper_portrait_look}'s slot types. These values
    describe an accessory; they carry no ownership or purchase authority. *)

type slot = Face | Neck | Head | Hand | Base

type t = private
  | Face_item of Keeper_portrait_look.face_item
  | Neck_item of Keeper_portrait_look.neck_item
  | Head_item of Keeper_portrait_look.head_item
  | Hand_item of Keeper_portrait_look.hand_item
  | Base_item of Keeper_portrait_look.base_item

val all : t list
(** Every nonempty item, ordered by slot and the renderer's declaration order.
    Empty-slot constructors are never items. *)

val slots : slot list
val slot : t -> slot
val slot_id : slot -> string
val slot_of_id : string -> slot option
val empty_id : slot -> string
(** The explicit empty label in an equipment snapshot. It is not a catalog
    item and {!of_id} refuses it. *)

val id : t -> string
(** The stable id used by the catalog, equipment output and preview request. *)

val of_id : string -> t option
(** [None] for an unknown id, including an empty-slot label. *)

val in_slot : Keeper_portrait_look.equipment -> slot -> t option
(** [None] when the slot is empty. This says what the picture wears, not what
    its Keeper owns. *)

val preview : t -> Keeper_portrait_look.equipment -> Keeper_portrait_look.equipment
(** Replace the selected item's slot in a drawing. Other slots are preserved;
    no equipment choice is persisted. *)
