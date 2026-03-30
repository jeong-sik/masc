(** Keeper_tools_oas — Wrap keeper tools as OAS Tool.t for Agent.run().

    Bridges [Keeper_exec_tools.execute_keeper_tool_call] dispatch
    to [Agent_sdk.Tool.t] list via [Tool_bridge.oas_tool_of_masc].

    Tool execution reads current context from [ctx_ref] (mutable ref),
    enabling Agent.run() to manage messages while keeper tools
    access the working context for status/metrics.

    @since Phase 4 — Keeper → Agent.run() migration *)

(* ── Per-keeper tool usage tracking ──────────────────────────── *)

(** Re-export from Keeper_types so dashboard code using
    [e.Keeper_tools_oas.count] keeps compiling. *)
type tool_call_entry = Keeper_types.tool_call_entry = {
  mutable count : int;
  mutable successes : int;
  mutable failures : int;
  mutable last_used_at : float;
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
    [ctx_ref] snapshot. Tools that raise exceptions return error results
    instead of crashing the agent loop.

    @param config Room configuration for tool dispatch
    @param meta Keeper metadata (determines which tools are allowed)
    @param ctx_ref Mutable ref to current working context *)
(** Repeated-failure guardrail: blocks a tool after [max_consecutive]
    consecutive failures with the same (tool_name, args_hash) key.
    Resets on success. Prevents infinite retry loops (e.g. keeper
    reading a non-existent file 400+ times). *)
let max_consecutive_failures =
  Env_config.KeeperToolExec.max_consecutive_tool_failures

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
  (* No mutex: Hashtbl ops are non-yielding, single domain. *)
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
            (match Hashtbl.find_opt failure_counts key with
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
                Hashtbl.replace failure_counts key count;
                Keeper_registry.record_tool_use ~base_path:config.base_path meta.name ~tool_name:td.name ~success:false;
                Log.Keeper.warn
                  "tool %s returned error result (%d/%d) for same args"
                  td.name count max_consecutive_failures;
                (false, result)
              end else begin
                Hashtbl.remove failure_counts key;
                Keeper_registry.record_tool_use ~base_path:config.base_path meta.name ~tool_name:td.name ~success:true;
                (* PR#814 Gap 1: Capture git status delta after successful tool execution.
                   If the working tree changed, log it so the keeper is aware of
                   file-system side effects from its tool calls. *)
                (match Worktree_live_context.capture_change_block
                         ~base_path:config.base_path ~actor_key:meta.name with
                 | Some change_block ->
                     Log.Keeper.info "post-tool git delta detected for %s after %s"
                       meta.name td.name;
                     (true, result ^ "\n" ^ change_block)
                 | None -> (true, result))
              end
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              let count = prior_fails + 1 in
              Hashtbl.replace failure_counts key count;
              Keeper_registry.record_tool_use ~base_path:config.base_path meta.name ~tool_name:td.name ~success:false;
              let msg = Printf.sprintf "tool %s failed (%d/%d): %s"
                td.name count max_consecutive_failures
                (Printexc.to_string exn) in
              Log.Keeper.error "%s" msg;
              (false, msg)))
    else None
  ) tool_defs
