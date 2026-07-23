module Types = Masc.Keeper_memory_os_types
module Memory_io = Masc.Keeper_memory_os_io
module Sweep = Masc.Keeper_memory_os_sanity_sweep

let now = 10_000.0

let fact
      ?(category = Types.Fact)
      ?(first_seen = now -. 60.0)
      ?valid_until
      ?last_verified_at
      ?claim_id
      ?(claim_kind = None)
      claim
  =
  { Types.claim
  ; category
  ; claim_kind
  ; source = { Types.trace_id = "trace-sanity"; turn = 1; tool_call_id = None }
  ; observed_by = []
  ; first_seen
  ; valid_until
  ; last_verified_at
  ; schema_version = Types.schema_version
  ; claim_id
  }
;;

let with_temp_keepers_dir f =
  let marker = Filename.temp_file "keeper-memory-os-sanity-" ".tmp" in
  Sys.remove marker;
  Memory_io.For_testing.with_keepers_dir marker (fun () -> f marker)
;;

let with_eio f = Eio_main.run @@ fun _env -> f ()

let result_for keeper_id report =
  List.find_opt
    (function
      | Sweep.Keeper_ok row -> String.equal row.keeper_id keeper_id
      | Sweep.Keeper_error row -> String.equal row.keeper_id keeper_id)
    report.Sweep.results
;;

let test_sweep_projects_typed_memory_state_without_rewrite () =
  with_eio (fun () ->
    with_temp_keepers_dir (fun keepers_dir ->
      let rows =
        [ fact ~claim_id:"same-conclusion" "first wording"
        ; fact ~claim_id:"same-conclusion" "second wording"
        ; fact
            ~claim_kind:(Some Types.External_state)
            ~first_seen:(now -. 1_000_000.0)
            "external state claim"
        ; fact ~claim_kind:(Some Types.Diagnostic) "diagnostic evidence"
        ]
      in
      List.iter (Memory_io.append_fact ~keeper_id:"alpha") rows;
      let report = Sweep.run_for_keepers_dir ~keepers_dir ~keeper_ids:[ "alpha" ] ~now () in
      Alcotest.(check int) "total facts" 4 report.total_facts;
      Alcotest.(check int) "current facts" 4 report.current_facts;
      Alcotest.(check int) "expired facts" 0 report.expired_facts;
      Alcotest.(check int) "duplicate groups" 1 report.duplicate_group_count;
      Alcotest.(check int) "gc ttl expired" 0 report.deterministic_ttl_expired;
      Alcotest.(check int) "dry-run does not rewrite" 4
        (List.length (Memory_io.read_facts_all ~keeper_id:"alpha"));
      match result_for "alpha" report with
      | Some (Sweep.Keeper_ok row) ->
        Alcotest.(check int) "row total" 4 row.total_facts;
        Alcotest.(check int) "row gc written" 4 row.gc_preview.written;
        (match row.duplicate_groups with
         | [ group ] ->
           Alcotest.(check string)
             "claim identity from claim_id"
             "id:same-conclusion"
             group.claim_identity;
           Alcotest.(check (list int)) "duplicate indices" [ 0; 1 ] group.member_indices
         | groups ->
           Alcotest.failf "expected one duplicate group, got %d" (List.length groups));
        (match List.nth_opt row.facts 2 with
         | Some external_state ->
           Alcotest.(check bool) "old unbounded external state stays current" true external_state.current;
           Alcotest.(check bool)
             "no implicit horizon"
             true
             (Option.is_none external_state.effective_valid_until)
         | None -> Alcotest.fail "missing expired row");
        (match List.nth_opt row.facts 3 with
         | Some diagnostic ->
           Alcotest.(check bool) "diagnostic current" true diagnostic.current
         | None -> Alcotest.fail "missing diagnostic row")
      | Some (Sweep.Keeper_error row) ->
        Alcotest.failf "unexpected error for alpha: %s" row.keeper_id
      | None -> Alcotest.fail "missing alpha result"))
;;

let test_duplicate_groups_follow_claim_identity_only () =
  let rows =
    [ Sweep.For_testing.row_of_fact
        ~now
        ~index:0
        (fact ~claim_id:"first-identity" "same topic")
    ; Sweep.For_testing.row_of_fact
        ~now
        ~index:1
        (fact ~claim_id:"second-identity" "same topic")
    ; Sweep.For_testing.row_of_fact ~now ~index:2 (fact "exact same")
    ; Sweep.For_testing.row_of_fact ~now ~index:3 (fact "exact same")
    ]
  in
  let groups = Sweep.For_testing.duplicate_groups rows in
  Alcotest.(check int) "only exact claim identity groups" 1 (List.length groups);
  match groups with
  | [ group ] ->
    Alcotest.(check bool)
      "exact observation identity"
      true
      (String.starts_with ~prefix:"observation:" group.claim_identity);
    Alcotest.(check (list int)) "members" [ 2; 3 ] group.member_indices
  | _ -> Alcotest.fail "unexpected duplicate group shape"
;;

let test_explicit_missing_keeper_is_structured_error () =
  with_eio (fun () ->
    with_temp_keepers_dir (fun keepers_dir ->
      let report =
        Sweep.run_for_keepers_dir ~keepers_dir ~keeper_ids:[ "missing" ] ~now ()
      in
      Alcotest.(check int) "error count" 1 report.error_count;
      match result_for "missing" report with
      | Some (Sweep.Keeper_error row) ->
        (match row.error with
         | Sweep.Missing_fact_store { facts_path } ->
           Alcotest.(check string)
             "missing path"
             (Memory_io.facts_path_for_keepers_dir ~keepers_dir ~keeper_id:"missing")
             facts_path
         | Sweep.Corrupt_fact_store _
         | Sweep.Fact_store_access_error _
         | Sweep.Fact_store_locked _ ->
           Alcotest.fail "expected missing fact store");
        (match Sweep.to_json report with
         | `Assoc fields ->
           (match List.assoc_opt "keepers" fields with
            | Some (`List [ `Assoc keeper_fields ]) ->
              Alcotest.(check (option string))
                "error status"
                (Some "error")
                (Option.bind
                   (List.assoc_opt "status" keeper_fields)
                   (function `String s -> Some s | _ -> None));
              Alcotest.(check (option string))
                "error code"
                (Some "fact_store_missing")
                (Option.bind
                   (List.assoc_opt "error_code" keeper_fields)
                   (function `String s -> Some s | _ -> None))
            | Some _ | None -> Alcotest.fail "missing keeper JSON")
         | _ -> Alcotest.fail "report JSON must be object")
      | Some (Sweep.Keeper_ok _) -> Alcotest.fail "expected missing keeper error"
      | None -> Alcotest.fail "missing result"))
;;

let () =
  Alcotest.run
    "keeper_memory_os_sanity_sweep"
    [ ( "sanity"
      , [ Alcotest.test_case
            "projects typed state without rewrite"
            `Quick
            test_sweep_projects_typed_memory_state_without_rewrite
        ; Alcotest.test_case
            "duplicate groups follow claim identity only"
            `Quick
            test_duplicate_groups_follow_claim_identity_only
        ; Alcotest.test_case
            "explicit missing keeper is structured error"
            `Quick
            test_explicit_missing_keeper_is_structured_error
        ] )
    ]
;;
