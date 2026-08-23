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

let test_resolve_reports_every_path_it_tried () =
  (* Given to [resolve] rather than read from the tree: whether a real
     start-masc.sh sits above the test binary differs between a sandbox and
     CI, and that is not what this is checking. *)
  let candidates = [ "/nonexistent/a.sh"; "/nonexistent/b.sh" ] in
  match Masc_tui_server_control.resolve candidates with
  | Ok script -> Alcotest.failf "expected no script, resolved %s" script
  | Error tried ->
      check (Alcotest.list Alcotest.string) "every candidate is reported"
        candidates tried;
      let sentence =
        Masc_tui_server_control.describe
          (Masc_tui_server_control.Script_missing tried)
      in
      check bool "sentence names the override" true
        (contains sentence "MASC_START_SCRIPT");
      check bool "sentence names the paths" true
        (contains sentence "/nonexistent/b.sh")

let test_resolve_takes_the_first_executable_candidate () =
  with_temp_dir "tui-server-control-resolve" (fun dir ->
      let missing = Filename.concat dir "missing.sh" in
      let present = Filename.concat dir "present.sh" in
      let later = Filename.concat dir "later.sh" in
      write_executable present "#!/bin/sh\n";
      write_executable later "#!/bin/sh\n";
      match Masc_tui_server_control.resolve [ missing; present; later ] with
      | Error tried ->
          Alcotest.failf "expected a script, tried %s" (String.concat "," tried)
      | Ok script -> check string "first executable wins" present script)

let test_candidate_paths_lead_with_the_override () =
  Unix.putenv "MASC_START_SCRIPT" "/operator/choice.sh";
  match Masc_tui_server_control.candidate_paths () with
  | first :: _ -> check string "override is searched first" "/operator/choice.sh" first
  | [] -> Alcotest.fail "no candidates at all"

let test_empty_override_is_treated_as_absent () =
  (* OCaml has no unsetenv, so "" is how an unset override reads here; the
     resolver must not offer it as a path. *)
  Unix.putenv "MASC_START_SCRIPT" "";
  check bool "empty override is not a candidate" false
    (List.mem "" (Masc_tui_server_control.candidate_paths ()))

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
            else if attempts = 0 then (
              (* Say why. The script's own account is in the log the spawn
                 opens, and a bare "never ran" hides it. *)
              let log = Filename.concat dir (Filename.concat ".masc" "tui-server-start.log") in
              let detail =
                if Sys.file_exists log then (
                  let ic = open_in log in
                  let text = In_channel.input_all ic in
                  close_in ic;
                  text)
                else "(no " ^ log ^ ")"
              in
              Alcotest.failf "script never ran; spawn log: %s" detail)
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
        [ Alcotest.test_case "resolve reports every path it tried" `Quick
            test_resolve_reports_every_path_it_tried;
          Alcotest.test_case "resolve takes the first executable" `Quick
            test_resolve_takes_the_first_executable_candidate;
          Alcotest.test_case "override is searched first" `Quick
            test_candidate_paths_lead_with_the_override;
          Alcotest.test_case "empty override is absent" `Quick
            test_empty_override_is_treated_as_absent;
          Alcotest.test_case "override runs with base path and port" `Quick
            test_override_runs_and_receives_the_arguments;
          Alcotest.test_case "started sentence names the script" `Quick
            test_started_sentence_names_the_script
        ] )
    ]
;;
