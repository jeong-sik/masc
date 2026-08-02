let check_json label expected actual =
  Alcotest.(check bool) label true (Yojson.Safe.equal expected actual)
;;

let test_snapshot_protocol () =
  let snapshot =
    Masc.Snapshot_protocol.respond
      ~revision:"backlog:7"
      ~if_revision:None
      (`List [ `String "task-1" ])
  in
  check_json
    "snapshot"
    (`Assoc
       [ "kind", `String "snapshot"
       ; "revision", `String "backlog:7"
       ; "snapshot", `List [ `String "task-1" ]
       ])
    (Masc.Snapshot_protocol.to_yojson snapshot);
  let unchanged =
    Masc.Snapshot_protocol.respond
      ~revision:"backlog:7"
      ~if_revision:(Some "backlog:7")
      (`List [ `String "task-1" ])
  in
  check_json
    "unchanged"
    (`Assoc [ "kind", `String "unchanged"; "revision", `String "backlog:7" ])
    (Masc.Snapshot_protocol.to_yojson unchanged);
  (match Masc.Snapshot_protocol.if_revision `Null with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "null arguments produced a revision"
   | Error message -> Alcotest.fail message);
  let revision_a =
    Masc.Snapshot_protocol.revision_of_json
      ~namespace:"test"
      (`Assoc [ "b", `Int 2; "a", `Int 1 ])
  in
  let revision_b =
    Masc.Snapshot_protocol.revision_of_json
      ~namespace:"test"
      (`Assoc [ "a", `Int 1; "b", `Int 2 ])
  in
  Alcotest.(check string) "object key order does not change revision" revision_a revision_b;
  Alcotest.(check bool)
    "revision uses sha256"
    true
    (String.length revision_a = String.length "test:" + 64);
  (match Masc.Snapshot_protocol.if_revision
           (`Assoc [ "if_revision", `String " " ]) with
   | Error message ->
     Alcotest.(check string)
       "blank if_revision is rejected"
       "if_revision must not be blank"
       message
   | Ok _ -> Alcotest.fail "blank if_revision was accepted")
;;

let mock_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_
    ~cwd:_
  =
  Unix.WEXITED 0, "", ""
;;

let test_effect_classification () =
  let docker =
    Masc_exec.Sandbox_target.docker
      ~image:
        "ubuntu:24.04@sha256:cdb5fd928fced577cfecf12c8966e830fcdf42ee481fb0b91904eeddc2fe5eff"
      ~runner:mock_runner
      ()
  in
  let classify = Masc.Keeper_execution_effect.classify in
  Alcotest.(check string)
    "confined docker network-none"
    "confined"
    (Masc.Keeper_execution_effect.to_string
       (classify
          ~sandbox_profile:Keeper_types_profile_sandbox.Docker
          ~network_mode:Keeper_types_profile_sandbox.Network_none
          ~target:docker));
  Alcotest.(check string)
    "docker with inherited network remains external"
    "external"
    (Masc.Keeper_execution_effect.to_string
       (classify
          ~sandbox_profile:Keeper_types_profile_sandbox.Docker
          ~network_mode:Keeper_types_profile_sandbox.Network_inherit
          ~target:docker));
  let unpinned_docker =
    Masc_exec.Sandbox_target.docker ~image:"ubuntu:24.04" ~runner:mock_runner ()
  in
  Alcotest.(check string)
    "untagged docker remains external"
    "external"
    (Masc.Keeper_execution_effect.to_string
       (classify
          ~sandbox_profile:Keeper_types_profile_sandbox.Docker
          ~network_mode:Keeper_types_profile_sandbox.Network_none
          ~target:unpinned_docker));
  Alcotest.(check string)
    "host remains external"
    "external"
    (Masc.Keeper_execution_effect.to_string
       (classify
          ~sandbox_profile:Keeper_types_profile_sandbox.Local
          ~network_mode:Keeper_types_profile_sandbox.Network_inherit
          ~target:(Masc_exec.Sandbox_target.host ())));
;;

let () =
  Alcotest.run
    "keeper efficiency protocol"
    [ ( "snapshot protocol"
      , [ Alcotest.test_case "snapshot and unchanged" `Quick test_snapshot_protocol ] )
    ; ( "execution effect"
      , [ Alcotest.test_case "closed effect classification" `Quick test_effect_classification ] )
    ]
;;
