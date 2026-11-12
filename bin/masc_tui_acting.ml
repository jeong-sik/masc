module Observer = Masc_tui_observer
module Message_layout = Masc_tui_message_layout

type filter =
  | Turns
  | Actions
  | Everything

let next_filter = function
  | Turns -> Actions
  | Actions -> Everything
  | Everything -> Turns

let filter_label ~ko filter =
  match filter, ko with
  | Turns, false -> "turns"
  | Turns, true -> "턴"
  | Actions, false -> "actions"
  | Actions, true -> "동작"
  | Everything, false -> "everything"
  | Everything, true -> "전체"

(* One feed event as the screen holds it. The arrival time is here rather than
   read back off the event because the screen is a feed: rows are held and
   drawn in the order they arrived, and two event kinds carry no clock at all
   ([Snapshot], [Other]) -- those rows used to draw --:--:--, on 925 of the
   927 rows on the screen that prompted this. *)
type entry = {
  ae_at : float;  (** when the TUI received it *)
  ae_event : Observer.event;
}

let visible filter (event : Observer.event) =
  match filter with
  | Everything -> true
  | Turns | Actions -> (
      match event with
      (* A resource that could not be acquired, or whose release nobody can show,
         is a failure the operator acts on. One acquired or released
         is the lane runtime doing its job, and is state. *)
      | Observer.Lane_resource { Observer.lr_lifecycle; _ } -> (
          match lr_lifecycle with
          | Masc.Lane_addon_resource_events.Acquire_failed | Masc.Lane_addon_resource_events.Release_incomplete -> true
          | Masc.Lane_addon_resource_events.Acquired | Masc.Lane_addon_resource_events.Release_confirmed -> false)
      | Observer.Agent_core { Observer.kind = Observer.Telemetry; _ } -> false
      | Observer.Agent_core
          { Observer.kind =
              ( Observer.Tool_called | Observer.Tool_completed
              | Observer.Turn_started | Observer.Turn_ready
              | Observer.Turn_completed | Observer.Agent_started
              | Observer.Agent_completed _ | Observer.Agent_failed _
              | Observer.Agent_yielded _ | Observer.Agent_input_required _
              | Observer.Tool_approval_completed
              | Observer.Relay_subscription_loss _
              | Observer.Agent_core_other _ )
          ; _
          } -> true
      | Observer.Keeper_heartbeat _ | Observer.Keeper_composite_changed _ | Observer.Keeper_metrics_appended _
      | Observer.Snapshot _ | Observer.Execution_snapshot
      (* A reply sends one stream frame per token, and a queue-size change is
         state rather than something a keeper did. Both belong with the
         heartbeat: shown under [Everything], never counted as an action. *)
      | Observer.Keeper_chat_stream_frame _ | Observer.Keeper_turn_stream_frame _
      | Observer.Keeper_waiting_inventory_changed _ | Observer.Keeper_async_requests_changed _ | Observer.Keeper_skill_activations_changed _ | Observer.Keeper_roster_change _ | Observer.Keeper_turn_changed _
      (* A memory journal row follows a memory write whose tool call is
         already its own action row. *)
      | Observer.Keeper_memory_journal_appended _ | Observer.Keeper_runtime_journal_appended _
      (* A provider-call observation is identity the fold reads, not
         something a keeper did. *)
      | Observer.Keeper_turn_observation _
      (* Server push, same verdict as the whole-projection snapshots: a
         deliberation changing stage is something the server reports, not
         something a keeper did. *)
      | Observer.Fusion_run_status _
      (* A run registry or the Board changed. Nothing a keeper did; the
         frame says only that a reader showing it should fetch it again. *)
      | Observer.Internal_agent_runs_changed _ | Observer.Workspace_store_changed _ | Observer.Dataset_changed _ | Observer.Gate_connector_changed _ | Observer.Keeper_event_queue_changed _ | Observer.Board_changed _
      | Observer.Approval_change _ ->
          false
      | Observer.Keeper_tool_call _ | Observer.Keeper_turn_complete _
      | Observer.Keeper_chat_appended _ | Observer.Other _ ->
          true)

(* Trimming the ring by arrival alone let one class of event evict every
   other. [acting_retained_entries] was sized against a feed of about four
   events a second, and a chat stream sends one frame per token: a single
   thousand-token reply fills the whole ring, and the calls and settlements
   an operator opened this screen for are gone before they can read them.

   So the budget is per class, using the same predicate the screen filters
   with -- what [Actions] shows gets [actions] slots, everything else gets
   [quiet]. Every class keeps its newest and the rest is counted, not
   silently forgotten. Entries arrive newest-first and stay in that order.

   A turn observation spends an action slot although no scope but
   [Everything] draws it. The Turns fold reads it to number the calls it
   reports, so it has to leave the ring with those calls, neither before nor
   after them. Among the quiet class, token-sized stream frames trim it
   before its calls and the turn splits back into unnumbered rows. Held past
   its calls, it still answers for its ordinal when a session created
   without a checkpoint reaches that ordinal again, and the new call in
   flight opens a row under the old keeper turn. In the action budget it
   leaves in arrival order with the frames around it. *)
let retained_as_action (event : Observer.event) =
  match event with
  | Observer.Keeper_turn_observation _ -> true
  | Observer.Agent_core _ | Observer.Keeper_heartbeat _
  | Observer.Keeper_tool_call _ | Observer.Keeper_turn_complete _
  | Observer.Keeper_composite_changed _ | Observer.Keeper_metrics_appended _ | Observer.Keeper_chat_appended _
  | Observer.Keeper_memory_journal_appended _ | Observer.Keeper_runtime_journal_appended _
  | Observer.Keeper_chat_stream_frame _ | Observer.Keeper_turn_stream_frame _
  | Observer.Keeper_waiting_inventory_changed _ | Observer.Keeper_async_requests_changed _ | Observer.Keeper_skill_activations_changed _ | Observer.Keeper_roster_change _ | Observer.Keeper_turn_changed _
  | Observer.Fusion_run_status _ | Observer.Internal_agent_runs_changed _ | Observer.Workspace_store_changed _ | Observer.Dataset_changed _ | Observer.Gate_connector_changed _ | Observer.Keeper_event_queue_changed _ | Observer.Board_changed _ | Observer.Approval_change _
  | Observer.Lane_resource _ | Observer.Snapshot _ | Observer.Execution_snapshot | Observer.Other _ ->
      visible Actions event

let retain ~actions ~quiet ~event_of entries =
  let rec walk kept n_actions n_quiet dropped = function
    | [] -> (List.rev kept, dropped)
    | entry :: older ->
        let is_action = retained_as_action (event_of entry) in
        let used = if is_action then n_actions else n_quiet in
        let budget = if is_action then actions else quiet in
        if used >= budget then walk kept n_actions n_quiet (dropped + 1) older
        else
          walk (entry :: kept)
            (if is_action then n_actions + 1 else n_actions)
            (if is_action then n_quiet else n_quiet + 1)
            dropped older
  in
  walk [] 0 0 0 entries

type glyph =
  | Call_started
  | Call_returned
  | Turn_boundary
  | Turn_done
  | Failure
  | Attention
  | Quiet

