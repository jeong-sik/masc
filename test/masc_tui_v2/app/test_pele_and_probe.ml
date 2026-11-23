open Alcotest
module Pele = Masc_tui_app.Pele
module App = Masc_tui_app.App
module Signals = Masc_tui_app.Signals
module Wake_bell = Masc_tui_app.Wake_bell
module Probe = Masc_tui_term.Probe
module Palette = Masc_tui_term.Palette
module Presenter = Masc_tui_term.Presenter
module Input_decoder = Masc_tui_term.Input_decoder
module Msg = Masc_tui_store.Msg

let with_cache test =
  let directory = Filename.temp_dir "tui-pele-protocol-" "" in
  Fun.protect
    ~finally:(fun () -> Unix.rmdir directory)
    (fun () ->
      let result = test directory in
      check int "temporary files removed" 0
        (Array.length (Sys.readdir directory));
      result)

let write_file path value =
  Out_channel.with_open_bin path (fun out ->
      Out_channel.output_string out value)

let sample_scene =
  Pele.scene ~format:Pele.Mermaid ~max_width:640 ~font_size:16 ~now_ms:0L
    ~colors:None "graph TD; A-->B"

let run_probe ~cache_dir ~ending ~stderr ~stdout =
  let request = ref None in
  let runner ~input ~output ~errors =
    request := Some (Yojson.Safe.from_file input);
    write_file output stdout;
    write_file errors stderr;
    ending
  in
  let crop = { Pele.left = 0.; top = 0.; right = 0.5; bottom = 0.5 } in
  let raster = { Pele.width = 320; height = 240; crop = Some crop } in
  let result = Pele.render ~cache_dir ~runner ~raster sample_scene in
  (result, Option.get !request)

let test_pele_confirmed_protocol_v1 () =
  with_cache (fun cache_dir ->
      let palette =
        Palette.of_responses
          ~foreground:(Some (Palette.make_rgb ~red:226 ~green:232 ~blue:240))
          ~background:(Some (Palette.make_rgb ~red:15 ~green:23 ~blue:42))
          ~ansi:(Array.make Palette.ansi_slot_count None)
        |> Option.get
      in
      let fg, bg = Pele.colors_of_palette palette in
      check string "foreground hex" "#e2e8f0" fg;
      check string "background hex" "#0f172a" bg;

      let rendered, request =
        run_probe ~cache_dir ~ending:(Pele.Exited (Unix.WEXITED 0))
          ~stderr:"node warning\n" ~stdout:"masc-pele-protocol:1\npng"
      in
      check (result string string) "confirmed image" (Ok "png") rendered;
      let open Yojson.Safe.Util in
      check int "protocol version" 1 (request |> member "protocol" |> to_int);
      check string "format mermaid" "mermaid"
        (request |> member "format" |> to_string);
      check int "raster width" 320
        (request |> member "raster" |> member "width" |> to_int);

      let svg_scene =
        Pele.scene ~format:Pele.Svg ~max_width:1240 ~font_size:16 ~now_ms:42L
          ~colors:(Some (fg, bg)) "<svg xmlns=\"http://www.w3.org/2000/svg\"/>"
      in
      let svg_req = ref None in
      let runner ~input ~output ~errors =
        svg_req := Some (Yojson.Safe.from_file input);
        write_file output "masc-pele-protocol:1\nsvg-png";
        write_file errors "";
        Pele.Exited (Unix.WEXITED 0)
      in
      let svg_res = Pele.render ~cache_dir ~runner svg_scene in
      check (result string string) "confirmed svg" (Ok "svg-png") svg_res;
      let req = Option.get !svg_req in
      check string "format svg" "svg" (req |> member "format" |> to_string);
      check string "colors.foreground" "#e2e8f0"
        (req |> member "colors" |> member "foreground" |> to_string);
      check string "colors.background" "#0f172a"
        (req |> member "colors" |> member "background" |> to_string);

      let graph_scene =
        Pele.scene ~format:Pele.Graph ~max_width:640 ~font_size:16 ~now_ms:0L
          ~colors:None "{\"nodes\":[],\"edges\":[]}"
      in
      let graph_req = ref None in
      let graph_runner ~input ~output ~errors =
        graph_req := Some (Yojson.Safe.from_file input);
        write_file output "masc-pele-protocol:1\ngraph-png";
        write_file errors "";
        Pele.Exited (Unix.WEXITED 0)
      in
      let graph_res = Pele.render ~cache_dir ~runner:graph_runner graph_scene in
      check (result string string) "confirmed graph" (Ok "graph-png") graph_res;
      check string "format graph" "graph"
        (Option.get !graph_req |> member "format" |> to_string))

