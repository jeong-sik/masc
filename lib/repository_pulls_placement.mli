(** Where one open pull request stands, read from the facts of
    {!Repository_pulls} (RFC keeper-world-state-shows-open-work §4.2).

    A pull request has exactly one placement, the first row of this table it
    meets:

    {v
    1  draft                                  Not_listed Draft
    2  checks failing                         Needs Checks_failing
    3  review decision: changes requested     Needs Changes_requested
    4  mergeable: conflicting                 Needs Conflicting
    5  checks running                         Not_listed Checks_running
    6  checks passing or none, then by
       the head review of the pull request:
         not reviewed on head                 Needs Unreviewed_on_head
         review history incomplete            Not_listed Review_history_incomplete
         reviewed on head                     Not_listed Reviewed_on_head
         head or review list not read         Not_listed Head_review_unknown
    v}

    The RFC names three head-review values. {!Repository_pulls.head_review}
    has a fourth, [Head_review_unknown], for a pull request whose answer
    carried no head commit or no readable review list. It has its own
    placement so it is never counted as "not reviewed".

    The RFC also names a [Checks_unrecognized] placement for a check state this
    build does not know. {!Repository_pulls} has no such value: a row with an
    unknown state is not decoded and is counted in [undecodable]. *)

type attention =
  | Checks_failing
  | Changes_requested
  | Conflicting
  | Unreviewed_on_head

type not_listed =
  | Draft
  | Checks_running
  | Reviewed_on_head
  | Review_history_incomplete
  | Head_review_unknown

type placement =
  | Needs of attention
  | Not_listed of not_listed

val all : placement list
(** Every placement, in the order of the table above. *)

val to_string : placement -> string
(** The lower-case constructor name: [checks_failing], [changes_requested],
    [conflicting], [unreviewed_on_head], [draft], [checks_running],
    [reviewed_on_head], [review_history_incomplete], [head_review_unknown]. *)

val equal : placement -> placement -> bool

val rank : placement -> int
(** The position of the placement in {!all}. *)

val placement_of : Repository_pulls.pull_request -> placement
