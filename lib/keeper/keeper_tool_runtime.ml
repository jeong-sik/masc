(** Runtime dispatch for descriptor-backed agent tools. *)

open Keeper_tool_descriptor

(* RFC-0182 Phase 5 PR-A (RFC §12): optional Eio resource fields.
   When set, descriptor handlers like masc_keeper_msg / masc_keeper_up /
   masc_operator_* can call into Eio-bound
   primitives (start_keepalive, Keeper_msg_async.submit, LLM-call fibers,
   Operator_control.context) without re-introducing dispatch-ref
   plumbing.  Default = [None]; callers without Eio context (OAS handler,
   tests) leave them unset and the Eio-bound descriptor handlers return
   a typed "Eio context not provided" failure instead of crashing. *)
type context =
  { config : Workspace.config
  ; meta : Keeper_meta_contract.keeper_meta
  ; publication_recovery :
      Keeper_publication_recovery_availability.turn_context
  ; ctx_work : Keeper_types.working_context
  ; turn_sandbox_factory : Keeper_sandbox_factory.t option
  ; exec_cache : Masc_exec.Exec_cache.t option
  ; search_fn : unit -> Keeper_tool_execution.t
  ; sw : Eio.Switch.t option
  ; clock : float Eio.Time.clock_ty Eio.Resource.t option
  ; proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option
  ; mcp_session_id : string option
  ; continuation_channel : Keeper_continuation_channel.t option
    (* RFC-0320: the connector conversation the current turn started from,
       so async tools (masc_fusion) can route their completion wake back to
       the originating channel. [None] on non-connector turns and on callers
       without turn context (OAS handler defaults, tests). *)
  ; gate_context : (unit -> Keeper_gate.causal_context) option
    (* Exact outer-turn evidence for contextual Gate judgment. Runtime handlers
       pass it through without inspecting the snapshot. *)
  ; gate_grant : Keeper_gate.cycle_grant option
    (* Exact human decision delivered to this Keeper lane. External-effect
       handlers may consume it only after matching their normalized request. *)
  }

let descriptor_for_internal internal_name =
  match Keeper_tool_descriptor.descriptors_for_internal internal_name with
  | descriptor :: _ -> Some descriptor
  | [] -> None
;;

let handle_filesystem ctx descriptor args =
  match descriptor.Keeper_tool_descriptor.runtime_handler with
  | Tool_read_file ->
    Some
      (Keeper_tool_filesystem_runtime.handle_read_file_with_outcome
         ~turn_sandbox_factory:ctx.turn_sandbox_factory
         ~config:ctx.config
         ~meta:ctx.meta
         ~args)
  | Tool_edit_file | Tool_write_file ->
    Some
      (Keeper_tool_filesystem_runtime.handle_file_write_with_outcome
         ~turn_sandbox_factory:ctx.turn_sandbox_factory
         ~config:ctx.config
         ~meta:ctx.meta
         ~publication_recovery:ctx.publication_recovery
         ?continuation_channel:ctx.continuation_channel
         ?gate_context:ctx.gate_context
         ?gate_grant:ctx.gate_grant
         ~args
         ())
  | Tool_execute
  | Tool_search_files
  | Tool_time_now
  | Tool_tools_list
  | Tool_tool_search
  | Tool_context_status
  | Tool_memory_search
  | Tool_memory_write
  | Tool_library_search
  | Tool_library_read
  | Tool_surface_read
  | Tool_surface_post
  | Tool_person_note_set
  | Tool_ide_annotate
  | Tool_voice_dispatch
  | Tool_task_dispatch
  | Board_tool_dispatch
  | Tool_masc_board_dispatch
  | Tool_masc_task_dispatch
  | Tool_masc_plan_dispatch
  | Tool_masc_run_dispatch
  | Tool_masc_agent_dispatch
  | Tool_masc_workspace_dispatch
  | Tool_masc_misc_dispatch
  | Tool_web_search
  | Tool_web_fetch
  | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch
  | Tool_masc_schedule_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_fusion_dispatch
  | Tool_masc_fusion_status
  | Tool_masc_library_dispatch
  | Tool_masc_local_runtime_dispatch
  | Tool_analyze_image -> None
;;

(* Shell IR mechanics live under Execute lowerers. Keeper_tool_command_runtime is
   the descriptor-selected runtime boundary that binds Execute/Grep to
   those lowerers without keeping them under the keeper_exec* axis. *)
