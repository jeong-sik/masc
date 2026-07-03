(** In-process runtime handlers for descriptor-backed workspace tools.

    Each handler reproduces the exact JSON the legacy
    [Keeper_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome] match arm used
    to produce. Outcome inference via [classify_tool_result_payload] yields
    the same Success/Failure label as the legacy
    [success_tool_result]/[failure_tool_result] forces. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let handle_time_now ~args:_ =
  let now_unix = Time_compat.now () in
  let now_iso = Masc_domain.now_iso () in
  Yojson.Safe.to_string
    (`Assoc [ "now_iso", `String now_iso; "now_unix", `Float now_unix ])
;;

let handle_tools_list ~(meta : keeper_meta) ~args:_ =
  Keeper_tool_shared_runtime.keeper_tools_list_json ~meta
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
  Keeper_tool_memory_runtime.keeper_context_status_json ~config ~meta ~ctx_work
;;

let handle_memory_search ~config ~(meta : keeper_meta) ~ctx_work ~args =
  Keeper_tool_memory_runtime.keeper_memory_search_json ~config ~meta ~ctx_work ~args
;;

let handle_memory_write ~config ~(meta : keeper_meta) ~args =
  Keeper_tool_memory_runtime.keeper_memory_write_json ~config ~meta ~args
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

let handle_surface_read ~config ~(meta : keeper_meta) ~args =
  let surface = Safe_ops.json_string ~default:"" "surface" args in
  let limit =
    Safe_ops.json_int ~default:Keeper_surface_read.default_limit "limit" args
  in
  let before = Safe_ops.json_float_opt "before" args in
  let page =
    Keeper_chat_store.load_page
      ~base_dir:config.Workspace.base_path
      ~keeper_name:meta.name
      ?before
      ()
  in
  let notes =
    Keeper_person_notes.notes
      ~base_dir:config.Workspace.base_path
      ~keeper_name:meta.name
  in
  Keeper_surface_read.respond ~surface ~limit
    ~has_more:page.Keeper_chat_store.has_more
    ~notes
    page.Keeper_chat_store.messages
;;

let handle_person_note_set ~config ~(meta : keeper_meta) ~args =
  let speaker_id =
    String.trim (Safe_ops.json_string ~default:"" "speaker_id" args)
  in
  if speaker_id = "" then
    Yojson.Safe.to_string
      (`Assoc
        [ ( "error"
          , `String
              "speaker_id is required. Use the id field from the \
               keeper_surface_read roster." )
        ])
  else begin
    (* Distinguish field-absent (LLM omission) from field-present-empty:
       [json_string_opt] returns [None] when [note] is absent and [Some s] when
       it is present (including ""). An explicit "" is the deliberate tombstone
       that clears the note (RFC-0229 §3.1); an omitted [note] must be rejected,
       not silently cleared. The prior [json_string ~default:""] collapsed both
       to "", so a keeper that omitted [note] silently deleted an existing note
       (OAS anti-pattern #2: Unknown -> Permissive Default). The structural
       dispatch-level gap (in-process dispatch skips required validation) is
       tracked in #21875. *)
    match Safe_ops.json_string_opt "note" args with
    | None ->
      Yojson.Safe.to_string
        (`Assoc
          [ ( "error"
            , `String
                "note is required. Send an empty string to clear (tombstone) \
                 an existing note." )
          ])
    | Some note ->
      Keeper_person_notes.set_note
        ~base_dir:config.Workspace.base_path
        ~keeper_name:meta.name
        ~speaker_id
        ~note
        ();
      Yojson.Safe.to_string
        (`Assoc
          [ "ok", `Bool true
          ; "speaker_id", `String speaker_id
          ; "cleared", `Bool (String.trim note = "")
          ])
  end
;;

let slack_token_opt () =
  match Sys.getenv_opt "MASC_SLACK_BOT_TOKEN" with
  | None -> None
  | Some raw ->
      let trimmed = String.trim raw in
      if String.equal trimmed "" then None else Some trimmed

let handle_surface_post ~config ~(meta : keeper_meta) ~args =
  let surface = String.trim (Safe_ops.json_string ~default:"" "surface" args) in
  let content = Safe_ops.json_string ~default:"" "content" args in
  let redaction =
    Keeper_secret_redaction.snapshot
      ~base_path:config.Workspace.base_path
      ~keeper_name:meta.name
  in
  let safe_content = Keeper_secret_redaction.redact_text redaction content in
  let channel_id =
    match String.trim (Safe_ops.json_string ~default:"" "channel_id" args) with
    | "" -> None
    | id -> Some id
  in
  if surface = "" then
    Keeper_surface_post.error_json
      "surface is required. Good: surface='dashboard'."
  else if String.trim content = "" then
    Keeper_surface_post.error_json "content is required and must be non-empty."
  else
    let bound_discord_channels =
      Channel_gate_discord_state.bound_channels ~keeper_name:meta.name
    in
    let bound_slack_channels =
      Channel_gate_slack_state.bound_channels ~keeper_name:meta.name
    in
    match
      Keeper_surface_post.resolve_target ~surface ~channel_id
        ~bound_slack_channels ~bound_discord_channels ()
    with
    | Error message -> Keeper_surface_post.error_json message
    | Ok Keeper_surface_post.To_dashboard ->
        Keeper_chat_store.append_assistant_message
          ~base_dir:config.Workspace.base_path
          ~keeper_name:meta.name
          ~content:safe_content
          ~surface:(Surface_ref.Dashboard { session_id = None })
          ();
        Keeper_chat_broadcast.chat_appended ~keeper_name:meta.name
          ~source:"dashboard"
          ~content:safe_content
          ();
        Keeper_surface_post.ok_json ~surface ()
    | Ok (Keeper_surface_post.To_discord { channel_id }) -> (
        match Channel_gate_discord_state.send_message ~channel_id ~content:safe_content () with
        | Error send_error ->
            Keeper_surface_post.error_json
              (Format.asprintf "discord send failed: %a"
                 Channel_gate_discord_state.pp_send_error send_error)
        | Ok message_id ->
            Keeper_chat_store.append_assistant_message
              ~base_dir:config.Workspace.base_path
              ~keeper_name:meta.name
              ~content:safe_content
              ~surface:
                (Surface_ref.Discord
                   {
                     guild_id = None;
                     channel_id;
                     parent_channel_id = None;
                     thread_id = None;
                   })
              ();
            Keeper_chat_broadcast.chat_appended ~keeper_name:meta.name
              ~source:"discord"
              ~content:safe_content
              ();
            Keeper_surface_post.ok_json ~surface ~message_id ())
    | Ok (Keeper_surface_post.To_slack { channel_id; blocks = _ }) -> (
        let slack_blocks =
          Keeper_chat_slack.content_blocks_of_text safe_content
        in
        let (_ : Keeper_surface_post.post_target) =
          Keeper_surface_post.set_blocks
            (Keeper_surface_post.To_slack { channel_id; blocks = None })
            (Some slack_blocks)
        in
        match slack_token_opt () with
        | None ->
            Keeper_surface_post.error_json
              "MASC_SLACK_BOT_TOKEN is unset or empty"
        | Some token ->
            match
              Keeper_chat_slack.send_message_with_blocks ~token
                ~channel:channel_id ~content:safe_content ~blocks:slack_blocks
            with
            | Error err ->
                Keeper_surface_post.error_json
                  (Format.asprintf "slack send failed: %a"
                     Keeper_chat_slack.pp_error err)
            | Ok () ->
                Keeper_chat_store.append_assistant_message
                  ~base_dir:config.Workspace.base_path
                  ~keeper_name:meta.name
                  ~content:safe_content
                  ~surface:
                    (Surface_ref.Slack
                       { team_id = None; channel_id; thread_ts = None })
                  ();
                Keeper_chat_broadcast.chat_appended ~keeper_name:meta.name
                  ~source:"slack"
                  ~content:safe_content
                  ();
                Keeper_surface_post.ok_json ~surface ())
;;

let handle_ide_annotate ~config ~(meta : keeper_meta) ~args =
  Keeper_tool_ide_runtime.handle_ide_annotate
    ~config
    ~keeper_name:meta.name
    ~args
;;

let handle_voice ~config ~(meta : keeper_meta) ~name ~args () =
  Keeper_tool_voice_runtime.handle_voice_tool ~config ~meta ~name ~args ()
;;

let handle_task ~config ~(meta : keeper_meta) ~name ~args =
  Keeper_tool_task_runtime.handle_keeper_task_tool ~config ~meta ~name ~args
;;

let handle_board ~(meta : keeper_meta) ~name ~args =
  Keeper_tool_board_runtime.handle_keeper_board_tool ~meta ~name ~args
;;

let handle_masc_board ~(meta : keeper_meta) ~name ~args =
  let args =
    match Tool_name.Board_name.of_string name with
    | None -> args
    | Some board_name ->
      List.fold_left
        (fun args field ->
           Keeper_tool_shared_runtime.assoc_override_string field meta.name args)
        args
        (Board_tool_registry.identity_fields_for_board_name board_name)
  in
  let result =
    Board_tool_dispatch.handle_tool name args
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
      let fields =
        match Tool_result.failure_class result with
        | None -> [ "error", `String (Tool_result.message result) ]
        | Some cls ->
          [ "error", `String (Tool_result.message result)
          ; "failure_class", `String (Tool_result.tool_failure_class_to_string cls)
          ]
      in
      Yojson.Safe.to_string (`Assoc fields)
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

let handle_masc_task ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Task.Tool.context =
    { config; agent_name = meta.name; sw = None }
  in
  Task.Tool.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

let handle_masc_plan ~(config : Workspace.config) ~name ~args =
  let ctx : Tool_plan.context = { config } in
  Tool_plan.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

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

(* RFC-0182 §3.1 — masc_misc cluster. Active after Turn_mode_codec
   extraction (2026-05-27) broke the Tool_agent_timeline → Keeper_*
   back edge that previously cycled Config → ... →
   Keeper_tool_in_process_runtime. *)
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
  Tool_agent_timeline.dispatch
    ~load_chat:(fun ~agent_name ->
      Keeper_chat_timeline_source.lines_for
        ~base_dir:config.base_path ~keeper_name:agent_name)
    ctx ~name ~args
  |> dispatch_option_to_string ~name
;;

let handle_masc_schedule ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_schedule.context = { config; agent_name = meta.name } in
  Tool_schedule.dispatch ctx ~name ~args |> dispatch_option_to_string ~name
;;

(* RFC-0252 — masc_fusion out-of-band panel+judge deliberation.  The
   gate -> fiber fork -> orchestrator logic lives in [Fusion_tool.handle];
   this handler only gathers the keeper context (base_path, name, a fresh
   run_id, wall-clock) and loads the [fusion] policy from runtime.toml.

   Switch: fusion forks a background fiber that MUST outlive this keeper turn
   (out-of-band, ~7x latency).  So it forks on the server ROOT switch
   ([Eio_context.get_root_switch_opt], documented for exactly this case —
   "work that must survive a single keeper turn"), NOT the turn-scoped
   [ctx.sw], which would cancel the deliberation when the turn ends.  Net is
   the server net capability (not turn-scoped) from the same context.  When
   either is unavailable we return an explicit error JSON rather than
   silently dropping the request (CLAUDE.md Silent-Failure avoidance). *)
let handle_masc_fusion ~(config : Workspace.config) ~(meta : keeper_meta) ~args () =
  match Eio_context.get_root_switch_opt (), Eio_context.get_net_opt () with
  | Some sw, Some net ->
    (match Fusion_config_loader.load ~base_path:config.Workspace.base_path with
     | Error msg ->
       Yojson.Safe.to_string (`Assoc [ "ok", `Bool false; "error", `String msg ])
     | Ok policy ->
       let now_unix = Time_compat.now () in
       let run_id = Random_id.prefixed ~prefix:"fus-" ~bytes:16 in
       Fusion_tool.handle
         ~sw
         ~net
         ~base_dir:config.Workspace.base_path
         ~keeper:meta.name
         ~now_unix
         ~run_id
         ~policy
         ~args)
  | _ ->
    Yojson.Safe.to_string
      (`Assoc
         [ "ok", `Bool false
         ; ( "error"
           , `String "fusion requires the server root switch + net (unavailable)" )
         ])
;;

(* RFC-0266 §7 Phase 3 — masc_fusion_status: read-only view of the caller's
   fusion runs (in-progress + recently completed). [fusion_status_json] is the
   pure projection over any registry instance, so tests exercise it on an
   isolated [Fusion_run_registry.create ()]; [handle_masc_fusion_status] binds
   the process-wide [global] the fusion tool/sink write to and scopes by the
   calling keeper. *)
let fusion_status_json ~(registry : Fusion_run_registry.t) ~keeper ~run_id : string =
  (* Per-run serialization (field set + status vocabulary) is owned by
     Fusion_run_registry.run_to_yojson — the single serializer shared with the
     Phase 4 dashboard HTTP route and the fusion_run_status SSE event, so the
     shape never drifts between the tool and the dashboard. This function only
     adds the tool envelope + per-keeper scoping. *)
  let run_to_yojson = Fusion_run_registry.run_to_yojson in
  let belongs_to_keeper (r : Fusion_run_registry.run) =
    String.equal r.keeper keeper
  in
  let not_found () =
    Yojson.Safe.to_string
      (`Assoc
         [ "ok", `Bool true
         ; "found", `Bool false
         ; "run_id", `String run_id
         ; "status", `String "not_found"
         ])
  in
  if String.equal run_id ""
  then begin
    let runs =
      Fusion_run_registry.list_runs registry |> List.filter belongs_to_keeper
    in
    Yojson.Safe.to_string
      (`Assoc
         [ "ok", `Bool true
         ; "count", `Int (List.length runs)
         ; "runs", `List (List.map run_to_yojson runs)
         ])
  end
  else (
    match Fusion_run_registry.get registry ~run_id with
    | Some run when belongs_to_keeper run ->
      Yojson.Safe.to_string
        (`Assoc [ "ok", `Bool true; "found", `Bool true; "run", run_to_yojson run ])
    | Some _ | None -> not_found ())
;;

let handle_masc_fusion_status ~(meta : keeper_meta) ~args () =
  let run_id = Safe_ops.json_string ~default:"" "run_id" args |> String.trim in
  fusion_status_json ~registry:(Fusion_run_registry.global ()) ~keeper:meta.name ~run_id
;;

(* RFC-keeper-vision-delegation-tool §2.6 — analyze_image. Thin delegate to the
   vision sub-call shell in [Keeper_vision_tool], which threads the Eio net/clock
   it receives (the read-only sub-call needs net like masc_fusion needs it). *)
let handle_analyze_image ?sw ?clock ?net ~(meta : keeper_meta) ~args () =
  Keeper_vision_tool.handle ?sw ?clock ?net ~meta ~args ()
;;

(* RFC-0182 §3.1 — masc_tool_shard cluster.  [Tool_shard.execute]
   returns the older [(bool * Yojson.Safe.t)] tuple (predates RFC-0189
   typed-result migration), same shape as Tool_local_runtime.  Tool_shard
   has no Keeper/Workspace deps so no cycle concern.

   TEL-OK: descriptor projection — telemetry lives in [Tool_shard.execute]
   and the upstream [Keeper_tool_dispatch_runtime] dispatch wrapper. *)
let dashboard_surface_readiness_callback
    : (?surface_id:string -> unit -> Yojson.Safe.t) Atomic.t
  =
  Atomic.make (fun ?surface_id:_ () -> `Assoc [])

let register_dashboard_surface_readiness fn = Atomic.set dashboard_surface_readiness_callback fn

(* RFC-0182 §3.1 — masc_surface_audit singleton.  Body is pure
   ([Dashboard_surface_readiness.json ?surface_id ()]) with no ctx
   requirements; direct import is cycle-safe.

   TEL-OK: read-only dashboard surface snapshot, telemetry lives in
   [Dashboard_surface_readiness]. *)
let handle_masc_surface_audit ~args =
  let surface_id = Safe_ops.json_string_opt "surface_id" args in
  Yojson.Safe.to_string (Atomic.get dashboard_surface_readiness_callback ?surface_id ())
;;

(* RFC-0182 §3.1 — masc_keeper cluster.  [Keeper_tool_surface] lives in lib/
   (late) but exposes keeper workspace tools.  A direct import here
   closes a cycle, so we dispatch through [Keeper_dispatch_ref].  Today
   only [masc_keeper_list] is registered; remaining keeper tools depend
   on the Eio context and await Phase 5 Eio plumbing.

   TEL-OK: descriptor projection — telemetry lives in the underlying
   [Keeper_tool_surface] / [Keeper_tool_surface_ops] / [Keeper_status_detail] handlers
   that the registered ref delegates to. *)
let handle_masc_keeper
      ?sw
      ?clock
      ?proc_mgr
      ?net
      ?mcp_session_id
      ~(config : Workspace.config)
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
