module Ledger = Masc.Workspace_memory_ledger
module Context = Masc.Workspace_memory_context
module Os_current = Masc.Keeper_memory_os_current
module Os_types = Masc.Keeper_memory_os_types
module Source_current = Masc.Keeper_memory_source_current

let sha claim = Digestif.SHA256.(digest_string claim |> to_hex)
let str value = `String value

let ordinary ?(revision = 1) claims : Os_current.t =
  let origin : Os_types.origin = { kind = Os_types.Authored; trace_id = "trace" } in
  { revision
  ; updated_at = float_of_int revision
  ; source = { kind = Os_current.Explicit_write; trace_id = "trace" }
  ; facts = List.map (fun claim -> Os_types.observed ~claim ~category:Os_types.Fact ~now:0. ~origin) claims
  ; change = { added = []; removed = []; retained = 0; invalidated = [] }
  }

let source_bound pairs : Source_current.t =
  { revision = 1
  ; updated_at = 1.
  ; trace_id = "trace"
  ; facts = List.map (fun (path, claim) : Source_current.fact ->
      { claim; first_seen = 0.; source = { path; sha256 = sha (path ^ " bytes") } }) pairs
  ; invalidations = []
  }

let keeper ?(ordinary = Context.Missing) ?(source_bound = Context.Missing) keeper_id
  : Context.keeper =
  { keeper_id; ordinary; source_bound }

let ordinary_ref keeper_id claim = Ledger.Ordinary { keeper_id; claim_sha256 = sha claim }
let source_ref keeper_id path claim = Ledger.Source_bound { keeper_id; path; claim_sha256 = sha claim }

let fact_json fact disposition =
  let fact_fields = match fact with
    | Ledger.Ordinary { keeper_id; claim_sha256 } ->
      ["keeper_id", str keeper_id; "store", str "ordinary"; "claim_sha256", str claim_sha256]
    | Ledger.Source_bound { keeper_id; path; claim_sha256 } ->
      ["keeper_id", str keeper_id; "store", str "source_bound"; "path", str path;
       "claim_sha256", str claim_sha256]
  in
  `Assoc (fact_fields @ ["disposition", disposition])

let claim_member id = `Assoc ["kind", str "claim"; "claim_id", str id]
let conflict_member id = `Assoc ["kind", str "conflict"; "conflict_id", str id]
let excluded reason = `Assoc ["kind", str "excluded"; "reason", str reason]

let ledger_json ?(claims = []) ?(conflicts = []) facts =
  `Assoc
    [ "schema", str "workspace.memory.ledger.v1"
    ; "claims", `List (List.map (fun (id, claim) ->
        `Assoc ["claim_id", str id; "claim", str claim]) claims)
    ; "conflicts", `List (List.map (fun (id, description) ->
        `Assoc ["conflict_id", str id; "description", str description]) conflicts)
    ; "facts", `List (List.map (fun (fact, disposition) -> fact_json fact disposition) facts) ]

let decode json =
  match Ledger.of_json json with
  | Ok ledger -> ledger
  | Error detail -> Alcotest.fail detail

let fact_ref =
  Alcotest.testable
    (fun formatter fact -> Yojson.Safe.pp formatter (fact_json fact `Null))
    ( = )

let new_refs (result : Ledger.reconciliation) =
  List.map (fun (pending : Ledger.pending_fact) -> pending.fact) result.new_facts

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let test_ordinary_identity_is_the_memory_id () =
  let claim = "Build runs on OCaml 5.5.1" in
  let fact =
    Os_types.observed ~claim ~category:Os_types.Fact ~now:0. ~origin:{ kind = Os_types.Authored; trace_id = "trace" }
  in
  let result = Ledger.reconcile Ledger.empty [keeper "writer" ~ordinary:(Context.Available (ordinary [claim]))] in
  match result.new_facts with
  | [ { fact = Ledger.Ordinary { claim_sha256; _ }; claim = pending_claim } ] ->
    Alcotest.(check string) "the store's memory_id hash" (Os_types.memory_id fact) ("sha256:" ^ claim_sha256);
    Alcotest.(check string) "claim text travels with the fact" claim pending_claim
  | _ -> Alcotest.fail "expected one ordinary fact"

