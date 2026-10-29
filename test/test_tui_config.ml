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
   server reads, so [load ~base_path] must resolve to it. A missing file reads
   as no choice, not a crash. *)
let with_temp_base f =
  let base = Filename.temp_file "masc_tui_config_base" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  let masc = Filename.concat base ".masc" in
  let config = Filename.concat masc "config" in
  Unix.mkdir masc 0o755;
  Unix.mkdir config 0o755;
  (* A configured environment takes precedence over base_path. Never let a
     fixture's writes escape to the operator's actual config directory. *)
  let previous_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Unix.putenv "MASC_CONFIG_DIR" config;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "MASC_CONFIG_DIR" (Option.value previous_config_dir ~default:"");
      (try Sys.remove (Filename.concat config "runtime.toml") with _ -> ());
      (try Sys.remove (Filename.concat config "tui-keepers.toml") with _ -> ());
      (try Sys.remove (Filename.concat config "tui-keepers.toml.lock") with _ -> ());
      (try Unix.rmdir config with _ -> ());
      (try Unix.rmdir masc with _ -> ());
      try Unix.rmdir base with _ -> ())
    (fun () -> f ~base ~config)

let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let io_cases =
  [ Alcotest.test_case "all startup choices come from one retained snapshot" `Quick
      (fun () ->
        with_temp_base (fun ~base ~config ->
          let path = Filename.concat config "runtime.toml" in
          write path
            "[tui]\ntheme = \"monokai\"\nboard_sort = \"discussed\"\n\
             lift_colours = false\ntable_frame = true\nhints_visible = false\n\
             coalesce_queued_input = true\n\n\
             [voice.stt]\ndefault_model = \"scribe_v1\"\nsend_on_stop = false\n\n\
             [[voice.stt.endpoints]]\nid = \"eleven\"\nkind = \"elevenlabs_direct\"\n";
          let chosen = Config.load ~base_path:base in
          write path "[tui]\ntheme = \"nord\"\n";
          check_opt "retained theme" (Some "monokai") chosen.theme;
          check_opt "retained Board order" (Some "discussed") chosen.board_sort;
          Alcotest.(check (option bool)) "colours" (Some false) chosen.lift_colours;
          Alcotest.(check (option bool)) "frame" (Some true) chosen.table_frame;
          Alcotest.(check (option bool)) "hints" (Some false) chosen.hints_visible;
          Alcotest.(check (option bool)) "coalesce" (Some true) chosen.coalesce_queued_input;
          Alcotest.(check (option bool)) "voice consent" (Some false) chosen.send_on_stop;
          let next = Config.load ~base_path:base in
          check_opt "new read sees new theme" (Some "nord") next.theme;
          check_opt "new read sees removed order" None next.board_sort;
          Alcotest.(check (option bool)) "removed voice setting is absent" None next.send_on_stop))
  ; Alcotest.test_case "reads theme from the base's runtime.toml" `Quick
      (fun () ->
        with_temp_base (fun ~base ~config ->
            write (Filename.concat config "runtime.toml")
              "[tui]\ntheme = \"monokai\"\n";
            check_opt "monokai" (Some "monokai") (Config.load ~base_path:base).theme))
  ; Alcotest.test_case "a base with no runtime.toml reads as no choice" `Quick
      (fun () ->
        with_temp_base (fun ~base ~config:_ ->
            check_opt "none" None (Config.load ~base_path:base).theme))
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


(* The one-time door line's flag, [tui].help_hint_shown. Absence reads as
   "no" -- unlike hints_visible, whose default is the behaviour that predated
   the key: nobody has met the line until the flag says so, and a long-running
   operator meets it once too. *)
let help_hint_of s = Config.help_hint_shown_of_doc (doc_of s)
let check_help_hint = Alcotest.(check (option bool))

let help_hint_cases =
  [ Alcotest.test_case "reads [tui] help_hint_shown" `Quick (fun () ->
        check_help_hint "true" (Some true)
          (help_hint_of "[tui]\nhelp_hint_shown = true\n"))
  ; Alcotest.test_case "explicit false stays false" `Quick (fun () ->
        check_help_hint "false" (Some false)
          (help_hint_of "[tui]\nhelp_hint_shown = false\n"))
  ; Alcotest.test_case "absent key -> None (caller defaults to not shown)" `Quick
      (fun () -> check_help_hint "none" None (help_hint_of "[tui]\ntheme = \"x\"\n"))
  ]


(* Whether a queued line absorbs the next one, [tui].coalesce_queued_input.
   Absence leaves the caller's default (off) in place, and an explicit true
   opts into joining locally waiting lines. *)
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
  ; Alcotest.test_case "absent key -> None (caller keeps sends separate)" `Quick
      (fun () -> check_coalesce "none" None (coalesce_of "[tui]\ntheme = \"x\"\n"))
  ; Alcotest.test_case "wrong type -> None, not a crash" `Quick (fun () ->
        check_coalesce "string" None
          (coalesce_of "[tui]\ncoalesce_queued_input = \"yes\"\n"))
  ]

(* Whether ^Y also sends, [voice.stt].send_on_stop. Absence must read as None
   so the caller's default (off) stands: unlike its neighbours this one sends
   a message without the operator confirming it, and a file that never
   mentions it is not that operator asking for it.

   Read out of the [voice] section rather than a [tui] key. The setting used
   to have two spellings: this file read [tui].voice_send_on_stop, which no
   surface published, while [voice.stt].send_on_stop was parsed, published by
   GET /api/v1/voice/config and by the voice setup route, and read by nothing.
   An operator who set the documented one got silence. *)
