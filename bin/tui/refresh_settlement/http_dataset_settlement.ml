module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Tui_decode = Masc.Tui_decode
module Keeper_control = Masc_tui_keeper_control
module Planning_selection = Masc_tui_planning_selection

let note_read = Owed_retry.note_read

let fail_board_list_read (state : T.state) =
  state.T.board_list_owed <- Owed_retry.failed_read state.T.board_list_owed

let settle_planning_read (state : T.state) result =
  state.T.planning_owed <-
    (match result with
     | Ok _ -> Masc_tui_owed_read.succeeded state.T.planning_owed
     | Error _ -> Owed_retry.failed_read state.T.planning_owed)

let settle_overview_goals_read (state : T.state) result =
  state.T.overview_goals_owed <-
    (match result with
     | Ok _ -> Masc_tui_owed_read.succeeded state.T.overview_goals_owed
     | Error _ -> Owed_retry.failed_read state.T.overview_goals_owed)

(* A probe failed, or a pass raised before it settled: the next pass waits
   (RFC tui-one-screen-grammar §2). The owed reads' retry constants. The
   wall clock read here fixes the next try zone 4 says, so a redraw cannot
   move it. *)
let fail_refresh_pace (state : T.state) =
  state.T.refresh_pace <-
    Masc_tui_refresh_pace.probe_failed ~retry_s:Masc_tui_transport.Event_streams.stream_reconnect_s
      ~max_retry_s:Owed_retry.max_reconnect_s ~now:(Masc_tui_wake.Mono.now ())
      ~wall_now:(Unix.gettimeofday ()) state.T.refresh_pace

(* The [/health] probe's reading: its error is the probe's own failure. It
   also paces the next pass; [answered] says what an answer settles, the
   owed pass itself or only the wait before it. *)
let note_server_health (state : T.state) ~answered reading =
  note_read state Masc_tui_read_failure.Server_health
    (Result.map_error (fun detail -> T.Request_failed detail) reading);
  match reading with
  | Ok _ -> state.T.refresh_pace <- answered state.T.refresh_pace
  | Error _ -> fail_refresh_pace state

let apply_board_list_load (state : T.state) receipt =
  let previous = state.T.board_list_reported_error in
  let application = T.apply_board_posts_load state receipt in
  (match receipt.T.bpr_result with
   | Ok _ -> state.T.board_list_owed <- Masc_tui_owed_read.succeeded state.T.board_list_owed
   | Error detail ->
       fail_board_list_read state;
       state.T.board_list_reported_error <- Some detail;
       if not (Option.equal String.equal previous (Some detail)) then
         Masc_tui_loader.add_event state "error" (Printf.sprintf "board list data unreliable: %s" detail));
  application

let apply_board_hearths_load (state : T.state) result =
  T.apply_board_census_load state result;
  match result with
  | Ok _ -> ()
  | Error _ -> fail_board_list_read state

let apply_transport_load (state : T.state) = function
  | Ok transport ->
      state.T.transport <- Some transport;
      state.T.transport_error <- None
  | Error err ->
      state.T.transport <- None;
      Owed_retry.remember_surface_error state ~surface:"transport health"
        ~current_error:state.T.transport_error
        ~set_error:(fun value -> state.T.transport_error <- value)
        err

let apply_overview_load (state : T.state) result =
  match result with
  | Ok overview ->
      state.T.overview <- Some overview;
      state.T.overview_error <- None
  | Error err ->
      state.T.overview <- None;
      Owed_retry.remember_surface_error state ~surface:"overview"
        ~current_error:state.T.overview_error
        ~set_error:(fun value -> state.T.overview_error <- value)
        err

(* A failed read replaces the last good one: a window drawn after the reading
   that said so stopped arriving would name a report nobody heard again. *)
let apply_runtime_quota_load (state : T.state) (runtimes, providers) =
  (match runtimes with
   | Ok options -> state.T.overview_quota <- T.Quota_read options
   | Error err -> state.T.overview_quota <- T.Quota_failed err);
  match providers with
  | Ok windows -> state.T.overview_providers <- T.Providers_read windows
  | Error err -> state.T.overview_providers <- T.Providers_failed err

let apply_keeper_usage_load (state : T.state) = function
  | Ok usage -> state.T.keeper_usage <- T.Keeper_usage_read usage
  | Error reason -> state.T.keeper_usage <- T.Keeper_usage_error reason

