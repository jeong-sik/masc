open Alcotest
open Masc

module Contract = Keeper_failure_judgment_contract

let require_ok = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let expect_error label json =
  match Contract.of_yojson json with
  | Error _ -> ()
  | Ok _ -> failf "%s unexpectedly decoded" label
;;

module Judge = Keeper_failure_judge

let response_contract_error =
  Judge.Response_contract_error
    { runtime_id = "glm-coding.glm-5-turbo"
    ; detail = "JSON parse error: Invalid token '```json"
    }
;;

let oas_error =
  Judge.Oas_error
    { runtime_id = "glm-coding.glm-5-turbo"
    ; error =
        Agent_sdk.Error.Api
          (Llm_provider.Retry.RateLimited { retry_after = None; message = "slow down" })
    }
;;

(* The fence in [response_contract_error] is the live shape: keeper rondo settled its
   lane on it (event-queue.json last_settlement, 2026-07-25T10:44Z) and stopped
   advancing turns. Only that class may re-ask the next candidate; the enumeration is
   exhaustive so a new error class has to make this decision explicitly. *)
let test_only_a_response_contract_failure_advances_the_walk () =
  check bool "a fenced reply is re-asked of the next candidate" true
    (Judge.advances_walk response_contract_error);
  check bool "an OAS error does not re-walk what OAS already walked" false
    (Judge.advances_walk oas_error);
  check bool "a prompt contract error is identical for every candidate" false
    (Judge.advances_walk (Judge.Prompt_contract_error "template missing"));
  check bool "a configuration error is about the identity, not the answer" false
    (Judge.advances_walk (Judge.Runtime_configuration_error "no structured judge"))
;;

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    output_string oc content)
;;

let runtime_toml ~judge =
  Printf.sprintf
    {|
[runtime]
default = "p.first"
structured_judge = "%s"

[runtime.lanes.judge_lane]
strategy = "ordered"
candidates = [ "p.first", "p.second" ]

[providers.p]
display-name = "P"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.first]
api-name = "first"
max-context = 8192
tools-support = true
streaming = true

[models.second]
api-name = "second"
max-context = 8192
tools-support = true
streaming = true

[p.first]
is-default = true
max-concurrent = 1

[p.second]
max-concurrent = 1
|}
    judge
;;

let require_candidates = function
  | Ok candidates -> candidates
  | Error error -> fail (Judge.error_detail error)
;;

let init_runtime ~judge =
  let path = Filename.temp_file "failure_judgment_runtime_" ".toml" in
  write_file path (runtime_toml ~judge);
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error detail -> failf "Runtime.init_default failed: %s" detail
;;

(* One code path for both shapes of the configured identity: a lane contributes its
   ordered candidates, a single runtime contributes itself. Before this the judge
   resolved one id, so a runtime that would not honour the contract had no successor. *)
let test_lane_identity_yields_ordered_candidates () =
  init_runtime ~judge:"judge_lane";
  check (list string) "lane order is preserved" [ "p.first"; "p.second" ]
    (Judge.resolve_candidates () |> require_candidates)
;;

let test_single_runtime_identity_yields_one_candidate () =
  init_runtime ~judge:"p.second";
  check (list string) "a single runtime is a one-element walk" [ "p.second" ]
    (Judge.resolve_candidates () |> require_candidates)
;;

(* test_runtime_config_validity.ml already loads the shipped seed and pins the
   configured judgment id as a literal, which is a drift guard on the value. This
   asserts the property that value has to satisfy: the boundary has a successor at
   all, and the candidates are not one provider's formatting habit repeated. A pinned
   string cannot say that — it would still pass if the lane were narrowed to a single
   candidate on one provider. The fixture above proves the resolver; this proves what
   an operator actually gets. *)
let shipped_runtime_config () =
  let candidates = [ "config/runtime.toml"; Filename.concat ".." "config/runtime.toml" ] in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> fail "shipped config/runtime.toml not found"
;;