let send_on_stop_of = Config.send_on_stop_of_text

(* A whole stt section, because that is what the parser needs: every
   transcriber is asked for a model by name, so a section naming none does not
   load and the key inside it is not reachable either. *)
let stt_section ?(extra = "") () =
  "[voice.stt]\ndefault_model = \"scribe_v1\"\n" ^ extra
  ^ "\n[[voice.stt.endpoints]]\nid = \"eleven\"\nkind = \"elevenlabs_direct\"\n"

let send_on_stop_cases =
  [ Alcotest.test_case "reads [voice.stt] send_on_stop" `Quick (fun () ->
        Alcotest.(check (option bool)) "true" (Some true)
          (send_on_stop_of (stt_section ~extra:"send_on_stop = true\n" ())))
  ; Alcotest.test_case "false stays false" `Quick (fun () ->
        Alcotest.(check (option bool)) "false" (Some false)
          (send_on_stop_of (stt_section ~extra:"send_on_stop = false\n" ())))
  (* A section that loads but never names the key reads as off, not as absent:
     [Voice_config] carries this one as a plain [bool] defaulting to false, so
     "not asked for" and "asked for off" are the same answer -- which they are,
     because both keep the draft. Only a missing or unloadable section is
     [None], and that too keeps the draft. *)
  ; Alcotest.test_case "a section that omits the key reads as off" `Quick
      (fun () ->
        Alcotest.(check (option bool)) "off" (Some false)
          (send_on_stop_of (stt_section ())))
  ; Alcotest.test_case "no [voice] section at all -> None" `Quick (fun () ->
        Alcotest.(check (option bool)) "none" None
          (send_on_stop_of "[tui]\ntheme = \"x\"\n"))
  (* A section the voice parser refuses reads as off rather than as the last
     value that happened to parse. The TUI is not where a broken voice config
     is reported -- the speak and transcribe paths name it -- and off is the
     direction that does not send a message nobody confirmed. *)
  ; Alcotest.test_case "wrong type -> None, not a crash" `Quick (fun () ->
        Alcotest.(check (option bool)) "string" None
          (send_on_stop_of (stt_section ~extra:"send_on_stop = \"yes\"\n" ())))
  ; Alcotest.test_case "a section that does not load -> None" `Quick (fun () ->
        Alcotest.(check (option bool)) "no model named" None
          (send_on_stop_of
             "[voice.stt]\nsend_on_stop = true\n\n\
              [[voice.stt.endpoints]]\nid = \"eleven\"\nkind = \"elevenlabs_direct\"\n"))
  (* The old spelling is not read any more. A file that still carries it gets
     the default, which is what makes this a cut rather than two settings. *)
  ; Alcotest.test_case "the old [tui] spelling is not read" `Quick (fun () ->
        Alcotest.(check (option bool)) "ignored" None
          (send_on_stop_of "[tui]\nvoice_send_on_stop = true\n"))
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
   and refuses it otherwise.

   [models.sample] is a model no capability catalog knows, which is the ordinary
   shape for an operator running their own openai-compatible server. Such a model
   carries its own [capabilities] table: with none, nothing knows what a request
   to it may express, and the runtime refuses the file rather than dispatch
   blind. The table's presence is what makes it declared -- every field inside
   has a default -- so this one names only what 1024 tokens of context implies. *)
let storable_runtime =
  "[providers.local]\n\
   protocol = \"openai-compatible-http\"\n\
   endpoint = \"http://127.0.0.1:1/v1\"\n\
   \n\
   [models.sample]\n\
   api-name = \"sample\"\n\
   max-context = 1024\n\
   \n\
   [models.sample.capabilities]\n\
   max-output-tokens = 1024\n\
   \n\
   [local.sample]\n\
   \n\
   [runtime]\n\
   default = \"local.sample\"\n"

let store_or_fail ~base_path theme =
  match Config.set_theme ~base_path theme with
  | Ok _ignored_legacy_keys -> ()
  | Error message -> Alcotest.failf "storing the theme failed: %s" message

(* A runtime.toml carrying keys a released masc once read (see #45985): the
   save must still land, and the receipt must name what was ignored -- on the
   durable path AND on the after-rename durability-unconfirmed path, because
   the file on disk changed in both. Regression guard for the P2 that found
   the after-rename receipt computing its list from an empty string. *)
let legacy_runtime =
  String.concat "\n"
    [ "[providers.local]"
    ; "protocol = \"openai-compatible-http\""
    ; "endpoint = \"http://127.0.0.1:1/v1\""
    ; ""
    ; "[models.sample]"
    ; "api-name = \"sample\""
    ; "max-context = 1024"
    ; "max-prompt-bytes = 32768"
    ; ""
    ; "[models.sample.capabilities]"
    ; "max-output-tokens = 1024"
    ; "supports-reasoning-budget = true"
    ; ""
    ; "[local.sample]"
    ; ""
    ; "[runtime]"
    ; "default = \"local.sample\"" ]

let receipt_case (label : string) ~(inject : bool) =
  Alcotest.test_case label `Quick (fun () ->
      with_temp_base (fun ~base ~config ->
          let path = Filename.concat config "runtime.toml" in
          write path legacy_runtime;
          Fun.protect
            ~finally:(fun () -> try Sys.remove (path ^ ".lock") with _ -> ())
            (fun () ->
              let edited =
                Config.text_with_theme legacy_runtime ~theme:(Some "ayu-dark")
              in
              let replace_file =
                if inject then
                  fun path content ->
                    (* the rename landed; the post-rename fsync did not *)
                    ignore (Fs_compat.save_file_atomic_strict_staged path content);
                    Error
                      { Fs_compat.path
                      ; stage = Fs_compat.After_rename
                      ; exception_ = Failure "injected: directory fsync failed"
                      ; backtrace = Printexc.get_callstack 0 }
                else Fs_compat.save_file_atomic_strict_staged
              in
              match
                Runtime.commit_config_text_locked ~replace_file
                  ~runtime_config_path:path edited
              with
              | Error (Runtime.Config_commit_refused detail) ->
                Alcotest.failf "commit refused: %s" detail
              | Error (Runtime.Config_commit_write_failed failure) ->
                Alcotest.failf "commit write failed: %s"
                  (Fs_compat.atomic_replace_failure_to_string failure)
              | Ok receipt ->
                let durability_tag =
                  match receipt.Runtime.durability with
                  | Runtime.Durable -> "durable"
                  | Runtime.Durability_unconfirmed _ -> "durability-unconfirmed"
                in
              Alcotest.(check string) "durability follows the injection"
                (if inject then "durability-unconfirmed" else "durable")
                durability_tag;
              Alcotest.(check (list string))
                "the receipt names both ignored legacy keys"
                [ "models.sample.capabilities.supports-reasoning-budget"
                ; "models.sample.max-prompt-bytes" ]
                (List.sort compare receipt.Runtime.ignored_legacy_keys);
              (* the file the operator would read changed in both worlds *)
              Alcotest.(check bool) "the edited text landed on disk" true
                (let on_disk = read_file path in
                 String.equal on_disk edited))))

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
              (Config.load ~base_path).theme))
  ; Alcotest.test_case "withdrawing is there on the next read too" `Quick
      (fun () ->
        with_storable_base (fun ~base_path ->
            store_or_fail ~base_path (Some "gruvbox-dark");
            store_or_fail ~base_path None;
            check_opt "none" None (Config.load ~base_path).theme))
  ]

(* The one-time flag's write: written once by the first input, it has to be
   there on the next start beside whatever else the table holds. *)
let help_hint_store_cases =
  [ Alcotest.test_case "a retired door line stays retired on the next read" `Quick
      (fun () ->
        with_storable_base (fun ~base_path ->
            store_or_fail ~base_path (Some "gruvbox-dark");
            (match Config.set_help_hint_shown ~base_path with
             | Ok () -> () | Error message -> Alcotest.fail message);
            let read = Config.load ~base_path in
            check_opt "theme kept" (Some "gruvbox-dark") read.theme;
            check_help_hint "flag stored" (Some true) read.help_hint_shown))
  ]

