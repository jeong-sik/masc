(** Runtime dispatch for descriptor-backed agent tools. *)

open Agent_tool_descriptor

type context =
  { config : Coord.config
  ; meta : Keeper_types.keeper_meta
  ; turn_sandbox_factory : Keeper_sandbox_factory.t option
  ; turn_sandbox_factory_git : Keeper_sandbox_factory.t option
  ; exec_cache : Masc_exec.Exec_cache.t option
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
  | Tool_execute | Tool_search_files | Tool_remote_mcp | Tool_time_now
  | Tool_stay_silent | Tool_tools_list -> None
;;

(* Dispatch asymmetry: Filesystem and Remote_mcp go through Agent_tool_* runtime
   wrappers (handle_filesystem / handle_remote_mcp above), but Shell_ir
   dispatches directly into Keeper_exec_shell. This is intentional: Shell IR
   mechanics (Keeper_shell_ir / Keeper_shell_command_* / Keeper_shell_path /
   Keeper_shell_readonly_policy etc.) legitimately live in the keeper
   namespace as the typed Bash lowering and exec pipeline. A thin
   Agent_tool_shell_runtime wrapper that only renames Keeper_exec_shell
   functions would be substitution, not abstraction — it would preserve the
   coupling while reducing readability. Re-evaluate only if Shell IR
   substantive logic moves out of keeper_shell_* into a descriptor-owned
   module. *)
let handle_shell_ir ctx descriptor args =
  match descriptor.Agent_tool_descriptor.runtime_handler with
  | Tool_execute ->
    Some
      (Keeper_exec_shell.handle_tool_execute
         ~turn_sandbox_factory:ctx.turn_sandbox_factory
         ~turn_sandbox_factory_git:ctx.turn_sandbox_factory_git
         ~exec_cache:ctx.exec_cache
         ~config:ctx.config
         ~meta:ctx.meta
         ~args
         ())
  | Tool_search_files ->
    Some
      (Keeper_exec_shell.handle_tool_search_files
         ~turn_sandbox_factory:ctx.turn_sandbox_factory
         ~exec_cache:ctx.exec_cache
         ~config:ctx.config
         ~meta:ctx.meta
         ~args)
  | Tool_read_file | Tool_edit_file | Tool_write_file | Tool_remote_mcp
  | Tool_time_now | Tool_stay_silent | Tool_tools_list -> None
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
         Keeper_exec_shared.error_json
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
  | Tool_tools_list -> None
;;

let handle_in_process ctx descriptor args =
  match descriptor.Agent_tool_descriptor.runtime_handler with
  | Tool_time_now -> Some (Agent_tool_in_process_runtime.handle_time_now ~args)
  | Tool_stay_silent ->
    Some (Agent_tool_in_process_runtime.handle_stay_silent ~args)
  | Tool_tools_list ->
    Some (Agent_tool_in_process_runtime.handle_tools_list ~meta:ctx.meta ~args)
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