let test_pele_unconfirmed_and_errors () =
  with_cache (fun cache_dir ->
      List.iter
        (fun stdout ->
          let result, _ =
            run_probe ~cache_dir ~ending:(Pele.Exited (Unix.WEXITED 0))
              ~stderr:"" ~stdout
          in
          check bool "unconfirmed output rejected" true (Result.is_error result))
        [
          "\137PNG\r\n\026\nraw";
          "masc-pele-protocol:1";
          "masc-pele-protocol:2\npng";
          "noise\nmasc-pele-protocol:1\npng";
        ];

      let check_error stdout =
        let result, _ =
          run_probe ~cache_dir ~ending:(Pele.Exited (Unix.WEXITED 1))
            ~stderr:"bad diagram\n" ~stdout
        in
        match result with
        | Error message ->
            check bool "diagnostic retained" true
              (String.ends_with ~suffix:"bad diagram" message);
            message
        | Ok _ -> fail "failed renderer returned an image"
      in
      let confirmed = check_error "masc-pele-protocol:1\n" in
      let unconfirmed = check_error "" in
      check bool "confirmed vs unconfirmed error distinct" true
        (not (String.equal confirmed unconfirmed));

      let empty, _ =
        run_probe ~cache_dir ~ending:(Pele.Exited (Unix.WEXITED 0)) ~stderr:""
          ~stdout:"masc-pele-protocol:1\n"
      in
      check bool "empty pixels rejected" true (Result.is_error empty);

      let killed ending =
        match
          run_probe ~cache_dir ~ending ~stderr:""
            ~stdout:"masc-pele-protocol:1\npartial"
        with
        | Error message, _ -> message
        | Ok _, _ -> fail "killed renderer returned an image"
      in
      let endings =
        List.map killed
          [
            Pele.Exited (Unix.WSIGNALED Sys.sigkill);
            Pele.Killed_at_deadline;
            Pele.Cancelled;
          ]
      in
      check int "signal / deadline / cancelled errors are distinct" 3
        (List.length (List.sort_uniq String.compare endings)))

let test_pele_process_runner_timeout_and_missing_binary () =
  with_cache (fun cache_dir ->
      let missing_runner =
        Pele.process_runner ~executable:"/nonexistent/masc-pele-missing"
          ~timeout_s:0.5 ()
      in
      (match Pele.render ~cache_dir ~runner:missing_runner sample_scene with
       | Error msg -> check bool "non-empty missing error" true (String.length msg > 0)
       | Ok _ -> fail "missing executable must fail");
      (* Bounded timeout kills and reaps a hanging subprocess cleanly *)
      let script_dir = Filename.temp_dir "tui-pele-hang-" "" in
      let script = Filename.concat script_dir "hang.sh" in
      Fun.protect
        ~finally:(fun () ->
          (try Sys.remove script with Sys_error _ -> ());
          try Unix.rmdir script_dir with Unix.Unix_error _ -> ())
        (fun () ->
          write_file script "#!/bin/sh\nexec sleep 30\n";
          Unix.chmod script 0o700;
          Eio_main.run @@ fun env ->
          let clock = Eio.Stdenv.clock env in
          let hang_runner =
            Pele.process_runner ~executable:script ~timeout_s:0.06 ~clock ()
          in
          match Pele.render ~cache_dir ~runner:hang_runner sample_scene with
          | Error msg ->
              check string "deadline kill error"
                "Pele was killed at its deadline" msg
          | Ok _ -> fail "hanging subprocess must be killed at deadline"))

