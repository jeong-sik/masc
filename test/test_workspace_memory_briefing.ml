module B = Masc.Workspace_memory_briefing
let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let batch = function Some batch -> batch | None -> Alcotest.fail "expected briefing work"
let source ?(kind = B.Claim) id text : B.source = { id; kind; text }
let render input = Ok ("Summarize workspace evidence:\n" ^ Yojson.Safe.to_string input)
let prepare ?(contract = "fixture-prompt-and-schema") sources state =
  get (B.prepare ~sources ~contract ~render state)
let after_size_refusal request = batch (get (B.narrow ~render request))
let finish ?contract sources text state =
  get (B.accept (batch (prepare ?contract sources state)) ~text)
let member name = function
  | `Assoc fields -> List.assoc name fields
  | _ -> Alcotest.fail "expected object"
let previous batch = member "previous_summary" (B.input batch)
let entry_ids batch = match member "entries" (B.input batch) with
  | `List entries -> List.map (fun row -> match member "id" row with
      | `String id -> id | _ -> Alcotest.fail "expected source id") entries
  | _ -> Alcotest.fail "expected entries"
let expect_current sources state text = match B.observe ~sources state with
  | B.Current summary -> Alcotest.(check string) "published summary" text summary.text
  | B.Missing | B.Stale _ -> Alcotest.fail "expected current briefing"
let expect_stale sources state text = match B.observe ~sources state with
  | B.Stale summary -> Alcotest.(check string) "last publication survives" text summary.text
  | B.Missing | B.Current _ -> Alcotest.fail "expected stale briefing"
let with_directory f =
  let directory = Filename.temp_dir "workspace-briefing" "" in
  Fun.protect ~finally:(fun () ->
    Array.iter (fun name -> Sys.remove (Filename.concat directory name)) (Sys.readdir directory);
    Unix.rmdir directory) (fun () -> f directory)
let write path text = Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc text)

let test_shared_summary_reuse () =
  let sources = [source "a" "The report is complete"; source ~kind:B.Conflict "b" "Deployment date is disputed"] in
  (match B.observe ~sources B.empty with B.Missing -> () | _ -> Alcotest.fail "missing became available");
  let state = finish sources "Report complete; deployment date remains disputed." B.empty in
  (* Different Keepers get the same complete publication, in either source order. *)
  List.iter (fun sources ->
    expect_current sources state "Report complete; deployment date remains disputed.";
    Alcotest.(check bool) "provider admission is unnecessary" false
      (B.needs_refresh ~sources ~contract:"fixture-prompt-and-schema" state);
    let result = B.prepare ~sources ~contract:"fixture-prompt-and-schema"
      ~render:(fun _ -> Alcotest.fail "current briefing was rendered") state in
    match get result with None -> () | Some _ -> Alcotest.fail "current briefing called model")
    [sources; List.rev sources];
  expect_current [] state "";
  (match prepare [] state with None -> () | Some _ -> Alcotest.fail "empty ledger called model")

let test_additions_deletions_and_changed_contract () =
  let a = source "a" "Report complete" and b = source "b" "Deployment pending" in
  let published = finish [a] "Report complete." B.empty in
  let add = batch (prepare [b; a] published) in
  Alcotest.(check (list string)) "only addition sent" ["b"] (entry_ids add);
  Alcotest.(check bool) "old prose reused" true (previous add = `String "Report complete.");
  let both = get (B.accept add ~text:"Report complete; deployment pending.") in
  expect_current [a; b] both "Report complete; deployment pending.";
  let delete = batch (prepare [b] both) in
  Alcotest.(check bool) "removed claim is not in the prior summary" true (previous delete = `Null);
  Alcotest.(check (list string)) "rebuild from remaining source" ["b"] (entry_ids delete);
  let changed = { b with text = "Deployment complete" } in
  expect_stale [a; changed] both "Report complete; deployment pending.";
  let rebuild = batch (prepare [a; changed] both) in
  Alcotest.(check bool) "same id with changed text rebuilds" true (previous rebuild = `Null);
  let changed_kind = { b with kind = B.Conflict } in
  expect_stale [a; changed_kind] both "Report complete; deployment pending.";
  let contract = batch (prepare ~contract:"revised-prompt-and-schema" [a; b] both) in
  Alcotest.(check bool) "contract change rebuilds" true (previous contract = `Null);
  Alcotest.(check (list string)) "contract rebuild sees all sources" ["a"; "b"] (entry_ids contract)

let test_fixed_pass_survives_restart_and_new_additions () = with_directory (fun directory ->
  let a = source "a" "First entry" and b = source "b" "Other entry" and c = source "c" "Third entry" in
  let first = after_size_refusal (batch (prepare [a; b] B.empty)) in
  Alcotest.(check int) "first chunk selected" 1 (B.selected_count first);
  Alcotest.(check int) "one remains" 1 (B.remaining_count first);
  get (B.save ~directory (B.prepared_state first));
  let restored = get (B.load ~directory) in
  let retry_all = batch (prepare [a; b; c] restored) in
  Alcotest.(check (list string)) "unanswered target survives restart" ["a"; "b"] (entry_ids retry_all);
  let retry = after_size_refusal retry_all in
  Alcotest.(check (list string)) "unanswered chunk retried after restart" ["a"] (entry_ids retry);
  Alcotest.(check int) "new addition did not move the fixed target" 1 (B.remaining_count retry);
  let partial = get (B.accept retry ~text:"A") in
  get (B.save ~directory partial);
  (match B.observe ~sources:[a; b] (get (B.load ~directory)) with
   | B.Missing -> () | _ -> Alcotest.fail "partial summary leaked as publication");
  let next = batch (prepare [a; b; c] (get (B.load ~directory))) in
  Alcotest.(check (list string)) "consumed raw entry not replayed" ["b"] (entry_ids next);
  Alcotest.(check bool) "semantic partial summary reused" true (previous next = `String "A");
  let finished = get (B.accept next ~text:"AB") in
  get (B.save ~directory finished);
  let finished = get (B.load ~directory) in
  expect_current [a; b] finished "AB";
  expect_stale [a; b; c] finished "AB";
  let addition = batch (prepare [a; b; c] finished) in
  Alcotest.(check (list string)) "later pass consumes new addition" ["c"] (entry_ids addition);
  let all = get (B.accept addition ~text:"ABC") in
  get (B.save ~directory all);
  expect_current [a; b; c] (get (B.load ~directory)) "ABC")

