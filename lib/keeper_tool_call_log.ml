(** Keeper_tool_call_log — Full I/O logging for keeper tool calls.

    Persists complete tool call records (input arguments + output text)
    to [.masc/tool_calls/YYYY-MM/DD.jsonl] via {!Dated_jsonl}.

    Unlike {!Tool_usage_log} (metadata only) and {!Tool_metrics_persist}
    (aggregated counts), this module stores the actual I/O for debugging
    and dashboard inspection.

    Output is truncated to {!max_output_len} bytes to prevent disk
    explosion from large tool results (e.g. full file reads).

    @since 2.249.0 — Keeper observability *)

let max_output_len = 4000

(** Pre-truncation info, keyed by keeper name.
    Set by the tool handler wrapper (keeper_tools_oas), consumed by the
    OAS on_tool_result hook (keeper_hooks_oas).  Per-keeper isolation
    prevents cross-keeper corruption when multiple keepers call tools
    concurrently. Within a single keeper's Agent.run, tool calls are
    sequential so set→consume ordering is guaranteed. *)
let pending_truncation : (string, int * int option) Hashtbl.t = Hashtbl.create 8

type turn_context = {
  lane: string option;
  tool_choice: string option;
  thinking_enabled: bool option;
  thinking_budget: int option;
  prompt_fingerprint: string option;
  trace_id: string option;
  session_id: string option;
  turn: int option;
  keeper_turn_id: int option;
  task_id: string option;
  goal_ids: string list option;
  execution_scope: string option;
  sandbox_profile: string option;
  network_mode: string option;
  shared_memory_scope: string option;
  approval_mode: string option;
}

let empty_turn_context = {
  lane = None;
  tool_choice = None;
  thinking_enabled = None;
  thinking_budget = None;
  prompt_fingerprint = None;
  trace_id = None;
  session_id = None;
  turn = None;
  keeper_turn_id = None;
  task_id = None;
  goal_ids = None;
  execution_scope = None;
  sandbox_profile = None;
  network_mode = None;
  shared_memory_scope = None;
  approval_mode = None;
}

let pending_turn_context : (string, turn_context) Hashtbl.t = Hashtbl.create 8

let set_truncation_info ~keeper_name ~original_bytes ?truncated_to () =
  Hashtbl.replace pending_truncation keeper_name (original_bytes, truncated_to)

let consume_truncation_info ~keeper_name () =
  match Hashtbl.find_opt pending_truncation keeper_name with
  | Some info -> Hashtbl.remove pending_truncation keeper_name; info
  | None -> (0, None)

let set_turn_context ~keeper_name ?lane ?tool_choice ?thinking_enabled
    ?thinking_budget ?prompt_fingerprint ?trace_id ?session_id ?turn
    ?keeper_turn_id ?task_id ?goal_ids ?execution_scope ?sandbox_profile
    ?network_mode ?shared_memory_scope ?approval_mode () =
  Hashtbl.replace pending_turn_context keeper_name
    {
      lane;
      tool_choice;
      thinking_enabled;
      thinking_budget;
      prompt_fingerprint;
      trace_id;
      session_id;
      turn;
      keeper_turn_id;
      task_id;
      goal_ids;
      execution_scope;
      sandbox_profile;
      network_mode;
      shared_memory_scope;
      approval_mode;
    }

let get_turn_context ~keeper_name () =
  let ctx =
    match Hashtbl.find_opt pending_turn_context keeper_name with
    | Some ctx -> ctx
    | None -> empty_turn_context
  in
  ( ctx.lane
  , ctx.tool_choice
  , ctx.thinking_enabled
  , ctx.thinking_budget
  , ctx.prompt_fingerprint
  , ctx.trace_id
  , ctx.session_id
  , ctx.turn
  , ctx.keeper_turn_id
  , ctx.task_id
  , ctx.goal_ids
  , ctx.execution_scope
  , ctx.sandbox_profile
  , ctx.network_mode
  , ctx.shared_memory_scope
  , ctx.approval_mode )

let store_ref : Dated_jsonl.t option ref = ref None

