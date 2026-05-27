(** In-process runtime handlers for descriptor-backed coordination tools.

    Each handler reproduces the exact JSON the legacy
    [Agent_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome] match arm used
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
  Agent_tool_shared_runtime.keeper_tools_list_json ~meta
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

  in
  if Tool_result.is_success result
  then Tool_result.message result
  else
    Yojson.Safe.to_string
      (`Assoc [ "error", `String (Tool_result.message result) ])
;;

let handle_library_read ~(meta : keeper_meta) ~args =
  let result =
    Tool_library.handle_read
      ~tool_name:"keeper_library_read"
      ~start_time:0.0
      Tool_library.{ agent_name = meta.name }
      args

  in
  if Tool_result.is_success result
  then Tool_result.message result
  else
    Yojson.Safe.to_string
      (`Assoc [ "error", `String (Tool_result.message result) ])
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
    Tool_board_dispatch.handle_tool name args
  in
  if Tool_result.is_success result
  then Tool_result.message result
  else
    Yojson.Safe.to_string
      (`Assoc
         [ "error", `String (Tool_result.message result)
         ; "tool", `String name
         ])
;;

(* RFC-0182 §3.1 — shared helper. Converts the [Tool_result.result option]
   returned by [Tool_*.dispatch] to the in_process_runtime string-output
   convention. [None] means the dispatcher does not recognise the name
   (the descriptor → dispatcher mapping is misconfigured if this fires
   for a tool reachable via [descriptors_for_internal]). *)
let dispatch_option_to_string ~name = function
  | Some (result : Tool_result.result) ->
    if Tool_result.is_success result
    then Tool_result.message result
    else
      Yojson.Safe.to_string
        (`Assoc [ "error", `String (Tool_result.message result) ])
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
   by Agent_tool_dispatch_runtime). A direct static import here closes a cycle.

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

(* RFC-0182 §3.1 — masc_tool_shard cluster.  [Tool_shard.execute]
   returns the older [(bool * Yojson.Safe.t)] tuple (predates RFC-0189
   typed-result migration), same shape as Tool_local_runtime.  Tool_shard
   has no Keeper/Coord deps so no cycle concern.

   TEL-OK: descriptor projection — telemetry lives in [Tool_shard.execute]
   and the upstream [Agent_tool_dispatch_runtime] dispatch wrapper. *)
let handle_masc_tool_shard ~name ~args =
  let ok, payload = Tool_shard.execute name args in
  if ok
  then Yojson.Safe.to_string payload
  else Yojson.Safe.to_string (`Assoc [ "error", payload ])
;;

(* RFC-0182 §3.1 — masc_surface_audit singleton.  Body is pure
   ([Dashboard_surface_readiness.json ?surface_id ()]) with no ctx
   requirements; direct import is cycle-safe.

   TEL-OK: read-only dashboard surface snapshot, telemetry lives in
   [Dashboard_surface_readiness]. *)
let handle_masc_surface_audit ~args =
  let surface_id = Safe_ops.json_string_opt "surface_id" args in
  Yojson.Safe.to_string (Dashboard_surface_readiness.json ?surface_id ())
;;

(* RFC-0182 §3.1 — masc_keeper cluster.  [Tool_keeper] lives in lib/
   (late) but exposes keeper coordination tools.  A direct import here
   closes a cycle, so we dispatch through [Keeper_dispatch_ref].  Today
   only [masc_keeper_list] is registered; remaining keeper tools depend
   on the Eio context and await Phase 5 Eio plumbing.

   TEL-OK: descriptor projection — telemetry lives in the underlying
   [Tool_keeper] / [Tool_keeper_ops] / [Keeper_status_detail] handlers
   that the registered ref delegates to. *)
let handle_masc_keeper
      ?sw
      ?clock
      ?proc_mgr
      ?net
      ?mcp_session_id
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~name
      ~args
      ()
  =
  let result =
    !Keeper_dispatch_ref.dispatch
      ~config
      ~agent_name:meta.agent_name
      ?sw
      ?clock
      ?proc_mgr
      ?net
      ?mcp_session_id
      ~name
      ~args
      ()
  in
  dispatch_option_to_string ~name result
;;

(* RFC-0182 §3.1 — masc_persona cluster.  [Keeper_persona] /
   [Keeper_persona_authoring] transitively pull in [Keeper_turn_driver],
   which closes a cycle if imported here.  Resolution: dispatch
   through [Persona_dispatch_ref].  Tool_keeper (lib/, late) registers
   the ctx-free entry points at module load.

   TEL-OK: descriptor projection — telemetry lives in [Keeper_persona] /
   [Keeper_persona_authoring] backing handlers. *)
let handle_masc_persona ~name ~args =
  !Persona_dispatch_ref.dispatch ~name ~args |> dispatch_option_to_string ~name
;;

(* RFC-0182 §3.1 — masc_approval cluster.  Ports the same dispatch logic
   used by [Tool_inline_dispatch] for [masc_approval_pending/get/resolve]
   so keepers can reach the approval queue via descriptor projection.

   Cycle safety: [Keeper_approval_queue] is a lib/keeper module with no
   reverse deps on [Agent_tool_*].  Importing here introduces no
   late-dependency cycle.

   TEL-OK: descriptor projection — telemetry lives in
   [Keeper_approval_queue] (queue mutation events + Prometheus counters
   in the resolve path). *)
let handle_masc_approval ~name ~args =
  match name with
  | "masc_approval_pending" ->
    Yojson.Safe.to_string (Keeper_approval_queue.list_pending_json ())
  | "masc_approval_get" ->
    let id = Safe_ops.json_string ~default:"" "id" args |> String.trim in
    if String.equal id ""
    then Yojson.Safe.to_string (`Assoc [ "error", `String "id is required" ])
    else (
      match Keeper_approval_queue.get_pending_json ~id with
      | Some json -> Yojson.Safe.to_string json
      | None ->
        Yojson.Safe.to_string
          (`Assoc
             [ "error"
             , `String
                 (Printf.sprintf
                    "approval %s is no longer pending or was not found. \
                     Refresh with masc_approval_pending before \
                     approving/rejecting."
                    id)
             ]))
  | "masc_approval_resolve" ->
    let id = Safe_ops.json_string ~default:"" "id" args |> String.trim in
    let decision_str = Safe_ops.json_string ~default:"approve" "decision" args in
    if String.equal id ""
    then Yojson.Safe.to_string (`Assoc [ "error", `String "id is required" ])
    else (
      let decision =
        match String.lowercase_ascii decision_str with
        | "approve" -> Agent_sdk.Hooks.Approve
        | "reject" ->
          let reason =
            Safe_ops.json_string ~default:"operator rejected" "reason" args
          in
          Agent_sdk.Hooks.Reject reason
        | _ ->
          Agent_sdk.Hooks.Reject
            (Printf.sprintf "unknown decision: %s" decision_str)
      in
      match Keeper_approval_queue.resolve ~id ~decision with
      | Ok () ->
        Yojson.Safe.to_string
          (`Assoc
             [ "resolved", `String id
             ; "decision", `String decision_str
             ])
      | Error err ->
        Yojson.Safe.to_string
          (`Assoc
             [ "error"
             , `String (Keeper_approval_queue.resolve_error_to_string err)
             ]))
  | other ->
    Yojson.Safe.to_string
      (`Assoc
         [ "error"
         , `String
             (Printf.sprintf
                "descriptor projection: masc_approval cluster did not \
                 recognise %S"
                other)
         ])
;;

let handle_masc_local_runtime ~name ~args =
  Tool_local_runtime.dispatch () ~name ~args |> dispatch_option_to_string ~name
;;
