(** MASC Logging System - Structured logging with levels *)

(** Log levels *)
type level =
  | Debug
  | Info
  | Warn
  | Error

(** Structured event classes carried in log [details]. *)
type event_class = Routine

val event_class_to_string : event_class -> string
(** Convert a structured event class to its stable JSON label. *)

(** Log categories for dashboard filtering. *)
type category =
  | Fsm
  | Lifecycle
  | Directive
  | Heartbeat
  | Presence
  | Task
  | Tool
  | Memory
  | Telemetry
  | Routine
  | Boundary
  | Uncategorized

val category_to_string : category -> string
(** Canonical lowercase wire label for a {!category}. *)

val category_of_string_opt : string -> category option
(** Parse a category from its wire label.  Returns [None] for
    unrecognised input. *)

val level_to_string : level -> string
(** Convert level to string representation. *)

val level_to_int : level -> int
(** Convert level to integer for comparison. *)

val level_of_string_opt : string -> level option
(** Parse level from string without a fallback.  Returns [None] for
    unrecognised input. *)

val should_log : level -> bool
(** Check if a message at the given level should be logged. *)

val set_level : level -> unit
(** Set the global log level. *)

val set_level_from_string : string -> unit
(** Set the global log level from a string (e.g., from env var). *)

val init_from_env : unit -> unit
(** Initialize log level from MASC_LOG_LEVEL env var. *)

val timestamp : unit -> string
(** Get current timestamp as formatted string. *)

val format_utc_date_of : float -> string
(** #10392: format the [YYYY-MM-DD] UTC date for a Unix timestamp.
    Used internally for [system_log_<date>.jsonl] filename construction
    so the filename matches the entry [ts] field (also UTC).  Exposed
    for unit tests; production code calls [Ring.date_string] which
    delegates here. *)

