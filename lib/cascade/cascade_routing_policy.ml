(** Routing Policy — the Switchboard side of Phonebook/Switchboard.

    Maps 6 task_use categories to tier-groups with diversity constraints.
    All routing intelligence lives here; the phonebook TOML is data-only.

    Replaces the old 18-variant [logical_use] in {!Cascade_ref} with a
    simplified 6-variant [task_use] that covers all keeper/supervisor
    routing needs without over-specification. *)

(* ── Task Use (6 categories) ─────────────────────────────────── *)

(** The 6 routing categories for cascade task dispatch.

    Every former [logical_use] variant maps into one of these.
    Cross-verification and adversarial review are handled by diversity
    constraints on the [Code_review] task_use, not by separate variants. *)
type task_use =
  | Code_generation  (* synthesis, refactoring, translation *)
  | Code_review      (* analysis, audit, adversarial review, cross-verify *)
  | Quick_decision   (* classification, triage, short answer *)
  | Long_reasoning   (* planning, research synthesis, RFC drafting *)
  | Tool_execution   (* function calling, MCP tool use, structured output *)
  | Conversation     (* general chat, explanation, user interaction *)
[@@deriving show, eq]

let task_use_to_string = function
  | Code_generation -> "code_generation"
  | Code_review -> "code_review"
  | Quick_decision -> "quick_decision"
  | Long_reasoning -> "long_reasoning"
  | Tool_execution -> "tool_execution"
  | Conversation -> "conversation"

let task_use_of_string = function
  | "code_generation" -> Some Code_generation
  | "code_review" -> Some Code_review
  | "quick_decision" -> Some Quick_decision
  | "long_reasoning" -> Some Long_reasoning
  | "tool_execution" -> Some Tool_execution
  | "conversation" -> Some Conversation
  | _ -> None

(* ── Routing Policy ──────────────────────────────────────────── *)

(** Which tier-group to use for a given task, and any diversity constraint
    when selecting from non-primary tier-groups. *)
type task_routing_policy =
  { task : task_use
  ; primary_tier_group : string
  ; diversity : Cascade_phonebook_types.diversity_constraint option
  }
[@@deriving show, eq]

(** Default routing policies.

    These encode the Switchboard's intelligence. The phonebook only
    says which models exist; these policies say which tier-group to use.

    - Code_generation → primary (largest model, best quality)
    - Code_review → cross-verify (diverse from primary for independent review)
    - Quick_decision → primary (fast, high quality)
    - Long_reasoning → primary (needs deep thinking)
    - Tool_execution → primary (needs tool support)
    - Conversation → primary (general purpose) *)
let default_routing_policies : task_routing_policy list =
  [ { task = Code_generation; primary_tier_group = "primary"; diversity = None }
  ; { task = Code_review
    ; primary_tier_group = "cross-verify"
    ; diversity = Some Cascade_phonebook_types.Diverse_from_primary
    }
  ; { task = Quick_decision; primary_tier_group = "primary"; diversity = None }
  ; { task = Long_reasoning; primary_tier_group = "primary"; diversity = None }
  ; { task = Tool_execution; primary_tier_group = "primary"; diversity = None }
  ; { task = Conversation; primary_tier_group = "primary"; diversity = None }
  ]

(* ── Resolution ──────────────────────────────────────────────── *)

(** Resolve a task_use to its routing policy. *)
let policy_for_task (policies : task_routing_policy list) (task : task_use) :
    task_routing_policy option =
  List.find_opt (fun (p : task_routing_policy) -> p.task = task) policies

(** Check that a candidate model satisfies the diversity constraint
    relative to the primary tier-group's provider(s). *)
let satisfies_diversity
    (pb : Cascade_phonebook_types.cascade_phonebook)
    (primary_tg : Cascade_phonebook_types.cascade_phonebook_tier_group)
    (constraint_ : Cascade_phonebook_types.diversity_constraint option)
    (candidate : Cascade_phonebook_types.cascade_phonebook_model)
  : bool =
  match constraint_ with
  | None | Some Cascade_phonebook_types.Any_available -> true
  | Some Cascade_phonebook_types.Same_provider ->
    let primary_providers =
      List.filter_map
        (fun mid ->
           Option.map
             (fun (m : Cascade_phonebook_types.cascade_phonebook_model) -> m.provider)
             (Cascade_phonebook_types.model_of_id pb mid))
        primary_tg.members
    in
    List.mem candidate.provider primary_providers
  | Some Cascade_phonebook_types.Diverse_from_primary ->
    let primary_providers =
      List.filter_map
        (fun mid ->
           Option.map
             (fun (m : Cascade_phonebook_types.cascade_phonebook_model) -> m.provider)
             (Cascade_phonebook_types.model_of_id pb mid))
        primary_tg.members
    in
    not (List.mem candidate.provider primary_providers)

(** Resolve a tier-group name to its member model IDs via the phonebook,
    filtering by the policy's diversity constraint.

    For [Diverse_from_primary], the primary tier-group named in the
    [Code_generation] policy provides the provider baseline; models in
    the target tier-group whose providers overlap are excluded. *)
let resolve_models_for_task
    (pb : Cascade_phonebook_types.cascade_phonebook)
    (policies : task_routing_policy list)
    (task : task_use)
  : Cascade_phonebook_types.cascade_phonebook_model list =
  match policy_for_task policies task with
  | None -> []
  | Some policy ->
    match Cascade_phonebook_types.tier_group_of_name pb policy.primary_tier_group with
    | None -> []
    | Some tg ->
      let models = Cascade_phonebook_types.models_of_tier_group pb tg in
      let primary_tg =
        (* When the target tier-group is not "primary" itself, use the
           primary tier-group as the diversity baseline. *)
        if policy.primary_tier_group <> "primary" then
          Cascade_phonebook_types.tier_group_of_name pb "primary"
        else Some tg
      in
      match primary_tg with
      | None -> models
      | Some ptg ->
        List.filter (satisfies_diversity pb ptg policy.diversity) models
