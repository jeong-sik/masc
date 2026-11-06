(** How the journal reads and writes JSON: the field readers every decoder
    uses, and the codecs of the source and of a node result.

    [refuse] raises the decoding error, [require] raises it when a condition
    fails, and [decode] returns it as [Error]. [sha] and [json_sha] hash a
    string or a JSON value, [canonical_equal] compares two JSON values, and
    [nonblank], [exact_name] and [finite] check a string or a number.
    [valid_json] checks a JSON value and [object_fields] splits an object into
    the expected fields. [field], [string], [integer], [bool], [number],
    [nonnegative], [list] and [optional] read one field value, and
    [option_json] writes an option.

    [source_to_yojson], [source_of_yojson], [source_json], [source_of_json],
    [validate_source] and [same_source] encode, decode, check and compare a
    source, and [source_observation_json], [source_observation_of_json] and
    [same_source_observation] do the same for its observation.
    [named_origin_to_yojson] encodes the origin of a named producer.
    [result_json], [result_of_json], [effect_json] and [effect_of_json] encode
    and decode a tool result and its effect.
    [Keeper_tool_execution_journal] includes this module. *)

open Keeper_tool_execution_journal_types

val refuse : string -> 'a

val require : bool -> string -> unit

val decode : (unit -> 'a) -> ('a, string) result

val sha : string -> string

val json_sha : Yojson.Safe.t -> string

val canonical_equal : Yojson.Safe.t -> Yojson.Safe.t -> bool

val nonblank : string -> bool

val exact_name : string -> bool

val finite : float -> bool

val option_json :
  ('a -> 'b) -> 'a option -> [> `Assoc of (string * 'b) list | `Null ]

val valid_json : Yojson.Safe.t -> unit

val object_fields :
  string list -> Yojson.Safe.t -> (string * Yojson.Safe.t) list

val field : string -> (string * 'a) list -> 'a

val string : [> `String of 'a ] -> 'a

val integer : [> `Int of 'a ] -> 'a

val bool : [> `Bool of 'a ] -> 'a

val number : Yojson.Safe.t -> float

val list : ('a -> 'b) -> [> `List of 'a list ] -> 'b list

val optional : (Yojson.Safe.t -> 'a) -> Yojson.Safe.t -> 'a option

val nonnegative : Yojson.Safe.t -> int

val named_origin_to_yojson : named_origin -> Yojson.Safe.t

val source_json :
  source ->
  Yojson.Safe.t

val same_source : source -> source -> bool

val validate_source :
  source -> unit

val source_of_json :
  Yojson.Safe.t -> source

val source_to_yojson : source -> Yojson.Safe.t

val source_of_yojson : Yojson.Safe.t -> (source, error) result

val source_observation_json :
  source_observation ->
  Yojson.Safe.t

val source_observation_of_json :
  Yojson.Safe.t ->
  source_observation

val same_source_observation :
  source_observation option ->
  source_observation option -> bool

val result_json :
  Tool_result.result -> Yojson.Safe.t

val effect_of_json :
  Yojson.Safe.t -> Tool_result.failure_effect_disposition

val effect_json :
  Tool_result.failure_effect_disposition -> Yojson.Safe.t

val result_of_json : Yojson.Safe.t -> Tool_result.result