let test_interrupted_refresh_keeps_publication_and_deletion_resets () = with_directory (fun directory ->
  let a = source "a" "First entry" and b = source "b" "Other entry" and c = source "c" "Third entry" in
  let old = finish [a] "A" B.empty in
  let update = after_size_refusal (batch (prepare [a; b; c] old)) in
  get (B.save ~directory (B.prepared_state update));
  (* Invalid model output leaves the persisted pass and old summary intact. *)
  (match B.accept update ~text:" \n" with Error _ -> () | Ok _ -> Alcotest.fail "blank output consumed evidence");
  let restored = get (B.load ~directory) in
  expect_stale [a; b; c] restored "A";
  let partial = get (B.accept (after_size_refusal (batch (prepare [a; b; c] restored))) ~text:"AB") in
  get (B.save ~directory partial);
  let reset = batch (prepare [b; c] (get (B.load ~directory))) in
  Alcotest.(check bool) "deleted consumed source invalidates partial prose" true (previous reset = `Null);
  Alcotest.(check (list string)) "remaining current sources rebuilt" ["b"; "c"] (entry_ids reset);
  let changed_b = { b with text = "Edited entry" } in
  let changed = batch (prepare [a; changed_b; c] partial) in
  Alcotest.(check bool) "changed pass source invalidates partial prose" true (previous changed = `Null))

