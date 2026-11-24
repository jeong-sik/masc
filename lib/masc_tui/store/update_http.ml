open Masc_tui_core
open Masc_tui_protocol

let handle_workspace_mismatch ~now ~expected ~observed ~message (m : Model.t) =
  let exp_s = match expected with Some s -> s | None -> "?" in
  let obs_s = match observed with Some s -> s | None -> "?" in
  let summary =
    Say.make ~ko:"워크스페이스 불일치 · 재핸드셰이크"
      ~en:"Workspace mismatch · re-handshake"
  in
  let detail =
    Printf.sprintf "409 workspace_mismatch (expected=%s observed=%s): %s" exp_s
      obs_s message
  in
  let incidents, _ =
    Incidents.push ~occurred_at_unix:m.freshness.last_wall_unix
      ~source:Health.Source_client_http ~summary ~detail ~status:Health.Retried
      m.incidents
  in
  let next_epoch = Epoch.next m.epoch in
  let freshness =
    {
      m.freshness with
      observer =
        Health.Workspace_mismatch
          { expected_instance = exp_s; observed_instance = obs_s };
    }
  in
  let clear_modal_nav (nav : Model.nav_state) =
    match nav.overlay with
    | Some (Nav.Ask_answer | Nav.Inline_action _) -> { nav with overlay = None }
    | Some
        ( Nav.Palette
        | Nav.Settings _
        | Nav.Incidents
        | Nav.Queue_context _
        | Nav.Help
        | Nav.System_gate _ )
    | None ->
        nav
  in
  match m.server_identity.mismatch_state with
  | Model.Mismatch_recovering | Model.Mismatch_halted ->
      (* Anti-loop guard: transition to Mismatch_halted so Subscriptions stay
         blocked ([]) and stop issuing automatic re-handshakes until operator
         triggers Refresh (r). *)
      let server_identity =
        { m.server_identity with mismatch_state = Model.Mismatch_halted }
      in
      let next =
        {
          m with
          epoch = next_epoch;
          nav = clear_modal_nav m.nav;
          ask_modal = None;
          inline_modal = None;
          incidents;
          freshness;
          server_identity;
        }
        |> Model.with_toast ~now ~level:Model.Toast_warning
             (Say.make
                ~ko:"워크스페이스 불일치가 지속됩니다. 새로고침(r)으로 재시도하세요."
                ~en:"Workspace mismatch persists. Press r to retry handshake.")
      in
      (next, [])
  | Model.Mismatch_none ->
      let server_identity =
        {
          m.server_identity with
          workspace = None;
          observer_instance_id = None;
          mismatch_state = Model.Mismatch_recovering;
          last_mismatch_epoch = Some next_epoch;
        }
      in
      let next =
        {
          m with
          epoch = next_epoch;
          nav = clear_modal_nav m.nav;
          ask_modal = None;
          inline_modal = None;
          incidents;
          freshness;
          server_identity;
          infra = Infra_store.forget_log_cursor m.infra;
        }
        |> Model.mark_all_domains_stale
        |> Model.with_toast ~now ~level:Model.Toast_warning summary
      in
      let cmds =
        [
          Cmd.Update_workspace_guard
            { instance_id = None; workspace_sha256 = None };
          Cmd.Sync_streams { epoch = next_epoch; streams = [] };
          Cmd.Http_get { epoch = next_epoch; req = Cmd.Get_health };
        ]
      in
      (next, cmds)

let record_http_incident ~now ~source ~context err (m : Model.t) =
  match err with
  | Msg.Workspace_mismatch
      { expected_instance; observed_instance; message; _ } ->
      handle_workspace_mismatch ~now ~expected:expected_instance
        ~observed:observed_instance ~message m
  | Msg.Transport _ | Msg.Http_error _ | Msg.Decode_error _ ->
      let summary =
        Say.concat ~sep:": " [ context; Msg.http_error_summary err ]
      in
      let detail = Msg.http_error_detail err in
      let incidents, _ =
        Incidents.push ~occurred_at_unix:m.freshness.last_wall_unix ~source
          ~summary ~detail ~status:Health.Resolved m.incidents
      in
      (* Channel 3 isolation: ONLY append to incidents, NEVER touch live health. *)
      ({ m with incidents }, [])

(* A decision POST that failed leaves its attention item actionable again,
   records an incident, and toasts the failure. *)
let fail_decision_post ~now ~attention_id ~context err (m : Model.t) =
  let attention =
    match attention_id with
    | Some id -> Attention.clear_in_flight ~id m.attention
    | None -> m.attention
  in
  let next, cmds =
    record_http_incident ~now ~source:Health.Source_client_http ~context err
      { m with attention }
  in
  ( Model.with_toast ~now ~level:Model.Toast_error (Msg.http_error_summary err)
      next,
    cmds )

let confirm_pending_txs_from_history ~now ~keeper
    (page : Wire_fleet.chat_history_page) drafts =
  let open Fleet_store in
  let inputs, terminals =
    List.fold_left
      (fun (inputs, terminals) (row : Wire_fleet.chat_message) ->
        match Wire_fleet.accepted_input_operation row, Wire_fleet.terminal_operation row with
        | Some op, _ -> (String_map.add op row.content inputs, terminals)
        | None, Some op -> (inputs, String_set.add op terminals)
        | None, None -> (inputs, terminals))
      (String_map.empty, String_set.empty) page.messages
  in
  List.fold_left
    (fun acc (tx : Drafts.pending_message) ->
      let op = Option.value tx.operation_id ~default:tx.request_id in
      if String_set.mem op terminals then Drafts.remove_tx ~request_id:tx.request_id acc
      else if tx.state = Drafts.Sending &&
              Option.equal String.equal (String_map.find_opt op inputs) (Some tx.body)
      then Drafts.mark_accepted ~now ~request_id:tx.request_id ~operation_id:(Some op) acc
      else acc)
    drafts (Drafts.pending_txs_for_keeper ~keeper drafts)

let refresh_404_fallbacks ~now (m : Model.t) =
  let infra =
    if m.infra.sandboxes_fallback_404 then
      let keepers =
        match Observed.to_option m.fleet.keepers with Some ks -> ks | None -> []
      in
      Infra_store.apply_sandboxes_fallback ~observed_at:now
        ~wall_unix:m.freshness.last_wall_unix ~keepers
        ~sandbox_profiles:(Fleet_store.String_map.bindings m.fleet.sandbox_profiles)
        ~tool_series_totals:(Runtime_store.tool_series_totals m.runtime)
        m.infra
    else m.infra
  in
  let work =
    if m.work.candle_fallback_404 then
      Work_store.apply_candle_ledger_fallback ~observed_at:now
        ~summary:m.fleet.candle_summary_fallback
        ~balances:(Fleet_store.String_map.bindings m.fleet.candle_balances_milli)
        m.work
    else m.work
  in
  { m with infra; work }

let fusion_detail_matches_active (m : Model.t) run_id =
  match Model.active_dive m with
  | Some (Nav.Dive_runtime (Nav.Fusion_dive rid)) -> String.equal rid run_id
  | Some
      ( Nav.Dive_keeper _
      | Nav.Dive_work _
      | Nav.Dive_knowledge _
      | Nav.Dive_runtime (Nav.Tool_dive _)
      | Nav.Dive_infra _ ) ->
      false
  | None -> (
      match Runtime_store.selected_fusion_run m.runtime with
      | Some sel -> String.equal sel.run_id run_id
      | None -> true)

let verification_evidence_matches_active (m : Model.t) verification_id =
  match Model.active_dive m with
  | Some (Nav.Dive_work (Nav.Verification_dive vid)) ->
      String.equal vid verification_id
  | Some
      ( Nav.Dive_keeper _
      | Nav.Dive_work (Nav.Goal_dive _ | Nav.Task_dive _)
      | Nav.Dive_knowledge _
      | Nav.Dive_runtime _
      | Nav.Dive_infra _ )
  | None ->
      true

let runtime_trace_matches_active (m : Model.t) keeper =
  match Model.active_dive m with
  | Some (Nav.Dive_infra (Nav.Runtime_trace_dive k)) -> String.equal k keeper
  | Some
      ( Nav.Dive_keeper _
      | Nav.Dive_work _
      | Nav.Dive_knowledge _
      | Nav.Dive_runtime _
      | Nav.Dive_infra
          ( Nav.Sandbox_dive _
          | Nav.Lane_dive _
          | Nav.Incident_dive _
          | Nav.Log_detail_dive _ ) )
  | None ->
      true

let addon_preview_matches_active (m : Model.t) manifest_path =
  match Runtime_store.selected_addon_catalog_entry m.runtime with
  | Some (Wire_runtime.Catalog_package { manifest_path = cur; _ }) ->
      String.equal cur manifest_path
  | Some (Wire_runtime.Catalog_folder _ | Wire_runtime.Catalog_issue _) | None
    ->
      true

