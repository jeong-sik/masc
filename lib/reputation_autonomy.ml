(** Reputation_autonomy — Dynamic autonomy level derived from agent reputation.

    @since v2 Accountability & Reputation Roadmap
*)

type autonomy_level =
  | Restricted
  | Standard
  | Elevated
  | Full

let autonomy_level_to_string = function
  | Restricted -> "restricted"
  | Standard   -> "standard"
  | Elevated   -> "elevated"
  | Full       -> "full"

let autonomy_level_of_string = function
  | "restricted" -> Some Restricted
  | "standard"   -> Some Standard
  | "elevated"   -> Some Elevated
  | "full"       -> Some Full
  | _            -> None

(** {1 Thresholds}

    These constants define the boundary conditions for autonomy promotion.

    Design intent (v2 roadmap Phase 5):
    - All four dimensions must meet or exceed their threshold for promotion.
    - [safety_compliance] is the strictest gate: any active violation drops
      the agent to [Restricted] regardless of other dimensions.
    - The constants are intentionally explicit here so a future governance
      layer can override them via runtime parameters (RFC-0001). *)

let safety_floor_restricted  = 0.5
let safety_floor_standard    = 0.8
let safety_floor_elevated    = 0.9
let safety_floor_full        = 1.0

let reliability_floor_standard  = 0.6
let reliability_floor_elevated  = 0.8
let reliability_floor_full      = 0.9

let adherence_floor_standard  = 0.5
let adherence_floor_elevated  = 0.7
let adherence_floor_full      = 0.85

let accountability_floor_standard  = 0.4
let accountability_floor_elevated  = 0.7
let accountability_floor_full      = 0.85

let compute_autonomy_level
    ~execution_reliability
    ~goal_adherence
    ~safety_compliance
    ~accountability_score
    : autonomy_level =
  (* Safety compliance is the primary gate: a score below the restricted
     floor means the agent has too many active violations for any autonomy. *)
  if safety_compliance < safety_floor_restricted then Restricted
  else if
    safety_compliance >= safety_floor_full
    && execution_reliability >= reliability_floor_full
    && goal_adherence >= adherence_floor_full
    && accountability_score >= accountability_floor_full
  then Full
  else if
    safety_compliance >= safety_floor_elevated
    && execution_reliability >= reliability_floor_elevated
    && goal_adherence >= adherence_floor_elevated
    && accountability_score >= accountability_floor_elevated
  then Elevated
  else if
    safety_compliance >= safety_floor_standard
    && execution_reliability >= reliability_floor_standard
    && goal_adherence >= adherence_floor_standard
    && accountability_score >= accountability_floor_standard
  then Standard
  else Restricted

let describe_autonomy_constraints = function
  | Restricted ->
    "Read-only and safe tools only. Consequential actions require \
     human-in-the-loop approval."
  | Standard ->
    "Standard tool set with normal token budget."
  | Elevated ->
    "Expanded tool access including higher-impact tools. Increased token \
     budget available."
  | Full ->
    "Broadest tool surface and maximum budget. May participate in peer \
     approval of other agents."

let autonomy_level_to_json level =
  `Assoc
    [ ("level", `String (autonomy_level_to_string level))
    ; ("description", `String (describe_autonomy_constraints level))
    ]
