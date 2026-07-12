(** Pure wire contract for the independent failure-judgment LLM boundary.

    The model decides whether a failed Keeper lane can resume with explicit
    guidance or requires operator attention. Parsing is fail-closed: the wire
    object must contain exactly the declared fields, and invalid combinations
    never become a domain value. *)

type verdict =
  | Resume_with_guidance of
      { guidance : string
      ; rationale : string
      }
  | Escalate_to_operator of { rationale : string }

val decision_tokens : string list
(** Stable JSON-schema enum tokens, in declaration order. *)

val decision_label : verdict -> string
val rationale : verdict -> string
val guidance : verdict -> string option

val of_yojson : Yojson.Safe.t -> (verdict, string) result
(** Decode the strict wire object:
    [{"decision", "guidance", "rationale"}]. [guidance] is a non-empty
    string for [Resume_with_guidance] and JSON [null] for
    [Escalate_to_operator]. Unknown, missing, or duplicate keys are errors. *)

val to_yojson : verdict -> Yojson.Safe.t
(** Canonical encoding used by tests and telemetry. *)
