(* The repeated-call yield compares these fingerprints, so what they hash is
   behavior: a receipt field in the output must not break identity, and a
   changed answer must. Two live shapes this pins: a keeper ran [gh auth
   status] four times in one run and the four results differed only at
   execution_time_ms (2026-08-24); a keeper rewrote twelve memory claims 1,861
   times and every receipt differed only at revision and recorded_at
   (2026-10-05). Which part is the answer is each tool's to say
   (Keeper_tool_answer); this module names no field. *)

open Alcotest
module P = Masc.Keeper_tool_progress_identity
module A = Masc.Keeper_tool_answer

let fingerprints ~output =
  match
    P.digest_tool_io ~tool_name:"Execute"
      ~input:(`Assoc [ ("argv", `List [ `String "gh"; `String "auth" ]) ])
      ~output_text:output
  with
  | Some io -> io
  | None -> fail "digest_tool_io returned no fingerprints"

let execute_payload ~elapsed_ms ~stdout =
  Printf.sprintf
    {|{"ok":true,"status":{"kind":"exit","code":0},"output":%S,"typed":true,"execution_time_ms":%d}|}
    stdout elapsed_ms

let test_measurement_does_not_name_identity () =
  let a = fingerprints ~output:(execute_payload ~elapsed_ms:1170 ~stdout:"logged in") in
  let b = fingerprints ~output:(execute_payload ~elapsed_ms:1471 ~stdout:"logged in") in
  check string "same answer, different measurement: same fingerprint"
    a.P.output_fingerprint b.P.output_fingerprint

let test_a_changed_answer_changes_identity () =
  let a = fingerprints ~output:(execute_payload ~elapsed_ms:5 ~stdout:"branch main") in
  let b = fingerprints ~output:(execute_payload ~elapsed_ms:5 ~stdout:"branch dev") in
  check bool "different stdout: different fingerprint" false
    (String.equal a.P.output_fingerprint b.P.output_fingerprint)

let test_field_order_does_not_name_identity () =
  let a = fingerprints ~output:{|{"ok":true,"status":"exit"}|} in
  let b = fingerprints ~output:{|{"status":"exit","ok":true}|} in
  check string "canonicalized order" a.P.output_fingerprint b.P.output_fingerprint

let test_non_json_output_keeps_the_byte_hash () =
  let a = fingerprints ~output:"plain text answer" in
  let b = fingerprints ~output:"plain text answer" in
  let c = fingerprints ~output:"plain text different" in
  check string "equal text: equal fingerprint" a.P.output_fingerprint
    b.P.output_fingerprint;
  check bool "different text: different fingerprint" false
    (String.equal a.P.output_fingerprint c.P.output_fingerprint)

