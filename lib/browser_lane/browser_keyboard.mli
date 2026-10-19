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
(** Valid UTF-8 without C0/DEL controls. Enter and Tab are explicit key
    actions: text must never silently change focus or submit a form. *)
(** W3C input sources shared by WebDriver and BiDi. The caller owns release
    after dispatch, including transport failures and cancellation. *)
val input_source : id:string -> t -> Yojson.Safe.t
val text_source : id:string -> string -> (Yojson.Safe.t, string) result
(** W3C reserves U+E000 through U+E05D as special keys. Text containing one
    is refused instead of accidentally issuing a control command. *)
