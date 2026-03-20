(** MASC Logging System - Structured logging with levels *)

(** Log levels *)
type level =
  | Debug
  | Info
  | Warn
  | Error

(** Current log level (Atomic for thread safety in OCaml 5) *)
let current_level = Atomic.make 1 (* Info = 1 *)

(** Level to string *)
let level_to_string = function
  | Debug -> "DEBUG"
  | Info -> "INFO"
  | Warn -> "WARN"
  | Error -> "ERROR"

(** Level to int for comparison *)
let level_to_int = function
  | Debug -> 0
  | Info -> 1
  | Warn -> 2
  | Error -> 3

(** Parse level from string *)
let level_of_string s =
  match String.lowercase_ascii s with
  | "debug" -> Debug
  | "info" -> Info
  | "warn" | "warning" -> Warn
  | "error" -> Error
  | _ -> Info  (* Default to Info *)

(** Check if level should be logged *)
let should_log level =
  level_to_int level >= Atomic.get current_level

(** Set log level *)
let set_level level =
  Atomic.set current_level (level_to_int level)

(** Set log level from string (e.g., from env var) *)
let set_level_from_string s =
  Atomic.set current_level (level_to_int (level_of_string s))

(** Initialize from MASC_LOG_LEVEL env var *)
let init_from_env () =
  match Sys.getenv_opt "MASC_LOG_LEVEL" with
  | Some s -> set_level_from_string s
  | None -> ()

(** Get current timestamp *)
let timestamp () =
  let t = Time_compat.now () in
  let tm = Unix.localtime t in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec

(** Log a message at given level with optional context *)
let log level ?(ctx : string option) fmt =
  Printf.ksprintf (fun msg ->
    if should_log level then begin
      let prefix = match ctx with
        | Some c -> Printf.sprintf "[%s] [%s] [%s]" (timestamp ()) (level_to_string level) c
        | None -> Printf.sprintf "[%s] [%s]" (timestamp ()) (level_to_string level)
      in
      Printf.eprintf "%s %s\n%!" prefix msg
    end
  ) fmt

(** Convenience functions *)
let debug ?ctx fmt = log Debug ?ctx fmt
let info ?ctx fmt = log Info ?ctx fmt
let warn ?ctx fmt = log Warn ?ctx fmt
let error ?ctx fmt = log Error ?ctx fmt

(** Module-specific loggers.
    Each module checks MASC_LOG_{NAME}_LEVEL env var for per-module override,
    falling back to the global level. *)
module Make (M : sig val name : string end) = struct
  let module_level : int option =
    let env_key = Printf.sprintf "MASC_LOG_%s_LEVEL"
      (String.uppercase_ascii M.name) in
    match Sys.getenv_opt env_key with
    | Some s -> Some (level_to_int (level_of_string s))
    | None -> None

  let should_log_module level =
    let threshold = match module_level with
      | Some l -> l
      | None -> Atomic.get current_level
    in
    level_to_int level >= threshold

  let log_module level fmt =
    Printf.ksprintf (fun msg ->
      if should_log_module level then begin
        let prefix = Printf.sprintf "[%s] [%s] [%s]"
          (timestamp ()) (level_to_string level) M.name in
        Printf.eprintf "%s %s\n%!" prefix msg
      end
    ) fmt

  let debug fmt = log_module Debug fmt
  let info fmt = log_module Info fmt
  let warn fmt = log_module Warn fmt
  let error fmt = log_module Error fmt
end

(** Pre-defined module loggers *)
module Room = Make(struct let name = "Room" end)
module Mcp = Make(struct let name = "MCP" end)
module Auth = Make(struct let name = "Auth" end)
module Retry = Make(struct let name = "Retry" end)
module Backend = Make(struct let name = "Backend" end)
module Session = Make(struct let name = "Session" end)
module Cancel = Make(struct let name = "Cancellation" end)
module Sub = Make(struct let name = "Subscriptions" end)
module Mitosis_log = Make(struct let name = "Mitosis" end)
module Spawn = Make(struct let name = "Spawn" end)
module Pulse = Make(struct let name = "Pulse" end)
module Guardian = Make(struct let name = "Guardian" end)
module Sentinel = Make(struct let name = "Sentinel" end)
module LlmClient = Make(struct let name = "LlmClient" end)
module Orchestrator = Make(struct let name = "Orchestrator" end)
module BoardLog = Make(struct let name = "Board" end)
module Metrics = Make(struct let name = "Metrics" end)
module Dashboard = Make(struct let name = "Dashboard" end)
module Trpg = Make(struct let name = "Trpg" end)
module Feed = Make(struct let name = "Feed" end)
module Telemetry = Make(struct let name = "Telemetry" end)
module Noosphere = Make(struct let name = "Noosphere" end)
module CmdPlane = Make(struct let name = "CmdPlane" end)
module Governance = Make(struct let name = "Governance" end)
module Social = Make(struct let name = "Social" end)
module Transport = Make(struct let name = "Transport" end)
module Gc = Make(struct let name = "GC" end)
module Reputation = Make(struct let name = "Reputation" end)
module Keeper = Make(struct let name = "Keeper" end)
module Norm = Make(struct let name = "Norm" end)
module Memory = Make(struct let name = "Memory" end)
module Mention = Make(struct let name = "Mention" end)
module Misc = Make(struct let name = "Misc" end)
module Autoresearch = Make(struct let name = "Autoresearch" end)
module Identity = Make(struct let name = "Identity" end)
module Institution = Make(struct let name = "Institution" end)
module Pages = Make(struct let name = "Pages" end)
module Thompson = Make(struct let name = "Thompson" end)
module Chain = Make(struct let name = "Chain" end)
module Config = Make(struct let name = "Config" end)
module Task = Make(struct let name = "Task" end)
module Swarm = Make(struct let name = "Swarm" end)
module Http = Make(struct let name = "Http" end)
module Langfuse = Make(struct let name = "Langfuse" end)
module Safe = Make(struct let name = "Safe" end)
module Server = Make(struct let name = "Server" end)
module Dispatch = Make(struct let name = "Dispatch" end)
module BoardPg = Make(struct let name = "BoardPg" end)
module AutoResponder = Make(struct let name = "AutoResponder" end)
module Env = Make(struct let name = "Env" end)
module Level2 = Make(struct let name = "Level2" end)
module RoomTask = Make(struct let name = "RoomTask" end)
module Inline = Make(struct let name = "Inline" end)
module Protocol = Make(struct let name = "Protocol" end)
module Perpetual = Make(struct let name = "Perpetual" end)
module KeeperExec = Make(struct let name = "KeeperExec" end)
module Evolution = Make(struct let name = "Evolution" end)
module Llm = Make(struct let name = "LLM" end)
module BoardListener = Make(struct let name = "BoardListener" end)
module Ecosystem = Make(struct let name = "Ecosystem" end)
module Council = Make(struct let name = "Council" end)
module LocalWorker = Make(struct let name = "LocalWorker" end)
module Sse = Make(struct let name = "SSE" end)