let apply_http_reply ~now (m : Model.t) reply =
  let failed_slot err slot =
    Observed.fetch_failed ~reason:(Msg.http_error_detail err)
      ~retryable:(Msg.http_error_retryable err) ~at:now slot
  in
  (* Every read failure lands on the slot its panel renders, so a failed fetch
     shows "조회 실패: <reason>" instead of the "서버 미보고" placeholder.
     [~fail] is required, so a new reply cannot skip that decision. *)
  let on_fleet f (m : Model.t) = { m with fleet = f m.fleet } in
  let on_work f (m : Model.t) = { m with work = f m.work } in
  let on_knowledge f (m : Model.t) = { m with knowledge = f m.knowledge } in
  let on_runtime f (m : Model.t) = { m with runtime = f m.runtime } in
  let on_infra f (m : Model.t) = { m with infra = f m.infra } in
  let on_config f (m : Model.t) = { m with config = f m.config } in
  let err_reply ~source ~ko ~en ~fail err =
    let m =
      match err with
      | Msg.Workspace_mismatch _ -> m
      | Msg.Transport _ | Msg.Http_error _ | Msg.Decode_error _ -> fail m
    in
    record_http_incident ~now ~source ~context:(Say.make ~ko ~en) err m
  in
  match reply with
  | Msg.Reply_dashboard_shell (Ok shell) ->
      let freshness, fleet0 =
        match shell.generated_at_unix with
        | Some ts when ts > m.freshness.last_wall_unix ->
            ( { m.freshness with last_wall_unix = ts }
            , Fleet_store.set_wall_unix ts m.fleet )
        | Some _ | None -> (m.freshness, m.fleet)
      in
      let next =
        {
          m with
          freshness;
          fleet = Fleet_store.apply_shell ~observed_at:now shell fleet0;
        }
        |> Model.sync_effective_scorecard ~now
      in
      (next, [])
  | Msg.Reply_dashboard_shell (Error err) ->
      err_reply
        ~fail:
          (on_fleet (fun (x : Fleet_store.t) ->
               { x with shell = failed_slot err x.shell }))
        ~source:Health.Source_client_http ~ko:"대시보드 셸 조회"
        ~en:"Dashboard shell fetch" err
  | Msg.Reply_keepers_roster (Ok roster) ->
      let fleet = Fleet_store.apply_roster ~observed_at:now roster m.fleet in
      let runtime =
        Runtime_store.sync_keeper_companies roster.keepers m.runtime
      in
      let drafts =
        match m.drafts.active_keeper, fleet.selected_keeper with
        | None, Some name -> Drafts.set_active_keeper name m.drafts
        | Some _, _ | None, None -> m.drafts
      in
      let next =
        { m with fleet; runtime; drafts }
        |> Update_nav.sync_config_for_keeper_view
        |> refresh_404_fallbacks ~now
        |> Model.sync_effective_scorecard ~now
      in
      (* A roster change can mean a finished turn, which leaves the Context
         tab's turn records stale; the drawer opens over any view. *)
      let cmds =
        if
          Nav.equal_workspace next.nav.workspace Nav.Keepers
          && next.nav.dive_stack = []
          && Option.is_some fleet.selected_keeper
        then View_fetches.fetches_for_current_view next
        else View_fetches.overlay_fetches next
      in
      (next, cmds)
  | Msg.Reply_keepers_roster (Error err) ->
      err_reply
        ~fail:
          (on_fleet (fun (x : Fleet_store.t) ->
               { x with keepers = failed_slot err x.keepers }))
        ~source:Health.Source_client_http ~ko:"키퍼 목록 조회"
        ~en:"Keepers roster fetch" err
  | Msg.Reply_keepers_roster_extras extras ->
      let next =
        { m with fleet = Fleet_store.apply_roster_extras extras m.fleet }
        |> refresh_404_fallbacks ~now
      in
      (next, [])
  | Msg.Reply_execution_enrichments enrichments ->
      let next =
        {
          m with
          fleet =
            Fleet_store.apply_execution_enrichments ~observed_at:now enrichments
              m.fleet;
        }
        |> refresh_404_fallbacks ~now
        |> Model.sync_effective_scorecard ~now
      in
      (next, [])
  | Msg.Reply_keeper_turns (Ok rows) ->
      ({ m with fleet = Fleet_store.apply_turns ~observed_at:now rows m.fleet }, [])
  | Msg.Reply_keeper_turns (Error err) ->
      err_reply
        ~fail:
          (on_fleet (fun (x : Fleet_store.t) ->
               { x with turns = failed_slot err x.turns }))
        ~source:Health.Source_client_http ~ko:"키퍼 턴 상태 조회"
        ~en:"Keeper turns fetch" err
  | Msg.Reply_keeper_turn_records { keeper; result = Ok records } ->
      ( {
          m with
          fleet =
            Fleet_store.set_turn_records ~keeper
              (Observed.value ~observed_at:now records)
              m.fleet;
        }
      , [] )
  | Msg.Reply_keeper_turn_records { keeper; result = Error err } ->
      err_reply
        ~fail:
          (on_fleet (fun (x : Fleet_store.t) ->
               Fleet_store.set_turn_records ~keeper
                 (failed_slot err (Fleet_store.turn_records_for ~keeper x))
                 x))
        ~source:(Health.Source_keeper keeper) ~ko:"턴 기록 조회"
        ~en:"Turn records fetch" err
  | Msg.Reply_chat_queue { keeper; requested_at; operations; result } ->
      let prior = Fleet_store.chat_queue_for ~keeper m.fleet in
      let previous = match prior.read with
        | Observed.Loading { since_ns } -> Some since_ns
        | Observed.Value { observed_at; _ } -> Some observed_at
        | Observed.Failed { at; _ } -> Some at
        | Observed.Unreported | Observed.Absent -> None in
      if Option.fold ~none:false ~some:(fun stamp -> Clock.Mono.compare stamp requested_at > 0) previous
      then (m, [])
      else
        let set read =
          { m with fleet = Fleet_store.set_chat_queue ~keeper { operations; read } m.fleet } in
        (match result with
         | None -> (set (Observed.loading ~since_ns:requested_at), [])
         | Some (Ok ()) -> (set (Observed.value ~observed_at:requested_at ()), [])
         | Some (Error err) ->
             let read = Observed.failed ~at:requested_at ~reason:(Msg.http_error_detail err)
               ~retryable:(Msg.http_error_retryable err) in
             let operations =
               match err with
               | Msg.Workspace_mismatch _ | Msg.Http_error { status = (401 | 403); _ } -> []
               | Msg.Http_error _ | Msg.Transport _ | Msg.Decode_error _ ->
                   (* The empty terminator proves an empty queue on success. On a
                      failed read, no rows means the first page never arrived. *)
                   (match operations with [] -> prior.operations | _ :: _ -> operations)
             in
             let fleet = Fleet_store.set_chat_queue ~keeper { operations; read } m.fleet in
             record_http_incident ~now ~source:(Health.Source_keeper keeper)
               ~context:(Say.make ~ko:"대기열 조회" ~en:"Chat queue read") err { m with fleet })
  | Msg.Reply_chat_status { keeper; operation_id; result = Ok operation } ->
      let tx = Drafts.pending_txs_for_keeper ~keeper m.drafts
        |> List.find_opt (fun (tx : Drafts.pending_message) ->
             String.equal operation_id (Option.value tx.operation_id ~default:tx.request_id)) in
      (match tx with
       | None -> (m, [])
       | Some tx ->
           let request_id = tx.request_id in
           let drafts = match operation.state with
             | Keeper_chat_operation.State_name.Succeeded ->
                 Drafts.mark_delivered ~now ~request_id ~keeper ~body:tx.body m.drafts
             | Failed ->
                 let reason = Option.value operation.failure_detail ~default:"Operation failed" in
                 Drafts.mark_failed_retryable ~now ~request_id ~reason m.drafts
             | Cancelled ->
                 Drafts.mark_failed_retryable ~now ~request_id ~reason:"Operation cancelled" m.drafts
             | Queued -> Drafts.mark_queued ~now ~request_id ~operation_id:(Some operation_id) m.drafts
             | Running -> Drafts.mark_accepted ~now ~request_id ~operation_id:(Some operation_id) m.drafts in
           ({ m with drafts }, []))
  | Msg.Reply_chat_status { keeper; result = Error err; _ } ->
      record_http_incident ~now ~source:(Health.Source_keeper keeper)
        ~context:(Say.make ~ko:"대화 요청 상태 조회" ~en:"Chat operation read") err m
  | Msg.Reply_chat_history { keeper; result = Ok page } ->
      let fleet =
        Fleet_store.apply_chat_history ~observed_at:now ~keeper page m.fleet
      in
      let drafts =
        confirm_pending_txs_from_history ~now ~keeper page m.drafts
      in
      let next = { m with fleet; drafts } in
      (* The failure rows of a cut reply are known only once the history has
         landed, so the reply asks for their journals. *)
      (next, View_fetches.cut_reply_fetches ~keeper next)
  | Msg.Reply_chat_history { keeper; result = Error err } ->
      let fleet =
        Fleet_store.mark_chat_history_failed ~at:now ~keeper
          ~reason:(Msg.http_error_detail err)
          ~retryable:(Msg.http_error_retryable err) m.fleet
      in
      record_http_incident ~now ~source:(Health.Source_keeper keeper)
        ~context:(Say.make ~ko:"대화 이력 조회" ~en:"Chat history fetch")
        err { m with fleet }
  | Msg.Reply_chat_operation_events { keeper; operation_id; from; result } -> (
      let slot = Fleet_store.cut_reply_for ~keeper ~operation_id m.fleet in
      (* A page counts only as the answer to the page the slot waits for. A
         second request for the same page, sent before the first answered,
         must not append its text again. *)
      let answers_slot =
        match Cut_reply.pending_page slot with
        | Some pending -> Wire_chat_journal.equal_from pending from
        | None -> false
      in
      let set_slot obs (m : Model.t) =
        if answers_slot then
          on_fleet (Fleet_store.set_cut_reply ~keeper ~operation_id obs) m
        else m
      in
      match result with
      | Ok page ->
          if answers_slot then
            let prev =
              Option.value (Observed.to_option slot) ~default:Cut_reply.start
            in
            match Cut_reply.apply_page_checked page prev with
            | Ok cut ->
                let next = set_slot (Observed.value ~observed_at:now cut) m in
                let cmds =
                  match Cut_reply.next_page cut with
                  | Some from ->
                      [
                        Cmd.Http_get
                          {
                            epoch = next.epoch;
                            req =
                              Cmd.Get_chat_operation_events
                                { keeper; operation_id; from };
                          };
                      ]
                  | None -> []
                in
                (next, cmds)
            | Error err ->
                let detail = Cut_reply.page_error_to_string err in
                let http_err = Msg.Transport (Health.Protocol_error detail) in
                err_reply
                  ~fail:
                    (set_slot
                       (Observed.failed ~reason:detail ~retryable:false ~at:now))
                  ~source:(Health.Source_keeper keeper) ~ko:"끊긴 답장 조회"
                  ~en:"Cut reply fetch" http_err
          else (m, [])
      (* 410 is the route's [journal_pruned]: the operation ended and the
         server keeps no journal for it, so there is nothing to show now or
         later (Server_keeper_chat_public_error.status maps only
         Journal_pruned to Gone). *)
      | Error (Msg.Http_error { status = 410; _ }) ->
          (set_slot (Observed.value ~observed_at:now Cut_reply.no_journal) m, [])
      | Error
          (( Msg.Http_error _
           | Msg.Transport _
           | Msg.Workspace_mismatch _
           | Msg.Decode_error _ ) as err) ->
          (* A reply for a page the slot no longer waits for changes nothing
             and records no incident. A workspace mismatch is the exception:
             it is about the workspace, not about this slot. *)
          let about_workspace =
            match err with
            | Msg.Workspace_mismatch _ -> true
            | Msg.Http_error _ | Msg.Transport _ | Msg.Decode_error _ -> false
          in
          if answers_slot || about_workspace then
            (* The failure replaces the slot, partial read included. A
               failed fetch that kept the partial read stale would ask the
               same page again after every trigger, so a page that fails for
               good would never stop. A retryable failure asks again from the
               start, and the partial read draws nothing meanwhile. *)
            err_reply
              ~fail:
                (set_slot
                   (Observed.failed ~reason:(Msg.http_error_detail err)
                      ~retryable:(Msg.http_error_retryable err) ~at:now))
              ~source:(Health.Source_keeper keeper) ~ko:"끊긴 답장 조회"
              ~en:"Cut reply fetch" err
          else (m, []))
  | Msg.Reply_turn_interrupt { keeper; result = Ok resp } ->
      let fleet0 =
        match resp.chat_control_token with
        | Some tok -> Fleet_store.update_chat_control_token ~keeper ~token:tok m.fleet
        | None -> m.fleet
      in
      let fleet, drafts, toast_level, toast_msg =
        if resp.signalled then
          ( fleet0
          , m.drafts
          , Model.Toast_info
          , Say.make
              ~ko:("턴 중단 신호 전송됨: " ^ keeper)
              ~en:("Turn interrupt signalled: " ^ keeper) )
        else if resp.paused then
          ( fleet0
          , m.drafts
          , Model.Toast_info
          , Say.make
              ~ko:("대기 요청 일시 정지됨: " ^ keeper)
              ~en:("Pending admission paused: " ^ keeper) )
        else
          let fleet1 =
            match Fleet_store.String_map.find_opt keeper fleet0.chat_streams with
            | Some b when b.interrupting ->
                Fleet_store.mark_chat_stream_interrupting ~keeper
                  ~request_id:b.request_id ~interrupting:false fleet0
            | Some _ | None -> fleet0
          in
          let drafts1 =
            match Drafts.active_tx_for_keeper ~keeper m.drafts with
            | Some tx ->
                Drafts.clear_interrupting ~now ~request_id:tx.request_id m.drafts
            | None -> m.drafts
          in
          let detail = Option.value resp.reason ~default:"not_signalled" in
          ( fleet1
          , drafts1
          , Model.Toast_warning
          , Say.make
              ~ko:(Printf.sprintf "턴 중단 미적용 (%s): %s" keeper detail)
              ~en:(Printf.sprintf "Turn interrupt not signalled (%s): %s" keeper detail) )
      in
      let next =
        Model.with_toast ~now ~level:toast_level toast_msg { m with fleet; drafts }
      in
      ( next
      , [
          Cmd.Http_get
            {
              epoch = m.epoch;
              req =
                Cmd.Get_chat_history { keeper; limit = Some 80; cursor = None };
            };
          Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_keeper_turns };
        ] )
  | Msg.Reply_turn_interrupt { keeper; result = Error err } ->
      let fleet =
        match Fleet_store.String_map.find_opt keeper m.fleet.chat_streams with
        | Some b when b.interrupting ->
            Fleet_store.mark_chat_stream_interrupting ~keeper
              ~request_id:b.request_id ~interrupting:false m.fleet
        | Some _ | None -> m.fleet
      in
      let drafts =
        match Drafts.active_tx_for_keeper ~keeper m.drafts with
        | Some tx ->
            Drafts.clear_interrupting ~now ~request_id:tx.request_id m.drafts
        | None -> m.drafts
      in
      let next, inc_cmds =
        record_http_incident ~now ~source:(Health.Source_keeper keeper)
          ~context:(Say.make ~ko:"턴 중단 요청" ~en:"Turn interrupt")
          err { m with fleet; drafts }
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , inc_cmds
        @ [
            Cmd.Http_get
              {
                epoch = m.epoch;
                req =
                  Cmd.Get_chat_history { keeper; limit = Some 80; cursor = None };
              };
            Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_keeper_turns };
          ] )
  | Msg.Reply_planning (Ok planning) ->
      let work = Work_store.apply_planning ~observed_at:now planning m.work in
      ( { m with work }
        |> Model.rebuild_attention
        |> Model.sync_effective_scorecard ~now
      , [] )
  | Msg.Reply_planning (Error err) ->
      err_reply
        ~fail:
          (on_work (fun (x : Work_store.t) ->
               { x with planning = failed_slot err x.planning }))
        ~source:Health.Source_client_http ~ko:"목표·작업 조회"
        ~en:"Planning fetch" err
  | Msg.Reply_planning_backlog counts ->
      let work = Work_store.apply_backlog_counts counts m.work in
      ({ m with work } |> Model.sync_effective_scorecard ~now, [])
  | Msg.Reply_verifications (Ok vs) ->
      ( { m with work = Work_store.apply_verifications ~observed_at:now vs m.work }
        |> Model.sync_effective_scorecard ~now
      , [] )
  | Msg.Reply_verifications (Error err) ->
      err_reply
        ~fail:
          (on_work (fun (x : Work_store.t) ->
               { x with verifications = failed_slot err x.verifications }))
        ~source:Health.Source_client_http ~ko:"검증 목록 조회"
        ~en:"Verifications fetch" err
  | Msg.Reply_schedules (Ok scheds) ->
      ( { m with work = Work_store.apply_schedules ~observed_at:now scheds m.work }
      , [] )
  | Msg.Reply_schedules (Error err) ->
      err_reply
        ~fail:
          (on_work (fun (x : Work_store.t) ->
               { x with schedules = failed_slot err x.schedules }))
        ~source:Health.Source_client_http ~ko:"일정 조회"
        ~en:"Schedules fetch" err
  | Msg.Reply_asks (Ok asks) ->
      let work = Work_store.apply_asks ~observed_at:now asks m.work in
      (Model.rebuild_attention { m with work }, [])
  | Msg.Reply_asks (Error err) ->
      err_reply
        ~fail:
          (on_work (fun (x : Work_store.t) ->
               { x with asks = failed_slot err x.asks }))
        ~source:Health.Source_client_http ~ko:"질문 목록 조회"
        ~en:"Asks fetch" err
  | Msg.Reply_tool_approvals (Ok approvals) ->
      let work =
        Work_store.apply_tool_approvals ~observed_at:now approvals m.work
      in
      (Model.rebuild_attention { m with work }, [])
  | Msg.Reply_tool_approvals (Error err) ->
      err_reply
        ~fail:
          (on_work (fun (x : Work_store.t) ->
               { x with tool_approvals = failed_slot err x.tool_approvals }))
        ~source:Health.Source_client_http ~ko:"도구 승인 대기 조회"
        ~en:"Tool approvals fetch" err
  | Msg.Reply_gate_pending (Ok gates) ->
      let work = Work_store.apply_gate_pending ~observed_at:now gates m.work in
      (Model.rebuild_attention { m with work }, [])
  | Msg.Reply_gate_pending (Error err) ->
      err_reply
        ~fail:
          (on_work (fun (x : Work_store.t) ->
               { x with gate_pending = failed_slot err x.gate_pending }))
        ~source:Health.Source_client_http ~ko:"게이트 승인 조회"
        ~en:"Gate pending fetch" err
  | Msg.Reply_candle_ledger (Ok ledger) ->
      ( {
          m with
          work = Work_store.apply_candle_ledger ~observed_at:now ledger m.work;
        }
      , [] )
  | Msg.Reply_candle_ledger (Error err) -> (
      match err with
      | Msg.Http_error { status = 404; _ } ->
          let work =
            Work_store.apply_candle_ledger_fallback ~observed_at:now
              ~summary:m.fleet.candle_summary_fallback
              ~balances:
                (Fleet_store.String_map.bindings m.fleet.candle_balances_milli)
              m.work
          in
          ({ m with work }, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:
              (on_work (fun (x : Work_store.t) ->
                   { x with candle_ledger = failed_slot err x.candle_ledger }))
            ~source:Health.Source_client_http ~ko:"캔들 원장 조회"
            ~en:"Candle ledger fetch" err)
  | Msg.Reply_work_mutation
      { label; attention_id; decision_kind; target_id; keeper; result = Ok () } ->
      let attention =
        match attention_id with
        | Some id -> Attention.advance_after_resolution ~resolved_id:id m.attention
        | None -> m.attention
      in
      let work =
        match decision_kind, target_id with
        | Some kind, Some tid ->
            Work_store.record_decision ~at_unix:m.freshness.last_wall_unix ~kind
              ~target_id:tid ~keeper ~summary:(Say.resolve m.lang label) m.work
        | None, _ | Some _, None -> m.work
      in
      let nav, ask_modal =
        match m.ask_modal, attention_id with
        | Some modal, Some id
          when String.equal id ("ask:" ^ modal.ask.ask_id) ->
            let nav =
              match m.nav.overlay with
              | Some Nav.Ask_answer -> { m.nav with overlay = None }
              | Some
                  ( Nav.Palette
                  | Nav.Settings _
                  | Nav.Incidents
                  | Nav.Queue_context _
                  | Nav.Inline_action _
                  | Nav.Help
                  | Nav.System_gate _ )
              | None ->
                  m.nav
            in
            (nav, None)
        | Some _, _ | None, _ -> (m.nav, m.ask_modal)
      in
      let next =
        { m with nav; ask_modal; attention; work }
        |> Model.with_toast ~now ~level:Model.Toast_success label
      in
      (next, [])
  | Msg.Reply_work_mutation { label; attention_id; result = Error err; _ } ->
      let failed, cmds =
        fail_decision_post ~now ~attention_id ~context:label err m
      in
      let ask_modal =
        match err, failed.ask_modal, attention_id with
        | Msg.Workspace_mismatch _, _, _ -> None
        | ( (Msg.Transport _ | Msg.Http_error _ | Msg.Decode_error _)
          , Some modal
          , Some id )
          when String.equal id ("ask:" ^ modal.ask.ask_id) ->
            Some
              {
                modal with
                submitting = false;
                error = Some (Msg.http_error_summary err);
              }
        | (Msg.Transport _ | Msg.Http_error _ | Msg.Decode_error _), _, _ ->
            failed.ask_modal
      in
      ({ failed with ask_modal }, cmds)
  | Msg.Reply_tool_approval
      { keeper; approval_id; attention_id; decision; result = Ok outcome } -> (
      let decision_kind, settled_label, noun_ko, noun_en =
        match decision with
        | Wire_work.Tool_approve ->
            ( Work_store.Decision_tool_approved,
              Say.make ~ko:"도구 호출 승인됨" ~en:"Tool call approved",
              "승인",
              "approval" )
        | Wire_work.Tool_deny ->
            ( Work_store.Decision_tool_denied,
              Say.make ~ko:"도구 호출 거절됨" ~en:"Tool call denied",
              "거절",
              "denial" )
      in
      let resolve ~level label =
        let work =
          Work_store.record_decision ~at_unix:m.freshness.last_wall_unix
            ~kind:decision_kind ~target_id:approval_id ~keeper:(Some keeper)
            ~summary:(Say.resolve m.lang label) m.work
        in
        let attention =
          Attention.advance_after_resolution ~resolved_id:attention_id
            m.attention
        in
        ({ m with attention; work } |> Model.with_toast ~now ~level label, [])
      in
      match outcome with
      | Wire_work.Tool_approval_settled ->
          resolve ~level:Model.Toast_success settled_label
      | Wire_work.Tool_approval_remembered ->
          resolve ~level:Model.Toast_info
            (Say.make
               ~ko:
                 ("기다림이 끝난 호출이라 같은 호출을 다시 할 때 " ^ noun_ko
                ^ "이 적용됩니다")
               ~en:
                 ("The call had stopped waiting; the " ^ noun_en
                ^ " applies when the same call is retried"))
      | Wire_work.Tool_approval_no_waiting_call ->
          (* Nothing received the decision, so no decision is recorded and
             the held approvals are read again instead of dropping the item
             here. *)
          let next =
            {
              m with
              attention = Attention.clear_in_flight ~id:attention_id m.attention;
            }
            |> on_work (fun (x : Work_store.t) ->
                   { x with tool_approvals = Observed.mark_stale x.tool_approvals })
            |> Model.with_toast ~now ~level:Model.Toast_warning
                 (Say.make
                    ~ko:("기다리는 호출이 없어 " ^ noun_ko ^ "이 적용되지 않았습니다")
                    ~en:
                      ("No call was waiting, so the " ^ noun_en
                     ^ " was not applied"))
          in
          (next, [ Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_tool_approvals } ]))
  | Msg.Reply_tool_approval { attention_id; decision; result = Error err; _ } ->
      let context =
        match decision with
        | Wire_work.Tool_approve ->
            Say.make ~ko:"도구 호출 승인" ~en:"Tool call approval"
        | Wire_work.Tool_deny -> Say.make ~ko:"도구 호출 거절" ~en:"Tool call denial"
      in
      fail_decision_post ~now ~attention_id:(Some attention_id) ~context err m
  | Msg.Reply_board_feed (Ok feed) ->
      ( {
          m with
          knowledge = Knowledge_store.apply_board ~observed_at:now feed m.knowledge;
        }
        |> Model.sync_effective_scorecard ~now
      , [] )
  | Msg.Reply_board_feed (Error err) ->
      err_reply
        ~fail:
          (on_knowledge (fun (x : Knowledge_store.t) ->
               { x with board = failed_slot err x.board }))
        ~source:Health.Source_client_http ~ko:"보드 피드 조회"
        ~en:"Board feed fetch" err
  | Msg.Reply_board_thread (Ok thread) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_thread ~observed_at:now thread m.knowledge;
        }
      , [] )
  | Msg.Reply_board_thread (Error err) ->
      err_reply
        ~fail:
          (on_knowledge (fun (x : Knowledge_store.t) ->
               { x with active_thread = failed_slot err x.active_thread }))
        ~source:Health.Source_client_http ~ko:"보드 스레드 조회"
        ~en:"Board thread fetch" err
  | Msg.Reply_board_hearths (Ok hs) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_board_hearths ~observed_at:now hs m.knowledge;
        }
      , [] )
  | Msg.Reply_board_hearths (Error err) -> (
      match err with
      | Msg.Http_error { status = 404; _ } ->
          ({ m with knowledge = { m.knowledge with board_hearths = Observed.absent } }, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:
              (on_knowledge (fun (x : Knowledge_store.t) ->
                   { x with board_hearths = failed_slot err x.board_hearths }))
            ~source:Health.Source_client_http ~ko:"서브보드 목록 조회"
            ~en:"Board hearths fetch" err)
  | Msg.Reply_board_comment { post_id; result = Ok () } ->
      let is_board_comment_for_post = function
        | Nav.Board_comment { post_id = modal_post_id; _ } ->
            String.equal modal_post_id post_id
        | Nav.Btw_query
        | Nav.Gate_reject _
        | Nav.Verification_reject _
        | Nav.Harness_overrule _
        | Nav.Task_cancel _
        | Nav.Schedule_form
        | Nav.Connector_form
        | Nav.Repo_add_form
        | Nav.Board_new_post
        | Nav.Code_finder_form
        | Nav.Code_search_form
        | Nav.Github_token_form _ ->
            false
      in
      let matches_modal =
        match m.inline_modal with
        | Some modal -> modal.submitting && is_board_comment_for_post modal.kind
        | None -> false
      in
      let nav =
        if not matches_modal then m.nav
        else
          match m.nav.overlay with
          | Some (Nav.Inline_action k) when is_board_comment_for_post k ->
              { m.nav with overlay = None }
          | Some
              ( Nav.Inline_action _
              | Nav.Ask_answer
              | Nav.Palette
              | Nav.Settings _
              | Nav.Incidents
              | Nav.Queue_context _
              | Nav.Help
              | Nav.System_gate _ )
          | None ->
              m.nav
      in
      let inline_modal = if matches_modal then None else m.inline_modal in
      let next =
        { m with nav; inline_modal }
        |> Model.with_toast ~now ~level:Model.Toast_success
             (Say.make ~ko:"댓글이 등록되었습니다" ~en:"Comment posted")
      in
      ( next
      , [
          Cmd.Http_get
            {
              epoch = m.epoch;
              req = Cmd.Get_board_thread { post_id; comment_limit = Some 100 };
            };
          Cmd.Http_get
            {
              epoch = m.epoch;
              req =
                Cmd.Get_board_feed
                  {
                    sort_by = next.knowledge.board_sort_by;
                    hearth = next.knowledge.board_hearth;
                    signal_only = next.knowledge.board_signal_only;
                    limit = Some 50;
                    offset = None;
                  };
            };
        ] )
  | Msg.Reply_board_comment { post_id; result = Error err } ->
      let inline_modal =
        Option.map
          (fun (modal : Model.inline_modal_state) ->
            match modal.kind with
            | Nav.Board_comment { post_id = modal_post_id; _ }
              when modal.submitting && String.equal modal_post_id post_id ->
                {
                  modal with
                  submitting = false;
                  error = Some (Msg.http_error_detail err);
                }
            | Nav.Board_comment _
            | Nav.Btw_query
            | Nav.Gate_reject _
            | Nav.Verification_reject _
            | Nav.Harness_overrule _
            | Nav.Task_cancel _
            | Nav.Schedule_form
            | Nav.Connector_form
            | Nav.Repo_add_form
            | Nav.Board_new_post
            | Nav.Code_finder_form
            | Nav.Code_search_form
            | Nav.Github_token_form _ ->
                modal)
          m.inline_modal
      in
      let next, cmds =
        record_http_incident ~now ~source:Health.Source_client_http
          ~context:(Say.make ~ko:"댓글 등록" ~en:"Board comment")
          err { m with inline_modal }
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_board_vote { post_id; result = Ok () } ->
      let next =
        Model.with_toast ~now ~level:Model.Toast_success
          (Say.make ~ko:"투표가 반영되었습니다" ~en:"Vote recorded")
          m
      in
      let thread_cmds =
        match Model.active_dive next with
        | Some (Nav.Dive_knowledge (Nav.Thread_dive pid))
          when String.equal pid post_id ->
            [
              Cmd.Http_get
                {
                  epoch = m.epoch;
                  req =
                    Cmd.Get_board_thread { post_id; comment_limit = Some 100 };
                };
            ]
        | Some
            ( Nav.Dive_knowledge
                ( Nav.Thread_dive _
                | Nav.Wiki_dive _
                | Nav.Artifact_dive _
                | Nav.Memory_diff_dive _ )
            | Nav.Dive_keeper _
            | Nav.Dive_work _
            | Nav.Dive_runtime _
            | Nav.Dive_infra _ )
        | None ->
            []
      in
      let feed_cmd =
        Cmd.Http_get
          {
            epoch = m.epoch;
            req =
              Cmd.Get_board_feed
                {
                  sort_by = next.knowledge.board_sort_by;
                  hearth = next.knowledge.board_hearth;
                  signal_only = next.knowledge.board_signal_only;
                  limit = Some 50;
                  offset = None;
                };
          }
      in
      (next, feed_cmd :: thread_cmds)
  | Msg.Reply_board_vote { post_id = _; result = Error err } ->
      let next, cmds =
        record_http_incident ~now ~source:Health.Source_client_http
          ~context:(Say.make ~ko:"보드 투표" ~en:"Board vote")
          err m
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_wiki_index (Ok idx) ->
      let next =
        {
          m with
          knowledge =
            Knowledge_store.apply_wiki_index ~observed_at:now idx m.knowledge;
        }
      in
      (* Until the index lands no page is selected, so the Wiki tab's fetch
         list could not name one. Ask for the page the index selected. *)
      (next, View_fetches.selected_wiki_page_fetch next)
  | Msg.Reply_wiki_index (Error err) ->
      err_reply
        ~fail:
          (on_knowledge (fun (x : Knowledge_store.t) ->
               { x with wiki_index = failed_slot err x.wiki_index }))
        ~source:Health.Source_client_http ~ko:"위키 색인 조회"
        ~en:"Wiki index fetch" err
  | Msg.Reply_wiki_page { page; result = Ok detail } ->
      let matches_pending =
        Option.equal String.equal m.knowledge.pending_wiki_edit_slug (Some page)
      in
      let knowledge =
        Knowledge_store.set_wiki_page ~slug:page
          (Observed.value ~observed_at:now detail)
          m.knowledge
      in
      let knowledge =
        if matches_pending then Knowledge_store.clear_pending_wiki_edit knowledge
        else knowledge
      in
      let next = { m with knowledge } in
      let next =
        if matches_pending && Model.is_viewing_wiki_slug ~slug:page next then
          Model.open_wiki_edit_modal_for_detail detail next
        else next
      in
      (next, [])
  | Msg.Reply_wiki_page { page; result = Error err } ->
      err_reply
        ~fail:
          (on_knowledge (fun (x : Knowledge_store.t) ->
               let x =
                 Knowledge_store.set_wiki_page ~slug:page
                   (failed_slot err (Knowledge_store.wiki_page_for ~slug:page x))
                   x
               in
               if Option.equal String.equal x.pending_wiki_edit_slug (Some page)
               then Knowledge_store.clear_pending_wiki_edit x
               else x))
        ~source:Health.Source_client_http ~ko:"위키 문서 조회"
        ~en:"Wiki page fetch" err
  | Msg.Reply_wiki_log (Ok log) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_wiki_log ~observed_at:now log m.knowledge;
        }
      , [] )
  | Msg.Reply_wiki_log (Error err) ->
      err_reply
        ~fail:
          (on_knowledge (fun (x : Knowledge_store.t) ->
               { x with wiki_log = failed_slot err x.wiki_log }))
        ~source:Health.Source_client_http ~ko:"위키 변경 이력 조회"
        ~en:"Wiki log fetch" err
  | Msg.Reply_wiki_search (Ok search) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_wiki_search ~observed_at:now search m.knowledge;
        }
      , [] )
  | Msg.Reply_wiki_search (Error err) ->
      err_reply
        ~fail:
          (on_knowledge (fun (x : Knowledge_store.t) ->
               { x with wiki_search = failed_slot err x.wiki_search }))
        ~source:Health.Source_client_http ~ko:"위키 검색"
        ~en:"Wiki search" err
  | Msg.Reply_wiki_lint (Ok lint) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_wiki_lint ~observed_at:now lint m.knowledge;
        }
      , [] )
  | Msg.Reply_wiki_lint (Error err) ->
      err_reply
        ~fail:
          (on_knowledge (fun (x : Knowledge_store.t) ->
               { x with wiki_lint = failed_slot err x.wiki_lint }))
        ~source:Health.Source_client_http ~ko:"위키 린트 조회"
        ~en:"Wiki lint fetch" err
  | Msg.Reply_wiki_put { page; result = Ok saved } ->
      (* The answer names the revision written but no rendered page, so the
         stored page and index are marked stale and the current view reads
         them again instead of patching them. *)
      let knowledge =
        let k = m.knowledge in
        Knowledge_store.set_wiki_page ~slug:page
          (Observed.mark_stale (Knowledge_store.wiki_page_for ~slug:page k))
          { k with wiki_index = Observed.mark_stale k.wiki_index }
      in
      let done_ko, done_en =
        match saved.action with
        | Wire_knowledge.Wiki_page_created -> ("위키 생성 완료", "Created wiki")
        | Wire_knowledge.Wiki_page_updated -> ("위키 저장 완료", "Saved wiki")
      in
      let level, warning_note =
        match saved.warnings with
        | [] -> (Model.Toast_success, "")
        | warnings -> (Model.Toast_warning, " · " ^ String.concat "; " warnings)
      in
      let saved_page = Printf.sprintf "%s (rev %d)" page saved.revision in
      let next =
        { m with knowledge }
        |> Model.with_toast ~now ~level
             (Say.make
                ~ko:(done_ko ^ ": " ^ saved_page ^ warning_note)
                ~en:(done_en ^ ": " ^ saved_page ^ warning_note))
      in
      (next, View_fetches.fetches_for_current_view next)
  | Msg.Reply_wiki_put { page; result = Error err } ->
      let next, cmds =
        record_http_incident ~now ~source:Health.Source_client_http
          ~context:
            (Say.make ~ko:("위키 저장: " ^ page) ~en:("Save wiki: " ^ page))
          err m
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_artifacts (Ok items) ->
      let knowledge =
        Knowledge_store.apply_artifacts ~observed_at:now items m.knowledge
      in
      let next = { m with knowledge } in
      let detail_cmds =
        let target_artifact_opt =
          match Model.active_dive next with
          | Some (Nav.Dive_knowledge (Nav.Artifact_dive target)) ->
              Knowledge_store.find_artifact_by_id_or_sha target next.knowledge
          | Some
              ( Nav.Dive_keeper _
              | Nav.Dive_work _
              | Nav.Dive_runtime _
              | Nav.Dive_infra _
              | Nav.Dive_knowledge
                  ( Nav.Thread_dive _
                  | Nav.Wiki_dive _
                  | Nav.Memory_diff_dive _ ) ) ->
              None
          | None ->
              if
                Nav.equal_workspace next.nav.workspace Nav.Knowledge
                && Nav.equal_knowledge_tab next.knowledge.active_tab
                     Nav.Knowledge_artifacts
              then Knowledge_store.selected_artifact next.knowledge
              else None
        in
        match target_artifact_opt with
        | Some a ->
            let already_settled =
              Option.is_some
                (Knowledge_store.artifact_detail_for_entry a next.knowledge)
              ||
              match next.knowledge.active_artifact_detail with
              | Observed.Failed { retryable = false; _ } ->
                  Option.is_some
                    (Knowledge_store.artifact_detail_failure_for_entry a
                       next.knowledge)
              | Observed.Loading _
              | Observed.Value _
              | Observed.Absent
              | Observed.Unreported
              | Observed.Failed { retryable = true; _ } ->
                  false
            in
            if already_settled then []
            else
              [
                Cmd.Http_get
                  {
                    epoch = next.epoch;
                    req =
                      Cmd.Get_artifact_detail
                        { id = a.id; revision = Some a.revision };
                  };
              ]
        | None -> []
      in
      (next, detail_cmds)
  | Msg.Reply_artifacts (Error err) ->
      err_reply
        ~fail:
          (on_knowledge (fun (x : Knowledge_store.t) ->
               { x with artifacts = failed_slot err x.artifacts }))
        ~source:Health.Source_client_http ~ko:"산출물 목록 조회"
        ~en:"Artifacts fetch" err
  | Msg.Reply_artifact_detail { id; result = Ok detail } ->
      (* Guard against stale out-of-order responses after selection changed. *)
      let matches_active =
        let matches_target t =
          String.equal t id
          || String.equal t detail.artifact.id
          || String.equal t detail.artifact.body.sha256
        in
        match Model.active_dive m with
        | Some (Nav.Dive_knowledge (Nav.Artifact_dive target)) ->
            matches_target target
        | Some
            ( Nav.Dive_keeper _
            | Nav.Dive_work _
            | Nav.Dive_runtime _
            | Nav.Dive_infra _
            | Nav.Dive_knowledge
                ( Nav.Thread_dive _
                | Nav.Wiki_dive _
                | Nav.Memory_diff_dive _ ) )
        | None -> (
            match Knowledge_store.selected_artifact m.knowledge with
            | Some sel ->
                matches_target sel.id || matches_target sel.body.sha256
            | None -> true)
      in
      let matches_rev =
        Knowledge_store.matches_pending_artifact_revision
          ~id:detail.artifact.id ~revision:detail.artifact.revision m.knowledge
      in
      if not (matches_active && matches_rev) then (m, [])
      else
        ( {
            m with
            knowledge =
              Knowledge_store.apply_artifact_detail ~observed_at:now detail
                m.knowledge;
          }
        , [] )
  | Msg.Reply_artifact_detail { id; result = Error err } ->
      let matches_active =
        match Model.active_dive m with
        | Some (Nav.Dive_knowledge (Nav.Artifact_dive target)) -> (
            String.equal target id
            ||
            match Knowledge_store.find_artifact_by_id_or_sha target m.knowledge with
            | Some art ->
                String.equal art.id id || String.equal art.body.sha256 id
            | None -> false)
        | Some
            ( Nav.Dive_keeper _
            | Nav.Dive_work _
            | Nav.Dive_runtime _
            | Nav.Dive_infra _
            | Nav.Dive_knowledge
                ( Nav.Thread_dive _
                | Nav.Wiki_dive _
                | Nav.Memory_diff_dive _ ) )
        | None -> (
            match Knowledge_store.selected_artifact m.knowledge with
            | Some sel ->
                String.equal sel.id id || String.equal sel.body.sha256 id
            | None -> false)
      in
      if not matches_active then (m, [])
      else
        let retryable =
          match err with
          | Msg.Transport _ -> true
          | Msg.Http_error { status; _ } -> status >= 500 || status = 429
          | Msg.Workspace_mismatch _ | Msg.Decode_error _ -> false
        in
        let knowledge =
          Knowledge_store.mark_artifact_detail_failed ~target:id ~at:now
            ~reason:(Msg.http_error_detail err) ~retryable m.knowledge
        in
        record_http_incident ~now ~source:Health.Source_client_http
          ~context:(Say.make ~ko:"산출물 본문 조회" ~en:"Artifact detail fetch")
          err { m with knowledge }
  | Msg.Reply_artifact_checks (Ok checks) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_artifact_checks ~observed_at:now checks
              m.knowledge;
        }
      , [] )
  | Msg.Reply_artifact_checks (Error err) -> (
      match err with
      | Msg.Http_error { status = 404; _ } ->
          ( { m with knowledge = { m.knowledge with artifact_checks = Observed.absent } }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:
              (on_knowledge (fun (x : Knowledge_store.t) ->
                   { x with artifact_checks = failed_slot err x.artifact_checks }))
            ~source:Health.Source_client_http ~ko:"산출물 확인 체크 조회"
            ~en:"Artifact checks fetch" err)
  | Msg.Reply_artifact_check { id = _; result = Ok chk } ->
      let knowledge =
        Knowledge_store.apply_artifact_check_update ~observed_at:now chk
          m.knowledge
      in
      let msg =
        if chk.checked then
          Say.make ~ko:"산출물 확인 체크됨 (✓)" ~en:"Artifact marked checked (✓)"
        else
          Say.make ~ko:"산출물 확인 체크 해제됨" ~en:"Artifact check cleared"
      in
      (Model.with_toast ~now ~level:Model.Toast_success msg { m with knowledge }, [])
  | Msg.Reply_artifact_check { id = _; result = Error err } ->
      let next, cmds =
        record_http_incident ~now ~source:Health.Source_client_http
          ~context:(Say.make ~ko:"산출물 확인 체크" ~en:"Artifact check update")
          err m
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_artifact_share { id; result = Ok res } ->
      let knowledge =
        Knowledge_store.apply_artifact_share_result ~observed_at:now res
          m.knowledge
      in
      let level, msg, refresh_cmds =
        match res.outcome with
        | `Conflict ->
            ( Model.Toast_warning
            , Say.make ~ko:"공유 버전 충돌 — 최신 상태를 다시 불러옵니다"
                ~en:"Share version conflict — refreshing detail"
            , [
                Cmd.Http_get
                  {
                    epoch = m.epoch;
                    req = Cmd.Get_artifact_detail { id; revision = None };
                  };
              ] )
        | `Applied ->
            let s =
              if res.shared then
                Say.make ~ko:"외부 공유 활성화됨 ([Y] 공개 URL 복사)"
                  ~en:"External sharing enabled ([Y] copy public URL)"
              else
                Say.make ~ko:"외부 공유 비활성화됨" ~en:"External sharing disabled"
            in
            (Model.Toast_success, s, [])
      in
      ( Model.with_toast ~now ~level msg { m with knowledge }
      , refresh_cmds )
  | Msg.Reply_artifact_share { id = _; result = Error err } ->
      let next, cmds =
        record_http_incident ~now ~source:Health.Source_client_http
          ~context:(Say.make ~ko:"산출물 외부 공유" ~en:"Artifact share toggle")
          err m
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_world_memory (Ok wm) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_world_memory ~observed_at:now wm m.knowledge;
        }
      , [] )
  | Msg.Reply_world_memory (Error err) ->
      err_reply
        ~fail:
          (on_knowledge (fun (x : Knowledge_store.t) ->
               { x with world_memory = failed_slot err x.world_memory }))
        ~source:Health.Source_client_http ~ko:"세계 기억 조회"
        ~en:"World memory fetch" err
  | Msg.Reply_memory_diff { keeper; window; result = Ok diff } ->
      (* A diff is stored for the scope it was asked about. One whose scope
         differs from the request is not stored. *)
      let scope_ok =
        match keeper, diff.scope with
        | None, Wire_knowledge.Scope_world -> true
        | Some kp, Wire_knowledge.Scope_keeper dk -> String.equal kp dk
        | None, Wire_knowledge.Scope_keeper _
        | Some _, Wire_knowledge.Scope_world ->
            false
      in
      if scope_ok then
        ( {
            m with
            knowledge =
              Knowledge_store.set_memory_diff ~keeper ~window
                (Observed.value ~observed_at:now diff)
                m.knowledge;
          }
        , [] )
      else (m, [])
  | Msg.Reply_memory_diff { keeper; window; result = Error err } ->
      err_reply
        ~fail:
          (on_knowledge (fun (x : Knowledge_store.t) ->
               Knowledge_store.set_memory_diff ~keeper ~window
                 (failed_slot err
                    (Knowledge_store.memory_diff_for ~keeper ~window x))
                 x))
        ~source:Health.Source_client_http ~ko:"기억 변화 조회"
        ~en:"Memory diff fetch" err
  | Msg.Reply_keeper_memory_os_internals { keeper; result = Ok internals } ->
      (* Internals are stored for the keeper they were asked about. An answer
         that names another keeper is not stored. *)
      if String.equal internals.keeper keeper then
        ( {
            m with
            knowledge =
              Knowledge_store.set_memory_os_internals ~keeper
                (Observed.value ~observed_at:now internals)
                m.knowledge;
          }
        , [] )
      else (m, [])
  | Msg.Reply_keeper_memory_os_internals { keeper; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 404; _ } ->
          ( {
              m with
              knowledge =
                Knowledge_store.set_memory_os_internals ~keeper Observed.absent
                  m.knowledge;
            }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:
              (on_knowledge (fun (x : Knowledge_store.t) ->
                   Knowledge_store.set_memory_os_internals ~keeper
                     (failed_slot err
                        (Knowledge_store.memory_os_internals_for ~keeper x))
                     x))
            ~source:Health.Source_client_http ~ko:"메모리 OS 내부 상태 조회"
            ~en:"Memory OS internals fetch" err)
  | Msg.Reply_keeper_memory_facts { keeper; result = Ok facts } ->
      (* Facts land on the keeper they were asked about. An answer that names
         another keeper is not stored. *)
      if String.equal facts.keeper keeper then
        ( {
            m with
            knowledge =
              Knowledge_store.set_keeper_memory_facts ~keeper
                (Observed.value ~observed_at:now facts)
                m.knowledge;
          }
        , [] )
      else (m, [])
  | Msg.Reply_keeper_memory_facts { keeper; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          ( {
              m with
              knowledge =
                Knowledge_store.mark_keeper_memory_facts_failed ~at:now ~keeper
                  ~reason:(Msg.http_error_detail err) ~retryable:false
                  ~auth_denied:true m.knowledge;
            }
          , [] )
      | Msg.Http_error { status = 404; _ } ->
          ( {
              m with
              knowledge =
                Knowledge_store.set_keeper_memory_facts ~keeper Observed.absent
                  m.knowledge;
            }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:
              (on_knowledge (fun (x : Knowledge_store.t) ->
                   Knowledge_store.set_keeper_memory_facts ~keeper
                     (failed_slot err
                        (Knowledge_store.keeper_memory_facts_for ~keeper x))
                     x))
            ~source:(Health.Source_keeper keeper)
            ~ko:("키퍼 기억 사실 조회: " ^ keeper)
            ~en:("Keeper memory facts fetch: " ^ keeper)
            err)
  | Msg.Reply_keeper_memory_activity { keeper; result = Ok activity } ->
      if String.equal activity.keeper keeper then
        ( {
            m with
            knowledge =
              Knowledge_store.set_keeper_memory_activity ~keeper
                (Observed.value ~observed_at:now activity)
                m.knowledge;
          }
        , [] )
      else (m, [])
  | Msg.Reply_keeper_memory_activity { keeper; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 404; _ } ->
          ( {
              m with
              knowledge =
                Knowledge_store.set_keeper_memory_activity ~keeper
                  Observed.absent m.knowledge;
            }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:
              (on_knowledge (fun (x : Knowledge_store.t) ->
                   Knowledge_store.set_keeper_memory_activity ~keeper
                     (failed_slot err
                        (Knowledge_store.keeper_memory_activity_for ~keeper x))
                     x))
            ~source:(Health.Source_keeper keeper)
            ~ko:("키퍼 기억 변천 조회: " ^ keeper)
            ~en:("Keeper memory activity fetch: " ^ keeper)
            err)
  | Msg.Reply_keeper_memory_health (Ok fleet) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_keeper_memory_health ~observed_at:now fleet
              m.knowledge;
        }
      , [] )
  | Msg.Reply_keeper_memory_health (Error err) -> (
      match err with
      | Msg.Http_error { status = 404; _ } ->
          let knowledge =
            { m.knowledge with keeper_memory_health = Observed.absent }
          in
          ({ m with knowledge }, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          let retryable =
            match err with
            | Msg.Transport _ -> true
            | Msg.Http_error { status; _ } when status >= 500 && status <= 599
              ->
                true
            | Msg.Http_error _ | Msg.Workspace_mismatch _ | Msg.Decode_error _ ->
                false
          in
          let knowledge =
            Knowledge_store.fail_keeper_memory_health
              ~reason:(Msg.http_error_detail err) ~retryable ~at:now m.knowledge
          in
          record_http_incident ~now ~source:Health.Source_client_http
            ~context:
              (Say.make ~ko:"키퍼 기억 상태 지표 조회"
                 ~en:"Keeper memory health fetch")
            err { m with knowledge })
  | Msg.Reply_memory_act { keeper; result = Ok ans } ->
      let knowledge =
        Knowledge_store.record_memory_act_answer ~keeper ans m.knowledge
      in
      let level, msg =
        match ans with
        | Wire_knowledge.Memory_act_done _ ->
            ( Model.Toast_success
            , Say.make
                ~ko:("사서 복구 실행 완료: " ^ keeper)
                ~en:("Memory recovery applied: " ^ keeper) )
        | Wire_knowledge.Memory_act_refused { code; _ } ->
            ( Model.Toast_warning
            , Say.make
                ~ko:("사서 복구 거절: " ^ code)
                ~en:("Memory recovery refused: " ^ code) )
        | Wire_knowledge.Memory_act_invalid detail ->
            ( Model.Toast_error
            , Say.make
                ~ko:("잘못된 사서 복구 요청: " ^ detail)
                ~en:("Invalid memory act: " ^ detail) )
        | Wire_knowledge.Memory_act_no_writer ->
            ( Model.Toast_info
            , Say.make ~ko:"실행 중인 기억 기록기 없음"
                ~en:"No active memory writer" )
      in
      (Model.with_toast ~now ~level msg { m with knowledge }, [])
  | Msg.Reply_memory_act { keeper; result = Error err } ->
      let next, cmds =
        err_reply
          (* A recovery act is a write: the incident carries the failure. *)
          ~fail:Fun.id
          ~source:(Health.Source_keeper keeper) ~ko:"사서 기억 복구"
          ~en:"Memory recovery act" err
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_keeper_context_turn_records { keeper; result = Ok page } ->
      let keeper_context =
        Keeper_context_store.apply_turn_records ~observed_at:now ~keeper page
          m.keeper_context
      in
      let next = { m with keeper_context } in
      (next, View_fetches.fetches_for_current_view next)
  | Msg.Reply_keeper_context_turn_records { keeper; result = Error err } -> (
      let reason = Msg.http_error_detail err in
      match err with
      | Msg.Http_error { status = 404; _ } ->
          ( {
              m with
              keeper_context =
                Keeper_context_store.mark_turn_records_failed ~at:now ~keeper
                  ~reason ~retryable:false m.keeper_context;
            }
          , [] )
      | Msg.Decode_error _ ->
          err_reply
            ~fail:(fun m ->
              {
                m with
                keeper_context =
                  Keeper_context_store.mark_turn_records_failed ~at:now ~keeper
                    ~reason ~retryable:false m.keeper_context;
              })
            ~source:(Health.Source_keeper keeper) ~ko:"키퍼 턴 기록 조회"
            ~en:"Keeper turn records fetch" err
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _ ->
          err_reply
            ~fail:(fun m ->
              {
                m with
                keeper_context =
                  Keeper_context_store.mark_turn_records_failed ~at:now ~keeper
                    ~reason ~retryable:true m.keeper_context;
              })
            ~source:(Health.Source_keeper keeper) ~ko:"키퍼 턴 기록 조회"
            ~en:"Keeper turn records fetch" err)
  | Msg.Reply_keeper_provider_input { keeper; turn_ref; result = Ok manifest } ->
      ( {
          m with
          keeper_context =
            Keeper_context_store.apply_provider_input ~observed_at:now ~keeper
              ~turn_ref manifest m.keeper_context;
        }
      , [] )
  | Msg.Reply_keeper_provider_input { keeper; turn_ref; result = Error err }
    -> (
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          ( {
              m with
              keeper_context =
                Keeper_context_store.mark_provider_input_denied ~at:now ~keeper
                  ~turn_ref ~reason:(Msg.http_error_detail err) m.keeper_context;
            }
          , [] )
      | Msg.Http_error { status = 404; _ } ->
          ( {
              m with
              keeper_context =
                Keeper_context_store.mark_provider_input_absent ~keeper
                  ~turn_ref m.keeper_context;
            }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          let on_kc f (m : Model.t) =
            let st = Keeper_context_store.get_keeper ~keeper m.keeper_context in
            let by_keeper =
              Keeper_context_store.String_map.add keeper (f st)
                m.keeper_context.by_keeper
            in
            { m with keeper_context = { m.keeper_context with by_keeper } }
          in
          err_reply
            ~fail:
              (on_kc (fun s ->
                   { s with provider_input = failed_slot err s.provider_input }))
            ~source:(Health.Source_keeper keeper) ~ko:"프로바이더 입력 조회"
            ~en:"Provider input fetch" err)
  | Msg.Reply_keeper_provider_input_part
      { keeper; turn_ref; index; result = Ok content } ->
      ( {
          m with
          keeper_context =
            Keeper_context_store.apply_provider_input_part ~observed_at:now
              ~keeper ~turn_ref ~index content m.keeper_context;
        }
      , [] )
  | Msg.Reply_keeper_provider_input_part
      { keeper; turn_ref; index; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          ( {
              m with
              keeper_context =
                Keeper_context_store.mark_provider_input_part_denied ~at:now
                  ~keeper ~turn_ref ~index ~reason:(Msg.http_error_detail err)
                  m.keeper_context;
            }
          , [] )
      | Msg.Http_error { status = 404; _ } -> (m, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:(fun m ->
              let st = Keeper_context_store.get_keeper ~keeper m.keeper_context in
              let by_keeper =
                Keeper_context_store.String_map.add keeper
                  { st with part_content = failed_slot err st.part_content }
                  m.keeper_context.by_keeper
              in
              { m with keeper_context = { m.keeper_context with by_keeper } })
            ~source:(Health.Source_keeper keeper) ~ko:"입력 파트 본문 조회"
            ~en:"Provider input part fetch" err)
  | Msg.Reply_keeper_cache_outcome { keeper; turn_ref; result = Ok reading } ->
      ( {
          m with
          keeper_context =
            Keeper_context_store.apply_cache_outcome ~observed_at:now ~keeper
              ~turn_ref reading m.keeper_context;
        }
      , [] )
  | Msg.Reply_keeper_cache_outcome { keeper; turn_ref; result = Error err }
    -> (
      match err with
      | Msg.Http_error { status = 404; _ } ->
          ( {
              m with
              keeper_context =
                Keeper_context_store.mark_cache_outcome_absent ~keeper ~turn_ref
                  m.keeper_context;
            }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:(fun m ->
              let st = Keeper_context_store.get_keeper ~keeper m.keeper_context in
              let by_keeper =
                Keeper_context_store.String_map.add keeper
                  { st with cache_outcome = failed_slot err st.cache_outcome }
                  m.keeper_context.by_keeper
              in
              { m with keeper_context = { m.keeper_context with by_keeper } })
            ~source:(Health.Source_keeper keeper) ~ko:"캐시 진단 조회"
            ~en:"Cache outcome fetch" err)
  | Msg.Reply_keeper_next_request { keeper; result = Ok forecast } ->
      ( {
          m with
          keeper_context =
            Keeper_context_store.apply_next_request ~observed_at:now ~keeper
              forecast m.keeper_context;
        }
      , [] )
  | Msg.Reply_keeper_next_request { keeper; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 404; _ } ->
          ( {
              m with
              keeper_context =
                Keeper_context_store.mark_next_request_absent ~keeper
                  m.keeper_context;
            }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:(fun m ->
              let st = Keeper_context_store.get_keeper ~keeper m.keeper_context in
              let by_keeper =
                Keeper_context_store.String_map.add keeper
                  { st with next_request = failed_slot err st.next_request }
                  m.keeper_context.by_keeper
              in
              { m with keeper_context = { m.keeper_context with by_keeper } })
            ~source:(Health.Source_keeper keeper) ~ko:"다음 요청 예측 조회"
            ~en:"Next request forecast fetch" err)
  | Msg.Reply_keeper_turn_transcript { keeper; turn_ref; result = Ok tr } ->
      ( {
          m with
          keeper_context =
            Keeper_context_store.apply_turn_transcript ~observed_at:now ~keeper
              ~turn_ref tr m.keeper_context;
        }
      , [] )
  | Msg.Reply_keeper_turn_transcript { keeper; turn_ref; result = Error err }
    -> (
      match err with
      | Msg.Http_error { status = 404; _ } ->
          ( {
              m with
              keeper_context =
                Keeper_context_store.mark_turn_transcript_absent ~keeper
                  ~turn_ref m.keeper_context;
            }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:(fun m ->
              let st = Keeper_context_store.get_keeper ~keeper m.keeper_context in
              let by_keeper =
                Keeper_context_store.String_map.add keeper
                  { st with turn_transcript = failed_slot err st.turn_transcript }
                  m.keeper_context.by_keeper
              in
              { m with keeper_context = { m.keeper_context with by_keeper } })
            ~source:(Health.Source_keeper keeper) ~ko:"턴 전사 조회"
            ~en:"Turn transcript fetch" err)
  | Msg.Reply_keeper_tool_stats { keeper; result = Ok stats } ->
      ( {
          m with
          keeper_context =
            Keeper_context_store.apply_tool_stats ~observed_at:now ~keeper stats
              m.keeper_context;
        }
      , [] )
  | Msg.Reply_keeper_tool_stats { keeper; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 404; _ } ->
          ( {
              m with
              keeper_context =
                Keeper_context_store.mark_tool_stats_absent ~keeper
                  m.keeper_context;
            }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:(fun m ->
              let st = Keeper_context_store.get_keeper ~keeper m.keeper_context in
              let by_keeper =
                Keeper_context_store.String_map.add keeper
                  { st with tool_stats = failed_slot err st.tool_stats }
                  m.keeper_context.by_keeper
              in
              { m with keeper_context = { m.keeper_context with by_keeper } })
            ~source:(Health.Source_keeper keeper) ~ko:"키퍼 도구 통계 조회"
            ~en:"Keeper tool stats fetch" err)
  | Msg.Reply_keeper_tool_calls { keeper; turn_ref; result = Ok page } ->
      let keeper_context =
        match turn_ref with
        | Some tr ->
            Keeper_context_store.apply_call_evidence ~observed_at:now ~keeper
              ~turn_ref:tr page.entries m.keeper_context
        | None ->
            Keeper_context_store.apply_tool_calls ~observed_at:now ~keeper page
              m.keeper_context
      in
      ({ m with keeper_context }, [])
  | Msg.Reply_keeper_tool_calls { keeper; turn_ref; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          let keeper_context =
            match turn_ref with
            | Some tr ->
                Keeper_context_store.mark_call_evidence_denied ~at:now ~keeper
                  ~turn_ref:tr ~reason:(Msg.http_error_detail err)
                  m.keeper_context
            | None ->
                Keeper_context_store.mark_tool_calls_denied ~at:now ~keeper
                  ~reason:(Msg.http_error_detail err) m.keeper_context
          in
          ({ m with keeper_context }, [])
      | Msg.Http_error { status = 404; _ } ->
          let keeper_context =
            match turn_ref with
            | Some tr ->
                Keeper_context_store.mark_call_evidence_absent ~keeper
                  ~turn_ref:tr m.keeper_context
            | None ->
                Keeper_context_store.mark_tool_calls_absent ~keeper
                  m.keeper_context
          in
          ({ m with keeper_context }, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:(fun m ->
              let st = Keeper_context_store.get_keeper ~keeper m.keeper_context in
              let st' =
                match turn_ref with
                | Some _ ->
                    { st with call_evidence = failed_slot err st.call_evidence }
                | None -> { st with tool_calls = failed_slot err st.tool_calls }
              in
              let by_keeper =
                Keeper_context_store.String_map.add keeper st'
                  m.keeper_context.by_keeper
              in
              { m with keeper_context = { m.keeper_context with by_keeper } })
            ~source:(Health.Source_keeper keeper) ~ko:"키퍼 도구 호출 조회"
            ~en:"Keeper tool calls fetch" err)
  | Msg.Reply_keeper_tool_result { keeper; execution_id; result = Ok res } ->
      ( {
          m with
          keeper_context =
            Keeper_context_store.apply_tool_result ~observed_at:now ~keeper
              ~execution_id res m.keeper_context;
        }
      , [] )
  | Msg.Reply_keeper_tool_result
      { keeper; execution_id; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          ( {
              m with
              keeper_context =
                Keeper_context_store.mark_tool_result_denied ~at:now ~keeper
                  ~execution_id ~reason:(Msg.http_error_detail err)
                  m.keeper_context;
            }
          , [] )
      | Msg.Http_error { status = 404; _ } -> (m, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:(fun m ->
              let st = Keeper_context_store.get_keeper ~keeper m.keeper_context in
              let by_keeper =
                Keeper_context_store.String_map.add keeper
                  { st with tool_result = failed_slot err st.tool_result }
                  m.keeper_context.by_keeper
              in
              { m with keeper_context = { m.keeper_context with by_keeper } })
            ~source:(Health.Source_keeper keeper) ~ko:"도구 실행 결과 조회"
            ~en:"Tool result fetch" err)
  | Msg.Reply_provider_usage (Ok uw) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_usage_windows ~observed_at:now uw m.runtime;
        }
      , [] )
  | Msg.Reply_provider_usage (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with usage_windows = failed_slot err x.usage_windows }))
        ~source:(Health.Source_runtime "usage") ~ko:"프로바이더 할당 조회"
        ~en:"Provider usage fetch" err
  | Msg.Reply_provider_usage_history (Ok hist) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_usage_history ~observed_at:now hist m.runtime;
        }
      , [] )
  | Msg.Reply_provider_usage_history (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with usage_history = failed_slot err x.usage_history }))
        ~source:(Health.Source_runtime "usage_history")
        ~ko:"프로바이더 사용 이력 조회" ~en:"Provider usage history fetch" err
  | Msg.Reply_keeper_costs (Ok costs) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_keeper_costs ~observed_at:now costs m.runtime;
        }
        |> Model.sync_effective_scorecard ~now
      , [] )
  | Msg.Reply_keeper_costs (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with keeper_costs = failed_slot err x.keeper_costs }))
        ~source:(Health.Source_runtime "costs") ~ko:"키퍼 비용 조회"
        ~en:"Keeper costs fetch" err
  | Msg.Reply_efficiency (Ok eff) ->
      ( {
          m with
          runtime = Runtime_store.apply_efficiency ~observed_at:now eff m.runtime;
        }
      , [] )
  | Msg.Reply_efficiency (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with efficiency = failed_slot err x.efficiency }))
        ~source:(Health.Source_runtime "efficiency") ~ko:"효율 지표 조회"
        ~en:"Efficiency fetch" err
  | Msg.Reply_models_metrics (Ok mm) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_models_metrics ~observed_at:now mm m.runtime;
        }
        |> Model.sync_effective_scorecard ~now
      , [] )
  | Msg.Reply_models_metrics (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with models_metrics = failed_slot err x.models_metrics }))
        ~source:(Health.Source_runtime "models_metrics")
        ~ko:"모델 메트릭 조회" ~en:"Model metrics fetch" err
  | Msg.Reply_runtime_metrics (Ok rm) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_runtime_metrics ~observed_at:now rm m.runtime;
        }
        |> Model.sync_effective_scorecard ~now
      , [] )
  | Msg.Reply_runtime_metrics (Error err) -> (
      match err with
      | Msg.Http_error { status = 401 | 403 | 404; _ } ->
          let runtime =
            {
              m.runtime with
              runtime_metrics =
                Observed.failed ~reason:(Msg.http_error_detail err)
                  ~retryable:false ~at:now;
            }
          in
          ({ m with runtime }, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:
              (on_runtime (fun (x : Runtime_store.t) ->
                   { x with runtime_metrics = failed_slot err x.runtime_metrics }))
            ~source:(Health.Source_runtime "runtime_metrics")
            ~ko:"런타임 메트릭 조회" ~en:"Runtime metrics fetch" err)
  | Msg.Reply_runtime_resolved (Ok resolved) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_runtime_resolved ~observed_at:now resolved
              m.runtime;
        }
      , [] )
  | Msg.Reply_runtime_resolved (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with runtime_resolved = failed_slot err x.runtime_resolved }))
        ~source:(Health.Source_runtime "resolved") ~ko:"페일오버 레인 조회"
        ~en:"Runtime lanes fetch" err
  | Msg.Reply_runtime_config_raw (Ok meta) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_runtime_config_raw ~observed_at:now meta
              m.runtime;
        }
      , [] )
  | Msg.Reply_runtime_config_raw (Error err) -> (
      match err with
      | Msg.Http_error { status = 401 | 403 | 404; _ } ->
          let runtime =
            {
              m.runtime with
              runtime_config_raw =
                Observed.failed ~reason:(Msg.http_error_detail err)
                  ~retryable:false ~at:now;
            }
          in
          ({ m with runtime }, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:
              (on_runtime (fun (x : Runtime_store.t) ->
                   { x with runtime_config_raw = failed_slot err x.runtime_config_raw }))
            ~source:(Health.Source_runtime "config_raw")
            ~ko:"런타임 설정 원본 조회" ~en:"Runtime raw config fetch" err)
  | Msg.Reply_setup_inventory (Ok inv) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_setup_inventory ~observed_at:now inv m.runtime;
        }
      , [] )
  | Msg.Reply_setup_inventory (Error err) -> (
      match err with
      | Msg.Http_error { status = 401 | 403 | 404; _ } ->
          let runtime =
            {
              m.runtime with
              setup_inventory =
                Observed.failed ~reason:(Msg.http_error_detail err)
                  ~retryable:false ~at:now;
            }
          in
          ({ m with runtime }, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:
              (on_runtime (fun (x : Runtime_store.t) ->
                   { x with setup_inventory = failed_slot err x.setup_inventory }))
            ~source:(Health.Source_runtime "setup_inventory")
            ~ko:"셋업 인벤토리 조회" ~en:"Setup inventory fetch" err)
  | Msg.Reply_setup_login_receipt (Ok receipt) ->
      let runtime =
        Runtime_store.apply_setup_login_receipt receipt m.runtime
      in
      let status_lc = String.lowercase_ascii receipt.status in
      let is_done =
        String.equal status_lc "complete" || String.equal status_lc "completed"
      in
      let level =
        if is_done then Model.Toast_success
        else if String.equal status_lc "failed" || String.equal status_lc "cancelled" then
          Model.Toast_error
        else Model.Toast_info
      in
      let detail =
        match receipt.account with
        | Some acc ->
            Printf.sprintf "%s [%s/%s] (%s)" receipt.integration_id
              receipt.status acc receipt.login_id
        | None ->
            Printf.sprintf "%s [%s] (%s)" receipt.integration_id receipt.status
              receipt.login_id
      in
      let next =
        { m with runtime }
        |> Model.with_toast ~now ~level
             (Say.make ~ko:("로그인 상태: " ^ detail) ~en:("Login: " ^ detail))
      in
      let refresh_cmds =
        if is_done then
          [
            Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_setup_inventory };
            Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_runtime_resolved };
          ]
        else []
      in
      (next, refresh_cmds)
  | Msg.Reply_setup_login_receipt (Error err) ->
      let next, cmds =
        record_http_incident ~now ~source:(Health.Source_runtime "setup_login")
          ~context:(Say.make ~ko:"계정 로그인" ~en:"Account login")
          err m
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_runtime_assignment { keeper_name; runtime_id; result = Ok () } ->
      let target_str = Option.value runtime_id ~default:"(default)" in
      let next =
        Model.with_toast ~now ~level:Model.Toast_success
          (Say.make
             ~ko:(Printf.sprintf "키퍼 런타임 배정 완료: %s -> %s" keeper_name target_str)
             ~en:(Printf.sprintf "Assigned runtime: %s -> %s" keeper_name target_str))
          m
      in
      ( next
      , [
          Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_runtime_resolved };
          Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_runtime_config_raw };
          Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_keepers_roster };
        ] )
  | Msg.Reply_runtime_assignment { keeper_name; result = Error err; _ } ->
      let next, cmds =
        record_http_incident ~now ~source:(Health.Source_runtime "assignment")
          ~context:
            (Say.make
               ~ko:("키퍼 런타임 배정: " ^ keeper_name)
               ~en:("Keeper runtime assignment: " ^ keeper_name))
          err m
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_runtime_routing { runtime_id; result = Ok () } ->
      let next =
        Model.with_toast ~now ~level:Model.Toast_success
          (Say.make
             ~ko:("기본 런타임 경로 변경 완료: " ^ runtime_id)
             ~en:("Default route updated: " ^ runtime_id))
          m
      in
      ( next
      , [
          Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_runtime_resolved };
          Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_runtime_config_raw };
        ] )
  | Msg.Reply_runtime_routing { runtime_id; result = Error err } ->
      let next, cmds =
        record_http_incident ~now ~source:(Health.Source_runtime "routing")
          ~context:
            (Say.make
               ~ko:("기본 런타임 변경: " ^ runtime_id)
               ~en:("Default route update: " ^ runtime_id))
          err m
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_setup_account_key { integration_id; result = Ok () } ->
      let next =
        Model.with_toast ~now ~level:Model.Toast_success
          (Say.make
             ~ko:("API 키 등록 완료: " ^ integration_id)
             ~en:("API key registered: " ^ integration_id))
          m
      in
      ( next
      , [
          Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_setup_inventory };
          Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_runtime_resolved };
          Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_runtime_config_raw };
        ] )
  | Msg.Reply_setup_account_key { integration_id; result = Error err } ->
      let next, cmds =
        record_http_incident ~now ~source:(Health.Source_runtime "setup_key")
          ~context:
            (Say.make
               ~ko:("API 키 등록: " ^ integration_id)
               ~en:("Register API key: " ^ integration_id))
          err m
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_runtime_probe (Ok probe) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_runtime_probe ~observed_at:now probe m.runtime;
        }
      , [] )
  | Msg.Reply_runtime_probe (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with runtime_probe = failed_slot err x.runtime_probe }))
        ~source:(Health.Source_runtime "probe") ~ko:"런타임 프로브 조회"
        ~en:"Runtime probe fetch" err
  | Msg.Reply_exact_lane_runs (Ok runs) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_exact_lane_runs ~observed_at:now runs m.runtime;
        }
      , [] )
  | Msg.Reply_exact_lane_runs (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with exact_lane_runs = failed_slot err x.exact_lane_runs }))
        ~source:(Health.Source_runtime "exact") ~ko:"교차 검증 레인 조회"
        ~en:"Exact lanes fetch" err
  | Msg.Reply_fusion_runs (Ok runs) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_fusion_runs ~observed_at:now runs m.runtime;
        }
      , [] )
  | Msg.Reply_fusion_runs (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with fusion_runs = failed_slot err x.fusion_runs }))
        ~source:(Health.Source_runtime "fusion") ~ko:"퓨전 실행 조회"
        ~en:"Fusion runs fetch" err
  | Msg.Reply_fusion_launch (Ok ()) ->
      let runtime = Runtime_store.clear_fusion_draft m.runtime in
      let next =
        { m with runtime }
        |> Model.with_toast ~now ~level:Model.Toast_success
             (Say.make ~ko:"퓨전 패널 실행 요청됨" ~en:"Fusion run launched")
      in
      (next, [ Cmd.Http_get { epoch = m.epoch; req = Cmd.Get_fusion_runs } ])
  | Msg.Reply_fusion_launch (Error err) ->
      let runtime = Runtime_store.set_fusion_submitting false m.runtime in
      let next, cmds =
        record_http_incident ~now ~source:(Health.Source_runtime "fusion")
          ~context:(Say.make ~ko:"퓨전 실행" ~en:"Fusion launch")
          err { m with runtime }
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_tool_series (Ok series) ->
      let next =
        {
          m with
          runtime =
            Runtime_store.apply_tool_series ~observed_at:now series m.runtime;
        }
        |> refresh_404_fallbacks ~now
      in
      (next, [])
  | Msg.Reply_tool_series (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with tool_series = failed_slot err x.tool_series }))
        ~source:(Health.Source_runtime "tools") ~ko:"도구 시계열 조회"
        ~en:"Tool series fetch" err
  | Msg.Reply_tool_series_summary { tool; since_hours; result = Ok summary } ->
      let _, expected_hours =
        Runtime_store.tools_window_params m.runtime.tools_window
      in
      let runtime =
        match tool with
        | Some t_name ->
            if Int.equal since_hours expected_hours then
              Runtime_store.apply_tool_detail_series ~observed_at:now
                ~tool:t_name summary m.runtime
            else m.runtime
        | None ->
            if Int.equal since_hours expected_hours then
              Runtime_store.apply_tool_series_summary ~observed_at:now summary
                m.runtime
            else m.runtime
      in
      let next = { m with runtime } |> refresh_404_fallbacks ~now in
      (next, [])
  | Msg.Reply_tool_series_summary { tool; since_hours = _; result = Error err } ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               match tool with
               | Some _ ->
                   { x with tool_detail_series = failed_slot err x.tool_detail_series }
               | None ->
                   { x with tool_series_summary = failed_slot err x.tool_series_summary }))
        ~source:(Health.Source_runtime "tools") ~ko:"도구 시계열 요약 조회"
        ~en:"Tool series summary fetch" err
  | Msg.Reply_tools_dashboard { keeper = req_keeper; result = Ok snap } ->
      let keeper_names =
        match Observed.to_option m.fleet.keepers with
        | Some ks ->
            List.map (fun (k : Wire_fleet.keeper_summary) -> k.name) ks
        | None -> []
      in
      let expected_keeper =
        Runtime_store.selected_tools_surface_keeper ~keeper_names m.runtime
      in
      let prev_surf =
        Option.bind
          (Observed.to_option m.runtime.tools_dashboard)
          (fun (d : Wire_runtime.tools_dashboard_snapshot) ->
            d.effective_keeper_surface)
      in
      let guarded_snap =
        match expected_keeper with
        | Some exp -> (
            match req_keeper with
            | Some rk when String.equal rk exp -> (
                match snap.effective_keeper_surface with
                | Some
                    ( Wire_runtime.Keeper_surface_available { keeper_name; _ }
                    | Wire_runtime.Keeper_surface_unavailable { keeper_name; _ }
                    ) ->
                    if String.equal keeper_name exp then snap
                    else { snap with effective_keeper_surface = prev_surf }
                | None -> snap)
            | Some _ | None ->
                { snap with effective_keeper_surface = prev_surf })
        | None -> snap
      in
      ( {
          m with
          runtime =
            Runtime_store.apply_tools_dashboard ~observed_at:now guarded_snap
              m.runtime;
        }
      , [] )
  | Msg.Reply_tools_dashboard { keeper = _; result = Error err } ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with tools_dashboard = failed_slot err x.tools_dashboard }))
        ~source:(Health.Source_runtime "tools") ~ko:"도구 대시보드 조회"
        ~en:"Tools dashboard fetch" err
  | Msg.Reply_tools_catalog (Ok (Wire_runtime.Tools_ready tools)) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_tools_catalog ~observed_at:now tools m.runtime;
        }
      , [] )
  | Msg.Reply_tools_catalog (Ok Wire_runtime.Tools_warming) ->
      ( {
          m with
          runtime = Runtime_store.apply_tools_warming ~observed_at:now m.runtime;
        }
      , [] )
  | Msg.Reply_tools_catalog (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with tools_catalog = failed_slot err x.tools_catalog }))
        ~source:(Health.Source_runtime "tools") ~ko:"도구 목록 조회"
        ~en:"Tools catalog fetch" err
  | Msg.Reply_skills (Ok snap) ->
      ( {
          m with
          runtime = Runtime_store.apply_skills ~observed_at:now snap m.runtime;
        }
      , [] )
  | Msg.Reply_skills (Error err) -> (
      match err with
      | Msg.Http_error { status = 401 | 403 | 404; _ } ->
          ( { m with runtime = { m.runtime with skills = Observed.absent } }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:
              (on_runtime (fun (x : Runtime_store.t) ->
                   { x with skills = failed_slot err x.skills }))
            ~source:(Health.Source_runtime "skills") ~ko:"스킬 스냅샷 조회"
            ~en:"Skills snapshot fetch" err)
  | Msg.Reply_connectors (Ok conns) ->
      let runtime =
        Runtime_store.apply_connectors ~observed_at:now conns m.runtime
      in
      let next = { m with runtime } in
      let name_cmds =
        if
          Option.is_none (Model.active_dive next)
          && Nav.equal_workspace next.nav.workspace Nav.Runtime
          && Nav.equal_runtime_tab next.runtime.active_tab
               Nav.Runtime_connectors
        then
          match Runtime_store.selected_connector next.runtime with
          | Some c
            when Runtime_store.connector_channel_names
                   ~connector_id:c.connector_id next.runtime
                 = [] ->
              [
                Cmd.Http_get
                  {
                    epoch = next.epoch;
                    req =
                      Cmd.Get_connector_names
                        { connector = c.connector_id; scope = "channel" };
                  };
              ]
          | Some _ | None -> []
        else []
      in
      (next, name_cmds)
  | Msg.Reply_connectors (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with connectors = failed_slot err x.connectors }))
        ~source:(Health.Source_runtime "connectors") ~ko:"커넥터 조회"
        ~en:"Connectors fetch" err
  | Msg.Reply_browser_lane (Ok bl) ->
      let runtime =
        Runtime_store.apply_browser_lane ~observed_at:now bl m.runtime
      in
      let next = { m with runtime } in
      let tab_cmds =
        if
          Option.is_none (Model.active_dive next)
          && Nav.equal_workspace next.nav.workspace Nav.Runtime
          && Nav.equal_runtime_tab next.runtime.active_tab
               Nav.Runtime_addons_browser
        then
          match Runtime_store.selected_browser_client next.runtime with
          | Some cl ->
              let already_settled =
                match
                  Runtime_store.browser_tabs_for ~client_id:cl.client_id
                    next.runtime
                with
                | Observed.Value { stale = false; _ }
                | Observed.Failed { retryable = false; _ } ->
                    true
                | Observed.Loading _
                | Observed.Value { stale = true; _ }
                | Observed.Absent
                | Observed.Unreported
                | Observed.Failed { retryable = true; _ } ->
                    false
              in
              if already_settled then []
              else
                [
                  Cmd.Http_post
                    {
                      epoch = next.epoch;
                      req = Cmd.Post_browser_tabs { client_id = cl.client_id };
                    };
                ]
          | None -> []
        else []
      in
      (next, tab_cmds)
  | Msg.Reply_browser_lane (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with browser_lane = failed_slot err x.browser_lane }))
        ~source:(Health.Source_runtime "browser") ~ko:"브라우저 레인 조회"
        ~en:"Browser lane fetch" err
  | Msg.Reply_browser_tabs { client_id; result = Ok resp } ->
      (* Guard against stale tab responses after the operator selected another client. *)
      let matches_selected =
        match Runtime_store.selected_browser_client m.runtime with
        | Some cl -> String.equal cl.client_id client_id
        | None -> false
      in
      if not matches_selected then (m, [])
      else
        ( {
            m with
            runtime =
              Runtime_store.apply_browser_tabs ~observed_at:now ~client_id resp
                m.runtime;
          }
        , [] )
  | Msg.Reply_browser_tabs { client_id; result = Error err } ->
      let matches_selected =
        match Runtime_store.selected_browser_client m.runtime with
        | Some cl -> String.equal cl.client_id client_id
        | None -> false
      in
      if not matches_selected then (m, [])
      else
        let retryable =
          match err with
          | Msg.Transport _ -> true
          | Msg.Http_error { status; _ } -> status >= 500 || status = 429
          | Msg.Workspace_mismatch _ | Msg.Decode_error _ -> false
        in
        let runtime =
          Runtime_store.mark_browser_tabs_failed ~at:now ~client_id
            ~reason:(Msg.http_error_detail err) ~retryable m.runtime
        in
        record_http_incident ~now ~source:(Health.Source_runtime "browser_tabs")
          ~context:(Say.make ~ko:"브라우저 탭 목록 조회" ~en:"Browser tabs fetch")
          err { m with runtime }
  | Msg.Reply_lane_addons (Ok snap) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_lane_addons ~observed_at:now snap m.runtime;
        }
      , [] )
  | Msg.Reply_lane_addons (Error err) -> (
      match err with
      | Msg.Http_error { status = 401 | 403 | 404; _ } ->
          let runtime =
            {
              m.runtime with
              lane_addons =
                Observed.failed ~reason:(Msg.http_error_detail err)
                  ~retryable:false ~at:now;
            }
          in
          ({ m with runtime }, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:
              (on_runtime (fun (x : Runtime_store.t) ->
                   { x with lane_addons = failed_slot err x.lane_addons }))
            ~source:(Health.Source_runtime "lane_addons")
            ~ko:"애드온 레인 조회" ~en:"Lane addons fetch" err)
  | Msg.Reply_mcp_clients (Ok clients) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_mcp_clients ~observed_at:now clients m.runtime;
        }
      , [] )
  | Msg.Reply_mcp_clients (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with mcp_clients = failed_slot err x.mcp_clients }))
        ~source:(Health.Source_runtime "clients") ~ko:"클라이언트 조회"
        ~en:"MCP clients fetch" err
  | Msg.Reply_sandboxes (Ok sb) ->
      ( {
          m with
          infra = Infra_store.apply_sandboxes ~observed_at:now sb m.infra;
        }
      , [] )
  | Msg.Reply_sandboxes (Error err) -> (
      match err with
      | Msg.Http_error { status = 404; _ } ->
          let keepers =
            match Observed.to_option m.fleet.keepers with
            | Some ks -> ks
            | None -> []
          in
          let infra =
            Infra_store.apply_sandboxes_fallback ~observed_at:now
              ~wall_unix:m.freshness.last_wall_unix ~keepers
              ~sandbox_profiles:
                (Fleet_store.String_map.bindings m.fleet.sandbox_profiles)
              ~tool_series_totals:(Runtime_store.tool_series_totals m.runtime)
              m.infra
          in
          ({ m with infra }, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:
              (on_infra (fun (x : Infra_store.t) ->
                   { x with sandboxes = failed_slot err x.sandboxes }))
            ~source:(Health.Source_sandbox "fleet") ~ko:"샌드박스 조회"
            ~en:"Sandboxes fetch" err)
  | Msg.Reply_keeper_sandbox { keeper; result = Ok ks } ->
      ( {
          m with
          infra =
            Infra_store.set_keeper_sandbox ~keeper
              (Observed.value ~observed_at:now ks)
              m.infra;
        }
      , [] )
  | Msg.Reply_keeper_sandbox { keeper; result = Error err } ->
      err_reply
        ~fail:
          (on_infra (fun (x : Infra_store.t) ->
               Infra_store.set_keeper_sandbox ~keeper
                 (failed_slot err (Infra_store.keeper_sandbox_for ~keeper x))
                 x))
        ~source:(Health.Source_sandbox keeper) ~ko:"키퍼 샌드박스 조회"
        ~en:"Keeper sandbox fetch" err
  | Msg.Reply_repositories (Ok repos) ->
      let infra =
        Infra_store.apply_repositories ~observed_at:now repos m.infra
      in
      let next = { m with infra } in
      let extra_cmds =
        if
          Nav.equal_workspace next.nav.workspace Nav.Infra
          && Nav.equal_infra_tab next.infra.active_tab Nav.Infra_repos_changes
        then View_fetches.fetches_for_current_view next
        else []
      in
      (next, extra_cmds)
  | Msg.Reply_repositories (Error err) ->
      err_reply
        ~fail:
          (on_infra (fun (x : Infra_store.t) ->
               { x with repositories = failed_slot err x.repositories }))
        ~source:Health.Source_client_http ~ko:"저장소 목록 조회"
        ~en:"Repositories fetch" err
  | Msg.Reply_repository_activity { repo_id; result = Ok activity } ->
      ( {
          m with
          infra =
            Infra_store.apply_repo_activity ~repo_id ~observed_at:now activity
              m.infra;
        }
      , [] )
  | Msg.Reply_repository_activity { repo_id; result = Error err } ->
      err_reply
        ~fail:
          (on_infra (Infra_store.fail_repo_activity ~repo_id (failed_slot err)))
        ~source:Health.Source_client_http ~ko:"파일 변경 조회"
        ~en:"File changes fetch" err
  | Msg.Reply_system_logs (Ok entries) ->
      ({ m with infra = Infra_store.apply_log_snapshot entries m.infra }, [])
  | Msg.Reply_system_logs (Error err) ->
      err_reply
        (* The log list has no observation state; the incident carries the failure. *)
        ~fail:Fun.id
        ~source:Health.Source_client_http ~ko:"시스템 로그 조회"
        ~en:"System logs fetch" err
  | Msg.Reply_tui_preferences (Ok prefs) ->
      let config = Config_store.apply_preferences ~observed_at:now prefs m.config in
      let lang =
        if m.cli_lang_override then m.lang
        else match prefs.language with Some l -> l | None -> m.lang
      in
      let theme_preset =
        if m.cli_theme_override then m.theme_preset
        else
          match prefs.theme with
          | Some name -> (
              match Theme.preset_of_name name with
              | Some p -> p
              | None -> m.theme_preset)
          | None -> m.theme_preset
      in
      let knowledge =
        match prefs.board_sort with
        | Some sort_by when not (String.equal (String.trim sort_by) "") ->
            Knowledge_store.set_board_sort sort_by m.knowledge
        | Some _ | None -> m.knowledge
      in
      ({ m with config; lang; theme_preset; knowledge }, [])
  | Msg.Reply_tui_preferences (Error err) ->
      err_reply
        ~fail:
          (on_config (fun (x : Config_store.t) ->
               { x with preferences = failed_slot err x.preferences }))
        ~source:Health.Source_client_http ~ko:"TUI 설정 조회"
        ~en:"TUI preferences fetch" err
  | Msg.Reply_config_schema_meta { target; meta } ->
      ( {
          m with
          config = Config_store.apply_schema_meta ~target meta m.config;
        }
      , [] )
  | Msg.Reply_config_schema (Ok schema) ->
      ( {
          m with
          config = Config_store.apply_schema ~observed_at:now schema m.config;
        }
      , [] )
  | Msg.Reply_config_schema (Error err) ->
      err_reply
        ~fail:
          (on_config (fun (x : Config_store.t) ->
               { x with schema = failed_slot err x.schema }))
        ~source:Health.Source_client_http ~ko:"설정 스키마 조회"
        ~en:"Config schema fetch" err
  | Msg.Reply_config_patch { dry_run; result = Ok resp } ->
      let config = Config_store.apply_patch_response ~dry_run resp m.config in
      let next = { m with config } in
      if dry_run then
        ( Model.with_toast ~now ~level:Model.Toast_info
            (Say.make ~ko:"TOML 변경 미리보기 준비됨"
               ~en:"TOML diff preview ready")
            next
        , [] )
      else
        let next =
          Model.with_toast ~now ~level:Model.Toast_success
            (Say.make ~ko:"설정이 원자적으로 저장되었습니다"
               ~en:"Configuration saved atomically")
            next
        in
        ( next
        , [
            Cmd.Http_get
              {
                epoch = m.epoch;
                req = Cmd.Get_config_schema next.config.target;
              };
          ] )
  | Msg.Reply_config_patch { dry_run; result = Error err } ->
      let config =
        Config_store.apply_patch_error ~dry_run (Msg.http_error_detail err)
          m.config
      in
      let next, cmds =
        record_http_incident ~now ~source:Health.Source_client_http
          ~context:
            (if dry_run then Say.make ~ko:"설정 미리보기" ~en:"Config dry-run"
            else Say.make ~ko:"설정 저장" ~en:"Config save")
          err { m with config }
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_action_ack { label; ack_scope; for_modal; result = Ok () } ->
      let closes_modal =
        match ack_scope with
        | Msg.Ack_close_modal | Msg.Ack_close_modal_and_refresh -> true
        | Msg.Ack_toast_only | Msg.Ack_refresh_view | Msg.Ack_editor_saved ->
            false
      in
      let should_refresh =
        match ack_scope with
        | Msg.Ack_refresh_view
        | Msg.Ack_close_modal_and_refresh
        | Msg.Ack_editor_saved ->
            true
        | Msg.Ack_toast_only | Msg.Ack_close_modal -> false
      in
      let ack_matches_modal (modal : Model.inline_modal_state) =
        closes_modal
        && modal.submitting
        &&
        match for_modal with
        | None -> false
        | Some (Nav.Harness_overrule ack_hash) -> (
            match modal.kind with
            | Nav.Harness_overrule modal_hash ->
                let raw =
                  String.trim (Model.modal_field_value ~key:"notes_hash" modal)
                in
                let effective =
                  if String.equal raw "" then String.trim modal_hash else raw
                in
                String.equal effective ack_hash
            | Nav.Btw_query
            | Nav.Gate_reject _
            | Nav.Verification_reject _
            | Nav.Task_cancel _
            | Nav.Schedule_form
            | Nav.Connector_form
            | Nav.Repo_add_form
            | Nav.Board_new_post
            | Nav.Board_comment _
            | Nav.Github_token_form _
            | Nav.Code_finder_form
            | Nav.Code_search_form ->
                false)
        | Some
            (( Nav.Btw_query
             | Nav.Gate_reject _
             | Nav.Verification_reject _
             | Nav.Task_cancel _
             | Nav.Schedule_form
             | Nav.Connector_form
             | Nav.Repo_add_form
             | Nav.Board_new_post
             | Nav.Board_comment _
             | Nav.Github_token_form _
             | Nav.Code_finder_form
             | Nav.Code_search_form ) as kind) ->
            Nav.equal_inline_action_kind modal.kind kind
      in
      let close_inline_modal =
        match m.inline_modal with
        | Some modal -> ack_matches_modal modal
        | None -> false
      in
      let nav, inline_modal =
        if not close_inline_modal then (m.nav, m.inline_modal)
        else
          let nav' =
            match m.nav.overlay with
            | Some (Nav.Inline_action _) ->
                { m.nav with overlay = m.nav.return_overlay; return_overlay = None }
            | Some
                ( Nav.Palette
                | Nav.Settings _
                | Nav.Incidents
                | Nav.Queue_context _
                | Nav.Ask_answer
                | Nav.Help
                | Nav.System_gate _ )
            | None ->
                m.nav
          in
          (nav', None)
      in
      let config =
        match ack_scope with
        | Msg.Ack_editor_saved -> Config_store.clear_dirty m.config
        | Msg.Ack_toast_only
        | Msg.Ack_close_modal
        | Msg.Ack_refresh_view
        | Msg.Ack_close_modal_and_refresh ->
            m.config
      in
      let next =
        Model.with_toast ~now ~level:Model.Toast_success label
          { m with nav; inline_modal; config }
      in
      let cmds =
        if should_refresh then
          View_fetches.fetches_for_current_view ~force:true next
        else []
      in
      (next, cmds)
  | Msg.Reply_action_ack { label; ack_scope; for_modal; result = Error err } ->
      let touches_modal =
        match ack_scope with
        | Msg.Ack_close_modal | Msg.Ack_close_modal_and_refresh -> true
        | Msg.Ack_toast_only | Msg.Ack_refresh_view | Msg.Ack_editor_saved ->
            false
      in
      let ack_matches_modal (modal : Model.inline_modal_state) =
        touches_modal
        && modal.submitting
        &&
        match for_modal with
        | None -> false
        | Some (Nav.Harness_overrule ack_hash) -> (
            match modal.kind with
            | Nav.Harness_overrule modal_hash ->
                let raw =
                  String.trim (Model.modal_field_value ~key:"notes_hash" modal)
                in
                let effective =
                  if String.equal raw "" then String.trim modal_hash else raw
                in
                String.equal effective ack_hash
            | Nav.Btw_query
            | Nav.Gate_reject _
            | Nav.Verification_reject _
            | Nav.Task_cancel _
            | Nav.Schedule_form
            | Nav.Connector_form
            | Nav.Repo_add_form
            | Nav.Board_new_post
            | Nav.Board_comment _
            | Nav.Github_token_form _
            | Nav.Code_finder_form
            | Nav.Code_search_form ->
                false)
        | Some
            (( Nav.Btw_query
             | Nav.Gate_reject _
             | Nav.Verification_reject _
             | Nav.Task_cancel _
             | Nav.Schedule_form
             | Nav.Connector_form
             | Nav.Repo_add_form
             | Nav.Board_new_post
             | Nav.Board_comment _
             | Nav.Github_token_form _
             | Nav.Code_finder_form
             | Nav.Code_search_form ) as kind) ->
            Nav.equal_inline_action_kind modal.kind kind
      in
      let inline_modal =
        if not touches_modal then m.inline_modal
        else
          Option.map
            (fun (modal : Model.inline_modal_state) ->
              if ack_matches_modal modal then
                {
                  modal with
                  submitting = false;
                  error = Some (Msg.http_error_detail err);
                }
              else modal)
            m.inline_modal
      in
      let next, cmds =
        record_http_incident ~now ~source:Health.Source_client_http
          ~context:label err { m with inline_modal }
      in
      let toast_msg =
        match err with
        | Msg.Transport (Health.Other_io _) -> label
        | Msg.Transport
            ( Health.Connect_refused
            | Health.Timeout
            | Health.Http_status _
            | Health.Stream_eof
            | Health.Protocol_error _ )
        | Msg.Workspace_mismatch _
        | Msg.Http_error _
        | Msg.Decode_error _ ->
            Msg.http_error_summary err
      in
      (Model.with_toast ~now ~level:Model.Toast_error toast_msg next, cmds)
  (* --- Wave 3 Replies --- *)
  | Msg.Reply_fusion_runs_snapshot (Ok snap) ->
      let runtime =
        Runtime_store.apply_fusion_runs_snapshot ~observed_at:now snap m.runtime
      in
      let next = { m with runtime } in
      let detail_cmds =
        if
          Option.is_none (Model.active_dive next)
          && Nav.equal_workspace next.nav.workspace Nav.Runtime
          && Nav.equal_runtime_tab next.runtime.active_tab Nav.Runtime_fusion
        then
          match Runtime_store.selected_fusion_run next.runtime with
          | Some run -> (
              if
                Runtime_store.is_retained_fusion_run ~run_id:run.run_id
                  next.runtime
              then
                if
                  Option.is_none
                    (Runtime_store.fusion_detail_for ~run_id:run.run_id
                       next.runtime)
                then
                  [
                    Cmd.Http_get
                      {
                        epoch = next.epoch;
                        req = Cmd.Get_fusion_run_detail { run_id = run.run_id };
                      };
                  ]
                else []
              else
                match
                  Runtime_store.historical_evidence_for_run ~run_id:run.run_id
                    next.runtime
                with
                | Some hist
                  when Option.is_none
                         (Runtime_store.fusion_board_evidence_for
                            ~post_id:hist.post_id next.runtime) ->
                    [
                      Cmd.Http_get
                        {
                          epoch = next.epoch;
                          req =
                            Cmd.Get_fusion_board_evidence
                              { post_id = hist.post_id };
                        };
                    ]
                | Some _ | None -> [])
          | None -> []
        else []
      in
      (next, detail_cmds)
  | Msg.Reply_fusion_runs_snapshot (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               { x with fusion_runs = failed_slot err x.fusion_runs }))
        ~source:Health.Source_client_http ~ko:"퓨전 실행 목록 조회"
        ~en:"Fusion runs fetch" err
  | Msg.Reply_fusion_run_detail { run_id; result = Ok detail } ->
      if not (fusion_detail_matches_active m run_id) then (m, [])
      else
        ( {
            m with
            runtime =
              Runtime_store.apply_fusion_detail ~observed_at:now ~run_id detail
                m.runtime;
          }
        , [] )
  | Msg.Reply_fusion_run_detail { run_id; result = Error err } -> (
      match err with
      | Msg.Workspace_mismatch _ ->
          err_reply ~fail:Fun.id ~source:Health.Source_client_http
            ~ko:"퓨전 상세 조회" ~en:"Fusion detail fetch" err
      | Msg.Http_error { status = 404; _ } -> (m, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Decode_error _ ->
          if not (fusion_detail_matches_active m run_id) then (m, [])
          else
            err_reply
              ~fail:
                (on_runtime (fun (x : Runtime_store.t) ->
                     { x with fusion_detail = failed_slot err x.fusion_detail }))
              ~source:Health.Source_client_http ~ko:"퓨전 상세 조회"
              ~en:"Fusion detail fetch" err)
  | Msg.Reply_fusion_config (Ok cfg) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_fusion_config ~observed_at:now cfg m.runtime;
        }
      , [] )
  | Msg.Reply_fusion_config (Error err) -> (
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          let runtime =
            Runtime_store.mark_fusion_config_denied ~at:now
              ~reason:(Msg.http_error_detail err) m.runtime
          in
          ({ m with runtime }, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:
              (on_runtime (fun (x : Runtime_store.t) ->
                   { x with fusion_config = failed_slot err x.fusion_config }))
            ~source:Health.Source_client_http ~ko:"퓨전 설정 조회"
            ~en:"Fusion config fetch" err)
  | Msg.Reply_fusion_board_evidence { post_id; result = Ok post } ->
      let runtime =
        Runtime_store.apply_fusion_board_evidence ~observed_at:now ~post_id post
          m.runtime
      in
      ( Model.with_toast ~now ~level:Model.Toast_info
          (Say.make
             ~ko:("보드 증거 로드됨: " ^ post_id)
             ~en:("Loaded board evidence: " ^ post_id))
          { m with runtime }
      , [] )
  | Msg.Reply_fusion_board_evidence { post_id = _; result = Error err } ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               {
                 x with
                 fusion_board_evidence =
                   failed_slot err x.fusion_board_evidence;
               }))
        ~source:Health.Source_client_http ~ko:"퓨전 보드 증거 조회"
        ~en:"Fusion board evidence fetch" err
  | Msg.Reply_harness_health (Ok hh) ->
      ( {
          m with
          work = Work_store.apply_harness_health ~observed_at:now hh m.work;
        }
      , [] )
  | Msg.Reply_harness_health (Error err) ->
      err_reply
        ~fail:
          (on_work (fun (x : Work_store.t) ->
               { x with harness_health = failed_slot err x.harness_health }))
        ~source:Health.Source_client_http ~ko:"하네스 상태 조회"
        ~en:"Harness health fetch" err
  | Msg.Reply_verification_evidence { verification_id; result = Ok bundle } ->
      if not (verification_evidence_matches_active m verification_id) then
        (m, [])
      else
        ( {
            m with
            work =
              Work_store.apply_verification_evidence ~observed_at:now
                ~verification_id bundle m.work;
          }
        , [] )
  | Msg.Reply_verification_evidence { verification_id; result = Error err } -> (
      match err with
      | Msg.Workspace_mismatch _ ->
          err_reply ~fail:Fun.id ~source:Health.Source_client_http
            ~ko:"검증 증거 조회" ~en:"Verification evidence fetch" err
      | Msg.Http_error { status = 401 | 403; _ } ->
          if not (verification_evidence_matches_active m verification_id) then
            (m, [])
          else
            let work =
              Work_store.mark_verification_evidence_denied ~at:now
                ~reason:(Msg.http_error_detail err) m.work
            in
            ({ m with work }, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Decode_error _ ->
          if not (verification_evidence_matches_active m verification_id) then
            (m, [])
          else
            err_reply
              ~fail:
                (on_work (fun (x : Work_store.t) ->
                     {
                       x with
                       verification_evidence =
                         failed_slot err x.verification_evidence;
                     }))
              ~source:Health.Source_client_http ~ko:"검증 증거 조회"
              ~en:"Verification evidence fetch" err)
  | Msg.Reply_verification_summary (Ok summary) ->
      ( {
          m with
          work =
            Work_store.apply_verification_summary ~observed_at:now summary m.work;
        }
      , [] )
  | Msg.Reply_verification_summary (Error err) ->
      err_reply
        ~fail:
          (on_work (fun (x : Work_store.t) ->
               {
                 x with
                 verification_summary = failed_slot err x.verification_summary;
               }))
        ~source:Health.Source_client_http ~ko:"검증 요약 조회"
        ~en:"Verification summary fetch" err
  | Msg.Reply_verification_specs (Ok specs) ->
      ( {
          m with
          work =
            Work_store.apply_verification_specs ~observed_at:now specs m.work;
        }
      , [] )
  | Msg.Reply_verification_specs (Error err) ->
      err_reply
        ~fail:
          (on_work (fun (x : Work_store.t) ->
               {
                 x with
                 verification_specs = failed_slot err x.verification_specs;
               }))
        ~source:Health.Source_client_http ~ko:"TLA+ 명세 조회"
        ~en:"Verification specs fetch" err
  | Msg.Reply_verification_tlc_results (Ok tlc) ->
      ( {
          m with
          work =
            Work_store.apply_verification_tlc_results ~observed_at:now tlc m.work;
        }
      , [] )
  | Msg.Reply_verification_tlc_results (Error err) ->
      err_reply
        ~fail:
          (on_work (fun (x : Work_store.t) ->
               {
                 x with
                 verification_tlc_results =
                   failed_slot err x.verification_tlc_results;
               }))
        ~source:Health.Source_client_http ~ko:"TLC 결과 조회"
        ~en:"TLC results fetch" err
  | Msg.Reply_activity_events (Ok (items, _next_seq)) ->
      ( {
          m with
          infra = Infra_store.apply_activity_events_backfill items m.infra;
        }
      , [] )
  | Msg.Reply_activity_events (Error err) ->
      err_reply ~fail:Fun.id ~source:Health.Source_client_http
        ~ko:"활동 이벤트 백필 조회" ~en:"Activity events backfill" err
  | Msg.Reply_keeper_runtime_trace { keeper; result = Ok snap } ->
      if not (runtime_trace_matches_active m keeper) then (m, [])
      else
        ( {
            m with
            infra =
              Infra_store.apply_runtime_trace ~observed_at:now ~keeper snap
                m.infra;
          }
        , [] )
  | Msg.Reply_keeper_runtime_trace { keeper; result = Error err } -> (
      match err with
      | Msg.Workspace_mismatch _ ->
          err_reply ~fail:Fun.id ~source:Health.Source_client_http
            ~ko:"런타임 트레이스 조회" ~en:"Runtime trace fetch" err
      | Msg.Http_error _ | Msg.Transport _ | Msg.Decode_error _ ->
          if not (runtime_trace_matches_active m keeper) then (m, [])
          else
            err_reply
              ~fail:
                (on_infra (fun (x : Infra_store.t) ->
                     { x with runtime_trace = failed_slot err x.runtime_trace }))
              ~source:Health.Source_client_http ~ko:"런타임 트레이스 조회"
              ~en:"Runtime trace fetch" err)
  | Msg.Reply_keeper_metrics { keeper; result = Ok snap } ->
      ( {
          m with
          keeper_context =
            Keeper_context_store.apply_metrics ~observed_at:now ~keeper snap
              m.keeper_context;
        }
      , [] )
  | Msg.Reply_keeper_metrics { keeper; result = Error err } ->
      let retryable =
        match err with
        | Msg.Http_error { status = 401 | 403 | 404; _ } -> false
        | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
        | Msg.Decode_error _ ->
            true
      in
      let m_failed =
        {
          m with
          keeper_context =
            Keeper_context_store.mark_metrics_failed ~at:now ~keeper
              ~reason:(Msg.http_error_detail err) ~retryable m.keeper_context;
        }
      in
      let next, cmds =
        record_http_incident ~now ~source:Health.Source_client_http
          ~context:(Say.make ~ko:"키퍼 지표 조회" ~en:"Keeper metrics fetch")
          err m_failed
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_keeper_sandbox_logs { keeper; result = Ok logs } ->
      ( {
          m with
          keeper_context =
            Keeper_context_store.apply_sandbox_logs ~observed_at:now ~keeper logs
              m.keeper_context;
        }
      , [] )
  | Msg.Reply_keeper_sandbox_logs { keeper; result = Error err } ->
      let retryable =
        match err with
        | Msg.Http_error { status = 401 | 403 | 404; _ } -> false
        | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
        | Msg.Decode_error _ ->
            true
      in
      let m_failed =
        {
          m with
          keeper_context =
            Keeper_context_store.mark_sandbox_logs_failed ~at:now ~keeper
              ~reason:(Msg.http_error_detail err) ~retryable m.keeper_context;
        }
      in
      let next, cmds =
        record_http_incident ~now ~source:Health.Source_client_http
          ~context:
            (Say.make ~ko:"키퍼 샌드박스 로그 조회"
               ~en:"Keeper sandbox logs fetch")
          err m_failed
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_workspace_children { scope; dir; result = Ok nodes } ->
      let infra =
        Infra_store.apply_workspace_children ~scope ~dir nodes m.infra
      in
      ({ m with infra }, [])
  | Msg.Reply_workspace_children { scope = _; dir = _; result = Error err } ->
      err_reply ~fail:Fun.id ~source:Health.Source_client_http
        ~ko:"워크스페이스 트리 조회" ~en:"Workspace tree fetch" err
  | Msg.Reply_workspace_files { scope; result = Ok catalog } ->
      ( {
          m with
          infra =
            Infra_store.apply_workspace_files ~observed_at:now ~scope catalog
              m.infra;
        }
      , [] )
  | Msg.Reply_workspace_files { scope = _; result = Error err } ->
      err_reply
        ~fail:
          (on_infra (fun (x : Infra_store.t) ->
               {
                 x with
                 code =
                   {
                     x.code with
                     files_catalog = failed_slot err x.code.files_catalog;
                   };
               }))
        ~source:Health.Source_client_http ~ko:"워크스페이스 파일 목록 조회"
        ~en:"Workspace files fetch" err
  | Msg.Reply_workspace_search { scope; result = Ok res } ->
      let infra =
        Infra_store.apply_workspace_search ~observed_at:now ~scope res m.infra
      in
      let focus_results =
        Option.is_none (Model.active_dive m)
        && Nav.equal_workspace m.nav.workspace Nav.Infra
        && Nav.equal_infra_tab m.infra.active_tab Nav.Infra_code
        && Wire_infra.equal_workspace_scope scope m.infra.code.scope
      in
      let nav =
        if focus_results then { m.nav with pane_index = 1 } else m.nav
      in
      ({ m with infra; nav }, [])
  | Msg.Reply_workspace_search { scope = _; result = Error err } ->
      err_reply
        ~fail:
          (on_infra (fun (x : Infra_store.t) ->
               {
                 x with
                 code =
                   {
                     x.code with
                     search_result = failed_slot err x.code.search_result;
                   };
               }))
        ~source:Health.Source_client_http ~ko:"코드 검색" ~en:"Code search" err
  | Msg.Reply_workspace_file { scope; path; result = Ok content } ->
      let infra =
        Infra_store.apply_workspace_file ~observed_at:now ~scope ~path content
          m.infra
      in
      ({ m with infra }, [])
  | Msg.Reply_workspace_file { scope = _; path = _; result = Error err } ->
      err_reply
        ~fail:
          (on_infra (fun (x : Infra_store.t) ->
               {
                 x with
                 code =
                   { x.code with open_file = failed_slot err x.code.open_file };
               }))
        ~source:Health.Source_client_http ~ko:"파일 내용 조회" ~en:"File read"
        err
  | Msg.Reply_git_branches { scope; result = Ok branches } ->
      ( {
          m with
          infra =
            Infra_store.apply_git_branches ~observed_at:now ~scope branches
              m.infra;
        }
      , [] )
  | Msg.Reply_git_branches { scope = _; result = Error err } ->
      err_reply
        ~fail:
          (on_infra (fun (x : Infra_store.t) ->
               {
                 x with
                 code =
                   {
                     x.code with
                     git_branches = failed_slot err x.code.git_branches;
                   };
               }))
        ~source:Health.Source_client_http ~ko:"Git 브랜치 조회"
        ~en:"Git branches fetch" err
  | Msg.Reply_git_worktrees { scope; result = Ok wts } ->
      ( {
          m with
          infra =
            Infra_store.apply_git_worktrees ~observed_at:now ~scope wts m.infra;
        }
      , [] )
  | Msg.Reply_git_worktrees { scope = _; result = Error err } ->
      err_reply
        ~fail:
          (on_infra (fun (x : Infra_store.t) ->
               {
                 x with
                 code =
                   {
                     x.code with
                     git_worktrees = failed_slot err x.code.git_worktrees;
                   };
               }))
        ~source:Health.Source_client_http ~ko:"Git 워크트리 조회"
        ~en:"Git worktrees fetch" err
  | Msg.Reply_git_status { scope; result = Ok snap } ->
      ( {
          m with
          infra =
            Infra_store.apply_git_status ~observed_at:now ~scope snap m.infra;
        }
      , [] )
  | Msg.Reply_git_status { scope = _; result = Error err } ->
      err_reply
        ~fail:
          (on_infra (fun (x : Infra_store.t) ->
               {
                 x with
                 code =
                   {
                     x.code with
                     git_status = failed_slot err x.code.git_status;
                   };
               }))
        ~source:Health.Source_client_http ~ko:"Git 상태 조회"
        ~en:"Git status fetch" err
  | Msg.Reply_git_blame { scope; path; result = Ok entries } ->
      ( {
          m with
          infra =
            Infra_store.apply_git_blame ~observed_at:now ~scope ~path entries
              m.infra;
        }
      , [] )
  | Msg.Reply_git_blame { scope = _; path = _; result = Error err } ->
      err_reply
        ~fail:
          (on_infra (fun (x : Infra_store.t) ->
               {
                 x with
                 code =
                   { x.code with git_blame = failed_slot err x.code.git_blame };
               }))
        ~source:Health.Source_client_http ~ko:"Git blame 조회"
        ~en:"Git blame fetch" err
  | Msg.Reply_git_log { scope; path; result = Ok commits } ->
      ( {
          m with
          infra =
            Infra_store.apply_git_log ~observed_at:now ~scope ~path commits
              m.infra;
        }
      , [] )
  | Msg.Reply_git_log { scope = _; path = _; result = Error err } ->
      err_reply
        ~fail:
          (on_infra (fun (x : Infra_store.t) ->
               {
                 x with
                 code = { x.code with git_log = failed_slot err x.code.git_log };
               }))
        ~source:Health.Source_client_http ~ko:"Git 로그 조회"
        ~en:"Git log fetch" err
  | Msg.Reply_git_diff { scope; path; result = Ok diff } ->
      ( {
          m with
          infra =
            Infra_store.apply_git_diff ~observed_at:now ~scope ~path diff m.infra;
        }
      , [] )
  | Msg.Reply_git_diff { scope = _; path = _; result = Error err } ->
      err_reply
        ~fail:
          (on_infra (fun (x : Infra_store.t) ->
               {
                 x with
                 code =
                   { x.code with git_diff = failed_slot err x.code.git_diff };
               }))
        ~source:Health.Source_client_http ~ko:"Git diff 조회"
        ~en:"Git diff fetch" err
  | Msg.Reply_memory_health_keeper { keeper; result = Ok row } ->
      let matches_keeper =
        match Model.active_dive m with
        | Some (Nav.Dive_keeper { name; _ }) -> String.equal name keeper
        | Some
            ( Nav.Dive_work _
            | Nav.Dive_knowledge _
            | Nav.Dive_runtime _
            | Nav.Dive_infra _ ) ->
            false
        | None -> (
            match Fleet_store.selected_keeper_summary m.fleet with
            | Some k -> String.equal k.name keeper
            | None -> true)
      in
      if not matches_keeper then (m, [])
      else
        ( {
            m with
            knowledge =
              Knowledge_store.apply_memory_health_keeper ~observed_at:now ~keeper
                row m.knowledge;
          }
        , [] )
  | Msg.Reply_memory_health_keeper { keeper; result = Error err } ->
      let active_keeper =
        match Model.active_dive m with
        | Some (Nav.Dive_keeper { name; _ }) -> Some name
        | Some
            ( Nav.Dive_work _
            | Nav.Dive_knowledge _
            | Nav.Dive_runtime _
            | Nav.Dive_infra _ ) ->
            None
        | None -> (
            match Fleet_store.selected_keeper_summary m.fleet with
            | Some k -> Some k.name
            | None -> m.knowledge.memory_diff_keeper)
      in
      let matches_keeper =
        match Model.active_dive m with
        | Some (Nav.Dive_keeper { name; _ }) -> String.equal name keeper
        | Some
            ( Nav.Dive_work _
            | Nav.Dive_knowledge _
            | Nav.Dive_runtime _
            | Nav.Dive_infra _ ) ->
            false
        | None -> (
            match Fleet_store.selected_keeper_summary m.fleet with
            | Some k -> String.equal k.name keeper
            | None -> true)
      in
      let retryable =
        match err with
        | Msg.Http_error { status = 400 | 401 | 403 | 404; _ } -> false
        | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
        | Msg.Decode_error _ ->
            true
      in
      let m_failed =
        if matches_keeper then
          {
            m with
            knowledge =
              Knowledge_store.mark_memory_health_keeper_failed ~at:now
                ?active_keeper ~keeper ~reason:(Msg.http_error_detail err)
                ~retryable m.knowledge;
          }
        else m
      in
      let next, cmds =
        record_http_incident ~now ~source:Health.Source_client_http
          ~context:
            (Say.make ~ko:"키퍼 기억 상태 조회"
               ~en:"Keeper memory health fetch")
          err m_failed
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_workspace_memory_ledger (Ok ledger) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_workspace_memory_ledger ~observed_at:now ledger
              m.knowledge;
        }
      , [] )
  | Msg.Reply_workspace_memory_ledger (Error err) -> (
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          ( {
              m with
              knowledge =
                Knowledge_store.mark_workspace_memory_ledger_failed ~at:now
                  ~reason:(Msg.http_error_detail err) ~retryable:false
                  ~auth_denied:true m.knowledge;
            }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          let m_failed =
            {
              m with
              knowledge =
                Knowledge_store.mark_workspace_memory_ledger_failed ~at:now
                  ~reason:(Msg.http_error_detail err) ~retryable:true
                  ~auth_denied:false m.knowledge;
            }
          in
          let next, cmds =
            record_http_incident ~now ~source:Health.Source_client_http
              ~context:
                (Say.make ~ko:"워크스페이스 기억 원장 조회"
                   ~en:"Workspace memory ledger fetch")
              err m_failed
          in
          ( Model.with_toast ~now ~level:Model.Toast_error
              (Msg.http_error_summary err) next
          , cmds ))
  | Msg.Reply_workspace_memory_context (Ok ctx) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_workspace_memory_context ~observed_at:now ctx
              m.knowledge;
        }
      , [] )
  | Msg.Reply_workspace_memory_context (Error err) -> (
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          ( {
              m with
              knowledge =
                Knowledge_store.mark_workspace_memory_context_failed ~at:now
                  ~reason:(Msg.http_error_detail err) ~retryable:false
                  ~auth_denied:true m.knowledge;
            }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          let m_failed =
            {
              m with
              knowledge =
                Knowledge_store.mark_workspace_memory_context_failed ~at:now
                  ~reason:(Msg.http_error_detail err) ~retryable:true
                  ~auth_denied:false m.knowledge;
            }
          in
          let next, cmds =
            record_http_incident ~now ~source:Health.Source_client_http
              ~context:
                (Say.make ~ko:"워크스페이스 기억 컨텍스트 조회"
                   ~en:"Workspace memory context fetch")
              err m_failed
          in
          ( Model.with_toast ~now ~level:Model.Toast_error
              (Msg.http_error_summary err) next
          , cmds ))
  | Msg.Reply_keeper_memory_journal { keeper; result = Ok journal } ->
      let matches_keeper =
        match Model.active_dive m with
        | Some (Nav.Dive_keeper { name; _ }) -> String.equal name keeper
        | Some
            ( Nav.Dive_work _
            | Nav.Dive_knowledge _
            | Nav.Dive_runtime _
            | Nav.Dive_infra _ ) ->
            false
        | None -> (
            match Fleet_store.selected_keeper_summary m.fleet with
            | Some k -> String.equal k.name keeper
            | None -> true)
      in
      if not matches_keeper then (m, [])
      else
        ( {
            m with
            knowledge =
              Knowledge_store.apply_keeper_memory_journal ~observed_at:now
                ~keeper journal m.knowledge;
          }
        , [] )
  | Msg.Reply_keeper_memory_journal { keeper; result = Error err } -> (
      let active_keeper =
        match Model.active_dive m with
        | Some (Nav.Dive_keeper { name; _ }) -> Some name
        | Some
            ( Nav.Dive_work _
            | Nav.Dive_knowledge _
            | Nav.Dive_runtime _
            | Nav.Dive_infra _ ) ->
            None
        | None -> (
            match Fleet_store.selected_keeper_summary m.fleet with
            | Some k -> Some k.name
            | None -> m.knowledge.memory_diff_keeper)
      in
      let matches_keeper =
        match Model.active_dive m with
        | Some (Nav.Dive_keeper { name; _ }) -> String.equal name keeper
        | Some
            ( Nav.Dive_work _
            | Nav.Dive_knowledge _
            | Nav.Dive_runtime _
            | Nav.Dive_infra _ ) ->
            false
        | None -> (
            match Fleet_store.selected_keeper_summary m.fleet with
            | Some k -> String.equal k.name keeper
            | None -> true)
      in
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          let knowledge =
            if matches_keeper then
              Knowledge_store.mark_keeper_memory_journal_failed ~at:now
                ?active_keeper ~keeper ~reason:(Msg.http_error_detail err)
                ~retryable:false ~auth_denied:true m.knowledge
            else
              {
                m.knowledge with
                keeper_memory_journal_auth_denied =
                  Knowledge_store.String_set.add keeper
                    m.knowledge.keeper_memory_journal_auth_denied;
              }
          in
          ({ m with knowledge }, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          let m_failed =
            if matches_keeper then
              {
                m with
                knowledge =
                  Knowledge_store.mark_keeper_memory_journal_failed ~at:now
                    ?active_keeper ~keeper ~reason:(Msg.http_error_detail err)
                    ~retryable:true ~auth_denied:false m.knowledge;
              }
            else m
          in
          let next, cmds =
            record_http_incident ~now ~source:Health.Source_client_http
              ~context:
                (Say.make ~ko:"키퍼 기억 저널 조회"
                   ~en:"Keeper memory journal fetch")
              err m_failed
          in
          ( Model.with_toast ~now ~level:Model.Toast_error
              (Msg.http_error_summary err) next
          , cmds ))
  | Msg.Reply_oauth_providers (Ok providers) ->
      ( {
          m with
          keeper_context =
            Keeper_context_store.apply_oauth_providers ~observed_at:now providers
              m.keeper_context;
        }
      , [] )
  | Msg.Reply_oauth_providers (Error err) ->
      err_reply
        ~fail:(fun (m : Model.t) ->
          {
            m with
            keeper_context =
              {
                m.keeper_context with
                oauth_providers =
                  failed_slot err m.keeper_context.oauth_providers;
              };
          })
        ~source:Health.Source_client_http ~ko:"OAuth 공급자 조회"
        ~en:"OAuth providers fetch" err
  | Msg.Reply_oauth_attached_tools { keeper; result = Ok snap } ->
      ( {
          m with
          keeper_context =
            Keeper_context_store.apply_oauth_attached_tools ~observed_at:now
              ~keeper snap m.keeper_context;
        }
      , [] )
  | Msg.Reply_oauth_attached_tools { keeper; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          ( {
              m with
              keeper_context =
                Keeper_context_store.mark_oauth_denied ~at:now ~keeper
                  ~reason:(Msg.http_error_detail err) m.keeper_context;
            }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:(fun (m : Model.t) ->
              let st = Keeper_context_store.get_keeper ~keeper m.keeper_context in
              let by_keeper =
                Keeper_context_store.String_map.add keeper
                  { st with oauth_attached = failed_slot err st.oauth_attached }
                  m.keeper_context.by_keeper
              in
              { m with keeper_context = { m.keeper_context with by_keeper } })
            ~source:Health.Source_client_http ~ko:"OAuth 도구 조회"
            ~en:"OAuth attached tools fetch" err)
  | Msg.Reply_oauth_attempt_status { keeper; result = Ok status } ->
      let keeper_context =
        Keeper_context_store.set_oauth_attempt_status ~keeper (Some status)
          m.keeper_context
      in
      let m1 = { m with keeper_context } in
      let next =
        Model.with_toast ~now ~level:Model.Toast_info
          (Say.make
             ~ko:("OAuth 상태: " ^ status.kind)
             ~en:("OAuth status: " ^ status.kind))
          m1
      in
      let refresh_cmds =
        if String.equal status.kind "completed" then
          [
            Cmd.Http_get
              { epoch = m.epoch; req = Cmd.Get_oauth_attached_tools { keeper } };
          ]
        else []
      in
      (next, refresh_cmds)
  | Msg.Reply_oauth_attempt_status { keeper; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          let keeper_context =
            Keeper_context_store.mark_oauth_denied ~at:now ~keeper
              ~reason:(Msg.http_error_detail err) m.keeper_context
          in
          ( Model.with_toast ~now ~level:Model.Toast_warning
              (Say.make ~ko:"OAuth 상태 확인 권한(CanAdmin) 필요"
                 ~en:"OAuth status requires CanAdmin auth")
              { m with keeper_context }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply ~fail:Fun.id ~source:Health.Source_client_http
            ~ko:"OAuth 로그인 상태 확인" ~en:"OAuth attempt status" err)
  | Msg.Reply_oauth_mutation { keeper; label; result = Ok () } ->
      ( Model.with_toast ~now ~level:Model.Toast_success label m
      , [
          Cmd.Http_get
            { epoch = m.epoch; req = Cmd.Get_oauth_attached_tools { keeper } };
        ] )
  | Msg.Reply_oauth_mutation { keeper; label; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          let keeper_context =
            Keeper_context_store.mark_oauth_denied ~at:now ~keeper
              ~reason:(Msg.http_error_detail err) m.keeper_context
          in
          ( Model.with_toast ~now ~level:Model.Toast_warning
              (Say.make ~ko:"OAuth 변경 권한(CanAdmin) 필요"
                 ~en:"OAuth update requires CanAdmin auth")
              { m with keeper_context }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          let next, cmds =
            record_http_incident ~now ~source:Health.Source_client_http
              ~context:label err m
          in
          ( Model.with_toast ~now ~level:Model.Toast_error
              (Msg.http_error_summary err) next
          , cmds ))
  | Msg.Reply_oauth_login { keeper; result = Ok res } ->
      let keeper_context =
        Keeper_context_store.set_oauth_pending_login ~keeper (Some res)
          m.keeper_context
      in
      let m1 = { m with keeper_context } in
      let toast, extra =
        match res with
        | Wire_keeper_context.Oauth_login_exchange { provider_label; _ } ->
            ( Say.make
                ~ko:(provider_label ^ " 인증 URL 준비됨 ([y] 복사 · [L] 상태 확인)")
                ~en:(provider_label ^ " auth URL ready ([y] copy · [L] poll)")
            , [] )
        | Wire_keeper_context.Oauth_login_direct { provider_label; message; _ } ->
            ( Say.make
                ~ko:(provider_label ^ ": " ^ message)
                ~en:(provider_label ^ ": " ^ message)
            , [
                Cmd.Http_get
                  {
                    epoch = m.epoch;
                    req = Cmd.Get_oauth_attached_tools { keeper };
                  };
              ] )
      in
      (Model.with_toast ~now ~level:Model.Toast_success toast m1, extra)
  | Msg.Reply_oauth_login { keeper; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          let keeper_context =
            Keeper_context_store.mark_oauth_denied ~at:now ~keeper
              ~reason:(Msg.http_error_detail err) m.keeper_context
          in
          ( Model.with_toast ~now ~level:Model.Toast_warning
              (Say.make ~ko:"OAuth 로그인 권한(CanAdmin) 필요"
                 ~en:"OAuth login requires CanAdmin auth")
              { m with keeper_context }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply ~fail:Fun.id ~source:Health.Source_client_http
            ~ko:"OAuth 로그인 시작" ~en:"OAuth login start" err)
  | Msg.Reply_board_quarantines { keeper; generation; result } ->
      let inventory = match result with
        | Ok rows -> Observed.value ~observed_at:now rows
        | Error err -> Observed.failed ~reason:(Msg.http_error_detail err)
                         ~retryable:(Msg.http_error_retryable err) ~at:now in
      let board_recovery = Board_recovery.observe ~keeper ~generation inventory m.knowledge.board_recovery in
      let next = { m with knowledge = { m.knowledge with board_recovery } } in
      (match result with
       | Ok _ -> (next, [])
       | Error err -> record_http_incident ~now ~source:(Health.Source_keeper keeper)
           ~context:(Say.make ~ko:"Board 격리 목록 조회" ~en:"Read Board quarantines") err next)
  | Msg.Reply_board_recovery { item; result } ->
      let keeper = item.keeper_name in
      let outcome = match result with
        | Ok receipt -> Board_recovery.Accepted receipt
        | Error (Msg.Http_error { status = (400 | 401 | 403); _ } as err) ->
            Board_recovery.Rejected (Msg.http_error_detail err)
        | Error ((Msg.Http_error _ | Msg.Transport _ | Msg.Decode_error _ | Msg.Workspace_mismatch _) as err) ->
            Board_recovery.Unconfirmed (Msg.http_error_detail err) in
      let board_recovery = Board_recovery.finish item outcome m.knowledge.board_recovery in
      let next = { m with knowledge = { m.knowledge with board_recovery } } in
      (match result with
       | Error (Msg.Workspace_mismatch _ as err) ->
           record_http_incident ~now ~source:(Health.Source_keeper keeper)
             ~context:(Say.make ~ko:"Board 복구" ~en:"Board recovery") err next
       | Ok _ | Error (Msg.Http_error _ | Msg.Transport _ | Msg.Decode_error _) ->
           View_fetches.read_board_quarantines ~keeper ~now next)
  | Msg.Reply_github_identity { keeper; result = Ok obs } ->
      let keeper_context =
        Keeper_context_store.apply_github_identity ~observed_at:now ~keeper obs
          m.keeper_context
      in
      ({ m with keeper_context }, [])
  | Msg.Reply_github_identity { keeper; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          let keeper_context =
            Keeper_context_store.mark_github_denied ~at:now ~keeper
              ~reason:(Msg.http_error_detail err) m.keeper_context
          in
          ({ m with keeper_context }, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply
            ~fail:(fun (m : Model.t) ->
              let st = Keeper_context_store.get_keeper ~keeper m.keeper_context in
              let by_keeper =
                Keeper_context_store.String_map.add keeper
                  { st with github_identity = failed_slot err st.github_identity }
                  m.keeper_context.by_keeper
              in
              { m with keeper_context = { m.keeper_context with by_keeper } })
            ~source:Health.Source_client_http ~ko:"GitHub 아이덴티티 조회"
            ~en:"GitHub identity fetch" err)
  | Msg.Reply_github_token_save { keeper; result = Ok obs } ->
      let keeper_context =
        Keeper_context_store.apply_github_identity ~observed_at:now ~keeper obs
          m.keeper_context
      in
      ( Model.with_toast ~now ~level:Model.Toast_success
          (Say.make ~ko:"GitHub 토큰이 저장되었습니다" ~en:"GitHub token saved")
          { m with keeper_context }
      , [] )
  | Msg.Reply_github_token_save { keeper; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 401 | 403; _ } ->
          let keeper_context =
            Keeper_context_store.mark_github_denied ~at:now ~keeper
              ~reason:(Msg.http_error_detail err) m.keeper_context
          in
          ( Model.with_toast ~now ~level:Model.Toast_warning
              (Say.make ~ko:"GitHub 토큰 저장 권한(CanAdmin) 필요"
                 ~en:"GitHub token save requires CanAdmin auth")
              { m with keeper_context }
          , [] )
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply ~fail:Fun.id ~source:Health.Source_client_http
            ~ko:"GitHub 토큰 저장" ~en:"GitHub token save" err)
  | Msg.Reply_addon_package_catalog (Ok cat) ->
      let runtime =
        Runtime_store.apply_addon_package_catalog ~observed_at:now cat m.runtime
      in
      let next = { m with runtime } in
      let preview_cmds =
        match Runtime_store.selected_addon_catalog_entry next.runtime with
        | Some (Wire_runtime.Catalog_package { manifest_path; _ }) ->
            [
              Cmd.Http_get
                {
                  epoch = next.epoch;
                  req = Cmd.Get_addon_package_preview { manifest_path };
                };
            ]
        | Some (Wire_runtime.Catalog_folder _ | Wire_runtime.Catalog_issue _)
        | None ->
            []
      in
      (next, preview_cmds)
  | Msg.Reply_addon_package_catalog (Error err) ->
      err_reply
        ~fail:
          (on_runtime (fun (x : Runtime_store.t) ->
               {
                 x with
                 addon_package_catalog =
                   failed_slot err x.addon_package_catalog;
               }))
        ~source:Health.Source_client_http ~ko:"애드온 패키지 카탈로그 조회"
        ~en:"Addon package catalog fetch" err
  | Msg.Reply_addon_package_preview { manifest_path; result = Ok prev } ->
      if not (addon_preview_matches_active m manifest_path) then (m, [])
      else
        ( {
            m with
            runtime =
              Runtime_store.apply_addon_package_preview ~observed_at:now
                ~manifest_path prev m.runtime;
          }
        , [] )
  | Msg.Reply_addon_package_preview { manifest_path; result = Error err } -> (
      match err with
      | Msg.Workspace_mismatch _ ->
          err_reply ~fail:Fun.id ~source:Health.Source_client_http
            ~ko:"애드온 패키지 미리보기 조회" ~en:"Addon package preview fetch"
            err
      | Msg.Http_error _ | Msg.Transport _ | Msg.Decode_error _ ->
          if not (addon_preview_matches_active m manifest_path) then (m, [])
          else
            err_reply
              ~fail:
                (on_runtime (fun (x : Runtime_store.t) ->
                     {
                       x with
                       addon_package_preview =
                         failed_slot err x.addon_package_preview;
                     }))
              ~source:Health.Source_client_http ~ko:"애드온 패키지 미리보기 조회"
              ~en:"Addon package preview fetch" err)
  | Msg.Reply_connector_names { connector; result = Ok page } ->
      let runtime =
        Runtime_store.apply_connector_names ~connector_id:connector
          page.mappings m.runtime
      in
      ({ m with runtime }, [])
  | Msg.Reply_connector_names { connector = _; result = Error err } -> (
      match err with
      | Msg.Http_error { status = 401 | 403 | 404 | 400; _ } -> (m, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply ~fail:Fun.id ~source:Health.Source_client_http
            ~ko:"커넥터 채널 이름 조회" ~en:"Connector names fetch" err)
