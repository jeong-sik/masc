(** SSOT invariants for keeper sandbox / playground path resolution.

    Plan v3 Leak 8 hypothesis (2026-04-25 evidence): masc-improver's
    tool_read_file returned a path resolver root of
    [/Users/dancer/me/.masc/playground/analyst] while the request's
    runtime_contract.sandbox_root was
    [/Users/dancer/me/.masc/playground/docker/masc-improver/]. The
    initial guess was that two parallel path systems
    ([keeper_playground_root] in [keeper_tool_shared_runtime] versus
    [Keeper_sandbox.allowed_root_rel_of_meta]) had drifted apart.

    Code inspection in keeper_sandbox.ml:100 found that
    [allowed_root_rel_of_meta] is a thin alias for
    [host_root_rel_of_meta], so the SSOT is in fact maintained by
    construction.  These tests pin that invariant so any future
    regression that reintroduces a separate root for one helper is
    caught at build time rather than producing a silent
    wrong-keeper-bound fs_read in production.

    The actual production wrong-root symptom is therefore most
    plausibly a Leak 2 manifestation (the request's resolved
    keeper_meta is the wrong one), not a Leak 8 path-system split.
    PR-F closes the upstream identity drift; if fs_read still
    surfaces the wrong root after PR-F lands, this test suite
    should still pass and the diagnosis must look elsewhere. *)

module Workspace = Masc.Workspace
module Keeper_types = Keeper_types
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_sandbox_docker = Masc.Keeper_sandbox_docker

