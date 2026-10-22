module Ledger = Masc.Workspace_memory_ledger
module Request = Masc.Workspace_memory_request
module Decision = Masc.Workspace_memory_decision

let sha claim = Digestif.SHA256.(digest_string claim |> to_hex)
let pending keeper claim : Ledger.pending_fact =
  { fact = Ledger.Ordinary { keeper_id = keeper; claim_sha256 = sha claim }; claim }
let sourced keeper path claim : Ledger.pending_fact =
  { fact = Ledger.Source_bound { keeper_id = keeper; path; claim_sha256 = sha claim }; claim }
let render json = Ok ("Curate changed facts:\n" ^ Yojson.Safe.to_string json)
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let member = Yojson.Safe.Util.member
let to_list = Yojson.Safe.Util.to_list

let get = function
  | Ok (Some batch) -> batch
  | Ok None -> Alcotest.fail "expected a request"
  | Error error -> Alcotest.fail (Request.error_to_string error)

let ledger_of json = match Ledger.of_json json with
  | Ok ledger -> ledger
  | Error detail -> Alcotest.fail detail

let fact_fields (fact : Ledger.pending_fact) =
  match fact.fact with
  | Ledger.Ordinary { keeper_id; claim_sha256 } ->
    ["keeper_id", `String keeper_id; "store", `String "ordinary"; "claim_sha256", `String claim_sha256]
  | Ledger.Source_bound { keeper_id; path; claim_sha256 } ->
    ["keeper_id", `String keeper_id; "store", `String "source_bound";
     "path", `String path; "claim_sha256", `String claim_sha256]
let ledger_member fact kind id_field id =
  `Assoc (fact_fields fact @ ["disposition", `Assoc ["kind", `String kind; id_field, `String id]])

(* Two Keepers' new facts share one neighbor that is already a member of a
   shared claim, and one neighbor sits in a conflict. *)
let changed = pending "writer" "Release evidence is ready"
let second = sourced "auditor" "notes/release.md" "Release evidence is ready"
let shared = sourced "reviewer" "notes/left.md" changed.claim
let disputed = pending "archivist" changed.claim
let unrelated = pending "planner" "Old meeting notes"
let third = pending "treasurer" "Quarterly budget draft is open"
let ledger = ledger_of (`Assoc [
  "schema", `String "workspace.memory.ledger.v1";
  "claims", `List [`Assoc ["claim_id", `String "c-release"; "claim", `String "The release evidence is ready"];
                   `Assoc ["claim_id", `String "c-unrelated"; "claim", `String unrelated.claim]];
  "conflicts", `List [`Assoc ["conflict_id", `String "x-release";
                              "description", `String "Conflicting release evidence"]];
  "facts", `List [ledger_member shared "claim" "claim_id" "c-release";
                  ledger_member disputed "conflict" "conflict_id" "x-release";
                  ledger_member unrelated "claim" "claim_id" "c-unrelated"]])
let current = [changed; second; shared; disputed; unrelated; third]
(* Three other Keepers hold the same claim text, so a limit of three takes
   exactly those; the unrelated fact never becomes a neighbor. *)
let prepare ?(neighbors = 3) pending =
  get (Request.prepare ~neighbor_limit:neighbors ~render ~ledger ~current ~pending
         ~frame:max_int ~measure:(fun _ -> Ok 0))

let ids_of field batch = batch.Request.input |> member field |> to_list |> List.map (member "id")
let contains ~sub text =
  let n = String.length sub and m = String.length text in
  let rec at i = i + n <= m && (String.equal (String.sub text i n) sub || at (i + 1)) in
  at 0
let local_id batch (fact : Ledger.pending_fact) =
  match List.find_opt (fun (_, (selected : Ledger.pending_fact)) -> selected = fact) (Request.selected_ids batch) with
  | Some (id, _) -> id
  | None -> Alcotest.fail "selected fact has no local id"

let test_each_fact_and_entry_is_listed_once () =
  let batch = prepare [changed; second] in
  let facts = ids_of "facts" batch in
  Alcotest.(check int) "two new facts and two shared neighbors, each listed once" 4 (List.length facts);
  Alcotest.(check int) "no id repeats" 4 (List.length (List.sort_uniq compare facts));
  let shared_id = batch.input |> member "facts" |> to_list |> List.filter (fun fact ->
      member "keeper" fact = `String "reviewer") |> List.map (member "id") in
  Alcotest.(check int) "the neighbor both rows share has one entry" 1 (List.length shared_id);
  List.iter (fun row ->
    Alcotest.(check bool) "each row names the shared neighbor by that one id" true
      (List.mem (List.hd shared_id) (member "neighbors" row |> to_list)))
    (batch.input |> member "new_facts" |> to_list);
  Alcotest.check (Alcotest.list json) "the referenced claim is listed once, the unrelated one never"
    [`Assoc ["id", `String "c1"; "claim", `String "The release evidence is ready"]]
    (batch.input |> member "claims" |> to_list);
  Alcotest.check (Alcotest.list json) "the conflict is listed once with its description"
    [`Assoc ["id", `String "x1"; "description", `String "Conflicting release evidence"]]
    (batch.input |> member "conflicts" |> to_list);
  let text = Yojson.Safe.to_string batch.input in
  List.iter (fun (fact : Ledger.pending_fact) ->
    match fact.fact with
    | Ledger.Ordinary { claim_sha256; _ } | Ledger.Source_bound { claim_sha256; _ } ->
      Alcotest.(check bool) "ledger hashes stay in the host snapshot" false (contains ~sub:claim_sha256 text))
    current;
  Alcotest.(check (list string)) "selected facts carry short ids, oldest first" ["f1"; "f2"]
    (List.map fst (Request.selected_ids batch))

let test_narrow_keeps_the_oldest_half_and_its_context () =
  let batch = prepare [changed; second; third] in
  let narrowed = match Request.narrow ~render ~ledger batch with
    | Ok (Some narrowed) -> narrowed
    | Ok None -> Alcotest.fail "a three-row batch was indivisible"
    | Error error -> Alcotest.fail (Request.error_to_string error) in
  Alcotest.(check bool) "the oldest row stays" true (narrowed.selected = [changed]);
  Alcotest.(check bool) "neighbors stay whole" true
    ((List.hd narrowed.rows).neighbors = (List.hd batch.rows).neighbors);
  Alcotest.(check bool) "only facts the kept row references are listed" true
    (List.length (ids_of "facts" narrowed) = 1 + List.length (List.hd narrowed.rows).neighbors);
  (match Request.narrow ~render ~ledger batch with
   | Ok (Some again) -> Alcotest.check json "one parent always yields the same child"
                          (Request.batch_to_json narrowed) (Request.batch_to_json again)
   | Ok None | Error _ -> Alcotest.fail "narrowing the same parent changed");
  Alcotest.(check int) "narrowing does not rebuild the index"
    batch.index_stats.index_builds narrowed.index_stats.index_builds;
  (match Request.narrow ~render:(fun _ -> Alcotest.fail "single row rendered again") ~ledger narrowed with
   | Ok None -> () | Ok (Some _) | Error _ -> Alcotest.fail "indivisible fact was dropped or truncated");
  (match Request.narrow ~render:(fun _ -> Error "render unavailable") ~ledger batch with
   | Error (Request.Render_failed _) -> ()
   | Ok _ | Error (Request.Invalid_limit | Index_unavailable _ | Invalid_batch _ | Measure_failed _
                  | Exceeds_frame _) ->
     Alcotest.fail "narrow render failure hidden")

let test_no_change_does_not_render_or_search () =
  let render_calls = ref 0 in
  let result = Request.prepare ~neighbor_limit:2
      ~render:(fun json -> incr render_calls; render json)
      ~ledger:Ledger.empty ~current:[pending "writer" "a fact"] ~pending:[]
      ~frame:max_int ~measure:(fun _ -> Ok 0) in
  (match result with Ok None -> () | Ok (Some _) | Error _ -> Alcotest.fail "no change built a request");
  Alcotest.(check int) "render was not called" 0 !render_calls

let test_many_facts_drain_oldest_first_after_size_refusals () =
  let facts = List.init 40 (fun i -> pending ("keeper-" ^ string_of_int i)
      ("A changed claim number " ^ string_of_int i)) in
  let rec narrow_to_single batch =
    match Request.narrow ~render ~ledger:Ledger.empty batch with
    | Ok None -> batch
    | Ok (Some smaller) -> narrow_to_single smaller
    | Error error -> Alcotest.fail (Request.error_to_string error) in
  let rec drain classified remaining =
    match remaining with
    | [] -> List.rev classified
    | _ :: _ ->
      let batch = narrow_to_single (get (Request.prepare ~neighbor_limit:0 ~render ~ledger:Ledger.empty
        ~current:facts ~pending:remaining ~frame:max_int ~measure:(fun _ -> Ok 0))) in
      (match batch.selected with
       | [fact] -> drain (fact :: classified) (List.filter (fun other -> other <> fact) remaining)
       | [] | _ :: _ :: _ -> Alcotest.fail "a provider-refused batch must reach one complete fact") in
  Alcotest.(check bool) "every fact is classified, oldest first" true (drain [] facts = facts)

let test_model_answer_uses_request_local_ids () =
  let batch = prepare [changed; second] in
  let id_of = local_id batch in
  let row id kind value = `Assoc ["fact_id", `String id; "kind", `String kind; "value", `String value] in
  let answer rows = `Assoc ["decisions", `List rows] in
  let valid = answer [row (id_of changed) "join_claim" "c1"; row (id_of second) "join_conflict" "x1"] in
  let assignments = match Decision.decode ~batch valid with
    | Ok values -> values | Error detail -> Alcotest.fail detail in
  Alcotest.(check bool) "local ids map back to ledger identities" true
    (assignments = [{ Ledger.fact = changed.fact; decision = Ledger.Join_claim "c-release" };
                    { fact = second.fact; decision = Ledger.Join_conflict "x-release" }]);
  (match Ledger.apply ledger ~selected:batch.selected assignments with
   | Ok applied -> Alcotest.(check int) "both facts are disposed" 5 (List.length (Ledger.dispositions applied))
   | Error error -> Alcotest.fail (Ledger.apply_error_to_string error));
  let refused label raw = match Decision.decode ~batch raw with
    | Ok _ -> Alcotest.fail (label ^ " was accepted")
    | Error _ -> () in
  refused "a ledger claim id instead of the shown id"
    (answer [row (id_of changed) "join_claim" "c-release"; row (id_of second) "exclude" "out of scope"]);
  refused "a claim the request does not show"
    (answer [row (id_of changed) "join_claim" "c9"; row (id_of second) "exclude" "out of scope"]);
  refused "a neighbor instead of a selected fact"
    (answer [row "f3" "exclude" "no"; row (id_of second) "exclude" "out of scope"]);
  refused "duplicate fact" (answer [row (id_of changed) "exclude" "one"; row (id_of changed) "exclude" "two"]);
  refused "missing fact" (answer [row (id_of changed) "exclude" "one"]);
  refused "unknown action" (answer [row (id_of changed) "magic" "one"; row (id_of second) "exclude" "two"])

