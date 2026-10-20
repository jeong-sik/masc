(** Tests for objective allowed-root containment. *)

open Masc

(* ── Helpers ─────────────────────────────────────────────────────── *)

let with_env key value f =
  let prior = try Some (Sys.getenv key) with Not_found -> None in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None ->
          (* No "unset" in stdlib Unix; clear via empty value. The
             containment module reads via env_config which treats empty
             as "not set" for booleans. *)
          Unix.putenv key "")
    f

let with_tmp_base f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_containment_%d_%d"
         (Unix.getpid ()) (Random.int 1_000_000))
  in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rmrf p =
        match Unix.lstat p with
        | { st_kind = Unix.S_DIR; _ } ->
            Sys.readdir p
            |> Array.iter (fun e -> rmrf (Filename.concat p e));
            (try Unix.rmdir p with _ -> ())
        | _ -> (try Unix.unlink p with _ -> ())
        | exception Unix.Unix_error _ -> ()
      in
      rmrf dir)
    (fun () -> f dir)

let make_meta ~name ~sandbox () =
  let json =
    `Assoc
      [
        ("name", `String name);
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m ->
    { m with Masc.Keeper_meta_contract.sandbox_profile = sandbox }
  | Error e -> Alcotest.fail e

(* ── Tests ───────────────────────────────────────────────────────── *)

let test_local_profile_uses_same_containment () =
  with_tmp_base @@ fun base ->
  let config = Workspace.default_config base in
  let meta = make_meta ~name:"alice" ~sandbox:Keeper_types_profile_sandbox.Remote_ssh () in
  let outside = "/etc/passwd" in
  Alcotest.(check bool)
    "Local keeper uses allowed roots"
    true
    (Result.is_error
       (Keeper_sandbox_containment.check_read_target
          ~config ~meta ~target:outside))

let test_docker_keeper_blocks_outside () =
  with_tmp_base @@ fun base ->
  let config = Workspace.default_config base in
  let meta = make_meta ~name:"acme-sandbox" ~sandbox:Keeper_types_profile_sandbox.Docker () in
  let outside = "/etc/passwd" in
  match
    Keeper_sandbox_containment.check_read_target ~config ~meta ~target:outside
  with
  | Ok () ->
      Alcotest.fail "expected containment to block /etc/passwd for acme-sandbox"
  | Error refusal ->
      let msg = refusal.Keeper_alerting_path.message in
      Alcotest.(check bool) "error is objective containment rejection"
        true
        (let needle = "path_outside_sandbox:" in
         let len = String.length needle in
         String.length msg >= len
         && String.sub msg 0 len = needle);
      Alcotest.(check string) "a path outside the roots is the caller's to correct"
        "policy_rejection"
        (Tool_result.tool_failure_class_to_string refusal.failure_class)

let test_docker_keeper_allows_inside_playground () =
  with_tmp_base @@ fun base ->
  let config = Workspace.default_config base in
  let meta = make_meta ~name:"acme-sandbox" ~sandbox:Keeper_types_profile_sandbox.Docker () in
  let bundle = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let inside = Filename.concat bundle "scratch/scratch.md" in
  Alcotest.(check bool) "playground-internal path is allowed"
    true
    (Result.is_ok
       (Keeper_sandbox_containment.check_read_target
          ~config ~meta ~target:inside))

let test_docker_second_keeper_contained () =
  with_tmp_base @@ fun base ->
  let config = Workspace.default_config base in
  let meta = make_meta ~name:"poe" ~sandbox:Keeper_types_profile_sandbox.Docker () in
  let outside = "/etc/passwd" in
  Alcotest.(check bool) "Docker is also subject to containment"
    true
    (Result.is_error
       (Keeper_sandbox_containment.check_read_target
          ~config ~meta ~target:outside))

