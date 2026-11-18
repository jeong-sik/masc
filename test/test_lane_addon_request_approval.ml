open Alcotest
open Masc
module Fingerprint = Keeper_approval_request_fingerprint
module Approval = Lane_addon_request_approval
module Channel = Keeper_continuation_channel

let get = function Ok value -> value | Error detail -> fail detail
let rejects label = function Ok _ -> fail (label ^ " unexpectedly accepted") | Error _ -> ()
let digest_a = String.make 64 'a'
let digest_b = String.make 64 'b'
let channel = get (Channel.dashboard ~thread_id:"original-thread")
let input = `Assoc ["count", `Float 1.; "source", `String "original-source"]

let origin turn =
  let source = get (Keeper_approval_origin.admitted_source ~snapshot_ref:digest_a
      ~admitted_revision:3L ~board_post_id:None) in
  get (Keeper_approval_origin.admitted_sources ~sources:[source]
    ~turn_ref:(Ids.Turn_ref.make ~trace_id:"approval-codec" ~absolute_turn:turn))

let exact ?(base_path="/workspace") ?(input=input) ?(origin=origin 1) () =
  get (Fingerprint.exact_request ~base_path ~keeper_name:"fixture" ~operation:"media_read"
    ~input ~origin ~task_id:(Some "task-a") ~goal_id:(Some "goal-a")
    ~continuation_channel:channel)

let matches ?(base_path="/workspace") ?(keeper_name="fixture") ?(operation="media_read")
    ?(input=input) ?(origin=origin 1) ?(task_id=Some "task-a") ?(goal_id=Some "goal-a")
    ?(continuation_channel=channel) ?input_hash request =
  let input_hash = match input_hash with
    | Some hash -> hash
    | None -> Fingerprint.request_fingerprint input in
  Fingerprint.matches_entry request ~base_path ~keeper_name ~operation ~input
    ~input_hash
    ~origin ~task_id ~goal_id ~continuation_channel

let object_fields = function
  | `Assoc fields -> fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "fixture expected an object"

