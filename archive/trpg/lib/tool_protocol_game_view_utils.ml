(** Tool_protocol_game_view_utils — types, utilities, broadcast helpers,
    and payload serialization for the GAME-VIEW protocol gateway. *)

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
  store : Trpg.Store.t;
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
    "task_updates";
    "agent_events";
    "board";
    "keeper_events";
    "trpg.events";
    "trpg.state";
    "trpg.world";
  ]

let split_topics requested =
  let accepted, rejected =
    List.partition (fun t -> List.mem t supported_client_topics) requested
  in
  (dedupe_keep_order accepted, dedupe_keep_order rejected)

let sse_endpoints_for_topics _topics =
  []

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

let with_string_default args ~key ~value =
  match args with
  | `Assoc fields ->
      let current = get_string args key "" in
      if current <> "" then args
      else
        let kept = List.filter (fun (k, _) -> k <> key) fields in
        `Assoc ((key, `String value) :: kept)
  | _ -> args

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

let world_agent_payload (a : Trpg.World_projection.agent_state) =
  `Assoc
    [
      ("name", `String a.name);
      ("status", `String (Trpg.World_projection.string_of_agent_status a.status));
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

