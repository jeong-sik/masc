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

(* The write side of [tui].theme. It is the only key here that changes while
   masc runs -- the rest are read once at boot -- and the writer spells it in
   the line editor's table-and-key form while [theme_of_doc] above reads the
   loader's dotted form. The two grammars are not the same, so nothing can be
   shared between them; these round trips are what keep them from drifting
   apart. *)
let written text ~theme = Config.text_with_theme text ~theme

let contains haystack needle =
  let n = String.length needle in
  let rec scan i =
    if i + n > String.length haystack then false
    else if String.equal (String.sub haystack i n) needle then true
    else scan (i + 1)
  in
  n = 0 || scan 0

(* The live runtime.toml carries no [tui] table, so the missing-table case is
   the one every first pick takes. The comment and the other table are in the
   fixture because the server writes its own tables of this same file: a
   writer that reformatted rather than edited one line would take an
   operator's comments, and could take their routing with them. *)
let unstored =
  "# operators edit this file by hand\n\
   [runtime]\n\
   default = \"local.sample\"\n"

let write_cases =
  [ Alcotest.test_case "a first pick lands where the reader looks" `Quick
      (fun () ->
        check_opt "gruvbox-dark" (Some "gruvbox-dark")
          (theme_of (written unstored ~theme:(Some "gruvbox-dark"))))
  ; Alcotest.test_case "a second pick replaces the first" `Quick (fun () ->
        let twice =
          written
            (written unstored ~theme:(Some "gruvbox-dark"))
            ~theme:(Some "solarized-light")
        in
        check_opt "solarized-light" (Some "solarized-light") (theme_of twice);
        (* Appending instead of replacing would leave two rows and let TOML
           duplicate-key handling pick which one the reader gets. *)
        Alcotest.(check bool) "the earlier pick is gone" false
          (contains twice "gruvbox-dark"))
  ; Alcotest.test_case "withdrawing removes the key" `Quick (fun () ->
        check_opt "none" None
          (theme_of
             (written
                (written unstored ~theme:(Some "gruvbox-dark"))
                ~theme:None)))
  ; Alcotest.test_case "withdrawing without a stored pick is harmless" `Quick
      (fun () -> check_opt "none" None (theme_of (written unstored ~theme:None)))
  ; Alcotest.test_case "the rest of the file survives a write" `Quick (fun () ->
        let text = written unstored ~theme:(Some "gruvbox-dark") in
        Alcotest.(check bool) "the hand-written comment is still there" true
          (contains text "operators edit this file by hand");
        check_opt "another table still reads" (Some "local.sample")
          (Toml.toml_string_opt (doc_of text) "runtime.default"))
  ]

(* End to end, through the same two calls the TUI makes: the theme pane stores
   the pick, and the next start reads it back. A [tui] table is not something
   the runtime schema models, so this also answers whether writing one leaves
   a runtime.toml the server still loads -- the write validates the whole file
   and refuses it otherwise. *)
let storable_runtime =
  "[providers.local]\n\
   protocol = \"openai-compatible-http\"\n\
   endpoint = \"http://127.0.0.1:1/v1\"\n\
   \n\
   [models.sample]\n\
   api-name = \"sample\"\n\
   max-context = 1024\n\
   \n\
   [local.sample]\n\
   max-request-body-bytes = 65536\n\
   \n\
   [runtime]\n\
   default = \"local.sample\"\n"

let store_or_fail ~base_path theme =
  match Config.set_theme ~base_path theme with
  | Ok () -> ()
  | Error message -> Alcotest.failf "storing the theme failed: %s" message

(* Runtime's config write lock leaves a runtime.toml.lock beside the file it
   guards. Removing it here is what lets the shared temp-base cleanup finish
   its rmdir instead of leaving a directory behind on every run. *)
let with_storable_base f =
  with_temp_base (fun ~base ~config ->
      let path = Filename.concat config "runtime.toml" in
      write path storable_runtime;
      Fun.protect
        ~finally:(fun () -> try Sys.remove (path ^ ".lock") with _ -> ())
        (fun () -> f ~base_path:base))

let store_cases =
  [ Alcotest.test_case "a stored pick is there on the next read" `Quick
      (fun () ->
        with_storable_base (fun ~base_path ->
            store_or_fail ~base_path (Some "gruvbox-dark");
            check_opt "gruvbox-dark" (Some "gruvbox-dark")
              (Config.theme ~base_path)))
  ; Alcotest.test_case "withdrawing is there on the next read too" `Quick
      (fun () ->
        with_storable_base (fun ~base_path ->
            store_or_fail ~base_path (Some "gruvbox-dark");
            store_or_fail ~base_path None;
            check_opt "none" None (Config.theme ~base_path)))
  ]

let () =
  Alcotest.run "tui_config"
    [ ("theme_of_doc", cases)
    ; ("table_frame_of_doc", frame_cases)
    ; ( "lift_colours", lift_cases )
    ; ("hints_visible_of_doc", hints_cases)
    ; ("coalesce_queued_input", coalesce_cases)
    ; ("theme_io", io_cases)
    ; ("text_with_theme", write_cases)
    ; ("set_theme", store_cases)
    ]
