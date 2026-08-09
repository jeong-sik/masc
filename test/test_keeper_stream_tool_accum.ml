(* Unit tests for the turn-local tool-call accumulator. The persist site reads
   this to fill [append_turn_result ~tool_calls]; before it existed the argument
   was never passed, so history rows carried no tool rows and a reload lost the
   tool timeline the live stream had shown. *)

open Alcotest

module A = Keeper_stream_tool_accum

let tool_call = testable
  (fun fmt (c : Masc.Keeper_chat_store.tool_call) ->
     Format.fprintf fmt "{id=%s; name=%s; args=%s}" c.call_id c.call_name c.args)
  (fun (a : Masc.Keeper_chat_store.tool_call) b ->
     String.equal a.call_id b.call_id
     && String.equal a.call_name b.call_name
     && String.equal a.args b.args)

let start ~index ~tool_id ~tool_name =
  Agent_core.Types.ContentBlockStart
    { index; content_type = "tool_use"; tool_id; tool_name }

let json_delta ~index fragment =
  Agent_core.Types.ContentBlockDelta
    { index; delta = Agent_core.Types.InputJsonDelta fragment }

let json_snapshot ~index snapshot =
  Agent_core.Types.ContentBlockDelta
    { index; delta = Agent_core.Types.InputJsonSnapshot snapshot }

let stop ~index = Agent_core.Types.ContentBlockStop { index }

(* Unlike [start], this does not hardcode content_type = "tool_use" — it
   represents a genuinely non-tool content block (e.g. text/thinking), which
   carries no tool identity because it is not a tool block at all. *)
let non_tool_start ~index ~content_type =
  Agent_core.Types.ContentBlockStart
    { index; content_type; tool_id = None; tool_name = None }

let media_delta ~index data =
  Agent_core.Types.ContentBlockDelta
    { index
    ; delta =
        Agent_core.Types.MediaDelta
          { media_type = "image/png"; source_type = Agent_core.Types.Base64; data }
    }

