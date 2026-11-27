open Masc_tui_protocol

type os_family =
  | Os_macos
  | Os_linux

type playback_plan =
  | Audio_spawn of { executable : string; args : string list }
  | Midi_fluidsynth of { executable : string; args : string list }
  | Midi_handoff_alphatex of string
  | Video_open of { executable : string; args : string list }

type play_outcome =
  | Playing of string
  | Opened_external of string
  | Handoff_alphatex of string

type reap_state = {
  reap_mu : Stdlib.Mutex.t;
  mutable reaped : bool;
}

type active_process = {
  pid : int;
  label : string;
  reap_state : reap_state;
  reaper : Thread.t;
}

let max_retained_temps = 4

type t = {
  mu : Stdlib.Mutex.t;
  mutable active : active_process option;
  mutable retained_temps : string list;
}

let create () =
  { mu = Stdlib.Mutex.create (); active = None; retained_temps = [] }

let detect_os () =
  match Sys.os_type with
  | "Unix" ->
      if Sys.file_exists "/System/Library/CoreServices/SystemVersion.plist" then
        Os_macos
      else Os_linux
  | _ -> Os_linux

let default_file_exists path =
  match Unix.stat path with
  | { Unix.st_kind = Unix.S_REG; _ } -> true
  | {
      Unix.st_kind =
        Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
        | Unix.S_SOCK;
      _;
    } ->
      false
  | exception Unix.Unix_error _ -> false

let find_soundfont ?(getenv = Sys.getenv_opt)
    ?(executable_name = Sys.executable_name) ?base_path
    ?(file_exists = default_file_exists) () =
  let nonblank s =
    let t = String.trim s in
    if String.equal t "" then None else Some t
  in
  let env_sf = Option.bind (getenv "MASC_SOUNDFONT") nonblank in
  let home = Option.bind (getenv "HOME") nonblank in
  let sibling_dir =
    if String.equal (String.trim executable_name) "" then None
    else Some (Filename.dirname executable_name)
  in
  let candidates =
    (match env_sf with Some p -> [ p ] | None -> [])
    @ (match base_path with
       | Some bp when not (String.equal (String.trim bp) "") ->
           [
             Filename.concat
               (Filename.concat (Common.masc_dir_from_base_path ~base_path:bp) "music")
               "sonivox.sf2";
             Filename.concat (Filename.concat bp "assets") "sonivox.sf2";
           ]
       | Some _ | None -> [])
    @ (match sibling_dir with
       | Some dir ->
           [
             Filename.concat dir "sonivox.sf2";
             Filename.concat (Filename.concat dir "../share/masc") "sonivox.sf2";
           ]
       | None -> [])
    @ (match home with
       | Some h ->
           [
             Filename.concat h ".local/share/masc/sonivox.sf2";
             Filename.concat h ".local/bin/sonivox.sf2";
             Filename.concat h ".masc/music/sonivox.sf2";
           ]
       | None -> [])
    @ [
        "/opt/homebrew/share/soundfonts/default.sf2";
        "/opt/homebrew/share/soundfonts/FluidR3_GM.sf2";
        "/usr/local/share/soundfonts/default.sf2";
        "/usr/local/share/soundfonts/FluidR3_GM.sf2";
        "/usr/share/sounds/sf2/FluidR3_GM.sf2";
        "/usr/share/sounds/sf2/default-GM.sf2";
        "/usr/share/soundfonts/FluidR3_GM.sf2";
        "/usr/share/soundfonts/default.sf2";
      ]
  in
  List.find_opt file_exists candidates

let first_available ~resolve names =
  List.find_map
    (fun name ->
      match resolve name with
      | Some exe -> Some (name, exe)
      | None -> None)
    names

let plan_playback ?(os = detect_os ())
    ?(resolve = fun name -> Executable_path.absolute_on_path name)
    ?soundfont ~mime_type ~path () =
  let mime = Wire_attachment.normalize_mime mime_type in
  if String.equal mime "audio/midi" then
    match resolve "fluidsynth", soundfont with
    | Some fs_exe, Some sf when not (String.equal (String.trim sf) "") ->
        Ok (Midi_fluidsynth { executable = fs_exe; args = [ "-i"; "-n"; "-q"; sf; path ] })
    | _ -> Ok (Midi_handoff_alphatex path)
  else if Wire_attachment.is_video_mime mime then
    let candidates =
      match os with
      | Os_macos -> [ "open"; "ffplay" ]
      | Os_linux -> [ "xdg-open"; "ffplay" ]
    in
    match first_available ~resolve candidates with
    | Some ("ffplay", exe) ->
        Ok (Video_open { executable = exe; args = [ "-autoexit"; "-loglevel"; "quiet"; path ] })
    | Some (_, exe) -> Ok (Video_open { executable = exe; args = [ path ] })
    | None -> Error "no video player found (need open/xdg-open or ffplay)"
  else if String.starts_with ~prefix:"audio/" mime then
    let candidates =
      match os with
      | Os_macos -> [ "afplay"; "ffplay" ]
      | Os_linux -> [ "ffplay"; "paplay"; "aplay" ]
    in
    match first_available ~resolve candidates with
    | Some ("ffplay", exe) ->
        Ok
          (Audio_spawn
             {
               executable = exe;
               args = [ "-nodisp"; "-autoexit"; "-loglevel"; "quiet"; path ];
             })
    | Some (_, exe) -> Ok (Audio_spawn { executable = exe; args = [ path ] })
    | None -> Error "no audio player found (need afplay, ffplay, paplay, or aplay)"
  else
    Error (Printf.sprintf "unsupported playable media type: %s" mime)