let glyph_text = function
  | Call_started -> "\xe2\x96\xb6"
  | Call_returned -> "\xe2\x9c\x93"
  | Turn_boundary -> "\xe2\x97\x8f"
  | Turn_done -> "\xe2\x96\xa0"
  | Failure -> "\xe2\x9c\x97"
  | Attention -> "?"
  (* A quiet row claims no state, so it draws no mark: a blank first cell.
     [\xc2\xb6] here read as the roster's idle glyph -- the same character
     saying two things in one line (#33691). The label beside the cell
     names the row. *)
  | Quiet -> " "

type row = {
  at : float;
  keeper : string;
  glyph : glyph;
  label : string;
  detail : string;
}

(* The feed measures a call in milliseconds; the spelling is the TUI's one
   duration ladder, which takes seconds. This ladder used to stop at minutes,
   so a run over an hour read "62m03s".

   A negative duration has no spelling on the ladder, and every row below
   treats it as the feed giving no duration at all: the row a missing one
   leaves is the row a negative one leaves. *)
let milliseconds_in_a_second = 1000.

let elapsed_text ms =
  Masc_tui_message_layout.elapsed_text (ms /. milliseconds_in_a_second)

let turn_number_text ~ko turn =
  Printf.sprintf (if ko then "턴 %d" else "turn %d") turn

(* Two readings of the same value, because the two places it goes want
   different things from a turn nobody numbered.

   The number is missing whenever the settle that carries it is not in the
   held window, which on a live-only feed is the common case, not the odd
   one: over a two-minute live window the Events list drew ten
   turn-labelled rows and nine of them had no number.

   The column that names the event still has something to say -- it is a
   turn, and the glyph beside it already says whether it started or
   finished. The detail beside it does not: a turn with no number adds
   nothing to "in 812 out 96". Neither of them asks [turn ?], a question
   the row cannot answer and the reader cannot act on; the acting pane
   reached the same conclusion about the same value. *)
let turn_label ~ko = function
  | Some turn -> turn_number_text ~ko turn
  | None -> if ko then "턴" else "turn"

let turn_detail ~ko = function
  | Some turn -> turn_number_text ~ko turn
  | None -> ""

(* A turn's input count holds everything the turn sent, cache reads
   included. On a cached runtime that is mostly the cache read back:
   e-masc-the-leader's turn 1853 (2026-09-25) sent 3,716,155 tokens, 3,556,362
   of them cache reads, and the row said "in 3.72M" as if all of it were new.

   The split is drawn only from counts that add up. The input less the cache
   reads is what the turn processed fresh: the cache writes plus the uncached
   rest, so it can be no smaller than the cache writes. Counts that break that
   keep the whole figure; a split drawn from them would be a guess. So does a
   cache read of zero: the server's usage sample holds 0 for a runtime that
   never reports its cache, so on the wire a zero and an unreported read are
   the same value, and "new" would claim what nobody measured. *)
type turn_input =
  | Input_whole of int
  | Input_split of { fresh : int; cached : int }

let turn_input ~input ~cache_read ~cache_creation =
  match (cache_read, cache_creation) with
  | Some cached, Some creation ->
      let fresh = input - cached in
      if cached > 0 && creation >= 0 && fresh >= creation then
        Input_split { fresh; cached }
      else Input_whole input
  | Some _, None | None, (Some _ | None) -> Input_whole input

let turn_input_of_settle (t : Observer.keeper_turn_complete) =
  Option.map
    (fun input ->
      turn_input ~input ~cache_read:t.Observer.tc_cache_read_tokens
        ~cache_creation:t.Observer.tc_cache_creation_tokens)
    t.Observer.tc_input_tokens

let turn_input_total = function
  | Input_whole n -> n
  | Input_split { fresh; cached } -> fresh + cached

let fresh_input_text ~ko fresh =
  let figure = Message_layout.compact_count fresh in
  if ko then "새 입력 " ^ figure else "in " ^ figure ^ " new"

let cached_input_text ~ko cached =
  let figure = Message_layout.compact_count cached in
  if ko then "캐시 " ^ figure else figure ^ " cached"

let output_text ~ko output =
  (if ko then "출력 " else "out ") ^ Message_layout.compact_count output

let calls_text ~ko n =
  if ko then Printf.sprintf "호출 %d건" n
  else Printf.sprintf "%d call%s" n (if n = 1 then "" else "s")

let turn_input_text ~ko = function
  | Input_whole n -> (if ko then "입력 " else "in ") ^ Message_layout.compact_count n
  | Input_split { fresh; cached } ->
      fresh_input_text ~ko fresh ^ " \xc2\xb7 " ^ cached_input_text ~ko cached

(* A whole input keeps the row's old "in N out M"; a split one already
   joins its parts with dots, so the output takes one too. *)
let settle_tokens_text ~ko = function
  | Some (Input_whole _ as input), Some o ->
      turn_input_text ~ko input ^ " " ^ output_text ~ko o
  | Some (Input_split _ as input), Some o ->
      turn_input_text ~ko input ^ " \xc2\xb7 " ^ output_text ~ko o
  | Some input, None -> turn_input_text ~ko input
  | None, Some o -> output_text ~ko o
  | None, None -> ""

(* The keeper turn a provider call belongs to, as the keeper's hook reports
   it: [total_turns] keeper turns had completed when the call ran, so the
   call is inside turn [total_turns + 1] -- the registry's own definition of
   a turn id and the number the turn's settle carries. *)
let keeper_turn_of_observation (o : Observer.keeper_turn_observation) =
  Option.map succ o.Observer.to_total_turns

let batch_text = function
  | Some (index, size) -> Printf.sprintf " [%d/%d]" (index + 1) size
  | None -> ""

(* Mirrors Keeper_tool_composition_catalog.{skill_tool_name,tool_name_prefix}.
   Those tool names are a stable wire contract (RFC skills-as-tools keeps
   them identical across migrations); this projection library deliberately
   depends only on the observer, so it names them instead of linking the
   keeper catalog. Display tagging only — never a dispatch decision. *)
let skill_read_tool_name = "keeper_skill"
let composition_tool_name_prefix = "keeper_compose_"

let is_skill_tool tool =
  String.equal tool skill_read_tool_name
  || String.starts_with ~prefix:composition_tool_name_prefix tool

(* A run's elapsed time as the words its row joins: none when the ladder has
   no spelling for it, so a run reported with a negative time reads like one
   the feed gave no time for. *)
let run_elapsed elapsed_s =
  Option.to_list (elapsed_text (elapsed_s *. milliseconds_in_a_second))

(* The EVENT column's word, on its own. Measuring the table needs the two
   named columns and nothing else, and building a row to read one of them
   spells every detail sentence the measurement throws away. The row asks
   this function for its label rather than spelling the word a second time,
   so the two readings cannot drift. *)
let agent_core_label ~ko (e : Observer.agent_core) =
  let say korean english = if ko then korean else english in
  let skill = Option.exists is_skill_tool e.Observer.tool in
  match e.Observer.kind with
  | Observer.Tool_called -> if skill then say "스킬 호출" "skill call" else say "호출" "call"
  | Observer.Tool_completed -> if skill then say "스킬 반환" "skill returned" else say "반환" "returned"
  | Observer.Turn_started -> say "턴 시작" "turn start"
  | Observer.Turn_ready -> say "턴 준비" "turn ready"
  | Observer.Turn_completed -> say "턴 끝" "turn end"
  | Observer.Agent_started -> say "에이전트 시작" "agent start"
  | Observer.Agent_completed _ -> say "에이전트 완료" "agent done"
  | Observer.Agent_failed _ -> say "에이전트 실패" "agent failed"
  | Observer.Agent_yielded _ -> say "에이전트 양보" "agent yielded"
  | Observer.Agent_input_required _ -> say "입력 대기" "waiting for input"
  | Observer.Tool_approval_completed -> say "승인 결정됨" "approval settled"
  | Observer.Telemetry -> say "텔레메트리" "telemetry"
  | Observer.Relay_subscription_loss _ -> say "관찰 이벤트 유실" "observer events lost"
  | Observer.Agent_core_other name -> name

let agent_core_row ~ko ~at ~duration_ms (e : Observer.agent_core) =
  let tool = Option.value ~default:Masc_tui_theme.Glyph.no_value e.Observer.tool in
  let label = agent_core_label ~ko e in
  let glyph, detail =
    match e.Observer.kind with
    (* The wire's [turn] is the agent session's ordinal for the provider
       call, not the keeper's turn number that [turn N] means everywhere else
       on this surface, so a flat row does not print it; the event evidence
       shows it under its own name. *)
    | Observer.Tool_called ->
        (Call_started, Printf.sprintf "%s%s" tool (batch_text e.Observer.batch))
    | Observer.Tool_completed ->
        ( Call_returned
        , Printf.sprintf "%s%s%s" tool
            (match Option.bind duration_ms elapsed_text with
             | Some text -> " \xc2\xb7 " ^ text
             | None -> "")
            (batch_text e.Observer.batch) )
    | Observer.Turn_started -> (Turn_boundary, "")
    | Observer.Turn_ready -> (Turn_boundary, "")
    | Observer.Turn_completed -> (Turn_boundary, "")
    (* A run's own wire id rides these four as [task_id]; it is not a MASC
       task, and the event evidence shows it under its own name. What the row
       says is how the run went: how long it ran, and for a failure the
       error's code and text. *)
    | Observer.Agent_started -> (Turn_boundary, "")
    | Observer.Agent_completed { elapsed_s } ->
        (Turn_done, String.concat "" (run_elapsed elapsed_s))
    | Observer.Agent_failed { elapsed_s; error_code; error } ->
        ( Failure
        , String.concat " \xc2\xb7 " (run_elapsed elapsed_s @ [ error_code; error ])
        )
    | Observer.Agent_yielded { elapsed_s } ->
        (Quiet, String.concat "" (run_elapsed elapsed_s))
    | Observer.Agent_input_required { elapsed_s; question } ->
        (Attention, String.concat " · " (run_elapsed elapsed_s @ [ question ]))
    (* Where the tool name is the whole detail, an event that carries none
       leaves the cell empty rather than printing the [?] the default stands
       for. A lone [?] in the Detail column reads as a failure marker and says
       nothing; [masc:audit_event] drew one. The arms above spell the tool
       into a longer sentence, where the placeholder still marks its slot. *)
    | Observer.Tool_approval_completed ->
        (Attention, Option.value ~default:"" e.Observer.tool)
    | Observer.Telemetry -> (Quiet, "")
    | Observer.Relay_subscription_loss { dropped_count; _ } ->
        (Attention, Printf.sprintf
            (if ko then "중계 전에 이벤트 %d개 유실" else "%d events lost before relay")
            dropped_count)
    | Observer.Agent_core_other _ ->
        (Attention, Option.value ~default:"" e.Observer.tool)
  in
  let detail =
    match e.Observer.kind, e.Observer.task with
    | ( ( Observer.Agent_started | Observer.Agent_completed _
        | Observer.Agent_failed _ | Observer.Agent_yielded _
        | Observer.Agent_input_required _ )
      , (Some _ | None) ) ->
        detail
    | ( ( Observer.Tool_called | Observer.Tool_completed | Observer.Turn_started
        | Observer.Turn_ready | Observer.Turn_completed
        | Observer.Tool_approval_completed | Observer.Telemetry | Observer.Relay_subscription_loss _
        | Observer.Agent_core_other _ )
      , Some task ) ->
        if detail = "" then task else detail ^ " \xc2\xb7 " ^ task
    | ( ( Observer.Tool_called | Observer.Tool_completed | Observer.Turn_started
        | Observer.Turn_ready | Observer.Turn_completed
        | Observer.Tool_approval_completed | Observer.Telemetry | Observer.Relay_subscription_loss _
        | Observer.Agent_core_other _ )
      , None ) ->
        detail
  in
  { at
  ; keeper = Option.value ~default:Masc_tui_theme.Glyph.no_value e.Observer.agent
  ; glyph
  ; label
  ; detail
  }

(* The Keeper a change names, or ["server"] for a change of the whole queue,
   the rules, a Gate mode or an installation's questions. *)
let approval_change_keeper = function
  | Observer.Gate_keeper_settings_changed { keeper }
  | Observer.Tool_approval_waits_changed { keeper }
  | Observer.Tool_approval_mode_changed { keeper }
  | Observer.Keeper_asks_changed { keeper } ->
      keeper
  | Observer.Approval_queue_changed | Observer.Approval_rules_changed | Observer.Gate_mode_changed
  | Observer.Installation_asks_changed _ ->
      "server"

let keeper_of_event ~traces (event : Observer.event) =
  match event with
  | Observer.Agent_core e -> (
      let by_agent = Option.value ~default:Masc_tui_theme.Glyph.no_value e.Observer.agent in
      match e.Observer.correlation with
      | None -> by_agent
      | Some correlation -> (
          match
            List.find_opt
              (fun (_, trace) -> String.equal trace correlation)
              traces
          with
          | Some (keeper, _) -> keeper
          | None -> by_agent))
  | Observer.Keeper_heartbeat h -> h.Observer.hb_keeper
  | Observer.Keeper_tool_call c -> c.Observer.kt_keeper
  | Observer.Keeper_turn_complete t -> t.Observer.tc_keeper
  | Observer.Keeper_turn_observation o -> o.Observer.to_keeper
  | Observer.Keeper_composite_changed { keeper; _ }
  | Observer.Keeper_metrics_appended { keeper; _ }
  | Observer.Keeper_chat_appended { keeper; _ }
  | Observer.Keeper_memory_journal_appended { keeper; _ }
  | Observer.Keeper_runtime_journal_appended { keeper; _ }
  | Observer.Keeper_chat_stream_frame { keeper; _ }
  | Observer.Keeper_turn_stream_frame { keeper; _ }
  | Observer.Keeper_waiting_inventory_changed { keeper; _ }
  | Observer.Keeper_async_requests_changed { keeper }
  | Observer.Keeper_skill_activations_changed { keeper }
  | Observer.Keeper_event_queue_changed { keeper }
  | Observer.Keeper_roster_change (Observer.Keeper_row_changed { keeper })
  | Observer.Keeper_turn_changed { keeper; _ }
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Keeper_metrics { keeper })
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Keeper_oauth_attempts { keeper })
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Skill_activations { keeper })
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Memory_health { keeper })
  | Observer.Fusion_run_status { keeper; _ } ->
      keeper
  | Observer.Approval_change change -> approval_change_keeper change
  | Observer.Keeper_roster_change Observer.Every_row_changed
  | Observer.Internal_agent_runs_changed _ | Observer.Workspace_store_changed _
  | Observer.Dataset_changed
      ( Masc.Workspace_dataset_event.Repositories | Masc.Workspace_dataset_event.Verification_requests
      | Masc.Workspace_dataset_event.Harness_verdicts | Masc.Workspace_dataset_event.Goals
      | Masc.Workspace_dataset_event.Runtime_config | Masc.Workspace_dataset_event.Connectors
      | Masc.Workspace_dataset_event.Skill_catalog | Masc.Workspace_dataset_event.Clients
      | Masc.Workspace_dataset_event.Account_emails | Masc.Workspace_dataset_event.Provider_usage
      | Masc.Workspace_dataset_event.Provider_standing | Masc.Workspace_dataset_event.Keeper_costs
      | Masc.Workspace_dataset_event.Workspace_health | Masc.Workspace_dataset_event.Runtime_probe
      | Masc.Workspace_dataset_event.Runtime_metrics | Masc.Workspace_dataset_event.Lanes
      | Masc.Workspace_dataset_event.Machine_live _ | Masc.Workspace_dataset_event.Browser_observation _
      | Masc.Workspace_dataset_event.Play_room _
      | Masc.Workspace_dataset_event.Play_seats | Masc.Workspace_dataset_event.World_memory
      | Masc.Workspace_dataset_event.Dashboard_observation _
      | Masc.Workspace_dataset_event.Lane_addons _ )
  | Observer.Gate_connector_changed _ | Observer.Board_changed _ | Observer.Lane_resource _
  | Observer.Snapshot _ | Observer.Execution_snapshot | Observer.Other _ ->
      "server"

