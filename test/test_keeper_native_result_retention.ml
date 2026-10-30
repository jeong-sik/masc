module T = Agent_core.Types
module Retention = Masc.Keeper_native_result_retention

let message role content : T.message =
  { origin = T.Conversation; role; content; name=None; tool_call_id=None; metadata=[]}

let result id content =
  T.ToolResult {tool_use_id=id; content; outcome=T.Tool_succeeded;
               json=None; content_blocks=None}

let use id = T.ToolUse {id; name="effect"; input=`Assoc []}
let receipt = result "reused-id" "same payload"
let old_cycle = [message T.Assistant [use "reused-id"]; message T.Tool [receipt]]
let seed = old_cycle @ [T.user_msg "new operation"]
let current_request = message T.Assistant [use "reused-id"]
let current_result = message T.Tool [receipt]

(* The runtime hands its results over as provider blocks; these hold no
   media, so an empty store converts them. *)
let check label expected messages results =
  let media_store = Agent_core.History.Memory_store.create () in
  let results =
    List.map (fun block -> Agent_core.History.to_wire_block media_store block |> Result.get_ok) results
  in
  Alcotest.(check bool) label true (Retention.retains ~seed ~messages ~results = Ok expected)

let test_previous_receipt_does_not_settle_current_call () =
  check "prior identical receipt cannot close current checkpoint gap" false
    (seed @ [current_request]) [receipt];
  check "current occurrence closes this call" true
    (seed @ [current_request; current_result]) [receipt]

let test_one_occurrence_cannot_settle_two_invocations () =
  check "one occurrence for two canonical invocations remains fenced" false
    (seed @ [current_request; current_result; current_request]) [receipt; receipt];
  check "both current occurrences are retained" true
    (seed @ [current_request; current_result; current_request; current_result])
    [receipt; receipt]

let test_changed_seed_or_payload_rejects () =
  check "receipt in an unrelated transcript does not authorize fallback" false
    [current_request; current_result] [receipt];
  check "different result body does not satisfy journal receipt" false
    (seed @ [current_request; message T.Tool [result "reused-id" "different"]]) [receipt]

let test_empty_result_set_preserves_provider_projection () =
  check "provider-only media projection has no settled results to lose" true
    [T.user_msg "existing media fallback projection"] []

(* A result's image as the journal recorded it, and as history holds it. *)
let image_result source =
  Agent_core.Llm_provider.Types.ToolResult
    { tool_use_id = "image-call"; content = ""; outcome = Agent_core.Llm_provider.Types.Tool_succeeded
    ; json = None
    ; content_blocks = Some [ Agent_core.Llm_provider.Types.Image { media_type = "image/png"; source } ] }

let held_image_result =
  T.ToolResult
    { tool_use_id = "image-call"; content = ""; outcome = T.Tool_succeeded; json = None
    ; content_blocks =
        Some
          [ T.Image
              { media_type = "image/png"
              ; source = T.Stored (Agent_core.History.stored_of_raw "\000")
              } ] }

(* "AB==" is not the canonical encoding of the byte 0 ("AA==") but decodes to
   it. The comparison is over the bytes, so either writing settles the call. *)
let test_media_is_compared_by_its_bytes () =
  let messages = seed @ [ current_request; message T.Tool [ held_image_result ] ] in
  List.iter
    (fun encoded ->
       Alcotest.(check bool) ("retained when the journal wrote " ^ encoded) true
         (Retention.retains ~seed ~messages
            ~results:[ image_result (Agent_core.Llm_provider.Types.Base64 encoded) ]
          = Ok true))
    [ "AA=="; "AB==" ]

let test_undecodable_media_is_an_error_not_a_miss () =
  match
    Retention.retains ~seed ~messages:(seed @ [ current_request ])
      ~results:[ image_result (Agent_core.Llm_provider.Types.Base64 "abc") ]
  with
  | Error (Agent_core.History.Invalid_base64 _) -> ()
  | Error _ | Ok _ -> Alcotest.fail "a result whose media does not decode must be a decode error"

let () =
  Alcotest.run "native result retention"
    ["scope and occurrence",
     [Alcotest.test_case "prior identical result" `Quick test_previous_receipt_does_not_settle_current_call;
      Alcotest.test_case "repeated invocation" `Quick test_one_occurrence_cannot_settle_two_invocations;
      Alcotest.test_case "exact transcript and payload" `Quick test_changed_seed_or_payload_rejects;
      Alcotest.test_case "provider-only projection" `Quick test_empty_result_set_preserves_provider_projection];
     "media",
     [Alcotest.test_case "compared by its bytes" `Quick test_media_is_compared_by_its_bytes;
      Alcotest.test_case "undecodable media is an error" `Quick test_undecodable_media_is_an_error_not_a_miss]]
