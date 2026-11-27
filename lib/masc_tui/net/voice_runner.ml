open Masc_tui_core
open Masc_tui_protocol

let voice_config_path = "/api/v1/voice/config"
let voice_transcribe_path = "/api/v1/voice/transcribe"
let voice_probe_stt_path = "/api/v1/voice/probe/stt"

type phase =
  | Voice_idle
  | Voice_recording of { started_ns : Clock.Mono.t; level_db : float option }
  | Voice_transcribing
  | Voice_failed of string

type command =
  | Start_ptt of { device : string option }
  | Stop_ptt
  | Cancel_ptt
  | Probe_capabilities

type capabilities = {
  recorder_available : bool;
  recorder_cmd : string option;
  stt_available : bool;
}

type recorder_kind =
  | Recorder_rec
  | Recorder_sox
  | Recorder_ffmpeg

type audio_platform =
  | Audio_macos
  | Audio_linux_pulse
  | Audio_linux_alsa

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

let resolve_recorder_for_device ~device ~find =
  let has_explicit_device =
    match device with
    | Some dev -> not (String.equal (String.trim dev) "")
    | None -> false
  in
  if has_explicit_device then
    (* [rec] only records from the default input; prefer [sox] or [ffmpeg]
       when the user configured a specific input device. *)
    match find "sox" with
    | Some p -> Some (Recorder_sox, p)
    | None -> (
        match find "ffmpeg" with
        | Some p -> Some (Recorder_ffmpeg, p)
        | None -> resolve_recorder_from ~find)
  else resolve_recorder_from ~find

let build_record_argv_for_platform ~platform ~kind ~bin_path ~device ~out_path =
  match (kind, device) with
  | Recorder_rec, _ ->
      [| bin_path; "-q"; "-r"; "16000"; "-c"; "1"; "-b"; "16"; out_path |]
  | Recorder_sox, Some dev when not (String.equal (String.trim dev) "") ->
      let driver =
        match platform with
        | Audio_macos -> "coreaudio"
        | Audio_linux_pulse -> "pulseaudio"
        | Audio_linux_alsa -> "alsa"
      in
      [|
        bin_path;
        "-q";
        "-t";
        driver;
        String.trim dev;
        "-r";
        "16000";
        "-c";
        "1";
        out_path;
      |]
  | Recorder_sox, (Some _ | None) ->
      [| bin_path; "-q"; "-d"; "-r"; "16000"; "-c"; "1"; out_path |]
  | Recorder_ffmpeg, _ -> (
      match platform with
      | Audio_macos ->
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
      | Audio_linux_pulse | Audio_linux_alsa ->
          let fmt =
            match platform with
            | Audio_linux_pulse -> "pulse"
            | Audio_linux_alsa -> "alsa"
            | Audio_macos -> "pulse"
          in
          let input =
            match device with
            | Some dev when not (String.equal (String.trim dev) "") ->
                String.trim dev
            | Some _ | None -> "default"
          in
          [|
            bin_path;
            "-y";
            "-loglevel";
            "error";
            "-f";
            fmt;
            "-i";
            input;
            "-ar";
            "16000";
            "-ac";
            "1";
            "-f";
            "wav";
            out_path;
          |])

let build_record_argv ~kind ~bin_path ~device ~out_path =
  build_record_argv_for_platform ~platform:Audio_macos ~kind ~bin_path ~device
    ~out_path

let rms_level_of_pcm16_le buf ~offset ~len =
  let buf_len = Bytes.length buf in
  let start = Int.max 0 (Int.min buf_len offset) in
  let avail = Int.max 0 (Int.min (buf_len - start) len) in
  let samples = avail / 2 in
  if samples <= 0 then 0.0
  else
    let sum_sq = ref 0.0 in
    for i = 0 to samples - 1 do
      let pos = start + (i * 2) in
      let lo = Char.code (Bytes.get buf pos) in
      let hi = Char.code (Bytes.get buf (pos + 1)) in
      let raw = lo lor (hi lsl 8) in
      let signed = if raw >= 32768 then raw - 65536 else raw in
      let norm = float_of_int signed /. 32768.0 in
      sum_sq := !sum_sq +. (norm *. norm)
    done;
    let rms = Float.sqrt (!sum_sq /. float_of_int samples) in
    if not (Float.is_finite rms) then 0.0
    else Float.max 0.0 (Float.min 1.0 (Float.sqrt rms *. 1.8))

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
  Ok
    {
      recorder_available = Option.is_some recorder_cmd;
      recorder_cmd;
      stt_available;
    }