(* [digest_tool_io] answers from a memo (#33765) whose key holds the tool
   name, the input and the output text. Every case above varies the output
   under one fixed input, so a key that had dropped [input] would pass all of
   them: the first call would cache its answer under the output alone and the
   second would be handed the first call's input fingerprint.

   Sharing the output between two inputs is what asks the question. A memo
   that answers here with one fingerprint is answering for bytes it was not
   given. *)
let input_fingerprints ~input =
  match
    P.digest_tool_io ~tool_name:"Execute" ~input
      ~output_text:"the same answer for both"
  with
  | Some io -> io.P.input_fingerprint
  | None -> fail "digest_tool_io returned no fingerprints"

let test_the_input_reaches_the_answer_through_the_memo () =
  let a = input_fingerprints ~input:(`Assoc [ ("argv", `List [ `String "gh" ]) ]) in
  let b = input_fingerprints ~input:(`Assoc [ ("argv", `List [ `String "git" ]) ]) in
  check bool "different input, shared output: different fingerprint" false
    (String.equal a b);
  (* And the repeat is faithful: asking again for the first input gives back
     what it gave the first time rather than the neighbour it now shares a
     memo with. *)
  let a_again =
    input_fingerprints ~input:(`Assoc [ ("argv", `List [ `String "gh" ]) ])
  in
  check string "the repeat answers the same" a a_again

let output_fingerprint ~tool_name output =
  match P.digest_tool_io ~tool_name ~input:(`Assoc [ ("title", `String "t") ]) ~output_text:output with
  | Some io -> io.P.output_fingerprint
  | None -> fail "digest_tool_io returned no fingerprints"

(* A name that does not reach its handler would leave the tool's answer
   unread and the loop hidden again, with nothing failing. *)
let test_tool_names_reach_their_handlers () =
  let handler name =
    match A.resolve name with
    | A.Keeper_handler handler -> Masc.Keeper_tool_descriptor.runtime_handler_to_string handler
    | A.Outside_keeper_descriptors -> "outside"
  in
  check string "Execute" (Masc.Keeper_tool_descriptor.runtime_handler_to_string Masc.Keeper_tool_descriptor.Tool_execute)
    (handler "Execute");
  check string "keeper_memory_write"
    (Masc.Keeper_tool_descriptor.runtime_handler_to_string Masc.Keeper_tool_descriptor.Tool_memory_write)
    (handler "keeper_memory_write");
  check string "a transport-prefixed name"
    (Masc.Keeper_tool_descriptor.runtime_handler_to_string Masc.Keeper_tool_descriptor.Tool_memory_write)
    (handler "mcp__masc__keeper_memory_write");
  check string "an external tool" "outside" (handler "some_external_mcp_tool")

let test_a_whole_output_tool_keeps_every_field () =
  let shape ms = Printf.sprintf {|{"content":"x","execution_time_ms":%d}|} ms in
  check bool "Read reads its whole output: a changed field changes identity" false
    (String.equal
       (output_fingerprint ~tool_name:"Read" (shape 10))
       (output_fingerprint ~tool_name:"Read" (shape 99)));
  check bool "an external tool reads its whole output too" false
    (String.equal
       (output_fingerprint ~tool_name:"some_external_mcp_tool" (shape 10))
       (output_fingerprint ~tool_name:"some_external_mcp_tool" (shape 99)))

let memory_receipt ~disposition ~memory_id ~revision ~recorded_at =
  Printf.sprintf
    {|{"ok":true,"error_kind":"","identity_disposition":%S,"what_committed":"w","rows_written":1,"revision":%d,"recorded_at":%S,"outcome":"persisted_current_snapshot","store":"current_memory_snapshot","memory_id":%S,"basis":{"kind":"observed"}}|}
    disposition revision recorded_at memory_id

let test_a_memory_rewrite_is_the_same_answer () =
  let fingerprint ~revision ~recorded_at =
    output_fingerprint ~tool_name:"keeper_memory_write"
      (memory_receipt ~disposition:"reobserved" ~memory_id:"sha256:aa" ~revision
         ~recorded_at)
  in
  check string "revision and recorded_at do not name identity"
    (fingerprint ~revision:3760 ~recorded_at:"2026-10-05T21:00:45Z")
    (fingerprint ~revision:3772 ~recorded_at:"2026-10-05T21:03:14Z");
  check bool "another claim is another answer" false
    (String.equal
       (fingerprint ~revision:1 ~recorded_at:"t")
       (output_fingerprint ~tool_name:"keeper_memory_write"
          (memory_receipt ~disposition:"reobserved" ~memory_id:"sha256:bb" ~revision:1
             ~recorded_at:"t")));
  check bool "the insert is another answer than the rewrite" false
    (String.equal
       (fingerprint ~revision:1 ~recorded_at:"t")
       (output_fingerprint ~tool_name:"keeper_memory_write"
          (memory_receipt ~disposition:"inserted" ~memory_id:"sha256:aa" ~revision:1
             ~recorded_at:"t")))

(* A source-bound write names what it stored by the file's hash, not by a
   memory_id. The hash is the answer: the same file written again is the
   same answer, an edited file is another one. *)
let source_bound_receipt ~source_sha256 ~revision =
  Printf.sprintf
    {|{"ok":true,"error_kind":"","what_committed":"w","rows_written":1,"revision":%d,"recorded_at":"2026-10-05T21:%02d:00Z","outcome":"persisted_source_bound_current","store":"source_bound_current_memory","source_path":"docs/a.md","source_sha256":%S}|}
    revision revision source_sha256

let test_a_source_bound_rewrite_is_named_by_its_hash () =
  let fingerprint ~source_sha256 ~revision =
    output_fingerprint ~tool_name:"keeper_memory_write"
      (source_bound_receipt ~source_sha256 ~revision)
  in
  check string "the same file written again is the same answer"
    (fingerprint ~source_sha256:"sha256:11" ~revision:7)
    (fingerprint ~source_sha256:"sha256:11" ~revision:8);
  check bool "an edited file is another answer" false
    (String.equal
       (fingerprint ~source_sha256:"sha256:11" ~revision:7)
       (fingerprint ~source_sha256:"sha256:22" ~revision:7))

(* The detector the turn runs, fed the fingerprints the turn computes. *)
let test_a_third_memory_rewrite_stops_the_turn () =
  let call revision : Masc.Keeper_agent_result.tool_call_detail =
    let io =
      P.digest_tool_io ~tool_name:"keeper_memory_write"
        ~input:(`Assoc [ ("title", `String "t"); ("content", `String "c") ])
        ~output_text:
          (memory_receipt ~disposition:"reobserved" ~memory_id:"sha256:aa" ~revision
             ~recorded_at:(Printf.sprintf "2026-10-05T21:%02d:00Z" revision))
    in
    { tool_name = "keeper_memory_write"
    ; provider = "test"
    ; execution_outcome = Tool_result.Ok
    ; typed_outcome = None
    ; latency_ms = 1.
    ; task_id = None
    ; route_evidence = None
    ; input_fingerprint = Option.map (fun (io : P.io_fingerprints) -> io.input_fingerprint) io
    ; output_fingerprint = Option.map (fun (io : P.io_fingerprints) -> io.output_fingerprint) io
    }
  in
  check (option (pair string int)) "the third identical rewrite yields"
    (Some ("keeper_memory_write", 3))
    (Masc.Keeper_agent_run.For_testing.repeated_exact_tool_call ~threshold:3
       [ call 3; call 2; call 1 ])

let test_memory_identity_survives_changing_inputs () =
  let call ~tool_name ~memory_id ~content ~revision =
    let input =
      match tool_name with
      | "keeper_memory_write" ->
        `Assoc
          [ "content", `String content
          ; "observed_at", `String content
          ]
      | "keeper_memory_retract" ->
        `Assoc [ "memory_id", `String memory_id ]
      | _ -> fail "unexpected memory tool"
    in
    match
      P.digest_tool_io ~tool_name ~input
        ~output_text:
          (memory_receipt ~disposition:"reobserved" ~memory_id ~revision
             ~recorded_at:content)
    with
    | Some io -> io
    | None -> fail "digest_tool_io returned no fingerprints"
  in
  let first =
    call ~tool_name:"keeper_memory_write" ~memory_id:"sha256:aa"
      ~content:"10:01Z" ~revision:1
  in
  let repeated =
    call ~tool_name:"keeper_memory_write" ~memory_id:"sha256:aa"
      ~content:"10:02Z" ~revision:2
  in
  let other =
    call ~tool_name:"keeper_memory_write" ~memory_id:"sha256:bb"
      ~content:"10:02Z" ~revision:2
  in
  check string "same claim despite changed input"
    first.P.input_fingerprint repeated.P.input_fingerprint;
  let detail content revision : Masc.Keeper_agent_result.tool_call_detail =
    let io =
      call ~tool_name:"keeper_memory_write" ~memory_id:"sha256:aa" ~content
        ~revision
    in
    { tool_name = "keeper_memory_write"
    ; provider = "test"
    ; execution_outcome = Tool_result.Ok
    ; typed_outcome = None
    ; latency_ms = 1.
    ; task_id = None
    ; route_evidence = None
    ; input_fingerprint = Some io.P.input_fingerprint
    ; output_fingerprint = Some io.P.output_fingerprint
    }
  in
  check (option (pair string int)) "changing write payload still reaches repeat threshold"
    (Some ("keeper_memory_write", 3))
    (Masc.Keeper_agent_run.For_testing.repeated_exact_tool_call ~threshold:3
       [ detail "10:03Z" 3; detail "10:02Z" 2; detail "10:01Z" 1 ]);
  check string "same claim despite changed receipt"
    first.P.output_fingerprint repeated.P.output_fingerprint;
  check bool "different claim keeps its own identity" false
    (String.equal first.P.input_fingerprint other.P.input_fingerprint);
  check bool "write and retract remain distinct operations" false
    (String.equal first.P.input_fingerprint
       (call ~tool_name:"keeper_memory_retract" ~memory_id:"sha256:aa"
          ~content:"10:02Z" ~revision:2).P.input_fingerprint)

let selection_fact claim =
  Masc.Keeper_memory_os_types.observed ~claim ~category:Masc.Keeper_memory_os_types.Fact
    ~now:100. ~origin:{kind=Masc.Keeper_memory_os_types.Authored;trace_id="selection-fixture"}
let selected_memory ~claim ~use =
  let fact=selection_fact claim in
  let id=Masc.Keeper_memory_os_types.memory_id fact in
  `Assoc ["id",`String id;"use",`String use;"current",`Assoc
    ["store",`String "current_memory_snapshot";"memory_id",`String id;
     "current_fact",Masc.Keeper_memory_os_types.fact_to_json fact;
     "direct_admission_witness_count",`Int 1;"successor_witness_count",`Int 0]]
let selection_receipt receipt =
  `Assoc ["status",`String "completed";"purpose",`String "E17 production approval";
    "selection_id",`String receipt;"selected",`List [selected_memory ~claim:"Two approvals required" ~use:"current_decision"];
    "deferred",`List [];"unavailable",`List [];"assessed_count",`Int 1;"selected_count",`Int 1;
    "not_needed_count",`Int 0;"truncated_count",`Int 0;"incomplete",`Bool false;
    "snapshot_revision",`Int 7;"guidance",`String "Comparison is not current-event authority."]
let selection_fingerprint value = output_fingerprint ~tool_name:"keeper_memory_select" (Yojson.Safe.to_string value)
let replace_field key value = function
  | `Assoc fields -> `Assoc (List.map (fun (name,old) -> name,if name=key then value else old) fields)
  | _ -> fail "fixture object required"
let test_selection_receipts_do_not_create_false_progress () =
  let first=selection_receipt "selection-first" and second=selection_receipt "selection-second" in
  check string "different evaluation receipts are the same useful answer"
    (selection_fingerprint first) (selection_fingerprint second);
  let call value : Masc.Keeper_agent_result.tool_call_detail =
    let io=P.digest_tool_io ~tool_name:"keeper_memory_select" ~input:(`Assoc ["purpose",`String "E17 production approval"])
      ~output_text:(Yojson.Safe.to_string value) in
    {tool_name="keeper_memory_select";provider="fixture";execution_outcome=Tool_result.Ok;
     typed_outcome=None;latency_ms=1.;task_id=None;route_evidence=None;
     input_fingerprint=Option.map (fun (io : P.io_fingerprints) -> io.input_fingerprint) io;
     output_fingerprint=Option.map (fun (io : P.io_fingerprints) -> io.output_fingerprint) io} in
  check (option (pair string int)) "receipt-only retries reach the existing repeated-call yield"
    (Some ("keeper_memory_select",3))
    (Masc.Keeper_agent_run.For_testing.repeated_exact_tool_call ~threshold:3
       [call (selection_receipt "selection-third");call second;call first]);
  List.iter (fun (name,changed) -> check bool (name ^ " still changes progress identity") false
    (selection_fingerprint first=selection_fingerprint changed))
    ["claim",replace_field "selected" (`List [selected_memory ~claim:"Owner approval required" ~use:"current_decision"]) second;
     "role",replace_field "selected" (`List [selected_memory ~claim:"Two approvals required" ~use:"comparison"]) second;
     "unresolved",replace_field "deferred" (`List [`Assoc
       ["id",`String (Masc.Keeper_memory_os_types.memory_id (selection_fact "Other evidence"));
        "kind",`String "evidence_changed";"detail",`String "Current evidence changed during selection."]]) second;
     "snapshot",replace_field "snapshot_revision" (`Int 8) second;
     "count",replace_field "truncated_count" (`Int 1) second;
     "future answer field",(match second with `Assoc fields -> `Assoc (("future_meaning",`String "changed")::fields) | _ -> fail "fixture")]
let test_selection_malformed_output_keeps_whole_identity () =
  let answer text=Masc.Keeper_tool_answer.answer ~tool_name:"keeper_memory_select" ~output_text:text in
  List.iter (fun text -> check bool "malformed or noncompleted output is not projected" true (answer text=None))
    ["not json"; {|{"status":"completed","selection_id":"a"}|};
     Yojson.Safe.to_string (replace_field "status" (`String "unknown") (selection_receipt "a"));
     Yojson.Safe.to_string (match selection_receipt "a" with
       | `Assoc fields -> `Assoc (("selection_id",`String "duplicate")::fields) | _ -> fail "fixture")];
  let unavailable reason=`Assoc ["status",`String "unavailable";"reason",`String reason;"selected",`List [];"incomplete",`Bool true] in
  check bool "policy failures remain distinct" false
    (selection_fingerprint (unavailable "lane_disabled")=selection_fingerprint (unavailable "keeper_excluded"))

let () =
  run "keeper_tool_progress_identity"
    [ ( "identity"
      , [ test_case "measurement does not name identity" `Quick
            test_measurement_does_not_name_identity
        ; test_case "tool names reach their handlers" `Quick
            test_tool_names_reach_their_handlers
        ; test_case "a whole-output tool keeps every field" `Quick
            test_a_whole_output_tool_keeps_every_field
        ; test_case "a memory rewrite is the same answer" `Quick
            test_a_memory_rewrite_is_the_same_answer
        ; test_case "a source-bound rewrite is named by its hash" `Quick
            test_a_source_bound_rewrite_is_named_by_its_hash
        ; test_case "selection receipt identity is not retrieval progress" `Quick test_selection_receipts_do_not_create_false_progress
        ; test_case "malformed selection preserves fallback identity" `Quick test_selection_malformed_output_keeps_whole_identity
        ; test_case "a third memory rewrite stops the turn" `Quick
            test_a_third_memory_rewrite_stops_the_turn
        ; test_case "memory identity survives changing inputs" `Quick
            test_memory_identity_survives_changing_inputs
        ; test_case "a changed answer changes identity" `Quick
            test_a_changed_answer_changes_identity
        ; test_case "field order does not name identity" `Quick
            test_field_order_does_not_name_identity
        ; test_case "non-JSON output keeps the byte hash" `Quick
            test_non_json_output_keeps_the_byte_hash
        ; test_case "the input reaches the answer through the memo" `Quick
            test_the_input_reaches_the_answer_through_the_memo
        ] )
    ]
