module Look = Keeper_portrait_look

type slot = Face | Neck | Head | Hand | Base [@@deriving enumerate]

type t =
  | Face_item of Look.face_item
  | Neck_item of Look.neck_item
  | Head_item of Look.head_item
  | Hand_item of Look.hand_item
  | Base_item of Look.base_item

let face_item = function
  | Look.Bare_face -> None
  | (Look.Glasses | Look.Shades | Look.Eye_patch | Look.Plaster | Look.Freckles | Look.Beard) as item ->
    Some (Face_item item)

let neck_item = function
  | Look.Bare_neck -> None
  | (Look.Scarf | Look.Bow_tie | Look.Medal) as item -> Some (Neck_item item)

let head_item = function
  | Look.Bare_head -> None
  | (Look.Bow | Look.Crown | Look.Beanie) as item -> Some (Head_item item)

let hand_item = function
  | Look.Empty_hand -> None
  | (Look.Book | Look.Mug | Look.Quill) as item -> Some (Hand_item item)

let base_item = function
  | Look.No_dish -> None
  | Look.Dish _ as item -> Some (Base_item item)

let all =
  List.filter_map face_item Look.all_face_items
  @ List.filter_map neck_item Look.all_neck_items
  @ List.filter_map head_item Look.all_head_items
  @ List.filter_map hand_item Look.all_hand_items
  @ List.filter_map base_item Look.all_base_items

let slots = all_of_slot

let slot = function
  | Face_item _ -> Face
  | Neck_item _ -> Neck
  | Head_item _ -> Head
  | Hand_item _ -> Hand
  | Base_item _ -> Base

let slot_id = function
  | Face -> "face"
  | Neck -> "neck"
  | Head -> "head"
  | Hand -> "hand"
  | Base -> "base"

let slot_of_id id = List.find_opt (fun slot -> String.equal (slot_id slot) id) slots

let empty_id = function
  | Face -> "bare_face"
  | Neck -> "bare_neck"
  | Head -> "bare_head"
  | Hand -> "empty_hand"
  | Base -> "no_dish"

let id = function
  | Face_item Look.Glasses -> "glasses"
  | Face_item Look.Shades -> "shades"
  | Face_item Look.Eye_patch -> "eye_patch"
  | Face_item Look.Plaster -> "plaster"
  | Face_item Look.Freckles -> "freckles"
  | Face_item Look.Beard -> "beard"
  | Neck_item Look.Scarf -> "scarf"
  | Neck_item Look.Bow_tie -> "bow_tie"
  | Neck_item Look.Medal -> "medal"
  | Head_item Look.Bow -> "bow"
  | Head_item Look.Crown -> "crown"
  | Head_item Look.Beanie -> "beanie"
  | Hand_item Look.Book -> "book"
  | Hand_item Look.Mug -> "mug"
  | Hand_item Look.Quill -> "quill"
  | Base_item (Look.Dish Look.Gilt) -> "dish_gilt"
  | Base_item (Look.Dish Look.Silver) -> "dish_silver"
  | Base_item (Look.Dish Look.Oak) -> "dish_oak"
  (* Construction is private. The five constructors' helpers exclude these
     empty-slot values before a catalog item can leave this module. *)
  | Face_item Look.Bare_face | Neck_item Look.Bare_neck
  | Head_item Look.Bare_head | Hand_item Look.Empty_hand | Base_item Look.No_dish ->
    invalid_arg "Keeper_portrait_item.id: an empty slot is not an item"

let of_id value = List.find_opt (fun item -> String.equal (id item) value) all

let in_slot (equipment : Look.equipment) = function
  | Face -> face_item equipment.face
  | Neck -> neck_item equipment.neck
  | Head -> head_item equipment.head
  | Hand -> hand_item equipment.hand
  | Base -> base_item equipment.base

let preview item (equipment : Look.equipment) =
  match item with
  | Face_item face -> { equipment with face }
  | Neck_item neck -> { equipment with neck }
  | Head_item head -> { equipment with head }
  | Hand_item hand -> { equipment with hand }
  | Base_item base -> { equipment with base }
