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
     Cli_args.parse ~version:"1.2.3" ~build_commit:(Some "deadbeef")
       ~env:empty_env ~cwd:"/tmp/ws" [ "--version" ]
   with
  | Cli_args.Info (Cli_args.Print_version v) ->
      Alcotest.(check string) "version" "1.2.3" v
  | Cli_args.Run _ | Cli_args.Info _ | Cli_args.Parse_error _ ->
      Alcotest.fail "expected Print_version");
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
  | Cli_args.Run cfg -> Alcotest.(check int) "https default port" 443 cfg.port
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
      tts_available = false;
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
      speak = (fun ~text:_ ~voice_id:_ -> Ok ());
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
                     | Msg.Voice_speaking
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
                  tts_available = false;
                });
          record_until_stopped =
            (fun ~device:_ ~stop_signal ~on_level:_ ->
              Eio.Promise.await stop_signal;
              Error "stopped");
          transcribe = (fun ~audio_path:_ -> Error "unused");
          speak = (fun ~text:_ ~voice_id:_ -> Error "unused");
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
      ~publish:(fun res -> emitted := res :: !emitted)
      ~stream;
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
    App.should_emit_tick ~now_ns:t0 ~last_voice_tick_ns:0L
      ~toast_expires_ns:None ~voice_recording:false
  in
  Alcotest.(check bool) "idle emits no tick" false emit_idle;
  Alcotest.(check (option int64)) "idle has no deadline (0 Hz)" None dl_idle;
  let t_33ms = Int64.add t0 33_333_333L in
  let emit_33, dl_33 =
    App.should_emit_tick ~now_ns:t_33ms ~last_voice_tick_ns:t0
      ~toast_expires_ns:None ~voice_recording:true
  in
  Alcotest.(check bool) "no voice tick at +33ms" false emit_33;
  Alcotest.(check (option int64)) "next voice deadline at +100ms"
    (Some (Int64.add t0 App.voice_tick_interval_ns))
    dl_33;
  let t_100ms = Int64.add t0 App.voice_tick_interval_ns in
  let emit_100, dl_100 =
    App.should_emit_tick ~now_ns:t_100ms ~last_voice_tick_ns:t0
      ~toast_expires_ns:None ~voice_recording:true
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

let test_p2_voice_runner_ffmpeg_and_afplay () =
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

  (* 3. Audio player resolution for speak: closed sum afplay -> paplay -> aplay -> ffplay *)
  (match
     Voice_runner.resolve_audio_player_from
       ~find:(fun n ->
         if String.equal n "afplay" then Some "/usr/bin/afplay" else None)
   with
  | Some (Voice_runner.Player_afplay, "/usr/bin/afplay") -> ()
  | _ -> Alcotest.fail "expected Player_afplay");
  (match
     Voice_runner.resolve_audio_player_from
       ~find:(fun n ->
         if String.equal n "paplay" then Some "/usr/bin/paplay" else None)
   with
  | Some (Voice_runner.Player_paplay, "/usr/bin/paplay") -> ()
  | _ -> Alcotest.fail "expected Player_paplay");
  (match Voice_runner.resolve_audio_player_from ~find:(fun _ -> None) with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None when no player present");
  Alcotest.(check (array string)) "afplay argv"
    [| "/usr/bin/afplay"; "/tmp/reply.mp3" |]
    (Voice_runner.build_player_argv ~player:Voice_runner.Player_afplay
       ~bin_path:"/usr/bin/afplay" ~audio_path:"/tmp/reply.mp3");
  Alcotest.(check (array string)) "ffplay argv"
    [| "/usr/bin/ffplay"; "-nodisp"; "-autoexit"; "-loglevel"; "quiet"; "/tmp/reply.mp3" |]
    (Voice_runner.build_player_argv ~player:Voice_runner.Player_ffplay
       ~bin_path:"/usr/bin/ffplay" ~audio_path:"/tmp/reply.mp3");

  (* 4. Honest /api/v1/voice/probe/tts outcome decoding (never fakes Ok () on refusal or no-audio probe) *)
  let probe_answered_json =
    Yojson.Safe.from_string
      {|{"endpoints":[{"endpoint_id":"elevenlabs-1","kind":"elevenlabs","state":"answered","detail":"200 OK (4120 bytes)"}]}|}
  in
  (match Voice_runner.decode_tts_probe_outcome probe_answered_json with
  | Ok (Voice_runner.Tts_probe_answered_no_audio { endpoint_id = "elevenlabs-1"; _ }) ->
      ()
  | _ -> Alcotest.fail "expected Tts_probe_answered_no_audio");
  let probe_refused_json =
    Yojson.Safe.from_string
      {|{"endpoints":[{"endpoint_id":"elevenlabs-1","kind":"elevenlabs","state":"refused","detail":"missing api key"}]}|}
  in
  (match Voice_runner.decode_tts_probe_outcome probe_refused_json with
  | Ok (Voice_runner.Tts_probe_failed msg) ->
      Alcotest.(check bool) "refused reason preserved" true
        (String.length msg > 0)
  | _ -> Alcotest.fail "expected Tts_probe_failed on refused probe");
  let probe_file_json =
    Yojson.Safe.from_string {|{"audio_path":"/tmp/synth.wav"}|}
  in
  (match Voice_runner.decode_tts_probe_outcome probe_file_json with
  | Ok (Voice_runner.Tts_audio_file "/tmp/synth.wav") -> ()
  | _ -> Alcotest.fail "expected Tts_audio_file");

  (* 5. P1-13 / P2-7d: Mouse capture OFF by default, no ?1002h hijack, guarded [m] toggle *)
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
    (App.should_toggle_mouse_capture m_filter bare_eu)

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
          Alcotest.test_case "setup login stream propagates non-terminal error & delivers terminal receipt once"
            `Quick test_setup_login_stream_error_and_single_delivery;
        ] );
      ( "app"
      , [
          Alcotest.test_case "Kitty Ctrl+C detection & 100ms voice tick gating"
            `Quick test_app_ctrl_c_and_voice_tick_gate;
          Alcotest.test_case "caller stderr exit line & local tz offset" `Quick
            test_exit_line_fd_and_local_tz_offset;
          Alcotest.test_case "P2-1 Voice_runner ffmpeg avfoundation argv & afplay lookup"
            `Quick test_p2_voice_runner_ffmpeg_and_afplay;
        ] );
    ]
