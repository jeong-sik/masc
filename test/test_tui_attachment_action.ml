(* Attachment decisions and the actual save boundary. Fetch is injected;
   the save case owns its temporary cache and starts no external process. *)

module Action = Masc_tui_attachment_action

let action_testable =
  Alcotest.testable
    (fun ppf action ->
       Format.pp_print_string ppf
         (match action with
          | Action.Play_local -> "play_local"
          | Action.Play_midi -> "play_midi"
          | Action.Open_external -> "open_external"
          | Action.Save_only -> "save_only"))
    ( = )

let check_action label kind expected =
  Alcotest.(check action_testable) label expected (Action.action_of kind)

let test_action_of_maps_all_kinds () =
  let open Masc_tui_types in
  check_action "audio plays locally" Ak_audio Action.Play_local;
  check_action "midi plays through the synth" Ak_midi Action.Play_midi;
  List.iter
    (fun kind -> check_action "media and links open externally" kind
        Action.Open_external)
    [ Ak_image; Ak_video; Ak_youtube; Ak_external_link ];
  List.iter
    (fun kind -> check_action "files, scores, and unknowns save only" kind
        Action.Save_only)
    [ Ak_file; Ak_score; Ak_unknown "stem" ]

let test_allows_external_open_blocks_executable_extensions () =
  Alcotest.(check bool) "png image allowed" true
    (Action.allows_external_open ~name:"cover.PNG");
  Alcotest.(check bool) "mp4 video allowed" true
    (Action.allows_external_open ~name:"clip.mp4");
  Alcotest.(check bool) ".terminal blocked" false
    (Action.allows_external_open ~name:"run.terminal");
  Alcotest.(check bool) ".jar blocked" false
    (Action.allows_external_open ~name:"payload.jar");
  Alcotest.(check bool) ".pkg blocked" false
    (Action.allows_external_open ~name:"installer.pkg");
  Alcotest.(check bool) ".dmg blocked" false
    (Action.allows_external_open ~name:"image.dmg");
  Alcotest.(check bool) ".webloc blocked" false
    (Action.allows_external_open ~name:"link.webloc");
  Alcotest.(check bool) ".workflow blocked" false
    (Action.allows_external_open ~name:"auto.workflow");
  Alcotest.(check bool) "extensionless blocked" false
    (Action.allows_external_open ~name:"attachment")

let test_target_path_uses_full_digest_and_basename () =
  let path =
    Action.target_path ~name:(Some "riff.gp5")
      ~sha256:"0123456789abcdef0123456789abcdef"
  in
  Alcotest.(check bool) "it lives in the cache dir" true
    (String.starts_with ~prefix:(Action.cache_dir () ^ "/") path);
  Alcotest.(check string) "the source directory carries the full digest"
    "0123456789abcdef0123456789abcdef" (Filename.basename (Filename.dirname path));
  Alcotest.(check string) "the original filename remains intact" "riff.gp5"
    (Filename.basename path);
  let other = Action.target_path ~name:(Some "riff.gp5")
      ~sha256:"0123456789abcdef0123456789abcdeff" in
  Alcotest.(check bool) "shared digest prefix cannot replace another prepared source"
    false (String.equal path other);
  let unnamed =
    Action.target_path ~name:None
      ~sha256:"0123456789abcdef0123456789abcdef"
  in
  Alcotest.(check string) "no name falls back to a word" "attachment"
    (Filename.basename unnamed);
  let separated = Action.target_path ~name:(Some "a/b.mid") ~sha256:"ffffffff" in
  Alcotest.(check string) "a separator keeps only the basename" "b.mid"
    (Filename.basename separated)

(* A PATH with nothing in it picks no player; a PATH with one fake executable
   picks it. *)
let mkdtemp prefix =
  let rec attempt () =
    let name =
      Printf.sprintf "%s%d-%d" prefix (Unix.getpid ())
        (Random.int 1_000_000)
    in
    let dir = Filename.concat (Filename.get_temp_dir_name ()) name in
    match Unix.mkdir dir 0o700 with
    | () -> dir
    | exception Unix.Unix_error (Unix.EEXIST, _, _) -> attempt ()
  in
  attempt ()

let with_fake_path executables f =
  let dir = mkdtemp "masc_attach_test" in
  List.iter
    (fun name ->
       let path = Filename.concat dir name in
       let channel = open_out_bin path in
       output_string channel "#!/bin/sh\n";
       close_out channel;
       Unix.chmod path 0o755)
    executables;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun name -> Sys.remove (Filename.concat dir name))
        executables;
      Unix.rmdir dir)
    (fun () -> f (Some dir))

