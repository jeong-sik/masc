(** Unified protocol gateway for GAME-VIEW domains.

    Canonical API (dot namespace):
    - decision.*
    - experiment.*
    - trpg.*
    - client.*

    Legacy compatibility:
    - experiment_* and masc_trpg_* are kept as aliases for a deprecation window.
*)

open Yojson.Safe.Util

type tool_result = bool * string

type context = {
  config : Room.config;
  store : Trpg_store.t;
  agent_name : string;
  trpg_keeper_call :
    (name:string -> message:string -> timeout_sec:float -> Tool_trpg.keeper_call_result)
      option;
  trpg_keeper_probe :
    (name:string -> Tool_trpg.keeper_probe_result)
      option;
  trpg_dm_voice_emit :
    (agent_id:string ->
     message:string ->
     provider:string option ->
     Tool_trpg.dm_voice_emit_result)
      option;
}

let ( let* ) = Result.bind

let protocol_version = "masc.game-view/0.1"

open Tool_args

let get_object_opt args key =
  match args |> member key with
  | (`Assoc _ as json) -> Some json
  | _ -> None

let parse_json_or_string s =
  try Yojson.Safe.from_string s with Yojson.Json_error _ -> `String s

let dedupe_keep_order xs =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | x :: rest ->
        if List.mem x seen then
          loop seen acc rest
        else
          loop (x :: seen) (x :: acc) rest
  in
  loop [] [] xs

let json_string_list xs = `List (List.map (fun s -> `String s) xs)

let default_trpg_room_id = "default"

let supported_client_topics =
  [
    "trpg.events";
    "trpg.state";
    "trpg.world";
    "experiment.events";
    "experiment.state";
  ]

let split_topics requested =
  let accepted, rejected =
    List.partition (fun t -> List.mem t supported_client_topics) requested
  in
  (dedupe_keep_order accepted, dedupe_keep_order rejected)

let sse_endpoints_for_topics topics =
  let items = ref [] in
  if List.mem "experiment.events" topics then
    items :=
      `Assoc
        [
          ("topic", `String "experiment.events");
          ("url", `String "/sse?room=experiment");
        ]
      :: !items;
  !items |> List.rev

let pull_fallback_for_topics topics =
  let fields = ref [] in
  if List.mem "trpg.events" topics then
    fields :=
      ( "trpg.events",
        `Assoc
          [
            ("tool", `String "trpg.stream.read");
            ( "cursor",
              `Assoc
                [
                  ("room_id", `String default_trpg_room_id);
                  ("after_seq", `Int 0);
                ] );
          ] )
      :: !fields;
  if List.mem "trpg.state" topics then
    fields :=
      ( "trpg.state",
        `Assoc
          [
            ("http", `String "/api/v1/trpg/state?room_id=default");
            ("room_id", `String default_trpg_room_id);
          ] )
      :: !fields;
  if List.mem "trpg.world" topics then
    fields :=
      ( "trpg.world",
        `Assoc
          [
            ("tool", `String "trpg.world.query");
            ("note", `String "requires session_id");
          ] )
      :: !fields;
  if List.mem "experiment.state" topics then
    fields :=
      ( "experiment.state",
        `Assoc
          [
            ("tool", `String "experiment.status");
            ("note", `String "requires experiment_id");
          ] )
      :: !fields;
  `Assoc (List.rev !fields)

let rec take n xs =
  if n <= 0 then []
  else
    match xs with
    | [] -> []
    | x :: rest -> x :: take (n - 1) rest

let take_last n xs =
  xs |> List.rev |> take n |> List.rev

let make_envelope ?legacy_alias ~canonical_tool ~status ~code ?message ~payload () =
  `Assoc
    [
      ("status", `String status);
      ("code", `String code);
      ("message", Option.fold ~none:`Null ~some:(fun m -> `String m) message);
      ("protocol_version", `String protocol_version);
      ("canonical_tool", `String canonical_tool);
      ( "deprecated_alias_used",
        Option.fold ~none:`Null ~some:(fun a -> `String a) legacy_alias );
      ("payload", payload);
    ]

let ok_json ?legacy_alias ~canonical_tool payload : tool_result =
  let json =
    make_envelope ?legacy_alias ~canonical_tool ~status:"ok" ~code:"OK" ~payload
      ()
  in
  (true, Yojson.Safe.to_string json)

let err_json ?legacy_alias ~canonical_tool ~code ~message ?(retryable = false)
    ?(details = `Assoc []) () : tool_result =
  let payload =
    `Assoc
      [
        ("code", `String code);
        ("message", `String message);
        ("retryable", `Bool retryable);
        ("details", details);
      ]
  in
  let json =
    make_envelope ?legacy_alias ~canonical_tool ~status:"error" ~code ~message
      ~payload ()
  in
  (false, Yojson.Safe.to_string json)

let broadcast_deprecated_alias ~agent_name ~legacy_tool ~canonical_tool =
  let params =
    `Assoc
      [
        ("type", `String "protocol.deprecated_alias");
        ("agent", `String agent_name);
        ( "data",
          `Assoc
            [
              ("legacy_tool", `String legacy_tool);
              ("canonical_tool", `String canonical_tool);
              ("protocol_version", `String protocol_version);
            ] );
        ("timestamp", `Float (Time_compat.now ()));
      ]
  in
  let notification =
    `Assoc
      [
        ("jsonrpc", `String "2.0");
        ("method", `String "masc/event");
        ("params", params);
      ]
  in
  Sse.broadcast notification

let broadcast_masc_event ~event_type ~agent ?(data = `Null) () =
  let params =
    `Assoc
      [
        ("type", `String event_type);
        ("agent", `String agent);
        ("data", data);
        ("timestamp", `Float (Time_compat.now ()));
      ]
  in
  let notification =
    `Assoc
      [
        ("jsonrpc", `String "2.0");
        ("method", `String "masc/event");
        ("params", params);
      ]
  in
  Sse.broadcast notification

let broadcast_decision_create_events ~agent (decision : Game_view_state.decision) =
  broadcast_masc_event ~event_type:"decision_issue" ~agent
    ~data:
      (`Assoc
        [
          ("id", `String decision.decision_id);
          ("title", `String decision.issue);
          ("description", `String decision.issue);
          ("urgency", `String "medium");
        ])
    ();
  List.iteri
    (fun idx option_label ->
      broadcast_masc_event ~event_type:"decision_option" ~agent
        ~data:
          (`Assoc
            [
              ("issue_id", `String decision.decision_id);
              ("label", `String option_label);
              ("proposed_by", `String agent);
              ("option_id", `String (Printf.sprintf "opt-%d" idx));
            ])
        ())
    decision.options;
  broadcast_masc_event ~event_type:"decision_phase" ~agent
    ~data:
      (`Assoc
        [
          ("issue_id", `String decision.decision_id);
          ("phase", `String "proposal");
        ])
    ()

let broadcast_decision_finalize_events ~agent
    (decision : Game_view_state.decision) =
  let chosen_option =
    decision.selected_option |> Option.value ~default:"unknown"
  in
  let confidence = decision.confidence |> Option.value ~default:1.0 in
  broadcast_masc_event ~event_type:"decision_consensus" ~agent
    ~data:
      (`Assoc
        [
          ("issue_id", `String decision.decision_id);
          ("chosen_option_id", `String chosen_option);
          ("method", `String "decision.finalize");
          ("margin", `Float confidence);
          ("dissenting", `List []);
        ])
    ();
  broadcast_masc_event ~event_type:"decision_phase" ~agent
    ~data:
      (`Assoc
        [
          ("issue_id", `String decision.decision_id);
          ("phase", `String "resolved");
        ])
    ()

let trpg_context_of (ctx : context) : Tool_trpg.context =
  {
    store = ctx.store;
    agent_name = ctx.agent_name;
    keeper_call = ctx.trpg_keeper_call;
    keeper_probe = ctx.trpg_keeper_probe;
    dm_voice_emit = ctx.trpg_dm_voice_emit;
  }

let experiment_context_of (ctx : context) : Tool_experiment.context =
  { config = ctx.config; agent_name = ctx.agent_name }

let with_string_default args ~key ~value =
  match args with
  | `Assoc fields ->
      let current = get_string args key "" in
      if current <> "" then args
      else
        let kept = List.filter (fun (k, _) -> k <> key) fields in
        `Assoc ((key, `String value) :: kept)
  | _ -> args