let test_startup_probe_collection_and_capabilities () =
  check bool "default env requests palette" true
    (App.palette_requested_of_env ~getenv:(fun _ -> None));
  check bool "NO_COLOR skips palette query" false
    (App.palette_requested_of_env ~getenv:(function
       | "NO_COLOR" -> Some "1"
       | _ -> None));
  check bool "MASC_TUI_FORCE_COLOR=1 overrides NO_COLOR" true
    (App.palette_requested_of_env ~getenv:(function
       | "NO_COLOR" -> Some "1"
       | "MASC_TUI_FORCE_COLOR" -> Some "1"
       | _ -> None));

  let safe_close fd =
    match Unix.close fd with () -> () | exception Unix.Unix_error _ -> ()
  in
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in

  (* 1. Responsive terminal: replies populate Palette, graphics, cell_pixels, and replay user keys *)
  let rd1, wr1 = Unix.pipe () in
  Fun.protect
    ~finally:(fun () ->
      safe_close rd1;
      safe_close wr1)
    (fun () ->
      Unix.set_nonblock rd1;
      let stream =
        "\x1b[6;18;9t\x1b]10;rgb:eeee/f0f0/ffff\x1b\\\x1b]11;rgb:0000/0000/0808\x1b\\\x1b_Gi=31;OK\x1b\\jk"
      in
      ignore (Unix.write_substring wr1 stream 0 (String.length stream) : int);
      let pd =
        App.collect_startup_probe ~timeout_s:0.2 ~clock ~fd:rd1
          ~palette_requested:true ()
      in
      let snap = Probe.snapshot pd in
      check string "early user keystrokes preserved in replay" "jk" snap.replay;
      check (option (pair int int)) "cell_pixels observed" (Some (9, 18))
        snap.cell_pixels;
      check bool "graphics supported" true
        (Option.equal Probe.equal_graphics_reply snap.graphics
           (Some Probe.Graphics_supported));
      check bool "palette observed" true (Option.is_some snap.palette);

      let presenter =
        Presenter.create ~cols:80 ~rows:24
          ~capabilities:Presenter.default_capabilities
      in
      App.apply_probe_observation ~presenter (Probe.observation pd);
      let caps = Presenter.capabilities presenter in
      check (option (pair int int)) "presenter cell_pixels populated"
        (Some (9, 18)) caps.cell_pixels;
      check bool "presenter graphics populated" true
        (Option.equal Probe.equal_graphics_reply caps.graphics
           (Some Probe.Graphics_supported));
      check bool "Palette.current populated" true
        (Option.is_some (Palette.current ()));
      check bool "Probe.current_observation populated" true
        (Option.equal Probe.equal_graphics_reply
           (Probe.current_observation ()).graphics
           (Some Probe.Graphics_supported)));

  (* 2. Non-responding terminal: bounded timeout returns cleanly without hanging *)
  let rd2, wr2 = Unix.pipe () in
  Fun.protect
    ~finally:(fun () ->
      safe_close rd2;
      safe_close wr2)
    (fun () ->
      Unix.set_nonblock rd2;
      let pd =
        App.collect_startup_probe ~timeout_s:0.03 ~clock ~fd:rd2
          ~palette_requested:true ()
      in
      let obs = Probe.observation pd in
      check bool "silent terminal has no graphics" true (Option.is_none obs.graphics);
      check bool "silent terminal has no cell_pixels" true
        (Option.is_none obs.cell_pixels);
      check bool "silent terminal has no palette" true (Option.is_none obs.palette);

      (* 3. Late terminal replies arriving via Input_decoder update the same owner *)
      let bell = Wake_bell.create () in
      let signals = Signals.create ~bell in
      let queue : Msg.t Eio.Stream.t = Eio.Stream.create max_int in
      let updates = ref [] in
      let on_reply reply =
        match App.apply_terminal_reply ~probe_decoder:pd reply with
        | Some next_obs -> updates := next_obs :: !updates
        | None -> ()
      in
      let dec = Input_decoder.create () in
      let events =
        Input_decoder.feed_string dec
          "\x1b[6;20;10t\x1b_Gi=31;OK\x1b\\x"
      in
      App.dispatch_decoded_events ~signals ~bell ~input_queue:queue ~on_reply
        events;
      check int "two late observation updates" 2 (List.length !updates);
      let latest = List.hd !updates in
      check (option (pair int int)) "late cell_pixels recorded" (Some (10, 20))
        latest.cell_pixels;
      check bool "late graphics recorded" true
        (Option.equal Probe.equal_graphics_reply latest.graphics
           (Some Probe.Graphics_supported));
      match Eio.Stream.take_nonblocking queue with
      | Some (Msg.Key_event { key = Input_decoder.Char "x"; _ }) -> ()
      | Some _ | None -> fail "expected key 'x' dispatched alongside late replies")

let () =
  run "masc_tui_v2_pele_and_probe"
    [
      ( "pele",
        [
          test_case "protocol v1 confirmed Mermaid/Svg/Graph + palette colors"
            `Quick test_pele_confirmed_protocol_v1;
          test_case "unconfirmed output, errors, deadline & cancellation" `Quick
            test_pele_unconfirmed_and_errors;
          test_case "process_runner missing binary & non-protocol output" `Quick
            test_pele_process_runner_timeout_and_missing_binary;
        ] );
      ( "startup_probe",
        [
          test_case "bounded startup probe, replay, Presenter caps, late replies"
            `Quick test_startup_probe_collection_and_capabilities;
        ] );
    ]
