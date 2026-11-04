(* The clipboard readers' commands, checked where they fail silently.

   A command whose destination path escaped wrong does not crash: the reader
   writes somewhere else or refuses, the file this process opens is empty, and
   Ctrl-V answers "the clipboard holds no image" for a clipboard that has one.
   That is indistinguishable from an empty clipboard at the call site, so the
   quoting is asserted here instead. *)

let check_contains ~command ~needle ~what =
  let found =
    let needle_length = String.length needle in
    let limit = String.length command - needle_length in
    let rec scan index =
      if index > limit
      then false
      else if String.equal (String.sub command index needle_length) needle
      then true
      else scan (index + 1)
    in
    needle_length > 0 && scan 0
  in
  Alcotest.check Alcotest.bool
    (Printf.sprintf "%s: %s in %s" what needle command)
    true found
;;

let ends_with ~suffix text =
  let suffix_length = String.length suffix in
  String.length text >= suffix_length
  && String.equal (String.sub text (String.length text - suffix_length) suffix_length) suffix
;;

let reader_named name =
  match
    List.find_opt
      (fun reader -> String.equal (Masc_tui_clipboard.reader_name reader) name)
      Masc_tui_clipboard.readers
  with
  | Some reader -> reader
  | None -> Alcotest.failf "no clipboard reader named %s" name
;;