let normalize_experiment_start_args args =
  args
  |> with_string_default ~key:"treatment_description" ~value:"protocol.treatment"
  |> with_string_default ~key:"control_description" ~value:"protocol.control"

let decision_payload (d : Game_view_state.decision) =
  let status = if d.finalized_at = None then "created" else "finalized" in
  `Assoc
    [
      ("decision_id", `String d.decision_id);
      ("session_id", `String d.session_id);
      ("issue", `String d.issue);
      ("options", `List (List.map (fun s -> `String s) d.options));
      ("criteria", `List (List.map (fun s -> `String s) d.criteria));
      ("weights", Option.value ~default:`Null d.weights);
      ("status", `String status);
      ("created_at", `Float d.created_at);
      ("finalized_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) d.finalized_at);
      ("selected_option", Option.fold ~none:`Null ~some:(fun v -> `String v) d.selected_option);
      ("rationale", Option.fold ~none:`Null ~some:(fun v -> `String v) d.rationale);
      ("confidence", Option.fold ~none:`Null ~some:(fun v -> `Float v) d.confidence);
      ("verifier", Option.fold ~none:`Null ~some:(fun v -> `String v) d.verifier);
      ("risk_ack", Option.fold ~none:`Null ~some:(fun v -> `String v) d.risk_ack);
    ]

let client_input_payload (i : Game_view_state.client_input) =
  let status = Game_view_state.client_input_status_to_string i.status in
  `Assoc
    [
      ("input_id", `String i.input_id);
      ("session_id", `String i.session_id);
      ("input", `String i.input);
      ("status", `String status);
      ("submitted_by", `String i.submitted_by);
      ("submitted_at", `Float i.submitted_at);
      ("handled_by", Option.fold ~none:`Null ~some:(fun v -> `String v) i.handled_by);
      ("handled_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) i.handled_at);
      ("reject_reason", Option.fold ~none:`Null ~some:(fun v -> `String v) i.reject_reason);
    ]

let experiment_summary_payload (e : Tool_experiment.experiment) =
  `Assoc
    [
      ("experiment_id", `String e.id);
      ("status", `String (Tool_experiment.status_to_string e.status));
      ("created_at", `Float e.created_at);
      ("metrics", `List (List.map (fun m -> `String m) e.metrics));
      ("window_seconds", `Float e.window_seconds);
      ("assignments", `Int (List.length e.assignments));
      ("observations", `Int (List.length e.observations));
    ]

let world_agent_payload (a : Trpg_world_projection.agent_state) =
  `Assoc
    [
      ("name", `String a.name);
      ("status", `String (Trpg_world_projection.string_of_agent_status a.status));
      ("last_action", Option.fold ~none:`Null ~some:(fun v -> `String v) a.last_action);
    ]

let json_strings = function
  | `List xs -> List.filter_map (function `String s -> Some s | _ -> None) xs
  | _ -> []

let capabilities_for_agent config ~agent_name =
  try
    match Room.get_agents_status config |> member "agents" with
    | `List items ->
        items
        |> List.find_map (fun item ->
               match item |> member "name" with
               | `String n when n = agent_name ->
                   Some (json_strings (item |> member "capabilities"))
               | _ -> None)
        |> Option.value ~default:[]
    | _ -> []
  with exn ->
    Log.Trpg.error "capabilities_for_agent failed: %s" (Printexc.to_string exn);
    []

let default_world_skills =
  [ "observe"; "deliberate"; "act"; "negotiate" ]

let skills_for_world_query config ~agent_name =
  let caps = capabilities_for_agent config ~agent_name in
  if caps = [] then default_world_skills else dedupe_keep_order caps

let latest_decision_for_session config ~session_id =
  let score (d : Game_view_state.decision) =
    match d.finalized_at with Some ts -> ts | None -> d.created_at
  in
  Game_view_state.load_decisions config
  |> List.filter
       (fun (d : Game_view_state.decision) -> d.session_id = session_id)
  |> List.sort (fun a b -> Float.compare (score b) (score a))
  |> function
  | head :: _ -> Some head
  | [] -> None

let require_session_id args ~canonical_tool =
  let session_id = get_string args "session_id" "" in
  if session_id = "" then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"session_id is required" ())
  else Ok session_id

let require_input_id args ~canonical_tool =
  let input_id = get_string args "input_id" "" in
  if input_id = "" then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"input_id is required" ())
  else Ok input_id

let require_finalized_decision (ctx : context) ~canonical_tool args =
  let* session_id = require_session_id args ~canonical_tool in
  let decision_id = get_string_opt args "decision_id" in
  match
    Game_view_state.finalized_decision_for_session ?decision_id ctx.config
      ~session_id
  with
  | Ok d -> Ok (session_id, d)
  | Error msg ->
      Error
        (err_json ~canonical_tool ~code:"PRECONDITION_REQUIRED"
           ~message:
             (Printf.sprintf
                "decision.finalize required before %s: %s"
                canonical_tool msg)
           ())