type event =
  | Phase_changed of phase
  | Level_meter of float
  | Transcript_ready of string
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

let detect_audio_platform () =
  let is_linux =
    match Sys.file_exists "/proc/version" with
    | true -> true
    | false -> false
    | exception Sys_error _ -> false
  in
  if not is_linux then Audio_macos
  else
    let has_pulse_env =
      Option.is_some (Sys.getenv_opt "PULSE_SERVER")
      ||
      match Sys.getenv_opt "XDG_RUNTIME_DIR" with
      | Some dir -> (
          try Sys.file_exists (Filename.concat dir "pulse")
          with Sys_error _ -> false)
      | None -> false
    in
    if
      has_pulse_env
      || Option.is_some (find_on_path "pactl")
      || Option.is_some (find_on_path "parecord")
    then Audio_linux_pulse
    else Audio_linux_alsa

(* Read newly appended 16-bit PCM bytes from a growing WAV file past the
   44-byte header, returning [(next_offset, Some level)] when at least one
   PCM sample was available. *)
let poll_wav_rms_sync ~path ~offset =
  let header_bytes = 44 in
  match In_channel.open_bin path with
  | ic ->
      Fun.protect
        ~finally:(fun () -> In_channel.close_noerr ic)
        (fun () ->
          let file_len =
            match In_channel.length ic with
            | n -> Int64.to_int n
            | exception Sys_error _ -> 0
          in
          let start = Int.max header_bytes offset in
          let avail = file_len - start in
          let aligned = avail - (avail mod 2) in
          if aligned <= 0 then (start, None)
          else
            let max_chunk = 8192 in
            let read_from, to_read =
              if aligned > max_chunk then
                let skipped = aligned - max_chunk in
                let skipped_even = skipped - (skipped mod 2) in
                (start + skipped_even, aligned - skipped_even)
              else (start, aligned)
            in
            In_channel.seek ic (Int64.of_int read_from);
            let buf = Bytes.create to_read in
            let got = In_channel.input ic buf 0 to_read in
            let got_even = got - (got mod 2) in
            if got_even <= 0 then (start, None)
            else
              let level = rms_level_of_pcm16_le buf ~offset:0 ~len:got_even in
              (read_from + got_even, Some level))
  | exception Sys_error _ -> (offset, None)

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
          }
  in
  let record_until_stopped ~device ~stop_signal ~on_level =
    let recorder =
      Eio_unix.run_in_systhread (fun () ->
          resolve_recorder_for_device ~device ~find:find_on_path)
    in
    match recorder with
    | None -> Error "no supported audio recorder (rec/sox/ffmpeg) found on PATH"
    | Some (kind, bin_path) ->
        let platform, out_path =
          Eio_unix.run_in_systhread (fun () ->
              (detect_audio_platform (), Filename.temp_file "masc_ptt_" ".wav"))
        in
        let argv =
          build_record_argv_for_platform ~platform ~kind ~bin_path ~device
            ~out_path
        in
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
            let meter_loop () =
              let rec loop offset =
                Eio.Time.sleep clock 0.08;
                let next_offset, level_opt =
                  Eio_unix.run_in_systhread (fun () ->
                      poll_wav_rms_sync ~path:out_path ~offset)
                in
                Option.iter on_level level_opt;
                loop next_offset
              in
              loop 44
            in
            match
              Eio.Fiber.first
                (fun () -> Eio.Promise.await stop_signal)
                meter_loop
            with
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
  { probe; record_until_stopped; transcribe; cleanup_audio }

