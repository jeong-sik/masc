(* Typed escalation state for repeated [Invalid task state] transition
   errors emitted by [Tool_task.run_task_transition].

   See [task_transition_state.mli] for the contract, background,
   workaround posture, and threading guarantees.

   WORKAROUND-CARRYOVER: this module is a log-surface dedupe layer, not
   a structural fix for the upstream invalid-transition retry pattern.
   Root fix: client-side gating using cached [task_status] +
   [valid_next_actions] before dispatching the transition. Deferred to
   its own RFC. *)

type status_kind =
  | Todo_kind
  | Claimed_kind
  | InProgress_kind
  | AwaitingVerification_kind
  | Done_kind
  | Cancelled_kind
  | OperatorBlocked_kind

type transition_action =
  | Claim
  | Start
  | Done_action
  | Cancel
  | Release
  | Submit_for_verification
  | Approve_verification
  | Reject_verification
  | Block_for_operator
  | Unblock

type family =
  | Invalid_transition of
      { from_status : status_kind
      ; action : transition_action
      }
  | Awaiting_verification_done
  | Self_approval_not_allowed
  | Self_rejection_not_allowed
  | Already_done
  | Active_task_limit_exceeded
  | Submit_verification_missing_evidence
  | Reclaim_policy_blocked
  | Other_invalid_state

type threshold_silence_payload =
  { count : int
  ; silence_threshold : int
  }

