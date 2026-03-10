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
            surface ~id:"agents" ~label:"Agents"
              ~purpose:"Shows live execution actors and long-lived keepers side by side."
              ~problem_solved:"Separates short-horizon work health from long-horizon continuity health."
              ~when_active:"Used when the operator asks who is stale, overloaded, or gone."
              ~agent_role:"Agents can compare their own state with room-wide posture."
              ~ecosystem_function:"Makes execution and continuity pressure inspectable."
              [
                panel ~id:"agents.attention_queue" ~title:"Attention Queue"
                  ~purpose:"Ranks agents and keepers that need attention first."
                  ~problem_solved:"Reduces scanning cost across heterogeneous actors."
                  ~when_active:"Top of Agents."
                  ~agent_role:"A supervising agent can use the first rows as the immediate correction targets."
                  ~ecosystem_function:"Concentrates oversight where degradation is fastest."
                  [];
                panel ~id:"agents.active_agents" ~title:"Active Agents"
                  ~purpose:"Monitors short-horizon execution actors."
                  ~problem_solved:"Shows whether active work still has a fresh signal."
                  ~when_active:"Normal execution."
                  ~agent_role:"Each agent is expected to keep ownership and freshness coherent here."
                  ~ecosystem_function:"Makes execution drift visible before tasks rot."
                  [];
                panel ~id:"agents.keeper_watch" ~title:"Keeper Watch"
                  ~purpose:"Monitors long-lived keepers for continuity risk."
                  ~problem_solved:"Prevents slow-burn keeper degradation from being missed."
                  ~when_active:"When keepers are part of the room."
                  ~agent_role:"Keepers are expected to maintain heartbeat, continuity, and sane context pressure."
                  ~ecosystem_function:"Preserves long-term memory and autonomy continuity."
                  [];
                panel ~id:"agents.offline_agents" ~title:"Offline Agents"
                  ~purpose:"Preserves dropout visibility."
                  ~problem_solved:"Stops disappeared executors from silently vanishing from memory."
                  ~when_active:"When agents leave or go stale."
                  ~agent_role:"Agents that exit without clean handoff create risk here."
                  ~ecosystem_function:"Maintains accountability across churn."
                  [];
              ];
            surface ~id:"board" ~label:"Board"
              ~purpose:"Acts as the room’s asynchronous discussion and deliberation memory."
              ~problem_solved:"Lets humans and agents coordinate without requiring simultaneity."
              ~when_active:"Used for posts, debates, and voting."
              ~agent_role:"Agents publish findings, discuss, debate, and leave context for later readers."
              ~ecosystem_function:"Provides the social memory layer."
              [
                panel ~id:"board.post_feed" ~title:"Posts / Comments"
                  ~purpose:"Shows durable coordination context and its local discussion."
                  ~problem_solved:"Prevents ad-hoc reasoning from disappearing after the current session."
                  ~when_active:"Posts list and post detail."
                  ~agent_role:"Agents leave findings and status here for humans and other agents."
                  ~ecosystem_function:"Turns coordination into durable memory."
                  [];
                panel ~id:"board.debates" ~title:"Debates"
                  ~purpose:"Supports structured disagreement on design or policy."
                  ~problem_solved:"Prevents important disagreements from dissolving into untracked chat."
                  ~when_active:"Debates subview."
                  ~agent_role:"Agents contribute explicit support/oppose/neutral arguments."
                  ~ecosystem_function:"Turns conflict into inspectable reasoning."
                  [];
                panel ~id:"board.voting" ~title:"Voting"
                  ~purpose:"Tracks formal consensus closure."
                  ~problem_solved:"Prevents debates from lingering without an explicit decision state."
                  ~when_active:"Voting subview."
                  ~agent_role:"Agents cast approve/reject/abstain with reasons."
                  ~ecosystem_function:"Turns deliberation into governance."
                  [];
              ];
            surface ~id:"goals" ~label:"Goals"
              ~purpose:"Aligns direction, metric loops, and backlog posture."
              ~problem_solved:"Separates strategic intent from raw task churn."
              ~when_active:"Used when planning, reviewing, or checking numeric iteration."
              ~agent_role:"Agents read goals for intent, MDAL for movement, and backlog for obligation."
              ~ecosystem_function:"Bridges long-horizon direction with short-horizon execution."
              [
                panel ~id:"goals.planning_surface" ~title:"Planning Surface"
                  ~purpose:"Explains how goals and MDAL loops complement each other."
                  ~problem_solved:"Prevents planning from collapsing into vague aspiration or metric myopia."
                  ~when_active:"Top of Goals."
                  ~agent_role:"Agents should infer both intent and acceptance pressure here."
                  ~ecosystem_function:"Bridges strategy and iteration."
                  [];
                panel ~id:"goals.goal_pipeline" ~title:"Goal Pipeline"
                  ~purpose:"Groups strategic intent by horizon."
                  ~problem_solved:"Prevents all goals from being treated as equally urgent."
                  ~when_active:"Any planning session."
                  ~agent_role:"Agents should understand which time horizon they are serving."
                  ~ecosystem_function:"Maintains temporal structure in room priorities."
                  [];
                panel ~id:"goals.mdal_loops" ~title:"MDAL Loops"
                  ~purpose:"Shows whether strict metric-driven loops are actually improving."
                  ~problem_solved:"Prevents endless iteration without measured movement."
                  ~when_active:"When MDAL is in play."
                  ~agent_role:"Agents use this as evidence of progress, not just intent."
                  ~ecosystem_function:"Supplies numeric proof that iteration is worthwhile."
                  [];
                panel ~id:"goals.task_backlog" ~title:"Task Backlog"
                  ~purpose:"Shows the concrete workload under the plan."
                  ~problem_solved:"Prevents planning from ignoring actual execution load."
                  ~when_active:"When goals connect to tasks."
                  ~agent_role:"Agents translate direction into claims and completions here."
                  ~ecosystem_function:"Connects plans to room labor."
                  [];
              ];
            surface ~id:"trpg" ~label:"TRPG"
              ~purpose:"Provides narrative room state and explicit world control."
              ~problem_solved:"Keeps world state, round progression, and intervention coherent."
              ~when_active:"When a TRPG room is active."
              ~agent_role:"Agents can act as DM/player/observer and need to know what layer they are touching."
              ~ecosystem_function:"Provides a sandboxed narrative coordination environment."
              [
                panel ~id:"trpg.overview" ~title:"Overview"
                  ~purpose:"Summarizes session, round, party, and visible world state."
                  ~problem_solved:"Prevents control actions without world awareness."
                  ~when_active:"Overview screen."
                  ~agent_role:"Agents observe world and round posture before acting."
                  ~ecosystem_function:"Maintains narrative situational awareness."
                  [];
                panel ~id:"trpg.timeline" ~title:"Timeline"
                  ~purpose:"Shows the causal event stream of the room."
                  ~problem_solved:"Lets humans and agents inspect what actually happened."
                  ~when_active:"Timeline screen."
                  ~agent_role:"Agents use it to justify claims about world transitions."
                  ~ecosystem_function:"Provides narrative causal memory."
                  [];
                panel ~id:"trpg.control" ~title:"Control"
                  ~purpose:"Contains world-mutating actions and entry gates."
                  ~problem_solved:"Separates dangerous world mutations from passive viewing."
                  ~when_active:"Control screen."
                  ~agent_role:"Agents mutate the room here only after reading the current state."
                  ~ecosystem_function:"Keeps narrative intervention explicit and gated."
                  [];
              ];
          ] );
    ]
