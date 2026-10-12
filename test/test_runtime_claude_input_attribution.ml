open Alcotest
module A = Runtime_claude_input_attribution

let create () = A.create ~receiver_generation:"receiver-1" ~session_id:"session-1" ~client_uuid:"input-1"
let stamp primary consumed =
  ["user_message_uuid", `String primary;
   "user_message_uuids", `List (List.map (fun id -> `String id) consumed)]
let own = stamp "input-1" ["input-1"]
let observe t frame fields =
  match A.observe t ~session_id:"session-1" ~frame fields with
  | Some value -> value
  | None -> fail "expected a fresh observation"
let start uuid id = A.Partial_start {uuid=Some uuid;message_id=id}
let fragment uuid = A.Partial_fragment {uuid=Some uuid}
let assistant uuid id = A.Assistant {uuid=Some uuid;message_id=id}
let result uuid outcome = A.Result {uuid=Some uuid;outcome=Some outcome}
let is_consumed = function A.Consumed | A.Settled _ -> true | A.Prepared | A.Written | A.Write_unknown -> false
let group_of = function A.Explicit group | A.Inherited group | A.Command_inherited {group;_} -> Some group | A.Unattributed | A.Rejected _ -> None
let expect_rejected label attribution = match attribution with
  | A.Rejected _ -> () | A.Unattributed | A.Explicit _ | A.Inherited _ | A.Command_inherited _ -> fail label

let test_serialized_ticket_and_write_facts () =
  let t = create () in
  let ticket = A.ticket t in
  check bool "prepared before writing" true ((A.prepared t).phase=A.Prepared);
  let blocks = [`Assoc ["type", `String "text"; "text", `String "  네\n한글  "];
    `Assoc ["type",`String "image";"source",`Assoc ["data",`String "AQID"]]] in
  let wire = A.user_message t ~content:blocks |> Yojson.Safe.to_string |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  check string "outer UUID is the minted ticket" ticket.client_uuid (wire |> member "uuid" |> to_string);
  check bool "original content bytes and order" true (wire |> member "message" |> member "content" = `List blocks);
  check bool "written is not consumed" false (is_consumed (A.written t).phase);
  let other = create () in
  check bool "partial write is unknown" true ((A.write_unknown other).phase=A.Write_unknown)

let test_explicit_groups_and_exact_response_inheritance () =
  let t = create () in ignore (A.written t);
  let first = observe t (start "p1" "model-1") own in
  check bool "stamp consumes exact member" true (first.phase=A.Consumed);
  let folded = stamp "input-1" ["input-1";"other-client"] in
  let next = observe t (fragment "p2") folded in
  let inherited = observe t (fragment "p3") [] in
  check bool "explicit update is legal in same response" true (group_of next.attribution=group_of inherited.attribution);
  check bool "complete envelope has exact witnessed identity" true
    (group_of (observe t (assistant "a1" (Some "model-1")) []).attribution=group_of next.attribution);
  let unrelated = observe t (assistant "a2" (Some "other-model")) [] in
  check bool "new model remains within the witnessed typed command" true
    (match unrelated.attribution with A.Command_inherited witness ->
      witness.stamp_uuid="p2" && witness.group.primary="input-1" | _ -> false);
  let absent = observe t (result "r1" A.Provider_success) [] in
  check bool "unstamped result never inherits" true (absent.phase=A.Consumed && absent.attribution=A.Unattributed);
  let terminal = observe t (result "r2" A.Provider_error) (stamp "other-client" ["input-1";"other-client"]) in
  check bool "membership settles even with another primary" true (terminal.phase=A.Settled A.Provider_error)

let test_malformed_group_has_no_singular_fallback () =
  let invalid = [
    ["user_message_uuid",`String "input-1";"user_message_uuids",`Null];
    ["user_message_uuid",`String "input-1";"user_message_uuids",`List []];
    stamp "input-1" ["other"];
    stamp "input-1" ["input-1";"input-1"];
    ["user_message_uuids",`List [`String "input-1"]];
    ["user_message_uuid",`Null];
    ["user_message_uuid",`String "input-1";"user_message_uuid",`String "input-1"];
    stamp "input-1" ("input-1" :: List.init 64 (fun i -> string_of_int i))] in
  List.iteri (fun i fields ->
    let t = create () in ignore (A.written t);
    let observation = observe t (result (string_of_int i) A.Provider_success) fields in
    expect_rejected "malformed attribution admitted" observation.attribution;
    check bool "rejected result doesn't settle" true (observation.phase=A.Written)) invalid;
  check bool "provider's complete group at 64 is retained" true
    (match A.decode (stamp "input-1" ("input-1" :: List.init 63 string_of_int)) with
     | A.Explicit g -> List.length g.consumed=64 | _ -> false)