let test_shipped_config_gives_the_judgment_boundary_a_successor () =
  (match Runtime.init_default ~config_path:(shipped_runtime_config ()) with
   | Ok () -> ()
   | Error detail -> failf "shipped config/runtime.toml does not load: %s" detail);
  let candidates = Judge.resolve_candidates () |> require_candidates in
  (* One candidate is the shape that made a fenced reply terminal. *)
  check bool "the shipped judgment identity has a successor" true
    (List.length candidates > 1);
  check bool "candidates are distinct" true
    (List.length (List.sort_uniq compare candidates) = List.length candidates);
  let provider id = match String.index_opt id '.' with
    | Some i -> String.sub id 0 i
    | None -> id
  in
  (* A second candidate on the same provider would repeat the formatting habit. *)
  check bool "candidates span more than one provider" true
    (List.length (List.sort_uniq compare (List.map provider candidates)) > 1)
;;

let test_resume_with_guidance () =
  let verdict =
    Contract.of_yojson
      (`Assoc
        [ "decision", `String "resume_with_guidance"
        ; "guidance", `String "Inspect the typed failure and choose different work."
        ; "rationale", `String "The lane can act without external mutation."
        ])
    |> require_ok
  in
  match verdict with
  | Contract.Resume_with_guidance { guidance; rationale } ->
    check
      string
      "guidance preserved"
      "Inspect the typed failure and choose different work."
      guidance;
    check
      string
      "rationale preserved"
      "The lane can act without external mutation."
      rationale
  | Contract.Await_external_input _ -> fail "resume verdict changed variant"
;;

let test_await_external_input () =
  let verdict =
    Contract.of_yojson
      (`Assoc
        [ "decision", `String "await_external_input"
        ; "guidance", `Null
        ; "rationale", `String "Required external input is unavailable."
        ])
    |> require_ok
  in
  match verdict with
  | Contract.Await_external_input { rationale } ->
    check
      string
      "rationale preserved"
      "Required external input is unavailable."
      rationale
  | Contract.Resume_with_guidance _ -> fail "external-input verdict changed variant"
;;

let test_invalid_shapes_fail_closed () =
  expect_error
    "unknown decision"
    (`Assoc
      [ "decision", `String "retry"
      ; "guidance", `Null
      ; "rationale", `String "unsupported"
      ]);
  expect_error
    "extra field"
    (`Assoc
      [ "decision", `String "await_external_input"
      ; "guidance", `Null
      ; "rationale", `String "external input required"
      ; "score", `Float 0.9
      ]);
  expect_error
    "duplicate field"
    (`Assoc
      [ "decision", `String "await_external_input"
      ; "decision", `String "resume_with_guidance"
      ; "guidance", `Null
      ; "rationale", `String "ambiguous"
      ]);
  expect_error
    "resume without guidance"
    (`Assoc
      [ "decision", `String "resume_with_guidance"
      ; "guidance", `Null
      ; "rationale", `String "missing instruction"
      ]);
  expect_error
    "external-input verdict with guidance"
    (`Assoc
      [ "decision", `String "await_external_input"
      ; "guidance", `String "keep going"
      ; "rationale", `String "contradictory payload"
      ]);
  expect_error
    "empty rationale"
    (`Assoc
      [ "decision", `String "await_external_input"
      ; "guidance", `Null
      ; "rationale", `String "  "
      ])
;;

let test_canonical_roundtrip () =
  let original =
    Contract.Resume_with_guidance
      { guidance = "Move to a different actionable task."
      ; rationale = "The Keeper has enough evidence for another action."
      }
  in
  let parsed = Contract.to_yojson original |> Contract.of_yojson |> require_ok in
  check bool "canonical verdict round-trips" true (parsed = original)
;;

