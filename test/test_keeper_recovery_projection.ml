open Alcotest
open Masc
module T = Agent_core.Types
module P = Keeper_recovery_projection
module Store = Keeper_checkpoint_store

let message ?tool_call_id role content : T.message =
  {role; content; tool_call_id; name=None; metadata=[]}
let text role value = message role [T.Text value]
let use id = T.ToolUse {id; name="keeper_artifact_read"; input=`Assoc []}
let result ?content_blocks id = T.ToolResult
  {tool_use_id=id; content="exact original result"; outcome=T.Tool_succeeded;
   json=Some (`Assoc ["id", `String id]); content_blocks}
let snapshot messages =
  let cp = Agent_core.Checkpoint.{
    version=checkpoint_version; session_id="projection-source"; agent_name="fixture";
    model="fixture"; system_prompt=None; messages; usage=T.empty_usage; turn_count=1;
    created_at=1000.; tools=[]; tool_choice=None; disable_parallel_tool_use=false;
    temperature=None; top_p=None; top_k=None; min_p=None; reasoning_effort=None;
    enable_thinking=None; preserve_thinking=None; response_format=T.Off;
    thinking_budget=None; cache_system_prompt=false; context=Agent_core.Context.create_sync ();
    mcp_sessions=[]; working_context=None} in
  let bytes = Yojson.Safe.pretty_to_string (Agent_core.Checkpoint.to_json cp) in
  let expected_session_id = Keeper_id.Trace_id.of_string "projection-source" |> Result.get_ok in
  match Store.exact_snapshot_of_canonical_bytes ~expected_session_id bytes with
  | Ok source -> source | Error _ -> fail "checkpoint fixture cannot be decoded"
let ok = function Ok x -> x | Error e -> fail (P.error_to_string e)
let rejected label predicate = function
  | Error error -> check bool label true (predicate error)
  | Ok _ -> fail (label ^ " unexpectedly succeeded")
let propose source steps = P.{source_sha256=(source_reference source).sha256; steps}
let summary first_atom last_atom = P.Summarize {first_atom;last_atom;text="Derived: the source tool returned an exact result."}
let exact label expected actual = check bool label true (expected=actual)

let fixture () =
  let instruction = text T.User "Keep the original task contract" in
  let cycle = [message T.Assistant [
      T.Thinking {content="fixture thinking"; signature=Some "fixture signature"}; use "a"; use "b"];
    message T.Tool ~tool_call_id:"b" [result ~content_blocks:[use "nested-only"] "b"];
    text T.User "An intervening requirement belongs to this same cycle";
    message T.Tool ~tool_call_id:"a" [result "a"]] in
  let suffix = [message T.Assistant [use "pending"]; text T.User "Still waiting for this call"] in
  instruction, cycle, suffix

let test_closed_cycle_and_pending_tail () =
  let instruction,cycle,suffix = fixture () in
  let messages = instruction :: cycle @ suffix in
  let raw = snapshot messages in
  let bytes = Store.exact_snapshot_canonical_bytes raw in
  let source = P.index ~source:raw ~required:[{message_index=0;reason=P.Task_contract}] |> ok in
  exact "parallel results, interstitial input, and pending tail are indivisible"
    [(0,0,0,false);(1,1,4,false);(2,5,6,true)]
    (List.map (fun (a:P.atom) -> a.atom_id,a.first_message,a.last_message,a.pending_tool_cycle) (P.atoms source));
  let proposal = propose source [P.Retain 0;summary 1 1;P.Retain 2] in
  let wire = Yojson.Safe.to_string (P.proposal_to_yojson proposal) in
  let proposal = match P.proposal_of_yojson (Yojson.Safe.from_string wire) with
    | Ok p -> p | Error e -> fail e in
  let validated = P.validate ~source proposal |> ok in
  (match P.bind_exact ~current_source:raw validated |> ok with
   | [P.Original [original];P.Derived derived;P.Original pending] ->
     exact "required instruction retained as its actual message" instruction original;
     exact "pending call and following user message unchanged" suffix pending;
     check string "derived text binds exact bytes" (Store.exact_snapshot_reference raw).sha256 derived.source_sha256;
     exact "derived provenance covers complete exchange" (1,4) (derived.first_message,derived.last_message)
   | _ -> fail "proposal invented or dropped a segment");
  check string "index and proposal preserve canonical bytes" bytes (Store.exact_snapshot_canonical_bytes raw);
  let retained = P.validate ~source (propose source [P.Retain 0;P.Retain 1;P.Retain 2]) |> ok in
  let retained = List.concat_map (function P.Original m -> m | P.Derived _ -> fail "unexpected derived segment") (P.segments retained) in
  exact "signed blocks, nested payload, IDs, and ordering remain exact" messages retained

let test_host_requirements_and_coverage () =
  let instruction,cycle,suffix = fixture () in
  let raw = snapshot (instruction :: cycle @ suffix) in
  let source = P.index ~source:raw ~required:[{message_index=3;reason=P.User_instruction}] |> ok in
  P.validate ~source (propose source [P.Retain 0;summary 1 1;P.Retain 2])
  |> rejected "interstitial requirement protects entire exchange" (function P.Protected_atom 1 -> true | _ -> false);
  P.validate ~source (propose source [P.Retain 0;P.Retain 1;summary 2 2])
  |> rejected "unfinished calls cannot be summarized" (function P.Protected_atom 2 -> true | _ -> false);
  P.index ~source:raw ~required:[{message_index=7;reason=P.Pending_continuation}]
  |> rejected "host requirement must exist in this source" (function P.Required_message_missing 7 -> true | _ -> false);
  List.iter (fun steps -> P.validate ~source (propose source steps)
    |> rejected "no missing, duplicated or reordered source" (function
       | P.Atom_order_mismatch _ | P.Incomplete_partition _ | P.Invalid_atom_range _ -> true | _ -> false))
    [[P.Retain 0];[P.Retain 1;P.Retain 0;P.Retain 2];[P.Retain 0;P.Retain 0;P.Retain 1;P.Retain 2];
     [P.Retain 0;P.Retain 1;P.Retain 2;P.Retain 3]]

let test_source_change_and_grouped_summary () =
  let messages = [text T.Assistant "first";text T.Assistant "second";text T.User "keep current request"] in
  let raw = snapshot messages in
  let source = P.index ~source:raw ~required:[{message_index=2;reason=P.User_instruction}] |> ok in
  let validated = P.validate ~source (propose source [summary 0 1;P.Retain 2]) |> ok in
  (match P.segments validated with
   | [P.Derived d;P.Original [_]] -> exact "adjacent source atoms may share one derived block" (0,1) (d.first_message,d.last_message)
   | _ -> fail "unexpected partition");
  List.iter (fun changed -> P.bind_exact ~current_source:(snapshot changed) validated
    |> rejected "stale source rejected" (function P.Source_changed -> true | _ -> false))
    [messages @ [text T.User "new instruction"];[text T.Assistant "changed";List.nth messages 1;List.nth messages 2]];
  let another = snapshot [text T.User "another source"] in
  P.validate ~source { (propose source [summary 0 1;P.Retain 2]) with source_sha256=(Store.exact_snapshot_reference another).sha256 }
  |> rejected "proposal digest belongs to exact source" (function P.Source_changed -> true | _ -> false);
  P.validate ~source (propose source [P.Summarize {first_atom=0;last_atom=1;text=" \n"};P.Retain 2])
  |> rejected "empty derived text is not recovery" (function P.Empty_summary -> true | _ -> false)

let test_shared_protocol_contract () =
  let cycle = [message T.Assistant [use "reused"];message T.Tool ~tool_call_id:"reused" [result "reused"]] in
  let source = P.index ~source:(snapshot (cycle @ cycle)) ~required:[] |> ok in
  check int "IDs may repeat after a closed exchange" 2 (List.length (P.atoms source));
  List.iter (fun messages -> P.index ~source:(snapshot messages) ~required:[]
    |> rejected "invalid protocol uses existing typed validator" (function P.Invalid_transcript _ -> true | _ -> false))
    [[message T.Tool [result "orphan"]];
     [message T.Assistant [use "a"];message T.Tool ~tool_call_id:"wrong" [result "a"]];
     [message T.Assistant [use "a";use "a"]]]

let () = Alcotest.run "Keeper source-bound recovery projection"
  ["proposal",[
    test_case "complete exchanges and original pending tail" `Quick test_closed_cycle_and_pending_tail;
    test_case "owner obligations and complete source coverage" `Quick test_host_requirements_and_coverage;
    test_case "grouped summary and exact source binding" `Quick test_source_change_and_grouped_summary;
    test_case "reuse canonical transcript protocol" `Quick test_shared_protocol_contract]]
