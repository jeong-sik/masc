let check = Alcotest.check
let bool = Alcotest.bool
let string = Alcotest.string

let contains haystack needle =
  let hn = String.length needle and hh = String.length haystack in
  let rec at i = i + hn <= hh && (String.sub haystack i hn = needle || at (i + 1)) in
  hn = 0 || at 0

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "/bin/rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let write_executable path body =
  let oc = open_out path in
  output_string oc body;
  close_out oc;
  Unix.chmod path 0o755

let test_missing_script_names_what_it_tried () =
  (* "" is how the operator's override reads when it is unset, so this also
     covers the empty-value case the resolver treats as absent. *)
  Unix.putenv "MASC_START_SCRIPT" "";
  match Masc_tui_server_control.start ~base_path:"/nonexistent-base" ~port:1 with
  | Masc_tui_server_control.Started script ->
      Alcotest.failf "expected no script, ran %s" script
  | Masc_tui_server_control.Spawn_failed detail ->
      Alcotest.failf "expected no script, spawn failed with %s" detail
  | Masc_tui_server_control.Script_missing candidates ->
      check bool "candidates are reported" true (candidates <> []);
      let sentence =
        Masc_tui_server_control.describe
          (Masc_tui_server_control.Script_missing candidates)
      in
      check bool "sentence names the override" true
        (contains sentence "MASC_START_SCRIPT")

let test_override_runs_and_receives_the_arguments () =
  with_temp_dir "tui-server-control" (fun dir ->
      let script = Filename.concat dir "fake-start.sh" in
      let observed = Filename.concat dir "argv" in
      write_executable script
        (Printf.sprintf "#!/bin/sh\nprintf '%%s' \"$*\" > %s\n"
           (Filename.quote observed));
      Unix.putenv "MASC_START_SCRIPT" script;
      match Masc_tui_server_control.start ~base_path:dir ~port:4242 with
      | Masc_tui_server_control.Script_missing _ ->
          Alcotest.fail "override was not used"
      | Masc_tui_server_control.Spawn_failed detail ->
          Alcotest.failf "spawn failed: %s" detail
      | Masc_tui_server_control.Started ran ->
          check string "the override ran" script ran;
          (* The child is not parented by us, so wait for the file it writes
             rather than for the process. *)
          let rec settle attempts =
            if Sys.file_exists observed then ()
            else if attempts = 0 then Alcotest.fail "script never ran"
            else (
              ignore (Unix.select [] [] [] 0.05);
              settle (attempts - 1))
          in
          settle 60;
          let ic = open_in observed in
          let argv = In_channel.input_all ic in
          close_in ic;
          check string "base path and port reach the script"
            (Printf.sprintf "--base-path %s --port 4242" dir)
            (String.trim argv))

let test_started_sentence_names_the_script () =
  check string "started sentence"
    "server start requested: /tmp/x.sh"
    (Masc_tui_server_control.describe
       (Masc_tui_server_control.Started "/tmp/x.sh"))

let () =
  Alcotest.run "tui_server_control"
    [ ( "start",
        [ Alcotest.test_case "missing script names what it tried" `Quick
            test_missing_script_names_what_it_tried;
          Alcotest.test_case "override runs with base path and port" `Quick
            test_override_runs_and_receives_the_arguments;
          Alcotest.test_case "started sentence names the script" `Quick
            test_started_sentence_names_the_script
        ] )
    ]
;;