let handle_shell_ir ctx descriptor args =
  match descriptor.Keeper_tool_descriptor.runtime_handler with
  | Tool_execute ->
      Some
        (Keeper_tool_command_runtime.handle_tool_execute_with_outcome
           ~turn_sandbox_factory:ctx.turn_sandbox_factory
           ~exec_cache:ctx.exec_cache
         ~config:ctx.config
         ~meta:ctx.meta
         ?continuation_channel:ctx.continuation_channel
         ?gate_context:ctx.gate_context
         ?gate_grant:ctx.gate_grant
         ~args
         ())
  | Tool_search_files ->
    Some
      (Keeper_tool_command_runtime.handle_tool_search_files_with_outcome
         ~turn_sandbox_factory:ctx.turn_sandbox_factory
         ~exec_cache:ctx.exec_cache
         ~config:ctx.config
         ~meta:ctx.meta
         ~args)
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_time_now
  | Tool_tools_list
  | Tool_tool_search
  | Tool_context_status
  | Tool_memory_search
  | Tool_memory_write
  | Tool_library_search
  | Tool_library_read
  | Tool_surface_read
  | Tool_surface_post
  | Tool_person_note_set
  | Tool_ide_annotate
  | Tool_voice_dispatch
  | Tool_task_dispatch
  | Board_tool_dispatch
  | Tool_masc_board_dispatch
  | Tool_masc_task_dispatch
  | Tool_masc_plan_dispatch
  | Tool_masc_run_dispatch
  | Tool_masc_agent_dispatch
  | Tool_masc_workspace_dispatch
  | Tool_masc_misc_dispatch
  | Tool_web_search
  | Tool_web_fetch
  | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch
  | Tool_masc_schedule_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_fusion_dispatch
  | Tool_masc_fusion_status
  | Tool_masc_library_dispatch
  | Tool_masc_local_runtime_dispatch
  | Tool_analyze_image -> None
;;

