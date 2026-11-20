let catch_non_cancel ~on_error f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> on_error (Printexc.to_string exn)

let observe_reader ~on_progress source ~outcome read =
  match on_progress with
  | None -> read ()
  | Some publish ->
      publish
        (Masc_tui_types.Http_refresh_progress.Started
           (source, Mtime_clock.elapsed_ns ()));
      let settle result =
        publish
          (Masc_tui_types.Http_refresh_progress.Completed
             (source, Mtime_clock.elapsed_ns (), result))
      in
      match read () with
      | result ->
          settle (outcome result);
          result
      | exception (Eio.Cancel.Cancelled _ as exn) ->
          settle Masc_tui_types.Http_refresh_progress.Interrupted;
          raise exn
      | exception exn ->
          settle Masc_tui_types.Http_refresh_progress.Failed;
          raise exn

let observe_component ~on_progress component read =
  match on_progress with
  | None -> read ()
  | Some publish ->
      let module Progress = Masc_tui_types.Http_refresh_progress in
      publish (Progress.Component_started (component, Mtime_clock.elapsed_ns ()));
      let settle outcome =
        publish
          (Progress.Component_completed
             (component, Mtime_clock.elapsed_ns (), outcome))
      in
      match read () with
      | result ->
          settle (Progress.Component_returned (Progress.part_of_result result));
          result
      | exception (Eio.Cancel.Cancelled _ as exn) ->
          settle Progress.Component_interrupted;
          raise exn
      | exception exn ->
          settle Progress.Component_exception;
          raise exn

let finish_observed_refresh (state : Masc_tui_types.state) ~ticket =
  if Masc_tui_types.Http_refresh_order.is_current state.http_refresh_order ticket then begin
    let was_running = Option.is_some state.http_refresh_started_ns in
    Masc_tui_types.finish_http_refresh_state state;
    if was_running then
      Option.iter
        (fun (_, progress) ->
          Log.Transport.info "tui_http_refresh=%s"
            (Yojson.Safe.to_string
               (Masc_tui_types.Http_refresh_progress.to_json progress)))
        state.http_refresh_progress
  end

let load_keeper_surfaces ~on_progress ~on_asks ~on_roster ~ask_request
    ~roster_request ~server_identity ~host ~port
    ~(needs : Masc_tui_types.surface_needs) =
  let expected_workspace = Result.to_option server_identity in
  Masc_tui_loader.read_pair
    (fun () ->
      if not needs.needs_asks then None
      else
        Option.map
          (fun asks_request ->
            observe_reader ~on_progress Masc_tui_types.Http_refresh_progress.Questions
              ~outcome:(fun (observation : Masc_tui_types.asks_observation) ->
                Masc_tui_types.Http_refresh_progress.of_result
                  observation.asks_result)
              (fun () ->
                let asks_result =
                  match expected_workspace with
                  | None ->
                      Error
                        (Masc_tui_types.Request_withdrawn
                           Masc_tui_types.Workspace_identity_not_confirmed)
                  | Some expected_workspace ->
                      Masc_tui_http.fetch_asks ~expected_workspace ~host ~port ()
                      |> Result.map_error (fun detail ->
                             Masc_tui_types.Request_failed detail)
                in
                let observation =
                  { Masc_tui_types.asks_request; asks_result }
                in
                (match on_asks with
                 | None -> ()
                 | Some publish ->
                     Option.iter
                       (fun identity -> publish identity observation)
                       expected_workspace);
                observation))
          ask_request)
    (fun () ->
      if not needs.needs_keeper_roster then None
      else
        Option.map
          (fun roster_request ->
            observe_reader ~on_progress Masc_tui_types.Http_refresh_progress.Keepers
              ~outcome:(fun (observation : Masc_tui_types.keeper_roster_observation) ->
                Masc_tui_types.Http_refresh_progress.of_keeper_roster
                  observation.roster_result)
              (fun () ->
                let roster_result =
                  match expected_workspace with
                  | None ->
                      Error
                        (Masc_tui_keeper_control.Roster_malformed
                           "Server workspace identity is unavailable")
                  | Some expected_workspace ->
                      Masc_tui_loader.load_keeper_roster ~host ~port
                        ~expected_workspace
                in
                let observation =
                  { Masc_tui_types.roster_request; roster_result }
                in
                Option.iter
                  (fun publish ->
                    Option.iter
                      (fun identity -> publish identity observation)
                      expected_workspace)
                  on_roster;
                observation))
          roster_request)

