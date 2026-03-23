(** Keeper_tools_oas — Wrap keeper tools as OAS Tool.t for Agent.run().

    Bridges [Keeper_exec_tools.execute_keeper_tool_call] dispatch
    to [Agent_sdk.Tool.t] list via [Tool_bridge.oas_tool_of_masc].

    Tool execution reads current context from [ctx_ref] (mutable ref),
    enabling Agent.run() to manage messages while keeper tools
    access the working context for status/metrics.

    @since Phase 4 — Keeper → Agent.run() migration *)

(** Build OAS Tool.t list from keeper's allowed tools.

    Each tool delegates to [execute_keeper_tool_call] with the current
    [ctx_ref] snapshot. Tools that raise exceptions return error results
    instead of crashing the agent loop.

    @param config Room configuration for tool dispatch
    @param meta Keeper metadata (determines which tools are allowed)
    @param ctx_ref Mutable ref to current working context *)
(** Repeated-failure guardrail: blocks a tool after [max_consecutive]
    consecutive failures with the same (tool_name, args_hash) key.
    Resets on success. Prevents infinite retry loops (e.g. keeper
    reading a non-existent file 400+ times). *)
let max_consecutive_failures = 3

let keeper_tool_result_is_failure (result : string) : bool =
  try
    let json = Yojson.Safe.from_string result in
    let has_error_field =
      match Safe_ops.json_string_opt "error" json with
      | Some msg -> String.trim msg <> ""
      | None -> false
    in
    let has_error_status =
      match Safe_ops.json_string_opt "status" json with
      | Some status ->
          String.equal (String.lowercase_ascii (String.trim status)) "error"
      | None -> false
    in
    let has_ok_false =
      match Safe_ops.json_bool_opt "ok" json with
      | Some false -> true
      | Some true | None -> false
    in
    has_error_field || has_error_status || has_ok_false
  with Yojson.Json_error _ -> false

let make_tools
    ~(config : Room.config)
    ~(meta : Keeper_types.keeper_meta)
    ~(ctx_ref : Keeper_working_context.working_context ref)
  : Agent_sdk.Tool.t list =
  let allowed_names =
    Keeper_exec_tools.keeper_allowed_tool_names meta
  in
  let tool_defs =
    Keeper_exec_tools.keeper_allowed_model_tools meta
  in
  let failure_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let failure_counts_mu : Eio.Mutex.t option ref = ref None in
  let with_failure_counts f =
    match !failure_counts_mu with
    | Some mu -> Eio.Mutex.use_rw ~protect:true mu (fun () -> f ())
    | None -> (
        match Eio_context.get_switch_opt () with
        | Some _ ->
            let mu = Eio.Mutex.create () in
            failure_counts_mu := Some mu;
            Eio.Mutex.use_rw ~protect:true mu (fun () -> f ())
        | None -> f ())
  in
  let args_key name input =
    let h = Hashtbl.hash (Yojson.Safe.to_string input) in
    Printf.sprintf "%s:%d" name h
  in
  List.filter_map (fun (td : Types.tool_schema) ->
    if List.mem td.name allowed_names then
      Some (Tool_bridge.oas_tool_of_masc
        ~name:td.name
        ~description:td.description
        ~input_schema:td.input_schema
        (fun input ->
          let key = args_key td.name input in
          let prior_fails =
            with_failure_counts (fun () ->
              match Hashtbl.find_opt failure_counts key with
              | Some n -> n | None -> 0)
          in
          if prior_fails >= max_consecutive_failures then begin
            Log.Keeper.warn "tool %s blocked after %d consecutive failures (same args)"
              td.name prior_fails;
            (false, Printf.sprintf
              "This tool has failed %d times in a row with the same arguments. Try a different approach or different arguments."
              prior_fails)
          end else
            try
              let result =
                Keeper_exec_tools.execute_keeper_tool_call
                  ~config ~meta ~ctx_work:(!ctx_ref)
                  ~name:td.name ~input
              in
              if keeper_tool_result_is_failure result then begin
                let count = prior_fails + 1 in
                with_failure_counts (fun () ->
                  Hashtbl.replace failure_counts key count);
                Log.Keeper.warn
                  "tool %s returned error result (%d/%d) for same args"
                  td.name count max_consecutive_failures;
                (false, result)
              end else begin
                with_failure_counts (fun () ->
                  Hashtbl.remove failure_counts key);
                (true, result)
              end
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              let count = prior_fails + 1 in
              with_failure_counts (fun () ->
                Hashtbl.replace failure_counts key count);
              let msg = Printf.sprintf "tool %s failed (%d/%d): %s"
                td.name count max_consecutive_failures
                (Printexc.to_string exn) in
              Log.Keeper.error "%s" msg;
              (false, msg)))
    else None
  ) tool_defs
