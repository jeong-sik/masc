(** Dashboard utility primitives — small string/JSON helpers, severity
    ranking, and two ADTs (health level, tone) that replace ad-hoc string
    matching across the dashboard, briefing, and operator modules. *)

(** {1 Time} *)

val parse_iso_opt : string option -> float option
(** Parse an RFC 3339 timestamp via {!Masc_domain.parse_iso8601_opt}.
    Returns [None] for [None], empty/whitespace strings, or parse failures. *)

(** {1 Strings} *)

val first_some : 'a option -> 'a option -> 'a option
(** Return the first [Some], or the second. *)

val string_contains : needle:string -> string -> bool
(** Case-sensitive substring test. *)

val dedup_strings : string list -> string list
(** Order-preserving deduplication via local [String_set]. *)

val compact_text : ?max_len:int -> string -> string
(** Collapse newlines/whitespace into single spaces, then truncate to a
    UTF-8-safe byte budget with a single-character ellipsis suffix.
    Default [max_len = 160]. Empty/whitespace input returns [""]. *)

val normalized_text_key : string -> string
(** [compact_text ~max_len:512] then trim and lowercase — a stable
    key for fuzzy text grouping. *)

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

(** {1 Ranking} *)

val status_rank : string -> int
(** Rank a serialized {!Masc_domain.agent_status}: [Busy] 4, [Active] 3,
    [Listening] 2, [Inactive] 1. Anything that is not an [agent_status]
    ranks 0. *)

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

(** {1 Status/health predicates} *)

val is_health_critical : health_level -> bool
val is_health_warning : health_level -> bool
val is_health_at_risk : health_level -> bool

(** {1 Tone} *)

(** Severity indicator for UI rendering — eliminates catch-all string
    matching, serialized only at JSON boundaries via {!string_of_tone}. *)
type tone = Tone_ok | Tone_warn | Tone_bad

val string_of_tone : tone -> string
val tone_rank : tone -> int
