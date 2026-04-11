(** Coverage tests for #6641 iter10 — per-agent playground containment
    in [Tool_repair_loop.resolve_playground_working_dir].

    These tests exercise the shared helper directly (flat field
    signature — no Eio context, no Room config fixture) so that both
    [Tool_repair_loop.handle_start] and [Tool_keeper.handle_keeper_repair]
    inherit the same containment guarantees via a single unit-tested
    function. *)

open Masc_mcp

let () = Printf.printf "\n=== Tool_repair_loop containment (#6641 iter10) ===\n"

(* macOS canonicalises [$TMPDIR] through a symlink (`/var/folders/...`
   vs `/private/var/folders/...`), which trips `String.starts_with` on
   `playground_abs` when comparing against a realpath-ed child. Use
   [Unix.realpath] on the tmp dir immediately so every downstream
   [Unix.realpath] call returns a prefix that matches. *)
let fresh_base_path ~tag =
  let raw =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-repair-loop-containment-%s-%d" tag
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  Unix.mkdir raw 0o755;
  try Unix.realpath raw with Unix.Unix_error _ -> raw

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

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else loop (i + 1)
  in
  nlen = 0 || loop 0

let test name f =
  try
    f ();
    Printf.printf "✓ %s passed\n" name
  with e ->
    Printf.printf "✗ %s FAILED: %s\n" name (Printexc.to_string e);
    exit 1

(* Build a tmp [base_path] with two keeper playgrounds + an
   out-of-playground sibling dir so each branch of the gate can be
   exercised. Returns [(base_path, own_abs, other_abs, outside_abs)]. *)
let make_fixture ~tag =
  let base_path = fresh_base_path ~tag in
  let own_rel = ".masc/playground/agent-alpha" in
  let other_rel = ".masc/playground/agent-beta" in
  let outside_rel = "outside" in
  mkdir_p (Filename.concat base_path own_rel);
  mkdir_p (Filename.concat base_path other_rel);
  mkdir_p (Filename.concat base_path outside_rel);
  let own_abs =
    try Unix.realpath (Filename.concat base_path own_rel)
    with Unix.Unix_error _ -> Filename.concat base_path own_rel
  in
  let other_abs =
    try Unix.realpath (Filename.concat base_path other_rel)
    with Unix.Unix_error _ -> Filename.concat base_path other_rel
  in
  let outside_abs =
    try Unix.realpath (Filename.concat base_path outside_rel)
    with Unix.Unix_error _ -> Filename.concat base_path outside_rel
  in
  (base_path, own_abs, other_abs, outside_abs)

(* 1. Empty [working_dir_arg] defaults to the caller's own playground.
      Regression gate for the former [Sys.getcwd ()] default. *)
let () =
  test "empty_working_dir_defaults_to_own_playground" (fun () ->
    let base_path, own_abs, _other, _outside = make_fixture ~tag:"empty" in
    match
      Tool_repair_loop.resolve_playground_working_dir
        ~agent_name:"agent-alpha" ~base_path ~working_dir_arg:""
    with
    | Ok resolved ->
        assert (resolved = own_abs)
    | Error msg ->
        failwith (Printf.sprintf "expected Ok, got Error %S" msg))

(* 2. Whitespace-only [working_dir_arg] also defaults to own playground —
      pins the [String.trim] behaviour so a regression that drops trim
      does not fall through to [Unix.realpath ""]. *)
let () =
  test "whitespace_working_dir_defaults_to_own_playground" (fun () ->
    let base_path, own_abs, _other, _outside = make_fixture ~tag:"ws" in
    match
      Tool_repair_loop.resolve_playground_working_dir
        ~agent_name:"agent-alpha" ~base_path ~working_dir_arg:"   "
    with
    | Ok resolved -> assert (resolved = own_abs)
    | Error msg ->
        failwith (Printf.sprintf "expected Ok, got Error %S" msg))

