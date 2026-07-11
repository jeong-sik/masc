(** Keeper_turn_driver_helpers — pure helper functions extracted from
    [Keeper_turn_driver].

    These are top-level pure functions (no closures over outer state)
    that compute provider-attempt timeout bounds, health-key derivations,
    lane labels, etc. Lifting them out of the 1459-LOC
    [keeper_turn_driver.ml] is a foundation step toward the eventual
    A/B/C decomposition (Agent SDK call / runtime strategy / keeper
    bookkeeping) deferred from RFC-0047 Phase 4.

    No behavior change. Mechanical extraction.

    @since RFC-0048 — keeper_turn_driver split, helpers slice *)

let resolved_tool_lane_label ~effective_tools ~runtime_mcp_policy =
  let inline_names =
    List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) effective_tools
  in
  let runtime_ids =
    match runtime_mcp_policy with
    | Some policy -> policy.Llm_provider.Llm_transport.allowed_tool_names
    | None -> []
  in
  match inline_names <> [], runtime_ids <> [], runtime_mcp_policy with
  | true, true, _ -> "mixed"
  | true, false, _ -> "inline"
  | false, true, _ -> "runtime_mcp"
  | false, false, Some _ -> "runtime_mcp_connect_only"
  | false, false, None -> "none"

(* Compatibility-only public API: RFC-0206 removed every production caller,
   but downstream users may still compile against the installed helper module. *)
let fail_open_health_filtered_candidates
    ~(tool_filtered_candidates : 'a list)
    ~(health_filtered_candidates : 'a list)
  : 'a list * bool =
  match health_filtered_candidates with
  | [] when tool_filtered_candidates <> [] -> tool_filtered_candidates, true
  | _ -> health_filtered_candidates, false

(* RFC-0206: provider_rejections_for_no_tool_error deleted — multi-candidate
   tool-filter rejection lists have no meaning under single-runtime dispatch. *)

let apply_stream_idle_timeout_default = function
  | Some _ as v -> v
  | None -> Some Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec

let checkpoint_after_attempt ?agent_ref = function
  | Some agent ->
      (match agent_ref with Some r -> r := Some agent | None -> ());
      Some (Agent_sdk.Agent.checkpoint agent)
  | None -> None
