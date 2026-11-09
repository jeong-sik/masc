(* What a terminal reader starts with (RFC-0482 §3.1): the [tui] settings the
   server answers, the Keeper list preferences of this terminal's
   [tui-keepers.toml], and the picks it sends back to the server one at a time
   in the order they were made. The settings themselves are read and written
   by Masc.Tui_preference, tested in test_tui_preference. *)

module Config = Masc_tui_config
module Writer = Masc_tui_preference_writer
module P = Masc.Tui_preference

let check_opt = Alcotest.(check (option string))

(* The IO path: tui-keepers.toml sits beside the runtime.toml under
   [base]/.masc/config that the server reads. A missing file reads as no
   choice, not a crash. *)
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
                Masc.Tui_preference.edit
                  (Masc.Tui_preference.Theme_chosen (Some "ayu-dark")) legacy_runtime
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


(* The Keeper list fields of a snapshot whose settings came back as the
   defaults: what these tests look at is the local file. *)
let keepers ~base_path = Config.of_settings ~base_path (Ok (P.settings_of_reading (Ok None)))

let keeper name =
  match Keeper_id.Keeper_name.of_string name with
  | Ok keeper -> keeper
  | Error reason -> Alcotest.fail reason

let settings_cases =
  [ Alcotest.test_case "unread settings open on the defaults and say why" `Quick (fun () ->
        with_temp_base (fun ~base ~config:_ ->
          let read = Config.of_settings ~base_path:base (Error "connection refused") in
          check_opt "the reason is kept" (Some "connection refused") read.settings_unread;
          check_opt "no theme" None read.stored.theme;
          Alcotest.(check bool) "the overview opens" true (read.stored.opening = Ok Config.Overview);
          Alcotest.(check bool) "the last conversation stays unread, not none" true
            (read.stored.last_chat_keeper = Error "connection refused")))
  ; Alcotest.test_case "the server's settings are what the snapshot holds" `Quick (fun () ->
        with_temp_base (fun ~base ~config:_ ->
          let settings =
            P.settings_of_reading
              (Ok (Some "[tui]\ntheme = \"monokai\"\nopening = \"last\"\nlast_chat_keeper = \"alpha\"\n"))
          in
          let read = Config.of_settings ~base_path:base (Ok settings) in
          check_opt "nothing unread" None read.settings_unread;
          check_opt "theme" (Some "monokai") read.stored.theme;
          Alcotest.(check bool) "opening" true
            (read.stored.opening = Ok (Config.Last (Some (keeper "alpha"))))))
  ; Alcotest.test_case "the start-up read asks the server once" `Quick (fun () ->
        with_temp_base (fun ~base ~config:_ ->
          Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
            let asked = ref 0 in
            let read_settings () =
              incr asked;
              Ok (P.settings_of_reading (Ok (Some "[tui]\ncandle = \"dotted\"\n")))
            in
            let startup = Config.prepare_startup_read ~sw:(Some sw) ~base_path:base ~read_settings in
            let snapshot = Eio.Promise.await_exn startup.result in
            Alcotest.(check int) "one read" 1 !asked;
            check_opt "candle" (Some "dotted") snapshot.settings.stored.candle))))
  ]

(* The server's answer to a stored pick. A body of another shape is an unread
   answer, never an exception the writer would report as its own failure. *)
let answer_cases =
  let saved =
    Alcotest.testable
      (fun ppf -> function
         | Writer.Unchanged -> Format.pp_print_string ppf "unchanged"
         | Writer.Committed { durability = Runtime.Durable; ignored_legacy_keys } ->
             Format.fprintf ppf "durable [%s]" (String.concat "," ignored_legacy_keys)
         | Writer.Committed
             { durability = Runtime.Durability_unconfirmed { detail }; ignored_legacy_keys } ->
             Format.fprintf ppf "unconfirmed %s [%s]" detail (String.concat "," ignored_legacy_keys))
      ( = )
  in
  let check label expected body =
    Alcotest.(check (result saved pass)) label expected (Masc_tui_http.tui_preference_answer body)
  in
  let unread label body =
    match Masc_tui_http.tui_preference_answer body with
    | Ok _ -> Alcotest.failf "%s: read as a stored pick" label
    | Error _ -> ()
  in
  [ Alcotest.test_case "unchanged and committed answers are read" `Quick (fun () ->
        check "unchanged" (Ok Writer.Unchanged)
          {|{"state":"unchanged","warnings":[],"source_revision":"r1"}|};
        check "durable"
          (Ok (Writer.Committed { durability = Runtime.Durable; ignored_legacy_keys = [] }))
          {|{"state":"committed","commit":{"durability":"durable","durability_detail":null,"ignored_legacy_keys":[]}}|};
        check "unconfirmed"
          (Ok (Writer.Committed
                 { durability = Runtime.Durability_unconfirmed { detail = "fsync failed" }
                 ; ignored_legacy_keys = [ "max-prompt-bytes" ] }))
          {|{"state":"committed","commit":{"durability":"unconfirmed","durability_detail":"fsync failed","ignored_legacy_keys":["max-prompt-bytes"]}}|})
  ; Alcotest.test_case "other shapes are unread answers, not exceptions" `Quick (fun () ->
        unread "not JSON" "<html>";
        unread "not an object" "[]";
        unread "no state" "{}";
        unread "committed without a commit" {|{"state":"committed"}|};
        unread "a commit that is not an object" {|{"state":"committed","commit":"yes"}|};
        unread "unconfirmed without a detail"
          {|{"state":"committed","commit":{"durability":"unconfirmed","ignored_legacy_keys":[]}}|};
        unread "ignored keys that are not names"
          {|{"state":"committed","commit":{"durability":"durable","ignored_legacy_keys":[1]}}|})
  ]

(* Picks that reach the writer in one order are sent in that order, one at a
   time, and their completions come back in that order: the last pick is the
   one the server keeps. *)
let writer_cases =
  [ Alcotest.test_case "picks are sent one at a time in the order made" `Quick (fun () ->
        Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
          let sent = ref [] and in_flight = ref 0 and overlapped = ref false in
          let send change =
            incr in_flight;
            if !in_flight > 1 then overlapped := true;
            Eio.Fiber.yield ();
            sent := P.change_kind change :: !sent;
            decr in_flight;
            Ok Writer.Unchanged
          in
          let writer = Writer.create ~send in
          let first = Writer.submit writer ~sw:(Some sw) (P.Candle_chosen P.Dotted) in
          let second = Writer.submit writer ~sw:(Some sw) (P.Theme_chosen (Some "nord")) in
          let third = Writer.submit writer ~sw:(Some sw) (P.Candle_chosen P.Painted) in
          Writer.close writer;
          Alcotest.(check bool) "never two at once" false !overlapped;
          Alcotest.(check (list string)) "sent in order" [ "candle"; "theme"; "candle" ] (List.rev !sent);
          let settled = ref [] in
          Writer.drain_completed writer ~can_take:(fun () -> true)
            ~apply:(fun (completion : Writer.completion) -> settled := completion.request :: !settled);
          Alcotest.(check bool) "completions in order" true
            (match List.rev !settled with
             | [ a; b; c ] -> Writer.same_request a first && Writer.same_request b second && Writer.same_request c third
             | _ -> false))))
  ; Alcotest.test_case "a pick with no switch is not started and says so" `Quick (fun () ->
        let writer = Writer.create ~send:(fun _ -> Alcotest.fail "nothing should be sent") in
        let request = Writer.submit writer ~sw:None P.Help_hint_retired in
        let outcomes = ref [] in
        Writer.drain_completed writer ~can_take:(fun () -> true)
          ~apply:(fun (completion : Writer.completion) ->
            outcomes := (Writer.same_request completion.request request, completion.outcome) :: !outcomes);
        Alcotest.(check bool) "not started" true
          (match !outcomes with
           | [ (true, Error (Writer.Not_started _)) ] -> true
           | _ -> false))
  ]

(* The Home setting belongs to the local workspace. A visit is sent only while
   the server reading is this workspace, confirmed and ready; a visit already
   sent still owns its completion while another workspace is on screen. *)
let test_home_visit_stays_with_local_workspace () =
  with_temp_base (fun ~base:base_path ~config:_ ->
    let module State = Masc_tui_types in
    let module Decode = Masc.Tui_decode in
    let canonical = Decode.Canonical_path.of_path in
    let identity base : Decode.server_identity =
      { sid_version = "test"; sid_binary_commit = "test";
        sid_binary_commit_age_s = None; sid_runtime_instance_id = None; sid_base_path = canonical base;
        sid_masc_root = canonical (Filename.concat base ".masc");
        sid_executable_in_worktree = None; sid_state_ready = Some true;
        sid_uptime = None; sid_sse_clients = None; sid_gc = None;
        sid_scheduler = None; sid_operator_action = None } in
    let alpha = keeper "alpha" and beta = keeper "beta" in
    Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
      let sent = ref [] in
      let preference_send change =
        sent := change :: !sent;
        Ok (Writer.Committed { durability = Runtime.Durable; ignored_legacy_keys = [] })
      in
      let state = State.create_state ~workspace:"visits" ~local_base_path:base_path
          ~preference_send ~port:0 () in
      let admit keeper = State.remember_local_chat_visit state ~sw:(Some sw) keeper in
      Alcotest.(check bool) "unread workspace admits no visit" false (admit beta);
      let local = identity base_path in
      state.server_identity <- Some local;
      state.workspace_identity <- Workspace_identity_match;
      Alcotest.(check bool) "verified local visit is admitted" true (admit alpha);
      let pending = match state.home_chat_visit with
        | Some request -> request | None -> Alcotest.fail "missing local visit" in
      let declined label =
        Alcotest.(check bool) label false (admit beta);
        Alcotest.(check bool) "earlier local request remains owned" true
          (Option.exists (Writer.same_request pending) state.home_chat_visit) in
      let remote = identity (base_path ^ "-remote") in
      state.server_identity <- Some remote;
      state.workspace_identity <- Workspace_identity_mismatch
        { local_base_path=base_path; server_base_path=base_path ^ "-remote" };
      declined "remote Keeper cannot update local Home";
      state.workspace_identity <- Workspace_identity_match;
      declined "a foreign reading cannot borrow a stale match";
      state.server_identity <- Some {local with sid_masc_root = remote.sid_masc_root};
      declined "a different MASC root is a different workspace";
      state.server_identity <- Some {local with sid_state_ready = Some false};
      declined "a starting server cannot authorize the write";
      state.server_identity <- Some local;
      state.workspace_identity <- Workspace_identity_match_unconfirmed "health failed";
      declined "an unconfirmed local identity cannot authorize the write";
      Writer.close state.preference_writer;
      Alcotest.(check bool) "only alpha was sent" true
        (!sent = [ P.Chat_visited alpha ]);
      Alcotest.(check bool) "the admitted visit is this session's pick, the declined ones are not" true
        (state.session_picks = [ P.Key.Last_chat_keeper ]);
      State.note_session_key state P.Key.Hints_visible;
      State.note_session_key state P.Key.Hints_visible;
      Alcotest.(check int) "a setting changed twice is listed once" 2
        (List.length state.session_picks);
      let settled = ref 0 in
      Writer.drain_completed state.preference_writer ~can_take:(fun () -> true)
        ~apply:(fun (completion : Writer.completion) ->
          incr settled;
          Alcotest.(check bool) "the local visit settles Home" true
            (State.accept_chat_visit state completion alpha));
      Alcotest.(check int) "one completion" 1 !settled;
      match state.home_last_chat with
      | Recorded_chat name when Keeper_id.Keeper_name.equal name alpha -> ()
      | No_chat_receipt | Saving_chat _ | Recorded_chat _ | Session_chat _
      | Unconfirmed_chat _ | Unobserved_chat _ | Unreadable_chat_receipt _ ->
          Alcotest.fail "the local visit did not settle for alpha")))

let home_cases =
  [ Alcotest.test_case "Home visits stay in their verified local workspace" `Quick
      test_home_visit_stays_with_local_workspace ]