let board_sort_cases =
  [ Alcotest.test_case "last Board order survives a new read" `Quick (fun () ->
        with_storable_base (fun ~base_path ->
          (match Config.set_board_sort ~base_path "discussed" with
           | Ok () -> () | Error message -> Alcotest.fail message);
          check_opt "stored order" (Some "discussed") (Config.load ~base_path).board_sort;
          store_or_fail ~base_path (Some "gruvbox-dark");
          check_opt "theme update keeps order" (Some "discussed") (Config.load ~base_path).board_sort))
  ; Alcotest.test_case "the candle's style survives a new read beside the Board order" `Quick
      (fun () ->
        with_storable_base (fun ~base_path ->
          (match Config.set_board_sort ~base_path "discussed" with
           | Ok () -> () | Error message -> Alcotest.fail message);
          (match Config.set_candle ~base_path "dotted" with
           | Ok () -> () | Error message -> Alcotest.fail message);
          let read = Config.load ~base_path in
          check_opt "stored candle" (Some "dotted") read.candle;
          check_opt "the Board order is kept" (Some "discussed") read.board_sort;
          (match Config.set_candle ~base_path "painted" with
           | Ok () -> () | Error message -> Alcotest.fail message);
          check_opt "changed back" (Some "painted") (Config.load ~base_path).candle)) ]

