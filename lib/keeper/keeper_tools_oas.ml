(** Keeper_tools_oas — Wrap keeper tools as OAS Tool.t for Agent.run().

    Bridges [Keeper_exec_tools.execute_keeper_tool_call] dispatch
    to [Agent_sdk.Tool.t] list via [Tool_bridge.oas_tool_of_masc].

    Tool execution reads current context from [ctx_snapshot] (immutable),
    enabling Agent.run() to manage messages while keeper tools
    access the working context for status/metrics.

    @since Phase 4 — Keeper → Agent.run() migration *)

(* ── Per-keeper tool usage tracking ──────────────────────────── *)

(** Re-export from Keeper_types so dashboard code using
    [e.Keeper_tools_oas.count] keeps compiling. *)
type tool_call_entry = Keeper_types.tool_call_entry = {
  count : int;
  successes : int;
  failures : int;
  last_used_at : float;
}

(** Tool usage now lives in Keeper_registry (per-entry tool_usage Hashtbl).
    These public functions preserve the existing API surface. *)

let tool_usage_for_keeper keeper_name : (string * tool_call_entry) list =
  Keeper_registry.tool_usage_of_by_name keeper_name

let tool_usage_json keeper_name : Yojson.Safe.t =
  `List (List.map (fun (name, e) ->
    `Assoc [
      ("tool_name", `String name);
      ("count", `Int e.count);
      ("successes", `Int e.successes);
      ("failures", `Int e.failures);
      ("last_used_at", `Float e.last_used_at);
    ]
  ) (tool_usage_for_keeper keeper_name))

let recent_tools_for_keeper ?(limit = 5) keeper_name : string list =
  tool_usage_for_keeper keeper_name
  |> List.sort (fun (_, a) (_, b) -> Float.compare b.last_used_at a.last_used_at)
  |> (fun l -> let rec take n acc = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | (name, _) :: rest -> take (n - 1) (name :: acc) rest
    in take limit [] l)

(* ── end tracking ────────────────────────────────────────────── *)

(** Build OAS Tool.t list from keeper's allowed tools.

    Each tool delegates to [execute_keeper_tool_call] with the current
    [ctx_snapshot] value. Tools that raise exceptions return error results
    instead of crashing the agent loop.

    @param config Coord configuration for tool dispatch
    @param meta Keeper metadata (determines which tools are allowed)
    @param ctx_snapshot Immutable snapshot of current working context *)
(** Repeated-failure guardrail: blocks a tool after [max_consecutive]
    consecutive failures with the same (tool_name, args_hash) key.
    Resets on success. Prevents infinite retry loops (e.g. keeper
    reading a non-existent file 400+ times). *)
let max_consecutive_failures =
  Env_config.KeeperToolExec.max_consecutive_tool_failures

(** Normalize a raw tool result string into a consistent JSON envelope.

    The LLM sees this output directly. Without normalization, tool results
    use 6+ different schemas ({ok,error,status,...} in various combinations),
    making it hard for the LLM to parse success/failure reliably.

    After normalization, all results follow:
    - Success: {"ok": true, "result": <original_json_or_string>}
    - Success with changes: {"ok": true, "result": ..., "changes": <delta>}
    - Failure: {"ok": false, "error": <message>, "detail": <original_json|null>}

    The [success] flag comes from the typed outcome returned by
    [Keeper_exec_tools.execute_keeper_tool_call_with_outcome]. *)
let normalize_tool_result ~(success : bool) (raw : string) : string =
  try
    let json = Yojson.Safe.from_string raw in
    if success then
      (* Success: wrap original JSON under "result" key.
         If original already has "ok":true, the normalized envelope
         is still consistent — "ok" at the top level is authoritative. *)
      Yojson.Safe.to_string (`Assoc [
        ("ok", `Bool true);
        ("result", json);
      ])
    else
      (* Failure: extract error message from whichever field is present,
         preserve original JSON as "detail" for debugging. *)
      let error_msg =
        match Safe_ops.json_string_opt "error" json with
        | Some msg when String.trim msg <> "" -> msg
        | _ ->
          match Safe_ops.json_string_opt "output" json with
          | Some msg when String.trim msg <> "" -> msg
          | _ ->
            match Safe_ops.json_string_opt "message" json with
            | Some msg when String.trim msg <> "" -> msg
            | _ ->
              match Safe_ops.json_string_opt "status" json with
              | Some s when String.lowercase_ascii (String.trim s) = "error" ->
                "tool returned error status"
              | _ -> "tool call failed"
      in
      Yojson.Safe.to_string (`Assoc [
        ("ok", `Bool false);
        ("error", `String error_msg);
        ("detail", json);
      ])
  with Yojson.Json_error _ ->
    (* Raw is not JSON (e.g. plain text from keeper_tasks_list).
       Wrap as-is. *)
    if success then
      Yojson.Safe.to_string (`Assoc [
        ("ok", `Bool true);
        ("result", `String raw);
      ])
    else
      Yojson.Safe.to_string (`Assoc [
        ("ok", `Bool false);
        ("error", `String raw);
        ("detail", `Null);
      ])

(** Max chars for SSE error preview. Short enough for dashboard display,
    long enough to include the actionable portion of the error. *)
let sse_error_preview_max_chars = 300

let make_tools
    ~(config : Coord.config)
    ~(meta : Keeper_types.keeper_meta)
    ~(ctx_snapshot : Keeper_types.working_context)
    ?search_fn
    ?on_tool_called
    ()
  : Agent_sdk.Tool.t list =
  (* Build Tool.t for the full universe so BM25 and Tool_op can
     discover tools beyond the active preset.  Progressive disclosure
     (AllowList filter in before_turn_hook) controls LLM visibility;
     execute_keeper_tool_call uses can_execute for the execution gate. *)
  let universe_names = Keeper_exec_tools.keeper_universe_tool_names meta in
  let tool_defs =
    Keeper_exec_tools.keeper_universe_model_tools meta
  in
  let failure_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
  (* No mutex: Hashtbl ops are non-yielding, single domain. *)
  let args_key name input =
    let h = Hashtbl.hash (Yojson.Safe.to_string input) in
    Printf.sprintf "%s:%d" name h
  in
  List.filter_map (fun (td : Types.tool_schema) ->
    if List.mem td.name universe_names then
      Some (Tool_bridge.oas_tool_of_masc
        ~name:td.name
        ~description:td.description
        ~input_schema:td.input_schema
        (fun input ->
          let key = args_key td.name input in
          let prior_fails =
            (match Hashtbl.find_opt failure_counts key with
              | Some n -> n | None -> 0)
          in
          if prior_fails >= max_consecutive_failures then begin
            Log.Keeper.warn "tool %s blocked after %d consecutive failures (same args)"
              td.name prior_fails;
            let msg = Printf.sprintf
              "This tool has failed %d times in a row with the same arguments. Try a different approach or different arguments."
              prior_fails in
            (false, normalize_tool_result ~success:false msg)
          end else
            let t0 = Time_compat.now () in
            try
              let (result, duration_ms) =
                Inference_utils.timed (fun () ->
                  Keeper_exec_tools.execute_keeper_tool_call_with_outcome
                    ~config ~meta ~ctx_work:ctx_snapshot
                    ?search_fn
                    ~name:td.name ~input ())
              in
              let raw_result = result.raw_output in
              let is_failure =
                match result.outcome with
                | `Failure -> true
                | `Success -> false
              in
              if is_failure then begin
                let count = prior_fails + 1 in
                Hashtbl.replace failure_counts key count;
                Keeper_registry.record_tool_use ~base_path:config.base_path meta.name ~tool_name:td.name ~success:false;
                !Keeper_exec_tools.on_keeper_tool_call ~tool_name:td.name ~success:false ~duration_ms;
                Keeper_exec_tools.notify_tool_call_observers
                  ~keeper_name:meta.name
                  ~tool_name:td.name
                  ~input
                  ~success:false;
                (let tr = Tool_result.{ tool_name = td.name; success = false;
                    duration_ms = Float.of_int duration_ms; data = `Null } in
                 ignore (Tool_dispatch.run_post_hooks tr));
                let detail =
                  let s = String.trim raw_result in
                  String_util.utf8_safe ~max_bytes:(sse_error_preview_max_chars + 3) ~suffix:"..." s |> String_util.to_string
                in
                let ts = Time_compat.now () in
                (try Sse.broadcast
                  (`Assoc [
                    ("type", `String "keeper_tool_call");
                    ("name", `String meta.name);
                    ("tool_name", `String td.name);
                    ("duration_ms", `Int duration_ms);
                    ("success", `Bool false);
                    ("error_text", `String detail);
                    ("ts_unix", `Float ts);
                  ])
                 with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
                Log.Keeper.error
                  "tool %s returned error result (%d/%d): %s"
                  td.name count max_consecutive_failures detail;
                let normalized_error =
                  normalize_tool_result ~success:false raw_result
                in
                (try
                  Keeper_types_support.append_jsonl_line
                    (Keeper_types_support.keeper_decision_log_path config meta.name)
                    (`Assoc [
                      "ts_unix", `Float ts;
                      "event", `String "tool_exec";
                      "keeper_name", `String meta.name;
                      "tool", `String td.name;
                      "duration_ms", `Int duration_ms;
                      "result_bytes", `Int (String.length normalized_error);
                      "ok", `Bool false;
                    ])
                with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
                Keeper_tool_call_log.set_truncation_info
                  ~keeper_name:meta.name
                  ~original_bytes:(String.length normalized_error) ();
                (false, Tool_output_validation.cap normalized_error)
              end else begin
                Hashtbl.remove failure_counts key;
                Keeper_registry.record_tool_use ~base_path:config.base_path meta.name ~tool_name:td.name ~success:true;
                !Keeper_exec_tools.on_keeper_tool_call ~tool_name:td.name ~success:true ~duration_ms;
                Keeper_exec_tools.notify_tool_call_observers
                  ~keeper_name:meta.name
                  ~tool_name:td.name
                  ~input
                  ~success:true;
                (let tr = Tool_result.{ tool_name = td.name; success = true;
                    duration_ms = Float.of_int duration_ms; data = `Null } in
                 ignore (Tool_dispatch.run_post_hooks tr));
                let ts = Time_compat.now () in
                (try Sse.broadcast
                  (`Assoc [
                    ("type", `String "keeper_tool_call");
                    ("name", `String meta.name);
                    ("tool_name", `String td.name);
                    ("duration_ms", `Int duration_ms);
                    ("success", `Bool true);
                    ("ts_unix", `Float ts);
                  ])
                 with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
                (* Notify session callback (e.g., mark_used for discovered tools) *)
                (match on_tool_called with Some f -> f td.name | None -> ());
                (* PR#814 Gap 1: Capture git status delta after successful tool execution.
                   If the working tree changed, log it so the keeper is aware of
                   file-system side effects from its tool calls. *)
                let change_block =
                  Worktree_live_context.capture_change_block
                    ~base_path:config.base_path ~actor_key:meta.name
                in
                (match change_block with
                 | Some _cb ->
                     Log.Keeper.info "post-tool git delta detected for %s after %s"
                       meta.name td.name
                 | None -> ());
                let normalized =
                  normalize_tool_result ~success:true raw_result
                in
                let final_result =
                  match change_block with
                  | None -> normalized
                  | Some cb ->
                    (* Inject changes field into the normalized JSON envelope
                       to preserve valid JSON structure. *)
                    (try
                       let json = Yojson.Safe.from_string normalized in
                       match json with
                       | `Assoc fields ->
                         Yojson.Safe.to_string
                           (`Assoc (fields @ [("changes", `String cb)]))
                       | _ -> normalized
                     with Yojson.Json_error _ -> normalized)
                in
                let original_len = String.length final_result in
                let truncated_result = Tool_output_validation.cap final_result in
                let was_truncated = original_len > Tool_output_validation.max_output_chars in
                if was_truncated then
                  Log.Keeper.info "tool %s output truncated: %d -> %d chars"
                    td.name original_len (String.length truncated_result);
                (try
                  Keeper_types_support.append_jsonl_line
                    (Keeper_types_support.keeper_decision_log_path config meta.name)
                    (`Assoc ([
                      "ts_unix", `Float ts;
                      "event", `String "tool_exec";
                      "keeper_name", `String meta.name;
                      "tool", `String td.name;
                      "duration_ms", `Int duration_ms;
                      "result_bytes", `Int original_len;
                      "ok", `Bool true;
                    ] @ (if was_truncated then
                      ["truncated_to", `Int (String.length truncated_result)]
                    else [])))
                with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
                (* Publish truncation info for OAS hook's tool_call_log *)
                Keeper_tool_call_log.set_truncation_info
                  ~keeper_name:meta.name
                  ~original_bytes:original_len
                  ?truncated_to:(if was_truncated
                    then Some (String.length truncated_result) else None) ();
                (true, truncated_result)
              end
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              let ts = Time_compat.now () in
              let duration_ms =
                int_of_float ((ts -. t0) *. 1000.0) in
              let count = prior_fails + 1 in
              let error_text = Printexc.to_string exn in
              Hashtbl.replace failure_counts key count;
              Keeper_registry.record_tool_use ~base_path:config.base_path meta.name ~tool_name:td.name ~success:false;
              !Keeper_exec_tools.on_keeper_tool_call ~tool_name:td.name ~success:false ~duration_ms;
              Keeper_exec_tools.notify_tool_call_observers
                ~keeper_name:meta.name
                ~tool_name:td.name
                ~input
                ~success:false;
              (try Sse.broadcast
                (`Assoc [
                  ("type", `String "keeper_tool_call");
                  ("name", `String meta.name);
                  ("tool_name", `String td.name);
                  ("duration_ms", `Int duration_ms);
                  ("success", `Bool false);
                  ("error_text", `String error_text);
                  ("ts_unix", `Float ts);
                ])
               with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
              let msg = Printf.sprintf "tool %s failed (%d/%d): %s"
                td.name count max_consecutive_failures
                (Printexc.to_string exn) in
              Log.Keeper.error "%s" msg;
              let normalized_exn = normalize_tool_result ~success:false msg in
              (try
                Keeper_types_support.append_jsonl_line
                  (Keeper_types_support.keeper_decision_log_path config meta.name)
                  (`Assoc [
                    "ts_unix", `Float ts;
                    "event", `String "tool_exec";
                    "keeper_name", `String meta.name;
                    "tool", `String td.name;
                    "duration_ms", `Int duration_ms;
                    "result_bytes", `Int (String.length normalized_exn);
                    "ok", `Bool false;
                    "error", `String error_text;
                  ])
              with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
              Keeper_tool_call_log.set_truncation_info
                ~keeper_name:meta.name
                ~original_bytes:(String.length normalized_exn) ();
              (false, Tool_output_validation.cap normalized_exn)))
    else None
  ) tool_defs
