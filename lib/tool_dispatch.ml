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

(** Central Tool Dispatch Registry.

    Production MCP tool names route through {!Tool_name} and an exhaustive
    module-tag match. Mutable registries remain for direct-handler
    compatibility, schemas, and test/dynamic tools.

    RFC-0084 host-config-cleanup-J removed the [MASC_DISPATCH_V2]
    feature flag and the legacy match chain it gated.  The Hashtbl
    dispatch path is now the only code path. *)

(** Unified handler type: every tool call is [name * args -> result option].
    [None] means "this handler does not know this tool" (should not happen
    when lookups go through the registry, but kept for compatibility). *)
type handler = name:string -> args:Yojson.Safe.t -> Tool_result.t option

(** Central registry — populated once during server initialisation. *)
let registry : (string, handler) Hashtbl.t = Hashtbl.create 256

(** Mutex protecting all mutable state in this module.
    Uses Eio_guard for dual-mode (pre/post Eio runtime) locking. *)
let dispatch_mu = Eio.Mutex.create ()
let with_dispatch_rw f = Eio_guard.with_mutex dispatch_mu f
let with_dispatch_ro f = Eio_guard.with_mutex_ro dispatch_mu f

(** Register a single tool name → handler mapping. *)
let register ~tool_name ~(handler : handler) =
  with_dispatch_rw (fun () -> Hashtbl.replace registry tool_name handler)

(** Bulk-register every tool name from a schema list to the same handler.
    This is the primary registration path — it extracts names from the
    module's published schemas, ensuring the registry is always in sync
    with the advertised tool list. *)
let register_module ~(schemas : Masc_domain.tool_schema list) ~(handler : handler) =
  with_dispatch_rw (fun () ->
    List.iter
      (fun (schema : Masc_domain.tool_schema) ->
        Hashtbl.replace registry schema.name handler)
      schemas)

(** {2 Dispatch Hooks}

    Pre-hooks run before the handler; post-hooks run after.
    Multiple hooks are supported — they execute in registration order.

    - Pre-hook returning [Some result] short-circuits (handler is skipped).
      Use case: permission checks (Sprint 3), request logging.
    - Post-hook transforms the result.  Identity function when observing only.
      Use case: tracing spans (Sprint 2), metrics collection. *)

(** Pre-hook action: determines how dispatch proceeds after a hook runs. *)
type pre_hook_action =
  | Pass                        (** This hook has no opinion — continue *)
  | Proceed of Yojson.Safe.t   (** Replace args (e.g. type coercion) and continue *)
  | Reject of Tool_result.t    (** Short-circuit with error result *)

(** Pre-hook: receives tool name and args before handler runs. *)
type pre_hook = name:string -> args:Yojson.Safe.t -> pre_hook_action

(* RFC-0084 PR-I-3 — legacy [type post_hook = Tool_result.t -> Tool_result.t]
   removed.  All 5 in-tree call-sites migrated by PR-I-2.a..e:
   tool_metrics / tool_usage_log / otel_dispatch_hook / tool_output_validation
   / server_bootstrap_loops.  Observation moved to [post_hook_typed]
   below; transformation moved to [result_transformer] further down. *)

(** Typed post-hook (RFC-0084 PR-I-1).

    Receives the typed {!Dispatch_outcome.t} together with the
    handler-produced {!Tool_result.t} (when the [Handled] arm ran)
    once dispatch completes — regardless of which arm fired
    ([Handled] / [Rejected_by_capability] / [Rejected_by_pre_hook] /
    [No_handler] / [Handler_error]).

    The optional [Tool_result.t] is [Some _] only on the [Handled]
    arm (matching legacy [post_hook] semantics for that arm); other
    arms receive [None] so observers can pattern-match on the
    typed outcome first and read [tool_name] / [success] /
    [duration_ms] from the result only when relevant.

    Returns [unit] because typed hooks are *observers* (metrics,
    spans, audit log) — they cannot mutate the dispatch outcome.
    The mutation door from the legacy [post_hook] surface is closed
    on purpose; it was historically used for result transformation
    (e.g. redaction) which now belongs in a dedicated layer rather
    than mid-dispatch.  PR-I-2.* migrations preserve observation
    semantics. *)
type post_hook_typed = Dispatch_outcome.t -> Tool_result.t option -> unit

let pre_hooks : pre_hook list ref = ref []
let typed_post_hooks : post_hook_typed list ref = ref []

let register_pre_hook (hook : pre_hook) =
  with_dispatch_rw (fun () -> pre_hooks := !pre_hooks @ [hook])

let register_typed_post_hook (hook : post_hook_typed) =
  with_dispatch_rw (fun () -> typed_post_hooks := !typed_post_hooks @ [hook])

