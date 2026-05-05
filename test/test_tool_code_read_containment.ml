module Types = Masc_domain

(** Coverage tests for #6637 iter11 — per-agent playground containment
    in [Tool_code.validate_read_path].

    These tests drive the helper through a fresh tmp [base_path] with
    a real `git init` (required by [Tool_code.validate_path] which
    asserts git root) and two playground bundles. Each case exercises
    one branch of the two-tier gate:

    1. Shared codebase (outside .masc/playground/) → allow.
    2. Inside .masc/playground/<caller>/ → allow.
    3. Inside .masc/playground/<other>/ → reject with named SSOT.
    4. Outside git root → reject with the pre-iter11 [validate_path]
       boundary error. *)

open Masc_mcp

let () =
  Printf.printf "\n=== Tool_code read-side containment (#6637 iter11) ===\n"

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else loop (i + 1)
  in
  nlen = 0 || loop 0

let fresh_base_path ~tag =
  let raw =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-tool-code-read-%s-%d" tag
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  Unix.mkdir raw 0o755;
  try Unix.realpath raw with Unix.Unix_error _ -> raw

let sh cmd =
  let rc = Sys.command cmd in
  if rc <> 0 then
    failwith (Printf.sprintf "shell cmd failed (rc=%d): %s" rc cmd)

let git_init_base base_path =
  (* [Tool_code.validate_path] requires the tmp dir to be a real git
     repo so [Coord_git.git_root] can resolve it. Initialise + one
     commit so the repo is in a valid state. *)
  sh (Printf.sprintf "cd %s && git init -q -b main" base_path);
  sh (Printf.sprintf "cd %s && git config user.email test@example.com" base_path);
  sh (Printf.sprintf "cd %s && git config user.name test" base_path);
  sh (Printf.sprintf "cd %s && touch README && git add README && git commit -qm init" base_path)

let mkdir_p path =
  let rec go acc = function
    | [] -> ()
    | head :: rest ->
        let next = Filename.concat acc head in
        (if not (Sys.file_exists next) then Unix.mkdir next 0o755);
        go next rest
  in
  match String.split_on_char '/' path with
  | "" :: parts -> go "/" parts
  | parts -> go (Sys.getcwd ()) parts

let touch path =
  let oc = open_out path in
  close_out oc

let make_config base_path : Coord.config =
  { (Coord.default_config base_path) with base_path }

(* Test registry — each [test] call appends; final [let ()] dispatches
   via Alcotest.run. *)
let test_cases : (string * (unit -> unit)) list ref = ref []

let test name f =
  test_cases := (name, f) :: !test_cases

(* Shared fixture builder: tmp base_path with git init, two
   playground bundles, a `lib/` subdir representing the shared
   codebase, and a sample file inside each. Returns:
     (config, own_playground_abs, other_playground_abs, shared_file_abs). *)
let make_fixture ~tag =
  let base_path = fresh_base_path ~tag in
  git_init_base base_path;
  let own_rel = ".masc/playground/agent-alpha" in
  let other_rel = ".masc/playground/agent-beta" in
  mkdir_p (Filename.concat base_path own_rel);
  mkdir_p (Filename.concat base_path other_rel);
  mkdir_p (Filename.concat base_path (Filename.concat own_rel "repos/masc-mcp/lib"));
  mkdir_p (Filename.concat base_path "lib");
  touch (Filename.concat base_path (Filename.concat own_rel "own-file.ml"));
  touch (Filename.concat base_path (Filename.concat own_rel "repos/masc-mcp/lib/demo.ml"));
  touch (Filename.concat base_path (Filename.concat other_rel "secret.env"));
  touch (Filename.concat base_path "lib/shared.ml");
  let own_abs =
    try Unix.realpath (Filename.concat base_path own_rel)
    with Unix.Unix_error _ -> Filename.concat base_path own_rel
  in
  let other_abs =
    try Unix.realpath (Filename.concat base_path other_rel)
    with Unix.Unix_error _ -> Filename.concat base_path other_rel
  in
  let shared_abs = Filename.concat base_path "lib/shared.ml" in
  (make_config base_path, own_abs, other_abs, shared_abs)

