(** Structured terminal-reason surface for keeper turn ledgers.

    RFC-0047 PR-3: the [code: string] field is removed; the typed
    [disposition] field is the SSOT. [code : t -> string] is provided
    as an accessor for callers that still need the wire string
    (Prometheus labels, JSON, dashboard chips). [severity / summary /
    next_action] are now exhaustive matches on [disposition]; the
    legacy [severity_of_code / summary_of_code / next_action_of_code]
    substring classifiers are deleted.

    The [severity] type is re-exported from [Keeper_turn_disposition]
    so external callers using [Keeper_turn_terminal.Ok | Warn | Bad |
    Unknown_bad] continue to compile. *)

type severity = Keeper_turn_disposition.severity =
  | Ok
  | Warn
  | Bad
  | Unknown_bad

type t =
  { disposition : Keeper_turn_disposition.t
    (** Typed operator-facing disposition. SSOT after RFC-0047 PR-3.
          [severity / summary / next_action] are derived from this
          field at construction time. The wire-format string
          (previously [t.code]) is now [Keeper_turn_terminal.code t]. *)
  ; source : string
  ; severity : severity
  ; summary : string
  ; next_action : string option
  }

(** Wire-format accessor. Returns
    [Keeper_turn_disposition.to_wire t.disposition]. Use this when
    the caller needs the legacy string code (JSON serialisation,
    Prometheus labels, dashboard chips). *)
val code : t -> string

val severity_to_string : severity -> string
val success : unit -> t
val of_code : ?source:string -> ?summary:string -> ?next_action:string -> string -> t

(** Typed constructor. Skips the wire→[Keeper_turn_disposition.t]
    decode step that [of_code] performs; useful for producers that
    have already committed to a typed disposition (e.g. wrapping an
    SDK error code as [Provider_error (Sdk_error _)] without losing
    the typed identity in an [Unknown { raw_error = _ }] fallback). *)
val of_disposition
  :  ?source:string
  -> ?summary:string
  -> ?next_action:string
  -> Keeper_turn_disposition.t
  -> t

val of_failure
  :  ?post_commit_ambiguous:bool
  -> ?tool_call_count:int
  -> raw_error:string
  -> Agent_sdk.Error.sdk_error
  -> t

val of_legacy_error_text : string -> t
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> t option
