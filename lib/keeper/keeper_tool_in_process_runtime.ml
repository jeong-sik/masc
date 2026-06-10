(** In-process runtime handlers for descriptor-backed workspace tools.

    Each handler reproduces the exact JSON the legacy
    [Keeper_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome] match arm used
    to produce. Outcome inference via [classify_tool_result_payload] yields
    the same Success/Failure label as the legacy
    [success_tool_result]/[failure_tool_result] forces. *)

open Tool_output_validation
open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** [capped_output s] applies the output size gate: strings exceeding
    [max_output_chars] (64 KB) are truncated and a marker appended.
    This is the global middleware for all in-process runtime tool outputs. *)
let capped_output s = cap s

let handle_time_now ~args:_ =
  let now_unix = Time_compat.now () in
  let now_iso = Masc_domain.now_iso () in
  capped_output
    (Yojson.Safe.to_string
       (`Assoc [ "now_iso", `String now_iso; "now_unix", `Float now_unix ]))
;;

let handle_stay_silent ~args:_ =
  capped_output
    (Yojson.Safe.to_string (`Assoc [ "status", `String "silent" ]))
;;

let handle_tools_list ~(meta : keeper_meta) ~args:_ =
  capped_output (Keeper_tool_shared_runtime.keeper_tools_list_json ~meta)
;;

let handle_tool_search ~search_fn ~(args : Yojson.Safe.t) =
  let query = Safe_ops.json_string ~default:"" "query" args |> String.trim in
  let max_results =
    min 10 (max 1 (Safe_ops.json_int ~default:5 "max_results" args))
  in
  if query = ""
  then
    capped_output
      (Yojson.Safe.to_string
         (`Assoc
            [ "error"
            , `String
                "query is required. Good: query='read file'. Bad: query=''."
            ]))
  else capped_output (Yojson.Safe.to_string (search_fn ~query ~max_results))
;;

let handle_context_status ~config ~(meta : keeper_meta) ~ctx_work ~args:_ =
  capped_output
    (Keeper_tool_memory_runtime.keeper_context_status_json ~config ~meta ~ctx_work)
;;

let handle_memory_search ~config ~(meta : keeper_meta) ~ctx_work ~args =
  capped_output
    (Keeper_tool_memory_runtime.keeper_memory_search_json ~config ~meta ~ctx_work ~args)
;;

let handle_memory_write ~config ~(meta : keeper_meta) ~args =
  capped_output
    (Keeper_tool_memory_runtime.keeper_memory_write_json ~config ~meta ~args)
;;

let handle_library_search ~(meta : keeper_meta) ~args =
  let result =
    Tool_library.handle_search
      ~tool_name:"keeper_library_search"
      ~start_time:0.0
      Tool_library.{ agent_name = meta.name }
      args
  in
  capped_output
    (if Tool_result.is_success result
     then Tool_result.message result
     else
       Yojson.Safe.to_string
         (`Assoc [ "error", `String (Tool_result.message result) ]))
;;

let handle_library_read ~(meta : keeper_meta) ~args =
  let result =
    Tool_library.handle_read
      ~tool_name:"keeper_library_read"
      ~start_time:0.0
      Tool_library.{ agent_name = meta.name }
      args
  in
  capped_output
    (if Tool_result.is_success result
     then Tool_result.message result
     else
       Yojson.Safe.to_string
         (`Assoc [ "error", `String (Tool_result.message result) ]))
;;

let handle_ide_annotate ~config ~(meta : keeper_meta) ~args =
  capped_output
    (Keeper_tool_ide_runtime.handle_ide_annotate
       ~config
       ~keeper_name:meta.name
       ~args)
;;

let handle_voice ~config ~(meta : keeper_meta) ~name ~args () =
  capped_output
    (Keeper_tool_voice_runtime.handle_voice_tool ~config ~meta ~name ~args ())
;;

let handle_task ~config ~(meta : keeper_meta) ~name ~args =
  capped_output
    (Keeper_tool_task_runtime.handle_keeper_task_tool ~config ~meta ~name ~args)
;;

let handle_board ~(meta : keeper_meta) ~name ~args =
  capped_output
    (Keeper_tool_board_runtime.handle_keeper_board_tool ~meta ~name ~args)
;;

let handle_masc_board ~name ~args =
  let result = Board_tool_dispatch.handle_tool name args in
  capped_output
    (if Tool_result.is_success result
     then Tool_result.message result
     else
       Yojson.Safe.to_string
         (`Assoc
            [ "error", `String (Tool_result.message result)
            ; "tool", `String name
            ]))
;;

(* RFC-0182 §3.1 — shared helper. Converts the [Tool_result.result option]
   returned by dispatch functions into a capped JSON string. *)
let dispatch_option_to_string ~name (r : Tool_result.result option) : string =
  match r with
  | None ->
      capped_output
        (Yojson.Safe.to_string
           (`Assoc
              [ "error", `String "no result — tool not found or handler not ready"
              ; "tool", `String name
              ]))
  | Some result ->
      capped_output
        (if Tool_result.is_success result
         then Tool_result.message result
         else
           Yojson.Safe.to_string
             (`Assoc
                [ "error", `String (Tool_result.message result)
                ; "tool", `String name
                ]))
;;

(* --- *)

let handle_masc_run ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_run.context = { config; agent_name = Some meta.name } in
  Tool_run.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

let handle_masc_agent ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_agent.context = { config; agent_name = meta.name } in
  Tool_agent.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

(* RFC-0182 §3.1 — masc_workspace_ cluster. Tool_workspace lies LATE in module
   order (depends on Keeper_runtime which depends on much of the keeper
   layer). Keeper_tool_in_process_runtime is EARLY (transitively imported
   by Keeper_tool_dispatch_runtime). A direct static import here closes a cycle.

   Resolution: dispatch through [Workspace_dispatch_ref.dispatch]. A late
   bootstrap module ([Mcp_server_eio_execute]) registers
   [Tool_workspace.dispatch] into the ref. Until registered the ref returns
   [None], surfacing a clear projection error rather than silently
   succeeding with stale state. *)
let handle_masc_workspace ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let dispatched =
    !Workspace_dispatch_ref.dispatch ~config ~agent_name:meta.name ~name ~args
  in
  dispatch_option_to_string ~name dispatched
;;

(* RFC-0182 §3.1 — masc_misc cluster. *)
let handle_masc_misc ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_misc.context = { config; agent_name = meta.name } in
  Tool_misc.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

let handle_masc_control ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_control.context = { config; agent_name = meta.name } in
  Tool_control.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

let handle_masc_agent_timeline ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_agent_timeline.context = { config; agent_name = meta.name } in
  Tool_agent_timeline.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

(* Output assembled by caller. *)