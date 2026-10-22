open Alcotest

let fixture action =
  let root = Filename.temp_file "masc-music-launch-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let executable = Filename.concat root "masc-alphatex" in
  let receipt = Filename.concat root "arguments" in
  let old_path = Sys.getenv_opt "PATH" in
  Fun.protect ~finally:(fun () ->
    (match old_path with Some path -> Unix.putenv "PATH" path | None -> Unix.unsetenv "PATH");
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path) [executable; receipt];
    Unix.rmdir root)
    (fun () ->
      Unix.putenv "PATH" root;
      let script code =
        let output = open_out_bin executable in
        Fun.protect ~finally:(fun () -> close_out_noerr output) (fun () ->
          Printf.fprintf output "#!/bin/sh\nprintf '%%s\\000' \"$@\" > %s\nexit %d\n"
            (Filename.quote receipt) code);
        Unix.chmod executable 0o700 in
      action ~script ~receipt)

let read_arguments path =
  let input = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr input) (fun () ->
    really_input_string input (in_channel_length input)
    |> String.split_on_char '\000' |> List.filter (fun arg -> arg <> ""))

let test_requests () = fixture (fun ~script ~receipt ->
  List.iter (fun code ->
    script code;
    let restored = ref 0 and reentered = ref 0 in
    let project_root = "/a project/with spaces;$(unchanged)" and session_root = "/takes/한 곡" in
    let soundfont = Some "/sounds/a piano.sf2" in
    let result = Masc_tui_score.launch_music ~project_root ~session_root ~soundfont
      ~restore:(fun () -> incr restored) ~reenter:(fun () -> incr reentered) in
    check (list string) "exact child argv, without shell interpretation"
      ["--music"; "--project-root"; project_root; "--session-root"; session_root;
       "--soundfont"; "/sounds/a piano.sf2"] (read_arguments receipt);
    check int "terminal handed over once" 1 !restored;
    check int "terminal restored after child completion" 1 !reentered;
    check bool "exit status remains an outcome" (code = 0) (Result.is_ok result)
  ) [0; 7])

let test_midi_requests () = fixture (fun ~script ~receipt ->
  List.iter (fun code ->
    script code;
    let restored = ref 0 and reentered = ref 0 in
    let path = "/cache/한 곡;$(unchanged).mid" in
    let result = Masc_tui_score.launch_midi ~project_root:"/a project"
      ~session_root:"/owned takes" ~soundfont:(Some "/sound files/bass.sf2") ~path
      ~restore:(fun () -> incr restored) ~reenter:(fun () -> incr reentered) in
    check (list string) "frozen source and workspace directories are child arguments"
      ["--midi-file"; path; "--project-root"; "/a project";
       "--session-root"; "/owned takes"; "--soundfont"; "/sound files/bass.sf2"]
      (read_arguments receipt);
    check int "terminal handed over once" 1 !restored;
    check int "terminal restored after child" 1 !reentered;
    check bool "child failure is retained" (code = 0) (Result.is_ok result)
  ) [0; 7])

let test_missing_helper () = fixture (fun ~script:_ ~receipt:_ ->
  let touched = ref false in
  let result = Masc_tui_score.launch_music ~project_root:"/projects" ~session_root:"/takes"
    ~soundfont:None ~restore:(fun () -> touched := true) ~reenter:(fun () -> touched := true) in
  check bool "missing helper is an error" true (Result.is_error result);
  check bool "parent retains terminal without a child" false !touched)

let test_restore_failure () = fixture (fun ~script ~receipt ->
  script 0;
  let reentered = ref false in
  let result = Masc_tui_score.launch_music ~project_root:"/projects" ~session_root:"/takes"
    ~soundfont:None ~restore:(fun () -> raise (Sys_error "restore interrupted"))
    ~reenter:(fun () -> reentered := true) in
  check bool "partial handoff reenters terminal" true !reentered;
  check bool "failure is retained" true (Result.is_error result);
  check bool "no child started" false (Sys.file_exists receipt))

let test_command () =
  check bool "music is a local command" true (Masc_tui_command.parse "/music" = Masc_tui_command.Open_music);
  check bool "explicit chat MIDI is a local editing action" true
    (Masc_tui_command.parse "/music midi" = Masc_tui_command.Open_music_midi);
  List.iter (fun text -> check bool "extra input is refused" true
    (Masc_tui_command.parse text = Masc_tui_command.Music_invalid_arguments))
    ["/music song.json"; "/music\nretain this text"; "/music midi\nretain this text"; "/music midi other"]

let () = run "music terminal handoff"
  ["requests and ownership", [test_case "child argv and exit outcomes" `Quick test_requests;
    test_case "MIDI source and child ownership" `Quick test_midi_requests;
    test_case "missing helper retains parent ownership" `Quick test_missing_helper;
    test_case "partial handoff failure restores terminal" `Quick test_restore_failure;
    test_case "entry never becomes Keeper text" `Quick test_command]]