let load_scoped_surface_reads ~on_progress ~on_dataset ~surface_request
    ~ask_request ~refresh_ticket ~server_identity ~host ~port ~approval_ticket
    ~(board_query : Masc_tui_types.board_query) ~provider_history_days
    ~tool_series_days ~(needs : Masc_tui_types.surface_needs) :
    unit Masc_tui_async_protocol.http_scoped_surface_readings =
  let publish_bound ~dataset load =
    match server_identity, Fs_compat.execution_context () with
    | Ok expected, Fs_compat.Eio_fiber ->
        Masc_tui_workspace_read.with_binding ~host ~port ~expected
          ~proof:Masc_tui_workspace_read.Request_precondition (fun () ->
            let result = load () in
            Option.iter
              (fun publish -> publish expected (dataset result))
              on_dataset;
            result)
    | Error _, _ | Ok _, Fs_compat.Non_eio -> load ()
  in
  let when_needed ~source ~dataset ~outcome wanted load =
    if wanted then
      Some
        (publish_bound ~dataset (fun () ->
             observe_reader ~on_progress
               (Masc_tui_types.Http_refresh_progress.Surface_data source)
               ~outcome load))
    else None
  in
  let read_transport () =
    when_needed ~source:Masc_tui_types.Surface_read_order.Transport
      ~outcome:Masc_tui_types.Http_refresh_progress.of_result
      ~dataset:(fun result -> Masc_tui_async_protocol.Dataset_transport result)
      needs.needs_transport (fun () ->
        Masc_tui_loader.load_transport_health ~host ~port)
  in
  let read_approvals () =
    Option.map
      (fun ao_ticket ->
        { Masc_tui_async_protocol.ao_ticket
        ; ao_result = Masc_tui_loader.load_approvals ~host ~port
        })
      approval_ticket
  in
  let read_board () =
    if not needs.needs_board then None, None
    else
      let board, hearths =
        observe_reader ~on_progress
          (Masc_tui_types.Http_refresh_progress.Surface_data
             Masc_tui_types.Surface_read_order.Board)
          ~outcome:Masc_tui_types.Http_refresh_progress.of_board (fun () ->
            Masc_tui_loader.read_pair
              (fun () ->
                publish_bound
                  ~dataset:(fun result ->
                    Masc_tui_async_protocol.Dataset_board_posts
                      { Masc_tui_types.bpr_query = board_query
                      ; bpr_result = result
                      })
                  (fun () ->
                    observe_component ~on_progress
                      Masc_tui_types.Http_refresh_progress.Board_posts
                      (fun () ->
                        Masc_tui_loader.load_board_list ~host ~port
                          ~sort_by:
                            (Masc_tui_types.board_sort_label board_query.bq_sort)
                          ~hearth:board_query.bq_hearth)))
              (fun () ->
                publish_bound
                  ~dataset:(fun result ->
                    Masc_tui_async_protocol.Dataset_board_hearths result)
                  (fun () ->
                    observe_component ~on_progress
                      Masc_tui_types.Http_refresh_progress.Board_hearths
                      (fun () -> Masc_tui_loader.load_board_hearths ~host ~port))))
      in
      ( Some { Masc_tui_types.bpr_query = board_query; bpr_result = board }
      , Some hearths )
  in
  let read_planning () =
    when_needed ~source:Masc_tui_types.Surface_read_order.Planning
      ~outcome:Masc_tui_types.Http_refresh_progress.of_result
      ~dataset:(fun result -> Masc_tui_async_protocol.Dataset_planning result)
      needs.needs_planning (fun () -> Masc_tui_loader.load_planning ~host ~port)
  in
  let read_keeper_surfaces () =
    load_keeper_surfaces ~on_progress:None ~on_asks:None ~on_roster:None
      ~ask_request ~roster_request:None ~server_identity ~host ~port ~needs
  in
  let read_runtime_quota () =
    when_needed ~source:Masc_tui_types.Surface_read_order.Runtime_quota
      ~dataset:(fun (runtimes, quota) ->
        Masc_tui_async_protocol.Dataset_runtime_quota (runtimes, quota))
      ~outcome:Masc_tui_types.Http_refresh_progress.of_runtime_quota
      needs.needs_runtime_quota (fun () ->
        catch_non_cancel
          ~on_error:(fun reason -> Error reason, Error reason)
          (fun () -> Masc_tui_loader.load_overview_runtime_resolved ~host ~port))
  in
  let read_keeper_usage () =
    when_needed ~source:Masc_tui_types.Surface_read_order.Keeper_usage
      ~outcome:Masc_tui_types.Http_refresh_progress.of_result
      ~dataset:(fun result -> Masc_tui_async_protocol.Dataset_keeper_usage result)
      needs.needs_keeper_usage (fun () ->
        catch_non_cancel
          ~on_error:(fun reason -> Error reason)
          (fun () -> Masc_tui_loader.load_keeper_usage ~host ~port))
  in
  let read_provider_history () =
    when_needed ~source:Masc_tui_types.Surface_read_order.Provider_history
      ~dataset:(fun reading ->
        Masc_tui_async_protocol.Dataset_provider_history reading)
      ~outcome:(fun (reading : Masc_tui_async_protocol.provider_history_reading) ->
        Masc_tui_types.Http_refresh_progress.of_result reading.phr_result)
      needs.needs_provider_history (fun () ->
        let phr_requested_at = Unix.gettimeofday () in
        let phr_result =
          catch_non_cancel
            ~on_error:(fun reason -> Error reason)
            (fun () ->
              Masc_tui_loader.load_provider_usage_history ~host ~port
                ~days:provider_history_days)
        in
        { Masc_tui_async_protocol.phr_days = provider_history_days
        ; phr_requested_at
        ; phr_result
        })
  in
  let read_overview_goals () =
    when_needed ~source:Masc_tui_types.Surface_read_order.Overview_goals
      ~outcome:Masc_tui_types.Http_refresh_progress.of_result
      ~dataset:(fun result ->
        Masc_tui_async_protocol.Dataset_overview_goals result)
      needs.needs_overview_goals (fun () ->
        catch_non_cancel
          ~on_error:(fun reason -> Error reason)
          (fun () -> Masc_tui_loader.load_overview_goals ~host ~port))
  in
  let read_account_emails () =
    when_needed ~source:Masc_tui_types.Surface_read_order.Account_emails
      ~outcome:Masc_tui_types.Http_refresh_progress.of_result
      ~dataset:(fun result ->
        Masc_tui_async_protocol.Dataset_account_emails result)
      needs.needs_account_emails (fun () ->
        catch_non_cancel
          ~on_error:(fun reason -> Error reason)
          (fun () -> Masc_tui_loader.load_account_emails ~host ~port))
  in
  let read_tool_series () =
    match tool_series_days with
    | None -> None
    | Some days ->
        when_needed ~source:Masc_tui_types.Surface_read_order.Tool_series
          ~dataset:(fun load -> Masc_tui_async_protocol.Dataset_tool_series load)
          ~outcome:(fun (load : Masc_tui_async_protocol.tool_series_load) ->
            Masc_tui_types.Http_refresh_progress.of_result load.tsl_result)
          needs.needs_tool_series (fun () ->
            let tsl_result =
              match Masc_tui_usage_calls.window_of_days days with
              | None ->
                  Error (Printf.sprintf "Calls has no window of %d days" days)
              | Some window ->
                  catch_non_cancel
                    ~on_error:(fun reason -> Error reason)
                    (fun () ->
                      match
                        Masc_tui_loader.load_tool_series ~host ~port
                          ~width:(Masc_tui_usage_calls.width window)
                          ~since_hours:(Masc_tui_usage_calls.since_hours window)
                      with
                      | Ok series -> Masc_tui_usage_calls.of_series window series
                      | Error reason -> Error reason)
            in
            { Masc_tui_async_protocol.tsl_days = days; tsl_result })
  in
  let ( (http_transport, ((http_approvals, (http_board, http_board_hearths)), http_planning))
      , ( ((http_asks, http_keeper_roster), http_overview_goals)
        , ((http_runtime_quota, http_keeper_usage), ((http_provider_history, http_account_emails), http_tool_series)) ) )
      =
    Masc_tui_loader.read_pair
      (fun () ->
        Masc_tui_loader.read_pair read_transport (fun () ->
            Masc_tui_loader.read_pair
              (fun () -> Masc_tui_loader.read_pair read_approvals read_board)
              read_planning))
      (fun () ->
        Masc_tui_loader.read_pair
          (fun () -> Masc_tui_loader.read_pair read_keeper_surfaces read_overview_goals)
          (fun () ->
            Masc_tui_loader.read_pair
              (fun () -> Masc_tui_loader.read_pair read_runtime_quota read_keeper_usage)
              (fun () ->
                Masc_tui_loader.read_pair
                  (fun () ->
                    Masc_tui_loader.read_pair read_provider_history read_account_emails)
                  read_tool_series)))
  in
  { Masc_tui_async_protocol.http_refresh_ticket = refresh_ticket
  ; http_surface_request = surface_request
  ; http_scoped_server_identity = ()
  ; http_transport
  ; http_approvals
  ; http_asks
  ; http_board
  ; http_board_hearths
  ; http_planning
  ; http_keeper_roster
  ; http_runtime_quota
  ; http_keeper_usage
  ; http_provider_history
  ; http_overview_goals
  ; http_account_emails
  ; http_tool_series
  }

