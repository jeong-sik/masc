(* What the telemetry ratchet counts as a new action handler.

   The scan reads a [--unified=0] diff, so every changed line arrives as an
   addition. Testing that line as text made two things read as new handlers: a
   call into a module whose name carries "dispatch", and a handler that only
   gained a parameter. Both named files the gate had already accepted. *)

open Alcotest

let contains ~needle haystack =
  String_util.string_contains_substring ~needle haystack

let source_root () =
  let cwd = Sys.getcwd () in
  if
    Sys.file_exists
      (Filename.concat cwd "scripts/ci/check-telemetry-coverage.sh")
  then cwd
  else
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> cwd

let script_path () =
  Filename.concat (source_root ()) "scripts/ci/check-telemetry-coverage.sh"

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path contents =
  let dir = Filename.dirname path in
  if not (Sys.file_exists dir) then
    ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote dir)));
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc contents)

(* stderr joins stdout: the gate prints findings on one and git's complaints on
   the other, and reading only one would let a crashed run look like a pass. *)
let sh ~cwd command =
  let out = Filename.temp_file "tel-gate-out" ".txt" in
  let code =
    Sys.command
      (Printf.sprintf "cd %s && { %s ; } >%s 2>&1" (Filename.quote cwd) command
         (Filename.quote out))
  in
  let text = read_file out in
  Sys.remove out;
  (code, text)

let git ~cwd args =
  let code, output = sh ~cwd (Printf.sprintf "git %s" args) in
  if code <> 0 then failwith (Printf.sprintf "git %s: %s" args output)

(* A repository holding [base_files] in its first commit and [head_files] in
   its second, with the gate copied in. Returns the base commit. *)
let repo_with ~dir ~base_files ~head_files =
  (* A branch name of its own, and no hooks: the fixture must not inherit the
     developer's global git configuration. A hook that refuses commits on
     [main] would otherwise fail this test on their machine and pass in CI. *)
  git ~cwd:dir "init -q -b tel-gate-fixture";
  Unix.mkdir (Filename.concat dir "empty-hooks") 0o755;
  git ~cwd:dir "config core.hooksPath empty-hooks";
  git ~cwd:dir "config user.email tel-gate@test.invalid";
  git ~cwd:dir "config user.name tel-gate-test";
  git ~cwd:dir "config commit.gpgsign false";
  write_file
    (Filename.concat dir "scripts/ci/check-telemetry-coverage.sh")
    (read_file (script_path ()));
  List.iter
    (fun (path, contents) -> write_file (Filename.concat dir path) contents)
    base_files;
  git ~cwd:dir "add -A";
  git ~cwd:dir "commit -q -m base";
  let code, base_sha = sh ~cwd:dir "git rev-parse HEAD" in
  if code <> 0 then failwith base_sha;
  List.iter
    (fun (path, contents) -> write_file (Filename.concat dir path) contents)
    head_files;
  git ~cwd:dir "add -A";
  git ~cwd:dir "commit -q -m head";
  String.trim base_sha

let gate ~dir ~base =
  sh ~cwd:dir
    (Printf.sprintf
       "bash scripts/ci/check-telemetry-coverage.sh --base %s --head HEAD" base)

let test_a_handler_that_did_not_exist_is_reported () =
  with_temp_dir "tel-gate-new" (fun dir ->
      let base =
        repo_with ~dir ~base_files:[]
          ~head_files:[ ("lib/probe.ml", "let dispatch_probe ~name = ignore name\n") ]
      in
      let code, output = gate ~dir ~base in
      check int "the gate refuses the diff" 1 code;
      check bool "and names the file it refused" true
        (contains ~needle:"lib/probe.ml" output))

let test_a_handler_that_only_gained_a_parameter_is_left_alone () =
  with_temp_dir "tel-gate-changed" (fun dir ->
      let base =
        repo_with ~dir
          ~base_files:[ ("lib/probe.ml", "let dispatch ~a = ignore a\n") ]
          ~head_files:[ ("lib/probe.ml", "let dispatch ~a ~b = ignore (a, b)\n") ]
      in
      let code, output = gate ~dir ~base in
      check int "the gate accepts the diff" 0 code;
      check bool "and the ratchet reports nothing" true
        (contains ~needle:"PASS: no new telemetry-uncovered" output))

let test_a_call_into_a_dispatch_module_is_not_a_handler () =
  with_temp_dir "tel-gate-call" (fun dir ->
      let base =
        repo_with ~dir ~base_files:[]
          ~head_files:
            [ ("lib/probe.ml", "let events = Board_dispatch.get_karma_ledger ()\n") ]
      in
      let code, _ = gate ~dir ~base in
      check int "binding a value from a dispatch module is not a handler" 0 code)

let () =
  run "telemetry_gate_handler_detection"
    [ ( "handler detection",
        [ test_case "a handler that did not exist is reported" `Quick
            test_a_handler_that_did_not_exist_is_reported
        ; test_case "a handler that only gained a parameter is left alone"
            `Quick test_a_handler_that_only_gained_a_parameter_is_left_alone
        ; test_case "a call into a dispatch module is not a handler" `Quick
            test_a_call_into_a_dispatch_module_is_not_a_handler
        ] )
    ]
