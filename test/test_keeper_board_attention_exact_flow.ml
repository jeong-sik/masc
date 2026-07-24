open Masc

module Candidate = Keeper_board_attention_candidate
module Exact_flow = Keeper_board_attention_exact_flow
module Fixture = Compaction_exact_output_fixture
module Judgment = Keeper_board_attention_judgment

type callback_event =
  | Dispatch of Exact_flow.attempt_provenance
  | Advance of Exact_flow.attempt_provenance * Exact_flow.attempt_provenance

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

let publish_lane fixtures =
  let snapshot =
    Fixture.resolver_snapshot
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

let test_explicit_lane_failover_and_success_provenance () =
  with_prompt_registry (fun () ->
    run_eio (fun ~sw ~net ~clock ->
      let candidate = candidate "board-attention-failover" in
      let response =
        Fixture.openai_response
          (judgment_output ~candidate_id:candidate.candidate_id)
      in
      let server = Fixture.start_server ~sw ~net ~clock (Fixture.Reply response) in
      let first = target "board-attention-unreachable" (reserved_non_listening_loopback_base_url ~sw) in
      let second = target "board-attention-success" server.base_url in
      publish_lane [ first; second ];
      Alcotest.(check string)
        "explicit production lane"
        "board_attention_exact"
        Exact_flow.lane_id;
      let prepared =
        match Exact_flow.prepare ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "explicit Board-attention lane was not admitted"
      in
      let events = ref [] in
      let before_dispatch provenance : (unit, string) result =
        events := Dispatch provenance :: !events;
        Ok ()
      in
      let before_advance
            ~(failed : Exact_flow.attempt_provenance)
            ~(next : Exact_flow.attempt_provenance)
        : (unit, string) result
        =
        events := Advance (failed, next) :: !events;
        Ok ()
      in
      let judgment =
        match
          Exact_flow.execute
            ~clock
            ~before_dispatch
            ~before_advance
            prepared
        with
        | Ok judgment -> judgment
        | Error _ -> Alcotest.fail "OAS did not advance to the usable second slot"
      in
      Alcotest.(check int) "second slot dispatched once" 1 (Fixture.post_count server);
      match List.rev !events with
      | [ Dispatch first_dispatch
        ; Advance (failed, next)
        ; Dispatch second_dispatch
        ] ->
        Alcotest.(check string)
          "first dispatch uses first lane slot"
          first.id
          first_dispatch.slot_id;
        check_same_provenance "failed projection" first_dispatch failed;
        check_same_provenance "next projection" next second_dispatch;
        Alcotest.(check string)
          "second dispatch uses second lane slot"
          second.id
          second_dispatch.slot_id;
        Alcotest.(check string)
          "success slot is opaque admitted slot"
          second_dispatch.slot_id
          judgment.slot_id;
        Alcotest.(check string)
          "success call provenance"
          second_dispatch.call_id
          judgment.call_id;
        Alcotest.(check string)
          "success plan provenance"
          second_dispatch.plan_fingerprint
          judgment.plan_fingerprint;
        Alcotest.(check string)
          "success request provenance"
          second_dispatch.request_body_sha256
          judgment.request_body_sha256;
        (match judgment.verdict.decision with
         | Judgment.Relevant -> ()
         | Judgment.Not_relevant ->
           Alcotest.fail "strict singleton verdict changed decision")
      | _ ->
        Alcotest.fail
          "expected dispatch(first), advance(first,next), dispatch(next) projections"))
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
        match Exact_flow.prepare ~net:(Some net) candidate with
        | Ok prepared -> prepared
        | Error _ -> Alcotest.fail "valid domain-mismatch fixture was not admitted"
      in
      let dispatches = ref [] in
      let before_dispatch provenance : (unit, string) result =
        dispatches := provenance :: !dispatches;
        Ok ()
      in
      let before_advance
            ~(failed : Exact_flow.attempt_provenance)
            ~(next : Exact_flow.attempt_provenance)
        : (unit, string) result
        =
        Alcotest.failf
          "domain-invalid OAS success must not advance from %s to %s"
          failed.slot_id
          next.slot_id
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
      (match Exact_flow.prepare ~net:(Some net) candidate with
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
    match Exact_flow.prepare ~net:None candidate with
    | Error Exact_flow.Candidate_not_pending -> ()
    | Error _ -> Alcotest.failf "%s returned a different setup error" label
    | Ok _ -> Alcotest.failf "%s was admitted before requeue authorization" label
  in
  let expect_network_unavailable label candidate =
    match Exact_flow.prepare ~net:None candidate with
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
        ] )
    ]
;;
