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
            surface ~id:"side_rail" ~label:"Side Rail"
              ~purpose:"Gives room-wide orientation and lightweight control without leaving the current tab."
              ~problem_solved:"Prevents operators from losing the big picture while drilling into one screen."
              ~when_active:"Always visible while the dashboard is open."
              ~agent_role:"Agents can treat it as the top-level room context and operator posture."
              ~ecosystem_function:"Provides a stable coordination shell above all surfaces."
              [
                panel ~id:"side_rail.navigate" ~title:"Navigate"
                  ~purpose:"Explains what each major workspace is for before the user enters it."
                  ~problem_solved:"Reduces tab thrash and random exploration."
                  ~when_active:"Always visible."
                  ~agent_role:"Agents can infer what style of action is expected in the active workspace."
                  ~ecosystem_function:"Keeps information architecture legible."
                  [];
                panel ~id:"side_rail.snapshot" ~title:"Snapshot"
                  ~purpose:"Shows room pulse, connection state, and high-level counts."
                  ~problem_solved:"Avoids local reasoning on top of stale room context."
                  ~when_active:"Continuously refreshed with dashboard data."
                  ~agent_role:"Agents can use it as a cheap room summary."
                  ~ecosystem_function:"Maintains a common operational baseline."
                  [
                    metric ~id:"side_rail.snapshot.events" ~label:"Events"
                      ~what_it_measures:"Whether the dashboard is receiving live SSE updates."
                      ~why_it_exists:"Freshness-sensitive conclusions are meaningless if the feed is stale."
                      ~source_path:"sse.connected + sse.eventCount"
                      ~update_trigger:"SSE events / reconnect state"
                      ~agent_behavior_effect:"Agents should be more conservative when transport is degraded."
                      ~ecosystem_effect:"Preserves shared reality across the room."
                      ~interpretation:"A healthy feed means the rest of the UI can be trusted more."
                      ~bad_smell:"Everything looks calm because updates stopped."
                      ~next_action:"Recover the feed or refresh manually."
                  ];
                panel ~id:"side_rail.quick_actions" ~title:"Quick Actions"
                  ~purpose:"Enables low-cost nudges before heavier intervention workflows."
                  ~problem_solved:"Cuts the latency to simple room corrections."
                  ~when_active:"When the rail fold is open."
                  ~agent_role:"Agents can map a small nudge to a room-level coordination action."
                  ~ecosystem_function:"Lets the ecosystem self-correct before full operator escalation."
                  [];
              ];
            surface ~id:"mission" ~label:"Mission"
              ~purpose:"Serves as the triage-first landing view for room incidents and next actions."
              ~problem_solved:"Answers what matters now before the user opens deeper control surfaces."
              ~when_active:"Default landing tab and first-stop operational briefing."
              ~agent_role:"Agents can use it to summarize the room’s immediate supervisory priorities."
              ~ecosystem_function:"Compresses room pressure into a single dispatchable briefing."
              [
                panel ~id:"mission.hero" ~title:"지금 가장 먼저 볼 것"
                  ~purpose:"Highlights the top incident and top action in one place."
                  ~problem_solved:"Stops critical room issues from being buried in lists."
                  ~when_active:"Mission landing."
                  ~agent_role:"Agents should use this to explain why a room needs attention now."
                  ~ecosystem_function:"Directs human attention to the highest leverage intervention."
                  [];
                panel ~id:"mission.focus" ~title:"운영 포커스"
                  ~purpose:"Summarizes command-plane posture in mission language."
                  ~problem_solved:"Bridges high-level mission posture and detailed command data."
                  ~when_active:"Mission landing."
                  ~agent_role:"Agents can explain whether the room needs observation, intervention, or deep command work."
                  ~ecosystem_function:"Links top-line pressure with execution structure."
                  [
                    metric ~id:"mission.focus.active_lanes" ~label:"활성 레인"
                      ~what_it_measures:"How many swarm lanes are currently active."
                      ~why_it_exists:"The mission surface needs a compact representation of moving execution."
                      ~source_path:"mission.command_focus.swarm_overview.active_lanes"
                      ~update_trigger:"Mission refresh / command refresh"
                      ~agent_behavior_effect:"Low motion may justify intervention or command-plane inspection."
                      ~ecosystem_effect:"Represents current swarm liveliness."
                      ~interpretation:"Active lanes show room movement, not output quality."
                      ~bad_smell:"High urgency with no visible execution motion."
                      ~next_action:"Open command swarm detail."
                  ];
                panel ~id:"mission.incidents" ~title:"우선 Incident"
                  ~purpose:"Ranks current room incidents."
                  ~problem_solved:"Prevents the operator from treating every anomaly equally."
                  ~when_active:"Mission landing."
                  ~agent_role:"Agents can treat top incidents as explanation or action targets."
                  ~ecosystem_function:"Concentrates room-wide supervision pressure."
                  [];
                panel ~id:"mission.actions" ~title:"추천 액션"
                  ~purpose:"Shows the smallest backend-suggested corrections."
                  ~problem_solved:"Reduces overreaction and aimless control hopping."
                  ~when_active:"Mission landing."
                  ~agent_role:"Agents can turn these into explicit intervention suggestions."
                  ~ecosystem_function:"Connects room observation to concrete corrective action."
                  [];
                panel ~id:"mission.sessions" ~title:"집중 세션"
                  ~purpose:"Shows which sessions are driving mission pressure."
                  ~problem_solved:"Localizes room issues to the session level."
                  ~when_active:"Mission landing."
                  ~agent_role:"Agents can decide which session deserves direct supervision."
                  ~ecosystem_function:"Allocates supervisory attention across sessions."
                  [];
                panel ~id:"mission.session_detail" ~title:"세션 상세"
                  ~purpose:"Presents one session as the primary observational unit."
                  ~problem_solved:"Lets the operator read goal, actors, recent events, and linked execution in one view."
                  ~when_active:"When a session is selected or auto-focused on Mission."
                  ~agent_role:"Agents should explain a session as one coherent unit instead of scattering details across surfaces."
                  ~ecosystem_function:"Unifies collaboration and execution evidence around the chosen session."
                  [];
                panel ~id:"mission.targets" ~title:"바로 개입할 대상"
                  ~purpose:"Lists keepers or sessions that are immediate intervention candidates."
                  ~problem_solved:"Turns mission signal into actionable target selection."
                  ~when_active:"Mission landing."
                  ~agent_role:"Agents use it to decide who to message or steer next."
                  ~ecosystem_function:"Narrows intervention from room-level to actor-level."
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
                  ~purpose:"Makes the confirm gate explicit for disruptive actions."
                  ~problem_solved:"Prevents previewed interventions from being mistaken as executed."
                  ~when_active:"Only when there are preview tokens."
                  ~agent_role:"Agents should explain these as governance debt, not completed work."
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
                      ~source_path:"/api/v1/command-plane/swarm -> summary.pass_end_to_end"
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
                      ~source_path:"/api/v1/command-plane/swarm -> provider.runtime_blocker"
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
                      ~source_path:"/api/v1/command-plane/swarm -> recommended_next_tool"
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
