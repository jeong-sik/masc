open Alcotest
open Masc
open Keeper_official_client_session_store

let temp_workspace prefix =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let cleanup_tree root =
  let rec remove path =
    if Sys.file_exists path
    then if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path)
      else Unix.unlink path
  in
  try remove root with
  | _ -> ()
;;

let with_workspace prefix f =
  let base_path = temp_workspace prefix in
  Fun.protect ~finally:(fun () -> cleanup_tree base_path) (fun () -> f base_path)
;;

let owner_epoch = "11111111-1111-4111-8111-111111111111"
let next_owner_epoch = "22222222-2222-4222-8222-222222222222"
let empty_surface = tool_surface_sha256 []

let claim_new ~base_path ~keeper_name ~client_kind ~runtime_id ~owner_epoch ~at =
  claim
    ~base_path
    ~keeper_name
    ~expected:None
    ~client_kind
    ~owner_epoch
    ~runtime_id
    ~tool_surface_sha256:empty_surface
    ~updated_at:at
  |> Result.get_ok
;;

let test_roundtrip_and_settlement () =
  with_workspace "masc-official-client-store-roundtrip-" (fun base_path ->
    let keeper_name = "roundtrip" in
    check bool "missing" true (load ~base_path ~keeper_name = Ok None);
    let claimed =
      claim_new
        ~base_path
        ~keeper_name
        ~client_kind:Codex
        ~runtime_id:"codex.default"
        ~owner_epoch
        ~at:1.0
    in
    (match
       claim
         ~base_path
         ~keeper_name
         ~expected:(Some claimed)
         ~client_kind:Claude_code
         ~owner_epoch
         ~runtime_id:"claude-code.default"
         ~tool_surface_sha256:empty_surface
         ~updated_at:1.5
     with
     | Error _ -> ()
     | Ok _ -> fail "incomplete claim changed official client identity");
    let active =
      mark_active
        ~base_path
        ~keeper_name
        ~expected:claimed
        ~session_id:"session-1"
        ~updated_at:2.0
      |> Result.get_ok
    in
    let starting =
      mark_turn_starting
        ~base_path
        ~keeper_name
        ~expected:active
        ~session_id:"session-1"
        ~updated_at:3.0
      |> Result.get_ok
    in
    let inflight =
      mark_turn_started
        ~base_path
        ~keeper_name
        ~expected:starting
        ~session_id:"session-1"
        ~turn_id:"turn-1"
        ~updated_at:4.0
      |> Result.get_ok
    in
    let settled =
      settle
        ~base_path
        ~keeper_name
        ~expected:inflight
        ~session_id:"session-1"
        ~turn_id:"turn-1"
        ~updated_at:5.0
      |> Result.get_ok
    in
    let resume_plan =
      plan_claim
        ~expected:(Some settled)
        ~client_kind:Codex
        ~runtime_id:"codex.default"
      |> Result.get_ok
    in
    check int "resume ordinal" 2 resume_plan.turn_count;
    check bool
      "resume settlement"
      true
      (resume_plan.previous_settlement
       = Some { session_id = "session-1"; turn_id = "turn-1" });
    check
      (option string)
      "resume surface requirement"
      (Some empty_surface)
      resume_plan.required_tool_surface_sha256;
    match load ~base_path ~keeper_name with
    | Error detail -> fail detail
    | Ok None -> fail "durable session disappeared"
    | Ok (Some loaded) ->
      check bool "exact read-back" true (loaded = settled);
      check bool "client kind" true (loaded.client_kind = Codex);
      check int "completed turns" 1 loaded.turn_count;
      (match loaded.phase with
       | Settled { session_id; turn_id } ->
         check string "session" "session-1" session_id;
         check string "turn" "turn-1" turn_id
       | Ready | Start _ | Active _ | Turn_inflight _ | Recovery_required _ ->
         fail "terminal turn was not settled"))
;;

