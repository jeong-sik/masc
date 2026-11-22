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

let take_matching_user_msg (tx : Drafts.pending_message)
    (pool : Wire_fleet.chat_message list) =
  let is_prior (msg : Wire_fleet.chat_message) =
    List.exists (String.equal msg.id) tx.prior_user_msg_ids
  in
  let matches_exact_id (msg : Wire_fleet.chat_message) =
    (not (is_prior msg))
    && String.equal msg.content tx.body
    && (String.equal msg.id tx.request_id
       ||
       match tx.operation_id, msg.execution_id with
       | Some op, Some ex -> String.equal op ex
       | Some _, None | None, Some _ | None, None -> false)
  in
  let matches_unseen_body (msg : Wire_fleet.chat_message) =
    (not (is_prior msg)) && String.equal msg.content tx.body
  in
  let rec extract pred acc = function
    | [] -> None
    | msg :: rest ->
        if pred msg then Some (List.rev_append acc rest)
        else extract pred (msg :: acc) rest
  in
  match extract matches_exact_id [] pool with
  | Some remaining -> (true, remaining)
  | None -> (
      match extract matches_unseen_body [] pool with
      | Some remaining -> (true, remaining)
      | None -> (false, pool))

let confirm_pending_txs_from_history ~now ~keeper
    (page : Wire_fleet.chat_history_page) drafts =
  let persisted_user_rows =
    List.filter
      (fun (msg : Wire_fleet.chat_message) ->
        match msg.role with
        | Wire_fleet.Role_user -> true
        | Wire_fleet.Role_assistant
        | Wire_fleet.Role_system
        | Wire_fleet.Role_tool ->
            false)
      page.messages
  in
  let drafts', _remaining =
    List.fold_left
      (fun (acc, pool) (tx : Drafts.pending_message) ->
        match tx.state with
        | Drafts.Pending_processing | Drafts.Confirming_delivery ->
            let matched, next_pool = take_matching_user_msg tx pool in
            if matched then
              ( Drafts.mark_delivered ~now ~request_id:tx.request_id ~keeper
                  ~body:tx.body acc
              , next_pool )
            else (acc, pool)
        | Drafts.Queued
        | Drafts.Sending
        | Drafts.Delivered
        | Drafts.Failed_retryable _ ->
            (acc, pool))
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
  let err_reply ~source ~ko ~en err =
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
      err_reply ~source:Health.Source_client_http ~ko:"대시보드 셸 조회"
        ~en:"Dashboard shell fetch" err
  | Msg.Reply_keepers_roster (Ok ks) ->
      let fleet = Fleet_store.apply_keepers ~observed_at:now ks m.fleet in
      let runtime = Runtime_store.sync_keeper_companies ks m.runtime in
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
      let cmds =
        if
          Nav.equal_workspace next.nav.workspace Nav.Keepers
          && next.nav.dive_stack = []
          && Option.is_some fleet.selected_keeper
        then View_fetches.fetches_for_current_view next
        else []
      in
      (next, cmds)
  | Msg.Reply_keepers_roster (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"키퍼 목록 조회"
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
      err_reply ~source:Health.Source_client_http ~ko:"키퍼 턴 상태 조회"
        ~en:"Keeper turns fetch" err
  | Msg.Reply_chat_history { keeper; result = Ok page } ->
      let fleet =
        Fleet_store.apply_chat_history ~observed_at:now ~keeper page m.fleet
      in
      let drafts =
        confirm_pending_txs_from_history ~now ~keeper page m.drafts
      in
      ({ m with fleet; drafts }, [])
  | Msg.Reply_chat_history { keeper; result = Error err } ->
      err_reply ~source:(Health.Source_keeper keeper) ~ko:"대화 이력 조회"
        ~en:"Chat history fetch" err
  | Msg.Reply_planning (Ok planning) ->
      let work = Work_store.apply_planning ~observed_at:now planning m.work in
      ( { m with work }
        |> Model.rebuild_attention
        |> Model.sync_effective_scorecard ~now
      , [] )
  | Msg.Reply_planning (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"목표·작업 조회"
        ~en:"Planning fetch" err
  | Msg.Reply_planning_backlog counts ->
      let work = Work_store.apply_backlog_counts counts m.work in
      ({ m with work } |> Model.sync_effective_scorecard ~now, [])
  | Msg.Reply_verifications (Ok vs) ->
      ( { m with work = Work_store.apply_verifications ~observed_at:now vs m.work }
        |> Model.sync_effective_scorecard ~now
      , [] )
  | Msg.Reply_verifications (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"검증 목록 조회"
        ~en:"Verifications fetch" err
  | Msg.Reply_schedules (Ok scheds) ->
      ( { m with work = Work_store.apply_schedules ~observed_at:now scheds m.work }
      , [] )
  | Msg.Reply_schedules (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"일정 조회"
        ~en:"Schedules fetch" err
  | Msg.Reply_asks (Ok asks) ->
      let work = Work_store.apply_asks ~observed_at:now asks m.work in
      (Model.rebuild_attention { m with work }, [])
  | Msg.Reply_asks (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"질문 목록 조회"
        ~en:"Asks fetch" err
  | Msg.Reply_tool_approvals (Ok approvals) ->
      let work =
        Work_store.apply_tool_approvals ~observed_at:now approvals m.work
      in
      (Model.rebuild_attention { m with work }, [])
  | Msg.Reply_tool_approvals (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"도구 승인 대기 조회"
        ~en:"Tool approvals fetch" err
  | Msg.Reply_gate_pending (Ok gates) ->
      let work = Work_store.apply_gate_pending ~observed_at:now gates m.work in
      (Model.rebuild_attention { m with work }, [])
  | Msg.Reply_gate_pending (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"게이트 승인 조회"
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
          err_reply ~source:Health.Source_client_http ~ko:"캔들 원장 조회"
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
      let attention =
        match attention_id with
        | Some id -> Attention.clear_in_flight ~id m.attention
        | None -> m.attention
      in
      let m' = { m with attention } in
      let next, cmds =
        record_http_incident ~now ~source:Health.Source_client_http
          ~context:label err m'
      in
      let next =
        Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      in
      (next, cmds)
  | Msg.Reply_board_feed (Ok feed) ->
      ( {
          m with
          knowledge = Knowledge_store.apply_board ~observed_at:now feed m.knowledge;
        }
        |> Model.sync_effective_scorecard ~now
      , [] )
  | Msg.Reply_board_feed (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"보드 피드 조회"
        ~en:"Board feed fetch" err
  | Msg.Reply_board_thread (Ok thread) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_thread ~observed_at:now thread m.knowledge;
        }
      , [] )
  | Msg.Reply_board_thread (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"보드 스레드 조회"
        ~en:"Board thread fetch" err
  | Msg.Reply_quarantines (Ok qs) ->
      let knowledge =
        Knowledge_store.apply_quarantines ~observed_at:now qs m.knowledge
      in
      (Model.rebuild_attention { m with knowledge }, [])
  | Msg.Reply_quarantines (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"격리 후보 조회"
        ~en:"Quarantines fetch" err
  | Msg.Reply_wiki_index (Ok idx) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_wiki_index ~observed_at:now idx m.knowledge;
        }
      , [] )
  | Msg.Reply_wiki_index (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"위키 색인 조회"
        ~en:"Wiki index fetch" err
  | Msg.Reply_wiki_page (Ok page) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_wiki_page ~observed_at:now page m.knowledge;
        }
      , [] )
  | Msg.Reply_wiki_page (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"위키 문서 조회"
        ~en:"Wiki page fetch" err
  | Msg.Reply_wiki_log (Ok log) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_wiki_log ~observed_at:now log m.knowledge;
        }
      , [] )
  | Msg.Reply_wiki_log (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"위키 변경 이력 조회"
        ~en:"Wiki log fetch" err
  | Msg.Reply_wiki_search (Ok search) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_wiki_search ~observed_at:now search m.knowledge;
        }
      , [] )
  | Msg.Reply_wiki_search (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"위키 검색"
        ~en:"Wiki search" err
  | Msg.Reply_wiki_lint (Ok lint) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_wiki_lint ~observed_at:now lint m.knowledge;
        }
      , [] )
  | Msg.Reply_wiki_lint (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"위키 린트 조회"
        ~en:"Wiki lint fetch" err
  | Msg.Reply_wiki_put { page; result = Ok detail } ->
      let knowledge =
        m.knowledge
        |> Knowledge_store.apply_wiki_page ~observed_at:now detail
        |> Knowledge_store.cancel_wiki_edit
      in
      let next =
        { m with knowledge }
        |> Model.with_toast ~now ~level:Model.Toast_success
             (Say.make ~ko:("위키 저장 완료: " ^ page) ~en:("Saved wiki: " ^ page))
      in
      ( next
      , [
          Cmd.Http_get
            {
              epoch = m.epoch;
              req = Cmd.Get_wiki_index { tag = None; source = None; sort = None };
            };
        ] )
  | Msg.Reply_wiki_put { page; result = Error err } ->
      let knowledge = Knowledge_store.mark_wiki_edit_saving false m.knowledge in
      let next, cmds =
        record_http_incident ~now ~source:Health.Source_client_http
          ~context:
            (Say.make ~ko:("위키 저장: " ^ page) ~en:("Save wiki: " ^ page))
          err { m with knowledge }
      in
      ( Model.with_toast ~now ~level:Model.Toast_error
          (Msg.http_error_summary err) next
      , cmds )
  | Msg.Reply_artifacts (Ok items) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_artifacts ~observed_at:now items m.knowledge;
        }
      , [] )
  | Msg.Reply_artifacts (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"산출물 목록 조회"
        ~en:"Artifacts fetch" err
  | Msg.Reply_world_memory (Ok wm) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_world_memory ~observed_at:now wm m.knowledge;
        }
      , [] )
  | Msg.Reply_world_memory (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"세계 기억 조회"
        ~en:"World memory fetch" err
  | Msg.Reply_memory_diff (Ok diff) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_memory_diff ~observed_at:now diff m.knowledge;
        }
      , [] )
  | Msg.Reply_memory_diff (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"기억 변화 조회"
        ~en:"Memory diff fetch" err
  | Msg.Reply_keeper_memory_os_internals (Ok internals) ->
      ( {
          m with
          knowledge =
            Knowledge_store.apply_memory_os_internals ~observed_at:now internals
              m.knowledge;
        }
      , [] )
  | Msg.Reply_keeper_memory_os_internals (Error err) -> (
      match err with
      | Msg.Http_error { status = 404; _ } ->
          let knowledge =
            {
              m.knowledge with
              memory_os_internals = Observed.absent;
            }
          in
          ({ m with knowledge }, [])
      | Msg.Http_error _ | Msg.Transport _ | Msg.Workspace_mismatch _
      | Msg.Decode_error _ ->
          err_reply ~source:Health.Source_client_http ~ko:"메모리 OS 내부 상태 조회"
            ~en:"Memory OS internals fetch" err)
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
      err_reply ~source:(Health.Source_keeper keeper) ~ko:"사서 기억 복구"
        ~en:"Memory recovery act" err
  | Msg.Reply_provider_usage (Ok uw) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_usage_windows ~observed_at:now uw m.runtime;
        }
      , [] )
  | Msg.Reply_provider_usage (Error err) ->
      err_reply ~source:(Health.Source_runtime "usage") ~ko:"프로바이더 할당 조회"
        ~en:"Provider usage fetch" err
  | Msg.Reply_provider_usage_history (Ok hist) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_usage_history ~observed_at:now hist m.runtime;
        }
      , [] )
  | Msg.Reply_provider_usage_history (Error err) ->
      err_reply ~source:(Health.Source_runtime "usage_history")
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
      err_reply ~source:(Health.Source_runtime "costs") ~ko:"키퍼 비용 조회"
        ~en:"Keeper costs fetch" err
  | Msg.Reply_efficiency (Ok eff) ->
      ( {
          m with
          runtime = Runtime_store.apply_efficiency ~observed_at:now eff m.runtime;
        }
      , [] )
  | Msg.Reply_efficiency (Error err) ->
      err_reply ~source:(Health.Source_runtime "efficiency") ~ko:"효율 지표 조회"
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
      err_reply ~source:(Health.Source_runtime "models_metrics")
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
          err_reply ~source:(Health.Source_runtime "runtime_metrics")
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
      err_reply ~source:(Health.Source_runtime "resolved") ~ko:"페일오버 레인 조회"
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
          err_reply ~source:(Health.Source_runtime "config_raw")
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
          err_reply ~source:(Health.Source_runtime "setup_inventory")
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
      err_reply ~source:(Health.Source_runtime "probe") ~ko:"런타임 프로브 조회"
        ~en:"Runtime probe fetch" err
  | Msg.Reply_exact_lane_runs (Ok runs) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_exact_lane_runs ~observed_at:now runs m.runtime;
        }
      , [] )
  | Msg.Reply_exact_lane_runs (Error err) ->
      err_reply ~source:(Health.Source_runtime "exact") ~ko:"교차 검증 레인 조회"
        ~en:"Exact lanes fetch" err
  | Msg.Reply_fusion_runs (Ok runs) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_fusion_runs ~observed_at:now runs m.runtime;
        }
      , [] )
  | Msg.Reply_fusion_runs (Error err) ->
      err_reply ~source:(Health.Source_runtime "fusion") ~ko:"퓨전 실행 조회"
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
      err_reply ~source:(Health.Source_runtime "tools") ~ko:"도구 시계열 조회"
        ~en:"Tool series fetch" err
  | Msg.Reply_tools_catalog (Ok tools) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_tools_catalog ~observed_at:now tools m.runtime;
        }
      , [] )
  | Msg.Reply_tools_catalog (Error err) ->
      err_reply ~source:(Health.Source_runtime "tools") ~ko:"도구 목록 조회"
        ~en:"Tools catalog fetch" err
  | Msg.Reply_connectors (Ok conns) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_connectors ~observed_at:now conns m.runtime;
        }
      , [] )
  | Msg.Reply_connectors (Error err) ->
      err_reply ~source:(Health.Source_runtime "connectors") ~ko:"커넥터 조회"
        ~en:"Connectors fetch" err
  | Msg.Reply_browser_lane (Ok bl) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_browser_lane ~observed_at:now bl m.runtime;
        }
      , [] )
  | Msg.Reply_browser_lane (Error err) ->
      err_reply ~source:(Health.Source_runtime "browser") ~ko:"브라우저 레인 조회"
        ~en:"Browser lane fetch" err
  | Msg.Reply_mcp_clients (Ok clients) ->
      ( {
          m with
          runtime =
            Runtime_store.apply_mcp_clients ~observed_at:now clients m.runtime;
        }
      , [] )
  | Msg.Reply_mcp_clients (Error err) ->
      err_reply ~source:(Health.Source_runtime "clients") ~ko:"클라이언트 조회"
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
          err_reply ~source:(Health.Source_sandbox "fleet") ~ko:"샌드박스 조회"
            ~en:"Sandboxes fetch" err)
  | Msg.Reply_keeper_sandbox (Ok ks) ->
      ( {
          m with
          infra = Infra_store.apply_keeper_sandbox ~observed_at:now ks m.infra;
        }
      , [] )
  | Msg.Reply_keeper_sandbox (Error err) ->
      err_reply ~source:(Health.Source_sandbox "keeper") ~ko:"키퍼 샌드박스 조회"
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
      err_reply ~source:Health.Source_client_http ~ko:"저장소 목록 조회"
        ~en:"Repositories fetch" err
  | Msg.Reply_file_changes { keeper; result = Ok changes } ->
      let expected =
        match Infra_store.selected_repository m.infra with
        | Some { keepers = k :: _; _ } -> Some k
        | Some { keepers = []; _ } -> None
        | None ->
            Option.map
              (fun (k : Wire_fleet.keeper_summary) -> k.name)
              (Fleet_store.selected_keeper_summary m.fleet)
      in
      if Option.equal String.equal expected (Some keeper) then
        ( {
            m with
            infra =
              Infra_store.apply_file_changes ~keeper ~observed_at:now changes
                m.infra;
          }
        , [] )
      else (m, [])
  | Msg.Reply_file_changes { keeper = _; result = Error err } ->
      err_reply ~source:Health.Source_client_http ~ko:"파일 변경 조회"
        ~en:"File changes fetch" err
  | Msg.Reply_system_logs (Ok entries) ->
      ({ m with infra = Infra_store.apply_log_snapshot entries m.infra }, [])
  | Msg.Reply_system_logs (Error err) ->
      err_reply ~source:Health.Source_client_http ~ko:"시스템 로그 조회"
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
      err_reply ~source:Health.Source_client_http ~ko:"TUI 설정 조회"
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
      err_reply ~source:Health.Source_client_http ~ko:"설정 스키마 조회"
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
