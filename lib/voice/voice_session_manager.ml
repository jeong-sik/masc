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
  mutable last_activity: float;
  mutable turn_count: int;
  mutable status: session_status;
  mutable conversation_mode: conversation_mode;
}

type t = {
  sessions: (string, session) Hashtbl.t;  (* agent_id -> session *)
  config_path: string;
  session_dir: string;
  sessions_mu: Eio.Mutex.t;
  (** Serialises every read/write on [sessions] and every mutation of
      the [mutable] fields of a [session] value.  Keeper fibers call
      start_session / heartbeat / end_session / cleanup_zombies from
      different turns concurrently, and without the lock the Hashtbl
      races on TOCTOU ([find_opt] + [add]) and the session record's
      mutable [turn_count]/[last_activity]/[status] are non-atomic.

      Eio.Mutex via [Eio_guard.with_mutex] so contending fibers
      suspend instead of blocking the whole domain during file I/O. *)
}

(** {1 Utilities} *)

let generate_session_id () =
  (* intentional: voice session IDs need randomness for distributed uniqueness *)
  let high = Random.int 0xFFFF in
  let mid = Random.int 0xFFFF in
  let low = Random.int 0xFFFF in
  Printf.sprintf "vs-%08x-%04x%04x%04x"
    (Random.int 0x3FFFFFFF)
    high mid low

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

let realtime_bridge_env = "MASC_VOICE_REALTIME_WS_URL"

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
          ; "browser_route", `String "GET /api/v1/voice/audio/<token>"
          ] )
    ; ( "keeper_next_actions"
      , `List
          [ `String "Use keeper_voice_speak for audible keeper output."
          ; `String
              "Treat transcribed operator speech as normal text input; do not wait \
               for a live duplex audio stream."
          ; `String
              "Call keeper_voice_agent to inspect whether a turn-based voice session \
               is active."
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
          ; "fallback_route", `String "POST /api/v1/voice/transcribe"
          ] )
    ; ( "keeper_output"
      , `Assoc
          [ "delivery", `String "assistant_audio_events_or_tts_audio_clip"
          ; "fallback_tool", `String "keeper_voice_speak"
          ; "browser_route", `String "GET /api/v1/voice/audio/<token>"
          ] )
    ; ( "keeper_next_actions"
      , `List
          [ `String
              "Use the realtime bridge for live audio frames while the session \
               is active."
          ; `String
              "Fall back to keeper_voice_speak and batch STT/TTS if the bridge \
               disconnects."
          ; `String
              "Call keeper_voice_agent to inspect active realtime bridge state."
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
  Random.self_init ();
  let session_dir = Filename.concat config_path "voice_sessions" in
  {
    sessions = Hashtbl.create 16;
    config_path;
    session_dir;
    sessions_mu = Eio.Mutex.create ();
  }

let with_lock t f =
  Eio_guard.with_mutex t.sessions_mu f

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
  with_lock t (fun () ->
    (* Check if session already exists *)
    match Hashtbl.find_opt t.sessions agent_id with
    | Some existing ->
      existing.status <- Active;
      existing.last_activity <- Time_compat.now ();
      existing.conversation_mode <- conversation_mode;
      save_session t existing;
      existing
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
      Hashtbl.add t.sessions agent_id session;
      save_session t session;
      session)

let end_session t ~agent_id =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.sessions agent_id with
    | Some _ ->
      Hashtbl.remove t.sessions agent_id;
      delete_session_file t agent_id;
      true
    | None -> false)

let suspend_session t ~agent_id =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.sessions agent_id with
    | Some session ->
      session.status <- Suspended;
      save_session t session
    | None -> ())

let resume_session t ~agent_id =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.sessions agent_id with
    | Some session ->
      session.status <- Active;
      session.last_activity <- Time_compat.now ();
      save_session t session
    | None -> ())

(** {1 Session Query} *)

let get_session t ~agent_id =
  with_lock t (fun () -> Hashtbl.find_opt t.sessions agent_id)

let list_sessions t =
  with_lock t (fun () ->
    Hashtbl.fold (fun _ session acc -> session :: acc) t.sessions [])

let has_session t ~agent_id =
  with_lock t (fun () -> Hashtbl.mem t.sessions agent_id)

let session_count t =
  with_lock t (fun () -> Hashtbl.length t.sessions)

(** {1 Activity Tracking} *)

let heartbeat t ~agent_id =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.sessions agent_id with
    | Some session ->
      session.last_activity <- Time_compat.now ();
      save_session t session
    | None -> ())

let increment_turn t ~agent_id =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.sessions agent_id with
    | Some session ->
      session.turn_count <- session.turn_count + 1;
      session.last_activity <- Time_compat.now ();
      save_session t session
    | None -> ())

(** {1 Zombie Cleanup} *)

let cleanup_zombies t ?(timeout = Workspace_resilience.default_zombie_threshold) () =
  with_lock t (fun () ->
    let now = Time_compat.now () in
    let to_remove = Hashtbl.fold (fun agent_id session acc ->
      if now -. session.last_activity > timeout then
        agent_id :: acc
      else
        acc
    ) t.sessions [] in
    List.iter (fun agent_id ->
      Hashtbl.remove t.sessions agent_id;
      delete_session_file t agent_id
    ) to_remove;
    List.length to_remove)

(** {1 Persistence} *)

let persist t =
  ensure_session_dir t;
  with_lock t (fun () ->
    Hashtbl.iter (fun _ session -> save_session t session) t.sessions)

let restore t =
  if Sys.file_exists t.session_dir && Sys.is_directory t.session_dir then begin
    let files = Sys.readdir t.session_dir in
    with_lock t (fun () ->
      Array.iter (fun filename ->
        if Filename.check_suffix filename ".json" then begin
          let agent_id = Filename.chop_suffix filename ".json" in
          match load_session t agent_id with
          | Some session ->
            Hashtbl.add t.sessions agent_id session
          | None -> ()
        end
      ) files)
  end

(** {1 Status} *)

let status_json t =
  let sessions_json = list_sessions t
    |> List.map session_to_json
    |> (fun l -> `List l)
  in
  `Assoc [
    ("session_count", `Int (session_count t));
    ("config_path", `String t.config_path);
    ("sessions", sessions_json);
  ]