let test_strict_storage_and_output () = with_directory (fun directory ->
  let sources = [source "a" "Evidence"] in
  (match B.observe ~sources (get (B.load ~directory)) with B.Missing -> () | _ -> Alcotest.fail "missing artifact was not empty");
  let state = finish sources "Summary" B.empty in
  get (B.save ~directory state);
  get (B.save ~directory (finish (source "b" "More evidence" :: sources) "Updated" state));
  expect_current (source "b" "More evidence" :: sources) (get (B.load ~directory)) "Updated";
  let path = B.path ~directory in
  let valid = In_channel.with_open_bin path In_channel.input_all |> Yojson.Safe.from_string in
  let malformed = match valid with
    | `Assoc fields -> `Assoc (("schema", `String "workspace.memory.briefing.v1") :: fields)
    | _ -> Alcotest.fail "state object" in
  write path (Yojson.Safe.to_string malformed);
  (match B.load ~directory with Error _ -> () | Ok _ -> Alcotest.fail "duplicate fields were accepted");
  write path "{";
  (match B.load ~directory with Error _ -> () | Ok _ -> Alcotest.fail "truncated artifact became empty");
  let error = B.save ~directory:path state in
  (match error with Error _ -> () | Ok () -> Alcotest.fail "non-directory storage was accepted");
  List.iter (fun json -> match B.decode_output json with
    | Error _ -> () | Ok _ -> Alcotest.fail "malformed output accepted")
    [`Assoc ["briefing", `String " "]; `Assoc ["briefing", `String "x"; "extra", `Null];
     `Assoc ["briefing", `String "x"; "briefing", `String "y"]];
  Alcotest.(check string) "strict model answer" "Valid summary"
    (get (B.decode_output (`Assoc ["briefing", `String "Valid summary"]))))

let test_actual_refusal_narrows_without_losing_entries () =
  let prior = source "prior" "Already summarized evidence" in
  let published = finish [prior] "Existing semantic summary" B.empty in
  let entries = List.map (fun id -> source id ("Uncut source: " ^ id ^ "\n확인할 원문 전체"))
    ["a"; "b"; "c"; "d"; "e"] in
  let sources = prior :: entries in
  let full = batch (prepare sources published) in
  Alcotest.(check (list string)) "prepare offers all remaining entries"
    ["a"; "b"; "c"; "d"; "e"] (entry_ids full);
  Alcotest.(check string) "rendered request is the complete input"
    (get (render (B.input full))) (B.rendered_prompt full);
  let half = after_size_refusal full in
  Alcotest.(check (list string)) "first refusal selects whole prefix" ["a"; "b"] (entry_ids half);
  Alcotest.(check int) "first suffix retained" 3 (B.remaining_count half);
  let single = after_size_refusal half in
  Alcotest.(check (list string)) "second refusal selects one entry" ["a"] (entry_ids single);
  Alcotest.(check int) "suffix prepended to earlier remainder" 4 (B.remaining_count single);
  Alcotest.(check bool) "previous semantic summary unchanged" true
    (previous single = `String "Existing semantic summary");
  Alcotest.(check bool) "whole source text preserved" true
    (member "entries" (B.input single) = `List [
      `Assoc ["id", `String "a"; "kind", `String "claim";
              "text", `String (List.hd entries).text]]);
  (match get (B.narrow ~render:(fun _ -> Alcotest.fail "single entry was rendered again") single) with
   | None -> () | Some _ -> Alcotest.fail "single entry was truncated or repeated");
  (* Refusal is not consumption. A restart still has the entire original pass. *)
  let retry = batch (prepare sources (B.prepared_state single)) in
  Alcotest.(check (list string)) "refused evidence is still pending"
    ["a"; "b"; "c"; "d"; "e"] (entry_ids retry);
  (match B.narrow ~render:(fun _ -> Error "template unavailable") full with
   | Error "template unavailable" -> () | _ -> Alcotest.fail "narrow render error hidden");
  let partial = get (B.accept single ~text:"Prior plus A") in
  expect_stale sources partial "Existing semantic summary";
  let next = batch (prepare sources partial) in
  Alcotest.(check (list string)) "all split suffixes resume in order"
    ["b"; "c"; "d"; "e"] (entry_ids next);
  expect_current sources (get (B.accept next ~text:"All evidence summarized")) "All evidence summarized"

let test_invalid_sources_and_render_failure_do_not_consume () =
  let a = source "a" "Complete uncut source" in
  (match B.prepare ~sources:[a; a] ~contract:"fixture" ~render B.empty with
   | Error _ -> () | Ok _ -> Alcotest.fail "duplicate source identity accepted");
  (match B.prepare ~sources:[a] ~contract:"fixture"
      ~render:(fun _ -> Error "template unavailable") B.empty with
   | Error "template unavailable" -> () | _ -> Alcotest.fail "render failure hidden")

let () = Alcotest.run "Workspace memory briefing"
  ["behavior", [
     Alcotest.test_case "one shared publication avoids repeated model work" `Quick test_shared_summary_reuse;
     Alcotest.test_case "additions reuse; deletion and contract changes rebuild" `Quick test_additions_deletions_and_changed_contract;
     Alcotest.test_case "fixed pass resumes and eventually publishes under additions" `Quick test_fixed_pass_survives_restart_and_new_additions;
     Alcotest.test_case "failed refresh preserves old publication and removal resets" `Quick test_interrupted_refresh_keeps_publication_and_deletion_resets;
     Alcotest.test_case "strict storage and model output" `Quick test_strict_storage_and_output;
     Alcotest.test_case "actual refusal bisects without losing whole entries" `Quick test_actual_refusal_narrows_without_losing_entries;
     Alcotest.test_case "invalid source and render failure boundary" `Quick test_invalid_sources_and_render_failure_do_not_consume]]