let keeper_list_preferences_cases =
  [ Alcotest.test_case "list preferences survive a new read and independent edits" `Quick
      (fun () ->
        with_storable_base (fun ~base_path ->
          (match Config.set_keeper_list_sort ~base_path "oldest" with
           | Ok () -> () | Error message -> Alcotest.fail message);
          (match Config.set_keeper_list_layout ~base_path "grouped" with
           | Ok () -> () | Error message -> Alcotest.fail message);
          store_or_fail ~base_path (Some "gruvbox-dark");
          let read = Config.load ~base_path in
          check_opt "stored order" (Some "oldest") read.keeper_list_sort;
          check_opt "stored view" (Some "grouped") read.keeper_list_layout;
          (match Config.set_keeper_list_sort ~base_path "activity" with
           | Ok () -> () | Error message -> Alcotest.fail message);
          let read = Config.load ~base_path in
          check_opt "changed order" (Some "activity") read.keeper_list_sort;
          check_opt "view preserved" (Some "grouped") read.keeper_list_layout))
  ; Alcotest.test_case "first preference does not need runtime.toml" `Quick (fun () ->
        with_temp_base (fun ~base ~config:_ ->
          (match Config.set_keeper_list_sort ~base_path:base "name" with
           | Ok () -> () | Error message -> Alcotest.fail message);
          let read = Config.load ~base_path:base in
          check_opt "order stored" (Some "name") read.keeper_list_sort;
          check_opt "no read error" None read.keeper_list_error))
  ; Alcotest.test_case "a failed edit preserves the original preferences" `Quick (fun () ->
        with_temp_base (fun ~base ~config ->
          let path = Filename.concat config "tui-keepers.toml" in
          let original = "keepers = { sort = \"name\", layout = \"grouped\" }\n" in
          write path original;
          Alcotest.(check bool) "unsupported table shape is reported" true
            (Option.is_some (Config.load ~base_path:base).keeper_list_error);
          Alcotest.(check bool) "unsafe inline-table edit refused" true
            (Result.is_error (Config.set_keeper_list_sort ~base_path:base "recent"));
          Alcotest.(check string) "original bytes remain" original (read_file path)))
  ; Alcotest.test_case "wrong preference type is reported" `Quick (fun () ->
        with_temp_base (fun ~base ~config ->
          write (Filename.concat config "tui-keepers.toml")
            "[keepers]\nsort = 42\nlayout = \"grouped\"\n";
          let read = Config.load ~base_path:base in
          check_opt "invalid order is absent" None read.keeper_list_sort;
          check_opt "valid view is retained" (Some "grouped") read.keeper_list_layout;
          Alcotest.(check bool) "invalid order is reported" true (Option.is_some read.keeper_list_error)))
  ; Alcotest.test_case "a FIFO is refused without opening it" `Quick (fun () ->
        with_temp_base (fun ~base ~config ->
          Unix.mkfifo (Filename.concat config "tui-keepers.toml") 0o600;
          let read = Config.load ~base_path:base in
          Alcotest.(check bool) "special file is reported" true (Option.is_some read.keeper_list_error);
          Alcotest.(check bool) "special file is not replaced" true
            (Result.is_error (Config.set_keeper_list_sort ~base_path:base "name"))))
  ; Alcotest.test_case "symbolic links, including dangling links, are preserved" `Quick (fun () ->
        with_temp_base (fun ~base ~config ->
          let path = Filename.concat config "tui-keepers.toml" in
          let target = Filename.concat base "preferences-target.toml" in
          let original = "[keepers]\nsort = \"oldest\"\n" in
          Fun.protect ~finally:(fun () -> try Sys.remove target with _ -> ()) (fun () ->
            write target original;
            Unix.symlink target path;
            List.iter (fun target_exists ->
              if not target_exists then Sys.remove target;
              Alcotest.(check bool) "link is reported on read" true
                (Option.is_some (Config.load ~base_path:base).keeper_list_error);
              Alcotest.(check bool) "link write is refused" true
                (Result.is_error (Config.set_keeper_list_sort ~base_path:base "name"));
              Alcotest.(check bool) "link remains a link" true
                ((Unix.lstat path).Unix.st_kind = Unix.S_LNK);
              Alcotest.(check string) "link target remains unchanged" target (Unix.readlink path);
              if target_exists then Alcotest.(check string) "target bytes remain" original (read_file target)
            ) [true; false])))
  ; Alcotest.test_case "queued choices save in submission order" `Quick (fun () ->
        with_temp_base (fun ~base ~config:_ ->
          Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
            let writer = Config.create_keeper_preference_writer () in
            let registered = ref [] in
            let submit preference = Config.submit_keeper_preference writer
              ~on_request_id:(fun request_id -> registered := request_id :: !registered)
              ~sw:(Some sw) ~base_path:base preference in
            let first = submit (Config.Keeper_order "recent") in
            let second = submit (Config.Keeper_view "grouped") in
            let third = submit (Config.Keeper_order "oldest") in
            let submitted = [first; second; third] in
            Alcotest.(check (list int)) "registered IDs match returned IDs" submitted (List.rev !registered);
            Config.close_keeper_preference_writer writer;
            let results = ref [] in
            Config.drain_keeper_preferences writer ~can_take:(fun () -> true)
              ~apply:(fun result -> results := result :: !results);
            Alcotest.(check int) "every request settled" 3 (List.length !results);
            Alcotest.(check (list int)) "completion IDs follow submission order"
              submitted (List.rev_map (fun (result : Config.keeper_preference_completion) -> result.request_id) !results);
            Alcotest.(check bool) "every save succeeded" true
              (List.for_all (fun (result : Config.keeper_preference_completion) ->
                result.outcome = Config.Preference_saved) !results);
            let read = Config.load ~base_path:base in
            check_opt "latest order" (Some "oldest") read.keeper_list_sort;
            check_opt "view survives" (Some "grouped") read.keeper_list_layout))))
  ; Alcotest.test_case "an unstarted later choice keeps its submission identity" `Quick (fun () ->
        with_temp_base (fun ~base ~config:_ ->
          Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
            let writer = Config.create_keeper_preference_writer () in
            let registered = ref [] in
            let submit ~sw preference = Config.submit_keeper_preference writer
              ~on_request_id:(fun request_id -> registered := request_id :: !registered)
              ~sw ~base_path:base preference in
            let first = submit ~sw:(Some sw) (Config.Keeper_order "recent") in
            let second = submit ~sw:None (Config.Keeper_order "oldest") in
            Alcotest.(check (list int)) "registered IDs include the unstarted choice"
              [first; second] (List.rev !registered);
            Config.close_keeper_preference_writer writer;
            let results = ref [] in
            Config.drain_keeper_preferences writer ~can_take:(fun () -> true)
              ~apply:(fun result -> results := result :: !results);
            let results = List.rev !results in
            Alcotest.(check bool) "later request can finish before the earlier write" true
              (match results with
               | [{ request_id = later; outcome = Config.Preference_not_started _; _ };
                  { request_id = earlier; outcome = Config.Preference_saved; _ }] ->
                   later = second && earlier = first && earlier < later
               | _ -> false))))) ]