type record_outcome =
  [ `First
  | `Repeated of int
  | `Threshold_silence of threshold_silence_payload
  ]

(* ── Stable string labels ─────────────────────────────────────────── *)

let status_kind_to_string = function
  | Todo_kind -> "todo"
  | Claimed_kind -> "claimed"
  | InProgress_kind -> "in_progress"
  | AwaitingVerification_kind -> "awaiting_verification"
  | Done_kind -> "done"
  | Cancelled_kind -> "cancelled"
  | OperatorBlocked_kind -> "operator_blocked"

let transition_action_to_string = function
  | Claim -> "claim"
  | Start -> "start"
  | Done_action -> "done"
  | Cancel -> "cancel"
  | Release -> "release"
  | Submit_for_verification -> "submit_for_verification"
  | Approve_verification -> "approve_verification"
  | Reject_verification -> "reject_verification"
  | Block_for_operator -> "block_for_operator"
  | Unblock -> "unblock"

let family_to_string = function
  | Invalid_transition { from_status; action } ->
    Printf.sprintf
      "invalid_transition:%s->%s"
      (status_kind_to_string from_status)
      (transition_action_to_string action)
  | Awaiting_verification_done -> "awaiting_verification_done"
  | Self_approval_not_allowed -> "self_approval_not_allowed"
  | Self_rejection_not_allowed -> "self_rejection_not_allowed"
  | Already_done -> "already_done"
  | Active_task_limit_exceeded -> "active_task_limit_exceeded"
  | Submit_verification_missing_evidence ->
    "submit_verification_missing_evidence"
  | Reclaim_policy_blocked -> "reclaim_policy_blocked"
  | Other_invalid_state -> "other_invalid_state"

(* ── Exhaustive enumeration helpers ───────────────────────────────── *)

let all_status_kinds : status_kind list =
  [ Todo_kind
  ; Claimed_kind
  ; InProgress_kind
  ; AwaitingVerification_kind
  ; Done_kind
  ; Cancelled_kind
  ; OperatorBlocked_kind
  ]

let all_transition_actions : transition_action list =
  [ Claim
  ; Start
  ; Done_action
  ; Cancel
  ; Release
  ; Submit_for_verification
  ; Approve_verification
  ; Reject_verification
  ; Block_for_operator
  ; Unblock
  ]

let all_families : family list =
  let invalid_pairs =
    List.concat_map
      (fun from_status ->
        List.map
          (fun action -> Invalid_transition { from_status; action })
          all_transition_actions)
      all_status_kinds
  in
  let leaf_families : family list =
    [ Awaiting_verification_done
    ; Self_approval_not_allowed
    ; Self_rejection_not_allowed
    ; Already_done
    ; Active_task_limit_exceeded
    ; Submit_verification_missing_evidence
    ; Reclaim_policy_blocked
    ; Other_invalid_state
    ]
  in
  invalid_pairs @ leaf_families

(* ── Classification ───────────────────────────────────────────────── *)

(* Case-insensitive substring containment over ASCII inputs. The error
   messages we classify are all ASCII; [String.lowercase_ascii] is safe
   here. *)
let contains_ci ~(needle : string) (haystack : string) : bool =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let hl = String.length h in
  let nl = String.length n in
  if nl = 0
  then true
  else if nl > hl
  then false
  else (
    let last = hl - nl in
    let found = ref false in
    let i = ref 0 in
    while (not !found) && !i <= last do
      if String.equal (Stdlib.String.sub h !i nl) n then found := true;
      incr i
    done;
    !found)

(* Parse the substring after [Invalid transition: <from> -> <action>]
   into a typed [(status_kind, transition_action)] pair. Returns [None]
   when either side fails to match a known token — the caller falls
   back to [Other_invalid_state] in that case rather than synthesising
   a partial [Invalid_transition]. *)
let parse_status_kind_token (s : string) : status_kind option =
  match String.lowercase_ascii (String.trim s) with
  | "todo" -> Some Todo_kind
  | "claimed" -> Some Claimed_kind
  | "in_progress" | "inprogress" -> Some InProgress_kind
  | "awaiting_verification" | "awaitingverification" ->
    Some AwaitingVerification_kind
  | "done" -> Some Done_kind
  | "cancelled" | "canceled" -> Some Cancelled_kind
  | _ -> None

let parse_transition_action_token (s : string) : transition_action option =
  match String.lowercase_ascii (String.trim s) with
  | "claim" -> Some Claim
  | "start" -> Some Start
  | "done" | "done_action" -> Some Done_action
  | "cancel" -> Some Cancel
  | "release" -> Some Release
  | "submit_for_verification" -> Some Submit_for_verification
  | "approve_verification" | "approve" -> Some Approve_verification
  | "reject_verification" | "reject" -> Some Reject_verification
  | _ -> None

(* Find the substring between [prefix] and the first occurrence of
   [stop] (or end-of-string). Returns [None] when [prefix] is absent. *)
let extract_after ~(prefix : string) ~(stop : char) (s : string) : string option
  =
  let h = String.lowercase_ascii s in
  let p = String.lowercase_ascii prefix in
  let hl = String.length h in
  let pl = String.length p in
  if pl > hl
  then None
  else (
    let start = ref None in
    let i = ref 0 in
    let last = hl - pl in
    while Option.is_none !start && !i <= last do
      if String.equal (Stdlib.String.sub h !i pl) p
      then start := Some (!i + pl);
      incr i
    done;
    match !start with
    | None -> None
    | Some from ->
      let j = ref from in
      while !j < hl && s.[!j] <> stop do
        incr j
      done;
      Some (Stdlib.String.sub s from (!j - from)))

let parse_invalid_transition_pair (msg : string)
    : (status_kind * transition_action) option
  =
  (* Expected fragment: "Invalid transition: <from> -> <action> (..."
     We tolerate optional whitespace around the arrow. *)
  match extract_after ~prefix:"invalid transition:" ~stop:'(' msg with
  | None -> None
  | Some body ->
    (* split on "->" *)
    let body = String.trim body in
    let arrow = "->" in
    let bl = String.length body in
    let al = String.length arrow in
    let pos = ref None in
    let i = ref 0 in
    let last = bl - al in
    while Option.is_none !pos && !i <= last do
      if String.equal (Stdlib.String.sub body !i al) arrow
      then pos := Some !i;
      incr i
    done;
    (match !pos with
     | None -> None
     | Some p ->
       let lhs = String.trim (Stdlib.String.sub body 0 p) in
       let rhs = String.trim (Stdlib.String.sub body (p + al) (bl - p - al)) in
       (match parse_status_kind_token lhs, parse_transition_action_token rhs with
        | Some s, Some a -> Some (s, a)
        | _, _ -> None))

(* Order of checks matters: the more specific fragments are tried
   first so that, for example, "Self-approval not allowed" is not
   absorbed by a generic "not allowed" rule. *)
let classify (msg : string) : family =
  if contains_ci ~needle:"Self-approval not allowed" msg
  then Self_approval_not_allowed
  else if contains_ci ~needle:"Self-rejection not allowed" msg
  then Self_rejection_not_allowed
  else if contains_ci ~needle:"awaiting verification" msg
  then Awaiting_verification_done
  else if contains_ci ~needle:"already done by" msg
  then Already_done
  else if contains_ci ~needle:"already done/cancelled" msg
  then Already_done
  else if contains_ci ~needle:"blocked from re-claim" msg
  then Reclaim_policy_blocked
  else if contains_ci ~needle:"active task limit" msg
  then Active_task_limit_exceeded
  else if contains_ci ~needle:"active_task_limit" msg
  then Active_task_limit_exceeded
  else if contains_ci ~needle:"missing evidence" msg
     || contains_ci ~needle:"submit_for_verification requires" msg
  then Submit_verification_missing_evidence
  else if contains_ci ~needle:"Invalid transition:" msg
  then (
    match parse_invalid_transition_pair msg with
    | Some (from_status, action) -> Invalid_transition { from_status; action }
    | None -> Other_invalid_state)
  else Other_invalid_state

let default_silence_threshold : int = 10

(* ── In-memory state ──────────────────────────────────────────────── *)

let state = Bounded_event_dedupe.create ~initial_capacity:64 ()

let key ~task_id ~family =
  Bounded_event_dedupe.key [ task_id; family_to_string family ]

let record_invalid_state
    ?(silence_threshold = default_silence_threshold)
    ~(task_id : string)
    ~(family : family)
    ()
    : record_outcome
  =
  let key = key ~task_id ~family in
  match Bounded_event_dedupe.record_threshold state ~key ~threshold:silence_threshold with
  | Bounded_event_dedupe.First_threshold -> `First
  | Bounded_event_dedupe.Repeated_threshold count -> `Repeated count
  | Bounded_event_dedupe.Threshold { count; threshold } ->
    `Threshold_silence { count; silence_threshold = threshold }

let reset_for_task ~(task_id : string) : unit =
  List.iter
    (fun family ->
      let key = key ~task_id ~family in
      Bounded_event_dedupe.remove state ~key)
    all_families

let reset_for_test () : unit =
  Bounded_event_dedupe.reset state

let cardinality () : int =
  Bounded_event_dedupe.cardinality state

let failure_count ~(task_id : string) ~(family : family) : int =
  let key = key ~task_id ~family in
  Bounded_event_dedupe.count state ~key
