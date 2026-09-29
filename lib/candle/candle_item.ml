type slot =
  | Face
  | Neck
  | Head
  | Hand
  | Base

type t =
  | Glasses
  | Shades
  | Eye_patch
  | Plaster
  | Freckles
  | Beard
  | Scarf
  | Bow_tie
  | Medal
  | Bow
  | Crown
  | Beanie
  | Book
  | Mug
  | Quill
  | Gilt_dish
  | Silver_dish
  | Oak_dish

type wear =
  | Wear of t
  | Default of slot

let all =
  [ Glasses; Shades; Eye_patch; Plaster; Freckles; Beard
  ; Scarf; Bow_tie; Medal
  ; Bow; Crown; Beanie
  ; Book; Mug; Quill
  ; Gilt_dish; Silver_dish; Oak_dish
  ]
;;

let slots = [ Face; Neck; Head; Hand; Base ]

let slot = function
  | Glasses | Shades | Eye_patch | Plaster | Freckles | Beard -> Face
  | Scarf | Bow_tie | Medal -> Neck
  | Bow | Crown | Beanie -> Head
  | Book | Mug | Quill -> Hand
  | Gilt_dish | Silver_dish | Oak_dish -> Base
;;

let slot_to_wire = function
  | Face -> "face"
  | Neck -> "neck"
  | Head -> "head"
  | Hand -> "hand"
  | Base -> "base"
;;

let slot_of_wire wire =
  List.find_opt (fun candidate -> String.equal (slot_to_wire candidate) wire) slots
;;

let slot_equal left right = String.equal (slot_to_wire left) (slot_to_wire right)

let to_wire = function
  | Glasses -> "glasses"
  | Shades -> "shades"
  | Eye_patch -> "eye_patch"
  | Plaster -> "plaster"
  | Freckles -> "freckles"
  | Beard -> "beard"
  | Scarf -> "scarf"
  | Bow_tie -> "bow_tie"
  | Medal -> "medal"
  | Bow -> "bow"
  | Crown -> "crown"
  | Beanie -> "beanie"
  | Book -> "book"
  | Mug -> "mug"
  | Quill -> "quill"
  | Gilt_dish -> "gilt_dish"
  | Silver_dish -> "silver_dish"
  | Oak_dish -> "oak_dish"
;;

(* The wire name is written once, in [to_wire]; reading it back walks [all]. *)
let of_wire wire = List.find_opt (fun candidate -> String.equal (to_wire candidate) wire) all
let equal left right = String.equal (to_wire left) (to_wire right)
let compare left right = String.compare (to_wire left) (to_wire right)

let wear_slot = function
  | Wear item -> slot item
  | Default slot -> slot
;;
