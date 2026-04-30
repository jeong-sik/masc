---- MODULE MASCEcosystem ----
\* Formal specification of the MASC Ecosystem Core Concepts
\* Models the interactions between Agents, Keepers, Personas, and the Room/Board environment.

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS 
    Agents,       \* Set of regular agents (e.g., {"agent1", "agent2"})
    Keepers,      \* Set of persistent keepers (e.g., {"keeper_sangsu", "keeper_helper"})
    Tasks,        \* Set of tasks in the room
    MaxContext    \* Max token capacity for a keeper (e.g., 100)

VARIABLES
    room_agents,     \* Set of normal agents currently in the room
    tasks_status,    \* Function: task -> {"Pending", "InProgress", "Completed"}
    agent_tasks,     \* Function: agent -> task or "None"
    keeper_context,  \* Function: keeper -> context ratio (0..MaxContext)
    keeper_gen,      \* Function: keeper -> generation counter
    board_posts      \* Nat: Total number of posts on the community board

vars == <<room_agents, tasks_status, agent_tasks, keeper_context, keeper_gen, board_posts>>

Init ==
    /\ room_agents = {}
    /\ tasks_status = [t \in Tasks |-> "Pending"]
    /\ agent_tasks = [a \in Agents |-> "None"]
    /\ keeper_context = [k \in Keepers |-> 0]
    /\ keeper_gen = [k \in Keepers |-> 1]
    /\ board_posts = 0

\* ── 1. Agent Lifecycle (Task execution) ───────────────────

AgentJoins(a) ==
    /\ a \notin room_agents
    /\ room_agents' = room_agents \cup {a}
    /\ UNCHANGED <<tasks_status, agent_tasks, keeper_context, keeper_gen, board_posts>>

AgentClaimsTask(a, t) ==
    /\ a \in room_agents
    /\ agent_tasks[a] = "None"
    /\ tasks_status[t] = "Pending"
    /\ agent_tasks' = [agent_tasks EXCEPT ![a] = t]
    /\ tasks_status' = [tasks_status EXCEPT ![t] = "InProgress"]
    /\ UNCHANGED <<room_agents, keeper_context, keeper_gen, board_posts>>

AgentCompletesTask(a) ==
    /\ a \in room_agents
    /\ agent_tasks[a] \in Tasks
    /\ tasks_status' = [tasks_status EXCEPT ![agent_tasks[a]] = "Completed"]
    /\ agent_tasks' = [agent_tasks EXCEPT ![a] = "None"]
    /\ room_agents' = room_agents \ {a} \* Agent leaves the room after finishing the task
    /\ UNCHANGED <<keeper_context, keeper_gen, board_posts>>

\* ── 2 & 5. Keeper Lifecycle & Board Interaction ───────────

KeeperActs(k) ==
    /\ keeper_context[k] < 50
    /\ keeper_context' = [keeper_context EXCEPT ![k] = @ + 10] \* Context increases
    /\ UNCHANGED <<room_agents, tasks_status, agent_tasks, keeper_gen, board_posts>>

KeeperPostsToBoard(k) ==
    /\ keeper_context[k] < 85
    /\ board_posts' = board_posts + 1
    /\ keeper_context' = [keeper_context EXCEPT ![k] = @ + 15] \* Board activity takes more context
    /\ UNCHANGED <<room_agents, tasks_status, agent_tasks, keeper_gen>>

\* ── 4. Core Mechanisms (Compaction & Handoff) ─────────────

KeeperCompacts(k) ==
    /\ keeper_context[k] >= 50
    /\ keeper_context[k] < 85
    /\ keeper_context' = [keeper_context EXCEPT ![k] = @ - 20] \* Compaction reduces context
    /\ UNCHANGED <<room_agents, tasks_status, agent_tasks, keeper_gen, board_posts>>

