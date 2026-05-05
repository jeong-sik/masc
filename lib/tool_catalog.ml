module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_catalog — Visibility and lifecycle metadata for MCP tools.

    Central registry for tool access control:
    - Visibility: Default (public) vs Hidden (internal-only)
    - Lifecycle: Active, Deprecated, Placeholder
    - Surface: Canonical per-surface tool name membership SSOT

    Sub-modules (private):
    - Tool_catalog_surfaces: surface type, canonical tool lists, keeper-internal

    @since 2.188.0 — Decomposed from monolithic tool_catalog.ml *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type visibility =
  | Default
  | Hidden

type lifecycle =
  | Active
  | Deprecated

type implementation_status =
  | Real
  | Adapter
  | Simulation
  | Placeholder

type effect_domain =
  | Read_only
  | Masc_coordination
  | Playground_write
  | Main_worktree_write

type tool_group =
  | Board
  | Knowledge
  | Tasks
  | Voice
  | Filesystem
  | Masc_board
  | Masc_keeper
  | Masc_plan
  | Masc_worktree
  | Masc_code
  | Masc_autoresearch
  | Masc_agent
  | Masc_core

include (Tool_catalog_surfaces : sig
  type surface = Tool_catalog_surfaces.surface =
    | Public_mcp | Spawned_agent | Local_worker | Session_min
    | Admin | Keeper_internal | Keeper_denied | System_internal
end)

type metadata = {
  visibility : visibility;
  lifecycle : lifecycle;
  implementation_status : implementation_status;
  canonical_name : string option;
  replacement : string option;
  reason : string option;
  allow_direct_call_when_hidden : bool;
  readonly : bool option;
  destructive : bool option;
  idempotent : bool option;
  required_permission : Masc_domain.permission option;
  effect_domain : effect_domain option;
  requires_actor_binding : bool option;
}

(* ================================================================ *)
(* Metadata constructors                                            *)
(* ================================================================ *)

let default_metadata =
  {
    visibility = Default;
    lifecycle = Active;
    implementation_status = Real;
    canonical_name = None;
    replacement = None;
    reason = None;
    allow_direct_call_when_hidden = false;
    readonly = None;
    destructive = None;
    idempotent = None;
    required_permission = None;
    effect_domain = None;
    requires_actor_binding = None;
  }

(* Runtime-readable like MASC_FULL_SURFACE so tests and local admin flows can
   toggle placeholder exposure without restarting the server. Keep the legacy
   exact-match semantics for "false"/"0" so existing deployments do not change
   behavior when they use other spellings. *)
let placeholder_tools_enabled () =
  match Sys.getenv_opt "MASC_PLACEHOLDER_TOOLS_ENABLED" with
  | Some "false" | Some "0" -> false
  | _ -> true

let deprecated ?canonical_name ?replacement ?(allow_direct_call_when_hidden = false)
    ?(implementation_status = Adapter) reason =
  {
    visibility = Hidden;
    lifecycle = Deprecated;
    implementation_status;
    canonical_name;
    replacement;
    reason = Some reason;
    allow_direct_call_when_hidden;
    readonly = None;
    destructive = None;
    idempotent = None;
    required_permission = None;
    effect_domain = None;
    requires_actor_binding = None;
  }

let hidden_active ?canonical_name ?replacement ?(allow_direct_call_when_hidden = true)
    ?(implementation_status = Real) reason =
  {
    visibility = Hidden;
    lifecycle = Active;
    implementation_status;
    canonical_name;
    replacement;
    reason = Some reason;
    allow_direct_call_when_hidden;
    readonly = None;
    destructive = None;
    idempotent = None;
    required_permission = None;
    effect_domain = None;
    requires_actor_binding = None;
  }

let with_semantic_flags ?readonly ?destructive ?idempotent ?effect_domain
    ?requires_actor_binding meta =
  {
    meta with
    readonly =
      (match readonly with Some value -> Some value | None -> meta.readonly);
    destructive =
      (match destructive with Some value -> Some value | None -> meta.destructive);
    idempotent =
      (match idempotent with Some value -> Some value | None -> meta.idempotent);
    effect_domain =
      (match effect_domain with
      | Some value -> Some value
      | None -> meta.effect_domain);
    requires_actor_binding =
      (match requires_actor_binding with
      | Some value -> Some value
      | None -> meta.requires_actor_binding);
  }

