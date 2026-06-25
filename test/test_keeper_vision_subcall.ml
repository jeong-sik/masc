(** Phase 1 unit tests for {!Masc.Keeper_vision_subcall} — the bounded vision
    sub-call. No network: the [complete] seam is injected. Each test has a
    concrete revert that turns it red (noted inline). *)

module V = Masc.Keeper_vision_subcall
module VA = Multimodal.Vision_analyze

let mk_response ~content ~stop_reason : Agent_sdk.Types.api_response =
  { id = "test"
  ; model = "vision-test"
  ; stop_reason
  ; content = (if String.equal content "" then [] else [ Agent_sdk.Types.Text content ])
  ; usage = None
  ; telemetry = None
  }
;;

let req () =
  match
    VA.make_request
      ~query:"what is in this image?"
      ~image_media_type:"image/png"
      ~image_bytes:"\x89PNG\r\n\x1a\nbytes"
  with
  | Ok r -> r
  | Error e -> failwith ("make_request: " ^ e)
;;

let provider_config () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Anthropic
    ~model_id:"vision-test"
    ~base_url:"http://127.0.0.1:9/v1"
    ()
;;

let complete_ok response : V.complete_fn =
  fun ~sw:_ ~net:_ ?clock:_ ?body_timeout_s:_ ~config:_ ~messages:_ () -> Ok response
;;

let complete_err err : V.complete_fn =
  fun ~sw:_ ~net:_ ?clock:_ ?body_timeout_s:_ ~config:_ ~messages:_ () -> Error err
;;

(* Sleeps far past the timeout, then would return — the outer with_timeout_exn
   must fire first. *)
let complete_slow : V.complete_fn =
  fun ~sw:_ ~net:_ ?clock ?body_timeout_s:_ ~config:_ ~messages:_ () ->
  (match clock with Some c -> Eio.Time.sleep c 100.0 | None -> ());
  Ok (mk_response ~content:"late" ~stop_reason:Agent_sdk.Types.EndTurn)
;;

let run_with ~clock ~net ~timeout_sec complete =
  Eio.Switch.run (fun sw ->
    V.run ~complete ~sw ~net ~clock ~provider_config:(provider_config ()) ~timeout_sec (req ()))
;;

let err_str = function
  | Ok s -> "Ok " ^ s
  | Error e -> "Error " ^ V.string_of_error e
;;

(* P0: a stalled vision runtime must NOT stall the turn — revert-red if [run]
   calls [complete] without [Eio.Time.with_timeout_exn]. *)
let test_timeout_bounded ~clock ~net () =
  match run_with ~clock ~net ~timeout_sec:0.05 complete_slow with
  | Error (V.Timed_out _) -> ()
  | r -> Alcotest.failf "expected Timed_out, got %s" (err_str r)
;;

(* Empty reply on a normal stop -> Empty_extraction, never Ok "". Revert-red if
   [run] returns the raw text instead of routing through Vision_analyze.classify. *)
let test_empty_endturn ~clock ~net () =
  match
    run_with ~clock ~net ~timeout_sec:5.0
      (complete_ok (mk_response ~content:"" ~stop_reason:Agent_sdk.Types.EndTurn))
  with
  | Error (V.Extraction VA.Empty_extraction) -> ()
  | r -> Alcotest.failf "expected Empty_extraction, got %s" (err_str r)
;;

(* Empty reply with MaxTokens -> Truncated_extraction (the gemma4 case). Revert-red
   if stop_reason is hardcoded to Stop instead of read as the typed SDK variant. *)
let test_empty_maxtokens ~clock ~net () =
  match
    run_with ~clock ~net ~timeout_sec:5.0
      (complete_ok (mk_response ~content:"" ~stop_reason:Agent_sdk.Types.MaxTokens))
  with
  | Error (V.Extraction VA.Truncated_extraction) -> ()
  | r -> Alcotest.failf "expected Truncated_extraction, got %s" (err_str r)
;;

let test_unknown_maxtokens_string_is_not_truncated ~clock ~net () =
  match
    run_with ~clock ~net ~timeout_sec:5.0
      (complete_ok
         (mk_response ~content:"" ~stop_reason:(Agent_sdk.Types.Unknown "max_tokens")))
  with
  | Error (V.Extraction VA.Empty_extraction) -> ()
  | r -> Alcotest.failf "expected Empty_extraction, got %s" (err_str r)
;;

let test_http_error ~clock ~net () =
  match
    run_with ~clock ~net ~timeout_sec:5.0
      (complete_err (Llm_provider.Http_client.HttpError { code = 503; body = "busy" }))
  with
  | Error (V.Subcall_failed _) -> ()
  | r -> Alcotest.failf "expected Subcall_failed, got %s" (err_str r)
;;

let test_ok ~clock ~net () =
  match
    run_with ~clock ~net ~timeout_sec:5.0
      (complete_ok (mk_response ~content:"a tabby cat" ~stop_reason:Agent_sdk.Types.EndTurn))
  with
  | Ok "a tabby cat" -> ()
  | r -> Alcotest.failf "expected Ok \"a tabby cat\", got %s" (err_str r)
;;

let make_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String "vision-subcall-test"
         ; "agent_name", `String "vision-subcall-test"
         ; "trace_id", `String "vision-subcall-test-trace"
         ])
  with
  | Ok meta -> meta
  | Error e -> failwith ("make_meta: " ^ e)
;;

let test_missing_context_is_workflow_rejection () =
  let config = Masc.Workspace.default_config "/tmp/masc-vision-subcall-test" in
  let payload =
    Masc.Keeper_tool_in_process_runtime.handle_analyze_image
      ~config
      ~meta:(make_meta ())
      ~args:(`Assoc [ "artifact", `String ""; "query", `String "what is this?" ])
      ()
  in
  let cls = Masc.Keeper_tool_dispatch_runtime.failure_class_of_tool_result_payload payload in
  match cls with
  | Some Tool_result.Workflow_rejection ->
    if
      Masc.Keeper_tool_dispatch_runtime.should_apply_circuit_breaker_to_failure_payload cls
    then Alcotest.fail "workflow rejection must not apply the circuit breaker"
  | Some other ->
    Alcotest.failf
      "expected workflow_rejection, got %s"
      (Tool_result.tool_failure_class_to_string other)
  | None -> Alcotest.fail "expected failure_class"
;;

let () =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let net = Eio.Stdenv.net env in
    Alcotest.run
      "keeper_vision_subcall"
      [ ( "run"
        , [ Alcotest.test_case "bounded timeout (P0)" `Quick (test_timeout_bounded ~clock ~net)
          ; Alcotest.test_case "empty+endturn -> Empty_extraction" `Quick
              (test_empty_endturn ~clock ~net)
          ; Alcotest.test_case "empty+maxtokens -> Truncated_extraction" `Quick
              (test_empty_maxtokens ~clock ~net)
          ; Alcotest.test_case
              "unknown max_tokens string is not parsed as MaxTokens"
              `Quick
              (test_unknown_maxtokens_string_is_not_truncated ~clock ~net)
          ; Alcotest.test_case "http error -> Subcall_failed" `Quick
              (test_http_error ~clock ~net)
          ; Alcotest.test_case "ok -> Ok text" `Quick (test_ok ~clock ~net)
          ; Alcotest.test_case
              "missing Eio context is workflow rejection"
              `Quick
              test_missing_context_is_workflow_rejection
          ] )
      ])
;;
