(** Currently configurable builtin exact-output routes outside a Keeper turn.
    Each is one [\[runtime.exact_output_lanes.<id>\]] table and one row of the
    standalone-lane projection. Retained observations have the independent
    {!Lane_run_identity.t} vocabulary; route removal cannot erase that history.

    [Runtime.exact_lane] is this type. [Exact_lane_run_registry.lane] is its
    own type without [Verifier], and
    [run_identity] matches every current route explicitly, so adding one must
    state its original observation identity. *)

(** [all] (derived) lists every lane once, in declaration order. *)
type t =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Verifier
  | Candle_appraiser
  | Librarian_memory
[@@deriving enumerate]

val to_id : t -> string
(** Current route's table/projection key, derived from {!run_identity}. *)

val run_identity : t -> Lane_run_identity.t
(** Observation identity of this current builtin route. The converse is not
    an execution/configuration capability: retained records can outlive a route. *)

val equal : t -> t -> bool

val of_id : string -> t option
(** The lane whose {!to_id} is the argument. An id no lane has is [None]. *)

type obligation =
  | Required
  | Optional

val obligation : t -> obligation
(** Whether a server may run without the lane. This is the one place that
    says so: the exact-output registry refuses a publication or a config
    commit that leaves a [Required] lane without an admitted slot, and the
    standalone-lane projection draws the same answer. *)

val admission_class : t -> Llm_provider.Admission_class.t
(** The admission queue the lane's provider requests join. It orders permit
    waits only on an account that declares [admission-priority-run-limit].
    This is the one place that says which lanes go first: the verifier's
    reviewer config and every exact flow masc opens read their class here.
    [Librarian] and [Librarian_memory] use [Background]; [Verifier],
    [Hitl_auto_judge], [Board_attention], and [Candle_appraiser] use
    [Standard], reserving [Priority] for interactive chat turns. A background
    request still receives bounded service while higher classes wait; running
    requests are not preempted. *)

type caller_lane =
  | Interactive_chat
  | Standalone of t
  | Workspace_curator

val admission_class_of_caller : caller_lane -> Llm_provider.Admission_class.t
(** Closed admission classification across interactive chat, standalone lanes,
    and workspace curation:
    - [Interactive_chat] -> [Priority]
    - [Standalone (Verifier | Hitl_auto_judge | Board_attention | Candle_appraiser)] -> [Standard]
    - [Standalone (Librarian | Librarian_memory) | Workspace_curator] -> [Background] *)

val required_ids : string list
(** The {!to_id} of every [Required] lane, in {!all} order: the
    [required_lane_ids] the exact-output registry is published with. *)