(* A failed read replaces the last good one, as the usage windows do: an
   email drawn after the reading that named it stopped arriving could name an
   account the home no longer signs in to. *)
let apply_account_emails_load (state : T.state) = function
  | Ok (emails, unreadable_rows) ->
      state.T.overview_account_emails <- T.Account_emails_read { emails; unreadable_rows }
  | Error err -> state.T.overview_account_emails <- T.Account_emails_failed err

let seconds_per_day = 86_400.0

(* The first instant of the UTC day after [now]. *)
let next_utc_day ~now = (Float.floor (now /. seconds_per_day) +. 1.0) *. seconds_per_day

let apply_provider_history_load (state : T.state) { P.phr_days = days; phr_requested_at; phr_result = result } =
  if days = state.T.provider_history_days then begin
    (* The history window starts at a UTC day, so the reading is owed again
       once the day this request started on has ended. *)
    state.T.provider_history_reread_at <- Some (next_utc_day ~now:phr_requested_at);
    match result with
    | Ok (history : Masc.Tui_decode_usage.provider_usage_history)
      when history.Masc.Tui_decode_usage.puh_days = days ->
        state.T.provider_history <-
          T.Provider_history_read
            (Masc_tui_usage_trend.of_history
               ~share:Masc_tui_overview_providers.share_of_full history)
    | Ok _ ->
        state.T.provider_history <- T.Provider_history_error
            "history response window differs from request"
    | Error reason -> state.T.provider_history <- T.Provider_history_error reason
  end

(* A reply to a window the screen has since left is dropped: the operator
   cycled the period, or moved between Calls and the Dashboard, which draw
   different windows ([tool_series_days]). A failed read
   replaces the last good one, as the history's does: bars drawn from a read
   that stopped arriving would be buckets nobody observed this refresh. An
   answer sets the moment the series is owed again; a failure leaves the owed
   read to try again after its wait ([settle_pushed_dataset]). *)
let apply_tool_series_load (state : T.state) { P.tsl_days = days; tsl_result = result } =
  if Some days = T.tool_series_days state then begin
    match result with
    | Ok calls ->
        state.T.tool_series <- T.Tool_series_read calls;
        T.note_tool_series_read state ~now:(Masc_tui_wake.Mono.now ())
    | Error reason -> state.T.tool_series <- T.Tool_series_error reason
  end else
    (* The reply is for a window the screen has left, and the read it was
       settled as answered nothing for the window the screen draws now: a
       move from Calls to the Dashboard while Calls' read was out leaves the
       Dashboard with no reading and no read on the way. That window is owed
       (a screen that draws no series drops the debt in
       [launch_owed_pushed_reads]). *)
    Owed_retry.owe_pushed_read state T.Surface_read_source.Tool_series

(* A failed read replaces the last good one, as the quota reading does: goals
   drawn after the read that listed them stopped arriving would be rows nobody
   observed this refresh. *)
let apply_overview_goals_load (state : T.state) result =
  settle_overview_goals_read state result;
  match result with
  | Ok goals -> state.T.overview_goals <- T.Goals_read goals
  | Error err -> state.T.overview_goals <- T.Goals_failed err

let apply_remote_keeper_rows ~before_view_change (state : T.state) =
  match state.T.workspace_identity with
  | T.Workspace_identity_match | T.Workspace_identity_match_unconfirmed _
  | T.Workspace_identity_unread -> ()
  | T.Workspace_identity_mismatch _ ->
    let keepers, error = match Keeper_control.roster_view state.T.keeper_roster with
      | Keeper_control.Roster_unobserved -> [],
        Some (Option.value state.T.keeper_roster_error ~default:"Remote Keeper roster not observed")
      | Keeper_control.Roster_complete rows -> List.map Tui_decode.keeper_of_runtime rows, None
      | Keeper_control.Roster_partial { observed; total } -> List.map Tui_decode.keeper_of_runtime observed,
        Some (Printf.sprintf "Remote Keeper roster is partial (%d of %d)"
          (List.length observed) total)
      | Keeper_control.Roster_invalid { observed; errors; complete = _ } ->
        List.map Tui_decode.keeper_of_runtime observed @
        List.filter_map (fun (name, reason) ->
          if List.exists (fun (row : Tui_decode.keeper_runtime) ->
              String.equal name row.Tui_decode.kr_name) observed then None
          else Some { Tui_decode.k_origin = Tui_decode.Remote_keeper; k_name = name;
            k_paused = false; k_identity = Error (Tui_decode.Identity_unreadable reason);
            k_activity = None }) errors,
        Some (String.concat "; " (List.map (fun (name, reason) -> name ^ ": " ^ reason) errors))
    in
    Masc_tui_loader.replace_keeper_rows ~before_view_change
      ~preserve_on_error:false state
      ~keepers ~error;
    T.clear_keeper_logs state