let init ?cluster_name ~base_path () =
  let cluster_name =
    Option.value ~default:(Env_config_core.cluster_name ()) cluster_name
  in
  let dir =
    Filename.concat
      (Coord_utils.masc_root_dir_from ~base_path ~cluster_name)
      "tool_calls"
  in
  (try
     let store = Dated_jsonl.create ~base_dir:dir () in
     store_ref := Some store
   with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
     Log.Misc.warn "keeper_tool_call_log: init failed: %s"
       (Printexc.to_string exn))

let reset_for_testing () =
  store_ref := None;
  Hashtbl.reset pending_truncation;
  Hashtbl.reset pending_turn_context

(** [blob_aware_output_json safe_output] wraps a tool-output string for
    persistence as the [output] field. When [safe_output] is the OCaml
    [%S]-quoted [masc:blob ...] sentinel produced by
    [Tool_output.encode_for_oas], the wire format escapes the inner
    preview JSON twice (OCaml string-literal + JSON string), which makes
    the telemetry record illegible and inflates disk usage by 30-40%.

    We decode the sentinel and emit a structured object instead:
      {"_blob": {"sha256":"...", "bytes":N, "mime":"...", "preview":"..."}}

    Non-sentinel outputs keep the historical [String _] shape so that
    older readers (dashboard, jq scripts) keep working. The dashboard
    consumers are updated in the same change to accept either shape. *)
let blob_aware_output_json (output : string) : Yojson.Safe.t =
  match Tool_output.decode_from_oas output with
  | Tool_output.Stored { sha256; bytes; preview; mime } ->
      `Assoc
        [ ("_blob",
           `Assoc
             [ ("sha256", `String sha256)
             ; ("bytes", `Int bytes)
             ; ("mime", `String mime)
             ; ("preview", `String preview)
             ])
        ]
  | Tool_output.Inline _ -> `String output

let input_to_json (input : Yojson.Safe.t) : Yojson.Safe.t =
  (* Per-leaf sentinel-aware truncation. Previously
     [String.sub (Yojson.Safe.to_string input) 0 (max - suffix)] chopped
     through a [masc:blob ...] marker embedded in a nested JSON string
     value and stranded sha256/bytes/mime halfway, breaking the keeper
     artifact hydrator on replay. *)
  let input =
    Observability_redact.preview_json_strings ~max_len:max_output_len input
  in
  let s = Yojson.Safe.to_string input in
  if String.length s > max_output_len then
    `String (Observability_redact.redact_preview ~max_len:max_output_len s)
  else input

