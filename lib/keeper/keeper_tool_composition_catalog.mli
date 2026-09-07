(** Closed grammar for immutable Keeper tool-composition plans. Declared
    inside SKILL.md composition fences ({!Keeper_skill_catalog}).

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
  | Invalid_execution_mode of
      { path : string list
      ; mode : string
      }
  | Async_tool_not_statically_read_only of
      { name : string
      ; node_id : Keeper_tool_plan.Node_id.t
      ; tool_name : string
      }
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
  | Invalid_param_type of
      { path : string list
      ; type_name : string
      }
  | Duplicate_param_name of
      { name : string
      ; param : string
      }
  | Unknown_param_reference of
      { name : string
      ; param : string
      }
  | Unused_param of
      { name : string
      ; param : string
      }
  | Plan_rejected of
      { name : string
      ; error : Keeper_tool_plan.error
      }

type execution_mode =
  | Inline
  | Async

(** Scalar parameter types a composition can declare. The generated input
    schema mirrors them, so the provider-side validation the model already
    gets for every tool applies to composition arguments unchanged. *)
type param_type =
  | String_param
  | Integer_param
  | Number_param
  | Boolean_param

type param = private
  { param_name : string
  ; param_type : param_type
  ; param_description : string
  }

type entry = private
  { name : string
  ; description : string option
  ; execution : execution_mode
  ; params : param list
        (** Declared invocation parameters, [[compositions.params]] in the
            document. Every declared name is referenced by some node input
            ([kind = "param"]) and vice versa — both directions are load
            errors. All params are required. Async entries bind params at
            submission: the broker never replays a worker closure after a
            crash, so the bound plan lives exactly as long as the run. *)
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

val skill_source_of_tool_name : string -> string option
(** The SKILL.md a composition tool name came from, relative to the masc
    directory (["skills/<name>/SKILL.md"]), or [None] for a name that is not a
    composition tool. Composed rather than looked up: the tool exists only
    because that file was read, so the path is a fact about how it got here,
    not a guess that it is there. *)
(** Stable model-visible name for this materialized composition. *)

val execution_mode_to_string : execution_mode -> string

(** Execution-semantics kind (RFC-0386) declared by the entry's execution
    mode: [Inline] entries are [Composition_tool], [Async] entries are
    [Async_composition_tool]. *)
val tool_kind : entry -> Keeper_tool_descriptor.tool_kind

(** The shared async request controls operate on async composition runs, so
    both are [Keeper_tool_descriptor.Async_composition_tool]. *)
val status_tool_kind : Keeper_tool_descriptor.tool_kind
val cancel_tool_kind : Keeper_tool_descriptor.tool_kind

(** The ad-hoc plan tool's name. It lives here beside the catalog's own tool
    names because the approval policy needs to recognise it and must not
    depend on the surface that materialises it. Unlike a [keeper_compose_*]
    entry it carries no catalog plan: its nodes arrive in the tool input. *)

val status_tool_name : string
val cancel_tool_name : string

val skill_tool_name : string
(** The tool that serves one instruction skill body by name. *)

val error_to_string : error -> string

val input_schema_of_params : param list -> Yojson.Safe.t
(** The model-visible input schema for an entry: an object with one required,
    described property per declared param, closed to extras. The empty list
    yields the zero-param object schema. *)

type instantiation_error =
  | Missing_argument of string
  | Instantiated_plan_rejected of Keeper_tool_plan.error

val instantiation_error_to_string : instantiation_error -> string
val instantiation_error_to_json : instantiation_error -> Yojson.Safe.t

val instantiate
  :  descriptors:Keeper_tool_descriptor.t list
  -> args:Yojson.Safe.t
  -> entry
  -> (Keeper_tool_plan.t, instantiation_error) result
(** Bind one invocation's validated arguments into the entry's plan: every
    [Param] leaf becomes the caller's value and the param-free copy is
    revalidated by {!Keeper_tool_plan.create}. A zero-param entry returns its
    declared plan unchanged. *)