let test_snapshot_is_bound_to_the_captured_ledger () =
  let batch = prepare [changed; second] in
  let snapshot = Request.batch_to_json batch in
  (match Request.batch_of_json ~ledger snapshot with
   | Ok restored -> Alcotest.check json "snapshot round trip" snapshot (Request.batch_to_json restored)
   | Error error -> Alcotest.fail (Request.error_to_string error));
  let replace key value = function
    | `Assoc fields -> `Assoc (List.map (fun (name, old) -> name, if name = key then value else old) fields)
    | _ -> Alcotest.fail "expected an object" in
  let map_list key f node = replace key (`List (List.map f (member key node |> to_list))) node in
  let refused label ?(against = ledger) tampered =
    match Request.batch_of_json ~ledger:against tampered with
    | Error (Request.Invalid_batch _) -> ()
    | Ok _ | Error (Request.Invalid_limit | Render_failed _ | Index_unavailable _ | Measure_failed _
                   | Exceeds_frame _) ->
      Alcotest.fail (label ^ " was restored") in
  let input = member "input" snapshot in
  refused "a changed membership" (replace "input" (map_list "facts" (fun fact ->
    if member "member_of" fact = `String "c1" then replace "member_of" `Null fact else fact) input) snapshot);
  refused "a changed claim text" (replace "input" (map_list "claims" (fun claim ->
    replace "claim" (`String "Changed claim prose") claim) input) snapshot);
  refused "a claim id pointing elsewhere" (map_list "claims" (fun pair ->
    replace "claim_id" (`String "c-unrelated") pair) snapshot);
  refused "a changed selected claim" (replace "input" (map_list "facts" (fun fact ->
    if member "id" fact = `String "f1" then replace "claim" (`String "Changed selected prose") fact else fact)
    input) snapshot);
  (* Both rebuild to the same input, so only the row checks can refuse them. *)
  let selected_rows f =
    replace "input" (replace "new_facts" (`List (f (member "new_facts" input |> to_list))) input) snapshot in
  refused "a row that repeats a neighbor" (selected_rows (function
    | first :: rest ->
      let neighbors = match member "neighbors" first |> to_list with
        | neighbor :: others -> neighbor :: neighbor :: others
        | [] -> Alcotest.fail "the first selected row needs a neighbor" in
      replace "neighbors" (`List neighbors) first :: rest
    | [] -> Alcotest.fail "expected a selected row"));
  refused "a fact selected twice" (selected_rows (function
    | first :: rest -> first :: first :: rest
    | [] -> Alcotest.fail "expected a selected row"));
  let disposed = ledger_of (`Assoc [
    "schema", `String "workspace.memory.ledger.v1";
    "claims", `List [`Assoc ["claim_id", `String "c-release"; "claim", `String "The release evidence is ready"];
                     `Assoc ["claim_id", `String "c-unrelated"; "claim", `String unrelated.claim]];
    "conflicts", `List [`Assoc ["conflict_id", `String "x-release";
                                "description", `String "Conflicting release evidence"]];
    "facts", `List [ledger_member shared "claim" "claim_id" "c-release";
                    ledger_member disputed "conflict" "conflict_id" "x-release";
                    ledger_member unrelated "claim" "claim_id" "c-unrelated";
                    ledger_member changed "claim" "claim_id" "c-release"]]) in
  refused "a selected fact the captured ledger already classified" ~against:disposed snapshot;
  refused "the same snapshot against an empty ledger" ~against:Ledger.empty snapshot

let test_first_batch_fills_the_frame_with_the_oldest_facts () =
  let facts = List.init 40 (fun i -> pending ("keeper-" ^ string_of_int i)
      ("Changed claim number " ^ string_of_int i)) in
  (* Stands in for the host's measure (the submit it would send) with a fixed
     size per selected fact, so the frame is a number of facts. *)
  let per_fact = 100 in
  let within ?(measure = fun (batch : Request.batch) -> Ok (per_fact * List.length batch.rows)) frame =
    Request.prepare ~neighbor_limit:1 ~render ~ledger:Ledger.empty ~current:facts ~pending:facts
      ~frame ~measure in
  let batch = get (within ((5 * per_fact) + (per_fact / 2))) in
  Alcotest.(check bool) "the five oldest facts fill a five-fact frame" true (batch.selected = List.take 5 facts);
  Alcotest.(check bool) "ranking stops at the first size that does not fit" true
    (batch.index_stats.queries_executed <= 2 * List.length batch.selected);
  Alcotest.(check int) "one index table serves the whole preparation" 1 batch.index_stats.index_builds;
  Alcotest.(check int) "a frame that holds every fact takes them all" 40
    (List.length (get (within (40 * per_fact))).selected);
  (match within (per_fact - 1) with
   | Error (Request.Exceeds_frame { fact; bytes; frame }) ->
     Alcotest.(check bool) "the refusal names the oldest fact" true (fact = (List.hd facts).fact);
     Alcotest.(check (pair int int)) "with its measured size and the frame" (per_fact, per_fact - 1) (bytes, frame)
   | Ok _ | Error (Request.Invalid_limit | Render_failed _ | Index_unavailable _ | Invalid_batch _
                  | Measure_failed _) ->
     Alcotest.fail "a fact larger than the frame was not refused");
  (match within ~measure:(fun _ -> Error "no request") max_int with
   | Error (Request.Measure_failed _) -> ()
   | Ok _ | Error (Request.Invalid_limit | Render_failed _ | Index_unavailable _ | Invalid_batch _
                  | Exceeds_frame _) ->
     Alcotest.fail "a failed measure was not reported")

let () =
  Alcotest.run "Workspace memory request"
    [ "request shape", [Alcotest.test_case "each fact and entry is listed once" `Quick
                         test_each_fact_and_entry_is_listed_once
                       ; Alcotest.test_case "no change is silent" `Quick
                         test_no_change_does_not_render_or_search
                       ; Alcotest.test_case "model answer uses request-local ids" `Quick
                         test_model_answer_uses_request_local_ids
                       ; Alcotest.test_case "snapshot is bound to the captured ledger" `Quick
                         test_snapshot_is_bound_to_the_captured_ledger
                       ; Alcotest.test_case "first batch fills the frame with the oldest facts" `Quick
                         test_first_batch_fills_the_frame_with_the_oldest_facts ]
    ; "provider refusal", [Alcotest.test_case "narrow keeps the oldest half" `Quick
                            test_narrow_keeps_the_oldest_half_and_its_context
                          ; Alcotest.test_case "many changes drain oldest first" `Quick
                            test_many_facts_drain_oldest_first_after_size_refusals] ]
