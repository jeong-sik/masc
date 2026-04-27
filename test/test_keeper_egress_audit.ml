(** Tests for [Keeper_egress_audit] (Leak 11 / PR-Eg2).

    Each test case builds a synthetic config + meta + file system
    state and asserts the audit reproduces the same status the boot
    hook would emit in production. *)

module Coord = Masc_mcp.Coord
module Keeper_types = Masc_mcp.Keeper_types
module Keeper_egress_audit = Masc_mcp.Keeper_egress_audit

let temp_dir () =
  let path = Filename.temp_file "masc-egress-audit-" "" in
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
        ("goal", `String "egress audit test");
        ( "sandbox_profile",
          `String (Keeper_types.sandbox_profile_to_string sandbox) );
      ]
  in
  match Keeper_types.meta_of_json json with
  | Ok m -> m
  | Error e -> Alcotest.fail e

let make_config () =
  let base = temp_dir () in
  Unix.mkdir (Filename.concat base ".masc") 0o755;
  Coord.default_config base

let mkdir_p path =
  let rec aux p =
    if Sys.file_exists p then ()
    else (
      aux (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  aux path

let write_egress_at path =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  output_string oc {|["*.github.com"]|};
  close_out oc

(* ── Status classification ─────────────────────────────────────────── *)

let test_docker_ok_when_expected_present () =
  let config = make_config () in
  let meta = make_meta ~name:"sangsu" ~sandbox:Keeper_types.Docker in
  let expected = Masc_mcp.Keeper_shell_docker.egress_policy_path ~config ~meta in
  write_egress_at expected;
  let r = Keeper_egress_audit.audit_one ~config ~meta in
  match r.status with
  | Keeper_egress_audit.Ok_present -> ()
  | _ -> Alcotest.fail "expected Ok_present for docker keeper with file"

let test_docker_stale_orphan_when_only_host_direct_present () =
  let config = make_config () in
  let meta = make_meta ~name:"executor" ~sandbox:Keeper_types.Docker in
  let host_direct =
    Keeper_egress_audit.host_direct_egress_path ~config ~meta
  in
  write_egress_at host_direct;
  let r = Keeper_egress_audit.audit_one ~config ~meta in
  match r.status with
  | Keeper_egress_audit.Stale_orphan
      { expected_path; orphan_path } ->
      let docker_expected =
        Masc_mcp.Keeper_shell_docker.egress_policy_path ~config ~meta
      in
      Alcotest.(check string)
        "expected_path matches docker resolver" docker_expected expected_path;
      Alcotest.(check string)
        "orphan_path matches host-direct resolver" host_direct orphan_path
  | _ ->
      Alcotest.fail
        "expected Stale_orphan when host-direct present and docker-path \
         absent"

let test_docker_missing_when_neither_present () =
  let config = make_config () in
  let meta = make_meta ~name:"verifier" ~sandbox:Keeper_types.Docker in
  let r = Keeper_egress_audit.audit_one ~config ~meta in
  match r.status with
  | Keeper_egress_audit.Missing_at_expected _ -> ()
  | _ ->
      Alcotest.fail
        "expected Missing_at_expected when neither path is populated"

let test_local_ok_when_expected_present () =
  let config = make_config () in
  let meta = make_meta ~name:"ramarama" ~sandbox:Keeper_types.Local in
  let expected = Masc_mcp.Keeper_shell_docker.egress_policy_path ~config ~meta in
  write_egress_at expected;
  let r = Keeper_egress_audit.audit_one ~config ~meta in
  match r.status with
  | Keeper_egress_audit.Ok_present -> ()
  | _ -> Alcotest.fail "expected Ok_present for local keeper with file"

let test_local_missing_does_not_check_orphan () =
  (* Local profile: expected path == host-direct, so [Stale_orphan] is
     impossible by construction.  A missing file is always
     [Missing_at_expected]. *)
  let config = make_config () in
  let meta = make_meta ~name:"velvet-hammer" ~sandbox:Keeper_types.Local in
  let r = Keeper_egress_audit.audit_one ~config ~meta in
  match r.status with
  | Keeper_egress_audit.Missing_at_expected _ -> ()
  | _ -> Alcotest.fail "local profile must never report Stale_orphan"

(* ── audit_all + partition ─────────────────────────────────────────── *)

let test_audit_all_partitions_correctly () =
  let config = make_config () in
  let m_ok = make_meta ~name:"sangsu" ~sandbox:Keeper_types.Docker in
  write_egress_at
    (Masc_mcp.Keeper_shell_docker.egress_policy_path ~config ~meta:m_ok);
  let m_stale = make_meta ~name:"executor" ~sandbox:Keeper_types.Docker in
  write_egress_at
    (Keeper_egress_audit.host_direct_egress_path ~config ~meta:m_stale);
  let m_missing = make_meta ~name:"verifier" ~sandbox:Keeper_types.Docker in
  let results =
    Keeper_egress_audit.audit_all ~config
      ~metas:[ m_ok; m_stale; m_missing ]
  in
  let oks, missings, orphans = Keeper_egress_audit.partition results in
  Alcotest.(check int) "1 ok" 1 (List.length oks);
  Alcotest.(check int) "1 missing" 1 (List.length missings);
  Alcotest.(check int) "1 stale orphan" 1 (List.length orphans)

(* ── log line format ───────────────────────────────────────────────── *)

let starts_with prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let test_format_log_line_tags () =
  let config = make_config () in
  let m = make_meta ~name:"sangsu" ~sandbox:Keeper_types.Docker in
  let r_missing = Keeper_egress_audit.audit_one ~config ~meta:m in
  Alcotest.(check bool)
    "missing line tagged [egress_audit:missing]" true
    (starts_with "[egress_audit:missing]"
       (Keeper_egress_audit.format_log_line r_missing));
  write_egress_at
    (Masc_mcp.Keeper_shell_docker.egress_policy_path ~config ~meta:m);
  let r_ok = Keeper_egress_audit.audit_one ~config ~meta:m in
  Alcotest.(check bool)
    "ok line tagged [egress_audit:ok]" true
    (starts_with "[egress_audit:ok]"
       (Keeper_egress_audit.format_log_line r_ok))

let () =
  Alcotest.run "Keeper Egress Audit"
    [
      ( "status classification",
        [
          Alcotest.test_case "docker ok when file present" `Quick
            test_docker_ok_when_expected_present;
          Alcotest.test_case "docker stale orphan" `Quick
            test_docker_stale_orphan_when_only_host_direct_present;
          Alcotest.test_case "docker missing" `Quick
            test_docker_missing_when_neither_present;
          Alcotest.test_case "local ok when file present" `Quick
            test_local_ok_when_expected_present;
          Alcotest.test_case "local missing never reports orphan" `Quick
            test_local_missing_does_not_check_orphan;
        ] );
      ( "aggregation",
        [
          Alcotest.test_case "audit_all + partition" `Quick
            test_audit_all_partitions_correctly;
        ] );
      ( "log format",
        [
          Alcotest.test_case "tag prefixes" `Quick test_format_log_line_tags;
        ] );
    ]
