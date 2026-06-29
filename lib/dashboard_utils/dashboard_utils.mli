(** Dashboard utility primitives — small string/JSON helpers, severity
    ranking, and three ADTs (health level, session lifecycle, tone) that
    replace ad-hoc string matching across the dashboard, briefing, and
    operator modules. *)

(** {1 Time} *)

val parse_iso_opt : string option -> float option
(** Parse an ISO-8601 timestamp via {!Masc_domain.parse_iso8601}.
    Returns [None] for [None], empty/whitespace strings, or parse failures. *)

(** {1 Strings} *)

val first_some : 'a option -> 'a option -> 'a option
(** Return the first [Some], or the second. *)

val string_contains : needle:string -> string -> bool
(** Case-sensitive substring test. *)

val string_contains_ci : needle:string -> string -> bool
(** Case-insensitive substring test (lowercases both sides). *)

(** [Some s] for non-empty trimmed text, [None] otherwise. *)

val dedup_strings : string list -> string list
(** Order-preserving deduplication via local [String_set]. *)

val compact_text : ?max_len:int -> string -> string
(** Collapse newlines/whitespace into single spaces, then truncate to a
    UTF-8-safe byte budget with a single-character ellipsis suffix.
    Default [max_len = 160]. Empty/whitespace input returns [""]. *)

val normalized_text_key : string -> string
(** [compact_text ~max_len:512] then trim and lowercase — a stable
    key for fuzzy text grouping. *)

(** {1 Session JSON accessors} *)

val session_payload_json : Yojson.Safe.t -> Yojson.Safe.t
(** Normalise a session JSON: if the ["status"] field is an [`Assoc],
    return that sub-object; otherwise return the original JSON. *)

val session_meta_json : Yojson.Safe.t -> Yojson.Safe.t
(** ["session"] sub-key inside the payload. *)

val session_summary_json : Yojson.Safe.t -> Yojson.Safe.t
(** ["summary"] sub-key inside the payload. *)

val session_team_health_json : Yojson.Safe.t -> Yojson.Safe.t
(** ["team_health"] sub-key inside the payload. *)

val session_communication_json : Yojson.Safe.t -> Yojson.Safe.t
(** ["communication_metrics"] sub-key inside the payload. *)

val session_status_opt : Yojson.Safe.t -> string option
(** Resolve the status string by probing ["summary"] → ["meta"] →
    top-level session JSON.  Returns [None] when no ["status"] field is found. *)

val session_recent_events : Yojson.Safe.t -> Yojson.Safe.t list
(** ["recent_events"] list from the session JSON. *)

val event_detail_json : Yojson.Safe.t -> Yojson.Safe.t
(** ["detail"] sub-key inside an event JSON. *)

(** {1 JSON helpers} *)

val string_list_of_json : Yojson.Safe.t -> string list
(** From a [`List] of [`String], yield the trimmed non-empty entries.
    Other shapes return []. *)

val member_assoc : string -> Yojson.Safe.t -> Yojson.Safe.t
(** Lookup [key] inside [`Assoc fields], returning [`Null] if missing or
    if the input is not an [`Assoc]. *)

val string_field : ?default:string -> string -> Yojson.Safe.t -> string
(** Read [key] as a [`String]. Default [""]. *)

val list_field : string -> Yojson.Safe.t -> Yojson.Safe.t list
(** Read [key] as a [`List]. Default [[]]. *)

(** Wrap as [`List of `String]. *)

(** {1 Ranking} *)

val severity_rank : string -> int
(** Severity score from a free-form status string ([0]–[2]). *)

val status_rank : string -> int
(** Status score for keeper status ([0]–[4]). *)

val take : int -> 'a list -> 'a list
(** [take n xs] returns the first [n] elements (or all if shorter). *)

(** {1 Health level} *)

(** Health severity, ordered by {!Health_status.rank}. Parsed from
    dashboard/operator JSON via {!health_level_of_string}, then used in
    typed predicates ({!is_health_critical} etc.) instead of string
    matching. *)
type health_level = Health_status.t

val health_level_of_string : string -> health_level
val string_of_health_level : health_level -> string
val severity_rank_of_health_level : health_level -> int

(** {1 Session lifecycle} *)

(** Session lifecycle. ADT makes the different terminal sets visible:
    {!is_session_terminal} = {[ Completed | Cancelled | Failed | Stopped ]};
    {!is_session_blocked} = {[ Failed | Cancelled | Interrupted ]}. *)
type session_lifecycle =
  | SL_active
  | SL_running
  | SL_paused
  | SL_completed
  | SL_cancelled
  | SL_failed
  | SL_stopped
  | SL_interrupted
  | SL_expired
  | SL_unknown

val session_lifecycle_of_string : string -> session_lifecycle
val string_of_session_lifecycle : session_lifecycle -> string

(** {1 Status/health predicates} *)

val is_keeper_offline : string -> bool
(** Membership in [["offline"; "inactive"; "error"]]. *)

val is_health_critical : health_level -> bool
val is_health_warning : health_level -> bool
val is_health_at_risk : health_level -> bool

val is_session_terminal : session_lifecycle -> bool
val is_session_blocked : session_lifecycle -> bool

(** {1 Tone} *)

(** Severity indicator for UI rendering — eliminates catch-all string
    matching, serialized only at JSON boundaries via {!string_of_tone}. *)
type tone = Tone_ok | Tone_warn | Tone_bad

val string_of_tone : tone -> string
val tone_rank : tone -> int