let log_call ~keeper_name ~tool_name ~(input : Yojson.Safe.t)
    ~(output_text : string) ~(success : bool) ~(duration_ms : float)
    ?(model : string = "") ?lane ?tool_choice ?thinking_enabled
    ?thinking_budget ?prompt_fingerprint ?trace_id ?session_id ?turn
    ?keeper_turn_id ?task_id ?goal_ids ?execution_scope ?sandbox_profile
    ?network_mode ?shared_memory_scope ?approval_mode ?result_bytes
    ?truncated_to () =
  if Observability_redact.is_denied_tool ~tool_name then ()
  else
    match !store_ref with
    | None -> ()
    | Some store ->
      let ( ctx_lane
          , ctx_tool_choice
          , ctx_thinking_enabled
          , ctx_thinking_budget
          , ctx_prompt_fingerprint
          , ctx_trace_id
          , ctx_session_id
          , ctx_turn
          , ctx_keeper_turn_id
          , ctx_task_id
          , ctx_goal_ids
          , ctx_execution_scope
          , ctx_sandbox_profile
          , ctx_network_mode
          , ctx_shared_memory_scope
          , ctx_approval_mode ) =
        get_turn_context ~keeper_name ()
      in
      let lane = match lane with Some _ -> lane | None -> ctx_lane in
      let tool_choice =
        match tool_choice with Some _ -> tool_choice | None -> ctx_tool_choice
      in
      let thinking_enabled =
        match thinking_enabled with
        | Some _ -> thinking_enabled
        | None -> ctx_thinking_enabled
      in
      let thinking_budget =
        match thinking_budget with
        | Some _ -> thinking_budget
        | None -> ctx_thinking_budget
      in
      let prompt_fingerprint =
        match prompt_fingerprint with
        | Some _ -> prompt_fingerprint
        | None -> ctx_prompt_fingerprint
      in
      let trace_id = match trace_id with Some _ -> trace_id | None -> ctx_trace_id in
      let session_id =
        match session_id with Some _ -> session_id | None -> ctx_session_id
      in
      let turn = match turn with Some _ -> turn | None -> ctx_turn in
      let keeper_turn_id =
        match keeper_turn_id with
        | Some _ -> keeper_turn_id
        | None -> ctx_keeper_turn_id
      in
      let task_id = match task_id with Some _ -> task_id | None -> ctx_task_id in
      let goal_ids =
        match goal_ids with Some _ -> goal_ids | None -> ctx_goal_ids
      in
      let execution_scope =
        match execution_scope with
        | Some _ -> execution_scope
        | None -> ctx_execution_scope
      in
      let sandbox_profile =
        match sandbox_profile with
        | Some _ -> sandbox_profile
        | None -> ctx_sandbox_profile
      in
      let network_mode =
        match network_mode with
        | Some _ -> network_mode
        | None -> ctx_network_mode
      in
      let shared_memory_scope =
        match shared_memory_scope with
        | Some _ -> shared_memory_scope
        | None -> ctx_shared_memory_scope
      in
      let approval_mode =
        match approval_mode with
        | Some _ -> approval_mode
        | None -> ctx_approval_mode
      in
      let model_field =
        if model = "" then [] else [("model", `String model)]
      in
      let result_bytes_field = match result_bytes with
        | Some n -> [("result_bytes", `Int n)]
        | None -> []
      in
      let truncated_to_field = match truncated_to with
        | Some n -> [("truncated_to", `Int n)]
        | None -> []
      in
      let lane_field = match lane with
        | Some value -> [("lane", `String value)]
        | None -> []
      in
      let tool_choice_field = match tool_choice with
        | Some value -> [("tool_choice", `String value)]
        | None -> []
      in
      let thinking_enabled_field = match thinking_enabled with
        | Some value -> [("thinking_enabled", `Bool value)]
        | None -> []
      in
      let thinking_budget_field = match thinking_budget with
        | Some value -> [("thinking_budget", `Int value)]
        | None -> []
      in
      let prompt_fingerprint_field = match prompt_fingerprint with
        | Some value -> [("prompt_fingerprint", `String value)]
        | None -> []
      in
      let trace_id_field = match trace_id with
        | Some value -> [("trace_id", `String value)]
        | None -> []
      in
      let session_id_field = match session_id with
        | Some value -> [("session_id", `String value)]
        | None -> []
      in
      let turn_field = match turn with
        | Some value -> [("turn", `Int value)]
        | None -> []
      in
      let keeper_turn_id_field = match keeper_turn_id with
        | Some value -> [("keeper_turn_id", `Int value)]
        | None -> []
      in
      let task_id_field = match task_id with
        | Some value -> [("task_id", `String value)]
        | None -> []
      in
      let goal_ids_field = match goal_ids with
        | Some values ->
            [("goal_ids", `List (List.map (fun value -> `String value) values))]
        | None -> []
      in
      let execution_scope_field = match execution_scope with
        | Some value -> [("execution_scope", `String value)]
        | None -> []
      in
      let sandbox_profile_field = match sandbox_profile with
        | Some value -> [("sandbox_profile", `String value)]
        | None -> []
      in
      let network_mode_field = match network_mode with
        | Some value -> [("network_mode", `String value)]
        | None -> []
      in
      let shared_memory_scope_field = match shared_memory_scope with
        | Some value -> [("shared_memory_scope", `String value)]
        | None -> []
      in
      let approval_mode_field = match approval_mode with
        | Some value -> [("approval_mode", `String value)]
        | None -> []
      in
      let safe_input = input_to_json (Observability_redact.redact_json_value input) in
      let safe_output = Observability_redact.redact_preview ~max_len:max_output_len output_text in
      let output_json = blob_aware_output_json safe_output in
      let json =
        `Assoc
          ([ ("ts", `Float (Time_compat.now ()))
           ; ("keeper", `String keeper_name)
           ; ("tool", `String tool_name)
           ; ("input", safe_input)
           ; ("output", output_json)
           ; ("success", `Bool success)
           ; ("duration_ms", `Float duration_ms)
           ]
           @ model_field @ lane_field @ tool_choice_field
           @ thinking_enabled_field @ thinking_budget_field
           @ prompt_fingerprint_field
           @ trace_id_field @ session_id_field @ turn_field
           @ keeper_turn_id_field @ task_id_field @ goal_ids_field
           @ execution_scope_field @ sandbox_profile_field @ network_mode_field
           @ shared_memory_scope_field @ approval_mode_field
           @ result_bytes_field @ truncated_to_field)
      in
      (* Sanitize UTF-8 before persisting.  Tool output may contain invalid
         byte sequences (truncated UTF-8, binary output from subprocess
         captures) that would corrupt the JSONL file and cause downstream
         readers — including the dashboard — to silently skip entire rows. *)
      let safe_json = Inference_utils.sanitize_json_utf8 json in
      (try Dated_jsonl.append store safe_json
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Log.Misc.warn "keeper_tool_call_log: append failed for %s/%s: %s"
           keeper_name tool_name (Printexc.to_string exn))

