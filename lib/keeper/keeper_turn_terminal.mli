(** Structured terminal-reason surface for keeper turn ledgers. *)

type severity =
  | Ok
  | Warn
  | Bad
  | Unknown_bad

type t =
  { code : string
  ; disposition : Keeper_turn_disposition.t
    (** RFC-0047 PR-2: typed operator-facing disposition. Derived
          from [code] via [Keeper_turn_disposition.of_wire] at
          construction time. PR-3 swaps
          [severity / summary / next_action] derivation to be
          exhaustive on this field and removes [code: string]. *)
  ; source : string
  ; severity : severity
  ; summary : string
  ; next_action : string option
  }

val severity_to_string : severity -> string
val success : unit -> t
val of_code : ?source:string -> ?summary:string -> ?next_action:string -> string -> t

val of_failure
  :  ?post_commit_ambiguous:bool
  -> ?tool_call_count:int
  -> raw_error:string
  -> Agent_sdk.Error.sdk_error
  -> t

val of_legacy_error_text : string -> t
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> t option