type recording_session = {
  id : int;
  stop_u : unit Eio.Promise.u;
  cancel_u : unit Eio.Promise.u;
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

let set_phase_if_active t ~session_id ~cancelled next =
  let updated =
    Stdlib.Mutex.protect t.mu (fun () ->
        if t.next_session_id = session_id && not (Atomic.get cancelled) then begin
          t.current_phase <- next;
          true
        end
        else false)
  in
  if updated then t.on_event (Phase_changed next);
  updated

let set_phase t next =
  Stdlib.Mutex.protect t.mu (fun () -> t.current_phase <- next);
  t.on_event (Phase_changed next)

let phase t = Stdlib.Mutex.protect t.mu (fun () -> t.current_phase)

let clear_session_if_id t session_id =
  Stdlib.Mutex.protect t.mu (fun () ->
      match t.session with
      | Some s when s.id = session_id -> t.session <- None
      | Some _ | None -> ())

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
      if cancel then begin
        Atomic.set sess.cancelled true;
        ignore (Eio.Promise.try_resolve sess.cancel_u () : bool)
      end;
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
      let cancel_signal, cancel_u = Eio.Promise.create () in
      let cancelled = Atomic.make false in
      let started_ns = Clock.Mono.now () in
      let session_id_opt =
        Stdlib.Mutex.protect t.mu (fun () ->
            match t.session with
            | Some _ -> None
            | None ->
                let id = t.next_session_id + 1 in
                t.next_session_id <- id;
                t.session <- Some { id; stop_u; cancel_u; cancelled };
                t.current_phase <- Voice_recording { started_ns; level_db = None };
                Some id)
      in
      (match session_id_opt with
      | None -> ()
      | Some session_id ->
          t.on_event
            (Phase_changed (Voice_recording { started_ns; level_db = None }));
          Eio.Fiber.fork ~sw:t.sw (fun () ->
              Fun.protect
                ~finally:(fun () -> clear_session_if_id t session_id)
                (fun () ->
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
                            | Voice_failed _ ) ->
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
                  if Atomic.get cancelled then begin
                    match rec_res with
                    | Ok audio_path -> t.backend.cleanup_audio ~audio_path
                    | Error _ -> ()
                  end
                  else
                    match rec_res with
                    | Error msg ->
                        if
                          set_phase_if_active t ~session_id ~cancelled
                            (Voice_failed msg)
                        then t.on_event (Voice_error msg)
                    | Ok audio_path -> (
                        if
                          set_phase_if_active t ~session_id ~cancelled
                            Voice_transcribing
                        then begin
                          let tr_res =
                            Eio.Fiber.first
                              (fun () ->
                                Eio.Promise.await cancel_signal;
                                t.backend.cleanup_audio ~audio_path;
                                Error "cancelled")
                              (fun () ->
                                match t.backend.transcribe ~audio_path with
                                | r -> r
                                | exception (Eio.Cancel.Cancelled _ as ex) ->
                                    t.backend.cleanup_audio ~audio_path;
                                    raise ex
                                | exception ex ->
                                    t.backend.cleanup_audio ~audio_path;
                                    Error (Printexc.to_string ex))
                          in
                          if Atomic.get cancelled then ()
                          else
                            match tr_res with
                            | Ok text ->
                                if
                                  set_phase_if_active t ~session_id ~cancelled
                                    Voice_idle
                                then t.on_event (Transcript_ready text)
                            | Error msg ->
                                if
                                  set_phase_if_active t ~session_id ~cancelled
                                    (Voice_failed msg)
                                then t.on_event (Voice_error msg)
                        end
                        else t.backend.cleanup_audio ~audio_path))))
  | Stop_ptt -> ignore (stop_active_session t ~cancel:false : bool)
  | Cancel_ptt ->
      if stop_active_session t ~cancel:true then set_phase t Voice_idle

let stop t =
  if stop_active_session t ~cancel:true then
    Stdlib.Mutex.protect t.mu (fun () -> t.current_phase <- Voice_idle)