let test_typed_judge_error_disposition () =
  let check_disposition label error =
    check
      bool
      label
      true
      (Keeper_failure_judge.error_disposition error
       = Keeper_failure_judge.Escalate_judge_failure)
  in
  check_disposition
    "OAS retryable error terminates at the single judge boundary"
    (Keeper_failure_judge.Oas_error
       { runtime_id = "structured-judge"
       ; error =
           Agent_sdk.Error.Api
             (Llm_provider.Retry.RateLimited
                { retry_after = None; message = "slow down" })
       });
  check_disposition
    "OAS credential error cannot rotate a single judge runtime"
    (Keeper_failure_judge.Oas_error
       { runtime_id = "structured-judge"
       ; error =
           Agent_sdk.Error.Api
             (Llm_provider.Retry.AuthError { message = "401" })
       });
  check_disposition
    "deterministic OAS error escalates"
    (Keeper_failure_judge.Oas_error
       { runtime_id = "structured-judge"
       ; error =
           Agent_sdk.Error.Api
             (Llm_provider.Retry.InvalidRequest
                { message = "bad request"
                ; reason = Llm_provider.Retry.Unknown_invalid_request
                })
       });
  check_disposition
    "response contract error escalates"
    (Keeper_failure_judge.Response_contract_error
       { runtime_id = "structured-judge"; detail = "invalid JSON" })
;;

let failure_event post_id : Keeper_world_observation.pending_board_event =
  { event_kind = Keeper_world_observation.Failure_judgment
  ; post_id
  ; author = "keeper-a"
  ; title = "original failure"
  ; preview = "original detail"
  ; hearth = None
  ; post_kind = Board.System_post
  ; updated_at = 1.0
  ; explicit_mention = false
  ; matched_targets = []
  ; self_commented = false
  ; new_external_since = 1
  ; latest_external_author = None
  ; latest_external_preview = None
  }
;;

let test_guidance_binds_exact_observation () =
  let post_id = "failure-judgment:runtime:contract_violation:oas_agent_error" in
  let guidance = "Inspect the failed contract and choose independent useful work." in
  let events =
    Keeper_world_observation.apply_failure_judgment_guidance
      ~post_id
      ~judge_runtime_id:"structured-judge"
      ~guidance
      ~rationale:"The Keeper has enough evidence for another action."
      [ failure_event post_id ]
    |> require_ok
  in
  let event =
    match events with
    | [ event ] -> event
    | _ -> fail "guidance changed event cardinality"
  in
  let open Yojson.Safe.Util in
  let preview = Yojson.Safe.from_string event.preview in
  check
    string
    "judge runtime remains opaque"
    "structured-judge"
    (preview |> member "judge_runtime_id" |> to_string);
  let verdict =
    preview
    |> member "verdict"
    |> Contract.of_yojson
    |> require_ok
  in
  (match verdict with
   | Contract.Resume_with_guidance { guidance = actual; _ } ->
     check string "full guidance preserved" guidance actual
   | Contract.Await_external_input _ -> fail "guidance changed verdict");
  match
    Keeper_world_observation.apply_failure_judgment_guidance
      ~post_id:"missing"
      ~judge_runtime_id:"structured-judge"
      ~guidance
      ~rationale:"evidence"
      [ failure_event post_id ]
  with
  | Error _ -> ()
  | Ok _ -> fail "missing observation was silently accepted"
;;

let () =
  run
    "keeper_failure_judgment_contract"
    [ ( "decode"
      , [ test_case "resume with guidance" `Quick test_resume_with_guidance
        ; test_case "await external input" `Quick test_await_external_input
        ; test_case "invalid shapes fail closed" `Quick test_invalid_shapes_fail_closed
        ; test_case "canonical roundtrip" `Quick test_canonical_roundtrip
        ; test_case
            "typed judge error disposition"
            `Quick
            test_typed_judge_error_disposition
        ; test_case
            "guidance binds exact observation"
            `Quick
            test_guidance_binds_exact_observation
        ] )
    ; ( "candidate_walk"
      , [ test_case
            "only a response contract failure advances"
            `Quick
            test_only_a_response_contract_failure_advances_the_walk
        ; test_case
            "lane identity yields ordered candidates"
            `Quick
            test_lane_identity_yields_ordered_candidates
        ; test_case
            "single runtime identity yields one candidate"
            `Quick
            test_single_runtime_identity_yields_one_candidate
        ; test_case
            "shipped config gives the judgment boundary a successor"
            `Quick
            test_shipped_config_gives_the_judgment_boundary_a_successor
        ] )
    ]
;;
