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

type tool_spec =
  { name : string
  ; description : string
  ; parameters : param list
  ; additional_properties : bool
  }
