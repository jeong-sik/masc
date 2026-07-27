open Masc

module Candidate = Keeper_board_attention_candidate
module Exact_flow = Keeper_board_attention_exact_flow
module Fixture = Compaction_exact_output_fixture
module Judgment = Keeper_board_attention_judgment
module Partition = Keeper_board_attention_partition
module Worker = Keeper_board_attention_worker

type callback_event =
  | Dispatch of Exact_flow.attempt_provenance
  | Advance of Exact_flow.advance_source * Exact_flow.candidate_visit

let has_prompt_root path =
  Sys.file_exists (Filename.concat path "config/prompts")
;;

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
    let rec ascend path =
      if has_prompt_root path
      then path
      else (
        let parent = Filename.dirname path in
        if String.equal parent path then Sys.getcwd () else ascend parent)
    in
    ascend (Sys.getcwd ())
;;

let with_prompt_registry f =
  Fun.protect
    ~finally:Prompt_registry.clear
    (fun () ->
      Prompt_registry.clear ();
      Prompt_registry.set_markdown_dir (Filename.concat (repo_root ()) "config/prompts");
      Prompt_defaults.init ();
      f ())
;;

let run_eio f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  f
    ~sw
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
;;

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base prefix f =
  let base_path = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)
;;

let prepare_exact ~net candidate =
  let keeper_name =
    "board-attention-exact-test-" ^ candidate.Candidate.candidate_id
  in
  let base_path = "/tmp/masc-board-attention-exact-flow" in
  (match Keeper_registry.get ~base_path keeper_name with
   | Some _ -> ()
   | None ->
     let meta =
       Masc_test_deps.meta_of_json_fixture
         (`Assoc
           [ "name", `String keeper_name
           ; "trace_id", `String ("trace-" ^ keeper_name)
           ])
       |> Result.get_ok
     in
     ignore (Keeper_registry.register_offline ~base_path keeper_name meta));
  Exact_flow.prepare
    ~base_path
    ~keeper_name
    ~net
    candidate
;;

let post_id_exn raw =
  match Board.Post_id.of_string raw with
  | Ok id -> id
  | Error _ -> Alcotest.failf "invalid Board post id fixture: %s" raw
;;

let agent_id_exn raw =
  match Board.Agent_id.of_string raw with
  | Ok id -> id
  | Error _ -> Alcotest.failf "invalid Board agent id fixture: %s" raw
;;

let comment_id_exn raw =
  match Board.Comment_id.of_string raw with
  | Ok id -> id
  | Error _ -> Alcotest.failf "invalid Board comment id fixture: %s" raw
;;

let signal post_id : Board_dispatch.board_signal =
  { kind = Board_dispatch.Board_post_created
  ; post_id
  ; author = "external-author"
  ; title = "Board update"
  ; content = "Persisted Board evidence"
  ; hearth = Some "hearth-1"
  ; updated_at = Some 42.0
  }
;;

let post_of_signal (signal : Board_dispatch.board_signal) : Board.post =
  { id = post_id_exn signal.post_id
  ; author = agent_id_exn signal.author
  ; title = signal.title
  ; body = signal.content
  ; content = signal.content
  ; post_kind = Board.Human_post
  ; meta_json = None
  ; visibility = Board.Public
  ; created_at = 1.0
  ; updated_at = Option.value signal.updated_at ~default:1.0
  ; expires_at = 3601.0
  ; votes_up = 0
  ; votes_down = 0
  ; reply_count = 0
  ; pinned = false
  ; hearth = signal.hearth
  ; thread_id = None
  ; origin = None
  }
;;

let comment_of_signal (signal : Board_dispatch.board_signal) : Board.comment =
  { id = comment_id_exn ("comment-" ^ signal.post_id)
  ; post_id = post_id_exn signal.post_id
  ; parent_id = None
  ; author = agent_id_exn "comment-author"
  ; content = "Canonical Board comment"
  ; created_at = 2.0
  ; expires_at = 3602.0
  ; votes_up = 0
  ; votes_down = 0
  }
;;

let candidate post_id : Candidate.candidate =
  let signal = signal post_id in
  let keeper_name = "sangsu" in
  let candidate_id =
    `Assoc
      [ "keeper_name", `String keeper_name
      ; "signal", Candidate.signal_to_yojson signal
      ]
    |> Yojson.Safe.to_string
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_hex
  in
  { candidate_id
  ; keeper_name
  ; signal
  ; judgment_request =
      `Assoc
        [ "candidate_id", `String candidate_id
        ; "signal", Candidate.signal_to_yojson signal
        ; "post", Board.post_to_yojson (post_of_signal signal)
        ; "comments", `List [ Board.comment_to_yojson (comment_of_signal signal) ]
        ; ( "keeper_context"
          , `Assoc
              [ "lane_keeper_name", `String keeper_name
              ; "agent_name", `String "sangsu-agent"
              ; "keeper_record_id", `Null
              ; "keeper_runtime_uid", `Null
              ; "persona", `Null
              ; "instructions", `String "continue"
              ; "active_goal_ids", `List []
              ; "current_task_id", `Null
              ; "mention_keeper_ids", `List [ `String keeper_name ]
              ] )
        ]
  ; recorded_at = 1.0
  ; status = Candidate.Pending { last_delivery_failure = None }
  }
;;

let judgment_output ~candidate_id =
  `Assoc
    [ ( "verdicts"
      , `List
          [ `Assoc
              [ "candidate_id", `String candidate_id
              ; "decision", `String "relevant"
              ; "rationale", `String "The persisted Board evidence requires attention."
              ]
          ] )
    ]
;;

let target id base_url : Fixture.target_fixture = { id; base_url }

let reserved_non_listening_loopback_base_url ~sw =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Eio.Switch.on_release sw (fun () -> Unix.close socket);
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  match Unix.getsockname socket with
  | Unix.ADDR_INET (_, port) -> Printf.sprintf "http://127.0.0.1:%d" port
  | Unix.ADDR_UNIX _ -> assert false
;;

let publish_lane ?(api_key_envs = []) fixtures =
  let snapshot =
    Fixture.resolver_snapshot
      ~api_key_envs
      ~supports_response_format_json:true
      ~supports_structured_output:false
      ~source:"Board attention exact-flow conformance"
      fixtures
  in
  ignore
    (Fixture.publish_registry
       ~lane_id:Exact_flow.lane_id
       ~slot_ids:(List.map (fun (fixture : Fixture.target_fixture) -> fixture.id) fixtures)
       snapshot
      : Runtime_exact_output_registry.t)
;;

let check_same_provenance label
      (expected : Exact_flow.attempt_provenance)
      (actual : Exact_flow.attempt_provenance)
  =
  Alcotest.(check string) (label ^ " slot") expected.slot_id actual.slot_id;
  Alcotest.(check string) (label ^ " call") expected.call_id actual.call_id;
  Alcotest.(check string)
    (label ^ " plan fingerprint")
    expected.plan_fingerprint
    actual.plan_fingerprint;
  Alcotest.(check string)
    (label ^ " request hash")
    expected.request_body_sha256
    actual.request_body_sha256
;;

let partition_history ~base_path ~keeper_name =
  Partition.For_testing.path ~base_path ~keeper_name
  |> Fs_compat.load_file
  |> String.split_on_char '\n'
  |> List.filter (fun line -> not (String.equal line ""))
  |> List.map (fun line ->
    match Partition.of_yojson (Yojson.Safe.from_string line) with
    | Ok partition -> partition
    | Error detail ->
      Alcotest.failf "partition history decode failed: %s" detail)
;;

let test_explicit_lane_failover_and_success_provenance () =
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      with_temp_base "board-attention-production-chain" @@ fun base_path ->
      let candidate = candidate "board-attention-production-chain" in
      (match Candidate.record ~base_path candidate with
       | Candidate.Recorded _ -> ()
       | Candidate.Duplicate _ -> Alcotest.fail "fresh candidate duplicated"
       | Candidate.Record_error detail -> Alcotest.fail detail);
      let meta =
        Masc_test_deps.meta_of_json_fixture
          (`Assoc
            [ "name", `String candidate.keeper_name
            ; "trace_id", `String "trace-board-production-chain"
            ])
        |> Result.get_ok
      in
      ignore
        (Keeper_registry.register_offline
           ~base_path
           candidate.keeper_name
           meta);
      let response =
        Fixture.openai_response
          (judgment_output ~candidate_id:candidate.candidate_id)
      in
      let rejected_server =
        Fixture.start_server ~sw ~net ~clock (Fixture.Reply response)
      in
      let success_server =
        Fixture.start_server ~sw ~net ~clock (Fixture.Reply response)
      in
      let first =
        target
          "board-attention-unreachable"
          (reserved_non_listening_loopback_base_url ~sw)
      in
      let second =
        target "board-attention-missing-credential" rejected_server.base_url
      in
      let third = target "board-attention-success" success_server.base_url in
      publish_lane
        ~api_key_envs:
          [ second.id, "MASC_TEST_MISSING_BOARD_ATTENTION_KEY" ]
        [ first; second; third ];
      (match
         Worker.For_testing.process_next_exact
           ~clock
           ~net:(Some net)
           ~now:(fun () -> 3.0)
           ~worker_epoch:(Partition.Worker_epoch.generate ())
           ~base_path
           ~keeper_name:candidate.keeper_name
       with
       | Ok (Worker.Judgment_completed { candidate_id; _ })
         when String.equal candidate_id candidate.candidate_id -> ()
       | Ok _ -> Alcotest.fail "production exact flow did not complete"
       | Error detail -> Alcotest.fail detail);
      Alcotest.(check int)
        "B rejected before HTTP"
        0
        (Fixture.post_count rejected_server);
      Alcotest.(check int)
        "C dispatched once"
        1
        (Fixture.post_count success_server);
      let relevant =
        partition_history ~base_path ~keeper_name:candidate.keeper_name
        |> List.filter_map (fun partition ->
          match partition.Partition.state with
          | Partition.Running { progress = Partition.Bound proof; _ } ->
            Some (`Bound proof)
          | Partition.Running
              { progress =
                  Partition.Advancing
                    { execution_anchor; last_from; next }
              ; _
              } ->
            Some (`Advance (execution_anchor, last_from, next))
          | Partition.Completed { item = { judgment; _ }; _ } ->
            Some (`Completed judgment)
          | _ -> None)
      in
      match relevant with
      | [ `Bound first_bound
        ; `Advance (Some first_anchor, None, rejected_visit)
        ; `Advance (Some retained_anchor, Some rejected, success_visit)
        ; `Bound third_bound
        ; `Completed judgment
        ] ->
        Alcotest.(check bool)
          "A exact execution anchor persisted"
          true
          (first_bound = first_anchor
           && first_anchor = retained_anchor
           && String.equal first_bound.slot_id first.id);
        Alcotest.(check bool)
          "B rejection identity persisted before C"
          true
          (rejected = rejected_visit
           && String.equal rejected.slot_id second.id
           && String.equal success_visit.slot_id third.id);
        Alcotest.(check bool)
          "C bound and completed with exact provenance"
          true
          (String.equal third_bound.slot_id third.id
           && String.equal judgment.slot_id third_bound.slot_id
           && String.equal judgment.call_id third_bound.call_id
           && String.equal
                judgment.plan_fingerprint
                third_bound.plan_fingerprint
           && String.equal
                judgment.request_body_sha256
                third_bound.request_body_sha256)
      | _ ->
        Alcotest.fail
          "expected Bound(A), Advancing(A->B), Advancing(B->C), Bound(C), Completed(C)"))
;;

let test_domain_candidate_id_mismatch_does_not_advance () =
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      let candidate = candidate "board-attention-domain-mismatch" in
      let invalid =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply
             (Fixture.openai_response
                (judgment_output ~candidate_id:"different-candidate")))
      in
      let unused =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply
             (Fixture.openai_response
                (judgment_output ~candidate_id:candidate.candidate_id)))
      in
      let first = target "board-attention-domain-invalid" invalid.base_url in
      let second = target "board-attention-must-not-run" unused.base_url in
      publish_lane [ first; second ];
      let prepared =
        match prepare_exact ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "valid domain-mismatch fixture was not admitted"
      in
      let dispatches = ref [] in
      let before_dispatch provenance : (unit, string) result =
        dispatches := provenance :: !dispatches;
        Ok ()
      in
      let before_advance
            ~(failed : Exact_flow.advance_source)
            ~next:_
        : (unit, string) result
        =
        let failed_slot_id =
          match failed with
          | Exact_flow.Executed_failure provenance -> provenance.slot_id
          | Exact_flow.Predispatch_rejection visit -> visit.slot_id
        in
        Alcotest.failf
          "domain-invalid OAS success must not advance from %s"
          failed_slot_id
      in
      (match
         Exact_flow.execute
           ~clock
           ~before_dispatch
           ~before_advance
           prepared
       with
       | Error (Exact_flow.Domain_output_invalid _) -> ()
       | Ok _ -> Alcotest.fail "wrong singleton candidate id was accepted"
       | Error _ -> Alcotest.fail "wrong candidate id produced a non-domain error");
      Alcotest.(check int) "domain-invalid slot dispatched once" 1 (Fixture.post_count invalid);
      Alcotest.(check int) "second slot was not dispatched" 0 (Fixture.post_count unused);
      match List.rev !dispatches with
      | [ provenance ] ->
        Alcotest.(check string)
          "only admitted first slot reached dispatch"
          first.id
          provenance.slot_id
      | _ -> Alcotest.fail "domain-invalid success dispatched more than once"))
;;

let test_missing_lane_is_setup_error_without_dispatch () =
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      let candidate = candidate "board-attention-missing-lane" in
      let server =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply
             (Fixture.openai_response
                (judgment_output ~candidate_id:candidate.candidate_id)))
      in
      let fixture = target "board-attention-unassigned" server.base_url in
      let snapshot =
        Fixture.resolver_snapshot
          ~supports_response_format_json:true
          ~supports_structured_output:false
          ~source:"Board attention missing-lane conformance"
          [ fixture ]
      in
      (match Runtime_exact_output_registry.publish ~lanes:[] snapshot with
       | Ok _ -> ()
       | Error error ->
         Alcotest.failf
           "missing-lane registry fixture did not publish: %s"
           (Runtime_exact_output_registry.publication_error_to_string error));
      (match prepare_exact ~net:(Some net) candidate with
       | Error Exact_flow.Lane_unavailable -> ()
       | Ok _ -> Alcotest.fail "missing Board-attention lane was synthesized"
       | Error _ -> Alcotest.fail "missing lane produced the wrong setup error");
      Alcotest.(check int) "missing lane performs no provider POST" 0 (Fixture.post_count server)))
