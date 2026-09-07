(** MASC Voice Session Manager - Multi-Agent Session Tracking

    Implementation of multi-agent voice session management.
    Each agent can have one active voice session at a time.

    @author Second Brain
    @since MASC v3.0
*)

(** {1 Types} *)

type session_status =
  | Active
  | Idle
  | Suspended

type conversation_mode =
  | Turn_based
  | Realtime_bridge of { endpoint : string }

type session = {
  session_id: string;
  agent_id: string;
  voice: string;
  started_at: float;
  last_activity: float;
  turn_count: int;
  status: session_status;
  conversation_mode: conversation_mode;
}

module Session_by_agent = Set_util.StringMap

type state = {
  sessions : session Session_by_agent.t;
}

type t = {
  state : state Atomic.t;
  session_dir: string;
  mutation_lock : Cross_context_mutex.t;
  (** Serialises filesystem effects with publication of the next immutable
      session-map snapshot. Readers never acquire this lock. *)
}

(** {1 Utilities} *)

let generate_session_id () =
  Random_id.prefixed ~prefix:"vs-" ~bytes:16

let string_of_status = function
  | Active -> "active"
  | Idle -> "idle"
  | Suspended -> "suspended"

(* Issue #8612: returns [Some] only for the 3 wire-format names; any
   other input returns [None]. The previous variant-returning shape
   silently routed unknowns to [Idle], a *valid* downstream variant,
   which is silent JSON-decode miscategorization. Same anti-pattern
   class as #8605 (removed policy enum parsing) and #8607 (agent_health). *)
let status_of_string_opt = function
  | "active" -> Some Active
  | "idle" -> Some Idle
  | "suspended" -> Some Suspended
  | _ -> None

let string_of_conversation_mode = function
  | Turn_based -> "turn_based"
  | Realtime_bridge _ -> "realtime_bridge"

let transport_mode_of_conversation_mode = function
  | Turn_based -> "batch_stt_tts"
  | Realtime_bridge _ -> "websocket_audio_bridge"

let realtime_supported = function
  | Turn_based -> false
  | Realtime_bridge _ -> true

let realtime_bridge_env =
  Env_setting.String_opt_knob.env_name Voice_realtime_ws_url
;;

let has_prefix ~prefix s =
  let prefix_len = String.length prefix in
  String.length s >= prefix_len && String.sub s 0 prefix_len = prefix

let valid_realtime_bridge_endpoint endpoint =
  has_prefix ~prefix:"ws://" endpoint || has_prefix ~prefix:"wss://" endpoint

let realtime_bridge_endpoint ?(getenv = Sys.getenv_opt) () =
  match getenv realtime_bridge_env with
  | None -> None
  | Some raw ->
    let endpoint = String.trim raw in
    if endpoint = "" || not (valid_realtime_bridge_endpoint endpoint)
    then None
    else Some endpoint

let realtime_bridge_public_json ?endpoint () =
  `Assoc
    [ "configured", `Bool (Option.is_some endpoint)
    ; "required_env", `String realtime_bridge_env
    ; "endpoint", `Null
    ]

let session_conversation_mode session = session.conversation_mode