let test_player_argvs_empty_without_path () =
  Alcotest.(check (list (list string))) "no player in an empty path" []
    (Action.player_argvs ~path_value:"/nonexistent" ~path:"/tmp/x.mp3" ())

let test_player_argvs_picks_the_available_one () =
  with_fake_path [ "mpg123" ] (fun path_value ->
      match Action.player_argvs ?path_value ~path:"/tmp/x.mp3" () with
      | [ argv ] ->
          Alcotest.(check string) "the fake mpg123 runs" "/tmp/x.mp3"
            (List.nth argv (List.length argv - 1));
          Alcotest.(check bool) "quiet flag rides along" true
            (List.mem "-q" argv)
      | other ->
          Alcotest.failf "expected one candidate, got %d" (List.length other))

let test_midi_argv_needs_fluidsynth_and_soundfont () =
  (match
     Action.midi_argv ~path_value:"/nonexistent" ~path:"/tmp/x.mid"
       ~soundfont:(Some "/tmp/x.sf2") ()
   with
   | Ok _ -> Alcotest.fail "fluidsynth out of PATH cannot run"
   | Error reason ->
       Alcotest.(check bool) "says what is missing" true
         (String.contains reason 'f'));
  with_fake_path [ "fluidsynth" ] (fun path_value ->
      (match
         Action.midi_argv ?path_value ~path:"/tmp/x.mid" ~soundfont:None ()
       with
       | Ok _ -> Alcotest.fail "no soundfont cannot run"
       | Error reason ->
           Alcotest.(check bool) "points at the setting" true
             (String.contains reason 's'));
      let missing = Filename.concat (Filename.get_temp_dir_name ()) "no-such.sf2" in
      (match
         Action.midi_argv ?path_value ~path:"/tmp/x.mid"
           ~soundfont:(Some missing) ()
       with
       | Ok _ -> Alcotest.fail "a missing soundfont cannot run"
       | Error _ -> ());
      let soundfont = Filename.concat (Filename.get_temp_dir_name ()) "masc-test.sf2" in
      let channel = open_out_bin soundfont in
      close_out channel;
      Fun.protect
        ~finally:(fun () -> Sys.remove soundfont)
        (fun () ->
           match
             Action.midi_argv ?path_value ~path:"/tmp/x.mid"
               ~soundfont:(Some soundfont) ()
           with
           | Ok argv ->
               Alcotest.(check string) "the file rides last" "/tmp/x.mid"
                 (List.nth argv (List.length argv - 1));
               Alcotest.(check bool) "non-interactive" true
                 (List.mem "-i" argv)
           | Error reason -> Alcotest.fail reason))

let test_describe_outcome () =
  let open Action in
  let outcome result = { name = "riff.gp5"; result; midi_summary = None } in
  Alcotest.(check string) "played" "playing riff.gp5"
    (describe_outcome (outcome Played));
  Alcotest.(check string) "opened" "opened riff.gp5"
    (describe_outcome (outcome Opened));
  Alcotest.(check string) "saved carries the path" "saved riff.gp5 · /tmp/riff.gp5"
    (describe_outcome (outcome (Saved "/tmp/riff.gp5")));
  Alcotest.(check string) "failed carries the reason"
    "failed riff.gp5 · nope"
    (describe_outcome (outcome (Failed "nope")));
  Alcotest.(check string) "the midi summary rides along"
    "playing take1.mid · 2 tracks · 96 BPM"
    (describe_outcome
       { name = "take1.mid"; result = Played; midi_summary = Some "2 tracks · 96 BPM" })

