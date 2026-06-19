module SMap = Map.Make (String)

type authority =
  | Assignee
  | Operator
  | System
  | Legacy_forced
  | Legacy_unforced
  | Unknown of string

type done_record = {
  task_id : string;
  actor : string;
  authority : authority;
  assignee : string option;
  ts : string;
}

type metric = {
  done_total : int;
  done_assignee : int;
  done_operator : int;
  done_system : int;
  done_legacy_forced : int;
  done_legacy_unforced : int;
  done_unknown_authority : int;
  foreign_assignee_completions : done_record list;
  verification_approvals : int;
  force_equivalent_completions : int;
  indeterminate_ownership : int;
  events_parsed : int;
  events_skipped : int;
}

let empty_metric =
  { done_total = 0
  ; done_assignee = 0
  ; done_operator = 0
  ; done_system = 0
  ; done_legacy_forced = 0
  ; done_legacy_unforced = 0
  ; done_unknown_authority = 0
  ; foreign_assignee_completions = []
  ; verification_approvals = 0
  ; force_equivalent_completions = 0
  ; indeterminate_ownership = 0
  ; events_parsed = 0
  ; events_skipped = 0
  }
;;

let authority_to_string = function
  | Assignee -> "assignee"
  | Operator -> "operator"
  | System -> "system"
  | Legacy_forced -> "legacy_forced"
  | Legacy_unforced -> "legacy_unforced"
  | Unknown s -> Printf.sprintf "unknown(%s)" s
;;

(* Field extractors pattern-match the [`Assoc] directly rather than using
   [Yojson.Safe.Util], which raises on type mismatch. A missing or wrong-typed
   field yields [None] — a log line we cannot interpret never aborts the fold. *)
let str_field kvs key =
  match List.assoc_opt key kvs with
  | Some (`String s) -> Some s
  | Some _ | None -> None
;;

let bool_field kvs key =
  match List.assoc_opt key kvs with
  | Some (`Bool b) -> Some b
  | Some _ | None -> None
;;

(* RFC-0262 wire label -> typed authority. Pre-0262 lines have no [authority]
   field, so we recover the legacy distinction from [forced]. An unrecognised
   label is surfaced as [Unknown], not folded into a convenient default
   (CLAUDE.md: unknown input -> explicit variant, never permissive default). *)
let parse_authority ~forced authority_label =
  match authority_label with
  | None -> if forced then Legacy_forced else Legacy_unforced
  | Some "assignee" -> Assignee
  | Some "operator" -> Operator
  | Some "system" -> System
  | Some other -> Unknown other
;;

(* A "self-claim" authority is a non-Operator/System actor acting on its own
   claim — the only authority for which completing a *foreign* task is a §9①
   violation. [Unknown] is conservatively excluded (we cannot assert it is a
   self-claim actor). *)
let is_self_claim_authority = function
  | Assignee | Legacy_unforced -> true
  | Operator | System | Legacy_forced | Unknown _ -> false
;;

let is_force_equivalent = function
  | Operator | System | Legacy_forced -> true
  | Assignee | Legacy_unforced | Unknown _ -> false
;;

type acc = {
  claimant : string SMap.t;
  metric : metric;
}

let bump_authority metric = function
  | Assignee -> { metric with done_assignee = metric.done_assignee + 1 }
  | Operator -> { metric with done_operator = metric.done_operator + 1 }
  | System -> { metric with done_system = metric.done_system + 1 }
  | Legacy_forced -> { metric with done_legacy_forced = metric.done_legacy_forced + 1 }
  | Legacy_unforced ->
    { metric with done_legacy_unforced = metric.done_legacy_unforced + 1 }
  | Unknown _ ->
    { metric with done_unknown_authority = metric.done_unknown_authority + 1 }
;;

let process_done acc ~task_id ~actor ~authority ~from_status ~logged_assignee ~ts =
  (* Prefer the owner the transition itself recorded (RFC-0262 §9 [assignee]
     field); fall back to stream reconstruction only for legacy lines that
     predate it. A logged assignee removes the out-of-window blind spot, so such
     a completion is never [indeterminate]. *)
  let assignee =
    match logged_assignee with
    | Some _ as a -> a
    | None -> SMap.find_opt task_id acc.claimant
  in
  let m = acc.metric in
  let m = { m with done_total = m.done_total + 1 } in
  let m = bump_authority m authority in
  let m =
    if is_force_equivalent authority
    then { m with force_equivalent_completions = m.force_equivalent_completions + 1 }
    else m
  in
  (* A completion from [awaiting_verification] is an [Approve_verification] by the
     bound verifier, which the FSM *requires* to differ from the assignee
     (cross-agent verification, #4). It is never a §9① foreign completion — the
     foreign check only applies to a *direct* [Done_action] (from claimed /
     in_progress). Mixing the two is what over-counted the live log. *)
  let m =
    match from_status with
    | "awaiting_verification" ->
      { m with verification_approvals = m.verification_approvals + 1 }
    | _ ->
      (match assignee with
       | Some a when a <> actor && is_self_claim_authority authority ->
         let record = { task_id; actor; authority; assignee = Some a; ts } in
         { m with
           foreign_assignee_completions = record :: m.foreign_assignee_completions
         }
       | None when is_self_claim_authority authority ->
         (* Ownership matters here but the claim is outside the fed window —
            indeterminate, not a violation ("indeterminate dominates"). *)
         { m with indeterminate_ownership = m.indeterminate_ownership + 1 }
       | Some _ | None -> m)
  in
  (* A completion releases ownership of the task. *)
  { claimant = SMap.remove task_id acc.claimant; metric = m }
;;

let process_event acc (ev : Yojson.Safe.t) =
  match ev with
  | `Assoc kvs ->
    let acc =
      { acc with metric = { acc.metric with events_parsed = acc.metric.events_parsed + 1 } }
    in
    let task = str_field kvs "task" in
    let actor = str_field kvs "agent" in
    let to_status = str_field kvs "to_status" in
    (match task, to_status with
     | Some task_id, Some "claimed" ->
       (match actor with
        | Some a -> { acc with claimant = SMap.add task_id a acc.claimant }
        | None -> acc)
     | Some task_id, Some "todo" ->
       (* release back to the pool clears ownership *)
       { acc with claimant = SMap.remove task_id acc.claimant }
     | Some task_id, Some "cancelled" ->
       { acc with claimant = SMap.remove task_id acc.claimant }
     | Some task_id, Some "done" ->
       let actor = Option.value actor ~default:"" in
       let forced = Option.value (bool_field kvs "forced") ~default:false in
       let authority = parse_authority ~forced (str_field kvs "authority") in
       let from_status = Option.value (str_field kvs "from_status") ~default:"" in
       let logged_assignee = str_field kvs "assignee" in
       let ts = Option.value (str_field kvs "ts") ~default:"" in
       process_done acc ~task_id ~actor ~authority ~from_status ~logged_assignee ~ts
     | Some _, Some ("in_progress" | "awaiting_verification") ->
       (* start / verification keep the same claimant — no ownership change *)
       acc
     | Some _, Some _ ->
       (* an unrecognised status string (e.g. a future state): a completion is
          always [to_status="done"], so anything else cannot be a §9 event. *)
       acc
     | Some _, None | None, _ -> acc)
  | _ -> { acc with metric = { acc.metric with events_skipped = acc.metric.events_skipped + 1 } }
;;

let audit_events events =
  let final =
    List.fold_left process_event { claimant = SMap.empty; metric = empty_metric } events
  in
  (* foreign completions were prepended; restore chronological order *)
  { final.metric with
    foreign_assignee_completions = List.rev final.metric.foreign_assignee_completions
  }
;;

let done_record_to_json r =
  `Assoc
    [ "task", `String r.task_id
    ; "actor", `String r.actor
    ; "authority", `String (authority_to_string r.authority)
    ; "assignee", (match r.assignee with Some a -> `String a | None -> `Null)
    ; "ts", `String r.ts
    ]
;;

let metric_to_json m : Yojson.Safe.t =
  `Assoc
    [ "done_total", `Int m.done_total
    ; ( "done_by_authority"
      , `Assoc
          [ "assignee", `Int m.done_assignee
          ; "operator", `Int m.done_operator
          ; "system", `Int m.done_system
          ; "legacy_forced", `Int m.done_legacy_forced
          ; "legacy_unforced", `Int m.done_legacy_unforced
          ; "unknown", `Int m.done_unknown_authority
          ] )
    ; ( "foreign_assignee_completion_count"
      , `Int (List.length m.foreign_assignee_completions) )
    ; ( "foreign_assignee_completions"
      , `List (List.map done_record_to_json m.foreign_assignee_completions) )
    ; "verification_approvals", `Int m.verification_approvals
    ; "force_equivalent_completions", `Int m.force_equivalent_completions
    ; "indeterminate_ownership", `Int m.indeterminate_ownership
    ; "events_parsed", `Int m.events_parsed
    ; "events_skipped", `Int m.events_skipped
    ; ( "section_9_verdict"
      , `String (if m.foreign_assignee_completions = [] then "PASS" else "FAIL") )
    ]