let read_recent ?keeper_name ?(n = 100) () : Yojson.Safe.t list =
  if n <= 0 then []
  else
  match !store_ref with
  | None -> []
  | Some store ->
    let keeper_matches name json =
      match Safe_ops.json_string_opt "keeper" json with
      | Some k -> String.equal k name
      | None -> false
    in
    (* Single-pass: read from store, filter, and collect last n in one traversal *)
    let raw = Dated_jsonl.read_recent store (n * 5) in
    let buf = Array.make n (`Null : Yojson.Safe.t) in
    let pos = ref 0 in
    let total = ref 0 in
    List.iter (fun json ->
      let dominated = match keeper_name with
        | None -> true
        | Some name -> keeper_matches name json
      in
      if dominated then begin
        buf.(!pos mod n) <- json;
        incr pos;
        incr total
      end
    ) raw;
    let count = min !total n in
    if count = 0 then []
    else
      let start = if !total <= n then 0 else !pos mod n in
      List.init count (fun i -> buf.((start + i) mod n))

let iso_date_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02d"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday

let ts_of_entry (json : Yojson.Safe.t) : float option =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "ts" fields with
      | Some (`Float f) -> Some f
      | Some (`Int i) -> Some (Float.of_int i)
      | _ -> None)
  | _ -> None

let read_window ?keeper_name ~(window_hours : float) () : Yojson.Safe.t list =
  if window_hours <= 0.0 then []
  else
    match !store_ref with
    | None -> []
    | Some store ->
        let now = Time_compat.now () in
        let since_ts = now -. (window_hours *. 3600.0) in
        let since_date = iso_date_of_unix since_ts in
        let until_date = iso_date_of_unix now in
        let keeper_matches name json =
          match Safe_ops.json_string_opt "keeper" json with
          | Some k -> String.equal k name
          | None -> false
        in
        Dated_jsonl.read_range store ~since:since_date ~until:until_date
        |> List.filter (fun json ->
               let in_window =
                 match ts_of_entry json with
                 | Some ts -> ts >= since_ts
                 | None -> false
               in
               in_window
               &&
               match keeper_name with
               | None -> true
               | Some name -> keeper_matches name json)

let read_latest ?keeper_name () : Yojson.Safe.t option =
  let keeper_matches name json =
    match Safe_ops.json_string_opt "keeper" json with
    | Some k -> String.equal k name
    | None -> false
  in
  match !store_ref with
  | None -> None
  | Some store ->
      let scan_limit =
        match keeper_name with
        | None -> 1
        | Some _ -> 16
      in
      let raw_lines = Dated_jsonl.read_recent_lines store scan_limit in
      let rec loop = function
        | [] -> None
        | line :: rest -> (
            match Yojson.Safe.from_string line with
            | exception Yojson.Json_error _ -> loop rest
            | json ->
                let dominated =
                  match keeper_name with
                  | None -> true
                  | Some name -> keeper_matches name json
                in
                if dominated then Some json else loop rest)
      in
      loop (List.rev raw_lines)
