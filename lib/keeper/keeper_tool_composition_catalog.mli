(** TOML-backed catalog of immutable Keeper tool-composition plans.

    The document grammar is closed and explicit. Input templates use tagged
    [literal], [output], [object], and [array] nodes; strings are never scanned
    for placeholders or inferred as references. Plan creation resolves tool
    authority only through the process-owned descriptor registry. *)

type expected_value =
  | String_value
  | String_array_value
  | Table_value
  | Table_array_value
  | Array_value

type error =
  | Toml_syntax of string
  | Empty_catalog
  | Unknown_field of
      { path : string list
      ; field : string
      }
  | Duplicate_field of
      { path : string list
      ; field : string
      }
  | Missing_field of
      { path : string list
      ; field : string
      }
  | Wrong_value_kind of
      { path : string list
      ; field : string
      ; expected : expected_value
      }
  | Empty_name of { path : string list }
  | Composition_name_too_long of
      { name : string
      ; maximum_bytes : int
      }
  | Invalid_composition_name_character of
      { name : string
      ; character : char
      }
  | Duplicate_composition_name of string
  | Invalid_template_kind of
      { path : string list
      ; kind : string
      }
  | Invalid_node_id of
      { path : string list
      ; error : Keeper_tool_plan.Node_id.error
      }
  | Invalid_json_pointer of
      { path : string list
      ; error : Keeper_tool_plan.Json_pointer.syntax_error
      }
  | Duplicate_template_object_field of
      { path : string list
      ; field : string
      }
  | Plan_rejected of
      { name : string
      ; error : Keeper_tool_plan.error
      }

type entry = private
  { name : string
  ; description : string option
  ; plan : Keeper_tool_plan.t
  }

type t

val parse : string -> (t, error) result
(** Parse one complete TOML document and validate every composition against the
    current canonical Keeper descriptor registry. Unknown fields and malformed
    tagged templates fail closed. *)

val entries : t -> entry list
val find : t -> string -> entry option
val tool_name : entry -> string
(** Stable model-visible name for this materialized composition. *)

val error_to_string : error -> string

val path : config_root:string -> string
(** Dedicated catalog path below the resolved MASC config root. *)
