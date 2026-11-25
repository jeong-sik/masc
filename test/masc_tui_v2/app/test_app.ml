open Masc_tui_core
open Masc_tui_net
open Masc_tui_store
open Masc_tui_app

let contains_substring ~needle haystack =
  let n_len = String.length needle in
  let h_len = String.length haystack in
  if n_len = 0 then true
  else if n_len > h_len then false
  else
    let limit = h_len - n_len in
    let rec scan i =
      if i > limit then false
      else if String.equal (String.sub haystack i n_len) needle then true
      else scan (i + 1)
    in
    scan 0

(* -------------------------------------------------------------------------- *)
(* 1. Cli_args                                                                *)
(* -------------------------------------------------------------------------- *)

let empty_env _ = None

let test_cli_info_flags () =
  (match
     Cli_args.parse ~version:"1.2.3" ~build_commit:(Some "deadbeef1234")
       ~env:empty_env ~cwd:"/tmp/ws" [ "--version" ]
   with
  | Cli_args.Info (Cli_args.Print_version v) ->
      Alcotest.(check string) "version with embedded commit"
        "1.2.3 (deadbeef)" v
  | Cli_args.Run _ | Cli_args.Info _ | Cli_args.Parse_error _ ->
      Alcotest.fail "expected Print_version");
  (match
     Cli_args.parse ~version:"1.2.3" ~build_commit:(Some "abc")
       ~env:empty_env ~cwd:"/tmp/ws" [ "--version" ]
   with
  | Cli_args.Info (Cli_args.Print_version v) ->
      Alcotest.(check string) "version with short commit" "1.2.3 (abc)" v
  | Cli_args.Run _ | Cli_args.Info _ | Cli_args.Parse_error _ ->
      Alcotest.fail "expected Print_version for short commit");
  (match
     Cli_args.parse ~version:"1.2.3" ~build_commit:None ~env:empty_env
       ~cwd:"/tmp/ws" [ "--version" ]
   with
  | Cli_args.Info (Cli_args.Print_version v) ->
      Alcotest.(check string) "bare version without commit" "1.2.3" v
  | Cli_args.Run _ | Cli_args.Info _ | Cli_args.Parse_error _ ->
      Alcotest.fail "expected bare Print_version when build_commit = None");
  (match
     Cli_args.parse ~version:"1.2.3" ~build_commit:(Some "   ") ~env:empty_env
       ~cwd:"/tmp/ws" [ "--version" ]
   with
  | Cli_args.Info (Cli_args.Print_version v) ->
      Alcotest.(check string) "bare version on blank commit" "1.2.3" v
  | Cli_args.Run _ | Cli_args.Info _ | Cli_args.Parse_error _ ->
      Alcotest.fail "expected bare Print_version when build_commit is blank");
  (match
     Cli_args.parse ~version:"1.2.3"
       ~build_commit:(Some "0123456789abcdef0123456789abcdef01234567")
       ~env:empty_env ~cwd:"/tmp/ws" [ "--build-commit" ]
   with
  | Cli_args.Info (Cli_args.Print_build_commit (Some sha)) ->
      Alcotest.(check string) "commit sha"
        "0123456789abcdef0123456789abcdef01234567" sha
  | Cli_args.Run _ | Cli_args.Info _ | Cli_args.Parse_error _ ->
      Alcotest.fail "expected Print_build_commit");
  List.iter
    (fun flag ->
      match Cli_args.parse ~env:empty_env ~cwd:"/tmp/ws" [ flag ] with
      | Cli_args.Info (Cli_args.Print_help text) ->
          List.iter
            (fun required ->
              Alcotest.(check bool)
                ("help contains " ^ required)
                true
                (contains_substring ~needle:required text))
            [
              "--port";
              "--base-path";
              "--url";
              "--theme";
              "--lang";
              "--no-auto-start";
              "--version";
              "--build-commit";
            ]
      | Cli_args.Run _ | Cli_args.Info _ | Cli_args.Parse_error _ ->
          Alcotest.fail ("expected Print_help for " ^ flag))
    [ "--help"; "-h" ]

let test_cli_flags_and_urls () =
  let env = function
    | "HOME" -> Some "/tmp/fake-home"
    | _ -> None
  in
  (match
     Cli_args.parse ~env ~cwd:"/tmp/cwd"
       [
         "--port";
         "9123";
         "--base-path";
         "~/my-workspace";
         "--theme";
         "arcade";
         "--lang";
         "en";
         "--no-auto-start";
       ]
   with
  | Cli_args.Run cfg ->
      Alcotest.(check string) "scheme" "http" cfg.scheme;
      Alcotest.(check string) "host" "127.0.0.1" cfg.host;
      Alcotest.(check int) "port" 9123 cfg.port;
      Alcotest.(check string) "base_path" "/tmp/fake-home/my-workspace"
        cfg.base_path;
      Alcotest.(check string) "workspace" "my-workspace" cfg.workspace;
      Alcotest.(check bool) "theme" true
        (Theme.equal_preset cfg.theme Theme.Arcade_hi);
      Alcotest.(check bool) "lang" true (Say.equal_lang cfg.lang Say.Lang_en);
      Alcotest.(check bool) "theme_explicit set" true cfg.theme_explicit;
      Alcotest.(check bool) "lang_explicit set" true cfg.lang_explicit;
      Alcotest.(check bool) "auto_start disabled" false cfg.auto_start
  | Cli_args.Info _ | Cli_args.Parse_error _ ->
      Alcotest.fail "expected valid Run config");
  (match
     Cli_args.parse ~env:empty_env ~cwd:"/tmp/cwd"
       [ "--url=https://masc.example.internal:8443"; "--theme=paper"; "--lang=ko" ]
   with
  | Cli_args.Run cfg ->
      Alcotest.(check string) "https scheme" "https" cfg.scheme;
      Alcotest.(check string) "url host" "masc.example.internal" cfg.host;
      Alcotest.(check int) "url port" 8443 cfg.port;
      Alcotest.(check bool) "paper theme" true
        (Theme.equal_preset cfg.theme Theme.Paper_light);
      Alcotest.(check bool) "ko lang" true (Say.equal_lang cfg.lang Say.Lang_ko);
      Alcotest.(check bool) "auto_start default true" true cfg.auto_start
  | Cli_args.Info _ | Cli_args.Parse_error _ ->
      Alcotest.fail "expected valid URL Run config");
  (match
     Cli_args.parse ~env:empty_env ~cwd:"/tmp/cwd"
       [ "--url"; "https://masc.example.internal" ]
   with
  | Cli_args.Run cfg ->
      Alcotest.(check int) "https default port" 443 cfg.port;
      Alcotest.(check bool) "theme_explicit false when omitted" false
        cfg.theme_explicit;
      Alcotest.(check bool) "lang_explicit false when omitted" false
        cfg.lang_explicit
  | Cli_args.Info _ | Cli_args.Parse_error _ ->
      Alcotest.fail "expected https default port 443")

let test_cli_rejects_invalid_inputs () =
  let bad_cases =
    [
      [ "--port"; "0" ];
      [ "--port"; "-5" ];
      [ "--port"; "65536" ];
      [ "--port"; "not-a-number" ];
      [ "--port" ];
      [ "--theme"; "neon-cyber" ];
      [ "--lang"; "fr" ];
      [ "--url"; "ftp://127.0.0.1:8935" ];
      [ "--url"; "http://127.0.0.1:8935/extra/path" ];
      [ "--unknown-flag" ];
    ]
  in
  List.iter
    (fun argv ->
      match Cli_args.parse ~env:empty_env ~cwd:"/tmp/cwd" argv with
      | Cli_args.Parse_error _ -> ()
      | Cli_args.Run _ | Cli_args.Info _ ->
          Alcotest.fail
            ("expected Parse_error for: " ^ String.concat " " argv))
    bad_cases

let test_cli_removed_reasoning_and_tool_view_flags () =
  let expect_removed_err argv =
    match Cli_args.parse ~env:empty_env ~cwd:"/tmp/cwd" argv with
    | Cli_args.Parse_error msg ->
        Alcotest.(check bool)
          ("contains /tools for " ^ String.concat " " argv)
          true
          (contains_substring ~needle:"/tools" msg);
        Alcotest.(check bool)
          ("contains Toggle_thinking for " ^ String.concat " " argv)
          true
          (contains_substring ~needle:"Toggle_thinking" msg);
        msg
    | Cli_args.Run _ | Cli_args.Info _ ->
        Alcotest.fail
          ("expected Parse_error for removed flag: " ^ String.concat " " argv)
  in
  let r_space = expect_removed_err [ "--reasoning"; "full" ] in
  let r_eq = expect_removed_err [ "--reasoning=full" ] in
  Alcotest.(check string)
    "--reasoning full and --reasoning=full yield identical message"
    r_space r_eq;
  let t_space = expect_removed_err [ "--tool-view"; "results" ] in
  let t_eq = expect_removed_err [ "--tool-view=results" ] in
  Alcotest.(check string)
    "--tool-view results and --tool-view=results yield identical message"
    t_space t_eq;
  (* Removed flags must NOT be re-listed in --help usage text. *)
  Alcotest.(check bool) "help_text omits --reasoning" false
    (contains_substring ~needle:"--reasoning" Cli_args.help_text);
  Alcotest.(check bool) "help_text omits --tool-view" false
    (contains_substring ~needle:"--tool-view" Cli_args.help_text);
  (* parse_and_dispatch exits with code 2 on removed flags. *)
  let err_path = Filename.temp_file "masc_tui_removed_flag_err_" ".log" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove err_path with Sys_error _ -> ())
    (fun () ->
      let err_ch = Out_channel.open_text err_path in
      let outcome =
        Fun.protect
          ~finally:(fun () -> Out_channel.close_noerr err_ch)
          (fun () ->
            Cli_args.parse_and_dispatch
              ~argv:[| "masc-tui"; "--tool-view"; "results" |]
              ~err_channel:err_ch ())
      in
      match outcome with
      | Cli_args.Exit 2 -> ()
      | Cli_args.Exit code ->
          Alcotest.failf "expected exit code 2, got %d" code
      | Cli_args.Start _ ->
          Alcotest.fail "expected Exit 2 for removed --tool-view flag")

let test_cli_non_tty_detection () =
  (match
     Cli_args.check_tty_pure ~stdin_is_tty:false ~stdout_is_tty:true
       ~term_env:(Some "xterm-256color")
   with
  | Cli_args.Non_tty { exit_code; reason } ->
      Alcotest.(check int) "non-tty stdin exit 2" 2 exit_code;
      Alcotest.(check bool) "non-empty reason" true (String.length reason > 0)
  | Cli_args.Tty_ok -> Alcotest.fail "expected Non_tty for non-tty stdin");
  (match
     Cli_args.check_tty_pure ~stdin_is_tty:true ~stdout_is_tty:false
       ~term_env:(Some "xterm-256color")
   with
  | Cli_args.Non_tty { exit_code; _ } ->
      Alcotest.(check int) "non-tty stdout exit 2" 2 exit_code
  | Cli_args.Tty_ok -> Alcotest.fail "expected Non_tty for non-tty stdout");
  (match
     Cli_args.check_tty_pure ~stdin_is_tty:true ~stdout_is_tty:true
       ~term_env:(Some "dumb")
   with
  | Cli_args.Non_tty { exit_code; _ } ->
      Alcotest.(check int) "TERM=dumb exit 2" 2 exit_code
  | Cli_args.Tty_ok -> Alcotest.fail "expected Non_tty for TERM=dumb");
  match
    Cli_args.check_tty_pure ~stdin_is_tty:true ~stdout_is_tty:true
      ~term_env:(Some "xterm-256color")
  with
  | Cli_args.Tty_ok -> ()
  | Cli_args.Non_tty _ -> Alcotest.fail "expected Tty_ok for interactive TTY"

(* -------------------------------------------------------------------------- *)
(* 2. Frame_scheduler                                                         *)
(* -------------------------------------------------------------------------- *)

let test_scheduler_60fps_burst_and_0hz_idle () =
  let t0 = 1_000_000_000L in
  let s0 = Frame_scheduler.create () in
  (* First frame renders immediately. *)
  (match Frame_scheduler.decide ~now_ns:t0 ~output_behind:false s0 with
  | Frame_scheduler.Render_now -> ()
  | Frame_scheduler.Skip_backpressure _
  | Frame_scheduler.Wait_until _
  | Frame_scheduler.Sleep_idle ->
      Alcotest.fail "expected Render_now for initial frame");
  let s1 =
    Frame_scheduler.record_rendered ~now_ns:t0 ~render_us:800 ~diff_us:150
      ~dirty_cells:42 ~bytes_emitted:512 s0
  in
  (* Clean + no extra deadline => 0 Hz pure sleep (Next_deadline_ns None). *)
  Alcotest.(check bool) "clean after render" false (Frame_scheduler.is_dirty s1);
  (match Frame_scheduler.decide ~now_ns:t0 ~output_behind:false s1 with
  | Frame_scheduler.Sleep_idle -> ()
  | Frame_scheduler.Render_now
  | Frame_scheduler.Skip_backpressure _
  | Frame_scheduler.Wait_until _ ->
      Alcotest.fail "expected Sleep_idle when clean");
  (match Frame_scheduler.next_deadline ~now_ns:t0 ~output_behind:false s1 with
  | Frame_scheduler.Next_deadline_ns None -> ()
  | Frame_scheduler.Next_deadline_ns (Some _) ->
      Alcotest.fail "expected Next_deadline_ns None for 0 Hz pure sleep");

  (* Mark dirty with interactive 60 FPS pace immediately after t0. *)
  let s2 =
    Frame_scheduler.mark_dirty ~pace:Frame_scheduler.Pace_interactive s1
    |> Frame_scheduler.mark_dirty ~pace:Frame_scheduler.Pace_animation
  in
  (* Interactive pace is preserved over animation within the same burst. *)
  let t_mid = Int64.add t0 5_000_000L in
  (match Frame_scheduler.decide ~now_ns:t_mid ~output_behind:false s2 with
  | Frame_scheduler.Wait_until { deadline_ns } ->
      Alcotest.(check int64) "60 FPS slot"
        (Int64.add t0 Frame_scheduler.frame_interval_60fps_ns)
        deadline_ns
  | Frame_scheduler.Render_now
  | Frame_scheduler.Skip_backpressure _
  | Frame_scheduler.Sleep_idle ->
      Alcotest.fail "expected Wait_until for 60 FPS burst");
  let t_due = Int64.add t0 Frame_scheduler.frame_interval_60fps_ns in
  (match Frame_scheduler.decide ~now_ns:t_due ~output_behind:false s2 with
  | Frame_scheduler.Render_now -> ()
  | Frame_scheduler.Skip_backpressure _
  | Frame_scheduler.Wait_until _
  | Frame_scheduler.Sleep_idle ->
      Alcotest.fail "expected Render_now at 16.67ms boundary");
  let s3 =
    Frame_scheduler.record_rendered ~now_ns:t_due ~render_us:1200 ~diff_us:250
      ~dirty_cells:80 ~bytes_emitted:900 s2
  in
  let tel = Frame_scheduler.telemetry s3 in
  Alcotest.(check int) "frames_rendered" 2 tel.frames_rendered;
  Alcotest.(check int) "last_render_us" 1200 tel.last_render_us;
  Alcotest.(check int) "last_diff_us" 250 tel.last_diff_us;
  Alcotest.(check int) "last_dirty_cells" 80 tel.last_dirty_cells;
  Alcotest.(check int) "avg_render_us" 1000 tel.avg_render_us;
  Alcotest.(check int) "avg_diff_us" 200 tel.avg_diff_us;
  Alcotest.(check int) "max_render_us" 1200 tel.max_render_us

let test_scheduler_backpressure_and_animation () =
  let t0 = 5_000_000_000L in
  let s =
    Frame_scheduler.create ()
    |> Frame_scheduler.record_rendered ~now_ns:t0 ~render_us:500 ~diff_us:100
         ~dirty_cells:10 ~bytes_emitted:100
    |> Frame_scheduler.mark_dirty ~pace:Frame_scheduler.Pace_animation
  in
  let t1 = Int64.add t0 20_000_000L in
  (* Animation pace is 33.33ms, so at +20ms we still wait. *)
  (match Frame_scheduler.decide ~now_ns:t1 ~output_behind:false s with
  | Frame_scheduler.Wait_until { deadline_ns } ->
      Alcotest.(check int64) "30 FPS animation slot"
        (Int64.add t0 Frame_scheduler.frame_interval_30fps_ns)
        deadline_ns
  | Frame_scheduler.Render_now
  | Frame_scheduler.Skip_backpressure _
  | Frame_scheduler.Sleep_idle ->
      Alcotest.fail "expected 30 FPS animation wait");

  (* When stdout is backed up, skip frame and keep dirty armed. *)
  let t2 = Int64.add t0 40_000_000L in
  (match Frame_scheduler.decide ~now_ns:t2 ~output_behind:true s with
  | Frame_scheduler.Skip_backpressure { retry_at_ns } ->
      Alcotest.(check int64) "backpressure retry"
        (Int64.add t2 Frame_scheduler.backpressure_retry_ns)
        retry_at_ns
  | Frame_scheduler.Render_now
  | Frame_scheduler.Wait_until _
  | Frame_scheduler.Sleep_idle ->
      Alcotest.fail "expected Skip_backpressure when output_behind=true");
  let s_skipped = Frame_scheduler.record_skipped_backpressure ~now_ns:t2 s in
  Alcotest.(check bool) "still dirty after backpressure skip" true
    (Frame_scheduler.is_dirty s_skipped);
  Alcotest.(check int) "frames_skipped_backpressure" 1
    (Frame_scheduler.telemetry s_skipped).frames_skipped_backpressure

(* -------------------------------------------------------------------------- *)
(* 3. Wake_bell & Signals                                                     *)
(* -------------------------------------------------------------------------- *)

