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

let make_meta ?(allowed_paths = []) ~name ~sandbox () =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String name);
        ("trace_id", `String "test-trace-containment");
        ("policy_voice_enabled", `Bool false);
        ("sandbox_profile",
         `String (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox));
        ("allowed_paths", `List (List.map (fun path -> `String path) allowed_paths));
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> Alcotest.fail e

(* ── Tests ───────────────────────────────────────────────────────── *)

let test_local_profile_uses_same_containment () =
  with_tmp_base @@ fun base ->
  let config = Workspace.default_config base in
  let meta = make_meta ~name:"alice" ~sandbox:Keeper_types_profile_sandbox.Local () in
  let outside = "/etc/passwd" in
  Alcotest.(check bool)
    "Local keeper uses allowed roots"
    true
    (Result.is_error
       (Keeper_sandbox_containment.check_read_target
          ~config ~meta ~target:outside))

let test_explicit_external_root_is_allowed () =
  with_tmp_base @@ fun base ->
  let config = Workspace.default_config base in
  let meta =
    make_meta
      ~allowed_paths:[ "/etc" ]
      ~name:"alice"
      ~sandbox:Keeper_types_profile_sandbox.Local
      ()
  in
  Alcotest.(check bool)
    "explicit external root"
    true
    (Result.is_ok
       (Keeper_sandbox_containment.check_read_target
          ~config
          ~meta
          ~target:"/etc/passwd"))

let test_docker_keeper_blocks_outside () =
  with_tmp_base @@ fun base ->
  let config = Workspace.default_config base in
  let meta = make_meta ~name:"minjae" ~sandbox:Keeper_types_profile_sandbox.Docker () in
  let outside = "/etc/passwd" in
  match
    Keeper_sandbox_containment.check_read_target ~config ~meta ~target:outside
  with
  | Ok () ->
      Alcotest.fail "expected containment to block /etc/passwd for minjae"
  | Error msg ->
      Alcotest.(check bool) "error is objective containment rejection"
        true
        (let needle = "path_outside_sandbox:" in
         let len = String.length needle in
         String.length msg >= len
         && String.sub msg 0 len = needle)

let test_docker_keeper_allows_inside_playground () =
  with_tmp_base @@ fun base ->
  let config = Workspace.default_config base in
  let meta = make_meta ~name:"minjae" ~sandbox:Keeper_types_profile_sandbox.Docker () in
  let bundle = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let inside = Filename.concat bundle "mind/scratch.md" in
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
  let meta = make_meta ~name:"minjae" ~sandbox:Keeper_types_profile_sandbox.Docker () in
  (* Sibling directory with a name that LOOKS like a prefix of the playground
     path; must still be blocked (prevents the classic prefix-without-slash
     containment bypass). *)
  let bundle_normalized =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Keeper_alerting_path.normalize_path_for_check
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let sibling = bundle_normalized ^ "_evil/secret.txt" in
  Alcotest.(check bool) "lookalike sibling path is blocked"
    true
    (Result.is_error
       (Keeper_sandbox_containment.check_read_target
          ~config ~meta ~target:sibling))

let () =
  Alcotest.run "Keeper_sandbox_containment"
    [
      ( "containment",
        [
          Alcotest.test_case "local profile uses same containment" `Quick
            test_local_profile_uses_same_containment;
          Alcotest.test_case "explicit root outside base is allowed" `Quick
            test_explicit_external_root_is_allowed;
          Alcotest.test_case "docker keeper blocks /etc/passwd" `Quick
            test_docker_keeper_blocks_outside;
          Alcotest.test_case "docker keeper allows inside playground"
            `Quick test_docker_keeper_allows_inside_playground;
          Alcotest.test_case "docker second keeper also contained" `Quick
            test_docker_second_keeper_contained;
          Alcotest.test_case "lookalike sibling path blocked" `Quick
            test_path_just_outside_playground_blocked;
        ] );
    ]
