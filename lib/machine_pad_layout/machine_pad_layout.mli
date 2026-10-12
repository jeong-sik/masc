(** Pure gamepad layout shared by the worker and host UI. *)
type button = South | East | North | West | Dpad_up | Dpad_down | Dpad_left | Dpad_right | Start | Select | Tl | Tr
val all_buttons : button list
val button_to_string : button -> string
val button_of_string : string -> (button, string) result
type binding = { keys : string list; label : string }
type layout = (button * binding) list
val bindings : layout -> (button * binding) list
val binding : layout -> button -> binding option
type source = Workspace | Builtin
val source_to_string : source -> string
val to_json : saves_name:string -> source:source -> layout -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> ((string * source * layout), string) result