let handle_decision_create (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let issue = get_string args "issue" "" in
  let options = get_string_list args "options" in
  if issue = "" then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"issue is required" ())
  else if options = [] then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"options must have at least one entry" ())
  else
    let criteria = get_string_list args "criteria" in
    let weights = get_object_opt args "weights" in
    let decision =
      Game_view_state.create_decision ctx.config ~session_id ~issue ~options
        ~criteria ~weights
    in
    broadcast_decision_create_events ~agent:ctx.agent_name decision;
    Ok (ok_json ~canonical_tool (decision_payload decision))

let handle_decision_finalize (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let decision_id = get_string args "decision_id" "" in
  let selected_option = get_string args "selected_option" "" in
  let rationale = get_string args "rationale" "" in
  let verifier = String.uppercase_ascii (get_string args "verifier" "PASS") in
  let confidence = get_float_opt args "confidence" in
  let risk_ack = get_string_opt args "risk_ack" in
  if decision_id = "" then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"decision_id is required" ())
  else if selected_option = "" then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"selected_option is required" ())
  else if rationale = "" then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"rationale is required" ())
  else if verifier = "WARN" && Option.is_none risk_ack then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"risk_ack is required when verifier is WARN" ())
  else
    match
      Game_view_state.finalize_decision ctx.config ~session_id ~decision_id
        ~selected_option ~rationale ~confidence ~verifier ~risk_ack
    with
    | Ok finalized ->
        broadcast_decision_finalize_events ~agent:ctx.agent_name finalized;
        Ok (ok_json ~canonical_tool (decision_payload finalized))
    | Error msg ->
        let code =
          if String.starts_with ~prefix:"decision not found" msg then "NOT_FOUND"
          else "VALIDATION_ERROR"
        in
        Error (err_json ~canonical_tool ~code ~message:msg ())

let handle_decision_status (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let decision_id = get_string_opt args "decision_id" in
  let selected =
    match decision_id with
    | Some did -> (
        let all = Game_view_state.load_decisions ctx.config in
        List.find_opt
          (fun (d : Game_view_state.decision) ->
            d.session_id = session_id && d.decision_id = did)
          all)
    | None -> latest_decision_for_session ctx.config ~session_id
  in
  match selected with
  | Some d -> Ok (ok_json ~canonical_tool (decision_payload d))
  | None ->
      Error
        (err_json ~canonical_tool ~code:"NOT_FOUND"
           ~message:
             (Printf.sprintf "no decision found for session_id=%s" session_id)
           ())

let delegate_experiment (ctx : context) ~legacy_name ~args =
  let exp_ctx = experiment_context_of ctx in
  Tool_experiment.dispatch exp_ctx ~name:legacy_name ~args

let delegate_trpg (ctx : context) ~legacy_name ~args =
  let trpg_ctx = trpg_context_of ctx in
  Tool_trpg.dispatch trpg_ctx ~name:legacy_name ~args

let handle_experiment_canonical (ctx : context) ~canonical_tool ~legacy_name
    ~require_decision args : (tool_result, tool_result) result =
  let* () =
    if require_decision then
      let* _ = require_finalized_decision ctx ~canonical_tool args in
      Ok ()
    else Ok ()
  in
  let args =
    if legacy_name = "experiment_start" then normalize_experiment_start_args args
    else args
  in
  match delegate_experiment ctx ~legacy_name ~args with
  | Some (true, body) ->
      Ok (ok_json ~canonical_tool (parse_json_or_string body))
  | Some (false, msg) ->
      Error
        (err_json ~canonical_tool ~code:"LEGACY_ERROR" ~message:msg
           ~details:(`Assoc [ ("legacy_tool", `String legacy_name) ])
           ())
  | None ->
      Log.Dispatch.info "NOT_IMPLEMENTED: experiment %s (canonical: %s)"
        legacy_name canonical_tool;
      Error
        (err_json ~canonical_tool ~code:"NOT_IMPLEMENTED"
           ~message:(Printf.sprintf "legacy dispatcher unavailable: %s. Use canonical tool names from dispatch table." legacy_name)
           ())

let sanitize_room_id (s : string) =
  let b = Bytes.of_string s in
  for i = 0 to Bytes.length b - 1 do
    let c = Bytes.get b i in
    let valid =
      (c >= 'a' && c <= 'z')
      || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9')
      || c = '.' || c = '_' || c = '-'
    in
    if not valid then Bytes.set b i '-'
  done;
  let out = Bytes.to_string b in
  if out = "" then "session-default" else out

let next_event_seq ~base_dir ~room_id =
  match Trpg_engine_store.read_events ~base_dir ~room_id with
  | Ok [] -> 1
  | Ok events ->
      List.fold_left
        (fun acc (ev : Trpg_engine_event.t) -> max acc ev.seq)
        0 events
      + 1
  | Error _ -> 1

let append_event ~base_dir ~room_id ~seq ~event_type ~payload ?actor_id () =
  let event =
    Trpg_engine_event.make ~seq ~room_id ~ts:(Types.now_iso ()) ~event_type
      ?actor_id ~payload ()
  in
  Trpg_engine_store.append_event ~base_dir ~event

