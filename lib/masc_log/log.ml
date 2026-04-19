(* MASC Logging System - Structured logging with levels *)

(** Log levels *)
type level =
  | Debug
  | Info
  | Warn
  | Error

type source =
  | Structured
  | Legacy_stderr
  | Legacy_traceln
  | Client_tool_host

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

(** Parse level from string without a fallback.  Returns [None] when the
    input does not match any known level — callers that originate from
    user input (env vars, config files) should treat [None] as an error
    rather than silently collapsing it to a default. *)
let level_of_string_opt s =
  match String.lowercase_ascii (String.trim s) with
  | "debug" -> Some Debug
  | "info" -> Some Info
  | "warn" | "warning" -> Some Warn
  | "error" -> Some Error
  | _ -> None

(** Parse level from string, defaulting to [Info] on unrecognised input.
    Kept for backward compatibility with existing callers.  When the
    input comes from a user (env var, config), prefer
    [level_of_string_opt] and warn on [None] so typos surface. *)
let level_of_string s =
  match level_of_string_opt s with
  | Some lvl -> lvl
  | None -> Info

let source_to_string = function
  | Structured -> "structured"
  | Legacy_stderr -> "legacy_stderr"
  | Legacy_traceln -> "legacy_traceln"
  | Client_tool_host -> "client_tool_host"

let has_prefix ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.sub value 0 prefix_len = prefix

let infer_legacy_level message =
  let trimmed = String.trim message in
  let upper = String.uppercase_ascii trimmed in
  if has_prefix ~prefix:"[FATAL]" upper || has_prefix ~prefix:"FATAL:" upper then
    (Error, "FATAL")
  else if has_prefix ~prefix:"[ERROR]" upper || has_prefix ~prefix:"ERROR:" upper then
    (Error, "ERROR")
  else if has_prefix ~prefix:"[WARN]" upper || has_prefix ~prefix:"[WARNING]" upper
          || has_prefix ~prefix:"WARN:" upper || has_prefix ~prefix:"WARNING:" upper then
    (Warn, "WARN")
  else if has_prefix ~prefix:"[INFO]" upper || has_prefix ~prefix:"INFO:" upper then
    (Info, "INFO")
  else if has_prefix ~prefix:"[DEBUG]" upper || has_prefix ~prefix:"DEBUG:" upper then
    (Debug, "DEBUG")
  else
    (Info, "INFO")

(** Check if level should be logged *)
let should_log level =
  level_to_int level >= Atomic.get current_level

(** Set log level *)
let set_level level =
  Atomic.set current_level (level_to_int level)

(** Set log level from string (e.g., from env var).  Emits a stderr
    warning when the input is not a recognised level, so operator
    typos (e.g. [MASC_LOG_LEVEL=debg]) surface instead of silently
    collapsing to [Info]. *)
let set_level_from_string s =
  let lvl =
    match level_of_string_opt s with
    | Some lvl -> lvl
    | None ->
      Printf.eprintf
        "[masc_log] WARN: unrecognised log level %S, defaulting to Info\n%!"
        s;
      Info
  in
  Atomic.set current_level (level_to_int lvl)

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

(** ISO 8601 timestamp for JSON *)
let timestamp_iso () =
  let t = Time_compat.now () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

(** In-memory ring buffer for dashboard log viewer.
    Fixed capacity, oldest entries evicted on overflow.
    Lock-free: single-writer (log functions), multi-reader (API).
    Optional file sink persists entries across restarts. *)