let opening_cases =
  let parsed text = Config.opening_of_doc (doc_of text) in
  let name = Keeper_id.Keeper_name.to_string in
  [ Alcotest.test_case "absent opening keeps Overview" `Quick (fun () ->
        match parsed "" with
        | Ok Config.Overview -> ()
        | _ -> Alcotest.fail "absent opening did not select Overview")
  ; Alcotest.test_case "overview ignores an unrelated Keeper name" `Quick (fun () ->
        match parsed "[tui]\nopening = \"overview\"\nopening_keeper = \"last\"\n" with
        | Ok Config.Overview -> ()
        | _ -> Alcotest.fail "overview did not stay Overview")
  ; Alcotest.test_case "last reads the saved Keeper name" `Quick (fun () ->
        match parsed "[tui]\nopening = \"last\"\nopening_keeper = \"last\"\n" with
        | Ok (Config.Last (Some keeper)) ->
            Alcotest.(check string) "legal Keeper named last" "last" (name keeper)
        | _ -> Alcotest.fail "last did not read its saved target")
  ; Alcotest.test_case "last without a saved target stays unresolved" `Quick (fun () ->
        match parsed "[tui]\nopening = \"last\"\n" with
        | Ok (Config.Last None) -> ()
        | _ -> Alcotest.fail "missing last target was not retained")
  ; Alcotest.test_case "keeper needs a name" `Quick (fun () ->
        match parsed "[tui]\nopening = \"keeper\"\n" with
        | Error _ -> ()
        | _ -> Alcotest.fail "keeper without a name was accepted")
  ; Alcotest.test_case "keeper parses a named target" `Quick (fun () ->
        match parsed "[tui]\nopening = \"keeper\"\nopening_keeper = \"harbor-lamp\"\n" with
        | Ok (Config.Keeper keeper) ->
            Alcotest.(check string) "target" "harbor-lamp" (name keeper)
        | _ -> Alcotest.fail "keeper target did not parse")
  ; Alcotest.test_case "last target survives ordered visits and shared settings edits" `Quick (fun () ->
        with_storable_base (fun ~base_path ->
          let path = Filename.concat base_path ".masc/config/runtime.toml" in
          write path (storable_runtime ^ "\n[tui]\nopening = \"last\"\n");
          let target =
            match Keeper_id.Keeper_name.of_string "alpha" with
            | Ok target -> target
            | Error reason -> Alcotest.fail reason
          in
          (match Config.record_chat_visit ~base_path target with
           | Ok (Runtime.Durable | Runtime.Durability_unconfirmed _) -> ()
           | Error reason -> Alcotest.fail reason);
          (match (Config.load ~base_path).opening with
           | Ok (Config.Last (Some saved)) ->
               Alcotest.(check string) "saved target" "alpha" (name saved)
           | _ -> Alcotest.fail "saved target was not read");
          (match (Config.load ~base_path).last_chat_keeper with
           | Ok (Some saved) ->
               Alcotest.(check string) "conversation receipt" "alpha" (name saved)
           | _ -> Alcotest.fail "conversation receipt was not read");
          check_opt "runtime default survives" (Some "local.sample")
            (Toml.toml_string_opt
               (doc_of (In_channel.with_open_bin path In_channel.input_all))
               "runtime.default");
          let module Visits = Masc_tui_chat_visit in
          let module State = Masc_tui_types in
          let previous_pool = Domain_pool_ref.get () in
          let previous_ready = Eio_guard.is_ready () in
          Fun.protect ~finally:(fun () ->
            (match previous_pool with
             | Some pool -> Domain_pool_ref.set pool
             | None -> Domain_pool_ref.clear_for_tests ());
            if not previous_ready then Eio_guard.disable ()) (fun () ->
            Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
              Eio_guard.enable ();
              Domain_pool_ref.set (Domain_pool.create ~sw ~domain_count:1
                  (Eio.Stdenv.domain_mgr env));
              let startup = Config.prepare_startup_read ~sw:(Some sw) ~base_path in
              let state = State.create_state ~workspace:"visits" ~local_base_path:base_path
                  ~port:0 ~refresh_interval:0. () in
              let initial_settings = Eio.Promise.await_exn startup.result in
              let beta = match Keeper_id.Keeper_name.of_string "beta" with
                | Ok keeper -> keeper | Error reason -> Alcotest.fail reason in
              let first = Visits.submit state.home_chat_writer ~sw:(Some sw) ~base_path target in
              let middle = Visits.submit state.home_chat_writer ~sw:(Some sw) ~base_path beta in
              (* Another editor changes startup mode and theme through the real
                 shared lock between this session's visit admissions. *)
              (match Runtime.edit_config_text ~runtime_config_path:path (fun content ->
                  let content = Config.text_with_theme content ~theme:(Some "gruvbox-dark") in
                  Toml_line_editor.edit_table_scalar content
                    ~path:Runtime_toml_namespace.(key Tui) ~key:"opening"
                    ~value:(Some "overview")) with
               | Ok _ -> () | Error reason -> Alcotest.fail reason);
              let latest = Visits.submit state.home_chat_writer ~sw:(Some sw) ~base_path target in
              state.home_chat_visit <- Some latest;
              state.home_last_chat <- State.Saving_chat target;
              Visits.close state.home_chat_writer;
              let expected = ref [first; middle; latest] in
              Visits.drain_completed state.home_chat_writer ~can_take:(fun () -> true)
                ~apply:(fun completion ->
                  (match !expected with
                   | request :: rest ->
                       Alcotest.(check bool) "original FIFO request" true
                         (Visits.same_request request completion.request);
                       expected := rest
                   | [] -> Alcotest.fail "an unowned completion was published");
                  Alcotest.(check string) "captured workspace" base_path completion.request.base_path;
                  (match completion.outcome with
                   | Visits.Saved (Runtime.Durable | Runtime.Durability_unconfirmed _) -> ()
                   | Refused reason | Unobserved reason | Not_started reason -> Alcotest.fail reason);
                  let current = Visits.same_request latest completion.request in
                  Alcotest.(check bool) "only the latest visit can settle Home" current
                    (State.accept_chat_visit state completion);
                  if not current then
                    match state.home_last_chat with
                    | State.Saving_chat keeper when Keeper_id.Keeper_name.equal keeper target -> ()
                    | _ -> Alcotest.fail "an older receipt replaced the pending latest visit");
              Alcotest.(check bool) "each admitted visit retains its outcome" true (!expected = []);
              (match state.home_last_chat with
               | State.Recorded_chat keeper | Unconfirmed_chat {keeper;_}
                   when Keeper_id.Keeper_name.equal keeper target -> ()
               | _ -> Alcotest.fail "latest visit did not settle with its durability");
              let read = Config.load ~base_path in
              (match read.opening with
               | Ok Config.Overview -> ()
               | _ -> Alcotest.fail "queued visit overwrote the other editor's startup mode");
              check_opt "other editor's theme survives" (Some "gruvbox-dark") read.theme;
              (* The original read remains its own immutable startup snapshot;
                 it cannot borrow the intervening writer's current settings. *)
              let original = Eio.Promise.await_exn startup.result in
              Alcotest.(check bool) "original startup snapshot retained" true
                (original == initial_settings);
              check_opt "original startup did not acquire the later theme" None
                original.settings.theme;
              (match original.settings.opening with
               | Ok (Config.Last (Some keeper)) when Keeper_id.Keeper_name.equal keeper target -> ()
               | Ok (Config.Overview | Last None | Last (Some _) | Keeper _)
               | Error _ -> Alcotest.fail "original startup acquired a later opening mode");
              (match read.last_chat_keeper with
               | Ok (Some keeper) when Keeper_id.Keeper_name.equal keeper target -> ()
               | _ -> Alcotest.fail "disk did not retain the last FIFO visit");
              (* Failure to launch must settle as session-only, without writing
                 inline or allowing a previous successful receipt to claim it. *)
              let unavailable = Visits.create () in
              let request = Visits.submit unavailable ~sw:None ~base_path beta in
              state.home_chat_visit <- Some request;
              state.home_last_chat <- State.Saving_chat beta;
              Visits.drain_completed unavailable ~can_take:(fun () -> true)
                ~apply:(fun completion ->
                  match completion.outcome with
                  | Visits.Not_started _ -> ignore (State.accept_chat_visit state completion)
                  | Saved _ | Refused _ | Unobserved _ -> Alcotest.fail "missing runtime started a write");
              Visits.close unavailable;
              (match state.home_last_chat, (Config.load ~base_path).last_chat_keeper with
               | State.Session_chat {keeper;_}, Ok (Some stored)
                   when Keeper_id.Keeper_name.equal keeper beta
                        && Keeper_id.Keeper_name.equal stored target -> ()
               | _ -> Alcotest.fail "launch refusal lost the distinction between session and disk")
            )))))
  ; Alcotest.test_case "unknown opening is an error" `Quick (fun () ->
        match parsed "[tui]\nopening = \"something-else\"\n" with
        | Error _ -> ()
        | _ -> Alcotest.fail "unknown opening was silently ignored")
  ]

