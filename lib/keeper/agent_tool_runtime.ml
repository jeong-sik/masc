(** Runtime dispatch for descriptor-backed agent tools. *)

open Agent_tool_descriptor

(* RFC-0182 Phase 5 PR-A (RFC §12): optional Eio resource fields.
   When set, descriptor handlers like masc_keeper_msg / masc_keeper_up /
   masc_operator_* / masc_persona_generate can call into Eio-bound
   primitives (start_keepalive, Keeper_msg_async.submit, LLM-call fibers,
   Operator_control.context) without re-introducing dispatch-ref
   plumbing.  Default = [None]; callers without Eio context (OAS handler,
   tests) leave them unset and the Eio-bound descriptor handlers return
   a typed "Eio context not provided" failure instead of crashing. *)
type context =
  { config : Coord.config
  ; meta : Keeper_types.keeper_meta
  ; ctx_work : Keeper_types.working_context
  ; turn_sandbox_factory : Keeper_sandbox_factory.t option
  ; turn_sandbox_factory_git : Keeper_sandbox_factory.t option
  ; exec_cache : Masc_exec.Exec_cache.t option
  ; search_fn : query:string -> max_results:int -> Yojson.Safe.t
  ; sw : Eio.Switch.t option
  ; clock : float Eio.Time.clock_ty Eio.Resource.t option
  ; proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option
  ; mcp_session_id : string option
  }

let descriptor_for_internal internal_name =
  match Agent_tool_descriptor.descriptors_for_internal internal_name with
  | descriptor :: _ -> Some descriptor
  | [] -> None
;;

let handle_filesystem ctx descriptor args =
  match descriptor.Agent_tool_descriptor.runtime_handler with
  | Tool_read_file ->
    Some
      (Agent_tool_filesystem_runtime.handle_read_file
         ~turn_sandbox_factory:ctx.turn_sandbox_factory
         ~config:ctx.config
         ~keeper_name:ctx.meta.name
         ~args)
  | Tool_edit_file | Tool_write_file ->
    Some
      (Agent_tool_filesystem_runtime.handle_file_write
         ~turn_sandbox_factory:ctx.turn_sandbox_factory
         ~config:ctx.config
         ~keeper_name:ctx.meta.name
         ~args)
  | Tool_execute
  | Tool_search_files
  | Tool_remote_mcp
  | Tool_time_now
  | Tool_stay_silent
  | Tool_tools_list
  | Tool_tool_search
  | Tool_context_status
  | Tool_memory_search
  | Tool_memory_write
  | Tool_library_search
  | Tool_library_read
  | Tool_ide_annotate
  | Tool_voice_dispatch
  | Tool_task_dispatch
  | Tool_board_dispatch
  | Tool_masc_board_dispatch
  | Tool_masc_task_dispatch
  | Tool_masc_plan_dispatch
  | Tool_masc_run_dispatch
  | Tool_masc_agent_dispatch
  | Tool_masc_coord_dispatch
  | Tool_masc_misc_dispatch
  | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch
  | Tool_masc_local_runtime_dispatch
  | Tool_masc_tool_shard_dispatch
  | Tool_masc_approval_dispatch
  | Tool_masc_persona_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_surface_audit -> None
;;

(* Shell IR mechanics live under Execute lowerers. Agent_tool_command_runtime is
   the descriptor-selected runtime boundary that binds Execute/SearchFiles to
   those lowerers without keeping them under the keeper_exec* axis. *)
let handle_shell_ir ctx descriptor args =
  match descriptor.Agent_tool_descriptor.runtime_handler with
  | Tool_execute ->
    Some
      (Agent_tool_command_runtime.handle_tool_execute
         ~turn_sandbox_factory:ctx.turn_sandbox_factory
         ~turn_sandbox_factory_git:ctx.turn_sandbox_factory_git
         ~exec_cache:ctx.exec_cache
         ~config:ctx.config
         ~meta:ctx.meta
         ~args
         ())
  | Tool_search_files ->
    Some
      (Agent_tool_command_runtime.handle_tool_search_files
         ~turn_sandbox_factory:ctx.turn_sandbox_factory
         ~exec_cache:ctx.exec_cache
         ~config:ctx.config
         ~meta:ctx.meta
         ~args)
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_remote_mcp
  | Tool_time_now
  | Tool_stay_silent
  | Tool_tools_list
  | Tool_tool_search
  | Tool_context_status
  | Tool_memory_search
  | Tool_memory_write
  | Tool_library_search
  | Tool_library_read
  | Tool_ide_annotate
  | Tool_voice_dispatch
  | Tool_task_dispatch
  | Tool_board_dispatch
  | Tool_masc_board_dispatch
  | Tool_masc_task_dispatch
  | Tool_masc_plan_dispatch
  | Tool_masc_run_dispatch
  | Tool_masc_agent_dispatch
  | Tool_masc_coord_dispatch
  | Tool_masc_misc_dispatch
  | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch
  | Tool_masc_local_runtime_dispatch
  | Tool_masc_tool_shard_dispatch
  | Tool_masc_approval_dispatch
  | Tool_masc_persona_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_surface_audit -> None
;;

