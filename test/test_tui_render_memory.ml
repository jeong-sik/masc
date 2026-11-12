open Alcotest
module Cat = Masc.Keeper_memory_os_types
module Types = Masc_tui_types
module Render_memory = Masc_tui_render_memory

let make_state () =
  Types.create_state ~workspace:"" ~port:0 ()
;;

(* The browser open on the snapshot's keeper, with its facts answered the way
   the answer handler settles them. *)
let answer_memory_facts ?unread (state : Types.state) (snapshot : Masc.Tui_decode_memory_facts.memory_fact_snapshot) =
  let keeper = snapshot.Masc.Tui_decode_memory_facts.mfs_keeper in
  state.Types.memory_facts_keeper <- Some keeper;
  match Masc_tui_fetched.start ~equal:String.equal state.Types.memory_facts ~key:keeper with
  | Masc_tui_fetched.Already_loading -> Alcotest.fail "fixture already loading"
  | Masc_tui_fetched.Started (next, request) ->
      state.Types.memory_facts <-
        Masc_tui_fetched.complete ~equal:String.equal next request (Ok (snapshot, unread))
;;

(* A refresh of the open keeper's facts that failed: the facts stay, stale. *)
let fail_memory_facts_refresh (state : Types.state) detail =
  let keeper = Option.get state.Types.memory_facts_keeper in
  match Masc_tui_fetched.start ~equal:String.equal state.Types.memory_facts ~key:keeper with
  | Masc_tui_fetched.Already_loading -> Alcotest.fail "fixture already loading"
  | Masc_tui_fetched.Started (next, request) ->
      state.Types.memory_facts <-
        Masc_tui_fetched.complete ~equal:String.equal next request (Error detail)
;;

let contains needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec go i = i + n <= h && (String.equal (String.sub haystack i n) needle || go (i + 1)) in
  go 0
;;

let wire_controls = "\x07\027[2J\027]0;title\x07\127"

let multi_line_claim =
  "The chat pane keeps the model's reply verbatim.\n\n**Why**:\n1. first reason\n\
   2. second reason " ^ wire_controls

(* This is a terminal-safety boundary, independent of detail labels, field
   order, wrapping, or row count. Ignore only the renderer's own SGR styling;
   the fixture's clear-screen, OSC, BEL and DEL must remain visible escapes. *)
let check_terminal_safe ~what lines =
  let plain = List.map Masc_tui_theme.strip_sgr lines in
  List.iter
    (fun line ->
      check bool (what ^ ": no wire control byte reaches a terminal row") false
        (String.exists (fun ch -> Char.code ch < 0x20 || Char.code ch = 0x7f) line))
    plain;
  List.iter
    (fun escaped ->
      check bool (what ^ ": wire controls are escaped, not discarded") true
        (List.exists (contains escaped) plain))
    ["\\x07"; "\\x1B[2J"; "\\x1B]0;title"; "\\x7F"]

let test_detail_escapes_wire_controls_without_changing_facts () =
  let fact : Masc.Tui_decode_memory_facts.memory_fact =
    { mf_keeper = "alpha" ^ wire_controls
    ; mf_claim = multi_line_claim
    ; mf_category = Cat.Constraint
    ; mf_origin = "manual" ^ wire_controls
    ; mf_first_seen = 100.0
    ; mf_last_seen = 200.0
    ; mf_memory_id = "mem-lines-1" ^ wire_controls
    ; mf_events = Masc.Tui_decode_memory_facts.no_memory_fact_events
    }
  in
  let sfact : Masc.Tui_decode_memory_facts.memory_source_fact =
    { msf_keeper = "alpha" ^ wire_controls
    ; msf_claim = multi_line_claim
    ; msf_first_seen = 100.0
    ; msf_path = "config/runtime.toml" ^ wire_controls
    ; msf_sha256 = "abc123sha" ^ wire_controls
    }
  in
  let invalidation : Masc.Tui_decode_memory_facts.memory_invalidation =
    { mi_keeper = "alpha" ^ wire_controls
    ; mi_source_path = "legacy_docs.md" ^ wire_controls
    ; mi_invalidated_at = 300.0
    ; mi_reason = "superseded " ^ wire_controls
    }
  in
  List.iter (fun ko ->
    List.iter (fun (what, row) ->
      check_terminal_safe ~what (Render_memory.memory_fact_detail_lines ~ko ~cols:120 row))
      ["fact", Types.Memory_row_fact fact;
       "source-bound fact", Types.Memory_row_source_fact sfact;
       "invalidation", Types.Memory_row_invalidation invalidation])
    [false; true];
  check string "the original claim still has its line breaks and wire bytes"
    multi_line_claim fact.mf_claim;
  check bool "the original typed category is preserved" true
    (fact.mf_category = Cat.Constraint);
  check string "the original source claim is preserved" multi_line_claim sfact.msf_claim;
  check string "the original bound path is preserved" ("config/runtime.toml" ^ wire_controls)
    sfact.msf_path;
  check string "the original invalidation reason is preserved" ("superseded " ^ wire_controls)
    invalidation.mi_reason
;;

let make_keeper_health ~keeper_id ~facts ~snapshot_bytes : Masc.Tui_decode_memory_health.memory_keeper_health =
  { mkh_keeper_id = keeper_id
  ; mkh_revision = 1
  ; mkh_updated_at = Some 1700000000.
  ; mkh_facts = facts
  ; mkh_observed_facts = facts
  ; mkh_derived_facts = 0
  ; mkh_support_invalidations = 0
  ; mkh_snapshot_bytes = snapshot_bytes
  ; mkh_added = facts
  ; mkh_removed = 0
  ; mkh_snapshot_present = true
  ; mkh_age_bins = Some Masc.Keeper_memory_age_bins.zero
  ; mkh_facts_by_hour = []
  ; mkh_changes_since_start = []
  ; mkh_context_cycle =
      { mcc_saved = None; mcc_saved_unreadable = false; mcc_read_position = None;
        mcc_read_position_unreadable = false; mcc_rewriting_through = None;
        mcc_prepared = None; mcc_synthesis = None; mcc_unread_snapshot = Ok []; mcc_unread_memory = Ok [] }
  ; mkh_librarian =
      { Masc.Tui_decode_memory_health.mlh_state = Some Masc.Tui_decode_memory_health.Pass_drained
      ; mlh_admission_wait = None
      ; mlh_operator_action_required = false
      ; mlh_measured_at = Some 1_775_000_000.0
      ; mlh_unread_atom_turns = Some 0
      ; mlh_unread_official_turns = Some 0
      ; mlh_continuity_unread_atoms = Some 0
      ; mlh_last_success_at = None
      ; mlh_last_failure_kind = None
      ; mlh_stalled = None
      }
  ; mkh_librarian_failures = 0
  ; mkh_vision_ingest_errors = 0
  ; mkh_vision_ingest_error_reasons = []
  ; mkh_read_error = None
  ; mkh_source_revision = 0
  ; mkh_source_facts = 0
  ; mkh_source_invalidations = 0
  ; mkh_source_snapshot_bytes = 0
  ; mkh_source_snapshot_present = false
  ; mkh_source_read_error = None
  ; mkh_alerts = []
  }
;;

let make_fleet_health keeper : Masc.Tui_decode_memory_health.memory_health_snapshot =
  { mhs_generated_at = 1000.0
  ; mhs_keepers = [ keeper ]
  ; mhs_refused_keepers = []
  ; mhs_total_facts = 10
  ; mhs_total_observed_facts = 10
  ; mhs_total_derived_facts = 0
  ; mhs_total_support_invalidations = 0
  ; mhs_total_snapshot_bytes = 1024
  ; mhs_total_source_facts = 0
  ; mhs_total_source_invalidations = 0
  ; mhs_total_source_snapshot_bytes = 0
  ; mhs_total_librarian_failures = 0
  ; mhs_total_librarian_unread_turns = Some 0
  ; mhs_total_librarian_continuity_unread_atoms = 0
  ; mhs_total_librarian_continuity_unmeasured = 0
  ; mhs_total_vision_ingest_errors = 0
  ; mhs_total_read_errors = 0
  ; mhs_total_source_read_errors = 0
  ; mhs_warn_alerts = 0
  ; mhs_error_alerts = 0
  ; mhs_starving_keepers = 0
  ; mhs_librarian_attention_required_keepers = 0
  }

let fleet_health : Masc.Tui_decode_memory_health.memory_health_snapshot =
  let with_lag (keeper : Masc.Tui_decode_memory_health.memory_keeper_health) lag =
    { keeper with
      mkh_librarian = { keeper.mkh_librarian with Masc.Tui_decode_memory_health.mlh_continuity_unread_atoms = lag } }
  in
  let unmeasured = with_lag (make_keeper_health ~keeper_id:"alpha" ~facts:10 ~snapshot_bytes:1024) None in
  let behind = with_lag (make_keeper_health ~keeper_id:"beta" ~facts:4 ~snapshot_bytes:512) (Some 3) in
  let health : Masc.Tui_decode_memory_health.memory_health_snapshot =
    { mhs_generated_at = 1000.0
    ; mhs_keepers = [ unmeasured; behind ]
    ; mhs_refused_keepers = []
    ; mhs_total_facts = 14
    ; mhs_total_observed_facts = 14
    ; mhs_total_derived_facts = 0
    ; mhs_total_support_invalidations = 0
    ; mhs_total_snapshot_bytes = 1536
    ; mhs_total_source_facts = 0
    ; mhs_total_source_invalidations = 0
    ; mhs_total_source_snapshot_bytes = 0
    ; mhs_total_librarian_failures = 0
    ; mhs_total_librarian_unread_turns = Some 0
    ; mhs_total_librarian_continuity_unread_atoms = 3
    ; mhs_total_librarian_continuity_unmeasured = 1
    ; mhs_total_vision_ingest_errors = 0
    ; mhs_total_read_errors = 0
    ; mhs_total_source_read_errors = 0
    ; mhs_warn_alerts = 0
    ; mhs_error_alerts = 0
    ; mhs_starving_keepers = 0
    ; mhs_librarian_attention_required_keepers = 0
    }
  in
  health

let test_memory_diagnostics_escape_control_bytes () =
  let with_beta stalled =
    { fleet_health with
      Masc.Tui_decode_memory_health.mhs_keepers =
        List.map
          (fun (keeper : Masc.Tui_decode_memory_health.memory_keeper_health) ->
             if String.equal keeper.mkh_keeper_id "beta"
             then
               { keeper with
                 mkh_librarian = { keeper.mkh_librarian with Masc.Tui_decode_memory_health.mlh_stalled = Some stalled } }
             else keeper)
          fleet_health.mhs_keepers }
  in
  let render ?(stalled = Masc.Tui_decode_memory_health.Stalled_gap { mls_gap_start_atom = 2; mls_gap_end_atom = 8 })
      cursor =
    let state = make_state () in
    state.memory_health <- Some (with_beta stalled);
    state.memory_health_cursor <- cursor;
    let lines = ref [] in
    Render_memory.render_memory_body ~cols:100 ~budget:20 state
      ~push:(fun line -> lines := line :: !lines)
      ~push_styled:(fun ~style:_ line -> lines := line :: !lines)
      ~push_selected:(fun line -> lines := line :: !lines)
      ~push_divider:(fun () -> ())
      ~push_empty:(fun () -> ());
    String.concat "\n" (List.rev !lines)
  in
  let unmeasured =
    render
      ~stalled:
        (Masc.Tui_decode_memory_health.Stalled_unmeasured
           { mls_cause = Masc.Tui_decode_memory_health.Stall_read_position_unreadable; mls_detail = "bad \027[31mjson" })
      1
  in
  check bool "the reader's message is escaped" false (contains "\027[31m" unmeasured)
;;

let make_memory_fact ?(keeper = "alpha") category claim : Masc.Tui_decode_memory_facts.memory_fact =
  { mf_keeper = keeper
  ; mf_claim = claim
  ; mf_category = category
  ; mf_origin = "manual"
  ; mf_first_seen = 100.0
  ; mf_last_seen = 200.0
  ; mf_memory_id = "mem-" ^ claim
  ; mf_events = Masc.Tui_decode_memory_facts.no_memory_fact_events
  }

let three_kinds_state ?(keeper = "alpha") ?(extra_ordinary = []) () =
  let state = make_state () in
  let fact = make_memory_fact ~keeper in
  let ordinary : Masc.Tui_decode_memory_facts.memory_ordinary_store =
    { mos_facts =
        [ fact Cat.Fact "The renderer draws the board"
        ; fact Cat.Preference "Roger reads for the tester"
        ] @ extra_ordinary
    }
  in
  let source : Masc.Tui_decode_memory_facts.memory_source_store =
    { mss_facts =
        [ { msf_keeper = keeper
          ; msf_claim = "Config points at runtime.toml"
          ; msf_first_seen = 150.0
          ; msf_path = "config/rt.toml"
          ; msf_sha256 = "abc123sha"
          }
        ]
    ; mss_invalidations =
        [ { mi_keeper = keeper
          ; mi_source_path = "legacy_docs.md"
          ; mi_invalidated_at = 300.0
          ; mi_reason = "superseded"
          }
        ]
    }
  in
  answer_memory_facts state
       { mfs_keeper = keeper
       ; mfs_ordinary = Masc.Tui_decode_memory_facts.Memory_store_present ordinary
       ; mfs_source = Masc.Tui_decode_memory_facts.Memory_store_present source
       ; mfs_events_read_error = None
       };
  state.memory_facts_cursor <- 0;
  state

let test_typed_category_filters_select_fact_identities () =
  let state = three_kinds_state () in
  let verify category ordinary_ids source_paths dropped_paths =
    state.memory_facts_category <- category;
    let ordinary, source, dropped =
      List.fold_left (fun (ordinary, source, dropped) -> function
        | Types.Memory_row_fact fact -> fact.mf_memory_id :: ordinary, source, dropped
        | Types.Memory_row_source_fact fact -> ordinary, fact.msf_path :: source, dropped
        | Types.Memory_row_invalidation row -> ordinary, source, row.mi_source_path :: dropped)
        ([], [], []) (Types.memory_fact_rows state)
    in
    check (list string) "ordinary fact identities" (List.sort String.compare ordinary_ids)
      (List.sort String.compare ordinary);
    check (list string) "source fact identities" source_paths source;
    check (list string) "invalidation identities" dropped_paths dropped
  in
  verify (Types.Category_ordinary Cat.Preference)
    ["mem-Roger reads for the tester"] [] [];
  verify (Types.Category_ordinary Cat.Fact)
    ["mem-The renderer draws the board"] [] [];
  verify Types.Category_source [] ["config/rt.toml"] [];
  verify Types.Category_dropped [] [] ["legacy_docs.md"];
  verify Types.Category_all
    ["mem-Roger reads for the tester"; "mem-The renderer draws the board"]
    ["config/rt.toml"] ["legacy_docs.md"]
;;

let test_custom_category_preserves_original_identity () =
  let name = "custom_" ^ String.make 50_000 'a' in
  let category = Option.get (Cat.category_of_string name) in
  let original = make_memory_fact category "Custom category fact" in
  let state = three_kinds_state ~extra_ordinary:[original] () in
  state.memory_facts_category <- Types.Category_ordinary category;
  let verify () =
    match Types.memory_fact_rows state with
    | [Types.Memory_row_fact fact] ->
        check string "the selected fact keeps its ID" original.mf_memory_id fact.mf_memory_id;
        check string "the selected fact keeps its claim" original.mf_claim fact.mf_claim;
        (match fact.mf_category with
         | Cat.Custom _ ->
             check string "Custom preserves the entire API category" name
               (Cat.category_to_string fact.mf_category)
         | Cat.Code_change | Cat.Fact | Cat.Preference | Cat.Goal | Cat.Constraint
         | Cat.Validated_approach | Cat.Lesson | Cat.Blocker ->
             fail "Custom category changed to a built-in category")
    | [] | Types.Memory_row_fact _ :: _
    | Types.Memory_row_source_fact _ :: _ | Types.Memory_row_invalidation _ :: _ ->
        fail "typed Custom filter did not isolate its original fact"
  in
  verify ();
  fail_memory_facts_refresh state "facts load failed: HTTP 503";
  verify ()
;;

let test_memory_search_uses_the_filter_text_and_query () =
  let state = three_kinds_state () in
  state.view <- Types.Memory;
  state.memory_facts_keeper <- Some "alpha";
  let snapshot = Option.get (Types.memory_facts_snapshot state) in
  let ordinary = match snapshot.mfs_ordinary with
    | Masc.Tui_decode_memory_facts.Memory_store_present store -> store
    | _ -> fail "fixture ordinary store missing" in
  let original = List.hd ordinary.mos_facts in
  let fact = { original with mf_claim = "deploy"; mf_category = Cat.Fact;
                            mf_origin = "authored" } in
  answer_memory_facts state { snapshot with mfs_ordinary =
    Masc.Tui_decode_memory_facts.Memory_store_present { mos_facts = [fact] } };
  let verify ~typing query expected =
    state.search <- if typing then Some query else None;
    state.search_last <- if typing then "unrelated committed query" else query;
    let rows = Types.memory_fact_rows state in
    check int "filter row count" expected (List.length rows);
    check (option int) "marker agrees with filter" (Some expected)
      (Masc_tui_surface_search.surface_search_count ~cols:120 state Types.Memory ~query);
    let texts = Option.get (Masc_tui_surface_search.surface_row_texts ~cols:120 state Types.Memory) in
    let effective = Types.surface_search_query Types.Memory query in
    check int "cursor matcher reaches every filtered row" expected
      (List.length (List.filter (Masc_tui_pick_list.lowercase_contains ~needle:effective) texts))
  in
  List.iter (fun typing ->
    List.iter (fun query -> verify ~typing query 1)
      (* The category is part of a fact's search text, and it is the
         taxonomy's word now: this read "deploy note" while the fixture's
         category was the invented "note". *)
      ["deploy fact"; "  deploy fact  "; "authored";
       "runtime.toml config/rt.toml"; "superseded legacy_docs.md"];
    verify ~typing "not-present" 0) [true; false];
  state.search <- Some "   ";
  check int "blank Memory query still shows all rows" 3
    (List.length (Types.memory_fact_rows state));
  check (option int) "blank query has no matches to jump" (Some 0)
    (Masc_tui_surface_search.surface_search_count ~cols:120 state Types.Memory ~query:"   ");
  check string "other surfaces retain literal whitespace" "  deploy fact  "
    (Types.surface_search_query Types.Board "  deploy fact  ")
;;

let test_memory_keeper_search_accepts_display_words () =
  let module H = Masc.Tui_decode_memory_health in
  let state = make_state () in
  state.view <- Types.Memory;
  state.memory_overview_sort <- Types.Mem_overview_name;
  let with_pass keeper_id ending =
    let keeper = make_keeper_health ~keeper_id ~facts:10 ~snapshot_bytes:1024 in
    { keeper with mkh_librarian = { keeper.mkh_librarian with mlh_state = Some ending } } in
  let ready = with_pass "ready" H.Pass_drained in
  let empty = { ready with mkh_keeper_id = "empty"; mkh_snapshot_present = false;
    mkh_facts = 0; mkh_observed_facts = 0; mkh_snapshot_bytes = 0; mkh_added = 0;
    mkh_updated_at = None; mkh_age_bins = None } in
  state.memory_health <- Some { (make_fleet_health ready) with
    mhs_keepers = [ready; with_pass "halted" (H.Pass_stopped "addon unavailable");
      with_pass "failed" (H.Pass_raised "worker raised"); empty];
    mhs_total_facts = 30; mhs_total_observed_facts = 30; mhs_total_snapshot_bytes = 3072 };
  let verify ~typing query wanted =
    state.search <- if typing then Some query else None;
    state.search_last <- if typing then "previous query" else query;
    state.memory_health_cursor <- 0;
    let rows = Types.visible_memory_keepers state in
    check (list string) "the query selects the intended Keeper IDs" wanted
      (List.map (fun keeper -> keeper.H.mkh_keeper_id) rows);
    check (option string) "the selection decision returns the matching Keeper" (List.nth_opt wanted 0)
      (Option.map (fun keeper -> keeper.H.mkh_keeper_id) (Types.selected_memory_keeper state));
    let texts = Option.get
        (Masc_tui_surface_search.surface_row_texts ~cols:120 state Types.Memory) in
    let query = Types.surface_search_query Types.Memory query in
    let reachable = List.combine rows texts |> List.filter_map (fun (keeper, text) ->
      if Masc_tui_pick_list.lowercase_contains ~needle:query text
      then Some keeper.H.mkh_keeper_id else None) in
    check (list string) "cursor search reaches the same Keeper IDs" wanted reachable in
  List.iter (fun language ->
    state.ui_language <- language;
    List.iter (fun typing ->
      List.iter (fun (query, wanted) -> verify ~typing query wanted)
        [ "스냅샷 없음", ["empty"]; "no snapshot", ["empty"];
          "중단됨", ["halted"]; "stopped", ["halted"];
          "  STOPPED  ", ["halted"];
          "처리 실패", ["failed"]; "crashed", ["failed"];
          "기억 관측됨", ["ready"]; "memory observed", ["ready"];
          "degraded", ["failed"; "halted"]; "no-current", ["empty"];
          "ok", ["ready"]; "halted", ["halted"]; "not-present", [] ])
      [true; false])
    [Types.Lang_ko; Types.Lang_en];
  let module P = Masc.Keeper_librarian_pending in
  let worker wait : P.worker =
    { installation_id = "librarian"; request_id = "original-request"; wait } in
  let pending =
    [ "capacity", P.Worker (worker P.Capacity)
    ; "processing", P.Worker (worker P.Processing)
    ; "unknown", P.Worker (worker P.Outcome_unknown)
    ; "missing", P.Worker (worker P.Missing_after_dispatch)
    ; "offline", P.Worker (worker P.Unreachable)
    ; "recheck", P.Worker (worker P.Journal_recheck)
    ; "publication", P.Publication { request_id = "original-request"; detail = "saving" }
    ; "basis", P.Basis_changed { request_id = "original-request" }
    ; "parts", P.Message_floor { request_id = "original-request"; detail = "partial" }
    ; "recovery", P.Local_failure "read failed"
    ] in
  let admission = { ready with mkh_keeper_id = "admission";
    mkh_librarian = { ready.mkh_librarian with mlh_admission_wait = Some (P.Admission_waiting (worker P.Capacity)) } } in
  let refused = { ready with mkh_keeper_id = "refused-pass";
    mkh_librarian = { ready.mkh_librarian with
      mlh_admission_wait = Some (P.Admission_failed "pass refused") } } in
  state.memory_health <- Some { (make_fleet_health ready) with
    mhs_keepers = admission :: refused :: List.map (fun (id, pending) ->
      with_pass id (H.Pass_pending pending)) pending };
  List.iter (fun language ->
    state.ui_language <- language;
    List.iter (fun typing ->
      List.iter (fun (query, wanted) -> verify ~typing query wanted)
        [ "대기열 가득 참", ["admission"; "capacity"]; "queue full", ["admission"; "capacity"]
        ; "처리 중", ["processing"]; "processing", ["processing"]
        ; "결과 확인 필요", ["missing"; "unknown"]; "check outcome", ["missing"; "unknown"]
        ; "작업자 연결 안 됨", ["offline"]; "worker offline", ["offline"]
        ; "다시 확인 중", ["recheck"]; "rechecking", ["recheck"]
        ; "저장 확정 중", ["publication"]; "settling", ["publication"]
        ; "원문 변경됨", ["basis"]; "source changed", ["basis"]
        ; "나누어 읽는 중", ["parts"]; "reading parts", ["parts"]
        ; "복구 실패", ["recovery"]; "recovery failed", ["recovery"]
        ; "접수 실패", ["refused-pass"]; "admission failed", ["refused-pass"]
        ]) [true; false])
    [Types.Lang_ko; Types.Lang_en]
;;

let test_the_breakdown_counts_the_rows_the_screen_lists () =
  (* A filter narrows the rows; the title then says how many are left. A
     breakdown taken from the store would sum to four under a title saying
     one. *)
  let state = three_kinds_state () in
  state.search_last <- "Roger";
  check int "which is the number the title counts" 1
    (List.length (Types.memory_fact_rows state))

let test_memory_selection_follows_sort_and_filter () =
  let state = make_state () in
  let k1 = make_keeper_health ~keeper_id:"alpha" ~facts:10 ~snapshot_bytes:2048 in
  let k2 = make_keeper_health ~keeper_id:"beta" ~facts:50 ~snapshot_bytes:1024 in
  let health : Masc.Tui_decode_memory_health.memory_health_snapshot =
    { mhs_generated_at = 1000.0
    ; mhs_keepers = [ k1; k2 ]
    ; mhs_refused_keepers = []
    ; mhs_total_facts = 60
    ; mhs_total_observed_facts = 60
    ; mhs_total_derived_facts = 0
    ; mhs_total_support_invalidations = 0
    ; mhs_total_snapshot_bytes = 3072
    ; mhs_total_source_facts = 0
    ; mhs_total_source_invalidations = 0
    ; mhs_total_source_snapshot_bytes = 0
    ; mhs_total_librarian_failures = 0
    ; mhs_total_librarian_unread_turns = Some 0
    ; mhs_total_librarian_continuity_unread_atoms = 0
    ; mhs_total_librarian_continuity_unmeasured = 0
    ; mhs_total_vision_ingest_errors = 0
    ; mhs_total_read_errors = 0
    ; mhs_total_source_read_errors = 0
    ; mhs_warn_alerts = 0
    ; mhs_error_alerts = 0
    ; mhs_starving_keepers = 0
    ; mhs_librarian_attention_required_keepers = 0
    }
  in
  state.memory_health <- Some health;
  state.memory_overview_sort <- Types.Mem_overview_facts;
  let selected () = Option.map (fun k -> k.Masc.Tui_decode_memory_health.mkh_keeper_id) (Types.selected_memory_keeper state) in
  check (option string) "the selection decision follows fact order" (Some "beta") (selected ());
  state.memory_overview_sort <- Types.Mem_overview_size;
  check (option string) "the selection decision follows size order" (Some "alpha") (selected ());
  state.search_last <- "beta";
  state.memory_health_cursor <- 99;
  check (option string) "the selection decision clamps to the matching Keeper" (Some "beta") (selected ());
  state.search_last <- "";
  state.memory_health_cursor <- 0;
  state.memory_health <- Some { health with mhs_keepers =
      [{ k1 with mkh_updated_at = None }; { k2 with mkh_updated_at = Some 1700000000. }] };
  state.memory_overview_sort <- Types.Mem_overview_updated;
  check (option string) "known dates sort before absent snapshots" (Some "beta") (selected ())
;;

let test_retained_health_filter_keeps_the_selected_owner () =
  let state = make_state () in
  state.view <- Types.Memory;
  state.memory_overview_sort <- Types.Mem_overview_name;
  let keepers = List.init 5 (fun index ->
    let keeper = make_keeper_health ~keeper_id:(Printf.sprintf "keeper-%d" index)
        ~facts:10 ~snapshot_bytes:1024 in
    if index <> 4 then keeper else
      { keeper with mkh_source_read_error = Some "unreadable source snapshot" }) in
  let health = { (make_fleet_health (List.hd keepers)) with
    mhs_keepers = keepers; mhs_total_facts = 50; mhs_total_observed_facts = 50;
    mhs_total_snapshot_bytes = 5120; mhs_total_source_read_errors = 1 } in
  state.memory_health <- Some health;
  let selected () = Option.map (fun keeper -> keeper.Masc.Tui_decode_memory_health.mkh_keeper_id)
      (Types.selected_memory_keeper state) in
  state.memory_health_cursor <- -1;
  check (option string) "a negative cursor selects the first Keeper" (Some "keeper-0") (selected ());
  state.memory_health_cursor <- 99;
  check (option string) "an excessive cursor selects the last Keeper" (Some "keeper-4") (selected ());
  state.memory_health_error <- Some "refresh failed";
  state.search_last <- "keeper-4";
  check (list string) "a retained snapshot still filters by Keeper identity" ["keeper-4"]
    (List.map (fun keeper -> keeper.Masc.Tui_decode_memory_health.mkh_keeper_id)
       (Types.visible_memory_keepers state));
  check (option string) "filtering retained health keeps the requested owner" (Some "keeper-4")
    (selected ());
  check (option string) "the selected owner's source read error remains known"
    (Some "unreadable source snapshot")
    (Option.bind (Types.selected_memory_keeper state) (fun keeper -> keeper.mkh_source_read_error));
  state.search_last <- "not-present";
  check (option string) "an unmatched query has no fallback owner" None (selected ());
  check bool "search does not replace the retained health data" true
    (state.memory_health = Some health);
  check (option string) "search does not clear the refresh failure" (Some "refresh failed")
    state.memory_health_error
;;

let test_a_failed_facts_refresh_keeps_facts_and_unread_scope () =
  let module F = Masc.Tui_decode_memory_facts in
  let state = three_kinds_state () in
  let complete = Option.get (Types.memory_facts_snapshot state) in
  let partial = { complete with
    F.mfs_ordinary = F.Memory_store_read_error "ordinary snapshot unreadable";
    mfs_events_read_error = Some "memory events unreadable" } in
  List.iter (fun snapshot ->
    answer_memory_facts state snapshot;
    let before = Types.memory_fact_rows state in
    let failure = "facts load failed: HTTP 503" in
    fail_memory_facts_refresh state failure;
    check bool "failed refresh retains the original fact identities and values" true
      (Types.memory_fact_rows state = before);
    check bool "failed refresh retains the original stores and unread scopes" true
      (Types.memory_facts_snapshot state = Some snapshot);
    check (option string) "the refresh failure remains separate from retained data" (Some failure)
      (Types.memory_facts_failure state);
    check bool "the failed refresh is a retained observation" true
      (Types.memory_facts_view state = Masc_tui_fetched.Stale ((snapshot, None), failure)))
    [complete; partial];
  let retained = Option.get (Types.memory_facts_snapshot state) in
  check (option int) "an unread ordinary store has no measured fact count" None
    (F.memory_fact_count ~complete:true retained (F.Ordinary_facts None));
  check (option int) "the readable source store retains its measured count" (Some 1)
    (F.memory_fact_count ~complete:true retained F.Source_facts);
  check (option int) "the readable invalidation store retains its measured count" (Some 1)
    (F.memory_fact_count ~complete:true retained F.Dropped_facts);
  check (option int) "partial store failure keeps the all-facts count unknown" None
    (F.memory_fact_count ~complete:true retained F.All_facts);
  let fleet, unread = F.merge_keeper_memory_facts
      ~refused:[{ Masc.Tui_decode_memory_health.mkr_keeper_id = Some "beta";
                  mkr_reason = "invalid health payload" }]
      ["alpha", Ok complete] in
  check bool "the fleet fixture has an unread scope" true (Option.is_some unread);
  answer_memory_facts ?unread state fleet;
  let failure = "fleet refresh failed: HTTP 503" in
  fail_memory_facts_refresh state failure;
  check bool "failed fleet refresh retains facts with their unread summary" true
    (Types.memory_facts_view state = Masc_tui_fetched.Stale ((fleet, unread), failure));
  List.iter (fun scope ->
    check (option int) "an incomplete retained fleet has no measured total" None
      (F.memory_fact_count ~complete:(Option.is_none unread) fleet scope))
    [F.All_facts; F.Ordinary_facts None; F.Source_facts; F.Dropped_facts]
;;

let test_memory_row_visibility () =
  let shown kind =
    match Render_memory.memory_row_visibility kind with
    | Render_memory.Shown_by_default -> true
    | Render_memory.Detail_only -> false
  in
  List.iter
    (fun (label, kind, expected) -> check bool label expected (shown kind))
    [ "an unread lag is shown, not folded to zero", Render_memory.Row_lag None, true
    ; "a lag of 3 is shown", Render_memory.Row_lag (Some 3), true
    ; "a lag of 0 waits for detail", Render_memory.Row_lag (Some 0), false
    ; "3 Librarian failures are shown", Render_memory.Row_librarian_failures 3, true
    ; "0 Librarian failures wait for detail", Render_memory.Row_librarian_failures 0, false
    ]
;;

let test_memory_state_tracks_current_pass_not_history () =
  let module H = Masc.Tui_decode_memory_health in
  let base = make_keeper_health ~keeper_id:"recovered" ~facts:10 ~snapshot_bytes:262144 in
  let recovered = { base with H.mkh_librarian_failures = 3 } in
  check bool "history does not keep a recovered snapshot degraded" true
    (Types.memory_state recovered = Types.Memory_ordinary);
  let stopped = { base with H.mkh_librarian =
      { base.mkh_librarian with H.mlh_state = Some (H.Pass_stopped "model unavailable") } } in
  check bool "current error is visible before a counter update" true
    (Types.memory_state stopped = Types.Memory_degraded);
  check bool "empty current failure is starving" true
    (Types.memory_state { stopped with H.mkh_snapshot_present = false } = Types.Memory_starving);
  check bool "empty recovered memory is not starving from historical failures" true
    (Types.memory_state { recovered with H.mkh_snapshot_present = false } = Types.Memory_no_current);
  check bool "store read error overrides a recovered pass" true
    (Types.memory_state { recovered with H.mkh_read_error = Some "EACCES" } = Types.Memory_read_error);
  let empty_recovered = { recovered with H.mkh_snapshot_present = false } in
  let source_only = { empty_recovered with H.mkh_source_snapshot_present = true } in
  let stopped_empty = { stopped with H.mkh_snapshot_present = false } in
  List.iter (fun (keeper, expected) ->
    check (option int) "fleet count follows current row state" (Some expected)
      (Types.current_memory_starving_count (make_fleet_health keeper)))
    [empty_recovered, 0; source_only, 0; stopped_empty, 1];
  check bool "failure-history alert does not color current memory as an error" true
    (H.memory_alert_is_history H.Librarian_starvation
     && H.memory_alert_is_history H.Librarian_failures);
  check bool "current store read errors retain error semantics" false
    (H.memory_alert_is_history H.Snapshot_read_error);
  let refused = { (make_fleet_health recovered) with H.mhs_refused_keepers =
      [{ H.mkr_keeper_id = Some "unread"; mkr_reason = "invalid payload" }] } in
  check (option int) "refused rows keep fleet count unknown" None
    (Types.current_memory_starving_count refused)
;;

let test_memory_refresh_keeps_the_selected_keeper () =
  let module H = Masc.Tui_decode_memory_health in
  let keeper name facts =
    make_keeper_health ~keeper_id:name ~facts ~snapshot_bytes:1024
  in
  let alpha = keeper "alpha" 20 in
  let health keepers = { (make_fleet_health alpha) with H.mhs_keepers = keepers } in
  List.iter (fun query ->
    let state = make_state () in
    state.memory_overview_sort <- Types.Mem_overview_facts;
    state.search_last <- query;
    Types.apply_memory_health_snapshot state
      (health [alpha; keeper "beta" 10; keeper "gamma" 5; keeper "hidden" 0]);
    let selected_id () =
      Option.map (fun row -> row.H.mkh_keeper_id) (Types.selected_memory_keeper state)
    in
    check (option string) "start on alpha" (Some "alpha") (selected_id ());
    let usage : Masc_tui_memory_usage.t =
      { records = 1
      ; tokens =
          { distribution = Some { samples = 1; mean = 100.; minimum = 100; maximum = 100 }
          ; last = Some 100 }
      ; bytes = { distribution = None; last = None }
      }
    in
    let request =
      match Masc_tui_fetched.start ~equal:String.equal state.memory_input ~key:"alpha" with
      | Already_loading -> fail "fresh fixture was loading"
      | Started (next, request) -> state.memory_input <- next; request
    in
    Types.apply_memory_health_snapshot state
      (health [alpha; keeper "beta" 30; keeper "gamma" 25; keeper "hidden" 100]);
    check (option string) "ranking changes keep the selected Keeper" (Some "alpha")
      (selected_id ());
    state.memory_input <-
      Masc_tui_fetched.complete ~equal:String.equal state.memory_input request (Ok usage);
    check bool "the pending input still belongs to the selected Keeper" true
      (Masc_tui_fetched.view_for ~equal:String.equal state.memory_input
         ~key:(Option.get (selected_id ())) = Ready usage);
    Types.apply_memory_health_snapshot state
      (health [keeper "beta" 30; keeper "gamma" 25; keeper "hidden" 100]);
    check (option string) "removal clamps to the last visible Keeper" (Some "gamma")
      (selected_id ());
    check int "removed selection leaves an in-range cursor"
      (List.length (Types.visible_memory_keepers state) - 1) state.memory_health_cursor;
    check bool "removed Keeper input cannot appear under the fallback selection" true
      (Masc_tui_fetched.view_for ~equal:String.equal state.memory_input ~key:"gamma" = Absent);
    Types.apply_memory_health_snapshot state (health []);
    check (option string) "empty refreshed roster has no selection" None (selected_id ());
    check int "empty refreshed roster resets the cursor" 0 state.memory_health_cursor)
    [""; "a"]
;;

let () =
  run "tui_render_memory"
    [ "input statistics",
      [ test_case "refresh preserves Keeper selection" `Quick
          test_memory_refresh_keeps_the_selected_keeper ]
    ; "terminal safety",
      [ test_case "fact detail escapes wire controls and preserves API values" `Quick
          test_detail_escapes_wire_controls_without_changing_facts
      ; test_case "Librarian diagnostics escape wire controls" `Quick
          test_memory_diagnostics_escape_control_bytes ]
    ; "memory decisions",
      [ test_case "memory recovery does not inherit historical failure state" `Quick
          test_memory_state_tracks_current_pass_not_history
      ; test_case "the row classifier keeps unread readings as actions" `Quick
          test_memory_row_visibility
      ; test_case "selection follows sort and filter" `Quick
          test_memory_selection_follows_sort_and_filter
      ; test_case "retained health filter preserves the selected owner" `Quick
          test_retained_health_filter_keeps_the_selected_owner
      ; test_case "typed category filters select fact identities" `Quick
          test_typed_category_filters_select_fact_identities
      ; test_case "Custom category preserves its original identity" `Quick
          test_custom_category_preserves_original_identity
      ; test_case "failed facts refresh retains facts and unread scope" `Quick
          test_a_failed_facts_refresh_keeps_facts_and_unread_scope ]
    ; "one place per fact",
      [ test_case "search count and cursor share Memory filter text and query" `Quick
          test_memory_search_uses_the_filter_text_and_query
      ; test_case "Keeper queries accept canonical and both display languages" `Quick
          test_memory_keeper_search_accepts_display_words
      ; test_case "the breakdown counts the rows the screen lists" `Quick
          test_the_breakdown_counts_the_rows_the_screen_lists ]
    ]
;;
