(** Tool-surface gating, selection constants, and backlog task reconciliation. *)

let unexpected_tool_partial_warned : (string, unit) Hashtbl.t =
  Hashtbl.create 32

let unexpected_tool_partial_warn_mu = Eio.Mutex.create ()

let should_log_unexpected_tool_partial_once ~keeper_name ~unexpected_tool_names =
  let key =
    String.concat "\000" (keeper_name :: List.sort String.compare unexpected_tool_names)
  in
  Eio_guard.with_mutex unexpected_tool_partial_warn_mu (fun () ->
      if Hashtbl.mem unexpected_tool_partial_warned key then
        false
      else (
        Hashtbl.replace unexpected_tool_partial_warned key ();
        true))

type tool_surface_metrics =
  { turn_lane : string
  ; tool_surface_class : string
  ; tool_requirement : string
  ; visible_tool_count : int
  ; tool_gate_enabled : bool
  ; tool_surface_fallback_used : bool
  ; config_root : string
  ; cascade_config_path : string option
  ; gemini_mcp_disabled : bool
  ; approval_mode_effective : string option
  ; approval_mode_derived : bool
  }

type computed_tool_surface =
  { all_allowed : string list
  ; absolute_turn : int
  ; checkpoint_start_turn : int
  ; per_call_turn : int
  ; per_call_max_turns : int
  ; core_count : int
  ; deterministic_prefilter_count : int
  ; discovered_count : int
  ; llm_selected_count : int
  ; selection_mode : string
  ; is_last_turn : bool
  ; is_warning_zone : bool
  ; tool_surface_class : string
  ; tool_requirement : string
  ; tool_gate_requested : bool
  ; tool_surface_fallback_used : bool
  ; lane : string
  ; query_text : string
  }

type turn_affordance =
  | Board_post_or_comment
  | Message_sweep
  | Task_claim
  | Task_audit

let turn_affordance_of_string = function
  | "board_post_or_comment" -> Some Board_post_or_comment
  | "message_sweep" -> Some Message_sweep
  | "task_claim" -> Some Task_claim
  | "task_audit" -> Some Task_audit
  | _ -> None

let should_tool_gate_affordance = function
  | Board_post_or_comment | Message_sweep | Task_claim | Task_audit -> true

let turn_affordances_require_tool_gate turn_affordances =
  List.exists
    (function
      | Some affordance -> should_tool_gate_affordance affordance
      | None -> false)
    (List.map turn_affordance_of_string turn_affordances)

let should_require_tools_for_initial_turn ~(max_turns : int)
    ~(turn_affordances : string list) =
  let initial_per_call_turn = 1 in
  let initial_turn_is_last = initial_per_call_turn >= max_turns - 1 in
  max_turns > 1
  && not initial_turn_is_last
  && turn_affordances_require_tool_gate turn_affordances

let has_task_claim_affordance turn_affordances =
  List.exists
    (fun affordance ->
       match turn_affordance_of_string affordance with
       | Some Task_claim -> true
       | Some (Board_post_or_comment | Message_sweep | Task_audit) | None -> false)
    turn_affordances

let has_task_audit_affordance turn_affordances =
  List.exists
    (fun affordance ->
       match turn_affordance_of_string affordance with
       | Some Task_audit -> true
       | Some (Board_post_or_comment | Message_sweep | Task_claim) | None -> false)
    turn_affordances

let preferred_tool_choice_for_required_turn ~(has_current_task : bool)
    ~(turn_affordances : string list) ~(allowed_tool_names : string list) =
  if (not has_current_task)
     && has_task_claim_affordance turn_affordances
     && List.mem "keeper_task_claim" allowed_tool_names
  then Oas.Types.Tool "keeper_task_claim"
  else if (not has_current_task)
          && has_task_audit_affordance turn_affordances
          && List.mem "keeper_tasks_list" allowed_tool_names
  then Oas.Types.Tool "keeper_tasks_list"
  else Oas.Types.Any