let test_duplicate_claim_and_cas_are_fail_closed () =
  with_workspace "masc-official-client-store-cas-" (fun base_path ->
    let keeper_name = "cas" in
    let claimed =
      claim_new
        ~base_path
        ~keeper_name
        ~client_kind:Codex
        ~runtime_id:"codex.default"
        ~owner_epoch
        ~at:1.0
    in
    (match
       claim
         ~base_path
         ~keeper_name
         ~expected:(Some claimed)
         ~client_kind:Codex
         ~owner_epoch
         ~runtime_id:"codex.default"
         ~tool_surface_sha256:empty_surface
         ~updated_at:2.0
     with
     | Error _ -> ()
     | Ok _ -> fail "incomplete claim admitted duplicate execution");
    let active =
      mark_active
        ~base_path
        ~keeper_name
        ~expected:claimed
        ~session_id:"session-cas"
        ~updated_at:3.0
      |> Result.get_ok
    in
    (match
       mark_turn_starting
         ~base_path
         ~keeper_name
         ~expected:claimed
         ~session_id:"session-cas"
         ~updated_at:4.0
     with
     | Error _ -> ()
     | Ok _ -> fail "stale expected state bypassed compare-and-swap");
    match load ~base_path ~keeper_name with
    | Ok (Some loaded) -> check bool "active preserved" true (loaded = active)
    | Error detail -> fail detail
    | Ok None -> fail "CAS failure removed durable state")
;;

let test_terminal_identity_switch_starts_fresh () =
  with_workspace "masc-official-client-store-switch-" (fun base_path ->
    let keeper_name = "switch" in
    let claimed =
      claim_new
        ~base_path
        ~keeper_name
        ~client_kind:Codex
        ~runtime_id:"codex.default"
        ~owner_epoch
        ~at:1.0
    in
    let active =
      mark_active
        ~base_path
        ~keeper_name
        ~expected:claimed
        ~session_id:"codex-session"
        ~updated_at:2.0
      |> Result.get_ok
    in
    let starting =
      mark_turn_starting
        ~base_path
        ~keeper_name
        ~expected:active
        ~session_id:"codex-session"
        ~updated_at:3.0
      |> Result.get_ok
    in
    let inflight =
      mark_turn_started
        ~base_path
        ~keeper_name
        ~expected:starting
        ~session_id:"codex-session"
        ~turn_id:"codex-turn"
        ~updated_at:4.0
      |> Result.get_ok
    in
    let settled =
      settle
        ~base_path
        ~keeper_name
        ~expected:inflight
        ~session_id:"codex-session"
        ~turn_id:"codex-turn"
        ~updated_at:5.0
      |> Result.get_ok
    in
    (match
       claim
         ~base_path
         ~keeper_name
         ~expected:(Some settled)
         ~client_kind:Codex
         ~owner_epoch
         ~runtime_id:"codex.default"
         ~tool_surface_sha256:(String.make 64 'a')
         ~updated_at:6.0
     with
     | Error _ -> ()
     | Ok _ -> fail "same settled session resumed with a changed tool surface");
    let switched =
      claim
        ~base_path
        ~keeper_name
        ~expected:(Some settled)
        ~client_kind:Claude_code
        ~owner_epoch
        ~runtime_id:"claude-code.sonnet"
        ~tool_surface_sha256:(String.make 64 'b')
        ~updated_at:7.0
      |> Result.get_ok
    in
    check bool "new client" true (switched.client_kind = Claude_code);
    check string "new runtime" "claude-code.sonnet" switched.runtime_id;
    check int "fresh ordinal" 1 switched.turn_count;
    match switched.phase with
    | Start { previous_settlement = None; _ } -> ()
    | Start { previous_settlement = Some _; _ }
    | Ready | Active _ | Turn_inflight _ | Recovery_required _ | Settled _ ->
      fail "terminal client switch inherited the old external session")
;;

