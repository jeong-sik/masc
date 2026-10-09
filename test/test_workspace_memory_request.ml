module Ledger = Masc.Workspace_memory_ledger
module Request = Masc.Workspace_memory_request
module Decision = Masc.Workspace_memory_decision

let sha claim = Digestif.SHA256.(digest_string claim |> to_hex)
let pending keeper claim : Ledger.pending_fact =
  { fact = Ledger.Ordinary { keeper_id = keeper; claim_sha256 = sha claim }; claim }
let sourced keeper path claim : Ledger.pending_fact =
  { fact = Ledger.Source_bound { keeper_id = keeper; path; claim_sha256 = sha claim }; claim }
let render json = Ok ("Curate changed facts:\n" ^ Yojson.Safe.to_string json)
let request ~neighbors ~current pending =
  Request.prepare ~neighbor_limit:neighbors ~render
    ~ledger:Ledger.empty ~current ~pending

let get = function
  | Ok (Some batch) -> batch
  | Ok None -> Alcotest.fail "expected a request"
  | Error error -> Alcotest.fail (Request.error_to_string error)

let test_changed_facts_are_complete_and_refusals_preserve_remainder () =
  let first = pending "writer" "The report has twelve pages" in
  let second = sourced "writer" "notes/b.md" "Deployment finished on Friday" in
  let other = pending "reviewer" "The report has ten pages" in
  let current = [first; second; other] in
  let renders = ref 0 in
  let full = get (Request.prepare ~neighbor_limit:1
    ~render:(fun json -> incr renders; render json) ~ledger:Ledger.empty
    ~current ~pending:[first; second]) in
  Alcotest.(check int) "all pending facts are selected" 2 (List.length full.selected);
  Alcotest.(check int) "complete input rendered once" 1 !renders;
  Alcotest.(check int) "no omitted evidence before provider refusal" 0 (List.length full.remaining);
  let narrowed = get (Request.narrow ~render full) in
  Alcotest.(check bool) "first whole row selected" true (narrowed.selected = [first]);
  Alcotest.(check bool) "source-bound suffix retained" true (narrowed.remaining = [second]);
  Alcotest.(check int) "one index for all pending queries" 1 narrowed.index_stats.index_builds;
  Alcotest.(check int) "all current facts entered once" 3 narrowed.index_stats.indexed_rows;
  Alcotest.(check int) "every pending query searched" 2 narrowed.index_stats.queries_executed;
  let neighbors = match narrowed.input with
    | `Assoc ["new_facts", `List [`Assoc fields]] ->
      (match List.assoc_opt "neighbors" fields with Some (`List values) -> values | _ -> [])
    | _ -> Alcotest.fail "request input shape" in
  Alcotest.(check int) "other Keeper is the only neighbor" 1 (List.length neighbors);
  (match Request.narrow ~render:(fun _ -> Alcotest.fail "single row rendered again") narrowed with
   | Ok None -> () | _ -> Alcotest.fail "indivisible fact was dropped or truncated");
  (match Request.narrow ~render { full with selected = List.rev full.selected } with
   | Error (Request.Invalid_batch _) -> () | _ -> Alcotest.fail "mismatched public batch was accepted");
  (match Request.narrow ~render { full with input = `Assoc ["new_facts", `List []] } with
   | Error (Request.Invalid_batch _) -> () | _ -> Alcotest.fail "missing rows were accepted");
  (match Request.narrow ~render:(fun _ -> Error "render unavailable") full with
   | Error (Request.Render_failed _) -> () | _ -> Alcotest.fail "narrow render failure hidden")

let test_no_change_does_not_render_or_search () =
  let render_calls = ref 0 in
  let result = Request.prepare ~neighbor_limit:2
      ~render:(fun json -> incr render_calls; render json)
      ~ledger:Ledger.empty ~current:[pending "writer" "a fact"] ~pending:[] in
  (match result with Ok None -> () | _ -> Alcotest.fail "no change built a request");
  Alcotest.(check int) "render was not called" 0 !render_calls

