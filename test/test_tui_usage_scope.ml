open Alcotest
open Masc_tui_types
module Usage = Masc.Tui_decode_usage
module Trend = Masc_tui_usage_trend
module Calls = Masc_tui_usage_calls
module Series = Masc.Tui_decode_tool_series

let account id : Usage.provider_usage_account =
  { pua_scope="runtime-owned-" ^ id; pua_scope_id=id;
    pua_providers=[{pup_id="provider-" ^ id;pup_display_name="Same display name"}];
    pua_state=Account_not_reported_since_start }

let history_row id : Trend.row =
  {scope_id=id; kind="window";limit_id=None;marks="";samples=[];reported_days=0}

let state () =
  let state = create_state ~workspace:"usage-scope-test" ~port:8935 () in
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

(* A Keeper usage answer with no rows: an observation the workspace owns. *)
let keeper_usage : Usage.keeper_usage_window =
  { Usage.kuw_generated_at = 0.; kuw_window_minutes = 1440; kuw_rows = [] }

let test_workspace_replacement_retires_usage () =
  let state = state () in
  let transport : Masc.Tui_decode.transport_health =
    { th_primary_path=Masc.Transport_metrics.Sse; th_queue_pressure=Steady;
      th_sse_sessions=1; th_websocket_sessions=None; th_grpc_port=None; th_events_dropped=0 } in
  state.transport <- Some transport;
  state.overview_quota <- Quota_read [];
  state.keeper_usage <- Keeper_usage_read keeper_usage;
  state.overview_account_emails <- Account_emails_read
      {emails=["provider-B", "fictional@example.test"]; unreadable_rows=0};
  state.usage_section <- Usage_trend;
  state.provider_history_days <- 7;
  state.tool_series <- Tool_series_error "the series read was refused";
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
     && state.keeper_usage = Keeper_usage_read keeper_usage);
  check bool "an unconfirmed identity retires old read authority" true
    (state.workspace_read_authority != previous_reading);
  withdraw_usage_workspace state;
  check bool "replacement retires every workspace usage observation" true
    (state.transport = None && state.transport_error = None
     && state.overview_quota = Quota_unread
     && state.overview_providers = Providers_unread
     && state.keeper_usage = Keeper_usage_unread
     && state.provider_history = Provider_history_unread
     && state.tool_series = Tool_series_unread
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
  check bool "the System logs view asks the bundle for nothing" false
    (revalidate_workspace_surfaces state ~workspace_moved:true
       ~needs:(surface_needs_of_surface System_logs))

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

(* A fortnight of idle days, cut to the window the way a read does. *)
let fortnight_of_calls () =
  let day = 86400.0 in
  let first = 1793750400.0 in
  let series =
    { Series.tsr_generated_at = first +. (15.0 *. day)
    ; tsr_width = Series.Series_day
    ; tsr_utc_offset_min = 0
    ; tsr_buckets =
        List.init 15 (fun index ->
          { Series.tsb_start = first +. (float_of_int index *. day)
          ; tsb_activity = Series.Series_idle })
    }
  in
  match Calls.of_series Calls.Last_fortnight series with
  | Ok calls -> calls
  | Error reason -> failf "the fortnight was refused: %s" reason

let test_calls_closes_the_view_cycle_in_both_directions () =
  let forward = [ Usage_plan; Usage_trend; Usage_keepers; Usage_calls ] in
  check int "four sections" 4 (List.length forward);
  List.iteri
    (fun index section ->
      let next = List.nth forward ((index + 1) mod 4) in
      check bool "v goes to the next section" true (next_usage_section section = next);
      check bool "V undoes v" true (previous_usage_section next = section))
    forward

let test_calls_reads_only_while_it_is_drawn () =
  let state = state () in
  state.view <- Metrics;
  state.usage_section <- Usage_calls;
  check bool "Usage on its Calls section draws it" true (usage_calls_drawn state);
  state.usage_telemetry_open <- true;
  check bool "the Telemetry panel replaces the sections" false (usage_calls_drawn state);
  state.usage_telemetry_open <- false;
  List.iter
    (fun section ->
      state.usage_section <- section;
      check bool "another section does not" false (usage_calls_drawn state))
    [ Usage_plan; Usage_trend; Usage_keepers ];
  state.usage_section <- Usage_calls;
  state.view <- Board;
  check bool "another surface does not, whatever Usage last showed" false (usage_calls_drawn state);
  check bool "no surface asks for the series on its own" true
    (List.for_all
       (fun (surface, _) -> not (surface_needs_of_surface surface).needs_tool_series)
       surface_ring)

let test_the_period_key_on_calls_rereads_calls () =
  let state = state () in
  let module Order = Surface_read_order in
  state.view <- Metrics;
  state.usage_section <- Usage_calls;
  state.provider_history_days <- 14;
  state.tool_series <- Tool_series_read (fortnight_of_calls ());
  let needs = cycle_usage_history_window state in
  check bool "the section stays on Calls" true (state.usage_section = Usage_calls);
  check int "the period moves" 1 state.provider_history_days;
  check bool "the reading of the old period is dropped" true
    (state.tool_series = Tool_series_unread);
  check bool "the series is read again" true needs.needs_tool_series;
  check bool "so is the history, which shares the period" true needs.needs_provider_history;
  let reads, request = Order.dispatch ~kind:Order.Navigation ~needs ~started_ns:0L Order.initial in
  check bool "the new request owns the series" true
    (Order.owns_dataset reads request Order.Tool_series_data);
  check bool "and names it as a source" true (List.mem Order.Tool_series (Order.sources needs))

let test_the_period_key_elsewhere_lands_on_trend_without_the_series () =
  List.iter
    (fun section ->
      let state = state () in
      state.view <- Metrics;
      state.usage_section <- section;
      state.tool_series <- Tool_series_read (fortnight_of_calls ());
      let needs = cycle_usage_history_window state in
      check bool "it lands on Trend" true (state.usage_section = Usage_trend);
      check bool "it asks for no series" false needs.needs_tool_series;
      check bool "the old reading cannot be shown for the new period" true
        (state.tool_series = Tool_series_unread))
    [ Usage_plan; Usage_trend; Usage_keepers ]

let test_a_moved_workspace_rereads_an_unread_series_only_while_it_is_drawn () =
  let state = state () in
  withdraw_usage_workspace state;
  state.workspace_identity <- Workspace_identity_mismatch
      {local_base_path="/workspace/a";server_base_path="/workspace/b"};
  let drawn = { nothing with needs_tool_series = true } in
  check bool "unread and drawn" true
    (revalidate_workspace_surfaces state ~workspace_moved:true ~needs:drawn);
  check bool "unread and not drawn" false
    (revalidate_workspace_surfaces state ~workspace_moved:true ~needs:nothing);
  state.tool_series <- Tool_series_error "the series read was refused";
  check bool "a settled failure is not read again" false
    (revalidate_workspace_surfaces state ~workspace_moved:true ~needs:drawn)

let drawn_calls_state () =
  let state = state () in
  state.view <- Metrics;
  state.usage_section <- Usage_calls;
  state

let test_the_series_is_owed_once_a_period_after_its_answer () =
  let state = drawn_calls_state () in
  check bool "nothing is owed before a read answered" false
    (take_tool_series_due state ~now:1e9);
  note_tool_series_read state ~now:100.0;
  check bool "not owed just before the period ends" false
    (take_tool_series_due state ~now:(100.0 +. Calls.reread_s -. 0.001));
  check bool "owed when the period ends" true
    (take_tool_series_due state ~now:(100.0 +. Calls.reread_s));
  check bool "owed once for that moment" false
    (take_tool_series_due state ~now:(100.0 +. (10.0 *. Calls.reread_s)));
  check bool "a longer wait than a period still owes it once" true
    (note_tool_series_read state ~now:100.0;
     take_tool_series_due state ~now:(100.0 +. (10.0 *. Calls.reread_s)))

let test_the_moment_is_dropped_while_calls_is_not_drawn () =
  let state = drawn_calls_state () in
  note_tool_series_read state ~now:100.0;
  state.usage_section <- Usage_keepers;
  check bool "not owed while another section is up" false
    (take_tool_series_due state ~now:1e9);
  check bool "the moment is gone" true (state.tool_series_reread_at = None);
  state.usage_section <- Usage_calls;
  check bool "back on Calls the old moment owes no second read behind the one on arrival" false
    (take_tool_series_due state ~now:1e9)

let test_a_period_change_and_a_withdrawn_workspace_drop_the_moment () =
  let state = drawn_calls_state () in
  note_tool_series_read state ~now:100.0;
  ignore (cycle_usage_history_window state);
  check bool "the period key drops it" true (state.tool_series_reread_at = None);
  note_tool_series_read state ~now:100.0;
  withdraw_usage_workspace state;
  check bool "a withdrawn workspace drops it" true (state.tool_series_reread_at = None)

(* A day of idle hours, cut to the window the way a read does. *)
let day_of_calls () =
  let hour = 3600.0 in
  let first = 1793750400.0 in
  let series =
    { Series.tsr_generated_at = first +. (25.0 *. hour)
    ; tsr_width = Series.Series_hour
    ; tsr_utc_offset_min = 0
    ; tsr_buckets =
        List.init 25 (fun index ->
          { Series.tsb_start = first +. (float_of_int index *. hour)
          ; tsb_activity = Series.Series_idle })
    }
  in
  match Calls.of_series Calls.Last_day series with
  | Ok calls -> calls
  | Error reason -> failf "the day was refused: %s" reason

let test_a_window_and_its_days_name_each_other () =
  List.iter
    (fun window ->
      check bool "the days name the window" true
        (Calls.window_of_days (Calls.days window) = Some window))
    [ Calls.Last_day; Calls.Last_week; Calls.Last_fortnight ]

let test_the_dashboard_draws_the_last_day_whatever_the_period_holds () =
  let state = state () in
  state.view <- Overview;
  List.iter
    (fun days ->
      state.provider_history_days <- days;
      check (option int) "the Dashboard's line is the last day" (Some 1)
        (tool_series_days state);
      check bool "so the series is drawn" true (tool_series_drawn state))
    [ 1; 7; 14 ];
  state.view <- Metrics;
  state.usage_section <- Usage_calls;
  state.provider_history_days <- 7;
  check (option int) "Calls follows the period" (Some 7) (tool_series_days state);
  state.usage_telemetry_open <- true;
  check (option int) "the Telemetry panel draws no series" None (tool_series_days state);
  state.usage_telemetry_open <- false;
  state.usage_section <- Usage_trend;
  check (option int) "another section draws none" None (tool_series_days state);
  state.view <- Board;
  check (option int) "another surface draws none" None (tool_series_days state);
  check bool "so no series is drawn" false (tool_series_drawn state)

let test_moving_between_calls_and_the_dashboard_rereads_the_other_window () =
  let state = state () in
  state.provider_history_days <- 14;
  state.view <- Metrics;
  state.usage_section <- Usage_calls;
  state.tool_series <- Tool_series_read (fortnight_of_calls ());
  note_tool_series_read state ~now:100.0;
  check bool "Calls owes nothing before its time" false
    (take_tool_series_due state ~now:100.0);
  check bool "and keeps the window it asked for" true
    (state.tool_series <> Tool_series_unread);
  state.view <- Overview;
  check bool "the Dashboard owes the series at once" true
    (take_tool_series_due state ~now:100.0);
  check bool "the fortnight is dropped, not drawn as the day" true
    (state.tool_series = Tool_series_unread);
  check bool "owed once for that move" false (take_tool_series_due state ~now:100.0);
  state.tool_series <- Tool_series_read (day_of_calls ());
  note_tool_series_read state ~now:200.0;
  check bool "the Dashboard keeps a reading of its own window" false
    (take_tool_series_due state ~now:200.0);
  state.view <- Metrics;
  check bool "Calls on 14 days owes the series at once" true
    (take_tool_series_due state ~now:200.0);
  check bool "the day is dropped, not drawn as the fortnight" true
    (state.tool_series = Tool_series_unread)

let test_a_one_day_period_serves_calls_and_the_dashboard_with_one_reading () =
  let state = state () in
  state.provider_history_days <- 1;
  state.view <- Metrics;
  state.usage_section <- Usage_calls;
  state.tool_series <- Tool_series_read (day_of_calls ());
  state.view <- Overview;
  check bool "the Dashboard owes nothing" false (take_tool_series_due state ~now:1e9);
  state.view <- Metrics;
  check bool "nor does Calls on its way back" false (take_tool_series_due state ~now:1e9);
  check bool "the reading is kept" true (state.tool_series <> Tool_series_unread)

let () = run "usage account continuity"
  ["scope", [test_case "exact source identity" `Quick test_exact_scope_filters_both_sources;
             test_case "refresh and window continuity" `Quick test_refresh_does_not_choose_another_account;
             test_case "source failures" `Quick test_failed_and_unread_sources_stay_failed_and_unread;
             test_case "email search target" `Quick test_email_search_keeps_exact_target;
             test_case "workspace replacement retires usage" `Quick test_workspace_replacement_retires_usage;
             test_case "workspace replacement rereads superseded usage" `Quick test_workspace_replacement_rereads_superseded_usage;
             test_case "workspace replacement rereads shared accounts and logs" `Quick test_shared_accounts_and_server_logs_revalidate;
             test_case "period change requests its own history" `Quick test_window_change_replaces_only_its_history_request;
             test_case "Calls closes the view cycle in both directions" `Quick test_calls_closes_the_view_cycle_in_both_directions;
             test_case "Calls reads only while it is drawn" `Quick test_calls_reads_only_while_it_is_drawn;
             test_case "the period key on Calls rereads Calls" `Quick test_the_period_key_on_calls_rereads_calls;
             test_case "the period key elsewhere lands on Trend" `Quick test_the_period_key_elsewhere_lands_on_trend_without_the_series;
             test_case "a moved workspace rereads an unread series" `Quick test_a_moved_workspace_rereads_an_unread_series_only_while_it_is_drawn;
             test_case "the series is owed once a period after its answer" `Quick test_the_series_is_owed_once_a_period_after_its_answer;
             test_case "the moment is dropped while Calls is not drawn" `Quick test_the_moment_is_dropped_while_calls_is_not_drawn;
             test_case "a period change and a withdrawn workspace drop the moment" `Quick test_a_period_change_and_a_withdrawn_workspace_drop_the_moment;
             test_case "a window and its days name each other" `Quick test_a_window_and_its_days_name_each_other;
             test_case "the Dashboard draws the last day whatever the period holds" `Quick test_the_dashboard_draws_the_last_day_whatever_the_period_holds;
             test_case "moving between Calls and the Dashboard rereads the other window" `Quick test_moving_between_calls_and_the_dashboard_rereads_the_other_window;
             test_case "a one day period serves Calls and the Dashboard with one reading" `Quick test_a_one_day_period_serves_calls_and_the_dashboard_with_one_reading]]
