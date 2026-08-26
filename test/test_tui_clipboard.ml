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

(* An operator who pressed Ctrl-V needs to know which of the three it was:
   nothing installed, nothing on the clipboard, or a reader that broke. *)
let test_errors_name_what_to_do () =
  Alcotest.check Alcotest.string "no reader names what was looked for"
    "no clipboard reader found (looked for osascript, wl-paste, xclip)"
    (Masc_tui_clipboard.error_to_string
       (Masc_tui_clipboard.No_reader { tried = [ "osascript"; "wl-paste"; "xclip" ] }));
  Alcotest.check Alcotest.string "an empty clipboard is a plain answer"
    "the clipboard holds no image (osascript)"
    (Masc_tui_clipboard.error_to_string
       (Masc_tui_clipboard.No_image { reader = "osascript" }));
  Alcotest.check Alcotest.string "a broken reader says what broke"
    "xclip could not read the clipboard image: the reader wrote no bytes"
    (Masc_tui_clipboard.error_to_string
       (Masc_tui_clipboard.Unreadable
          { reader = "xclip"; detail = "the reader wrote no bytes" }))
;;

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
    ; ("errors", [ Alcotest.test_case "name what to do" `Quick test_errors_name_what_to_do ])
    ]
;;