let test_fragments_concatenate_in_order () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-1") ~tool_name:(Some "WebSearch"));
  A.on_event t (json_delta ~index:0 "{\"query\":");
  A.on_event t (json_delta ~index:0 "\"masc\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "one call with joined args"
    [ { call_id = "call-1"; call_name = "WebSearch"; args = "{\"query\":\"masc\"}" } ]
    (A.to_tool_calls t)

(* The provider sends a snapshot as the whole argument object, so appending it
   to the fragments already seen would duplicate them. *)
let test_snapshot_replaces_fragments () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-2") ~tool_name:(Some "WebFetch"));
  A.on_event t (json_delta ~index:0 "{\"url\":\"partial");
  A.on_event t (json_snapshot ~index:0 "{\"url\":\"https://example.com\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "snapshot wins"
    [ { call_id = "call-2"; call_name = "WebFetch"; args = "{\"url\":\"https://example.com\"}" } ]
    (A.to_tool_calls t)

let test_parallel_blocks_keep_provider_order () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-a") ~tool_name:(Some "WebSearch"));
  A.on_event t (start ~index:1 ~tool_id:(Some "call-b") ~tool_name:(Some "WebFetch"));
  A.on_event t (json_delta ~index:1 "{\"b\":1}");
  A.on_event t (json_delta ~index:0 "{\"a\":1}");
  (* Finalize out of order: the result still reads in the order the provider
     opened the blocks, which is the order the transcript renders. *)
  A.on_event t (stop ~index:1);
  A.on_event t (stop ~index:0);
  check (list string) "provider order"
    [ "call-a"; "call-b" ]
    (List.map (fun (c : Masc.Keeper_chat_store.tool_call) -> c.call_id) (A.to_tool_calls t))

let test_replayed_start_keeps_received_fragments () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-replayed") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":");
  A.on_event t (start ~index:0 ~tool_id:(Some "call-replayed") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "\"a.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "identical start does not reset fragments"
    [ { call_id = "call-replayed"; call_name = "Read"; args = "{\"path\":\"a.ml\"}" } ]
    (A.to_tool_calls t)

let test_replayed_completed_block_is_not_persisted_twice () =
  let t = A.create () in
  A.on_event t (start ~index:1 ~tool_id:(Some "call-complete") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:1 "{\"path\":\"a.ml\"}");
  A.on_event t (stop ~index:1);
  (* A reconnect can replay the fully finalized block. Its provider call id is
     already durable, so it must not open a second transcript tool row. *)
  A.on_event t (start ~index:0 ~tool_id:(Some "call-complete") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t (start ~index:0 ~tool_id:(Some "call-conflict") ~tool_name:(Some "Write"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"wrong.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "completed replay remains one call"
    [ { call_id = "call-complete"; call_name = "Read"; args = "{\"path\":\"a.ml\"}" } ]
    (A.to_tool_calls t)

let test_parallel_blocks_with_same_call_id_drop_the_later_block () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-duplicate") ~tool_name:(Some "Read"));
  A.on_event t (start ~index:1 ~tool_id:(Some "call-duplicate") ~tool_name:(Some "Write"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t (json_delta ~index:1 "{\"path\":\"b.ml\"}");
  A.on_event t (stop ~index:1);
  A.on_event t (stop ~index:0);
  check (list tool_call) "later active duplicate is omitted"
    [ { call_id = "call-duplicate"; call_name = "Read"; args = "{\"path\":\"a.ml\"}" } ]
    (A.to_tool_calls t)

let test_tool_call_id_is_preserved_before_persistence () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some " call-trimmed ")
       ~tool_name:(Some " Read "));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "persisted id remains the opaque provider identity"
    [ { call_id = " call-trimmed "; call_name = "Read"; args = "{\"path\":\"a.ml\"}" } ]
    (A.to_tool_calls t)

let test_replay_identity_is_compared_before_trimming () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "call-raw") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":");
  A.on_event t
    (start ~index:0 ~tool_id:(Some " call-raw ") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "\"a.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "whitespace identity drift conflicts like live bridge"
    [] (A.to_tool_calls t)

let test_conflicting_start_cannot_reopen_until_stop () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-a") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}" );
  (* A conflicting identity invalidates this provider block. A later start at
     the same index must not turn the original fragments into a new call. *)
  A.on_event t (start ~index:0 ~tool_id:(Some "call-b") ~tool_name:(Some "Write"));
  A.on_event t (start ~index:0 ~tool_id:(Some "call-c") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"c.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "conflicted block is dropped" [] (A.to_tool_calls t);
  (* The terminator closes the bad bridge; a genuinely later block may reuse
     the index without inheriting any old fragments. *)
  A.on_event t (start ~index:0 ~tool_id:(Some "call-d") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"d.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "later block after stop is accepted"
    [ { call_id = "call-d"; call_name = "Read"; args = "{\"path\":\"d.ml\"}" } ]
    (A.to_tool_calls t)

(* A block with no call id cannot be joined to its output row, so persisting it
   would render an anonymous step. *)
let test_block_without_call_id_is_dropped () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:None ~tool_name:(Some "WebSearch"));
  A.on_event t (json_delta ~index:0 "{}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "identityless block dropped" [] (A.to_tool_calls t)

(* A stream that ends without per-block stops must still persist what it saw;
   otherwise the reload loses exactly the turns that were interrupted. *)
let test_message_stop_finalizes_open_blocks () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-3") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t Agent_core.Types.MessageStop;
  check (list tool_call) "open block finalized"
    [ { call_id = "call-3"; call_name = "Read"; args = "{\"path\":\"a.ml\"}" } ]
    (A.to_tool_calls t)

let test_non_tool_events_are_ignored () =
  let t = A.create () in
  A.on_event t (non_tool_start ~index:0 ~content_type:"text");
  A.on_event t (json_delta ~index:0 "{\"ignored\":true}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "no calls" [] (A.to_tool_calls t)

let test_identity_free_non_tool_start_preserves_active_tool () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "call-active") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":");
  A.on_event t (non_tool_start ~index:0 ~content_type:"text");
  A.on_event t (json_delta ~index:0 "\"a.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "identity-free non-tool start leaves active call intact"
    [ { call_id = "call-active"; call_name = "Read"; args = "{\"path\":\"a.ml\"}" } ]
    (A.to_tool_calls t)

(* masc#26071 review round 3: content_type = "tool_use" with no id/name is not
   a non-tool start — it is the malformed-tool-typed case the bridge
   tombstones (Tool_start_missing_identity). Unlike a genuinely non-tool
   start, the bridge's handler for this case does not consult the existing
   block: it unconditionally invalidates whatever was at that index,
   discarding an in-progress active tool's fragments too. *)
let test_malformed_tool_use_start_invalidates_active_tool () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "call-active") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t (start ~index:0 ~tool_id:None ~tool_name:None);
  A.on_event t (stop ~index:0);
  check (list tool_call) "malformed tool-use start drops the active call" []
    (A.to_tool_calls t)

(* Fresh evidence beyond the malformed-start review: a valid tool start
   arrives at the same index a malformed tool-use start already tombstoned,
   before that block's own terminator. The bridge keeps the index
   Invalid_tool_block until its stop and never emits Tool_call_start for the
   later valid start; the collector must not open a fresh block either. *)
let test_valid_start_after_malformed_tool_use_on_same_index_is_dropped () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:None ~tool_name:None);
  A.on_event t (start ~index:0 ~tool_id:(Some "call-e") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"e.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "valid start after malformed tool-use start is dropped" []
    (A.to_tool_calls t);
  (* The stop clears the tombstone; the index is reusable afterwards. *)
  A.on_event t (start ~index:0 ~tool_id:(Some "call-f") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"f.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "index reusable after malformed block's stop"
    [ { call_id = "call-f"; call_name = "Read"; args = "{\"path\":\"f.ml\"}" } ]
    (A.to_tool_calls t)

let test_invalid_tool_starts_are_ignored () =
  let t = A.create () in
  (* Blank tool_id or tool_name *)
  A.on_event t (start ~index:0 ~tool_id:(Some "   ") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t (stop ~index:0);
  (* Non-tool content type carrying identity *)
  A.on_event t (Agent_core.Types.ContentBlockStart
    { index = 1; content_type = "text"; tool_id = Some "call-x"; tool_name = Some "Read" });
  A.on_event t (json_delta ~index:1 "{\"path\":\"b.ml\"}");
  A.on_event t
    (start ~index:1 ~tool_id:(Some "call-y") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:1 "{\"path\":\"y.ml\"}");
  A.on_event t (stop ~index:1);
  check (list tool_call) "invalid starts ignored" [] (A.to_tool_calls t)

(* The bridge opens an [Active_media] block from a bare [MediaDelta] (no
   [ContentBlockStart]) and rejects a tool start colliding with it: protocol
   error only, no [Tool_call_start]. Persisting that start would give the
   reload a phantom tool row the live stream never showed. *)
let test_tool_start_on_media_occupied_index_is_dropped () =
  let t = A.create () in
  A.on_event t (media_delta ~index:0 "iVBORw0KGgo=");
  A.on_event t (start ~index:0 ~tool_id:(Some "call-m") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "tool start on media index dropped" [] (A.to_tool_calls t);
  (* The stop terminates the media block; the index is reusable afterwards,
     matching the bridge which frees the index at [ContentBlockStop]. *)
  A.on_event t (start ~index:0 ~tool_id:(Some "call-n") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"b.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "index reusable after media stop"
    [ { call_id = "call-n"; call_name = "Read"; args = "{\"path\":\"b.ml\"}" } ]
    (A.to_tool_calls t)

(* A media delta landing on an active tool block is a protocol error on the
   bridge side, but the bridge keeps the tool block active; the collector must
   not lose the call either. *)
let test_media_delta_on_active_tool_block_keeps_the_call () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-t") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":");
  A.on_event t (media_delta ~index:0 "iVBORw0KGgo=");
  A.on_event t (json_delta ~index:0 "\"a.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "tool block survives stray media delta"
    [ { call_id = "call-t"; call_name = "Read"; args = "{\"path\":\"a.ml\"}" } ]
    (A.to_tool_calls t)

let () =
  run "Keeper_stream_tool_accum"
    [ ( "accumulation"
      , [ test_case "fragments concatenate in order" `Quick test_fragments_concatenate_in_order
        ; test_case "snapshot replaces fragments" `Quick test_snapshot_replaces_fragments
        ; test_case "parallel blocks keep provider order" `Quick test_parallel_blocks_keep_provider_order
        ; test_case "replayed start keeps fragments" `Quick test_replayed_start_keeps_received_fragments
        ; test_case "replayed completed block stays deduplicated" `Quick
            test_replayed_completed_block_is_not_persisted_twice
        ; test_case "parallel duplicate ids stay deduplicated" `Quick
            test_parallel_blocks_with_same_call_id_drop_the_later_block
        ; test_case "tool call id stays opaque before persistence" `Quick
            test_tool_call_id_is_preserved_before_persistence
        ; test_case "replay identity compares raw provider values" `Quick
            test_replay_identity_is_compared_before_trimming
        ; test_case "conflicting start stays closed until stop" `Quick test_conflicting_start_cannot_reopen_until_stop
        ; test_case "block without call id is dropped" `Quick test_block_without_call_id_is_dropped
        ; test_case "message stop finalizes open blocks" `Quick test_message_stop_finalizes_open_blocks
        ; test_case "non-tool events are ignored" `Quick test_non_tool_events_are_ignored
        ; test_case "identity-free non-tool start preserves active tool" `Quick
            test_identity_free_non_tool_start_preserves_active_tool
        ; test_case "malformed tool-use start invalidates active tool" `Quick
            test_malformed_tool_use_start_invalidates_active_tool
        ; test_case "valid start stays dropped until malformed stop" `Quick
            test_valid_start_after_malformed_tool_use_on_same_index_is_dropped
        ; test_case "invalid tool starts are ignored" `Quick test_invalid_tool_starts_are_ignored
        ; test_case "tool start on media-occupied index is dropped" `Quick
            test_tool_start_on_media_occupied_index_is_dropped
        ; test_case "media delta on active tool block keeps the call" `Quick
            test_media_delta_on_active_tool_block_keeps_the_call
        ] )
    ]