let test_replay_and_reused_response_ids () =
  let t=create () in ignore (A.written t);
  ignore (observe t (start "p1" "same-id") own);
  check bool "same frame metadata replay is idempotent" true
    (A.observe t ~session_id:"session-1" ~frame:(start "p1" "same-id") own=None);
  ignore (observe t (start "p2" "same-id") (stamp "other" ["other"]));
  check bool "fresh occurrence inherits only its own explicit group" true
    (match (observe t (fragment "p3") []).attribution with A.Inherited g -> g.primary="other" | _ -> false);
  expect_rejected "ambiguous complete ID chose newest" (observe t (assistant "a1" (Some "same-id")) []).attribution;
  ignore (observe t (fragment "p2") own);
  expect_rejected "conflicting UUID left current inheritance active" (observe t (fragment "p4") []).attribution

let test_replayed_start_cannot_retain_a_newer_owner () =
  let t=create () in ignore (A.written t);
  ignore (observe t (start "start-A" "response-A") own);
  ignore (observe t (start "start-B" "response-B") (stamp "other" ["other"]));
  check bool "exact old start metadata still deduplicates" true
    (A.observe t ~session_id:"session-1" ~frame:(start "start-A" "response-A") own=None);
  let after_start=observe t (fragment "after-old-start") [] in
  check bool "old start never leaves newer input inherited" true
    (after_start.attribution=A.Unattributed);
  expect_rejected "old response ID cannot revive ambiguous owner"
    (observe t (assistant "complete-A" (Some "response-A")) []).attribution

let test_replayed_stop_preserves_current_owner () =
  let t=create () in ignore (A.written t);
  ignore (observe t (start "start-C" "response-C") own);
  let stop=A.Partial_stop {uuid=Some "stop-C"} in
  ignore (observe t stop []);
  ignore (observe t (start "start-D" "response-D") (stamp "other" ["other"]));
  check bool "exact old stop metadata still deduplicates" true
    (A.observe t ~session_id:"session-1" ~frame:stop []=None);
  let after_stop=observe t (fragment "after-old-stop") [] in
  check bool "exact historical stop preserves newer witnessed input" true
    (after_stop.phase=A.Consumed && match after_stop.attribution with
     | A.Inherited group -> group.primary="other" && group.consumed=["other"]
     | _ -> false);
  ignore (observe t (A.Partial_stop {uuid=Some "stop-D"}) []);
  check bool "fresh stop retires current inheritance" true
    ((observe t (fragment "after-fresh-stop") []).attribution=A.Unattributed);
  ignore (observe t (start "start-E" "response-E") own);
  expect_rejected "missing stop UUID must be rejected"
    (observe t (A.Partial_stop {uuid=None}) []).attribution;
  check bool "missing stop identity cannot leave current inheritance" true
    ((observe t (fragment "after-missing-stop") []).attribution=A.Unattributed);
  ignore (observe t (start "start-F" "response-F") own);
  expect_rejected "conflicting stop UUID must be rejected"
    (observe t (A.Partial_stop {uuid=Some "start-F"}) []).attribution;
  check bool "conflicting stop identity cannot leave current inheritance" true
    ((observe t (fragment "after-conflicting-stop") []).attribution=A.Unattributed);
  check bool "stop without an owned cursor adopts nobody" true
    ((observe t (A.Partial_stop {uuid=Some "unowned-stop"}) []).attribution=A.Unattributed);
  ignore (observe t (start "start-G" "response-G") own);
  check bool "fresh response recovers its own witnessed scope" true
    (match (observe t (fragment "after-new-start") []).attribution with A.Inherited _ -> true | _ -> false)

