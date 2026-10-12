(** Pure tool-schema contract. The public Types surface includes this private
    owner; generated and manual decoders share exact-field validation and the
    constructors that keep authoritative schemas and parameter projections in
    agreement. No provider transport, runtime state or filesystem effects. *)

type param_type =
  | String
  | Integer
  | Number
  | Boolean
  | Array
  | Object
[@@deriving yojson, show]

val param_type_to_string : param_type -> string

type tool_param =
  { name : string
  ; description : string
  ; param_type : param_type
  ; required : bool
  }
[@@deriving yojson, show]

val param_type_of_string : string -> (param_type, string) result
val tool_param_to_json : tool_param -> Yojson.Safe.t

(** Total exact inverse for the manual JSON encoding. The derived
    {!tool_param_of_yojson} boundary applies the same duplicate/unknown-field
    rejection to its own encoding. A payload that is not an object, or whose
    fields have the wrong JSON shape, is reported as [Error] rather than
    raising [Yojson.Safe.Util.Type_error]. *)
val tool_param_of_json : Yojson.Safe.t -> (tool_param, string) result

val params_to_input_schema : tool_param list -> Yojson.Safe.t

(** Exact JSON shape of a value, used to name what arrived when a decode is
    refused. *)
type json_shape =
  | Json_null
  | Json_bool
  | Json_int
  | Json_intlit
  | Json_float
  | Json_string
  | Json_list
  | Json_object
[@@deriving show, eq]


(** Exact object-shape check for a manual decoder. [Error] names the missing
    required fields, the fields outside [required @ optional], and the
    duplicated keys, prefixed with [scope]. *)
val exact_object_fields
  :  scope:string
  -> required:string list
  -> ?optional:string list
  -> (string * Yojson.Safe.t) list
  -> (unit, string) result

val json_schema_type_to_param_type_result : string -> (param_type, string) result

(** Derive the parameter view of a JSON Schema. Keeps only the parts a
    {!tool_param} can carry — name, one representable type, description, and
    required — which is why it is a projection of the schema and not a
    substitute for it. Valid properties expressed only through [$ref],
    [anyOf], [oneOf], or an unrepresentable union are omitted from this view;
    they remain unchanged in the authoritative schema. *)
val json_schema_to_params_result : Yojson.Safe.t -> (tool_param list, string) result

(** Why a JSON value was refused as a tool argument schema. *)
type input_schema_error =
  | Input_schema_not_an_object of json_shape
  | Input_schema_duplicate_keys of
      { path : string (** Path of the offending object, rooted at ["input_schema"]. *)
      ; keys : string list (** The repeated keys, sorted and deduplicated. *)
      }
[@@deriving show, eq]

val input_schema_error_to_string : input_schema_error -> string

(** Accept a value as a tool argument schema. A provider tool argument schema
    is a JSON object with unique keys, so an explicit [`Null], a scalar, an
    array, or an object Yojson parsed with a repeated key (at any depth) is
    refused instead of being stored. *)
val input_schema_of_json : Yojson.Safe.t -> (Yojson.Safe.t, input_schema_error) result

(** A tool definition. [private]: the two views of the arguments must agree, and
    the only values that satisfy that are the ones {!tool_schema_of_params} and
    {!tool_schema_of_input_schema} build. *)
type tool_schema = private
  { name : string
  ; description : string
  ; parameters : tool_param list
  ; strict : bool option
    (** Per-function JSON Schema strict validation. [Some true] opts the tool
        into strict mode (OpenAI, DeepSeek Beta, Kimi, MiMo); [None] omits the
        field so providers apply their default. *)
  ; input_schema : Yojson.Safe.t option
    (** Authoritative wire form emitted to providers verbatim when [Some]; when
        [None] the wire form is derived from [parameters] by
        {!params_to_input_schema}. [parameters] is the derived view used for
        validation and introspection, so [Some schema] always satisfies
        [parameters = json_schema_to_params_result schema].

        {!params_to_input_schema} keeps only type, description and required,
        so a caller-supplied schema carrying [minimum], [maximum], [default],
        [enum] or nested properties reaches the model only through this
        field. *)
  }
[@@deriving yojson, show]

(** Build a schema from the parameter view. [input_schema] is [None], so the
    wire form is derived by {!params_to_input_schema}. *)
val tool_schema_of_params
  :  ?strict:bool
  -> name:string
  -> description:string
  -> parameters:tool_param list
  -> unit
  -> tool_schema

(** Build a schema from one authoritative JSON Schema — the only way
    [input_schema] is ever [Some]. [parameters] is derived from [~input_schema]
    here, so the two cannot disagree. Properties that cannot be represented by
    the deliberately lossy {!tool_param} view (for example [$ref], [anyOf], or
    multi-type unions) remain only in the authoritative schema instead of
    making the tool unusable. Fails when the value is not a tool argument
    schema ({!input_schema_of_json}), explicitly describes non-object tool
    arguments, or contains a malformed projectable field. *)
val tool_schema_of_input_schema
  :  ?strict:bool
  -> name:string
  -> description:string
  -> input_schema:Yojson.Safe.t
  -> unit
  -> (tool_schema, string) result

(** Separates enum members when they are written as text instead of carried
    as [enum], as ["one of: a | b"] in a parameter description for a provider
    whose tool schemas cannot carry [enum]. Members are written unquoted, so a
    member containing this character cannot be told apart from two members. *)
val enum_member_separator : char

(** [members] written as text, separated by {!enum_member_separator}. *)
val enum_vocabulary_text : string list -> string

val tool_schema_to_json : tool_schema -> Yojson.Safe.t

(** Inverse of {!tool_schema_to_json}, and total: malformed input is reported
    as [Error] rather than raising. Absence of an authoritative schema is
    encoded by omitting the ["input_schema"] key, so an omitted key decodes to
    [None] and a present one must be a tool argument schema
    ({!input_schema_of_json}). A payload whose ["parameters"] array disagrees
    with the projection of its ["input_schema"] is refused, because no value of
    this type could have carried that pair. Top-level and parameter objects must
    contain exactly their declared fields with no duplicate keys. The derived
    {!tool_schema_of_yojson} boundary enforces the same rule for its own
    encoding. A schema written by {!tool_schema_to_json} therefore round-trips
    unchanged. *)
val tool_schema_of_json : Yojson.Safe.t -> (tool_schema, string) result

val result_all : ('a, 'e) result list -> ('a list, 'e) result