(* The EVENT column's word for any event, the sibling of {!keeper_of_event}
   for the other measured column. [row_of_event] reads its label here, so the
   word has one owner and a measurement can ask for it without building the
   detail sentence that sits beside it. *)
let label_of_event ~ko (event : Observer.event) =
  let say korean english = if ko then korean else english in
  match event with
  | Observer.Agent_core e -> agent_core_label ~ko e
  | Observer.Keeper_heartbeat _ -> say "하트비트" "heartbeat"
  | Observer.Keeper_tool_call c -> (
      let skill = is_skill_tool c.Observer.kt_tool in
      match c.Observer.kt_disposition with
      | Some disposition ->
          let word =
            match disposition with
            | Ok disposition ->
                Masc.Tui_decode.keeper_call_disposition_word ~ko disposition
            | Error _ -> say "처리 결과 불명" "unknown disposition"
          in
          if skill then say "스킬 \xc2\xb7 " "skill \xc2\xb7 " ^ word else word
      | None -> if skill then say "스킬 호출" "skill call" else say "도구 호출" "tool call")
  | Observer.Keeper_turn_complete _ -> say "턴 완료" "turn done"
  | Observer.Keeper_composite_changed _ -> "composite"
  | Observer.Keeper_metrics_appended _ -> say "지표" "metrics"
  | Observer.Keeper_turn_observation _ -> say "호출" "call"
  | Observer.Keeper_chat_appended _ -> say "채팅" "chat"
  | Observer.Keeper_memory_journal_appended _ -> say "메모리" "memory"
  | Observer.Keeper_runtime_journal_appended { journal = Observer.Native_tasks_journal; _ } -> "native tasks"
  | Observer.Keeper_runtime_journal_appended { journal = Observer.Child_content_journal; _ } -> "child content"
  | Observer.Keeper_chat_stream_frame _ | Observer.Keeper_turn_stream_frame _ -> say "채팅 스트림" "chat stream"
  | Observer.Keeper_waiting_inventory_changed _ -> say "대기열" "waiting queue"
  | Observer.Keeper_async_requests_changed _ -> say "비동기 요청" "async requests"
  | Observer.Keeper_skill_activations_changed _ -> say "스킬 활성화" "skill activations"
  | Observer.Keeper_roster_change _ -> say "Keeper 목록" "roster"
  | Observer.Keeper_turn_changed { change = Observer.Turn_state; _ } -> say "턴 상태" "turns"
  | Observer.Keeper_turn_changed { change = Observer.Turn_preview; _ } -> say "미리보기" "preview"
  | Observer.Fusion_run_status _ -> say "Fusion" "fusion"
  | Observer.Lane_resource resource -> (
      match resource.Observer.lr_lifecycle with
      | Masc.Lane_addon_resource_events.Acquired -> say "리소스 확보" "resource acquired"
      | Masc.Lane_addon_resource_events.Acquire_failed -> say "확보 실패" "acquisition failed"
      | Masc.Lane_addon_resource_events.Release_confirmed -> say "리소스 반납" "resource released"
      | Masc.Lane_addon_resource_events.Release_incomplete -> say "반납 미확인" "release unconfirmed")
  | Observer.Internal_agent_runs_changed _ -> say "내부 실행" "internal runs"
  | Observer.Workspace_store_changed Observer.Schedule_store -> say "일정" "schedule"
  | Observer.Workspace_store_changed Observer.Pending_confirms -> say "확인 대기" "pending confirmation"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Verification_requests -> say "검증" "verification"
  | Observer.Workspace_store_changed Observer.Goal_projection -> say "목표" "goals"
  | Observer.Workspace_store_changed Observer.Runtime_config -> "runtime.toml"
  | Observer.Workspace_store_changed Observer.Skill_catalog -> say "스킬 카탈로그" "skill catalog"
  | Observer.Workspace_store_changed Observer.Lane_addon_exports -> say "Lane Add-on 도구" "lane add-on exports"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Repositories -> say "저장소" "repositories"
  | Observer.Gate_connector_changed _ -> say "커넥터" "connector"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Harness_verdicts -> say "하네스" "harness"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Clients -> say "클라이언트" "clients"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Account_emails -> say "계정" "accounts"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Provider_usage -> say "제공자 사용량" "provider usage"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Provider_standing -> say "제공자 상태" "provider standing"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Keeper_costs -> say "Keeper 비용" "keeper costs"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Workspace_health -> say "작업 공간 상태" "workspace health"
  | Observer.Dataset_changed
      (Masc.Workspace_dataset_event.Keeper_oauth_attempts _) -> say "로그인" "login"
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Keeper_metrics _) -> say "지표" "metrics"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Goals -> say "목표" "goals"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Runtime_config -> say "런타임 설정" "runtime config"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Connectors -> say "커넥터" "connectors"
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Skill_activations _) -> say "스킬 기록" "skill record"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Skill_catalog -> say "스킬" "skills"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Runtime_probe -> say "런타임 점검" "runtime probe"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Runtime_metrics -> say "런타임 기록" "runtime history"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Lanes -> "lanes"
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Machine_live _) -> "machine live"
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Browser_observation _) -> say "브라우저 관측" "browser observation"
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Play_room _) -> "play room"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Play_seats -> "play seats"
  | Observer.Dataset_changed Masc.Workspace_dataset_event.World_memory -> "world memory"
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Dashboard_observation _) -> say "대시보드 관측" "dashboard observation"
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Lane_addons _) -> say "Add-on" "add-ons"
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Memory_health _) -> say "메모리 상태" "memory health"
  | Observer.Keeper_event_queue_changed _ -> say "이벤트 큐" "event queue"
  | Observer.Board_changed _ -> say "보드" "board"
  | Observer.Approval_change
      ( Observer.Approval_queue_changed | Observer.Approval_rules_changed
      | Observer.Gate_mode_changed | Observer.Gate_keeper_settings_changed _ ) -> say "Gate" "gate"
  | Observer.Approval_change
      (Observer.Tool_approval_waits_changed _ | Observer.Tool_approval_mode_changed _) ->
      say "도구 승인" "tool approval"
  | Observer.Approval_change
      (Observer.Keeper_asks_changed _ | Observer.Installation_asks_changed _) ->
      say "질문" "questions"
  | Observer.Snapshot _ | Observer.Execution_snapshot -> say "스냅샷" "snapshot"
  | Observer.Other name -> name