let turn_based_voice_loop_json ~session_active =
  `Assoc
    [ "mode", `String "turn_based_batch"
    ; "transport_mode", `String "batch_stt_tts"
    ; "realtime_supported", `Bool false
    ; "session_active", `Bool session_active
    ; ( "operator_input"
      , `Assoc
          [ "capture", `String "dashboard_microphone_or_audio_upload"
          ; "server_route", `String "POST /api/v1/voice/transcribe"
          ; "handoff", `String "transcribed_text_enters_normal_keeper_turn"
          ] )
    ; ( "keeper_output"
      , `Assoc
          [ "tool", `String "keeper_voice_speak"
          ; "delivery", `String "tts_audio_clip"
          ; ( "browser_route"
            , `String ("GET " ^ Masc_network_defaults.voice_audio_path "<token>")
            )
          ] )
    ]

let realtime_bridge_voice_loop_json ~session_active ~endpoint =
  `Assoc
    [ "mode", `String "realtime_bridge"
    ; "transport_mode", `String "websocket_audio_bridge"
    ; "realtime_supported", `Bool true
    ; "session_active", `Bool session_active
    ; "protocol", `String "masc.voice.realtime_bridge.v1"
    ; "realtime_bridge", realtime_bridge_public_json ~endpoint ()
    ; ( "operator_input"
      , `Assoc
          [ "capture", `String "dashboard_microphone_stream"
          ; "handoff", `String "audio_frames_to_realtime_bridge"
          ] )
    ; ( "keeper_output"
      , `Assoc
          [ "delivery", `String "assistant_audio_events_or_tts_audio_clip"
          ; ( "browser_route"
            , `String ("GET " ^ Masc_network_defaults.voice_audio_path "<token>")
            )
          ] )
    ]

let voice_loop_json ~session_active = function
  | Turn_based -> turn_based_voice_loop_json ~session_active
  | Realtime_bridge { endpoint } ->
    realtime_bridge_voice_loop_json ~session_active ~endpoint

let session_to_json session =
  let session_active =
    match session.status with
    | Active -> true
    | Idle | Suspended -> false
  in
  let mode = session.conversation_mode in
  let bridge_endpoint =
    match mode with
    | Turn_based -> `Null
    | Realtime_bridge _ -> `Null
  in
  let realtime_bridge =
    match mode with
    | Turn_based -> realtime_bridge_public_json ()
    | Realtime_bridge { endpoint } -> realtime_bridge_public_json ~endpoint ()
  in
  `Assoc [
    ("session_id", `String session.session_id);
    ("agent_id", `String session.agent_id);
    ("voice", `String session.voice);
    ("started_at", `Float session.started_at);
    ("last_activity", `Float session.last_activity);
    ("turn_count", `Int session.turn_count);
    ("status", `String (string_of_status session.status));
    ("conversation_mode", `String (string_of_conversation_mode mode));
    ("transport_mode", `String (transport_mode_of_conversation_mode mode));
    ("realtime_supported", `Bool (realtime_supported mode));
    ("realtime_bridge_endpoint", bridge_endpoint);
    ("realtime_bridge", realtime_bridge);
    ("voice_loop", voice_loop_json ~session_active mode);
  ]

let conversation_mode_of_json json =
  match Json_util.get_string json "conversation_mode" with
  | Some "realtime_bridge" | Some "realtime" ->
    (match realtime_bridge_endpoint () with
     | Some endpoint -> Realtime_bridge { endpoint }
     | _ -> Turn_based)
  | _ -> Turn_based

let session_of_json json =
  {
    session_id = Json_util.get_string_with_default json ~key:"session_id" ~default:"";
    agent_id = Json_util.get_string_with_default json ~key:"agent_id" ~default:"";
    voice = Json_util.get_string_with_default json ~key:"voice" ~default:"";
    started_at = Json_util.get_float json "started_at" |> Option.value ~default:0.0;
    last_activity = Json_util.get_float json "last_activity" |> Option.value ~default:0.0;
    turn_count = Json_util.get_int json "turn_count" |> Option.value ~default:0;
    (* Issue #8612: a corrupt or mis-versioned status field used to
       silently decode as [Idle]. We now fail-closed at the boundary:
       unknown status defaults to [Suspended] so the session is visible
       to the operator (and won't be skipped by lifecycle GC that treats
       Idle as "nothing to clean up"). *)
    status =
      Json_util.get_string json "status"
      |> Option.value ~default:""
      |> status_of_string_opt
      |> Option.value ~default:Suspended;
    conversation_mode = conversation_mode_of_json json;
  }

(** {1 Creation} *)

let create ~config_path =
  let session_dir = Filename.concat config_path "voice_sessions" in
  {
    state = Atomic.make { sessions = Session_by_agent.empty };
    session_dir;
    mutation_lock = Cross_context_mutex.create ();
  }

let with_mutation t f =
  Cross_context_mutex.with_durable_lock t.mutation_lock f

(** {1 Internal Helpers} *)

let ensure_session_dir t =
  Fs_compat.mkdir_p t.session_dir

let session_file t agent_id =
  Filename.concat t.session_dir (agent_id ^ ".json")

let save_session t session =
  ensure_session_dir t;
  let json = session_to_json session in
  let content = Yojson.Safe.pretty_to_string json in
  let filepath = session_file t session.agent_id in
  Fs_compat.save_file filepath content

let load_session t agent_id =
  let filepath = session_file t agent_id in
  if Sys.file_exists filepath then begin
    try
      let content = Fs_compat.load_file filepath in
      let json = Yojson.Safe.from_string content in
      Some (session_of_json json)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | (Sys_error _ | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _) as exn ->
      Log.Misc.warn
        "[voice_session_manager.load_session] read failed for agent=%s: %s"
        agent_id
        (Printexc.to_string exn);
      None
  end else
    None

let delete_session_file t agent_id =
  let filepath = session_file t agent_id in
  if Sys.file_exists filepath then
    Sys.remove filepath

(** {1 Session Lifecycle} *)

let start_session t ~agent_id ?voice ?(conversation_mode = Turn_based) () =
  with_mutation t (fun () ->
    let current = Atomic.get t.state in
    (* Check if session already exists *)
    match Session_by_agent.find_opt agent_id current.sessions with
    | Some existing ->
      let session =
        {
          existing with
          status = Active;
          last_activity = Time_compat.now ();
          conversation_mode;
        }
      in
      save_session t session;
      Atomic.set
        t.state
        { sessions = Session_by_agent.add agent_id session current.sessions };
      session
    | None ->
      (* Get default voice from Voice_bridge *)
      let voice = match voice with
        | Some v -> v
        | None -> Voice_bridge.get_voice_for_agent agent_id
      in
      let now = Time_compat.now () in
      let session = {
        session_id = generate_session_id ();
        agent_id;
        voice;
        started_at = now;
        last_activity = now;
        turn_count = 0;
        status = Active;
        conversation_mode;
      } in
      save_session t session;
      Atomic.set
        t.state
        { sessions = Session_by_agent.add agent_id session current.sessions };
      session)

let end_session t ~agent_id =
  with_mutation t (fun () ->
    let current = Atomic.get t.state in
    match Session_by_agent.find_opt agent_id current.sessions with
    | Some _ ->
      delete_session_file t agent_id;
      Atomic.set
        t.state
        { sessions = Session_by_agent.remove agent_id current.sessions };
      true
    | None -> false)


let get_session t ~agent_id =
  Session_by_agent.find_opt agent_id (Atomic.get t.state).sessions

let list_sessions t =
  Session_by_agent.bindings (Atomic.get t.state).sessions
  |> List.map snd

let session_count t =
  Session_by_agent.cardinal (Atomic.get t.state).sessions

(** {1 Activity Tracking} *)

let increment_turn t ~agent_id =
  with_mutation t (fun () ->
    let current = Atomic.get t.state in
    match Session_by_agent.find_opt agent_id current.sessions with
    | Some session ->
      let session =
        {
          session with
          turn_count = session.turn_count + 1;
          last_activity = Time_compat.now ();
        }
      in
      save_session t session;
      Atomic.set
        t.state
        { sessions = Session_by_agent.add agent_id session current.sessions }
    | None -> ())

(** {1 Persistence} *)

let restore t =
  with_mutation t (fun () ->
    if Sys.file_exists t.session_dir && Sys.is_directory t.session_dir
    then (
      let files = Sys.readdir t.session_dir in
      let current = Atomic.get t.state in
      let sessions =
        Array.fold_left
          (fun sessions filename ->
            if Filename.check_suffix filename ".json"
            then (
              let agent_id = Filename.chop_suffix filename ".json" in
              match load_session t agent_id with
              | Some session -> Session_by_agent.add agent_id session sessions
              | None -> sessions)
            else sessions)
          current.sessions
          files
      in
      Atomic.set t.state { sessions }))

(** {1 Status} *)