let test_rejected_boundaries_quarantine_without_retracting_facts () =
  let t=create () in ignore (A.written t);
  ignore (observe t (start "p1" "first") own);
  ignore (observe t (assistant "unbound" None) []);
  expect_rejected "colliding start" (observe t (start "unbound" "second") []).attribution;
  let after = observe t (fragment "p3") [] in
  check bool "new unidentifiable response cannot inherit prior" true (after.attribution=A.Unattributed);
  check bool "consumption fact isn't retracted" true (after.phase=A.Consumed);
  ignore (observe t (start "p4" "third") own);
  ignore (observe t (A.Partial_fragment {uuid=None}) (stamp "other" ["other"]));
  expect_rejected "missing UUID stamp leaked old group" (observe t (fragment "p5") []).attribution;
  ignore (observe t (fragment "p6") own);
  check bool "fresh explicit stamp recovers exact occurrence" true
    (match (observe t (fragment "p7") []).attribution with A.Inherited _ -> true | _ -> false)

let test_foreign_session_unattributed_and_unknown_result () =
  let t=create () in ignore (A.written t);
  ignore (observe t (start "p1" "first") own);
  ignore (A.observe t ~session_id:"foreign" ~frame:(start "bad" "second") own);
  check bool "foreign session cannot poison local cursor" true
    (match (observe t (fragment "p2") []).attribution with A.Inherited _ -> true | _ -> false);
  let unknown = observe t (A.Result {uuid=Some "unknown";outcome=None}) own in
  check bool "invalid terminal isn't settlement" true (unknown.phase=A.Consumed);
  A.unowned_response_start t ~message_id:"unscoped-model";
  check bool "unowned start cannot preserve old root cursor" true
    ((observe t (fragment "after-unowned") []).attribution=A.Unattributed);
  ignore (observe t (A.Partial_stop {uuid=Some "stop"}) []);
  check bool "later unbound fragment doesn't inherit closed cursor" true
    ((observe t (fragment "late") []).attribution=A.Unattributed)

let test_typed_command_owns_later_model_responses () =
  let t=create () in ignore (A.written t);
  ignore (observe t (start "p1" "model-1") own);
  ignore (observe t (assistant "a1" (Some "model-1")) own);
  ignore (observe t (A.Partial_stop {uuid=Some "stop-1"}) []);
  let second=observe t (start "p2" "model-2") [] in
  let agent=observe t (assistant "agent-envelope" (Some "model-2")) [] in
  let complete_only=observe t (assistant "complete-only" None) [] in
  List.iter (fun (o : A.observation) ->
    check bool "whole typed command owns later unstamped roots" true
      (match o.attribution with A.Command_inherited witness ->
        witness.stamp_uuid="a1" && witness.group.primary="input-1"
        && witness.group.consumed=["input-1"] && o.phase=A.Consumed
       | _ -> false)) [second;agent;complete_only];
  let folded=stamp "input-1" ["input-1";"folded-input"] in
  ignore (observe t (assistant "fold-witness" (Some "model-2")) folded);
  ignore (observe t (A.Partial_stop {uuid=Some "stop-2"}) []);
  let third=observe t (start "p3" "model-3") [] in
  check bool "new root uses exactly the observed full group snapshot" true
    (match third.attribution with A.Command_inherited witness ->
      witness.stamp_uuid="fold-witness" && witness.group.consumed=["input-1";"folded-input"] | _ -> false);
  check bool "older observation is not retroactively expanded" true
    (match second.attribution with A.Command_inherited witness -> witness.group.consumed=["input-1"] | _ -> false);
  check bool "result settles through explicit membership" true
    ((observe t (result "result" A.Provider_success) folded).phase=A.Settled A.Provider_success)