;;

let metric_to_summary m =
  let buf = Buffer.create 512 in
  let line fmt = Printf.ksprintf (fun s -> Buffer.add_string buf (s ^ "\n")) fmt in
  line "RFC-0262 §9 completion-trust audit";
  line "  events: %d parsed, %d skipped" m.events_parsed m.events_skipped;
  line "  completions: %d total" m.done_total;
  line
    "    by authority: assignee=%d operator=%d system=%d legacy_forced=%d legacy_unforced=%d unknown=%d"
    m.done_assignee
    m.done_operator
    m.done_system
    m.done_legacy_forced
    m.done_legacy_unforced
    m.done_unknown_authority;
  line
    "  verification approvals (cross-agent, not §9① foreign): %d"
    m.verification_approvals;
  line
    "  §9② force-equivalent completions (Phase-3 evidence-gate baseline): %d"
    m.force_equivalent_completions;
  line "  indeterminate ownership (claim out of window): %d" m.indeterminate_ownership;
  let foreign = List.length m.foreign_assignee_completions in
  line "  §9① foreign completions by a non-Operator/System actor: %d" foreign;
  List.iter
    (fun r ->
      line
        "      VIOLATION task=%s actor=%s assignee=%s authority=%s ts=%s"
        r.task_id
        r.actor
        (Option.value r.assignee ~default:"?")
        (authority_to_string r.authority)
        r.ts)
    m.foreign_assignee_completions;
  line "  §9① verdict: %s" (if foreign = 0 then "PASS" else "FAIL");
  Buffer.contents buf
;;