(* A starting Keeper's [next_action] turns from Probe once it is
   [agent_staleness_threshold_s] old (RFC-0481 §3.6), and no write says so:
   its row is read again at that time. A time already past schedules
   nothing. The server's clock decides the value, so a read that came early
   finds it unchanged, and the next signal or revalidation reads it again. *)
let starting_rows_due roster =
  let rows =
    match Keeper_control.roster_view roster with
    | Keeper_control.Roster_unobserved -> []
    | Keeper_control.Roster_complete observed
    | Keeper_control.Roster_partial { observed; _ }
    | Keeper_control.Roster_invalid { observed; _ } -> observed
  in
  let wall_now = Unix.gettimeofday () and now = Masc_tui_wake.Mono.now () in
  List.filter_map
    (fun (row : Tui_decode.keeper_runtime) ->
      match Keeper_control.starting_up_until row with
      | Some until when until > wall_now ->
          Some (row.Tui_decode.kr_name, Masc_tui_wake.Mono.of_wall ~now ~wall_now until)
      | Some _ | None -> None)
    rows

(* No cadence reads the roster again, so a failed whole read is owed: it
   reads again after a wait that grows with each failure in a row, whatever
   started it (RFC-0481 §3.3). *)
let owe_failed_whole_roster_read (state : T.state) =
  let read = Masc_tui_roster_owed.Read_roster in
  state.T.keeper_roster_owed <-
    Masc_tui_roster_owed.failed ~retry_s:Masc_tui_transport.Event_streams.stream_reconnect_s
      ~max_retry_s:Owed_retry.max_reconnect_s ~now:(Masc_tui_wake.Mono.now ()) read
      (Masc_tui_roster_owed.started read
         (Masc_tui_roster_owed.roster_changed state.T.keeper_roster_owed))

let apply_keeper_roster_load ~before_view_change (state : T.state) result =
  (match result with
  | Ok (roster, candle) ->
      (* The roster's Candle totals are this workspace's only when the
         server is this workspace's and has finished booting; a foreign
         server's totals are not the operator's. *)
      state.T.candle_observation <-
        (match state.T.workspace_identity, state.T.server_identity with
         | T.Workspace_identity_match,
           Some { Tui_decode.sid_state_ready = Some true | None; _ } -> Some candle
         | T.Workspace_identity_match,
           (None | Some { Tui_decode.sid_state_ready = Some false; _ })
         | ( T.Workspace_identity_mismatch _ | T.Workspace_identity_unread
           | T.Workspace_identity_match_unconfirmed _ ), _ -> None);
      state.T.keeper_roster <- roster;
      state.T.keeper_roster_error <- None;
      state.T.keeper_roster_owed <-
        Masc_tui_roster_owed.schedule_rows (starting_rows_due roster) state.T.keeper_roster_owed;
      (match state.T.item_account with
       | None -> ()
       | Some (keeper_name, _) ->
         (match Keeper_control.liveness_of_roster roster keeper_name with
          | Keeper_control.Present _ | Keeper_control.Unobserved -> ()
          | Keeper_control.Invalid _ | Keeper_control.Absent ->
              Masc_tui_surface_requests.Keeper_surface_requests.withdraw_keeper_items state))
  | Error failure ->
      (* The last good roster is dropped rather than kept: a stale one reports
         fibers as running after the reading that said so stopped arriving,
         and every lifecycle action on this surface is chosen from it. Going
         back to unobserved withdraws the actions instead of offering the
         wrong one. *)
      state.T.keeper_roster <- Keeper_control.unobserved_roster;
      state.T.keeper_roster_owed <- Masc_tui_roster_owed.schedule_rows [] state.T.keeper_roster_owed;
      owe_failed_whole_roster_read state;
      Masc_tui_surface_requests.Keeper_surface_requests.withdraw_keeper_items state;
      state.T.item_account_error <- Some "Keeper roster authority is unavailable";
      let msg =
        Keeper_control.roster_failure_message
          ~credential_sent:(Masc_tui_http.operator_token_present ()) failure
      in
      state.T.candle_observation <- Some (Error msg);
      Owed_retry.remember_surface_error state ~surface:"keeper roster"
        ~current_error:state.T.keeper_roster_error
        ~set_error:(fun value -> state.T.keeper_roster_error <- value)
        msg);
  apply_remote_keeper_rows ~before_view_change state