let test_codec_round_trip_is_canonical () =
  let input =
    ledger_json ~claims:["c2", "Tests run from the worktree root"; "c1", "PDF has ten pages"]
      ~conflicts:["x1", "Owners disagree on the page count"]
      [ source_ref "writer" "notes/b.md" "PDF has ten pages", claim_member "c1"
      ; ordinary_ref "reviewer" "PDF has twelve pages", conflict_member "x1"
      ; ordinary_ref "writer" "PDF has ten pages", claim_member "c1"
      ; ordinary_ref "tester" "Tests run from the worktree root", claim_member "c2"
      ; ordinary_ref "auditor" "Lunch is at noon", excluded "not about the workspace" ]
  in
  let ledger = decode input in
  let canonical =
    ledger_json ~claims:["c1", "PDF has ten pages"; "c2", "Tests run from the worktree root"]
      ~conflicts:["x1", "Owners disagree on the page count"]
      [ ordinary_ref "auditor" "Lunch is at noon", excluded "not about the workspace"
      ; ordinary_ref "reviewer" "PDF has twelve pages", conflict_member "x1"
      ; ordinary_ref "tester" "Tests run from the worktree root", claim_member "c2"
      ; ordinary_ref "writer" "PDF has ten pages", claim_member "c1"
      ; source_ref "writer" "notes/b.md" "PDF has ten pages", claim_member "c1" ]
  in
  let encoded = Ledger.to_json ledger in
  Alcotest.check json "every text and disposition, entries in id order, facts in keeper, store and path order"
    canonical encoded;
  Alcotest.check json "decoding the encoding changes nothing" encoded (Ledger.to_json (decode encoded))

let replace key value = function
  | `Assoc fields -> `Assoc (List.map (fun (k, v) -> if String.equal k key then k, value else k, v) fields)
  | _ -> Alcotest.fail "fixture object"