let test_command_requires_own_primary_write_and_fresh_witness () =
  List.iter (fun initial ->
    let t=create () in ignore (A.written t);
    ignore (observe t (start "p1" "model-1") initial);
    ignore (observe t (A.Partial_stop {uuid=Some "stop"}) []);
    check bool "no own primary witness means no command inheritance" true
      ((observe t (start "p2" "model-2") []).attribution=A.Unattributed))
    [[]; stamp "foreign" ["foreign"]; stamp "foreign" ["input-1";"foreign"];
     ["user_message_uuid",`String "input-1";"user_message_uuids",`Null]];
  List.iter (fun contradictory ->
    let t=create () in ignore (A.written t);
    ignore (observe t (assistant "seed" None) own);
    ignore (observe t (assistant "contradiction" None) contradictory);
    check bool "contradictory metadata suspends an already witnessed command" true
      ((observe t (start "next-response" "next-model") []).attribution=A.Unattributed))
    [stamp "foreign" ["input-1";"foreign"];
     ["user_message_uuid",`String "input-1";"user_message_uuids",`Null];
     stamp "input-1" ["not-the-primary"]];
  let t=create () in
  ignore (observe t (assistant "before-write" None) own);
  ignore (A.written t);
  check bool "pre-write stamp cannot witness a dispatched command" true
    ((observe t (assistant "after-write" None) []).attribution=A.Unattributed);
  let t=create () in ignore (A.write_unknown t);
  ignore (observe t (assistant "unknown-write-1" None) own);
  ignore (observe t (assistant "unknown-write-2" None) own);
  check bool "consumption after unknown write is not a full-write command proof" true
    ((observe t (assistant "unknown-write-3" None) []).attribution=A.Unattributed);
  let t=create () in ignore (A.written t);
  ignore (observe t (start "root-1" "model-1") own);
  ignore (observe t (A.Partial_stop {uuid=Some "root-stop"}) []);
  ignore (observe t (start "root-2" "model-2") []);
  ignore (observe t (assistant "foreign-without-model-id" None) (stamp "foreign" ["foreign"]));
  check bool "derived response proof cannot bypass suspended command authority" true
    ((observe t (fragment "after-foreign-root") []).attribution=A.Unattributed);
  let t=create () in ignore (A.written t);
  ignore (observe t (assistant "owned-witness" None) own);
  ignore (observe t (assistant "foreign-witness" None) (stamp "foreign" ["foreign"]));
  check bool "old exact stamp stays deduplicated" true
    (A.observe t ~session_id:"session-1" ~frame:(assistant "owned-witness" None) own=None);
  check bool "replay cannot reseed a suspended command" true
    ((observe t (assistant "still-unknown" None) []).attribution=A.Unattributed);
  ignore (observe t (assistant "fresh-own-witness" None) own);
  check bool "fresh own-primary witness can resume command evidence" true
    (match (observe t (assistant "known-again" None) []).attribution with
     | A.Command_inherited w -> w.stamp_uuid="fresh-own-witness" | _ -> false)

let test_command_cannot_conceal_uncertain_cursor_or_outlive_result () =
  let t=create () in ignore (A.written t);
  ignore (observe t (start "p1" "model-1") own);
  ignore (observe t (start "p2" "model-2") []);
  ignore (A.observe t ~session_id:"session-1" ~frame:(start "p1" "model-1") own);
  check bool "command route cannot hide stale body cursor" true
    ((observe t (fragment "after-stale-start") []).attribution=A.Unattributed);
  ignore (observe t (assistant "new-own-proof" None) own);
  check bool "new command witness alone cannot repair uncertain body scope" true
    ((observe t (assistant "uncertain-complete" None) []).attribution=A.Unattributed);
  let recovered=observe t (start "p3" "model-3") [] in
  check bool "fresh response boundary uses reestablished command proof" true
    (match recovered.attribution with A.Command_inherited _ -> true | _ -> false);
  List.iter (fun result_fields ->
    let t=create () in ignore (A.written t);
    ignore (observe t (start "initial" "response") own);
    let ended=observe t (result "terminal" A.Provider_error) result_fields in
    check bool "unstamped/foreign/malformed result never inherits" true
      (match ended.attribution with A.Inherited _ | A.Command_inherited _ -> false | _ -> true);
    check bool "root result ends command fallback" true
      ((observe t (start "late" "late-response") []).attribution=A.Unattributed);
    ignore (observe t (assistant "late-own" None) own);
    check bool "even a later explicit frame cannot reopen this ended command" true
      ((observe t (assistant "late-unstamped" None) []).attribution=A.Unattributed))
    [[];stamp "foreign" ["foreign"];["user_message_uuid",`String "input-1";"user_message_uuids",`Null]]