let remove_quietly path =
  match Sys.remove path with
  | () -> ()
  | exception Sys_error _ -> ()

let close_quietly fd =
  match Unix.close fd with
  | () -> ()
  | exception Unix.Unix_error _ -> ()

let signal_if_alive (proc : active_process) sig_num =
  Stdlib.Mutex.protect proc.reap_state.reap_mu (fun () ->
      if not proc.reap_state.reaped then
        try Unix.kill proc.pid sig_num with Unix.Unix_error _ -> ())

let is_reaped (proc : active_process) =
  Stdlib.Mutex.protect proc.reap_state.reap_mu (fun () ->
      proc.reap_state.reaped)

let reap_active_proc (proc : active_process) =
  signal_if_alive proc Sys.sigterm;
  let rec wait_grace tries =
    if is_reaped proc then ()
    else if tries > 0 then (
      Unix.sleepf 0.02;
      wait_grace (tries - 1))
    else signal_if_alive proc Sys.sigkill
  in
  wait_grace 10;
  Thread.join proc.reaper

let take_active t =
  Stdlib.Mutex.protect t.mu (fun () ->
      let cur = t.active in
      t.active <- None;
      cur)

let stop t =
  match take_active t with
  | None -> None
  | Some proc ->
      reap_active_proc proc;
      Some proc.label

let is_playing t =
  Stdlib.Mutex.protect t.mu (fun () -> Option.is_some t.active)

let record_retained_temp t path =
  let evicted =
    Stdlib.Mutex.protect t.mu (fun () ->
        let deduped =
          path :: List.filter (fun p -> not (String.equal p path)) t.retained_temps
        in
        let rec split n acc = function
          | [] -> (List.rev acc, [])
          | rest when n <= 0 -> (List.rev acc, rest)
          | x :: xs -> split (n - 1) (x :: acc) xs
        in
        let kept, old = split max_retained_temps [] deduped in
        t.retained_temps <- kept;
        old)
  in
  List.iter remove_quietly evicted

let shutdown t =
  ignore (stop t : string option);
  let retained =
    Stdlib.Mutex.protect t.mu (fun () ->
        let paths = t.retained_temps in
        t.retained_temps <- [];
        paths)
  in
  List.iter remove_quietly retained

let spawn_quiet ~executable ~args =
  match Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0o600 with
  | exception Unix.Unix_error (err, fn, _) ->
      Error (Printf.sprintf "%s: %s" fn (Unix.error_message err))
  | devnull ->
      Fun.protect
        ~finally:(fun () -> close_quietly devnull)
        (fun () ->
          match
            Unix.create_process executable
              (Array.of_list (executable :: args))
              devnull devnull devnull
          with
          | pid -> Ok pid
          | exception Unix.Unix_error (err, fn, _) ->
              Error (Printf.sprintf "%s: %s" fn (Unix.error_message err)))

let start_reaper t ~pid ~temp_path ~reap_state =
  Thread.create
    (fun () ->
      let rec loop () =
        match Unix.waitpid [] pid with
        | _, _ -> ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
        | exception Unix.Unix_error _ -> ()
      in
      loop ();
      Stdlib.Mutex.protect reap_state.reap_mu (fun () ->
          reap_state.reaped <- true);
      Stdlib.Mutex.protect t.mu (fun () ->
          match t.active with
          | Some cur when cur.reap_state == reap_state -> t.active <- None
          | Some _ | None -> ());
      Option.iter remove_quietly temp_path)
    ()

let play_file t ?base_path ?resolve ?(temp_cleanup = false) ~mime_type ~label ~path () =
  let soundfont = find_soundfont ?base_path () in
  match plan_playback ?resolve ?soundfont ~mime_type ~path () with
  | Error msg ->
      if temp_cleanup then remove_quietly path;
      Error msg
  | Ok (Midi_handoff_alphatex midi_path) ->
      ignore (stop t : string option);
      Ok (Handoff_alphatex midi_path)
  | Ok (Video_open { executable; args }) -> (
      match spawn_quiet ~executable ~args with
      | Error msg ->
          if temp_cleanup then remove_quietly path;
          Error msg
      | Ok pid ->
          if temp_cleanup then record_retained_temp t path;
          (* Reap [open]/[xdg-open] launcher in background; temp file stays until [shutdown] or LRU eviction. *)
          ignore
            (Thread.create
               (fun () ->
                 let rec loop () =
                   match Unix.waitpid [] pid with
                   | _, _ -> ()
                   | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
                   | exception Unix.Unix_error _ -> ()
                 in
                 loop ())
               ()
              : Thread.t);
          Ok (Opened_external label))
  | Ok (Audio_spawn { executable; args } | Midi_fluidsynth { executable; args }) -> (
      Option.iter reap_active_proc (take_active t);
      let temp_path = if temp_cleanup then Some path else None in
      let spawned, displaced =
        Stdlib.Mutex.protect t.mu (fun () ->
            let prev = t.active in
            t.active <- None;
            match spawn_quiet ~executable ~args with
            | Error msg -> (Error msg, prev)
            | Ok pid ->
                let reap_state =
                  { reap_mu = Stdlib.Mutex.create (); reaped = false }
                in
                let reaper = start_reaper t ~pid ~temp_path ~reap_state in
                t.active <- Some { pid; label; reap_state; reaper };
                (Ok (), prev))
      in
      Option.iter reap_active_proc displaced;
      match spawned with
      | Error msg ->
          if temp_cleanup then remove_quietly path;
          Error msg
      | Ok () -> Ok (Playing label))