let owned_active_task_id_for_meta ~(config : Coord.config)
    ~(meta : Keeper_types.keeper_meta) =
  match meta.current_task_id with
  | Some task_id -> Some task_id
  | None ->
    let actual_name =
      try Coord.resolve_agent_name config meta.agent_name
      with
      | Sys_error _ | Yojson.Json_error _ -> meta.agent_name
      | exn ->
        Log.Keeper.warn
          "keeper:%s resolve_agent_name failed while reconciling current task: %s"
          meta.name (Printexc.to_string exn);
        meta.agent_name
    in
    let matches assignee =
      String.equal assignee meta.agent_name || String.equal assignee actual_name
    in
    (try
       Coord.get_tasks_raw config
       |> List.find_map (fun (task : Types.task) ->
            match task.task_status with
            | Types.Claimed { assignee; _ }
            | Types.InProgress { assignee; _ }
            | Types.AwaitingVerification { assignee; _ }
              when matches assignee -> (
                match Keeper_id.Task_id.of_string task.id with
                | Ok task_id -> Some task_id
                | Error msg ->
                  Log.Keeper.warn
                    "keeper:%s owned task %s could not be parsed: %s"
                    meta.name task.id msg;
                  None)
            | Types.Claimed _
            | Types.InProgress _
            | Types.AwaitingVerification _
            | Types.Todo
            | Types.Done _
            | Types.Cancelled _ -> None)
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.warn
         "keeper:%s owned task reconciliation failed: %s"
         meta.name (Printexc.to_string exn);
       None)
;;

let merge_current_task_id ~(latest : Keeper_types.keeper_meta)
    ~(caller : Keeper_types.keeper_meta) =
  {
    latest with
    current_task_id = caller.current_task_id;
    updated_at = caller.updated_at;
  }
;;

let sync_current_task_id_from_backlog ~(config : Coord.config)
    (meta : Keeper_types.keeper_meta) =
  match meta.current_task_id with
  | Some _ -> meta
  | None -> (
    match owned_active_task_id_for_meta ~config ~meta with
    | None -> meta
    | Some task_id ->
      let updated_meta =
        {
          meta with
          current_task_id = Some task_id;
          updated_at = Types.now_iso ();
        }
      in
      Keeper_registry.update_meta ~base_path:config.base_path meta.name updated_meta;
      (match
         Keeper_types.write_meta_with_merge
           ~merge:merge_current_task_id config updated_meta
       with
       | Ok () -> ()
       | Error msg ->
         Log.Keeper.warn
           "keeper:%s failed to persist reconciled current_task_id=%s: %s"
           meta.name (Keeper_id.Task_id.to_string task_id) msg);
      Log.Keeper.info
        "keeper:%s reconciled current_task_id=%s from backlog ownership"
        meta.name (Keeper_id.Task_id.to_string task_id);
      updated_meta)
;;

let tool_names =
  List.map Tool_name.to_string

let fallback_floor_tool_names =
  tool_names
    Tool_name.[
      Keeper Context_status;
      Keeper Task_claim;
      Keeper Tasks_list;
      Keeper Board_list;
      Keeper Board_get;
    ]

let fallback_repo_probe_tool_names =
  tool_names Tool_name.[ Keeper Fs_read; Keeper Shell; Keeper Bash ]

let is_claim_tool_name name =
  Keeper_tool_disclosure.is_claim_tool_name name

let is_claim_context_tool_name name =
  Keeper_tool_disclosure.is_claim_context_tool_name name

(* Tool selection & disclosure — extracted to Keeper_tool_disclosure (#5732) *)

(* Deterministic selection floor size: keep the executable surface small
   enough for prompt budgets while still surfacing a handful of relevant
   tools even before any LLM hinting lands. *)
let keeper_selection_top_k = 10

(* BM25 candidate pool for TopK_llm: wide enough to give reranking room to
   improve results, but still bounded and deterministic. *)
let keeper_selection_bm25_prefilter_n = 30

let tool_index_entry_of_tool
    ~(korean_kw_tbl : (string, string) Hashtbl.t)
    (t : Oas.Tool.t) : Oas.Tool_index.entry =
  let name = t.schema.name in
  let group =
    Tool_catalog.tool_group name
    |> Option.map Tool_catalog.tool_group_to_string
  in
  let aliases =
    match Hashtbl.find_opt korean_kw_tbl name with
    | Some kw ->
        String.split_on_char ' ' kw
        |> List.filter (fun s -> s <> "")
    | None -> []
  in
  Oas.Tool_index.{ name; description = t.schema.description; group; aliases }