(** RFC-0084 PR-I-2.d — Result transformer surface.

    Carries the [Tool_result.t -> Tool_result.t] *transformation*
    responsibility that the legacy [post_hook] surface used to mix
    with observation.  Today there is exactly one transformer in
    tree ([Tool_output_validation.post_hook] which caps oversized
    payloads); the single-ref shape reflects that.  Future PRs may
    grow this into a list if more transformers appear, but PR-I-3
    can already remove the legacy [post_hook] surface knowing
    transformation is no longer threaded through it. *)
type result_transformer = Tool_result.t -> Tool_result.t

let result_transformer_ref : result_transformer option ref = ref None

let set_result_transformer (t : result_transformer) =
  with_dispatch_rw (fun () -> result_transformer_ref := Some t)

let apply_result_transformer (r : Tool_result.t) : Tool_result.t =
  match !result_transformer_ref with
  | None -> r
  | Some t -> t r
;;

let clear_hooks () =
  with_dispatch_rw (fun () ->
    pre_hooks := [];
    typed_post_hooks := [];
    result_transformer_ref := None)

(** Run pre-hooks in order, threading coerced args through the chain.
    First [Reject] wins (short-circuit). [Proceed] replaces args for
    subsequent hooks and the final handler. *)
let run_pre_hooks ~name ~args =
  let rec go current_args = function
    | [] -> (None, current_args)
    | hook :: rest ->
      (match hook ~name ~args:current_args with
       | Reject result -> (Some result, current_args)
       | Proceed new_args -> go new_args rest
       | Pass -> go current_args rest)
  in
  go args !pre_hooks

(* RFC-0084 PR-I-3 — [run_post_hooks] removed alongside the legacy
   [post_hook] type and [post_hooks] ref.  Observation flows through
   [run_typed_post_hooks] below; transformation through
   [apply_result_transformer]. *)

(** Run typed post-hooks in order against the typed dispatch outcome.
    Each hook is invoked for its side-effects; mutation of the
    outcome is not permitted (see [post_hook_typed] above).

    [result] is [Some r] only on the [Handled] arm; other arms
    pass [None] so observers can branch on the typed outcome first. *)
let run_typed_post_hooks
    (outcome : Dispatch_outcome.t)
    (result : Tool_result.t option) : unit =
  List.iter (fun hook -> hook outcome result) !typed_post_hooks

(** RFC-0084 §2.2 + RFC-0085 PR-14 — Single dispatch entry.

    Inlines what used to be a three-step file-private chain
    ([dispatch] -> [dispatch_structured] -> [guarded_dispatch]) into
    one function so the lifecycle reads top-to-bottom:

      1. [Tool_telemetry.with_span]   (4-tuple emission wrapper)
      2. pre-hook chain                (reject / coerce-args)
      3. registry lookup + handler     (handler exception capture)
      4. result transformer            ([apply_result_transformer])
      5. typed post-hook fan-out       ([run_typed_post_hooks])

    PR-11 already removed the three-step chain from the public mli.
    PR-14 finishes the consolidation by removing the file-private
    indirection — each step had exactly one caller, so the layering
    was pure overhead. *)
