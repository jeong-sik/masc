(** Prompt_names — SSOT for Prompt_registry template keys
    used by keeper modules.

    All keeper prompt lookups must reference these constants
    instead of string literals. *)

let keeper = "keeper"
let judge_board = "judge.board"
let judge_effect = "judge.effect"
let verification = "verification"
let goal_verification_proof = "goal_verification.proof"
let goal_verification_lookup = "goal_verification.lookup"

(* Review sections rendered as their own templates and injected into the review
   prompt. They live as files so the prose is editable and overridable through
   the operator layer, and so a code change cannot leave the instructions
   stale: [Anti_rationalization] supplies the data and picks the key, and holds
   no review prose of its own. *)
let verification_lookup_none = "verification.lookup.none"
let verification_lookup_producer_tree = "verification.lookup.producer_tree"
let verification_contract = "verification.contract"
let verification_required_evidence = "verification.required_evidence"

(* One key per typed degraded-observation state. Each names what the Keeper may
   and may not conclude from that state, which is prose about a data condition
   and belongs beside the other prompt text rather than inside the projection
   that detects it. *)
let keeper_observation_recovered_current_task =
  "keeper.observation.recovered_current_task"
;;

let keeper_observation_current_task_absent = "keeper.observation.current_task_absent"

let keeper_observation_current_task_absent_in_recovery =
  "keeper.observation.current_task_absent_in_recovery"
;;

let keeper_observation_current_task_unobservable =
  "keeper.observation.current_task_unobservable"
;;

let keeper_observation_rejected_digest_heading =
  "keeper.observation.rejected_digest_heading"
;;

let keeper_observation_rejected_digest_row = "keeper.observation.rejected_digest_row"
let keeper_current_task_skills = "keeper.current_task.skills"
let keeper_held_task_skills = "keeper.held_task.skills"
let keeper_held_task_skills_heading = "keeper.held_task.skills_heading"
let librarian = "librarian"

(* Runtime-owned instruction assets.  A caller may supply data to these
   templates, but the instruction wording itself never lives beside the
   execution path. *)
let fusion_judge = "fusion.judge"
let fusion_judge_refine = "fusion.judge.refine"
let fusion_judge_meta = "fusion.judge.meta"
let fusion_judge_output = "fusion.judge.output"
let mcp_full = "mcp.full"
let mcp_managed_agent = "mcp.managed_agent"
let mcp_operator_remote = "mcp.operator_remote"
let keeper_workspace = "keeper.workspace"
let keeper_identity = "keeper.identity"
let keeper_canary_judge_system = "keeper.canary.judge.system"
let keeper_canary_judge_user = "keeper.canary.judge.user"
let keeper_canary_recall = "keeper.canary.recall"
let keeper_capability_probe = "keeper.capability_probe"
let lane_cli_probe_librarian_system = "lane_cli_probe.librarian.system"
let lane_cli_probe_librarian_user = "lane_cli_probe.librarian.user"
let lane_cli_probe_hitl_system = "lane_cli_probe.hitl.system"
let lane_cli_probe_hitl_user = "lane_cli_probe.hitl.user"
let keeper_antigravity_system_instructions_label = "keeper.antigravity.system_instructions_label"
let keeper_antigravity_current_goal_label = "keeper.antigravity.current_goal_label"
let eval_calibration_few_shot = "eval.calibration.few_shot"
let eval_calibration_few_shot_example = "eval.calibration.few_shot.example"

(* Repository checkout freshness — one fragment per line part, so an
   operator can reword any of them without an OCaml change. *)
let keeper_context_checkouts_section = "keeper.context.checkouts.section"
let keeper_context_checkouts_row = "keeper.context.checkouts.row"
let keeper_context_checkouts_standing_current = "keeper.context.checkouts.standing.current"
let keeper_context_checkouts_standing_ahead = "keeper.context.checkouts.standing.ahead"
let keeper_context_checkouts_standing_behind = "keeper.context.checkouts.standing.behind"
let keeper_context_checkouts_standing_diverged = "keeper.context.checkouts.standing.diverged"
let keeper_context_checkouts_standing_unavailable = "keeper.context.checkouts.standing.unavailable"
let keeper_context_checkouts_unmeasured = "keeper.context.checkouts.unmeasured"

(* Approval authority — the same split, so the state wording is an
   operator surface rather than an OCaml literal. *)
let keeper_context_approval_authority_heading = "keeper.context.approval_authority.heading"
let keeper_context_approval_authority_state_complete = "keeper.context.approval_authority.state.complete"
let keeper_context_approval_authority_state_partial = "keeper.context.approval_authority.state.partial"
let keeper_context_approval_authority_state_unavailable = "keeper.context.approval_authority.state.unavailable"
let keeper_context_approval_authority_footer = "keeper.context.approval_authority.footer"
