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
  Keeper_exec_task.handle_keeper_task_tool ~config ~meta ~name ~args
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

(* RFC-0182 §3.1 — masc_coord_ cluster (status / heartbeat / check /
   reset / goal_ tools). [Tool_coord.dispatch] cannot be called directly
   from here: it transitively depends on [Keeper_runtime →
   Keeper_exec_tools → Agent_tool_runtime → Agent_tool_in_process_runtime],
   so importing it would form a dependency cycle. Resolution options for
   the follow-up PR: (a) split [Tool_coord] into a pure dispatch leaf,
   (b) move keeper-coupled handlers out of [Tool_coord], or (c) lift the
   cluster handler out of [lib/keeper/] into a layer above. For now the
   descriptor entries route via this stub which surfaces the constraint
   to callers instead of silently failing. *)
let handle_masc_coord ~config:_ ~meta:_ ~name ~args:_ =
  Yojson.Safe.to_string
    (`Assoc
       [ "error"
       , `String
           (Printf.sprintf
              "%s descriptor projection is pending: Tool_coord cycle resolution \
               (see RFC-0182 §3.1 cycle audit note)."
              name)
       ])
;;

(* RFC-0182 §3.1 — masc_misc cluster. Tool_misc transitively depends on
   Config → Transport → Transport_read_model, and via Config also reaches
   Tool_agent_timeline → Keeper_agent_error → ... → Agent_tool_runtime.
   Importing it here would form a cycle. Same constraint as masc_coord
   and masc_agent_timeline — stub until cycle is broken by upstream
   refactor (see RFC-0182 §3.1 cycle audit notes). *)
let handle_masc_misc ~config:_ ~meta:_ ~name ~args:_ =
  Yojson.Safe.to_string
    (`Assoc
       [ "error"
       , `String
           (Printf.sprintf
              "%s descriptor projection is pending: Tool_misc cycle resolution \
               (Config -> Transport -> Transport_read_model)."
              name)
       ])
;;

(* RFC-0182 §3.1 — masc_control cluster. Tool_control may also cycle via
   Config; stubbed for consistency with masc_misc / masc_agent_timeline /
   masc_coord. To re-enable: confirm cycle and break upstream, or move
   the handler to a layer above lib/keeper/. *)
let handle_masc_control ~config:_ ~meta:_ ~name ~args:_ =
  Yojson.Safe.to_string
    (`Assoc
       [ "error"
       , `String
           (Printf.sprintf
              "%s descriptor projection is pending: Tool_control cycle resolution \
               (likely shares Config-mediated cycle with Tool_misc)."
              name)
       ])
;;

(* RFC-0182 §3.1 — masc_agent_timeline singleton. Same dependency-cycle
   constraint as masc_coord (Tool_agent_timeline transitively depends on
   Keeper_agent_error). Stub for now. *)
let handle_masc_agent_timeline ~config:_ ~meta:_ ~name ~args:_ =
  Yojson.Safe.to_string
    (`Assoc
       [ "error"
       , `String
           (Printf.sprintf
              "%s descriptor projection is pending: Tool_agent_timeline cycle \
               resolution (same constraint as masc_coord cluster)."
              name)
       ])
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
