(** Dashboard semantics registry.

    This is the "why" layer for dashboard surfaces, panels, and metrics. *)

let str_list values =
  `List (List.map (fun value -> `String value) values)

let metric ~id ~label ~what_it_measures ~why_it_exists ~source_path
    ~update_trigger ~agent_behavior_effect ~ecosystem_effect ~interpretation
    ~bad_smell ~next_action =
  `Assoc
    [
      ("id", `String id);
      ("label", `String label);
      ("what_it_measures", `String what_it_measures);
      ("why_it_exists", `String why_it_exists);
      ("source_path", `String source_path);
      ("update_trigger", `String update_trigger);
      ("agent_behavior_effect", `String agent_behavior_effect);
      ("ecosystem_effect", `String ecosystem_effect);
      ("interpretation", `String interpretation);
      ("bad_smell", `String bad_smell);
      ("next_action", `String next_action);
    ]

let panel ~id ~title ~purpose ~problem_solved ~when_active ~agent_role
    ~ecosystem_function ?(related_tools = []) metrics =
  `Assoc
    [
      ("id", `String id);
      ("title", `String title);
      ("purpose", `String purpose);
      ("problem_solved", `String problem_solved);
      ("when_active", `String when_active);
      ("agent_role", `String agent_role);
      ("ecosystem_function", `String ecosystem_function);
      ("related_tools", str_list related_tools);
      ("metrics", `List metrics);
    ]

let surface ~id ~label ~purpose ~problem_solved ~when_active ~agent_role
    ~ecosystem_function panels =
  `Assoc
    [
      ("id", `String id);
      ("label", `String label);
      ("purpose", `String purpose);
      ("problem_solved", `String problem_solved);
      ("when_active", `String when_active);
      ("agent_role", `String agent_role);
      ("ecosystem_function", `String ecosystem_function);
      ("panels", `List panels);
    ]

let json () =
  `Assoc
    [
      ("schema_version", `String "1.0.0");
      ("generated_at", `String (Types.now_iso ()));
      ( "surfaces",
        `List
          [
            surface ~id:"side_rail" ~label:"사이드 레일"
              ~purpose:"현재 탭을 벗어나지 않고 Room 전체 방향과 경량 제어를 제공한다."
              ~problem_solved:"한 화면에 집중하다 전체 상황을 놓치는 것을 방지한다."
              ~when_active:"대시보드가 열려 있는 동안 항상 표시."
              ~agent_role:"에이전트가 Room 최상위 컨텍스트와 운영자 자세로 활용."
              ~ecosystem_function:"모든 surface 위에 안정적인 조율 셸을 제공한다."
              [
                panel ~id:"side_rail.navigate" ~title:"탐색"
                  ~purpose:"각 주요 워크스페이스의 용도를 진입 전에 설명한다."
                  ~problem_solved:"탭 전환 낭비와 무작위 탐색을 줄인다."
                  ~when_active:"항상 표시."
                  ~agent_role:"에이전트가 활성 워크스페이스에서 기대되는 행동 양식을 추론할 수 있다."
                  ~ecosystem_function:"정보 구조를 읽기 쉽게 유지한다."
                  [];
                panel ~id:"side_rail.snapshot" ~title:"스냅샷"
                  ~purpose:"Room 펄스, 연결 상태, 주요 카운트를 표시한다."
                  ~problem_solved:"오래된 Room 컨텍스트 위에서 판단하는 것을 방지한다."
                  ~when_active:"대시보드 데이터와 지속 갱신."
                  ~agent_role:"에이전트가 저비용 Room 요약으로 활용할 수 있다."
                  ~ecosystem_function:"공통 운영 기준선을 유지한다."
                  [
                    metric ~id:"side_rail.snapshot.events" ~label:"이벤트"
                      ~what_it_measures:"대시보드가 SSE 업데이트를 수신하고 있는지 여부."
                      ~why_it_exists:"피드가 오래되면 최신성 의존 판단이 무의미해진다."
                      ~source_path:"sse.connected + sse.eventCount"
                      ~update_trigger:"SSE 이벤트 / 재연결 상태"
                      ~agent_behavior_effect:"전송 상태가 나쁘면 에이전트는 보수적으로 행동해야 한다."
                      ~ecosystem_effect:"Room 전체의 공유 현실을 보존한다."
                      ~interpretation:"피드가 정상이면 나머지 UI를 더 신뢰할 수 있다."
                      ~bad_smell:"업데이트가 멈춘 상태에서 모든 것이 잠잠해 보인다."
                      ~next_action:"피드를 복구하거나 수동 새로고침."
                  ];
                panel ~id:"side_rail.quick_actions" ~title:"빠른 액션"
                  ~purpose:"무거운 개입 워크플로 전에 저비용 조정을 가능하게 한다."
                  ~problem_solved:"단순한 Room 교정까지의 지연 시간을 줄인다."
                  ~when_active:"레일 접기가 열려 있을 때."
                  ~agent_role:"에이전트가 작은 조정을 Room 수준 조율 액션으로 매핑할 수 있다."
                  ~ecosystem_function:"전면 운영자 에스컬레이션 전에 생태계가 자체 교정할 수 있게 한다."
                  [];
              ];
            surface ~id:"mission" ~label:"미션"
              ~purpose:"Room 인시던트와 다음 액션을 위한 트리아지 우선 랜딩 뷰."
              ~problem_solved:"더 깊은 제어 화면을 열기 전에 지금 중요한 것에 답한다."
              ~when_active:"기본 랜딩 탭이자 첫 번째 운영 브리핑."
              ~agent_role:"에이전트가 Room의 즉각적인 감독 우선순위를 요약하는 데 사용."
              ~ecosystem_function:"Room 압력을 하나의 디스패치 가능한 브리핑으로 압축한다."
              [
                panel ~id:"mission.hero" ~title:"지금 가장 먼저 볼 것"
                  ~purpose:"최상위 인시던트와 최상위 액션을 한 곳에 강조한다."
                  ~problem_solved:"중요한 Room 이슈가 목록에 묻히는 것을 방지한다."
                  ~when_active:"미션 랜딩."
                  ~agent_role:"에이전트가 Room에 지금 주의가 필요한 이유를 설명할 때 사용."
                  ~ecosystem_function:"가장 높은 레버리지 개입에 인간의 주의를 유도한다."
                  [];
                panel ~id:"mission.focus" ~title:"운영 포커스"
                  ~purpose:"커맨드 플레인 상태를 미션 언어로 요약한다."
                  ~problem_solved:"상위 미션 상태와 상세 커맨드 데이터를 연결한다."
                  ~when_active:"미션 랜딩."
                  ~agent_role:"Room이 관찰, 개입, 심층 커맨드 작업 중 무엇이 필요한지 설명할 수 있다."
                  ~ecosystem_function:"최상위 압력과 실행 구조를 연결한다."
                  [
                    metric ~id:"mission.focus.active_lanes" ~label:"활성 레인"
                      ~what_it_measures:"현재 활성 상태인 swarm 레인 수."
                      ~why_it_exists:"미션 화면에 실행 움직임의 간결한 표현이 필요하다."
                      ~source_path:"mission.command_focus.swarm_overview.active_lanes"
                      ~update_trigger:"미션/커맨드 갱신"
                      ~agent_behavior_effect:"움직임이 적으면 개입이나 커맨드 플레인 점검이 필요할 수 있다."
                      ~ecosystem_effect:"현재 swarm 활성도를 나타낸다."
                      ~interpretation:"활성 레인은 Room 움직임을 보여주지, 출력 품질을 보여주지 않는다."
                      ~bad_smell:"긴급도는 높은데 가시적인 실행 움직임이 없다."
                      ~next_action:"커맨드 swarm 상세 열기."
                  ];
                panel ~id:"mission.incidents" ~title:"우선 인시던트"
                  ~purpose:"현재 Room 인시던트를 순위화한다."
                  ~problem_solved:"운영자가 모든 이상을 동등하게 취급하는 것을 방지한다."
                  ~when_active:"미션 랜딩."
                  ~agent_role:"에이전트가 최상위 인시던트를 설명 또는 액션 대상으로 활용할 수 있다."
                  ~ecosystem_function:"Room 전체 감독 압력을 집중시킨다."
                  [];
                panel ~id:"mission.actions" ~title:"추천 액션"
                  ~purpose:"백엔드가 제안하는 최소 교정 액션을 표시한다."
                  ~problem_solved:"과잉 반응과 무목적 제어 전환을 줄인다."
                  ~when_active:"미션 랜딩."
                  ~agent_role:"에이전트가 이를 명시적 개입 제안으로 전환할 수 있다."
                  ~ecosystem_function:"Room 관찰을 구체적 교정 액션에 연결한다."
                  [];
                panel ~id:"mission.sessions" ~title:"집중 세션"
                  ~purpose:"미션 압력을 만들어내는 세션을 보여준다."
                  ~problem_solved:"Room 이슈를 세션 수준으로 지역화한다."
                  ~when_active:"미션 랜딩."
                  ~agent_role:"에이전트가 어떤 세션에 직접 감독이 필요한지 판단할 수 있다."
                  ~ecosystem_function:"세션 간 감독 주의를 배분한다."
                  [];
                panel ~id:"mission.session_detail" ~title:"세션 상세"
                  ~purpose:"하나의 세션을 주요 관찰 단위로 제시한다."
                  ~problem_solved:"목표, 참여자, 최근 이벤트, 연결된 실행을 한 뷰에서 읽을 수 있게 한다."
                  ~when_active:"미션에서 세션이 선택되거나 자동 포커스될 때."
                  ~agent_role:"에이전트가 세션을 여러 화면에 흩뿌리지 않고 하나의 일관된 단위로 설명해야 한다."
                  ~ecosystem_function:"선택된 세션을 중심으로 협업과 실행 증거를 통합한다."
                  [];
                panel ~id:"mission.targets" ~title:"바로 개입할 대상"
                  ~purpose:"즉시 개입 후보인 keeper나 세션을 나열한다."
                  ~problem_solved:"미션 신호를 실행 가능한 대상 선택으로 전환한다."
                  ~when_active:"미션 랜딩."
                  ~agent_role:"에이전트가 다음에 메시지를 보내거나 조정할 대상을 결정한다."
                  ~ecosystem_function:"개입 범위를 Room 수준에서 액터 수준으로 좁힌다."
                  [];
              ];
            surface ~id:"intervene" ~label:"Intervene"
              ~purpose:"Acts as the guided operator intervention workspace."
              ~problem_solved:"Provides a safe place to steer rooms, sessions, and keepers without raw MCP calls."
              ~when_active:"Used when the operator wants to mutate state rather than only observe it."
              ~agent_role:"Agents can translate diagnostics into structured interventions here."
              ~ecosystem_function:"Converts supervision intent into explicit, auditable actions."
              [
                panel ~id:"intervene.priority_cards" ~title:"Action Priority"
                  ~purpose:"Summarizes room, confirm, session, and keeper pressure."
                  ~problem_solved:"Prevents the operator from missing the dominant intervention domain."
                  ~when_active:"Top of Intervene."
                  ~agent_role:"Agents can infer where intervention demand is highest."
                  ~ecosystem_function:"Turns broad room state into intervention pressure."
                  [];
                panel ~id:"intervene.recommended_actions" ~title:"Recommended Actions"
                  ~purpose:"Shows the backend’s smallest suggested interventions."
                  ~problem_solved:"Avoids oversized interventions when a small course correction would work."
                  ~when_active:"Whenever operator digest has suggestions."
                  ~agent_role:"Agents can present backend suggestions in room language."
                  ~ecosystem_function:"Encourages minimal, reversible supervision."
                  [];
                panel ~id:"intervene.pending_confirmations" ~title:"Pending Confirmations"
                  ~purpose:"Shows the actor-scoped preview queue for confirm-required operator actions."
                  ~problem_solved:"Prevents previewed interventions from being mistaken as executed and explains when the queue is empty only because another actor owns the token."
                  ~when_active:"When confirm-required actions exist or when the operator needs to know which actions enter the preview-confirm path."
                  ~agent_role:"Agents should explain these as incomplete work, call out actor filtering, and distinguish visible from hidden pending tokens."
                  ~ecosystem_function:"Maintains human-in-the-loop control."
                  [];
                panel ~id:"intervene.session_queue" ~title:"Session Queue"
                  ~purpose:"Ranks team sessions by intervention need."
                  ~problem_solved:"Avoids spreading attention evenly across every session."
                  ~when_active:"When multiple sessions exist."
                  ~agent_role:"Agents can decide which session needs steering first."
                  ~ecosystem_function:"Allocates supervision bandwidth."
                  [];
                panel ~id:"intervene.session_digest" ~title:"Session Digest"
                  ~purpose:"Explains which worker pattern is causing session pressure."
                  ~problem_solved:"Bridges room-level pressure and worker-level diagnosis."
                  ~when_active:"A session is selected."
                  ~agent_role:"Agents can explain why a specific session is unhealthy."
                  ~ecosystem_function:"Localizes intervention to the right session component."
                  [];
                panel ~id:"intervene.keeper_queue" ~title:"Keeper Queue"
                  ~purpose:"Shows long-lived keepers that need recovery or correction."
                  ~problem_solved:"Stops keepers from being overshadowed by short-lived sessions."
                  ~when_active:"Keepers are present."
                  ~agent_role:"Agents can choose a keeper recovery target here."
                  ~ecosystem_function:"Protects continuity assets."
                  [];
                panel ~id:"intervene.action_studio" ~title:"Action Studio"
                  ~purpose:"Central place where room/session/keeper interventions are executed."
                  ~problem_solved:"Keeps mutating controls centralized and legible."
                  ~when_active:"Whenever the user is ready to act."
                  ~agent_role:"Agents map desired intervention into structured action payloads."
                  ~ecosystem_function:"Makes ecosystem steering explicit and auditable."
                  [];
              ];
            surface ~id:"proof" ~label:"Proof"
              ~purpose:"Shows collaboration evidence, actor contributions, and managed backing artifacts in one read-only surface."
              ~problem_solved:"Stops swarm or session success claims from floating free of auditable evidence."
              ~when_active:"Used when the operator wants to verify who did what, with which tools, toward which goal."
              ~agent_role:"Agents can use it to justify claims with timeline and artifact evidence instead of narration alone."
              ~ecosystem_function:"Creates a deterministic proof layer between mission narration and command truth."
              [
                panel ~id:"proof.summary" ~title:"3-Line Proof Summary"
                  ~purpose:"Compresses the proof verdict into one human-readable headline."
                  ~problem_solved:"Prevents operators from digging through raw timelines before knowing whether evidence is strong enough."
                  ~when_active:"Top of Proof."
                  ~agent_role:"Agents should start with this before elaborating on evidence."
                  ~ecosystem_function:"Makes collaboration proof fast to scan."
                  [];
                panel ~id:"proof.timeline" ~title:"Collaboration Timeline"
                  ~purpose:"Merges team-session events and command-plane traces into one evidence stream."
                  ~problem_solved:"Prevents collaboration and execution evidence from being read in isolation."
                  ~when_active:"Proof timeline section."
                  ~agent_role:"Agents can explain what happened in order rather than by abstraction."
                  ~ecosystem_function:"Preserves chronological causality."
                  [];
                panel ~id:"proof.contributions" ~title:"Actor Contributions"
                  ~purpose:"Shows who contributed inputs, outputs, and tool evidence."
                  ~problem_solved:"Avoids vague claims that a team worked together without naming contributions."
                  ~when_active:"Proof contribution section."
                  ~agent_role:"Agents can point to specific actors instead of generic group language."
                  ~ecosystem_function:"Keeps collaboration legible at actor granularity."
                  [];
                panel ~id:"proof.goal_binding" ~title:"Goal Binding"
                  ~purpose:"Shows how the observed activity maps back to the stated session or operation goal."
                  ~problem_solved:"Prevents busy evidence from masquerading as aligned work."
                  ~when_active:"Proof goal section."
                  ~agent_role:"Agents can distinguish activity from aligned progress."
                  ~ecosystem_function:"Maintains goal-traceability."
                  [];
                panel ~id:"proof.backing" ~title:"CPv2 Backing Evidence"
                  ~purpose:"Shows the managed execution backing for the selected proof target."
                  ~problem_solved:"Prevents collaboration proof from being mistaken for managed execution proof."
                  ~when_active:"When an operation or synthetic detachment link exists."
                  ~agent_role:"Agents can ground collaboration claims in CPv2 state when available."
                  ~ecosystem_function:"Connects session proof to command truth."
                  [];
                panel ~id:"proof.artifacts" ~title:"Artifacts"
                  ~purpose:"Lists the stored report/proof/session artifacts behind the current proof view."
                  ~problem_solved:"Makes it obvious whether evidence is persisted or only inferred live."
                  ~when_active:"Proof artifacts section."
                  ~agent_role:"Agents can cite concrete files instead of ephemeral memory."
                  ~ecosystem_function:"Supports replayable auditing."
                  [];
              ];
            surface ~id:"command" ~label:"Command"
              ~purpose:"Provides the direct operational truth surface for command-plane, swarm, chains, alerts, and policy."
              ~problem_solved:"Stops swarm and execution claims from floating free of managed evidence."
              ~when_active:"Used for deep operational debugging and orchestration truth."
              ~agent_role:"Agents read this when they need execution truth, not just mission narration."
              ~ecosystem_function:"Acts as the system-of-record view for managed execution."
              [
                panel ~id:"command.summary" ~title:"지금 조치 / 운영 경로"
                  ~purpose:"Translates command-plane posture into the next likely canonical tool or path."
                  ~problem_solved:"Prevents operators from seeing pressure without a plausible next move."
                  ~when_active:"Top of Command."
                  ~agent_role:"Agents use it to move from explanation to tool-level next step."
                  ~ecosystem_function:"Shortens recovery loops."
                  [];
                panel ~id:"command.swarm" ~title:"Swarm"
                  ~purpose:"Shows whether the swarm story is actually true in terms of lanes, workers, runtime, and blockers."
                  ~problem_solved:"Prevents people from saying 'the swarm worked' without run-scoped evidence."
                  ~when_active:"Swarm surface."
                  ~agent_role:"Agents can explain what happened, not just what was intended."
                  ~ecosystem_function:"Turns swarm behavior into auditable evidence."
                  [
                    metric ~id:"command.swarm.pass_end_to_end" ~label:"종단 점검"
                      ~what_it_measures:"Whether the expected worker lifecycle and run evidence all lined up."
                      ~why_it_exists:"The room needs a single flag for 'did the swarm actually execute as claimed?'."
                      ~source_path:"command.swarm read-model -> summary.pass_end_to_end"
                      ~update_trigger:"Swarm refresh"
                      ~agent_behavior_effect:"False should block confident success claims."
                      ~ecosystem_effect:"Protects the system from fake swarm success narratives."
                      ~interpretation:"A pass means orchestration evidence is complete, not that output quality is perfect."
                      ~bad_smell:"People cite swarm success while this is false."
                      ~next_action:"Inspect checklist, blockers, and traces."
                  ;
                    metric ~id:"command.swarm.runtime_blocker" ~label:"런타임 막힘"
                      ~what_it_measures:"The concrete runtime substrate failure, if any."
                      ~why_it_exists:"Provider or slot mismatch often masquerades as orchestration failure."
                      ~source_path:"command.swarm read-model -> provider.runtime_blocker"
                      ~update_trigger:"Swarm refresh / runtime doctor update"
                      ~agent_behavior_effect:"Agents should explain substrate failure before orchestration blame."
                      ~ecosystem_effect:"Separates runtime breakage from control-plane breakage."
                      ~interpretation:"A blocker means the swarm is not trustworthy until substrate is fixed."
                      ~bad_smell:"Operators tune orchestration while the runtime contract is broken."
                      ~next_action:"Fix runtime profile or restart the provider."
                  ;
                    metric ~id:"command.swarm.recommended_next_tool" ~label:"추천 도구"
                      ~what_it_measures:"The backend’s suggested next diagnostic or repair step."
                      ~why_it_exists:"Operators need the next move, not just evidence."
                      ~source_path:"command.swarm read-model -> recommended_next_tool"
                      ~update_trigger:"Swarm refresh"
                      ~agent_behavior_effect:"Agents can convert this into precise guidance."
                      ~ecosystem_effect:"Reduces indecision after failure."
                      ~interpretation:"This is the shortest useful next hop, not a full diagnosis."
                      ~bad_smell:"The system explains failure but leaves the operator directionless."
                      ~next_action:"Follow the recommended tool unless a stronger blocker is visible."
                  ];
                panel ~id:"command.orchestra" ~title:"Orchestra Map"
                  ~purpose:"Shows the full room as a single tactical map across sessions, lanes, workers, keepers, and hot signals."
                  ~problem_solved:"Prevents operators from having to mentally merge swarm, war-room, intervene, and continuity views."
                  ~when_active:"Orchestra surface."
                  ~agent_role:"Agents should start here for room-wide orientation, then drill down into swarm, war-room, or intervene."
                  ~ecosystem_function:"Creates a room-scale visual control room over orchestration state."
                  [];
                panel ~id:"command.operations" ~title:"Operations / Detachments"
                  ~purpose:"Shows managed intent and materialized execution bodies together."
                  ~problem_solved:"Prevents confusion between assigned work and instantiated runtime work."
                  ~when_active:"Operations surface."
                  ~agent_role:"Agents use operations for intent and detachments for embodiment."
                  ~ecosystem_function:"Connects managed objectives to concrete execution."
                  [];
                panel ~id:"command.chains" ~title:"Chains"
                  ~purpose:"Exposes chain-backed orchestration inside the command plane."
                  ~problem_solved:"Prevents chain execution from becoming an invisible substrate."
                  ~when_active:"Chains surface."
                  ~agent_role:"Agents use it when operation behavior depends on chain execution."
                  ~ecosystem_function:"Makes orchestration substrate inspectable."
                  [];
                panel ~id:"command.topology" ~title:"지휘 계층"
                  ~purpose:"Shows structural ownership across company/platoon/squad/agent."
                  ~problem_solved:"Prevents failures from being blamed on the wrong structural layer."
                  ~when_active:"Topology surface."
                  ~agent_role:"Agents use it to reason about assignment scope and responsibility."
                  ~ecosystem_function:"Keeps orchestration structure intelligible."
                  [];
                panel ~id:"command.alerts" ~title:"경보"
                  ~purpose:"Surfaces anomalies derived from command-plane state."
                  ~problem_solved:"Concentrates hidden pathologies into a readable queue."
                  ~when_active:"Alerts surface."
                  ~agent_role:"Agents treat alerts as prioritized explanation targets."
                  ~ecosystem_function:"Turns latent failure into visible supervision demand."
                  [];
                panel ~id:"command.trace" ~title:"최근 트레이스"
                  ~purpose:"Shows recent execution transitions as evidence rather than summary."
                  ~problem_solved:"Lets humans and agents verify what actually happened."
                  ~when_active:"Trace surface and swarm detail."
                  ~agent_role:"Agents use trace rows to justify causal claims."
                  ~ecosystem_function:"Provides causal auditability."
                  [];
                panel ~id:"command.control" ~title:"승인 대기 / Unit 제어"
                  ~purpose:"Contains governance and actuation levers."
                  ~problem_solved:"Separates observation from mutation."
                  ~when_active:"Control surface."
                  ~agent_role:"Agents should use this surface carefully because it mutates policy."
                  ~ecosystem_function:"Allows the ecosystem to be steered, not just watched."
                  [];
              ];
            surface ~id:"execution" ~label:"Execution"
              ~purpose:"Shows short-horizon worker drift and long-horizon keeper continuity as separate concerns."
              ~problem_solved:"Prevents operator confusion between active execution failure and continuity degradation."
              ~when_active:"Used when the operator asks who owns work, who is stale, and what continuity asset is at risk."
              ~agent_role:"Agents can compare worker freshness and keeper continuity without collapsing them into one class of actor."
              ~ecosystem_function:"Makes execution pressure legible without hiding continuity debt."
              [
                panel ~id:"execution.queue" ~title:"Execution Queue"
                  ~purpose:"Ranks blocked sessions and operation blockers before any worker detail."
                  ~problem_solved:"Cuts time to the first execution diagnosis and handoff decision."
                  ~when_active:"Top of Execution."
                  ~agent_role:"A supervising agent starts with the queue, then drills into linked session or operation detail."
                  ~ecosystem_function:"Turns mixed execution drift into a small set of actionable blocked targets."
                  [];
                panel ~id:"execution.sessions" ~title:"Affected Sessions"
                  ~purpose:"Shows which team sessions are actually affected by the current blocked execution."
                  ~problem_solved:"Keeps session goal, health, and runtime blocker in one place."
                  ~when_active:"After selecting an execution queue item."
                  ~agent_role:"Agents can decide whether to intervene at the session layer or escalate to command truth."
                  ~ecosystem_function:"Preserves session-level ownership while still supporting command-plane diagnosis."
                  [];
                panel ~id:"execution.operations" ~title:"Affected Operations"
                  ~purpose:"Summarizes linked command-plane operations and their blocker state without opening Command yet."
                  ~problem_solved:"Shows why the execution is blocked in command terms, not just worker symptoms."
                  ~when_active:"When a queue item or session links to an operation."
                  ~agent_role:"Agents can decide whether to escalate into deep command inspection."
                  ~ecosystem_function:"Bridges session execution and command-plane truth."
                  [];
                panel ~id:"execution.worker_support" ~title:"Worker Support"
                  ~purpose:"Shows only the workers supporting the selected execution target."
                  ~problem_solved:"Prevents the old global worker wall from drowning the actual blocked execution."
                  ~when_active:"After queue/session/operation selection."
                  ~agent_role:"Workers are supporting evidence, not the main unit of execution judgment."
                  ~ecosystem_function:"Keeps worker visibility proportional to the current blocked target."
                  [];
                panel ~id:"execution.continuity" ~title:"Continuity"
                  ~purpose:"Keeps keeper continuity as a supporting lane under the execution target."
                  ~problem_solved:"Prevents continuity pressure from disappearing while avoiding equal weight with blocked execution."
                  ~when_active:"When unhealthy or linked keepers exist."
                  ~agent_role:"Keepers remain continuity assets, not primary execution units."
                  ~ecosystem_function:"Protects long-horizon continuity without stealing focus from blocked execution."
                  [];
                panel ~id:"execution.offline" ~title:"Offline Workers"
                  ~purpose:"Preserves dropout visibility without drowning the live worker view."
                  ~problem_solved:"Stops disappeared executors from silently vanishing from operator memory."
                  ~when_active:"When workers leave or go stale."
                  ~agent_role:"Agents that exit without clean handoff create risk here."
                  ~ecosystem_function:"Maintains execution accountability across churn."
                  [];
              ];
            surface ~id:"memory" ~label:"Memory"
              ~purpose:"Acts as the room’s durable asynchronous memory for posts and comments only."
              ~problem_solved:"Keeps durable discussion context separate from decision protocol and voting."
              ~when_active:"Used when the operator wants to read or write durable room memory."
              ~agent_role:"Agents publish findings, context, and status for later readers here."
              ~ecosystem_function:"Turns coordination context into durable room memory."
              [
                panel ~id:"memory.feed" ~title:"Posts / Comments"
                  ~purpose:"Shows durable coordination context and its local discussion."
                  ~problem_solved:"Prevents ad-hoc reasoning from disappearing after the current session."
                  ~when_active:"Memory feed and post detail."
                  ~agent_role:"Agents leave findings and status here for humans and other agents."
                  ~ecosystem_function:"Preserves asynchronous coordination memory."
                  [];
              ];
            surface ~id:"governance" ~label:"Governance"
              ~purpose:"Separates formal disagreement and consensus state from the memory feed."
              ~problem_solved:"Prevents debates and voting from being mistaken for ordinary discussion posts."
              ~when_active:"Used when decisions are open, contested, or awaiting quorum."
              ~agent_role:"Agents contribute structured arguments and formal votes here."
              ~ecosystem_function:"Turns deliberation into explicit governance state."
              [
                panel ~id:"governance.debates" ~title:"Debates"
                  ~purpose:"Supports structured disagreement on design or policy."
                  ~problem_solved:"Prevents important disagreements from dissolving into untracked chat."
                  ~when_active:"Debate list and detail."
                  ~agent_role:"Agents contribute explicit support, oppose, or neutral arguments."
                  ~ecosystem_function:"Turns conflict into inspectable reasoning."
                  [];
                panel ~id:"governance.voting" ~title:"Voting"
                  ~purpose:"Tracks formal consensus closure."
                  ~problem_solved:"Prevents debates from lingering without an explicit decision state."
                  ~when_active:"Voting list."
                  ~agent_role:"Agents cast approve, reject, or abstain with reasons."
                  ~ecosystem_function:"Turns deliberation into governance."
                  [];
              ];
            surface ~id:"planning" ~label:"Planning"
              ~purpose:"Aligns direction, metric loops, and backlog posture."
              ~problem_solved:"Separates strategic intent from raw task churn."
              ~when_active:"Used when planning, reviewing, or checking numeric iteration."
              ~agent_role:"Agents read goals for intent, MDAL for movement, and backlog for obligation."
              ~ecosystem_function:"Bridges long-horizon direction with short-horizon execution."
              [
                panel ~id:"planning.surface" ~title:"Planning Surface"
                  ~purpose:"Explains how goals, loops, and backlog pressure fit together."
                  ~problem_solved:"Prevents planning from collapsing into vague aspiration or metric myopia."
                  ~when_active:"Top of Planning."
                  ~agent_role:"Agents should infer both intent and acceptance pressure here."
                  ~ecosystem_function:"Bridges strategy and iteration."
                  [];
                panel ~id:"planning.goal_pipeline" ~title:"Goal Pipeline"
                  ~purpose:"Groups strategic intent by horizon."
                  ~problem_solved:"Prevents all goals from being treated as equally urgent."
                  ~when_active:"Any planning session."
                  ~agent_role:"Agents should understand which time horizon they are serving."
                  ~ecosystem_function:"Maintains temporal structure in room priorities."
                  [];
                panel ~id:"planning.mdal_loops" ~title:"MDAL Loops"
                  ~purpose:"Shows whether strict metric-driven loops are actually improving."
                  ~problem_solved:"Prevents endless iteration without measured movement."
                  ~when_active:"When MDAL is in play."
                  ~agent_role:"Agents use this as evidence of progress, not just intent."
                  ~ecosystem_function:"Supplies numeric proof that iteration is worthwhile."
                  [];
                panel ~id:"planning.backlog" ~title:"Task Backlog"
                  ~purpose:"Shows the concrete workload under the plan."
                  ~problem_solved:"Prevents planning from ignoring actual execution load."
                  ~when_active:"When goals connect to tasks."
                  ~agent_role:"Agents translate direction into claims and completions here."
                  ~ecosystem_function:"Connects plans to room labor."
                  [];
              ];
            surface ~id:"lab" ~label:"Lab"
              ~purpose:"Holds experimental or narrative surfaces outside the main operator console."
              ~problem_solved:"Keeps experimental domains from polluting operational meanings in the main dashboard."
              ~when_active:"Used when the operator intentionally enters experimental space."
              ~agent_role:"Agents should treat this as explicitly non-canonical operational territory."
              ~ecosystem_function:"Contains experimentation without corrupting the main operator model."
              [
                panel ~id:"lab.experimental" ~title:"Experimental Surface"
                  ~purpose:"Marks the boundary between canonical operator surfaces and experiments."
                  ~problem_solved:"Prevents experimental screens from masquerading as mainline operations."
                  ~when_active:"Top of Lab."
                  ~agent_role:"Agents should explain that features here are outside the main operator console."
                  ~ecosystem_function:"Protects conceptual hygiene."
                  [];
                panel ~id:"lab.trpg" ~title:"TRPG"
                  ~purpose:"Provides narrative room state and explicit world control."
                  ~problem_solved:"Keeps world state, round progression, and intervention coherent without leaking into the main operator IA."
                  ~when_active:"When a TRPG room is active inside Lab."
                  ~agent_role:"Agents can act as DM, player, or observer and should know this is an experimental sandbox."
                  ~ecosystem_function:"Provides a sandboxed narrative coordination environment."
                  [];
              ];
          ] );
    ]