let reduce_motion_cases =
  [ Alcotest.test_case "reduce motion starts at the final about frame" `Quick
      (fun () ->
        check_lift "enabled" (Some true)
          (Config.reduce_motion_of_doc (doc_of "[tui]\nreduce_motion = true\n"));
        check_lift "disabled" (Some false)
          (Config.reduce_motion_of_doc (doc_of "[tui]\nreduce_motion = false\n"));
        check_lift "absent" None
          (Config.reduce_motion_of_doc (doc_of "[tui]\ntheme = \"dusk\"\n")))
  ]

(* The input device captures open, [tui].audio_input_device. Same read shape
   as theme: absent is "no stored pick", and the same line editor that edits
   the theme writes this one, so the round trips are the same ones. *)
let device_of s = Config.audio_input_device_of_doc (doc_of s)
let check_device = Alcotest.(check (option string))

let device_cases =
  [ Alcotest.test_case "reads [tui] audio_input_device" `Quick (fun () ->
        check_device "macbook mic" (Some "macbook mic")
          (device_of "[tui]\naudio_input_device = \"macbook mic\"\n"))
  ; Alcotest.test_case "no [tui] table -> None" `Quick (fun () ->
        check_device "none" None (device_of "[turn]\nstream_idle_timeout_sec = 120\n"))
  ; Alcotest.test_case "[tui] present but no key -> None" `Quick (fun () ->
        check_device "none" None (device_of "[tui]\ntheme = \"nord\"\n"))
  ; Alcotest.test_case "empty file -> None" `Quick (fun () ->
        check_device "none" None (device_of ""))
  ; Alcotest.test_case "a blank value turns the pick off -> None" `Quick (fun () ->
        check_device "empty" None (device_of "[tui]\naudio_input_device = \"\"\n");
        check_device "spaces" None (device_of "[tui]\naudio_input_device = \"  \"\n"))
  ]