let handle_remote_mcp ctx descriptor args =
  match descriptor.Agent_tool_descriptor.runtime_handler with
  | Tool_remote_mcp ->
    Some
      (match
         Agent_tool_remote_mcp_runtime.handle_registered_remote_tool
           ~config:ctx.config
           ~keeper_name:ctx.meta.name
           ~name:descriptor.internal_name
           ~args
       with
       | Some raw_output -> raw_output
       | None ->
         Agent_tool_shared_runtime.error_json
           (Printf.sprintf
              "descriptor remote tool handler is not registered: %s"
              descriptor.internal_name))
  | Tool_execute
  | Tool_search_files
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_time_now
  | Tool_stay_silent
  | Tool_tools_list
  | Tool_tool_search
  | Tool_context_status
  | Tool_memory_search
  | Tool_memory_write
  | Tool_library_search
  | Tool_library_read
  | Tool_ide_annotate
  | Tool_voice_dispatch
  | Tool_task_dispatch
  | Tool_board_dispatch
  | Tool_masc_board_dispatch
  | Tool_masc_task_dispatch
  | Tool_masc_plan_dispatch
  | Tool_masc_run_dispatch
  | Tool_masc_agent_dispatch
  | Tool_masc_coord_dispatch
  | Tool_masc_misc_dispatch
  | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch
  | Tool_masc_local_runtime_dispatch
  | Tool_masc_tool_shard_dispatch
  | Tool_masc_approval_dispatch
  | Tool_masc_persona_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_surface_audit -> None
;;

let handle_in_process ctx descriptor args =
  let name = descriptor.Agent_tool_descriptor.internal_name in
  match descriptor.Agent_tool_descriptor.runtime_handler with
  | Tool_time_now ->
    Some (Agent_tool_in_process_runtime.handle_time_now ~args)
  | Tool_stay_silent ->
    Some (Agent_tool_in_process_runtime.handle_stay_silent ~args)
  | Tool_tools_list ->
    Some (Agent_tool_in_process_runtime.handle_tools_list ~meta:ctx.meta ~args)
  | Tool_tool_search ->
    Some
      (Agent_tool_in_process_runtime.handle_tool_search
         ~search_fn:ctx.search_fn
         ~args)
  | Tool_context_status ->
    Some
      (Agent_tool_in_process_runtime.handle_context_status
         ~config:ctx.config
         ~meta:ctx.meta
         ~ctx_work:ctx.ctx_work
         ~args)
  | Tool_memory_search ->
    Some
      (Agent_tool_in_process_runtime.handle_memory_search
         ~config:ctx.config
         ~meta:ctx.meta
         ~ctx_work:ctx.ctx_work
         ~args)
  | Tool_memory_write ->
    Some
      (Agent_tool_in_process_runtime.handle_memory_write
         ~config:ctx.config
         ~meta:ctx.meta
         ~args)
  | Tool_library_search ->
    Some
      (Agent_tool_in_process_runtime.handle_library_search ~meta:ctx.meta ~args)
  | Tool_library_read ->
    Some
      (Agent_tool_in_process_runtime.handle_library_read ~meta:ctx.meta ~args)
  | Tool_ide_annotate ->
    Some
      (Agent_tool_in_process_runtime.handle_ide_annotate
         ~config:ctx.config
         ~meta:ctx.meta
         ~args)
  | Tool_voice_dispatch ->
    Some
      (Agent_tool_in_process_runtime.handle_voice ~meta:ctx.meta ~name ~args)
  | Tool_task_dispatch ->
    Some
      (Agent_tool_in_process_runtime.handle_task
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_board_dispatch ->
    Some
      (Agent_tool_in_process_runtime.handle_board ~meta:ctx.meta ~name ~args)
  | Tool_masc_board_dispatch ->
    Some (Agent_tool_in_process_runtime.handle_masc_board ~name ~args)
  | Tool_masc_task_dispatch ->
    Some
      (Agent_tool_in_process_runtime.handle_masc_task
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_plan_dispatch ->
    Some
      (Agent_tool_in_process_runtime.handle_masc_plan
         ~config:ctx.config
         ~name
         ~args)
  | Tool_masc_run_dispatch ->
    Some
      (Agent_tool_in_process_runtime.handle_masc_run
         ~config:ctx.config
         ~name
         ~args)
  | Tool_masc_agent_dispatch ->
    Some
      (Agent_tool_in_process_runtime.handle_masc_agent
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_coord_dispatch ->
    Some
      (Agent_tool_in_process_runtime.handle_masc_coord
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_misc_dispatch ->
    Some
      (Agent_tool_in_process_runtime.handle_masc_misc
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_control_dispatch ->
    Some
      (Agent_tool_in_process_runtime.handle_masc_control
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_agent_timeline_dispatch ->
    Some
      (Agent_tool_in_process_runtime.handle_masc_agent_timeline
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_local_runtime_dispatch ->
    Some (Agent_tool_in_process_runtime.handle_masc_local_runtime ~name ~args)
  | Tool_masc_tool_shard_dispatch ->
    Some (Agent_tool_in_process_runtime.handle_masc_tool_shard ~name ~args)
  | Tool_masc_approval_dispatch ->
    Some (Agent_tool_in_process_runtime.handle_masc_approval ~name ~args)
  | Tool_masc_persona_dispatch ->
    Some (Agent_tool_in_process_runtime.handle_masc_persona ~name ~args)
  | Tool_masc_keeper_dispatch ->
    Some
      (Agent_tool_in_process_runtime.handle_masc_keeper
         ~config:ctx.config
         ~meta:ctx.meta
         ~name
         ~args)
  | Tool_masc_surface_audit ->
    Some (Agent_tool_in_process_runtime.handle_masc_surface_audit ~args)
  | Tool_execute
  | Tool_search_files
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_remote_mcp -> None
;;

let handle ctx ~descriptor ~args =
  match descriptor.Agent_tool_descriptor.executor with
  | Filesystem -> handle_filesystem ctx descriptor args
  | Shell_ir -> handle_shell_ir ctx descriptor args
  | Remote_mcp -> handle_remote_mcp ctx descriptor args
  | In_process -> handle_in_process ctx descriptor args
;;

let handle_internal ctx ~name ~args =
  match descriptor_for_internal name with
  | None -> None
  | Some descriptor -> handle ctx ~descriptor ~args
;;
