open Alcotest
open Masc_tui_types
module Usage = Masc.Tui_decode_usage
module Trend = Masc_tui_usage_trend

let account id : Usage.provider_usage_account =
  { pua_scope="runtime-owned-" ^ id; pua_scope_id=id;
    pua_providers=[{pup_id="provider-" ^ id;pup_display_name="Same display name"}];
    pua_state=Account_not_reported_since_start }

let history_row id : Trend.row =
  {scope_id=id; kind="window";limit_id=None;marks="";samples=[];reported_days=0}

let state () =
  let state = create_state ~workspace:"usage-scope-test" ~port:8935 ~refresh_interval:2. () in
  state.overview_providers <- Providers_read {puws_since=123.;puws_accounts=[account "A";account "B"]};
  state.provider_history <- Provider_history_read
      {days=7;generated_at=456.;unreadable_reports=2;rows=[history_row "B";history_row "historical-only"]};
  state.usage_scope_id <- Some "B";
  state

let test_exact_scope_filters_both_sources () =
  let state = state () in
  (match usage_providers_reading state with
   | Providers_read reading ->
       check (list string) "opaque account id owns Plan" ["B"]
         (List.map (fun account -> account.Usage.pua_scope_id) reading.puws_accounts);
       check (float 0.) "process provenance retained" 123. reading.puws_since
   | Providers_unread | Providers_failed _ -> fail "lost account reading");
  (match usage_history_reading state with
   | Provider_history_read trend ->
       check (list string) "same opaque id owns Trend" ["B"] (List.map (fun row -> row.Trend.scope_id) trend.rows);
       check int "unreadable history is not hidden" 2 trend.unreadable_reports;
       check (float 0.) "observation provenance retained" 456. trend.generated_at
   | Provider_history_unread | Provider_history_error _ -> fail "lost history reading");
  check (list string) "historical accounts remain selectable" ["A";"B";"historical-only"]
    (usage_scope_ids state)

let test_refresh_does_not_choose_another_account () =
  let state = state () in
  state.overview_providers <- Providers_read {puws_since=789.;puws_accounts=[account "A"]};
  state.usage_section <- Usage_trend;
  state.provider_history_days <- 14;
  check (option string) "view and window retain chosen id" (Some "B") state.usage_scope_id;
  (match usage_providers_reading state with
   | Providers_read reading -> check int "missing id is not a replacement" 0 (List.length reading.puws_accounts)
   | Providers_unread | Providers_failed _ -> fail "lost inventory");
  check bool "history-only selection is executable" true
    (List.exists (fun (_,action) -> action=Masc_tui_palette.Palette_usage_scope (Some "historical-only"))
       (Masc_tui_palette.palette_entries state))

let test_failed_and_unread_sources_stay_failed_and_unread () =
  let state = state () in
  state.overview_providers <- Providers_failed "plan read refused";
  state.provider_history <- Provider_history_error "history read refused";
  check bool "Plan failure is not an empty successful filter" true
    (usage_providers_reading state=state.overview_providers);
  check bool "Trend failure is not an empty successful filter" true
    (usage_history_reading state=state.provider_history);
  state.overview_providers <- Providers_unread;
  state.provider_history <- Provider_history_unread;
  check bool "Plan remains unread" true (usage_providers_reading state=Providers_unread);
  check bool "Trend remains unread" true (usage_history_reading state=Provider_history_unread)

let test_email_search_keeps_exact_target () =
  let state = state () in
  state.overview_account_emails <- Account_emails_read
      {emails=["provider-A","first@example.test";"provider-B","chosen@example.test"];unreadable_rows=0};
  state.palette_query <- "chosen@example.test";
  check bool "email search resolves the stored account id" true
    (List.exists (fun (_,action) -> action=Masc_tui_palette.Palette_usage_scope (Some "B"))
       (Masc_tui_palette.palette_matches state))

let () = run "usage account continuity"
  ["scope", [test_case "exact source identity" `Quick test_exact_scope_filters_both_sources;
             test_case "refresh and window continuity" `Quick test_refresh_does_not_choose_another_account;
             test_case "source failures" `Quick test_failed_and_unread_sources_stay_failed_and_unread;
             test_case "email search target" `Quick test_email_search_keeps_exact_target]]
