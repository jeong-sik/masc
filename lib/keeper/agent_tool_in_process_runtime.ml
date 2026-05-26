(** In-process runtime handlers for descriptor-backed coordination tools.

    Each handler reproduces the exact JSON the legacy
    [Keeper_exec_tools.execute_keeper_tool_call_with_outcome] match arm used
    to produce. Outcome inference via [classify_tool_result_payload] yields
    the same Success/Failure label as the legacy
    [success_tool_result]/[failure_tool_result] forces. *)

open Keeper_types

let handle_time_now ~args:_ =
  let now_unix = Time_compat.now () in
  let now_iso = Masc_domain.now_iso () in
  Yojson.Safe.to_string
    (`Assoc [ "now_iso", `String now_iso; "now_unix", `Float now_unix ])
;;

let handle_stay_silent ~args:_ =
  Yojson.Safe.to_string (`Assoc [ "status", `String "silent" ])
;;

let handle_tools_list ~(meta : keeper_meta) ~args:_ =
  Keeper_exec_shared.keeper_tools_list_json ~meta
;;

let handle_tool_search ~search_fn ~(args : Yojson.Safe.t) =
  let query = Safe_ops.json_string ~default:"" "query" args |> String.trim in
  let max_results =
    min 10 (max 1 (Safe_ops.json_int ~default:5 "max_results" args))
  in
  if query = ""
  then
    Yojson.Safe.to_string
      (`Assoc
         [ "error"
         , `String
             "query is required. Good: query='read file'. Bad: query=''."
         ])
  else Yojson.Safe.to_string (search_fn ~query ~max_results)
;;

let handle_context_status ~config ~(meta : keeper_meta) ~ctx_work ~args:_ =
  Keeper_exec_memory.keeper_context_status_json ~config ~meta ~ctx_work
;;

let handle_memory_search ~config ~(meta : keeper_meta) ~ctx_work ~args =
  Keeper_exec_memory.keeper_memory_search_json ~config ~meta ~ctx_work ~args
;;

let handle_memory_write ~config ~(meta : keeper_meta) ~args =
  Keeper_exec_memory.keeper_memory_write_json ~config ~meta ~args
;;

let handle_library_search ~(meta : keeper_meta) ~args =
  let result =
    Tool_library.handle_search
      ~tool_name:"keeper_library_search"
      ~start_time:0.0
      Tool_library.{ agent_name = meta.name }
      args
  in
  if result.Tool_result.success
  then result.Tool_result.message
  else
    Yojson.Safe.to_string
      (`Assoc [ "error", `String result.Tool_result.message ])
;;

let handle_library_read ~(meta : keeper_meta) ~args =
  let result =
    Tool_library.handle_read
      ~tool_name:"keeper_library_read"
      ~start_time:0.0
      Tool_library.{ agent_name = meta.name }
      args
  in
  if result.Tool_result.success
  then result.Tool_result.message
  else
    Yojson.Safe.to_string
      (`Assoc [ "error", `String result.Tool_result.message ])
;;

let handle_ide_annotate ~config ~(meta : keeper_meta) ~args =
  Agent_tool_ide_runtime.handle_ide_annotate
    ~config
    ~keeper_name:meta.name
    ~args
;;

let handle_voice ~(meta : keeper_meta) ~name ~args =
  Agent_tool_voice_runtime.handle_voice_tool ~meta ~name ~args
;;

let handle_task ~config ~(meta : keeper_meta) ~name ~args =
  Keeper_exec_task.handle_keeper_task_tool ~config ~meta ~name ~args
;;

let handle_board ~(meta : keeper_meta) ~name ~args =
  Agent_tool_board_runtime.handle_keeper_board_tool ~meta ~name ~args
;;

let handle_masc_board ~name ~args =
  let result = Tool_board_dispatch.handle_tool name args in
  if result.Tool_result.success
  then result.Tool_result.message
  else
    Yojson.Safe.to_string
      (`Assoc
         [ "error", `String result.Tool_result.message
         ; "tool", `String name
         ])
;;
