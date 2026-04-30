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

val level_to_string : level -> string
(** Convert level to string representation. *)

val level_to_int : level -> int
(** Convert level to integer for comparison. *)

val level_of_string : string -> level
(** Parse level from string. Defaults to [Info] for unrecognised input.
    Kept for backward compatibility — prefer [level_of_string_opt] when
    the input is user-supplied so typos surface instead of collapsing. *)

val level_of_string_opt : string -> level option
(** Parse level from string without a fallback.  Returns [None] for
    unrecognised input.  Callers that originate from user input (env
    vars, config files) should use this and warn on [None] rather than
    relying on the silent [Info] default of [level_of_string]. *)

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

val log : level -> ?ctx:string -> ('a, unit, string, unit) format4 -> 'a
(** Log a message at the given level with optional context. *)

val emit : level -> ?module_name:string -> ?details:Yojson.Safe.t -> string -> unit
(** Log a preformatted structured message with optional JSON details. *)

val emit_routine : ?module_name:string -> ?details:Yojson.Safe.t -> string -> unit
(** Log repeatable housekeeping/telemetry through the central routine policy.
    The effective level is controlled by [MASC_LOG_ROUTINE_LEVEL] and defaults
    to [Debug]. Set it to [off] to suppress routine events entirely. *)

val debug : ?ctx:string -> ('a, unit, string, unit) format4 -> 'a
val info : ?ctx:string -> ('a, unit, string, unit) format4 -> 'a
val warn : ?ctx:string -> ('a, unit, string, unit) format4 -> 'a
val error : ?ctx:string -> ('a, unit, string, unit) format4 -> 'a

val legacy_stderr : ?level:level -> ?module_name:string -> string -> unit
(** Mirror a legacy stderr line into the dashboard log ring. *)

val legacy_traceln : ?level:level -> ?module_name:string -> string -> unit
(** Mirror a legacy [Eio.traceln]-style line into the dashboard log ring. *)

(** In-memory ring buffer exposed for dashboard log viewer routes. *)
module Ring : sig
  type entry = {
    seq : int;
    ts : string;
    level : string;
    raw_level : string;
    normalized_level : string;
    source : string;
    legacy_classified : bool;
    module_name : string;
    keeper_name : string option;
    turn_id : int option;
    message : string;
    details : Yojson.Safe.t;
  }

  val recent :
    ?limit:int ->
    ?min_level:int ->
    ?module_filter:string ->
    ?since_seq:int ->
    ?order:[< `Newest_first | `Oldest_first > `Newest_first ] ->
    unit ->
    entry list

  val entry_to_json : entry -> Yojson.Safe.t
  val to_json : entry list -> Yojson.Safe.t

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
  val emit : level -> ?details:Yojson.Safe.t -> ?keeper_name:string -> ?turn_id:int -> string -> unit
  val routine :
    ?details:Yojson.Safe.t ->
    ?keeper_name:string ->
    ?turn_id:int ->
    ('a, unit, string, unit) format4 ->
    'a
  val debug : ?keeper_name:string -> ?turn_id:int -> ('a, unit, string, unit) format4 -> 'a
  val info : ?keeper_name:string -> ?turn_id:int -> ('a, unit, string, unit) format4 -> 'a
  val warn : ?keeper_name:string -> ?turn_id:int -> ('a, unit, string, unit) format4 -> 'a
  val error : ?keeper_name:string -> ?turn_id:int -> ('a, unit, string, unit) format4 -> 'a
end

module Make (_ : sig val name : string end) : LOGGER

(** {1 Pre-defined module loggers} *)

module Coord : LOGGER
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
module Governance : LOGGER
module Social : LOGGER
module Transport : LOGGER
module Gc : LOGGER
module Reputation : LOGGER
module Keeper : LOGGER
module Memory : LOGGER
module Mention : LOGGER
module Misc : LOGGER
module Autoresearch : LOGGER
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
module RoomTask : LOGGER
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
