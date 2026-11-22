open Masc_tui_core
open Masc_tui_protocol

let voice_config_path = "/api/v1/voice/config"
let voice_transcribe_path = "/api/v1/voice/transcribe"
let voice_probe_tts_path = "/api/v1/voice/probe/tts"
let voice_probe_stt_path = "/api/v1/voice/probe/stt"

type phase =
  | Voice_idle
  | Voice_recording of { started_ns : Clock.Mono.t; level_db : float option }
  | Voice_transcribing
  | Voice_speaking
  | Voice_failed of string

type command =
  | Start_ptt of { device : string option }
  | Stop_ptt
  | Cancel_ptt
  | Speak of { text : string; voice_id : string option }
  | Probe_capabilities

type capabilities = {
  recorder_available : bool;
  recorder_cmd : string option;
  stt_available : bool;
  tts_available : bool;
}

type recorder_kind =
  | Recorder_rec
  | Recorder_sox
  | Recorder_ffmpeg

let resolve_recorder_from ~find =
  match find "rec" with
  | Some p -> Some (Recorder_rec, p)
  | None -> (
      match find "sox" with
      | Some p -> Some (Recorder_sox, p)
      | None -> (
          match find "ffmpeg" with
          | Some p -> Some (Recorder_ffmpeg, p)
          | None -> None))

let build_record_argv ~kind ~bin_path ~device ~out_path =
  match (kind, device) with
  | Recorder_rec, _ ->
      [| bin_path; "-q"; "-r"; "16000"; "-c"; "1"; "-b"; "16"; out_path |]
  | Recorder_sox, Some dev when not (String.equal (String.trim dev) "") ->
      [|
        bin_path;
        "-q";
        "-t";
        "coreaudio";
        String.trim dev;
        "-r";
        "16000";
        "-c";
        "1";
        out_path;
      |]
  | Recorder_sox, (Some _ | None) ->
      [| bin_path; "-q"; "-d"; "-r"; "16000"; "-c"; "1"; out_path |]
  | Recorder_ffmpeg, _ ->
      let input =
        match device with
        | Some dev when not (String.equal (String.trim dev) "") ->
            let d = String.trim dev in
            if String.contains d ':' then d else ":" ^ d
        | Some _ | None -> ":default"
      in
      [|
        bin_path;
        "-y";
        "-loglevel";
        "error";
        "-f";
        "avfoundation";
        "-i";
        input;
        "-ar";
        "16000";
        "-ac";
        "1";
        "-f";
        "wav";
        out_path;
      |]

type audio_player =
  | Player_afplay
  | Player_paplay
  | Player_aplay
  | Player_ffplay

let audio_player_name = function
  | Player_afplay -> "afplay"
  | Player_paplay -> "paplay"
  | Player_aplay -> "aplay"
  | Player_ffplay -> "ffplay"

let resolve_audio_player_from ~find =
  match find "afplay" with
  | Some p -> Some (Player_afplay, p)
  | None -> (
      match find "paplay" with
      | Some p -> Some (Player_paplay, p)
      | None -> (
          match find "aplay" with
          | Some p -> Some (Player_aplay, p)
          | None -> (
              match find "ffplay" with
              | Some p -> Some (Player_ffplay, p)
              | None -> None)))

let build_player_argv ~player ~bin_path ~audio_path =
  match player with
  | Player_afplay -> [| bin_path; audio_path |]
  | Player_paplay -> [| bin_path; audio_path |]
  | Player_aplay -> [| bin_path; "-q"; audio_path |]
  | Player_ffplay ->
      [| bin_path; "-nodisp"; "-autoexit"; "-loglevel"; "quiet"; audio_path |]

type tts_probe_outcome =
  | Tts_audio_file of string
  | Tts_probe_answered_no_audio of { endpoint_id : string; detail : string }
  | Tts_probe_failed of string

let ( let* ) = Result.bind

let assoc_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None

