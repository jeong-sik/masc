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
  match m.server_identity.mismatch_state with
  | Model.Mismatch_recovering | Model.Mismatch_halted ->
      (* Anti-loop guard: transition to Mismatch_halted so Subscriptions stay
         blocked ([]) and stop issuing automatic re-handshakes until operator
         triggers Refresh (r). *)
      let server_identity =
        { m.server_identity with mismatch_state = Model.Mismatch_halted }
      in
      let next =
        { m with epoch = next_epoch; incidents; freshness; server_identity }
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
        { m with epoch = next_epoch; incidents; freshness; server_identity }
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

let max_confirm_rechecks = 3

let take_matching_user_msg (tx : Drafts.pending_message)
    (pool : Wire_fleet.chat_message list) =
  let tx_op_id = Option.value tx.operation_id ~default:tx.request_id in
  let is_prior (msg : Wire_fleet.chat_message) =
    List.exists (String.equal msg.id) tx.prior_user_msg_ids
  in
  let matches_exact_provenance (msg : Wire_fleet.chat_message) =
    String.equal msg.content tx.body
    && ((match msg.operation_id with
        | Some op -> String.equal op tx_op_id
        | None -> false)
       || String.equal msg.id tx.request_id)
  in
  let matches_legacy_unseen_body (msg : Wire_fleet.chat_message) =
    Option.is_none msg.operation_id
    && (not (is_prior msg))
    && String.equal msg.content tx.body
  in
  let rec extract pred acc = function
    | [] -> None
    | msg :: rest ->
        if pred msg then Some (msg, List.rev_append acc rest)
        else extract pred (msg :: acc) rest
  in
  match extract matches_exact_provenance [] pool with
  | Some (matched, remaining) -> (Some matched, remaining)
  | None -> (
      match extract matches_legacy_unseen_body [] pool with
      | Some (matched, remaining) -> (Some matched, remaining)
      | None -> (None, pool))