;;

let test_prepare_resumable_status_gate () =
  let pending = candidate "board-attention-gate" in
  let quarantine : Candidate.quarantine =
    { quarantine_id = "ba-quarantine-gate"
    ; partition_id = "ba-root-gate"
    ; partition_generation =
        Masc.Keeper_board_attention_partition_generation.initial
    ; failure_category = Candidate.Unexpected_worker_failure
    ; attempt_provenance = None
    ; quarantined_at = 2.0
    ; prior_status =
        Candidate.Resumable_pending { last_delivery_failure = None }
    }
  in
  let quarantined phase =
    { pending with status = Candidate.Quarantine { quarantine; phase } }
  in
  let expect_candidate_not_pending label candidate =
    match prepare_exact ~net:None candidate with
    | Error Exact_flow.Candidate_not_pending -> ()
    | Error _ -> Alcotest.failf "%s returned a different setup error" label
    | Ok _ -> Alcotest.failf "%s was admitted before requeue authorization" label
  in
  let expect_network_unavailable label candidate =
    match prepare_exact ~net:None candidate with
    | Error Exact_flow.Network_unavailable -> ()
    | Error _ -> Alcotest.failf "%s did not reach the network gate" label
    | Ok _ -> Alcotest.failf "%s unexpectedly prepared without a network" label
  in
  expect_candidate_not_pending
    "quarantined candidate"
    (quarantined Candidate.Quarantined);
  expect_candidate_not_pending
    "requeue-requested candidate"
    (quarantined (Candidate.Requeue_requested { requested_at = 3.0 }));
  expect_network_unavailable "normal pending candidate" pending;
  expect_network_unavailable
    "authorized requeued candidate"
    (quarantined (Candidate.Requeued { requeued_at = 4.0 }))