let test_unowned_start_retires_cursor_without_suspending_command () =
  let t=create () in ignore (A.written t);
  ignore (observe t (start "witness" "root-before-child") own);
  A.unowned_response_start t ~message_id:"child-model";
  check bool "child scope cannot lend root proof to an unbound fragment" true
    ((observe t (fragment "before-fresh-root") []).attribution=A.Unattributed);
  check bool "complete envelope alone cannot clear uncertain response scope" true
    ((observe t (assistant "before-root-envelope" None) []).attribution=A.Unattributed);
  let restored=observe t (start "fresh-root" "root-after-child") [] in
  check bool "fresh root uses the original command witness" true
    (match restored.attribution with
     | A.Command_inherited witness -> witness.stamp_uuid="witness"
         && witness.group.primary="input-1" && witness.group.consumed=["input-1"]
     | A.Unattributed | A.Explicit _ | A.Inherited _ | A.Rejected _ -> false);
  List.iter (fun prepare ->
    let t=create () in ignore (A.written t); prepare t;
    A.unowned_response_start t ~message_id:"child-model";
    check bool "fresh root cannot create or revive missing command evidence" true
      ((observe t (start "fresh-root" "root-after-child") []).attribution=A.Unattributed))
    [(fun _ -> ());
     (fun t -> ignore (observe t (start "witness" "root") own);
       ignore (observe t (assistant "foreign" None) (stamp "other" ["other"])));
     (fun t -> ignore (observe t (start "witness" "root") own);
       ignore (observe t (result "terminal" A.Provider_success) own));
     (fun t -> ignore (observe t (start "witness" "root") own);
       ignore (observe t (start "next" "next-root") []);
       ignore (A.observe t ~session_id:"session-1" ~frame:(start "witness" "root") own))]

let test_command_proof_does_not_select_reused_model_occurrence () =
  let prepare stamp =
    let t=create () in ignore (A.written t);
    ignore (observe t (start "first" "reused-model") stamp);
    ignore (observe t (A.Partial_stop {uuid=Some "first-stop"}) []);
    ignore (observe t (start "second" "reused-model") []);
    t in
  let t=prepare own in
  check bool "fresh assistant with reused model ID keeps separate command proof" true
    (match (observe t (assistant "fresh-agent" (Some "reused-model")) []).attribution with
     | A.Command_inherited witness -> witness.stamp_uuid="first"
         && witness.group.primary="input-1" && witness.group.consumed=["input-1"]
     | _ -> false);
  List.iter (fun initial ->
    let t=prepare initial in
    check bool "ambiguous response without own command remains rejected" true
      ((observe t (assistant "unowned-agent" (Some "reused-model")) []).attribution=A.Rejected A.Ambiguous_response))
    [[];stamp "foreign" ["input-1";"foreign"]];
  let t=prepare own in
  ignore (observe t (assistant "foreign" None) (stamp "foreign" ["foreign"]));
  check bool "suspended command cannot bypass ambiguous model ID" true
    ((observe t (assistant "suspended-agent" (Some "reused-model")) []).attribution=A.Rejected A.Ambiguous_response);
  let t=prepare own in
  ignore (A.observe t ~session_id:"session-1" ~frame:(start "first" "reused-model") own);
  ignore (observe t (assistant "new-command-witness" None) own);
  check bool "new command witness cannot hide stale body scope" true
    ((observe t (assistant "uncertain-agent" (Some "reused-model")) []).attribution=A.Rejected A.Ambiguous_response);
  let t=prepare own in
  ignore (observe t (result "terminal" A.Provider_success) own);
  check bool "ended command supplies no ambiguous-ID fallback" true
    ((observe t (assistant "after-terminal-agent" (Some "reused-model")) []).attribution=A.Unattributed)

let () = run "Claude input attribution"
  ["ticket", [test_case "outer UUID and write facts" `Quick test_serialized_ticket_and_write_facts;
    test_case "group update and response inheritance" `Quick test_explicit_groups_and_exact_response_inheritance;
    test_case "malformed group cannot fall back" `Quick test_malformed_group_has_no_singular_fallback;
    test_case "replay and message ID reuse" `Quick test_replay_and_reused_response_ids;
    test_case "old start replay cannot keep newer owner" `Quick test_replayed_start_cannot_retain_a_newer_owner;
    test_case "historical stop preserves current owner" `Quick test_replayed_stop_preserves_current_owner;
    test_case "rejected boundaries quarantine inheritance" `Quick test_rejected_boundaries_quarantine_without_retracting_facts;
    test_case "foreign and unknown authority" `Quick test_foreign_session_unattributed_and_unknown_result;
    test_case "typed SDK command owns later model responses" `Quick test_typed_command_owns_later_model_responses;
    test_case "command requires own primary write and fresh witness" `Quick test_command_requires_own_primary_write_and_fresh_witness;
    test_case "command respects cursor uncertainty and result end" `Quick test_command_cannot_conceal_uncertain_cursor_or_outlive_result;
    test_case "unowned start retains witnessed command until fresh root" `Quick test_unowned_start_retires_cursor_without_suspending_command;
    test_case "command proof does not select reused model occurrence" `Quick test_command_proof_does_not_select_reused_model_occurrence]]
