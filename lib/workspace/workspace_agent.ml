(** Workspace_agent -- agent-status surface removed (2026-06-09).

    The disk-backed [.masc/agents/] registry producer
    ([Workspace_eio.register_agent]) had zero call sites, so the read surface
    here (get_agents_status / register_capabilities / update_agent_r /
    find_agents_by_capability) returned empty for ~12 days and the dashboard
    judge produced 0 judgments. Live agent status is served by the in-memory
    session registry ([Session.get_agent_statuses], exposed via the `who`
    resource). The module is retained only to re-export [Workspace_utils] /
    [Workspace_state] through [Workspace]. See PR body for the analysis. *)

include Workspace_utils
include Workspace_state