(* 3. A path under the caller's own playground is accepted. *)
let () =
  test "own_playground_subpath_accepted" (fun () ->
    let base_path, own_abs, _other, _outside = make_fixture ~tag:"own_sub" in
    let sub = Filename.concat own_abs "repos" in
    Unix.mkdir sub 0o755;
    match
      Tool_repair_loop.resolve_playground_working_dir
        ~agent_name:"agent-alpha" ~base_path ~working_dir_arg:sub
    with
    | Ok resolved ->
        let sub_real =
          try Unix.realpath sub with Unix.Unix_error _ -> sub
        in
        assert (resolved = sub_real)
    | Error msg ->
        failwith (Printf.sprintf "expected Ok, got Error %S" msg))

(* 4. A path under another keeper's playground is rejected with a
      clear cross-keeper message that names the SSOT playground path. *)
let () =
  test "cross_keeper_playground_rejected" (fun () ->
    let base_path, _own, other_abs, _outside = make_fixture ~tag:"cross" in
    match
      Tool_repair_loop.resolve_playground_working_dir
        ~agent_name:"agent-alpha" ~base_path ~working_dir_arg:other_abs
    with
    | Ok resolved ->
        failwith
          (Printf.sprintf
             "expected Error, got Ok %S — cross-keeper write not gated"
             resolved)
    | Error msg ->
        assert (contains_substring msg "your own keeper playground");
        assert (contains_substring msg "Cross-keeper repair loops");
        assert (contains_substring msg "agent-alpha"))

(* 5. A path completely outside any playground is rejected. *)
let () =
  test "outside_playground_rejected" (fun () ->
    let base_path, _own, _other, outside_abs = make_fixture ~tag:"outside" in
    match
      Tool_repair_loop.resolve_playground_working_dir
        ~agent_name:"agent-alpha" ~base_path ~working_dir_arg:outside_abs
    with
    | Ok resolved ->
        failwith
          (Printf.sprintf
             "expected Error, got Ok %S — outside-playground accepted"
             resolved)
    | Error msg ->
        assert (contains_substring msg "your own keeper playground"))

(* 6. A non-existent [working_dir_arg] returns the "does not exist"
      error, not the containment error — so the LLM can distinguish
      "typo in path" from "tried to reach another keeper". *)
let () =
  test "nonexistent_working_dir_returns_not_accessible" (fun () ->
    let base_path, _own, _other, _outside =
      make_fixture ~tag:"nonexistent"
    in
    let bogus = Filename.concat base_path ".masc/playground/agent-alpha/absent-dir" in
    match
      Tool_repair_loop.resolve_playground_working_dir
        ~agent_name:"agent-alpha" ~base_path ~working_dir_arg:bogus
    with
    | Ok resolved ->
        failwith
          (Printf.sprintf "expected Error for bogus path, got Ok %S" resolved)
    | Error msg ->
        assert (contains_substring msg "does not exist"))

(* 7. If the caller's playground bundle does not exist yet, the
      helper must fail closed with an explicit error naming the
      playground path and the recovery action. Pre-iter10 code
      silently fell back to the raw non-realpath'd parent, which
      on macOS symlink-heavy filesystems could yield a false accept.
      Regression gate for GLM-5.1 MEDIUM finding on PR #6651. *)
let () =
  test "missing_playground_fails_closed" (fun () ->
    let base_path = fresh_base_path ~tag:"missing_pg" in
    (* Intentionally do NOT create `.masc/playground/agent-alpha/`.
       The caller has no playground bundle yet — every request must
       be rejected with an actionable error, not silently accepted. *)
    let sibling = Filename.concat base_path "some-dir" in
    Unix.mkdir sibling 0o755;
    match
      Tool_repair_loop.resolve_playground_working_dir
        ~agent_name:"agent-alpha" ~base_path ~working_dir_arg:sibling
    with
    | Ok resolved ->
        failwith
          (Printf.sprintf
             "expected fail-closed Error on missing playground, got Ok %S"
             resolved)
    | Error msg ->
        assert (contains_substring msg "playground directory");
        assert (contains_substring msg "does not exist");
        assert (contains_substring msg "masc_worktree_create"))

let () = Printf.printf "\n✅ All Tool_repair_loop containment tests passed!\n"
