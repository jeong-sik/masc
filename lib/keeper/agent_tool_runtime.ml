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
  match Agent_tool_descriptor.public_descriptors_for_internal internal_name with
  | descriptor :: _ -> Some descriptor
  | [] -> None
;;

let handle_filesystem ctx descriptor args =
  match descriptor.Agent_tool_descriptor.runtime_handler with
  | Tool_read_file ->
    Some
      (Keeper_exec_fs.handle_keeper_fs_read
         ~turn_sandbox_factory:ctx.turn_sandbox_factory
         ~config:ctx.config
         ~keeper_name:ctx.meta.name
         ~args)
  | Tool_edit_file | Tool_write_file ->
    Some
      (Keeper_exec_fs.handle_keeper_fs_edit
         ~turn_sandbox_factory:ctx.turn_sandbox_factory
         ~config:ctx.config
         ~keeper_name:ctx.meta.name
         ~args)
  | Tool_execute | Tool_search_files | Tool_remote_mcp -> None
;;

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
  | Tool_read_file | Tool_edit_file | Tool_write_file | Tool_remote_mcp -> None
;;

let handle_remote_mcp ctx descriptor args =
  match descriptor.Agent_tool_descriptor.runtime_handler with
  | Tool_remote_mcp ->
    Some
      (match
         Keeper_exec_masc.handle_registered_keeper_tool
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
  | Tool_write_file -> None
;;

let handle ctx ~descriptor ~args =
  match descriptor.Agent_tool_descriptor.executor with
  | Filesystem -> handle_filesystem ctx descriptor args
  | Shell_ir -> handle_shell_ir ctx descriptor args
  | Remote_mcp -> handle_remote_mcp ctx descriptor args
  | In_process | Gh_cli | Oas_bridge -> None
;;

let handle_internal ctx ~name ~args =
  match descriptor_for_internal name with
  | None -> None
  | Some descriptor -> handle ctx ~descriptor ~args
;;
