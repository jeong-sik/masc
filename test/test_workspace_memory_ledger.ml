module Ledger = Masc.Workspace_memory_ledger
module Context = Masc.Workspace_memory_context
module Os_current = Masc.Keeper_memory_os_current
module Os_types = Masc.Keeper_memory_os_types
module Source_current = Masc.Keeper_memory_source_current

let sha claim = Agent_core_sha256.(digest_string claim |> to_hex)
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

let test_observe_reads_published_briefing_and_reports_staleness () =
  let module Briefing = Masc.Workspace_memory_briefing in
  let require = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let base_path = Filename.temp_dir "workspace-ledger-briefing" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let ledger = decode (ledger_json ~claims:["c1", "Owner review is still pending"]
      [ordinary_ref "writer" "Owner review is still pending", claim_member "c1"]) in
    Ledger.save ~base_path ledger |> require;
    (match Ledger.observe ~base_path with
     | Ledger.Available { briefing = Ok Briefing.Missing; _ } -> ()
     | _ -> Alcotest.fail "classified evidence without a summary was hidden or called summarized");
    let directory = Ledger.directory ~base_path in
    let template = (Prompt_registry.resolve_prompt Prompt_names.workspace_memory_briefing).effective in
    let contract = Briefing.contract ~template in
    let batch = match Briefing.prepare ~sources:(Ledger.briefing_sources ledger) ~contract
        ~render:(fun value -> Ok (Yojson.Safe.to_string value)) Briefing.empty |> require with
      | Briefing.Prepared batch -> batch
      | Briefing.Unchanged | Briefing.Cleanup _ -> Alcotest.fail "unsummarized ledger prepared no work" in
    Briefing.save ~directory (Briefing.prepared_state batch) |> require;
    (match Ledger.observe ~base_path with
     | Ledger.Available { building = Ok (Some pass); _ } ->
       Alcotest.(check int) "building pass target matches" 1 pass.target;
       Alcotest.(check int) "building pass remaining matches" 1 pass.remaining
     | _ -> Alcotest.fail "active briefing pass was not observed");
    let text = "Owner review is pending; completion has not been confirmed." in
    let accepted = Briefing.accept batch ~text |> require in
    Briefing.save ~directory accepted |> require;
    (match Ledger.observe ~base_path with
     | Ledger.Available { building = Ok None; _ } -> ()
     | _ -> Alcotest.fail "completed pass still observed as building");
    let observe_current () = match Ledger.observe ~base_path with
      | Ledger.Available { briefing = Ok (Briefing.Current summary); claim_count = 1; _ } ->
        Alcotest.(check string) "actual saved semantic text reaches the observation" text summary.text;
        Alcotest.(check (list string)) "publication names the supporting claim" ["claim:c1"] summary.source_ids
      | _ -> Alcotest.fail "saved briefing was not observed as current" in
    observe_current (); observe_current ();
    let superseded = match Briefing.prepare ~sources:(Ledger.briefing_sources ledger)
        ~contract:(Briefing.contract ~template:(template ^ "\nPrior synthesis contract"))
        ~render:(fun value -> Ok (Yojson.Safe.to_string value)) Briefing.empty |> require with
      | Briefing.Prepared batch -> Briefing.accept batch ~text |> require
      | Briefing.Unchanged | Briefing.Cleanup _ -> Alcotest.fail "prior contract prepared no briefing" in
    Briefing.save ~directory superseded |> require;
    (match Ledger.observe ~base_path with
     | Ledger.Available { briefing = Ok (Briefing.Stale summary); _ } ->
       Alcotest.(check string) "superseded prompt is stale even before the worker starts" text summary.text
     | _ -> Alcotest.fail "same sources hid a synthesis contract mismatch");
    Briefing.save ~directory accepted |> require;
    let changed = decode (ledger_json ~claims:["c1", "Owner review has completed"]
      [ordinary_ref "writer" "Owner review has completed", claim_member "c1"]) in
    Ledger.save ~base_path changed |> require;
    (match Ledger.observe ~base_path with
     | Ledger.Available { briefing = Ok (Briefing.Stale summary); _ } ->
       Alcotest.(check string) "changed source text retains the prior summary as stale" text summary.text
     | _ -> Alcotest.fail "changed source content reused an allegedly current summary");
    Out_channel.with_open_bin (Briefing.path ~directory)
      (fun channel -> output_string channel "{broken");
    match Ledger.observe ~base_path with
    | Ledger.Available { briefing = Error _; claim_count = 1; _ } -> ()
    | _ -> Alcotest.fail "briefing corruption hid the readable ledger or claimed a summary")