let test_wake_bell_coalesce_and_drain () =
  let bell = Wake_bell.create () in
  Alcotest.(check bool) "initially not rung" false (Wake_bell.is_rung bell);
  Alcotest.(check int) "initial mask 0" 0 (Wake_bell.peek_mask bell);
  Wake_bell.ring bell Wake_bell.Ui_bus;
  Wake_bell.ring bell Wake_bell.Ui_bus;
  Wake_bell.ring_from_signal bell Wake_bell.Resize;
  Wake_bell.ring_from_signal bell Wake_bell.Terminate;
  Alcotest.(check bool) "is rung" true (Wake_bell.is_rung bell);
  let expected_mask =
    Wake_bell.mask_of_source Wake_bell.Ui_bus
    lor Wake_bell.mask_of_source Wake_bell.Resize
    lor Wake_bell.mask_of_source Wake_bell.Terminate
  in
  Alcotest.(check int) "coalesced mask" expected_mask (Wake_bell.peek_mask bell);
  let drained = Wake_bell.drain bell in
  Alcotest.(check int) "3 coalesced sources" 3 (List.length drained);
  Alcotest.(check bool) "ordered Ui_bus first" true
    (Wake_bell.equal_source (List.nth drained 0) Wake_bell.Ui_bus);
  Alcotest.(check bool) "ordered Resize second" true
    (Wake_bell.equal_source (List.nth drained 1) Wake_bell.Resize);
  Alcotest.(check bool) "ordered Terminate third" true
    (Wake_bell.equal_source (List.nth drained 2) Wake_bell.Terminate);
  Alcotest.(check bool) "cleared after drain" false (Wake_bell.is_rung bell);
  Alcotest.(check int) "second drain empty" 0 (List.length (Wake_bell.drain bell))

