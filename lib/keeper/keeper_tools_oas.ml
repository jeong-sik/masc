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

type tool_bundle =
  {
    tools : Agent_sdk.Tool.t list;
    cleanup : unit -> unit;
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

let transient_mutex_contention_error_class = "transient_mutex_contention"

let transient_mutex_contention_tool_error
    ~(tool_name : string)
    ~(error_text : string)
    ?backtrace
    () : string =
  let message =
    Printf.sprintf
      "tool %s hit transient mutex contention (EDEADLK); not counted toward consecutive-failure budget. Retry the same call or wait for the contending operation to finish."
      tool_name
  in
  Yojson.Safe.to_string
    (`Assoc [
      ("ok", `Bool false);
      ("error", `String message);
      ("error_class", `String transient_mutex_contention_error_class);
      ("recoverable", `Bool true);
      ("transient", `Bool true);
      ("retry_recommended", `Bool true);
      ( "detail",
        `Assoc [
          ("tool_name", `String tool_name);
          ("exception", `String error_text);
          ("operator_action", `String "retry_same_call_or_wait");
          ("backtrace_available", `Bool (Option.is_some backtrace));
        ] );
    ])

(** Max chars for SSE error preview. Short enough for dashboard display,
    long enough to include the actionable portion of the error. *)
let sse_error_preview_max_chars = 300

let add_unique_marker marker markers =
  if List.mem marker markers then markers else marker :: markers

let json_string_field_opt key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) -> Some value
      | _ -> None)
  | _ -> None

let strip_simple_quotes text =
  let len = String.length text in
  if len >= 2 then
    match text.[0], text.[len - 1] with
    | '\'', '\'' | '"', '"' -> String.sub text 1 (len - 2)
    | _ -> text
  else text

let command_words command =
  command
  |> String.split_on_char ' '
  |> List.filter_map (fun word ->
         match String.trim word with
         | "" -> None
         | word -> Some (strip_simple_quotes word |> String.lowercase_ascii))

let add_command_markers command markers =
  match command_words command with
  | "git" :: "push" :: _ -> add_unique_marker "git push" markers
  | "gh" :: "pr" :: "create" :: _ ->
      add_unique_marker "gh pr create" markers
  | _ -> markers

let add_action_marker action markers =
  match String.lowercase_ascii (String.trim action) with
  | "push" -> add_unique_marker "git push" markers
  | _ -> markers

let add_event_marker event markers =
  match String.uppercase_ascii (String.trim event) with
  | "APPROVE" -> add_unique_marker "event=APPROVE" markers
  | _ -> markers

let add_operation_marker operation markers =
  match String.lowercase_ascii (String.trim operation) with
  | "pr_create" -> add_unique_marker "gh pr create" markers
  | _ -> markers

let allowed_via_marker = function
  | "brokered" | "docker" | "host" | "keeper" | "operator" | "system"
  | "taskmaster" ->
      true
  | _ -> false

let add_via_marker via markers =
  let value = String.trim via |> String.lowercase_ascii in
  if allowed_via_marker value then add_unique_marker ("via=" ^ value) markers
  else markers

let add_json_marker_fields ?(trusted_route_fields = true) json markers =
  let markers =
    if trusted_route_fields then
      match json_string_field_opt "via" json with
      | Some via -> add_via_marker via markers
      | None -> markers
    else markers
  in
  let markers =
    match json_string_field_opt "cmd" json with
    | Some command -> add_command_markers command markers
    | None -> markers
  in
  let markers =
    match json_string_field_opt "command" json with
    | Some command -> add_command_markers command markers
    | None -> markers
  in
  let markers =
    match json_string_field_opt "op_cmd" json with
    | Some command -> add_command_markers command markers
    | None -> markers
  in
  let markers =
    if trusted_route_fields then
      match json_string_field_opt "action" json with
      | Some action -> add_action_marker action markers
      | None -> markers
    else markers
  in
  let markers =
    if trusted_route_fields then
      match json_string_field_opt "event" json with
      | Some event -> add_event_marker event markers
      | None -> markers
    else markers
  in
  if trusted_route_fields then
    match json_string_field_opt "operation" json with
    | Some operation -> add_operation_marker operation markers
    | None -> markers
  else markers