let keeper_list_preferences_cases =
  [ Alcotest.test_case "list preferences survive a new read and independent edits" `Quick
      (fun () ->
        with_storable_base (fun ~base_path ->
          (match Config.set_keeper_list_sort ~base_path "oldest" with
           | Ok () -> () | Error message -> Alcotest.fail message);
          (match Config.set_keeper_list_view ~base_path ~view:"state" ~density:"detailed" with
           | Ok () -> () | Error message -> Alcotest.fail message);
          let read = keepers ~base_path in
          check_opt "stored order" (Some "oldest") read.keeper_list_sort;
          check_opt "stored view" (Some "state") read.keeper_list_view;
          check_opt "stored density" (Some "detailed") read.keeper_list_density;
          (match Config.set_keeper_list_sort ~base_path "activity" with
           | Ok () -> () | Error message -> Alcotest.fail message);
          let read = keepers ~base_path in
          check_opt "changed order" (Some "activity") read.keeper_list_sort;
          check_opt "view preserved" (Some "state") read.keeper_list_view;
          check_opt "density preserved" (Some "detailed") read.keeper_list_density;
          (match Config.set_keeper_list_view ~base_path ~view:"24h" ~density:"compact" with
           | Ok () -> () | Error message -> Alcotest.fail message);
          let read = keepers ~base_path in
          check_opt "order preserved by a view edit" (Some "activity") read.keeper_list_sort;
          check_opt "changed view" (Some "24h") read.keeper_list_view;
          check_opt "changed density" (Some "compact") read.keeper_list_density))
  ; Alcotest.test_case "a key the reader does not know is not read" `Quick (fun () ->
        with_temp_base (fun ~base ~config ->
          write (Filename.concat config "tui-keepers.toml")
            "[keepers]\nsort = \"name\"\nwidth = \"wide\"\n";
          let read = keepers ~base_path:base in
          check_opt "order is read" (Some "name") read.keeper_list_sort;
          check_opt "no view" None read.keeper_list_view;
          check_opt "no density" None read.keeper_list_density;
          check_opt "no read error" None read.keeper_list_error;
          (match Config.set_keeper_list_view ~base_path:base ~view:"state" ~density:"compact" with
           | Ok () -> () | Error message -> Alcotest.fail message);
          check_opt "a view saves beside it" (Some "state") (keepers ~base_path:base).keeper_list_view))
  ; Alcotest.test_case "first preference does not need runtime.toml" `Quick (fun () ->
        with_temp_base (fun ~base ~config:_ ->
          (match Config.set_keeper_list_sort ~base_path:base "name" with
           | Ok () -> () | Error message -> Alcotest.fail message);
          let read = keepers ~base_path:base in
          check_opt "order stored" (Some "name") read.keeper_list_sort;
          check_opt "no read error" None read.keeper_list_error))
  ; Alcotest.test_case "a failed edit preserves the original preferences" `Quick (fun () ->
        with_temp_base (fun ~base ~config ->
          let path = Filename.concat config "tui-keepers.toml" in
          let original = "keepers = { sort = \"name\", view = \"state\" }\n" in
          write path original;
          Alcotest.(check bool) "unsupported table shape is reported" true
            (Option.is_some (keepers ~base_path:base).keeper_list_error);
          Alcotest.(check bool) "unsafe inline-table edit refused" true
            (Result.is_error (Config.set_keeper_list_sort ~base_path:base "recent"));
          Alcotest.(check string) "original bytes remain" original (read_file path)))
  ; Alcotest.test_case "wrong preference type is reported" `Quick (fun () ->
        with_temp_base (fun ~base ~config ->
          write (Filename.concat config "tui-keepers.toml")
            "[keepers]\nsort = 42\nview = \"state\"\n";
          let read = keepers ~base_path:base in
          check_opt "invalid order is absent" None read.keeper_list_sort;
          check_opt "valid view is retained" (Some "state") read.keeper_list_view;
          Alcotest.(check bool) "invalid order is reported" true (Option.is_some read.keeper_list_error)))
  ; Alcotest.test_case "a FIFO is refused without opening it" `Quick (fun () ->
        with_temp_base (fun ~base ~config ->
          Unix.mkfifo (Filename.concat config "tui-keepers.toml") 0o600;
          let read = keepers ~base_path:base in
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
                (Option.is_some (keepers ~base_path:base).keeper_list_error);
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
            let second = submit (Config.Keeper_view { view = "state"; density = "detailed" }) in
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
            let read = keepers ~base_path:base in
            check_opt "latest order" (Some "oldest") read.keeper_list_sort;
            check_opt "view survives" (Some "state") read.keeper_list_view;
            check_opt "density survives" (Some "detailed") read.keeper_list_density))))
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
    [ ("settings", settings_cases)
    ; ("keeper_list_preferences", keeper_list_preferences_cases)
    ; ("preference_writer", writer_cases)
    ; ("preference_answer", answer_cases)
    ; ("home", home_cases)
    ; ("ui_language_mapping", language_mapping_cases)
    ; ( "commit receipt carries the ignored legacy keys"
      , [ receipt_case "durable save names ignored legacy keys" ~inject:false
        ; receipt_case
            "after-rename unconfirmed save still names ignored legacy keys"
            ~inject:true ] )
    ]