(* Order is the contract: the macOS reader is part of the system and cannot be
   the wrong one for the session, while both Linux readers can be installed
   with only one of them able to see the running desktop's clipboard. *)
let test_reader_order () =
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "readers, in the order they are tried"
    [ "osascript"; "wl-paste"; "xclip" ]
    (List.map Masc_tui_clipboard.reader_name Masc_tui_clipboard.readers)
;;

(* A path is one argument. Without quoting, a temp directory with a space in it
   splits into two and the reader writes to a file nothing reads. *)
let test_redirect_paths_are_quoted () =
  List.iter
    (fun name ->
      let command =
        Masc_tui_clipboard.reader_command (reader_named name) ~dest:"/tmp/two words.img"
      in
      check_contains ~command ~needle:(Filename.quote "/tmp/two words.img")
        ~what:(name ^ " quotes its destination"))
    [ "wl-paste"; "xclip" ]
;;

(* AppleScript's own string syntax, inside the shell's. A quote in the path
   would otherwise end the AppleScript string early and the script would fail
   to parse -- reported as an ordinary "no image". *)
let test_applescript_escapes_quotes () =
  let command =
    Masc_tui_clipboard.reader_command (reader_named "osascript")
      ~dest:"/tmp/say \"hi\".img"
  in
  check_contains ~command ~needle:"/tmp/say \\\"hi\\\".img"
    ~what:"osascript escapes a quote in the path";
  (* The backslash is an escape in AppleScript too, so it doubles. *)
  let command =
    Masc_tui_clipboard.reader_command (reader_named "osascript") ~dest:"/tmp/back\\slash.img"
  in
  check_contains ~command ~needle:"/tmp/back\\\\slash.img"
    ~what:"osascript escapes a backslash in the path"
;;

(* The temp file already exists with a length. Writing without truncating
   leaves the previous image's tail behind a shorter one. *)
let test_applescript_truncates_before_writing () =
  let command =
    Masc_tui_clipboard.reader_command (reader_named "osascript") ~dest:"/tmp/clip.img"
  in
  check_contains ~command ~needle:"set eof of f to 0"
    ~what:"osascript truncates the destination"
;;

(* This terminal is a frame being drawn. ColorSync writes to stderr while
   converting some clipboard images, and a line that lands between two frames
   leaves the screen no longer what the frame presenter believes it wrote. *)
let test_every_reader_silences_stderr () =
  List.iter
    (fun reader ->
      let command = Masc_tui_clipboard.reader_command reader ~dest:"/tmp/clip.img" in
      Alcotest.check Alcotest.bool
        (Printf.sprintf "%s keeps stderr off the terminal: %s"
           (Masc_tui_clipboard.reader_name reader)
           command)
        true
        (ends_with ~suffix:"2>/dev/null" command))
    Masc_tui_clipboard.readers
;;

(* Over SSH a tool on this host fills this host's clipboard, so the copy goes
   to the terminal whatever is installed. *)
let test_a_remote_session_copies_through_the_terminal () =
  let env pairs name = List.assoc_opt name pairs in
  let session = Masc_tui_clipboard.copy_session in
  Alcotest.(check bool) "no SSH variables is local" true
    (session (env []) = Masc_tui_clipboard.Local);
  Alcotest.(check bool) "SSH_CONNECTION is remote" true
    (session (env [ "SSH_CONNECTION", "10.0.0.1 51000 10.0.0.2 22" ])
     = Masc_tui_clipboard.Remote);
  Alcotest.(check bool) "SSH_TTY is remote" true
    (session (env [ "SSH_TTY", "/dev/ttys004" ]) = Masc_tui_clipboard.Remote);
  Alcotest.(check bool) "a remote session never runs a tool" true
    (Masc_tui_clipboard.copy_route Masc_tui_clipboard.Remote ~installed:(fun _ -> true)
     = Masc_tui_clipboard.Terminal_only)

(* Locally the installed tools are tried in their order, and with none
   installed the terminal is the only way out. *)
let test_a_local_session_tries_the_installed_tools_first () =
  let names = function
    | Masc_tui_clipboard.Through_tools tools ->
        List.map Masc_tui_clipboard.writer_name tools
    | Masc_tui_clipboard.Terminal_only -> []
  in
  let route installed =
    Masc_tui_clipboard.copy_route Masc_tui_clipboard.Local
      ~installed:(fun name -> List.mem name installed)
  in
  Alcotest.(check (list string)) "every installed tool, in order"
    [ "pbcopy"; "wl-copy"; "xclip" ]
    (names (route [ "xclip"; "wl-copy"; "pbcopy" ]));
  Alcotest.(check (list string)) "only the installed ones" [ "xclip" ]
    (names (route [ "xclip" ]));
  Alcotest.(check bool) "nothing installed goes to the terminal" true
    (route [] = Masc_tui_clipboard.Terminal_only)

(* When no tool runs, the text still leaves through the terminal, and the
   outcome says so. *)
let test_a_copy_without_a_tool_is_sent_to_the_terminal () =
  let sent = ref None in
  let outcome =
    Masc_tui_clipboard.copy_text Masc_tui_clipboard.Remote
      ~write_osc52:(fun text -> sent := Some text) "copied text"
  in
  Alcotest.(check (option string)) "the text went to the terminal" (Some "copied text") !sent;
  Alcotest.(check bool) "and the outcome says so" true
    (outcome = Masc_tui_clipboard.Sent_to_terminal { failed = [] })

(* Fake tools on a private PATH stand in for the desktop ones, so the real
   clipboard is never touched. Each fake writes what it reads to its own file
   and exits with the given status. *)
let with_fake_tools tools f =
  let dir = Filename.temp_dir "masc-tui-copy-tools" "" in
  let received name = Filename.concat dir (name ^ ".received") in
  List.iter
    (fun (name, status) ->
      let script = Filename.concat dir name in
      Out_channel.with_open_bin script (fun channel ->
        Printf.fprintf channel "#!/bin/sh\n/bin/cat > %s\nexit %d\n"
          (Filename.quote (received name)) status);
      Unix.chmod script 0o755)
    tools;
  let saved_path = Sys.getenv_opt "PATH" in
  Unix.putenv "PATH" dir;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" (Option.value saved_path ~default:"");
      Array.iter (fun entry -> Sys.remove (Filename.concat dir entry)) (Sys.readdir dir);
      Sys.rmdir dir)
    (fun () ->
      f (fun name ->
        match In_channel.with_open_bin (received name) In_channel.input_all with
        | text -> Some text
        | exception Sys_error _ -> None))

let multiline_text = "first line\n'quoted' \"twice\" $HOME `tick`\n한글 줄\n"

let not_sent_to_terminal _ = Alcotest.fail "the terminal got a copy a tool already took"

(* The first tool that exits 0 holds the text byte for byte, and the terminal
   is left alone. *)
let test_a_local_copy_reaches_the_first_tool_intact () =
  with_fake_tools [ "pbcopy", 0; "wl-copy", 0 ] (fun received ->
    let outcome =
      Masc_tui_clipboard.copy_text Masc_tui_clipboard.Local
        ~write_osc52:not_sent_to_terminal multiline_text
    in
    Alcotest.(check bool) "pbcopy took it" true
      (outcome = Masc_tui_clipboard.Copied_by "pbcopy");
    Alcotest.(check (option string)) "byte for byte" (Some multiline_text)
      (received "pbcopy");
    Alcotest.(check (option string)) "the next tool never ran" None (received "wl-copy"))

(* A tool that exits non-zero is passed over for the next one. *)
let test_a_failed_tool_hands_the_copy_to_the_next () =
  with_fake_tools [ "pbcopy", 1; "wl-copy", 0 ] (fun received ->
    let outcome =
      Masc_tui_clipboard.copy_text Masc_tui_clipboard.Local
        ~write_osc52:not_sent_to_terminal multiline_text
    in
    Alcotest.(check bool) "wl-copy took it" true
      (outcome = Masc_tui_clipboard.Copied_by "wl-copy");
    Alcotest.(check (option string)) "wl-copy holds the text" (Some multiline_text)
      (received "wl-copy"))

(* When every installed tool fails, the terminal gets the text and the
   outcome names the tools that failed, in the order they were tried. *)
let test_every_failed_tool_is_named_before_the_terminal_copy () =
  with_fake_tools [ "pbcopy", 1; "xclip", 2 ] (fun _received ->
    let sent = ref None in
    let outcome =
      Masc_tui_clipboard.copy_text Masc_tui_clipboard.Local
        ~write_osc52:(fun text -> sent := Some text) multiline_text
    in
    Alcotest.(check (option string)) "the terminal got the text" (Some multiline_text) !sent;
    Alcotest.(check bool) "both failures named in order" true
      (outcome = Masc_tui_clipboard.Sent_to_terminal { failed = [ "pbcopy"; "xclip" ] }))

let () =
  Alcotest.run "tui clipboard"
    [ ( "readers"
      , [ Alcotest.test_case "order" `Quick test_reader_order
        ; Alcotest.test_case "redirect paths are quoted" `Quick
            test_redirect_paths_are_quoted
        ; Alcotest.test_case "applescript escapes quotes" `Quick
            test_applescript_escapes_quotes
        ; Alcotest.test_case "applescript truncates" `Quick
            test_applescript_truncates_before_writing
        ; Alcotest.test_case "stderr stays off the terminal" `Quick
            test_every_reader_silences_stderr
        ] )
    ; ("errors", [])
    ; ( "copy"
      , [ Alcotest.test_case "remote session goes through the terminal" `Quick
            test_a_remote_session_copies_through_the_terminal
        ; Alcotest.test_case "local session tries installed tools first" `Quick
            test_a_local_session_tries_the_installed_tools_first
        ; Alcotest.test_case "no tool sends to the terminal" `Quick
            test_a_copy_without_a_tool_is_sent_to_the_terminal
        ; Alcotest.test_case "first tool gets the text intact" `Quick
            test_a_local_copy_reaches_the_first_tool_intact
        ; Alcotest.test_case "failed tool hands over to the next" `Quick
            test_a_failed_tool_hands_the_copy_to_the_next
        ; Alcotest.test_case "failed tools are named before the terminal copy" `Quick
            test_every_failed_tool_is_named_before_the_terminal_copy
        ] )
    ]
;;