let tool_exec_result_markers ~(input : Yojson.Safe.t) ~(output : string)
    : string list =
  let markers = add_json_marker_fields ~trusted_route_fields:false input [] in
  let markers =
    try
      let json = Yojson.Safe.from_string output in
      let markers = add_json_marker_fields json markers in
      match json with
      | `Assoc fields -> (
          match List.assoc_opt "result" fields with
          | Some result -> add_json_marker_fields result markers
          | None -> markers)
      | _ -> markers
    with Yojson.Json_error _ -> markers
  in
  List.rev markers

(** RFC-0006 Phase A.2: build the per-tool handler closure.

    Extracted from the original anonymous closure inside [make_tools] so
    that alias [Tool.t] entries (e.g. [Bash] -> [keeper_bash]) can reuse
    the exact same telemetry/circuit-breaker/decision-log pipeline by
    instantiating this helper with the INTERNAL name as [~name].

    Telemetry SSOT contract: [~name] flows into every observability
    sink (Keeper_registry.record_tool_use, SSE broadcast tool_name,
    decision-log "tool" field, on_keeper_tool_call). The LLM-facing
    public name (Bash/Read/...) only appears as the [Tool.schema.name]
    set by [Tool_bridge.oas_tool_of_masc] above this helper.

    [?translate_input] reshapes the incoming JSON from the public schema
    to the internal tool's expected payload (e.g. [{command,timeout}] ->
    [{cmd,timeout_sec}]). Identity by default. *)
let make_keeper_tool_handler
    ~(name : string)
    ~(config : Coord.config)
    ~(meta : Keeper_types.keeper_meta)
    ~(ctx_snapshot : Keeper_types.working_context)
    ?turn_sandbox_factory
    ?turn_sandbox_factory_git
    ~(exec_cache : Masc_exec.Exec_cache.t option)
    ?search_fn
    ?on_tool_called
    ?(translate_input = fun j -> j)
    ~(failure_counts : (string, int) Hashtbl.t)
    ()
  : Yojson.Safe.t -> bool * string =
  let args_key input =
    let h = Hashtbl.hash (Yojson.Safe.to_string input) in
    Printf.sprintf "%s:%d" name h
  in
  fun raw_input ->
    let input = translate_input raw_input in
    let key = args_key input in
    let prior_fails =
      (match Hashtbl.find_opt failure_counts key with
        | Some n -> n | None -> 0)
    in
    if prior_fails >= max_consecutive_failures then begin
      Prometheus.inc_counter
        Prometheus.metric_keeper_tools_oas_failures
        ~labels:[("tool", name); ("site", "blocked")]
        ();
      Log.Keeper.warn "tool %s blocked after %d consecutive failures (same args)"
        name prior_fails;
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
              ?turn_sandbox_factory
              ?turn_sandbox_factory_git
              ~exec_cache
              ?search_fn
              ~name ~input ())
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
          Keeper_registry.record_tool_use ~base_path:config.base_path meta.name ~tool_name:name ~success:false;
          !Keeper_exec_tools.on_keeper_tool_call ~tool_name:name ~success:false ~duration_ms;
          (* Tool-call observability flows through the OAS Event_bus
             (ToolCalled + ToolCompleted). MASC-side observers removed
             in refactor/tool-call-single-source. *)
          (let tr = Tool_result.{ tool_name = name; success = false;
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
              ("tool_name", `String name);
              ("duration_ms", `Int duration_ms);
              ("success", `Bool false);
              ("error_text", `String detail);
              ("ts_unix", `Float ts);
            ])
           with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
          Prometheus.inc_counter
            Prometheus.metric_keeper_tools_oas_failures
            ~labels:[("tool", name); ("site", "error_result")]
            ();
          Log.Keeper.error
            "tool %s returned error result (%d/%d): %s"
            name count max_consecutive_failures detail;
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
                "tool", `String name;
                "duration_ms", `Int duration_ms;
                "result_bytes", `Int (String.length normalized_error);
                "ok", `Bool false;
                "error_preview", `String detail;
              ])
          with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
          Keeper_tool_call_log.set_truncation_info
            ~keeper_name:meta.name
            ~original_bytes:(String.length normalized_error) ();
          (false, Tool_output_validation.cap normalized_error)
        end else begin
          Hashtbl.remove failure_counts key;
          Keeper_registry.record_tool_use ~base_path:config.base_path meta.name ~tool_name:name ~success:true;
          !Keeper_exec_tools.on_keeper_tool_call ~tool_name:name ~success:true ~duration_ms;
          (* Tool-call observability via OAS Event_bus. See above. *)
          (let tr = Tool_result.{ tool_name = name; success = true;
              duration_ms = Float.of_int duration_ms; data = `Null } in
           ignore (Tool_dispatch.run_post_hooks tr));
          let ts = Time_compat.now () in
          (try Sse.broadcast
            (`Assoc [
              ("type", `String "keeper_tool_call");
              ("name", `String meta.name);
              ("tool_name", `String name);
              ("duration_ms", `Int duration_ms);
              ("success", `Bool true);
              ("ts_unix", `Float ts);
            ])
           with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
          (* Notify session callback (e.g., mark_used for discovered tools) *)
          (match on_tool_called with Some f -> f name | None -> ());
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
                 meta.name name
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
          let result_markers =
            tool_exec_result_markers ~input ~output:final_result
          in
          let result_marker_fields =
            match result_markers with
            | [] -> []
            | markers ->
                [
                  ( "result_markers",
                    `List (List.map (fun marker -> `String marker) markers) );
                ]
          in
          if was_truncated then
            Log.Keeper.info "tool %s output truncated: %d -> %d chars"
              name original_len (String.length truncated_result);
          (try
            Keeper_types_support.append_jsonl_line
              (Keeper_types_support.keeper_decision_log_path config meta.name)
              (`Assoc ([
                "ts_unix", `Float ts;
                "event", `String "tool_exec";
                "keeper_name", `String meta.name;
                "tool", `String name;
                "duration_ms", `Int duration_ms;
                "result_bytes", `Int original_len;
                "ok", `Bool true;
              ] @ result_marker_fields @ (if was_truncated then
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
        (* #10682: capture backtrace BEFORE any other operation that might
           raise/handle exceptions and clobber the raw_backtrace.  Used
           below to attach a stack to mutex EDEADLK ("Resource deadlock
           avoided") errors so the exact Stdlib.Mutex site can be
           identified — without this, the issue body for #10682 had to
           speculate across 5 candidate sites because no caller wrote
           the backtrace anywhere. *)
        let raw_bt = Printexc.get_raw_backtrace () in
        let ts = Time_compat.now () in
        let duration_ms =
          int_of_float ((ts -. t0) *. 1000.0) in
        let error_text = Printexc.to_string exn in
        let edeadlk_backtrace =
          (* Mutex EDEADLK signature on macOS / Linux pthread errorcheck
             mutexes is exactly this Sys_error message; targeting it
             keeps backtrace dump narrow (rare event) instead of
             spamming every routine tool error. *)
          if String_util.contains_substring error_text
               "Resource deadlock avoided"
          then Some (Printexc.raw_backtrace_to_string raw_bt)
          else None
        in
        let is_edeadlk = edeadlk_backtrace <> None in
        (* #10567: EDEADLK is a transient mutex-contention race in shared
           coord/keeper Stdlib.Mutex sites, not a real keeper-side failure.
           Counting it toward [failure_counts] burns the consecutive-failure
           budget (max 3) and ends the keeper turn even when the next call
           would succeed.  Skip the counter bump and downgrade the log to
           warn so dashboards don't conflate transient EDEADLK with real
           tool errors. The #10682 EDEADLK backtrace logging stays so the
           underlying Stdlib.Mutex site can still be pinpointed. *)
        let count = if is_edeadlk then prior_fails else prior_fails + 1 in
        if not is_edeadlk then
          Hashtbl.replace failure_counts key count;
        Keeper_registry.record_tool_use ~base_path:config.base_path meta.name ~tool_name:name ~success:false;
        !Keeper_exec_tools.on_keeper_tool_call ~tool_name:name ~success:false ~duration_ms;
        (* Tool-call observability via OAS Event_bus. See above. *)
        (try Sse.broadcast
          (`Assoc ([
            ("type", `String "keeper_tool_call");
            ("name", `String meta.name);
            ("tool_name", `String name);
            ("duration_ms", `Int duration_ms);
            ("success", `Bool false);
            ("error_text", `String error_text);
            ("ts_unix", `Float ts);
          ]
          @
          if is_edeadlk then
            [
              ( "error_class",
                `String transient_mutex_contention_error_class );
              ("recoverable", `Bool true);
            ]
          else []))
         with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
        let msg =
          if is_edeadlk then
            Printf.sprintf
              "tool %s hit transient mutex contention (EDEADLK); not counted toward consecutive-failure budget. Retry the same call or pick a different tool."
              name
          else
            Printf.sprintf "tool %s failed (%d/%d): %s"
              name count max_consecutive_failures
              (Printexc.to_string exn)
        in
        Prometheus.inc_counter
          Prometheus.metric_keeper_tools_oas_failures
          ~labels:[("tool", name); ("site", "exception")]
          ();
        if is_edeadlk then Log.Keeper.warn "%s" msg
        else Log.Keeper.error "%s" msg;
        (match edeadlk_backtrace with
         | Some bt ->
             Log.Keeper.error
               "tool %s EDEADLK backtrace (#10682):\n%s" name bt
         | None -> ());
        let normalized_exn =
          if is_edeadlk then
            transient_mutex_contention_tool_error
              ~tool_name:name ~error_text ?backtrace:edeadlk_backtrace ()
          else
            normalize_tool_result ~success:false msg
        in
        (try
          Keeper_types_support.append_jsonl_line
            (Keeper_types_support.keeper_decision_log_path config meta.name)
            (`Assoc ([
              "ts_unix", `Float ts;
              "event", `String "tool_exec";
              "keeper_name", `String meta.name;
              "tool", `String name;
              "duration_ms", `Int duration_ms;
              "result_bytes", `Int (String.length normalized_exn);
              "ok", `Bool false;
              "error", `String error_text;
            ]
            @
            if is_edeadlk then
              [
                ( "error_class",
                  `String transient_mutex_contention_error_class );
                ("recoverable", `Bool true);
              ]
            else []))
        with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
        Keeper_tool_call_log.set_truncation_info
          ~keeper_name:meta.name
          ~original_bytes:(String.length normalized_exn) ();
        (false, Tool_output_validation.cap normalized_exn)

let make_tool_bundle
    ~(config : Coord.config)
    ~(meta : Keeper_types.keeper_meta)
    ~(ctx_snapshot : Keeper_types.working_context)
    ?search_fn
    ?on_tool_called
    ()
  : tool_bundle =
  (* PR-3b (#11611 part 1): replace eager [Keeper_turn_sandbox_runtime]
     instances with a factory.  in_playground/cwd are unknown at
     turn-start, so the factory defers
     [Keeper_shell_docker.effective_sandbox_profile] resolution until
     each tool call site that already knows its [cwd].  The git variant
     stays gated by [hard_mode]; when off, it carries a
     [default_network_override] so resolved runtimes always inherit the
     host network. *)
  let turn_sandbox_factory =
    Some (Keeper_sandbox_factory.create ~config ~meta ())
  in
  let turn_sandbox_factory_git =
    if Env_config_keeper.KeeperSandbox.hard_mode () then
      None
    else
      Some
        (Keeper_sandbox_factory.create
           ~default_network_override:Network_inherit
           ~config ~meta ())
  in
  let exec_cache = Some (Masc_exec.Exec_cache.create ()) in
  (* Build Tool.t for the full universe so BM25 and Tool_op can
     discover tools beyond the active preset.  Progressive disclosure
     (AllowList filter in before_turn_hook) controls LLM visibility;
     execute_keeper_tool_call uses can_execute for the execution gate. *)
  let universe_names = Keeper_exec_tools.keeper_universe_tool_names meta in
  let tool_defs =
    Keeper_exec_tools.keeper_universe_model_tools meta
  in
  (* Record tool assignment telemetry for causal tracing.
     assignment_id links Assigned → Called → Completed events. *)
  let (_assignment_id : Tool_assignment_telemetry.assignment_id) =
    let lookup = Keeper_tool_policy.tool_access_lookup_of_meta meta in
    let preset =
      match meta.tool_access with
      | Preset { preset; _ } ->
          Some (Keeper_tool_policy.preset_name_of_tool_preset preset)
      | Custom _ -> None
    in
    Tool_assignment_telemetry.emit_assigned
      ~agent_id:meta.agent_name
      ~profile:"keeper"
      ?preset
      ~tool_list:universe_names
      ~allow_set:(Keeper_tool_policy.StringSet.elements lookup.allow_set)
      ~deny_set:(Keeper_tool_policy.StringSet.elements lookup.deny_set)
      ~reason:"keeper tool bundle assembly"
      ()
  in
  let failure_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
  (* No mutex: Hashtbl ops are non-yielding, single domain. *)
  (* Pass A: existing internal tools. Behavior unchanged from pre-A.2. *)
  let internal_tools =
    List.filter_map (fun (td : Masc_domain.tool_schema) ->
      if List.mem td.name universe_names then
        let h = make_keeper_tool_handler ~name:td.name ~config ~meta ~ctx_snapshot
              ?turn_sandbox_factory
              ?turn_sandbox_factory_git
              ~exec_cache
              ?search_fn ?on_tool_called ~failure_counts () in
        Some (Tool_bridge.oas_tool_of_masc
          ~name:td.name
          ~description:td.description
          ~input_schema:td.input_schema
          (fun input ->
            let start_time = Time_compat.now () in
            Tool_result.wrap ~tool_name:td.name ~start_time (h input)))
      else None
    ) tool_defs
  in
  (* Pass B: RFC-0006 Phase A.2 — register dual aliases so the LLM can
     call Anthropic Code names (Bash/Read) successfully. The handler
     dispatches with [~name:internal] so all telemetry SSOT remains
     internal; only the Tool.schema.name (LLM-visible) is the public
     alias. translate_input reshapes the LLM's payload before dispatch. *)
  let alias_tools =
    List.filter_map (fun (public, internal) ->
      if not (List.mem internal universe_names) then None
      else
        match
          List.find_opt (fun (td : Masc_domain.tool_schema) ->
            String.equal td.name internal) tool_defs
        with
        | None -> None
        | Some internal_def ->
          let input_schema =
            match Keeper_tool_alias.public_input_schema public with
            | Some s -> s
            | None -> internal_def.input_schema
          in
          let description =
            match public with
            | "Grep" ->
                "Search file contents with ripgrep. This is a public alias \
                 for keeper_shell op=rg only; use Bash/keeper_bash for \
                 command execution."
            | "Bash" ->
                "Execute one shell command through keeper_bash, including \
                 Legendary Bash safety gates, write gating, background \
                 execution, and sandbox routing."
            | _ -> internal_def.description
          in
          let h =
            make_keeper_tool_handler ~name:internal ~config ~meta ~ctx_snapshot
               ?turn_sandbox_factory
               ?turn_sandbox_factory_git
               ~exec_cache
               ?search_fn ?on_tool_called
               ~translate_input:(fun j ->
                 Keeper_tool_alias.translate_input ~public j)
               ~failure_counts ()
          in
          Some (Tool_bridge.oas_tool_of_masc
            ~name:public
            ~description
            ~input_schema
            (fun input ->
              let start_time = Time_compat.now () in
              Tool_result.wrap ~tool_name:public ~start_time (h input)))
    ) (Keeper_tool_alias.oas_dual_register_aliases ())
  in
  {
    tools = internal_tools @ alias_tools;
    cleanup =
      (fun () ->
        Option.iter Keeper_sandbox_factory.cleanup turn_sandbox_factory;
        Option.iter Keeper_sandbox_factory.cleanup turn_sandbox_factory_git);
  }

let make_tools
    ~(config : Coord.config)
    ~(meta : Keeper_types.keeper_meta)
    ~(ctx_snapshot : Keeper_types.working_context)
    ?search_fn
    ?on_tool_called
    ()
  : Agent_sdk.Tool.t list =
  (make_tool_bundle ~config ~meta ~ctx_snapshot ?search_fn ?on_tool_called ()).tools