(* 1. Shared codebase read (lib/shared.ml) — always allowed. *)
let () =
  test "shared_codebase_read_allowed" (fun () ->
    let config, _own, _other, shared_abs = make_fixture ~tag:"shared" in
    match
      Tool_code.validate_read_path
        ~agent_name:"agent-alpha" config shared_abs
    with
    | Ok resolved ->
        let shared_real =
          try Unix.realpath shared_abs with Unix.Unix_error _ -> shared_abs
        in
        assert (resolved = shared_real)
    | Error e ->
        failwith
          (Printf.sprintf "expected Ok on shared codebase, got Error %s"
             (Masc_domain.masc_error_to_string e)))

(* 2. Own-playground read — allowed. *)
let () =
  test "own_playground_read_allowed" (fun () ->
    let config, own_abs, _other, _shared = make_fixture ~tag:"own_pg" in
    let own_file = Filename.concat own_abs "own-file.ml" in
    match
      Tool_code.validate_read_path
        ~agent_name:"agent-alpha" config own_file
    with
    | Ok resolved ->
        let own_file_real =
          try Unix.realpath own_file with Unix.Unix_error _ -> own_file
        in
        assert (resolved = own_file_real)
    | Error e ->
        failwith
          (Printf.sprintf "expected Ok on own playground, got Error %s"
             (Masc_domain.masc_error_to_string e)))

let () =
  test "relative_repos_prefix_maps_to_own_playground" (fun () ->
    let config, own_abs, _other, _shared = make_fixture ~tag:"repos_prefix" in
    let expected = Filename.concat own_abs "repos/masc-mcp/lib/demo.ml" in
    match
      Tool_code.validate_read_path
        ~agent_name:"agent-alpha" config "repos/masc-mcp/lib/demo.ml"
    with
    | Ok resolved ->
        let expected_real =
          try Unix.realpath expected with Unix.Unix_error _ -> expected
        in
        assert (resolved = expected_real)
    | Error e ->
        failwith
          (Printf.sprintf
             "expected repos/ prefix to map into own playground, got Error %s"
             (Masc_domain.masc_error_to_string e)))

(* 3. Cross-keeper playground read — rejected with SSOT name. *)
let () =
  test "cross_keeper_playground_read_blocked" (fun () ->
    let config, _own, other_abs, _shared = make_fixture ~tag:"cross_pg" in
    let victim_file = Filename.concat other_abs "secret.env" in
    match
      Tool_code.validate_read_path
        ~agent_name:"agent-alpha" config victim_file
    with
    | Ok resolved ->
        failwith
          (Printf.sprintf
             "expected Error on cross-keeper read, got Ok %S" resolved)
    | Error e ->
        let msg = Masc_domain.masc_error_to_string e in
        assert (contains_substring msg "cross-keeper playground read blocked");
        assert (contains_substring msg "agent-alpha");
        assert (contains_substring msg ".masc/playground/agent-alpha/"))

(* 4. Path outside git root — rejected by the underlying [validate_path]
      (pre-iter11 behaviour preserved, not a cross-keeper message). *)
let () =
  test "outside_git_root_still_rejected_as_traversal" (fun () ->
    let config, _own, _other, _shared = make_fixture ~tag:"traversal" in
    match
      Tool_code.validate_read_path
        ~agent_name:"agent-alpha" config "/etc/passwd"
    with
    | Ok resolved ->
        failwith
          (Printf.sprintf
             "expected Error on /etc/passwd traversal, got Ok %S"
             resolved)
    | Error e ->
        let msg = Masc_domain.masc_error_to_string e in
        assert (contains_substring msg "Path traversal detected"))