let device_write_cases =
  [ Alcotest.test_case "a first pick lands where the reader looks" `Quick (fun () ->
        check_device "macbook mic" (Some "macbook mic")
          (device_of (Config.text_with_audio_input_device unstored ~device:(Some "macbook mic"))))
  ; Alcotest.test_case "a second pick replaces the first" `Quick (fun () ->
        let twice =
          Config.text_with_audio_input_device
            (Config.text_with_audio_input_device unstored ~device:(Some "macbook mic"))
            ~device:(Some "usb interface")
        in
        check_device "usb interface" (Some "usb interface") (device_of twice);
        Alcotest.(check bool) "the earlier pick is gone" false
          (contains twice "macbook mic"))
  ; Alcotest.test_case "withdrawing removes the key" `Quick (fun () ->
        check_device "none" None
          (device_of
             (Config.text_with_audio_input_device
                (Config.text_with_audio_input_device unstored ~device:(Some "macbook mic"))
                ~device:None)))
  ; Alcotest.test_case "the rest of the file survives a write" `Quick (fun () ->
        let text = Config.text_with_audio_input_device unstored ~device:(Some "macbook mic") in
        Alcotest.(check bool) "the hand-written comment is still there" true
          (contains text "operators edit this file by hand");
        check_opt "another table still reads" (Some "local.sample")
          (Toml.toml_string_opt (doc_of text) "runtime.default"))
  ]

let device_store_cases =
  [ Alcotest.test_case "a stored pick is there on the next read" `Quick (fun () ->
        with_storable_base (fun ~base_path ->
            (match Config.set_audio_input_device ~base_path (Some "macbook mic") with
             | Ok () -> () | Error message -> Alcotest.failf "storing the device failed: %s" message);
            check_device "macbook mic" (Some "macbook mic")
              (Config.load ~base_path).audio_input_device))
  ; Alcotest.test_case "withdrawing is there on the next read too" `Quick (fun () ->
        with_storable_base (fun ~base_path ->
            (match Config.set_audio_input_device ~base_path (Some "macbook mic") with
             | Ok () -> () | Error message -> Alcotest.failf "storing the device failed: %s" message);
            (match Config.set_audio_input_device ~base_path None with
             | Ok () -> () | Error message -> Alcotest.failf "withdrawing failed: %s" message);
            check_device "none" None (Config.load ~base_path).audio_input_device))
  ; Alcotest.test_case "the theme pick survives the device write" `Quick (fun () ->
        with_storable_base (fun ~base_path ->
            store_or_fail ~base_path (Some "gruvbox-dark");
            (match Config.set_audio_input_device ~base_path (Some "macbook mic") with
             | Ok () -> () | Error message -> Alcotest.failf "storing the device failed: %s" message);
            let read = Config.load ~base_path in
            check_device "device stored" (Some "macbook mic") read.audio_input_device;
            check_opt "theme kept" (Some "gruvbox-dark") read.theme))
  ]

(* The UI display language, [tui].language. Stored as "ko" or "en"; the typed
   reading lives with the UI state, so this layer reads the raw spelling and
   lets the caller report an unknown one rather than forcing a default. *)
let language_of s = Config.language_of_doc (doc_of s)

let language_cases =
  [ Alcotest.test_case "reads [tui] language" `Quick (fun () ->
        check_opt "ko" (Some "ko")
          (language_of "[tui]\nlanguage = \"ko\"\n");
        check_opt "en" (Some "en")
          (language_of "[tui]\nlanguage = \"en\"\n"))
  ; Alcotest.test_case "no [tui] table -> None" `Quick (fun () ->
        check_opt "none" None
          (language_of "[turn]\nstream_idle_timeout_sec = 120\n"))
  ; Alcotest.test_case "[tui] present but no key -> None" `Quick (fun () ->
        check_opt "none" None (language_of "[tui]\ntheme = \"nord\"\n"))
  ; Alcotest.test_case "empty file -> None" `Quick (fun () ->
        check_opt "none" None (language_of ""))
  ; Alcotest.test_case "an unknown spelling reads through for the caller to report" `Quick
      (fun () ->
        check_opt "ja" (Some "ja")
          (language_of "[tui]\nlanguage = \"ja\"\n"))
  ; Alcotest.test_case "wrong type -> None, not a crash" `Quick (fun () ->
        check_opt "bool" None
          (language_of "[tui]\nlanguage = true\n"))
  ]

let language_write_cases =
  [ Alcotest.test_case "a first pick lands where the reader looks" `Quick
      (fun () ->
        check_opt "en" (Some "en")
          (language_of (Config.text_with_language unstored ~language:"en")))
  ; Alcotest.test_case "a second pick replaces the first" `Quick (fun () ->
        let twice =
          Config.text_with_language
            (Config.text_with_language unstored ~language:"ko")
            ~language:"en"
        in
        check_opt "en" (Some "en") (language_of twice);
        Alcotest.(check bool) "the earlier pick is gone" false
          (contains twice "language = \"ko\""))
  ; Alcotest.test_case "the rest of the file survives a write" `Quick (fun () ->
        let text = Config.text_with_language unstored ~language:"en" in
        Alcotest.(check bool) "the hand-written comment is still there" true
          (contains text "operators edit this file by hand");
        check_opt "another table still reads" (Some "local.sample")
          (Toml.toml_string_opt (doc_of text) "runtime.default"))
  ]