let apply_keeper_roster_observation ~before_view_change (state : T.state) observation =
  match T.take_keeper_roster_observation state observation with
  | None -> false
  | Some result ->
      apply_keeper_roster_load ~before_view_change state result;
      Result.is_ok result

let apply_planning_load (state : T.state) result =
  settle_planning_read state result;
  match result with
  | Ok (planning : T.planning_snapshot) ->
      let goal_ids (planning : T.planning_snapshot) =
        T.planning_visible_goals ~filter:state.T.planning_filter
          ~sort:state.T.planning_sort planning.T.pl_goals
        |> List.map (fun (goal : T.planning_goal) -> goal.T.pg_id)
      in
      let current =
        match state.T.planning_mode with
        | T.Planning_list ->
            Planning_selection.List_cursor state.T.planning_cursor
        | T.Planning_detail goal_id ->
            Planning_selection.Detail_goal
              { goal_id; cursor = state.T.planning_cursor }
      in
      let current_ids =
        match state.T.planning with
        | None -> []
        | Some current_planning -> goal_ids current_planning
      in
      let navigation =
        Planning_selection.reconcile ~current_ids
          ~next_ids:(goal_ids planning) ~current
      in
      if Option.is_none state.T.planning_baseline then
        state.T.planning_baseline <- Some planning;
      state.T.goal_action_pending <-
        T.goal_action_pending_after_reading planning state.T.goal_action_pending;
      state.T.planning <- Some planning;
      state.T.planning_error <- None;
      (match navigation with
       | Planning_selection.List_cursor cursor ->
           state.T.goal_action_pending <- None;
           state.T.planning_cursor <- cursor;
           state.T.planning_mode <- T.Planning_list;
           state.T.planning_scroll <- T.Planning_scroll_offset 0
       | Planning_selection.Detail_goal { goal_id; cursor } ->
           state.T.planning_cursor <- cursor;
           state.T.planning_mode <- T.Planning_detail goal_id)
  | Error err ->
      state.T.goal_action_pending <- (match state.T.goal_action_pending with
        | Some (T.Goal_action_armed _) | None -> None
        | Some (T.Goal_drop_reason _) as draft -> draft);
      (* A failed observation supplies no replacement goal list. Keep the
         snapshot, selected goal and viewport until a successful replacement
         reconciles them; workspace source replacement still clears it. *)
      Log.Transport.warn "tui_planning_refresh_failed=%s"
        (Yojson.Safe.to_string (`Assoc
          [ "retained", `Bool (Option.is_some state.T.planning)
          ; "draft_retained", `Bool (match state.T.goal_action_pending with
              | Some (T.Goal_drop_reason _) -> true
              | Some (T.Goal_action_armed _) | None -> false)
          ; "snapshot_generated_at", (match state.T.planning with
              | None -> `Null | Some (snapshot : T.planning_snapshot) -> `String snapshot.T.pl_generated_at)
          ; "observed_ns", `String (Int64.to_string (Mtime_clock.elapsed_ns ())) ]));
      Owed_retry.remember_surface_error state ~surface:"planning"
        ~current_error:state.T.planning_error
        ~set_error:(fun value -> state.T.planning_error <- value)
        err