let handle_trpg_action_submit (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id, decision = require_finalized_decision ctx ~canonical_tool args in
  let action = get_string args "action" "" in
  if action = "" then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"action is required" ())
  else
    let intent = get_string args "intent" "unspecified" in
    let stakes = String.lowercase_ascii (get_string args "stakes" "medium") in
    let risk_delta =
      match stakes with
      | "low" -> 0.10
      | "medium" -> 0.25
      | "high" -> 0.50
      | _ -> 0.20
    in
    let room_id =
      get_string_opt args "room_id"
      |> Option.value
           ~default:(sanitize_room_id (Printf.sprintf "session-%s" session_id))
    in
    let base_dir = ctx.config.base_path in
    let story =
      Printf.sprintf
        "%s chose '%s' and performed '%s' with intent '%s' (stakes=%s)."
        session_id
        (Option.value ~default:"n/a" decision.selected_option)
        action intent stakes
    in
    let proposed_payload =
      `Assoc
        [
          ("session_id", `String session_id);
          ("decision_id", `String decision.decision_id);
          ("action", `String action);
          ("intent", `String intent);
          ("stakes", `String stakes);
        ]
    in
    let resolved_payload =
      `Assoc
        [
          ("session_id", `String session_id);
          ("decision_id", `String decision.decision_id);
          ("next_scene_or_state", `String "scene.continue");
          ("resolved_effects", `List [ `String ("action.applied:" ^ action) ]);
          ("risk_delta", `Float risk_delta);
          ("story_log", `List [ `String story ]);
        ]
    in
    let seq = next_event_seq ~base_dir ~room_id in
    (match
       append_event ~base_dir ~room_id ~seq
         ~event_type:Trpg_engine_event.Turn_action_proposed
         ~actor_id:ctx.agent_name ~payload:proposed_payload ()
     with
    | Error e ->
        Error
          (err_json ~canonical_tool ~code:"IO_ERROR"
             ~message:(Printf.sprintf "failed to append TRPG proposed event: %s" e)
             ())
    | Ok () -> (
        match
          append_event ~base_dir ~room_id ~seq:(seq + 1)
            ~event_type:Trpg_engine_event.Turn_action_resolved
            ~actor_id:ctx.agent_name ~payload:resolved_payload ()
        with
        | Error e ->
            Error
              (err_json ~canonical_tool ~code:"IO_ERROR"
                 ~message:
                   (Printf.sprintf "failed to append TRPG resolved event: %s" e)
                 ())
        | Ok () ->
            let payload =
              `Assoc
                [
                  ("session_id", `String session_id);
                  ("room_id", `String room_id);
                  ("decision_id", `String decision.decision_id);
                  ("next_scene_or_state", `String "scene.continue");
                  ("resolved_effects", `List [ `String ("action.applied:" ^ action) ]);
                  ("risk_delta", `Float risk_delta);
                  ("story_log", `List [ `String story ]);
                ]
            in
            Ok (ok_json ~canonical_tool payload)))

let handle_trpg_world_query (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let room_id =
    get_string_opt args "room_id"
    |> Option.value
         ~default:(sanitize_room_id (Printf.sprintf "session-%s" session_id))
  in
  let after_seq = max 0 (get_int args "after_seq" 0) in
  let event_limit = get_int args "event_limit" 20 |> max 1 |> min 100 in
  match Game_view_state.get_client_session ctx.config ~session_id with
  | None ->
      Error
        (err_json ~canonical_tool ~code:"PRECONDITION_REQUIRED"
           ~message:"client.session.open required before trpg.world.query" ())
  | Some session ->
      let viewer_agent =
        get_string_opt args "agent"
        |> Option.value ~default:session.agent_name
        |> String.trim
      in
      let viewer_agent =
        if viewer_agent = "" then session.agent_name else viewer_agent
      in
      let _ =
        Game_view_state.open_client_session ctx.config ~session_id ~trace_id:None
          ~agent_name:ctx.agent_name
      in
      let skills = skills_for_world_query ctx.config ~agent_name:viewer_agent in
      (match Trpg_world_projection.build ~base_dir:ctx.config.base_path ~room_id with
      | Error msg ->
          Error
            (err_json ~canonical_tool ~code:"IO_ERROR"
               ~message:(Printf.sprintf "failed to build world projection: %s" msg)
               ())
      | Ok world ->
          let view =
            Trpg_visibility.filter ~agent_name:viewer_agent ~after_seq
              ~event_limit ~available_skills:skills world
          in
          let payload =
            `Assoc
              [
                ("session_id", `String session_id);
                ("room_id", `String room_id);
                ("agent", `String viewer_agent);
                ("scope", `String "visible");
                ("round", `Int view.round);
                ("phase", `String view.phase);
                ("self", world_agent_payload view.self);
                ("visible_agents", `List (List.map world_agent_payload view.visible_agents));
                ("events_since", `List (List.map Trpg_engine_event.to_yojson view.events_since));
                ("available_skills", json_string_list view.available_skills);
                ( "source_counts",
                  `Assoc
                    [
                      ("jsonl", `Int world.source_counts.jsonl);
                      ("sqlite", `Int world.source_counts.sqlite);
                      ("merged", `Int world.source_counts.merged);
                    ] );
                ("server_time", `Float (Time_compat.now ()));
                ("protocol_version", `String protocol_version);
              ]
          in
          Ok (ok_json ~canonical_tool payload))

let handle_trpg_canonical (ctx : context) ~canonical_tool ~legacy_name args :
    tool_result =
  match delegate_trpg ctx ~legacy_name ~args with
  | Some (true, body) ->
      ok_json ~canonical_tool (parse_json_or_string body)
  | Some (false, msg) ->
      err_json ~canonical_tool ~code:"LEGACY_ERROR" ~message:msg
        ~details:(`Assoc [ ("legacy_tool", `String legacy_name) ])
        ()
  | None ->
      Log.Dispatch.info "NOT_IMPLEMENTED: trpg %s (canonical: %s)"
        legacy_name canonical_tool;
      err_json ~canonical_tool ~code:"NOT_IMPLEMENTED"
        ~message:(Printf.sprintf "legacy dispatcher unavailable: %s. Use canonical tool names from dispatch table." legacy_name)
        ()

let handle_client_session_open (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let trace_id = get_string_opt args "trace_id" in
  let session =
    Game_view_state.open_client_session ctx.config ~session_id ~trace_id
      ~agent_name:ctx.agent_name
  in
  let payload =
    `Assoc
      [
        ("session_id", `String session.session_id);
        ("trace_id", Option.fold ~none:`Null ~some:(fun v -> `String v) session.trace_id);
        ("status", `String "opened");
        ("opened_at", `Float session.created_at);
        ("last_seen", `Float session.last_seen);
        ("protocol_version", `String protocol_version);
      ]
  in
  Ok (ok_json ~canonical_tool payload)

let handle_client_state_subscribe (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let requested_topics =
    get_string_list args "topics"
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
    |> dedupe_keep_order
  in
  if requested_topics = [] then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"topics must include at least one entry" ())
  else
    match Game_view_state.get_client_session ctx.config ~session_id with
    | None ->
        Error
          (err_json ~canonical_tool ~code:"PRECONDITION_REQUIRED"
             ~message:
               "client.session.open required before client.state.subscribe"
             ())
    | Some _ ->
        let _ =
          Game_view_state.open_client_session ctx.config ~session_id
            ~trace_id:None ~agent_name:ctx.agent_name
        in
        let accepted_topics, rejected_topics = split_topics requested_topics in
        let sub =
          Game_view_state.create_client_subscription ctx.config ~session_id
            ~topics:requested_topics ~accepted_topics ~rejected_topics
        in
        let payload =
          `Assoc
            [
              ("subscription_id", `String sub.subscription_id);
              ("session_id", `String sub.session_id);
              ("accepted_topics", json_string_list accepted_topics);
              ("rejected_topics", json_string_list rejected_topics);
              ( "transport",
                `Assoc
                  [
                    ("primary", `String "sse");
                    ("sse_endpoints", `List (sse_endpoints_for_topics accepted_topics));
                    ("pull_fallback", pull_fallback_for_topics accepted_topics);
                  ] );
            ]
        in
        Ok (ok_json ~canonical_tool payload)