let test_path_just_outside_playground_blocked () =
  with_tmp_base @@ fun base ->
  let config = Workspace.default_config base in
  (* [check_target] with an explicit, synthetic root — not
     [check_read_target]/[Keeper_alerting_path.sandbox_roots ~meta] —
     because since task-634 / #26289 (operator: read_superset)
     [check_read_target] also allows anything under [/tmp] and the
     sandbox workspace root by design (Q1's whole point). A base built
     under the system temp dir (as [with_tmp_base] does) would make a
     "lookalike sibling of the bundle" trivially pass containment
     through the WIDER /tmp root, testing nothing. The prefix-without-
     slash bypass this test exists to catch belongs to one allowed
     root's own boundary, which [check_target] exercises directly. *)
  let root = "/nonexistent-masc-test-root/acme-sandbox" in
  let sibling = root ^ "_evil/secret.txt" in
  Alcotest.(check bool) "lookalike sibling path is blocked"
    true
    (Result.is_error
       (Keeper_alerting_path.resolve_keeper_target_path
          ~config ~sandbox_roots:[ root ] ~raw_path:sibling))

(* task-634 / #26289 (operator decision, ask938aaf519a5c543e: read_superset)
   — [check_read_target] now allows a path anywhere under [/tmp], the same
   objective scratch root the exec lane already judged. This is the
   intentional widening: a Read of a path Execute is allowed to create
   (e.g. a [git worktree add /tmp/...] destination) must not be refused
   by a narrower Read jail. *)
let test_tmp_scratch_allowed_for_read () =
  with_tmp_base @@ fun base ->
  let config = Workspace.default_config base in
  let meta = make_meta ~name:"acme-sandbox" ~sandbox:Keeper_types_profile_sandbox.Docker () in
  let scratch = "/tmp/task-634-read-superset-probe/file.txt" in
  Alcotest.(check bool) "an arbitrary /tmp path is allowed for read"
    true
    (Result.is_ok
       (Keeper_sandbox_containment.check_read_target
          ~config ~meta ~target:scratch))

(* The widening adds a literal root, [/tmp]; it must not also weaken the
   component-based containment that root itself gets. A lookalike
   SIBLING of [/tmp] (not a path under it) must stay blocked exactly
   like any other root's lookalike sibling. *)
let test_tmp_lookalike_sibling_still_blocked () =
  with_tmp_base @@ fun base ->
  let config = Workspace.default_config base in
  let meta = make_meta ~name:"acme-sandbox" ~sandbox:Keeper_types_profile_sandbox.Docker () in
  let lookalike = "/tmp_evil/secret.txt" in
  Alcotest.(check bool) "a sibling of /tmp itself is still blocked"
    true
    (Result.is_error
       (Keeper_sandbox_containment.check_read_target
          ~config ~meta ~target:lookalike))

(* ── Host root preparation ───────────────────────────────────────── *)

let host_root_error ~needle = function
  | Ok () -> Alcotest.failf "expected an error naming %s" needle
  | Error detail ->
    Alcotest.(check bool)
      ("the error names " ^ needle)
      true
      (String_util.contains_substring detail needle)

let test_host_root_is_created_with_its_parents () =
  with_tmp_base @@ fun base ->
  let root = Filename.concat base "playground/docker/alice" in
  (match Keeper_sandbox_control.ensure_host_root root with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "host root was not created: %s" detail);
  Alcotest.(check bool) "a directory now exists" true
    (Sys.file_exists root && Sys.is_directory root);
  match Keeper_sandbox_control.ensure_host_root root with
  | Ok () -> ()
  | Error detail -> Alcotest.failf "an existing host root was refused: %s" detail

let test_host_root_refuses_a_regular_file () =
  with_tmp_base @@ fun base ->
  let root = Filename.concat base "alice" in
  Out_channel.with_open_bin root (fun channel -> output_string channel "not a directory");
  host_root_error ~needle:"regular_file" (Keeper_sandbox_control.ensure_host_root root)

let test_host_root_accepts_a_symlink_to_a_directory () =
  with_tmp_base @@ fun base ->
  let target = Filename.concat base "elsewhere" in
  Unix.mkdir target 0o755;
  let root = Filename.concat base "alice" in
  Unix.symlink target root;
  match Keeper_sandbox_control.ensure_host_root root with
  | Ok () -> ()
  | Error detail -> Alcotest.failf "a link to a directory was refused: %s" detail

let test_host_root_refuses_a_symlink_that_points_nowhere () =
  with_tmp_base @@ fun base ->
  let root = Filename.concat base "alice" in
  Unix.symlink (Filename.concat base "missing") root;
  host_root_error ~needle:"points nowhere" (Keeper_sandbox_control.ensure_host_root root)

let test_host_root_reports_a_parent_that_is_not_a_directory () =
  with_tmp_base @@ fun base ->
  let parent = Filename.concat base "blocked" in
  Out_channel.with_open_bin parent (fun channel -> output_string channel "file");
  host_root_error ~needle:"cannot be inspected"
    (Keeper_sandbox_control.ensure_host_root (Filename.concat parent "alice"))

let () =
  Alcotest.run "Keeper_sandbox_containment"
    [
      ( "containment",
        [
          Alcotest.test_case "local profile uses same containment" `Quick
            test_local_profile_uses_same_containment;
          Alcotest.test_case "docker keeper blocks /etc/passwd" `Quick
            test_docker_keeper_blocks_outside;
          Alcotest.test_case "docker keeper allows inside playground"
            `Quick test_docker_keeper_allows_inside_playground;
          Alcotest.test_case "docker second keeper also contained" `Quick
            test_docker_second_keeper_contained;
          Alcotest.test_case "lookalike sibling path blocked" `Quick
            test_path_just_outside_playground_blocked;
          Alcotest.test_case "tmp scratch allowed for read" `Quick
            test_tmp_scratch_allowed_for_read;
          Alcotest.test_case "tmp lookalike sibling still blocked" `Quick
            test_tmp_lookalike_sibling_still_blocked;
        ] );
      ( "host_root",
        [
          Alcotest.test_case "created with its parents" `Quick
            test_host_root_is_created_with_its_parents;
          Alcotest.test_case "refuses a regular file" `Quick
            test_host_root_refuses_a_regular_file;
          Alcotest.test_case "accepts a symlink to a directory" `Quick
            test_host_root_accepts_a_symlink_to_a_directory;
          Alcotest.test_case "refuses a symlink that points nowhere" `Quick
            test_host_root_refuses_a_symlink_that_points_nowhere;
          Alcotest.test_case "reports a parent that is not a directory" `Quick
            test_host_root_reports_a_parent_that_is_not_a_directory;
        ] );
    ]
