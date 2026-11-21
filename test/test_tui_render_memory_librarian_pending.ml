open Alcotest
module Types = Masc_tui_types

let make_state () =
  Types.create_state ~workspace:"" ~port:0 ()
;;

let make_keeper_health ~keeper_id ~facts ~snapshot_bytes : Masc.Tui_decode_memory_health.memory_keeper_health =
  { (Memory_keeper_health_fixture.keeper_without_source ~keeper_id ~facts ~snapshot_bytes) with
    mkh_observed_facts = facts
  ; mkh_derived_facts = 0
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
    [ "processing", P.Worker (worker P.Processing)
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
    mkh_librarian = { ready.mkh_librarian with mlh_admission_wait = Some (P.Admission_waiting (worker P.Processing)) } } in
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
        [ "처리 중", ["admission"; "processing"]; "processing", ["admission"; "processing"]
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

let () =
  run "tui_render_memory_librarian_pending"
    [ "one place per fact",
      [ test_case "Keeper queries accept canonical and both display languages" `Quick
          test_memory_keeper_search_accepts_display_words
      ]
    ]
;;
