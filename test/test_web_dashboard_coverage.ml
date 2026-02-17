(** Web_dashboard Module Coverage Tests

    Tests for MASC Web Dashboard:
    - html: dashboard HTML generation
*)

open Alcotest

module Web_dashboard = Masc_mcp.Web_dashboard

let contains_re re s =
  try
    let _ = Str.search_forward (Str.regexp re) s 0 in
    true
  with Not_found -> false

let contains_re_ci re s =
  try
    let _ = Str.search_forward (Str.regexp_case_fold re) s 0 in
    true
  with Not_found -> false

let contains_substr sub s =
  try
    let _ = Str.search_forward (Str.regexp_string sub) s 0 in
    true
  with Not_found -> false

(* ============================================================
   html Tests
   ============================================================ *)

let test_html_nonempty () =
  let html = Web_dashboard.html () in
  check bool "nonempty" true (String.length html > 0)

let test_html_starts_with_doctype () =
  let html = Web_dashboard.html () in
  check bool "doctype" true
    (String.length html >= 15 && String.sub html 0 15 = "<!DOCTYPE html>")

let test_html_contains_head () =
  let html = Web_dashboard.html () in
  check bool "has head" true (String.length html > 0)

let test_html_contains_body () =
  let html = Web_dashboard.html () in
  check bool "has body" true (String.length html > 0)

let test_html_contains_title () =
  let html = Web_dashboard.html () in
  check bool "has MASC title" true
    (String.length html > 0 && contains_re "MASC" html)

let test_html_contains_style () =
  let html = Web_dashboard.html () in
  check bool "has style" true
    (String.length html > 0 && contains_re "<style>" html)

let test_html_contains_script () =
  let html = Web_dashboard.html () in
  check bool "has script" true
    (String.length html > 0 && contains_re "<script>" html)

let test_html_valid_length () =
  let html = Web_dashboard.html () in
  (* Dashboard HTML should be substantial *)
  check bool "reasonable length" true (String.length html > 1000)

let test_html_ends_with_html_tag () =
  let html = Web_dashboard.html () in
  let trimmed = String.trim html in
  let len = String.length trimmed in
  check bool "ends with </html>" true
    (len >= 7 && String.sub trimmed (len - 7) 7 = "</html>")

let test_html_contains_sse () =
  let html = Web_dashboard.html () in
  (* Dashboard should reference SSE for real-time updates *)
  check bool "references SSE" true
    (String.length html > 0 && contains_re_ci "sse\\|eventsource" html)

let test_html_contains_keeper_state_query_params () =
  let html = Web_dashboard.html () in
  check bool "keeper query params" true
    (String.length html > 0
    && contains_re "keeper_field_query" html
    && contains_re "keeper_kpi" html)

let test_html_contains_keeper_kpi_interaction () =
  let html = Web_dashboard.html () in
  check bool "keeper kpi interaction" true
    (String.length html > 0
    && contains_re "setKeeperSelectedKpi" html
    && contains_re "keeper-kpi\\.selected" html)

let test_html_contains_meta_localizer () =
  let html = Web_dashboard.html () in
  check bool "keeper meta localizer" true
    (String.length html > 0
    && contains_re "localizeKeeperMetaLabels" html
    && contains_re "keeperMetaLabelKo" html)

let test_html_contains_life_state_normalizer () =
  let html = Web_dashboard.html () in
  check bool "keeper payload normalizer" true
    (String.length html > 0
    && contains_substr "function normalizeKeeperPayload(payload)" html
    && contains_substr "if (Array.isArray(payload)) return payload;" html
    && contains_substr "if (payload && Array.isArray(payload.keepers)) return payload.keepers;" html)

let test_html_notify_uses_normalized_payload () =
  let html = Web_dashboard.html () in
  check bool "keeper notify uses normalized payload" true
    (String.length html > 0
    && contains_substr "notifyKeeperAlerts(normalizeKeeperPayload(data.keepers))" html
    && contains_substr "function notifyKeeperAlerts(keepersPayload)" html
    && contains_substr "const keepers = normalizeKeeperPayload(keepersPayload)" html)

let test_html_life_state_pills_present () =
  let html = Web_dashboard.html () in
  check bool "life state pills in keeper cards" true
    (String.length html > 0
    && contains_re "lifeState\\.staleState" html
    && contains_re "staleState === 'bad'" html
    && contains_re "life_status" html
    && contains_re "Life Pulse" html)

let test_html_contains_trpg_round_run_controls () =
  let html = Web_dashboard.html () in
  check bool "trpg round run controls" true
    (String.length html > 0
    && contains_substr "id=\"trpg-run-round-btn\"" html
    && contains_substr "id=\"trpg-dm-keeper-input\"" html
    && contains_substr "id=\"trpg-player-keepers-input\"" html
    && contains_substr "function runTrpgRound(options = {})" html
    && contains_substr "/api/v1/trpg/rounds/run" html)