module Ring = struct
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

  let capacity = 5000
  let buf : entry array = Array.make capacity
    {
      seq = 0;
      ts = "";
      level = "";
      raw_level = "";
      normalized_level = "";
      source = "";
      legacy_classified = false;
      module_name = "";
      message = "";
      details = `Null;
    }
  let total = Atomic.make 0 (* total entries ever written *)

  (* File sink state *)
  let file_channel : out_channel option ref = ref None
  let file_current_date : string ref = ref ""
  let file_base_dir : string ref = ref ""

  let date_string () =
    let t = Time_compat.now () in
    let tm = Unix.localtime t in
    Printf.sprintf "%04d-%02d-%02d"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday

  let log_file_path dir date =
    Filename.concat dir (Printf.sprintf "system_log_%s.jsonl" date)

  let ensure_dir dir =
    if not (Sys.file_exists dir) then
      (try Sys.mkdir dir 0o755 with Sys_error _ -> ())

  let open_sink dir =
    ensure_dir dir;
    let date = date_string () in
    let path = log_file_path dir date in
    let oc = open_out_gen [Open_append; Open_creat; Open_wronly] 0o644 path in
    file_channel := Some oc;
    file_current_date := date;
    file_base_dir := dir

  let entry_to_json e =
    `Assoc [
      ("seq", `Int e.seq);
      ("ts", `String e.ts);
      ("level", `String e.level);
      ("raw_level", `String e.raw_level);
      ("normalized_level", `String e.normalized_level);
      ("source", `String e.source);
      ("legacy_classified", `Bool e.legacy_classified);
      ("module", `String e.module_name);
      ("message", `String e.message);
      ("details", e.details);
    ]

  let rotate_if_needed () =
    let today = date_string () in
    if today <> !file_current_date && !file_base_dir <> "" then begin
      (match !file_channel with Some oc -> (try close_out oc with Sys_error _ -> ()) | None -> ());
      open_sink !file_base_dir
    end

  let write_to_sink entry_json =
    rotate_if_needed ();
    match !file_channel with
    | Some oc ->
        output_string oc (Yojson.Safe.to_string entry_json);
        output_char oc '\n';
        (* flush on warn/error for timely persistence *)
        (try flush oc with Sys_error _ -> ())
    | None -> ()

  let entry_of_json json =
    match json with
    | `Assoc _ ->
        let open Yojson.Safe.Util in
        (match
           member "seq" json, member "ts" json, member "level" json,
           member "raw_level" json, member "normalized_level" json,
           member "source" json, member "legacy_classified" json,
           member "module" json, member "message" json
         with
         | `Int seq, `String ts, `String level,
           `String raw_level, `String normalized_level,
           `String source, `Bool legacy_classified,
           `String module_name, `String message ->
             Some {
               seq; ts; level; raw_level; normalized_level;
               source; legacy_classified; module_name; message;
               details = member "details" json;
             }
         | _ -> None)
    | _ -> None

  let load_from_file dir =
    ensure_dir dir;
    let today = date_string () in
    (* Load today's and yesterday's logs *)
    let yesterday =
      let t = Time_compat.now () -. 86400.0 in
      let tm = Unix.localtime t in
      Printf.sprintf "%04d-%02d-%02d"
        (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    in
    let load_file path =
      if Sys.file_exists path then begin
        let ic = open_in path in
        let entries = ref [] in
        Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
          (try while true do
             let line = input_line ic in
             if String.length line > 0 then
               (match entry_of_json (Yojson.Safe.from_string line) with
                | Some e -> entries := e :: !entries
                | None -> ()
                | exception Yojson.Json_error _ -> ())
           done with End_of_file -> ());
          List.rev !entries
        )
      end else []
    in
    let yesterday_entries = load_file (log_file_path dir yesterday) in
    let today_entries = load_file (log_file_path dir today) in
    let all = yesterday_entries @ today_entries in
    (* Take only last [capacity] entries *)
    let len = List.length all in
    let to_load = if len > capacity then
      let skip = len - capacity in
      let rec drop n = function [] -> [] | _ :: tl when n > 0 -> drop (n-1) tl | l -> l in
      drop skip all
    else all in
    List.iter (fun e ->
      let seq = Atomic.fetch_and_add total 1 in
      let idx = seq mod capacity in
      buf.(idx) <- { e with seq }
    ) to_load

  let init_file_sink dir =
    load_from_file dir;
    let loaded = Atomic.get total in
    open_sink dir;
    if loaded > 0 then
      Printf.eprintf "[%s] [INFO] [Log] Restored %d log entries from disk\n%!" (timestamp ()) loaded

  let cleanup_old_files ?(keep_days = 7) dir =
    if Sys.file_exists dir then begin
      let files = try Sys.readdir dir with Sys_error _ -> [||] in
      let cutoff =
        let t = Time_compat.now () -. (float_of_int keep_days *. 86400.0) in
        let tm = Unix.localtime t in
        Printf.sprintf "%04d-%02d-%02d"
          (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      in
      Array.iter (fun fname ->
        if has_prefix ~prefix:"system_log_" fname
           && Filename.check_suffix fname ".jsonl" then begin
          (* Extract date from system_log_YYYY-MM-DD.jsonl *)
          let date_part = String.sub fname 11 10 in
          if date_part < cutoff then
            (try Sys.remove (Filename.concat dir fname) with Sys_error _ -> ())
        end
      ) files
    end

  let push
      ?raw_level
      ?(source = Structured)
      ?(legacy_classified = false)
      ?(details = `Null)
      ~normalized_level
      ~module_name
      ~message
      () =
    let seq = Atomic.fetch_and_add total 1 in
    let idx = seq mod capacity in
    let raw_level = Option.value ~default:normalized_level raw_level in
    let source = source_to_string source in
    let entry = {
        seq;
        ts = timestamp_iso ();
        level = normalized_level;
        raw_level;
        normalized_level;
        source;
        legacy_classified;
        module_name;
        message;
        details;
      } in
    buf.(idx) <- entry;
    if !file_channel <> None then
      write_to_sink (entry_to_json entry)

  let recent ?(limit = 200) ?(min_level = 0) ?(module_filter = "")
      ?since_seq
      ?(order = `Newest_first) () : entry list =
    let t = Atomic.get total in
    if t = 0 then []
    else begin
      let start = max 0 (t - capacity) in
      let start =
        match since_seq with
        | Some seq -> max start (seq + 1)
        | None -> start
      in
      let entries = ref [] in
      let count = ref 0 in
      let i = ref (t - 1) in
      while !i >= start && !count < limit do
        let e = buf.(!i mod capacity) in
        let level_ok =
          (level_to_int (level_of_string e.normalized_level)) >= min_level
        in
        let module_ok = module_filter = "" ||
          String.lowercase_ascii e.module_name =
          String.lowercase_ascii module_filter in
        if level_ok && module_ok then begin
          entries := e :: !entries;
          incr count
        end;
        decr i
      done;
      (* Prepend builds oldest-first; reverse for newest-first *)
      match order with
      | `Oldest_first -> !entries
      | `Newest_first -> List.rev !entries
    end

  let to_json entries =
    `Assoc [
      ("total", `Int (Atomic.get total));
      ("entries", `List (List.map entry_to_json entries));
    ]
end

(** Log a message at given level with optional context *)
let log level ?(ctx : string option) fmt =
  Printf.ksprintf (fun msg ->
    if should_log level then begin
      let level_str = level_to_string level in
      let module_name = match ctx with Some c -> c | None -> "" in
      let prefix = match ctx with
        | Some c -> Printf.sprintf "[%s] [%s] [%s]" (timestamp ()) level_str c
        | None -> Printf.sprintf "[%s] [%s]" (timestamp ()) level_str
      in
      Printf.eprintf "%s %s\n%!" prefix msg;
      Ring.push ~raw_level:level_str ~normalized_level:level_str ~module_name
        ~message:msg ()
    end
  ) fmt

let emit level ?(module_name = "") ?(details = `Null) message =
  if should_log level then begin
    let level_str = level_to_string level in
    let prefix =
      if module_name = "" then
        Printf.sprintf "[%s] [%s]" (timestamp ()) level_str
      else
        Printf.sprintf "[%s] [%s] [%s]" (timestamp ()) level_str module_name
    in
    Printf.eprintf "%s %s\n%!" prefix message;
    Ring.push ~raw_level:level_str ~normalized_level:level_str ~module_name
      ~message ~details ()
  end

(** Convenience functions *)
let debug ?ctx fmt = log Debug ?ctx fmt
let info ?ctx fmt = log Info ?ctx fmt
let warn ?ctx fmt = log Warn ?ctx fmt
let error ?ctx fmt = log Error ?ctx fmt

let emit_legacy_raw ?level ?(module_name = "") ~source message =
  let normalized_level, raw_level, legacy_classified =
    match level with
    | Some level ->
        let level_str = level_to_string level in
        (level_str, level_str, false)
    | None ->
        let inferred, raw_level = infer_legacy_level message in
        (level_to_string inferred, raw_level, true)
  in
  Printf.eprintf "%s\n%!" message;
  Ring.push ~raw_level ~normalized_level ~source ~legacy_classified ~module_name
    ~message ()

let legacy_stderr ?level ?module_name message =
  emit_legacy_raw ?level ?module_name ~source:Legacy_stderr message

let legacy_traceln ?level ?module_name message =
  emit_legacy_raw ?level ?module_name ~source:Legacy_traceln message

let client_tool_host_error ?(module_name = "ToolHost") ?(details = `Null) message =
  Printf.eprintf "%s\n%!" message;
  Ring.push ~raw_level:"ERROR" ~normalized_level:"ERROR" ~source:Client_tool_host
    ~module_name ~message ~details ()

(** Module-specific loggers.
    Each module checks MASC_LOG_{NAME}_LEVEL env var for per-module override,
    falling back to the global level. *)
module Make (M : sig val name : string end) = struct
  let module_level : int option =
    let env_key = Printf.sprintf "MASC_LOG_%s_LEVEL"
      (String.uppercase_ascii M.name) in
    match Sys.getenv_opt env_key with
    | None -> None
    | Some s ->
      match level_of_string_opt s with
      | Some lvl -> Some (level_to_int lvl)
      | None ->
        Printf.eprintf
          "[masc_log] WARN: %s=%S is not a valid level; ignoring override\n%!"
          env_key s;
        None

  let should_log_module level =
    let threshold = match module_level with
      | Some l -> l
      | None -> Atomic.get current_level
    in
    level_to_int level >= threshold

  let log_module level fmt =
    Printf.ksprintf (fun msg ->
      if should_log_module level then begin
        let level_str = level_to_string level in
        let prefix = Printf.sprintf "[%s] [%s] [%s]"
          (timestamp ()) level_str M.name in
        Printf.eprintf "%s %s\n%!" prefix msg;
        Ring.push ~raw_level:level_str ~normalized_level:level_str
          ~module_name:M.name ~message:msg ()
      end
    ) fmt

  let debug fmt = log_module Debug fmt
  let info fmt = log_module Info fmt
  let warn fmt = log_module Warn fmt
  let error fmt = log_module Error fmt
end

(** Pre-defined module loggers *)
module Coord = Make(struct let name = "Coord" end)
module Mcp = Make(struct let name = "MCP" end)
module Auth = Make(struct let name = "Auth" end)
module Retry = Make(struct let name = "Retry" end)
module Backend = Make(struct let name = "Backend" end)
module Session = Make(struct let name = "Session" end)
module Cancel = Make(struct let name = "Cancellation" end)
module Sub = Make(struct let name = "Subscriptions" end)
module Spawn = Make(struct let name = "Spawn" end)
module Pulse = Make(struct let name = "Pulse" end)
module ModelClient = Make(struct let name = "ModelClient" end)
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
module Memory = Make(struct let name = "Memory" end)
module Mention = Make(struct let name = "Mention" end)
module Misc = Make(struct let name = "Misc" end)
module Autoresearch = Make(struct let name = "Autoresearch" end)
module Identity = Make(struct let name = "Identity" end)
module Institution = Make(struct let name = "Institution" end)
module Pages = Make(struct let name = "Pages" end)
module Thompson = Make(struct let name = "Thompson" end)
module Config = Make(struct let name = "Config" end)
module Task = Make(struct let name = "Task" end)
module Http = Make(struct let name = "Http" end)
module Langfuse = Make(struct let name = "Langfuse" end)
module Server = Make(struct let name = "Server" end)
module Dispatch = Make(struct let name = "Dispatch" end)
module BoardPg = Make(struct let name = "BoardPg" end)
module MemoryPg = Make(struct let name = "MemoryPg" end)
module MemoryJsonl = Make(struct let name = "MemoryJsonl" end)
module AutoResponder = Make(struct let name = "AutoResponder" end)
module Env = Make(struct let name = "Env" end)
module Level2 = Make(struct let name = "Level2" end)
module RoomTask = Make(struct let name = "RoomTask" end)
module Inline = Make(struct let name = "Inline" end)
module Protocol = Make(struct let name = "Protocol" end)
module AlwaysOn = Make(struct let name = "AlwaysOn" end)
module KeeperExec = Make(struct let name = "KeeperExec" end)
module LocalWorker = Make(struct let name = "LocalWorker" end)
module Worker = Make(struct let name = "Worker" end)
module Sse = Make(struct let name = "SSE" end)
module Verifier = Make(struct let name = "Verifier" end)
module Planner = Make(struct let name = "Planner" end)
module Compact = Make(struct let name = "Compact" end)
module Harness = Make(struct let name = "Harness" end)
module Discovery = Make(struct let name = "Discovery" end)
