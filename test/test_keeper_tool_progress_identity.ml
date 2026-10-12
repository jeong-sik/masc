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
module O = Tool_output

let fingerprints ~output =
  match
    P.digest_tool_io ~tool_name:"Execute"
      ~input:(`Assoc [ ("argv", `List [ `String "gh"; `String "auth" ]) ])
      ~output_text:output ()
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
      ~output_text:"the same answer for both" ()
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
  match P.digest_tool_io ~tool_name ~input:(`Assoc [ ("title", `String "t") ]) ~output_text:output () with
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
             ~recorded_at:(Printf.sprintf "2026-10-05T21:%02d:00Z" revision)) ()
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
        ()
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

(* A memory write receipt too large to travel inline reaches the model as a
   blob marker. Read from verified blob bytes, it must name the same claim its
   inline form names, so a rewrite loop with a changing request reaches the
   repeated-call yield either way. *)
let test_a_stored_memory_rewrite_keeps_memory_identity () =
  let base_path = Filename.temp_file "masc-memory-write-identity" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let ceiling = O.inline_ceiling_bytes O.default_model_projection in
  let removed =
    List.init (ceiling / 64 + 1) (fun i -> `String (Printf.sprintf "sha256:%064d" i))
  in
  let receipt ~memory_id ~revision ~at =
    `Assoc
      [ "ok", `Bool true
      ; "error_kind", `String ""
      ; "identity_disposition", `String "reobserved"
      ; "what_committed", `String "w"
      ; "rows_written", `Int 1
      ; "revision", `Int revision
      ; "recorded_at", `String at
      ; "outcome", `String "persisted_current_snapshot"
      ; "store", `String "current_memory_snapshot"
      ; "memory_id", `String memory_id
      ; "basis", `Assoc [ "kind", `String "observed" ]
      ; "removed_memory_ids", `List removed
      ]
  in
  let stored value =
    check bool "the receipt exceeds the inline ceiling" true
      (String.length (Yojson.Safe.to_string value) > ceiling);
    let result =
      Tool_result.make_ok ~tool_name:"keeper_memory_write"
        ~start_time:(Tool_timing.start ()) ~data:value ()
    in
    match
      Masc.Tool_bridge.to_agent_core_typed_result ~base_path
        ~answer_reader:(fun output_text ->
          A.answer ~tool_name:"keeper_memory_write" ~output_text)
        result
    with
    | Error error -> fail error.Agent_core.Types.message
    | Ok typed ->
      let content = typed.Agent_core.Types.content in
      (match O.decode_from_agent_core content with
       | O.Decoded _ -> content
       | O.Not_marker | O.Invalid_marker _ -> fail "the bridge must store this receipt")
  in
  let input at =
    `Assoc [ "content", `String "Two approvals required"; "observed_at", `String at ]
  in
  let io ?base_path ~at output_text =
    match
      P.digest_tool_io ?base_path ~tool_name:"keeper_memory_write" ~input:(input at)
        ~output_text ()
    with
    | Some io -> io
    | None -> fail "digest_tool_io returned no fingerprints"
  in
  let stored_io ~memory_id ~revision ~at =
    io ~base_path ~at (stored (receipt ~memory_id ~revision ~at))
  in
  let detail fingerprints : Masc.Keeper_agent_result.tool_call_detail =
    { tool_name = "keeper_memory_write"
    ; provider = "test"
    ; execution_outcome = Tool_result.Ok
    ; typed_outcome = None
    ; latency_ms = 1.
    ; task_id = None
    ; route_evidence = None
    ; input_fingerprint = Some fingerprints.P.input_fingerprint
    ; output_fingerprint = Some fingerprints.P.output_fingerprint
    }
  in
  let first = receipt ~memory_id:"sha256:aa" ~revision:1 ~at:"10:01Z" in
  let first_stored = stored first in
  let inline = io ~at:"10:01Z" (Yojson.Safe.to_string first) in
  let stored_first = io ~base_path ~at:"10:01Z" first_stored in
  check string "a stored receipt names the claim its inline form names (input)"
    inline.P.input_fingerprint stored_first.P.input_fingerprint;
  check string "a stored receipt names the claim its inline form names (output)"
    inline.P.output_fingerprint stored_first.P.output_fingerprint;
  check (option (pair string int)) "stored rewrites with a changing request yield"
    (Some ("keeper_memory_write", 3))
    (Masc.Keeper_agent_run.For_testing.repeated_exact_tool_call ~threshold:3
       [ detail (stored_io ~memory_id:"sha256:aa" ~revision:3 ~at:"10:03Z")
       ; detail (stored_io ~memory_id:"sha256:aa" ~revision:2 ~at:"10:02Z")
       ; detail stored_first
       ]);
  check bool "a stored receipt for another claim keeps its own identity" false
    (String.equal stored_first.P.input_fingerprint
       (stored_io ~memory_id:"sha256:bb" ~revision:2 ~at:"10:02Z").P.input_fingerprint);
  check bool "without the owned store the marker does not name a claim" false
    (String.equal inline.P.input_fingerprint
       (io ~at:"10:01Z" first_stored).P.input_fingerprint);
  let pair : P.history_pair =
    { tool_name = "keeper_memory_write"; input = input "10:01Z"; output_text = first_stored }
  in
  check (list (option string)) "history replay names the same claim"
    [ Some inline.P.input_fingerprint ]
    (List.map
       (Option.map (fun (io : P.io_fingerprints) -> io.input_fingerprint))
       (P.digest_history_pairs ~base_path (P.History_memo.create ()) [ pair ]))

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
      ~output_text:(Yojson.Safe.to_string value) () in
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

let test_large_selection_projection_keeps_answer_identity () =
  let path = Filename.temp_file "masc-selection-identity" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  let cleanup () =
    let rec remove path =
      if Sys.file_exists path then
        if Sys.is_directory path then begin
          Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
          Unix.rmdir path
        end else Unix.unlink path
    in
    remove path
  in
  Fun.protect ~finally:cleanup @@ fun () ->
  let claim = String.concat "\n" (List.init
      (O.inline_ceiling_bytes O.default_model_projection / 32 + 1)
      (fun i -> Printf.sprintf "Release R%04d requires two independent approvals." i)) in
  let receipt id claim use = selection_receipt id
    |> replace_field "selected" (`List [selected_memory ~claim ~use]) in
  let project value =
    let raw = Yojson.Safe.to_string value in
    check bool "actual selected claim exceeds bridge ceiling" true
      (String.length raw > O.inline_ceiling_bytes O.default_model_projection);
    let result = Tool_result.make_ok ~tool_name:"keeper_memory_select"
        ~start_time:(Tool_timing.start ()) ~data:value () in
    let content = match Masc.Tool_bridge.to_agent_core_typed_result ~base_path:path
        ~answer_reader:(fun output_text -> A.answer ~tool_name:"keeper_memory_select" ~output_text) result with
      | Ok result -> result.Agent_core.Types.content
      | Error error -> fail error.Agent_core.Types.message in
    match O.decode_from_agent_core content with
    | O.Decoded reference ->
      check (option string) "stored original preserves full receipt bytes" (Some raw)
        (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path:path)
           ~sha256:reference.sha256 with Ok value -> value | Error _ -> fail "fetch failed");
      content, reference
    | _ -> fail "actual bridge must externalize this selected claim" in
  let input = `Assoc ["purpose",`String "release policies"] in
  let identity ?base_path ?(tool_name="keeper_memory_select") content =
    match P.digest_tool_io ?base_path ~tool_name ~input ~output_text:content () with
    | Some io -> io.P.output_fingerprint | None -> fail "identity missing" in
  let first_value = receipt "selection-first" claim "current_decision" in
  let first, first_ref = project first_value in
  let second, second_ref = project (receipt "selection-second" claim "current_decision") in
  check bool "audit receipts remain distinct raw blobs" false (first_ref.sha256=second_ref.sha256);
  let expected = selection_fingerprint first_value in
  check string "verified first blob has producer semantic identity" expected (identity ~base_path:path first);
  check string "receipt-only change preserves semantic identity" expected (identity ~base_path:path second);
  check bool "without owned store identity remains distinct" false (identity first=identity second);
  let changed, changed_ref = project (receipt "selection-third" (claim ^ "\nR9999 requires owner approval.") "current_decision") in
  let comparison, _ = project (receipt "selection-fourth" claim "comparison") in
  List.iter (fun content -> check bool "claim and use remain semantic differences" false
      (expected=identity ~base_path:path content)) [changed;comparison];
  let forged = match O.with_answer_fingerprint changed_ref first_ref.answer_fingerprint with
    | Ok reference -> O.encode_for_agent_core (O.Stored reference)
    | Error _ -> fail "valid fingerprint required" in
  check string "different blob cannot assert another answer" (identity forged) (identity ~base_path:path forged);
  check string "Whole_output tool ignores declared answer" (identity ~tool_name:"keeper_artifact_read" first)
    (identity ~base_path:path ~tool_name:"keeper_artifact_read" first);
  let memo = P.History_memo.create () in
  let pair : P.history_pair = {tool_name="keeper_memory_select"; input; output_text=first} in
  let historical () = match P.digest_history_pairs ~base_path:path memo [pair] with
    | [Some io] -> io.P.output_fingerprint | _ -> fail "history identity missing" in
  check string "history initially verifies original bytes" expected (historical ());
  let blob_path reference = Filename.concat (Tool_blob_store.root_dir (Tool_blob_store.create ~base_path:path))
      (Filename.concat (String.sub reference.O.sha256 0 2) reference.sha256) in
  Unix.unlink (blob_path first_ref);
  check string "missing blob cannot reuse live memo" (identity first) (identity ~base_path:path first);
  check string "missing blob cannot reuse history memo" (identity first) (historical ());
  Fs_compat.save_file (blob_path first_ref) "corrupt replacement";
  check string "corrupt blob cannot reuse live memo" (identity first) (identity ~base_path:path first);
  check string "corrupt blob cannot reuse history memo" (identity first) (historical ());
  Printf.printf "MEMORY_SELECTION_LARGE_IDENTITY %s\n%!"
    (Yojson.Safe.to_string (`Assoc ["raw_blobs_distinct",`Bool (first_ref.sha256<>second_ref.sha256);
      "verified_answers_equal",`Bool (expected=identity ~base_path:path second);
      "first_bytes",`Int first_ref.bytes;"second_bytes",`Int second_ref.bytes]))


let test_a_manifest_wrapped_execute_keeps_identity () =
  let path = Filename.temp_file "masc-manifest-identity" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  let cleanup () =
    let rec remove path =
      if Sys.file_exists path then
        if Sys.is_directory path then begin
          Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
          Unix.rmdir path
        end else Unix.unlink path
    in
    remove path
  in
  Fun.protect ~finally:cleanup @@ fun () ->
  let store = Tool_blob_store.create ~base_path:path in
  let big = String.concat "" (List.init
      (O.inline_ceiling_bytes O.default_model_projection / 32 + 1)
      (fun i -> Printf.sprintf "line %06d of collected output" i)) in
  (* The payload shape is the one composable_output_fields writes once the
     output is externalized: the artifact fields replace the inline text. *)
  let receipt ~elapsed_ms ~text =
    let ref = Tool_blob_store.put_durable store ~bytes:text ~mime:"text/plain"
      |> Tool_output.normalized_artifact_ref_to_json in
    `Assoc [ "ok", `Bool true
           ; "status", `Assoc [ "kind", `String "exit"; "code", `Int 0 ]
           ; "output_artifact", ref
           ; "typed", `Bool true
           ; "execution_time_ms", `Int elapsed_ms ] in
  let project value =
    let result = Tool_result.make_ok ~tool_name:"Execute"
        ~start_time:(Tool_timing.start ()) ~data:value () in
    let wrapped = match Masc.Tool_bridge.attach_artifact_manifest ~base_path:path result with
      | Ok result -> result
      | Error error -> fail error.Masc.Tool_bridge.message in
    let content = match Masc.Tool_bridge.to_agent_core_typed_result ~base_path:path
        ~answer_reader:(fun output_text -> A.answer ~tool_name:"Execute" ~output_text) wrapped with
      | Ok typed -> typed.Agent_core.Types.content
      | Error error -> fail error.Agent_core.Types.message in
    match O.decode_from_agent_core content with
    | O.Decoded reference -> content, reference
    | _ -> fail "the manifest branch must store this receipt" in
  let input = `Assoc [ "argv", `List [ `String "collect"; `String "--all" ] ] in
  let identity ?base_path content =
    match P.digest_tool_io ?base_path ~tool_name:"Execute" ~input ~output_text:content () with
    | Some io -> io.P.output_fingerprint | None -> fail "identity missing" in
  let first, first_ref = project (receipt ~elapsed_ms:1170 ~text:big) in
  let second, second_ref = project (receipt ~elapsed_ms:1180 ~text:big) in
  let changed, _ = project (receipt ~elapsed_ms:1170 ~text:(big ^ "\nfinal line differs")) in
  check bool "manifests differ between runs" false (first_ref.sha256 = second_ref.sha256);
  check bool "the manifest declares the answer fingerprint" true
    (Option.is_some first_ref.O.answer_fingerprint);
  let inline = identity (Yojson.Safe.to_string (receipt ~elapsed_ms:1170 ~text:big)) in
  check string "an externalized execute keeps its inline identity" inline
    (identity ~base_path:path first);
  check string "a repeated externalized execute keeps one identity"
    (identity ~base_path:path first) (identity ~base_path:path second);
  check bool "a changed externalized answer changes identity" false
    (identity ~base_path:path first = identity ~base_path:path changed)

let test_execute_manifest_identity_does_not_read_child_artifacts () =
  let base_path = Filename.temp_file "execute-manifest-identity-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let store = Tool_blob_store.create ~base_path in
  let child text = Tool_blob_store.put_durable store ~bytes:text ~mime:"text/plain" in
  let stdout = child "release verification passed" in
  let stderr = child "" in
  let changed_stdout = child "release verification failed" in
  let data output code = `Assoc ["ok",`Bool (code=0);"status",`Assoc
      ["kind",`String "exit";"code",`Int code];"execution_time_ms",`Int 42;
      "stdout_artifact",O.normalized_artifact_ref_to_json output;
      "stderr_artifact",O.normalized_artifact_ref_to_json stderr;
      "output_artifact",O.normalized_artifact_ref_to_json output] in
  let project data =
    let result = Tool_result.make_ok ~tool_name:"Execute" ~start_time:(Tool_timing.start ()) ~data () in
    let result = match Masc.Tool_bridge.attach_artifact_manifest ~base_path result with
      | Ok result -> result | Error error -> fail error.Masc.Tool_bridge.message in
    match Masc.Tool_bridge.to_agent_core_typed_result ~base_path
        ~answer_reader:(fun output_text -> A.answer ~tool_name:"Execute" ~output_text) result with
    | Ok result -> result.Agent_core.Types.content
    | Error error -> fail error.Agent_core.Types.message in
  let fingerprint content = match P.digest_tool_io ~base_path ~tool_name:"Execute"
      ~input:(`Assoc ["command",`String "verify-release"]) ~output_text:content () with
    | Some io -> io.P.output_fingerprint | None -> fail "fingerprint missing" in
  let original = project (data stdout 0) in
  let expected = fingerprint original in
  List.iter (fun changed -> check bool "output address and exit status change the answer" false
      (expected=fingerprint changed)) [project (data changed_stdout 0);project (data stdout 1)];
  let memo = P.History_memo.create () in
  let pair : P.history_pair = {tool_name="Execute";input=`Assoc [];output_text=original} in
  let history () = match P.digest_history_pairs ~base_path memo [pair] with
    | [Some io] -> io.P.output_fingerprint | _ -> fail "history fingerprint missing" in
  check string "history starts from verified manifest" expected (history ());
  List.iter (fun (reference : O.artifact_ref) ->
    Unix.unlink (Filename.concat (Tool_blob_store.root_dir store)
      (Filename.concat (String.sub reference.sha256 0 2) reference.sha256)))
    [stdout;stderr;changed_stdout];
  check string "child availability does not change original command answer" expected (fingerprint original);
  check string "history verifies manifest without traversing missing children" expected (history ());
  check bool "verification does not restore output child" true
    (match Tool_blob_store.fetch store ~sha256:stdout.sha256 with Ok None -> true | _ -> false)


let () =
  run "keeper_tool_progress_identity"
    [ ( "identity"
      , [ test_case "Execute manifest does not traverse child artifacts" `Quick
            test_execute_manifest_identity_does_not_read_child_artifacts
        ; test_case "measurement does not name identity" `Quick
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
        ; test_case "large selection preserves answer identity" `Quick
            test_large_selection_projection_keeps_answer_identity
        ; test_case "a manifest-wrapped execute keeps identity" `Quick
            test_a_manifest_wrapped_execute_keeps_identity
        ; test_case "a third memory rewrite stops the turn" `Quick
            test_a_third_memory_rewrite_stops_the_turn
        ; test_case "memory identity survives changing inputs" `Quick
            test_memory_identity_survives_changing_inputs
        ; test_case "a stored memory rewrite keeps memory identity" `Quick
            test_a_stored_memory_rewrite_keeps_memory_identity
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