let handle_in_process ctx descriptor args =
  let name = descriptor.Keeper_tool_descriptor.internal_name in
  match descriptor.Keeper_tool_descriptor.runtime_handler with
  | Tool_time_now ->
    Some
      (Keeper_tool_execution.success
         (Keeper_tool_in_process_runtime.handle_time_now ~args))
  | Tool_tools_list ->
    Some
      (Keeper_tool_execution.success
         (Keeper_tool_in_process_runtime.handle_tools_list ~meta:ctx.meta ~args))
  | Tool_tool_search -> Some (ctx.search_fn ())
  | Tool_context_status ->
    Some
      (Keeper_tool_execution.success
         (Keeper_tool_in_process_runtime.handle_context_status
            ~config:ctx.config
            ~meta:ctx.meta
            ~ctx_work:ctx.ctx_work
            ~args))
  | Tool_memory_search ->
    Some
      (Keeper_tool_memory_runtime.keeper_memory_search_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ~ctx_work:ctx.ctx_work
         ~args)
  | Tool_memory_write ->
    Some
      (Keeper_tool_memory_runtime.keeper_memory_write_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ~args)
  | Tool_library_search ->
    Some
      (Keeper_tool_in_process_runtime.handle_library_search_with_outcome
         ~meta:ctx.meta
         ~args)
  | Tool_library_read ->
    Some
      (Keeper_tool_in_process_runtime.handle_library_read_with_outcome
         ~meta:ctx.meta
         ~args)
  | Tool_surface_read ->
    Some
      (Keeper_tool_execution.success
         (Keeper_tool_in_process_runtime.handle_surface_read
            ~config:ctx.config
            ~meta:ctx.meta
            ~args))
  | Tool_surface_post ->
    Some
      (Keeper_tool_in_process_runtime.handle_surface_post_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ?continuation_channel:ctx.continuation_channel
         ?gate_context:ctx.gate_context
         ?gate_grant:ctx.gate_grant
         ~args
         ())
  | Tool_person_note_set ->
    Some
      (Keeper_tool_in_process_runtime.handle_person_note_set_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ~args)
  | Tool_ide_annotate ->
    Some
      (Keeper_tool_in_process_runtime.handle_ide_annotate_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ~args)
  | Tool_voice_dispatch ->
    Some
      (Keeper_tool_in_process_runtime.handle_voice_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args
         ())
  | Tool_task_dispatch ->
    Some
      (Keeper_tool_task_runtime.handle_keeper_task_tool_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Board_tool_dispatch ->
    Some
      (Keeper_tool_board_runtime.handle_keeper_board_tool_with_outcome
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_board_dispatch ->
    Some
      (Keeper_tool_in_process_runtime.handle_masc_board_with_outcome
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_task_dispatch ->
    Some
      (Keeper_tool_in_process_runtime.handle_masc_task_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_plan_dispatch ->
    Some
      (Keeper_tool_in_process_runtime.handle_masc_plan_with_outcome
         ~config:ctx.config
         ~name
         ~args)
  | Tool_masc_run_dispatch ->
    Some
      (Keeper_tool_in_process_runtime.handle_masc_run_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_agent_dispatch ->
    Some
      (Keeper_tool_in_process_runtime.handle_masc_agent_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_workspace_dispatch ->
    Some
      (Keeper_tool_in_process_runtime.handle_masc_workspace_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_misc_dispatch ->
    Some
      (Keeper_tool_in_process_runtime.handle_masc_misc_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_web_search ->
    Some
      (Keeper_tool_in_process_runtime.handle_web_search_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ?continuation_channel:ctx.continuation_channel
         ?gate_context:ctx.gate_context
         ?gate_grant:ctx.gate_grant
         ~args
         ())
  | Tool_web_fetch ->
    Some
      (Keeper_tool_in_process_runtime.handle_web_fetch_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ?continuation_channel:ctx.continuation_channel
         ?gate_context:ctx.gate_context
         ?gate_grant:ctx.gate_grant
         ~args
         ())
  | Tool_masc_control_dispatch ->
    Some
      (Keeper_tool_in_process_runtime.handle_masc_control_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_agent_timeline_dispatch ->
    Some
      (Keeper_tool_in_process_runtime.handle_masc_agent_timeline_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_schedule_dispatch ->
    Some
      (Keeper_tool_in_process_runtime.handle_masc_schedule_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_keeper_dispatch ->
    Some
      (Keeper_tool_in_process_runtime.handle_masc_keeper_with_outcome
         ~publication_recovery_provider:ctx.publication_recovery.provider
         ?sw:ctx.sw
         ?clock:ctx.clock
         ?proc_mgr:ctx.proc_mgr
         ?net:ctx.net
         ?mcp_session_id:ctx.mcp_session_id
         ?continuation_channel:ctx.continuation_channel
         ?gate_context:ctx.gate_context
         ?gate_grant:ctx.gate_grant
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args
         ())
  | Tool_masc_fusion_dispatch ->
    (* sw/net는 핸들러가 Eio_context(서버 root switch + net)에서 직접 해석한다 —
       턴 스코프 ctx.sw를 쓰면 out-of-band 심의가 턴 종료 시 취소된다. *)
    Some
      (Keeper_tool_in_process_runtime.handle_masc_fusion_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ?continuation_channel:ctx.continuation_channel
         ~args
         ())
  | Tool_masc_fusion_status ->
    (* read-only: reads the in-memory run registry, no server context needed. *)
    Some
      (Keeper_tool_execution.success
         (Keeper_tool_in_process_runtime.handle_masc_fusion_status
            ~meta:ctx.meta
            ~args
            ()))
  | Tool_masc_library_dispatch ->
    Keeper_tool_registered_runtime.handle_registered_tool_with_outcome
      ~config:ctx.config
      ~keeper_name:ctx.meta.name
      ~name
      ~args
  | Tool_masc_local_runtime_dispatch ->
    Some
      (Keeper_tool_in_process_runtime.handle_masc_local_runtime_with_outcome
         ~config:ctx.config
         ~meta:ctx.meta
         ?continuation_channel:ctx.continuation_channel
         ?gate_context:ctx.gate_context
         ?gate_grant:ctx.gate_grant
         ~name
         ~args
         ())
  | Tool_analyze_image ->
    (* read-only vision sub-call; needs [net] (like masc_fusion), threaded from
       the turn-scoped dispatch context. *)
    Some
      (Keeper_tool_in_process_runtime.handle_analyze_image_with_outcome
         ?sw:ctx.sw
         ?clock:ctx.clock
         ?net:ctx.net
         ~meta:ctx.meta
         ~args
         ())
  | Tool_execute
  | Tool_search_files
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file -> None
;;

let handle ctx ~descriptor ~args =
  match descriptor.Keeper_tool_descriptor.executor with
  | Filesystem -> handle_filesystem ctx descriptor args
  | Shell_ir -> handle_shell_ir ctx descriptor args
  | In_process -> handle_in_process ctx descriptor args
;;