let row_of_event ~ko ~at ~duration_ms (event : Observer.event) =
  let label = label_of_event ~ko event in
  let say korean english = if ko then korean else english in
  match event with
  | Observer.Agent_core e -> agent_core_row ~ko ~at ~duration_ms e
  | Observer.Keeper_heartbeat h ->
      { at
      ; keeper = h.Observer.hb_keeper
      ; glyph = Quiet
      ; label
      ; detail =
          (let phase = Option.value ~default:"" h.Observer.hb_phase in
           match
             (h.Observer.hb_in_turn, Option.bind h.Observer.hb_in_flight_ms elapsed_text)
           with
           | Some true, Some in_flight ->
               Printf.sprintf
                 (if ko then "%s \xc2\xb7 턴 진행 중 %s"
                  else "%s \xc2\xb7 in turn for %s")
                 phase in_flight
           | (Some true | Some false | None), (Some _ | None) -> phase)
      }
  | Observer.Keeper_tool_call c ->
      { at
      ; keeper = c.Observer.kt_keeper
      ; glyph = Call_returned
      ; label
      ; detail =
          (match Option.bind c.Observer.kt_duration_ms elapsed_text with
           | Some text -> c.Observer.kt_tool ^ " \xc2\xb7 " ^ text
           | None -> c.Observer.kt_tool)
      }
  | Observer.Keeper_turn_complete t ->
      (* Each part says only itself; the separator belongs to the join. They
         each carried a leading " \xc2\xb7 " on the reading that the turn
         ahead of them is always there to hang it off, and the turn is the
         one part that can be missing. *)
      let tokens =
        settle_tokens_text ~ko (turn_input_of_settle t, t.Observer.tc_output_tokens)
      in
      let cost =
        match t.Observer.tc_cost_usd with
        | Some usd -> Printf.sprintf "$%.4f" usd
        | None -> ""
      in
      let calls =
        match t.Observer.tc_tool_calls with
        | Some n -> calls_text ~ko n
        | None -> ""
      in
      { at
      ; keeper = t.Observer.tc_keeper
      ; glyph = Turn_done
      ; label
      ; detail =
          [ turn_detail ~ko t.Observer.tc_turn; tokens; cost; calls ]
          |> List.filter (fun part -> part <> "")
          |> String.concat " \xc2\xb7 "
      }
  | Observer.Keeper_composite_changed { keeper; _ }
  | Observer.Keeper_metrics_appended { keeper; _ } ->
      { at; keeper; glyph = Quiet; label; detail = "" }
  | Observer.Keeper_turn_observation o ->
      { at
      ; keeper = o.Observer.to_keeper
      ; glyph = Quiet
      ; label
      ; detail = turn_detail ~ko (keeper_turn_of_observation o)
      }
  | Observer.Keeper_chat_appended { keeper; connector; _ } ->
      { at
      ; keeper
      ; glyph = Turn_boundary
      ; label
      ; detail = Option.value ~default:"" connector
      }
  | Observer.Keeper_chat_stream_frame { keeper; frame; _ } ->
      { at
      ; keeper
      ; glyph = Quiet
      ; label
      ; detail = Option.value ~default:"" frame
      }
  | Observer.Keeper_turn_stream_frame { keeper; _ }
  | Observer.Keeper_memory_journal_appended { keeper; _ }
  | Observer.Keeper_runtime_journal_appended { keeper; _ }
  | Observer.Keeper_async_requests_changed { keeper }
  | Observer.Keeper_skill_activations_changed { keeper }
  | Observer.Keeper_roster_change (Observer.Keeper_row_changed { keeper })
  | Observer.Keeper_turn_changed { keeper; _ } ->
      { at; keeper; glyph = Quiet; label; detail = "" }
  | Observer.Keeper_roster_change Observer.Every_row_changed ->
      { at; keeper = "server"; glyph = Quiet; label; detail = "" }
  | Observer.Keeper_waiting_inventory_changed { keeper; queue_kind; _ } ->
      { at
      ; keeper
      ; glyph = Quiet
      ; label
      ; detail = Option.value ~default:"" queue_kind
      }
  | Observer.Fusion_run_status { keeper; run_id; status } ->
      (* Quiet: the Fusion surface is where a run is read, and it reloads
         itself on this same event. This row is the Everything-feed trace
         that a deliberation moved. The run id keeps its kmsg- prefix --
         it is what Ctrl-] would jump on. *)
      { at
      ; keeper
      ; glyph = Quiet
      ; label
      ; detail = status ^ " \xc2\xb7 " ^ run_id
      }
  | Observer.Lane_resource resource ->
      let glyph =
        match resource.Observer.lr_lifecycle with
        | Masc.Lane_addon_resource_events.Acquired -> Quiet
        | Masc.Lane_addon_resource_events.Acquire_failed -> Failure
        | Masc.Lane_addon_resource_events.Release_confirmed -> Quiet
        | Masc.Lane_addon_resource_events.Release_incomplete -> Failure
      in
      (* The package says which add-on; the reason is the server's own words,
         and it is the part a failure row exists to carry. *)
      let detail =
        match resource.Observer.lr_detail with
        | Some reason -> resource.Observer.lr_package ^ " \xc2\xb7 " ^ reason
        | None -> resource.Observer.lr_package
      in
      { at; keeper = "server"; glyph; label; detail }
  | Observer.Internal_agent_runs_changed registry ->
      { at
      ; keeper = "server"
      ; glyph = Quiet
      ; label
      ; detail =
          (let name = Masc.Internal_agent_runs_event.registry_to_wire registry in
           if ko then name ^ " 실행 목록이 바뀜"
           else "the " ^ name ^ " run registry changed")
      }
  | Observer.Workspace_store_changed Observer.Schedule_store ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "일정 상태가 바뀌었을 수 있음" "schedule status may have changed" }
  | Observer.Workspace_store_changed Observer.Pending_confirms ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "확인 대기 상태가 바뀌었을 수 있음" "pending confirmation status may have changed" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Verification_requests ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "검증 요청이 바뀜" "a verification request changed" }
  | Observer.Workspace_store_changed Observer.Goal_projection ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "목표가 바뀜" "a Goal changed" }
  | Observer.Workspace_store_changed Observer.Runtime_config ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "runtime.toml 이 바뀜" "runtime.toml changed" }
  | Observer.Workspace_store_changed Observer.Skill_catalog ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "스킬 카탈로그가 게시됨" "the skill catalog was published" }
  | Observer.Workspace_store_changed Observer.Lane_addon_exports ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "Lane Add-on 이 내보내는 도구가 바뀜" "a Lane Add-on's exported tools changed" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Repositories ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "저장소 목록이 바뀜" "the repository catalog changed" }
  | Observer.Gate_connector_changed { connector } ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "커넥터 " "connector " ^ connector ^ say " 바뀜" " changed" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Harness_verdicts ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "판정이나 라벨이 기록됨" "a judge verdict or label was recorded" }
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Keeper_oauth_attempts { keeper }) ->
      { at; keeper; glyph = Quiet; label; detail = say "OAuth 로그인 시도가 바뀜" "an OAuth login attempt changed" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Clients ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "작업 공간 클라이언트 항목이 바뀜" "a workspace client row changed" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Account_emails ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "로그인이 계정 자격 증명을 다시 씀" "a login rewrote the account credentials" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Provider_usage ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "제공자 사용량 보고가 기록됨" "a provider usage report was recorded" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Provider_standing ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "런타임의 한도나 속도 제한 상태가 바뀜" "a runtime's quota or rate-limit standing changed" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Keeper_costs ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "Keeper 비용 구간에 줄이 들어오거나 빠짐" "the Keeper cost window took or dropped a row" }
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Keeper_metrics { keeper }) ->
      { at; keeper; glyph = Quiet; label; detail = say "지표 기록에 줄이 들어옴" "the metrics ledger took a row" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Goals ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "목표 목록이 바뀜" "the Goal projection changed" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Runtime_config ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "runtime.toml 저장을 시도함" "a runtime.toml commit was attempted" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Connectors ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "커넥터 상태가 바뀜" "a connector's status changed" }
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Skill_activations { keeper }) ->
      { at; keeper; glyph = Quiet; label; detail = say "스킬 활성화 기록에 줄이 들어옴" "the Skill activation ledger took a row" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Skill_catalog ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "스킬 카탈로그 스냅샷이 게시됨" "a Skill catalog snapshot was published" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Workspace_health ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "Home Health 줄이 바뀜" "the Home Health line moved" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Runtime_probe ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "런타임 점검 결과가 들어옴" "a runtime probe landed" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Runtime_metrics ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "런타임 기록에 줄이 들어오거나 빠짐" "the runtime history took or dropped a row" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Lanes ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "Lane 목록이 바뀜" "the Lane inventory changed" }
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Machine_live { machine }) ->
      { at; keeper = "server"; glyph = Quiet; label; detail = Masc.Machine_lane.to_wire machine }
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Browser_observation { scope; _ }) ->
      { at; keeper = "server"; glyph = Quiet; label; detail = Printf.sprintf "%s/%d"
          (Browser_lane.Lane_name.to_wire scope.source) scope.tab_id }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.Play_seats ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "Play seat 권한이 바뀜" "Play seat authority changed" }
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Dashboard_observation _) ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "웹 대시보드 관측이 바뀜" "a web dashboard observation changed" }
  | Observer.Dataset_changed Masc.Workspace_dataset_event.World_memory ->
      { at; keeper = "server"; glyph = Quiet; label; detail = say "작업 공간 메모리 목록이 바뀜" "the workspace memory inventory changed" }
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Play_room { machine }) ->
      { at; keeper = "server"; glyph = Quiet; label; detail = Masc.Machine_lane.to_wire machine }
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Lane_addons { instance_id }) ->
      { at; keeper = "server"; glyph = Quiet; label; detail = instance_id }
  | Observer.Dataset_changed (Masc.Workspace_dataset_event.Memory_health { keeper }) ->
      { at; keeper; glyph = Quiet; label; detail = say "메모리 상태 입력이 기록됨" "a memory health input was written" }
  | Observer.Keeper_event_queue_changed { keeper } ->
      { at; keeper; glyph = Quiet; label; detail = say "이벤트 큐가 바뀜" "the event queue changed" }
  | Observer.Board_changed { post_id } ->
      { at
      ; keeper = "server"
      ; glyph = Quiet
      ; label
      ; detail = Option.value post_id ~default:(say "댓글이나 반응이 바뀜" "a comment or a reaction changed")
      }
  | Observer.Approval_change change ->
      let detail =
        match change with
        | Observer.Approval_queue_changed -> say "승인 대기열이 바뀜" "the approval queue changed"
        | Observer.Approval_rules_changed -> say "항상 허용 규칙이 바뀜" "the standing rules changed"
        | Observer.Gate_mode_changed -> say "Gate 모드가 바뀜" "a Gate mode changed"
        | Observer.Gate_keeper_settings_changed _ -> say "Keeper 의 Gate 설정이 바뀜" "the Keeper's Gate settings changed"
        | Observer.Tool_approval_waits_changed _ -> say "보류된 도구 호출이 바뀜" "a held tool call changed"
        | Observer.Tool_approval_mode_changed _ -> say "도구 승인 모드가 바뀜" "the tool approval mode changed"
        | Observer.Keeper_asks_changed _ -> say "Keeper 의 질문이 바뀜" "the Keeper's questions changed"
        | Observer.Installation_asks_changed { declaration_id } ->
            if ko then declaration_id ^ " 의 질문이 바뀜"
            else "the questions of " ^ declaration_id ^ " changed"
      in
      { at; keeper = approval_change_keeper change; glyph = Quiet; label; detail }
  | Observer.Snapshot projection ->
      { at; keeper = "server"; glyph = Quiet; label; detail = Observer.projection_name projection }
  | Observer.Execution_snapshot ->
      { at; keeper = "server"; glyph = Quiet; label
      ; detail = Masc.Dashboard_event_slices.execution_snapshot_type }
  | Observer.Other _ ->
      { at; keeper = "server"; glyph = Attention; label; detail = "" }

