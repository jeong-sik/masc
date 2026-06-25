(** keeper-v2 #9: response-feedback typed model + deterministic aggregation
    (MASC-side only; OAS is unaware of this module by construction).

    Phase 1a — the PURE, deterministic core: the vote vocabulary, a strict
    JSON codec, and a pure tally fold. No I/O, no Eio. The durable sink
    ([open_sink]/[record]) and the log reader ([read_tally]) land in Phase 1b
    on top of these types.

    Design + adversarial-review trail: keeper-v2 backlog #9. The vote is a
    closed variant (not [bool]) because the FE toggle is retractable, and the
    codec returns [result] on unknown input rather than substituting a default
    — the deliberate counter-example to the SOUL-evolution callback's
    [Option.value ~default:"Creativity"] path. *)

(** The vote. Three states because the operator toggle is retractable:
    re-clicking the active button clears the vote. A [bool] would drop the
    retraction case, so this is a closed variant. *)
type signal =
  | Helpful      (** FE 'up' / 좋음 *)
  | Not_helpful  (** FE 'down' / 별로 *)
  | Cleared      (** FE toggle-off: an explicit un-vote, NOT absence *)

(** Originating surface. Closed variant — adding a channel is a compile
    obligation, not a silent string passthrough. Only [Dashboard] has a real
    producer today; Discord/Slack/etc. are added when their producer lands
    (pre-populating them now would hardcode a roadmap into the type). *)
type source =
  | Dashboard

(** One durable feedback record. [turn_id] reuses the canonical
    {!Keeper_invariant.turn_id} (server-assigned turn identity) rather than a
    fresh ad-hoc key. All times are float epoch seconds; ISO conversion, if
    any, happens only at the wire boundary in the caller. *)
type record =
  { keeper_id   : string
  ; turn_id     : Keeper_invariant.turn_id
  ; signal      : signal
  ; source      : source
  ; recorded_at : float
  }

(** {2 Strict wire codec — no Unknown→default} *)

val signal_to_wire : signal -> string
val signal_of_wire : string -> (signal, string) result
(** ["up" | "down" | "clear"]. Anything else is [Error], never a default. *)

val source_to_wire : source -> string
val source_of_wire : string -> (source, string) result
(** ["dashboard"]. Anything else is [Error]. *)

val to_json : record -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (record, string) result
(** Strict: a missing field, a wrong type, or an unknown signal/source token
    all return [Error]. Never substitutes a default. *)

(** {2 Aggregation — pure, deterministic} *)

type tally =
  { helpful     : int
  ; not_helpful : int
  ; cleared     : int          (** retractions seen; informational *)
  ; net         : int          (** [helpful - not_helpful]; integer, no weights *)
  ; malformed   : int          (** parse failures; 0 here (records are already
                                   parsed), populated by Phase-1b [read_tally] *)
  ; last_at     : float option (** epoch of the most recent counted record *)
  }

val empty_tally : tally

val tally_of_records : record list -> tally
(** Pure, deterministic: same record list ⇒ same tally. Votes are deduplicated
    by [turn_id] with last-occurrence-wins (the log is append-only and
    chronological, so the last record for a turn is the current vote — a
    re-vote or a [Cleared] supersedes earlier ones). [Cleared] is counted but
    excluded from [net] (a retraction is "no opinion", not a negative). No
    magic multipliers, no time-decay, no fabricated 0..1 score. *)
