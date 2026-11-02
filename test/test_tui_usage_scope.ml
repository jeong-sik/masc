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

let test_workspace_replacement_retires_usage () =
  let state = state () in
  let transport : Masc.Tui_decode.transport_health =
    { th_primary_path=Masc.Transport_metrics.Sse; th_queue_pressure=Steady;
      th_sse_sessions=1; th_websocket_sessions=None; th_grpc_port=None; th_events_dropped=0 } in
  state.transport <- Some transport;
  state.overview_quota <- Quota_read [];
  state.keeper_usage <- Keeper_usage_read Usage.Keeper_usage_loading;
  state.overview_account_emails <- Account_emails_read
      {emails=["provider-B", "fictional@example.test"]; unreadable_rows=0};
  state.usage_section <- Usage_trend;
  state.provider_history_days <- 7;
  state.metrics_scroll <- 42;
  state.metrics_content_height <- 12;
  state.metrics_scroll_card_rows <- Some 3;
  let previous_history = state.provider_history in
  let previous_providers = state.overview_providers in
  let previous_emails = state.overview_account_emails in
  let previous_reading = state.workspace_read_authority in
  state.workspace_identity <- Workspace_identity_match_unconfirmed "temporarily unavailable";
  suspend_workspace_readings state;
  check bool "an unconfirmed identity preserves the last observations" true
    (state.provider_history == previous_history
     && state.overview_providers == previous_providers
     && state.overview_account_emails == previous_emails
     && state.transport = Some transport
     && state.overview_quota = Quota_read []
     && state.keeper_usage = Keeper_usage_read Usage.Keeper_usage_loading);
  check bool "an unconfirmed identity retires old read authority" true
    (state.workspace_read_authority != previous_reading);
  withdraw_usage_workspace state;
  check bool "replacement retires every workspace usage observation" true
    (state.transport = None && state.transport_error = None
     && state.overview_quota = Quota_unread
     && state.overview_providers = Providers_unread
     && state.keeper_usage = Keeper_usage_unread
     && state.provider_history = Provider_history_unread
     && state.overview_account_emails = Account_emails_unread);
  check bool "replacement clears the old selection and scroll" true
    (state.usage_scope_id = None && state.metrics_scroll = 0
     && state.metrics_content_height = 0 && state.metrics_scroll_card_rows = None);
  check bool "the reader's view and period survive" true
    (state.usage_section = Usage_trend && state.provider_history_days = 7);
  state.provider_history <- Provider_history_read
      {days=7;generated_at=789.;unreadable_reports=0;rows=[history_row "new-workspace"]};
  check bool "a new history can arrive without restoring old account data" true
    (state.overview_providers = Providers_unread
     && state.overview_account_emails = Account_emails_unread
     && match usage_history_reading state with
        | Provider_history_read trend ->
            List.map (fun row -> row.Trend.scope_id) trend.rows = ["new-workspace"]
        | Provider_history_unread | Provider_history_error _ -> false)

let test_workspace_replacement_rereads_superseded_usage () =
  let state = state () in
  let module Order = Surface_read_order in
  state.view <- Metrics;
  let needs = surface_needs_of_surface Metrics in
  let reads, full = Order.dispatch ~kind:Order.Full ~needs ~started_ns:0L Order.initial in
  let reads, old_navigation = Order.dispatch ~kind:Order.Navigation ~needs ~started_ns:1L reads in
  state.http_surface_reads <- reads;
  let reads, owned = Order.take state.http_surface_reads full in
  state.http_surface_reads <- reads;
  check bool "the older navigation displaced the full usage result" false
    (List.mem Order.Runtime_quota_data owned || List.mem Order.Provider_history_data owned);
  check bool "the old navigation still owns its in-flight datasets" true
    (Order.owns_dataset state.http_surface_reads old_navigation Order.Runtime_quota_data);
  withdraw_usage_workspace state;
  state.workspace_identity <- Workspace_identity_mismatch
      {local_base_path="/workspace/a";server_base_path="/workspace/b"};
  check bool "a moved workspace rereads its unobserved Usage" true
    (revalidate_workspace_surfaces state ~workspace_moved:true ~needs);
  check bool "no move does not repeatedly revalidate" false
    (revalidate_workspace_surfaces state ~workspace_moved:false ~needs);
  let reads, fresh = Order.dispatch ~kind:Order.Full ~needs ~started_ns:2L state.http_surface_reads in
  check bool "new read owns the current workspace datasets" true
    (Order.owns_dataset reads fresh Order.Runtime_quota_data
     && Order.owns_dataset reads fresh Order.Provider_history_data
     && not (Order.owns_dataset reads old_navigation Order.Runtime_quota_data)
     && not (Order.owns_dataset reads old_navigation Order.Provider_history_data));
  state.overview_quota <- Quota_failed "runtime unavailable";
  state.transport_error <- Some "transport unavailable";
  state.overview_providers <- Providers_failed "providers unavailable";
  state.keeper_usage <- Keeper_usage_error "keeper usage unavailable";
  state.provider_history <- Provider_history_error "history unavailable";
  state.overview_account_emails <- Account_emails_failed "accounts unavailable";
  check bool "settled failures do not trigger another reread" false
    (revalidate_workspace_surfaces state ~workspace_moved:true ~needs);
  state.provider_history <- Provider_history_unread;
  check bool "a single missing dataset needs revalidation" true
    (revalidate_workspace_surfaces state ~workspace_moved:true ~needs);
  let hidden_needs = surface_needs_of_surface Overview in
  check bool "a hidden Usage surface does not trigger the mismatch reread" false
    (revalidate_workspace_surfaces state ~workspace_moved:true ~needs:hidden_needs);
  state.workspace_identity <- Workspace_identity_match;
  check bool "the existing matched-workspace revalidation remains" true
    (revalidate_workspace_surfaces state ~workspace_moved:true ~needs:hidden_needs);
  state.workspace_identity <- Workspace_identity_match_unconfirmed "offline";
  check bool "an unconfirmed identity does not start a read" false
    (revalidate_workspace_surfaces state ~workspace_moved:true ~needs)

