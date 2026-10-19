(** Native keyboard data. Text is Unicode; a chord has one scalar or a named
    key and an explicit, closed set of modifiers. *)
type modifier = Control | Meta | Alt | Shift
type key = Named of Browser_action.key | Character of Uchar.t
type t = private { modifiers : modifier list; key : key }
val of_wire : key:string -> modifiers:string list -> (t, string) result
val modifier_name : modifier -> string
val key_text : key -> string
val to_json_fields : t -> (string * Yojson.Safe.t) list
val validate_text : string -> (unit, string) result