let language_store_cases =
  [ Alcotest.test_case "a stored pick is there on the next read" `Quick
      (fun () ->
        with_storable_base (fun ~base_path ->
            (match Config.set_language ~base_path "en" with
             | Ok () -> ()
             | Error message -> Alcotest.failf "storing the language failed: %s" message);
            check_opt "en" (Some "en") (Config.load ~base_path).language))
  ; Alcotest.test_case "a changed pick replaces the stored one" `Quick (fun () ->
        with_storable_base (fun ~base_path ->
            (match Config.set_language ~base_path "ko" with
             | Ok () -> ()
             | Error message -> Alcotest.failf "storing the language failed: %s" message);
            (match Config.set_language ~base_path "en" with
             | Ok () -> ()
             | Error message -> Alcotest.failf "storing the language failed: %s" message);
            check_opt "en" (Some "en") (Config.load ~base_path).language))
  ; Alcotest.test_case "the theme pick survives the language write" `Quick
      (fun () ->
        with_storable_base (fun ~base_path ->
            store_or_fail ~base_path (Some "gruvbox-dark");
            (match Config.set_language ~base_path "en" with
             | Ok () -> ()
             | Error message -> Alcotest.failf "storing the language failed: %s" message);
            let read = Config.load ~base_path in
            check_opt "language stored" (Some "en") read.language;
            check_opt "theme kept" (Some "gruvbox-dark") read.theme))
  ]

(* The stored spelling's typed reading. Unknown values stay unknown so the
   caller can say the stored value back instead of silently keeping a
   default the operator did not ask for. *)
let language_mapping_cases =
  let module State = Masc_tui_types in
  let check_lang = Alcotest.(check (option (testable
    (fun ppf -> function
       | State.Lang_ko -> Format.pp_print_string ppf "ko"
       | State.Lang_en -> Format.pp_print_string ppf "en")
    ( = )))) in
  [ Alcotest.test_case "ko and en read as themselves" `Quick (fun () ->
        check_lang "ko" (Some State.Lang_ko) (State.ui_language_of_string "ko");
        check_lang "en" (Some State.Lang_en) (State.ui_language_of_string "en"))
  ; Alcotest.test_case "unknown reads as unknown, not a default" `Quick (fun () ->
        check_lang "ja" None (State.ui_language_of_string "ja");
        check_lang "empty" None (State.ui_language_of_string ""))
  ; Alcotest.test_case "the stored spellings round-trip" `Quick (fun () ->
        Alcotest.(check string) "ko" "ko"
          (State.ui_language_to_string State.Lang_ko);
        Alcotest.(check string) "en" "en"
          (State.ui_language_to_string State.Lang_en);
        check_lang "ko round-trips" (Some State.Lang_ko)
          (State.ui_language_of_string
             (State.ui_language_to_string State.Lang_ko));
        check_lang "en round-trips" (Some State.Lang_en)
          (State.ui_language_of_string
             (State.ui_language_to_string State.Lang_en)))
  ]

let () =
  Alcotest.run "tui_config"
    [ ("board_sort", board_sort_cases)
    ; ("keeper_list_preferences", keeper_list_preferences_cases)
    ; ("opening", opening_cases)
    ; ("theme_of_doc", cases)
    ; ("audio_input_device_of_doc", device_cases)
    ; ("text_with_audio_input_device", device_write_cases)
    ; ("set_audio_input_device", device_store_cases)
    ; ("table_frame_of_doc", frame_cases)
    ; ("lift_colours", lift_cases)
    ; ("reduce_motion", reduce_motion_cases)
    ; ("hints_visible_of_doc", hints_cases)
    ; ("help_hint_shown_of_doc", help_hint_cases)
    ; ("set_help_hint_shown", help_hint_store_cases)
    ; ("coalesce_queued_input", coalesce_cases)
    ; ("send_on_stop", send_on_stop_cases)
    ; ("theme_io", io_cases)
    ; ("text_with_theme", write_cases)
    ; ("set_theme", store_cases)
    ; ("language_of_doc", language_cases)
    ; ("text_with_language", language_write_cases)
    ; ("set_language", language_store_cases)
    ; ("ui_language_mapping", language_mapping_cases)
    ; ( "commit receipt carries the ignored legacy keys"
      , [ receipt_case "durable save names ignored legacy keys" ~inject:false
        ; receipt_case
            "after-rename unconfirmed save still names ignored legacy keys"
            ~inject:true ] )
    ]
