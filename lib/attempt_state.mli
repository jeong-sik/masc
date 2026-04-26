(** Shared retry/attempt state for reconcile-style surfaces.

    Purpose: a single record + backoff predicate reused by surfaces that
    today reimplement their own [attempt_record] / [last_attempt_*] fields
    (sidecar lifecycle routes, voice bridge, dashboard cache). See #8930
    for the consolidation trail.

    Boundary rules:
    - Internal state is [float] (seconds-since-epoch). ISO serialization is
      a boundary-only concern; callers must not compare wire strings.
    - [result] is a closed variant, not a string. [result_of_string] is a
      sound-partial parser (returns [None] on unknown input) to avoid the
      #8605 family of silent-default decoders. *)

type result =
  | Start_dispatched
  | Failed of { reason : string }
  | Timed_out

(** Canonical wire token. Round-trips with [result_of_string_opt] for
    known constructors. Unknown-result is impossible by construction. *)
val result_to_string : result -> string

(** Strict parser. Returns [None] for anything the wire-format does not
    recognise. Callers that must keep going should warn + treat as a new
    attempt rather than coercing to a concrete result. *)
val result_of_string_opt : string -> result option

type t =
  { generation : int
  ; attempt_number : int
  ; attempt_id : string (** [Printf.sprintf "%d:%d" generation attempt_number]. *)
  ; last_result : result
  ; next_retry_unix : float option
  ; updated_unix : float
  }

(** Build the next attempt record. [attempt_number] continues from
    [previous] when [generation] matches, else resets to 1. *)
val make_next
  :  now:float
  -> backoff_seconds:float
  -> generation:int
  -> last_result:result
  -> previous:t option
  -> t

(** Window test. False when [next_retry_unix] is [None] or in the past. *)
val is_backoff_active : now:float -> t -> bool

val to_json : t -> Yojson.Safe.t

(** [of_json] is strict: missing fields, wrong types, or unknown [last_result]
    tokens all return [None]. *)
val of_json : Yojson.Safe.t -> t option
