(** Tool descriptor generator input types. *)

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
