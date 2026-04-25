(** MASC Logging System - Structured logging with levels *)

(** Log levels *)
type level =
  | Debug
  | Info
  | Warn
  | Error

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

val log : level -> ?ctx:string -> ('a, unit, string, unit) format4 -> 'a
(** Log a message at the given level with optional context. *)

val emit : level -> ?module_name:string -> ?details:Yojson.Safe.t -> string -> unit
(** Log a preformatted structured message with optional JSON details. *)

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

  module For_testing : sig
    val date_string : unit -> string
    (** UTC date string ([YYYY-MM-DD]) used for the current
        [system_log_<date>.jsonl] filename.  Exposed so tests
        can pin the boundary against the entry-timestamp TZ. *)
  end
end

val client_tool_host_error :
  ?module_name:string -> ?details:Yojson.Safe.t -> string -> unit
(** Mirror a client/tool-host failure into the dashboard log ring with its own source. *)

(** Functor for creating module-specific loggers.
    [M.name] controls the env-var key MASC_LOG_{NAME}_LEVEL
    and the context prefix in log output. *)
module Make (_ : sig val name : string end) : sig
  val emit : level -> ?details:Yojson.Safe.t -> string -> unit
  val debug : ('a, unit, string, unit) format4 -> 'a
  val info : ('a, unit, string, unit) format4 -> 'a
  val warn : ('a, unit, string, unit) format4 -> 'a
  val error : ('a, unit, string, unit) format4 -> 'a
end

(** {1 Pre-defined module loggers} *)

module Coord : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Mcp : sig val emit : level -> ?details:Yojson.Safe.t -> string -> unit val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Auth : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Retry : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Backend : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Session : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Cancel : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Sub : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Spawn : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Pulse : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module ModelClient : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Orchestrator : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module BoardLog : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Metrics : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Dashboard : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Trpg : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Feed : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Telemetry : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Noosphere : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module CmdPlane : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Governance : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Social : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Transport : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Gc : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Reputation : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Keeper : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Memory : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Mention : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Misc : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Autoresearch : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Identity : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Institution : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Pages : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Thompson : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Config : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Task : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Http : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Langfuse : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Server : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Dispatch : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module BoardPg : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module MemoryPg : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module MemoryJsonl : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module AutoResponder : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Env : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Level2 : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module RoomTask : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Inline : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Protocol : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module AlwaysOn : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module KeeperExec : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module LocalWorker : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Worker : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Sse : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Verifier : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Planner : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Compact : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Harness : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
module Discovery : sig val debug : ('a, unit, string, unit) format4 -> 'a val info : ('a, unit, string, unit) format4 -> 'a val warn : ('a, unit, string, unit) format4 -> 'a val error : ('a, unit, string, unit) format4 -> 'a end
