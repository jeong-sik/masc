(* What opening a board attachment does: save it, play it, or hand it to
   the local default app. The pure decisions are tested; [run] takes the
   fetch from its caller, so the network stays outside this library. *)

type action =
  | Play_local
  | Play_midi
  | Open_external
  | Save_only

let action_of : Masc_tui_types.board_attachment_kind -> action = function
  | Ak_audio -> Play_local
  | Ak_midi -> Play_midi
  | Ak_image | Ak_video | Ak_youtube | Ak_external_link -> Open_external
  | Ak_file | Ak_score | Ak_unknown _ -> Save_only

let safe_external_extensions =
  [
    ".png";
    ".jpg";
    ".jpeg";
    ".gif";
    ".webp";
    ".bmp";
    ".svg";
    ".mp4";
    ".mov";
    ".webm";
    ".mkv";
    ".m4v";
    ".pdf";
    ".txt";
    ".md";
  ]

let allows_external_open ~name =
  let ext =
    Filename.basename name
    |> Filename.extension
    |> String.lowercase_ascii
  in
  not (String.equal ext "") && List.mem ext safe_external_extensions

(* {1 Where an artifact lands} *)

let cache_dirname = "masc_attachments"

let cache_dir () =
  let dir = Filename.concat (Filename.get_temp_dir_name ()) cache_dirname in
  if not (Sys.file_exists dir) then
    (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let target_path ~name ~sha256 =
  let base =
    match name with
    | Some name when not (String.equal name "") -> Filename.basename name
    | Some _ | None -> "attachment"
  in
  Filename.concat (Filename.concat (cache_dir ()) sha256) base

(* {1 Players} *)

let split_path value =
  String.split_on_char ':' value
  |> List.filter (fun entry -> not (String.equal (String.trim entry) ""))

let find_executable_in_path ?path_value executable =
  let path_value =
    Option.value path_value ~default:(Sys.getenv_opt "PATH" |> Option.value ~default:"")
  in
  split_path path_value
  |> List.map (fun dir -> Filename.concat dir executable)
  |> List.find_opt (fun path -> Sys.file_exists path && not (Sys.is_directory path))

let player_commands =
  [
    ("afplay", []);
    ("ffplay", [ "-nodisp"; "-autoexit"; "-loglevel"; "error" ]);
    ("mpg123", [ "-q" ]);
    ("play", [ "-q" ]);
  ]

let player_argvs ?path_value ~path () =
  player_commands
  |> List.filter_map (fun (executable, args) ->
    match find_executable_in_path ?path_value executable with
    | Some found -> Some (found :: args @ [ path ])
    | None -> None)

let midi_argv ?path_value ~path ~soundfont () =
  match find_executable_in_path ?path_value "fluidsynth" with
  | None -> Error "no fluidsynth executable found"
  | Some executable -> (
      match soundfont with
      | None -> Error "no MIDI soundfont configured ([tui] midi_soundfont)"
      | Some soundfont when not (Sys.file_exists soundfont) ->
          Error (Printf.sprintf "the MIDI soundfont %S does not exist" soundfont)
      | Some soundfont -> Ok [ executable; "-i"; soundfont; path ])

(* {1 One playback at a time} *)

let current_player : int option ref = ref None

let devnull = lazy (Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0)

let stop_current () =
  match !current_player with
  | None -> ()
  | Some pid ->
      current_player := None;
      (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
      (try ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ())

let spawn argv =
  match argv with
  | [] -> Error "nothing to run"
  | prog :: _ ->
      stop_current ();
      let null = Lazy.force devnull in
      (match Unix.create_process prog (Array.of_list argv) null null null with
       | pid ->
           current_player := Some pid;
           Ok ()
       | exception Unix.Unix_error (_, name, _) ->
           Error (Printf.sprintf "could not start %s" name))

(* {1 The outcome one line is built from} *)

type result_kind =
  | Played
  | Opened
  | Saved of string  (** 저장 경로; 외부 앱 열기가 안 될 때도 파일은 남는다 *)
  | Failed of string

type outcome = {
  name : string;
  result : result_kind;
  midi_summary : string option;
}

let describe_outcome { name; result; midi_summary } =
  let base =
    match result with
    | Played -> "playing " ^ name
    | Opened -> "opened " ^ name
    | Saved path -> Printf.sprintf "saved %s · %s" name path
    | Failed reason -> Printf.sprintf "failed %s · %s" name reason
  in
  match midi_summary with
  | Some summary -> base ^ " · " ^ summary
  | None -> base

(* {1 Effects} *)

let digest_display_bytes = 12

let display_name ~(sha256 : string) = function
  | Some name when not (String.equal name "") -> name
  | Some _ | None ->
      if String.length sha256 > digest_display_bytes
      then String_util.utf8_prefix ~max_bytes:digest_display_bytes sha256 ^ "…"
      else sha256

let open_external ~name ~path =
  if not (allows_external_open ~name) then
    { name; result = Saved path; midi_summary = None }
  else
    match Masc_tui_browser.open_url path with
    | Ok _ -> { name; result = Opened; midi_summary = None }
    | Error _ -> { name; result = Saved path; midi_summary = None }

type prepared =
  | Prepared_url of string
  | Prepared_file of {
      name : string;
      path : string;
      action : action;
      midi_summary : string option;
    }

let prepare ~fetch (attachment : Masc_tui_types.board_attachment) =
  match attachment.ba_source with
  | Masc_tui_types.As_url url -> Ok (Prepared_url url)
  | Masc_tui_types.As_artifact { sha256; _ } ->
      let name = display_name ~sha256 attachment.ba_name in
      let failed reason = Error { name; result = Failed reason; midi_summary = None } in
      match fetch ~sha256 with
      | Error reason -> failed reason
      | Ok bytes when String.length bytes > Tool_blob_store.max_served_bytes ->
          failed (Printf.sprintf "attachment exceeds %d-byte artifact limit"
            Tool_blob_store.max_served_bytes)
      | Ok bytes ->
          let path = target_path ~name:(Some name) ~sha256 in
          let published =
            try
              Fs_compat.mkdir_p (Filename.dirname path);
              Fs_compat.save_file_atomic_rename_only path bytes
            with
            | Sys_error detail -> Error detail
            | Unix.Unix_error (code, _, _) -> Error (Unix.error_message code) in
          match published with
          | Error reason -> failed reason
          | Ok () ->
              let action = action_of attachment.ba_kind in
              let midi_summary = match action with
                | Play_midi ->
                    (match Masc_tui_midi.read bytes with
                     | Ok info -> Some (Masc_tui_midi.summary info)
                     | Error _ -> None)
                | Play_local | Open_external | Save_only -> None in
              Ok (Prepared_file { name; path; action; midi_summary })

let perform prepared ~midi_soundfont =
  match prepared with
  | Prepared_url url ->
      (match Masc_tui_browser.open_url url with
       | Ok _ -> { name = url; result = Opened; midi_summary = None }
       | Error reason -> { name = url; result = Failed reason; midi_summary = None })
  | Prepared_file { name; path; action; midi_summary } ->
      match action with
      | Save_only -> { name; result = Saved path; midi_summary }
      | Open_external -> open_external ~name ~path
      | Play_local ->
          (match player_argvs ~path () with
           | [] ->
               { name; result = Failed "no afplay/ffplay/mpg123/play executable found";
                 midi_summary }
           | candidates ->
               let rec try_spawn = function
                 | [] -> { name; result = Failed "every player failed to start"; midi_summary }
                 | argv :: rest ->
                     (match spawn argv with
                      | Ok () -> { name; result = Played; midi_summary }
                      | Error _ -> try_spawn rest) in
               try_spawn candidates)
      | Play_midi ->
          (match midi_argv ~path ~soundfont:midi_soundfont () with
           | Ok argv ->
               (match spawn argv with
                | Ok () -> { name; result = Played; midi_summary }
                | Error reason -> { name; result = Failed reason; midi_summary })
           | Error _ -> { name; result = Saved path; midi_summary })

let run ~fetch attachment ~midi_soundfont =
  match prepare ~fetch attachment with
  | Error outcome -> outcome
  | Ok prepared -> perform prepared ~midi_soundfont
