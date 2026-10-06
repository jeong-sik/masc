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

let to_id = function
  | Librarian -> "librarian_exact"
  | Hitl_auto_judge -> "hitl_auto_judge"
  | Board_attention -> "board_attention_exact"
  | Workspace_curator -> "workspace_curator_exact"
  | Verifier -> "verifier_exact"
  | Browser_stagehand -> "browser_stagehand_exact"
  | Candle_appraiser -> "candle_appraiser"
;;

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
   looks at next on board attention. The librarian's requests are large and
   nothing waits on them; a priority permit held by one would stall the
   judgment lanes again (RFC judgment-lanes-take-account-admission-before-
   keeper-turns). *)
let admission_class : t -> Llm_provider.Admission_class.t = function
  | Verifier | Hitl_auto_judge | Board_attention -> Priority
  | Librarian | Workspace_curator | Browser_stagehand | Candle_appraiser -> Standard
;;

let required_ids =
  List.filter_map
    (fun lane ->
       match obligation lane with
       | Required -> Some (to_id lane)
       | Optional -> None)
    all
;;