let test_restart_recovery_and_transient_release () =
  with_workspace "masc-official-client-store-restart-" (fun base_path ->
    let keeper_name = "restart" in
    let claimed =
      claim_new
        ~base_path
        ~keeper_name
        ~client_kind:Antigravity
        ~runtime_id:"antigravity.gemini"
        ~owner_epoch
        ~at:1.0
    in
    (match
       reconcile_process_restart
         ~base_path
         ~keeper_name
         ~expected:claimed
         ~current_owner_epoch:owner_epoch
         ~required_at:2.0
     with
     | Error _ -> ()
     | Ok _ -> fail "same process epoch was classified as a restart");
    let recovery =
      reconcile_process_restart
        ~base_path
        ~keeper_name
        ~expected:claimed
        ~current_owner_epoch:next_owner_epoch
        ~required_at:3.0
      |> Result.get_ok
    in
    let recovery_id =
      match recovery.phase with
      | Recovery_required required ->
        check bool "restart class" true (required.failure = Process_restarted);
        check bool "ambiguous" true (failure_disposition required.failure = Ambiguous);
        check string "claim epoch" owner_epoch required.owner_epoch;
        required.recovery_id
      | Ready | Start _ | Active _ | Turn_inflight _ | Settled _ ->
        fail "old process claim did not enter recovery"
    in
    let ready, application =
      resolve_recovery
        ~base_path
        ~keeper_name
        ~expected:recovery
        ~recovery_id
        ~resolution:Restart_fresh
        ~resolved_by:"operator"
        ~resolved_at:4.0
      |> Result.get_ok
    in
    check bool "recovery applied" true (application = Applied);
    let reclaimed =
      claim
        ~base_path
        ~keeper_name
        ~expected:(Some ready)
        ~client_kind:Antigravity
        ~owner_epoch:next_owner_epoch
        ~runtime_id:"antigravity.gemini"
        ~tool_surface_sha256:empty_surface
        ~updated_at:5.0
      |> Result.get_ok
    in
    let released =
      release_transient
        ~base_path
        ~keeper_name
        ~expected:reclaimed
        ~failure:Transient_spawn_failed
        ~released_at:6.0
      |> Result.get_ok
    in
    check int "transient does not count" 0 released.turn_count;
    (match released.phase with
     | Ready -> ()
     | Start _ | Active _ | Turn_inflight _ | Recovery_required _ | Settled _ ->
       fail "transient failure did not release the claim");
    match released.last_transient_release with
    | Some record ->
      check bool "transient evidence" true (record.failure = Transient_spawn_failed);
      check string "release epoch" next_owner_epoch record.owner_epoch
    | None -> fail "transient release evidence was not persisted")
;;

let test_exact_recovery_restart () =
  with_workspace "masc-official-client-store-resolution-" (fun base_path ->
    let keeper_name = "resolution" in
    let claimed =
      claim_new
        ~base_path
        ~keeper_name
        ~client_kind:Claude_code
        ~runtime_id:"claude-code.default"
        ~owner_epoch
        ~at:1.0
    in
    let recovery =
      require_recovery
        ~base_path
        ~keeper_name
        ~expected:claimed
        ~failure:Protocol_failed
        ~detail:"ambiguous client protocol failure"
        ~required_at:2.0
      |> Result.get_ok
    in
    let recovery_id =
      match recovery.phase with
      | Recovery_required required -> required.recovery_id
      | Ready | Start _ | Active _ | Turn_inflight _ | Settled _ ->
        fail "ambiguous failure did not require recovery"
    in
    (match
       resolve_recovery
         ~base_path
         ~keeper_name
         ~expected:recovery
         ~recovery_id:"33333333-3333-4333-8333-333333333333"
         ~resolution:Restart_fresh
         ~resolved_by:"operator"
         ~resolved_at:3.0
     with
     | Error _ -> ()
     | Ok _ -> fail "wrong recovery fence was accepted");
    let restarted, application =
      resolve_recovery
        ~base_path
        ~keeper_name
        ~expected:recovery
        ~recovery_id
        ~resolution:Restart_fresh
        ~resolved_by:"operator"
        ~resolved_at:4.0
      |> Result.get_ok
    in
    check bool "recovery applied" true (application = Applied);
    check int "restart drops incomplete turn" 0 restarted.turn_count;
    (match restarted.phase with
     | Ready -> ()
     | Settled _ | Start _ | Active _ | Turn_inflight _ | Recovery_required _ ->
       fail "fresh restart did not return the binding to Ready");
    let replayed, replay_application =
      resolve_recovery
        ~base_path
        ~keeper_name
        ~expected:recovery
        ~recovery_id
        ~resolution:Restart_fresh
        ~resolved_by:"operator-retry"
        ~resolved_at:5.0
      |> Result.get_ok
    in
    check bool "recovery replayed" true (replay_application = Replayed);
    check bool "replay returns committed binding" true (restarted = replayed);
    (match
       resolve_recovery
         ~base_path
         ~keeper_name
         ~expected:recovery
         ~recovery_id
         ~resolution:Retry_previous
         ~resolved_by:"operator"
         ~resolved_at:6.0
     with
     | Error Resolution_conflict -> ()
     | Error _ -> fail "different replay decision returned the wrong conflict"
     | Ok _ -> fail "different replay decision replaced committed recovery");
    match restarted.last_recovery_resolution with
    | Some record ->
      check string "durable actor" "operator" record.resolved_by;
      check string "recovery fence" recovery_id record.recovery_id
    | None -> fail "recovery resolution evidence was not persisted")