let test_many_facts_drain_after_repeated_size_refusals () =
  let facts = List.init 100 (fun i -> pending ("keeper-" ^ string_of_int i)
      ("A changed claim number " ^ string_of_int i)) in
  let rec narrow_to_single batch =
    match Request.narrow ~render batch with
    | Ok None -> batch
    | Ok (Some smaller) -> narrow_to_single smaller
    | Error error -> Alcotest.fail (Request.error_to_string error) in
  let rec drain selected remaining =
    match remaining with
    | [] -> selected
    | _ ->
      let batch = narrow_to_single (get (request ~neighbors:0 ~current:facts remaining)) in
      Alcotest.(check int) "provider-refused batch reaches one complete fact" 1 (List.length batch.selected);
      drain (selected @ batch.selected) batch.remaining in
  Alcotest.(check bool) "every split suffix is eventually selected in original order" true
    (drain [] facts = facts)

let test_model_answer_applies_only_to_selected_facts () =
  let first = pending "writer" "The report has twelve pages" in
  let second = sourced "reviewer" "notes/a.md" "The report has ten pages" in
  let selected = [first; second] in
  let row (fact : Ledger.pending_fact) kind value = `Assoc
    ["fact_id", `String (Request.fact_id fact.fact);
     "kind", `String kind; "value", `String value] in
  let answer rows = `Assoc ["decisions", `List rows] in
  let valid = answer [row first "create_conflict" "Page counts disagree";
                      row second "create_conflict" "Page counts disagree"] in
  let assignments = match Decision.decode ~selected valid with
    | Ok values -> values | Error detail -> Alcotest.fail detail in
  let ledger = match Ledger.apply Ledger.empty ~selected assignments with
    | Ok ledger -> ledger
    | Error error -> Alcotest.fail (Ledger.apply_error_to_string error) in
  Alcotest.(check int) "one conflict has both fact members" 1
    (List.length (Ledger.conflicts ledger));
  Alcotest.(check int) "both facts are disposed" 2
    (List.length (Ledger.dispositions ledger));
  let refused label raw = match Decision.decode ~selected raw with
    | Ok _ -> Alcotest.fail (label ^ " was accepted")
    | Error _ -> () in
  refused "unknown fact" (answer [row (pending "stranger" "no") "exclude" "out of scope";
                                  row second "exclude" "out of scope"]);
  refused "duplicate fact" (answer [row first "exclude" "one"; row first "exclude" "two"]);
  refused "missing fact" (answer [row first "exclude" "one"]);
  refused "unknown action" (answer [row first "magic" "one"; row second "exclude" "two"])

