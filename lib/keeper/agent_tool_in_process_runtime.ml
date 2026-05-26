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
  Agent_tool_memory_runtime.keeper_context_status_json ~config ~meta ~ctx_work
;;

let handle_memory_search ~config ~(meta : keeper_meta) ~ctx_work ~args =
  Agent_tool_memory_runtime.keeper_memory_search_json ~config ~meta ~ctx_work ~args
;;

let handle_memory_write ~config ~(meta : keeper_meta) ~args =
  Agent_tool_memory_runtime.keeper_memory_write_json ~config ~meta ~args
;;

let handle_library_search ~(meta : keeper_meta) ~args =
  let result =
    Tool_library.handle_search
      ~tool_name:"keeper_library_search"
      ~start_time:0.0
      Tool_library.{ agent_name = meta.name }
      args
    |> Tool_result.to_legacy
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
    |> Tool_result.to_legacy
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
  Agent_tool_task_runtime.handle_keeper_task_tool ~config ~meta ~name ~args
;;

let handle_board ~(meta : keeper_meta) ~name ~args =
  Agent_tool_board_runtime.handle_keeper_board_tool ~meta ~name ~args
;;

let handle_masc_board ~name ~args =
  let result =
    Tool_board_dispatch.handle_tool name args |> Tool_result.to_legacy
  in
  if result.Tool_result.success
  then result.Tool_result.message
  else
    Yojson.Safe.to_string
      (`Assoc
         [ "error", `String result.Tool_result.message
         ; "tool", `String name
         ])
;;

(* RFC-0182 §3.1 — shared helper. Converts the [Tool_result.t option]
   returned by [Tool_*.dispatch] to the in_process_runtime string-output
   convention. [None] means the dispatcher does not recognise the name
   (the descriptor → dispatcher mapping is misconfigured if this fires
   for a tool reachable via [descriptors_for_internal]). *)
let dispatch_option_to_string ~name = function
  | Some (result : Tool_result.t) ->
    if result.Tool_result.success
    then result.Tool_result.message
    else
      Yojson.Safe.to_string
        (`Assoc [ "error", `String result.Tool_result.message ])
  | None ->
    Yojson.Safe.to_string
      (`Assoc
         [ "error"
         , `String
             (Printf.sprintf
                "descriptor projection: cluster dispatcher did not recognise %S"
                name)
         ])
;;

let handle_masc_task ~(config : Coord.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_task.context =
    { config; agent_name = meta.name; sw = None }
  in
  Tool_task.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

let handle_masc_plan ~(config : Coord.config) ~name ~args =
  let ctx : Tool_plan.context = { config } in
  Tool_plan.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

let handle_masc_run ~(config : Coord.config) ~name ~args =
  let ctx : Tool_run.context = { config } in
  Tool_run.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

let handle_masc_agent ~(config : Coord.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_agent.context = { config; agent_name = meta.name } in
  Tool_agent.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

(* RFC-0182 §3.1 — masc_coord_ cluster. Tool_coord lies LATE in module
   order (depends on Keeper_runtime which depends on much of the keeper
   layer). Agent_tool_in_process_runtime is EARLY (transitively imported
   by Keeper_exec_tools). A direct static import here closes a cycle.

   Resolution: dispatch through [Coord_dispatch_ref.dispatch]. A late
   bootstrap module ([Mcp_server_eio_execute]) registers
   [Tool_coord.dispatch] into the ref. Until registered the ref returns
   [None], surfacing a clear projection error rather than silently
   succeeding with stale state. *)
let handle_masc_coord ~(config : Coord.config) ~(meta : keeper_meta) ~name ~args =
  let dispatched =
    !Coord_dispatch_ref.dispatch ~config ~agent_name:meta.name ~name ~args
  in
  dispatch_option_to_string ~name dispatched
;;

(* RFC-0182 §3.1 — masc_misc cluster. Active after Turn_mode_codec
   extraction (2026-05-27) broke the Tool_agent_timeline → Keeper_*
   back edge that previously cycled Config → ... →
   Agent_tool_in_process_runtime. *)
let handle_masc_misc ~(config : Coord.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_misc.context = { config; agent_name = meta.name } in
  Tool_misc.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

let handle_masc_control ~(config : Coord.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_control.context = { config; agent_name = meta.name } in
  Tool_control.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

let handle_masc_agent_timeline ~(config : Coord.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_agent_timeline.context = { config; agent_name = meta.name } in
  Tool_agent_timeline.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

let handle_masc_local_runtime ~name ~args =
  (* Tool_local_runtime.dispatch is polymorphic in ctx (handlers ignore it).
     The result type is the older [bool * string] tuple from
     Tool_local_runtime_core, not Tool_result.t — predates RFC-0189
     typed-result migration. Convert tuple → string via the same
     success/failure convention used elsewhere. *)
  match Tool_local_runtime.dispatch () ~name ~args with
  | Some (true, payload) -> payload
  | Some (false, payload) ->
    Yojson.Safe.to_string (`Assoc [ "error", `String payload ])
  | None ->
    Yojson.Safe.to_string
      (`Assoc
         [ "error"
         , `String
             (Printf.sprintf
                "descriptor projection: Tool_local_runtime did not recognise %S"
                name)
         ])
;;