val log : level -> ?ctx:string -> ?category:category -> ('a, unit, string, unit) format4 -> 'a
(** Log a message at the given level with optional context. *)

val emit : level -> ?module_name:string -> ?details:Yojson.Safe.t -> ?category:category -> string -> unit
(** Log a preformatted structured message with optional JSON details. *)

val emit_routine : ?module_name:string -> ?details:Yojson.Safe.t -> ?category:category -> string -> unit
(** Log repeatable housekeeping/telemetry through the central routine policy.
    The effective level is controlled by [MASC_LOG_ROUTINE_LEVEL] and defaults
    to [Debug]. Set it to [off] to suppress routine events entirely. *)

val debug : ?ctx:string -> ?category:category -> ('a, unit, string, unit) format4 -> 'a
val info : ?ctx:string -> ?category:category -> ('a, unit, string, unit) format4 -> 'a
val warn : ?ctx:string -> ?category:category -> ('a, unit, string, unit) format4 -> 'a
val error : ?ctx:string -> ?category:category -> ('a, unit, string, unit) format4 -> 'a

(** Mirror source kinds carried on every [Ring.entry]. *)
type source =
  | Structured
  | Legacy_stderr
  | Legacy_traceln
  | Client_tool_host

val source_to_string : source -> string
(** Canonical lowercase wire label for a {!source}.  The dashboard schema
    in [dashboard/src/api/schemas/logs.ts] reads this back via
    [source_of_string]. *)

val legacy_stderr : level:level -> ?module_name:string -> string -> unit
(** Mirror a stderr line into the dashboard log ring.  [~level] is
    required as of RFC-0079; the prior [?level] option backed a
    string-prefix classifier ([infer_legacy_level]) that has been removed. *)

val legacy_traceln : level:level -> ?module_name:string -> string -> unit
(** Mirror an [Eio.traceln]-style line into the dashboard log ring.
    [~level] required (see [legacy_stderr]). *)

(** In-memory ring buffer exposed for dashboard log viewer routes. *)
module Ring : sig
  (** RFC-0079: typed entry.  Wire format keeps [level] and [source] as
      their canonical strings (see {!level_to_string} / {!source_to_string});
      the dashboard schema in [dashboard/src/api/schemas/logs.ts] mirrors
      that wire format.  Pre-RFC-0079 fields [raw_level] /
      [normalized_level] / [legacy_classified] are gone — they only ever
      carried the pre-typed mirror's classifier state. *)
  type entry = {
    seq : int;
    ts : string;
    level : level;
    source : source;
    module_name : string;
    keeper_name : string option;
    turn_id : int option;
    message : string;
    details : Yojson.Safe.t;
    category : category option;
  }

  exception Entry_decode_error of string
  (** Raised by {!entry_of_json} on missing or ill-typed fields.  The
      file-fold boundary ([load_from_file]) catches this on historical
      JSONL files that were written before the typed encoder.  Every
      other call site lets it propagate. *)

  val capacity : int
  (** Maximum number of entries retained in the in-memory dashboard ring. *)

  val source_of_string : string -> source
  (** Inverse of {!source_to_string}.  Raises {!Entry_decode_error} on
      unknown labels. *)

  val recent :
    ?limit:int ->
    ?min_level:int ->
    ?module_filter:string ->
    ?since_seq:int ->
    ?before_seq:int ->
    ?order:[< `Newest_first | `Oldest_first > `Newest_first ] ->
    ?category_filter:string ->
    ?exclude_category:string list ->
    unit ->
    entry list
  (** Read a slice of the in-memory ring, newest-first by default.
      [since_seq] returns only entries strictly newer than the cursor (forward
      delta polling); [before_seq] returns only entries strictly older than the
      cursor (backward "load older" paging). Both are inclusive-exclusive on the
      cursor and compose into a bounded window when supplied together. *)

  val entry_to_json : entry -> Yojson.Safe.t
  val entry_of_json : Yojson.Safe.t -> entry
  val to_json : entry list -> Yojson.Safe.t
  val summary_json : unit -> Yojson.Safe.t
  (** Cheap operator summary for [/health].  It exposes ring counters,
      latest metadata, and file-sink state without raw log message text or
      [details] payloads. *)

  val init_file_sink : string -> unit
  (** Initialize file-based log persistence. Loads previous entries from disk
      into the ring buffer, then opens the file for appending new entries.
      [dir] is the directory for dated JSONL log files. *)

  val cleanup_old_files : ?keep_days:int -> string -> unit
  (** Remove log files older than [keep_days] (default 7). *)
end

val client_tool_host_error :
  ?module_name:string -> ?details:Yojson.Safe.t -> string -> unit
(** Mirror a client/tool-host failure into the dashboard log ring with its own source. *)

(** Functor for creating module-specific loggers.
    [M.name] controls the env-var key MASC_LOG_{NAME}_LEVEL
    and the context prefix in log output. *)
module type LOGGER = sig
  val emit : level -> ?details:Yojson.Safe.t -> ?keeper_name:string -> ?turn_id:int -> ?category:category -> string -> unit
  val routine :
    ?details:Yojson.Safe.t ->
    ?keeper_name:string ->
    ?turn_id:int ->
    ?category:category ->
    ('a, unit, string, unit) format4 ->
    'a
  val debug : ?keeper_name:string -> ?turn_id:int -> ?category:category -> ('a, unit, string, unit) format4 -> 'a
  val info : ?keeper_name:string -> ?turn_id:int -> ?category:category -> ('a, unit, string, unit) format4 -> 'a
  val warn : ?keeper_name:string -> ?turn_id:int -> ?category:category -> ('a, unit, string, unit) format4 -> 'a
  val warning : ?keeper_name:string -> ?turn_id:int -> ?category:category -> ('a, unit, string, unit) format4 -> 'a
  val error : ?keeper_name:string -> ?turn_id:int -> ?category:category -> ('a, unit, string, unit) format4 -> 'a
end

module Make (_ : sig val name : string end) : LOGGER

(** {1 Pre-defined module loggers} *)

module Workspace : LOGGER
module Mcp : LOGGER
module Auth : LOGGER
module Retry : LOGGER
module Backend : LOGGER
module Session : LOGGER
module Cancel : LOGGER
module Sub : LOGGER
module Spawn : LOGGER
module Pulse : LOGGER
module ModelClient : LOGGER
module Orchestrator : LOGGER
module BoardLog : LOGGER
module Metrics : LOGGER
module Dashboard : LOGGER
module Trpg : LOGGER
module Feed : LOGGER
module Telemetry : LOGGER
module Noosphere : LOGGER
module CmdPlane : LOGGER
module Gate : LOGGER
module Social : LOGGER
module Transport : LOGGER
module Gc : LOGGER
module Reputation : LOGGER
module Keeper : LOGGER
module Runtime : LOGGER
(** RFC-0058 Phase 8.1.5: runtime-domain namespace for catalog,
    routing, and partial-parse events. Separated from {!Keeper} so
    alerting/dashboard filters can target runtime subsystem without
    keeper-domain false positives. *)
module Memory : LOGGER
module Mention : LOGGER
module Misc : LOGGER
module Identity : LOGGER
module Institution : LOGGER
module Pages : LOGGER
module Thompson : LOGGER
module Config : LOGGER
module Task : LOGGER
module Http : LOGGER
module Langfuse : LOGGER
module Server : LOGGER
module Dispatch : LOGGER
module BoardPg : LOGGER
module MemoryPg : LOGGER
module MemoryJsonl : LOGGER
module AutoResponder : LOGGER
module Env : LOGGER
module Level2 : LOGGER
module TaskState : LOGGER
module Inline : LOGGER
module Protocol : LOGGER
module AlwaysOn : LOGGER
module KeeperExec : LOGGER
module LocalWorker : LOGGER
module Worker : LOGGER
module Sse : LOGGER
module Verifier : LOGGER
module Planner : LOGGER
module Compact : LOGGER
module Harness : LOGGER
module Discovery : LOGGER

(** {2 Logging-consistency migration modules}

    Added by [refactor/logging-consistency-harness]. The first group replaces
    former [Log.info ~ctx:"<name>"] call sites; each [name] preserves the exact
    component string operators see ([ts] [LEVEL] [<name>]). The second group
    replaces former raw-stderr / [Logs.*] sites that carried no context and are
    named after their domain. See [docs/LOGGING.md]. *)
module Otel : LOGGER
module Agent_health : LOGGER
module Relay : LOGGER
module Runtime_verify : LOGGER
module Checkpoint : LOGGER
module Jsonl_atomic : LOGGER
module Mcp_transport : LOGGER
module Startup : LOGGER
module Model_inference_metrics : LOGGER
module Oas_worker_exec : LOGGER
module Oas_event : LOGGER
module H2_gateway : LOGGER
module Voice : LOGGER
module Exec_tap : LOGGER
module Tool_validation : LOGGER
module Discord : LOGGER
module Slack : LOGGER
