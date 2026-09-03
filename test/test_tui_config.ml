(* The TUI reads its own keys out of the [tui] table of runtime.toml. The file
   read and path resolution are the server's shared machinery; what is worth
   pinning is that a [tui].theme is picked up and that every absence -- no
   table, no key, empty file -- reads as "no stored choice" so the caller falls
   back to following the terminal. *)

module Config = Masc_tui_config
module Toml = Keeper_toml_loader

let doc_of s =
  match Toml.parse_toml s with
  | Ok d -> d
  | Error e -> Alcotest.failf "runtime.toml fixture did not parse: %s" e

let theme_of s = Config.theme_of_doc (doc_of s)
let check_opt = Alcotest.(check (option string))

let cases =
  [ Alcotest.test_case "reads [tui] theme" `Quick (fun () ->
        check_opt "monokai" (Some "monokai")
          (theme_of "[tui]\ntheme = \"monokai\"\n"))
  ; Alcotest.test_case "a different theme name reads through" `Quick (fun () ->
        check_opt "solarized" (Some "solarized-dark")
          (theme_of "[tui]\ntheme = \"solarized-dark\"\n"))
  ; Alcotest.test_case "no [tui] table -> None" `Quick (fun () ->
        check_opt "none" None
          (theme_of "[turn]\nstream_idle_timeout_sec = 120\n"))
  ; Alcotest.test_case "[tui] present but no theme -> None" `Quick (fun () ->
        check_opt "none" None (theme_of "[tui]\nsomething_else = 1\n"))
  ; Alcotest.test_case "empty file -> None" `Quick (fun () ->
        check_opt "none" None (theme_of ""))
  ]

(* Whether masc lifts colours a scheme leaves under the readable floor,
   [tui].lift_colours. Absence reads as on, which is what masc drew before the
   key existed -- a reader who never set it must see no change.

   Off has to read through as off rather than as absent, because off is a
   choice: it is what every other terminal UI does, and what a reader on a
   high-contrast scheme is asking for. *)
let lift_of s = Config.lift_colours_of_doc (doc_of s)
let check_lift = Alcotest.(check (option bool))

let lift_cases =
  [ Alcotest.test_case "reads [tui] lift_colours" `Quick (fun () ->
        check_lift "true" (Some true)
          (lift_of "[tui]\nlift_colours = true\n"))
  ; Alcotest.test_case "off reads through as off, not as absent" `Quick
      (fun () ->
        check_lift "false" (Some false)
          (lift_of "[tui]\nlift_colours = false\n"))
  ; Alcotest.test_case "absent stays absent" `Quick (fun () ->
        check_lift "none" None (lift_of "[tui]\ntheme = \"nord\"\n"))
  ]

(* The box a table draws, [tui].table_frame. Absence has to read as "no" the
   same way an absent theme reads as "follow the terminal": the frame is paid
   for out of the columns, and a reader who never asked for it should not lose
   a cell of content to it. *)
let frame_of s = Config.table_frame_of_doc (doc_of s)
let check_frame = Alcotest.(check (option bool))

