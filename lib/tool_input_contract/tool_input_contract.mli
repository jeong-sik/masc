(** Tool_input_validation — Pre-dispatch validation of one tool argument object.

    Property [type], [enum], [const] and [required], including nested objects
    and array items, are checked by
    [Agent_core.Tool_input_validation.validate] against the tool's full input
    schema, the same check Agent-Core runs before any tool handler. MASC adds the
    checks Agent-Core does not make: undeclared fields under
    [additionalProperties: false], [oneOf] branch selection, declared
    range/length bounds, and arguments that did not arrive. Underscore-prefixed
    protocol markers are stripped before validation. *)

type numeric_keyword =
  | Minimum
  | Maximum
  | Exclusive_minimum
  | Exclusive_maximum

type count_keyword =
  | Min_length
  | Max_length
  | Min_items
  | Max_items

(** A declared range or length bound. *)
type bound_keyword =
  | Numeric_bound of numeric_keyword
  | Count_bound of count_keyword

(** The rule an argument object broke. Constructors for schema defects
    ([Schema_*]) are masc's fault, not the caller's.

    [Field_errors] paths are JSON Pointers ([/query]); range paths are dotted
    property paths ([query], [items[0]]). *)
type violation =
  | Schema_not_registered
  | Schema_declares_required_without_properties
  | Schema_unusable of { detail : string }
      (** Agent-Core refused the input schema itself. *)
  | Schema_bound_malformed of
      { path : string
      ; keyword : bound_keyword
      }
  | Arguments_for_fieldless_schema
  | Retired_transition_alias of { fields : string list }
  | Arguments_did_not_arrive
      (** An empty object for a schema that cannot accept one. *)
  | Unsupported_fields of { fields : string list }
  | No_one_of_branch_matches
  | Several_one_of_branches_match
  | Field_errors of Agent_core.Tool_input_validation.field_error list
      (** Property [type], [enum], [const] or [required], at any depth. *)
  | Argument_out_of_range of
      { path : string
      ; keyword : bound_keyword
      }
  | Validation_raised of { exception_text : string }

(** [message] is the rendering shown to the caller; branch on [violation]. *)
type rejection =
  { tool_name : string
  ; schema : Yojson.Safe.t option
  ; violation : violation
  ; message : string
  }

(** The failed tool result a rejection is reported as. *)
val rejection_result : rejection -> Tool_result.result

type schema_shape =
  { properties : string list
  ; required : string list
  ; one_of_required : string list list
  ; errors : string list
  }

val schema_shape : Yojson.Safe.t -> schema_shape
(** Validated JSON-schema shape projection used by dispatch diagnostics and
    descriptor discovery. Unexpected [properties], [required], or [oneOf]
    shapes are reported in [errors] instead of silently flattening to [[]]. *)

val schema_shape_json : Yojson.Safe.t -> Yojson.Safe.t
(** JSON form of {!schema_shape}. Omits [one_of_required] and [schema_errors]
    when empty. *)

val constraint_declaration_paths : Yojson.Safe.t -> string list
(** Every declared range/length constraint that pre-dispatch validation can
    reach, as ["<field path>:<keyword>"] — [minimum], [maximum],
    [exclusiveMinimum], [exclusiveMaximum], [minLength], [maxLength],
    [minItems], [maxItems].

    Enforcement descends through [properties] and object-form [items] only.
    A declaration placed anywhere else (a [oneOf] branch, a tuple-form
    [items]) would never be enforced, so tests compare this list against a
    raw scan of the whole schema. *)

type accepted = Accepted_empty_schema | Accepted_valid | Accepted_normalized
val accepted_reason : accepted -> string
val violation_reason : violation -> string
val check_arguments : schema:Yojson.Safe.t option -> name:string -> args:Yojson.Safe.t ->
  ((Yojson.Safe.t * accepted), rejection) result
(** Pure schema contract. The caller owns registry lookup, telemetry and effects. *)
