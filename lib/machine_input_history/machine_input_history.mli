(** Private transfer port for an immutable input prefix captured with a frame.
    The worker owner serializes publication and reads. No emulator or host API. *)
val tool_name : string
val input_schema : Yojson.Safe.t
type 'a t
val create : encode:('a -> Yojson.Safe.t) -> unit -> 'a t
val publish : 'a t -> incarnation:string -> entry_count:int -> newest_first:'a list -> Yojson.Safe.t
(** Keeps the captured persistent list without traversing it. The native owner
    guarantees the count and a fresh incarnation on replacement/restore. *)
val clear : 'a t -> unit
val read : 'a t -> arguments:Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** Requests identify the exact published incarnation and entry_count. [before]
    is an exclusive cursor into oldest-first numbering; entries return newest
    first and [next_before] resumes at the next older record. [max_bytes] bounds
    the JSON payload, excluding the surrounding MCP response. Sequential pages
    reuse a list cursor without walking the already transferred prefix. Missing,
    superseded, malformed and oversized-single-record reads fail explicitly. *)
