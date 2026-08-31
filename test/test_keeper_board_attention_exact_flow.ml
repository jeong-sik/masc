open Masc

module Candidate = Keeper_board_attention_candidate
module Exact_flow = Keeper_board_attention_exact_flow
module Fixture = Exact_output_fixture
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
          [ "name", `String keeper_name ])
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
  (* A comment id must have the shape [Comment_id.generate] mints; derive one
     from the post id so the fixture stays deterministic per post. *)
  { id = comment_id_exn (Printf.sprintf "c-%032x" (Hashtbl.hash signal.post_id))
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
  let keeper_name = "alpha" in
  let candidate_id = Candidate.candidate_id_of_signal ~keeper_name signal in
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
              ; "keeper_record_id", `Null
              ; "keeper_runtime_uid", `Null
              ; "instructions", `String "continue"
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

let publish_lane ?(api_key_envs = []) ?(cli_slot_ids = []) fixtures =
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
       ~cli_slot_ids
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
           &&
           match judgment.source with
           | Candidate.Cli_lane_slot -> false
           | Candidate.Exact_attempt attempt ->
             String.equal attempt.call_id third_bound.call_id
             && String.equal attempt.plan_fingerprint third_bound.plan_fingerprint
             && String.equal
                  attempt.request_body_sha256
                  third_bound.request_body_sha256)
      | _ ->
        Alcotest.fail
          "expected Bound(A), Advancing(A->B), Advancing(B->C), Bound(C), Completed(C)"))
;;

let test_domain_candidate_id_mismatch_advances_to_declared_successor () =
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
      let successor =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply
             (Fixture.openai_response
                (judgment_output ~candidate_id:candidate.candidate_id)))
      in
      let first = target "board-attention-domain-invalid" invalid.base_url in
      let second = target "board-attention-domain-successor" successor.base_url in
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
      let advances = ref [] in
      let before_advance
            ~(failed : Exact_flow.advance_source)
            ~(next : Exact_flow.candidate_visit)
        : (unit, string) result
        =
        let failed_slot_id =
          match failed with
          | Exact_flow.Executed_failure provenance -> provenance.slot_id
          | Exact_flow.Predispatch_rejection visit -> visit.slot_id
        in
        advances := (failed_slot_id, next.slot_id) :: !advances;
        Ok ()
      in
      (match
         Exact_flow.execute
           ~clock
           ~before_dispatch
           ~before_advance
           prepared
       with
       | Ok judgment ->
         Alcotest.(check string)
           "success came from declared successor"
           second.id
           judgment.slot_id
       | Error _ -> Alcotest.fail "declared semantic successor did not complete");
      Alcotest.(check int) "domain-invalid slot dispatched once" 1 (Fixture.post_count invalid);
      Alcotest.(check int) "declared successor dispatched once" 1 (Fixture.post_count successor);
      Alcotest.(check (list (pair string string)))
        "successor bind records one local A-to-B journal transition"
        [ first.id, second.id ]
        (List.rev !advances);
      match List.rev !dispatches with
      | [ first_provenance; second_provenance ] ->
        Alcotest.(check string)
          "first declared slot reached dispatch first"
          first.id
          first_provenance.slot_id;
        Alcotest.(check string)
          "declared successor reached dispatch second"
          second.id
          second_provenance.slot_id
      | _ -> Alcotest.fail "semantic failover did not preserve declared dispatch order"))
;;

let test_keeper_preference_reorders_the_board_lane () =
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      with_temp_base "board-attention-per-keeper-preference" @@ fun base_path ->
      let candidate = candidate "board-attention-per-keeper-preference" in
      let response =
        Fixture.openai_response
          (judgment_output ~candidate_id:candidate.candidate_id)
      in
      let first = Fixture.start_server ~sw ~net ~clock (Fixture.Reply response) in
      let preferred =
        Fixture.start_server ~sw ~net ~clock (Fixture.Reply response)
      in
      publish_lane
        [ target "board-default" first.base_url
        ; target "board-preferred" preferred.base_url
        ];
      (match
         Keeper_exact_lane_preference.set
           (Workspace.default_config base_path)
           ~actor:"test"
           ~keeper_name:candidate.keeper_name
           ~lane_id:Exact_flow.lane_id
           (Some "board-preferred")
       with
       | Ok _ -> ()
       | Error detail -> Alcotest.fail detail);
      let prepared =
        match
          Exact_flow.prepare
            ~base_path
            ~keeper_name:candidate.keeper_name
            ~net:(Some net)
            candidate
        with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "preferred Board lane did not prepare"
      in
      let result =
        Exact_flow.execute
          ~clock
          ~before_dispatch:(fun _ -> Ok ())
          ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
          prepared
      in
      (match result with
       | Ok judgment ->
         Alcotest.(check string)
           "preferred Board slot selected"
           "board-preferred"
           judgment.slot_id
       | Error _ -> Alcotest.fail "preferred Board exact flow failed");
      Alcotest.(check int) "default Board slot not called" 0 (Fixture.post_count first);
      Alcotest.(check int)
        "preferred Board slot called once"
        1
        (Fixture.post_count preferred)))
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



(* --- cli tail (RFC cli-runtimes-as-lane-slots) --------------------------- *)

let cli_base_path = "/tmp/masc-board-attention-exact-flow"

let contains_substring ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  n = 0 || at 0
;;

