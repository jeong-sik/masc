val parse_header_block : string -> (string * string) list * string
val header_assoc_opt : (string * string) list -> string -> string option
val nonempty_header_opt : (string * string) list -> string -> string option
val comma_list_header_opt : (string * string) list -> string -> string list