let test_shared_accounts_and_server_logs_revalidate () =
  let state = state () in
  let module Order = Surface_read_order in
  let config_needs = surface_needs_of_surface Config in
  let usage_needs = surface_needs_of_surface Metrics in
  let reads, full = Order.dispatch ~kind:Order.Full ~needs:config_needs ~started_ns:0L Order.initial in
  let reads, _old_navigation = Order.dispatch ~kind:Order.Navigation ~needs:config_needs ~started_ns:1L reads in
  let _, owned = Order.take reads full in
  check bool "the prior navigation displaced the account result" false
    (List.mem Order.Account_emails_data owned);
  withdraw_usage_workspace state;
  state.workspace_identity <- Workspace_identity_mismatch
      {local_base_path="/workspace/a";server_base_path="/workspace/b"};
  check bool "Config rereads its missing accounts" true
    (revalidate_workspace_surfaces state ~workspace_moved:true ~needs:config_needs);
  let delta = surface_needs_delta ~previous:config_needs ~next:usage_needs in
  check bool "entering Usage would not request the shared accounts again" false
    delta.needs_account_emails;
  state.overview_account_emails <- Account_emails_failed "accounts unavailable";
  check bool "a settled account failure does not reread hidden Usage" false
    (revalidate_workspace_surfaces state ~workspace_moved:true ~needs:config_needs);
  let logs_needs = surface_needs_of_surface System_logs in
  check bool "unread server logs are also recovered" true
    (revalidate_workspace_surfaces state ~workspace_moved:true ~needs:logs_needs);
  check bool "local TUI logs do not request server logs" false
    (revalidate_workspace_surfaces state ~workspace_moved:true
       ~needs:{logs_needs with needs_system_logs=false});
  state.system_logs <- System_logs_view.apply Server (Error "logs unavailable") state.system_logs;
  check bool "a settled server-log failure does not retry" false
    (revalidate_workspace_surfaces state ~workspace_moved:true ~needs:logs_needs)

let test_window_change_replaces_only_its_history_request () =
  let state = state () in
  let module Order = Surface_read_order in
  state.view <- Metrics;
  let initial_needs = { nothing with needs_provider_history=true; needs_keeper_usage=true } in
  let reads, original = Order.dispatch ~kind:Order.Full ~needs:initial_needs
      ~started_ns:0L Order.initial in
  let advance reads =
    let needs = cycle_usage_history_window state in
    Order.dispatch ~kind:Order.Navigation ~needs ~started_ns:1L reads
  in
  let reads, first = advance reads in
  check int "select the next period" 1 state.provider_history_days;
  check (option string) "period change retains the chosen account" (Some "B") state.usage_scope_id;
  check bool "only the new history is pending" true
    (Order.pending_scoped ~needs:initial_needs reads = [Order.Provider_history]);
  check bool "old history cannot populate the new period" false
    (Order.owns_dataset reads original Order.Provider_history_data);
  check bool "unrelated usage keeps its original request" true
    (Order.owns_dataset reads original Order.Keeper_usage_data);
  let reads, _ = advance reads in
  let reads, latest = advance reads in
  check int "cycling returns to the original period" 14 state.provider_history_days;
  check bool "same days do not revive an old request" false
    (Order.owns_dataset reads original Order.Provider_history_data);
  check bool "the intermediate period is superseded" false
    (Order.owns_dataset reads first Order.Provider_history_data);
  let reads, accepted = Order.take_dataset reads latest Order.Provider_history_data in
  check bool "the selected period's request can settle" true accepted;
  let _, accepted = Order.take_dataset reads latest Order.Provider_history_data in
  check bool "that result cannot settle twice" false accepted

let () = run "usage account continuity"
  ["scope", [test_case "exact source identity" `Quick test_exact_scope_filters_both_sources;
             test_case "refresh and window continuity" `Quick test_refresh_does_not_choose_another_account;
             test_case "source failures" `Quick test_failed_and_unread_sources_stay_failed_and_unread;
             test_case "email search target" `Quick test_email_search_keeps_exact_target;
             test_case "workspace replacement retires usage" `Quick test_workspace_replacement_retires_usage;
             test_case "workspace replacement rereads superseded usage" `Quick test_workspace_replacement_rereads_superseded_usage;
             test_case "workspace replacement rereads shared accounts and logs" `Quick test_shared_accounts_and_server_logs_revalidate;
             test_case "period change requests its own history" `Quick test_window_change_replaces_only_its_history_request]]