(* Records what the walk handed the client so the test can assert the schema
   actually travelled, not just that an answer came back. *)
let recording_runner reply =
  let seen = ref None in
  let runner ~runtime_id ~system_prompt:_ ~output_schema ~prompt =
    seen := Some (runtime_id, output_schema, prompt);
    reply runtime_id
  in
  runner, seen
;;

let prepared_with_cli_tail ~net ~cli_slot_ids candidate =
  let server_url = "http://127.0.0.1:1" in
  publish_lane ~cli_slot_ids [ target "board-attention-primary" server_url ];
  ignore net;
  match prepare_exact ~net candidate with
  | Ok prepared -> prepared
  | Error _ -> Alcotest.fail "board attention flow did not prepare"
;;

let test_cli_tail_judges_with_its_own_provenance () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw:_ ~net ~clock:_ ->
      let candidate = candidate "board-attention-cli-tail" in
      let prepared =
        prepared_with_cli_tail
          ~net:(Some net)
          ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
          candidate
      in
      Alcotest.(check (list string))
        "the lane's declared tail is carried onto the prepared flow"
        [ Fixture.cli_primary_runtime ]
        (Exact_flow.cli_slots prepared);
      let runner, seen =
        recording_runner (fun _ ->
          Ok
            (Yojson.Safe.to_string
               (judgment_output ~candidate_id:candidate.Candidate.candidate_id)))
      in
      match Exact_flow.run_cli_tail ~runner ~base_path:cli_base_path prepared with
      | Error error ->
        Alcotest.failf
          "cli tail did not judge: %s"
          (Exact_flow.cli_tail_error_to_string error)
      | Ok (slot_id, judgment) ->
        Alcotest.(check string)
          "the answering client is named"
          Fixture.cli_primary_runtime
          slot_id;
        Alcotest.(check string)
          "the slot id is that client, not a catalog slot"
          Fixture.cli_primary_runtime
          judgment.Candidate.slot_id;
        (match judgment.Candidate.source with
         | Candidate.Cli_lane_slot -> ()
         | Candidate.Exact_attempt _ ->
           Alcotest.fail "a cli judgment must not claim an exact attempt");
        (match !seen with
         | None -> Alcotest.fail "the runner was never called"
         | Some (_, output_schema, prompt) ->
           Alcotest.(check bool)
             "the lane schema travelled on the client's own channel"
             true
             (output_schema <> `Null);
           Alcotest.(check bool)
             "the judge prompt travelled too"
             true
             (String.length prompt > 0)))))
;;

let test_cli_tail_without_declared_slots_is_typed () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw:_ ~net ~clock:_ ->
      let candidate = candidate "board-attention-cli-tail-empty" in
      let prepared =
        prepared_with_cli_tail ~net:(Some net) ~cli_slot_ids:[] candidate
      in
      let runner, _ = recording_runner (fun _ -> Ok "{}") in
      match Exact_flow.run_cli_tail ~runner ~base_path:cli_base_path prepared with
      | Error Exact_flow.No_cli_slots -> ()
      | Error other ->
        Alcotest.failf
          "an undeclared tail must say so: %s"
          (Exact_flow.cli_tail_error_to_string other)
      | Ok _ -> Alcotest.fail "a lane with no declared tail must not produce a judgment")))
;;

let test_cli_tail_rejects_a_verdict_for_another_candidate () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw:_ ~net ~clock:_ ->
      let candidate = candidate "board-attention-cli-tail-mismatch" in
      let prepared =
        prepared_with_cli_tail
          ~net:(Some net)
          ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
          candidate
      in
      let runner, _ =
        recording_runner (fun _ ->
          Ok
            (Yojson.Safe.to_string
               (judgment_output ~candidate_id:"some-other-candidate")))
      in
      match Exact_flow.run_cli_tail ~runner ~base_path:cli_base_path prepared with
      | Error (Exact_flow.Cli_output_invalid { slot_id; detail }) ->
        Alcotest.(check string)
          "the rejecting slot is named"
          Fixture.cli_primary_runtime
          slot_id;
        Alcotest.(check bool)
          "the identity mismatch is reported"
          true
          (contains_substring ~needle:"identity mismatch" detail)
      | Error other ->
        Alcotest.failf
          "a verdict for another candidate must be rejected as invalid output: %s"
          (Exact_flow.cli_tail_error_to_string other)
      | Ok _ ->
        Alcotest.fail "a verdict naming another candidate must not become this judgment")))
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
            "strict singleton mismatch advances to declared successor"
            `Quick
            test_domain_candidate_id_mismatch_advances_to_declared_successor
        ; Alcotest.test_case
            "Keeper preference reorders the Board lane"
            `Quick
            test_keeper_preference_reorders_the_board_lane
        ; Alcotest.test_case
            "missing lane is setup error without dispatch"
            `Quick
            test_missing_lane_is_setup_error_without_dispatch
        ] )
    ; ( "cli tail"
      , [ Alcotest.test_case
            "a cli slot judges under its own provenance"
            `Quick
            test_cli_tail_judges_with_its_own_provenance
        ; Alcotest.test_case
            "an undeclared tail is a typed refusal"
            `Quick
            test_cli_tail_without_declared_slots_is_typed
        ; Alcotest.test_case
            "a verdict naming another candidate is rejected"
            `Quick
            test_cli_tail_rejects_a_verdict_for_another_candidate
        ] )
    ]
;;