;;

let test_retry_previous_restores_exact_settlement () =
  with_workspace "masc-official-client-store-retry-" (fun base_path ->
    let keeper_name = "retry" in
    let claimed =
      claim_new
        ~base_path
        ~keeper_name
        ~client_kind:Codex
        ~runtime_id:"codex.default"
        ~owner_epoch
        ~at:1.0
    in
    let active =
      mark_active
        ~base_path
        ~keeper_name
        ~expected:claimed
        ~session_id:"session-1"
        ~updated_at:2.0
      |> Result.get_ok
    in
    let starting =
      mark_turn_starting
        ~base_path
        ~keeper_name
        ~expected:active
        ~session_id:"session-1"
        ~updated_at:3.0
      |> Result.get_ok
    in
    let inflight =
      mark_turn_started
        ~base_path
        ~keeper_name
        ~expected:starting
        ~session_id:"session-1"
        ~turn_id:"turn-1"
        ~updated_at:4.0
      |> Result.get_ok
    in
    let settled =
      settle
        ~base_path
        ~keeper_name
        ~expected:inflight
        ~session_id:"session-1"
        ~turn_id:"turn-1"
        ~updated_at:5.0
      |> Result.get_ok
    in
    let resumed_claim =
      claim
        ~base_path
        ~keeper_name
        ~expected:(Some settled)
        ~client_kind:Codex
        ~owner_epoch
        ~runtime_id:"codex.default"
        ~tool_surface_sha256:empty_surface
        ~updated_at:6.0
      |> Result.get_ok
    in
    let recovery =
      require_recovery
        ~base_path
        ~keeper_name
        ~expected:resumed_claim
        ~failure:Protocol_failed
        ~detail:"resume transport ended before the next turn started"
        ~required_at:7.0
      |> Result.get_ok
    in
    let recovery_id =
      match recovery.phase with
      | Recovery_required required ->
        check bool
          "retry retains exact previous settlement"
          true
          (required.previous_settlement
           = Some { session_id = "session-1"; turn_id = "turn-1" });
        required.recovery_id
      | Ready | Start _ | Active _ | Turn_inflight _ | Settled _ ->
        fail "resumed claim did not enter recovery"
    in
    let restored, application =
      resolve_recovery
        ~base_path
        ~keeper_name
        ~expected:recovery
        ~recovery_id
        ~resolution:Retry_previous
        ~resolved_by:"operator"
        ~resolved_at:8.0
      |> Result.get_ok
    in
    check bool "retry decision applied" true (application = Applied);
    check int "failed retry does not count" 1 restored.turn_count;
    (match restored.phase with
     | Settled { session_id; turn_id } ->
       check string "restored session" "session-1" session_id;
       check string "restored turn" "turn-1" turn_id
     | Ready | Start _ | Active _ | Turn_inflight _ | Recovery_required _ ->
       fail "retry_previous did not restore the exact settlement");
    let next_claim =
      claim
        ~base_path
        ~keeper_name
        ~expected:(Some restored)
        ~client_kind:Codex
        ~owner_epoch
        ~runtime_id:"codex.default"
        ~tool_surface_sha256:empty_surface
        ~updated_at:9.0
      |> Result.get_ok
    in
    match next_claim.phase with
    | Start { previous_settlement; _ } ->
      check bool
        "next claim resumes restored session"
        true
        (previous_settlement
         = Some { session_id = "session-1"; turn_id = "turn-1" })
    | Ready | Active _ | Turn_inflight _ | Recovery_required _ | Settled _ ->
      fail "restored settlement did not drive the next resume claim")