(* The screen draws entries, not bare events. Taking the entry means there is
   no clock argument at the call site to hand in the wrong value. *)
let row_of_entry ~ko ~duration_ms entry =
  row_of_event ~ko ~at:entry.ae_at ~duration_ms entry.ae_event

(* The row the flat scopes draw, under the keeper who acted rather than the
   agent name the feed gave. [measured_of_event] reads the same keeper, so
   the one rule that renames an agent_core lane lives here beside it instead
   of in the renderer. *)
let keeper_row_of_entry ~ko ~traces ~duration_ms entry =
  { (row_of_entry ~ko ~duration_ms entry) with
    keeper = keeper_of_event ~traces entry.ae_event
  }

(* ── Turn chunks ────────────────────────────────────────────────────────
   [Turns] draws one row per keeper turn instead of the up-to-seven
   lifecycle rows a single tool call produces across the two reporting
   planes (agent-core wire: ready / start / call / returned / end; keeper
   ledger: completed / settled). The fold is a display projection only:
   nothing is stored, and events that are not part of a turn's lifecycle
   pass through as the rows they already were -- when [visible Turns]
   shows them at all; what the scope hides stays hidden.

   Attribution: a chunk is one keeper turn. The wire and ledger members state
   the agent session's ordinal for their provider call; a settle states the
   keeper turn; a turn observation names both, and {!fold_chunks} files each
   member through them. A member whose call no retained observation names
   is filed by its ordinal and the keeper's open turn, which can misfile a
   row across a session restart. A member that states no ordinal at all (a
   ledger row from the runtime MCP path) joins the keeper's newest chunk,
   settled or not, so it lands on the turn before its own once that turn has
   settled. Both are display blemishes, never stored facts. *)

type chunk_tool = {
  ct_tool : string;
  ct_duration_ms : float option;
  ct_at : float;
  ct_tool_use_id : string option;
  ct_session_turn : int option;
  ct_disposition : (Masc.Tui_decode.keeper_call_disposition, string) result option;
  ct_schedule : (Agent_core.Tool_contract.schedule, string) result option;
  ct_input : string option;
  ct_output : string option;
}

type call_key =
  | Call_by_id of string
  | Call_by_receipt of { at : float; tool : string }

let call_key tool =
  match tool.ct_tool_use_id with
  | Some id -> Call_by_id id
  | None -> Call_by_receipt { at = tool.ct_at; tool = tool.ct_tool }

let call_key_equal a b =
  match a, b with
  | Call_by_id a, Call_by_id b -> String.equal a b
  | Call_by_receipt a, Call_by_receipt b ->
      Float.equal a.at b.at && String.equal a.tool b.tool
  | Call_by_id _, Call_by_receipt _ | Call_by_receipt _, Call_by_id _ -> false

(* A wire-plane call keeps its start and id so its return can settle the
   duration in place; the tool is on screen from the call, not from the
   return — a running turn names what it is doing right now. *)
type wire_tool = {
  wt_id : string option;
  wt_started : float;
  wt_tool : string;
  wt_duration_ms : float option;
  wt_session_turn : int option;
}

(* The turn marker the agent-core loop last sent for this record: a
   provider call was asked for, started, or came back. The pane reads the
   newest one to say whether the model has the turn right now. *)
type turn_marker =
  | Marker_ready
  | Marker_started
  | Marker_completed

type chunk = {
  ck_keeper : string;
  ck_turn : int option;
  ck_session_turns : int list;
  ck_at : float;  (** newest member's arrival — the chunk's feed position *)
  ck_wire_tools : wire_tool list;  (** oldest-first, from the agent-core wire *)
  ck_ledger_tools : chunk_tool list;  (** oldest-first, from the keeper ledger *)
  ck_settled : bool;
  ck_marker : (turn_marker * float) option;
  ck_tokens : turn_input option * int option;
  ck_cost_usd : float option;
  ck_calls : int option;
}

type chunk_member =
  | Member_turn_marker of { marker : turn_marker; turn : int option }
  | Member_wire_call of {
      tool : string;
      tool_use_id : string option;
      turn : int option;
    }
  | Member_wire_return of {
      tool : string;
      tool_use_id : string option;
      turn : int option;
    }
  | Member_ledger_tool of {
      tool : string;
      duration_ms : float option;
      turn : int option;
      tool_use_id : string option;
      disposition : (Masc.Tui_decode.keeper_call_disposition, string) result option;
      schedule : (Agent_core.Tool_contract.schedule, string) result option;
      input : string option;
      output : string option;
    }
  | Member_settle of Observer.keeper_turn_complete
  | Member_quiet

(* Which events fold into a chunk. Internal agent runs (Agent_started and
   friends) and approvals stay standalone: they are not keeper-turn
   lifecycle, and a reader scanning for them should not find them buried
   inside a turn row. *)
let member_of_event (event : Observer.event) =
  match event with
  | Observer.Agent_core e -> (
      match e.Observer.kind with
      | Observer.Turn_ready ->
          Some (Member_turn_marker { marker = Marker_ready; turn = e.Observer.turn })
      | Observer.Turn_started ->
          Some (Member_turn_marker { marker = Marker_started; turn = e.Observer.turn })
      | Observer.Turn_completed ->
          Some (Member_turn_marker { marker = Marker_completed; turn = e.Observer.turn })
      | Observer.Tool_called ->
          Some
            (Member_wire_call
               { tool = Option.value ~default:Masc_tui_theme.Glyph.no_value e.Observer.tool
               ; tool_use_id = e.Observer.tool_use_id
               ; turn = e.Observer.turn
               })
      | Observer.Tool_completed ->
          Some
            (Member_wire_return
               { tool = Option.value ~default:Masc_tui_theme.Glyph.no_value e.Observer.tool
               ; tool_use_id = e.Observer.tool_use_id
               ; turn = e.Observer.turn
               })
      | Observer.Telemetry -> Some Member_quiet
      | Observer.Agent_started | Observer.Agent_completed _
      | Observer.Agent_failed _ | Observer.Agent_yielded _
      | Observer.Agent_input_required _
      | Observer.Tool_approval_completed | Observer.Relay_subscription_loss _
      | Observer.Agent_core_other _ ->
          None)
  | Observer.Keeper_tool_call c ->
      Some
        (Member_ledger_tool
           { tool = c.Observer.kt_tool
           ; duration_ms = c.Observer.kt_duration_ms
           ; turn = c.Observer.kt_turn
           ; tool_use_id = c.Observer.kt_tool_use_id
           ; disposition = c.Observer.kt_disposition
           ; schedule = c.Observer.kt_schedule
           ; input = c.Observer.kt_tool_args_preview
           ; output = c.Observer.kt_tool_output_preview
           })
  | Observer.Keeper_turn_complete t -> Some (Member_settle t)
  (* Identity for the fold's session table, read before members are filed
     ([fold_chunks]); not a member itself. *)
  | Observer.Keeper_turn_observation _
  | Observer.Keeper_heartbeat _ | Observer.Keeper_composite_changed _ | Observer.Keeper_metrics_appended _
  | Observer.Keeper_chat_appended _ | Observer.Keeper_memory_journal_appended _ | Observer.Keeper_runtime_journal_appended _
  | Observer.Keeper_chat_stream_frame _ | Observer.Keeper_turn_stream_frame _
  | Observer.Keeper_waiting_inventory_changed _ | Observer.Keeper_async_requests_changed _ | Observer.Keeper_skill_activations_changed _ | Observer.Keeper_roster_change _ | Observer.Keeper_turn_changed _ | Observer.Snapshot _ | Observer.Execution_snapshot
  | Observer.Fusion_run_status _ | Observer.Internal_agent_runs_changed _ | Observer.Workspace_store_changed _ | Observer.Dataset_changed _ | Observer.Gate_connector_changed _ | Observer.Keeper_event_queue_changed _ | Observer.Board_changed _ | Observer.Approval_change _
  | Observer.Lane_resource _ | Observer.Other _ ->
      None

let empty_chunk ~keeper ~at =
  { ck_keeper = keeper
  ; ck_turn = None
  ; ck_session_turns = []
  ; ck_at = at
  ; ck_wire_tools = []
  ; ck_ledger_tools = []
  ; ck_settled = false
  ; ck_marker = None
  ; ck_tokens = (None, None)
  ; ck_cost_usd = None
  ; ck_calls = None
  }