let test_wake_bell_signal_pipe_and_timeout () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let bell = Wake_bell.create () in
  Wake_bell.attach_signal_pipe ~sw bell;
  (* Pure 0 Hz sleep woken via signal-safe self-pipe. *)
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Time.sleep clock 0.01;
      Wake_bell.ring_from_signal bell Wake_bell.Resize);
  let res =
    Wake_bell.await_until_ns ~clock ~now_ns:0L ~deadline_ns:None bell
  in
  Alcotest.(check bool) "woken by signal pipe" true (res = `Woken);
  let drained = Wake_bell.drain bell in
  Alcotest.(check int) "drained Resize" 1 (List.length drained);
  (* Timed wait expires cleanly with `Timeout when silent. *)
  let now_ns = 1_000_000_000L in
  let res_timeout =
    Wake_bell.await_until_ns ~clock ~now_ns
      ~deadline_ns:(Some (Int64.add now_ns 15_000_000L))
      bell
  in
  Alcotest.(check bool) "timed wait returns Timeout" true
    (res_timeout = `Timeout)

let test_signals_state_machine_and_restore () =
  let bell = Wake_bell.create () in
  let sigs = Signals.create ~bell in
  Alcotest.(check bool) "initial Continue" true
    (Signals.equal_exit_verdict (Signals.poll_exit sigs) Signals.Continue);
  Signals.record_resize sigs;
  Alcotest.(check int) "resize gen 1" 1 (Signals.resize_generation sigs);
  (* First SIGINT arms; withdraw disarms; two consecutive SIGINT confirm. *)
  Signals.record_interrupt sigs;
  Alcotest.(check bool) "first SIGINT armed" true
    (Signals.equal_exit_verdict (Signals.poll_exit sigs) Signals.Interrupt_armed);
  Signals.withdraw_interrupt sigs;
  Signals.record_interrupt sigs;
  Alcotest.(check bool) "re-armed after withdraw" true
    (Signals.equal_exit_verdict (Signals.poll_exit sigs) Signals.Interrupt_armed);
  Signals.record_interrupt sigs;
  let v_conf = Signals.poll_exit sigs in
  Alcotest.(check bool) "second SIGINT confirmed" true
    (Signals.equal_exit_verdict v_conf Signals.Interrupt_confirmed);
  (match Signals.exit_reason_of_verdict v_conf with
  | Some Exit_reason.Interrupt -> ()
  | Some _ | None -> Alcotest.fail "expected Exit_reason.Interrupt");
  Signals.record_terminate sigs ~signal:"SIGTERM";
  let v_term = Signals.poll_exit sigs in
  Alcotest.(check bool) "SIGTERM Terminate" true
    (Signals.equal_exit_verdict v_term (Signals.Terminate "SIGTERM"));
  (* clear_interrupts disarms SIGINT without erasing SIGTERM. *)
  Signals.record_interrupt sigs;
  Signals.clear_interrupts sigs;
  Alcotest.(check (option string)) "SIGTERM preserved after clear_interrupts"
    (Some "SIGTERM")
    (Signals.terminate_signal sigs);
  (match Signals.exit_reason_of_verdict v_term with
  | Some reason ->
      Alcotest.(check string) "exit wire line"
        "[masc-tui] exit: normal (signal SIGTERM)"
        (Exit_reason.wire_line reason)
  | None -> Alcotest.fail "expected Terminate exit reason");
  (* Switch install/restore roundtrip including SIGTSTP guard suspend/resume
     for $EDITOR handoff. *)
  let sentinel_hits = ref 0 in
  let orig_sigtstp =
    Sys.signal Sys.sigtstp (Sys.Signal_handle (fun _ -> incr sentinel_hits))
  in
  Fun.protect
    ~finally:(fun () -> Sys.set_signal Sys.sigtstp orig_sigtstp)
    (fun () ->
      Eio_main.run @@ fun _env ->
      Eio.Switch.run (fun sw ->
          let bell2 = Wake_bell.create () in
          let sigs2 = Signals.create ~bell:bell2 in
          Signals.install ~sw sigs2;
          Alcotest.(check bool) "SIGTSTP guarded after install" true
            (Signals.is_sigtstp_guarded sigs2);
          (* Sending SIGTSTP while guarded must NOT stop or invoke prior handler. *)
          Unix.kill (Unix.getpid ()) Sys.sigtstp;
          Alcotest.(check int) "prior SIGTSTP handler suppressed while guarded"
            0 !sentinel_hits;
          (* $EDITOR pause_terminal suspends guard, restoring prior disposition. *)
          Signals.suspend_sigtstp_guard sigs2;
          Alcotest.(check bool) "SIGTSTP unguarded while suspended" false
            (Signals.is_sigtstp_guarded sigs2);
          Unix.kill (Unix.getpid ()) Sys.sigtstp;
          Alcotest.(check int) "prior SIGTSTP handler active while suspended"
            1 !sentinel_hits;
          (* $EDITOR resume_terminal re-installs guard before raw mode resumes. *)
          Signals.resume_sigtstp_guard sigs2;
          Alcotest.(check bool) "SIGTSTP guarded again after resume" true
            (Signals.is_sigtstp_guarded sigs2);
          Unix.kill (Unix.getpid ()) Sys.sigtstp;
          Alcotest.(check int) "prior SIGTSTP handler suppressed again after resume"
            1 !sentinel_hits);
      (* Switch release restores prior SIGTSTP disposition. *)
      Unix.kill (Unix.getpid ()) Sys.sigtstp;
      Alcotest.(check int) "prior SIGTSTP handler restored on switch release"
        2 !sentinel_hits)

let test_ctrl_c_arm_expire_and_withdraw_on_paste_mouse () =
  let t0 = Clock.Mono.of_ns 10_000_000_000L in
  let bell = Wake_bell.create () in
  let sigs = Signals.create ~bell in
  let queue : Msg.t Eio.Stream.t = Eio.Stream.create max_int in
  let ctrl_c_ev =
    Masc_tui_term.Input_decoder.Key
      {
        key = Masc_tui_term.Input_decoder.Char "c";
        mods = { ctrl = true; alt = false; shift = false };
      }
  in

  (* 1. First Ctrl+C arms for 3s; confirm inside window succeeds. *)
  App.dispatch_decoded_events ~signals:sigs ~bell ~input_queue:queue [ ctrl_c_ev ];
  Alcotest.(check bool) "first Ctrl+C arms" true
    (Signals.equal_exit_verdict (Signals.poll_exit ~now:t0 sigs) Signals.Interrupt_armed);
  Alcotest.(check bool) "armed at t0" true (Signals.is_interrupt_armed ~now:t0 sigs);
  let t_before = Clock.Mono.after_s t0 2.9 in
  Alcotest.(check bool) "does not expire at +2.9s" false
    (Signals.expire_interrupt ~now:t_before sigs);
  App.dispatch_decoded_events ~signals:sigs ~bell ~input_queue:queue [ ctrl_c_ev ];
  Alcotest.(check bool) "second Ctrl+C at +2.9s confirms exit" true
    (Signals.equal_exit_verdict
       (Signals.poll_exit ~now:t_before sigs)
       Signals.Interrupt_confirmed);
  Alcotest.(check bool) "disarmed after confirm" false
    (Signals.is_interrupt_armed ~now:t_before sigs);

  (* 2. Auto-expiry after 3s toast window (explicit expire_interrupt on Tick). *)
  App.dispatch_decoded_events ~signals:sigs ~bell ~input_queue:queue [ ctrl_c_ev ];
  Alcotest.(check bool) "re-armed at t0" true
    (Signals.equal_exit_verdict (Signals.poll_exit ~now:t0 sigs) Signals.Interrupt_armed);
  let t_expired = Clock.Mono.after_s t0 Signals.interrupt_arm_window_s in
  Alcotest.(check bool) "expire_interrupt fires at +3.0s" true
    (Signals.expire_interrupt ~now:t_expired sigs);
  Alcotest.(check bool) "disarmed after +3.0s" false
    (Signals.is_interrupt_armed ~now:t_expired sigs);
  Alcotest.(check bool) "armed deadline cleared" true
    (Option.is_none (Signals.interrupt_armed_deadline sigs));
  App.dispatch_decoded_events ~signals:sigs ~bell ~input_queue:queue [ ctrl_c_ev ];
  Alcotest.(check bool) "stray Ctrl+C after expiry re-arms instead of quitting" true
    (Signals.equal_exit_verdict
       (Signals.poll_exit ~now:t_expired sigs)
       Signals.Interrupt_armed);

  (* 3. Auto-expiry directly on next poll_exit minutes later even without intermediate Tick. *)
  let t_minutes_later = Clock.Mono.after_s t_expired 300.0 in
  App.dispatch_decoded_events ~signals:sigs ~bell ~input_queue:queue [ ctrl_c_ev ];
  Alcotest.(check bool) "Ctrl+C 5 minutes later re-arms instead of quitting" true
    (Signals.equal_exit_verdict
       (Signals.poll_exit ~now:t_minutes_later sigs)
       Signals.Interrupt_armed);

  (* 4. Bracketed Paste withdraws armed interrupt. *)
  App.dispatch_decoded_events ~signals:sigs ~bell ~input_queue:queue
    [ Masc_tui_term.Input_decoder.Paste { text = "hello paste"; dropped_bytes = 0 } ];
  Alcotest.(check bool) "Paste disarms interrupt" false
    (Signals.is_interrupt_armed ~now:t_minutes_later sigs);
  (match Eio.Stream.take_nonblocking queue with
  | Some (Msg.Paste_text "hello paste") -> ()
  | Some _ | None -> Alcotest.fail "expected Paste_text queued");
  let t_soon = Clock.Mono.after_s t_minutes_later 0.5 in
  App.dispatch_decoded_events ~signals:sigs ~bell ~input_queue:queue [ ctrl_c_ev ];
  Alcotest.(check bool) "Ctrl+C after Paste re-arms instead of quitting" true
    (Signals.equal_exit_verdict
       (Signals.poll_exit ~now:t_soon sigs)
       Signals.Interrupt_armed);

  (* 5. Mouse events (Wheel and Left_press) withdraw armed interrupt. *)
  App.dispatch_decoded_events ~signals:sigs ~bell ~input_queue:queue
    [
      Masc_tui_term.Input_decoder.Mouse
        (Masc_tui_term.Input_decoder.Wheel
           { dir = Masc_tui_term.Input_decoder.Wheel_down; col = 4; row = 8 });
    ];
  Alcotest.(check bool) "Mouse wheel disarms interrupt" false
    (Signals.is_interrupt_armed ~now:t_soon sigs);
  (match Eio.Stream.take_nonblocking queue with
  | Some (Msg.Mouse_event (Masc_tui_term.Input_decoder.Wheel _)) -> ()
  | Some _ | None -> Alcotest.fail "expected Mouse_event queued");
  App.dispatch_decoded_events ~signals:sigs ~bell ~input_queue:queue [ ctrl_c_ev ];
  Alcotest.(check bool) "re-armed before Left_press" true
    (Signals.equal_exit_verdict
       (Signals.poll_exit ~now:t_soon sigs)
       Signals.Interrupt_armed);
  App.dispatch_decoded_events ~signals:sigs ~bell ~input_queue:queue
    [
      Masc_tui_term.Input_decoder.Mouse
        (Masc_tui_term.Input_decoder.Left_press { col = 2; row = 3 });
    ];
  Alcotest.(check bool) "Mouse press disarms interrupt" false
    (Signals.is_interrupt_armed ~now:t_soon sigs);
  (match Eio.Stream.take_nonblocking queue with
  | Some (Msg.Mouse_event (Masc_tui_term.Input_decoder.Left_press _)) -> ()
  | Some _ | None -> Alcotest.fail "expected Left_press queued");

  (* 6. Noise events (Unknown_escape / Invalid_utf8) do NOT withdraw armed interrupt. *)
  App.dispatch_decoded_events ~signals:sigs ~bell ~input_queue:queue [ ctrl_c_ev ];
  Alcotest.(check bool) "re-armed before noise" true
    (Signals.equal_exit_verdict
       (Signals.poll_exit ~now:t_soon sigs)
       Signals.Interrupt_armed);
  App.dispatch_decoded_events ~signals:sigs ~bell ~input_queue:queue
    [
      Masc_tui_term.Input_decoder.Unknown_escape;
      Masc_tui_term.Input_decoder.Invalid_utf8;
    ];
  Alcotest.(check bool) "noise preserves armed state" true
    (Signals.is_interrupt_armed ~now:t_soon sigs)

(* -------------------------------------------------------------------------- *)
(* 4. Cmd_executor                                                            *)
(* -------------------------------------------------------------------------- *)

let make_temp_dir () =
  let base = Filename.temp_file "masc_tui_app_test_" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  base

let rec rm_rf path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
      Unix.unlink path
  | exception Unix.Unix_error _ -> ()

let test_cmd_executor_auth_and_headers () =
  let tmp = make_temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf tmp)
    (fun () ->
      let token_path = Cmd_executor.admin_token_path ~base_path:tmp in
      Alcotest.(check bool) "uses Common.masc_dirname" true
        (contains_substring ~needle:Common.masc_dirname token_path);
      Alcotest.(check (option string)) "missing token returns None" None
        (Cmd_executor.load_bearer_token ~getenv:empty_env ~base_path:tmp ());
      Fs_compat.mkdir_p (Filename.dirname token_path);
      let oc = Out_channel.open_text token_path in
      Fun.protect
        ~finally:(fun () -> Out_channel.close_noerr oc)
        (fun () -> Out_channel.output_string oc "  secret-admin-tok-42 \n");
      Alcotest.(check (option string)) "loads admin.token"
        (Some "secret-admin-tok-42")
        (Cmd_executor.load_bearer_token ~getenv:empty_env ~base_path:tmp ());
      let env_override = function
        | "MASC_TOKEN" -> Some "env-override-tok"
        | _ -> None
      in
      Alcotest.(check (option string)) "MASC_TOKEN overrides file"
        (Some "env-override-tok")
        (Cmd_executor.load_bearer_token ~getenv:env_override ~base_path:tmp ());

      let cli : Cli_args.config =
        {
          scheme = "http";
          host = "127.0.0.1";
          port = 8935;
          base_path = tmp;
          workspace = "test";
          theme = Theme.Midnight;
          lang = Say.Lang_en;
          theme_explicit = false;
          lang_explicit = false;
          auto_start = false;
        }
      in
      let ep =
        Cmd_executor.endpoint_of_cli cli
        |> fun e ->
        Http_client.with_guard e
          {
            expected_instance = Some "inst-99";
            expected_workspace = Some "sha-abc";
          }
      in
      let headers = Http_client.build_headers ep in
      let find_h k = List.assoc_opt k headers in
      Alcotest.(check (option string)) "Bearer header injected"
        (Some "Bearer secret-admin-tok-42")
        (find_h "Authorization");
      Alcotest.(check (option string)) "Instance guard header"
        (Some "inst-99")
        (find_h Http_client.expected_instance_header);
      Alcotest.(check (option string)) "Workspace guard header"
        (Some "sha-abc")
        (find_h Http_client.expected_workspace_header);
      Alcotest.(check string) "endpoint URL"
        "http://127.0.0.1:8935/health"
        (Http_client.build_url ep ~path:"/health"))

let test_cmd_executor_mappings_and_url_safety () =
  let ids =
    [
      Subscriptions.Stream_observer;
      Subscriptions.Stream_fleet;
      Subscriptions.Stream_model_metrics;
      Subscriptions.Stream_tool_metrics_series;
      Subscriptions.Stream_logs { since_seq = Some 12 };
    ]
  in
  List.iter
    (fun id ->
      let spec = Cmd_executor.stream_spec_of_id id in
      let roundtrip = Cmd_executor.stream_id_of_kind spec.kind in
      Alcotest.(check bool) "stream id roundtrip" true
        (Subscriptions.equal_stream_id id roundtrip))
    ids;
  Alcotest.(check bool) "https url allowed" true
    (Cmd_executor.is_safe_external_url "https://github.com/jeong-sik/masc");
  Alcotest.(check bool) "http url allowed" true
    (Cmd_executor.is_safe_external_url "http://127.0.0.1:8935/health");
  Alcotest.(check bool) "file url rejected" false
    (Cmd_executor.is_safe_external_url "file:///etc/passwd");
  Alcotest.(check bool) "newline url rejected" false
    (Cmd_executor.is_safe_external_url "https://example.com/\nrm -rf /");
  (match Cmd_executor.editor_file_path ~base_path:"/tmp/base" Cmd.Edit_runtime_toml with
  | Some p ->
      Alcotest.(check bool) "runtime toml path contains .masc/config/runtime.toml"
        true
        (contains_substring ~needle:"runtime.toml" p
        && contains_substring ~needle:Common.masc_dirname p)
  | None -> Alcotest.fail "expected runtime.toml path");
  Alcotest.(check (option string)) "wiki target has no local file path" None
    (Cmd_executor.editor_file_path ~base_path:"/tmp/base"
       (Cmd.Edit_wiki_page "arch"))

let test_cmd_executor_dispatch_and_cancellation () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let io = Io_domain.start ~sw ~env in
  let worker = Worker_pool.create ~sw (Eio.Stdenv.domain_mgr env) in
  let woken = Atomic.make 0 in
  let bus =
    Cmd_executor.create_bus ~on_wake:(fun () -> Atomic.incr woken) ()
  in
  let quit_seen = ref None in
  let restart_seen = ref false in
  let probe_caps : Voice_runner.capabilities =
    {
      recorder_available = true;
      recorder_cmd = Some "rec";
      stt_available = true;
    }
  in
  let fake_voice : Voice_runner.backend =
    {
      probe = (fun () -> Ok probe_caps);
      record_until_stopped =
        (fun ~device:_ ~stop_signal ~on_level:_ ->
          Eio.Promise.await stop_signal;
          Error "stopped");
      transcribe = (fun ~audio_path:_ -> Ok "hello");
      cleanup_audio = (fun ~audio_path:_ -> ());
    }
  in
  let cli : Cli_args.config =
    {
      scheme = "http";
      host = "127.0.0.1";
      port = 8935;
      base_path = "/tmp";
      workspace = "test";
      theme = Theme.Midnight;
      lang = Say.Lang_en;
      theme_explicit = false;
      lang_explicit = false;
      auto_start = false;
    }
  in
  (* Run executor inside a nested switch to verify clean cancellation teardown. *)
  (match
     Eio.Switch.run (fun exec_sw ->
         let exec =
           Cmd_executor.create ~sw:exec_sw ~io ~worker ~clock ~cli ~bus
             ~bearer_token:(Some "tok-1") ~voice_backend:fake_voice
             ~on_quit:(fun r -> quit_seen := Some r)
             ~on_restart:(fun () -> restart_seen := true)
             ()
         in
         Cmd_executor.execute_all exec
           [
             Cmd.Update_workspace_guard
               { instance_id = Some "inst-1"; workspace_sha256 = Some "ws-1" };
             Cmd.Start_local_server;
             Cmd.Voice_cmd Cmd.Probe_capabilities;
             Cmd.Restart_tui;
             Cmd.Quit Exit_reason.Quit_key;
           ];
         let ep = Cmd_executor.current_endpoint exec in
         Alcotest.(check (option string)) "guard instance updated"
           (Some "inst-1") ep.guard.expected_instance;
         Alcotest.(check (option string)) "guard workspace updated"
           (Some "ws-1") ep.guard.expected_workspace;
         Alcotest.(check bool) "restart callback fired" true !restart_seen;
         (match !quit_seen with
         | Some Exit_reason.Quit_key -> ()
         | Some _ | None -> Alcotest.fail "expected Quit_key callback");
         (* Allow forked voice probe fiber to publish onto Ui_bus. *)
         Eio.Time.sleep clock 0.02;
         let items = Ui_bus.drain bus in
         let saw_start_err = ref false in
         let saw_voice_caps = ref false in
         List.iter
           (fun item ->
             match item with
             | Ui_bus.Stream_event msg -> (
                 match msg with
                 | Msg.Server_start_result (Error _) -> saw_start_err := true
                 | Msg.Voice_event
                     (Msg.Voice_capabilities { stt_available = true; _ }) ->
                     saw_voice_caps := true
                 | Msg.Server_start_result (Ok _)
                 | Msg.Voice_event
                     ( Msg.Voice_capabilities { stt_available = false; _ }
                     | Msg.Voice_started
                     | Msg.Voice_level _
                     | Msg.Voice_transcribing
                     | Msg.Voice_idle
                     | Msg.Voice_transcript _
                     | Msg.Voice_failed _ )
                 | Msg.Boot
                 | Msg.Key_event _
                 | Msg.Paste_text _
                 | Msg.Mouse_event _
                 | Msg.Resize _
                 | Msg.Tick _
                 | Msg.Server_health_result _
                 | Msg.Http_reply _
                 | Msg.Sse_event _
                 | Msg.Sse_freshness _
                 | Msg.Chat_stream_chunk _
                 | Msg.Chat_stream_done _
                 | Msg.Chat_stream_decode_warning _
                 | Msg.Memory_diagram_rendered _
                 | Msg.Github_login_chunk _
                 | Msg.Github_login_done _
                 | Msg.Setup_login_output _
                 | Msg.Setup_login_input_ready _
                 | Msg.Stream_gap _ ->
                     ())
             | Ui_bus.Snapshot _ | Ui_bus.Stream_gap _ -> ())
           items;
         Alcotest.(check bool) "auto-start disabled error delivered" true
           !saw_start_err;
         Alcotest.(check bool) "voice capabilities delivered" true
           !saw_voice_caps;
         Alcotest.(check bool) "wake callback triggered" true
           (Atomic.get woken > 0);
         (* Start an active PTT recording fiber, then cancel exec_sw to verify
            cancellation propagates cleanly without deadlock or swallowed Cancelled. *)
         Cmd_executor.execute exec
           (Cmd.Voice_cmd (Cmd.Start_ptt { device = None }));
         Eio.Fiber.yield ();
         Cmd_executor.shutdown exec;
         Eio.Switch.fail exec_sw Exit)
   with
  | () -> Alcotest.fail "expected switch cancellation with Exit"
  | exception Exit -> ())

let test_remote_editor_escape_hatch_blocked () =
  (* 1. Pure loopback host check. *)
  List.iter
    (fun h ->
      Alcotest.(check bool) ("local host " ^ h) true
        (Cmd_executor.is_local_host h))
    [ "127.0.0.1"; "localhost"; "LOCALHOST"; "::1"; "[::1]"; "  127.0.0.1  " ];
  List.iter
    (fun h ->
      Alcotest.(check bool) ("remote host " ^ h) false
        (Cmd_executor.is_local_host h))
    [ "remote.example"; "10.0.0.5"; "192.168.1.20"; ""; "127.0.0.2" ];

  (* 2. Remote --url session refuses Edit_runtime_toml and Edit_keeper_toml
     without invoking terminal handoff or touching any local TOML file. *)
  let tmp = make_temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf tmp)
    (fun () ->
      let remote_cli =
        match
          Cli_args.parse ~env:empty_env ~cwd:tmp
            [
              "--url";
              "https://remote.example:8935";
              "--base-path";
              tmp;
              "--lang";
              "en";
              "--no-auto-start";
            ]
        with
        | Cli_args.Run cfg -> cfg
        | Cli_args.Info _ | Cli_args.Parse_error _ ->
            Alcotest.fail "expected valid remote Cli_args.Run config"
      in
      let pause_calls = ref 0 in
      let resume_calls = ref 0 in
      let handoff : Cmd_executor.editor_handoff =
        {
          pause_terminal = (fun () -> incr pause_calls);
          resume_terminal = (fun () -> incr resume_calls);
        }
      in
      let fake_voice : Voice_runner.backend =
        {
          probe =
            (fun () ->
              Ok
                {
                  recorder_available = false;
                  recorder_cmd = None;
                  stt_available = false;
                });
          record_until_stopped =
            (fun ~device:_ ~stop_signal ~on_level:_ ->
              Eio.Promise.await stop_signal;
              Error "stopped");
          transcribe = (fun ~audio_path:_ -> Error "unused");
          cleanup_audio = (fun ~audio_path:_ -> ());
        }
      in
      let drained =
        Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw ->
        let clock = Eio.Stdenv.clock env in
        let io = Io_domain.start ~sw ~env in
        let worker = Worker_pool.create ~sw (Eio.Stdenv.domain_mgr env) in
        let bus = Cmd_executor.create_bus () in
        let exec =
          Cmd_executor.create ~sw ~io ~worker ~clock ~cli:remote_cli ~bus
            ~bearer_token:None ~voice_backend:fake_voice ~editor_handoff:handoff
            ~on_quit:(fun _ -> ()) ~on_restart:(fun () -> ()) ()
        in
        Cmd_executor.execute exec
          (Cmd.Open_editor_escape_hatch Cmd.Edit_runtime_toml);
        Cmd_executor.execute exec
          (Cmd.Open_editor_escape_hatch (Cmd.Edit_keeper_toml "alpha"));
        let items = Ui_bus.drain bus in
        Cmd_executor.shutdown exec;
        items
      in
      Alcotest.(check int) "editor pause_terminal never called" 0 !pause_calls;
      Alcotest.(check int) "editor resume_terminal never called" 0 !resume_calls;
      let runtime_path =
        Option.get
          (Cmd_executor.editor_file_path ~base_path:tmp Cmd.Edit_runtime_toml)
      in
      let keeper_path =
        Option.get
          (Cmd_executor.editor_file_path ~base_path:tmp
             (Cmd.Edit_keeper_toml "alpha"))
      in
      Alcotest.(check bool) "local runtime.toml not created" false
        (Sys.file_exists runtime_path);
      Alcotest.(check bool) "local keeper toml not created" false
        (Sys.file_exists keeper_path);
      let blocked_msgs =
        List.filter_map
          (function
            | Ui_bus.Stream_event msg -> (
                match msg with
                | Msg.Http_reply { reply; _ } -> (
                    match[@warning "-4"] reply with
                    | Msg.Reply_action_ack
                        {
                          label;
                          ack_scope = _;
                          for_modal = None;
                          result = Error (Msg.Transport (Health.Other_io detail));
                        } ->
                        Some (label, detail, msg)
                    | _ -> None)
                | Msg.Boot
                | Msg.Key_event _
                | Msg.Paste_text _
                | Msg.Mouse_event _
                | Msg.Resize _
                | Msg.Tick _
                | Msg.Server_health_result _
                | Msg.Server_start_result _
                | Msg.Sse_event _
                | Msg.Sse_freshness _
                | Msg.Chat_stream_chunk _
                | Msg.Chat_stream_done _
                | Msg.Chat_stream_decode_warning _
                | Msg.Memory_diagram_rendered _
                | Msg.Github_login_chunk _
                | Msg.Github_login_done _
                | Msg.Setup_login_output _
                | Msg.Setup_login_input_ready _
                | Msg.Voice_event _
                | Msg.Stream_gap _ ->
                    None)
            | Ui_bus.Snapshot _ | Ui_bus.Stream_gap _ -> None)
          drained
      in
      Alcotest.(check int) "both TOML targets emitted blocked ack" 2
        (List.length blocked_msgs);
      List.iter
        (fun (label, detail, msg) ->
          let en_label = Say.resolve Say.Lang_en label in
          Alcotest.(check bool) "detail mentions Remote server attached" true
            (contains_substring ~needle:"Remote server attached" detail);
          Alcotest.(check bool) "detail mentions /api/v1/config/patch" true
            (contains_substring ~needle:"/api/v1/config/patch" detail);
          Alcotest.(check bool) "toast label mentions /api/v1/config/patch" true
            (contains_substring ~needle:"/api/v1/config/patch" en_label);
          let m0 = Model.initial ~lang:Say.Lang_en () in
          let m1, _ = Update.step ~now:Clock.Mono.zero m0 msg in
          match m1.toast with
          | Some toast ->
              Alcotest.(check bool) "store toast carries remote blocked notice"
                true
                (contains_substring ~needle:"/api/v1/config/patch"
                   (Say.resolve Say.Lang_en toast.message))
          | None -> Alcotest.fail "expected error toast on blocked remote $EDITOR")
        blocked_msgs);

  (* 3. Settings Target_keeper_create + Open_external refuses cleanly with a
     toast instead of falling back to Edit_runtime_toml. *)
  let m0 = Model.initial ~lang:Say.Lang_en () in
  let m_settings =
    {
      m0 with
      nav = { m0.nav with overlay = Some (Nav.Settings Nav.Settings_keepers_companies) };
      config =
        Config_store.set_target Masc_tui_protocol.Wire_config.Target_keeper_create
          m0.config;
    }
  in
  let m_after, cmds =
    Update.execute_action ~now:Clock.Mono.zero m_settings
      Masc_tui_keymap.Keymap.Open_external
  in
  Alcotest.(check int) "no editor command emitted for Target_keeper_create" 0
    (List.length cmds);
  match m_after.toast with
  | Some toast ->
      Alcotest.(check bool) "warning toast directs to Settings UI" true
        (contains_substring ~needle:"Settings"
           (Say.resolve Say.Lang_en toast.message))
  | None ->
      Alcotest.fail
        "expected warning toast when Open_external pressed on Target_keeper_create"

let with_loopback_executor ?stream_capacity ~respond run =
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn env#clock 5. @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let listener = Eio.Net.listen ~sw ~backlog:4 env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr listener with
    | `Tcp (_, port) -> port | `Unix _ -> Alcotest.fail "expected TCP listener" in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec accept () =
      Eio.Net.accept_fork ~sw listener
        ~on_error:(function End_of_file -> () | exn -> raise exn) (fun flow _ ->
        let reader = Eio.Buf_read.of_flow flow ~max_size:4096 in
        let request = Eio.Buf_read.line reader in
        let headers = Eio.Buf_read.lines reader |> Seq.take_while (fun s -> s <> "") |> List.of_seq in
        let length = headers |> List.find_map (fun header ->
          match String.split_on_char ':' (String.lowercase_ascii header) with
          | ["content-length"; n] -> int_of_string_opt (String.trim n) | _ -> None) in
        Option.iter (fun n -> ignore (Eio.Buf_read.take n reader : string)) length;
        let status, body = match String.split_on_char ' ' request with
          | [meth; path; _] -> respond ~meth ~path
          | _ -> Alcotest.failf "unexpected HTTP request %s" request in
        let raw = Yojson.Safe.to_string body in
        Eio.Flow.copy_string (Printf.sprintf
          "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
          status (if status = 200 then "OK" else "Unavailable") (String.length raw) raw) flow);
      accept () in
    accept ());
  let cli = match Cli_args.parse ~env:empty_env ~cwd:"/tmp" ["--port"; string_of_int port; "--no-auto-start"] with
    | Cli_args.Run cli -> cli | _ -> Alcotest.fail "expected fixture endpoint" in
  let io = Io_domain.start ~sw ~env in
  let worker = Worker_pool.create ~sw env#domain_mgr in
  let bus = Cmd_executor.create_bus ?stream_capacity () in
  let exec = Cmd_executor.create ~sw ~io ~worker ~clock:env#clock ~cli ~bus ~bearer_token:None
    ~on_quit:ignore ~on_restart:ignore () in
  Fun.protect ~finally:(fun () -> Cmd_executor.shutdown exec) (fun () -> run env#clock bus exec)

let test_tool_series_readers_each_receive_the_latest_reply () =
  let raw = Cmd.Get_tool_series { bucket = `Hour; since_hours = 24 } in
  let summary = Cmd.Get_tool_series_filtered { bucket = `Hour; since_hours = 24; tool = None } in
  let path = Cmd.get_request_path raw in
  Alcotest.(check string) "the two decoders read the same URL" path (Cmd.get_request_path summary);
  let first, first_arrived = Eio.Promise.create () and second, second_arrived = Eio.Promise.create () in
  let release_raw, finish_raw = Eio.Promise.create () and release_summary, finish_summary = Eio.Promise.create () in
  let calls = ref 0 in
  let respond ~meth ~path:received =
    Alcotest.(check string) "GET" "GET" meth;
    Alcotest.(check string) "shared URL" path received;
    incr calls;
    let generation = !calls in
    (match generation with
     | 1 -> Eio.Promise.resolve first_arrived (); Eio.Promise.await release_raw
     | 2 -> Eio.Promise.resolve second_arrived (); Eio.Promise.await release_summary
     | _ -> ());
    200, `Assoc [ "generated_at", `Float (Float.of_int generation); "bucket", `String "hour";
                  "buckets", `List [`Assoc ["start", `Int 0; "call_count", `Int 0; "failure_count", `Int 0]] ] in
  with_loopback_executor ~respond @@ fun clock bus exec ->
  let get req = Cmd_executor.execute exec (Cmd.Http_get {epoch = Epoch.initial; req}) in
  let rec wait_for_publications n =
    let stats = Ui_bus.stats bus in
    if stats.queued_snapshots + stats.total_coalesced_snapshots < n then
      (Eio.Time.sleep clock 0.001; wait_for_publications n) in
  get raw; Eio.Promise.await first;
  get summary; Eio.Promise.await second;
  List.iter get [raw; raw; summary; summary];
  Eio.Promise.resolve finish_raw (); wait_for_publications 2;
  Eio.Promise.resolve finish_summary (); wait_for_publications 4;
  Alcotest.(check int) "one original and one follow-up per decoder" 4 !calls;
  let replies = Ui_bus.drain bus |> List.filter_map (function
    | Ui_bus.Snapshot (_, Msg.Http_reply {reply = Msg.Reply_tool_series (Ok s); _}) ->
      Some ("raw", s.generated_at_unix)
    | Ui_bus.Snapshot (_, Msg.Http_reply {reply = Msg.Reply_tool_series_summary {result = Ok s; _}; _}) ->
      Some ("summary", s.series.generated_at_unix)
    | _ -> None) in
  Alcotest.(check (list (pair string (float 0.)))) "both latest replies survive until the first drain"
    ["raw", 3.; "summary", 4.] replies

let test_board_replies_survive_epoch_change_and_stream_overflow () =
  let module Q = Board_quarantine in
  let keeper = "alpha" in
  let item : Q.inventory_item =
    { keeper_name = keeper; partition_id = "p"; candidate_id = "candidate/a";
      quarantine_id = "generation/b"; phase = Q.Inventory_quarantined;
      failure_category = Q.Exact_lane_exhausted; attempt_provenance = None;
      quarantined_at = 1.; requested_at = None; requeued_at = None; requested_by = None } in
  let inventory = Q.inventory_to_json { items = [item]; errors = [] } in
  let receipt = `Assoc [
    "schema", `String Q.result_schema; "ok", `Bool true; "keeper_name", `String keeper;
    "partition_id", `String item.partition_id; "candidate_id", `String item.candidate_id;
    "quarantine_id", `String item.quarantine_id; "failure_category", `String "exact_lane_exhausted";
    "decision", `String "acknowledge_and_requeue"; "wake", `String "not_registered";
    "audit", `Assoc ["recorded", `Bool true]] in
  let respond ~meth ~path:_ = 200, (if meth = "POST" then receipt else inventory) in
  with_loopback_executor ~stream_capacity:1 ~respond @@ fun clock bus exec ->
  let dispatch count cmd =
    Cmd_executor.execute exec cmd;
    let rec wait () =
      let s = Ui_bus.stats bus in
      if s.queued_snapshots + s.total_coalesced_snapshots + s.queued_stream_events < count then
        (Eio.Time.sleep clock 0.001; wait ()) in
    wait () in
  let old = Epoch.initial and current = Epoch.next Epoch.initial in
  let read epoch = Cmd.Http_get { epoch; req = Cmd.Get_board_quarantines { keeper; generation = 1 } } in
  dispatch 1 (read current);
  dispatch 2 (read old);
  dispatch 3 (Cmd.Http_post { epoch = current; req = Cmd.Post_board_recovery item });
  Ui_bus.publish_stream bus (Msg.Stream_gap 1);
  Ui_bus.publish_stream bus (Msg.Stream_gap 1);
  let messages = Ui_bus.drain bus in
  let reads = List.filter_map (function
    | Ui_bus.Snapshot (_, Msg.Http_reply { epoch; reply = Msg.Reply_board_quarantines
        { generation = 1; result = Ok { items = [_]; errors = [] }; _ } }) -> Some (Epoch.to_int epoch)
    | _ -> None) messages |> List.sort Int.compare in
  Alcotest.(check (list int)) "equal read generations from both workspaces survive"
    [Epoch.to_int old; Epoch.to_int current] reads;
  Alcotest.(check bool) "one terminal receipt survives a full stream ring" true
    (List.exists (function Ui_bus.Snapshot (_, Msg.Http_reply { epoch; reply = Msg.Reply_board_recovery
      { item = actual; result = Ok { wake = Q.Not_registered; audit = Q.Recorded } } }) ->
        Epoch.equal epoch current && Q.same_candidate actual item | _ -> false) messages);
  Alcotest.(check int) "one stream event was evicted" 1 (Ui_bus.stats bus).total_dropped_stream_events

let test_queue_drawer_walks_all_http_pages () =
  let alpha = "alpha" and beta = "beta" in
  let start keeper = "/api/v1/keepers/" ^ keeper ^ "/chat/operations?state=queued" in
  let after keeper sequence = start keeper ^ "&after_sequence=" ^ string_of_int sequence in
  let operation prefix number sequence =
    `Assoc ["operation_id", `String (Printf.sprintf "%s-%d" prefix number);
            "sequence", `String (string_of_int sequence); "state", `String "Queued";
            "input", `Assoc ["message", `String "queued input"]] in
  let page ?(running_batch = `Null) rows =
    `Assoc ["schema", `String "masc.keeper_chat_operations.list.v1"; "state", `String "Queued";
            "operations", `List rows; "running_batch", running_batch] in
  let running_batch = `Assoc ["execution_id", `String "alpha-batch"; "member_count", `Int 2] in
  let first_page = List.init 100 (fun n -> operation alpha (n + 1) (n + 1)) in
  (* Operation 2 moves to the tail after the first page was read. *)
  let next_page = [operation alpha 101 101; operation alpha 102 102; operation alpha 103 103;
                   operation alpha 2 104] in
  let expected_first = List.init 100 (fun i -> Printf.sprintf "alpha-%d" (i + 1)) in
  let expected_all =
    List.filter ((<>) "alpha-2") expected_first @ ["alpha-101"; "alpha-102"; "alpha-103"; "alpha-2"] in
  let seen = ref [] and alpha_reads = ref 0 in
  let held, hold = Eio.Promise.create () and release, resume = Eio.Promise.create () in
  let respond ~meth ~path =
    if meth <> "GET" then Alcotest.failf "unexpected HTTP method %s" meth;
    seen := path :: !seen;
    if path = start alpha then (incr alpha_reads; 200, page ~running_batch first_page)
    else if path = after alpha 100 then
      (match !alpha_reads with
       | 1 -> 503, `Assoc []
       | 2 -> Eio.Promise.resolve hold (); Eio.Promise.await release; 503, `Assoc []
       | _ -> 200, page next_page)
    else if path = after alpha 104 then 200, page []
    else if path = start beta then 200, page [operation beta 1 1]
    else if path = after beta 1 then 200, page []
    else Alcotest.failf "unexpected queue path %s" path in
  with_loopback_executor ~respond @@ fun clock bus exec ->
  let model = ref (Model.initial ()) in
  let dispatch keeper action =
    let m = { !model with drafts = Drafts.set_active_keeper keeper !model.drafts } in
    let next, cmds = Update.execute_action ~now:(Clock.Mono.now ()) m action in
    model := next;
    match List.filter (function Cmd.Http_get { req = Cmd.Get_chat_queue { keeper = k }; _ } ->
               String.equal k keeper | _ -> false) (Cmd.flatten cmds) with
    | [cmd] -> Cmd_executor.execute exec cmd
    | _ -> Alcotest.fail "expected the drawer to issue one queue read" in
  let rec await_reply keeper accept =
    let found = List.fold_left (fun found -> function
      | Ui_bus.Snapshot (_, (Msg.Http_reply { reply = Msg.Reply_chat_queue r; _ } as msg)) ->
          let next, _ = Update.step ~now:(Clock.Mono.now ()) !model msg in
          model := next; (String.equal keeper r.keeper && accept r.result) || found
      | _ -> found) false (Ui_bus.drain bus) in
    if not found then (Eio.Time.sleep clock 0.001; await_reply keeper accept) in
  let queue keeper = fst (Model.drawer_queue ~keeper !model) in
  let ids keeper = List.map (fun (row : Masc_tui_protocol.Wire_fleet.chat_operation) ->
      Keeper_chat_operation.Operation_id.to_string row.id) (queue keeper).operations in
  let complete = function Some (Ok ()) -> true | _ -> false in
  let failed = function Some (Error (Msg.Http_error {status=503; _})) -> true | _ -> false in
  dispatch alpha Masc_tui_keymap.Keymap.Open_queue_context;
  await_reply alpha failed;
  Alcotest.(check (list string)) "a second-page error retains every first-page id" expected_first (ids alpha);
  let batch keeper =
    Option.map (fun (batch : Masc_tui_protocol.Wire_fleet.running_chat_batch) ->
        (Keeper_chat_operation.Operation_id.to_string batch.execution_id, batch.member_count))
      (queue keeper).running_batch
  in
  Alcotest.(check (option (pair string int))) "a partial reply retains the first-page execution"
    (Some ("alpha-batch", 2)) (batch alpha);
  Alcotest.(check bool) "the partial inventory remains explicitly failed" true
    (match (queue alpha).read with Observed.Failed { retryable = true; _ } -> true | _ -> false);
  dispatch alpha Masc_tui_keymap.Keymap.Refresh;
  Eio.Promise.await held;
  await_reply alpha Option.is_none;
  dispatch beta Masc_tui_keymap.Keymap.Refresh;
  await_reply beta complete;
  Alcotest.(check (list string)) "another Keeper receives its own inventory" ["beta-1"] (ids beta);
  dispatch alpha Masc_tui_keymap.Keymap.Refresh;
  await_reply alpha complete;
  Alcotest.(check (list string)) "all 103 durable ids include the operation moved across pages once"
    expected_all (ids alpha);
  Alcotest.(check (option (pair string int))) "later pages preserve the first-page execution"
    (Some ("alpha-batch", 2)) (batch alpha);
  Alcotest.(check (option (pair string int))) "running batch belongs to the requested Keeper"
    None (batch beta);
  Eio.Promise.resolve resume ();
  await_reply alpha failed;
  Alcotest.(check bool) "an older deferred failure leaves the newer complete read intact" true
    (Observed.to_option (queue alpha).read = Some () && ids alpha = expected_all);
  Alcotest.(check (list string)) "refreshing alpha preserves beta" ["beta-1"] (ids beta);
  Alcotest.(check (list string)) "the actual HTTP requests advance by returned sequence and refresh from the beginning"
    [start alpha; after alpha 100; start alpha; after alpha 100; start beta; after beta 1;
     start alpha; after alpha 100; after alpha 104] (List.rev !seen)

let test_bus_key_hash_and_stream_frames () =
  (* P1-1: equal Stream_logs keys with differing since_seq MUST hash identically
     and coalesce in Ui_bus. *)
  let k1 = Cmd_executor.Key_freshness (Subscriptions.Stream_logs { since_seq = None }) in
  let k2 = Cmd_executor.Key_freshness (Subscriptions.Stream_logs { since_seq = Some 42 }) in
  Alcotest.(check bool) "Stream_logs keys equal" true
    (Cmd_executor.equal_bus_key k1 k2);
  Alcotest.(check int) "Stream_logs hashes equal"
    (Cmd_executor.hash_bus_key k1)
    (Cmd_executor.hash_bus_key k2);
  let bus = Cmd_executor.create_bus () in
  Ui_bus.publish_snapshot bus ~key:k1
    (Msg.Sse_freshness
       {
         epoch = Epoch.initial;
         stream = Subscriptions.Stream_logs { since_seq = None };
         freshness = Health.Connecting;
       });
  Ui_bus.publish_snapshot bus ~key:k2
    (Msg.Sse_freshness
       {
         epoch = Epoch.initial;
         stream = Subscriptions.Stream_logs { since_seq = Some 42 };
         freshness = Health.Live { last_event_ns = Clock.Mono.zero; revision = 5 };
       });
  Alcotest.(check int) "coalesced to 1 snapshot" 1 (List.length (Ui_bus.drain bus));

  (* /api/v1/dashboard/logs/stream sends newest-first batch frames
     {"reset": true, "entries": [seq=2, seq=1]}; the frame reaches the store
     whole, reset flag included. *)
  let batch_json =
    {|{"reset":true,"entries":[{"seq":2,"ts":"2026-11-22T00:00:02Z","level":"WARN","source":"server","module":"Http","message":"second"},{"seq":1,"ts":"2026-11-22T00:00:01Z","level":"INFO","source":"server","module":"Http","message":"first"}]}|}
  in
  let log_msgs =
    Cmd_executor.decode_hub_event_msgs ~epoch:Epoch.initial
      ~observed_at:Clock.Mono.zero
      (Sse_hub.Raw_frame
         {
           stream = Sse_hub.Stream_spec.Logs { since_seq = None };
           frame = { Sse_wire.id = None; data = batch_json };
         })
  in
  let seqs =
    List.filter_map
      (fun (key_opt, msg) ->
        match key_opt, msg with
        | ( None
          , Msg.Sse_event
              { event = Msg.Sse_log_frame { reset = true; entries }; _ } ) ->
            Some
              (List.map
                 (fun (e : Masc_tui_protocol.Wire_infra.system_log_entry) -> e.seq)
                 entries)
        | None, Msg.Sse_event { event = Msg.Sse_log_frame { reset = false; _ }; _ }
          ->
            None
        | Some _, _ -> None
        | ( None
          , ( Msg.Sse_event
                {
                  event =
                    ( Msg.Sse_observer_handshake _
                    | Msg.Sse_observer_delivery _
                    | Msg.Sse_fleet _
                    | Msg.Sse_models_metrics_snapshot _
                    | Msg.Sse_tool_series _ );
                  _;
                }
            | Msg.Boot
            | Msg.Key_event _
            | Msg.Paste_text _
            | Msg.Mouse_event _
            | Msg.Resize _
            | Msg.Tick _
            | Msg.Server_health_result _
            | Msg.Server_start_result _
            | Msg.Http_reply _
            | Msg.Sse_freshness _
            | Msg.Chat_stream_chunk _
            | Msg.Chat_stream_done _
            | Msg.Chat_stream_decode_warning _
            | Msg.Memory_diagram_rendered _
            | Msg.Github_login_chunk _
            | Msg.Github_login_done _
            | Msg.Setup_login_output _
            | Msg.Setup_login_input_ready _
            | Msg.Voice_event _
            | Msg.Stream_gap _ ) ) ->
            None)
      log_msgs
  in
  Alcotest.(check (list (list int))) "one reset frame, newest first" [ [ 2; 1 ] ]
    seqs;

  (* A model metrics frame for another window (the server's unbucketed
     30-minute default) never replaces the 24h chart and is reported as a
     skipped frame instead of vanishing. *)
  let model_metrics_agg =
    {|{"window_minutes":30,"bucket_minutes":0,"total_entries":0,"total_error_entries":0,"models":[]}|}
  in
  let agg_msgs =
    Cmd_executor.decode_hub_event_msgs ~epoch:Epoch.initial
      ~observed_at:Clock.Mono.zero
      (Sse_hub.Raw_frame
         {
           stream = Sse_hub.Stream_spec.Model_metrics;
           frame = { Sse_wire.id = None; data = model_metrics_agg };
         })
  in
  Alcotest.(check bool) "other-window model metrics frame is reported, not applied" true
    (match agg_msgs with
    | [ ( None
        , Msg.Sse_event
            {
              event =
                Msg.Sse_observer_delivery
                  { decoded = Masc_tui_protocol.Wire_observer.Undecodable _; _ };
              _;
            } ) ] ->
        true
    | _ -> false);

  (* The tool series stream answers a failed read with {"error": detail} and
     ends; the skipped frame names the server's detail. *)
  let tool_error_msgs =
    Cmd_executor.decode_hub_event_msgs ~epoch:Epoch.initial
      ~observed_at:Clock.Mono.zero
      (Sse_hub.Raw_frame
         {
           stream = Sse_hub.Stream_spec.Tool_metrics_series;
           frame =
             { Sse_wire.id = None; data = {|{"error":"metrics store locked"}|} };
         })
  in
  Alcotest.(check bool) "tool series error frame names the server's detail" true
    (match tool_error_msgs with
    | [ ( None
        , Msg.Sse_event
            {
              event =
                Msg.Sse_observer_delivery
                  { decoded = Masc_tui_protocol.Wire_observer.Undecodable reason; _ };
              _;
            } ) ] ->
        String.equal reason "tool series stream: metrics store locked"
    | _ -> false);

  (* v2.5: bucketed model metrics SSE frame decodes into Sse_models_metrics_snapshot *)
  let model_metrics_bucketed =
    {|{"window_minutes":1440,"bucket_minutes":60,"total_entries":10,"total_error_entries":0,"models":[]}|}
  in
  let bucket_msgs =
    Cmd_executor.decode_hub_event_msgs ~epoch:Epoch.initial
      ~observed_at:Clock.Mono.zero
      (Sse_hub.Raw_frame
         {
           stream = Sse_hub.Stream_spec.Model_metrics;
           frame = { Sse_wire.id = None; data = model_metrics_bucketed };
         })
  in
  Alcotest.(check int) "bucketed model metrics frame emits 1 msg" 1
    (List.length bucket_msgs);
  (match snd (List.hd bucket_msgs) with
  | Msg.Sse_event
      {
        event =
          Msg.Sse_models_metrics_snapshot
            { window_minutes = 1440; bucket_minutes = 60; _ };
        _;
      } ->
      ()
  | Msg.Sse_event
      {
        event =
          ( Msg.Sse_models_metrics_snapshot _
          | Msg.Sse_observer_handshake _
          | Msg.Sse_observer_delivery _
          | Msg.Sse_fleet _
          | Msg.Sse_tool_series _
          | Msg.Sse_log_frame _ );
        _;
      }
  | Msg.Boot
  | Msg.Key_event _
  | Msg.Paste_text _
  | Msg.Mouse_event _
  | Msg.Resize _
  | Msg.Tick _
  | Msg.Server_health_result _
  | Msg.Server_start_result _
  | Msg.Http_reply _
  | Msg.Sse_freshness _
  | Msg.Chat_stream_chunk _
  | Msg.Chat_stream_done _
  | Msg.Chat_stream_decode_warning _
  | Msg.Memory_diagram_rendered _
  | Msg.Github_login_chunk _
  | Msg.Github_login_done _
  | Msg.Setup_login_output _
  | Msg.Setup_login_input_ready _
  | Msg.Voice_event _
  | Msg.Stream_gap _ ->
      Alcotest.fail "expected Sse_models_metrics_snapshot");

  (* P1-6: /health readiness check distinguishes ready=false from ready=true. *)
  Alcotest.(check bool) "health ready=false is not ready" false
    (Cmd_executor.is_health_body_ready
       {|{"ok":true,"ready":false,"status":"starting","version":"0.1.0"}|});
  Alcotest.(check bool) "health ok=false is not ready" false
    (Cmd_executor.is_health_body_ready
       {|{"ok":false,"ready":true,"status":"degraded","version":"0.1.0"}|});
  Alcotest.(check bool) "health ok=true ready=true is ready" true
    (Cmd_executor.is_health_body_ready
       {|{"ok":true,"ready":true,"status":"ok","version":"0.1.0"}|})

let test_setup_login_stream_error_and_single_delivery () =
  let sse_frame json = "data: " ^ json ^ "\n\n" in
  let running_json =
    {|{"login_id":"login-001","integration_id":"vibe_acp","status":"running","account":"keyring_host"}|}
  in
  let complete_json =
    {|{"login_id":"login-001","integration_id":"vibe_acp","status":"complete","account":"keyring_host","authentication":"login_completed"}|}
  in
  let failed_json =
    {|{"login_id":"login-001","integration_id":"vibe_acp","status":"failed"}|}
  in
  let collect ~stream =
    let emitted = ref [] in
    Cmd_executor.run_setup_login_stream
      ~on_interrupted:(fun ~login_id:_ err -> emitted := Error err :: !emitted)
      ~publish:(fun res -> emitted := res :: !emitted)
      ~stream ();
    List.rev !emitted
  in
  (* 1. SSE error after non-terminal "running" receipt MUST propagate Error *)
  let err_after_running =
    collect ~stream:(fun ~on_chunk ->
        on_chunk (sse_frame running_json);
        Error (Msg.Transport (Health.Other_io "connection reset")))
  in
  Alcotest.(check int) "running + stream error emits 2 events" 2
    (List.length err_after_running);
  (match err_after_running with
  | [ Ok r; Error (Msg.Transport (Health.Other_io msg)) ] ->
      Alcotest.(check string) "first event is running receipt" "running" r.status;
      Alcotest.(check string) "second event propagates stream error"
        "connection reset" msg
  | _ ->
      Alcotest.fail
        "expected [Ok running; Error Transport] when SSE drops after running");
  (* 2. Normal "running" -> "complete" stream emits "complete" EXACTLY ONCE *)
  let normal =
    collect ~stream:(fun ~on_chunk ->
        on_chunk (sse_frame running_json);
        on_chunk (sse_frame complete_json);
        Ok ())
  in
  Alcotest.(check int) "running -> complete emits exactly 2 events (no duplicate complete)" 2
    (List.length normal);
  (match normal with
  | [ Ok r1; Ok r2 ] ->
      Alcotest.(check string) "first is running" "running" r1.status;
      Alcotest.(check string) "second is complete" "complete" r2.status
  | _ -> Alcotest.fail "expected [Ok running; Ok complete]");
  (* 3. Terminal receipt followed by post-terminal transport error preserves terminal receipt once *)
  let after_terminal_err =
    collect ~stream:(fun ~on_chunk ->
        on_chunk (sse_frame running_json);
        on_chunk (sse_frame failed_json);
        Error (Msg.Transport Health.Stream_eof))
  in
  Alcotest.(check int) "terminal failed suppresses trailing EOF error" 2
    (List.length after_terminal_err);
  (match after_terminal_err with
  | [ Ok r1; Ok r2 ] ->
      Alcotest.(check string) "first is running" "running" r1.status;
      Alcotest.(check string) "second is terminal failed" "failed" r2.status
  | _ -> Alcotest.fail "expected [Ok running; Ok failed]");
  (* 4. Empty clean stream close emits Decode_error *)
  let empty_ok = collect ~stream:(fun ~on_chunk:_ -> Ok ()) in
  (match empty_ok with
  | [ Error (Msg.Decode_error _) ] -> ()
  | _ -> Alcotest.fail "expected single Decode_error on empty login stream")

let test_setup_login_interruption_closes_owned_input () =
  let now = Clock.Mono.zero in
  let initial = Model.initial () in
  let model = ref { initial with
      nav = { initial.nav with workspace = Nav.Runtime; sidebar_focused = false };
      runtime = Runtime_store.set_tab Nav.Runtime_quotas_credits initial.runtime } in
  let send msg = let next, _ = Update.step ~now !model msg in model := next in
  let reply msg = send (Msg.Http_reply { epoch = !model.epoch; reply = msg }) in
  let frames = ref [] in
  let interrupted ~login_id error =
    frames := (login_id, error) :: !frames;
    reply (Msg.Reply_setup_login_interrupted { login_id; error })
  in
  let on_input_ready ~login_id =
    send (Msg.Setup_login_input_ready { epoch = !model.epoch; login_id })
  in
  let input_is_open id =
    Option.equal Nav.equal_overlay !model.nav.overlay
      (Some (Nav.Inline_action (Nav.Setup_login_input_form { login_id = id })))
    && !model.runtime.setup_login_input_ready
  in
  let event name data = "event: " ^ name ^ "\ndata: " ^ data ^ "\n\n" in
  Cmd_executor.run_setup_login_stream ~on_interrupted:interrupted ~on_input_ready
    ~publish:(fun result -> reply (Msg.Reply_setup_login_receipt result))
    ~stream:(fun ~on_chunk ->
      on_chunk (event "started" {|{"login_id":"one","integration_id":"codex_cli","status":"running"}|});
      on_chunk "event: input_";
      on_chunk "ready\r\ndata: {}\r\n\r\n";
      let open Masc_tui_keymap.Keymap.Input in
      send (Msg.Key_event { key = Char "e"; mods = { ctrl = false; alt = false; shift = false } });
      Alcotest.(check bool) "the live login owns the input form" true (input_is_open "one");
      interrupted ~login_id:"older" (Msg.Transport Health.Stream_eof);
      Alcotest.(check bool) "a late interruption preserves another login's input" true (input_is_open "one");
      Ok ()) ();
  Alcotest.(check bool) "clean EOF emits one interruption for the observed login" true
    (!frames = [ ("one", Msg.Transport Health.Stream_eof); ("older", Msg.Transport Health.Stream_eof) ]);
  Alcotest.(check bool) "EOF clears input readiness and the owned modal" true
    (not !model.runtime.setup_login_input_ready && !model.inline_modal = None && !model.nav.overlay = None);
  Alcotest.(check bool) "EOF preserves the last server receipt" true
    (Option.fold ~none:false ~some:(fun (r : Masc_tui_protocol.Wire_runtime.setup_login_receipt) ->
      r.login_id = "one" && r.status = "running") !model.runtime.setup_login_receipt)

let test_setup_login_stream_output_auth_url_input_ready_and_oauth_tick_gate () =
  let sse_event name json = "event: " ^ name ^ "\ndata: " ^ json ^ "\n\n" in
  let started_json =
    {|{"login_id":"login-042","integration_id":"codex_cli","status":"running","account":"keyring_host"}|}
  in
  let complete_json =
    {|{"login_id":"login-042","integration_id":"codex_cli","status":"complete","account":"keyring_host","authentication":"login_completed"}|}
  in
  let receipts = ref [] in
  let outputs = ref [] in
  let inputs_ready = ref [] in
  Cmd_executor.run_setup_login_stream
    ~on_interrupted:(fun ~login_id:_ err -> receipts := Error err :: !receipts)
    ~on_output:(fun ~text ~auth_url ~device_code ->
      outputs := (text, auth_url, device_code) :: !outputs)
    ~on_input_ready:(fun ~login_id ->
      inputs_ready := login_id :: !inputs_ready)
    ~publish:(fun res -> receipts := res :: !receipts)
    ~stream:(fun ~on_chunk ->
      on_chunk (sse_event "started" started_json);
      on_chunk
        (sse_event "output"
           {|{"stream":"stdout","text":"\u001b[36mVisit https://auth.openai (split) HTTP-4000 2026-1124\u001b[0m"}|});
      on_chunk
        (sse_event "auth_url"
           {|{"login_id":"login-042","url":"https://auth.example.com/authorize?state=abc"}|});
      on_chunk
        (sse_event "device_code"
           {|{"login_id":"login-042","code":"ABCD-1234","verification_uri":"https://auth.example.com/verify"}|});
      on_chunk (sse_event "screen" {|{"text":"Paste code below:"}|});
      on_chunk (sse_event "input_ready" {|{"login_id":"login-042"}|});
      on_chunk (sse_event "complete" complete_json);
      Ok ()) ();
  let outputs = List.rev !outputs in
  let inputs_ready = List.rev !inputs_ready in
  let receipts = List.rev !receipts in
  Alcotest.(check int) "started + complete emit 2 receipts" 2
    (List.length receipts);
  Alcotest.(check int) "4 output/auth_url/device_code/screen events delivered" 4
    (List.length outputs);
  (match outputs with
  | [ (_, u1, c1); (_, u2, c2); (_, u3, c3); (t4, u4, c4) ] ->
      Alcotest.(check (option string))
        "raw output chunk does not race ?auth_hints=1 with half-URL scrape"
        None u1;
      Alcotest.(check (option string))
        "raw output chunk does not scrape unguarded device code" None c1;
      Alcotest.(check (option string)) "typed auth_url frame"
        (Some "https://auth.example.com/authorize?state=abc") u2;
      Alcotest.(check (option string)) "auth_url has no code" None c2;
      Alcotest.(check (option string)) "typed device_code verification_uri"
        (Some "https://auth.example.com/verify") u3;
      Alcotest.(check (option string)) "typed device_code code"
        (Some "ABCD-1234") c3;
      Alcotest.(check string) "screen text forwarded" "Paste code below:" t4;
      Alcotest.(check (option string)) "screen has no URL" None u4;
      Alcotest.(check (option string)) "screen has no code" None c4
  | _ -> Alcotest.fail "expected 4 output events");
  Alcotest.(check (list (option string))) "input_ready carries login_id"
    [ Some "login-042" ] inputs_ready;
  (* App.should_emit_tick: idle stays 0 Hz; active OAuth poll deadline wakes on time *)
  let t0 = 5_000_000_000L in
  let due_idle, dl_idle =
    App.should_emit_tick ~oauth_poll_deadline_ns:None ~now_ns:t0
      ~last_voice_tick_ns:0L ~toast_expires_ns:None ~voice_recording:false
  in
  Alcotest.(check bool) "idle oauth deadline emits no tick" false due_idle;
  Alcotest.(check (option int64)) "idle oauth deadline stays 0 Hz" None dl_idle;
  let future_dl = Int64.add t0 2_000_000_000L in
  let due_wait, dl_wait =
    App.should_emit_tick ~oauth_poll_deadline_ns:(Some future_dl) ~now_ns:t0
      ~last_voice_tick_ns:0L ~toast_expires_ns:None ~voice_recording:false
  in
  Alcotest.(check bool) "future oauth deadline does not emit immediately" false
    due_wait;
  Alcotest.(check (option int64)) "future oauth deadline scheduled"
    (Some future_dl) dl_wait;
  let due_now, dl_now =
    App.should_emit_tick ~oauth_poll_deadline_ns:(Some t0) ~now_ns:t0
      ~last_voice_tick_ns:0L ~toast_expires_ns:None ~voice_recording:false
  in
  Alcotest.(check bool) "elapsed oauth deadline emits tick immediately" true
    due_now;
  Alcotest.(check (option int64)) "elapsed oauth deadline consumed" None dl_now

let test_app_ctrl_c_and_voice_tick_gate () =
  (* P1-3: Kitty CSI u Ctrl+C (\x1b[99;5u) is recognized as Ctrl+C. *)
  let dec = Masc_tui_term.Input_decoder.create () in
  let events = Masc_tui_term.Input_decoder.feed_string dec "\x1b[99;5u" in
  let saw_ctrl_c =
    List.exists
      (function
        | Masc_tui_term.Input_decoder.Key kev -> App.is_ctrl_c kev
        | Masc_tui_term.Input_decoder.Paste _
        | Masc_tui_term.Input_decoder.Mouse _
        | Masc_tui_term.Input_decoder.Reply _
        | Masc_tui_term.Input_decoder.Unknown_escape
        | Masc_tui_term.Input_decoder.Invalid_utf8 ->
            false)
      events
  in
  Alcotest.(check bool) "Kitty CSI u Ctrl+C detected" true saw_ctrl_c;
  Alcotest.(check bool) "plain c is not Ctrl+C" false
    (App.is_ctrl_c
       {
         key = Masc_tui_term.Input_decoder.Char "c";
         mods = Masc_tui_term.Input_decoder.no_mods;
       });
  Alcotest.(check bool) "Ctrl+Shift+C is not Ctrl+C" false
    (App.is_ctrl_c
       {
         key = Masc_tui_term.Input_decoder.Char "c";
         mods = { ctrl = true; alt = false; shift = true };
       });

  (* P1-5: Voice recording ticks strictly at 100ms cadence; idle stays 0 Hz. *)
  let t0 = 1_000_000_000L in
  let emit_idle, dl_idle =
    App.should_emit_tick ~oauth_poll_deadline_ns:None ~now_ns:t0
      ~last_voice_tick_ns:0L ~toast_expires_ns:None ~voice_recording:false
  in
  Alcotest.(check bool) "idle emits no tick" false emit_idle;
  Alcotest.(check (option int64)) "idle has no deadline (0 Hz)" None dl_idle;
  let t_33ms = Int64.add t0 33_333_333L in
  let emit_33, dl_33 =
    App.should_emit_tick ~oauth_poll_deadline_ns:None ~now_ns:t_33ms
      ~last_voice_tick_ns:t0 ~toast_expires_ns:None ~voice_recording:true
  in
  Alcotest.(check bool) "no voice tick at +33ms" false emit_33;
  Alcotest.(check (option int64)) "next voice deadline at +100ms"
    (Some (Int64.add t0 App.voice_tick_interval_ns))
    dl_33;
  let t_100ms = Int64.add t0 App.voice_tick_interval_ns in
  let emit_100, dl_100 =
    App.should_emit_tick ~oauth_poll_deadline_ns:None ~now_ns:t_100ms
      ~last_voice_tick_ns:t0 ~toast_expires_ns:None ~voice_recording:true
  in
  Alcotest.(check bool) "voice tick fires at +100ms" true emit_100;
  Alcotest.(check (option int64)) "subsequent deadline at +200ms"
    (Some (Int64.add t_100ms App.voice_tick_interval_ns))
    dl_100;

  (* R2-P1-2: 1-minute wall-clock boundary scheduler preserves 0 Hz idle sleep *)
  let wall_sec12 = 1_795_252_092.0 in
  let cur_min = App.clock_minute_of_unix wall_sec12 in
  Alcotest.(check int64) "clock_minute_of_unix exact floor division"
    29_920_868L cur_min;
  let fire_same, min_same, dl_same =
    App.next_minute_tick ~now_ns:t0 ~wall_unix:wall_sec12 ~last_minute:cur_min
  in
  Alcotest.(check bool) "same minute emits no tick (0 Hz)" false fire_same;
  Alcotest.(check int64) "same minute keeps cur_min" cur_min min_same;
  let wait_same_ns = Int64.sub dl_same t0 in
  Alcotest.(check bool) "same minute sleeps ~48s until next :00 boundary" true
    (wait_same_ns >= 47_000_000_000L && wait_same_ns <= 49_000_000_000L);
  let wall_next_min = 1_795_252_140.1 in
  let fire_cross, min_cross, dl_cross =
    App.next_minute_tick ~now_ns:t0 ~wall_unix:wall_next_min
      ~last_minute:cur_min
  in
  Alcotest.(check bool) "crossing minute boundary fires wall-clock tick" true
    fire_cross;
  Alcotest.(check int64) "minute advances by 1" (Int64.succ cur_min) min_cross;
  let wait_cross_ns = Int64.sub dl_cross t0 in
  Alcotest.(check bool) "post-cross deadline sleeps ~60s until following :00" true
    (wait_cross_ns >= 59_000_000_000L && wait_cross_ns <= 61_000_000_000L)

let test_exit_line_fd_and_local_tz_offset () =
  let safe_close fd =
    match Unix.close fd with () -> () | exception Unix.Unix_error _ -> ()
  in
  let rd, wr = Unix.pipe () in
  Fun.protect
    ~finally:(fun () ->
      safe_close rd;
      safe_close wr)
    (fun () ->
      Unix.set_nonblock wr;
      App.write_exit_line_fd wr Exit_reason.Quit_key;
      safe_close wr;
      let buf = Bytes.create 128 in
      let n = Unix.read rd buf 0 (Bytes.length buf) in
      let got = Bytes.sub_string buf 0 n in
      Alcotest.(check string) "exit line written to caller stderr fd"
        "[masc-tui] exit: normal (quit key)\n" got);
  (* Broken pipe (closed reader) MUST NOT raise or terminate via SIGPIPE *)
  let rd_closed, wr_broken = Unix.pipe () in
  Fun.protect
    ~finally:(fun () ->
      safe_close rd_closed;
      safe_close wr_broken)
    (fun () ->
      safe_close rd_closed;
      App.write_exit_line_fd wr_broken Exit_reason.Quit_key);
  (* Planning enrichment propagates execution?light=true errors (never swallows) *)
  let obs_t0 = Clock.Mono.of_ns 1_000L in
  let sample_goal : Masc_tui_protocol.Wire_work.goal =
    {
      id = "g-1";
      title = "Goal";
      phase = Masc_tui_protocol.Wire_work.Executing;
      priority = 1;
      due_date = None;
      measure = "3 stack";
      procedure = "test";
      criterion_revision = Some "r1";
      criterion_verdict = Masc_tui_protocol.Wire_work.Criterion_valid;
      last_review_note = None;
      last_review_at = None;
      created_at = None;
      updated_at = None;
      linked_task_count = Observed.unreported;
    }
  in
  let empty_snap : Masc_tui_protocol.Wire_work.planning_snapshot =
    { goals = [ sample_goal ]; tasks = [] }
  in
  let mismatch_err =
    Msg.Workspace_mismatch
      {
        expected_instance = Some "srv-a";
        observed_instance = Some "srv-b";
        observed_workspace_sha256 = None;
        message = "changed";
      }
  in
  (match
     Cmd_executor.fetch_planning_with_tasks ~observed_at:obs_t0
       ~fetch_planning:(fun () -> Ok empty_snap)
       ~fetch_tasks:(fun () -> Error mismatch_err)
   with
  | Error (Msg.Workspace_mismatch { observed_instance = Some "srv-b"; _ }) -> ()
  | Ok _ | Error _ ->
      Alcotest.fail "expected Workspace_mismatch propagated from execution tasks");
  (match
     Cmd_executor.fetch_planning_with_tasks ~observed_at:obs_t0
       ~fetch_planning:(fun () -> Ok empty_snap)
       ~fetch_tasks:(fun () -> Error (Msg.Decode_error "drift"))
   with
  | Error (Msg.Decode_error "drift") -> ()
  | Ok _ | Error _ ->
      Alcotest.fail "expected Decode_error propagated from execution tasks");
  let task_1 : Masc_tui_protocol.Wire_work.task =
    {
      id = "t-1";
      title = "Task 1";
      description = None;
      priority = 1;
      status = Masc_tui_protocol.Wire_work.Todo;
      goal_link = Masc_tui_protocol.Wire_work.Linked "g-1";
      created_at = None;
      updated_at = None;
    }
  in
  (match
     Cmd_executor.fetch_planning_with_tasks ~observed_at:obs_t0
       ~fetch_planning:(fun () -> Ok empty_snap)
       ~fetch_tasks:(fun () -> Ok [ task_1 ])
   with
  | Ok enriched ->
      Alcotest.(check int) "enriched tasks count" 1 (List.length enriched.tasks);
      Alcotest.(check (option int)) "goal linked_task_count enriched" (Some 1)
        (Observed.to_option (List.hd enriched.goals).linked_task_count)
  | Error _ -> Alcotest.fail "expected enriched planning snapshot");
  let fetch_tasks_called = ref false in
  (match
     Cmd_executor.fetch_planning_with_tasks ~observed_at:obs_t0
       ~fetch_planning:(fun () -> Ok { goals = [ sample_goal ]; tasks = [ task_1 ] })
       ~fetch_tasks:(fun () ->
         fetch_tasks_called := true;
         Ok [])
   with
  | Ok snap ->
      Alcotest.(check bool) "skip secondary fetch when planning already has tasks"
        false !fetch_tasks_called;
      Alcotest.(check int) "preserved tasks" 1 (List.length snap.tasks)
  | Error _ -> Alcotest.fail "expected direct planning snapshot");
  let tz = App.local_tz_offset_sec ~at:1795208760.0 () in
  Alcotest.(check bool) "tz_offset_sec within valid UTC range [-12h..+14h]" true
    (tz >= -43200 && tz <= 50400);
  Alcotest.(check int) "tz_offset_sec is whole minutes" 0 (tz mod 60)

let test_p2_voice_runner_ffmpeg_and_mouse_capture () =
  (* 1. Recorder resolution order: rec -> sox -> ffmpeg *)
  let find_only target name =
    if String.equal name target then Some ("/usr/local/bin/" ^ name) else None
  in
  (match Voice_runner.resolve_recorder_from ~find:(find_only "ffmpeg") with
  | Some (Voice_runner.Recorder_ffmpeg, "/usr/local/bin/ffmpeg") -> ()
  | _ -> Alcotest.fail "expected ffmpeg fallback when rec/sox absent");
  (match Voice_runner.resolve_recorder_from ~find:(find_only "rec") with
  | Some (Voice_runner.Recorder_rec, "/usr/local/bin/rec") -> ()
  | _ -> Alcotest.fail "expected rec when present");
  (match Voice_runner.resolve_recorder_from ~find:(fun _ -> None) with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None when no recorder on PATH");

  (* 2. ffmpeg recording command args match avfoundation 16kHz mono wav *)
  let argv_default =
    Voice_runner.build_record_argv ~kind:Voice_runner.Recorder_ffmpeg
      ~bin_path:"/opt/homebrew/bin/ffmpeg" ~device:None ~out_path:"/tmp/ptt.wav"
  in
  Alcotest.(check (array string)) "ffmpeg default avfoundation argv"
    [|
      "/opt/homebrew/bin/ffmpeg";
      "-y";
      "-loglevel";
      "error";
      "-f";
      "avfoundation";
      "-i";
      ":default";
      "-ar";
      "16000";
      "-ac";
      "1";
      "-f";
      "wav";
      "/tmp/ptt.wav";
    |]
    argv_default;
  let argv_dev =
    Voice_runner.build_record_argv ~kind:Voice_runner.Recorder_ffmpeg
      ~bin_path:"/opt/homebrew/bin/ffmpeg" ~device:(Some ":1")
      ~out_path:"/tmp/ptt2.wav"
  in
  Alcotest.(check string) "ffmpeg honors explicit device" ":1" argv_dev.(7);

  (* 3. P1-13 / P2-7d: Mouse capture OFF by default, no ?1002h hijack, guarded [m] toggle *)
  Alcotest.(check bool) "mouse capture defaults OFF for native drag-select" false
    App.default_mouse_capture;
  Alcotest.(check string) "mouse ON enables ?1000h?1006h without ?1002h"
    "\x1b[?1000h\x1b[?1006h" (App.mouse_capture_seq true);
  Alcotest.(check string) "mouse OFF disables ?1000l?1002l?1006l"
    "\x1b[?1000l\x1b[?1002l\x1b[?1006l" (App.mouse_capture_seq false);
  let bare_m : Masc_tui_term.Input_decoder.key_event =
    {
      key = Masc_tui_term.Input_decoder.Char "m";
      mods = Masc_tui_term.Input_decoder.no_mods;
    }
  in
  let m_norm = Masc_tui_store.Model.initial ~cols:140 ~rows:40 () in
  Alcotest.(check bool) "[m] toggles mouse on normal unfocused view" true
    (App.should_toggle_mouse_capture m_norm bare_m);
  let m_tiny = Masc_tui_store.Model.initial ~cols:30 ~rows:10 () in
  Alcotest.(check bool) "[m] blocked on too-small viewport" false
    (App.should_toggle_mouse_capture m_tiny bare_m);
  let m_ov =
    {
      m_norm with
      nav = { m_norm.nav with overlay = Some Masc_tui_core.Nav.Palette };
    }
  in
  Alcotest.(check bool) "[m] blocked while overlay active" false
    (App.should_toggle_mouse_capture m_ov bare_m);
  let m_comp =
    {
      m_norm with
      drafts = Masc_tui_store.Drafts.set_focus true m_norm.drafts;
    }
  in
  Alcotest.(check bool) "[m] blocked while composer focused" false
    (App.should_toggle_mouse_capture m_comp bare_m);

  (* Korean 2-bulsik IME replay for bare 'm' ('ㅡ' U+3161 and NFD U+1173). *)
  let dec_ime = Masc_tui_term.Input_decoder.create () in
  let bare_eu =
    match Masc_tui_term.Input_decoder.feed_string dec_ime "ㅡ" with
    | [ Masc_tui_term.Input_decoder.Key kev ] -> kev
    | _ -> Alcotest.fail "expected single Key event for Korean ㅡ"
  in
  let bare_eu_nfd : Masc_tui_term.Input_decoder.key_event =
    {
      key = Masc_tui_term.Input_decoder.Char "\xe1\x85\xb3";
      mods = Masc_tui_term.Input_decoder.no_mods;
    }
  in
  let shift_eu : Masc_tui_term.Input_decoder.key_event =
    {
      key = Masc_tui_term.Input_decoder.Char "ㅡ";
      mods = { ctrl = false; alt = false; shift = true };
    }
  in
  let syllable_meu : Masc_tui_term.Input_decoder.key_event =
    {
      key = Masc_tui_term.Input_decoder.Char "므";
      mods = Masc_tui_term.Input_decoder.no_mods;
    }
  in
  let jamo_giyeok : Masc_tui_term.Input_decoder.key_event =
    {
      key = Masc_tui_term.Input_decoder.Char "ㄱ";
      mods = Masc_tui_term.Input_decoder.no_mods;
    }
  in
  let m_filter =
    { m_norm with nav = { m_norm.nav with filter_focused = true } }
  in
  let m_settings =
    {
      m_norm with
      nav = { m_norm.nav with overlay = Some (Masc_tui_core.Nav.Settings Masc_tui_core.Nav.Settings_general_ui) };
    }
  in
  let m_inline =
    {
      m_norm with
      nav = { m_norm.nav with overlay = Some (Masc_tui_core.Nav.Inline_action Masc_tui_core.Nav.Btw_query) };
    }
  in
  Alcotest.(check bool) "[ㅡ] toggles mouse on normal unfocused view" true
    (App.should_toggle_mouse_capture m_norm bare_eu);
  Alcotest.(check bool) "[U+1173] NFD toggles mouse on normal unfocused view" true
    (App.should_toggle_mouse_capture m_norm bare_eu_nfd);
  Alcotest.(check bool) "[Shift+ㅡ] does not toggle mouse" false
    (App.should_toggle_mouse_capture m_norm shift_eu);
  Alcotest.(check bool) "composed [므] does not toggle mouse" false
    (App.should_toggle_mouse_capture m_norm syllable_meu);
  Alcotest.(check bool) "unrelated [ㄱ] does not toggle mouse" false
    (App.should_toggle_mouse_capture m_norm jamo_giyeok);
  Alcotest.(check bool) "[ㅡ] blocked on too-small viewport" false
    (App.should_toggle_mouse_capture m_tiny bare_eu);
  Alcotest.(check bool) "[ㅡ] blocked while Palette overlay active" false
    (App.should_toggle_mouse_capture m_ov bare_eu);
  Alcotest.(check bool) "[ㅡ] blocked while Settings overlay active" false
    (App.should_toggle_mouse_capture m_settings bare_eu);
  Alcotest.(check bool) "[ㅡ] blocked while Inline_action overlay active" false
    (App.should_toggle_mouse_capture m_inline bare_eu);
  Alcotest.(check bool) "[ㅡ] blocked while composer focused" false
    (App.should_toggle_mouse_capture m_comp bare_eu);
  Alcotest.(check bool) "[ㅡ] blocked while filter focused" false
    (App.should_toggle_mouse_capture m_filter bare_eu);

  (* Layer 1 #9: Micro, sidebar focus, Knowledge>Memory, and Korean jamo in Keeper_chat *)
  let m_micro = Masc_tui_store.Model.initial ~cols:60 ~rows:20 () in
  Alcotest.(check bool) "[m] blocked on Micro viewport" false
    (App.should_toggle_mouse_capture m_micro bare_m);
  let m_sidebar =
    { m_norm with nav = { m_norm.nav with sidebar_focused = true } }
  in
  Alcotest.(check bool) "[m] blocked while sidebar focused" false
    (App.should_toggle_mouse_capture m_sidebar bare_m);
  let m_know_mem =
    {
      m_norm with
      nav = { m_norm.nav with workspace = Masc_tui_core.Nav.Knowledge };
      knowledge =
        Masc_tui_store.Knowledge_store.set_tab Masc_tui_core.Nav.Knowledge_memory
          m_norm.knowledge;
    }
  in
  Alcotest.(check bool) "[m] yielded to Toggle_memory_scope on Knowledge > Memory"
    false (App.should_toggle_mouse_capture m_know_mem bare_m);
  Alcotest.(check bool) "[ㅡ] yielded on Knowledge > Memory" false
    (App.should_toggle_mouse_capture m_know_mem bare_eu);
  let m_chat_dive =
    {
      m_norm with
      nav =
        {
          m_norm.nav with
          workspace = Masc_tui_core.Nav.Keepers;
          dive_stack =
            [
              Masc_tui_core.Nav.Dive_keeper
                { name = "alpha"; tab = Masc_tui_core.Nav.Keeper_chat };
            ];
        };
    }
  in
  Alcotest.(check bool) "ASCII [m] still toggles mouse in unfocused Keeper_chat dive"
    true (App.should_toggle_mouse_capture m_chat_dive bare_m);
  Alcotest.(check bool) "Korean [ㅡ] yields to Pillar 3 auto-focus in Keeper_chat dive"
    false (App.should_toggle_mouse_capture m_chat_dive bare_eu);
  Alcotest.(check bool) "Korean NFD [U+1173] yields in Keeper_chat dive"
    false (App.should_toggle_mouse_capture m_chat_dive bare_eu_nfd)

(* A chat stream that drops while the server reports its operation queued or
   running is posted again with its last journal seq, and only to the server
   instance that accepted it; anything else ends the submit. *)
let test_chat_reattach_decision () =
  let delay ?(acceptance = Some Keeper_chat_operation.State_name.Running)
      ?(terminal_seen = false) ?(reattaches = 0) result =
    Cmd_executor.chat_reattach_delay ~acceptance ~terminal_seen ~reattaches
      result
  in
  let dropped = Error (Msg.Transport Health.Stream_eof) in
  Alcotest.(check (option (float 0.0))) "accepted stream dropped mid-turn reattaches"
    (Some 1.0) (delay dropped);
  Alcotest.(check (option (float 0.0)))
    "clean close without a terminal reattaches for the missed terminal" (Some 1.0)
    (delay (Ok ()));
  Alcotest.(check (option (float 0.0))) "a refused connection after acceptance waits longer"
    (Some 15.0)
    (delay ~reattaches:4 (Error (Msg.Transport Health.Connect_refused)));
  Alcotest.(check (option (float 0.0))) "reattach budget is bounded" None
    (delay ~reattaches:5 dropped);
  Alcotest.(check (option (float 0.0))) "a failure before acceptance is the submit's error"
    None (delay ~acceptance:None dropped);
  Alcotest.(check (option (float 0.0))) "a queued operation reattaches" (Some 1.0)
    (delay ~acceptance:(Some Keeper_chat_operation.State_name.Queued) dropped);
  Alcotest.(check (option (float 0.0)))
    "a close after an acceptance that reports the operation succeeded is final"
    None
    (delay ~acceptance:(Some Keeper_chat_operation.State_name.Succeeded) (Ok ()));
  Alcotest.(check (option (float 0.0)))
    "a close after an acceptance that reports the operation cancelled is final"
    None
    (delay ~acceptance:(Some Keeper_chat_operation.State_name.Cancelled) (Ok ()));
  Alcotest.(check (option (float 0.0))) "a terminal frame ends the stream" None
    (delay ~terminal_seen:true (Ok ()));
  Alcotest.(check (option (float 0.0))) "a 4xx is final" None
    (delay
       (Error (Msg.Http_error { status = 400; body = "bad request"; api_error = None })));
  let guard instance : Http_client.workspace_guard =
    { Http_client.expected_instance = instance; expected_workspace = Some "ws-sha" }
  in
  let same ~submitted_to current =
    Cmd_executor.chat_reattach_same_instance ~submitted_to:(guard submitted_to)
      (guard current)
  in
  Alcotest.(check bool) "the instance that accepted the request still answers" true
    (same ~submitted_to:(Some "instance-1") (Some "instance-1"));
  Alcotest.(check bool) "a restarted server is another instance" false
    (same ~submitted_to:(Some "instance-1") (Some "instance-2"));
  Alcotest.(check bool) "a guard cleared for a handshake names no instance" false
    (same ~submitted_to:(Some "instance-1") None);
  Alcotest.(check bool) "a request sent before /health named an instance" false
    (same ~submitted_to:None (Some "instance-1"));
  (* Unexpected fiber exceptions become Transport errors for Chat_stream_done
     while Eio cancellation and Io_domain.Closed propagate unchanged. *)
  (match Cmd_executor.run_chat_stream_result (fun () -> Ok ()) with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "expected Ok () pass-through");
  (match
     Cmd_executor.run_chat_stream_result (fun () -> failwith "stream_boom")
   with
  | Error (Msg.Transport (Health.Other_io detail)) ->
      Alcotest.(check bool) "exception detail preserved" true
        (contains_substring ~needle:"stream_boom" detail)
  | Ok () | Error _ ->
      Alcotest.fail "expected Transport Other_io from unexpected exception");
  let closed_propagated =
    try
      ignore (Cmd_executor.run_chat_stream_result (fun () -> raise Io_domain.Closed));
      false
    with Io_domain.Closed -> true
  in
  Alcotest.(check bool) "Io_domain.Closed propagates" true closed_propagated;
  let cancel_propagated =
    try
      ignore
        (Cmd_executor.run_chat_stream_result (fun () ->
             raise (Eio.Cancel.Cancelled (Failure "stop"))));
      false
    with Eio.Cancel.Cancelled _ -> true
  in
  Alcotest.(check bool) "Eio.Cancel.Cancelled propagates" true cancel_propagated

let test_feature_wave1_osc52_and_artifact_export_safety () =
  (* 1. OSC 52 wrapping (never raw text) *)
  let seq_plain = Masc_tui_term.Clipboard.osc52_sequence ~in_tmux:false "<h1>Hi</h1>" in
  Alcotest.(check bool) "plain OSC 52 starts with ESC ]52;c;" true
    (String.starts_with ~prefix:"\x1b]52;c;" seq_plain);
  Alcotest.(check bool) "plain OSC 52 does not leak raw HTML" false
    (contains_substring ~needle:"<h1>Hi</h1>" seq_plain);
  let seq_tmux = Masc_tui_term.Clipboard.osc52_sequence ~in_tmux:true "<h1>Hi</h1>" in
  Alcotest.(check bool) "tmux OSC 52 wrapped in DCS passthrough" true
    (String.starts_with ~prefix:"\x1bPtmux;\x1b\x1b]52;c;" seq_tmux);
  (* 2. Dynamic export directory resolution (ZERO hardcoded /Users) *)
  let tmp = make_temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf tmp)
    (fun () ->
      let fake_home = Filename.concat tmp "home" in
      let fake_base = Filename.concat tmp "ws" in
      Fs_compat.mkdir_p fake_home;
      Fs_compat.mkdir_p fake_base;
      let env_with_home = function "HOME" -> Some fake_home | _ -> None in
      let dir_fallback =
        Cmd_executor.resolve_artifact_export_dir ~getenv:env_with_home
          ~base_path:fake_base ()
      in
      Alcotest.(check bool) "falls back to <base>/.masc/exports when Downloads absent"
        true
        (contains_substring ~needle:".masc/exports" dir_fallback);
      Fs_compat.mkdir_p (Filename.concat fake_home "Downloads");
      let dir_dl =
        Cmd_executor.resolve_artifact_export_dir ~getenv:env_with_home
          ~base_path:fake_base ()
      in
      Alcotest.(check bool) "uses $HOME/Downloads/masc-artifacts when Downloads exists"
        true
        (contains_substring ~needle:"Downloads/masc-artifacts" dir_dl);
      (* 3. Filename sanitization + distinct artifact-<32hex> suffixes + local export safety *)
      let fname =
        Cmd_executor.build_artifact_export_filename ~filename_stem:"../evil report/v2"
          ~id:"artifact-a1b2c3d4e5f60718293a4b5c6d7e8f90" ~ext:".html"
      in
      let fname2 =
        Cmd_executor.build_artifact_export_filename ~filename_stem:"../evil report/v2"
          ~id:"artifact-99998888777766665555444433332222" ~ext:".html"
      in
      Alcotest.(check bool) "filename ends with .html" true
        (Filename.check_suffix fname ".html");
      Alcotest.(check bool) "filename strips path separators" false
        (String.contains fname '/');
      Alcotest.(check bool) "distinct artifact-<32hex> IDs yield unique filenames"
        false (String.equal fname fname2);
      Alcotest.(check bool) "suffix uses unique hex tail, not constant '-artifact'"
        true (contains_substring ~needle:"6d7e8f90.html" fname);
      let good_file = Filename.concat fake_base "ok.html" in
      let bad_file = Filename.concat fake_base "bad.sh" in
      (match Fs_compat.save_file_atomic good_file "<!doctype html><h1>Safe</h1>" with
      | Ok () -> ()
      | Error e -> Alcotest.fail e);
      (match Fs_compat.save_file_atomic bad_file "#!/bin/sh\necho hi\n" with
      | Ok () -> ()
      | Error e -> Alcotest.fail e);
      Alcotest.(check bool) "regular .html allowed for open_local_export_file"
        true (Cmd_executor.is_safe_local_export_file good_file);
      Alcotest.(check bool) ".sh rejected for open_local_export_file" false
        (Cmd_executor.is_safe_local_export_file bad_file);
      Alcotest.(check bool) "file:// STILL rejected by is_safe_external_url" false
        (Cmd_executor.is_safe_external_url ("file://" ^ good_file));
      (* 4. Live Cmd.Export_artifact writes atomic file and publishes Reply_action_ack *)
      let cli : Cli_args.config =
        {
          scheme = "http";
          host = "127.0.0.1";
          port = 8935;
          base_path = fake_base;
          workspace = "test";
          theme = Theme.Midnight;
          lang = Say.Lang_en;
          theme_explicit = false;
          lang_explicit = false;
          auto_start = false;
        }
      in
      let fake_voice : Voice_runner.backend =
        {
          probe =
            (fun () ->
              Ok
                {
                  recorder_available = false;
                  recorder_cmd = None;
                  stt_available = false;
                });
          record_until_stopped =
            (fun ~device:_ ~stop_signal ~on_level:_ ->
              Eio.Promise.await stop_signal;
              Error "stopped");
          transcribe = (fun ~audio_path:_ -> Error "unused");
          cleanup_audio = (fun ~audio_path:_ -> ());
        }
      in
      (* Point HOME at a subdir without Downloads so Export_artifact writes cleanly
         into <fake_base>/.masc/exports (outside HOME, respecting Fs_compat test guard). *)
      let empty_home = Filename.concat tmp "home_no_downloads" in
      Fs_compat.mkdir_p empty_home;
      let orig_home = Sys.getenv_opt "HOME" in
      Unix.putenv "HOME" empty_home;
      let items =
        Fun.protect
          ~finally:(fun () ->
            Unix.putenv "HOME" (Option.value ~default:"" orig_home))
          (fun () ->
            Eio_main.run @@ fun env ->
            Eio.Switch.run @@ fun sw ->
            let clock = Eio.Stdenv.clock env in
            let io = Io_domain.start ~sw ~env in
            let worker = Worker_pool.create ~sw (Eio.Stdenv.domain_mgr env) in
            let bus = Cmd_executor.create_bus () in
            let exec =
              Cmd_executor.create ~sw ~io ~worker ~clock ~cli ~bus
                ~bearer_token:None ~voice_backend:fake_voice
                ~on_quit:(fun _ -> ()) ~on_restart:(fun () -> ()) ()
            in
            Cmd_executor.execute exec
              (Cmd.Export_artifact
                 {
                   epoch = Epoch.initial;
                   id = "art-export-1";
                   revision = Some 1;
                   filename_stem = "wave1-report";
                   ext = ".html";
                   content_opt = Some "<!doctype html><h1>Exported Wave 1</h1>";
                   open_after = false;
                 });
            let rec wait_drain tries acc =
              let got = Ui_bus.drain bus in
              let acc = acc @ got in
              if acc <> [] || tries <= 0 then acc
              else begin
                Eio.Time.sleep clock 0.02;
                wait_drain (tries - 1) acc
              end
            in
            let drained = wait_drain 40 [] in
            Cmd_executor.shutdown exec;
            drained)
      in
      let saved_label =
        List.find_map
          (function
            | Ui_bus.Stream_event
                (Msg.Http_reply
                   {
                     reply =
                       Msg.Reply_action_ack
                         { label; ack_scope = _; for_modal = None; result = Ok () };
                     _;
                   }) ->
                Some (Say.resolve Say.Lang_en label)
            | Ui_bus.Stream_event _ | Ui_bus.Snapshot _ | Ui_bus.Stream_gap _ -> None)
          items
      in
      match saved_label with
      | Some lbl ->
          Alcotest.(check bool) "ack toast includes .html saved path" true
            (contains_substring ~needle:".html" lbl);
          let prefix = "Exported: " in
          if String.starts_with ~prefix lbl then begin
            let path =
              String.sub lbl (String.length prefix)
                (String.length lbl - String.length prefix)
            in
            Alcotest.(check bool) "exported file exists on disk" true
              (Sys.file_exists path);
            let ic = In_channel.open_text path in
            let body =
              Fun.protect ~finally:(fun () -> In_channel.close_noerr ic)
                (fun () -> In_channel.input_all ic)
            in
            Alcotest.(check string) "exported HTML content matches"
              "<!doctype html><h1>Exported Wave 1</h1>" body;
            (try Sys.remove path with Sys_error _ -> ())
          end
      | None -> Alcotest.fail "expected Reply_action_ack for Export_artifact")

let test_github_login_stream_exception_emits_done () =
  let keeper = "alpha" in
  let m_running =
    let base = Model.initial () in
    {
      base with
      keeper_context =
        Keeper_context_store.start_github_login ~keeper base.keeper_context;
    }
  in
  Alcotest.(check bool) "github_login starts running = true" true
    (Keeper_context_store.get_keeper ~keeper m_running.keeper_context)
      .github_login.running;
  (* 1. Non-cancel exception inside stream emits Github_login_done with Error
     and clears running = false in the store. *)
  let done_evt = ref None in
  Cmd_executor.run_github_login_stream
    ~publish_chunk:(fun _ -> ())
    ~publish_done:(fun ~observation ~error ->
      done_evt := Some (observation, error))
    ~stream:(fun ~on_chunk:_ -> failwith "gh_stream_boom");
  (match !done_evt with
  | Some (None, Some err_msg) ->
      Alcotest.(check bool) "stream exception detail preserved" true
        (contains_substring ~needle:"gh_stream_boom" err_msg);
      let m_after, _ =
        Update.step ~now:Clock.Mono.zero m_running
          (Msg.Github_login_done
             {
               epoch = m_running.epoch;
               keeper;
               observation = None;
               error = Some err_msg;
             })
      in
      let gl =
        (Keeper_context_store.get_keeper ~keeper m_after.keeper_context)
          .github_login
      in
      Alcotest.(check bool) "Github_login_done clears running = false" false
        gl.running;
      Alcotest.(check bool) "Github_login_done records error" true
        (Option.is_some gl.error)
  | Some _ | None ->
      Alcotest.fail "expected publish_done with error on stream exception");
  (* 2. Non-cancel exception raised during on_chunk also emits Github_login_done
     so running cannot get stuck true. *)
  let done_chunk_evt = ref None in
  Cmd_executor.run_github_login_stream
    ~publish_chunk:(fun _ -> failwith "chunk_boom")
    ~publish_done:(fun ~observation ~error ->
      done_chunk_evt := Some (observation, error))
    ~stream:(fun ~on_chunk ->
      on_chunk "data: {\"text\":\"Enter code ABCD-1234\"}\n\n";
      Ok ());
  (match !done_chunk_evt with
  | Some (None, Some err_msg) ->
      Alcotest.(check bool) "on_chunk exception detail preserved" true
        (contains_substring ~needle:"chunk_boom" err_msg)
  | Some _ | None ->
      Alcotest.fail "expected publish_done with error on on_chunk exception");
  (* 3. Eio.Cancel.Cancelled and Io_domain.Closed propagate unchanged. *)
  let done_on_cancel = ref false in
  let cancel_propagated =
    try
      Cmd_executor.run_github_login_stream
        ~publish_chunk:(fun _ -> ())
        ~publish_done:(fun ~observation:_ ~error:_ -> done_on_cancel := true)
        ~stream:(fun ~on_chunk:_ ->
          raise (Eio.Cancel.Cancelled (Failure "cancelled")));
      false
    with Eio.Cancel.Cancelled _ -> true
  in
  Alcotest.(check bool) "Eio.Cancel.Cancelled propagates in github login stream"
    true cancel_propagated;
  Alcotest.(check bool) "Cancelled does not emit fake Github_login_done" false
    !done_on_cancel;
  let closed_propagated =
    try
      Cmd_executor.run_github_login_stream
        ~publish_chunk:(fun _ -> ())
        ~publish_done:(fun ~observation:_ ~error:_ -> ())
        ~stream:(fun ~on_chunk:_ -> raise Io_domain.Closed);
      false
    with Io_domain.Closed -> true
  in
  Alcotest.(check bool) "Io_domain.Closed propagates in github login stream"
    true closed_propagated

let test_bounded_clipboard_url_opener_and_async_wiki_editor () =
  (* 1. P1-4: Clipboard.copy_text bounds wedged pbcopy via WNOHANG + SIGKILL *)
  let bin_dir = Filename.temp_dir "tui-clip-hang-" "" in
  let fake_pbcopy = Filename.concat bin_dir "pbcopy" in
  let orig_path = Sys.getenv_opt "PATH" in
  Fun.protect
    ~finally:(fun () ->
      (match orig_path with
       | Some p -> Unix.putenv "PATH" p
       | None -> Unix.unsetenv "PATH");
      (try Sys.remove fake_pbcopy with Sys_error _ -> ());
      try Unix.rmdir bin_dir with Unix.Unix_error _ -> ())
    (fun () ->
      Out_channel.with_open_bin fake_pbcopy (fun oc ->
          Out_channel.output_string oc "#!/bin/sh\nexec /bin/sleep 30\n");
      Unix.chmod fake_pbcopy 0o700;
      Unix.putenv "PATH" bin_dir;
      let osc52_called = ref false in
      let t0 = Clock.Mono.now () in
      let outcome =
        Masc_tui_term.Clipboard.copy_text ~timeout_s:0.08
          Masc_tui_term.Clipboard.Local
          ~write_osc52:(fun _ -> osc52_called := true)
          "clip-payload"
      in
      let elapsed = Clock.Mono.seconds_since (Clock.Mono.now ()) ~since:t0 in
      Alcotest.(check bool) "wedged pbcopy bounded under 1.0s" true
        (elapsed < 1.0);
      Alcotest.(check bool) "fell back to OSC 52 after timeout" true
        !osc52_called;
      Alcotest.(check bool) "outcome reports Tools_failed fallback" true
        (match outcome with
         | Masc_tui_term.Clipboard.Sent_to_terminal
             (Masc_tui_term.Clipboard.Tools_failed _) ->
             true
         | _ -> false);
      (* Cancelled copy_text MUST NOT call write_osc52 *)
      let osc52_cancelled = ref false in
      ignore
        (Masc_tui_term.Clipboard.copy_text ~timeout_s:1.0
           ~cancelled:(fun () -> true)
           Masc_tui_term.Clipboard.Local
           ~write_osc52:(fun _ -> osc52_cancelled := true)
           "cancelled-payload"
          : Masc_tui_term.Clipboard.copy_outcome);
      Alcotest.(check bool) "cancelled copy_text skips write_osc52" false
        !osc52_cancelled;
      (* Cancelled read_image aborts immediately with cancelled Unreadable *)
      Alcotest.(check bool) "cancelled read_image aborts immediately" true
        (match
           Masc_tui_term.Clipboard.read_image ~timeout_s:1.0
             ~cancelled:(fun () -> true)
             ()
         with
         | Error (Masc_tui_term.Clipboard.Unreadable { detail = "cancelled"; _ })
           ->
             true
         | _ -> false);
      (* Directory named pbcopy on PATH is ignored (S_REG check) *)
      let dir_path = Filename.temp_dir "tui-clip-dir-" "" in
      let dir_pbcopy = Filename.concat dir_path "pbcopy" in
      Fun.protect
        ~finally:(fun () ->
          (try Unix.rmdir dir_pbcopy with Unix.Unix_error _ -> ());
          try Unix.rmdir dir_path with Unix.Unix_error _ -> ())
        (fun () ->
          Unix.mkdir dir_pbcopy 0o755;
          Unix.putenv "PATH" dir_path;
          let osc52_dir = ref false in
          let out_dir =
            Masc_tui_term.Clipboard.copy_text ~timeout_s:0.2
              Masc_tui_term.Clipboard.Local
              ~write_osc52:(fun _ -> osc52_dir := true)
              "dir-test"
          in
          Alcotest.(check bool) "directory pbcopy skipped -> Terminal_only" true
            (!osc52_dir
             &&
             match out_dir with
             | Masc_tui_term.Clipboard.Sent_to_terminal
                 Masc_tui_term.Clipboard.Not_tried ->
                 true
             | _ -> false)));

  (* 2. P1-4: Cmd_executor.wait_reap_pid bounds & cancels wedged opener PID *)
  let safe_close fd =
    match Unix.close fd with () -> () | exception Unix.Unix_error _ -> ()
  in
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
  Fun.protect
    ~finally:(fun () -> safe_close devnull)
    (fun () ->
      let pid1 =
        Unix.create_process "/bin/sh"
          [| "/bin/sh"; "-c"; "exec /bin/sleep 30" |]
          devnull devnull devnull
      in
      let t0 = Clock.Mono.now () in
      let res1 = Cmd_executor.wait_reap_pid ~timeout_s:0.08 pid1 in
      let elapsed1 = Clock.Mono.seconds_since (Clock.Mono.now ()) ~since:t0 in
      Alcotest.(check bool) "wait_reap_pid timed out under 1.0s" true
        (elapsed1 < 1.0);
      (match res1 with
       | Error msg ->
           Alcotest.(check bool) "timeout error message" true
             (contains_substring ~needle:"timed out" msg)
       | Ok () -> Alcotest.fail "expected timeout error");
      let pid2 =
        Unix.create_process "/bin/sh"
          [| "/bin/sh"; "-c"; "exec /bin/sleep 30" |]
          devnull devnull devnull
      in
      let res2 =
        Cmd_executor.wait_reap_pid ~timeout_s:5.0 ~cancelled:(fun () -> true)
          pid2
      in
      Alcotest.(check bool) "cancelled wait_reap_pid returns Error promptly" true
        (Result.is_error res2));

  (* 3. P1-6: App.can_launch_pending_wiki_editor predicate *)
  let m_wiki =
    let m0 = Model.initial ~cols:120 ~rows:40 () in
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Knowledge };
      knowledge = { m0.knowledge with active_tab = Nav.Knowledge_wiki };
    }
  in
  Alcotest.(check bool) "can_launch on Knowledge_wiki" true
    (App.can_launch_pending_wiki_editor m_wiki);
  let m_wiki_dive =
    {
      m_wiki with
      nav =
        {
          m_wiki.nav with
          dive_stack = [ Nav.Dive_knowledge (Nav.Wiki_dive "guide") ];
        };
    }
  in
  Alcotest.(check bool) "can_launch on Wiki_dive" true
    (App.can_launch_pending_wiki_editor m_wiki_dive);
  Alcotest.(check bool) "blocked after switching to Pulse" false
    (App.can_launch_pending_wiki_editor
       { m_wiki with nav = { m_wiki.nav with workspace = Nav.Pulse } });
  Alcotest.(check bool) "blocked on Knowledge_board" false
    (App.can_launch_pending_wiki_editor
       {
         m_wiki with
         knowledge = { m_wiki.knowledge with active_tab = Nav.Knowledge_board };
       });
  Alcotest.(check bool) "blocked when overlay open" false
    (App.can_launch_pending_wiki_editor
       { m_wiki with nav = { m_wiki.nav with overlay = Some Nav.Palette } });
  Alcotest.(check bool) "blocked when filter focused" false
    (App.can_launch_pending_wiki_editor
       { m_wiki with nav = { m_wiki.nav with filter_focused = true } });
  Alcotest.(check bool) "blocked in Micro breakpoint" false
    (App.can_launch_pending_wiki_editor
       {
         (Model.initial ~cols:100 ~rows:20 ()) with
         nav = { (Model.initial ~cols:100 ~rows:20 ()).nav with workspace = Nav.Knowledge };
         knowledge = { Knowledge_store.empty with active_tab = Nav.Knowledge_wiki };
       });

  (* 4. P1-6: Cmd.Edit_wiki_page async fetch + stale-epoch, can_launch, and
     out-of-order/double-Ctrl+E guards *)
  let orig_editor = Sys.getenv_opt "EDITOR" in
  let orig_visual = Sys.getenv_opt "VISUAL" in
  let editor_dir = Filename.temp_dir "tui-wiki-editor-" "" in
  let fake_editor = Filename.concat editor_dir "noop-editor.sh" in
  Fun.protect
    ~finally:(fun () ->
      (match orig_editor with
       | Some v -> Unix.putenv "EDITOR" v
       | None -> Unix.unsetenv "EDITOR");
      (match orig_visual with
       | Some v -> Unix.putenv "VISUAL" v
       | None -> Unix.unsetenv "VISUAL");
      (try Sys.remove fake_editor with Sys_error _ -> ());
      try Unix.rmdir editor_dir with Unix.Unix_error _ -> ())
    (fun () ->
      Out_channel.with_open_bin fake_editor (fun oc ->
          Out_channel.output_string oc "#!/bin/sh\nexit 0\n");
      Unix.chmod fake_editor 0o700;
      Unix.putenv "EDITOR" fake_editor;
      Unix.unsetenv "VISUAL";
      let wiki_json slug =
        Printf.sprintf
          {|{"page":"%s","slug":"%s","file":"%s.md","frontmatter":{"title":"T","summary":"","source":"direct_experience","author":"op","created":"2026-01-01","updated":"2026-01-01","revision":1,"tags":[]},"sha256":"abc123","body_markdown":"hello","outgoing_links":[],"backlinks":[],"lint_findings":[]}|}
          slug slug slug
      in
      let http_200 body =
        Printf.sprintf
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
          (String.length body) body
      in
      Eio_main.run @@ fun env ->
      Eio.Time.with_timeout_exn env#clock 5.0 @@ fun () ->
      (try
         Eio.Switch.run @@ fun sw ->
         let clock = Eio.Stdenv.clock env in
         let listener =
           Eio.Net.listen ~sw ~backlog:8 env#net
             (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
         in
         let port =
           match Eio.Net.listening_addr listener with
           | `Tcp (_, p) -> p
           | `Unix _ -> Alcotest.fail "expected TCP listener"
         in
         Eio.Fiber.fork_daemon ~sw (fun () ->
             let rec loop () =
               let flow, _addr = Eio.Net.accept ~sw listener in
               Eio.Fiber.fork ~sw (fun () ->
                   try
                     let br = Eio.Buf_read.of_flow flow ~max_size:4096 in
                     let req = Eio.Buf_read.line br in
                     if contains_substring ~needle:"stall-page" req then
                       Eio.Time.sleep clock 4.0
                     else if contains_substring ~needle:"slow-a" req then begin
                       Eio.Time.sleep clock 0.14;
                       Eio.Flow.copy_string (http_200 (wiki_json "slow-a")) flow
                     end
                     else
                       Eio.Flow.copy_string (http_200 (wiki_json "fast-b")) flow;
                     Eio.Flow.close flow
                   with
                   | Eio.Cancel.Cancelled _ as ex -> raise ex
                   | _ -> ());
               loop ()
             in
             loop ());
         let io = Io_domain.start ~sw ~env in
         let worker = Worker_pool.create ~sw (Eio.Stdenv.domain_mgr env) in
         let bus = Cmd_executor.create_bus () in
         let cli : Cli_args.config =
           {
             scheme = "http";
             host = "127.0.0.1";
             port;
             base_path = "/tmp/masc-tui-async-wiki-test";
             workspace = "test";
             theme = Theme.Midnight;
             lang = Say.Lang_en;
             theme_explicit = false;
             lang_explicit = false;
             auto_start = false;
           }
         in
         let pause_count = ref 0 in
         let resume_count = ref 0 in
         let editor_handoff : Cmd_executor.editor_handoff =
           {
             pause_terminal = (fun () -> incr pause_count);
             resume_terminal = (fun () -> incr resume_count);
           }
         in
         let executor =
           Cmd_executor.create ~sw ~io ~worker ~clock ~cli ~bus
             ~bearer_token:None ~editor_handoff
             ~on_quit:(fun _ -> ())
             ~on_restart:(fun () -> ())
             ()
         in
         let wait_pending ?(max_tries = 40) () =
           let rec go n =
             if Cmd_executor.has_pending_editor executor then true
             else if n <= 0 then false
             else begin
               Eio.Time.sleep clock 0.01;
               go (n - 1)
             end
           in
           go max_tries
         in
         (* 4a. Stalled server does not block UI fiber *)
         let t0 = Clock.Mono.now () in
         Cmd_executor.execute executor
           (Cmd.Open_editor_escape_hatch (Cmd.Edit_wiki_page "stall-page"));
         let elapsed = Clock.Mono.seconds_since (Clock.Mono.now ()) ~since:t0 in
         Alcotest.(check bool)
           (Printf.sprintf
              "Edit_wiki_page returns immediately without blocking UI (%.3fs < 0.2s)"
              elapsed)
           true (elapsed < 0.2);

         (* 4b. Stale-epoch race: Sync_streams with new epoch clears pending_editor *)
         Cmd_executor.execute executor
           (Cmd.Open_editor_escape_hatch (Cmd.Edit_wiki_page "fast-b"));
         Alcotest.(check bool) "fast-b queued pending_editor" true
           (wait_pending ());
         let epoch2 = Epoch.next Epoch.initial in
         Cmd_executor.execute executor
           (Cmd.Sync_streams { epoch = epoch2; streams = [] });
         Alcotest.(check bool) "Sync_streams epoch bump clears pending_editor"
           false (Cmd_executor.has_pending_editor executor);
         Cmd_executor.run_pending_editor executor;
         Alcotest.(check int) "stale-epoch pending_editor never launched" 0
           !pause_count;

         (* 4c. can_launch=false discards stale pending_editor cleanly *)
         Cmd_executor.execute executor
           (Cmd.Open_editor_escape_hatch (Cmd.Edit_wiki_page "fast-b"));
         Alcotest.(check bool) "fast-b queued in epoch2" true (wait_pending ());
         Cmd_executor.run_pending_editor ~can_launch:(fun () -> false) executor;
         Alcotest.(check bool) "can_launch=false discarded pending_editor" false
           (Cmd_executor.has_pending_editor executor);
         Alcotest.(check int) "can_launch=false did not pause terminal" 0
           !pause_count;

         (* 4d. Out-of-order double Ctrl+E: slow-a then fast-b launches ONLY fast-b,
            and late slow-a is dropped by wiki_editor_gen without re-opening $EDITOR *)
         Cmd_executor.execute executor
           (Cmd.Open_editor_escape_hatch (Cmd.Edit_wiki_page "slow-a"));
         Cmd_executor.execute executor
           (Cmd.Open_editor_escape_hatch (Cmd.Edit_wiki_page "fast-b"));
         Alcotest.(check bool) "fast-b ready first" true (wait_pending ());
         Cmd_executor.run_pending_editor ~can_launch:(fun () -> true) executor;
         Alcotest.(check int) "fast-b launched editor once" 1 !pause_count;
         Alcotest.(check int) "fast-b resumed terminal once" 1 !resume_count;
         (* Wait past slow-a's 140ms server delay; stale slow-a must NOT re-queue *)
         Eio.Time.sleep clock 0.22;
         Alcotest.(check bool) "stale slow-a ignored after newer generation"
           false (Cmd_executor.has_pending_editor executor);

         Cmd_executor.shutdown executor;
         Eio.Switch.fail sw Exit
       with Exit -> ()))

let test_timeout_budgets_and_reattach_on_timeout_detail () =
  Alcotest.(check (float 0.001)) "standard_timeout_sec" 12.0
    Cmd_executor.standard_timeout_sec;
  Alcotest.(check (float 0.001)) "heavy_timeout_sec" 30.0
    Cmd_executor.heavy_timeout_sec;
  Alcotest.(check (float 0.001)) "chat_stream_header_timeout_sec" 45.0
    Cmd_executor.chat_stream_header_timeout_sec;

  let ws_scope = Masc_tui_protocol.Wire_infra.Ws_project in
  let heavy_gets =
    [
      ("Get_tools_catalog", Cmd.Get_tools_catalog { keeper = None });
      ("Get_sandboxes", Cmd.Get_sandboxes);
      ( "Get_workspace_search"
      , Cmd.Get_workspace_search { scope = ws_scope; query = "timeout" } );
      ("Get_workspace_files", Cmd.Get_workspace_files { scope = ws_scope });
      ( "Get_workspace_file"
      , Cmd.Get_workspace_file { scope = ws_scope; path = "dune" } );
      ("Get_git_status", Cmd.Get_git_status { scope = ws_scope });
      ( "Get_git_diff"
      , Cmd.Get_git_diff { scope = ws_scope; path = "dune" } );
      ("Get_dashboard_shell", Cmd.Get_dashboard_shell);
      ("Get_keepers_roster", Cmd.Get_keepers_roster);
      ("Get_planning", Cmd.Get_planning);
      ("Get_candle_ledger", Cmd.Get_candle_ledger { limit = Some 50 });
      ("Get_world_memory", Cmd.Get_world_memory);
      ( "Get_keeper_memory_journal"
      , Cmd.Get_keeper_memory_journal { keeper = "alpha"; limit = Some 20 } );
      ( "Get_keeper_tool_calls"
      , Cmd.Get_keeper_tool_calls
          {
            keeper = "alpha";
            limit = Some 50;
            execution_ids = None;
            turn_ref = None;
          } );
      ("Get_artifacts", Cmd.Get_artifacts);
      ( "Get_artifact_detail"
      , Cmd.Get_artifact_detail { id = "art-1"; revision = None } );
      ( "Get_board_feed"
      , Cmd.Get_board_feed
          {
            sort_by = "recent";
            hearth = None;
            signal_only = false;
            limit = Some 30;
            offset = None;
          } );
      ("Get_runtime_probe", Cmd.Get_runtime_probe { force = true });
      ("Get_efficiency", Cmd.Get_efficiency { month = None });
      ("Get_harness_health", Cmd.Get_harness_health);
      ( "Get_verification_evidence"
      , Cmd.Get_verification_evidence
          { task_id = "t-1"; verification_id = "v-1" } );
      ( "Get_keeper_sandbox_logs"
      , Cmd.Get_keeper_sandbox_logs { keeper = "alpha"; tail = Some 100 } );
    ]
  in
  List.iter
    (fun (label, req) ->
      Alcotest.(check (float 0.001)) ("heavy GET: " ^ label) 30.0
        (Cmd_executor.timeout_sec_for_get req))
    heavy_gets;

  let fast_gets =
    [
      ("Get_health", Cmd.Get_health);
      ("Get_keeper_turns", Cmd.Get_keeper_turns);
      ( "Get_asks"
      , Cmd.Get_asks { keeper = None; include_resolved = false } );
      ("Get_tool_approvals", Cmd.Get_tool_approvals);
      ("Get_gate_pending", Cmd.Get_gate_pending);
      ("Get_board_hearths", Cmd.Get_board_hearths);
      ("Get_wiki_page", Cmd.Get_wiki_page { page = "home" });
      ("Get_tui_preferences", Cmd.Get_tui_preferences);
      ("Get_chat_queue", Cmd.Get_chat_queue { keeper = "alpha" });
      ( "Get_chat_status"
      , Cmd.Get_chat_status { keeper = "alpha"; operation_id = "op-1" } );
      ("Get_mcp_clients", Cmd.Get_mcp_clients);
    ]
  in
  List.iter
    (fun (label, req) ->
      Alcotest.(check (float 0.001)) ("fast GET: " ^ label) 12.0
        (Cmd_executor.timeout_sec_for_get req))
    fast_gets;

  let heavy_posts =
    [
      ("Post_sandbox_probe", Cmd.Post_sandbox_probe `All);
      ( "Post_fusion_launch"
      , Cmd.Post_fusion_launch
          {
            keeper = "alpha";
            request =
              {
                prompt = "check";
                preset = Some "default";
                topology = None;
                web_tools = false;
              };
          } );
      ( "Post_config_patch"
      , Cmd.Post_config_patch
          {
            target = Masc_tui_protocol.Wire_config.Target_runtime;
            keeper_name = None;
            expected_sha256 = None;
            dry_run = true;
            ops = [];
          } );
      ( "Post_memory_act"
      , Cmd.Post_memory_act
          {
            keeper = "alpha";
            act = Masc_tui_protocol.Wire_knowledge.Act_resume;
          } );
      ( "Post_oauth_identity_refresh"
      , Cmd.Post_oauth_identity_refresh
          { keeper = "alpha"; provider = "github" } );
      ("Post_browser_tabs", Cmd.Post_browser_tabs { client_id = "c-1" });
      ( "Post_repo_add"
      , Cmd.Post_repo_add { url = "https://example.com/r.git"; branch = None } );
    ]
  in
  List.iter
    (fun (label, req) ->
      Alcotest.(check (float 0.001)) ("heavy POST: " ^ label) 30.0
        (Cmd_executor.timeout_sec_for_post req))
    heavy_posts;

  let fast_posts =
    [
      ( "Post_ask_answer"
      , Cmd.Post_ask_answer
          { keeper = "alpha"; ask_id = "ask-1"; answers = [] } );
      ( "Post_tool_approval"
      , Cmd.Post_tool_approval
          {
            keeper = "alpha";
            tool_call_id = "tc-1";
            approval_id = "ap-1";
            decision = Masc_tui_protocol.Wire_work.Tool_approve;
            expected_workspace = None;
          } );
      ( "Post_board_vote"
      , Cmd.Post_board_vote { post_id = "p-1"; direction = `Up } );
      ( "Post_task_cancel"
      , Cmd.Post_task_cancel
          {
            task_id = "task-1";
            reason = None;
            expected_workspace =
              { base_path = "/tmp/ws"; masc_root = "/tmp/ws/.masc" };
          } );
      ( "Post_gate_resolution"
      , Cmd.Post_gate_resolution
          { id = "g-1"; approved = true; reason = None } );
    ]
  in
  List.iter
    (fun (label, req) ->
      Alcotest.(check (float 0.001)) ("fast POST: " ^ label) 12.0
        (Cmd_executor.timeout_sec_for_post req))
    fast_posts;

  (* Chat stream reattach treats Timeout_detail identically to retryable Timeout/Stream_eof *)
  let running = Some Keeper_chat_operation.State_name.Running in
  let stream_hdr_timeout =
    Error
      (Msg.Transport
         (Health.Timeout_detail
            {
              phase = Health.Timeout_stream_header;
              after_sec = Some 45.0;
              path = Some "/api/v1/keepers/chat/stream";
            }))
  in
  let stream_idle_timeout =
    Error
      (Msg.Transport
         (Health.Timeout_detail
            {
              phase = Health.Timeout_stream_idle;
              after_sec = Some 120.0;
              path = Some "/api/v1/keepers/chat/stream";
            }))
  in
  Alcotest.(check (option (float 0.001)))
    "Timeout_stream_header reattaches on running op" (Some 1.0)
    (Cmd_executor.chat_reattach_delay ~acceptance:running ~terminal_seen:false
       ~reattaches:0 stream_hdr_timeout);
  Alcotest.(check (option (float 0.001)))
    "Timeout_stream_idle reattaches on running op" (Some 2.0)
    (Cmd_executor.chat_reattach_delay ~acceptance:running ~terminal_seen:false
       ~reattaches:1 stream_idle_timeout)

let () =
  Alcotest.run "masc_tui_app"
    [
      ( "cli_args"
      , [
          Alcotest.test_case "info flags (--version, --build-commit, --help)"
            `Quick test_cli_info_flags;
          Alcotest.test_case "flags, URLs, themes, languages" `Quick
            test_cli_flags_and_urls;
          Alcotest.test_case "invalid ports, themes, langs, URLs rejected"
            `Quick test_cli_rejects_invalid_inputs;
          Alcotest.test_case
            "removed --reasoning and --tool-view return migration Parse_error (exit 2)"
            `Quick test_cli_removed_reasoning_and_tool_view_flags;
          Alcotest.test_case "non-TTY exit code 2 detection" `Quick
            test_cli_non_tty_detection;
        ] );
      ( "frame_scheduler"
      , [
          Alcotest.test_case "60 FPS burst, 0 Hz idle sleep, rolling telemetry"
            `Quick test_scheduler_60fps_burst_and_0hz_idle;
          Alcotest.test_case "30 FPS animation & backpressure frame skip" `Quick
            test_scheduler_backpressure_and_animation;
        ] );
      ( "wake_bell_and_signals"
      , [
          Alcotest.test_case "lock-free bitmask coalesce & drain" `Quick
            test_wake_bell_coalesce_and_drain;
          Alcotest.test_case "signal pipe wake & timed timeout" `Quick
            test_wake_bell_signal_pipe_and_timeout;
          Alcotest.test_case "POSIX signal state machine & switch restore"
            `Quick test_signals_state_machine_and_restore;
          Alcotest.test_case "Ctrl+C arm, 3s auto-expire & withdraw on Paste/Mouse"
            `Quick test_ctrl_c_arm_expire_and_withdraw_on_paste_mouse;
        ] );
      ( "cmd_executor"
      , [
          Alcotest.test_case "admin.token loading, endpoint & guard headers"
            `Quick test_cmd_executor_auth_and_headers;
          Alcotest.test_case "stream mappings, URL safety & editor paths" `Quick
            test_cmd_executor_mappings_and_url_safety;
          Alcotest.test_case "async dispatch, Ui_bus replies & cancellation"
            `Quick test_cmd_executor_dispatch_and_cancellation;
          Alcotest.test_case
            "remote --url blocks local TOML $EDITOR & Target_keeper_create refuses fallback"
            `Quick test_remote_editor_escape_hatch_blocked;
          Alcotest.test_case "bus_key hash invariant, batch log stream & health readiness"
            `Quick test_bus_key_hash_and_stream_frames;
          Alcotest.test_case "raw and summary tool series each deliver their latest reply before drain"
            `Quick test_tool_series_readers_each_receive_the_latest_reply;
          Alcotest.test_case "Board inventory and receipts survive workspace changes and stream bursts"
            `Quick test_board_replies_survive_epoch_change_and_stream_overflow;
          Alcotest.test_case "queue drawer follows HTTP keysets across overlapping refreshes"
            `Quick test_queue_drawer_walks_all_http_pages;
          Alcotest.test_case "setup login stream propagates non-terminal error & delivers terminal receipt once"
            `Quick test_setup_login_stream_error_and_single_delivery;
          Alcotest.test_case "setup login EOF closes only the matching input form"
            `Quick test_setup_login_interruption_closes_owned_input;
          Alcotest.test_case "setup login stream output/auth_url/device_code/input_ready & OAuth tick gate"
            `Quick test_setup_login_stream_output_auth_url_input_ready_and_oauth_tick_gate;
          Alcotest.test_case "chat stream reattach decision" `Quick
            test_chat_reattach_decision;
          Alcotest.test_case "github login stream catches non-cancel exceptions and emits done"
            `Quick test_github_login_stream_exception_emits_done;
          Alcotest.test_case "Feature Wave 1: OSC 52 wrapping & safe atomic artifact export"
            `Quick test_feature_wave1_osc52_and_artifact_export_safety;
          Alcotest.test_case "P1-4/P1-6: bounded clipboard & URL opener + async Edit_wiki_page"
            `Quick test_bounded_clipboard_url_opener_and_async_wiki_editor;
          Alcotest.test_case "exhaustive per-endpoint timeout budgets & Timeout_detail chat reattach"
            `Quick test_timeout_budgets_and_reattach_on_timeout_detail;
        ] );
      ( "app"
      , [
          Alcotest.test_case "Kitty Ctrl+C detection & 100ms voice tick gating"
            `Quick test_app_ctrl_c_and_voice_tick_gate;
          Alcotest.test_case "caller stderr exit line & local tz offset" `Quick
            test_exit_line_fd_and_local_tz_offset;
          Alcotest.test_case "P2-1 Voice_runner ffmpeg avfoundation argv & mouse capture toggle"
            `Quick test_p2_voice_runner_ffmpeg_and_mouse_capture;
        ] );
    ]