;;

let write_file path content =
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output content)
;;

let test_ambiguous_json_is_rejected () =
  with_workspace "masc-official-client-store-json-" (fun base_path ->
    let keeper_name = "ambiguous-json" in
    let state_path = path ~base_path ~keeper_name |> Result.get_ok in
    let (_ : string) = Keeper_fs.ensure_dir (Filename.dirname state_path) in
    write_file
      state_path
      {|{"client_kind":"codex","last_recovery_resolution":null,"last_transient_release":null,"phase":{"kind":"settled","session_id":"session-1","turn_id":"turn-1"},"runtime_id":"codex.default","runtime_id":"codex.other","schema":"masc.keeper.official-client-session.v1","tool_surface_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","turn_count":1,"updated_at":1.0}|};
    match load ~base_path ~keeper_name with
    | Error _ -> ()
    | Ok _ -> fail "duplicate JSON keys were accepted")
;;

let fixture_tool ?(parameters = []) ~name ~description () =
  Agent_sdk.Tool.create
    ~name
    ~description
    ~parameters
    (fun _ -> Ok { Agent_sdk.Types.content = "fixture"; _meta = None })
;;

let test_tool_surface_fingerprint_is_canonical () =
  let alpha = fixture_tool ~name:"alpha" ~description:"first" () in
  let beta = fixture_tool ~name:"beta" ~description:"second" () in
  let changed = fixture_tool ~name:"alpha" ~description:"changed" () in
  let first : Agent_sdk.Types.tool_param =
    { name = "first"; description = "first"; param_type = String; required = true }
  in
  let second : Agent_sdk.Types.tool_param =
    { name = "second"; description = "second"; param_type = Integer; required = true }
  in
  let ordered =
    fixture_tool
      ~parameters:[ first; second ]
      ~name:"ordered"
      ~description:"same"
      ()
  in
  let reordered =
    fixture_tool
      ~parameters:[ second; first ]
      ~name:"ordered"
      ~description:"same"
      ()
  in
  check string
    "tool order"
    (tool_surface_sha256 [ alpha; beta ])
    (tool_surface_sha256 [ beta; alpha ]);
  check string
    "parameter order"
    (tool_surface_sha256 [ ordered ])
    (tool_surface_sha256 [ reordered ]);
  check bool
    "description participates"
    true
    (not (String.equal (tool_surface_sha256 [ alpha ]) (tool_surface_sha256 [ changed ])))
;;

let () =
  run
    "official client session store"
    [ ( "durable owner"
      , [ test_case "roundtrip and settlement" `Quick test_roundtrip_and_settlement
        ; test_case
            "duplicate claim and CAS fail closed"
            `Quick
            test_duplicate_claim_and_cas_are_fail_closed
        ; test_case
            "terminal identity switch starts fresh"
            `Quick
            test_terminal_identity_switch_starts_fresh
        ; test_case
            "restart recovery and transient release"
            `Quick
            test_restart_recovery_and_transient_release
        ; test_case "exact recovery restart" `Quick test_exact_recovery_restart
        ; test_case
            "retry previous restores exact settlement"
            `Quick
            test_retry_previous_restores_exact_settlement
        ; test_case "ambiguous JSON rejected" `Quick test_ambiguous_json_is_rejected
        ; test_case
            "tool surface fingerprint canonical"
            `Quick
            test_tool_surface_fingerprint_is_canonical
        ] )
    ]
;;
