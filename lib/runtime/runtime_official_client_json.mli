(** Runtime_official_client_json — JSON shape checks shared by the official
    client runtimes.

    {!Runtime_antigravity}, {!Runtime_claude_code} and
    {!Runtime_codex_app_server} each speak a line-delimited JSON protocol and
    each carries its own [error] sum type. The shape checks were identical in
    all three; only the constructor they fail with differed. {!Make} takes
    that constructor so the checks live once and each runtime keeps its own
    error type. *)

module type Error = sig
  type t

  val protocol : stage:string -> detail:string -> t
  (** Build the runtime's protocol-failure error. [stage] names the protocol
      step being parsed; [detail] describes what was wrong with the payload. *)
end

module Make (E : Error) : sig
  val validate_unique_object_keys :
    stage:string -> path:string -> Yojson.Safe.t -> (unit, E.t) result
  (** Reject duplicate keys anywhere in the tree. `Yojson` keeps every
      occurrence, so a payload that repeats a key parses but reads
      ambiguously; [path] is the dotted position reported on failure. *)

  val assoc_at : string -> Yojson.Safe.t -> ((string * Yojson.Safe.t) list, E.t) result
  val required_member :
    string -> string -> (string * Yojson.Safe.t) list -> (Yojson.Safe.t, E.t) result

  val required_string :
    string -> string -> (string * Yojson.Safe.t) list -> (string, E.t) result
  (** Absent, non-string and whitespace-only all fail. *)

  val optional_string :
    string -> string -> (string * Yojson.Safe.t) list -> (string option, E.t) result
  (** Absent and [`Null] are both [None]; a non-string present value fails. *)

  val required_bool :
    string -> string -> (string * Yojson.Safe.t) list -> (bool, E.t) result
end

val bounded_tail : limit:int -> string -> string -> string
(** [bounded_tail ~limit current addition] appends and keeps the last [limit]
    bytes. Used for the rolling stderr tail each runtime reports on failure. *)