let handle_client_input_submit (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let input = get_string args "input" "" |> String.trim in
  if input = "" then
    Error
      (err_json ~canonical_tool ~code:"VALIDATION_ERROR"
         ~message:"input is required" ())
  else
    match Game_view_state.get_client_session ctx.config ~session_id with
    | None ->
        Error
          (err_json ~canonical_tool ~code:"PRECONDITION_REQUIRED"
             ~message:"client.session.open required before client.input.submit"
             ())
    | Some _ ->
        let _ =
          Game_view_state.open_client_session ctx.config ~session_id
            ~trace_id:None ~agent_name:ctx.agent_name
        in
        let item =
          Game_view_state.create_client_input ctx.config ~session_id ~input
            ~submitted_by:ctx.agent_name
        in
        Ok (ok_json ~canonical_tool (client_input_payload item))

let handle_client_input_transition (ctx : context) ~canonical_tool ~status
    ~default_reason args : (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let* input_id = require_input_id args ~canonical_tool in
  let reject_reason =
    match status with
    | Game_view_state.Rejected ->
        Some
          (get_string_opt args "reason"
           |> Option.value ~default:default_reason
           |> String.trim)
    | _ -> None
  in
  match Game_view_state.get_client_session ctx.config ~session_id with
  | None ->
      Error
        (err_json ~canonical_tool ~code:"PRECONDITION_REQUIRED"
           ~message:
             (Printf.sprintf
                "client.session.open required before %s"
                canonical_tool)
           ())
  | Some _ -> (
      let _ =
        Game_view_state.open_client_session ctx.config ~session_id
          ~trace_id:None ~agent_name:ctx.agent_name
      in
      match
        Game_view_state.transition_client_input ctx.config ~session_id ~input_id
          ~status ~handled_by:ctx.agent_name ~reject_reason
      with
      | Ok item ->
          let event_type = match status with
            | Game_view_state.Approved -> "client_input_approved"
            | Game_view_state.Rejected -> "client_input_rejected"
            | Game_view_state.Pending  -> "client_input_updated"
          in
          (try
            broadcast_masc_event ~event_type ~agent:ctx.agent_name
              ~data:(client_input_payload item) ()
          with exn ->
            Log.Protocol.error "SSE %s broadcast failed: %s"
              event_type (Printexc.to_string exn));
          Ok (ok_json ~canonical_tool (client_input_payload item))
      | Error msg ->
          let code =
            if String.starts_with ~prefix:"input not found" msg then "NOT_FOUND"
            else if String.starts_with ~prefix:"input already handled" msg then
              "CONFLICT"
            else "VALIDATION_ERROR"
          in
          Error (err_json ~canonical_tool ~code ~message:msg ()))

let handle_client_snapshot_get (ctx : context) ~canonical_tool args :
    (tool_result, tool_result) result =
  let* session_id = require_session_id args ~canonical_tool in
  let requested_room_id =
    get_string_opt args "room_id"
    |> Option.value
         ~default:(sanitize_room_id (Printf.sprintf "session-%s" session_id))
  in
  let max_events = get_int args "max_events" 20 |> min 100 |> max 1 in
  match Game_view_state.get_client_session ctx.config ~session_id with
  | None ->
      Error
        (err_json ~canonical_tool ~code:"PRECONDITION_REQUIRED"
           ~message:"client.session.open required before client.snapshot.get" ())
  | Some _ ->
      let session =
        Game_view_state.open_client_session ctx.config ~session_id ~trace_id:None
          ~agent_name:ctx.agent_name
      in
      let subscriptions =
        Game_view_state.get_client_subscriptions ctx.config ~session_id
      in
      let inputs =
        Game_view_state.get_client_inputs ctx.config ~session_id
      in
      let pending_inputs =
        List.filter
          (fun (i : Game_view_state.client_input) ->
            i.status = Game_view_state.Pending)
          inputs
      in
      let latest_decision =
        latest_decision_for_session ctx.config ~session_id
      in
      let finalized_decision =
        Game_view_state.latest_finalized_decision ctx.config ~session_id
      in
      let trpg_events =
        match
          Trpg_engine_store.read_events ~base_dir:ctx.config.base_path
            ~room_id:requested_room_id
        with
        | Ok events -> events
        | Error _ -> []
      in
      let recent_events = take_last max_events trpg_events in
      let last_seq =
        match List.rev recent_events with
        | (ev : Trpg_engine_event.t) :: _ -> ev.seq
        | [] -> 0
      in
      let all_experiments = Tool_experiment.list_experiments ctx.config in
      let running_experiments =
        List.filter
          (fun (e : Tool_experiment.experiment) ->
            e.status = Tool_experiment.Running)
          all_experiments
      in
      let payload =
        `Assoc
          [
            ("snapshot_version", `String "masc.game-view.snapshot/0.1");
            ("session", Game_view_state.client_session_to_json session);
            ( "latest_decision",
              Option.fold ~none:`Null ~some:decision_payload latest_decision );
            ( "finalized_decision",
              Option.fold ~none:`Null ~some:decision_payload finalized_decision );
            ( "subscriptions",
              `List
                (List.map
                   Game_view_state.client_subscription_to_json
                   subscriptions) );
            ( "input_queue",
              `Assoc
                [
                  ("pending_count", `Int (List.length pending_inputs));
                  ("recent", `List (List.map client_input_payload (take_last 20 inputs)));
                ] );
            ( "trpg",
              `Assoc
                [
                  ("room_id", `String requested_room_id);
                  ("event_count", `Int (List.length trpg_events));
                  ("last_seq", `Int last_seq);
                  ( "recent_events",
                    `List
                      (List.map
                         (fun (ev : Trpg_engine_event.t) ->
                           Trpg_engine_event.to_yojson ev)
                         recent_events) );
                ] );
            ( "experiments",
              `Assoc
                [
                  ("running_count", `Int (List.length running_experiments));
                  ( "recent",
                    `List
                      (List.map
                         experiment_summary_payload
                         (take 5 all_experiments)) );
                ] );
            ("server_time", `Float (Time_compat.now ()));
            ("protocol_version", `String protocol_version);
          ]
      in
      Ok (ok_json ~canonical_tool payload)