let test_save_served_artifact_boundary () =
  let root = mkdtemp "masc_attachment_save_" in
  let previous = Filename.get_temp_dir_name () in
  Fun.protect
    ~finally:(fun () ->
      Filename.set_temp_dir_name previous;
      let rec remove path =
        match Unix.lstat path with
        | {Unix.st_kind=Unix.S_DIR;_} ->
            Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
            Unix.rmdir path
        | {Unix.st_kind=(Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK
            | Unix.S_FIFO | Unix.S_SOCK);_} -> Unix.unlink path in
      remove root)
    (fun () ->
      Filename.set_temp_dir_name root;
      let limit = Tool_blob_store.max_served_bytes in
      let bytes = String.init limit (fun index -> Char.chr (index land 0xff)) in
      let sha256 = Digestif.SHA256.(digest_string bytes |> to_hex) in
      let attachment name ~sha256 size : Masc_tui_types.board_attachment =
        { ba_kind = Ak_file
        ; ba_name = Some name
        ; ba_source = As_artifact { sha256; bytes = size }
        }
      in
      let requested = ref [] in
      let fetch ~sha256 = requested := sha256 :: !requested; Ok bytes in
      let outcome = Action.run ~fetch (attachment "boundary.bin" ~sha256 limit)
          ~midi_soundfont:None in
      (match outcome.result with
       | Saved path ->
           Alcotest.(check int) "the complete served artifact was written"
             limit (Unix.stat path).st_size;
           let saved = In_channel.with_open_bin path In_channel.input_all in
           Alcotest.(check string) "saved binary bytes retain their exact digest"
             sha256 Digestif.SHA256.(digest_string saved |> to_hex)
       | Failed reason -> Alcotest.fail reason
       | Played | Opened -> Alcotest.fail "a file attachment started a process");
      Alcotest.(check (list string)) "fetch uses the original reference once"
        [sha256] !requested;
      let oversized = bytes ^ "\000" in
      let oversized_sha256 = Digestif.SHA256.(digest_string oversized |> to_hex) in
      let refused = attachment "oversized.bin" ~sha256:oversized_sha256
          (String.length oversized) in
      let target = Action.target_path ~name:refused.ba_name ~sha256:oversized_sha256 in
      let outcome = Action.run ~fetch:(fun ~sha256:_ -> Ok oversized) refused
          ~midi_soundfont:None in
      (match outcome.result with
       | Failed _ -> ()
       | Saved _ | Played | Opened -> Alcotest.fail "an oversized artifact was accepted");
      Alcotest.(check bool) "an oversized body never creates a saved file"
        false (Sys.file_exists target))

let test_retired_writer_cannot_damage_prepared_audio () =
  let nonce = Filename.temp_file "tui-listen-publication" "" in
  let bytes = "complete prepared audio " ^ nonce in
  let sha256 = Digestif.SHA256.(digest_string bytes |> to_hex) in
  let path = Action.target_path ~name:(Some "take.wav") ~sha256 in
  let attachment : Masc_tui_types.board_attachment =
    {ba_kind=Ak_audio; ba_name=Some "take.wav";
     ba_source=As_artifact {sha256; bytes=String.length bytes}} in
  let prepare () =
    match Action.prepare ~fetch:(fun ~sha256:_ -> Ok bytes) attachment with
    | Ok _ -> ()
    | Error outcome -> Alcotest.fail (Action.describe_outcome outcome) in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then Sys.remove path;
      if Sys.file_exists (Filename.dirname path) then Unix.rmdir (Filename.dirname path);
      Sys.remove nonce)
    (fun () ->
      prepare ();
      let retired_writer = Unix.openfile path [Unix.O_WRONLY] 0 in
      Fun.protect ~finally:(fun () -> Unix.close retired_writer) (fun () ->
        prepare ();
        In_channel.with_open_bin path (fun player ->
          (* A writer already holding the previous publication resumes only
             after its successor has prepared and the player opened it. *)
          Unix.ftruncate retired_writer 0;
          ignore (Unix.write_substring retired_writer "partial" 0 7);
          Alcotest.(check string) "retired writer cannot truncate the player source"
            bytes (In_channel.input_all player));
        Alcotest.(check string) "the published prepared source stays complete"
          bytes (In_channel.with_open_bin path In_channel.input_all)))

let listen_state () =
  let state = Masc_tui_types.create_state ~workspace:"test" ~port:8935
    ~refresh_interval:2. () in
  state.view <- Keepers Keeper_message;
  Masc_tui_types.retarget_message state (Some "music");
  state

let audio : Masc_tui_chat_media.playable =
  {name="take.wav"; kind=`Audio; source=`Data "UklGRg=="}

let test_listen_replacement_and_replay () =
  let open Masc_tui_types in
  let state = listen_state () in
  let first = begin_chat_listen state ~keeper:"music" audio in
  let second = begin_chat_listen state ~keeper:"music" audio in
  Alcotest.(check bool) "earlier read cannot authorize playback" false
    (take_chat_listen state first);
  Alcotest.(check bool) "earlier result keeps the successor pending" true
    (take_chat_listen state second);
  Alcotest.(check bool) "same completion cannot play twice" false
    (take_chat_listen state second)

