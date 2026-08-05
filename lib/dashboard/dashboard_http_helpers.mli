(** Dashboard HTTP helpers — shared env-parsing and JSON utility functions.

    Extracted from [server_dashboard_http.ml] for sub-module reuse. The
    surface is broad because four caller modules (server runtime info,
    namespace truth support, monitoring, keeper) [open
    Dashboard_http_helpers] and reference helpers unqualified. *)

(** {1 Environment-variable parsing} *)

(** [true] iff the env var is set to ["1" | "true" | "yes" | "y"]
    (case/whitespace insensitive). Default [false]. *)

val bool_default_true_of_env : string -> bool
(** Inverse default: [false] only when set to ["0" | "false" | "no" | "n"]. *)

val int_of_env_default :
  string -> default:int -> min_v:int -> max_v:int -> int
(** Parse env var as int and clamp to [\[min_v, max_v\]]. *)

val float_of_env_default :
  string -> default:float -> min_v:float -> max_v:float -> float
(** Parse env var as float and clamp to [\[min_v, max_v\]]. *)

(** {1 Dashboard-tunable limits} *)


val operator_snapshot_recent_completed_limit : unit -> int

(** {1 Tag/detail parsing} *)

val bool_of_tag_value : string -> bool
(** Truthy tag value: ["1" | "true" | "yes" | "y" | "on"], case-insensitive. *)

(** {1 Numeric helpers} *)

(** Nearest-rank percentile over a non-empty sorted copy of [values].
    Returns [None] for the empty list. *)

val safe_age_seconds_opt :
  now_ts:float -> event_ts:float -> int option
(** Bounded non-negative age in seconds; [None] for NaN/Inf inputs. *)

val keeper_tail_lines_or_empty :
  site:string -> string -> max_bytes:int -> max_lines:int -> string list
(** Dashboard-local degraded tail read.  The caller must name the
    dashboard site so memory read failures are counted and logged
    explicitly instead of flowing through the removed global silent
    fallback. *)

(** {1 JSON field accessors (marker-tolerant)} *)

val json_list_field : string -> Yojson.Safe.t -> Yojson.Safe.t list
(** Extract a [`List] field; returns [[]] on missing/wrong-type. *)

val json_int_field :
  string -> Yojson.Safe.t -> default:int -> int
(** Extract an [`Int]/[`Intlit] field; falls back to [default] otherwise. *)

val json_string_field_opt : string -> Yojson.Safe.t -> string option
(** [Some s] for non-blank [`String s]; [None] otherwise. *)

val json_assoc_field : string -> Yojson.Safe.t -> Yojson.Safe.t
(** Extract a record field; returns [`Assoc \[\]] on missing/wrong-type. *)

(** Like {!json_assoc_field} but [None] when missing/wrong-type. *)

(** {1 List helpers} *)

val count_where : 'a list -> ('a -> bool) -> int
(** [count_where xs p] is [List.length (List.filter p xs)]. *)

val normalize_text : string -> string
(** Collapse multi-line text into a single trimmed line, dropping blank
    rows. SSOT for judge-module LLM output normalization. *)