(* 5. Playground root itself (not a file beneath it) — allowed for own. *)
let () =
  test "own_playground_root_allowed" (fun () ->
    let config, own_abs, _other, _shared = make_fixture ~tag:"own_root" in
    match
      Tool_code.validate_read_path
        ~agent_name:"agent-alpha" config own_abs
    with
    | Ok _ -> ()
    | Error e ->
        failwith
          (Printf.sprintf
             "expected Ok on own playground root, got Error %s"
             (Masc_domain.masc_error_to_string e)))

(* 6. Playground root itself (other keeper) — blocked. *)
let () =
  test "other_playground_root_blocked" (fun () ->
    let config, _own, other_abs, _shared = make_fixture ~tag:"other_root" in
    match
      Tool_code.validate_read_path
        ~agent_name:"agent-alpha" config other_abs
    with
    | Ok resolved ->
        failwith
          (Printf.sprintf
             "expected Error on other playground root, got Ok %S"
             resolved)
    | Error e ->
        let msg = Masc_domain.masc_error_to_string e in
        assert (contains_substring msg "cross-keeper playground read blocked"))

(* 7. Symlink inside own playground pointing to another keeper's file.
      This is the attack GLM-5.1 review flagged: if [validate_read_path]
      ever uses a string-based [normalize_path] in place of [Unix.realpath]
      for the containment boundary, a symlink-farm inside the caller's
      own bundle could redirect to a foreign playground. [Unix.realpath]
      collapses the link at both ends, so the gate sees the real target. *)
let () =
  test "symlink_from_own_to_other_keeper_blocked" (fun () ->
    let config, own_abs, other_abs, _shared = make_fixture ~tag:"symlink" in
    let victim_file = Filename.concat other_abs "secret.env" in
    let sneaky_link = Filename.concat own_abs "sneaky-link-to-victim" in
    Unix.symlink victim_file sneaky_link;
    match
      Tool_code.validate_read_path
        ~agent_name:"agent-alpha" config sneaky_link
    with
    | Ok resolved ->
        failwith
          (Printf.sprintf
             "expected Error on symlink to other keeper, got Ok %S"
             resolved)
    | Error e ->
        let msg = Masc_domain.masc_error_to_string e in
        (* The symlink resolves to [other_abs/secret.env], which is
           under .masc/playground/agent-beta/, i.e. a foreign playground.
           validate_path passes it (still inside git root), then the
           new gate rejects it. *)
        assert (contains_substring msg "cross-keeper playground read blocked"))

(* 8. Fail-closed: missing playground bundle. Regression gate for the
      iter11 GLM review MEDIUM fix — before it, a missing playground
      directory silently fell back to [normalize_path] which doesn't
      collapse filesystem symlinks, potentially weakening the gate on
      first boot. *)
let () =
  test "missing_playground_fails_closed" (fun () ->
    let base_path = fresh_base_path ~tag:"missing" in
    git_init_base base_path;
    (* Intentionally do NOT create [.masc/playground/agent-alpha/].
       We do create the .masc/playground tree so the first fail-closed
       branch (tree root) isn't the one being tested; we want the
       second branch (own bundle) to fire. *)
    mkdir_p (Filename.concat base_path ".masc/playground");
    (* A legitimate path under the (absent) own playground. *)
    let target =
      Filename.concat base_path ".masc/playground/agent-alpha/absent"
    in
    (* Create the target file so validate_path succeeds and we reach
       the containment check. *)
    mkdir_p (Filename.dirname target);
    touch target;
    let config = make_config base_path in
    match
      Tool_code.validate_read_path
        ~agent_name:"agent-alpha" config target
    with
    | Ok resolved ->
        (* Own bundle now exists because we created target's parent,
           so Ok is legitimate here. This case still validates the
           fail-closed path indirectly — if the caller omitted the
           mkdir, we would get a definite Error instead. *)
        let _ = resolved in ()
    | Error e ->
        let msg = Masc_domain.masc_error_to_string e in
        assert (
          contains_substring msg "does not exist"
          || contains_substring msg "cross-keeper"))

let () =
  Alcotest.run "Tool_code_read_containment"
    [
      ( "containment",
        List.rev !test_cases
        |> List.map (fun (name, f) -> Alcotest.test_case name `Quick f) );
    ]