let apply_http_scoped_data ~before_view_change (state : T.state) ~datasets
    (results : 'a P.http_scoped_surface_readings) =
  let outcomes = ref [] in
  let record dataset outcome details =
    outcomes := `Assoc (["source", `String (T.Surface_read_order.source_name
        (T.Surface_read_order.dataset_source dataset));
      "dataset", `String (T.Surface_read_order.dataset_name dataset);
      "outcome", `String outcome] @ details) :: !outcomes in
  let apply dataset ~received load reading =
    if List.mem dataset datasets then Option.iter (fun value ->
      load value;
      let received = received value in
      Owed_retry.settle_pushed_dataset state dataset ~received;
      record dataset (if received then "received" else "failed") []) reading in
  apply T.Surface_read_order.Transport_data ~received:Result.is_ok (apply_transport_load state) results.P.http_transport;
  if state.T.workspace_identity = T.Workspace_identity_match then begin
  Option.iter (Approvals_asks_settlement.apply_approval_answer_observation state) results.P.http_approvals;
  Option.iter (Approvals_asks_settlement.apply_asks_observation state) results.P.http_asks;
  if List.mem T.Surface_read_order.Board_posts datasets then begin
    (* The terminal reservation already marked missing data unavailable. Only
       this remaining, workspace-admitted slot gets a missing observation;
       already consumed/superseded slots contribute no fictitious result. *)
    let application = match results.P.http_board with
      | Some receipt -> apply_board_list_load state receipt
      | None -> T.observe_board_posts_application state T.Board_posts_missing in
    record T.Surface_read_order.Board_posts (T.board_posts_application_outcome application)
      ["board_posts", T.board_posts_application_to_yojson application]
  end;
  apply T.Surface_read_order.Board_hearths ~received:Result.is_ok (apply_board_hearths_load state) results.P.http_board_hearths;
  apply T.Surface_read_order.Planning_data ~received:Result.is_ok (apply_planning_load state) results.P.http_planning;
    apply T.Surface_read_order.Overview_goals_data ~received:Result.is_ok (apply_overview_goals_load state) results.P.http_overview_goals
  end;
  let roster_refreshed = Option.fold ~none:false
    ~some:(apply_keeper_roster_observation ~before_view_change state) results.P.http_keeper_roster in
  apply T.Surface_read_order.Runtime_quota_data
    ~received:(fun (runtimes, quota) -> Result.is_ok runtimes && Result.is_ok quota) (apply_runtime_quota_load state) results.P.http_runtime_quota;
  apply T.Surface_read_order.Keeper_usage_data ~received:Result.is_ok (apply_keeper_usage_load state) results.P.http_keeper_usage;
  apply T.Surface_read_order.Provider_history_data ~received:(fun (reading : P.provider_history_reading) -> Result.is_ok reading.P.phr_result) (apply_provider_history_load state) results.P.http_provider_history;
  apply T.Surface_read_order.Account_emails_data ~received:Result.is_ok (apply_account_emails_load state) results.P.http_account_emails;
  apply T.Surface_read_order.Tool_series_data ~received:(fun (load : P.tool_series_load) -> Result.is_ok load.P.tsl_result) (apply_tool_series_load state) results.P.http_tool_series;
  let request = results.P.http_surface_request in
  Log.Transport.info "tui_surface_read_applied request=%d started_ns=%Ld applied_ns=%Ld sources=%s"
    (T.Surface_read_order.request_id request) (T.Surface_read_order.started_ns request)
    (Mtime_clock.elapsed_ns ()) (Yojson.Safe.to_string (`List (List.rev !outcomes)));
  roster_refreshed

(* Taking a dataset early ([take_early_surface_dataset]) ends its bundle's
   ownership of it, so the bundle's [apply_http_scoped_data] skips it and
   this is the only answer that settles its pushed source's owed read. Left
   in flight, the next loop iteration finds no read pending, owes the source
   again and reads it at once, every frame. *)
let apply_http_dataset (state : T.state) dataset =
  let application = match dataset with
    | P.Dataset_transport result -> apply_transport_load state result; None
    | P.Dataset_board_posts board -> Some (apply_board_list_load state board)
    | P.Dataset_board_hearths hearths -> apply_board_hearths_load state hearths; None
    | P.Dataset_planning result -> apply_planning_load state result; None
    | P.Dataset_runtime_quota (runtimes, quota) -> apply_runtime_quota_load state (runtimes, quota); None
    | P.Dataset_keeper_usage result -> apply_keeper_usage_load state result; None
    | P.Dataset_provider_history reading -> apply_provider_history_load state reading; None
    | P.Dataset_overview_goals result -> apply_overview_goals_load state result; None
    | P.Dataset_account_emails result -> apply_account_emails_load state result; None
    | P.Dataset_tool_series load -> apply_tool_series_load state load; None in
  Owed_retry.settle_pushed_dataset state (P.http_dataset_key dataset)
    ~received:(P.http_dataset_received dataset);
  application