let test_briefing_keeps_claim_and_conflict_namespaces_distinct () =
  let module Briefing = Masc.Workspace_memory_briefing in
  let ledger = decode (ledger_json
    ~claims:["shared-id", "Release review is pending"]
    ~conflicts:["shared-id", "Keepers disagree about the release date"]
    [ordinary_ref "writer" "Release review is pending", claim_member "shared-id";
     ordinary_ref "reviewer" "Keepers disagree about the release date", conflict_member "shared-id"]) in
  let sources = Ledger.briefing_sources ledger in
  Alcotest.(check (list string)) "collection-local IDs remain separate briefing sources"
    ["claim:shared-id"; "conflict:shared-id"]
    (List.map (fun (source : Briefing.source) -> source.id) sources);
  Alcotest.(check (list string)) "raw claim IDs are unchanged" ["shared-id"] (List.map fst (Ledger.claims ledger));
  Alcotest.(check (list string)) "raw conflict IDs are unchanged" ["shared-id"] (List.map fst (Ledger.conflicts ledger));
  let contract = Briefing.contract ~template:"fixture" in
  match Briefing.prepare ~sources ~contract
      ~render:(fun value -> Ok (Yojson.Safe.to_string value)) Briefing.empty with
  | Ok (Briefing.Prepared batch) ->
    Alcotest.(check int) "both complete bodies reach synthesis" 2 (Briefing.selected_count batch);
    (match Briefing.accept batch ~text:"Review is pending; the release date is disputed." with
     | Ok state ->
       (match Briefing.observe ~sources ~contract state with
        | Briefing.Current summary ->
          Alcotest.(check (list string)) "the publication binds both distinct sources"
            ["claim:shared-id"; "conflict:shared-id"] summary.source_ids
        | Briefing.Missing | Briefing.Stale _ -> Alcotest.fail "valid cross-kind IDs prevented current publication")
     | Error detail -> Alcotest.fail detail)
  | Ok (Briefing.Unchanged | Briefing.Cleanup _) -> Alcotest.fail "populated ledger prepared no briefing"
  | Error detail -> Alcotest.fail detail

let test_observe_empty_ledger_needs_no_briefing () =
  let module Briefing = Masc.Workspace_memory_briefing in
  let base_path = Filename.temp_dir "workspace-ledger-empty" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    (match Ledger.save ~base_path Ledger.empty with Ok () -> () | Error detail -> Alcotest.fail detail);
    match Ledger.observe ~base_path with
    | Ledger.Available { briefing = Ok (Briefing.Current summary); claim_count = 0; _ } ->
      Alcotest.(check string) "no evidence needs no generated prose" "" summary.text;
      Alcotest.(check (list string)) "empty evidence has no source references" [] summary.source_ids
    | _ -> Alcotest.fail "empty ledger fabricated a pending or unavailable briefing")

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
  (match Ledger.observe ~base_path:missing_base with
   | Ledger.Unavailable _ -> ()
   | Ledger.Missing | Ledger.Available _ ->
     Alcotest.fail "an invalid workspace was observed as an absent or available ledger");
  (match Ledger.load ~base_path:missing_base with
   | Ok _ -> Alcotest.fail "a missing base read as a fresh workspace"
   | Error _ -> ());
  match Ledger.save ~base_path:missing_base Ledger.empty with
  | Ok () -> Alcotest.fail "save created a missing base"
  | Error _ -> Alcotest.(check bool) "missing base stays missing" false (Sys.file_exists missing_base)

