module U = Masc.Keeper_compaction_unit
module T = Agent_core.Types

let message ?tool_call_id role content : T.message =
  { role; content; name = None; tool_call_id; metadata = [] }

let text role value = message role [ T.Text value ]

let use id =
  T.ToolUse { id; name = "test_tool"; input = `Assoc [ "id", `String id ] }

let result ?content_blocks id =
  T.ToolResult
    { tool_use_id = id
    ; content = "result:" ^ id
    ; outcome = T.Tool_succeeded
    ; json = Some (`Assoc [ "id", `String id ])
    ; content_blocks
    }

let check_exact label expected actual =
  Alcotest.(check bool) label true (expected = actual)

let require_ok = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "expected structural partition"

let test_signed_parallel_cycle_is_atomic () =
  let assistant =
    message T.Assistant
      [ T.Thinking { content = "private bytes"; signature = Some "signed-bytes" }
      ; use "call-a"
      ; T.RedactedThinking "opaque"
      ; use "call-b"
      ]
  in
  let nested_payload =
    [ T.ToolUse { id = "payload-only"; name = "not-an-anchor"; input = `Null }
    ; result "payload-only"
    ]
  in
  let result_b = message T.User [ result ~content_blocks:nested_payload "call-b" ] in
  let result_a = message T.Tool [ result "call-a" ] in
  let cycle = [ assistant; result_b; result_a ] in
  let output = U.partition cycle |> require_ok in
  Alcotest.(check int) "one atomic unit" 1 (List.length output.closed_prefix);
  check_exact "closed cycle exact"
    [ U.Closed_tool_cycle cycle ]
    output.closed_prefix;
  check_exact "no protected suffix" [] output.protected_suffix;
  match assistant.content with
  | T.Thinking { signature; content } :: _ ->
      Alcotest.(check (option string)) "signature exact" (Some "signed-bytes")
        signature;
      Alcotest.(check string) "thinking exact" "private bytes" content
  | _ -> Alcotest.fail "expected signed thinking"

let test_open_after_assistant_is_protected () =
  let prefix = text T.User "before" in
  let assistant = message T.Assistant [ use "open" ] in
  let output = U.partition [ prefix; assistant ] |> require_ok in
  check_exact "ordinary prefix"
    [ U.Ordinary_message prefix ]
    output.closed_prefix;
  check_exact "assistant suffix exact" [ assistant ] output.protected_suffix

let test_open_interstitial_suffix_is_exact () =
  let assistant = message T.Assistant [ use "open" ] in
  let middle_user = text T.User "still waiting" in
  let middle_assistant = text T.Assistant "progress prose" in
  let suffix = [ assistant; middle_user; middle_assistant ] in
  let output = U.partition suffix |> require_ok in
  check_exact "no closed unit" [] output.closed_prefix;
  check_exact "interstitial suffix exact" suffix output.protected_suffix

let test_closed_interstitial_cycle_is_atomic () =
  let assistant = message T.Assistant [ use "call" ] in
  let progress = text T.Assistant "tool progress" in
  let completed = message T.User [ result "call" ] in
  let cycle = [ assistant; progress; completed ] in
  let output = U.partition cycle |> require_ok in
  check_exact "closed interstitial cycle"
    [ U.Closed_tool_cycle cycle ]
    output.closed_prefix;
  check_exact "no protected suffix" [] output.protected_suffix

let test_tool_id_can_repeat_after_closed_cycle () =
  let cycle =
    [ message T.Assistant [ use "provider-id" ]
    ; message T.User [ result "provider-id" ] ] in
  let output = U.partition (cycle @ cycle) |> require_ok in
  check_exact "cycles remain distinct"
    [ U.Closed_tool_cycle cycle; U.Closed_tool_cycle cycle ]
    output.closed_prefix

let test_ordinary_prefix_order () =
  let messages =
    [ text T.System "system"; text T.User "one"; text T.Assistant "two" ]
  in
  let output = U.partition messages |> require_ok in
  check_exact "ordinary order"
    (List.map (fun msg -> U.Ordinary_message msg) messages)
    output.closed_prefix;
  check_exact "empty suffix" [] output.protected_suffix

let test_orphan_result_error () =
  match U.partition [ message T.User [ result "orphan" ] ] with
  | Error (U.Orphan_tool_result { message_index = 0; tool_use_id = "orphan" }) ->
      ()
  | _ -> Alcotest.fail "expected typed orphan ToolResult"

let test_duplicate_result_error () =
  let assistant = message T.Assistant [ use "a"; use "b" ] in
  let first = message T.User [ result "a" ] in
  let duplicate = message T.User [ result "a" ] in
  match U.partition [ assistant; first; duplicate ] with
  | Error (U.Duplicate_tool_result { message_index = 2; tool_use_id = "a" }) ->
      ()
  | _ -> Alcotest.fail "expected typed duplicate ToolResult"

let test_unknown_result_error () =
  let assistant = message T.Assistant [ use "known" ] in
  let unknown = message T.User [ result "unknown" ] in
  match U.partition [ assistant; unknown ] with
  | Error (U.Unknown_tool_result { message_index = 1; tool_use_id = "unknown" }) ->
      ()
  | _ -> Alcotest.fail "expected typed unknown ToolResult"

let test_open_result_role_error () =
  let assistant = message T.Assistant [ use "call" ] in
  let invalid = message T.Assistant [ result "call" ] in
  match U.partition [ assistant; invalid ] with
  | Error (U.Non_result_tool_role { message_index = 1; tool_use_id = "call" }) ->
      ()
  | _ -> Alcotest.fail "expected typed ToolResult role error"

let test_non_assistant_tool_use_error () =
  match U.partition [ message T.User [ use "invalid" ] ] with
  | Error
      (U.Non_assistant_tool_use { message_index = 0; tool_use_id = "invalid" }) ->
      ()
  | _ -> Alcotest.fail "expected typed non-assistant ToolUse"

let test_duplicate_tool_use_error () =
  match U.partition [ message T.Assistant [ use "same"; use "same" ] ] with
  | Error (U.Duplicate_tool_use_id { message_index = 0; tool_use_id = "same" }) ->
      ()
  | _ -> Alcotest.fail "expected typed duplicate ToolUse"

let test_mixed_request_result_error () =
  match U.partition [ message T.Assistant [ use "same"; result "same" ] ] with
  | Error
      (U.Tool_request_contains_result
        { message_index = 0; tool_use_id = "same" }) ->
      ()
  | _ -> Alcotest.fail "expected typed mixed request/result"

let test_empty_tool_use_id_error () =
  List.iter
    (fun tool_use_id ->
       match U.partition [ message T.Assistant [ use tool_use_id ] ] with
       | Error
           (U.Empty_tool_use_id
             { message_index = 0; block_index = 0; tool_use_id = actual }) ->
         Alcotest.(check string) "raw empty ToolUse id" tool_use_id actual
       | _ -> Alcotest.fail "expected typed empty ToolUse id")
    [ ""; " \t\n" ]
;;

let test_empty_tool_result_id_error () =
  List.iter
    (fun tool_use_id ->
       let request = message T.Assistant [ use "expected" ] in
       let response = message T.Tool [ result tool_use_id ] in
       match U.partition [ request; response ] with
       | Error
           (U.Empty_tool_result_id
             { message_index = 1; block_index = 0; tool_use_id = actual }) ->
         Alcotest.(check string) "raw empty ToolResult id" tool_use_id actual
       | _ -> Alcotest.fail "expected typed empty ToolResult id")
    [ ""; " \t\n" ]
;;

let test_parallel_empty_tool_use_id_error () =
  let request =
    message T.Assistant
      [ use "call-a"; T.Text "between"; use " \t"; use "call-b" ]
  in
  match U.partition [ request ] with
  | Error
      (U.Empty_tool_use_id
        { message_index = 0; block_index = 2; tool_use_id = " \t" }) ->
    ()
  | _ -> Alcotest.fail "expected typed empty parallel ToolUse id"
;;

let test_parallel_empty_tool_result_id_error () =
  let request = message T.Assistant [ use "call-a"; use "call-b" ] in
  let response =
    message T.Tool [ result "call-a"; T.Text "between"; result "\n " ]
  in
  match U.partition [ request; response ] with
  | Error
      (U.Empty_tool_result_id
        { message_index = 1; block_index = 2; tool_use_id = "\n " }) ->
    ()
  | _ -> Alcotest.fail "expected typed empty parallel ToolResult id"
;;

let test_message_content_tool_id_mismatch_error () =
  let request = message T.Assistant [ use "content-id" ] in
  let response =
    message ~tool_call_id:"message-id" T.Tool [ result "content-id" ]
  in
  match U.partition [ request; response ] with
  | Error
      (U.Message_tool_call_id_mismatch
        { message_index = 1
        ; message_tool_call_id = "message-id"
        ; content_tool_use_ids = [ "content-id" ]
        }) ->
    ()
  | _ -> Alcotest.fail "expected typed message/content ToolResult id mismatch"
;;

let test_message_tool_id_without_result_error () =
  let message = message ~tool_call_id:"stray-id" T.Tool [ T.Text "no result" ] in
  match U.partition [ message ] with
  | Error
      (U.Message_tool_call_id_mismatch
        { message_index = 0
        ; message_tool_call_id = "stray-id"
        ; content_tool_use_ids = []
        }) ->
    ()
  | _ -> Alcotest.fail "expected typed message ToolResult id mismatch"
;;

let test_nonblank_tool_ids_remain_exact () =
  let exact_id = "  exact-id  " in
  let request = message T.Assistant [ use exact_id ] in
  let response =
    message ~tool_call_id:exact_id T.Tool [ result exact_id ]
  in
  let cycle = [ request; response ] in
  let output = U.partition cycle |> require_ok in
  check_exact
    "nonblank id is not normalized"
    [ U.Closed_tool_cycle cycle ]
    output.closed_prefix;
  match
    U.partition
      [ request; message ~tool_call_id:"exact-id" T.Tool [ result "exact-id" ] ]
  with
  | Error (U.Unknown_tool_result { message_index = 1; tool_use_id = "exact-id" }) ->
    ()
  | _ -> Alcotest.fail "trimmed ToolResult id must not match the raw ToolUse id"
;;

let test_invalid_identity_prevents_plan_callback () =
  let plan_calls = ref 0 in
  let outcome =
    U.partition [ message T.Assistant [ use " \t" ] ]
    |> Result.map (fun (partition : U.partition) ->
      incr plan_calls;
      partition.closed_prefix)
  in
  (match outcome with
   | Error (U.Empty_tool_use_id _) -> ()
   | _ -> Alcotest.fail "expected invalid identity before plan callback");
  Alcotest.(check int) "plan callback count" 0 !plan_calls
;;

let test_quarantine_overlapping_keeps_valid_prefix () =
  let prefix = text T.User "valid prefix" in
  let open_a = message T.Assistant [ use "a" ] in
  let overlapping = message T.Assistant [ use "b" ] in
  let history = [ prefix; open_a; overlapping ] in
  (match U.partition history with
   | Error (U.Overlapping_tool_cycle { message_index = 2; tool_use_id = "b" }) ->
       ()
   | _ -> Alcotest.fail "default partition must reject overlapping tool cycle");
  let output = U.partition ~quarantine:true history |> require_ok in
  check_exact "valid prefix compacted under quarantine"
    [ U.Ordinary_message prefix ]
    output.closed_prefix;
  check_exact "open + overlapping protected under quarantine"
    [ open_a; overlapping ]
    output.protected_suffix
;;

let test_quarantine_orphan_keeps_valid_prefix () =
  let prefix = text T.User "valid prefix" in
  let orphan = message T.Tool [ result "x" ] in
  let history = [ prefix; orphan ] in
  (match U.partition history with
   | Error (U.Orphan_tool_result _) ->
       ()
   | _ -> Alcotest.fail "default partition must reject orphan tool result");
  let output = U.partition ~quarantine:true history |> require_ok in
  check_exact "valid prefix compacted under quarantine"
    [ U.Ordinary_message prefix ]
    output.closed_prefix;
  check_exact "orphan protected under quarantine" [ orphan ] output.protected_suffix
;;

(* RFC-0240 §2.4 / §5.4. A tool cycle left open by process death is the state
   checkpoint persistence stores on purpose; before [close_open_tail] nothing
   closed it, so provider admission rejected the history on every reload and the
   lane latched permanently (2026-07-27: four keepers). *)

let require_closure = function
  | Ok closure -> closure
  | Error _ -> Alcotest.fail "expected the open tail to close"

let appended_results closure ~before =
  let rec drop n = function
    | rest when n <= 0 -> rest
    | _ :: rest -> drop (n - 1) rest
    | [] -> []
  in
  drop (List.length before) closure.U.messages

(* [T.ToolResult]'s payload is an inline record, so it cannot escape the
   constructor; copy the fields into a view the assertions can hold. *)
type closer_view =
  { closer_tool_use_id : string
  ; closer_content : string
  ; closer_outcome : T.tool_result_outcome
  ; closer_json : Yojson.Safe.t option
  ; closer_content_blocks : T.content_block list option
  }

let interrupted_block = function
  | ({ role = T.Tool
     ; content = [ T.ToolResult { tool_use_id; content; outcome; json; content_blocks } ]
     ; tool_call_id = None
     ; _
     } : T.message) ->
    { closer_tool_use_id = tool_use_id
    ; closer_content = content
    ; closer_outcome = outcome
    ; closer_json = json
    ; closer_content_blocks = content_blocks
    }
  | _ -> Alcotest.fail "closer is not a single-result Tool message"

let test_close_open_tail_makes_transcript_dispatchable () =
  let before =
    [ message T.Assistant [ use "call-a"; use "call-b" ] ]
  in
  let closure = require_closure (U.close_open_tail before) in
  check_exact
    "both open ids are closed"
    [ "call-a"; "call-b" ]
    closure.U.closed_tool_use_ids;
  check_exact
    "one closer appended per open id"
    2
    (List.length (appended_results closure ~before));
  check_exact "prefix is preserved byte-exact" before
    (List.filteri (fun i _ -> i < List.length before) closure.U.messages);
  match U.validate_provider_transcript closure.U.messages with
  | Ok () -> ()
  | Error error ->
    Alcotest.failf
      "closed tail still rejected by provider admission: %s"
      (U.show_provider_transcript_error error)

let test_close_open_tail_closes_only_missing_ids () =
  (* One result already landed before the crash; only the other is synthesized. *)
  let before =
    [ message T.Assistant [ use "call-a"; use "call-b" ]
    ; message T.Tool [ result "call-b" ]
    ]
  in
  let closure = require_closure (U.close_open_tail before) in
  check_exact "only the unresolved id closes" [ "call-a" ] closure.U.closed_tool_use_ids;
  let appended = appended_results closure ~before in
  check_exact "exactly one closer" 1 (List.length appended);
  let r = interrupted_block (List.hd appended) in
  check_exact "closer targets the unresolved id" "call-a" r.closer_tool_use_id;
  match U.validate_provider_transcript closure.U.messages with
  | Ok () -> ()
  | Error error ->
    Alcotest.failf
      "partially recovered cycle still rejected: %s"
      (U.show_provider_transcript_error error)

let test_close_open_tail_is_identity_when_already_closed () =
  let closed =
    [ message T.Assistant [ use "call-a"; use "call-b" ]
    ; message T.Tool [ result "call-b"; result "call-a" ]
    ; text T.User "already dispatchable"
    ]
  in
  let closure = require_closure (U.close_open_tail closed) in
  check_exact "nothing was closed" [] closure.U.closed_tool_use_ids;
  check_exact "history is returned unchanged" closed closure.U.messages

let test_close_open_tail_preserves_structural_error () =
  (* A ToolResult with no preceding ToolUse does not parse. That is genuine
     corruption, not an interrupted call, and must keep latching. *)
  let unparseable = [ message T.Tool [ result "call-ghost" ] ] in
  match U.close_open_tail unparseable with
  | Ok _ -> Alcotest.fail "unparseable history must not be closed"
  | Error (U.Orphan_tool_result { tool_use_id = "call-ghost"; _ }) -> ()
  | Error error ->
    Alcotest.failf "wrong structural error: %s" (U.show_structural_error error)

let test_close_open_tail_never_fabricates_success () =
  let before = [ message T.Assistant [ use "call-a" ] ] in
  let closure = require_closure (U.close_open_tail before) in
  let r = interrupted_block (List.hd (appended_results closure ~before)) in
  check_exact "content is the SSOT interrupted body"
    U.interrupted_tool_result_content r.closer_content;
  check_exact "no structured payload is invented" None r.closer_json;
  check_exact "no content blocks are invented" None r.closer_content_blocks;
  (* The execution boundary died without recording provenance, so the outcome
     must say exactly that — not Tool_succeeded, and not a provider-reported
     failure the provider never reported. *)
  match r.closer_outcome with
  | T.Tool_failed { failure_kind = T.Unattributed_tool_error; error_class = Some T.Unknown }
    -> ()
  | outcome ->
    Alcotest.failf
      "interrupted call must be unattributed-unknown, got: %s"
      (T.show_tool_result_outcome outcome)

let test_provider_admission_requires_closed_tool_cycle () =
  let closed =
    [ message T.Assistant [ use "call-a"; use "call-b" ]
    ; message T.Tool [ result "call-b"; result "call-a" ]
    ]
  in
  (match U.validate_provider_transcript closed with
   | Ok () -> ()
   | Error error ->
     Alcotest.failf
       "closed provider transcript rejected: %s"
       (U.show_provider_transcript_error error));
  let open_messages =
    [ message T.Assistant [ use "call-a"; use "call-b" ]
    ; message T.Tool [ result "call-b" ]
    ; text T.User "next turn must not dispatch"
    ]
  in
  match U.validate_provider_transcript open_messages with
  | Error (U.Unresolved_tool_results { tool_use_ids = [ "call-a" ] }) -> ()
  | Error error ->
    Alcotest.failf
      "wrong provider transcript rejection: %s"
      (U.show_provider_transcript_error error)
  | Ok () -> Alcotest.fail "open ToolUse suffix reached provider admission"
;;

let test_provider_admission_quarantines_malformed_overlap () =
  let poisoned =
    [ message T.Assistant [ use "missing" ]
    ; text T.User "interstitial"
    ; message T.Assistant [ use "next" ]
    ]
  in
  let provider_dispatches = ref 0 in
  let dispatch _admitted =
    incr provider_dispatches;
    Ok ()
  in
  (match U.validate_provider_transcript poisoned with
   | Error
       (U.Invalid_transcript_structure
         (U.Overlapping_tool_cycle
           { message_index = 2; tool_use_id = "next" })) ->
     ()
   | Error error ->
     Alcotest.failf
       "wrong malformed transcript rejection: %s"
       (U.show_provider_transcript_error error)
   | Ok () -> Alcotest.fail "malformed overlap reached provider admission");
  match Masc.Keeper_agent_run.For_testing.dispatch_after_provider_transcript_admission
          ~messages:poisoned
          ~dispatch
  with
  | Error error ->
    Alcotest.(check int) "poisoned provider dispatch count" 0 !provider_dispatches;
    (match Keeper_internal_error.classify_masc_internal_error error with
     | Some
         (Keeper_internal_error.Incomplete_tool_transcript
           { reason = Keeper_internal_error.Structurally_invalid
           ; tool_use_ids = []
           ; _
           }) ->
       Alcotest.(check string)
         "operator receipt terminal code"
         "incomplete_tool_transcript"
         (Masc.Keeper_agent_error.terminal_reason_code_of_core_error error)
     | Some _ | None -> Alcotest.fail "missing typed transcript quarantine")
  | Ok () -> Alcotest.fail "poisoned transcript passed keeper admission"
;;



(* A provider timeout between the two checkpoint stages leaves the transcript
   ending on a ToolUse with no result. That is the ordinary shape of an
   interrupted turn, not corruption, so admission closes it and the turn runs;
   before this, the lane failed every turn until a restart (33 consecutive
   turns on one lane, 2026-08-25). *)
let test_interrupted_tool_cycle_is_closed_and_dispatched () =
  let interrupted =
    [ text T.User "do the thing"
    ; message T.Assistant [ use "call-in-flight" ]
    ]
  in
  (match U.validate_provider_transcript interrupted with
   | Error (U.Unresolved_tool_results { tool_use_ids = [ "call-in-flight" ] }) -> ()
   | Error error ->
     Alcotest.failf
       "expected an unresolved tool result: %s"
       (U.show_provider_transcript_error error)
   | Ok () -> Alcotest.fail "an open cycle must not validate as-is");
  let dispatched = ref None in
  let dispatch admitted =
    dispatched := Some admitted;
    Ok ()
  in
  match
    Masc.Keeper_agent_run.For_testing.dispatch_after_provider_transcript_admission
      ~messages:interrupted
      ~dispatch
  with
  | Error error ->
    Alcotest.failf
      "an interrupted cycle must not latch the lane: %s"
      (Agent_core.Error.to_string error)
  | Ok () ->
    (match !dispatched with
     | None -> Alcotest.fail "dispatch never ran"
     | Some admitted ->
       Alcotest.(check bool)
         "the admitted history validates"
         true
         (U.validate_provider_transcript admitted = Ok ());
       Alcotest.(check int)
         "one synthesized result was appended"
         (List.length interrupted + 1)
         (List.length admitted))
;;


let () =
  Alcotest.run "keeper_compaction_unit"
    [ ( "partition"
      , [ Alcotest.test_case "signed parallel cycle exact" `Quick
            test_signed_parallel_cycle_is_atomic
        ; Alcotest.test_case "open after assistant" `Quick
            test_open_after_assistant_is_protected
        ; Alcotest.test_case "open interstitial suffix" `Quick
            test_open_interstitial_suffix_is_exact
        ; Alcotest.test_case "closed interstitial cycle" `Quick
            test_closed_interstitial_cycle_is_atomic
        ; Alcotest.test_case "tool id reuse after closed cycle" `Quick
            test_tool_id_can_repeat_after_closed_cycle
        ; Alcotest.test_case "ordinary prefix order" `Quick
            test_ordinary_prefix_order
        ; Alcotest.test_case "orphan result" `Quick test_orphan_result_error
        ; Alcotest.test_case "duplicate result" `Quick
            test_duplicate_result_error
        ; Alcotest.test_case "unknown result" `Quick test_unknown_result_error
        ; Alcotest.test_case "invalid result role" `Quick
            test_open_result_role_error
        ; Alcotest.test_case "non-assistant use" `Quick
            test_non_assistant_tool_use_error
        ; Alcotest.test_case "duplicate use" `Quick test_duplicate_tool_use_error
        ; Alcotest.test_case "mixed request/result" `Quick
            test_mixed_request_result_error
        ; Alcotest.test_case "empty ToolUse id" `Quick
            test_empty_tool_use_id_error
        ; Alcotest.test_case "empty ToolResult id" `Quick
            test_empty_tool_result_id_error
        ; Alcotest.test_case "parallel empty ToolUse id" `Quick
            test_parallel_empty_tool_use_id_error
        ; Alcotest.test_case "parallel empty ToolResult id" `Quick
            test_parallel_empty_tool_result_id_error
        ; Alcotest.test_case "message/content id mismatch" `Quick
            test_message_content_tool_id_mismatch_error
        ; Alcotest.test_case "message id without result" `Quick
            test_message_tool_id_without_result_error
        ; Alcotest.test_case "nonblank ids remain exact" `Quick
            test_nonblank_tool_ids_remain_exact
        ; Alcotest.test_case "invalid identity stops plan callback" `Quick
            test_invalid_identity_prevents_plan_callback
        ; Alcotest.test_case "quarantine overlapping keeps valid prefix" `Quick
            test_quarantine_overlapping_keeps_valid_prefix
        ; Alcotest.test_case "quarantine orphan keeps valid prefix" `Quick
            test_quarantine_orphan_keeps_valid_prefix
        ; Alcotest.test_case "provider admission requires closed cycle" `Quick
            test_provider_admission_requires_closed_tool_cycle
        ; Alcotest.test_case "provider admission quarantines overlap" `Quick
            test_provider_admission_quarantines_malformed_overlap
        ; Alcotest.test_case "close_open_tail makes an interrupted turn dispatchable"
            `Quick test_close_open_tail_makes_transcript_dispatchable
        ; Alcotest.test_case "close_open_tail closes only the missing ids" `Quick
            test_close_open_tail_closes_only_missing_ids
        ; Alcotest.test_case "close_open_tail is identity on a closed history" `Quick
            test_close_open_tail_is_identity_when_already_closed
        ; Alcotest.test_case "close_open_tail keeps unparseable history latched" `Quick
            test_close_open_tail_preserves_structural_error
        ; Alcotest.test_case "close_open_tail never fabricates success" `Quick
            test_close_open_tail_never_fabricates_success
        ; Alcotest.test_case "interrupted tool cycle is closed and dispatched" `Quick
            test_interrupted_tool_cycle_is_closed_and_dispatched
        ] )
    ]