let confirm_pending_txs_from_history ~now ~keeper
    (page : Wire_fleet.chat_history_page) drafts =
  let persisted_user_rows =
    List.filter
      (fun (msg : Wire_fleet.chat_message) ->
        match msg.role with
        | Wire_fleet.Role_user | Wire_fleet.Role_peer _ -> true
        | Wire_fleet.Role_assistant
        | Wire_fleet.Role_system
        | Wire_fleet.Role_tool
        | Wire_fleet.Role_request_failure ->
            false)
      page.messages
  in
  let persisted_failure_ops =
    List.fold_left
      (fun acc (msg : Wire_fleet.chat_message) ->
        match msg.role, msg.operation_id with
        | Wire_fleet.Role_request_failure, Some op ->
            Fleet_store.String_set.add op acc
        | ( ( Wire_fleet.Role_user
            | Wire_fleet.Role_peer _
            | Wire_fleet.Role_assistant
            | Wire_fleet.Role_system
            | Wire_fleet.Role_tool
            | Wire_fleet.Role_request_failure )
          , (Some _ | None) ) ->
            acc)
      Fleet_store.String_set.empty page.messages
  in
  let persisted_assistant_ops =
    List.fold_left
      (fun acc (msg : Wire_fleet.chat_message) ->
        match msg.role, msg.operation_id with
        | Wire_fleet.Role_assistant, Some op -> (
            match msg.transcript_slot with
            | None | Some "terminal_result" ->
                Fleet_store.String_set.add op acc
            | Some _ -> acc)
        | ( ( Wire_fleet.Role_user
            | Wire_fleet.Role_peer _
            | Wire_fleet.Role_assistant
            | Wire_fleet.Role_system
            | Wire_fleet.Role_tool
            | Wire_fleet.Role_request_failure )
          , (Some _ | None) ) ->
            acc)
      Fleet_store.String_set.empty page.messages
  in
  let drafts', _remaining =
    List.fold_left
      (fun (acc, pool) (tx : Drafts.pending_message) ->
        match tx.state with
        | Drafts.Delivered -> (acc, pool)
        | Drafts.Queued
        | Drafts.Sending
        | Drafts.Pending_processing
        | Drafts.Confirming_delivery
        | Drafts.Interrupting
        | Drafts.Failed_retryable _ ->
            let tx_op_id =
              Option.value tx.operation_id ~default:tx.request_id
            in
            let matched_user, next_pool = take_matching_user_msg tx pool in
            if Fleet_store.String_set.mem tx_op_id persisted_failure_ops then
              (Drafts.remove_tx ~request_id:tx.request_id acc, next_pool)
            else if Fleet_store.String_set.mem tx_op_id persisted_assistant_ops
            then
              let acc' =
                match tx.state with
                | Drafts.Failed_retryable _ ->
                    Drafts.remove_tx ~request_id:tx.request_id acc
                | Drafts.Queued
                | Drafts.Sending
                | Drafts.Pending_processing
                | Drafts.Confirming_delivery
                | Drafts.Interrupting
                | Drafts.Delivered ->
                    Drafts.mark_delivered ~now ~request_id:tx.request_id ~keeper
                      ~body:tx.body acc
              in
              (acc', next_pool)
            else (
              match matched_user with
              | Some matched_msg -> (
                  match tx.state with
                  | Drafts.Confirming_delivery ->
                      ( Drafts.mark_delivered ~now ~request_id:tx.request_id
                          ~keeper ~body:tx.body acc
                      , next_pool )
                  | Drafts.Failed_retryable _ ->
                      ( Drafts.mark_user_persisted ~request_id:tx.request_id
                          ~operation_id:matched_msg.operation_id acc
                      , next_pool )
                  | Drafts.Sending ->
                      let acc' =
                        acc
                        |> Drafts.mark_user_persisted ~request_id:tx.request_id
                             ~operation_id:matched_msg.operation_id
                        |> Drafts.mark_accepted ~now ~request_id:tx.request_id
                             ~operation_id:matched_msg.operation_id
                      in
                      (acc', next_pool)
                  | Drafts.Queued
                  | Drafts.Pending_processing
                  | Drafts.Interrupting ->
                      ( Drafts.mark_user_persisted ~request_id:tx.request_id
                          ~operation_id:matched_msg.operation_id acc
                      , next_pool )
                  | Drafts.Delivered -> (acc, next_pool))
              | None -> (
                  match tx.state with
                  | Drafts.Confirming_delivery
                    when tx.recheck_count >= max_confirm_rechecks ->
                      let acc' =
                        if tx.user_persisted then
                          Drafts.mark_delivered ~now ~request_id:tx.request_id
                            ~keeper ~body:tx.body acc
                        else
                          Drafts.mark_failed_retryable ~now
                            ~request_id:tx.request_id
                            ~reason:"Delivery not confirmed in chat history" acc
                      in
                      (acc', pool)
                  | Drafts.Queued
                  | Drafts.Sending
                  | Drafts.Pending_processing
                  | Drafts.Confirming_delivery
                  | Drafts.Interrupting
                  | Drafts.Delivered
                  | Drafts.Failed_retryable _ ->
                      (acc, pool))))
      (drafts, persisted_user_rows)
      (Drafts.pending_txs_for_keeper ~keeper drafts)
  in
  drafts'

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
      let freshness =
        match shell.generated_at_unix with
        | Some ts when ts > m.freshness.last_wall_unix ->
            { m.freshness with last_wall_unix = ts }
        | Some _ | None -> m.freshness
      in
      let next =
        {
          m with
          freshness;
          fleet = Fleet_store.apply_shell ~observed_at:now shell m.fleet;
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
            let cut =
              Cut_reply.apply_page page
                (Option.value (Observed.to_option slot) ~default:Cut_reply.start)
            in
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
      let next =
        { m with attention; work }
        |> Model.with_toast ~now ~level:Model.Toast_success label
      in
      (next, [])
  | Msg.Reply_work_mutation { label; attention_id; result = Error err; _ } ->
      fail_decision_post ~now ~attention_id ~context:label err m
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
      ( {
          m with
          knowledge =
            Knowledge_store.set_wiki_page ~slug:page
              (Observed.value ~observed_at:now detail)
              m.knowledge;
        }
      , [] )
  | Msg.Reply_wiki_page { page; result = Error err } ->
      err_reply
        ~fail:
          (on_knowledge (fun (x : Knowledge_store.t) ->
               Knowledge_store.set_wiki_page ~slug:page
                 (failed_slot err (Knowledge_store.wiki_page_for ~slug:page x))
                 x))
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
      if not matches_active then (m, [])
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
  | Msg.Reply_keeper_memory_facts { keeper; result } ->
      let expected =
        match Model.active_dive m with
        | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_memory }) -> Some name
        | Some (Nav.Dive_knowledge (Nav.Memory_diff_dive { keeper = dk; _ })) ->
            dk
        | Some
            ( Nav.Dive_keeper
                {
                  tab =
                    ( Nav.Keeper_chat
                    | Nav.Keeper_work_candle
                    | Nav.Keeper_sandbox
                    | Nav.Keeper_config );
                  _;
                }
            | Nav.Dive_work _
            | Nav.Dive_knowledge
                (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Artifact_dive _)
            | Nav.Dive_infra _ ) ->
            m.knowledge.memory_diff_keeper
        | None -> (
            match m.nav.workspace with
            | Nav.Keepers
              when Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory
              ->
                Option.map
                  (fun (k : Wire_fleet.keeper_summary) -> k.name)
                  (Fleet_store.selected_keeper_summary m.fleet)
            | Nav.Pulse
            | Nav.Work
            | Nav.Keepers
            | Nav.Knowledge
            | Nav.Runtime
            | Nav.Infra ->
                m.knowledge.memory_diff_keeper)
      in
      if not (Option.equal String.equal expected (Some keeper)) then (m, [])
      else (
        match result with
        | Ok facts when String.equal facts.keeper keeper ->
            ( {
                m with
                knowledge =
                  Knowledge_store.apply_keeper_memory_facts ~observed_at:now
                    facts m.knowledge;
              }
            , [] )
        | Ok _ -> (m, [])
        | Error (Msg.Http_error { status = 404; _ }) ->
            let knowledge =
              { m.knowledge with keeper_memory_facts = Observed.absent }
            in
            ({ m with knowledge }, [])
        | Error
            (( Msg.Http_error _
             | Msg.Transport _
             | Msg.Workspace_mismatch _
             | Msg.Decode_error _ ) as err) ->
            let retryable =
              match err with
              | Msg.Transport _ -> true
              | Msg.Http_error { status; _ } when status >= 500 && status <= 599
                ->
                  true
              | Msg.Http_error _ | Msg.Workspace_mismatch _ | Msg.Decode_error _
                ->
                  false
            in
            let knowledge =
              Knowledge_store.fail_keeper_memory_facts ~keeper
                ~reason:(Msg.http_error_detail err) ~retryable ~at:now
                m.knowledge
            in
            record_http_incident ~now ~source:(Health.Source_keeper keeper)
              ~context:
                (Say.make ~ko:("키퍼 기억 사실 조회: " ^ keeper)
                   ~en:("Keeper memory facts fetch: " ^ keeper))
              err { m with knowledge })
  | Msg.Reply_keeper_memory_activity { keeper; result } ->
      let expected =
        match Model.active_dive m with
        | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_memory }) -> Some name
        | Some (Nav.Dive_knowledge (Nav.Memory_diff_dive { keeper = dk; _ })) ->
            dk
        | Some
            ( Nav.Dive_keeper
                {
                  tab =
                    ( Nav.Keeper_chat
                    | Nav.Keeper_work_candle
                    | Nav.Keeper_sandbox
                    | Nav.Keeper_config );
                  _;
                }
            | Nav.Dive_work _
            | Nav.Dive_knowledge
                (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Artifact_dive _)
            | Nav.Dive_infra _ ) ->
            m.knowledge.memory_diff_keeper
        | None -> (
            match m.nav.workspace with
            | Nav.Keepers
              when Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory
              ->
                Option.map
                  (fun (k : Wire_fleet.keeper_summary) -> k.name)
                  (Fleet_store.selected_keeper_summary m.fleet)
            | Nav.Pulse
            | Nav.Work
            | Nav.Keepers
            | Nav.Knowledge
            | Nav.Runtime
            | Nav.Infra ->
                m.knowledge.memory_diff_keeper)
      in
      if not (Option.equal String.equal expected (Some keeper)) then (m, [])
      else (
        match result with
        | Ok activity when String.equal activity.keeper keeper ->
            ( {
                m with
                knowledge =
                  Knowledge_store.apply_keeper_memory_activity ~observed_at:now
                    activity m.knowledge;
              }
            , [] )
        | Ok _ -> (m, [])
        | Error (Msg.Http_error { status = 404; _ }) ->
            let knowledge =
              { m.knowledge with keeper_memory_activity = Observed.absent }
            in
            ({ m with knowledge }, [])
        | Error
            (( Msg.Http_error _
             | Msg.Transport _
             | Msg.Workspace_mismatch _
             | Msg.Decode_error _ ) as err) ->
            let retryable =
              match err with
              | Msg.Transport _ -> true
              | Msg.Http_error { status; _ } when status >= 500 && status <= 599
                ->
                  true
              | Msg.Http_error _ | Msg.Workspace_mismatch _ | Msg.Decode_error _
                ->
                  false
            in
            let knowledge =
              Knowledge_store.fail_keeper_memory_activity ~keeper
                ~reason:(Msg.http_error_detail err) ~retryable ~at:now
                m.knowledge
            in
            record_http_incident ~now ~source:(Health.Source_keeper keeper)
              ~context:
                (Say.make ~ko:("키퍼 기억 변천 조회: " ^ keeper)
                   ~en:("Keeper memory activity fetch: " ^ keeper))
              err { m with knowledge })
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
      err_reply
        (* A recovery act is a write: the incident carries the failure. *)
        ~fail:Fun.id
        ~source:(Health.Source_keeper keeper) ~ko:"사서 기억 복구"
        ~en:"Memory recovery act" err
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
  | Msg.Reply_connectors (Ok conns) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_connectors ~observed_at:now conns m.runtime;
        }
      , [] )
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
      let lang = match prefs.language with Some l -> l | None -> m.lang in
      let theme_preset =
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
  | Msg.Reply_action_ack { label; result = Ok () } ->
      let nav =
        match m.nav.overlay with
        | Some (Nav.Inline_action _) -> { m.nav with overlay = None }
        | Some
            ( Nav.Palette
            | Nav.Settings _
            | Nav.Incidents
            | Nav.Queue_context _
            | Nav.Help
            | Nav.System_gate _ )
        | None ->
            m.nav
      in
      ( Model.with_toast ~now ~level:Model.Toast_success label
          { m with nav; inline_modal = None }
      , [] )
  | Msg.Reply_action_ack { label; result = Error err } ->
      let inline_modal =
        Option.map
          (fun (modal : Model.inline_modal_state) ->
            { modal with submitting = false; error = Some (Msg.http_error_detail err) })
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