let apply_member chunk ~at member =
  let chunk = { chunk with ck_at = Float.max chunk.ck_at at } in
  match member with
  | Member_quiet -> chunk
  | Member_turn_marker { marker; turn = _ } -> { chunk with ck_marker = Some (marker, at) }
  | Member_wire_call { tool; tool_use_id; turn } ->
      { chunk with
        ck_wire_tools =
          chunk.ck_wire_tools
          @ [ { wt_id = tool_use_id
              ; wt_started = at
              ; wt_tool = tool
              ; wt_duration_ms = None
              ; wt_session_turn = turn
              }
            ]
      }
  | Member_wire_return { tool; tool_use_id; turn } ->
      (* Settle the newest still-open call with this id in place; a return
         whose call was never held (the feed opened mid-turn) appends with
         no duration rather than being dropped. *)
      let settled = ref false in
      let settle_in_place =
        List.rev_map
          (fun wt ->
            if
              (not !settled)
              && Option.is_none wt.wt_duration_ms
              && Option.equal String.equal wt.wt_id tool_use_id
              && Option.is_some tool_use_id
            then begin
              settled := true;
              { wt with wt_duration_ms = Some ((at -. wt.wt_started) *. 1000.) }
            end
            else wt)
          (List.rev chunk.ck_wire_tools)
      in
      let ck_wire_tools =
        if !settled then settle_in_place
        else
          chunk.ck_wire_tools
          @ [ { wt_id = tool_use_id
              ; wt_started = at
              ; wt_tool = tool
              ; wt_duration_ms = None
              ; wt_session_turn = turn
              }
            ]
      in
      { chunk with ck_wire_tools }
  | Member_ledger_tool
      { tool; duration_ms; turn; tool_use_id; disposition; schedule; input; output } ->
      { chunk with
        ck_ledger_tools =
          chunk.ck_ledger_tools
          @ [ { ct_tool = tool
              ; ct_duration_ms = duration_ms
              ; ct_at = at
              ; ct_tool_use_id = tool_use_id
              ; ct_session_turn = turn
              ; ct_disposition = disposition
              ; ct_schedule = schedule
              ; ct_input = input
              ; ct_output = output
              }
            ]
      }
  | Member_settle t ->
      let ck_turn =
        match t.Observer.tc_turn with Some _ as n -> n | None -> chunk.ck_turn
      in
      { chunk with
        ck_turn
      ; ck_settled = true
      ; ck_tokens = (turn_input_of_settle t, t.Observer.tc_output_tokens)
      ; ck_cost_usd = t.Observer.tc_cost_usd
      ; ck_calls = t.Observer.tc_tool_calls
      }

let chunk_tools_text tools =
  tools
  |> List.map (fun { ct_tool; ct_duration_ms; _ } ->
      match Option.bind ct_duration_ms elapsed_text with
      | Some text -> ct_tool ^ " " ^ text
      | None -> ct_tool)
  |> String.concat " \xc2\xb7 "