let test_codec_refuses_malformed_ledgers () =
  let writer = ordinary_ref "writer" "PDF has ten pages" in
  let valid = ledger_json ~claims:["c1", "PDF has ten pages"] [writer, claim_member "c1"] in
  ignore (decode valid);
  let refused name input =
    match Ledger.of_json input with
    | Ok _ -> Alcotest.failf "%s: accepted" name
    | Error _ -> ()
  in
  let fact = fact_json writer (claim_member "c1") in
  let with_fact fact = replace "facts" (`List [fact]) valid in
  refused "missing top-level field"
    (match valid with `Assoc fields -> `Assoc (List.remove_assoc "conflicts" fields) | _ -> `Null);
  refused "facts that are not an array" (replace "facts" (`Assoc []) valid);
  refused "unknown top-level field"
    (match valid with `Assoc fields -> `Assoc (("extra", `Null) :: fields) | _ -> `Null);
  refused "repeated field"
    (match valid with `Assoc fields -> `Assoc (("schema", str "workspace.memory.ledger.v1") :: fields) | _ -> `Null);
  refused "other schema" (replace "schema" (str "workspace.memory.ledger.v0") valid);
  refused "short hash" (with_fact (replace "claim_sha256" (str "abc") fact));
  refused "uppercase hash" (with_fact (replace "claim_sha256" (str (String.uppercase_ascii (sha "x"))) fact));
  refused "blank keeper" (with_fact (replace "keeper_id" (str " ") fact));
  refused "unknown store" (with_fact (replace "store" (str "journal") fact));
  refused "ordinary fact with a path"
    (with_fact (match fact with `Assoc fields -> `Assoc (("path", str "a.md") :: fields) | _ -> `Null));
  refused "source-bound fact without a path" (with_fact (replace "store" (str "source_bound") fact));
  (* A ledger with no claims, so the only broken rule is the disposition's. *)
  ignore (decode (ledger_json [writer, excluded "old"]));
  refused "unknown disposition kind" (ledger_json [writer, `Assoc ["kind", str "maybe"]]);
  refused "blank exclusion reason" (ledger_json [writer, excluded " "]);
  refused "blank claim text" (ledger_json ~claims:["c1", " "] [writer, claim_member "c1"]);
  refused "fact listed twice" (replace "facts" (`List [fact; fact]) valid);
  refused "claim listed twice"
    (ledger_json ~claims:["c1", "PDF has ten pages"; "c1", "again"] [writer, claim_member "c1"]);
  refused "conflict listed twice"
    (ledger_json ~conflicts:["x1", "Owners disagree"; "x1", "again"] [writer, conflict_member "x1"]);
  refused "absent claim" (ledger_json [writer, claim_member "c1"]);
  refused "absent conflict" (ledger_json [writer, conflict_member "x1"]);
  refused "claim without members" (ledger_json ~claims:["c1", "PDF has ten pages"] [writer, excluded "old"]);
  refused "conflict without members"
    (ledger_json ~conflicts:["x1", "Owners disagree"] [writer, excluded "old"])

let test_observe_digest_is_bounded_and_first_line_only () =
  let base_path = Filename.temp_dir "workspace-ledger-digest" "" in
  let long_line =
    String.concat ""
      (List.init 80 (fun n -> Printf.sprintf "공유 주장 %03d 첫 줄이 예산보다 길면 문자 경계에서 잘리고 말줄임표가 붙는다. " n)) in
  let claims =
    ("c-long", long_line)
    :: (List.init 400 (fun n -> Printf.sprintf "c%03d" n, Printf.sprintf "주장 %03d의 첫 줄\n둘째 줄은 다이제스트에 오지 않는다" n))
  in
  let facts =
    List.map (fun (id, claim) -> ordinary_ref "writer" claim, claim_member id) claims in
  let ledger = decode (ledger_json ~claims facts) in
  (match Ledger.save ~base_path ledger with Ok () -> () | Error detail -> Alcotest.fail detail);
  (match Ledger.observe ~base_path with
   | Ledger.Available row ->
     let joined = String.concat "\n" row.claims_digest in
     Alcotest.(check bool) "the digest is a prefix of the claims, not all of them"
       (List.length row.claims_digest < row.claim_count) true;
     Alcotest.(check bool) "the digest keeps its byte budget"
       (String.length joined <= Ledger.digest_budget_bytes + Ledger.digest_line_max_bytes) true;
     Alcotest.(check bool) "lines render in claim_id order, the long id first"
       (String.starts_with ~prefix:"- c-long: " (List.hd row.claims_digest)) true;
     Alcotest.(check bool) "a line cut by the budget ends with the ellipsis mark"
       (String.ends_with ~suffix:"…" (List.hd row.claims_digest)) true;
     Alcotest.(check bool) "a numbered claim's digest line carries only its first line"
       (List.mem "- c000: 주장 000의 첫 줄" row.claims_digest) true
   | Ledger.Missing -> Alcotest.fail "saved ledger observed as missing"
   | Ledger.Unavailable detail -> Alcotest.fail ("saved ledger observed as unavailable: " ^ detail))

let test_observe_empty_ledger_digest_is_empty () =
  let base_path = Filename.temp_dir "workspace-ledger-empty-digest" "" in
  (match Ledger.save ~base_path Ledger.empty with Ok () -> () | Error detail -> Alcotest.fail detail);
  match Ledger.observe ~base_path with
  | Ledger.Available row -> Alcotest.(check int) "no claims, no digest lines" 0 (List.length row.claims_digest)
  | _ -> Alcotest.fail "saved empty ledger is unavailable"

let test_store_missing_corrupt_and_round_trip () =
  let base_path = Filename.temp_dir "workspace-ledger" "" in
  (match Ledger.load ~base_path with
   | Ok ledger -> Alcotest.check json "no ledger file is empty" (Ledger.to_json Ledger.empty) (Ledger.to_json ledger)
   | Error detail -> Alcotest.fail detail);
  let ledger =
    decode (ledger_json ~claims:["c1", "PDF has ten pages"]
              [ordinary_ref "writer" "PDF has ten pages", claim_member "c1"])
  in
  (match Ledger.save ~base_path ledger with Ok () -> () | Error detail -> Alcotest.fail detail);
  (match Ledger.load ~base_path with
   | Ok loaded -> Alcotest.check json "saved ledger reads back" (Ledger.to_json ledger) (Ledger.to_json loaded)
   | Error detail -> Alcotest.fail detail);
  let path = Filename.concat (Ledger.directory ~base_path) "ledger.json" in
  Out_channel.with_open_bin path (fun channel -> output_string channel "{broken");
  (match Ledger.load ~base_path with
   | Ok _ -> Alcotest.fail "a corrupt ledger read as a ledger"
   | Error _ -> ());
  let missing_base = Filename.concat base_path "absent" in
  (match Ledger.load ~base_path:missing_base with
   | Ok _ -> Alcotest.fail "a missing base read as a fresh workspace"
   | Error _ -> ());
  match Ledger.save ~base_path:missing_base Ledger.empty with
  | Ok () -> Alcotest.fail "save created a missing base"
  | Error _ -> Alcotest.(check bool) "missing base stays missing" false (Sys.file_exists missing_base)

let test_new_facts_follow_store_order () =
  let result =
    Ledger.reconcile Ledger.empty
      [ keeper "writer"
          ~ordinary:(Context.Available (ordinary ["B claim"; "A claim"; "B claim"]))
          ~source_bound:(Context.Available (source_bound ["notes/a.md", "File claim"]))
      ; keeper "reviewer" ~ordinary:(Context.Available (ordinary ["A claim"])) ]
  in
  Alcotest.(check (list fact_ref)) "keeper order, ordinary first, one fact per identity"
    [ ordinary_ref "writer" "B claim"
    ; ordinary_ref "writer" "A claim"
    ; source_ref "writer" "notes/a.md" "File claim"
    ; ordinary_ref "reviewer" "A claim" ]
    (new_refs result);
  Alcotest.(check (list fact_ref)) "nothing vanished" [] result.vanished

let test_unchanged_facts_are_no_work () =
  let ledger =
    decode (ledger_json ~claims:["c1", "Build uses dune"]
              [ ordinary_ref "writer" "Build uses dune", claim_member "c1"
              ; ordinary_ref "reviewer" "Build uses dune", claim_member "c1"
              ; source_ref "writer" "notes/a.md" "File claim", excluded "local detail" ])
  in
  let result =
    Ledger.reconcile ledger
      [ keeper "writer"
          ~ordinary:(Context.Available (ordinary ~revision:9 ["Build uses dune"]))
          ~source_bound:(Context.Available (source_bound ["notes/a.md", "File claim"]))
      ; keeper "reviewer" ~ordinary:(Context.Available (ordinary ~revision:4 ["Build uses dune"])) ]
  in
  Alcotest.(check int) "no new facts after a revision-only commit" 0 (List.length result.new_facts);
  Alcotest.(check int) "no vanished facts" 0 (List.length result.vanished);
  Alcotest.check json "ledger unchanged" (Ledger.to_json ledger) (Ledger.to_json result.ledger)

let test_vanished_members_leave_and_empty_entries_go () =
  let ledger =
    decode (ledger_json
              ~claims:["c1", "Build uses dune"]
              ~conflicts:["x1", "Owners disagree on the port"]
              [ ordinary_ref "writer" "Build uses dune", claim_member "c1"
              ; ordinary_ref "reviewer" "Build uses dune", claim_member "c1"
              ; ordinary_ref "reviewer" "Port is 8935", conflict_member "x1"
              ; ordinary_ref "auditor" "Port is 8936", conflict_member "x1" ])
  in
  let result =
    Ledger.reconcile ledger
      [ keeper "writer" ~ordinary:(Context.Available (ordinary ["Build uses dune"]))
      ; keeper "reviewer" ~ordinary:(Context.Available (ordinary ["Port is 8935"]))
      ; keeper "auditor" ~ordinary:(Context.Available (ordinary [])) ]
  in
  Alcotest.(check (list fact_ref)) "vanished facts"
    [ ordinary_ref "auditor" "Port is 8936"; ordinary_ref "reviewer" "Build uses dune" ]
    result.vanished;
  Alcotest.(check (list string)) "claim keeps its remaining member" ["c1"]
    (List.map fst (Ledger.claims result.ledger));
  Alcotest.(check (list string)) "conflict keeps its remaining member" ["x1"]
    (List.map fst (Ledger.conflicts result.ledger));
  let second =
    Ledger.reconcile result.ledger
      [ keeper "writer" ~ordinary:(Context.Available (ordinary []))
      ; keeper "reviewer" ~ordinary:(Context.Available (ordinary [])) ]
  in
  Alcotest.(check int) "claim without members is removed" 0 (List.length (Ledger.claims second.ledger));
  Alcotest.(check int) "conflict without members is removed" 0 (List.length (Ledger.conflicts second.ledger));
  Alcotest.(check int) "no dispositions left" 0 (List.length (Ledger.dispositions second.ledger))

let test_unavailable_store_keeps_its_facts () =
  let ledger =
    decode (ledger_json
              [ ordinary_ref "writer" "Build uses dune", excluded "local detail"
              ; source_ref "writer" "notes/a.md" "File claim", excluded "local detail"
              ; ordinary_ref "gone" "Old claim", excluded "local detail"
              ; ordinary_ref "emptied" "Old claim", excluded "local detail" ])
  in
  let result =
    Ledger.reconcile ledger
      [ keeper "writer" ~ordinary:(Context.Unavailable "EACCES")
          ~source_bound:(Context.Available (source_bound ["notes/b.md", "Other claim"]))
      ; keeper "emptied" ]
  in
  Alcotest.(check (list fact_ref)) "unreadable store loses nothing; missing store and absent keeper lose all"
    [ ordinary_ref "emptied" "Old claim"
    ; ordinary_ref "gone" "Old claim"
    ; source_ref "writer" "notes/a.md" "File claim" ]
    result.vanished;
  Alcotest.(check (list fact_ref)) "unreadable store adds nothing"
    [ source_ref "writer" "notes/b.md" "Other claim" ]
    (new_refs result)

let test_same_claim_in_two_files_is_two_facts () =
  let claim = "Port is 8935" in
  let ledger =
    decode (ledger_json ~claims:["c1", claim]
              [ source_ref "writer" "notes/a.md" claim, claim_member "c1"
              ; source_ref "writer" "notes/b.md" claim, claim_member "c1"
              ; ordinary_ref "reviewer" claim, claim_member "c1" ])
  in
  let result =
    Ledger.reconcile ledger
      [ keeper "writer" ~source_bound:(Context.Available (source_bound
          ["notes/a.md", claim; "notes/b.md", "Port is 8936"]))
      ; keeper "reviewer" ~ordinary:(Context.Available (ordinary [claim])) ]
  in
  Alcotest.(check (list fact_ref)) "only the changed file's fact vanished"
    [ source_ref "writer" "notes/b.md" claim ] result.vanished;
  Alcotest.(check (list fact_ref)) "the changed file's new claim is new"
    [ source_ref "writer" "notes/b.md" "Port is 8936" ] (new_refs result);
  Alcotest.(check (list fact_ref)) "the other file keeps its disposition"
    [ ordinary_ref "reviewer" claim; source_ref "writer" "notes/a.md" claim ]
    (List.map fst (Ledger.dispositions result.ledger))

let pending keeper_id claim : Ledger.pending_fact =
  { fact = ordinary_ref keeper_id claim; claim }

let applied ledger ~selected assignments =
  match Ledger.apply ledger ~selected assignments with
  | Ok updated -> updated
  | Error error -> Alcotest.fail (Ledger.apply_error_to_string error)

let test_selected_decisions_update_one_durable_ledger () =
  let writer = pending "writer" "The report is twelve pages" in
  let reviewer = pending "reviewer" "The report is twelve pages" in
  let ledger = applied Ledger.empty ~selected:[writer; reviewer]
    [ { Ledger.fact = writer.fact; decision = Ledger.Create_claim "The report is twelve pages" }
    ; { Ledger.fact = reviewer.fact; decision = Ledger.Create_claim "The report is twelve pages" } ] in
  Alcotest.(check int) "one shared claim" 1 (List.length (Ledger.claims ledger));
  Alcotest.(check int) "both original facts retain membership" 2
    (List.length (Ledger.dispositions ledger));
  let claim_id = fst (List.hd (Ledger.claims ledger)) in
  let newcomer = pending "auditor" "The report is about twelve pages" in
  let ledger = applied ledger ~selected:[newcomer]
      [{ Ledger.fact = newcomer.fact; decision = Ledger.Join_claim claim_id }] in
  let retained = Ledger.reconcile ledger
      [keeper "writer" ~ordinary:(Context.Available (ordinary [writer.claim]));
       keeper "reviewer";
       keeper "auditor" ~ordinary:(Context.Available (ordinary [newcomer.claim]))] in
  Alcotest.(check (list fact_ref)) "only the vanished review member leaves"
    [reviewer.fact] retained.vanished;
  Alcotest.(check int) "claim with remaining members stays" 1
    (List.length (Ledger.claims retained.ledger));
  Alcotest.check json "applied ledger is valid on disk" (Ledger.to_json retained.ledger)
    (Ledger.to_json (decode (Ledger.to_json retained.ledger)))

let test_apply_refuses_unselected_or_missing_decisions () =
  let writer = pending "writer" "Build uses OCaml" in
  let reviewer = pending "reviewer" "Build uses OCaml" in
  let decision fact : Ledger.assignment =
    { fact; decision = Ledger.Create_claim "Build uses OCaml" } in
  let refused expected selected assignments =
    match Ledger.apply Ledger.empty ~selected assignments with
    | Error error when error = expected -> ()
    | Error error -> Alcotest.fail ("wrong refusal: " ^ Ledger.apply_error_to_string error)
    | Ok _ -> Alcotest.fail "invalid batch was applied" in
  refused Ledger.Missing_assignment [writer; reviewer] [decision writer.fact];
  refused Ledger.Unselected_fact [writer] [decision reviewer.fact];
  refused Ledger.Duplicate_assignment [writer; reviewer]
    [decision writer.fact; decision writer.fact];
  refused (Ledger.Unknown_claim "absent") [writer]
    [{ Ledger.fact = writer.fact; decision = Ledger.Join_claim "absent" }];
  let new_claim = "Build uses OCaml" in
  let new_claim_id = "claim-" ^ Digestif.SHA256.(digest_string new_claim |> to_hex) in
  refused (Ledger.Unknown_claim new_claim_id) [writer; reviewer]
    [ decision writer.fact
    ; { Ledger.fact = reviewer.fact; decision = Ledger.Join_claim new_claim_id } ];
  refused Ledger.Blank_value [writer]
    [{ Ledger.fact = writer.fact; decision = Ledger.Exclude " " }]

let () =
  Alcotest.run "workspace memory ledger"
    [ ( "identity"
      , [ Alcotest.test_case "ordinary identity is the store's memory_id" `Quick
            test_ordinary_identity_is_the_memory_id
        ; Alcotest.test_case "same claim in two files is two facts" `Quick
            test_same_claim_in_two_files_is_two_facts ] )
    ; ( "codec"
      , [ Alcotest.test_case "round trip is canonical" `Quick test_codec_round_trip_is_canonical
        ; Alcotest.test_case "malformed ledgers are refused" `Quick test_codec_refuses_malformed_ledgers
        ; Alcotest.test_case "missing, corrupt and saved ledgers" `Quick
            test_store_missing_corrupt_and_round_trip ] )
    ; ( "observation"
      , [ Alcotest.test_case "digest is bounded and first-line only" `Quick
            test_observe_digest_is_bounded_and_first_line_only
        ; Alcotest.test_case "empty ledger digest is empty" `Quick
            test_observe_empty_ledger_digest_is_empty ] )
    ; ( "reconcile"
      , [ Alcotest.test_case "new facts follow store order" `Quick test_new_facts_follow_store_order
        ; Alcotest.test_case "unchanged facts are no work" `Quick test_unchanged_facts_are_no_work
        ; Alcotest.test_case "vanished members leave and empty entries go" `Quick
            test_vanished_members_leave_and_empty_entries_go
        ; Alcotest.test_case "unavailable store keeps its facts" `Quick
            test_unavailable_store_keeps_its_facts ] )
    ; ( "apply"
      , [ Alcotest.test_case "selected decisions make one durable ledger" `Quick
            test_selected_decisions_update_one_durable_ledger
        ; Alcotest.test_case "unselected or incomplete answers fail closed" `Quick
            test_apply_refuses_unselected_or_missing_decisions ] ) ]
