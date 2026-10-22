(* [all] is derived in constructor order, the order the runtime file editor
   and the route error list use. *)
type t =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Workspace_curator
  | Verifier
  | Browser_stagehand
  | Candle_appraiser
[@@deriving enumerate]

let run_identity = function
  | Librarian -> Lane_run_identity.Librarian
  | Hitl_auto_judge -> Lane_run_identity.Hitl_auto_judge
  | Board_attention -> Lane_run_identity.Board_attention
  | Workspace_curator -> Lane_run_identity.Workspace_curator
  | Verifier -> Lane_run_identity.Verifier
  | Browser_stagehand -> Lane_run_identity.Browser_stagehand
  | Candle_appraiser -> Lane_run_identity.Candle_appraiser
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
  | Librarian | Workspace_curator | Verifier | Browser_stagehand | Candle_appraiser -> Optional
;;

(* Other work waits on these three verdicts: a task's completion on the
   verifier, an operator's confirmation on the HITL judge, and what a Keeper
   looks at next on board attention. Librarian maintenance shares provider
   permits with the Keeper's own tool loop, but must not repeatedly put that
   loop behind the whole fleet's memory queue. Background service remains
   bounded by the provider's declared run limit. *)
let admission_class : t -> Llm_provider.Admission_class.t = function
  | Verifier | Hitl_auto_judge | Board_attention -> Priority
  | Librarian -> Background
  | Workspace_curator | Browser_stagehand | Candle_appraiser -> Standard
;;

let required_ids =
  List.filter_map
    (fun lane ->
       match obligation lane with
       | Required -> Some (to_id lane)
       | Optional -> None)
    all
;;
