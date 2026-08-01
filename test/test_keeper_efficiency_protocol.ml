let check_json label expected actual =
  Alcotest.(check string) label expected (Yojson.Safe.to_string actual)
;;

let test_snapshot_protocol () =
  let snapshot =
    Masc.Keeper_snapshot_protocol.respond
      ~revision:"backlog:7"
      ~if_revision:None
      (`List [ `String "task-1" ])
  in
  check_json
    "snapshot"
    {|{"kind":"snapshot","revision":"backlog:7","snapshot":["task-1"]}|}
    (Masc.Keeper_snapshot_protocol.to_yojson snapshot);
  let unchanged =
    Masc.Keeper_snapshot_protocol.respond
      ~revision:"backlog:7"
      ~if_revision:(Some "backlog:7")
      (`List [ `String "task-1" ])
  in
  check_json
    "unchanged"
    {|{"kind":"unchanged","revision":"backlog:7"}|}
    (Masc.Keeper_snapshot_protocol.to_yojson unchanged);
  (match Masc.Keeper_snapshot_protocol.if_revision
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
    Masc_exec.Sandbox_target.docker ~image:"pinned-image" ~runner:mock_runner ()
  in
  let classify = Masc.Keeper_execution_effect.classify in
  Alcotest.(check string)
    "confined docker network-none"
    "confined"
    (Masc.Keeper_execution_effect.to_string
       (classify
          ~sandbox_profile:Keeper_types_profile_sandbox.Docker
          ~network_mode:Keeper_types_profile_sandbox.Network_none
          ~target:docker
          ~containment_verified:true));
  Alcotest.(check string)
    "unverified docker remains external"
    "external"
    (Masc.Keeper_execution_effect.to_string
       (classify
          ~sandbox_profile:Keeper_types_profile_sandbox.Docker
          ~network_mode:Keeper_types_profile_sandbox.Network_none
          ~target:docker
          ~containment_verified:false));
  Alcotest.(check string)
    "host remains external"
    "external"
    (Masc.Keeper_execution_effect.to_string
       (classify
          ~sandbox_profile:Keeper_types_profile_sandbox.Local
          ~network_mode:Keeper_types_profile_sandbox.Network_inherit
          ~target:(Masc_exec.Sandbox_target.host ())
          ~containment_verified:true))
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