let legacy_alias_to_canonical = function
  | "experiment_start" -> Some "experiment.start"
  | "experiment_assign" -> Some "experiment.assign"
  | "experiment_observe" -> Some "experiment.observe"
  | "experiment_checkpoint" -> Some "experiment.checkpoint"
  | "experiment_conclude" -> Some "experiment.conclude"
  | "experiment_list" -> Some "experiment.list"
  | "experiment_status" -> Some "experiment.status"
  | "masc_trpg_dice_roll" -> Some "trpg.dice.roll"
  | "masc_trpg_turn_advance" -> Some "trpg.turn.advance"
  | "masc_trpg_stream" -> Some "trpg.stream.read"
  | "masc_trpg_round_run" -> Some "trpg.round.run"
  | "masc_trpg_preset_list" -> Some "trpg.preset.list"
  | "masc_trpg_pool_generate" -> Some "trpg.pool.generate"
  | "masc_trpg_party_select" -> Some "trpg.party.select"
  | "masc_trpg_session_start" -> Some "trpg.session.start"
  | "masc_trpg_actor_spawn" -> Some "trpg.actor.spawn"
  | "masc_trpg_actor_update" -> Some "trpg.actor.update"
  | "masc_trpg_actor_delete" -> Some "trpg.actor.delete"
  | "masc_trpg_actor_claim" -> Some "trpg.actor.claim"
  | "masc_trpg_actor_release" -> Some "trpg.actor.release"
  | "masc_trpg_join_eligibility" -> Some "trpg.join.eligibility"
  | "masc_trpg_mid_join_request" -> Some "trpg.mid_join.request"
  | "masc_trpg_intervention_submit" -> Some "trpg.intervention.submit"
  | "masc_trpg_scene_transition" -> Some "trpg.scene.transition"
  | "masc_trpg_quest_update" -> Some "trpg.quest.update"
  | "masc_trpg_world_event" -> Some "trpg.world.event"
  | _ -> None

let handle_legacy_alias (ctx : context) ~legacy_name ~canonical_tool args :
    tool_result =
  broadcast_deprecated_alias ~agent_name:ctx.agent_name ~legacy_tool:legacy_name
    ~canonical_tool;
  match legacy_name with
  | "experiment_start" -> (
      match require_finalized_decision ctx ~canonical_tool args with
      | Ok _ -> (
          let args = normalize_experiment_start_args args in
          match delegate_experiment ctx ~legacy_name ~args with
          | Some r -> r
          | None ->
              ( false,
                Printf.sprintf
                  "legacy experiment dispatcher unavailable for %s"
                  legacy_name ))
      | Error (_, body) ->
          ( false,
            Printf.sprintf
              "PRECONDITION_REQUIRED (legacy alias: %s): %s"
              legacy_name body ))
  | name when String.starts_with ~prefix:"experiment_" name -> (
      match delegate_experiment ctx ~legacy_name:name ~args with
      | Some r -> r
      | None ->
          (false, Printf.sprintf "legacy experiment dispatcher unavailable for %s" name))
  | name when String.starts_with ~prefix:"masc_trpg_" name -> (
      match delegate_trpg ctx ~legacy_name:name ~args with
      | Some r -> r
      | None ->
          (false, Printf.sprintf "legacy trpg dispatcher unavailable for %s" name))
  | _ ->
      Log.Dispatch.info "NOT_IMPLEMENTED: legacy alias %s -> %s"
        legacy_name canonical_tool;
      err_json ~canonical_tool ~legacy_alias:legacy_name ~code:"NOT_IMPLEMENTED"
        ~message:
          (Printf.sprintf "legacy alias not supported: %s -> %s. Use canonical tool names from dispatch table." legacy_name canonical_tool)
        ()

let dispatch (ctx : context) ~name ~args : tool_result option =
  match name with
  | "decision.create" ->
      Some
        (match handle_decision_create ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "decision.finalize" ->
      Some
        (match handle_decision_finalize ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "decision.status" ->
      Some
        (match handle_decision_status ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "experiment.start" ->
      Some
        (match
           handle_experiment_canonical ctx ~canonical_tool:name
             ~legacy_name:"experiment_start" ~require_decision:true args
         with
        | Ok r -> r
        | Error e -> e)
  | "experiment.assign" ->
      Some
        (match
           handle_experiment_canonical ctx ~canonical_tool:name
             ~legacy_name:"experiment_assign" ~require_decision:false args
         with
        | Ok r -> r
        | Error e -> e)
  | "experiment.observe" ->
      Some
        (match
           handle_experiment_canonical ctx ~canonical_tool:name
             ~legacy_name:"experiment_observe" ~require_decision:false args
         with
        | Ok r -> r
        | Error e -> e)
  | "experiment.checkpoint" ->
      Some
        (match
           handle_experiment_canonical ctx ~canonical_tool:name
             ~legacy_name:"experiment_checkpoint" ~require_decision:false args
         with
        | Ok r -> r
        | Error e -> e)
  | "experiment.conclude" ->
      Some
        (match
           handle_experiment_canonical ctx ~canonical_tool:name
             ~legacy_name:"experiment_conclude" ~require_decision:false args
         with
        | Ok r -> r
        | Error e -> e)
  | "experiment.list" ->
      Some
        (match
           handle_experiment_canonical ctx ~canonical_tool:name
             ~legacy_name:"experiment_list" ~require_decision:false args
         with
        | Ok r -> r
        | Error e -> e)
  | "experiment.status" ->
      Some
        (match
           handle_experiment_canonical ctx ~canonical_tool:name
             ~legacy_name:"experiment_status" ~require_decision:false args
         with
        | Ok r -> r
        | Error e -> e)
  | "trpg.action.submit" ->
      Some
        (match handle_trpg_action_submit ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "trpg.world.query" ->
      Some
        (match handle_trpg_world_query ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "trpg.preset.list" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_preset_list" args)
  | "trpg.pool.generate" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_pool_generate" args)
  | "trpg.party.select" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_party_select" args)
  | "trpg.session.start" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_session_start" args)
  | "trpg.actor.spawn" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_actor_spawn" args)
  | "trpg.actor.update" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_actor_update" args)
  | "trpg.actor.delete" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_actor_delete" args)
  | "trpg.actor.claim" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_actor_claim" args)
  | "trpg.actor.release" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_actor_release" args)
  | "trpg.join.eligibility" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_join_eligibility" args)
  | "trpg.mid_join.request" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_mid_join_request" args)
  | "trpg.intervention.submit" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_intervention_submit" args)
  | "trpg.dice.roll" ->
      Some (handle_trpg_canonical ctx ~canonical_tool:name ~legacy_name:"masc_trpg_dice_roll" args)
  | "trpg.turn.advance" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_turn_advance" args)
  | "trpg.stream.read" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_stream" args)
  | "trpg.round.run" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_round_run" args)
  | "trpg.scene.transition" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_scene_transition" args)
  | "trpg.quest.update" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_quest_update" args)
  | "trpg.world.event" ->
      Some
        (handle_trpg_canonical ctx ~canonical_tool:name
           ~legacy_name:"masc_trpg_world_event" args)
  | "client.session.open" ->
      Some
        (match handle_client_session_open ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "client.state.subscribe" ->
      Some
        (match handle_client_state_subscribe ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "client.input.submit" ->
      Some
        (match handle_client_input_submit ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | "client.input.approve" ->
      Some
        (match
           handle_client_input_transition ctx ~canonical_tool:name
             ~status:Game_view_state.Approved
             ~default_reason:""
             args
         with
        | Ok r -> r
        | Error e -> e)
  | "client.input.reject" ->
      Some
        (match
           handle_client_input_transition ctx ~canonical_tool:name
             ~status:Game_view_state.Rejected
             ~default_reason:"rejected"
             args
         with
        | Ok r -> r
        | Error e -> e)
  | "client.snapshot.get" ->
      Some
        (match handle_client_snapshot_get ctx ~canonical_tool:name args with
        | Ok r -> r
        | Error e -> e)
  | legacy -> (
      match legacy_alias_to_canonical legacy with
      | Some canonical_tool ->
          Some (handle_legacy_alias ctx ~legacy_name:legacy ~canonical_tool args)
      | None -> None)

let string_schema = `Assoc [ ("type", `String "string") ]
let number_schema = `Assoc [ ("type", `String "number") ]
let int_schema = `Assoc [ ("type", `String "integer") ]
let bool_schema = `Assoc [ ("type", `String "boolean") ]