let frame_cases =
  [ Alcotest.test_case "reads [tui] table_frame" `Quick (fun () ->
        check_frame "true" (Some true)
          (frame_of "[tui]\ntable_frame = true\n"))
  ; Alcotest.test_case "off reads through as off, not as absent" `Quick
      (fun () ->
        check_frame "false" (Some false)
          (frame_of "[tui]\ntable_frame = false\n"))
  ; Alcotest.test_case "no [tui] table -> None" `Quick (fun () ->
        check_frame "none" None
          (frame_of "[turn]\nstream_idle_timeout_sec = 120\n"))
  ; Alcotest.test_case "[tui] present but no key -> None" `Quick (fun () ->
        check_frame "none" None (frame_of "[tui]\ntheme = \"monokai\"\n"))
  ; (* One table, two keys, neither reading the other's. *)
    Alcotest.test_case "the theme and the frame do not shadow each other"
      `Quick (fun () ->
        let doc = "[tui]\ntheme = \"monokai\"\ntable_frame = true\n" in
        check_opt "theme" (Some "monokai") (theme_of doc);
        check_frame "frame" (Some true) (frame_of doc))
  ]

(* The IO path: a runtime.toml under [base]/.masc/config is the same file the
   server reads, so [theme ~base_path] must resolve to it. A missing file reads
   as no choice, not a crash. *)
let with_temp_base f =
  let base = Filename.temp_file "masc_tui_config_base" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  let masc = Filename.concat base ".masc" in
  let config = Filename.concat masc "config" in
  Unix.mkdir masc 0o755;
  Unix.mkdir config 0o755;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove (Filename.concat config "runtime.toml") with _ -> ());
      (try Unix.rmdir config with _ -> ());
      (try Unix.rmdir masc with _ -> ());
      try Unix.rmdir base with _ -> ())
    (fun () -> f ~base ~config)

let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let io_cases =
  [ Alcotest.test_case "reads theme from the base's runtime.toml" `Quick
      (fun () ->
        with_temp_base (fun ~base ~config ->
            write (Filename.concat config "runtime.toml")
              "[tui]\ntheme = \"monokai\"\n";
            check_opt "monokai" (Some "monokai") (Config.theme ~base_path:base)))
  ; Alcotest.test_case "a base with no runtime.toml reads as no choice" `Quick
      (fun () ->
        with_temp_base (fun ~base ~config:_ ->
            check_opt "none" None (Config.theme ~base_path:base)))
  ]

(* Whether footers spell their hints, [tui].hints_visible. Absence must read
   as "yes": the hints predate the key, and a reader who never set it sees
   no change. *)
let hints_of s = Config.hints_visible_of_doc (doc_of s)
let check_hints = Alcotest.(check (option bool))

let hints_cases =
  [ Alcotest.test_case "reads [tui] hints_visible" `Quick (fun () ->
        check_hints "false" (Some false)
          (hints_of "[tui]\nhints_visible = false\n"))
  ; Alcotest.test_case "on reads through as on" `Quick (fun () ->
        check_hints "true" (Some true)
          (hints_of "[tui]\nhints_visible = true\n"))
  ; Alcotest.test_case "absent key -> None (renderer defaults to on)" `Quick
      (fun () -> check_hints "none" None (hints_of "[tui]\ntheme = \"x\"\n"))
  ]


(* Whether a queued line absorbs the next one, [tui].coalesce_queued_input.
   Absence must read as "yes" so a reader who never touched the key gets the
   joining behaviour, and an explicit false must survive as false. *)
let coalesce_of s = Config.coalesce_queued_input_of_doc (doc_of s)

let check_coalesce label expected actual =
  Alcotest.(check (option bool)) label expected actual

let coalesce_cases =
  [ Alcotest.test_case "reads [tui] coalesce_queued_input" `Quick (fun () ->
        check_coalesce "false" (Some false)
          (coalesce_of "[tui]\ncoalesce_queued_input = false\n"))
  ; Alcotest.test_case "true stays true" `Quick (fun () ->
        check_coalesce "true" (Some true)
          (coalesce_of "[tui]\ncoalesce_queued_input = true\n"))
  ; Alcotest.test_case "absent key -> None (caller joins by default)" `Quick
      (fun () -> check_coalesce "none" None (coalesce_of "[tui]\ntheme = \"x\"\n"))
  ; Alcotest.test_case "wrong type -> None, not a crash" `Quick (fun () ->
        check_coalesce "string" None
          (coalesce_of "[tui]\ncoalesce_queued_input = \"yes\"\n"))
  ]

let () =
  Alcotest.run "tui_config"
    [ ("theme_of_doc", cases)
    ; ("table_frame_of_doc", frame_cases)
    ; ( "lift_colours", lift_cases )
    ; ("hints_visible_of_doc", hints_cases)
    ; ("coalesce_queued_input", coalesce_cases)
    ; ("theme_io", io_cases)
    ]
