(** Lodge Trace — Prompt/Response capture and file I/O for tuning.

    Captures full prompt, response, timing, and action for each LLM call
    during heartbeat ticks. Traces are written to per-agent JSONL files.

    @since 2.14.0
    @since 4.1.0 — Extracted from lodge_heartbeat.ml
*)

(** Trace entry: captures full prompt, response, timing, and action *)
type trace_entry = {
  tick_id : string;         (* Unique tick identifier *)
  agent_name : string;
  phase : string;           (* "decide_action", "auto_respond", etc. *)
  prompt : string;          (* Full prompt sent to LLM *)
  response : string;        (* LLM response *)
  llm_used : string;        (* Which LLM was used, e.g. "glm(glm-4.7)" *)
  action : string;          (* Parsed action: "POST", "COMMENT:id", "SKIP" *)
  duration_ms : int;        (* Time taken in milliseconds *)
  timestamp : float;        (* Unix timestamp *)
}

(** Ensure directory exists *)
let ensure_trace_dir ~agent_name =
  let me_root =
    match Env_config.me_root_opt () with
    | Some root -> root
    | None -> Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp"
  in
  let trace_dir = Filename.concat me_root (Printf.sprintf ".masc/traces/%s" agent_name) in
  Fs_compat.mkdir_p trace_dir;
  trace_dir

(** Save a trace entry to JSONL file *)
let save (entry : trace_entry) =
  let trace_dir = ensure_trace_dir ~agent_name:entry.agent_name in
  let date_str =
    let tm = Unix.gmtime entry.timestamp in
    Printf.sprintf "%04d-%02d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
  in
  let trace_file = Filename.concat trace_dir (date_str ^ ".jsonl") in
  let json = `Assoc [
    ("tick_id", `String entry.tick_id);
    ("agent_name", `String entry.agent_name);
    ("phase", `String entry.phase);
    ("prompt", `String entry.prompt);
    ("response", `String entry.response);
    ("llm_used", `String entry.llm_used);
    ("action", `String entry.action);
    ("duration_ms", `Int entry.duration_ms);
    ("timestamp", `Float entry.timestamp);
  ] in
  Fs_compat.append_jsonl trace_file json;
  Printf.printf "   📝 [%s] Trace saved: %s (%dms, %s)\n%!" entry.agent_name trace_file entry.duration_ms entry.llm_used