let ordinary_seen facts : Os_current.t =
  let origin : Os_types.origin = { kind = Os_types.Authored; trace_id = "trace" } in
  { (ordinary []) with
    facts = List.map (fun (claim, now) -> Os_types.observed ~claim ~category:Os_types.Fact ~now ~origin) facts }

let source_bound_seen facts : Source_current.t =
  { (source_bound []) with
    facts = List.map (fun (path, claim, first_seen) : Source_current.fact ->
      { claim; first_seen; source = { path; sha256 = sha (path ^ " bytes") } }) facts }

let test_new_facts_are_oldest_first () =
  let result =
    Ledger.reconcile Ledger.empty
      [ keeper "writer"
          ~ordinary:(Context.Available (ordinary_seen ["Late claim", 30.; "Early claim", 10.; "Late claim", 30.]))
          ~source_bound:(Context.Available (source_bound_seen ["notes/a.md", "File claim", 20.]))
      ; keeper "auditor" ~ordinary:(Context.Available (ordinary_seen ["Tied claim", 20.])) ]
  in
  Alcotest.(check (list fact_ref)) "oldest first_seen first; a tie follows Keeper, store and path"
    [ ordinary_ref "writer" "Early claim"
    ; ordinary_ref "auditor" "Tied claim"
    ; source_ref "writer" "notes/a.md" "File claim"
    ; ordinary_ref "writer" "Late claim" ]
    (new_refs result);
  Alcotest.(check (list fact_ref)) "current facts keep store order, one fact per identity"
    [ ordinary_ref "writer" "Late claim"
    ; ordinary_ref "writer" "Early claim"
    ; source_ref "writer" "notes/a.md" "File claim"
    ; ordinary_ref "auditor" "Tied claim" ]
    (List.map (fun (pending : Ledger.pending_fact) -> pending.fact) result.current_facts);
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

let test_an_entry_that_loses_a_member_goes_and_its_other_members_are_new () =
  let ledger =
    decode (ledger_json
              ~claims:["c1", "Build uses dune"; "c2", "Tests run from the worktree root"]
              ~conflicts:["x1", "Owners disagree on the port"]
              [ ordinary_ref "writer" "Build uses dune", claim_member "c1"
              ; ordinary_ref "reviewer" "Build uses dune", claim_member "c1"
              ; ordinary_ref "writer" "Tests run from the worktree root", claim_member "c2"
              ; ordinary_ref "tester" "Tests run from the worktree root", claim_member "c2"
              ; ordinary_ref "reviewer" "Port is 8935", conflict_member "x1"
              ; ordinary_ref "auditor" "Port is 8936", conflict_member "x1"
              ; ordinary_ref "gone" "Old local note", excluded "local detail" ])
  in
  let result =
    Ledger.reconcile ledger
      [ keeper "writer"
          ~ordinary:(Context.Available (ordinary ["Build uses dune"; "Tests run from the worktree root"]))
      ; keeper "reviewer" ~ordinary:(Context.Available (ordinary ["Port is 8935"]))
      ; keeper "tester" ~ordinary:(Context.Available (ordinary ["Tests run from the worktree root"]))
      ; keeper "auditor" ~ordinary:(Context.Available (ordinary [])) ]
  in
  Alcotest.(check (list fact_ref)) "vanished facts"
    [ ordinary_ref "auditor" "Port is 8936"
    ; ordinary_ref "gone" "Old local note"
    ; ordinary_ref "reviewer" "Build uses dune" ]
    result.vanished;
  Alcotest.(check (list string)) "only the claim that kept every member stays" ["c2"]
    (List.map fst (Ledger.claims result.ledger));
  Alcotest.(check (list string)) "the conflict that lost a member goes" []
    (List.map fst (Ledger.conflicts result.ledger));
  Alcotest.(check (list fact_ref)) "the kept claim's members keep their disposition"
    [ ordinary_ref "tester" "Tests run from the worktree root"
    ; ordinary_ref "writer" "Tests run from the worktree root" ]
    (List.map fst (Ledger.dispositions result.ledger));
  Alcotest.(check (list fact_ref)) "the other members of a gone entry are new again"
    [ ordinary_ref "reviewer" "Port is 8935"; ordinary_ref "writer" "Build uses dune" ]
    (new_refs result)

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
    decode (ledger_json
              [ source_ref "writer" "notes/a.md" claim, excluded "local detail"
              ; source_ref "writer" "notes/b.md" claim, excluded "local detail"
              ; ordinary_ref "reviewer" claim, excluded "local detail" ])
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