let test_related_ledger_context_remains_in_the_whole_row () =
  let open Yojson.Safe.Util in
  let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal in
  let changed = pending "writer" "Release evidence is ready" in
  (* Equal claim text gives equal BM25 ranks, so current-store order breaks
     ties. Two source paths are separate facts but share one ledger claim. *)
  let left = sourced "reviewer" "notes/left.md" changed.claim in
  let right = sourced "reviewer" "notes/right.md" changed.claim in
  let disputed = pending "auditor" changed.claim in
  let unrelated = pending "archivist" "Old meeting notes" in
  let fact_fields (fact : Ledger.pending_fact) =
    match fact.fact with
    | Ledger.Ordinary { keeper_id; claim_sha256 } ->
      ["keeper_id", `String keeper_id; "store", `String "ordinary";
       "claim_sha256", `String claim_sha256]
    | Ledger.Source_bound { keeper_id; path; claim_sha256 } ->
      ["keeper_id", `String keeper_id; "store", `String "source_bound";
       "path", `String path; "claim_sha256", `String claim_sha256]
  in
  let ledger_member fact kind id_field id =
    `Assoc (fact_fields fact @ ["disposition",
      `Assoc ["kind", `String kind; id_field, `String id]]) in
  let shared = `Assoc ["claim_id", `String "c-release";
                       "claim", `String "The release evidence is ready"] in
  (* Related ledger prose stays with the complete row even when a provider
     refuses it. Narrowing cannot discard a conflicting source. *)
  let conflict = `Assoc ["conflict_id", `String "x-release";
    "description", `String ("Conflicting release evidence: " ^ String.make 2048 'x')] in
  let ledger_json = `Assoc [
    "schema", `String "workspace.memory.ledger.v1";
    "claims", `List [shared; `Assoc ["claim_id", `String "c-unrelated";
                                    "claim", `String unrelated.claim]];
    "conflicts", `List [conflict];
    "facts", `List [ledger_member left "claim" "claim_id" "c-release";
                    ledger_member right "claim" "claim_id" "c-release";
                    ledger_member disputed "conflict" "conflict_id" "x-release";
                    ledger_member unrelated "claim" "claim_id" "c-unrelated"]] in
  let ledger = match Ledger.of_json ledger_json with
    | Ok ledger -> ledger
    | Error detail -> Alcotest.fail detail in
  let second = pending "writer" "A second changed fact" in
  let current = [changed; left; right; disputed; unrelated; second] in
  let prepare pending =
    get (Request.prepare ~neighbor_limit:3 ~render ~ledger ~current ~pending) in
  let only_row (batch : Request.batch) =
    match batch.input |> member "new_facts" |> to_list with
    | [row] -> row
    | _ -> Alcotest.fail "one changed fact must produce exactly one request row" in
  let neighbor (fact : Ledger.pending_fact) =
    `Assoc ["id", `String (Request.fact_id fact.fact);
            "fact", `Assoc (fact_fields fact); "claim", `String fact.claim] in
  let full = prepare [changed] in
  let full_row = only_row full in
  Alcotest.check json "both source paths and the conflicting fact remain attributed"
    (`List [neighbor left; neighbor right; neighbor disputed]) (member "neighbors" full_row);
  Alcotest.check json "shared ledger claim appears once, unrelated claim stays out"
    (`List [shared]) (member "related_claims" full_row);
  Alcotest.check json "conflict description accompanies its member"
    (`List [conflict]) (member "related_conflicts" full_row);
  let combined = prepare [changed; second] in
  let narrowed = get (Request.narrow ~render combined) in
  Alcotest.check json "whole row retains neighbors, shared claim, and conflict"
    full.input narrowed.input;
  Alcotest.(check string) "rendered prompt matches the complete attributed row"
    (match render narrowed.input with
     | Ok rendered -> rendered
     | Error detail -> Alcotest.fail detail) narrowed.rendered_prompt;
  Alcotest.(check bool) "changed fact and untouched suffix remain attributed" true
    (narrowed.selected = [changed] && narrowed.remaining = [second]);
  Alcotest.(check int) "narrowing does not rebuild the current-fact index" 1
    narrowed.index_stats.index_builds;
  (match Request.narrow ~render narrowed with
   | Ok None -> () | _ -> Alcotest.fail "single row lost related ledger context")

let () =
  Alcotest.run "Workspace memory request"
    [ "provider refusal", [Alcotest.test_case "neighbors and remainder" `Quick
                            test_changed_facts_are_complete_and_refusals_preserve_remainder
                          ; Alcotest.test_case "no change is silent" `Quick
                            test_no_change_does_not_render_or_search
                          ; Alcotest.test_case "many changes drain" `Quick
                            test_many_facts_drain_after_repeated_size_refusals
                          ; Alcotest.test_case "model answer changes selected facts only" `Quick
                            test_model_answer_applies_only_to_selected_facts
                          ; Alcotest.test_case "whole rows preserve all related context" `Quick
                            test_related_ledger_context_remains_in_the_whole_row] ]