let temp_dir () =
  let path = Filename.temp_file "masc-path-ssot-" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let make_meta ~name ~sandbox =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ( "sandbox_profile",
          `String (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox) );
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> Alcotest.fail e

let make_config () =
  let base = temp_dir () in
  Unix.mkdir (Filename.concat base ".masc") 0o755;
  Workspace.default_config base

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o755)

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let write_keeper_toml ~config ~name ~sandbox_profile =
  let dir =
    Filename.concat
      (Filename.concat
         (Filename.concat config.Workspace.base_path ".masc")
         "config")
      "keepers"
  in
  mkdir_p dir;
  write_file
    (Filename.concat dir (name ^ ".toml"))
    (Printf.sprintf "[keeper]\nsandbox_profile = %S\n" sandbox_profile)

(* ── Invariant: host_root_abs_of_meta == base_path / allowed_root_rel_of_meta ── *)

let assert_ssot ~name ~sandbox =
  let config = make_config () in
  let meta = make_meta ~name ~sandbox in
  let host_abs = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let allowed_rel = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
  let constructed = Filename.concat config.base_path allowed_rel in
  Alcotest.(check string)
    (Printf.sprintf
       "[%s/%s] host_root_abs_of_meta must equal base_path / \
        allowed_root_rel_of_meta"
       name
       (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox))
    constructed host_abs

let test_ssot_docker_keeper () =
  assert_ssot ~name:"sangsu" ~sandbox:Keeper_types_profile_sandbox.Docker

let test_ssot_local_keeper () =
  assert_ssot ~name:"analyst" ~sandbox:Keeper_types_profile_sandbox.Local

let test_ssot_docker_keeper_with_dashed_name () =
  assert_ssot ~name:"masc-improver" ~sandbox:Keeper_types_profile_sandbox.Docker

(* ── Wrong-meta detection: changing the keeper name MUST change the root ── *)

let test_root_depends_on_keeper_name () =
  (* If two distinct keepers can resolve to the same playground root,
     a wrong-meta lookup (Leak 2) would not be detectable from the
     fs_read root alone — the production "playground/analyst seen for
     masc-improver request" symptom proves the roots are in fact
     name-distinct, so this invariant must hold. *)
  let config = make_config () in
  let m1 = make_meta ~name:"masc-improver" ~sandbox:Keeper_types_profile_sandbox.Docker in
  let m2 = make_meta ~name:"analyst" ~sandbox:Keeper_types_profile_sandbox.Docker in
  let r1 = Keeper_sandbox.host_root_abs_of_meta ~config m1 in
  let r2 = Keeper_sandbox.host_root_abs_of_meta ~config m2 in
  Alcotest.(check bool)
    "distinct keeper names must yield distinct host roots" true
    (not (String.equal r1 r2))

let test_root_depends_on_sandbox_profile () =
  (* The Docker / Local profile flips the playground subtree
     (e.g. /playground/docker/<name>/ vs /playground/<name>/), so two
     metas that share a name but differ in profile must also diverge. *)
  let config = make_config () in
  let m_docker =
    make_meta ~name:"sangsu" ~sandbox:Keeper_types_profile_sandbox.Docker
  in
  let m_local =
    make_meta ~name:"sangsu" ~sandbox:Keeper_types_profile_sandbox.Local
  in
  let r_docker = Keeper_sandbox.host_root_abs_of_meta ~config m_docker in
  let r_local = Keeper_sandbox.host_root_abs_of_meta ~config m_local in
  Alcotest.(check bool)
    "same name across docker/local profiles must yield distinct roots"
    true
    (not (String.equal r_docker r_local))

(* ── Idempotence: same meta twice must produce the same answer ── *)

let test_ssot_idempotent () =
  let config = make_config () in
  let meta = make_meta ~name:"scholar" ~sandbox:Keeper_types_profile_sandbox.Docker in
  let r1 = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let r2 = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Alcotest.(check string) "host_root_abs_of_meta is pure / idempotent" r1 r2

let test_config_agent_projection_docker () =
  let config = make_config () in
  write_keeper_toml ~config ~name:"sangsu" ~sandbox_profile:"docker";
  let agent_name = "keeper-sangsu-agent" in
  Alcotest.(check string)
    "config-backed backend"
    "docker"
    (Keeper_sandbox.backend_of_config_agent ~config ~agent_name
     |> Keeper_sandbox.backend_to_string);
  Alcotest.(check string)
    "config-backed host root rel"
    ".masc/playground/docker/sangsu/"
    (Keeper_sandbox.host_root_rel_of_config_agent ~config ~agent_name);
  let visible =
    Filename.concat
      (Keeper_sandbox.container_root agent_name)
      "repos/masc/lib/foo.ml"
  in
  let expected =
    Filename.concat
      config.Workspace.base_path
      ".masc/playground/docker/sangsu/repos/masc/lib/foo.ml"
  in
  Alcotest.(check string)
    "sandbox-visible path maps to backend-scoped host path"
    expected
    (Keeper_sandbox.host_path_of_visible_path ~config ~agent_name visible)

let test_config_agent_projection_local () =
  let config = make_config () in
  let agent_name = "keeper-sangsu-agent" in
  Alcotest.(check string)
    "missing config defaults to local backend"
    "local"
    (Keeper_sandbox.backend_of_config_agent ~config ~agent_name
     |> Keeper_sandbox.backend_to_string);
  Alcotest.(check string)
    "local host root rel"
    ".masc/playground/sangsu/"
    (Keeper_sandbox.host_root_rel_of_config_agent ~config ~agent_name)

let test_config_agent_projection_rejects_legacy_alias () =
  let config = make_config () in
  write_keeper_toml ~config ~name:"sangsu" ~sandbox_profile:"docker_hardened";
  Alcotest.check_raises
    "legacy sandbox_profile aliases are rejected"
    (Keeper_sandbox_config.Invalid_keeper_sandbox_config
       (Printf.sprintf
          "%s: invalid sandbox_profile %S (allowed: local, docker)"
          (Keeper_sandbox_config.keeper_toml_path
             ~base_path:config.Workspace.base_path
             ~agent_name:"keeper-sangsu-agent")
          "docker_hardened"))
    (fun () ->
       ignore
         (Keeper_sandbox_config.sandbox_profile_of_agent
            ~base_path:config.Workspace.base_path
            ~agent_name:"keeper-sangsu-agent"))

let () =
  Alcotest.run "Keeper Path SSOT" [
    ( "host_root_abs invariant",
      [
        Alcotest.test_case "docker keeper" `Quick test_ssot_docker_keeper;
        Alcotest.test_case "local keeper" `Quick test_ssot_local_keeper;
        Alcotest.test_case "dashed-name keeper" `Quick
          test_ssot_docker_keeper_with_dashed_name;
      ] );
    ( "wrong-meta detection",
      [
        Alcotest.test_case "name-distinct keepers => distinct roots" `Quick
          test_root_depends_on_keeper_name;
        Alcotest.test_case "profile-distinct keepers => distinct roots" `Quick
          test_root_depends_on_sandbox_profile;
      ] );
    ( "idempotence",
      [
        Alcotest.test_case "same meta twice => same root" `Quick
          test_ssot_idempotent;
      ] );
    ( "config-backed sandbox contract",
      [
        Alcotest.test_case "docker projection" `Quick
          test_config_agent_projection_docker;
        Alcotest.test_case "local projection" `Quick
          test_config_agent_projection_local;
        Alcotest.test_case "legacy profile rejected" `Quick
          test_config_agent_projection_rejects_legacy_alias;
      ] );
  ]