let test_fact_refs_are_ordered_by_keeper_store_path_then_claim () =
  let ordinary keeper_id claim_sha256 = Ledger.Ordinary { keeper_id; claim_sha256 } in
  let bound keeper_id path claim_sha256 =
    Ledger.Source_bound { keeper_id; path; claim_sha256 }
  in
  let in_order =
    [ ordinary "a" "1"
    ; ordinary "a" "2"
    ; bound "a" "" "1"
    ; bound "a" "x.md" "1"
    ; bound "a" "x.md" "2"
    ; bound "a" "y.md" "1"
    ; ordinary "b" "1"
    ; bound "b" "x.md" "1"
    ]
  in
  List.iteri
    (fun i left ->
       List.iteri
         (fun j right ->
            Alcotest.(check int)
              (Printf.sprintf "ref %d against ref %d" i j)
              (Int.compare i j)
              (Int.compare (Ledger.compare_fact_ref left right) 0))
         in_order)
    in_order;
  let map =
    List.fold_left
      (fun map fact -> Ledger.Fact_map.add fact () map)
      Ledger.Fact_map.empty
      (List.rev in_order)
  in
  Alcotest.(check (list fact_ref)) "a map lists facts in that order" in_order
    (List.map fst (Ledger.Fact_map.bindings map))

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
  Alcotest.(check int) "the claim that lost a member goes" 0
    (List.length (Ledger.claims retained.ledger));
  Alcotest.(check (list fact_ref)) "its other members are new again"
    [newcomer.fact; writer.fact] (new_refs retained);
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
  let new_claim_id = "claim-" ^ Agent_core_sha256.(digest_string new_claim |> to_hex) in
  refused (Ledger.Unknown_claim new_claim_id) [writer; reviewer]
    [ decision writer.fact
    ; { Ledger.fact = reviewer.fact; decision = Ledger.Join_claim new_claim_id } ];
  refused Ledger.Blank_value [writer]
    [{ Ledger.fact = writer.fact; decision = Ledger.Exclude " " }]

let test_ordinary_absence_uses_fact_identity_and_all_dispositions () =
  let database = decode (ledger_json ~claims:["c", "shared"] ~conflicts:["x", "conflict"]
    [ordinary_ref "writer" "shared", claim_member "c";
     source_ref "writer" "file" "source-only", claim_member "c";
     ordinary_ref "writer" "conflict", conflict_member "x";
     ordinary_ref "writer" "excluded", excluded "not shared"]) in
  let observed = Ledger.ordinary_absence database
    [keeper "writer" ~ordinary:(Context.Available (ordinary
       ["shared"; "shared"; "source-only"; "conflict"; "excluded"; "new"]))
       ~source_bound:(Context.Available (source_bound ["file", "source-only"]));
     keeper "reviewer" ~ordinary:(Context.Available (ordinary ["shared"]))
       ~source_bound:(Context.Unavailable "source read failed")] in
  Alcotest.(check bool) "same Keeper duplicates collapse; another Keeper and source store stay distinct"
    true (observed = Ledger.Complete {facts=6; absent=3; available_stores=2; missing_stores=0})

let test_absence_uses_original_ledger_not_reclassification_queue () =
  let database = decode (ledger_json ~claims:["c", "shared"]
    [ordinary_ref "writer" "shared", claim_member "c";
     ordinary_ref "reviewer" "shared", claim_member "c"]) in
  let keepers = [keeper "writer" ~ordinary:(Context.Available (ordinary ["shared"]));
                 keeper "reviewer"] in
  Alcotest.(check int) "lost member makes the retained member pending for reclassification" 1
    (List.length (Ledger.reconcile database keepers).new_facts);
  Alcotest.(check bool) "that member remains present in the observed durable ledger" true
    (Ledger.ordinary_absence database keepers =
     Ledger.Complete {facts=1; absent=0; available_stores=1; missing_stores=1})

