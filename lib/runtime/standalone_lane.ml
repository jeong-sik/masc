(* [all] is derived in constructor order, the order the runtime file editor
   and the route error list use. *)
type t =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Verifier
  | Candle_appraiser
  | Librarian_memory
  | Workspace_memory_curator
[@@deriving enumerate]

let run_identity = function
  | Librarian -> Lane_run_identity.Librarian
  | Hitl_auto_judge -> Lane_run_identity.Hitl_auto_judge
  | Board_attention -> Lane_run_identity.Board_attention
  | Verifier -> Lane_run_identity.Verifier
  | Candle_appraiser -> Lane_run_identity.Candle_appraiser
  | Librarian_memory -> Lane_run_identity.Librarian_memory
  | Workspace_memory_curator -> Lane_run_identity.Workspace_memory_curator
;;

let to_id lane = Lane_run_identity.to_id (run_identity lane)

let equal (left : t) (right : t) = left = right

(* Read back through [to_id], so no id is spelled a second time. *)
let of_id id = List.find_opt (fun lane -> String.equal (to_id lane) id) all

type obligation =
  | Required
  | Optional

(* Board attention candidates persist before any model call and never expire,
   so without this lane no Board post between Keepers is ever judged. HITL auto
   judge was required before this list moved here; the reason is not recorded
   in the code (RFC every-lane-is-one-row-in-one-registry, decision d3). *)
let obligation = function
  | Board_attention | Hitl_auto_judge -> Required
  | Librarian | Verifier | Candle_appraiser | Librarian_memory | Workspace_memory_curator -> Optional
;;

(* Interactive chat turns reserve [Priority]. Standalone verdicts
   ([Verifier], [Hitl_auto_judge], [Board_attention], [Candle_appraiser]) run
   as [Standard] so judgment loops never contend at interactive chat priority,
   while [Librarian], [Librarian_memory], and [Workspace_curator] run as
   [Background]. Background service remains bounded by the provider's declared
   run limit. *)
let admission_class : t -> Llm_provider.Admission_class.t = function
  | Librarian | Librarian_memory | Workspace_memory_curator -> Background
  | Verifier | Hitl_auto_judge | Board_attention | Candle_appraiser -> Standard
;;

let required_ids =
  List.filter_map
    (fun lane ->
       match obligation lane with
       | Required -> Some (to_id lane)
       | Optional -> None)
    all
;;