let guarded_dispatch ~(token : Tool_token.t) ~args () : Tool_result.t option =
  let result, _outcome =
    Tool_telemetry.with_span ~tool_name:token.name (fun _trace_id_thunk ->
      let name = token.name in
      let r =
        match run_pre_hooks ~name ~args with
        | (Some _ as blocked, _) -> blocked
        | (None, coerced_args) ->
          (match Hashtbl.find_opt registry name with
           | Some handler ->
             let start_time = Time_compat.now () in
             (try handler ~name ~args:coerced_args
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn -> Some (Tool_result.of_exn ~tool_name:name ~start_time exn))
           | None -> None)
      in
      (* RFC-0085 PR-5 — finalisation is done inline here (we cannot
         depend on [Tool_dispatch_emit] without creating a dependency
         cycle).  The logic is byte-identical to
         [Tool_dispatch_emit.finalize], and any change must be mirrored
         in both places.  Future RFC may extract a shared private
         function once [Tool_dispatch_emit] is restructured.

         Order: transformer first (mutates the Tool_result.t inside the
         [Handled] arm), then typed observer fan-out. *)
      let r' =
        match r with
        | Some tr -> Some (apply_result_transformer tr)
        | None -> r
      in
      let typed_outcome : Dispatch_outcome.t =
        match r' with
        | Some _ -> Handled
        | None -> No_handler
      in
      run_typed_post_hooks typed_outcome r';
      let outcome =
        match r' with
        | Some _ -> "handled"
        | None -> "no_handler"
      in
      r', outcome)
  in
  result
;;

(** Number of registered tool names. *)
let registered_count () = Hashtbl.length registry

(** Check whether a tool name is registered. *)
let is_registered name = Hashtbl.mem registry name

(** --- Hashtbl sets for dispatch capability checks --- *)

let read_only_set : (string, unit) Hashtbl.t = Hashtbl.create 32
let requires_join_set : (string, unit) Hashtbl.t = Hashtbl.create 64
let mcp_context_required_set : (string, unit) Hashtbl.t = Hashtbl.create 64
let destructive_set : (string, unit) Hashtbl.t = Hashtbl.create 16
let idempotent_set : (string, unit) Hashtbl.t = Hashtbl.create 32

let init_read_only_set (names : string list) =
  with_dispatch_rw (fun () ->
    List.iter (fun name -> Hashtbl.replace read_only_set name ()) names)

let init_requires_join_set (names : string list) =
  with_dispatch_rw (fun () ->
    List.iter (fun name -> Hashtbl.replace requires_join_set name ()) names)

let init_mcp_context_required_set (names : string list) =
  with_dispatch_rw (fun () ->
    List.iter (fun name -> Hashtbl.replace mcp_context_required_set name ()) names)

let init_destructive_set (names : string list) =
  with_dispatch_rw (fun () ->
    List.iter (fun name -> Hashtbl.replace destructive_set name ()) names)

let init_idempotent_set (names : string list) =
  with_dispatch_rw (fun () ->
    List.iter (fun name -> Hashtbl.replace idempotent_set name ()) names)

let is_read_only name = with_dispatch_ro (fun () -> Hashtbl.mem read_only_set name)
let is_join_required name = with_dispatch_ro (fun () -> Hashtbl.mem requires_join_set name)
let is_mcp_context_required name =
  with_dispatch_ro (fun () -> Hashtbl.mem mcp_context_required_set name)
let is_destructive name = with_dispatch_ro (fun () -> Hashtbl.mem destructive_set name)
let is_idempotent name = with_dispatch_ro (fun () -> Hashtbl.mem idempotent_set name)

(** {2 Module Tag Dispatch}

    Known tool names map to module tags through a compile-time match.
    Runtime registrations remain as a fallback for test/dynamic tools. *)

type module_tag =
  | Mod_plan | Mod_operator
  | Mod_local_runtime
  | Mod_worktree
  | Mod_code | Mod_code_write
  | Mod_run
  | Mod_compact
  | Mod_agent | Mod_task | Mod_room
  | Mod_control | Mod_agent_timeline | Mod_misc | Mod_suspend
  | Mod_library | Mod_keeper
  | Mod_inline
  | Mod_autoresearch
  | Mod_shard

let static_tag_of_tool_name (tool : Tool_name.t) : module_tag option =
  match tool with
  | Tool_name.Keeper _ -> Some Mod_shard
  | Tool_name.Masc_keeper _ -> Some Mod_keeper
  | Tool_name.Masc m ->
    let open Tool_name.Masc in
    match m with
    | Cancel_task
    | Dispatch_plan
    | List_tasks
    | Operation_pause
    | Operation_start
    | Operation_status
    | Operation_stop
    | Release_task -> None
    | Add_task
    | Batch_add_tasks
    | Claim_next
    | Task_history
    | Tasks
    | Transition
    | Update_priority -> Some Mod_task
    | Agent_fitness
    | Agent_card
    | Agent_update
    | Agents
    | Get_metrics -> Some Mod_agent
    | Autoresearch_cycle
    | Autoresearch_inject
    | Autoresearch_record_finding
    | Autoresearch_search_findings
    | Autoresearch_start
    | Autoresearch_status
    | Autoresearch_stop -> Some Mod_autoresearch
    | Board_cleanup
    | Board_comment
    | Board_comment_vote
    | Board_curation_read
    | Board_curation_submit
    | Board_delete
    | Board_get
    | Board_hearths
    | Board_list
    | Board_post
    | Board_profile
    | Board_reaction
    | Board_search
    | Board_stats
    | Board_sub_board_create
    | Board_sub_board_delete
    | Board_sub_board_get
    | Board_sub_board_list
    | Board_sub_board_update
    | Board_vote
    | Approval_pending
    | Approval_get
    | Broadcast
    | Join
    | Leave
    | Mcp_session
    | Messages
    | Spawn
    | Start
    | Who -> Some Mod_inline
    | Check
    | Coord_status
    | Coordination_fsm_snapshot
    | Goal_list
    | Goal_review
    | Goal_transition
    | Goal_upsert
    | Goal_verify
    | Heartbeat
    | Reset
    | Status
    | Workflow_guide -> Some Mod_room
    | Code_read | Code_search | Code_symbols -> Some Mod_code
    | Code_delete | Code_edit | Code_git | Code_shell | Code_write -> Some Mod_code_write
    | Config
    | Cleanup_zombies
    | Dashboard
    | Gc
    | Tool_admin_snapshot
    | Tool_admin_update
    | Tool_help
    | Tool_stats
    | Web_fetch
    | Web_search
    | Webrtc_answer
    | Webrtc_offer -> Some Mod_misc
    | Deliver
    | Note_add
    | Plan_clear_task
    | Plan_get
    | Plan_get_task
    | Plan_init
    | Plan_set_task
    | Plan_update -> Some Mod_plan
    | Operator_action | Operator_confirm | Operator_digest | Operator_snapshot -> Some Mod_operator
    | Pause | Resume -> Some Mod_control
    | Tool_grant | Tool_list | Tool_revoke -> Some Mod_shard
    | Worktree_create | Worktree_list | Worktree_remove -> Some Mod_worktree

let tag_registry : (string, module_tag) Hashtbl.t = Hashtbl.create 512
let tag_registry_initialized = Atomic.make false

(** Schema registry — maps tool name → input_schema JSON.
    Populated alongside tag_registry during server initialization.
    Used by Tool_input_validation pre-hook to validate arguments
    before dispatch (C-4 precondition validation). *)
let schema_registry : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 512

let register_module_tag ~(schemas : Masc_domain.tool_schema list) ~tag =
  with_dispatch_rw (fun () ->
    List.iter (fun (s : Masc_domain.tool_schema) ->
      Hashtbl.replace tag_registry s.name tag;
      Hashtbl.replace schema_registry s.name s.input_schema) schemas)

(** Register a single tool name with a tag (for modules without schema exports). *)
let register_name_tag ~tool_name ~tag =
  with_dispatch_rw (fun () -> Hashtbl.replace tag_registry tool_name tag)

let lookup_tag name =
  match Tool_name.of_string name with
  | Some tool -> static_tag_of_tool_name tool
  | None -> with_dispatch_ro (fun () -> Hashtbl.find_opt tag_registry name)

let lookup_schema name = with_dispatch_ro (fun () -> Hashtbl.find_opt schema_registry name)

let tag_registry_count () = with_dispatch_ro (fun () -> Hashtbl.length tag_registry)

let mark_tag_registry_initialized () = with_dispatch_rw (fun () -> Atomic.set tag_registry_initialized true)
let is_tag_registry_initialized () = with_dispatch_ro (fun () -> Atomic.get tag_registry_initialized)

(** Mint a [Tool_token.t] validated against static routes or registries.
    Protected by dispatch_mu for thread safety (Copilot review).
    Checks known typed tool names first, then the runtime tag/handler registries.
    In production both are populated at startup; in test binaries
    only the handler registry may be populated. *)
let mint_token ~name =
  with_dispatch_ro (fun () ->
    Tool_token.mint_with
      ~validate:(fun n ->
        match Tool_name.of_string n with
        | Some tool -> Option.is_some (static_tag_of_tool_name tool)
        | None -> Hashtbl.mem tag_registry n || Hashtbl.mem registry n)
      ~name)

(** Enumerate every tool name registered in either the tag_registry (primary)
    or the handler registry (fallback). Used by [find_similar_names] to
    drive "did you mean" suggestions for Unknown tool errors (#9784). *)
let all_registered_names () =
  with_dispatch_ro (fun () ->
    let acc =
      Hashtbl.fold (fun n _ a -> n :: a) tag_registry []
    in
    Hashtbl.fold
      (fun n _ a -> if List.mem n a then a else n :: a)
      registry acc)

(* #9784: Unknown tool errors must include closest-name suggestions so the
   LLM can self-correct on the next turn. Jaccard works well for snake_case
   tool names because Text_similarity tokenizes on non-alphanumeric and
   captures shared morphemes via byte n-grams. The default min_score 0.4
   excludes unrelated names while accepting close task-tool typos. *)
let find_similar_names ?(limit = 3) ?(min_score = 0.4) ~query () =
  let candidates = all_registered_names () in
  let scored =
    List.filter_map
      (fun n ->
        let s = Text_similarity.jaccard_similarity query n in
        if Stdlib.Float.compare s min_score >= 0 then Some (s, n) else None)
      candidates
  in
  let sorted =
    List.sort (fun (a, _) (b, _) -> Float.compare b a) scored
  in
  let rec take k = function
    | _ when k <= 0 -> []
    | [] -> []
    | (_, n) :: rest -> n :: take (k - 1) rest
  in
  take limit sorted
