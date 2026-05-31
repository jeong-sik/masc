(** Tool alias routing shared by tool-surface and keeper callers. *)

type route =
  { internal_name : string
  ; translate : Yojson.Safe.t -> Yojson.Safe.t
  ; public_schema : Yojson.Safe.t option
  ; descriptor : Agent_tool_descriptor.t
  }

val route : string -> route option
val is_known_public : string -> bool
val is_known_internal : string -> bool
val public_names : unit -> string list
val public_name_for_internal : string -> string option
val public_masc_to_internal : string -> string option
val strip_mcp_masc_prefix : string -> string

type canonical_resolution =
  | Public_mcp of
      { stripped : string
      ; internal : string
      }
  | Public_alias of { internal : string }
  | Internal of { canonical : string }
  | Unknown

val canonical_resolution : string -> canonical_resolution
val canonical_internal_name : string -> string option
val public_input_schema : string -> Yojson.Safe.t option
val translate_input : public:string -> Yojson.Safe.t -> Yojson.Safe.t