let replace key value json =
  let fields = object_fields json in
  check bool "mutation targets an actual field" true (List.mem_assoc key fields);
  `Assoc (List.map (fun (name, old) -> name, if name=key then value else old) fields)

let test_canonical_input_and_legacy_hash () =
  check bool "legacy fingerprint still distinguishes scalar encodings" false
    (String.equal (Fingerprint.request_fingerprint (`Float 1.)) (Fingerprint.request_fingerprint (`Int 1)));
  let request = exact () in
  let integer_request = exact ~input:(`Assoc ["source", `String "original-source"; "count", `Int 1]) () in
  check bool "exact identity preserves the queue's float/integer distinction" false
    (Fingerprint.equal_exact_request request integer_request);
  check string "captured hash equals the actual submitted input hash"
    (Fingerprint.request_fingerprint input) (Fingerprint.input_hash request);
  check bool "object member order remains immaterial" true
    (Fingerprint.equal_exact_request request
      (exact ~input:(`Assoc ["source", `String "original-source"; "count", `Float 1.]) ()));
  let restored = get (Fingerprint.exact_request_of_json
      (get (Lane_addon_json.canonical (Fingerprint.exact_request_to_json request)))) in
  check bool "exact store-normalized round trip" true (Fingerprint.equal_exact_request request restored);
  check bool "outer normalization leaves the captured float intact" true
    (Yojson.Safe.equal (Fingerprint.input restored) input);
  List.iter (fun input ->
    let original = exact ~input () in
    let restored = get (Fingerprint.exact_request_of_json
      (get (Lane_addon_json.canonical (Fingerprint.exact_request_to_json original)))) in
    check bool "nested scalars survive the outer canonical envelope" true
      (Fingerprint.equal_exact_request original restored);
    check string "restored hash still describes submitted scalars"
      (Fingerprint.request_fingerprint input) (Fingerprint.input_hash restored))
    [`List [`Float (-0.); `Float 1.; `Int 1; `Intlit "9223372036854775808"];
     `Assoc ["nested", `List [`Float 1.; `Assoc ["count", `Int 1]]]];
  check string "workspace alias uses canonical workspace identity" "/workspace"
    (Fingerprint.base_path (exact ~base_path:"/workspace/.masc" ()));
  let make input = Fingerprint.exact_request ~base_path:"/workspace" ~keeper_name:"fixture"
      ~operation:"media_read" ~input ~origin:(origin 1) ~task_id:None ~goal_id:None
      ~continuation_channel:channel in
  rejects "duplicate Gate input keys" (make (`Assoc ["same",`Int 1;"same",`Int 2]));
  rejects "nonfinite Gate input" (make (`Assoc ["bad",`Float nan]));
  rejects "relative path cannot capture ambient cwd"
    (Fingerprint.exact_request ~base_path:"relative-workspace" ~keeper_name:"fixture"
      ~operation:"media_read" ~input ~origin:(origin 1) ~task_id:None ~goal_id:None ~continuation_channel:channel)

let test_matcher_keeps_logical_origin_and_complete_input () =
  let request = exact () in
  let integer_request = exact ~input:(`Assoc
      ["count", `Int 1; "source", `String "original-source"]) () in
  check bool "matching queue fields" true (matches request);
  check bool "physical turn is not a new logical request" true (matches ~origin:(origin 2) request);
  check bool "complete capture still retains physical witness" false
    (Fingerprint.equal_exact_request request (exact ~origin:(origin 2) ()));
  List.iter (fun (label, matched) -> check bool label false matched)
    ["workspace", matches ~base_path:"/other" request;
     "Keeper", matches ~keeper_name:"another" request;
     "operation", matches ~operation:"another" request;
     "complete input despite equal supplied hash",
       matches ~input:(`Assoc ["different",`Bool true])
         ~input_hash:(Fingerprint.input_hash request) request;
     "integer cannot borrow float identity even with the supplied float hash",
       matches ~input:(Fingerprint.input integer_request)
         ~input_hash:(Fingerprint.input_hash request) request;
     "malformed input", matches ~input:(`Assoc ["x",`Float infinity])
       ~input_hash:(Fingerprint.input_hash request) request;
     "logical origin", matches ~origin:Keeper_approval_origin.unavailable request;
     "task", matches ~task_id:None request;
     "goal", matches ~goal_id:None request;
     "exact channel", matches ~continuation_channel:(get (Channel.dashboard ~thread_id:"another-thread")) request];
  check bool "entry hash cannot be substituted" false
    (Fingerprint.matches_entry request ~base_path:"/workspace" ~keeper_name:"fixture" ~operation:"media_read"
      ~input ~input_hash:digest_b ~origin:(origin 1) ~task_id:(Some "task-a") ~goal_id:(Some "goal-a")
      ~continuation_channel:channel)

let test_strict_exact_codec () =
  let json = Fingerprint.exact_request_to_json (exact ()) in
  let fields = object_fields json in
  let malformed =
    ["unknown field", `Assoc (("unknown",`Bool true)::fields);
     "duplicate field", `Assoc (("input_hash",`String digest_a)::fields);
     "missing field", `Assoc (List.remove_assoc "goal_id" fields);
     "wrong digest", replace "input_hash" (`String digest_b) json;
     "wrong nullable type", replace "task_id" (`Bool false) json;
     "changed complete input", replace "input_json" (`String "{\"count\":2}") json;
     "changed scalar encoding", replace "input_json"
       (`String "{\"count\":1,\"source\":\"original-source\"}") json;
     "input must be text", replace "input_json" (`Assoc []) json;
     "invalid input JSON", replace "input_json" (`String "{") json;
     "duplicate input keys", replace "input_json" (`String "{\"same\":1,\"same\":2}") json;
     "nonfinite input", replace "input_json" (`String "NaN") json;
     "noncanonical input text", replace "input_json" (`String "{ \"count\":1.0}") json;
     "changed nested origin", replace "origin"
       (`Assoc (("unknown",`Bool true)::object_fields (Keeper_approval_origin.to_yojson (origin 1)))) json;
     "changed nested channel", replace "continuation_channel"
       (`Assoc (("unknown",`Bool true)::object_fields (Channel.to_yojson channel))) json]
  in
  List.iter (fun (label,value) -> rejects label (Fingerprint.exact_request_of_json value)) malformed

let test_public_origin_constructor_must_be_restorable () =
  let source = get (Keeper_approval_origin.admitted_source ~snapshot_ref:digest_a
      ~admitted_revision:3L ~board_post_id:None) in
  let unrestorable_origin = get (Keeper_approval_origin.admitted_sources ~sources:[source]
    ~turn_ref:(Ids.Turn_ref.make ~trace_id:"" ~absolute_turn:1)) in
  rejects "public origin with an empty trace cannot restore"
    (Keeper_approval_origin.of_yojson (Keeper_approval_origin.to_yojson unrestorable_origin));
  rejects "exact capture refuses an unrestorable typed origin"
    (Fingerprint.exact_request ~base_path:"/workspace" ~keeper_name:"fixture"
      ~operation:"media_read" ~input ~origin:unrestorable_origin ~task_id:None ~goal_id:None
      ~continuation_channel:channel)

let test_intent_and_exact_wait_link () =
  let request = exact () in
  let intent = get (Approval.intent ~request_id:"original-a" ~request_digest:digest_a ~request) in
  let restored = get (Approval.intent_of_json (Approval.intent_to_json intent)) in
  check bool "complete immutable intent round trip" true (Approval.equal_intent intent restored);
  check string "original ID" "original-a" (Approval.original_request_id restored);
  check string "original body digest" digest_a (Approval.original_request_digest restored);
  check bool "exact Gate identity retained" true (Fingerprint.equal_exact_request request (Approval.request restored));
  let other = get (Approval.intent ~request_id:"original-b" ~request_digest:digest_a ~request) in
  check bool "another original gets another intent identity" false
    (String.equal (Approval.intent_digest intent) (Approval.intent_digest other));
  let wait = get (Approval.wait intent ~approval_id:"approval-1" ~input_hash:(Fingerprint.input_hash request)) in
  let wait = get (Approval.wait_of_json (Approval.wait_to_json wait)) in
  check bool "exact waiting link" true (Approval.wait_matches_intent intent wait);
  check bool "same Gate hash cannot borrow another original's link" false (Approval.wait_matches_intent other wait);
  check string "actual approval identity retained" "approval-1" (Approval.approval_id wait);
  check string "wait hash" (Fingerprint.input_hash request) (Approval.wait_input_hash wait);
  rejects "wrong waiting input hash" (Approval.wait intent ~approval_id:"approval-1" ~input_hash:digest_b);
  rejects "blank approval identity" (Approval.wait intent ~approval_id:" " ~input_hash:(Fingerprint.input_hash request));
  let intent_json = Approval.intent_to_json intent in
  List.iter (fun (key,value) -> rejects ("intent tamper " ^ key)
    (Approval.intent_of_json (replace key value intent_json)))
    ["original_request_id",`String "another-original";
     "original_request_digest",`String digest_b;
     "exact_request",Fingerprint.exact_request_to_json (exact ~origin:(origin 2) ());
     "intent_digest",`String digest_b];
  let wrong_link = get (Approval.wait_of_json
    (replace "intent_digest" (`String (Approval.intent_digest other)) (Approval.wait_to_json wait))) in
  check bool "well-formed wait still requires its retained intent" false (Approval.wait_matches_intent intent wrong_link);
  rejects "duplicate wait fields" (Approval.wait_of_json
    (`Assoc (("approval_id",`String "approval-2")::object_fields (Approval.wait_to_json wait))));
  rejects "unknown intent fields" (Approval.intent_of_json
    (`Assoc (("allowed",`Bool true)::object_fields intent_json)))

let () = Alcotest.run "original approval facts"
  ["pure codecs",
   [test_case "canonical exact capture preserves legacy fingerprint semantics" `Quick test_canonical_input_and_legacy_hash;
    test_case "logical queue matching still checks complete input and owner" `Quick test_matcher_keeps_logical_origin_and_complete_input;
    test_case "strict complete exact-request codec" `Quick test_strict_exact_codec;
    test_case "public typed origin must survive strict restore" `Quick test_public_origin_constructor_must_be_restorable;
    test_case "immutable intent and exact waiting link" `Quick test_intent_and_exact_wait_link]]
