(** Governance pipeline — risk assessment and trifecta capability analysis.

    Implements Simon Willison's "Lethal Trifecta" detection:
    an agent simultaneously holding
    (1) untrusted external input,
    (2) sensitive data access, and
    (3) state modification capability = security incident.

    Meta AI's "Rule of Two" mitigation: when all 3 capability classes are
    active, escalate [State_modification] tools to at least [High] risk
    to fire HITL gates earlier.

    Capability classification and risk patterns live in code (not TOML)
    because a change is a security policy change requiring review. *)

open Governance_pipeline_types

(** {1 Tool capability classification} *)

(** Lookup the capability classes declared for [tool_name].
    Returns [[]] when the tool is not classified. *)
val tool_capabilities : string -> capability_class list

(** {1 Trifecta assessment} *)

(** [assess_trifecta ~active_tool_names] scans the active tool set and
    returns [(class_count, has_external, has_sensitive, has_state_mod)].

    [class_count] is the number of capability classes present (0–3).
    The trifecta is active when [class_count = 3]. *)
val assess_trifecta :
  active_tool_names:string list -> int * bool * bool * bool

(** [combinatorial_risk_escalation ~trifecta_active ~tool_name ~base_risk
    ~input] lifts [base_risk] to at least [High] when the trifecta is
    active and [tool_name] has [State_modification] capability.

    [keeper_shell] read-only github ops are exempt (checked via
    [Keeper_tool_registry.is_read_only_with_input]). *)
val combinatorial_risk_escalation :
  trifecta_active:bool ->
  tool_name:string ->
  base_risk:risk_level ->
  input:Yojson.Safe.t ->
  risk_level

(** {1 Risk assessment} *)

(** [assess_risk ~tool_name ~input] computes the final risk level for a
    tool invocation by combining:

    {ul
    {- payload-based classification (destructive content detection,
       empty-overwrite guard) — [Critical] short-circuit}
    {- metadata (Tool_catalog.destructive / readonly flags)}
    {- explicit per-tool overrides}
    {- [masc_transition] action pattern matching}
    {- substring pattern matching over [tool_name]}
    {- keeper mutation floor ([High] minimum for
       [keeper_fs_edit] / [keeper_write] / non-read-only [keeper_shell])}} *)
val assess_risk :
  tool_name:string -> input:Yojson.Safe.t -> risk_level
