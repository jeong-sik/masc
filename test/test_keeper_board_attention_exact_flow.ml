open Masc

module Candidate = Keeper_board_attention_candidate
module Exact_output = Agent_core.Exact_output
module Exact_flow = Keeper_board_attention_exact_flow
module Fixture = Exact_output_fixture
module Judgment = Keeper_board_attention_judgment
module Partition = Keeper_board_attention_partition
module Worker = Keeper_board_attention_worker

type callback_event =
  | Dispatch of Exact_flow.attempt_provenance
  | Advance of Exact_flow.advance_source * Exact_flow.candidate_visit

let with_prompt_registry f =
  Fun.protect
    ~finally:Prompt_registry.clear
    (fun () ->
      Prompt_registry.clear ();
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
  ; recorded_at = 1.0
  ; keeper_context =
      `Assoc
        [ "lane_keeper_name", `String keeper_name
        ; "keeper_record_id", `Null
        ; "keeper_runtime_uid", `Null
        ; "instructions", `String "continue"
        ; "current_task_id", `Null
        ; "mention_keeper_ids", `List [ `String keeper_name ]
        ]
  ; status =
      Candidate.Pending
        { last_delivery_failure = None
        ; material = { post = post_of_signal signal; comments = [ comment_of_signal signal ] }
        }
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
           | Candidate.Cli_lane_slot | Candidate.Vendor_system_one _ -> false
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
  let material =
    match Candidate.pending_judgment_material pending.Candidate.status with
    | Some material -> material
    | None -> Alcotest.fail "pending fixture carries no judgment material"
  in
  let quarantine : Candidate.quarantine =
    { quarantine_id = "ba-quarantine-gate"
    ; partition_id = "ba-root-gate"
    ; partition_generation =
        Masc.Keeper_board_attention_partition_generation.initial
    ; failure_category = Candidate.Unexpected_worker_failure
    ; attempt_provenance = None
    ; quarantined_at = 2.0
    ; prior_status =
        Candidate.Resumable_pending { last_delivery_failure = None; material }
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

let openai_text_response text =
  let encoded_content = Yojson.Safe.to_string (`String text) in
  Printf.sprintf
    {|{"id":"masc-conformance","model":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":%s},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
    encoded_content
;;

let board_attention_run_ids () =
  Exact_lane_run_registry.list_runs (Exact_lane_run_registry.global ())
  |> List.filter_map (fun (run : Exact_lane_run_registry.run) ->
    if run.lane = Exact_lane_run_registry.Board_attention
    then Some run.run_id
    else None)
;;

let new_board_attention_run ~before =
  Exact_lane_run_registry.list_runs (Exact_lane_run_registry.global ())
  |> List.find_opt (fun (run : Exact_lane_run_registry.run) ->
    run.lane = Exact_lane_run_registry.Board_attention
    && not (List.mem run.run_id before))
  |> function
  | Some run -> run
  | None -> Alcotest.fail "board attention exact run was not recorded"
;;

let new_board_attention_run_full ~before =
  let summary = new_board_attention_run ~before in
  match
    Exact_lane_run_registry.get
      (Exact_lane_run_registry.global ())
      ~run_id:summary.run_id
  with
  | Some run -> run
  | None -> Alcotest.fail "board attention exact run payload was not retained"
;;

let check_cli_run_selected ~before ~slot_id =
  match (new_board_attention_run ~before).Exact_lane_run_registry.status with
  | Exact_lane_run_registry.Completed
      { outcome = Exact_lane_run_registry.Succeeded; selected_slot; _ }
  | Exact_lane_run_registry.Completion_persistence_failed
      { intended_outcome = Exact_lane_run_registry.Succeeded; selected_slot; _ } ->
    Alcotest.(check (option string))
      "the exact run names the CLI slot that answered"
      (Some slot_id)
      selected_slot
  | Exact_lane_run_registry.Running
  | Exact_lane_run_registry.Completed _
  | Exact_lane_run_registry.Completion_persistence_failed _ ->
    Alcotest.fail "the mixed exact run did not close as a CLI success"
;;

let cli_success_runner candidate calls =
  fun ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
    incr calls;
    Ok
      (Yojson.Safe.to_string
         (judgment_output ~candidate_id:candidate.Candidate.candidate_id))
;;

let test_mixed_semantic_exhaustion_walks_cli_tail () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      let candidate = candidate "board-attention-mixed-semantic" in
      let rejected =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply
             (Fixture.openai_response
                (judgment_output ~candidate_id:"another-candidate")))
      in
      let http = target "board-attention-semantic-http" rejected.base_url in
      publish_lane ~cli_slot_ids:[ Fixture.cli_primary_runtime ] [ http ];
      let prepared =
        match prepare_exact ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "mixed semantic lane did not prepare"
      in
      let before = board_attention_run_ids () in
      let dispatches = ref [] in
      let cli_calls = ref 0 in
      let result =
        Exact_flow.execute
          ~cli_runner:(cli_success_runner candidate cli_calls)
          ~clock
          ~before_dispatch:(fun provenance ->
            dispatches := provenance :: !dispatches;
            Ok ())
          ~before_advance:(fun ~failed:_ ~next:_ ->
            Alcotest.fail "semantic rejection must not fabricate an HTTP advance callback")
          prepared
      in
      (match result with
       | Ok judgment ->
         Alcotest.(check string)
           "CLI answered after semantic exhaustion"
           Fixture.cli_primary_runtime
           judgment.Candidate.slot_id
       | Error _ -> Alcotest.fail "semantic exhaustion did not reach the CLI tail");
      Alcotest.(check int) "HTTP candidate dispatched once" 1 (Fixture.post_count rejected);
      Alcotest.(check int) "CLI candidate dispatched once" 1 !cli_calls;
      (match !dispatches with
       | [ provenance ] ->
         Alcotest.(check string)
           "the prior HTTP receipt remains observable"
           http.id
           provenance.slot_id
       | _ -> Alcotest.fail "mixed semantic flow lost its HTTP dispatch evidence");
      check_cli_run_selected ~before ~slot_id:Fixture.cli_primary_runtime)))
;;

let test_mixed_semantic_rejection_and_cli_failure_keep_both_causes () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      let candidate = candidate "board-attention-mixed-semantic-cli-failure" in
      let rejected =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply
             (Fixture.openai_response
                (judgment_output ~candidate_id:"another-candidate")))
      in
      publish_lane
        ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
        [ target "board-attention-semantic-cli-failure-http" rejected.base_url ];
      let prepared =
        match prepare_exact ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "mixed semantic failure lane did not prepare"
      in
      let before = board_attention_run_ids () in
      let runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
        Error (Masc.Fusion_official_client.Setup_failure (Provider_error "client unavailable"))
      in
      (match
         Exact_flow.execute
           ~cli_runner:runner
           ~clock
           ~before_dispatch:(fun _ -> Ok ())
           ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
           prepared
       with
       | Error
           (Exact_flow.Cli_slots_exhausted
              { prior_error = Some (Exact_flow.Domain_output_invalid detail)
              ; failures = [ _ ]
              }) ->
         Alcotest.(check bool)
           "typed prior error keeps the semantic rejection"
           true
           (contains_substring ~needle:"identity mismatch" detail)
       | Error _ -> Alcotest.fail "mixed failure lost its typed prior rejection"
       | Ok _ -> Alcotest.fail "failed semantic and CLI walks cannot judge");
      match (new_board_attention_run ~before).Exact_lane_run_registry.status with
      | Exact_lane_run_registry.Completed
          { outcome = Exact_lane_run_registry.Failed { detail; _ }; _ } ->
        Alcotest.(check bool)
          "durable detail keeps the semantic rejection class"
          true
          (contains_substring ~needle:"invalid_domain_output" detail);
        Alcotest.(check bool)
          "durable detail keeps the semantic rejection payload"
          true
          (contains_substring ~needle:"identity mismatch" detail);
        Alcotest.(check bool)
          "durable detail keeps the CLI failure"
          true
          (contains_substring ~needle:"client unavailable" detail)
      | Exact_lane_run_registry.Running
      | Exact_lane_run_registry.Completed _
      | Exact_lane_run_registry.Completion_persistence_failed _ ->
        Alcotest.fail "mixed failure did not close with durable detail")))
;;

let test_mixed_advanceable_final_failure_walks_cli_tail () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      let candidate = candidate "board-attention-mixed-invalid-json" in
      let invalid =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply (openai_text_response "not json"))
      in
      let http = target "board-attention-invalid-json-http" invalid.base_url in
      publish_lane ~cli_slot_ids:[ Fixture.cli_primary_runtime ] [ http ];
      let prepared =
        match prepare_exact ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "mixed invalid-JSON lane did not prepare"
      in
      let before = board_attention_run_ids () in
      let dispatches = ref [] in
      let cli_calls = ref 0 in
      let result =
        Exact_flow.execute
          ~cli_runner:(cli_success_runner candidate cli_calls)
          ~clock
          ~before_dispatch:(fun provenance ->
            dispatches := provenance :: !dispatches;
            Ok ())
          ~before_advance:(fun ~failed:_ ~next:_ ->
            Alcotest.fail "the exhausted final HTTP candidate has no HTTP successor")
          prepared
      in
      (match result with
       | Ok judgment ->
         Alcotest.(check string)
           "CLI answered after advanceable execution failure"
           Fixture.cli_primary_runtime
           judgment.Candidate.slot_id
       | Error _ -> Alcotest.fail "advanceable final failure did not reach the CLI tail");
      Alcotest.(check int) "invalid HTTP candidate dispatched once" 1 (Fixture.post_count invalid);
      Alcotest.(check int) "CLI candidate dispatched once" 1 !cli_calls;
      (match !dispatches with
       | [ provenance ] ->
         Alcotest.(check string) "HTTP evidence keeps its slot" http.id provenance.slot_id
       | _ -> Alcotest.fail "advanceable failure lost its HTTP dispatch evidence");
      check_cli_run_selected ~before ~slot_id:Fixture.cli_primary_runtime)))
;;

let test_mixed_non_advanceable_terminal_stops_before_cli () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      let candidate = candidate "board-attention-mixed-terminal" in
      let aborted = Fixture.start_server ~sw ~net ~clock Fixture.Abort_after_request in
      publish_lane
        ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
        [ target "board-attention-terminal-http" aborted.base_url ];
      let prepared =
        match prepare_exact ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "mixed terminal lane did not prepare"
      in
      let cli_calls = ref 0 in
      match
        Exact_flow.execute
          ~cli_runner:(cli_success_runner candidate cli_calls)
          ~clock
          ~before_dispatch:(fun _ -> Ok ())
          ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
          prepared
      with
      | Error (Exact_flow.Providers_exhausted { attempts; _ }) ->
        Alcotest.(check int) "terminal keeps one HTTP receipt" 1 (List.length attempts);
        Alcotest.(check int) "non-advanceable failure does not dispatch CLI" 0 !cli_calls
      | Error _ -> Alcotest.fail "non-advanceable execution failure changed category"
      | Ok _ -> Alcotest.fail "non-advanceable HTTP failure must remain terminal")))
;;

let test_mixed_before_advance_failure_stops_before_cli () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      let candidate = candidate "board-attention-mixed-persistence" in
      let invalid =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply (openai_text_response "not json"))
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
      publish_lane
        ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
        [ target "board-attention-persistence-first" invalid.base_url
        ; target "board-attention-persistence-second" successor.base_url
        ];
      let prepared =
        match prepare_exact ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "mixed persistence lane did not prepare"
      in
      let cli_calls = ref 0 in
      match
        Exact_flow.execute
          ~cli_runner:(cli_success_runner candidate cli_calls)
          ~clock
          ~before_dispatch:(fun _ -> Ok ())
          ~before_advance:(fun ~failed:_ ~next:_ -> Error "disk")
          prepared
      with
      | Error (Exact_flow.Before_advance_persistence_failed { cause; _ }) ->
        Alcotest.(check string) "persistence cause retained" "disk" cause;
        Alcotest.(check int) "persistence failure does not dispatch CLI" 0 !cli_calls;
        Alcotest.(check int) "successor is not dispatched" 0 (Fixture.post_count successor)
      | Error _ -> Alcotest.fail "before-advance failure changed category"
      | Ok _ -> Alcotest.fail "before-advance failure must remain terminal")))
;;

let test_mixed_before_dispatch_failure_stops_before_cli () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      let candidate = candidate "board-attention-mixed-bind-persistence" in
      let server =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply
             (Fixture.openai_response
                (judgment_output ~candidate_id:candidate.candidate_id)))
      in
      publish_lane
        ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
        [ target "board-attention-bind-persistence-http" server.base_url ];
      let prepared =
        match prepare_exact ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "mixed bind-persistence lane did not prepare"
      in
      let cli_calls = ref 0 in
      match
        Exact_flow.execute
          ~cli_runner:(cli_success_runner candidate cli_calls)
          ~clock
          ~before_dispatch:(fun _ -> Error "disk")
          ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
          prepared
      with
      | Error (Exact_flow.Before_dispatch_persistence_failed { cause; _ }) ->
        Alcotest.(check string) "bind persistence cause retained" "disk" cause;
        Alcotest.(check int) "bind persistence failure does not dispatch HTTP" 0
          (Fixture.post_count server);
        Alcotest.(check int) "bind persistence failure does not dispatch CLI" 0 !cli_calls
      | Error _ -> Alcotest.fail "before-dispatch failure changed category"
      | Ok _ -> Alcotest.fail "before-dispatch failure must remain terminal")))
;;

let test_mixed_cli_failure_keeps_http_evidence () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      let candidate = candidate "board-attention-mixed-cli-failure" in
      let invalid =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply (openai_text_response "not json"))
      in
      let http = target "board-attention-cli-failure-http" invalid.base_url in
      publish_lane ~cli_slot_ids:[ Fixture.cli_primary_runtime ] [ http ];
      let prepared =
        match prepare_exact ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "mixed CLI-failure lane did not prepare"
      in
      let cli_calls = ref 0 in
      let runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
        incr cli_calls;
        Error (Masc.Fusion_official_client.Setup_failure (Provider_error "client unavailable"))
      in
      match
        Exact_flow.execute
          ~cli_runner:runner
          ~clock
          ~before_dispatch:(fun _ -> Ok ())
          ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
          prepared
      with
      | Error
          (Exact_flow.Cli_slots_exhausted
             { prior_error = Some (Exact_flow.Providers_exhausted { attempts = [ provenance ]; _ })
             ; failures = [ _ ]
             }) ->
        Alcotest.(check string)
          "CLI failure retains the exhausted HTTP receipt"
          http.id
          provenance.slot_id;
        Alcotest.(check int) "the declared CLI slot was tried once" 1 !cli_calls
      | Error _ -> Alcotest.fail "CLI failure did not retain the HTTP execution failure"
      | Ok _ -> Alcotest.fail "a failed CLI tail must not produce a judgment")))
;;

let test_mixed_cli_cancellation_propagates_once () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      let candidate = candidate "board-attention-mixed-cli-cancel" in
      let rejected =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply
             (Fixture.openai_response
                (judgment_output ~candidate_id:"another-candidate")))
      in
      publish_lane
        ~cli_slot_ids:[ Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime ]
        [ target "board-attention-cancel-http" rejected.base_url ];
      let prepared =
        match prepare_exact ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "mixed cancellation lane did not prepare"
      in
      let before = board_attention_run_ids () in
      let cli_calls = ref 0 in
      let runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
        incr cli_calls;
        raise (Eio.Cancel.Cancelled (Failure "synthetic cli cancellation"))
      in
      let propagated =
        match
          Exact_flow.execute
            ~cli_runner:runner
            ~clock
            ~before_dispatch:(fun _ -> Ok ())
            ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
            prepared
        with
        | exception Eio.Cancel.Cancelled _ -> true
        | Ok _ | Error _ -> false
      in
      Alcotest.(check bool) "CLI cancellation propagates" true propagated;
      Alcotest.(check int) "cancellation stops the CLI walk" 1 !cli_calls;
      match (new_board_attention_run ~before).Exact_lane_run_registry.status with
      | Exact_lane_run_registry.Completed
          { outcome = Exact_lane_run_registry.Cancelled; _ }
      | Exact_lane_run_registry.Completion_persistence_failed
          { intended_outcome = Exact_lane_run_registry.Cancelled; _ } ->
        ()
      | Exact_lane_run_registry.Running
      | Exact_lane_run_registry.Completed _
      | Exact_lane_run_registry.Completion_persistence_failed _ ->
        Alcotest.fail "cancelled CLI tail did not close the exact run as cancelled")))
;;

let test_cli_only_executes_without_http_provenance () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw:_ ~net ~clock ->
      let candidate = candidate "board-attention-cli-only" in
      publish_lane ~cli_slot_ids:[ Fixture.cli_primary_runtime ] [];
      let prepared = match prepare_exact ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "CLI-only Board lane must prepare" in
      let calls = ref 0 in
      let runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
        incr calls;
        Ok (Yojson.Safe.to_string (judgment_output ~candidate_id:candidate.Candidate.candidate_id)) in
      match Exact_flow.execute ~cli_runner:runner
        ~clock
        ~before_dispatch:(fun _ -> Alcotest.fail "CLI-only must not bind an HTTP receipt")
        ~before_advance:(fun ~failed:_ ~next:_ -> Alcotest.fail "CLI-only must not advance HTTP")
        prepared with
      | Error _ -> Alcotest.fail "CLI-only Board judgment failed"
      | Ok judgment ->
        Alcotest.(check int) "one actual CLI dispatch" 1 !calls;
        (match judgment.Candidate.source with
         | Candidate.Cli_lane_slot -> ()
         | Candidate.Exact_attempt _ -> Alcotest.fail "fabricated HTTP provenance"
         | Candidate.Vendor_system_one _ ->
           Alcotest.fail "a CLI answer recorded as a vendor answer"))))
;;

(* A CLI-only lane has no HTTP failure behind it, so the failure it reports
   carries the walked slots alone. [prior_error = None] is that fact, not a
   missing field. *)
let test_cli_only_failure_keeps_the_walked_slots () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw:_ ~net ~clock ->
      let candidate = candidate "board-attention-cli-only-failed" in
      publish_lane ~cli_slot_ids:[ Fixture.cli_primary_runtime ] [];
      let prepared =
        match prepare_exact ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "CLI-only Board lane must prepare"
      in
      let runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
        Ok "not json"
      in
      match
        Exact_flow.execute
          ~cli_runner:runner
          ~clock
          ~before_dispatch:(fun _ -> Alcotest.fail "CLI-only must not bind an HTTP receipt")
          ~before_advance:(fun ~failed:_ ~next:_ -> Alcotest.fail "CLI-only must not advance HTTP")
          prepared
      with
      | Error (Exact_flow.Cli_slots_exhausted { prior_error; failures }) ->
        Alcotest.(check bool) "no HTTP failure is invented" true (Option.is_none prior_error);
        Alcotest.(check int) "the one walked slot is kept" 1 (List.length failures)
      | Error (Exact_flow.Providers_exhausted _) ->
        Alcotest.fail "a CLI-only lane has no provider walk to exhaust"
      | Error _ -> Alcotest.fail "a failed CLI-only walk must report its slots"
      | Ok _ -> Alcotest.fail "a slot answering non-JSON must not produce a judgment")))
;;

(* The HTTP slot of [prepared_with_cli_tail] is a closed port, so [execute]
   exhausts it and walks the CLI tail, the path production takes when a quota
   pool is spent. Callbacks accept every binding. *)
let execute_with_tail ~clock ~runner prepared =
  Exact_flow.execute
    ~cli_runner:runner
    ~clock
    ~before_dispatch:(fun _ -> Ok ())
    ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
    prepared
;;

let latest_board_attention_run ~actor =
  Exact_lane_run_registry.list_runs (Exact_lane_run_registry.global ())
  |> List.filter (fun (run : Exact_lane_run_registry.run) ->
    run.lane = Exact_lane_run_registry.Board_attention && String.equal run.actor actor)
  |> List.sort (fun (a : Exact_lane_run_registry.run) (b : Exact_lane_run_registry.run) ->
    Float.compare b.started_at a.started_at)
  |> function
  | run :: _ -> run
  | [] -> Alcotest.fail "no board attention run was recorded"
;;

(* RFC cli-runtimes-as-lane-slots §3: a run a CLI slot answered is recorded
   with [selected_slot] = that runtime id. The record used to close as failed
   on the last HTTP slot before the tail ran (2026-09-19: 12 of 12 runs a CLI
   slot answered read "failed"). *)
let test_cli_tail_judges_with_its_own_provenance () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw:_ ~net ~clock ->
      let candidate = candidate "board-attention-cli-tail" in
      let prepared =
        prepared_with_cli_tail
          ~net:(Some net)
          ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
          candidate
      in
      let runner, seen =
        recording_runner (fun _ ->
          Ok
            (Yojson.Safe.to_string
               (judgment_output ~candidate_id:candidate.Candidate.candidate_id)))
      in
      match execute_with_tail ~clock ~runner prepared with
      | Error _ -> Alcotest.fail "the cli tail did not judge after the HTTP slot failed"
      | Ok judgment ->
        Alcotest.(check string)
          "the slot id is that client, not a catalog slot"
          Fixture.cli_primary_runtime
          judgment.Candidate.slot_id;
        (match judgment.Candidate.source with
         | Candidate.Cli_lane_slot -> ()
         | Candidate.Exact_attempt _ ->
           Alcotest.fail "a cli judgment must not claim an exact attempt"
         | Candidate.Vendor_system_one _ ->
           Alcotest.fail "a cli judgment must not claim a vendor answer");
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
             (String.length prompt > 0));
        let run = latest_board_attention_run ~actor:candidate.Candidate.keeper_name in
        (match run.status with
         | Exact_lane_run_registry.Completed
             { outcome = Exact_lane_run_registry.Succeeded; selected_slot; _ }
         | Exact_lane_run_registry.Completion_persistence_failed
             { intended_outcome = Exact_lane_run_registry.Succeeded; selected_slot; _ } ->
           Alcotest.(check (option string))
             "the run record names the client that answered"
             (Some Fixture.cli_primary_runtime)
             selected_slot
         | Exact_lane_run_registry.Running
         | Exact_lane_run_registry.Completed _
         | Exact_lane_run_registry.Completion_persistence_failed _ ->
           Alcotest.fail "the run record did not close as succeeded"))))
;;

let test_cli_tail_advances_after_wrong_candidate () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw:_ ~net ~clock ->
      let candidate = candidate "board-attention-cli-domain-failover" in
      let prepared = prepared_with_cli_tail ~net:(Some net)
          ~cli_slot_ids:[Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime]
          candidate in
      let attempted = ref [] in
      let runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt:_ =
        attempted := !attempted @ [runtime_id];
        let candidate_id =
          if String.equal runtime_id Fixture.cli_primary_runtime then "another-candidate"
          else candidate.Candidate.candidate_id in
        Ok (Yojson.Safe.to_string (judgment_output ~candidate_id))
      in
      match execute_with_tail ~clock ~runner prepared with
      | Error _ -> Alcotest.fail "the second cli slot did not judge"
      | Ok judgment ->
        Alcotest.(check (list string)) "wrong identity advances to next slot"
          [Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime] !attempted;
        Alcotest.(check string) "accepted slot owns the judgment"
          Fixture.cli_secondary_runtime judgment.Candidate.slot_id;
        (match judgment.Candidate.source with
         | Candidate.Cli_lane_slot -> ()
         | Candidate.Exact_attempt _ -> Alcotest.fail "CLI answer forged HTTP provenance"
         | Candidate.Vendor_system_one _ ->
           Alcotest.fail "CLI answer recorded as a vendor answer"))))
;;

let test_cli_tail_without_declared_slots_is_typed () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw:_ ~net ~clock ->
      let candidate = candidate "board-attention-cli-tail-empty" in
      let prepared =
        prepared_with_cli_tail ~net:(Some net) ~cli_slot_ids:[] candidate
      in
      let runner, seen = recording_runner (fun _ -> Ok "{}") in
      match execute_with_tail ~clock ~runner prepared with
      | Error (Exact_flow.Providers_exhausted { detail; _ }) ->
        Alcotest.(check bool) "no client was asked" true (Option.is_none !seen);
        Alcotest.(check bool)
          "the failure is the HTTP one, with no tail walked"
          false
          (contains_substring ~needle:"cli tail" detail)
      | Error (Exact_flow.Cli_slots_exhausted _) ->
        Alcotest.fail "a lane that declares no slot walked none, so none is exhausted"
      | Error _ -> Alcotest.fail "provider exhaustion must stay provider exhaustion"
      | Ok _ -> Alcotest.fail "a lane with no declared tail must not produce a judgment")))
;;

let test_cli_tail_rejects_a_verdict_for_another_candidate () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw:_ ~net ~clock ->
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
      match execute_with_tail ~clock ~runner prepared with
      (* The failures arrive as the walker's own values, so the test asks the
         type which slot refused and why -- not a sentence for the substring. *)
      | Error (Exact_flow.Cli_slots_exhausted { prior_error; failures }) ->
        Alcotest.(check bool)
          "the HTTP failure the tail followed is kept"
          true
          (match prior_error with
           | Some (Exact_flow.Providers_exhausted _) -> true
           | Some _ | None -> false);
        (match failures with
         | [ failure ] ->
           let rendered = Keeper_lane_cli_oneshot.failure_to_string failure in
           Alcotest.(check bool)
             "the rejecting slot is named"
             true
             (contains_substring ~needle:Fixture.cli_primary_runtime rendered);
           Alcotest.(check bool)
             "the identity mismatch is reported"
             true
             (contains_substring ~needle:"identity mismatch" rendered)
         | failures ->
           Alcotest.failf "walked one slot, kept %d failures" (List.length failures))
      | Error _ -> Alcotest.fail "a rejected cli verdict must read as an exhausted tail"
      | Ok _ ->
        Alcotest.fail "a verdict naming another candidate must not become this judgment")))
;;

(* A failed durable write before dispatch says the record is in doubt; a second
   transport does not settle that, so the tail is not walked. *)
let test_persistence_failure_does_not_walk_the_cli_tail () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio (fun ~sw:_ ~net ~clock ->
      let candidate = candidate "board-attention-cli-tail-persistence" in
      let prepared =
        prepared_with_cli_tail
          ~net:(Some net)
          ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
          candidate
      in
      let runner, seen =
        recording_runner (fun _ ->
          Ok
            (Yojson.Safe.to_string
               (judgment_output ~candidate_id:candidate.Candidate.candidate_id)))
      in
      match
        Exact_flow.execute
          ~cli_runner:runner
          ~clock
          ~before_dispatch:(fun _ -> Error "disk")
          ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
          prepared
      with
      | Error (Exact_flow.Before_dispatch_persistence_failed { cause; _ }) ->
        Alcotest.(check string) "the persistence cause is kept" "disk" cause;
        Alcotest.(check bool) "no client was asked" true (Option.is_none !seen)
      | Error _ -> Alcotest.fail "a persistence failure must keep its own terminal"
      | Ok _ -> Alcotest.fail "a persistence failure must not become a judgment")))
;;

(* The four AGENT_CORE bookkeeping constructors all stay on the typed terminal
   side of the transport decision. A successful measurement followed by a
   failed dispatch callback supplies the opaque visit, receipt, and evidence
   values needed to construct them without a test-only production hook. *)
let test_flow_bookkeeping_failures_are_not_provider_exhaustion () =
  run_eio (fun ~sw ~net ~clock ->
    let id = "board-attention-bookkeeping-classification" in
    let server =
      Fixture.start_server
        ~sw
        ~net
        ~clock
        (Fixture.Reply {|{"input_tokens":1}|})
    in
    let snapshot =
      Fixture.resolver_snapshot
        ~requires_token_measurement:true
        ~source:"Board attention bookkeeping classification"
        [ target id server.base_url ]
    in
    let admitted_target =
      Exact_output.admit_target_ref snapshot id |> Result.get_ok
    in
    let flow_candidate =
      Exact_output.make_flow_candidate ~id ~admitted_target |> Result.get_ok
    in
    let requirement =
      Exact_output.make_output_requirement
        ~schema:Keeper_structured_output_schema.board_attention_judgment_batch_output_schema
        ~minimum_guarantee:Exact_output.Json_syntax
    in
    let start_flow () =
      Exact_output.snapshot_flow
        ~first:flow_candidate
        ~rest:[]
        ~messages:[ Agent_core.Types.user_msg "classify bookkeeping failure" ]
        requirement
      |> Result.get_ok
      |> Exact_output.start_flow
      |> Result.get_ok
    in
    let measurement = ref None in
    let captured_failure =
      Exact_output.execute_flow_once
        ~net
        ~clock
        ~before_measurement_dispatch:(fun receipt ->
          measurement := Some receipt;
          Ok ())
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_dispatch:(fun _ -> Error "capture admitted candidate")
        ~before_advance:(fun ~failed:_ ~next:_ ->
          Alcotest.fail "dispatch callback failure advanced")
        ~validate:(fun _ -> Alcotest.fail "dispatch callback failure reached validation")
        (start_flow ())
    in
    match captured_failure, !measurement with
    | Error
        (Exact_output.Flow_execution_terminal
           { cause =
               Exact_output.Flow_before_dispatch_callback_failed
                 { candidate; evidence; _ }
           ; _
           }), Some measurement ->
      let visit = candidate.visit in
      let failures =
        [ ( Exact_output.Flow_attempt_start_failed
              { candidate = visit
              ; cause = Exact_output.Call_id_generation_failed "call id"
              ; evidence
              }
          , Some "call_id_generation_failed detail=\"call id\"" )
        ; ( Exact_output.Flow_measurement_start_failed
              { candidate = visit
              ; cause =
                  Exact_output.Measurement_operation_id_generation_failed "operation id"
              ; evidence
              }
          , Some "operation_id_generation_failed detail=\"operation id\"" )
        ; ( Exact_output.Flow_before_measurement_dispatch_callback_failed
              { measurement; cause = "measurement intent"; evidence }
          , None )
        ; ( Exact_output.Flow_measurement_terminal_callback_failed
              { measurement; cause = "measurement terminal"; evidence }
          , None )
        ]
      in
      List.iter
        (fun (failure, expected_cause) ->
           match Exact_flow.terminal_of_flow_error failure with
           | Exact_flow.Flow_bookkeeping_failed { detail; _ } ->
             Option.iter
               (fun expected ->
                  Alcotest.(check bool)
                    "bookkeeping cause reaches the durable detail"
                    true
                    (contains_substring ~needle:expected detail))
               expected_cause
           | Exact_flow.Providers_exhausted _ ->
             Alcotest.fail "bookkeeping failure was classified as provider exhaustion"
           | _ -> Alcotest.fail "bookkeeping failure lost its typed terminal")
        failures
    | Ok _, _ | Error _, _ ->
      Alcotest.fail "fixture did not retain measurement and admitted candidate")
;;

(* Jev goes out through the pooled client, which needs a pool on this domain;
   the exact-output lane dials its own connections and does not. *)
let run_eio_with_http_pool f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Masc_http_client.with_scoped_pool ~sw ~env (fun () ->
    f ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env))
;;

(* Jev is on for [f] and asks the server at [endpoint]. *)
let with_jev ~endpoint f =
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "test-typesafeai-key") (fun () ->
    Masc_test_deps.with_typesafeai_policy
      { Runtime_schema.default_typesafeai with
        destinations =
          ( { Runtime_schema.endpoint; model = "requested-model"; api_key_env = "TYPESAFEAI_API_KEY" }
          , [] )
      }
      f)
;;

(* A System One answer to the adapter's one question, [relevance]. *)
let jev_response ~choice =
  Yojson.Safe.to_string
    (`Assoc
        [ "model", `String "jev-latest"
        ; ( "answers"
          , `Assoc
              [ ( "relevance"
                , `Assoc
                    [ "type", `String "choice"
                    ; "choice", `String choice
                    ; ( "probabilities"
                      , `Assoc [ "relevant", `Float 0.2; "not_relevant", `Float 0.8 ] )
                    ; "confidence", `Float 0.6
                    ] )
              ] )
        ])
;;

let json_string_field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`String value) -> Some value
     | Some _ | None -> None)
  | _ -> None
;;

let json_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let last_log_seq () =
  match Log.Ring.recent ~limit:1 () with
  | (entry : Log.Ring.entry) :: _ -> entry.seq
  | [] -> -1
;;

(* The [jev] details of every terminal entry the flow logged for this
   candidate after [since_seq]. *)
let terminal_jev_entries ~since_seq ~candidate_id =
  Log.Ring.recent ~limit:1000 ~module_filter:"Keeper" ~since_seq ~order:`Oldest_first ()
  |> List.filter_map (fun (entry : Log.Ring.entry) ->
    match entry.details with
    | `Assoc fields ->
      (match List.assoc_opt "candidate_id" fields, List.assoc_opt "jev" fields with
       | Some (`String id), Some jev when String.equal id candidate_id -> Some jev
       | _ -> None)
    | _ -> None)
;;

type jev_run =
  { result : (Candidate.judgment, string Exact_flow.execution_error) result
  ; jev_posts : int
  ; jev_destination : string
  ; jev_request_bodies : string list
  ; llm_posts : int
  ; terminal_jev : Yojson.Safe.t list
  ; exact_selected_slot : string option
  ; exact_output : Yojson.Safe.t
  }

(* Runs the exact flow with Jev switched on and answering [jev_choice], in
   front of one LLM slot that answers relevant. *)
let execute_behind_jev ~name ~jev_choice =
  with_prompt_registry (fun () ->
    run_eio_with_http_pool (fun ~sw ~net ~clock ->
      let candidate = candidate name in
      let jev =
        Fixture.start_server ~sw ~net ~clock (Fixture.Reply (jev_response ~choice:jev_choice))
      in
      let llm =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply
             (Fixture.openai_response
                (judgment_output ~candidate_id:candidate.candidate_id)))
      in
      publish_lane [ target (name ^ "-llm") llm.base_url ];
      let prepared =
        match prepare_exact ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "the Jev fixture candidate was not admitted"
      in
      with_jev ~endpoint:jev.base_url (fun () ->
        let since_seq = last_log_seq () in
        let before = board_attention_run_ids () in
        let result =
          Exact_flow.execute
            ~clock
            ~before_dispatch:(fun _ -> Ok ())
            ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
            prepared
        in
        let exact_selected_slot, exact_output =
          match (new_board_attention_run_full ~before).Exact_lane_run_registry.status with
          | Exact_lane_run_registry.Completed
              { outcome = Exact_lane_run_registry.Succeeded
              ; selected_slot
              ; output
              ; _
              } ->
            selected_slot, output
          | Exact_lane_run_registry.Running
          | Exact_lane_run_registry.Completed _
          | Exact_lane_run_registry.Completion_persistence_failed _ ->
            Alcotest.fail "Jev fixture did not close the exact run as succeeded"
        in
        { result
        ; jev_posts = Fixture.post_count jev
        ; jev_destination = jev.base_url
        ; jev_request_bodies = Fixture.request_bodies jev
        ; llm_posts = Fixture.post_count llm
        ; terminal_jev =
            terminal_jev_entries ~since_seq ~candidate_id:candidate.candidate_id
        ; exact_selected_slot
        ; exact_output
        })))
;;

let check_terminal_jev label ~answer ~rejudged run =
  match run.terminal_jev with
  | [ jev ] ->
    Alcotest.(check (option string))
      (label ^ ": Jev's answer on the terminal entry")
      (Some answer)
      (json_string_field "answer" jev);
    Alcotest.(check (option string))
      (label ^ ": what the LLM lane decided after Jev")
      rejudged
      (json_string_field "rejudged" jev)
  | entries ->
    Alcotest.failf
      "%s: expected one terminal entry for the candidate, found %d"
      label
      (List.length entries)
;;

let expected_jev_provenance run : Candidate.system_one_provenance =
  match run.jev_request_bodies with
  | [ body ] ->
    { destination_uri = run.jev_destination
    ; answering_model_id = "jev-latest"
    ; request_body_sha256 = Digestif.SHA256.(digest_string body |> to_hex)
    }
  | bodies ->
    Alcotest.failf
      "expected one exact Jev request body, saw %d"
      (List.length bodies)
;;

let check_terminal_provenance label run provenance =
  match run.terminal_jev with
  | [ jev ] ->
    Alcotest.(check bool)
      (label ^ ": terminal evidence repeats the request provenance")
      true
      (json_field "provenance" jev
       = Some (Candidate.system_one_provenance_to_yojson provenance))
  | _ -> Alcotest.failf "%s: terminal evidence is missing" label
;;

let test_jev_relevant_is_kept () =
  let run = execute_behind_jev ~name:"board-attention-jev-relevant" ~jev_choice:"relevant" in
  check_terminal_jev "relevant" ~answer:"relevant" ~rejudged:None run;
  match run.result with
  | Ok judgment ->
    Alcotest.(check int) "Jev asked once" 1 run.jev_posts;
    Alcotest.(check int) "the LLM lane is not asked" 0 run.llm_posts;
    Alcotest.(check (option string))
      "Vendor System One does not fabricate a selected slot"
      None
      run.exact_selected_slot;
    Alcotest.(check bool)
      "the exact-run output keeps the accepted judgment"
      true
      (run.exact_output = Candidate.judgment_to_yojson judgment);
    (match judgment.Candidate.source with
     | Candidate.Vendor_system_one provenance ->
       let expected = expected_jev_provenance run in
       Alcotest.(check string)
         "the configured destination is durable"
         run.jev_destination
         provenance.destination_uri;
       Alcotest.(check string)
         "the model Jev's response named"
         "jev-latest"
         provenance.answering_model_id;
       Alcotest.(check string)
         "the exact request bytes are durable"
         expected.request_body_sha256
         provenance.request_body_sha256;
       check_terminal_provenance "relevant" run provenance
     | Candidate.Exact_attempt _ | Candidate.Cli_lane_slot ->
       Alcotest.fail "a relevant Jev answer must be recorded as Jev's")
  | Error _ -> Alcotest.fail "a relevant Jev answer did not complete the flow"
;;

let check_judged_by_the_llm_lane label run =
  match run.result with
  | Ok judgment ->
    Alcotest.(check int) (label ^ ": Jev asked once") 1 run.jev_posts;
    Alcotest.(check int) (label ^ ": the LLM lane judges it") 1 run.llm_posts;
    (match judgment.Candidate.source with
     | Candidate.Exact_attempt _ -> ()
     | Candidate.Vendor_system_one _ | Candidate.Cli_lane_slot ->
       Alcotest.failf "%s: the judgment must come from the LLM lane" label);
    (match judgment.Candidate.verdict.Judgment.decision with
     | Judgment.Relevant -> ()
     | Judgment.Not_relevant ->
       Alcotest.failf "%s: the LLM lane's relevant verdict was not the one kept" label)
  | Error _ -> Alcotest.failf "%s: the LLM lane did not complete the flow" label
;;

(* The terminal entry is what tells these two apart: both end in one Jev call
   and one LLM call, but only the first had an answer from Jev. *)
let test_jev_not_relevant_is_judged_again () =
  let run =
    execute_behind_jev ~name:"board-attention-jev-not-relevant" ~jev_choice:"not_relevant"
  in
  check_judged_by_the_llm_lane "not_relevant" run;
  check_terminal_jev "not_relevant" ~answer:"not_relevant" ~rejudged:(Some "relevant") run;
  check_terminal_provenance "not_relevant" run (expected_jev_provenance run)
;;

let test_jev_not_relevant_cli_fallback_is_in_the_terminal_entry () =
  Fixture.with_official_client_runtimes (fun () ->
  with_prompt_registry (fun () ->
    run_eio_with_http_pool (fun ~sw ~net ~clock ->
      let candidate = candidate "board-attention-jev-cli-fallback" in
      let jev =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply (jev_response ~choice:"not_relevant"))
      in
      publish_lane
        ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
        [ target "board-attention-jev-closed-http" "http://127.0.0.1:1" ];
      let prepared =
        match prepare_exact ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "the Jev CLI fallback fixture did not prepare"
      in
      let before = board_attention_run_ids () in
      let cli_calls = ref 0 in
      let result, terminal_jev =
        with_jev ~endpoint:jev.base_url (fun () ->
          let since_seq = last_log_seq () in
          let result =
            Exact_flow.execute
              ~cli_runner:(cli_success_runner candidate cli_calls)
              ~clock
              ~before_dispatch:(fun _ -> Ok ())
              ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
              prepared
          in
          ( result
          , terminal_jev_entries
              ~since_seq
              ~candidate_id:candidate.Candidate.candidate_id ))
      in
      (match result with
       | Ok judgment ->
         Alcotest.(check string)
           "the declared CLI slot supplies the final judgment"
           Fixture.cli_primary_runtime
           judgment.Candidate.slot_id;
         (match judgment.Candidate.source with
          | Candidate.Cli_lane_slot -> ()
          | Candidate.Exact_attempt _ | Candidate.Vendor_system_one _ ->
            Alcotest.fail "the CLI fallback judgment lost its source")
       | Error _ -> Alcotest.fail "the declared CLI fallback did not answer");
      Alcotest.(check int) "Jev is asked once" 1 (Fixture.post_count jev);
      Alcotest.(check int) "the CLI fallback is asked once" 1 !cli_calls;
      (match terminal_jev with
       | [ jev ] ->
         Alcotest.(check (option string))
           "the terminal entry keeps Jev's answer"
           (Some "not_relevant")
           (json_string_field "answer" jev);
         Alcotest.(check (option string))
           "the terminal entry includes the CLI fallback decision"
           (Some "relevant")
           (json_string_field "rejudged" jev)
       | entries ->
         Alcotest.failf
           "expected one terminal Jev entry after the CLI fallback, found %d"
           (List.length entries));
      check_cli_run_selected ~before ~slot_id:Fixture.cli_primary_runtime)))
;;

let test_jev_choice_outside_the_question_is_judged_again () =
  let run = execute_behind_jev ~name:"board-attention-jev-unknown-choice" ~jev_choice:"maybe" in
  check_judged_by_the_llm_lane "unknown choice" run;
  check_terminal_jev "unknown choice" ~answer:"failed" ~rejudged:None run
;;

(* The adapter alone, against the same stand-in: the request offers the two
   decisions under their labels, and a not-relevant answer decodes to
   [Not_relevant] rather than an error. *)
let test_jev_adapter_sends_the_decisions_and_reads_not_relevant () =
  run_eio_with_http_pool (fun ~sw ~net ~clock ->
    let candidate = candidate "board-attention-jev-adapter" in
    let jev =
      Fixture.start_server ~sw ~net ~clock (Fixture.Reply (jev_response ~choice:"not_relevant"))
    in
    with_jev ~endpoint:jev.base_url (fun () ->
      let judged =
        match
          Typesafeai_board_attention.judge_candidate
            ~clock
            ~destinations:
              ( { Typesafeai_client.endpoint = jev.base_url
                 ; model = "requested-model"
                 ; api_key = "test-typesafeai-key"
                 }
              , [] )
            ~candidate
            ()
        with
        | Ok judged -> judged
        | Error detail ->
          Alcotest.failf "the not_relevant answer did not decode: %s" detail
      in
      Alcotest.(check string)
        "the destination used by the adapter"
        jev.base_url
        judged.provenance.destination_uri;
      Alcotest.(check string)
        "the model Jev's response named"
        "jev-latest"
        judged.provenance.answering_model_id;
      (match judged.verdict.Judgment.decision with
       | Judgment.Not_relevant -> ()
       | Judgment.Relevant -> Alcotest.fail "a not_relevant answer decoded as Relevant");
      match Fixture.request_bodies jev with
      | [ body ] ->
        Alcotest.(check string)
          "the adapter hashes the exact serialized body"
          Digestif.SHA256.(digest_string body |> to_hex)
          judged.provenance.request_body_sha256;
        let request_json = Yojson.Safe.from_string body in
        let state, relevance =
          match request_json with
          | `Assoc fields ->
            ( List.assoc_opt "state" fields
            , match List.assoc_opt "questions" fields with
              | Some (`Assoc questions) -> List.assoc_opt "relevance" questions
              | Some _ | None -> None )
          | _ -> None, None
        in
        Alcotest.(check bool)
          "Jev receives exactly the current signal and projected keeper role"
          true
          (state =
           Some
             (match Candidate.singleton_judgment_request candidate with
              | Ok request -> request
              | Error detail ->
                Alcotest.failf "candidate request projection failed: %s" detail));
        (match relevance with
         | Some (`Assoc question) ->
           Alcotest.(check (option string))
             "the relevance question is a choice"
             (Some "choice")
             (json_string_field "type" (`Assoc question));
           (match List.assoc_opt "criteria" question with
            | Some (`Assoc criteria) ->
              Alcotest.(check (list string))
                "the request offers every decision under its label"
                Judgment.decision_tokens
                (List.map fst criteria);
              Alcotest.(check (option string))
                "relevant requires the current signal, not capability overlap"
                (Some
                   "The current signal itself directly addresses this keeper, requests or assigns the role described by its instructions, or contains a concrete request specific to that role; general topic or capability overlap alone is insufficient.")
                (match List.assoc_opt "relevant" criteria with
                 | Some (`String description) -> Some description
                 | Some _ | None -> None);
              Alcotest.(check (option string))
                "not relevant includes broad capability overlap"
                (Some
                   "The current signal is aimed elsewhere, is general discussion or noise, only overlaps with the keeper's broad capabilities, or does not require this keeper to act.")
                (match List.assoc_opt "not_relevant" criteria with
                 | Some (`String description) -> Some description
                 | Some _ | None -> None)
            | Some _ | None -> Alcotest.fail "the relevance question has no criteria map")
         | Some _ | None -> Alcotest.fail "the request carries no relevance question")
      | bodies ->
        Alcotest.failf "expected one request to Jev, saw %d" (List.length bodies)))
;;

let () =
  Alcotest.run
    "Keeper Board-attention exact flow"
    [ ( "production adapter"
      , [ Alcotest.test_case "CLI-only Board judgments need no HTTP attempt" `Quick
            test_cli_only_executes_without_http_provenance
        ; Alcotest.test_case
            "a failed CLI-only walk keeps the slots it walked"
            `Quick
            test_cli_only_failure_keeps_the_walked_slots
        ; Alcotest.test_case
            "CLI domain mismatch advances with correct provenance"
            `Quick test_cli_tail_advances_after_wrong_candidate
        ; Alcotest.test_case
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
            "mixed semantic exhaustion walks the CLI tail"
            `Quick
            test_mixed_semantic_exhaustion_walks_cli_tail
        ; Alcotest.test_case
            "mixed semantic and CLI failures keep both causes"
            `Quick
            test_mixed_semantic_rejection_and_cli_failure_keep_both_causes
        ; Alcotest.test_case
            "mixed advanceable final failure walks the CLI tail"
            `Quick
            test_mixed_advanceable_final_failure_walks_cli_tail
        ; Alcotest.test_case
            "mixed non-advanceable terminal stops before CLI"
            `Quick
            test_mixed_non_advanceable_terminal_stops_before_cli
        ; Alcotest.test_case
            "mixed persistence failure stops before CLI"
            `Quick
            test_mixed_before_advance_failure_stops_before_cli
        ; Alcotest.test_case
            "mixed bind persistence failure stops before CLI"
            `Quick
            test_mixed_before_dispatch_failure_stops_before_cli
        ; Alcotest.test_case
            "mixed CLI failure keeps HTTP evidence"
            `Quick
            test_mixed_cli_failure_keeps_http_evidence
        ; Alcotest.test_case
            "mixed CLI cancellation propagates once"
            `Quick
            test_mixed_cli_cancellation_propagates_once
        ; Alcotest.test_case
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
        ; Alcotest.test_case
            "a persistence failure does not walk the cli tail"
            `Quick
            test_persistence_failure_does_not_walk_the_cli_tail
        ; Alcotest.test_case
            "flow bookkeeping failures are not provider exhaustion"
            `Quick
            test_flow_bookkeeping_failures_are_not_provider_exhaustion
        ] )
    ; ( "jev first"
      , [ Alcotest.test_case
            "a relevant Jev answer is kept"
            `Quick
            test_jev_relevant_is_kept
        ; Alcotest.test_case
            "a not-relevant Jev answer is judged again by the LLM lane"
            `Quick
            test_jev_not_relevant_is_judged_again
        ; Alcotest.test_case
            "a not-relevant Jev terminal entry includes the CLI fallback"
            `Quick
            test_jev_not_relevant_cli_fallback_is_in_the_terminal_entry
        ; Alcotest.test_case
            "a Jev choice the question did not offer goes to the LLM lane"
            `Quick
            test_jev_choice_outside_the_question_is_judged_again
        ; Alcotest.test_case
            "the adapter offers every decision and reads not_relevant"
            `Quick
            test_jev_adapter_sends_the_decisions_and_reads_not_relevant
        ] )
    ]
;;
