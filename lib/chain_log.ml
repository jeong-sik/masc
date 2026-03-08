(** Structured logging for llm-mcp

    Provides leveled logging with optional JSON output for production.

    Usage:
    {[
      let () = Log.info "mcp_server" "Starting server on port %d" 8932
      let () = Log.warn "chain" "Node %s timed out" node_id
      let () = Log.error "gemini" ~ctx:[("model", model)] "Rate limit exceeded"
    ]}

    Environment variables:
    - LLM_MCP_LOG_LEVEL: debug|info|warn|error (default: info)
    - LLM_MCP_LOG_FORMAT: text|json (default: text)

    @since 0.3.0
*)

(** {1 Log Levels} *)

type level =
  | Debug
  | Info
  | Warn
  | Error
  | Critical

let level_to_int = function
  | Debug -> 0
  | Info -> 1
  | Warn -> 2
  | Error -> 3
  | Critical -> 4

let level_to_string = function
  | Debug -> "DEBUG"
  | Info -> "INFO"
  | Warn -> "WARN"
  | Error -> "ERROR"
  | Critical -> "CRITICAL"

let level_of_string = function
  | "debug" -> Debug
  | "info" -> Info
  | "warn" | "warning" -> Warn
  | "error" -> Error
  | "critical" | "fatal" -> Critical
  | _ -> Info

(** {1 Configuration} *)

type format = Text | Json

type config = {
  mutable min_level: level;
  mutable format: format;
  mutable show_timestamp: bool;
  mutable show_module: bool;
}

let config = {
  min_level = Info;
  format = Text;
  show_timestamp = true;
  show_module = true;
}

let init () =
  (* Read from environment *)
  (match Sys.getenv_opt "LLM_MCP_LOG_LEVEL" with
   | Some s -> config.min_level <- level_of_string (String.lowercase_ascii s)
   | None -> ());
  (match Sys.getenv_opt "LLM_MCP_LOG_FORMAT" with
   | Some "json" -> config.format <- Json
   | _ -> config.format <- Text)

let set_level level = config.min_level <- level
let set_format fmt = config.format <- fmt

(** {1 Timestamp} *)

let timestamp () =
  let open Unix in
  let tm = localtime (gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

(** {1 Output Functions} *)

let level_emoji = function
  | Debug -> "\027[36m[D]\027[0m"     (* Cyan *)
  | Info -> "\027[32m[I]\027[0m"      (* Green *)
  | Warn -> "\027[33m[W]\027[0m"      (* Yellow *)
  | Error -> "\027[31m[E]\027[0m"     (* Red *)
  | Critical -> "\027[35m[!]\027[0m"  (* Magenta *)

let output_text level module_name ctx msg =
  let ts = if config.show_timestamp then timestamp () ^ " " else "" in
  let mod_str = if config.show_module then Printf.sprintf "[%s] " module_name else "" in
  let ctx_str =
    match ctx with
    | [] -> ""
    | pairs ->
        let kv = List.map (fun (k, v) -> Printf.sprintf "%s=%s" k v) pairs in
        " {" ^ String.concat ", " kv ^ "}"
  in
  Printf.eprintf "%s%s %s%s%s\n%!" ts (level_emoji level) mod_str msg ctx_str

let output_json level module_name ctx msg =
  let ctx_json =
    match ctx with
    | [] -> ""
    | pairs ->
        let kv = List.map (fun (k, v) -> Printf.sprintf "\"%s\":\"%s\"" k (String.escaped v)) pairs in
        "," ^ String.concat "," kv
  in
  Printf.eprintf "{\"ts\":\"%s\",\"level\":\"%s\",\"module\":\"%s\",\"msg\":\"%s\"%s}\n%!"
    (timestamp ()) (level_to_string level) module_name (String.escaped msg) ctx_json

let log level module_name ?(ctx=[]) fmt =
  if level_to_int level >= level_to_int config.min_level then
    Printf.ksprintf (fun msg ->
      match config.format with
      | Text -> output_text level module_name ctx msg
      | Json -> output_json level module_name ctx msg
    ) fmt
  else
    Printf.ksprintf (fun _ -> ()) fmt

(** {1 Convenience Functions} *)

let debug module_name ?ctx fmt = log Debug module_name ?ctx fmt
let info module_name ?ctx fmt = log Info module_name ?ctx fmt
let warn module_name ?ctx fmt = log Warn module_name ?ctx fmt
let error module_name ?ctx fmt = log Error module_name ?ctx fmt
let critical module_name ?ctx fmt = log Critical module_name ?ctx fmt

(** {1 Scoped Logging} *)

(** Create a logger scoped to a module *)
module type SCOPED = sig
  val debug : ?ctx:(string * string) list -> ('a, unit, string, unit) format4 -> 'a
  val info : ?ctx:(string * string) list -> ('a, unit, string, unit) format4 -> 'a
  val warn : ?ctx:(string * string) list -> ('a, unit, string, unit) format4 -> 'a
  val error : ?ctx:(string * string) list -> ('a, unit, string, unit) format4 -> 'a
  val critical : ?ctx:(string * string) list -> ('a, unit, string, unit) format4 -> 'a
end

module Make (M : sig val name : string end) : SCOPED = struct
  let debug ?ctx fmt = debug M.name ?ctx fmt
  let info ?ctx fmt = info M.name ?ctx fmt
  let warn ?ctx fmt = warn M.name ?ctx fmt
  let error ?ctx fmt = error M.name ?ctx fmt
  let critical ?ctx fmt = critical M.name ?ctx fmt
end

(** {1 Initialization} *)

let () = init ()