;;

let test_replaced_owner_defers_final_projection_without_mutation () =
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      let candidate = candidate "board-attention-owner-replaced" in
      let response =
        Fixture.openai_response
          (judgment_output ~candidate_id:candidate.candidate_id)
      in
      let server = Fixture.start_server ~sw ~net ~clock (Fixture.Reply response) in
      publish_lane [ target "board-attention-owner-replaced" server.base_url ];
      let prepared =
        match prepare_exact ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "Board exact flow was not prepared"
      in
      let keeper_name =
        "board-attention-exact-test-" ^ candidate.Candidate.candidate_id
      in
      let base_path = "/tmp/masc-board-attention-exact-flow" in
      let old_entry =
        match Keeper_registry.get ~base_path keeper_name with
        | Some entry -> entry
        | None -> Alcotest.fail "prepared Board owner disappeared"
      in
      (match Keeper_registry.unregister_exact old_entry with
       | Keeper_registry.Exact_unregistered -> ()
       | _ -> Alcotest.fail "old Board owner was not unregistered");
      let replacement_meta =
        Masc_test_deps.meta_of_json_fixture
          (`Assoc
            [ "name", `String keeper_name
            ; "trace_id", `String ("replacement-" ^ keeper_name)
            ])
        |> Result.get_ok
      in
      ignore
        (Keeper_registry.register_offline
           ~base_path
           keeper_name
           replacement_meta);
      let projection_mutations = ref 0 in
      (match
         Exact_flow.with_current_generation prepared (fun () ->
           incr projection_mutations)
       with
       | Keeper_exact_flow_scope.Owner_unregistered_deferred -> ()
       | Keeper_exact_flow_scope.Current () ->
         Alcotest.fail "replaced Board owner committed a stale projection");
      Alcotest.(check int)
        "stale final projection mutates nothing"
        0
        !projection_mutations))
;;

let test_owner_replacement_during_post_defers_success_projection () =
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      with_temp_base "board-owner-replacement" @@ fun base_path ->
      Fun.protect
        ~finally:(fun () -> Keeper_registry.For_testing.clear ())
        (fun () ->
           let candidate = candidate "board-owner-replacement-post" in
           (match Candidate.record ~base_path candidate with
            | Candidate.Recorded _ -> ()
            | Candidate.Duplicate _ ->
              Alcotest.fail "fresh Board candidate was duplicated"
            | Candidate.Record_error detail -> Alcotest.fail detail);
           let meta =
             Masc_test_deps.meta_of_json_fixture
               (`Assoc
                 [ "name", `String candidate.keeper_name
                 ; "trace_id", `String "trace-board-owner-replacement-post"
                 ])
             |> Result.get_ok
           in
           let old_owner =
             Keeper_registry.register_offline
               ~base_path
               candidate.keeper_name
               meta
           in
           let replace_owner () =
             (match Keeper_registry.unregister_exact old_owner with
              | Keeper_registry.Exact_unregistered -> ()
              | _ -> Alcotest.fail "Board old owner was not unregistered");
             let replacement_meta =
               Masc_test_deps.meta_of_json_fixture
                 (`Assoc
                   [ "name", `String candidate.keeper_name
                   ; "trace_id", `String "trace-board-owner-replacement-next"
                   ])
               |> Result.get_ok
             in
             ignore
               (Keeper_registry.register_offline
                  ~base_path
                  candidate.keeper_name
                  replacement_meta)
           in
           let server =
             Fixture.start_server
               ~on_request_before_reply:replace_owner
               ~sw
               ~net
               ~clock
               (Fixture.Reply
                  (Fixture.openai_response
                     (judgment_output
                        ~candidate_id:candidate.candidate_id)))
           in
           publish_lane
             [ target "board-owner-replacement-post" server.base_url ];
           (match
              Worker.For_testing.process_next_exact
                ~clock
                ~net:(Some net)
                ~now:(fun () -> 3.0)
                ~worker_epoch:(Partition.Worker_epoch.generate ())
                ~base_path
                ~keeper_name:candidate.keeper_name
            with
            | Ok (Worker.Owner_unregistered_deferred _) -> ()
            | Ok _ ->
              Alcotest.fail "stale Board owner projected a successful judgment"
            | Error detail -> Alcotest.fail detail);
           Alcotest.(check int)
             "real Board POST crossed replacement hook once"
             1
             (Fixture.post_count server);
           (match
              Candidate.load_candidates
                ~base_path
                ~keeper_name:candidate.keeper_name
            with
            | Ok [ { status = Candidate.Pending { last_delivery_failure = None }; _ } ] ->
              ()
            | Ok _ -> Alcotest.fail "stale Board success mutated the candidate"
            | Error detail -> Alcotest.fail detail);
           match
             Partition.load ~base_path ~keeper_name:candidate.keeper_name
           with
           | Ok [ { state = Partition.Running { progress = Partition.Bound _; _ }; _ } ] ->
             ()
           | Ok _ ->
             Alcotest.fail "stale Board success blocked or completed the partition"
           | Error detail -> Alcotest.fail detail)))
;;

let () =
  Alcotest.run
    "Keeper Board-attention exact flow"
    [ ( "production adapter"
      , [ Alcotest.test_case
            "resumable status gate requires durable requeue authorization"
            `Quick
            test_prepare_resumable_status_gate
        ; Alcotest.test_case
            "explicit lane failover preserves projection order and success provenance"
            `Quick
            test_explicit_lane_failover_and_success_provenance
        ; Alcotest.test_case
            "strict singleton candidate id is domain-terminal"
            `Quick
            test_domain_candidate_id_mismatch_does_not_advance
        ; Alcotest.test_case
            "missing lane is setup error without dispatch"
            `Quick
            test_missing_lane_is_setup_error_without_dispatch
        ; Alcotest.test_case
            "replaced owner defers final projection"
            `Quick
            test_replaced_owner_defers_final_projection_without_mutation
        ; Alcotest.test_case
            "owner replacement during POST defers success projection"
            `Quick
            test_owner_replacement_during_post_defers_success_projection
        ] )
    ]
;;
