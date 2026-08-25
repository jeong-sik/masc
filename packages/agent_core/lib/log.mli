(** Structured Logging -- level-based structured log system.

    Provides typed log records with key-value fields, composable sinks,
    and zero-cost filtering for disabled levels.

    - [sink] is [record -> unit] -- composable and lightweight.
    - [field] is a closed variant for schema enforcement at call sites.
    - Disabled levels skip record allocation entirely.

    @stability Internal
    @since 0.93.1 *)

(** {2 Level} *)

type level =
  | Debug
  | Info
  | Warn
  | Error

val level_to_string : level -> string
val level_of_string : string -> (level, string) result
val level_to_yojson : level -> Yojson.Safe.t
val level_of_yojson : Yojson.Safe.t -> (level, string) result
val pp_level : Format.formatter -> level -> unit
val show_level : level -> string

(** {2 Field} *)

type field =
  | S of string * string
  | I of string * int
  | F of string * float
  | B of string * bool
  | J of string * Yojson.Safe.t
  | Secret of string * Llm_provider.Secret.t
  (** Secret field — always renders as [<redacted>] in every sink. *)

val field_to_json : field -> string * Yojson.Safe.t

(** Best-effort redaction of secret patterns in log messages and string
    fields.  Used automatically by the built-in sinks; exposed for callers
    that want to scrub data before constructing a [field]. *)
val redact : string -> string

(** {2 Record} *)

type record =
  { ts : float
  ; level : level
  ; module_name : string
  ; message : string
  ; fields : field list
  ; trace_id : string option
  ; span_id : string option
  }

val record_to_json : record -> Yojson.Safe.t

(** {2 Sink} *)

type sink = record -> unit

(** {2 Global configuration}

    Underlying globals use [Atomic.t]. Concurrent sink registration is
    linearized with a CAS loop so [add_sink] does not lose updates
    across domains. [clear_sinks] first resets the no-sink drop counter,
    then publishes an empty sink set with an atomic store. A race between
    [add_sink] and [clear_sinks] resolves to whichever sink-set operation
    linearizes last; records emitted after the counter reset can still be
    counted if they observe no sinks. *)

val set_global_level : level -> unit
val add_sink : sink -> unit
val clear_sinks : unit -> unit

(** Number of enabled log records dropped because no sink was registered since
    the last {!clear_sinks}. *)
val dropped_without_sink_count : unit -> int

(** {2 Logger instance} *)

type t

val create : module_name:string -> unit -> t
val with_trace_id : t -> trace_id:string -> t
val with_span_id : t -> span_id:string -> t

(** {2 Logging} *)

val emit : t -> level -> string -> field list -> unit
val debug : t -> string -> field list -> unit
val info : t -> string -> field list -> unit
val warn : t -> string -> field list -> unit
val error : t -> string -> field list -> unit

(** {2 Built-in sinks} *)

val json_sink : _ Eio.Flow.sink -> sink
val stderr_sink : unit -> sink
val collector_sink : unit -> sink * (unit -> record list)