let readonly_tool =
  with_semantic_flags ~readonly:true ~idempotent:true
    ~effect_domain:Read_only default_metadata

let destructive_tool =
  with_semantic_flags ~destructive:true default_metadata

let masc_coordination_tool =
  with_semantic_flags ~effect_domain:Masc_coordination default_metadata

let actor_bound_masc_coordination_tool =
  with_semantic_flags ~requires_actor_binding:true masc_coordination_tool

(* ================================================================ *)
(* Explicit metadata registry                                       *)
(* ================================================================ *)

let explicit_metadata : (string * metadata) list =
  [
    ( "masc_operator_judgment_write",
      hidden_active
        "Internal operator-judge write path hidden from the default tool list; use for operator judgment experiments and keeper automation." );
    (* Physically removed: masc_interrupt, masc_approve, masc_reject,
       masc_pending_interrupts, masc_branch (masc-checkpoint CLI removed,
       #4709/#4734), operator_judgment_latest, hat_wear, hat_status,
       encryption_*, generate_key, tempo*, cost_log, cost_report (#4709/#4757). *)
    (* Semantic annotations for governance risk classification. *)
    ("masc_status", readonly_tool);
    ("masc_tasks", readonly_tool);
    ("masc_messages", readonly_tool);
    ("masc_who", readonly_tool);
    ("masc_agents", readonly_tool);
    ( "masc_agent_card",
      { readonly_tool with required_permission = Some Masc_domain.CanReadState } );
    ("masc_dashboard", readonly_tool);
    ("masc_board_list", readonly_tool);
    ("masc_board_get", readonly_tool);
    ("masc_tool_help", readonly_tool);
    ("masc_keeper_list", readonly_tool);
    ("masc_keeper_status", readonly_tool);
    ("masc_keeper_persona_audit", readonly_tool);
    ("masc_plan_get", readonly_tool);
    ("masc_worktree_list", readonly_tool);
    ( "masc_join",
      { actor_bound_masc_coordination_tool with required_permission = Some Masc_domain.CanJoin } );
    ( "masc_leave",
      { actor_bound_masc_coordination_tool with required_permission = Some Masc_domain.CanLeave } );
    ("masc_claim_next", actor_bound_masc_coordination_tool);
    ("masc_transition", actor_bound_masc_coordination_tool);
    ("masc_plan_set_task", actor_bound_masc_coordination_tool);
    ( "masc_broadcast",
      { masc_coordination_tool with required_permission = Some Masc_domain.CanBroadcast } );
    ( "masc_messages",
      { readonly_tool with required_permission = Some Masc_domain.CanReadState } );
    ( "masc_who",
      { readonly_tool with required_permission = Some Masc_domain.CanReadState } );
    ( "channel_gate",
      { masc_coordination_tool with required_permission = Some Masc_domain.CanBroadcast } );
    ( "masc_portal_open",
      { masc_coordination_tool with required_permission = Some Masc_domain.CanOpenPortal } );
    ( "masc_portal_close",
      { masc_coordination_tool with required_permission = Some Masc_domain.CanOpenPortal } );
    ( "masc_portal_send",
      { masc_coordination_tool with required_permission = Some Masc_domain.CanSendPortal } );
    ( "masc_room_status",
      hidden_active ~canonical_name:"masc_status" ~replacement:"masc_status"
        "Managed-agent compatibility alias. Prefer masc_status for canonical namespace state reads." );
    ( "masc_list_tasks",
      hidden_active ~canonical_name:"masc_tasks" ~replacement:"masc_tasks"
        "Managed-agent compatibility alias. Prefer masc_tasks for canonical backlog reads." );
    ( "masc_claim_task",
      hidden_active ~canonical_name:"masc_transition" ~replacement:"masc_transition"
        "Managed-agent compatibility alias for masc_transition(action=claim)." );
    ( "masc_set_current_task",
      hidden_active ~canonical_name:"masc_plan_set_task" ~replacement:"masc_plan_set_task"
        "Managed-agent compatibility alias that binds current_task. Prefer masc_plan_set_task." );
    ( "masc_complete_task",
      hidden_active ~canonical_name:"masc_transition" ~replacement:"masc_transition"
        "Managed-agent compatibility alias for masc_transition(action=done)." );
    ( "masc_release_task",
      hidden_active ~canonical_name:"masc_transition" ~replacement:"masc_transition"
        "Managed-agent compatibility alias for masc_transition(action=release)." );
    ( "masc_cancel_task",
      hidden_active ~canonical_name:"masc_transition" ~replacement:"masc_transition"
        "Managed-agent compatibility alias for masc_transition(action=cancel)." );
    (* masc_run_get, masc_run_list: migrated to Tool_spec.register (tool_run.ml) *)
    ("masc_execute_dry_run", readonly_tool);
    ( "masc_admin_cleanup",
      with_semantic_flags ~destructive:true
        (hidden_active "Administrative cleanup mutates persisted namespace state and should be treated as destructive.") );
    ( "masc_admin_reset",
      with_semantic_flags ~destructive:true
        (hidden_active "Administrative reset clears namespace state and should be treated as destructive.") );
    ( "masc_gc_force",
      with_semantic_flags ~destructive:true
        (hidden_active "Forced garbage collection removes persisted artifacts and should be treated as destructive.") );
    ( "masc_room_delete",
      with_semantic_flags ~destructive:true
        (hidden_active "Namespace deletion removes persisted state and should be treated as destructive.") );
    ( "masc_force_leave",
      with_semantic_flags ~destructive:true
        (hidden_active "Forced membership removal mutates namespace state and should be treated as destructive.") );
    ( "masc_operator_action",
      with_semantic_flags ~destructive:true
        (hidden_active "Operator actions can execute privileged side effects and should be treated as destructive.") );
    ( "masc_set_param",
      {
        (with_semantic_flags ~destructive:true
           (hidden_active
              "Internal HTTP runtime-parameter mutation route; hidden from the public tool surface."))
        with
        required_permission = Some Masc_domain.CanAdmin;
      } );
    ( "masc_execute",
      with_semantic_flags ~destructive:true
        (hidden_active "Direct execution can apply privileged side effects and should be treated as destructive.") );
    ("masc_tool_grant", destructive_tool);
    ("masc_tool_revoke", destructive_tool);
    ( "masc_keeper_reset",
      { masc_coordination_tool with required_permission = Some Masc_domain.CanBroadcast } );
    ( "masc_keeper_compact",
      { masc_coordination_tool with required_permission = Some Masc_domain.CanBroadcast } );
    ( "masc_keeper_clear",
      with_semantic_flags ~destructive:true
        { masc_coordination_tool with required_permission = Some Masc_domain.CanBroadcast } );
    ( "masc_operation_stop",
      destructive_tool );
    ( "masc_operation_pause",
      { default_metadata with destructive = Some false } );
    (* WebRTC tools: deprecated as MCP tools but still used as HTTP
       signaling endpoints in server_h2_gateway.ml — kept for now. *)
    ("masc_webrtc_offer", deprecated "Pruned from all surfaces in #4999");
    ("masc_webrtc_answer", deprecated "Pruned from all surfaces in #4999");
  ]

(* ================================================================ *)
(* Runtime metadata table (O(1) lookup, seeded from explicit list)  *)
(* ================================================================ *)

let metadata_table : (string, metadata) Hashtbl.t = Hashtbl.create 256
let () = List.iter (fun (n, m) -> Hashtbl.replace metadata_table n m) explicit_metadata

let register_metadata name (meta : metadata) =
  Hashtbl.replace metadata_table name meta

let registered_metadata name =
  Hashtbl.find_opt metadata_table name

(* ================================================================ *)
(* Public MCP surface — delegates to Tool_catalog_surfaces (SSOT)   *)
(* ================================================================ *)

(* Delegate to surfaces sub-module *)
let keeper_internal_set = Tool_catalog_surfaces.keeper_internal_tools

let keeper_internal_replacement = Tool_catalog_surfaces.keeper_internal_replacement

let public_mcp_tools = Tool_catalog_surfaces.public_mcp_surface_tools

let keeper_internal_metadata name =
  let replacement = keeper_internal_replacement name in
  let implementation_status =
    match replacement with
    | Some _ -> Adapter
    | None -> Real
  in
  let meta =
    hidden_active
    ?canonical_name:replacement
    ?replacement
    ~allow_direct_call_when_hidden:false
    ~implementation_status
    "Keeper-internal tool. Use the keeper runtime or the public MASC equivalent when available."
  in
  {
    meta with
    required_permission = Some Masc_domain.CanBroadcast;
    requires_actor_binding = Some true;
  }

let public_mcp_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create 64 in
  List.iter (fun name -> Hashtbl.replace tbl name ())
    Tool_catalog_surfaces.public_mcp_surface_tools;
  (* MASC_PUBLIC_TOOLS_EXTRA: comma-separated tool names to add at runtime.
     Example: MASC_PUBLIC_TOOLS_EXTRA=masc_board_search,masc_pause *)
  (match Env_config.Tools.public_tools_extra_opt () with
   | Some raw ->
       String.split_on_char ',' raw
       |> List.iter (fun s ->
              let name = String.trim s in
              if not (String.equal name "") then Hashtbl.replace tbl name ())
   | None -> ());
  tbl

let is_public_mcp name = Hashtbl.mem public_mcp_set name

let full_surface_override () = Env_config.Tools.full_surface_enabled ()

(* ================================================================ *)
(* Metadata lookup                                                  *)
(* ================================================================ *)

let implementation_status_to_string = function
  | Real -> "real"
  | Adapter -> "adapter"
  | Simulation -> "simulation"
  | Placeholder -> "placeholder"

let effect_domain_to_string = function
  | Read_only -> "read_only"
  | Masc_coordination -> "masc_coordination"
  | Playground_write -> "playground_write"
  | Main_worktree_write -> "main_worktree_write"

let tool_group_to_string = function
  | Board -> "board"
  | Knowledge -> "knowledge"
  | Tasks -> "tasks"
  | Voice -> "voice"
  | Filesystem -> "filesystem"
  | Masc_board -> "masc_board"
  | Masc_keeper -> "masc_keeper"
  | Masc_plan -> "masc_plan"
  | Masc_worktree -> "masc_worktree"
  | Masc_code -> "masc_code"
  | Masc_autoresearch -> "masc_autoresearch"
  | Masc_agent -> "masc_agent"
  | Masc_core -> "masc_core"

let implementation_allows_public_visibility = function
  | Real | Adapter -> true
  | Simulation | Placeholder -> false

module TN = Tool_name
module TK = Tool_name.Keeper
module TM = Tool_name.Masc
module TMK = Tool_name.Masc_keeper

let inferred_effect_domain_of_typed_tool_name = function
  | TN.Keeper TK.Bash
  | TN.Keeper TK.Bash_kill
  | TN.Keeper TK.Shell ->
      Some Main_worktree_write
  | TN.Keeper TK.Bash_output
  | TN.Keeper TK.Board_get
  | TN.Keeper TK.Board_list
  | TN.Keeper TK.Board_search
  | TN.Keeper TK.Board_stats
  | TN.Keeper TK.Code_read
  | TN.Keeper TK.Context_status
  | TN.Keeper TK.Discovery
  | TN.Keeper TK.Fs_read
  | TN.Keeper TK.Library_read
  | TN.Keeper TK.Library_search
  | TN.Keeper TK.Memory_search
  | TN.Keeper TK.Pr_review_read
  | TN.Keeper TK.Preflight_check
  | TN.Keeper TK.Stay_silent
  | TN.Keeper TK.Tasks_audit
  | TN.Keeper TK.Tasks_list
  | TN.Keeper TK.Time_now
  | TN.Keeper TK.Tool_search
  | TN.Keeper TK.Tools_list
  | TN.Keeper TK.Voice_sessions ->
      Some Read_only
  | TN.Keeper TK.Fs_edit
  | TN.Keeper TK.Write ->
      Some Playground_write
  | TN.Keeper TK.Board_cleanup
  | TN.Keeper TK.Board_comment
  | TN.Keeper TK.Board_comment_vote
  | TN.Keeper TK.Board_delete
  | TN.Keeper TK.Board_post
  | TN.Keeper TK.Board_vote
  | TN.Keeper TK.Broadcast
  | TN.Keeper TK.Handoff
  | TN.Keeper TK.Pr_review_comment
  | TN.Keeper TK.Pr_review_reply
  | TN.Keeper TK.Task_claim
  | TN.Keeper TK.Task_create
  | TN.Keeper TK.Task_done
  | TN.Keeper TK.Task_force_done
  | TN.Keeper TK.Task_force_release
  | TN.Keeper TK.Task_submit_for_verification
  | TN.Keeper TK.Voice_agent
  | TN.Keeper TK.Voice_listen
  | TN.Keeper TK.Voice_session_end
  | TN.Keeper TK.Voice_session_start
  | TN.Keeper TK.Voice_speak ->
      Some Masc_coordination
  | TN.Masc TM.Autoresearch_inject
  | TN.Masc TM.Autoresearch_start
  | TN.Masc TM.Autoresearch_stop
  | TN.Masc TM.Deliver
  | TN.Masc TM.Dispatch_plan
  | TN.Masc TM.Operator_action
  | TN.Masc TM.Spawn
  | TN.Masc TM.Start ->
      Some Main_worktree_write
  | TN.Masc TM.Agent_fitness
  | TN.Masc TM.Agent_card
  | TN.Masc TM.Agents
  | TN.Masc TM.Autoresearch_search_findings
  | TN.Masc TM.Autoresearch_status
  | TN.Masc TM.Board_get
  | TN.Masc TM.Board_hearths
  | TN.Masc TM.Board_list
  | TN.Masc TM.Board_profile
  | TN.Masc TM.Board_search
  | TN.Masc TM.Board_stats
  | TN.Masc TM.Check
  | TN.Masc TM.Code_read
  | TN.Masc TM.Code_search
  | TN.Masc TM.Code_symbols
  | TN.Masc TM.Config
  | TN.Masc TM.Coordination_fsm_snapshot
  | TN.Masc TM.Dashboard
  | TN.Masc TM.Get_metrics
  | TN.Masc TM.Goal_list
  | TN.Masc TM.Goal_review
  | TN.Masc TM.Mcp_session
  | TN.Masc TM.Messages
  | TN.Masc TM.Operation_status
  | TN.Masc TM.Operator_digest
  | TN.Masc TM.Operator_snapshot
  | TN.Masc TM.Plan_get
  | TN.Masc TM.Plan_get_task
  | TN.Masc TM.Status
  | TN.Masc TM.Task_history
  | TN.Masc TM.Tasks
  | TN.Masc TM.Tool_admin_snapshot
  | TN.Masc TM.Tool_help
  | TN.Masc TM.Tool_list
  | TN.Masc TM.Tool_stats
  | TN.Masc TM.Web_search
  | TN.Masc TM.Who
  | TN.Masc TM.Workflow_guide
  | TN.Masc TM.Worktree_list
  | TN.Masc TM.Approval_get
  | TN.Masc TM.Webrtc_answer
  | TN.Masc TM.Webrtc_offer ->
      Some Read_only
  | TN.Masc TM.Code_delete
  | TN.Masc TM.Code_edit
  | TN.Masc TM.Code_git
  | TN.Masc TM.Code_shell
  | TN.Masc TM.Code_write
  | TN.Masc TM.Worktree_create
  | TN.Masc TM.Worktree_remove ->
      Some Playground_write
  | TN.Masc TM.Add_task
  | TN.Masc TM.Agent_update
  | TN.Masc TM.Autoresearch_cycle
  | TN.Masc TM.Autoresearch_record_finding
  | TN.Masc TM.Batch_add_tasks
  | TN.Masc TM.Board_cleanup
  | TN.Masc TM.Board_comment
  | TN.Masc TM.Board_comment_vote
  | TN.Masc TM.Board_delete
  | TN.Masc TM.Board_post
  | TN.Masc TM.Board_reaction
  | TN.Masc TM.Board_vote
  | TN.Masc TM.Broadcast
  | TN.Masc TM.Cancel_task
  | TN.Masc TM.Claim_next
  | TN.Masc TM.Claim_task
  | TN.Masc TM.Cleanup_zombies
  | TN.Masc TM.Complete_task
  | TN.Masc TM.Gc
  | TN.Masc TM.Goal_transition
  | TN.Masc TM.Goal_upsert
  | TN.Masc TM.Goal_verify
  | TN.Masc TM.Heartbeat
  | TN.Masc TM.Join
  | TN.Masc TM.Leave
  | TN.Masc TM.List_tasks
  | TN.Masc TM.Note_add
  | TN.Masc TM.Operation_pause
  | TN.Masc TM.Operation_start
  | TN.Masc TM.Operation_stop
  | TN.Masc TM.Operator_confirm
  | TN.Masc TM.Pause
  | TN.Masc TM.Plan_clear_task
  | TN.Masc TM.Plan_init
  | TN.Masc TM.Plan_set_task
  | TN.Masc TM.Plan_update
  | TN.Masc TM.Register_capabilities
  | TN.Masc TM.Release_task
  | TN.Masc TM.Reset
  | TN.Masc TM.Coord_status
  | TN.Masc TM.Resume
  | TN.Masc TM.Set_current_task
  | TN.Masc TM.Tool_admin_update
  | TN.Masc TM.Tool_grant
  | TN.Masc TM.Tool_revoke
  | TN.Masc TM.Transition
  | TN.Masc TM.Update_priority ->
      Some Masc_coordination
  | TN.Masc_keeper TMK.List
  | TN.Masc_keeper TMK.Persona_audit
  | TN.Masc_keeper TMK.Status ->
      Some Read_only
  | TN.Masc_keeper TMK.Clear
  | TN.Masc_keeper TMK.Compact
  | TN.Masc_keeper TMK.Create_from_persona
  | TN.Masc_keeper TMK.Down
  | TN.Masc_keeper TMK.Msg
  | TN.Masc_keeper TMK.Repair
  | TN.Masc_keeper TMK.Reset
  | TN.Masc_keeper TMK.Up ->
      Some Masc_coordination

let inferred_effect_domain name =
  match Tool_name.of_string name with
  | Some typed_name -> inferred_effect_domain_of_typed_tool_name typed_name
  | None -> None

let tool_group_of_typed_tool_name = function
  | TN.Keeper
      ( TK.Board_cleanup
      | TK.Board_comment
      | TK.Board_comment_vote
      | TK.Board_delete
      | TK.Board_get
      | TK.Board_list
      | TK.Board_post
      | TK.Board_search
      | TK.Board_stats
      | TK.Board_vote ) ->
      Some Board
  | TN.Keeper (TK.Memory_search | TK.Library_read | TK.Library_search) ->
      Some Knowledge
  | TN.Keeper
      ( TK.Task_claim
      | TK.Task_create
      | TK.Task_done
      | TK.Task_force_done
      | TK.Task_force_release
      | TK.Task_submit_for_verification
      | TK.Tasks_audit
      | TK.Tasks_list ) ->
      Some Tasks
  | TN.Keeper
      ( TK.Voice_agent
      | TK.Voice_listen
      | TK.Voice_session_end
      | TK.Voice_session_start
      | TK.Voice_sessions
      | TK.Voice_speak ) ->
      Some Voice
  | TN.Keeper (TK.Bash | TK.Fs_edit | TK.Fs_read | TK.Shell | TK.Write) ->
      Some Filesystem
  | TN.Keeper
      ( TK.Bash_kill
      | TK.Bash_output
      | TK.Broadcast
      | TK.Code_read
      | TK.Context_status
      | TK.Discovery
      | TK.Handoff
      | TK.Pr_review_comment
      | TK.Pr_review_read
      | TK.Pr_review_reply
      | TK.Preflight_check
      | TK.Stay_silent
      | TK.Time_now
      | TK.Tool_search
      | TK.Tools_list ) ->
      None
  | TN.Masc
      ( TM.Board_cleanup
      | TM.Board_comment
      | TM.Board_comment_vote
      | TM.Board_delete
      | TM.Board_get
      | TM.Board_hearths
      | TM.Board_list
      | TM.Board_post
      | TM.Board_profile
      | TM.Board_reaction
      | TM.Board_search
      | TM.Board_stats
      | TM.Board_vote ) ->
      Some Masc_board
  | TN.Masc_keeper _ -> Some Masc_keeper
  | TN.Masc
      ( TM.Plan_clear_task
      | TM.Plan_get
      | TM.Plan_get_task
      | TM.Plan_init
      | TM.Plan_set_task
      | TM.Plan_update ) ->
      Some Masc_plan
  | TN.Masc (TM.Worktree_create | TM.Worktree_list | TM.Worktree_remove) ->
      Some Masc_worktree
  | TN.Masc
      ( TM.Code_delete
      | TM.Code_edit
      | TM.Code_git
      | TM.Code_read
      | TM.Code_search
      | TM.Code_shell
      | TM.Code_symbols
      | TM.Code_write ) ->
      Some Masc_code
  | TN.Masc
      ( TM.Autoresearch_cycle
      | TM.Autoresearch_inject
      | TM.Autoresearch_record_finding
      | TM.Autoresearch_search_findings
      | TM.Autoresearch_start
      | TM.Autoresearch_status
      | TM.Autoresearch_stop ) ->
      Some Masc_autoresearch
  | TN.Masc (TM.Agent_fitness | TM.Agent_update | TM.Agent_card | TM.Agents) ->
      Some Masc_agent
  | TN.Masc
      ( TM.Add_task
      | TM.Approval_get
      | TM.Batch_add_tasks
      | TM.Broadcast
      | TM.Cancel_task
      | TM.Check
      | TM.Claim_next
      | TM.Claim_task
      | TM.Cleanup_zombies
      | TM.Complete_task
      | TM.Config
      | TM.Coordination_fsm_snapshot
      | TM.Coord_status
      | TM.Dashboard
      | TM.Deliver
      | TM.Dispatch_plan
      | TM.Gc
      | TM.Get_metrics
      | TM.Goal_list
      | TM.Goal_review
      | TM.Goal_transition
      | TM.Goal_upsert
      | TM.Goal_verify
      | TM.Heartbeat
      | TM.Join
      | TM.Leave
      | TM.List_tasks
      | TM.Mcp_session
      | TM.Messages
      | TM.Note_add
      | TM.Operation_pause
      | TM.Operation_start
      | TM.Operation_status
      | TM.Operation_stop
      | TM.Operator_action
      | TM.Operator_confirm
      | TM.Operator_digest
      | TM.Operator_snapshot
      | TM.Pause
      | TM.Register_capabilities
      | TM.Release_task
      | TM.Reset
      | TM.Resume
      | TM.Set_current_task
      | TM.Spawn
      | TM.Start
      | TM.Status
      | TM.Task_history
      | TM.Tasks
      | TM.Tool_admin_snapshot
      | TM.Tool_admin_update
      | TM.Tool_grant
      | TM.Tool_help
      | TM.Tool_list
      | TM.Tool_revoke
      | TM.Tool_stats
      | TM.Transition
      | TM.Update_priority
      | TM.Web_search
      | TM.Webrtc_answer
      | TM.Webrtc_offer
      | TM.Who
      | TM.Workflow_guide ) ->
      Some Masc_core

let tool_group name =
  match Tool_name.of_string name with
  | Some typed_name -> tool_group_of_typed_tool_name typed_name
  | None -> None

let attach_inferred_effect_domain name (meta : metadata) =
  match meta.effect_domain with
  | Some _ -> meta
  | None -> { meta with effect_domain = inferred_effect_domain name }

let metadata name =
  let base =
    match Hashtbl.find_opt metadata_table name with
    | Some meta -> meta
    | None ->
      if is_public_mcp name then default_metadata
      else if List.mem name keeper_internal_set then
        keeper_internal_metadata name
      else if Tool_catalog_surfaces.is_on_surface System_internal name then
        { default_metadata with
          visibility = Hidden;
          allow_direct_call_when_hidden = true;
          reason = Some "System-internal tool; callable but not listed in tools/list." }
      else
        (* Non-public, non-explicit tools are internal: hidden from tools/list
           but callable via tools/call (tool_allowed_in_profile uses include_hidden). *)
        { default_metadata with
          visibility = Hidden;
          allow_direct_call_when_hidden = true;
          reason = Some "Internal tool; not on public MCP surface." }
  in
  let with_surface_visibility =
    if Tool_catalog_surfaces.is_on_surface System_internal name then
    (* Surface membership is the canonical "hidden but callable" contract for
       system-internal tools, even when a tool also carries explicit metadata
       for semantic hints like readonly/destructive. *)
      {
        base with
        visibility = Hidden;
        allow_direct_call_when_hidden = true;
        reason =
          (match base.reason with
          | Some _ -> base.reason
          | None ->
              Some
                "System-internal tool; callable but not listed in tools/list.");
      }
    else
      base
  in
  attach_inferred_effect_domain name with_surface_visibility

let implementation_status name =
  let meta = metadata name in
  meta.implementation_status

let effect_domain name =
  let meta = metadata name in
  meta.effect_domain

let requires_actor_binding name =
  match (metadata name).requires_actor_binding with
  | Some value -> value
  | None -> false

let is_main_worktree_boundary_exempt name =
  match effect_domain name with
  | Some Read_only | Some Masc_coordination | Some Playground_write -> Some true
  | Some Main_worktree_write -> Some false
  | None -> None

let canonical_tool_name name =
  match (metadata name).canonical_name with
  | Some canonical_name -> canonical_name
  | None -> name

let is_placeholder name =
  match implementation_status name with
  | Placeholder -> true
  | Real | Adapter | Simulation -> false

let is_visible ?(include_hidden = false) ?(include_deprecated = false) name =
  let meta = metadata name in
  match meta.visibility, meta.lifecycle with
  | Hidden, _ when include_hidden -> true
  | Hidden, _ when placeholder_tools_enabled () && is_placeholder name -> true
  | Hidden, _ -> false
  | Default, Deprecated -> include_deprecated
  | Default, Active -> implementation_allows_public_visibility meta.implementation_status

let visibility_to_string = function
  | Default -> "default"
  | Hidden -> "hidden"

let lifecycle_to_string = function
  | Active -> "active"
  | Deprecated -> "deprecated"

(** Precomputed list of deprecated tools from explicit_metadata.
    Static — computed once at module init. *)
let deprecated_tool_entries : (string * metadata) list =
  List.filter (fun (_name, meta) -> (=) meta.lifecycle Deprecated) explicit_metadata

(* ================================================================ *)
(* JSON metadata helpers                                            *)
(* ================================================================ *)

let metadata_to_fields name =
  let meta = metadata name in
  let surfaces =
    Tool_catalog_surfaces.surfaces_for_tool name
    |> List.map (fun s -> `String (Tool_catalog_surfaces.surface_to_string s))
  in
  let base =
    [
      ("visibility", `String (visibility_to_string meta.visibility));
      ("lifecycle", `String (lifecycle_to_string meta.lifecycle));
      ("implementationStatus", `String (implementation_status_to_string meta.implementation_status));
      ("surfaces", `List surfaces);
    ]
  in
  let with_canonical =
    match meta.canonical_name with
    | Some canonical_name -> ("canonicalName", `String canonical_name) :: base
    | None -> base
  in
  let with_replacement =
    match meta.replacement with
    | Some replacement -> ("replacement", `String replacement) :: with_canonical
    | None -> with_canonical
  in
  let with_reason =
    match meta.reason with
    | Some reason -> ("reason", `String reason) :: with_replacement
    | None -> with_replacement
  in
  let with_effect_domain =
    match meta.effect_domain with
    | Some effect_domain ->
        ("effectDomain", `String (effect_domain_to_string effect_domain))
        :: with_reason
    | None -> with_reason
  in
  let with_tool_group =
    match tool_group name with
    | Some group ->
        ("toolGroup", `String (tool_group_to_string group)) :: with_effect_domain
    | None -> with_effect_domain
  in
  let with_actor_binding =
    match meta.requires_actor_binding with
    | Some value -> ("requiresActorBinding", `Bool value) :: with_tool_group
    | None -> with_tool_group
  in
  match meta.required_permission with
  | Some permission ->
      ("requiredPermission", `String (Masc_domain.show_permission permission))
      :: with_actor_binding
  | None -> with_actor_binding

let public_contract_fields name =
  let meta = metadata name in
  let base =
    [
      ( "implementationStatus",
        `String (implementation_status_to_string meta.implementation_status) );
    ]
  in
  let with_effect_domain =
    match meta.effect_domain with
    | Some effect_domain ->
        ("effectDomain", `String (effect_domain_to_string effect_domain))
        :: base
    | None -> base
  in
  let with_actor_binding =
    match meta.requires_actor_binding with
    | Some value -> ("requiresActorBinding", `Bool value) :: with_effect_domain
    | None -> with_effect_domain
  in
  match meta.canonical_name with
  | Some canonical_name -> ("canonicalName", `String canonical_name) :: with_actor_binding
  | None -> with_actor_binding

let allow_direct_call name =
  let meta = metadata name in
  match meta.visibility with
  | Default -> true
  | Hidden -> meta.allow_direct_call_when_hidden

(* ================================================================ *)
(* Re-export: Surface system (from Tool_catalog_surfaces)           *)
(* ================================================================ *)

let tools_for_surface = Tool_catalog_surfaces.tools_for_surface
let all_surfaces = Tool_catalog_surfaces.all_surfaces
let is_on_surface = Tool_catalog_surfaces.is_on_surface
let surface_to_string = Tool_catalog_surfaces.surface_to_string