let load_surfaces ~probe_only ~surface_request ~on_initial_identity ~on_progress
    ~on_dataset ~on_asks ~on_approvals ~on_roster ~ask_request ~roster_request
    ~refresh_ticket ~host ~port ~approval_ticket ~board_query
    ~provider_history_days ~tool_series_days
    ~(needs : Masc_tui_types.surface_needs) =
  match
    Masc_tui_loader.server_probe
      (observe_reader ~on_progress
         Masc_tui_types.Http_refresh_progress.Identity_before
         ~outcome:Masc_tui_types.Http_refresh_progress.of_result (fun () ->
           Masc_tui_loader.load_server_reading ~host ~port))
  with
  | Masc_tui_loader.Probe_account_server { version } ->
      Masc_tui_async_protocol.Refresh_account_server
        { refresh_ticket; version; approval_ticket }
  | Masc_tui_loader.Probe_identity http_server_identity -> (
      match probe_only, http_server_identity with
      | true, Error detail ->
          Masc_tui_async_protocol.Refresh_workspace_unconfirmed
            { refresh_ticket
            ; latest_identity = Error detail
            ; detail = "Server probe failed; no surface was asked: " ^ detail
            ; unreachable = true
            ; approval_ticket
            }
      | true, Ok _ | false, (Ok _ | Error _) -> (
          if Masc_tui_types.server_is_booting http_server_identity then
            Masc_tui_async_protocol.Refresh_server_booting
              { refresh_ticket; identity = http_server_identity; approval_ticket }
          else begin
            let approval_ticket, ask_request, roster_request, surface_request =
              match on_initial_identity, http_server_identity with
              | Some admit, Ok identity -> (
                  match admit identity with
                  | Some requests ->
                      ( requests.Masc_tui_async_protocol.hrr_approval
                      , requests.hrr_asks
                      , requests.hrr_roster
                      , Masc_tui_types.Surface_read_context.current
                          requests.hrr_surfaces )
                  | None ->
                      approval_ticket, ask_request, roster_request, surface_request)
              | None, (Ok _ | Error _) | Some _, Error _ ->
                  approval_ticket, ask_request, roster_request, surface_request
            in
            let http_approvals, ((http_asks, http_keeper_roster), http_scoped) =
              Masc_tui_loader.read_pair
                (fun () ->
                  Option.map
                    (fun ao_ticket ->
                      observe_reader ~on_progress
                        Masc_tui_types.Http_refresh_progress.Approvals
                        ~outcome:(fun (observation : Masc_tui_async_protocol.approval_observation) ->
                          Masc_tui_types.Http_refresh_progress.of_result
                            observation.ao_result)
                        (fun () ->
                          let ao_result =
                            match http_server_identity with
                            | Ok expected_workspace ->
                                Masc_tui_loader.load_workspace_approvals
                                  ~expected_workspace ~host ~port
                            | Error detail -> Error detail
                          in
                          let observation =
                            { Masc_tui_async_protocol.ao_ticket; ao_result }
                          in
                          (match on_approvals, http_server_identity with
                           | Some publish, Ok identity -> publish identity observation
                           | None, (Ok _ | Error _) | Some _, Error _ -> ());
                          observation))
                    approval_ticket)
                (fun () ->
                  Masc_tui_loader.read_pair
                    (fun () ->
                      load_keeper_surfaces ~on_progress ~on_asks ~on_roster
                        ~ask_request ~roster_request
                        ~server_identity:http_server_identity ~host ~port
                        ~needs:{ needs with needs_asks = true })
                    (fun () ->
                      load_scoped_surface_reads ~on_progress ~on_dataset
                        ~surface_request ~ask_request:None ~refresh_ticket
                        ~server_identity:http_server_identity ~host ~port
                        ~approval_ticket:None ~board_query
                        ~provider_history_days ~tool_series_days
                        ~needs:
                          { needs with
                            needs_asks = false
                          ; needs_keeper_roster = false
                          }))
            in
            match
              Masc_tui_loader.server_probe
                (observe_reader ~on_progress
                   Masc_tui_types.Http_refresh_progress.Identity_after
                   ~outcome:Masc_tui_types.Http_refresh_progress.of_result
                   (fun () -> Masc_tui_loader.load_server_reading ~host ~port))
            with
            | Masc_tui_loader.Probe_account_server { version } ->
                Masc_tui_async_protocol.Refresh_account_server
                  { refresh_ticket; version; approval_ticket }
            | Masc_tui_loader.Probe_identity identity_after ->
                if Masc_tui_types.server_is_booting identity_after then
                  Masc_tui_async_protocol.Refresh_server_booting
                    { refresh_ticket; identity = identity_after; approval_ticket }
                else if
                  Masc_tui_types.server_workspace_matches
                    ~expected:(Result.to_option http_server_identity)
                    identity_after
                then
                  let http_scoped =
                    { http_scoped with
                      http_asks
                    ; http_keeper_roster
                    ; http_scoped_server_identity = identity_after
                    }
                  in
                  Masc_tui_async_protocol.Refresh_surfaces
                    { http_approvals
                    ; http_scoped
                    ; http_server_identity = identity_after
                    }
                else
                  Masc_tui_async_protocol.Refresh_workspace_unconfirmed
                    { refresh_ticket
                    ; latest_identity = identity_after
                    ; detail =
                        "Workspace identity changed or unavailable during surface collection; bundle discarded"
                    ; unreachable =
                        Result.is_error http_server_identity
                        && Result.is_error identity_after
                    ; approval_ticket
                    }
          end))
