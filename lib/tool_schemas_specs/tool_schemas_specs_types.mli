(** Tool descriptor generator input types. *)

val config_category_enum_strings : string list
(** Issue #15257 Phase 1: Canonical SSOT for config category enum strings. *)

type param_type =
  | T_string of
      { enum : string list option
      ; default : string option
      }
  | T_int of
      { min : int option
      ; max : int option
      ; default : int option
      }
  | T_bool of { default : bool option }
  | T_string_array of { default : Yojson.Safe.t option }
  | T_object of { default : Yojson.Safe.t option }

type param =
  { p_name : string
  ; p_type : param_type
  ; p_description : string
  ; p_required : bool
  }

(** Behavior contract — Issue #15257 C축. 자세한 rationale은 .ml 참조. *)

type dashboard_scope =
  | Dashboard_scope_all
  | Dashboard_scope_current
(** The dashboard tool's [scope] argument. One owner for the JSON Schema enum
    and the runtime parser, which sit on opposite sides of the generator's
    dependency cut (#27069). *)

val dashboard_scope_to_string : dashboard_scope -> string
val dashboard_scope_of_string_opt : string -> dashboard_scope option
val all_dashboard_scopes : dashboard_scope list

val dashboard_scope_strings : string list
(** The enum, in the order the schema lists it. *)

val dashboard_scope_default : dashboard_scope

type tool_name_ref = string

type usage_hint =
  | Mention_specific_agent
  | Update_status
  | Help_request

type behavior_rule =
  | Precede_with of tool_name_ref list
  | Hint of usage_hint

type tool_spec =
  { name : string
  ; description : string
  ; parameters : param list
  ; additional_properties : bool
  ; behavior_contract : behavior_rule list
  }