KeeperHandoff(k) ==
    /\ keeper_context[k] >= 85
    \* Extracts Capsule, increments generation, and resets context baseline
    /\ keeper_gen' = [keeper_gen EXCEPT ![k] = @ + 1]
    /\ keeper_context' = [keeper_context EXCEPT ![k] = 10] \* Remaining context represents the Capsule
    /\ UNCHANGED <<room_agents, tasks_status, agent_tasks, board_posts>>

\* ── Next State & Fairness ─────────────────────────────────

Next ==
    \/ \E a \in Agents: AgentJoins(a)
    \/ \E a \in Agents, t \in Tasks: AgentClaimsTask(a, t)
    \/ \E a \in Agents: AgentCompletesTask(a)
    \/ \E k \in Keepers: KeeperActs(k) 
    \/ \E k \in Keepers: KeeperPostsToBoard(k)
    \/ \E k \in Keepers: KeeperCompacts(k) 
    \/ \E k \in Keepers: KeeperHandoff(k)

Fairness ==
    /\ \A a \in Agents: WF_vars(AgentJoins(a))
    /\ \A a \in Agents, t \in Tasks: WF_vars(AgentClaimsTask(a, t))
    /\ \A a \in Agents: WF_vars(AgentCompletesTask(a))
    /\ \A k \in Keepers: WF_vars(KeeperActs(k))
    /\ \A k \in Keepers: WF_vars(KeeperPostsToBoard(k))
    /\ \A k \in Keepers: WF_vars(KeeperCompacts(k))
    /\ \A k \in Keepers: SF_vars(KeeperHandoff(k)) \* Strong Fairness to ensure handoff preempts memory overflow

Spec == Init /\ [][Next]_vars /\ Fairness

\* ── Safety Properties ─────────────────────────────────────

\* 1. Keeper context NEVER overflows the MaxContext limit (100)
NoContextOverflow == \A k \in Keepers: keeper_context[k] <= MaxContext

\* 2. A normal Agent can only have one task at a time
SingleTaskPerAgent == \A a \in Agents: agent_tasks[a] = "None" \/ agent_tasks[a] \in Tasks

\* 3. A task is claimed by at most one agent at any moment.
\*    SingleTaskPerAgent constrains the per-agent side; this
\*    constrains the per-task side. Required as the prereq for the
\*    DoubleClaim Bug Model (RFC-Q2-3).
AtMostOneAgentPerTask ==
    \A t \in Tasks :
        Cardinality({a \in Agents : agent_tasks[a] = t}) <= 1

\* ── Bug model (RFC-Q2-3) ────────────────────────────────────────
\*
\* Models the bug class where two agents end up claiming the same
\* task — e.g. a race in agent_tasks update without a CAS guard,
\* or a refactor that loses the [tasks_status[t] = "Pending"]
\* check. The clean AgentClaimsTask enforces the precondition;
\* the buggy variant drops it.

DoubleClaim(a, t) ==
    /\ a \in room_agents
    /\ agent_tasks[a] = "None"
    \* deliberately omitted: tasks_status[t] = "Pending"
    /\ \E other \in Agents : agent_tasks[other] = t  \* force overlap
    /\ agent_tasks' = [agent_tasks EXCEPT ![a] = t]
    /\ UNCHANGED <<room_agents, tasks_status, keeper_context,
                   keeper_gen, board_posts>>

NextBuggy ==
    \/ Next
    \/ \E a \in Agents, t \in Tasks : DoubleClaim(a, t)

SpecBuggy == Init /\ [][NextBuggy]_vars /\ Fairness

\* ── Liveness Properties ───────────────────────────────────

\* 3. A Task is eventually completed by an Agent
AllTasksEventuallyCompleted == \A t \in Tasks: (tasks_status[t] = "Pending") ~> (tasks_status[t] = "Completed")

\* 4. A Keeper's memory never stays indefinitely bloated; it eventually compacts or handoffs
MemoryManagementWorks == \A k \in Keepers: [] (keeper_context[k] >= 85 => <> (keeper_context[k] < 85))

====