let test_midi_editor_request_ownership () =
  let open Masc_tui_types in
  let state = listen_state () in
  let midi = {audio with Masc_tui_chat_media.kind=`Midi; name="phrase.mid"} in
  let editor = begin_chat_listen ~destination:Listen_music_editor state ~keeper:"music" midi in
  let player = begin_chat_listen state ~keeper:"music" audio in
  Alcotest.(check bool) "request freezes its editor intent" true
    (editor.lr_destination=Listen_music_editor && editor.lr_media=midi);
  Alcotest.(check bool) "new playback retires a prepared editor" false
    (take_chat_listen state editor);
  Alcotest.(check bool) "replacement retains player intent" true
    (player.lr_destination=Listen_player && take_chat_listen state player);
  let editor = begin_chat_listen ~destination:Listen_music_editor state ~keeper:"music" midi in
  ignore (withdraw_chat_music_editor state);
  Alcotest.(check bool) "new gesture retires editor focus" false
    (take_chat_listen state editor);
  let player = begin_chat_listen state ~keeper:"music" audio in
  ignore (withdraw_chat_music_editor state);
  Alcotest.(check bool) "ordinary playback survives newer input" true
    (take_chat_listen state player);
  let editor = begin_chat_listen ~destination:Listen_music_editor state ~keeper:"music" midi in
  Alcotest.(check bool) "explicit editor opens while its terminal is still owned" true
    (take_chat_listen state editor);
  let editor = begin_chat_listen ~destination:Listen_music_editor state ~keeper:"music" midi in
  suspend_workspace_readings state;
  Alcotest.(check bool) "retired workspace cannot open its MIDI editor" false
    (take_chat_listen state editor)

let test_listen_target_and_workspace_withdrawal () =
  let open Masc_tui_types in
  let state = listen_state () in
  let first = begin_chat_listen state ~keeper:"music" audio in
  retarget_message state (Some "other");
  retarget_message state (Some "music");
  Alcotest.(check bool) "A to B to A does not restore playback authority" false
    (take_chat_listen state first);
  let second = begin_chat_listen state ~keeper:"music" audio in
  suspend_workspace_readings state;
  Alcotest.(check bool) "reconnection retires pending audio" false
    (take_chat_listen state second);
  let third = begin_chat_listen state ~keeper:"music" audio in
  retarget_message state (Some "music");
  Alcotest.(check bool) "same target preserves the active request" true
    (take_chat_listen state third)

let test_listen_surface_withdrawal () =
  let open Masc_tui_types in
  let state = listen_state () in
  let request = begin_chat_listen state ~keeper:"music" audio in
  state.view <- Overview;
  reconcile_chat_listen state;
  state.view <- Keepers Keeper_message;
  Alcotest.(check bool) "returning to chat does not revive the withdrawn read" false
    (take_chat_listen state request)

let () =
  Alcotest.run "tui-attachment-action"
    [ ( "decisions"
      , [ Alcotest.test_case "the kind maps to an action" `Quick
            test_action_of_maps_all_kinds
        ; Alcotest.test_case "external open allowlists safe extensions" `Quick
            test_allows_external_open_blocks_executable_extensions
        ; Alcotest.test_case "the cache path names digest and file" `Quick
            test_target_path_uses_full_digest_and_basename
        ; Alcotest.test_case "no player in an empty path" `Quick
            test_player_argvs_empty_without_path
        ; Alcotest.test_case "the available player is picked" `Quick
            test_player_argvs_picks_the_available_one
        ; Alcotest.test_case "midi needs fluidsynth and a soundfont" `Quick
            test_midi_argv_needs_fluidsynth_and_soundfont
        ; Alcotest.test_case "the outcome is one line" `Quick
            test_describe_outcome
        ] )
    ; ( "listen ownership"
      , [ Alcotest.test_case "replacement and duplicate completion" `Quick
            test_listen_replacement_and_replay
        ; Alcotest.test_case "MIDI editor intent and retirement" `Quick
            test_midi_editor_request_ownership
        ; Alcotest.test_case "target and workspace withdrawal" `Quick
            test_listen_target_and_workspace_withdrawal
        ; Alcotest.test_case "surface withdrawal" `Quick
            test_listen_surface_withdrawal ] )
    ; ( "save"
      , [ Alcotest.test_case "retired writer cannot damage prepared audio" `Quick
            test_retired_writer_cannot_damage_prepared_audio
        ; Alcotest.test_case "saving uses the authoritative served-byte boundary"
            `Quick test_save_served_artifact_boundary ] )
    ]
