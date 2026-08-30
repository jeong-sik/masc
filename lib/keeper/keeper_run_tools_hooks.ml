(* keeper_run_tools_hooks — hooks assembly for prepare_agent_setup.
   Extracted from keeper_run_tools.ml. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_agent_tool_surface
open Keeper_agent_result
open Keeper_agent_prompt_metrics

type hook_accumulator = Keeper_run_tools_hook_accumulator.hook_accumulator

type tool_observer_serialization = (unit -> unit) -> unit

let create_tool_observer_serialization () : tool_observer_serialization =
  let mutex = Eio.Mutex.create () in
  fun observe ->
    Eio.Mutex.lock mutex;
    (* The enclosing Agent-core hook reports a failed observer and continues.
       [use_rw] would poison the per-run mutex on that reported exception and
       reject every later completion. [Fun.protect] keeps the non-suspending
       unlock exception-safe without masking cancellation across the observer's
       file locks and durable writes. *)
    (* fun-protect-finally-ok: [Eio.Mutex.unlock] is non-suspending and releases
       only the observer-serialization mutex acquired immediately above. *)
    Fun.protect
      ~finally:(fun () -> Eio.Mutex.unlock mutex)
      observe
;;

type agent_setup =
  { tools : Agent_core.Tool.t list
  ; agent_core_tools : Agent_core.Tool.t list
  ; agent_cell : Agent_core.Agent.t option ref
        (** The cell the turn's tools captured, so the AGENT_CORE call site
            fills the one they read rather than a second one of its own. *)
  ; cleanup : unit -> unit
  ; terminal_effect_state : unit -> Keeper_tools_agent_core.terminal_effect_state
  ; user_message : string
  ; hooks : Agent_core.Hooks.hooks
  ; on_runtime_attempt : Keeper_turn_driver.runtime_attempt -> unit
  ; model_input_projection : Agent_core.Agent.model_input_projection
  ; stage_skill_delivery_on_wire :
      runtime_id:string ->
      agent_core_turn:int ->
      Agent_core.Types.message list ->
      unit
  ; observe_official_client_result_handoff :
      runtime_id:string ->
      invocation:Agent_core.Tool_contract.Invocation.t ->
      content:string ->
      unit
  ; observe_official_client_native_action :
      runtime_id:string -> official_turn:int ->
      identity:Runtime_native_tools.action_identity -> tool_name:string -> unit
  ; gate_replay_evidence : Keeper_gate_replay.model_evidence option
  ; acc : hook_accumulator
  ; all_tool_names : string list
  ; skill_projection_diagnostics : Keeper_skill_catalog.projection_diagnostic list
  ; final_agent_core_turn_ordinal_ref : int option ref
  ; receipt_turn_count_ref : int option ref
  ; receipt_model_used_ref : string option ref
  ; receipt_stop_reason_ref : Runtime_agent.stop_reason option ref
  ; receipt_runtime_observation_ref : Runtime_observation.runtime_observation option ref
  ; receipt_lane_attempt_index_ref : int ref
  ; receipt_response_text_present_ref : bool ref
  }

type ctx =
  { acc : hook_accumulator
  ; agent_cell : Agent_core.Agent.t option ref
  ; agent_name : string
  ; all_tool_names : string list
  ; compute_tool_surface :
      turn:int -> current_tool_choice:Agent_core.Types.tool_choice option -> unit ->
      string list * turn_lane
  ; record_tool_assignment :
      turn:int -> tool_list:string list -> lane:turn_lane -> unit
  ; config : Workspace.config
  ; keeper_tools_cleanup : unit -> unit
  ; terminal_effect_state : unit -> Keeper_tools_agent_core.terminal_effect_state
  ; keeper_turn_id : int
  ; turn_kind : Turn_record.turn_kind
  ; meta : Keeper_meta_contract.keeper_meta
  ; turn_ctx_cell : Keeper_tool_call_log.turn_ctx_cell
    (* RFC-0225 §3.3: per-run carrier; written by the pre-request hook
       below, read by the post-tool hooks in Keeper_hooks_agent_core. *)
  ; final_agent_core_turn_ordinal_ref : int option ref
  ; receipt_turn_count_ref : int option ref
  ; receipt_model_used_ref : string option ref
  ; receipt_stop_reason_ref : Runtime_agent.stop_reason option ref
  ; receipt_runtime_observation_ref : Runtime_observation.runtime_observation option ref
  ; receipt_lane_attempt_index_ref : int ref
  ; receipt_response_text_present_ref : bool ref
  ; on_runtime_attempt : Keeper_turn_driver.runtime_attempt -> unit
  ; tool_result_commit_required : unit -> bool
  ; on_tool_result_ready :
      (tool_call_id:string -> turn:int -> planned_index:int -> execution_id:Ids.Execution_id.t -> unit) option
  ; on_tool_stream_observation :
      (Keeper_hooks_agent_core.tool_stream_observation -> unit) option
  ; skill_activation_context : Keeper_skill_activation_recorder.t
  ; tools : Agent_core.Tool.t list
  ; agent_core_tools : Agent_core.Tool.t list
  }

let relax_strict_tool_choice_for_keeper = function
  | Some (Agent_core.Types.Any | Agent_core.Types.Tool _) ->
    Some Agent_core.Types.Auto
  | other -> other

let project_model_input ~base_path ~gate_replay_evidence messages =
  match gate_replay_evidence with
  | None -> Ok messages
  | Some evidence ->
    Keeper_gate_replay.project_model_input ~base_path evidence messages
;;

let trailing_tool_result_receipts messages =
  match List.rev messages with
  | { Agent_core.Types.role = Tool; content; _ } :: _ ->
    List.filter_map
      (function
        | Agent_core.Types.ToolResult { tool_use_id; content; _ } ->
          Some
            Keeper_skill_activation_ledger.
              { tool_use_id
              ; content_bytes = String.length content
              ; content_sha256 =
                  Digestif.SHA256.(digest_string content |> to_hex)
              }
        | Text _
        | Thinking _
        | ReasoningDetails _
        | RedactedThinking _
        | ToolUse _
        | Image _
        | Document _
        | Audio _ -> None)
      content
  | { role = (User | System | Assistant); _ } :: _
  | [] ->
    []
;;

module Skill_delivery_state = struct
  type staged =
    { runtime_id : string
    ; agent_core_turn : int
    ; tool_results : Keeper_skill_activation_ledger.tool_result_receipt list
    }

  type t =
    { mutable pending : staged option
    ; mutable active_skill_tool_use_ids : string list
      (* The delivery boundary's MASC agent-core turn. Native actions reported
         by official clients carry only a per-CLI-session counter, so the
         ledger comparison against [delivery.agent_core_turn] must reuse this
         value — the two counters share no axis (#31081 review P1). *)
    ; mutable active_agent_core_turn : int option
    }

  let create () =
    { pending = None
    ; active_skill_tool_use_ids = []
    ; active_agent_core_turn = None
    }
  ;;

  let clear state =
    state.pending <- None;
    state.active_skill_tool_use_ids <- [];
    state.active_agent_core_turn <- None
  ;;

  let begin_turn = clear
  let begin_runtime_attempt = clear

  let stage state ~runtime_id ~agent_core_turn tool_results =
    state.pending <- Some { runtime_id; agent_core_turn; tool_results }
  ;;

  let set_active state ~agent_core_turn ids =
    state.active_skill_tool_use_ids <- ids;
    state.active_agent_core_turn
    <- (match ids with
        | [] -> None
        | _ :: _ -> Some agent_core_turn)
  ;;

  let clear_active state =
    state.active_skill_tool_use_ids <- [];
    state.active_agent_core_turn <- None
  ;;

  let commit_model_response state ~agent_core_turn ~observe =
    match state.pending with
    | Some staged when staged.agent_core_turn = agent_core_turn ->
      state.pending <- None;
      set_active state ~agent_core_turn (observe staged)
    | Some _ | None -> ()
  ;;

  let active state = state.active_skill_tool_use_ids

  let active_delivery state =
    match state.active_skill_tool_use_ids, state.active_agent_core_turn with
    | (_ :: _ as ids), Some agent_core_turn -> Some (ids, agent_core_turn)
    | _, _ -> None
  ;;
end

let relative_path_has_segment_prefix prefix raw =
  String.equal raw prefix || String.starts_with ~prefix:(prefix ^ "/") raw
;;

(* "scratch" is gone: no code ever created that directory, and the tool schema
   that taught it ('repos/X' or 'scratch/X') is removed in this change. It only
   ever mattered for a path a model invented from that sentence.

   "repos" stays for now. Removing it changes how {file_path; cwd} pairs anchor
   — the enclosing function decides whether a relative path is already
   workspace-rooted or is relative to cwd, and it can only decide that from a
   fixed vocabulary. That is the same layout assumption this work removes
   elsewhere, so it needs the resolver the tools themselves use rather than a
   shorter list. Separate change. *)
let sandbox_rooted_relative_path raw =
  Filename.is_relative raw
  && List.exists
       (fun prefix -> relative_path_has_segment_prefix prefix raw)
       [ "repos"; Common.masc_dirname; "playground" ]
;;

let non_empty_string_member name input =
  match Yojson.Safe.Util.member name input with
  | `String raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then None else Some raw
  | _ -> None
;;

(* #23469 (task-1733 completion): keeper file tools resolve relative paths
   against the keeper's playground sandbox root ([keeper_default_read_root]),
   never against the server base path. The observation join mirrors that
   contract, otherwise the emitted partition describes a file the tool never
   touched: a sandbox-rooted [repos/<id>/…] edit used to be re-anchored at
   the server base path and attributed through whichever repository happened
   to be registered there, and a bare relative path with no [cwd] leaked
   through unanchored for the resolver to join at the base path. Every
   relative shape therefore anchors at [sandbox_root]; absolute paths pass
   through untouched, and a pathless tool call stays a keeper-timeline fact
   at [base_path]. *)
let observation_file_path_from_tool_input ~sandbox_root input =
  let under_sandbox p = Filename.concat sandbox_root p in
  match Tool_input_path.tool_input_file_path input with
  | None -> None
  | Some p when Filename.is_relative p ->
    Some
      (if sandbox_rooted_relative_path p
       then under_sandbox p
       else (
         match non_empty_string_member "cwd" input with
         | Some cwd when Filename.is_relative cwd ->
           under_sandbox (Filename.concat cwd p)
         | Some cwd -> Filename.concat cwd p
         | None -> under_sandbox p))
  | Some p -> Some p
;;

(* Returns where the tool fact belongs (RFC-0378 §5.1). A call that names
   no file is [Pathless] — a keeper-timeline fact with no document — and
   never touches the resolver; a call that names one gets the resolver's
   attribution, minted once here and carried as a parsed value. *)
let annotation_attribution_from_tool_input input =
  let codebase =
    match Yojson.Safe.Util.member "codebase" input with
    | `String value -> value
    | _ -> ""
  in
  let path =
    match Yojson.Safe.Util.member "file_path" input with
    | `String value -> value
    | _ -> ""
  in
  match Agent_observation.Code_address.v ~codebase ~path with
  | Ok address ->
    Agent_observation.File
      (Agent_observation.Addressed { address; checkout = None })
  | Error reason ->
    Agent_observation.File
      (Agent_observation.Unaddressed
         { reason = Agent_observation.Unattributed.Unmintable reason
         ; attempted_path = path
         })
;;

let observation_attribution_for_tool_input ?(tool_name = "") ~config ~meta input =
  if String.equal tool_name "keeper_ide_annotate"
  then annotation_attribution_from_tool_input input
  else
  let base_dir = Keeper_alerting_path.project_root_of_config config in
  let sandbox_root =
    Keeper_tool_shared_runtime.keeper_observation_sandbox_root ~config ~meta
  in
  match observation_file_path_from_tool_input ~sandbox_root input with
  | None -> Agent_observation.Pathless
  | Some visible ->
    let host_path =
      Keeper_tool_shared_runtime.keeper_observation_host_path_of_visible_path
        ~config
        ~meta
        visible
    in
    Agent_observation.File
      (Keeper_tool_filesystem_runtime.resolve_write_attribution
         ~base_dir
         ~file_path:host_path)
;;

let assemble_hooks
      ~(ctx : ctx)
      ~(session : Keeper_types.session_context)
      ~(turn_system_prompt : string)
      ~(user_message : string)
      ~(dynamic_context : string)
      ~(history_messages : Agent_core.Types.message list)
      ~(prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics)
      ~(shared_context : Agent_core.Context.t)
      ~(start_turn_count : int)
      ~(runtime_id_string : string)
      ~is_retry:(_ : bool)
      ~(config_root : string)
      ~(runtime_config_path : string option)
      ~(trajectory_acc : Trajectory.accumulator option)
      ~(skill_projection_diagnostics : Keeper_skill_catalog.projection_diagnostic list)
      ?gate_replay_evidence
      ?runtime_manifest_context
      ?runtime_manifest_append
      ()
  : (agent_setup, Agent_core.Error.t) result
  =
  let acc = ctx.acc in
  let compute_tool_surface = ctx.compute_tool_surface in
  let record_tool_assignment = ctx.record_tool_assignment in
  let config = ctx.config in
  let memory_os_keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Workspace.base_path
  in
  let keeper_tools_cleanup = ctx.keeper_tools_cleanup in
  let terminal_effect_state = ctx.terminal_effect_state in
  let keeper_turn_id = ctx.keeper_turn_id in
  let turn_kind = ctx.turn_kind in
  let meta = ctx.meta in
  let turn_ctx_cell = ctx.turn_ctx_cell in
  let final_agent_core_turn_ordinal_ref = ctx.final_agent_core_turn_ordinal_ref in
  let receipt_turn_count_ref = ctx.receipt_turn_count_ref in
  let receipt_model_used_ref = ctx.receipt_model_used_ref in
  let receipt_stop_reason_ref = ctx.receipt_stop_reason_ref in
  let receipt_runtime_observation_ref = ctx.receipt_runtime_observation_ref in
  let receipt_lane_attempt_index_ref = ctx.receipt_lane_attempt_index_ref in
  let receipt_response_text_present_ref = ctx.receipt_response_text_present_ref in
  let tools = ctx.tools in
  let turn_agent_cell = ctx.agent_cell in
  let all_tool_names = ctx.all_tool_names in
  let initial_schema_filter, initial_turn_lane =
    compute_tool_surface
      ~turn:(start_turn_count + 1)
      ~current_tool_choice:None
      ()
  in
  acc.tool_surface
  <- { turn_lane = initial_turn_lane
     ; config_root
     ; runtime_config_path
     };
  Keeper_run_tools_hook_accumulator.record_requested_tool_names
      acc
      initial_schema_filter;
    let meta_ref = ref acc.meta in
    (* Explicitly concurrent tools complete in sibling fibers. Their tool bodies
       stay concurrent, but the post-tool observer is one transaction: it
       refreshes [acc.meta], appends the receipt detail, derives the fallback
       turn identity, and emits the observation/activity pair. A per-run Eio
       mutex gives those effects one order without introducing a process-global
       gate or serializing tool execution itself. *)
    let serialize_tool_observer = create_tool_observer_serialization () in
    let skill_delivery_state = Skill_delivery_state.create () in
    let observe_skill_delivery ~runtime_id ~boundary tool_results =
      (* Every handoff is a new causal boundary. A failed ledger observation
         cannot leave ids from an older successful handoff active. *)
      Skill_delivery_state.clear_active skill_delivery_state;
      let boundary_agent_core_turn =
        match boundary with
        | Keeper_skill_activation_ledger.Model_response { agent_core_turn }
        | Keeper_skill_activation_ledger.Official_client_result_handoff
            { agent_core_turn } -> agent_core_turn
      in
      match
        Keeper_skill_activation_recorder.observe_delivery
          ~config
          ctx.skill_activation_context
          ~tool_results
          ~boundary
          ~runtime_id
      with
      | Ok delivered ->
        Skill_delivery_state.set_active
          skill_delivery_state
          ~agent_core_turn:boundary_agent_core_turn
          (List.sort_uniq String.compare delivered)
      | Error error ->
        Log.Keeper.warn
          "Skill delivery observation failed for keeper=%s error=%s"
          meta.name
          (Keeper_skill_activation_recorder.error_to_string error)
    in
    let stage_skill_delivery_on_wire ~runtime_id ~agent_core_turn messages =
      Skill_delivery_state.stage
        skill_delivery_state
        ~runtime_id
        ~agent_core_turn
        (trailing_tool_result_receipts messages)
    in
    let observe_official_client_result_handoff ~runtime_id ~invocation ~content =
      let tool_use_id =
        Agent_core.Tool_contract.Invocation.tool_use_id invocation
      in
      let agent_core_turn = Agent_core.Tool_contract.Invocation.turn invocation in
      let tool_results =
        [ Keeper_skill_activation_ledger.
            { tool_use_id
            ; content_bytes = String.length content
            ; content_sha256 =
                Digestif.SHA256.(digest_string content |> to_hex)
            }
        ]
      in
      observe_skill_delivery
        ~runtime_id
        ~boundary:
          (Keeper_skill_activation_ledger.Official_client_result_handoff
             { agent_core_turn })
        tool_results
    in
    let observe_official_client_native_action
          ~runtime_id ~official_turn ~identity ~tool_name =
      (* [official_turn] is the CLI's own per-session counter and shares no
         axis with the ledger's agent-core turns; it stays in log lines as
         provenance only. The ledger receives the delivery boundary's
         agent-core turn, which the delivery state carries alongside the
         active ids (#31081 review P1). *)
      match Skill_delivery_state.active_delivery skill_delivery_state with
      | None -> ()
      | Some (active_skill_tool_use_ids, agent_core_turn) ->
        (try
           match
             Keeper_skill_activation_recorder.observe_native_action
               ~config ctx.skill_activation_context ~active_skill_tool_use_ids
               ~runtime_id ~agent_core_turn ~identity ~tool_name
           with
           | Ok _ -> ()
           | Error error ->
             Log.Keeper.warn "Official native Skill action observation failed keeper=%s runtime=%s official_turn=%d tool=%s error=%s"
               meta.name runtime_id official_turn tool_name
               (Keeper_skill_activation_recorder.error_to_string error)
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           Log.Keeper.warn "Official native Skill action observer raised keeper=%s runtime=%s official_turn=%d tool=%s error=%s"
             meta.name runtime_id official_turn tool_name (Printexc.to_string exn))
    in
    let on_runtime_attempt attempt =
      (* An official-client handoff belongs only to the runtime that produced
         it. A failover candidate must receive the Skill result itself before
         one of its actions can complete that activation's evidence. *)
      Skill_delivery_state.begin_runtime_attempt skill_delivery_state;
      ctx.on_runtime_attempt attempt
    in
    let base_hooks =
      Keeper_hooks_agent_core.make_hooks
        ~config
        ~meta_ref
        ~turn_ctx_cell
        ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
        ~keeper_turn_id
        ~on_after_turn_ordinal:(fun turn -> final_agent_core_turn_ordinal_ref := Some turn)
        ?on_tool_stream_observation:ctx.on_tool_stream_observation
        ~on_after_turn_response:
          (fun ~response ->
             Keeper_run_tools_hook_accumulator.record_assistant_turn_text
               acc
               response)
        ~tool_result_commit_required:ctx.tool_result_commit_required
        ?on_tool_result_ready:ctx.on_tool_result_ready
        ?trajectory_acc
        ~on_tool_executed:
          (fun
            ~tool_name ~input ~output_text ~success ~duration_ms ~provider ~typed_outcome ->
            serialize_tool_observer (fun () ->
              let route_evidence =
                Keeper_tool_call_log.route_evidence_json_of_tool_io
                  ~tool_name
                  ~input
                  ~output_text
              in
              let progress_io_fingerprints =
                Keeper_tool_progress_identity.digest_tool_io
                  ~tool_name
                  ~input
                  ~output_text
              in
              (match Keeper_registry.get ~base_path:config.base_path meta.name with
               | Some entry ->
                 acc.meta <- entry.meta;
                 meta_ref := entry.meta
               | None -> ());
              let execution_outcome =
                if success then Tool_result.Ok else Tool_result.Error
              in
              let task_id =
                Keeper_run_tools_task_scope.task_id_scope_of_tool_call
                  ~tool_name
                  ~input
                  ~meta:acc.meta
              in
              acc.tool_calls
              <- { tool_name
                 ; provider
                 ; execution_outcome
                 ; typed_outcome
                 ; latency_ms = duration_ms
                 ; task_id
                 ; route_evidence
                 ; input_fingerprint =
                     Option.map
                       (fun (d : Keeper_tool_progress_identity.io_fingerprints) ->
                          d.input_fingerprint)
                       progress_io_fingerprints
                 ; output_fingerprint =
                     Option.map
                       (fun (d : Keeper_tool_progress_identity.io_fingerprints) ->
                          d.output_fingerprint)
                       progress_io_fingerprints
                 }
                 :: acc.tool_calls;
              (* Emit neutral agent observation events; UI adapters subscribe separately. *)
              (let typed_outcome_str =
                 match typed_outcome with
                 | Some Keeper_tool_outcome.Progress -> "progress"
                 | Some (Keeper_tool_outcome.No_progress _) -> "no_progress"
                 | Some (Keeper_tool_outcome.Error _) -> "error"
                 | None -> Tool_result.string_of_tool_call_outcome execution_outcome
               in
               let turn_id =
                 match acc.meta.Keeper_meta_contract.current_task_id with
                 | Some t -> Keeper_id.Task_id.to_string t
                 | None -> "turn-" ^ string_of_int (List.length acc.tool_calls)
               in
               (* task-1733: attribute from the tool's actual edited file
                  (input.path / input.file_path, with explicit cwd honoured
                  for relative paths), not from the [.masc] runtime root.
                  #23469: relative shapes anchor at this keeper's playground
                  sandbox root, matching the file tools' own resolution. *)
               let attribution =
                 observation_attribution_for_tool_input
                   ~tool_name
                   ~config
                   ~meta:acc.meta
                   input
               in
               Agent_observation.emit_tool_event
                 { base_path = config.base_path
                 ; attribution
                 ; tool_name
                 ; keeper_id = acc.meta.name
                 ; turn_id
                 ; outcome = Tool_result.string_of_tool_call_outcome execution_outcome
                 ; typed_outcome = typed_outcome_str
                 ; duration_ms
                 ; output_text
                 ; input
                 };
               (* #23540: keeper in-turn tool executions never reached the
                  activity log ([tool.called] is emitted only by the external MCP
                  path), so the agent timeline reported tool_calls = 0 for any
                  keeper working through its own turn. *)
               Keeper_tool_activity.emit_tool_exec
                 ~config
                 ~meta:acc.meta
                 ~tool_name
                 ~success
                 ~duration_ms:(int_of_float (Float.round duration_ms))
                 ~typed_outcome
                 ~provider
                 ~keeper_turn_id:(Some keeper_turn_id)
                 ~agent_core_turn:acc.current_turn
                 ~task_id
                 ())))
        ()
    in
    let before_turn_hook : Agent_core.Hooks.hooks =
      { Agent_core.Hooks.empty with
        after_turn =
          Some
            (fun event ->
              match event with
              | Agent_core.Hooks.AfterTurn { turn; _ } ->
                Skill_delivery_state.commit_model_response
                  skill_delivery_state
                  ~agent_core_turn:turn
                  ~observe:(fun staged ->
                    observe_skill_delivery
                      ~runtime_id:staged.runtime_id
                      ~boundary:
                        (Keeper_skill_activation_ledger.Model_response
                           { agent_core_turn = turn })
                      staged.tool_results;
                    Skill_delivery_state.active skill_delivery_state);
                Agent_core.Hooks.Continue
              | Agent_core.Hooks.BeforeTurn _
              | BeforeTurnParams _
              | PreToolUse _
              | PostToolUse _
              | PostToolUseFailure _
              | OnStop _
              | OnError _
              | OnToolError _ -> Agent_core.Hooks.Continue)
      ;
        pre_tool_use =
          Some
            (fun event ->
              match event with
              | Agent_core.Hooks.PreToolUse { invocation; tool_name; _ }
                when not
                       (String.equal
                          tool_name
                          Keeper_tool_composition_catalog.skill_tool_name) ->
                if Skill_delivery_state.active skill_delivery_state <> []
                then
                  (match
                     Keeper_skill_activation_recorder.observe_action
                       ~config
                       ctx.skill_activation_context
                       ~active_skill_tool_use_ids:
                         (Skill_delivery_state.active skill_delivery_state)
                       ~invocation
                       ~tool_name
                   with
                   | Ok _ -> ()
                   | Error error ->
                     Log.Keeper.warn
                       "Skill action observation failed for keeper=%s tool=%s error=%s"
                       meta.name
                       tool_name
                       (Keeper_skill_activation_recorder.error_to_string error));
                Agent_core.Hooks.Continue
              | Agent_core.Hooks.PreToolUse _
              | BeforeTurn _
              | BeforeTurnParams _
              | AfterTurn _
              | PostToolUse _
              | PostToolUseFailure _
              | OnStop _
              | OnError _
              | OnToolError _ ->
                Agent_core.Hooks.Continue)
      ;
        before_turn_params =
          Some
            (fun event ->
              match event with
              | Agent_core.Hooks.BeforeTurnParams
                  { turn; current_params; messages; last_tool_results; _ } ->
                let hook_t0 = Time_compat.now () in
                acc.current_turn <- turn;
                (* A delivered Skill can only inform tool choices made from this
                   exact provider request. Do not carry causal candidates into a
                   later Agent Core turn. *)
                Skill_delivery_state.begin_turn skill_delivery_state;
                (* Reset the in-turn FSM before this hook writes the next agent-core
                   turn's runtime, policy, and prompt phases. *)
                Keeper_registry.mark_agent_core_turn_started
                  ~base_path:config.base_path
                  meta.name;
                let runtime_seed =
                  Runtime_inference.for_runtime ~name:runtime_id_string
                in
                let current_params =
                  { current_params with
                    thinking_budget =
                      (match runtime_seed.thinking_budget with
                       | Some _ as configured -> configured
                       | None -> current_params.thinking_budget)
                  ; enable_thinking =
                      (match runtime_seed.thinking_enabled with
                       | Some enabled -> Some enabled
                       | None -> current_params.enable_thinking)
                  ; preserve_thinking =
                      (match runtime_seed.preserve_thinking with
                       | Some preserve -> Some preserve
                       | None -> current_params.preserve_thinking)
                  }
                in
                (* RFC-0233 PR-3: every append below also records its
                   (block id, raw text) pair; the snapshot lands in the
                   hook accumulator just before AdjustParams so the
                   receipt/TurnRecord writer can persist typed
                   provenance. The closed Prompt_block_id sum makes a
                   new injection site without a recording a compile
                   error at the snapshot below. *)
                let recorded_blocks = ref [] in
                let record_block block text =
                  recorded_blocks := (block, text) :: !recorded_blocks
                in
                (* A round that follows tool results must read to the model as
                   "the tools returned", not "someone spoke again": the
                   assembly rides the wire as a trailing User-role message,
                   and re-broadcasting the world state there made models
                   re-answer it on every round of a tool loop (task-514,
                   2026-08-24 one keeper — 36 single-call rounds restating one
                   answer). Which blocks still ride a post-tool round is the
                   typed declaration [Prompt_block_id.injected_on_post_tool_round];
                   the filter sits at assembly below so a new recording site
                   cannot bypass it.

                   The predicate is the position of the conversation's last
                   message, not [last_tool_results]: that hook payload reports
                   the last Tool message anywhere in history, so it is
                   non-empty for almost every turn of a keeper that has ever
                   used a tool, and gating on it suppressed the world state on
                   the first round of ordinary turns (live: one keeper's turn 15,
                   2026-08-24 08:08Z). *)
                let post_tool_round =
                  (* [ends_with_tool_results] answers a question about the
                     replayed history, not about this turn. A keeper whose
                     previous turn ended on a tool result — the ordinary way a
                     turn ends — starts its next one with exactly that shape,
                     so the world state was filtered out of the first round of
                     every such turn: 39 of 108 turns on 2026-08-25, the same
                     keeper carrying it on some turns and not others.

                     The accumulator is built once per keeper turn and its
                     block list is empty until this turn's first assembly, so
                     it says the part the history cannot: whether anything has
                     been injected yet on this turn. *)
                  Keeper_run_prompt.is_later_round_of_this_turn
                    ~injected_this_turn:(acc.prompt_blocks <> [])
                    messages
                in
                (if String.trim dynamic_context <> ""
                 then
                   record_block Prompt_block_id.Dynamic_context dynamic_context);
                (match Masc_context_injector.render_temporal_summary shared_context with
                 | None -> ()
                 | Some temporal ->
                   record_block Prompt_block_id.Temporal_summary temporal);
                let schema_filter, computed_turn_lane =
                  compute_tool_surface
                    ~turn
                    ~current_tool_choice:current_params.tool_choice
                    ()
                in
                (if not post_tool_round
                 then
                   match
                     (* Memory OS recall — advisory block rendered from every
                        persisted current fact in stored order (read side; the
                        write side is the librarian current-selection pass).
                        Opt-in via MASC_KEEPER_MEMORY_OS_RECALL. The read is
                        skipped, not just filtered, on post-tool rounds: the
                        block would be dropped at assembly anyway and the file
                        I/O is per round. *)
                     (* Off-main: recall reads the current snapshot via synchronous
                        file I/O, which would starve the main Eio domain and HOL
                        sibling keepers. Read-side only, no module-level mutable
                        state, so it is domain-safe on the shared pool. *)
                     Domain_pool_ref.submit_io_or_inline (fun () ->
                       Keeper_memory_os_recall.render_if_enabled
                         ~keepers_dir:memory_os_keepers_dir
                         ~keeper_id:meta.name
                         ~now:(Time_compat.now ())
                         ())
                   with
                   | None -> ()
                   | Some block -> record_block Prompt_block_id.Memory_os_recall block);
                (* RFC-0366: last in assembly order. It is the most recent fact
                   the keeper has, and when it disagrees with an earlier block
                   the later text is the one that reads as current. Stamped
                   consumed only after the block is assembled, so a turn that
                   fails before this point does not burn the note. *)
                let consumed_operator_note =
                  match Keeper_operator_note.pending ~config ~keeper:meta.name with
                  | None -> false
                  | Some note ->
                    (match Keeper_operator_note.render note with
                     | None -> false
                     | Some block ->
                       record_block Prompt_block_id.Operator_note block;
                       true)
                in
                let turn_blocks =
                  let blocks = List.rev !recorded_blocks in
                  if post_tool_round
                  then
                    List.filter
                      (fun (block, _) ->
                         Prompt_block_id.injected_on_post_tool_round block)
                      blocks
                  else blocks
                in
                let extra_system_context_assembly =
                  Keeper_run_prompt.assemble_extra_system_context
                    ~existing_extra_system_context:
                      current_params.extra_system_context
                    ~blocks:turn_blocks
                in
                let ctx = extra_system_context_assembly.extra_system_context in
                let recorded_blocks_for_receipt =
                  extra_system_context_assembly.blocks
                in
                (* The assembled text exists only here. The turn record keeps
                   each block's bytes and digest, which answers "how much" but
                   never "what", so an operator asking what this keeper is being
                   told had no answer short of the provider's wire log. Capture
                   overwrites one file per keeper: the blocks are stable turn to
                   turn, so the turn that just assembled is what the next one
                   will assemble, and keeping only the last bounds the store. *)
                (* An empty post-tool assembly is not an injection: writing it
                   would overwrite the first-round capture — the one that says
                   what this keeper was actually told — with nothing. *)
                (if recorded_blocks_for_receipt <> []
                 then
                   Keeper_prompt_capture.write
                     ~config
                     ~keeper:meta.name
                     ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                     (* [turn] is the cumulative AGENT_CORE provider round.
                        The TurnRecord join key uses the admitted keeper turn,
                        which is stable across every provider round in this
                        run. Stamping the provider round here made one request
                        read as #721 in last-prompt and #13 in turn-records. *)
                     ~absolute_turn:keeper_turn_id
                     ~blocks:recorded_blocks_for_receipt
                     ~assembled:ctx);
                if consumed_operator_note
                then
                  Keeper_operator_note.mark_consumed
                    ~config
                    ~keeper:meta.name
                    ~absolute_turn:keeper_turn_id;
                (* AGENT_CORE treats [None] in AdjustParams as "keep the base
                   config", so strict choices must be explicitly relaxed.
                   Tools remain available, but the model may finish without
                   another forced tool call. *)
                let tool_choice =
                  relax_strict_tool_choice_for_keeper current_params.tool_choice
                in
                let lane = computed_turn_lane in
                record_tool_assignment ~turn ~tool_list:schema_filter ~lane;
                Keeper_run_tools_hook_accumulator.record_requested_tool_names
                  acc
                  schema_filter;
                acc.tool_surface
                <- { turn_lane = lane
                   ; config_root
                   ; runtime_config_path
                   };
                let thinking_enabled_effective =
                  match current_params.enable_thinking with
                  | Some b -> b
                  | None -> Keeper_config.keeper_enable_thinking ()
                in
                Keeper_tool_call_log.set_turn_context
                  ~cell:turn_ctx_cell
                  ~agent_name:meta.name
                  ~turn_kind
                  ~lane:
                    (Keeper_agent_tool_surface.turn_lane_to_string lane)
                  ?tool_choice:
                    (Option.map
                       (fun choice ->
                          Yojson.Safe.to_string
                            (Agent_core.Types.tool_choice_to_json choice))
                       tool_choice)
                  ~thinking_enabled:thinking_enabled_effective
                  ?thinking_budget:current_params.thinking_budget
                  ~prompt_fingerprint:prompt_metrics.fingerprint
                  ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                  ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                  ~turn
                  ~keeper_turn_id
                  ?task_id:
                    (Option.map Keeper_id.Task_id.to_string acc.meta.current_task_id)
                  ~sandbox_profile:
                    (Keeper_types_profile_sandbox.sandbox_profile_to_string meta.sandbox_profile)
                  ~sandbox_root:
                    (Keeper_sandbox.keeper_visible_root_abs_of_meta ~config meta)
                  ~sandbox_roots:(Keeper_alerting_path.sandbox_roots ~meta)
                  ~network_mode:(Keeper_types_profile_sandbox.network_mode_to_string meta.network_mode)
                  ~runtime_profile:runtime_id_string
                  ();
                (ignore hook_t0;
                 Keeper_registry.set_turn_decision_stage
                   ~base_path:config.base_path
                   meta.name
                   Keeper_registry.Decision_active_tool_policy_selected;
                 Keeper_registry.set_turn_phase
                   ~base_path:config.base_path
                   meta.name
                   (Keeper_registry.Packed Keeper_registry.Turn_routing);
                 (* Spec atomic group: SelectToolPolicy(idle->selecting)
                   is immediately followed by RuntimeTrying(selecting->
                   trying).  Both transitions are materialised inside
                   the disclosure hook because the spec invariant
                   [SelectingRequiresToolPolicy] requires
                   [decision_stage = Decision_tool_policy_selected],
                   which is only set at this site.  Pre-PR #14153 the
                   Runtime_trying marking lived inside
                   [Keeper_unified_turn.retry_loop] (line 1138 era),
                   producing an [idle -> trying] jump that bypassed
                   selecting; the move here closes that gap by keeping
                   the two transitions adjacent.  On retry attempts
                   the prior runtime state is [Runtime_trying]; the
                   re-entry sequence becomes [trying -> selecting ->
                   trying] which is admitted by
                   [validate_runtime_transition]. *)
                 Keeper_registry.mark_turn_provider_attempt_started
                   ~base_path:config.base_path
                   meta.name);
                (* RFC-0233 PR-3 + #20936: snapshot this agent-core turn's
                   assembly into the accumulator the receipt/TurnRecord
                   writer reads. Appended blocks hash their raw appended
                   text; Keeper instructions reuse the prompt-metrics fingerprint
                   (sha256 of the sanitized rendered system prompt) —
                   the digest the prompt store already records. *)
                let sha256_hex text =
                  Digestif.SHA256.(digest_string text |> to_hex)
                in
                let keeper_instruction_blocks =
                  match prompt_metrics.system_prompt_segment.fingerprint with
                  | Some digest ->
                    [ { Turn_record.block = Prompt_block_id.Keeper_instructions
                      ; bytes = prompt_metrics.system_prompt_segment.bytes
                      ; digest
                      }
                    ]
                  | None -> []
                in
                acc.prompt_blocks
                <- keeper_instruction_blocks
                   @ List.map
                       (fun (block, text) ->
                          { Turn_record.block
                          ; bytes = String.length text
                          ; digest = sha256_hex text
                          })
                       recorded_blocks_for_receipt;
                acc.extra_system_context_digest <- Option.map sha256_hex ctx;
                acc.extra_system_context_size <- Option.map String.length ctx;
                (match runtime_manifest_context, runtime_manifest_append with
                 | Some manifest_context, Some append_manifest ->
                   let post_tool_context = post_tool_round in
                   append_manifest
                     (Keeper_runtime_manifest.make_for_context
                        manifest_context
                        ~event:Keeper_runtime_manifest.Context_injected
                        ~agent_core_turn_count:turn
                        ~runtime_id:runtime_id_string
                        ~status:
                          (if post_tool_context
                           then "post_tool_context_injection"
                           else "pre_tool_context_injection")
                        ~decision:
                          (Keeper_runtime_manifest.with_payload_role
                             ~payload_role:Keeper_runtime_manifest.Model_input
                             (`Assoc
                               [ ( "agent_core_turn", `Int turn )
                               ; ( "post_tool_context_injection",
                                   `Bool post_tool_context )
                               ; ( "last_tool_result_count",
                                   `Int (List.length last_tool_results) )
                               ; ( "prompt_block_count",
                                   `Int (List.length acc.prompt_blocks) )
                               ; ( "extra_system_context_digest",
                                   Json_util.string_opt_to_json
                                     acc.extra_system_context_digest )
                               ; ( "extra_system_context_computed_size",
                                   Json_util.int_opt_to_json
                                     acc.extra_system_context_size )
                               ]))
                        ())
                 | _ -> ());
                (* Phase O observability: capture the effective AGENT_CORE request
                   boundary after keeper-owned context injection has finalized
                   [extra_system_context]. *)
                Keeper_wire_capture.capture_request
                  ~base_path:config.base_path
                  ~masc_root:(Workspace.masc_root_dir config)
                  ~keeper_name:meta.name
                  ~turn_id:keeper_turn_id
                  ~trace_id:meta.runtime.trace_id
                  ~agent_core_turn:turn
                  ~system_prompt:turn_system_prompt
                  ~extra_system_context:ctx
                  ~user_message
                  ~history_messages:messages
                  ~tools:
                    (Keeper_agent_tool_surface.on_the_wire
                       ~agent_cell:turn_agent_cell
                       ~built:tools)
                  ();
                Eio.Fiber.yield ();
                Agent_core.Hooks.AdjustParams
                  { current_params with
                    extra_system_context = ctx
                  ; tool_choice
                  }
              | _event -> Agent_core.Hooks.Continue)
      }
    in
    let hooks = Agent_core.Hooks.compose ~outer:before_turn_hook ~inner:base_hooks in
    let model_input_projection messages =
      (* Stored Tool results are already the canonical provider-bound
         representation. Fetching their bytes here would undo externalization
         and make one large result expand every later provider request. *)
      project_model_input
        ~base_path:ctx.config.base_path
        ~gate_replay_evidence
        messages
    in
    Ok
      { tools
      ; agent_core_tools = ctx.agent_core_tools
      ; agent_cell = ctx.agent_cell
      ; cleanup = keeper_tools_cleanup
      ; terminal_effect_state
      ; user_message
      ; hooks
      ; on_runtime_attempt
      ; model_input_projection
      ; stage_skill_delivery_on_wire
      ; observe_official_client_result_handoff
      ; observe_official_client_native_action
      ; gate_replay_evidence
      ; acc
      ; all_tool_names
      ; skill_projection_diagnostics
      ; final_agent_core_turn_ordinal_ref
      ; receipt_turn_count_ref
      ; receipt_model_used_ref
      ; receipt_stop_reason_ref
      ; receipt_runtime_observation_ref
      ; receipt_lane_attempt_index_ref
      ; receipt_response_text_present_ref
      }
;;