let array_of schema =
  `Assoc [ ("type", `String "array"); ("items", schema) ]

let object_schema ?(required = []) properties =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc properties);
      ("required", `List (List.map (fun k -> `String k) required));
    ]

let schema name description input_schema : Types.tool_schema =
  { name; description; input_schema }

let schemas : Types.tool_schema list =
  [
    schema "decision.create"
      "Create a decision record for a session."
      (object_schema
         ~required:[ "session_id"; "issue"; "options" ]
         [
           ("session_id", string_schema);
           ("issue", string_schema);
           ("options", array_of string_schema);
           ("criteria", array_of string_schema);
           ("weights", object_schema []);
         ]);
    schema "decision.finalize"
      "Finalize a decision. If verifier=WARN, risk_ack is required."
      (object_schema
         ~required:[ "session_id"; "decision_id"; "selected_option"; "rationale" ]
         [
           ("session_id", string_schema);
           ("decision_id", string_schema);
           ("selected_option", string_schema);
           ("rationale", string_schema);
           ("confidence", number_schema);
           ("verifier", string_schema);
           ("risk_ack", string_schema);
         ]);
    schema "decision.status"
      "Get latest decision status for a session or a specific decision_id."
      (object_schema
         ~required:[ "session_id" ]
         [ ("session_id", string_schema); ("decision_id", string_schema) ]);
    schema "experiment.start"
      "Start an experiment. Requires finalized decision for the same session."
      (object_schema
         ~required:[ "session_id"; "hypothesis" ]
         [
           ("session_id", string_schema);
           ("decision_id", string_schema);
           ("hypothesis", string_schema);
           ("treatment_description", string_schema);
           ("control_description", string_schema);
           ("metrics", array_of string_schema);
           ("window_seconds", number_schema);
         ]);
    schema "experiment.assign"
      "Assign a subject to treatment/control."
      (object_schema
         ~required:[ "experiment_id"; "subject_id"; "group" ]
         [
           ("experiment_id", string_schema);
           ("subject_id", string_schema);
           ("group", string_schema);
         ]);
    schema "experiment.observe"
      "Record observation for a metric."
      (object_schema
         ~required:[ "experiment_id"; "subject_id"; "metric_name"; "value" ]
         [
           ("experiment_id", string_schema);
           ("subject_id", string_schema);
           ("metric_name", string_schema);
           ("value", number_schema);
         ]);
    schema "experiment.checkpoint"
      "Compute checkpoint statistics."
      (object_schema
         ~required:[ "experiment_id" ]
         [ ("experiment_id", string_schema); ("metric_name", string_schema) ]);
    schema "experiment.conclude"
      "Conclude experiment with final result."
      (object_schema
         ~required:[ "experiment_id" ]
         [ ("experiment_id", string_schema) ]);
    schema "experiment.list"
      "List experiments."
      (object_schema [ ("status", string_schema); ("limit", int_schema) ]);
    schema "experiment.status"
      "Get one experiment status."
      (object_schema
         ~required:[ "experiment_id" ]
         [ ("experiment_id", string_schema) ]);
    schema "trpg.action.submit"
      "Submit TRPG action under decision gate and persist to TRPG event stream."
      (object_schema
         ~required:[ "session_id"; "action" ]
         [
           ("session_id", string_schema);
           ("decision_id", string_schema);
           ("room_id", string_schema);
           ("action", string_schema);
           ("intent", string_schema);
           ("stakes", string_schema);
         ]);
    schema "trpg.world.query"
      "Query agent-visible world projection for TRPG room."
      (object_schema
         ~required:[ "session_id" ]
         [
           ("session_id", string_schema);
           ("agent", string_schema);
           ("room_id", string_schema);
           ("after_seq", int_schema);
           ("event_limit", int_schema);
         ]);
    schema "trpg.preset.list"
      "Canonical alias of masc_trpg_preset_list."
      (object_schema
         [
           ("include_characters", bool_schema);
           ("include_skills", bool_schema);
         ]);
    schema "trpg.pool.generate"
      "Canonical alias of masc_trpg_pool_generate."
      (object_schema
         ~required:[ "session_id" ]
         [
           ("session_id", string_schema);
           ("world_preset_id", string_schema);
           ("dm_preset_id", string_schema);
           ("pool_size", int_schema);
           ("party_size", int_schema);
           ("seed", int_schema);
         ]);
    schema "trpg.party.select"
      "Canonical alias of masc_trpg_party_select."
      (object_schema
         ~required:[ "session_id"; "pool"; "selected_player_ids" ]
         [
           ("session_id", string_schema);
           ("room_id", string_schema);
           ("pool", array_of (object_schema []));
           ("selected_player_ids", array_of string_schema);
         ]);
    schema "trpg.session.start"
      "Canonical alias of masc_trpg_session_start."
      (object_schema
         ~required:[ "session_id" ]
         [
           ("session_id", string_schema);
           ("room_id", string_schema);
           ("dm_preset_id", string_schema);
           ("world_preset_id", string_schema);
           ("dm_keeper", string_schema);
           ("party", array_of (object_schema []));
           ("phase", string_schema);
           ("rule_module", string_schema);
           ("force", bool_schema);
         ]);
    schema "trpg.actor.spawn"
      "Canonical alias of masc_trpg_actor_spawn."
      (object_schema
         ~required:[ "room_id" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("role", string_schema);
           ("name", string_schema);
           ("archetype", string_schema);
           ("persona", string_schema);
           ("portrait", string_schema);
           ("background", string_schema);
           ("stats", object_schema []);
           ("hp", int_schema);
           ("max_hp", int_schema);
           ("alive", bool_schema);
           ("traits", array_of string_schema);
           ("skills", array_of string_schema);
           ("inventory", array_of string_schema);
         ]);
    schema "trpg.actor.update"
      "Canonical alias of masc_trpg_actor_update."
      (object_schema
         ~required:[ "room_id"; "actor_id" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("role", string_schema);
           ("name", string_schema);
           ("archetype", string_schema);
           ("persona", string_schema);
           ("portrait", string_schema);
           ("background", string_schema);
           ("stats", object_schema []);
           ("hp", int_schema);
           ("max_hp", int_schema);
           ("alive", bool_schema);
           ("traits", array_of string_schema);
           ("skills", array_of string_schema);
           ("inventory", array_of string_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.actor.delete"
      "Canonical alias of masc_trpg_actor_delete."
      (object_schema
         ~required:[ "room_id"; "actor_id" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("reason", string_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.actor.claim"
      "Canonical alias of masc_trpg_actor_claim."
      (object_schema
         ~required:[ "room_id"; "actor_id"; "keeper_name" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("keeper_name", string_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.actor.release"
      "Canonical alias of masc_trpg_actor_release."
      (object_schema
         ~required:[ "room_id"; "actor_id"; "keeper_name" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("keeper_name", string_schema);
           ("reason", string_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.join.eligibility"
      "Canonical alias of masc_trpg_join_eligibility."
      (object_schema
         ~required:[ "room_id"; "actor_id" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("keeper_name", string_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.mid_join.request"
      "Canonical alias of masc_trpg_mid_join_request."
      (object_schema
         ~required:[ "room_id"; "actor_id"; "keeper_name" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("keeper_name", string_schema);
           ("role", string_schema);
           ("name", string_schema);
           ("archetype", string_schema);
           ("persona", string_schema);
           ("hp", int_schema);
           ("max_hp", int_schema);
           ("traits", array_of string_schema);
           ("skills", array_of string_schema);
           ("inventory", array_of string_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.intervention.submit"
      "Canonical alias of masc_trpg_intervention_submit."
      (object_schema
         ~required:[ "room_id"; "intervention_type" ]
         [
           ("room_id", string_schema);
           ("session_id", string_schema);
           ("intervention_type", string_schema);
           ("scope", string_schema);
           ("target_actor", string_schema);
           ("expected_turn", int_schema);
           ("reason", string_schema);
           ("payload", object_schema []);
         ]);
    schema "trpg.dice.roll"
      "Canonical alias of masc_trpg_dice_roll."
      (object_schema
         ~required:[ "room_id"; "actor_id"; "action"; "stat_value"; "dc" ]
         [
           ("room_id", string_schema);
           ("actor_id", string_schema);
           ("action", string_schema);
           ("stat_value", int_schema);
           ("dc", int_schema);
           ("raw_d20", int_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.turn.advance"
      "Canonical alias of masc_trpg_turn_advance."
      (object_schema
         ~required:[ "room_id" ]
         [
           ("room_id", string_schema);
           ("phase", string_schema);
           ("rule_module", string_schema);
         ]);
    schema "trpg.stream.read"
      "Canonical alias of masc_trpg_stream."
      (object_schema
         ~required:[ "room_id" ]
         [
           ("room_id", string_schema);
           ("after_seq", int_schema);
           ("event_type", string_schema);
         ]);
    schema "trpg.round.run"
      "Canonical alias of masc_trpg_round_run."
      (object_schema
         ~required:[ "room_id"; "dm_keeper"; "player_keepers" ]
         [
           ("room_id", string_schema);
           ("dm_keeper", string_schema);
           ("player_keepers", object_schema []);
           ("phase", string_schema);
           ("rule_module", string_schema);
           ("timeout_sec", number_schema);
           ("dm_persona", string_schema);
           ("require_claim", bool_schema);
           ("local_fallback", bool_schema);
         ]);
    schema "trpg.scene.transition"
      "Canonical alias of masc_trpg_scene_transition."
      (object_schema
         ~required:[ "room_id"; "from_scene"; "to_scene" ]
         [
           ("room_id", string_schema);
           ("from_scene", string_schema);
           ("to_scene", string_schema);
           ("trigger", string_schema);
           ("narrative_hook", string_schema);
         ]);
    schema "trpg.quest.update"
      "Canonical alias of masc_trpg_quest_update."
      (object_schema
         ~required:[ "room_id"; "quest_id"; "title"; "status" ]
         [
           ("room_id", string_schema);
           ("quest_id", string_schema);
           ("title", string_schema);
           ("status", string_schema);
           ("objectives", array_of (object_schema [ ("desc", string_schema); ("done", bool_schema) ]));
         ]);
    schema "trpg.world.event"
      "Canonical alias of masc_trpg_world_event."
      (object_schema
         ~required:[ "room_id"; "event_type"; "description" ]
         [
           ("room_id", string_schema);
           ("event_type", string_schema);
           ("description", string_schema);
           ("affected_areas", array_of string_schema);
           ("severity", string_schema);
         ]);
    schema "client.session.open"
      "Open (or refresh) a client session for engine/viewer integration."
      (object_schema
         ~required:[ "session_id" ]
         [ ("session_id", string_schema); ("trace_id", string_schema) ]);
    schema "client.state.subscribe"
      "Subscribe client session to state/event topics (SSE primary, TRPG pull fallback)."
      (object_schema
         ~required:[ "session_id"; "topics" ]
         [ ("session_id", string_schema); ("topics", array_of string_schema) ]);
    schema "client.input.submit"
      "Submit human input into session queue (pending approval state)."
      (object_schema
         ~required:[ "session_id"; "input" ]
         [ ("session_id", string_schema); ("input", string_schema) ]);
    schema "client.input.approve"
      "Approve a queued human input."
      (object_schema
         ~required:[ "session_id"; "input_id" ]
         [ ("session_id", string_schema); ("input_id", string_schema) ]);
    schema "client.input.reject"
      "Reject a queued human input."
      (object_schema
         ~required:[ "session_id"; "input_id" ]
         [ ("session_id", string_schema); ("input_id", string_schema); ("reason", string_schema) ]);
    schema "client.snapshot.get"
      "Get a replay-friendly state snapshot for engine/viewer sync."
      (object_schema
         ~required:[ "session_id" ]
         [
           ("session_id", string_schema);
           ("room_id", string_schema);
           ("max_events", int_schema);
         ]);
  ]