let section_endpoint_enabled json key =
  match assoc_opt key json with
  | None | Some `Null -> Ok false
  | Some (`Assoc _ as section) -> (
      match assoc_opt "active_endpoint" section with
      | None | Some `Null -> Ok false
      | Some (`Assoc _ as ep) -> (
          match assoc_opt "enabled" ep with
          | Some (`Bool b) -> Ok b
          | Some _ -> Error (Printf.sprintf "%s.active_endpoint.enabled must be boolean" key)
          | None -> Error (Printf.sprintf "%s.active_endpoint.enabled is required" key))
      | Some _ -> Error (Printf.sprintf "%s.active_endpoint must be an object or null" key))
  | Some _ -> Error (Printf.sprintf "%s must be an object or null" key)

let decode_voice_config ~recorder_cmd json =
  let* _, body = Wire_common.unwrap_v2_or_raw json in
  let* stt_available = section_endpoint_enabled body "stt" in
  let* tts_available = section_endpoint_enabled body "tts" in
  Ok
    {
      recorder_available = Option.is_some recorder_cmd;
      recorder_cmd;
      stt_available;
      tts_available;
    }

let encode_tts_probe_request ~text = `Assoc [ ("message", `String text) ]

let decode_tts_probe_outcome json =
  let* _, body = Wire_common.unwrap_v2_or_raw json in
  let opt_str key obj =
    match assoc_opt key obj with
    | Some (`String s) when not (String.equal (String.trim s) "") ->
        Some (String.trim s)
    | Some _ | None -> None
  in
  let file_path_opt =
    match opt_str "audio_path" body with
    | Some _ as p -> p
    | None -> opt_str "file" body
  in
  match file_path_opt with
  | Some path -> Ok (Tts_audio_file path)
  | None -> (
      match assoc_opt "endpoints" body with
      | Some (`List []) ->
          Ok (Tts_probe_failed "no TTS endpoints configured on server")
      | Some (`List items) ->
          let answered = ref None in
          let failures = ref [] in
          List.iter
            (fun item ->
              let ep_id =
                Option.value (opt_str "endpoint_id" item) ~default:"endpoint"
              in
              let state =
                Option.value (opt_str "state" item) ~default:"unknown"
              in
              let detail = Option.value (opt_str "detail" item) ~default:"" in
              match state with
              | "answered" -> (
                  match !answered with
                  | None -> answered := Some (ep_id, detail)
                  | Some _ -> ())
              | _ ->
                  let summary =
                    if String.equal detail "" then
                      Printf.sprintf "%s: %s" ep_id state
                    else Printf.sprintf "%s: %s (%s)" ep_id state detail
                  in
                  failures := summary :: !failures)
            items;
          (match !answered with
          | Some (endpoint_id, detail) ->
              Ok (Tts_probe_answered_no_audio { endpoint_id; detail })
          | None ->
              let reason =
                match List.rev !failures with
                | [] -> "TTS probe did not report an answered endpoint"
                | xs -> String.concat "; " xs
              in
              Ok (Tts_probe_failed reason))
      | Some _ -> Error "TTS probe endpoints field must be a list"
      | None ->
          Ok (Tts_probe_failed "TTS response contained neither audio file nor endpoints"))

type event =
  | Phase_changed of phase
  | Level_meter of float
  | Transcript_ready of string
  | Speak_done
  | Capabilities of capabilities
  | Voice_error of string

type backend = {
  probe : unit -> (capabilities, string) result;
  record_until_stopped :
    device:string option ->
    stop_signal:unit Eio.Promise.t ->
    on_level:(float -> unit) ->
    (string, string) result;
  transcribe : audio_path:string -> (string, string) result;
  speak : text:string -> voice_id:string option -> (unit, string) result;
  cleanup_audio : audio_path:string -> unit;
}

let find_on_path cmd =
  match Sys.getenv_opt "PATH" with
  | None -> None
  | Some path_env ->
      String.split_on_char ':' path_env
      |> List.find_map (fun dir ->
             if String.equal (String.trim dir) "" then None
             else
               let candidate = Filename.concat dir cmd in
               match Unix.access candidate [ Unix.X_OK ] with
               | () -> Some candidate
               | exception Unix.Unix_error _ -> None)

let unlink_quiet_sync path =
  try Unix.unlink path with Unix.Unix_error _ -> ()

let read_file_bytes_sync path =
  match In_channel.open_bin path with
  | ic ->
      Fun.protect
        ~finally:(fun () -> In_channel.close_noerr ic)
        (fun () -> Ok (In_channel.input_all ic))
  | exception Sys_error msg -> Error ("read audio file failed: " ^ msg)

(* Reap a child process cleanly with bounded SIGINT -> SIGTERM -> SIGKILL
   escalation so a hung audio recorder never blocks cancellation or shutdown. *)
let stop_and_reap_pid_sync pid =
  let try_reap () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ -> false
    | _ -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> false
    | exception Unix.Unix_error _ -> true
  in
  let send_signal sig_num =
    try Unix.kill pid sig_num with Unix.Unix_error _ -> ()
  in
  let poll_wait ~steps ~step_sec =
    let rec loop n =
      if try_reap () then true
      else if n <= 0 then false
      else begin
        Unix.sleepf step_sec;
        loop (n - 1)
      end
    in
    loop steps
  in
  send_signal Sys.sigint;
  if not (poll_wait ~steps:10 ~step_sec:0.025) then begin
    send_signal Sys.sigterm;
    if not (poll_wait ~steps:10 ~step_sec:0.025) then begin
      send_signal Sys.sigkill;
      let rec final_wait () =
        match Unix.waitpid [] pid with
        | _ -> ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> final_wait ()
        | exception Unix.Unix_error _ -> ()
      in
      final_wait ()
    end
  end

(* Spawn with stdin/stdout/stderr redirected to [/dev/null] so the child never
   corrupts the raw terminal TTY. *)
let spawn_detached_sync ~bin_path ~argv =
  match Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 with
  | devnull ->
      Fun.protect
        ~finally:(fun () ->
          try Unix.close devnull with Unix.Unix_error _ -> ())
        (fun () ->
          match Unix.create_process bin_path argv devnull devnull devnull with
          | pid -> Ok pid
          | exception Unix.Unix_error (err, fn, _) ->
              Error (Printf.sprintf "%s: %s" fn (Unix.error_message err)))
  | exception Unix.Unix_error (err, fn, _) ->
      Error (Printf.sprintf "%s(/dev/null): %s" fn (Unix.error_message err))

let http_and_local_backend ~io ~clock ~endpoint =
  let clock = (clock :> float Eio.Time.clock_ty Eio.Resource.t) in
  let cleanup_audio ~audio_path =
    Eio.Cancel.protect (fun () ->
        Eio_unix.run_in_systhread (fun () -> unlink_quiet_sync audio_path))
  in
  let probe () =
    let recorder_cmd =
      Eio_unix.run_in_systhread (fun () ->
          Option.map snd (resolve_recorder_from ~find:find_on_path))
    in
    match
      Http_client.get_json ~io ~clock ~timeout_sec:3.0 endpoint
        ~path:voice_config_path ~decode:(decode_voice_config ~recorder_cmd)
    with
    | Ok caps -> Ok caps
    | Error _ ->
        Ok
          {
            recorder_available = Option.is_some recorder_cmd;
            recorder_cmd;
            stt_available = false;
            tts_available = false;
          }
  in
  let record_until_stopped ~device ~stop_signal ~on_level:_ =
    let recorder =
      Eio_unix.run_in_systhread (fun () ->
          resolve_recorder_from ~find:find_on_path)
    in
    match recorder with
    | None -> Error "no supported audio recorder (rec/sox/ffmpeg) found on PATH"
    | Some (kind, bin_path) ->
        let out_path =
          Eio_unix.run_in_systhread (fun () ->
              Filename.temp_file "masc_ptt_" ".wav")
        in
        let argv = build_record_argv ~kind ~bin_path ~device ~out_path in
        let pid_ref : int option Atomic.t = Atomic.make None in
        let reap_if_spawned () =
          match Atomic.exchange pid_ref None with
          | None -> ()
          | Some pid ->
              Eio_unix.run_in_systhread (fun () -> stop_and_reap_pid_sync pid)
        in
        let cleanup_all () =
          Eio.Cancel.protect (fun () ->
              reap_if_spawned ();
              Eio_unix.run_in_systhread (fun () -> unlink_quiet_sync out_path))
        in
        (match
           Eio_unix.run_in_systhread (fun () ->
               match spawn_detached_sync ~bin_path ~argv with
               | Ok pid ->
                   Atomic.set pid_ref (Some pid);
                   Ok pid
               | Error _ as err -> err)
         with
        | Error _ as err ->
            cleanup_all ();
            err
        | Ok _pid -> (
            match Eio.Promise.await stop_signal with
            | () ->
                Eio.Cancel.protect reap_if_spawned;
                Ok out_path
            | exception (Eio.Cancel.Cancelled _ as cancelled) ->
                cleanup_all ();
                raise cancelled)
        | exception (Eio.Cancel.Cancelled _ as cancelled) ->
            cleanup_all ();
            raise cancelled)
  in
  let transcribe ~audio_path =
    let read_res =
      match Eio_unix.run_in_systhread (fun () -> read_file_bytes_sync audio_path) with
      | res ->
          cleanup_audio ~audio_path;
          res
      | exception (Eio.Cancel.Cancelled _ as cancelled) ->
          cleanup_audio ~audio_path;
          raise cancelled
    in
    match read_res with
    | Error msg -> Error msg
    | Ok wav_bytes -> (
        if String.length wav_bytes = 0 then Error "recorded audio file is empty"
        else
          match
            Http_client.post_raw ~io ~clock ~timeout_sec:30.0
              ~content_type:"audio/wav" ~body:wav_bytes endpoint
              ~path:voice_transcribe_path
          with
          | Error err -> Error (Http_client.http_error_to_string err)
          | Ok body -> (
              match Yojson.Safe.from_string body with
              | json -> Wire_common.required_nonblank_string json "text"
              | exception Yojson.Json_error msg ->
                  Error ("invalid transcribe JSON: " ^ msg)))
  in
  let play_audio_file_cancel_safe ~player ~bin_path ~audio_path =
    let exists =
      Eio_unix.run_in_systhread (fun () -> Sys.file_exists audio_path)
    in
    if not exists then Error ("TTS audio file not found: " ^ audio_path)
    else
      let player_lbl = audio_player_name player in
      let argv = build_player_argv ~player ~bin_path ~audio_path in
      let pid_ref : int option Atomic.t = Atomic.make None in
      let reap_if_spawned () =
        match Atomic.exchange pid_ref None with
        | None -> ()
        | Some pid ->
            Eio_unix.run_in_systhread (fun () -> stop_and_reap_pid_sync pid)
      in
      let spawn_res =
        Eio_unix.run_in_systhread (fun () ->
            match spawn_detached_sync ~bin_path ~argv with
            | Ok pid ->
                Atomic.set pid_ref (Some pid);
                Ok pid
            | Error _ as err -> err)
      in
      match spawn_res with
      | Error _ as err -> err
      | Ok pid ->
          let rec poll () =
            let status_opt =
              Eio_unix.run_in_systhread (fun () ->
                  match Unix.waitpid [ Unix.WNOHANG ] pid with
                  | 0, _ -> Ok None
                  | _, st ->
                      Atomic.set pid_ref None;
                      Ok (Some st)
                  | exception Unix.Unix_error (Unix.EINTR, _, _) -> Ok None
                  | exception Unix.Unix_error (Unix.ECHILD, _, _) ->
                      Atomic.set pid_ref None;
                      Ok (Some (Unix.WEXITED 0))
                  | exception Unix.Unix_error (e, fn, _) ->
                      Atomic.set pid_ref None;
                      Error
                        (Printf.sprintf "%s: %s" fn (Unix.error_message e)))
            in
            match status_opt with
            | Error _ as err -> err
            | Ok None ->
                Eio.Time.sleep clock 0.025;
                poll ()
            | Ok (Some (Unix.WEXITED 0)) -> Ok ()
            | Ok (Some (Unix.WEXITED code)) ->
                Error
                  (Printf.sprintf "%s exited with status %d" player_lbl code)
            | Ok (Some (Unix.WSIGNALED s | Unix.WSTOPPED s)) ->
                Error
                  (Printf.sprintf "%s stopped by signal %d" player_lbl s)
          in
          (match poll () with
          | res ->
              Eio.Cancel.protect reap_if_spawned;
              res
          | exception (Eio.Cancel.Cancelled _ as cancelled) ->
              Eio.Cancel.protect reap_if_spawned;
              raise cancelled)
  in
  let speak ~text ~voice_id:_ =
    let trimmed = String.trim text in
    if String.equal trimmed "" then Error "empty text for TTS playback"
    else
      let player_opt =
        Eio_unix.run_in_systhread (fun () ->
            resolve_audio_player_from ~find:find_on_path)
      in
      match player_opt with
      | None ->
          Error
            "no local audio player (afplay/paplay/aplay/ffplay) found on PATH"
      | Some (player, bin_path) -> (
          let body = encode_tts_probe_request ~text:trimmed in
          match
            Http_client.post_json ~io ~clock ~timeout_sec:15.0 endpoint
              ~path:voice_probe_tts_path ~body ~decode:decode_tts_probe_outcome
          with
          | Error err -> Error (Http_client.http_error_to_string err)
          | Ok (Tts_audio_file audio_path) ->
              play_audio_file_cancel_safe ~player ~bin_path ~audio_path
          | Ok (Tts_probe_answered_no_audio { endpoint_id; detail }) ->
              let detail_suffix =
                if String.equal detail "" then "" else " (" ^ detail ^ ")"
              in
              Error
                (Printf.sprintf
                   "TTS probe %s answered%s without downloadable audio; local \
                    playback requires a synthesis audio file"
                   endpoint_id detail_suffix)
          | Ok (Tts_probe_failed reason) ->
              Error ("TTS probe failed: " ^ reason))
  in
  { probe; record_until_stopped; transcribe; speak; cleanup_audio }

type recording_session = {
  id : int;
  stop_u : unit Eio.Promise.u;
  cancelled : bool Atomic.t;
}

type t = {
  sw : Eio.Switch.t;
  backend : backend;
  on_event : event -> unit;
  mu : Stdlib.Mutex.t;
  mutable next_session_id : int;
  mutable current_phase : phase;
  mutable session : recording_session option;
}

let create ~sw ~backend ~on_event =
  Eio.Switch.check sw;
  {
    sw;
    backend;
    on_event;
    mu = Stdlib.Mutex.create ();
    next_session_id = 0;
    current_phase = Voice_idle;
    session = None;
  }

let set_phase_if_current t ~session_id next =
  let updated =
    Stdlib.Mutex.protect t.mu (fun () ->
        if t.next_session_id = session_id then begin
          t.current_phase <- next;
          true
        end
        else false)
  in
  if updated then t.on_event (Phase_changed next)

let set_phase t next =
  Stdlib.Mutex.protect t.mu (fun () -> t.current_phase <- next);
  t.on_event (Phase_changed next)

let phase t = Stdlib.Mutex.protect t.mu (fun () -> t.current_phase)

let stop_active_session t ~cancel =
  let sess_opt =
    Stdlib.Mutex.protect t.mu (fun () ->
        let s = t.session in
        if cancel then t.session <- None;
        s)
  in
  match sess_opt with
  | None -> false
  | Some sess ->
      if cancel then Atomic.set sess.cancelled true;
      ignore (Eio.Promise.try_resolve sess.stop_u () : bool);
      true

let dispatch t = function
  | Probe_capabilities ->
      Eio.Switch.check t.sw;
      Eio.Fiber.fork ~sw:t.sw (fun () ->
          let res =
            match t.backend.probe () with
            | r -> r
            | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
            | exception ex -> Error (Printexc.to_string ex)
          in
          match res with
          | Ok caps -> t.on_event (Capabilities caps)
          | Error msg -> t.on_event (Voice_error msg))
  | Start_ptt { device } ->
      Eio.Switch.check t.sw;
      let stop_signal, stop_u = Eio.Promise.create () in
      let cancelled = Atomic.make false in
      let started_ns = Clock.Mono.now () in
      let session_id_opt =
        Stdlib.Mutex.protect t.mu (fun () ->
            match t.session with
            | Some _ -> None
            | None ->
                let id = t.next_session_id + 1 in
                t.next_session_id <- id;
                t.session <- Some { id; stop_u; cancelled };
                t.current_phase <- Voice_recording { started_ns; level_db = None };
                Some id)
      in
      (match session_id_opt with
      | None -> ()
      | Some session_id ->
          t.on_event
            (Phase_changed (Voice_recording { started_ns; level_db = None }));
          Eio.Fiber.fork ~sw:t.sw (fun () ->
              let on_level db =
                let active =
                  Stdlib.Mutex.protect t.mu (fun () ->
                      match (t.session, t.current_phase) with
                      | Some s, Voice_recording r
                        when s.id = session_id && not (Atomic.get cancelled) ->
                          t.current_phase <-
                            Voice_recording { r with level_db = Some db };
                          true
                      | (Some _ | None),
                        ( Voice_idle | Voice_recording _ | Voice_transcribing
                        | Voice_speaking | Voice_failed _ ) ->
                          false)
                in
                if active then t.on_event (Level_meter db)
              in
              let rec_res =
                match
                  t.backend.record_until_stopped ~device ~stop_signal ~on_level
                with
                | r -> r
                | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
                | exception ex -> Error (Printexc.to_string ex)
              in
              Stdlib.Mutex.protect t.mu (fun () ->
                  match t.session with
                  | Some s when s.id = session_id -> t.session <- None
                  | Some _ | None -> ());
              if Atomic.get cancelled then begin
                (match rec_res with
                | Ok audio_path -> t.backend.cleanup_audio ~audio_path
                | Error _ -> ());
                set_phase_if_current t ~session_id Voice_idle
              end
              else
                match rec_res with
                | Error msg ->
                    set_phase_if_current t ~session_id (Voice_failed msg);
                    t.on_event (Voice_error msg)
                | Ok audio_path -> (
                    set_phase_if_current t ~session_id Voice_transcribing;
                    let tr_res =
                      match t.backend.transcribe ~audio_path with
                      | r -> r
                      | exception (Eio.Cancel.Cancelled _ as ex) ->
                          t.backend.cleanup_audio ~audio_path;
                          raise ex
                      | exception ex ->
                          t.backend.cleanup_audio ~audio_path;
                          Error (Printexc.to_string ex)
                    in
                    if Atomic.get cancelled then
                      set_phase_if_current t ~session_id Voice_idle
                    else
                      match tr_res with
                      | Ok text ->
                          set_phase_if_current t ~session_id Voice_idle;
                          t.on_event (Transcript_ready text)
                      | Error msg ->
                          set_phase_if_current t ~session_id (Voice_failed msg);
                          t.on_event (Voice_error msg))))
  | Stop_ptt -> ignore (stop_active_session t ~cancel:false : bool)
  | Cancel_ptt ->
      if stop_active_session t ~cancel:true then set_phase t Voice_idle
  | Speak { text; voice_id } ->
      Eio.Switch.check t.sw;
      let session_id =
        Stdlib.Mutex.protect t.mu (fun () ->
            let id = t.next_session_id + 1 in
            t.next_session_id <- id;
            t.current_phase <- Voice_speaking;
            id)
      in
      t.on_event (Phase_changed Voice_speaking);
      Eio.Fiber.fork ~sw:t.sw (fun () ->
          let res =
            match t.backend.speak ~text ~voice_id with
            | r -> r
            | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
            | exception ex -> Error (Printexc.to_string ex)
          in
          match res with
          | Ok () ->
              set_phase_if_current t ~session_id Voice_idle;
              t.on_event Speak_done
          | Error msg ->
              set_phase_if_current t ~session_id (Voice_failed msg);
              t.on_event (Voice_error msg))

let stop t = ignore (stop_active_session t ~cancel:true : bool)
