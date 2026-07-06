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
    by [turn_id], keeping the record with the greatest [recorded_at] — a re-vote
    or a [Cleared] supersedes an earlier vote for the same turn. [recorded_at]
    is the single authority for "latest" (the same one [last_at] uses), so the
    tally is independent of the input list order: a non-append read, a merge, or
    out-of-order input cannot change the winner. [Cleared] is counted but
    excluded from [net] (a retraction is "no opinion", not a negative). No magic
    multipliers, no time-decay, no fabricated 0..1 score. *)

(** {2 Durable sink + log aggregation — Stdlib I/O via the sibling-log family} *)

val record : config:Workspace.config -> record -> (unit, [ `Io of string ]) result
(** Append [r] to its keeper's feedback log
    ({!Keeper_types_support.keeper_feedback_log_path}, derived from
    [r.keeper_id]) via the sibling-family writer
    {!Keeper_types_support.append_jsonl_line_result} — so the feedback log shares the
    .policy/.decisions log family: identical JSONL format and the same
    size-threshold rotation while returning write failures as [`Io], so a
    failed write is never silently dropped. *)

val read_tally :
  config:Workspace.config -> keeper_id:string -> (tally, [ `Io of string ]) result
(** Read [keeper_id]'s feedback log and fold it into a {!tally}. Reuses the
    family reader {!Fs_compat.load_jsonl_diagnostics} (parsed values + count of
    JSON-malformed lines, oldest-first). A line that parses as JSON but not as
    a {!record} ([of_json] = [Error]) also increments [malformed], so a corrupt
    vote is counted and visible — never silently skipped to zero, never fatally
    zeroing the whole tally. A missing log (no votes yet) reads as
    {!empty_tally}; a read IO fault on an existing log surfaces as [`Io]. *)

(** {2 HTTP wire helpers — consumed by the GET/POST feedback route} *)

val tally_to_json : tally -> Yojson.Safe.t
(** Wire form of a {!tally} for the read API
    (GET [/api/v1/keepers/:name/feedback]). [last_at] serializes as a JSON
    number or [null]. *)

val record_of_request_body :
  keeper_id:string -> recorded_at:float -> Yojson.Safe.t -> (record, string) result
(** Parse a vote POST body [{ "signal", "source", "turn_id" }] into a
    {!record}. [keeper_id] comes from the route path and [recorded_at] from the
    server clock — neither is taken from (or trusted in) the body. Strict: an
    unknown signal/source token, or a missing/blank turn_id, returns [Error]
    rather than a default. *)
