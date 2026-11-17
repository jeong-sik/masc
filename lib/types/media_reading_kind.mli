(** The audio/document boundary shared by runtime reader declarations and
    attachment readings. This type does not declare a converter's support. *)
type t = Audio | Document
[@@deriving show, eq]