(* The ledger is the authority when it reported at all; the wire list only
   stands in for runtimes whose ledger plane is silent. A wire call has no
   disposition, schedule or I/O to stand in with: those are the ledger's. *)
let chunk_tools chunk =
  match chunk.ck_ledger_tools with
  | [] ->
      List.map
        (fun wt ->
          { ct_tool = wt.wt_tool
          ; ct_duration_ms = wt.wt_duration_ms
          ; ct_at = wt.wt_started
          ; ct_tool_use_id = wt.wt_id
          ; ct_session_turn = wt.wt_session_turn
          ; ct_disposition = None
          ; ct_schedule = None
          ; ct_input = None
          ; ct_output = None
          })
        chunk.ck_wire_tools
  | l -> l

let row_of_chunk ~ko chunk =
  let tools = chunk_tools chunk in
  let tools_text = chunk_tools_text tools in
  let tokens =
    match chunk.ck_tokens with
    | None, None -> ""
    | ((Some _, (Some _ | None)) | (None, Some _)) as tokens ->
        " \xc2\xb7 " ^ settle_tokens_text ~ko tokens
  in
  let cost =
    match chunk.ck_cost_usd with
    | Some usd -> Printf.sprintf " \xc2\xb7 $%.4f" usd
    | None -> ""
  in
  let calls =
    (* Only when no tool is listed by name: a count next to the list would
       say the same thing twice. *)
    match (tools, chunk.ck_calls) with
    | [], Some n when n > 0 -> calls_text ~ko n
    | _, (Some _ | None) -> ""
  in
  let detail =
    if chunk.ck_settled then
      let body = if tools_text = "" then calls else tools_text in
      let body = if body = "" then (if ko then "호출 없음" else "no calls") else body in
      body ^ tokens ^ cost
    else if tools_text = "" then (if ko then "실행 중" else "running")
    else tools_text
  in
  { at = chunk.ck_at
  ; keeper = chunk.ck_keeper
  ; glyph = (if chunk.ck_settled then Turn_done else Call_started)
  ; label = turn_label ~ko chunk.ck_turn
  ; detail
  }

(* Only observations feed the session table; every other event is listed
   so a new event kind has to say which side it is on. *)
let observation_of_event (event : Observer.event) =
  match event with
  | Observer.Keeper_turn_observation o -> Some o
  | Observer.Agent_core _ | Observer.Keeper_heartbeat _
  | Observer.Keeper_tool_call _ | Observer.Keeper_turn_complete _
  | Observer.Keeper_composite_changed _ | Observer.Keeper_metrics_appended _ | Observer.Keeper_chat_appended _
  | Observer.Keeper_memory_journal_appended _ | Observer.Keeper_runtime_journal_appended _
  | Observer.Keeper_chat_stream_frame _ | Observer.Keeper_turn_stream_frame _
  | Observer.Keeper_waiting_inventory_changed _ | Observer.Keeper_async_requests_changed _ | Observer.Keeper_skill_activations_changed _ | Observer.Keeper_roster_change _ | Observer.Keeper_turn_changed _
  | Observer.Fusion_run_status _ | Observer.Internal_agent_runs_changed _ | Observer.Workspace_store_changed _ | Observer.Dataset_changed _ | Observer.Gate_connector_changed _ | Observer.Keeper_event_queue_changed _ | Observer.Board_changed _ | Observer.Approval_change _
  | Observer.Lane_resource _ | Observer.Snapshot _ | Observer.Execution_snapshot | Observer.Other _ ->
      None

(* The agent session's ordinal a member states, if it states one. *)
let session_of_member = function
  | Member_turn_marker { turn; _ } -> turn
  | Member_wire_call { turn; _ } | Member_wire_return { turn; _ }
  | Member_ledger_tool { turn; _ } ->
      turn
  | Member_settle _ | Member_quiet -> None

(* Replace the newest chunk [fits] accepts with [apply] of it. *)
let attach ~fits ~apply chunks =
  let rec go acc = function
    | chunk :: rest when fits chunk ->
        Some (List.rev_append acc (apply chunk :: rest))
    | chunk :: rest -> go (chunk :: acc) rest
    | [] -> None
  in
  go [] chunks

(* File one member into a keeper's chunks, held newest first.

   [keeper_turn] is the member's keeper turn when known -- a settle carries
   it, a session-numbered member gets it from the observation table -- and
   [session] is the agent session's ordinal the member states. The first
   rule that finds a chunk wins; otherwise the member opens one, telemetry
   excepted.

   - A settle joins the chunk with its number, else the newest chunk if that
     one is unsettled; [apply_member] then stamps the settle's number on it.
   - A wire or ledger member with a keeper turn joins the chunk with that
     number, else the newest chunk if it is unsettled and still unnumbered.
   - A wire or ledger member with only an ordinal joins the newest chunk that
     already holds the ordinal; else the newest chunk if it holds no ordinal
     yet, settled or not (a settle that landed before its turn's wire
     replay); else the newest chunk if it is unsettled and numbered -- a
     keeper runs one turn at a time, and the call in flight has no
     observation until its response is collected.
   - A member stating neither lands on the newest chunk.
   - Telemetry only refreshes the newest chunk: a keeper the feed knows
     nothing else about gains no row from it (#32208). *)
let file_member ~existing ~keeper ~at ~session ~keeper_turn member =
  let absorb chunk =
    let chunk = apply_member chunk ~at member in
    let chunk =
      match session with
      | Some ordinal when not (List.mem ordinal chunk.ck_session_turns) ->
          { chunk with ck_session_turns = chunk.ck_session_turns @ [ ordinal ] }
      | Some _ | None -> chunk
    in
    match (chunk.ck_turn, keeper_turn) with
    | None, Some turn -> { chunk with ck_turn = Some turn }
    | Some _, (Some _ | None) | None, None -> chunk
  in
  let by_keeper_turn () =
    match keeper_turn with
    | Some turn -> attach ~fits:(fun c -> c.ck_turn = Some turn) ~apply:absorb existing
    | None -> None
  in
  let by_session () =
    match session with
    | Some ordinal ->
        attach ~fits:(fun c -> List.mem ordinal c.ck_session_turns) ~apply:absorb existing
    | None -> None
  in
  let on_newest fits () =
    match existing with
    | chunk :: rest when fits chunk -> Some (absorb chunk :: rest)
    | _ :: _ | [] -> None
  in
  let opened () = absorb (empty_chunk ~keeper ~at) :: existing in
  let first_of candidates ~otherwise =
    match List.find_map (fun candidate -> candidate ()) candidates with
    | Some chunks -> chunks
    | None -> otherwise ()
  in
  match member with
  | Member_quiet ->
      first_of [ on_newest (fun _ -> true) ] ~otherwise:(fun () -> existing)
  | Member_settle _ ->
      first_of
        [ by_keeper_turn; on_newest (fun c -> not c.ck_settled) ]
        ~otherwise:opened
  | Member_turn_marker _ | Member_wire_call _ | Member_wire_return _
  | Member_ledger_tool _ -> (
      match (keeper_turn, session) with
      | Some _, (Some _ | None) ->
          first_of
            [ by_keeper_turn
            ; on_newest (fun c -> (not c.ck_settled) && c.ck_turn = None)
            ]
            ~otherwise:opened
      | None, Some _ ->
          first_of
            [ by_session
            ; on_newest (fun c -> c.ck_session_turns = [])
            ; on_newest (fun c -> (not c.ck_settled) && Option.is_some c.ck_turn)
            ]
            ~otherwise:opened
      | None, None -> first_of [ on_newest (fun _ -> true) ] ~otherwise:opened)

(* Fold entries (held newest-first) into chunk and pass-through rows.

   One keeper turn is several provider calls. The agent-core wire and the
   keeper ledger number their frames by the call (the agent session's
   ordinal) while a settle numbers the turn from the keeper's lifetime, so
   the two could only meet by guesswork until the hook's per-call
   observation named both. The first pass reads every observation in the
   ring into a (keeper, ordinal) table of (feed position, keeper turn); the
   second files each member through {!file_member}.

   An agent session created without a checkpoint numbers its calls from
   zero again, so one keeper can observe the same ordinal twice in the ring.
   A member takes the observation nearest to it in feed position, which is
   the right one while a call's frames sit nearer their own observation than
   another session's observation of the same ordinal. On the agent-core loop
   they sit right around it: the call's turn markers just before, its tools
   just after. A CLI lane runs a whole keeper turn as one call, so every
   frame of the turn comes before the observation, and a frame from early in
   a long lane turn can sit nearer an older session's observation. A frame
   that lands long after its observation -- a slow tool's return, or one the
   relay held -- can sit nearer the next session's. Either way it is filed
   under the other session's turn.

   [traces] resolves agent-core correlation ids to keeper names, exactly as
   the flat view does. The ring holds up to [acting_retained_entries] +
   [acting_retained_quiet] entries and this runs on every frame, so chunks live in a per-keeper table:
   attaching costs the keeper's own chunk count, not the whole screen. *)
(* What a lane worker row folds on under [Turns]: the same package ending
   the same way for the same reason is one row, however many times it
   happened. Every other event is listed so a new kind has to say which side
   it is on. *)
let lane_fold_key (event : Observer.event) =
  match event with
  | Observer.Lane_resource r ->
      Some (r.Observer.lr_package, r.Observer.lr_lifecycle, r.Observer.lr_detail)
  | Observer.Agent_core _ | Observer.Keeper_heartbeat _
  | Observer.Keeper_tool_call _ | Observer.Keeper_turn_complete _
  | Observer.Keeper_turn_observation _ | Observer.Keeper_composite_changed _ | Observer.Keeper_metrics_appended _
  | Observer.Keeper_chat_appended _ | Observer.Keeper_memory_journal_appended _ | Observer.Keeper_runtime_journal_appended _
  | Observer.Keeper_chat_stream_frame _ | Observer.Keeper_turn_stream_frame _
  | Observer.Keeper_waiting_inventory_changed _ | Observer.Keeper_async_requests_changed _ | Observer.Keeper_skill_activations_changed _ | Observer.Keeper_roster_change _ | Observer.Keeper_turn_changed _ | Observer.Fusion_run_status _
  | Observer.Internal_agent_runs_changed _ | Observer.Workspace_store_changed _ | Observer.Dataset_changed _ | Observer.Gate_connector_changed _ | Observer.Keeper_event_queue_changed _ | Observer.Board_changed _ | Observer.Approval_change _ | Observer.Snapshot _ | Observer.Execution_snapshot
  | Observer.Other _ ->
      None

(* The newest occurrence's row, with how many the screen holds in front of
   the detail -- at the end it would be the first thing a long reason cuts. *)
let folded_lane_row ~ko ~count entry =
  let row = row_of_entry ~ko ~duration_ms:None entry in
  if count = 1 then row
  else { row with detail = Printf.sprintf "\xc3\x97%d %s" count row.detail }

(* What the fold leaves outside every chunk, held as what it is until
   [chunk_rows] chooses its words. [chunks] reads the same fold for the
   Activity pane and drops these, so the fold itself has no language. *)
type plain =
  | Plain_entry of entry
  | Folded_lane of { count : int; newest : entry }

let fold_chunks ~traces entries =
  let oldest_first = List.rev entries in
  let observed : (string * int, (int * int) list) Hashtbl.t = Hashtbl.create 64 in
  List.iteri
    (fun position entry ->
      match observation_of_event entry.ae_event with
      | Some o -> (
          match (o.Observer.to_session_turn, keeper_turn_of_observation o) with
          | Some ordinal, Some turn ->
              let key = (o.Observer.to_keeper, ordinal) in
              let held =
                match Hashtbl.find_opt observed key with
                | Some held -> held
                | None -> []
              in
              Hashtbl.replace observed key ((position, turn) :: held)
          | None, (Some _ | None) | Some _, None -> ())
      | None -> ())
    oldest_first;
  let keeper_turn_near ~keeper ~ordinal ~position =
    match Hashtbl.find_opt observed (keeper, ordinal) with
    | None -> None
    | Some held ->
        List.fold_left
          (fun nearest (at, turn) ->
            let distance = abs (at - position) in
            match nearest with
            | Some (nearest_distance, _) when nearest_distance <= distance -> nearest
            | Some _ | None -> Some (distance, turn))
          None held
        |> Option.map snd
  in
  let chunks : (string, chunk list) Hashtbl.t = Hashtbl.create 16 in
  let plains = ref [] in
  (* A lane worker that keeps failing the same way fails once a few
     seconds; one row per failure would bury the turns this scope is for, the
     way one row per lifecycle event would bury a turn. Folded like a turn:
     the newest occurrence stands for the rest. *)
  let lane_folds = Hashtbl.create 4 in
  List.iteri
    (fun position entry ->
      let event = entry.ae_event in
      let at = entry.ae_at in
      match member_of_event event with
      | None -> (
          (* A non-member passes through as its own row only if the Turns
             scope shows it at all. Without this test the fold readmitted
             everything [visible Turns] hides -- composite pushes, heartbeats,
             stream frames, waiting-queue changes -- and a live screen showed
             them outnumbering the turn rows it promised (2026-09-01, 128
             rows). *)
          match (visible Turns event, lane_fold_key event) with
          | false, (Some _ | None) -> ()
          | true, Some key ->
              let count =
                match Hashtbl.find_opt lane_folds key with
                | Some (_, held) -> held + 1
                | None -> 1
              in
              Hashtbl.replace lane_folds key (entry, count)
          | true, None ->
              plains :=
                (entry.ae_at, Plain_entry entry) :: !plains)
      | Some member ->
          let keeper = keeper_of_event ~traces event in
          let session = session_of_member member in
          let keeper_turn =
            match member with
            | Member_settle t -> t.Observer.tc_turn
            | Member_turn_marker _ | Member_wire_call _ | Member_wire_return _
            | Member_ledger_tool _ | Member_quiet -> (
                match session with
                | Some ordinal -> keeper_turn_near ~keeper ~ordinal ~position
                | None -> None)
          in
          let existing =
            match Hashtbl.find_opt chunks keeper with
            | Some held -> held
            | None -> []
          in
          Hashtbl.replace chunks keeper
            (file_member ~existing ~keeper ~at ~session ~keeper_turn member))
    oldest_first;
  Hashtbl.iter
    (fun _ (entry, count) ->
      plains := (entry.ae_at, Folded_lane { count; newest = entry }) :: !plains)
    lane_folds;
  (chunks, !plains)

(* Every keeper's turns as data, newest activity first. The Activity pane
   draws the same fold the [Turns] rows draw, keyed by keeper, so the two
   cannot disagree about which turn is current. *)
let chunks ~traces entries =
  let chunks, _plains = fold_chunks ~traces entries in
  Hashtbl.fold (fun _ keeper_chunks acc -> keeper_chunks @ acc) chunks []
  |> List.stable_sort (fun a b -> Float.compare b.ck_at a.ck_at)

type chunk_projection = {
  source_entries : entry list;
  source_traces : (string * string) list;
  projected_chunks : chunk list;
}

let refresh_projection ~previous ~traces entries =
  let same_trace (keeper, trace) (other_keeper, other_trace) =
    String.equal keeper other_keeper && String.equal trace other_trace
  in
  match previous with
  | Some projection
    when projection.source_entries == entries
      && List.equal same_trace projection.source_traces traces -> projection
  | _ ->
    { source_entries = entries; source_traces = traces;
      projected_chunks = chunks ~traces entries }

let projection_chunks projection = projection.projected_chunks

let chunk_rows ~ko ~traces entries =
  let chunks, plains = fold_chunks ~traces entries in
  let plains =
    List.map
      (fun (at, plain) ->
        ( at
        , match plain with
          | Plain_entry entry -> keeper_row_of_entry ~ko ~traces ~duration_ms:None entry
          | Folded_lane { count; newest } -> folded_lane_row ~ko ~count newest ))
      plains
  in
  let chunk_rows =
    Hashtbl.fold
      (fun _ keeper_chunks acc ->
        List.fold_left
          (fun acc chunk -> (chunk.ck_at, row_of_chunk ~ko chunk) :: acc)
          acc keeper_chunks)
      chunks []
  in
  (* Latest activity first, so a long-running turn surfaces when it moves. *)
  chunk_rows @ plains
  |> List.stable_sort (fun (a, _) (b, _) -> Float.compare b a)
  |> List.map snd

let duration_of_completion ~before (completed : Observer.agent_core) =
  match completed.Observer.tool_use_id with
  | None -> None
  | Some id ->
      List.find_map
        (fun (event : Observer.event) ->
          match event with
          | Observer.Agent_core
              { Observer.kind = Observer.Tool_called
              ; tool_use_id = Some started_id
              ; agent
              ; at
              ; _
              }
            when String.equal started_id id
                 && Option.equal String.equal agent completed.Observer.agent ->
              Some ((completed.Observer.at -. at) *. 1000.)
          | Observer.Agent_core
              { Observer.kind =
                  ( Observer.Tool_called | Observer.Tool_completed
                  | Observer.Turn_started | Observer.Turn_ready
                  | Observer.Turn_completed | Observer.Agent_started
                  | Observer.Agent_completed _ | Observer.Agent_failed _
                  | Observer.Agent_yielded _ | Observer.Agent_input_required _
                  | Observer.Tool_approval_completed | Observer.Telemetry
                  | Observer.Relay_subscription_loss _
                  | Observer.Agent_core_other _ )
              ; _
              }
          | Observer.Keeper_heartbeat _
          | Observer.Keeper_tool_call _ | Observer.Keeper_turn_complete _
          | Observer.Keeper_turn_observation _
          | Observer.Keeper_composite_changed _ | Observer.Keeper_metrics_appended _ | Observer.Keeper_chat_appended _
          | Observer.Keeper_memory_journal_appended _ | Observer.Keeper_runtime_journal_appended _
          | Observer.Keeper_chat_stream_frame _ | Observer.Keeper_turn_stream_frame _
          | Observer.Keeper_waiting_inventory_changed _ | Observer.Keeper_async_requests_changed _ | Observer.Keeper_skill_activations_changed _ | Observer.Keeper_roster_change _ | Observer.Keeper_turn_changed _
          | Observer.Fusion_run_status _ | Observer.Internal_agent_runs_changed _ | Observer.Workspace_store_changed _ | Observer.Dataset_changed _ | Observer.Gate_connector_changed _ | Observer.Keeper_event_queue_changed _ | Observer.Board_changed _ | Observer.Approval_change _
          | Observer.Lane_resource _ | Observer.Snapshot _ | Observer.Execution_snapshot | Observer.Other _ ->
              None)
        before

let evidence_fields ~ko (entry : entry) =
  let say korean english = if ko then korean else english in
  let field label value = label, value in
  let some label value = field label (Some value) in
  let number label value = field label (Option.map string_of_int value) in
  match entry.ae_event with
  | Observer.Agent_core e ->
      let kind = match e.kind with
        | Tool_called -> "tool_called" | Tool_completed -> "tool_completed"
        | Turn_started -> "turn_started" | Turn_ready -> "turn_ready"
        | Turn_completed -> "turn_completed" | Agent_started -> "agent_started"
        | Agent_completed _ -> "agent_completed" | Agent_failed _ -> "agent_failed"
        | Agent_yielded _ -> "agent_yielded"
        | Agent_input_required _ -> "agent_input_required"
        | Tool_approval_completed -> "tool_approval_completed"
        | Telemetry -> "telemetry_event"
        | Relay_subscription_loss _ -> Masc.Keeper_event_bridge.subscription_loss_event_type
        | Agent_core_other name -> name in
      [ some (say "출처" "Source") (say "런타임 관찰 이벤트" "runtime observer event")
      ; some (say "이벤트 종류" "Event kind") kind
      ; field (say "도구 이름" "Tool name") e.tool
      ; field "Tool use ID" e.tool_use_id
      ; field "Execution ID" e.execution_id
      ; field "Event ID" e.event_id
      ; field "Run ID" e.run_id
      ; field "Parent event ID" e.parent
      ; field "Caused by" e.caused_by
      ; field "Correlation ID" e.correlation
      ; field (say "런타임 에이전트" "Runtime agent") e.agent
      ; field
          (match e.kind with
           (* These carry the run's own wire id there, not a task. *)
           | Agent_started | Agent_completed _ | Agent_failed _ | Agent_yielded _
           | Agent_input_required _ ->
               "Agent run ID"
           | Tool_called | Tool_completed | Turn_started | Turn_ready
           | Turn_completed | Tool_approval_completed | Telemetry | Relay_subscription_loss _
           | Agent_core_other _ ->
               "Task ID")
          e.task
      ; number (say "에이전트 세션 턴" "Agent session turn") e.turn
      ; field (say "배치 순서 / 크기" "Batch index / size") (Option.map (fun (index, size) -> Printf.sprintf "%d / %d" index size) e.batch)
      ; some (say "입출력" "Input/output") (say "이 관찰 이벤트에 실려 오지 않음" "not carried by this observer event")
      ; some (say "스킬 영수증" "Skill receipt") (say "이 관찰 이벤트에 실려 오지 않음" "not carried by this observer event")
      ]
  | Observer.Keeper_tool_call call ->
      let schedule_fields =
        match call.kt_schedule with
        | None -> [ field (say "실행 방식" "Execution schedule") None ]
        | Some (Error error) -> [ some (say "실행 방식 오류" "Execution schedule error") error ]
        | Some (Ok schedule) ->
            [ some (say "실행 방식" "Execution mode")
                (match schedule.execution_mode with
                 | Agent_core.Tool_contract.Concurrent -> (say "동시" "concurrent")
                 | Agent_core.Tool_contract.Serial -> (say "순차" "serial"))
            ; some (say "계획 순서 (0부터)" "Planned index (zero-based)") (string_of_int schedule.planned_index)
            ; some (say "배치 순서 (0부터) / 크기" "Batch index (zero-based) / size")
                (Printf.sprintf "%d / %d" schedule.batch_index schedule.batch_size)
            ]
      in
      [ some (say "출처" "Source") (say "keeper_tool_call 관찰 이벤트" "keeper_tool_call observer event")
      ; some "Keeper" call.kt_keeper
      ; some (say "도구 이름" "Tool name") call.kt_tool
      ; number (say "에이전트 세션 턴" "Agent session turn") call.kt_turn
      ; (match call.kt_disposition with
         | None -> field (say "처리 결과" "Disposition") None
         | Some (Ok disposition) ->
             some (say "처리 결과" "Disposition")
               (Masc.Tui_decode.keeper_call_disposition_word ~ko disposition)
         | Some (Error error) -> some (say "처리 결과 오류" "Disposition error") error)
      ; field "Tool use ID" call.kt_tool_use_id
      ; some (say "입출력" "Input/output") (say "아래는 보낸 쪽이 가린 관측 · 전체 내용은 보장되지 않음" "producer-redacted observations below; full payload not guaranteed")
      ] @ schedule_fields
  | (Observer.Internal_agent_runs_changed _ | Observer.Workspace_store_changed _ | Observer.Dataset_changed _ | Observer.Gate_connector_changed _ | Observer.Keeper_event_queue_changed _ | Observer.Board_changed _ | Observer.Approval_change _ | Observer.Keeper_heartbeat _ | Observer.Keeper_turn_complete _ | Observer.Keeper_turn_observation _ | Observer.Keeper_composite_changed _ | Observer.Keeper_metrics_appended _ | Observer.Keeper_chat_appended _ | Observer.Keeper_memory_journal_appended _ | Observer.Keeper_runtime_journal_appended _ | Observer.Keeper_chat_stream_frame _ | Observer.Keeper_turn_stream_frame _ | Observer.Keeper_waiting_inventory_changed _ | Observer.Keeper_async_requests_changed _ | Observer.Keeper_skill_activations_changed _ | Observer.Keeper_roster_change _ | Observer.Keeper_turn_changed _ | Observer.Fusion_run_status _ | Observer.Lane_resource _ | Observer.Snapshot _ | Observer.Execution_snapshot | Observer.Other _) as event -> let row = row_of_event ~ko ~at:entry.ae_at ~duration_ms:None event in
      [ some (say "출처" "Source") (say "관찰 이벤트" "observer event")
      ; some (say "이벤트" "Event") row.label
      ; some (say "상세" "Detail") row.detail
      ; some (say "호출 근거" "Call evidence") (say "이 이벤트는 도구 호출 그 자체가 아님" "this event is not an exact tool invocation")
      ]

(* ── The Activity table's two measured columns ─────────────────────────── *)

type columns = { keeper_cells : int; content_cells : int; show_clock : bool }

(* Measuring needs the actor and label, without spelling the detail sentence
   of every retained off-screen event. *)
type measured = { measured_keeper : string; measured_label : string }

let measured_of_row row =
  { measured_keeper = row.keeper; measured_label = row.label }

let measured_of_event ~ko ~traces event =
  { measured_keeper = keeper_of_event ~traces event
  ; measured_label = label_of_event ~ko event
  }

(* The cells a name takes once drawn. The table draws the keeper and the
   label through the renderer's [Terminal_text.single_line], which is
   [Masc.Tui_terminal_text.sanitize_terminal_text]: a control byte reaches the
   screen as its four-cell escape ([\x09], [\x1B]). Measuring the raw text
   sized the column narrower than the name it then drew. *)
let drawn_cells text =
  Masc_tui_message_layout.display_width
    (Masc.Tui_terminal_text.sanitize_terminal_text text)

let columns ~inner_width measures =
  (* The kept entries repeat a handful of keeper names and event words, and
     the widest of a text measured twice is the widest of it measured once,
     so each distinct text is measured once. *)
  let widest pick =
    let seen = Hashtbl.create 32 in
    List.fold_left
      (fun widest measure ->
        let text = pick measure in
        if Hashtbl.mem seen text then widest
        else (
          Hashtbl.add seen text ();
          max widest (drawn_cells text)))
      0 measures
  in
  (* Two leading cells, a glyph, and the gaps before content and actor.
     Content owns at least two thirds; receipt time uses only the space an
     actor shorter than its allocation leaves behind. *)
  let available = max 0 (inner_width - 5) in
  let actor_budget = available / 3 in
  let keeper_needed = max (drawn_cells "ACTOR") (widest (fun m -> m.measured_keeper)) in
  let keeper_cells = min keeper_needed actor_budget in
  let clock_cells = drawn_cells "00:00:00" + 1 in
  let content_floor = max (available - actor_budget) (widest (fun m -> m.measured_label)) in
  let show_clock = available - keeper_cells - clock_cells >= content_floor in
  let content_cells = available - keeper_cells - (if show_clock then clock_cells else 0) in
  { keeper_cells; content_cells; show_clock }