let test_absence_preserves_unreadable_ordinary_stores () =
  Alcotest.(check bool) "a failed store leaves only a lower bound" true
    (Ledger.ordinary_absence Ledger.empty
      [keeper "read" ~ordinary:(Context.Available (ordinary ["fact"])); keeper "missing";
       keeper "broken" ~ordinary:(Context.Unavailable "bad snapshot")] =
     Ledger.Partial {counts={facts=1; absent=1; available_stores=1; missing_stores=1}; unavailable_stores=1});
  Alcotest.(check bool) "all unavailable is not a measured zero" true
    (Ledger.ordinary_absence Ledger.empty [keeper "broken" ~ordinary:(Context.Unavailable "bad snapshot")] =
     Ledger.Partial {counts={facts=0; absent=0; available_stores=0; missing_stores=0}; unavailable_stores=1});
  Alcotest.(check bool) "missing is known empty and distinct from a readable empty snapshot" true
    (Ledger.ordinary_absence Ledger.empty [keeper "missing";
       keeper "empty" ~ordinary:(Context.Available (ordinary []))] =
     Ledger.Complete {facts=0; absent=0; available_stores=1; missing_stores=1})

let () =
  Alcotest.run "workspace memory ledger"
    [ ( "identity"
      , [ Alcotest.test_case "ordinary identity is the store's memory_id" `Quick
            test_ordinary_identity_is_the_memory_id
        ; Alcotest.test_case "same claim in two files is two facts" `Quick
            test_same_claim_in_two_files_is_two_facts
        ; Alcotest.test_case "fact refs are ordered by Keeper, store, path, then claim" `Quick
            test_fact_refs_are_ordered_by_keeper_store_path_then_claim ] )
    ; ( "codec"
      , [ Alcotest.test_case "round trip is canonical" `Quick test_codec_round_trip_is_canonical
        ; Alcotest.test_case "malformed ledgers are refused" `Quick test_codec_refuses_malformed_ledgers
        ; Alcotest.test_case "missing, corrupt and saved ledgers" `Quick
            test_store_missing_corrupt_and_round_trip ] )
    ; ( "observation"
      , [ Alcotest.test_case "durable briefing is current, stale or explicitly unavailable" `Quick
            test_observe_reads_published_briefing_and_reports_staleness
        ; Alcotest.test_case "empty ledger needs no generated briefing" `Quick
            test_observe_empty_ledger_needs_no_briefing
        ; Alcotest.test_case "claim and conflict IDs remain separate" `Quick
            test_briefing_keeps_claim_and_conflict_namespaces_distinct ] )
    ; ( "reconcile"
      , [ Alcotest.test_case "new facts are oldest first" `Quick test_new_facts_are_oldest_first
        ; Alcotest.test_case "unchanged facts are no work" `Quick test_unchanged_facts_are_no_work
        ; Alcotest.test_case "an entry that loses a member goes and its other members are new" `Quick
            test_an_entry_that_loses_a_member_goes_and_its_other_members_are_new
        ; Alcotest.test_case "unavailable store keeps its facts" `Quick
            test_unavailable_store_keeps_its_facts ] )
    ; ( "apply"
      , [ Alcotest.test_case "selected decisions make one durable ledger" `Quick
            test_selected_decisions_update_one_durable_ledger
        ; Alcotest.test_case "unselected or incomplete answers fail closed" `Quick
            test_apply_refuses_unselected_or_missing_decisions ] )
    ; ( "ordinary absence"
      , [ Alcotest.test_case "identity, deduplication and dispositions" `Quick
            test_ordinary_absence_uses_fact_identity_and_all_dispositions
        ; Alcotest.test_case "original membership differs from reclassification" `Quick
            test_absence_uses_original_ledger_not_reclassification_queue
        ; Alcotest.test_case "unavailable stores preserve partial coverage" `Quick
            test_absence_preserves_unreadable_ordinary_stores ] ) ]
