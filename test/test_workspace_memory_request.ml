module Ledger = Masc.Workspace_memory_ledger
module Request = Masc.Workspace_memory_request
module Decision = Masc.Workspace_memory_decision

let sha claim = Digestif.SHA256.(digest_string claim |> to_hex)
let pending keeper claim : Ledger.pending_fact =
  { fact = Ledger.Ordinary { keeper_id = keeper; claim_sha256 = sha claim }; claim }
let sourced keeper path claim : Ledger.pending_fact =
  { fact = Ledger.Source_bound { keeper_id = keeper; path; claim_sha256 = sha claim }; claim }
let render json = Ok ("Curate changed facts:\n" ^ Yojson.Safe.to_string json)
let request ~limit ~neighbors ~current pending =
  Request.prepare ~max_input_bytes:limit ~neighbor_limit:neighbors ~render
    ~ledger:Ledger.empty ~current ~pending

let get = function
  | Ok (Some batch) -> batch
  | Ok None -> Alcotest.fail "expected a request"
  | Error error -> Alcotest.fail (Request.error_to_string error)

let test_changed_facts_are_bounded_and_preserve_remainder () =
  let first = pending "writer" "The report has twelve pages" in
  let second = sourced "writer" "notes/b.md" "Deployment finished on Friday" in
  let other = pending "reviewer" "The report has ten pages" in
  let current = [first; second; other] in
  let full = get (request ~limit:100_000 ~neighbors:1 ~current [first; second]) in
  Alcotest.(check int) "all new facts fit at large limit" 2 (List.length full.selected);
  let first_only = get (request ~limit:100_000 ~neighbors:1 ~current [first]) in
  let limit = String.length first_only.rendered_prompt in
  let bounded = get (request ~limit ~neighbors:1 ~current [first; second]) in
  Alcotest.(check int) "one selected" 1 (List.length bounded.selected);
  Alcotest.(check int) "one remains" 1 (List.length bounded.remaining);
  Alcotest.(check bool) "first is selected" true (List.hd bounded.selected = first);
  Alcotest.(check bool) "source-bound identity remains" true (List.hd bounded.remaining = second);
  Alcotest.(check bool) "complete rendered prompt fits" true
    (String.length bounded.rendered_prompt <= limit);
  Alcotest.(check int) "one index for the selected request" 1
    bounded.index_stats.index_builds;
  Alcotest.(check int) "all current facts entered once" 3
    bounded.index_stats.indexed_rows;
  let neighbors = match bounded.input with
    | `Assoc ["new_facts", `List [`Assoc fields]] ->
      (match List.assoc_opt "neighbors" fields with Some (`List values) -> values | _ -> [])
    | _ -> Alcotest.fail "request input shape" in
  Alcotest.(check int) "other Keeper is the only neighbor" 1 (List.length neighbors);
  let tiny = request ~limit:1 ~neighbors:1 ~current [first] in
  (match tiny with Error (Request.Fact_exceeds_limit fact) ->
     Alcotest.(check bool) "first oversized fact is named" true (fact = first.fact)
   | _ -> Alcotest.fail "oversized first fact was silently skipped")

let test_no_change_does_not_render_or_search () =
  let render_calls = ref 0 in
  let result = Request.prepare ~max_input_bytes:1024 ~neighbor_limit:2
      ~render:(fun json -> incr render_calls; render json)
      ~ledger:Ledger.empty ~current:[pending "writer" "a fact"] ~pending:[] in
  (match result with Ok None -> () | _ -> Alcotest.fail "no change built a request");
  Alcotest.(check int) "render was not called" 0 !render_calls

let test_many_facts_drain_in_bounded_requests () =
  let facts = List.init 100 (fun i -> pending ("keeper-" ^ string_of_int i)
      ("A changed claim number " ^ string_of_int i)) in
  let rec drain selected remaining =
    match remaining with
    | [] -> selected
    | _ ->
      let batch = get (request ~limit:430 ~neighbors:0 ~current:facts remaining) in
      Alcotest.(check bool) "batch has an admitted fact" true (batch.selected <> []);
      Alcotest.(check bool) "rendered request stays bounded" true
        (String.length batch.rendered_prompt <= 430);
      drain (selected @ batch.selected) batch.remaining
  in
  Alcotest.(check bool) "every fact is eventually selected in order" true
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

let () =
  Alcotest.run "Workspace memory request"
    [ "bounded change", [Alcotest.test_case "neighbors and remainder" `Quick
                            test_changed_facts_are_bounded_and_preserve_remainder
                          ; Alcotest.test_case "no change is silent" `Quick
                            test_no_change_does_not_render_or_search
                          ; Alcotest.test_case "many changes drain" `Quick
                            test_many_facts_drain_in_bounded_requests
                          ; Alcotest.test_case "model answer changes selected facts only" `Quick
                            test_model_answer_applies_only_to_selected_facts] ]
