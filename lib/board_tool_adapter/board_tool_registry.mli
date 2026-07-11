(** Tool schemas advertised by the board MCP adapter. *)

val tools : Masc_domain.tool_schema list

val schema_for_board_name : Tool_name.Board_name.t -> Masc_domain.tool_schema
(** Exhaustive typed projection to the advertised [masc_board_*] schema. *)

val identity_fields_for_board_name : Tool_name.Board_name.t -> string list
(** Input fields whose value is runtime-owned identity for this board tool. *)

val identity_input_fields : string list
(** Union of runtime-owned identity input fields used by board tools. *)
