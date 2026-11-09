module R = Repository_pulls

type attention =
  | Checks_failing
  | Changes_requested
  | Conflicting
  | Unreviewed_on_head
  | Awaiting_approval
[@@deriving enumerate, eq]

type not_listed =
  | Draft
  | Checks_running
  | Reviewed_on_head
  | Review_history_incomplete
  | Head_review_unknown
[@@deriving enumerate, eq]

type placement =
  | Needs of attention
  | Not_listed of not_listed
[@@deriving eq]

let all =
  List.map (fun attention -> Needs attention) all_of_attention
  @ List.map (fun listed -> Not_listed listed) all_of_not_listed
;;

let to_string = function
  | Needs Checks_failing -> "checks_failing"
  | Needs Changes_requested -> "changes_requested"
  | Needs Conflicting -> "conflicting"
  | Needs Unreviewed_on_head -> "unreviewed_on_head"
  | Needs Awaiting_approval -> "awaiting_approval"
  | Not_listed Draft -> "draft"
  | Not_listed Checks_running -> "checks_running"
  | Not_listed Reviewed_on_head -> "reviewed_on_head"
  | Not_listed Review_history_incomplete -> "review_history_incomplete"
  | Not_listed Head_review_unknown -> "head_review_unknown"
;;

let equal = equal_placement

(* [all] holds every placement, so the walk always finds it; the end of the
   list answers the length only to keep the function total. *)
let rank placement =
  let rec position index = function
    | [] -> index
    | candidate :: rest -> if equal candidate placement then index else position (index + 1) rest
  in
  position 0 all
;;

(* What the review decision says about approval once row 3 has taken the
   changes-requested pull requests out. A review of any verdict sits "on the
   head" (a comment, a dismissed approval, a line written by the author), so
   only the decision tells a head that is done from a head GitHub still holds
   for an approval. *)
type approval =
  | Approval_pending
  | Approval_settled

(* Rows 4 to 6 of the table. Every constructor of the mergeable and
   head-review columns is written, so a new constructor in
   {!Repository_pulls} fails to compile here until the table says where it
   goes. *)
let from_mergeable ~approval ~running (pull : R.pull_request) =
  match pull.mergeable with
  | R.Conflicting -> Needs Conflicting
  | R.Mergeable | R.Mergeable_unknown ->
    if running
    then Not_listed Checks_running
    else (
      match R.head_review_of pull with
      | R.Not_reviewed_on_head -> Needs Unreviewed_on_head
      | R.Review_history_incomplete -> Not_listed Review_history_incomplete
      | R.Reviewed_on_head ->
        (match approval with
         | Approval_pending -> Needs Awaiting_approval
         | Approval_settled -> Not_listed Reviewed_on_head)
      | R.Head_review_unknown -> Not_listed Head_review_unknown)
;;

(* Rows 3 to 6 of the table. *)
let after_checks ~running (pull : R.pull_request) =
  match pull.review with
  | R.Review_changes_requested -> Needs Changes_requested
  | R.Review_waiting -> from_mergeable ~approval:Approval_pending ~running pull
  | R.Review_approved | R.Review_none -> from_mergeable ~approval:Approval_settled ~running pull
;;

let placement_of (pull : R.pull_request) =
  if pull.draft
  then Not_listed Draft
  else (
    match pull.checks with
    | R.Checks_failing -> Needs Checks_failing
    | R.Checks_running -> after_checks ~running:true pull
    | R.Checks_passing | R.Checks_none -> after_checks ~running:false pull)
;;