let test_html_contains_trpg_keeper_quickpick_and_lang () =
  let html = Web_dashboard.html () in
  check bool "trpg keeper quickpick + lang" true
    (String.length html > 0
    && contains_substr "id=\"trpg-lang-select\"" html
    && contains_substr "id=\"trpg-reload-btn\"" html
    && contains_substr "id=\"trpg-bootstrap-run-round1\"" html
    && contains_substr "id=\"trpg-keeper-quick\"" html
    && contains_substr "function ensureTrpgKeeperCatalog(force = false)" html
    && contains_substr "function reloadTrpgCatalogs()" html)

let test_html_contains_trpg_session_history_and_assignment () =
  let html = Web_dashboard.html () in
  check bool "trpg session/history/assignment panels" true
    (String.length html > 0
    && contains_substr "id=\"trpg-session-meta\"" html
    && contains_substr "id=\"trpg-party-assignment\"" html
    && contains_substr "id=\"trpg-actor-browser\"" html
    && contains_substr "id=\"trpg-game-history\"" html
    && contains_substr "function trpgBuildSessionHistory(events)" html
    && contains_substr "function trpgPartyActorsFromStateOrEvents(state, events)" html
    && contains_substr "function trpgActorsFromStateOrEvents(state, events)" html
    && contains_substr "function renderTrpgActorBrowser(state, events)" html
    && contains_substr "function loadTrpgActorToForm(token)" html
    && contains_substr "function quickClaimTrpgActor(token)" html
    && contains_substr "function quickReleaseTrpgActor(token)" html
    && contains_substr "function trpgActorClaimCall(args)" html
    && contains_substr "function trpgActorReleaseCall(args)" html
    && contains_substr "Actor claim 완료" html
    && contains_substr "Actor release 완료" html
    && contains_substr "function renderTrpgSessionMeta(_state, events, summary, phase)" html
    && contains_substr "function renderTrpgPartyAssignment(state, events)" html
    && contains_substr "function renderTrpgGameHistory(events)" html)

let test_html_contains_trpg_next_action_guide () =
  let html = Web_dashboard.html () in
  check bool "trpg next action guide" true
    (String.length html > 0
    && contains_substr "id=\"trpg-next-action\"" html
    && contains_substr "id=\"trpg-next-action-desc\"" html
    && contains_substr "id=\"trpg-next-action-target\"" html
    && contains_substr "function trpgSetNextAction(kind, label, desc, enabled = true)" html
    && contains_substr "function trpgUpdateNextAction(state, events)" html
    && contains_substr "function trpgSanitizeNarrative(raw)" html)

let test_html_contains_keeper_goal_horizon_kpis () =
  let html = Web_dashboard.html () in
  check bool "keeper goal horizon kpis" true
    (String.length html > 0
    && contains_substr "'short_goal'" html
    && contains_substr "'mid_goal'" html
    && contains_substr "'long_goal'" html
    && contains_substr "Short Goal" html
    && contains_substr "Mid Goal" html
    && contains_substr "Long Goal" html)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Web_dashboard Coverage" [
    "html", [
      test_case "nonempty" `Quick test_html_nonempty;
      test_case "doctype" `Quick test_html_starts_with_doctype;
      test_case "head" `Quick test_html_contains_head;
      test_case "body" `Quick test_html_contains_body;
      test_case "title" `Quick test_html_contains_title;
      test_case "style" `Quick test_html_contains_style;
      test_case "script" `Quick test_html_contains_script;
      test_case "valid length" `Quick test_html_valid_length;
      test_case "ends with html" `Quick test_html_ends_with_html_tag;
      test_case "contains sse" `Quick test_html_contains_sse;
      test_case "keeper query params" `Quick test_html_contains_keeper_state_query_params;
      test_case "keeper kpi interaction" `Quick test_html_contains_keeper_kpi_interaction;
      test_case "keeper meta localizer" `Quick test_html_contains_meta_localizer;
      test_case "life state normalizer" `Quick test_html_contains_life_state_normalizer;
      test_case "notify uses normalized payload" `Quick test_html_notify_uses_normalized_payload;
      test_case "life state pills" `Quick test_html_life_state_pills_present;
      test_case "trpg round run controls" `Quick test_html_contains_trpg_round_run_controls;
      test_case
        "trpg keeper quickpick + lang"
        `Quick
        test_html_contains_trpg_keeper_quickpick_and_lang;
      test_case
        "trpg session/history/assignment panels"
        `Quick
        test_html_contains_trpg_session_history_and_assignment;
      test_case
        "trpg next action guide"
        `Quick
        test_html_contains_trpg_next_action_guide;
      test_case "keeper goal horizon kpis" `Quick test_html_contains_keeper_goal_horizon_kpis;
    ];
  ]
