(** MASC MCP Types - Domain Model *)

(* Newtypes are in ids.ml *)
include Ids

(* ============================================ *)
(* Timestamp utilities                          *)
(* ============================================ *)

(** Timestamp utilities *)

(* The clock read is not new — reading it is what [now_iso] is for. Only the
   body around it changed, from an inline gmtime block to a call to the shared
   writer, and the ratchet's move detector cannot match a line across that
   reshape.
   DET-OK *)
let now_iso () = Time_codec.rfc3339_of_unix (Unix.gettimeofday ())

(** Parse a strict RFC 3339 timestamp to Unix seconds. *)
let parse_iso8601_opt value = Time_codec.parse_rfc3339_opt value

(** Agent status - compile-time state machine *)
type agent_status =
  | Active
  | Busy
  | Listening
  | Inactive
[@@deriving show { with_path = false }]

let agent_status_to_string = function
  | Active -> "active"
  | Busy -> "busy"
  | Listening -> "listening"
  | Inactive -> "inactive"

(* Alias for dashboard compatibility *)
let string_of_agent_status = agent_status_to_string

(** Issue #8372: schema enum sites used to hand-roll [agent_status] strings,
    matching the same drift class as #8354 (task_status) and #8364 (Response).
    [agent_status] has only nullary constructors, so a list literal is safe.
    Adding a 5th constructor will fail compilation in [agent_status_to_string]
    (the witness) — the test in [test_types.ml] checks that every result of
    that function appears in [valid_agent_status_strings]. *)
let all_agent_statuses = [ Active; Busy; Listening; Inactive ]
let valid_agent_status_strings =
  List.map agent_status_to_string all_agent_statuses

(* Presence ordering for operator surfaces: the agent doing work outranks the
   one merely holding a session, which outranks the one only listening. A
   fifth constructor breaks compilation here instead of silently ranking 0,
   which is what happens when the ordering is written over the serialized
   strings instead. *)
let agent_status_rank = function
  | Busy -> 4
  | Active -> 3
  | Listening -> 2
  | Inactive -> 1

let agent_status_of_string_opt = function
  | "active" -> Some Active
  | "busy" -> Some Busy
  | "listening" -> Some Listening
  | "inactive" -> Some Inactive
  | _ -> None

(** [agent_status_of_string_r s] — explicit-failure parser.  Prefer this
    over {!agent_status_of_string} (which silently maps unknown input to
    [Active]).  The "permissive default" pattern was flagged in #10748:
    it merges semantically distinct inputs (typo, future variant, garbage
    payload) into a healthy "Active" presence and erases the diagnostic
    trail.  Callers that genuinely want a default should pin it at the
    call site so the choice is local and reviewable. *)
let agent_status_of_string_r s : (agent_status, string) result =
  match agent_status_of_string_opt s with
  | Some status -> Ok status
  | None -> Error (Printf.sprintf "unknown agent_status: %S" s)



(* Custom yojson converters for lowercase JSON compatibility *)
let agent_status_to_yojson status = `String (agent_status_to_string status)

let agent_status_of_yojson = function
  | `String s ->
      (match agent_status_of_string_opt s with
       | Some status -> Ok status
       | None -> Error ("Unknown agent status: " ^ s))
  | other ->
      (* Mirrors the [agent_role_of_yojson] shape introduced in iter#90
         #16927 — non-string inputs name the kind actually received so
         operators can distinguish wrong-type ([`Int]/[`Bool] from a
         config drift) from wrong-shape ([`Assoc]/[`Null] from a schema
         change mid-flight) without re-parsing the offending payload. *)
      Error
        (Printf.sprintf
           "agent_status_of_yojson: expected JSON string, got %s"
           (Json_util.kind_name other))

(** Agent metadata - session identification and environment info *)
type agent_meta = {
  session_id: string;                     (* short UUID for unique identification *)
  agent_type: string;                     (* claude, gemini, codex *)
  pid: int option; [@default None]        (* process ID *)
  hostname: string option; [@default None] (* machine hostname *)
  tty: string option; [@default None]     (* terminal identifier *)
  parent_task: string option; [@default None] (* task that spawned this agent *)
  keeper_name: string option; [@default None] (* stable keeper owner, when this runtime is keeper-owned *)
  keeper_id: string option; [@default None] (* stable keeper UUID, when available *)
} [@@deriving yojson { strict = false }, show]

(** Agent info *)
type agent = {
  id: Agent_id.t option; [@default None]  (* permanent UUID *)
  name: string;                           (* unique nickname: claude-swift-fox *)
  agent_type: string; [@default "unknown"] (* original type: claude, gemini, codex *)
  status: agent_status;
  capabilities: string list;
  current_task: string option; [@default None]
  session_bound_at: string;
  last_seen: string;
  meta: agent_meta option; [@default None] (* session metadata *)
} [@@deriving yojson { strict = false }, show]

(* Name kept because 73 call sites reach it through [Masc_domain]; renaming
   them to [Time_codec.rfc3339_of_unix] is tracked in #27131. *)
let iso8601_of_unix_seconds = Time_codec.rfc3339_of_unix

(** Actions an *agent* may drive on a task. A completion verdict is deliberately
    absent: it is not an agent action. See [completion_authority]. *)
type task_action =
  | Claim
  | Start
  | Done_action
  | Cancel
  | Release
  | Submit_for_verification
[@@deriving show]

let task_action_of_string s =
  match String.lowercase_ascii s with
  | "claim" -> Ok Claim
  | "start" -> Ok Start
  | "done" -> Ok Done_action
  | "cancel" -> Ok Cancel
  | "release" -> Ok Release
  | "submit_for_verification" -> Ok Submit_for_verification
  | ("approve" | "reject") as verdict ->
    (* Explicit rejection rather than "unknown action": the caller asked for a
       real operation that is no longer reachable from the agent action surface.
       A trusted operator or judge boundary constructs the authority provenance
       and calls the separate verdict entrypoint. *)
    Error
      (Printf.sprintf
         "Task action %S is not an agent action: a completion verdict is issued \
          by the completion authority (human operator or system LLM agent), not \
          through the task action surface. A Keeper is not a verifier."
         verdict)
  | other -> Error (Printf.sprintf "Unknown task action: %s" other)

let task_action_to_string = function
  | Claim -> "claim"
  | Start -> "start"
  | Done_action -> "done"
  | Cancel -> "cancel"
  | Release -> "release"
  | Submit_for_verification -> "submit_for_verification"

(** All valid task actions, derived from the ADT (single source of truth). *)
let all_task_actions =
  [ Claim; Start; Done_action; Cancel; Release; Submit_for_verification ]
let valid_task_action_strings = List.map task_action_to_string all_task_actions

(** Provenance carried by a completion verdict. This type separates verdicts
    from the Keeper task-action surface; it does not authenticate the embedded
    identity. The producer boundary must construct it only after authenticating
    an operator or accepting a typed system-LLM result. The system LLM agent
    is not a Keeper and has no Keeper lifecycle. *)
type completion_authority =
  | Human_operator of { operator_id: string }
  | System_llm_agent of { agent_run_id: string }
[@@deriving show]

(** A verdict cannot exist without an authority: both terminal outcomes are
    carried here and consumed only by the verdict decider, which takes an
    [completion_authority] argument. *)
type completion_verdict =
  | Verdict_approved
  | Verdict_rejected of { reason: string }
[@@deriving show]

let completion_authority_actor = function
  | Human_operator { operator_id } -> operator_id
  | System_llm_agent { agent_run_id } -> agent_run_id

let completion_authority_kind = function
  | Human_operator _ -> "human_operator"
  | System_llm_agent _ -> "system_llm_agent"

let completion_authority_has_identity authority =
  not (String.equal (String.trim (completion_authority_actor authority)) "")
;;

(** Which question a completion authority is being asked. A producer submits
    work it believes is finished, or a stop it believes is right; both wait in
    the same place and both end on one verdict, so the verdict needs to know
    which terminal state it is authorising. *)
type verification_intent =
  | Complete_task
  | Cancel_task
[@@deriving show]

let verification_intent_to_string = function
  | Complete_task -> "complete"
  | Cancel_task -> "cancel"
;;

let verification_intent_of_string = function
  | "complete" -> Ok Complete_task
  | "cancel" -> Ok Cancel_task
  | other ->
    Error
      (Printf.sprintf
         "verification intent must be \"complete\" or \"cancel\", got %S"
         other)
;;

type task_status =
  | Todo
  | Claimed of { assignee: string; claimed_at: string }
  | InProgress of { assignee: string; started_at: string }
  | AwaitingVerification of {
      assignee: string;
      started_at: string;
      submitted_at: string;
      intent: verification_intent;
        (** What an approval means for this obligation. Without it the
            authority reads one shape for two questions — "is this done" and
            "should this stop" — and an approval has no way to say which
            terminal state it authorised. *)
      verification_id: string;
        (** An obligation with no assignable satisfier. There is deliberately no
            [phase]/verifier binding: the previous [Verifier_assigned] field made
            whichever agent won the claim race the approver, so the obligation
            was owned by a Keeper. The verdict comes from a
            [completion_authority] instead, and [verification_id] is the join to
            the evidence record it reads. *)
    }
  | Done of { assignee: string; completed_at: string; notes: string option }
  | Cancelled of { cancelled_by: string; cancelled_at: string; reason: string option }
[@@deriving show]

(* Simple string representation for dashboard *)
let task_status_to_string = function
  | Todo -> "todo"
  | Claimed _ -> "claimed"
  | InProgress _ -> "in_progress"
  | AwaitingVerification _ -> "awaiting_verification"
  | Done _ -> "done"
  | Cancelled _ -> "cancelled"

let string_of_task_status = task_status_to_string

(** Display icon for task status. Used by workspace_status and workspace_query
    rendering. Exhaustive match — adding a constructor forces an update here. *)
let task_status_icon = function
  | Todo -> "📋"
  | Claimed _ | InProgress _ -> "🔄"
  | AwaitingVerification _ -> "🔍"
  | Done _ -> "✅"
  | Cancelled _ -> "🚫"

(** Who acted on a Task, and in what relationship.

    Every status carries an actor and a role, but a bare [string option]
    records only the name and drops the role. Callers then disagreed about
    what the name meant: three separate [task_assignee] implementations
    existed, differing on [Done] (assignee or nobody) and on [Cancelled]
    (nobody or the canceller). A completed Task therefore showed an owner on
    one surface and none on another, and a cancelled Task named its canceller
    as its assignee.

    Naming the role makes the disagreement impossible to write: a [Canceller]
    cannot be passed where a [Holder] is expected, and a new status has to
    state which role it carries. The three questions callers actually ask are
    derived below, each total over this sum. *)
type task_actor =
  | Unassigned
  | Holder of string  (** Claimed or InProgress: currently doing the work. *)
  | Submitter of string  (** AwaitingVerification: submitted, awaiting a verdict. *)
  | Completer of string  (** Done: finished the work. *)
  | Canceller of string  (** Cancelled: ended the work. Never its assignee. *)

let task_actor_of_status = function
  | Todo -> Unassigned
  | Claimed { assignee; _ } -> Holder assignee
  | InProgress { assignee; _ } -> Holder assignee
  | AwaitingVerification { assignee; _ } -> Submitter assignee
  | Done { assignee; _ } -> Completer assignee
  | Cancelled { cancelled_by; _ } -> Canceller cancelled_by

(** Who owes work on this Task now. [Done] and [Cancelled] owe nothing, so
    they answer [None] even though both carry a name. Canonical
    ownership-check helper — used by task_state, gRPC, etc. *)
let task_assignee_of_status status =
  match task_actor_of_status status with
  | Holder name | Submitter name -> Some name
  | Unassigned | Completer _ | Canceller _ -> None

(** Who did or is doing the work, including after completion. Distinct from
    ownership: a finished Task has no one responsible but does have someone
    who finished it. [Cancelled] answers [None] — the canceller ended the work
    rather than performing it, and travels as [cancelled_by] instead. *)
let task_performer_of_status status =
  match task_actor_of_status status with
  | Holder name | Submitter name | Completer name -> Some name
  | Unassigned | Canceller _ -> None

(** Total rendering of the actor for a surface that must print something.
    [Cancelled] surfaces its canceller and [Todo] yields "unclaimed"; neither
    is an ownership claim. *)
let task_display_assignee status =
  match task_actor_of_status status with
  | Unassigned -> "unclaimed"
  | Holder name | Submitter name | Completer name | Canceller name -> name

(** Terminal states: [Done] or [Cancelled]. No further transitions possible.
    Exhaustive match — adding a constructor forces an update here. *)
let task_status_is_terminal = function
  | Done _ | Cancelled _ -> true
  | Todo | Claimed _ | InProgress _ | AwaitingVerification _ -> false

(** Completed state: [Done]. Distinct from [task_status_is_terminal] which
    also includes [Cancelled]. Use this when only successful completion
    matters (e.g. convergence ratios, reputation counting). *)
let task_status_is_done = function
  | Done _ -> true
  | Todo | Claimed _ | InProgress _ | AwaitingVerification _ | Cancelled _ -> false

(** Issue #8354 + 2026-05-27 follow-up: schema enums for [task_status]
    used to be hand-rolled in [tool_shard.ml] and [mcp_server.ml],
    dropping [awaiting_verification].  The first fix introduced a
    [witness] [function] inside [all_task_status_names] whose
    exhaustiveness pinned *constructor coverage* but whose return
    [string list] was a separate literal — renaming an arm in
    [task_status_to_string] (e.g. "in_progress" -> "running") would
    not propagate to the published schema, leaving a silent
    string-identity drift.

    This version closes that gap by deriving the schema enum directly
    from [task_status_to_string] over a witness list with placeholder
    payloads.  [task_status] carries record payloads but the schema
    cares only about the constructor tag, so zero-valued placeholder
    fields are safe — only [task_status_to_string]'s constructor arm
    is consulted.  Now both axes are guarded:

    - Constructor coverage: adding a constructor breaks
      [task_status_to_string]'s exhaustive [match] at compile time.
    - String identity: schema enum is the actual function image, so
      renames cannot desync.

    The remaining hand-coded axis is the witness list itself.
    [test_task_status_vocabulary] compares it against the arms of
    [task_status_of_yojson], so a status one side knows and the other does
    not fails there.

    Order matches the FSM lifecycle (Todo -> Claimed -> InProgress ->
    AwaitingVerification -> Done | Cancelled) for readable schema docs. *)
let task_status_schema_witnesses : task_status list =
  let placeholder = "" in
  [ Todo
  ; Claimed { assignee = placeholder; claimed_at = placeholder }
  ; InProgress { assignee = placeholder; started_at = placeholder }
  ; AwaitingVerification
      { assignee = placeholder
      ; started_at = placeholder
      ; submitted_at = placeholder
      ; intent = Complete_task
      ; verification_id = placeholder
      }
  ; Done { assignee = placeholder; completed_at = placeholder; notes = None }
  ; Cancelled
      { cancelled_by = placeholder; cancelled_at = placeholder; reason = None }
  ]

let all_task_status_names : string list =
  List.map task_status_to_string task_status_schema_witnesses

let valid_task_status_strings = all_task_status_names

(* Manual yojson conversion for task_status (sum type with records) *)
let task_status_to_yojson = function
  | Todo -> `Assoc [("status", `String "todo")]
  | Claimed { assignee; claimed_at } ->
      `Assoc [
        ("status", `String "claimed");
        ("assignee", `String assignee);
        ("claimed_at", `String claimed_at);
      ]
  | InProgress { assignee; started_at } ->
      `Assoc [
        ("status", `String "in_progress");
        ("assignee", `String assignee);
        ("started_at", `String started_at);
      ]
  | Done { assignee; completed_at; notes } ->
      `Assoc [
        ("status", `String "done");
        ("assignee", `String assignee);
        ("completed_at", `String completed_at);
        ("notes", Json_util.string_opt_to_json notes);
      ]
  | AwaitingVerification { assignee; started_at; submitted_at; intent; verification_id } ->
      `Assoc [
        ("status", `String "awaiting_verification");
        ("assignee", `String assignee);
        ("started_at", `String started_at);
        ("submitted_at", `String submitted_at);
        ("intent", `String (verification_intent_to_string intent));
        ("verification_id", `String verification_id);
      ]
  | Cancelled { cancelled_by; cancelled_at; reason } ->
      `Assoc [
        ("status", `String "cancelled");
        ("cancelled_by", `String cancelled_by);
        ("cancelled_at", `String cancelled_at);
        ("reason", Json_util.string_opt_to_json reason);
      ]

let task_status_of_yojson json =
  let req key = Json_util.get_string_with_default json ~key ~default:"" in
  let opt key = Json_util.get_string json key in
  try
    match req "status" with
    | "todo" -> Ok Todo
    | "claimed" ->
        Ok (Claimed { assignee = req "assignee"; claimed_at = req "claimed_at" })
    | "in_progress" ->
        Ok (InProgress { assignee = req "assignee"; started_at = req "started_at" })
    | "done" ->
        Ok (Done { assignee = req "assignee"; completed_at = req "completed_at"; notes = opt "notes" })
    | "awaiting_verification" ->
        (* Write-boundary format validation: the field stays the wire string
           because no in-process consumer reads it as a time (rg: the only
           parse_iso8601 of a task started_at is this check; graphql carries
           it as display text). RFC-0371 audit reclassified this from
           validate-then-discard on that evidence. *)
        (match Json_util.get_string json "started_at" with
         | None -> Error "awaiting_verification requires started_at"
         | Some started_at ->
           (match parse_iso8601_opt started_at with
            | Some _ ->
              (* [intent] is required: an approval has to know which terminal
                 state it authorises, and a default here would silently make
                 every cancellation read as a completion. *)
              (match Json_util.get_string json "intent" with
               | None -> Error "awaiting_verification requires intent"
               | Some raw ->
                 (match verification_intent_of_string raw with
                  | Error message -> Error message
                  | Ok intent ->
                    Ok
                      (AwaitingVerification
                         { assignee = req "assignee"
                         ; started_at
                         ; submitted_at = req "submitted_at"
                         ; intent
                         ; verification_id = req "verification_id"
                         })))
            | None ->
              Error
                (Printf.sprintf
                   "awaiting_verification started_at must be RFC 3339, got %S"
                   started_at)))
    | "cancelled" ->
        Ok (Cancelled
              { cancelled_by = req "cancelled_by"
              ; cancelled_at = req "cancelled_at"
              ; reason = opt "reason"
              })
    | s -> Error ("Unknown task status: " ^ s)
  with e -> Error (Printexc.to_string e)

(** Task execution links - tie task state to runtime evidence producers *)
type task_execution_links = {
  operation_id : string option; [@default None]
  session_id : string option; [@default None]
} [@@deriving show, yojson { strict = true }]

(** No producer has been linked yet. A task starts here and stays here until a
    runtime records the operation or session that carried it out. *)
let no_execution_links = { operation_id = None; session_id = None }

(** Task contract - persisted completion criteria and evidence facts.

    Written once, when the task is created, and never rewritten: what counts as
    done cannot change while the task runs. Runtime evidence producers are
    recorded independently on the task itself as [execution_links].

    [completion_contract], [required_evidence], and [verify_gate_evidence] are
    supplied to the completion authority as task facts. The workspace FSM never
    interprets their prose, counts entries, or derives a completion verdict. *)
type task_contract = {
  strict : bool; [@default false]
  completion_contract : string list; [@default []]
  required_evidence : string list; [@default []]
  inspect_gate_evidence : string list; [@default []]
  verify_gate_evidence : string list; [@default []]
} [@@deriving show, yojson { strict = false }]

(** Handoff context persisted across release/reclaim cycles *)
type task_reclaim_policy =
  | Allow_reclaim
  | Block_reclaim
[@@deriving show]

let task_reclaim_policy_to_string = function
  | Allow_reclaim -> "allow_reclaim"
  | Block_reclaim -> "block_reclaim"

let task_reclaim_policy_of_string = function
  | "allow_reclaim" -> Ok Allow_reclaim
  | "block_reclaim" -> Ok Block_reclaim
  | value -> Error (Printf.sprintf "unknown task_reclaim_policy: %s" value)

let task_reclaim_policy_to_yojson policy =
  `String (task_reclaim_policy_to_string policy)

let task_reclaim_policy_of_yojson = function
  | `String value -> task_reclaim_policy_of_string value
  | _ -> Error "task_reclaim_policy must be a string"

type task_handoff_context = {
  summary : string; [@default ""]
  reason : string option; [@default None]
  next_step : string option; [@default None]
  failure_mode : string option; [@default None]
  reclaim_policy : task_reclaim_policy option; [@default None]
  evidence_refs : string list; [@default []]
  updated_at : string option; [@default None]
  updated_by : string option; [@default None]
} [@@deriving show, yojson { strict = false }]

(** The "why" behind a transition that stopped work, from whichever argument
    carried it. Two entry points supply it differently: [transition_task_r]
    takes an explicit [reason], while [release_task_r] takes none at all and
    forwards only a handoff context, which the production release tool requires
    for a strict release. [task_handoff_context.reason] is the same concept
    under a different argument, so it is read when the explicit one is empty.

    Single definition on purpose: the committed broadcast and the author wake
    both answer "why did this stop", and computing the answer twice let them
    disagree about the same cancellation. Returns [None] when neither carries a
    non-blank reason — distinct from a reason that is the empty string. *)
let stated_reason ~(reason : string option)
      ~(handoff_context : task_handoff_context option) : string option =
  let non_blank value =
    match String.trim value with
    | "" -> None
    | trimmed -> Some trimmed
  in
  (* [reason] then [summary]. A strict release is rejected without
     [handoff_context.summary] while [reason] stays optional, so a release
     whose whole explanation is its summary would otherwise publish a bare
     "Released <id>" — dropping text the caller was required to supply.
     [failure_mode] is left out: it classifies, it does not explain. *)
  let from_handoff () =
    match handoff_context with
    | None -> None
    | Some context ->
      (match Option.bind context.reason non_blank with
       | Some _ as reason -> reason
       | None -> non_blank context.summary)
  in
  match reason with
  | None -> from_handoff ()
  | Some explicit ->
    (match non_blank explicit with
     | Some stated -> Some stated
     | None -> from_handoff ())
;;

(** Task definition *)
type task = {
  id: string;
  title: string;
  description: string;
  task_status: task_status; [@key "status"]
  priority: int; [@default 3]
  files: string list; [@default []]
  created_at: string;
  created_by: string option; [@default None]
  (* RFC-0323 W2: write-once lineage pointer to the terminal task this one
     re-runs. Set only at creation (masc_add_task); every transition carries
     it through unchanged. Distinct from RFC-0267 goal linkage (many-to-many
     side registry). *)
  predecessor_task_id: string option; [@default None]
  contract: task_contract option; [@default None]
  (* Runtime identifiers attached after the task is created, by whichever
     execution picks it up. Separate from [contract] so linking them never
     touches what counts as done. *)
  execution_links: task_execution_links; [@default no_execution_links]
  handoff_context: task_handoff_context option; [@default None]
  cycle_count: int; [@default 0]
  reclaim_policy: task_reclaim_policy option; [@default None]
  do_not_reclaim_reason: string option; [@default None]
  (* Exact immutable Skill references are Task evidence. Their source,
     package, name, and content revision survive every state transition and do
     not depend on whichever catalog is current when the Task is later read. *)
  skills: Skill_reference.t list; [@default []]
} [@@deriving show]

(* RFC-0323 G-10: the typed reclaim claim gate is retired. #23661 removed its
   Todo producer; this change removes the Done producer, so nothing can be
   blocked-by-reclaim at claim time anymore. Claim blocks now describe the
   task-status fact that prevents an agent claim. [reclaim_policy] survives as
   release/cancel data plumbing only (its full retirement is a recorded
   follow-up decision, RFC-0323 Radius Map). *)

type task_claim_readiness =
  | Claim_ready

type task_claim_block =
  | Claim_block_pending_verdict of { verification_id : string }
  | Claim_block_not_todo of task_status

type task_claim_decision =
  | Claim_available of task_claim_readiness
  | Claim_unavailable of task_claim_block

let task_claim_readiness (_task : task) = Claim_ready
;;

let task_claim_decision_for_status task_status =
  match task_status with
  | Todo ->
    (* Todo tasks are always claimable regardless of reclaim_policy.
       reclaim_policy only gates Done -> re-claim, not Todo -> first claim.
       task-1869: 6 TaskError fingerprints show coordination-role tasks
       with Block_reclaim policy were blocked from claiming. *)
    Claim_available Claim_ready
  | AwaitingVerification { verification_id; _ } ->
    (* A pending obligation belongs to the completion-authority lane. No
       Keeper claim can grant verifier authority or inspect it as agent work. *)
    Claim_unavailable (Claim_block_pending_verdict { verification_id })
  | Done _
  (* RFC-0323: a verified Done is terminal for every actor, regardless of
     reclaim_policy — re-running completed work creates a NEW task linked via
     predecessor_task_id. Retires the #23632 Done-reclaim mechanism (which
     was production-unreachable: creation defaults the policy to None and
     claiming wipes it). *)
  | Claimed _
  | InProgress _
  | Cancelled _ ->
    Claim_unavailable (Claim_block_not_todo task_status)
;;

let task_claim_decision (task : task) =
  match task_claim_decision_for_status task.task_status with
  | Claim_available Claim_ready -> Claim_available (task_claim_readiness task)
  | Claim_unavailable block -> Claim_unavailable block
;;

let task_claim_decision_is_available task =
  match task_claim_decision task with
  | Claim_available _ -> true
  | Claim_unavailable _ -> false
;;

type task_claim_next_action =
  | Claim_now
  | Skip_claim of task_claim_block

let task_claim_next_action task =
  match task_claim_decision task with
  | Claim_available Claim_ready -> Claim_now
  | Claim_unavailable block -> Skip_claim block
;;

let task_claim_next_action_is_claimable task =
  match task_claim_next_action task with
  | Claim_now -> true
  | Skip_claim _ -> false
;;

(** When the Task last changed state, read from the timestamp its own status
    carries. [Todo] has no transition of its own and falls back to creation.
    Defined once: two byte-identical copies lived in the execution and goals
    projections, one per surface. *)
let task_last_transition_at (task : task) =
  match task.task_status with
  | Done { completed_at; _ } -> completed_at
  | Cancelled { cancelled_at; _ } -> cancelled_at
  | InProgress { started_at; _ } -> started_at
  | AwaitingVerification { submitted_at; _ } -> submitted_at
  | Claimed { claimed_at; _ } -> claimed_at
  | Todo -> task.created_at

(* Manual yojson for task *)
let task_to_yojson t =
  let status_json = task_status_to_yojson t.task_status in
  let base = [
    ("id", `String t.id);
    ("title", `String t.title);
    ("description", `String t.description);
    ("priority", `Int t.priority);
    ("files", `List (List.map (fun s -> `String s) t.files));
    ("created_at", `String t.created_at);
  ] in
  let with_created_by = match t.created_by with
    | None -> base
    | Some created_by -> base @ [("created_by", `String created_by)]
  in
  (* Omitted when no predecessor exists. *)
  let with_predecessor = match t.predecessor_task_id with
    | None -> with_created_by
    | Some p -> with_created_by @ [("predecessor_task_id", `String p)]
  in
  let with_contract = match t.contract with
    | None -> with_predecessor
    | Some contract ->
        with_predecessor @ [ ("contract", task_contract_to_yojson contract) ]
  in
  (* Omitted while unlinked, so a task carries the key only once an execution
     claimed it. *)
  let with_execution_links =
    match t.execution_links with
    | { operation_id = None; session_id = None } -> with_contract
    | links ->
        with_contract
        @ [ ("execution_links", task_execution_links_to_yojson links) ]
  in
  let with_handoff_context = match t.handoff_context with
    | None -> with_execution_links
    | Some handoff_context ->
        with_execution_links
        @
        [ ( "handoff_context",
            task_handoff_context_to_yojson handoff_context ) ]
  in
  (* A zero cycle count is the implicit initial state. *)
  let with_cycle_count =
    if t.cycle_count = 0 then with_handoff_context
    else with_handoff_context @ [("cycle_count", `Int t.cycle_count)]
  in
  let with_reclaim_policy =
    match t.reclaim_policy with
    | None -> with_cycle_count
    | Some policy ->
        with_cycle_count
        @ [("reclaim_policy", task_reclaim_policy_to_yojson policy)]
  in
  let with_do_not_reclaim = match t.do_not_reclaim_reason with
    | None -> with_reclaim_policy
    | Some r -> with_reclaim_policy @ [("do_not_reclaim_reason", `String r)]
  in
  (* Omitted when the Task declares no Skill. A present value always uses the
     canonical exact-reference wire shape. *)
  let with_skills =
    match t.skills with
    | [] -> with_do_not_reclaim
    | skills ->
        with_do_not_reclaim
        @ [("skills", Skill_reference.list_to_yojson skills)]
  in
  (* Merge status fields into task *)
  match status_json with
  | `Assoc status_fields -> `Assoc (with_skills @ status_fields)
  | _ -> `Assoc with_skills

(* Listing row for keeper tools: identity, ordering, and claim state without
   the body. A live backlog row averages 2.0 KB of which handoff_context,
   description, and contract are 89% (#29463); this carries the remaining
   fields so a 50-row listing stays a few KB. *)
let task_compact_to_yojson t =
  let base = [
    ("id", `String t.id);
    ("title", `String t.title);
    ("priority", `Int t.priority);
    ("created_at", `String t.created_at);
  ] in
  match task_status_to_yojson t.task_status with
  | `Assoc status_fields -> `Assoc (base @ status_fields)
  | _ -> `Assoc base

let task_of_yojson json =
  let req key = Json_util.get_string_with_default json ~key ~default:"" in
  let opt key = Json_util.get_string json key in
  let member key = Json_util.assoc_member_opt key json in
  let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key json) in
  try
    let id = req "id" in
    let title = req "title" in
    let description = opt "description" |> Option.value ~default:"" in
    let priority = Json_util.get_int json "priority" |> Option.value ~default:3 in
    let files = Json_util.get_string_list json "files" in
    let skills_result =
      match member "skills" with
      | None -> Ok []
      | Some skills_json ->
        Skill_reference.list_of_yojson skills_json
        |> Result.map_error (fun error ->
          let detail =
            match error with
            | Skill_reference.Expected_object { field } ->
              Printf.sprintf "%s must be an object" field
            | Expected_list _ -> "skills must be a list"
            | Missing_field { object_name; field } ->
              Printf.sprintf "%s.%s is required" object_name field
            | Expected_string { object_name; field } ->
              Printf.sprintf "%s.%s must be a string" object_name field
            | Duplicate_field { object_name; field } ->
              Printf.sprintf "%s.%s is duplicated" object_name field
            | Unexpected_field { object_name; field } ->
              Printf.sprintf "%s.%s is unexpected" object_name field
            | Invalid_source_id source_id ->
              Printf.sprintf "source_id %S is invalid" source_id
            | Invalid_package_id _ -> "package_id is invalid"
            | Invalid_content_revision _ -> "content_revision is invalid"
            | Duplicate_reference reference ->
              Printf.sprintf
                "exact reference is duplicated: %s"
                (Yojson.Safe.to_string (Skill_reference.to_yojson reference))
          in
          "task.skills corrupt: " ^ detail)
    in
    let created_at = req "created_at" in
    let created_by = opt "created_by" in
    (* The predecessor link is optional. *)
    let predecessor_task_id = opt "predecessor_task_id" in
    let contract_result =
      match member "contract" with
      | None | Some `Null -> Ok None
      | Some contract_json ->
        Result.map Option.some (task_contract_of_yojson contract_json)
    in
    let execution_links_result =
      match member "execution_links" with
      | None -> Ok no_execution_links
      | Some links_json -> task_execution_links_of_yojson links_json
    in
    let handoff_context = match m "handoff_context" with
      | `Null -> None
      | handoff_json ->
          (match task_handoff_context_of_yojson handoff_json with
           | Ok handoff_context -> Some handoff_context
           | Error _ -> None)
    in
    let cycle_count = Json_util.get_int json "cycle_count" |> Option.value ~default:0 in
    let reclaim_policy =
      match m "reclaim_policy" with
      | `Null -> None
      | reclaim_policy_json ->
          (match task_reclaim_policy_of_yojson reclaim_policy_json with
           | Ok policy -> Some policy
           | Error _ -> None)
    in
    let do_not_reclaim_reason = opt "do_not_reclaim_reason" in
    match
      skills_result, contract_result, execution_links_result, task_status_of_yojson json
    with
    | Ok skills, Ok contract, Ok execution_links, Ok task_status ->
        Ok
          {
            id;
            title;
            description;
            task_status;
            priority;
            files;
            created_at;
            created_by;
            predecessor_task_id;
            contract;
            execution_links;
            handoff_context;
            cycle_count;
            reclaim_policy;
            do_not_reclaim_reason;
            skills;
          }
    | Error error, _, _, _ -> Error error
    | _, Error error, _, _ -> Error ("task.contract corrupt: " ^ error)
    | _, _, Error error, _ -> Error ("task.execution_links corrupt: " ^ error)
    | _, _, _, Error error -> Error error
  with e -> Error (Printexc.to_string e)

(** Message - broadcast or direct *)
type message_mention_delivery =
  | Mention_passive
  | Mention_pending
  | Mention_accepted
  | Mention_rejected
[@@deriving yojson, show]

let message_mention_delivery_to_string = function
  | Mention_passive -> "passive"
  | Mention_pending -> "pending"
  | Mention_accepted -> "accepted"
  | Mention_rejected -> "rejected"

type message = {
  request_id: string;
  seq: int;
  from_agent: string; [@key "from"]
  msg_type: string; [@key "type"] [@default "broadcast"]
  content: string;
  mention: string option; [@default None]
  mention_delivery: message_mention_delivery;
  timestamp: string;
  trace_context: string option; [@default None]
  expires_at: float option; [@default None]
} [@@deriving yojson { strict = false }, show]

(** Workspace state *)
type workspace_state = {
  protocol_version: string;
  project: string;
  started_at: string;
  message_seq: int;
  active_agents: string list;
  paused: bool; [@default false]  (** Global pause flag - when true, orchestrator won't spawn *)
  pause_reason: string option; [@default None]  (** Reason for pause *)
  paused_by: string option; [@default None]  (** Who paused the workspace *)
  paused_at: string option; [@default None]  (** When paused *)
  search_strategy_default: string option; [@default None]
  speculation_enabled: bool; [@default false]
  speculation_budget: int option; [@default None]
} [@@deriving yojson { strict = false }, show]

(* ============================================ *)
(* Tempo configuration for cluster pace control *)
(* ============================================ *)

(** Tempo mode - controls cluster execution pace *)
type tempo_mode =
  | Normal    (* Default speed *)
  | Slow      (* Slow pace - careful work *)
  | Fast      (* Fast pace - simple tasks *)
  | Paused    (* Temporarily paused *)
[@@deriving show { with_path = false }]

let tempo_mode_to_string = function
  | Normal -> "normal"
  | Slow -> "slow"
  | Fast -> "fast"
  | Paused -> "paused"

(* Alias for dashboard compatibility *)
let string_of_tempo_mode = tempo_mode_to_string

let tempo_mode_of_string = function
  | "normal" -> Ok Normal
  | "slow" -> Ok Slow
  | "fast" -> Ok Fast
  | "paused" -> Ok Paused
  | s -> Error ("Unknown tempo mode: " ^ s)

let tempo_mode_to_yojson mode = `String (tempo_mode_to_string mode)

let tempo_mode_of_yojson = function
  | `String s -> tempo_mode_of_string s
  | other ->
    Error
      (Printf.sprintf "Expected string for tempo_mode (received %s)"
         (Json_util.kind_name other))

(** Tempo configuration *)
type tempo_config = {
  mode: tempo_mode;
  delay_ms: int;             (* Delay between operations in milliseconds *)
  reason: string option;     (* Why this tempo was set *)
  set_by: string option;     (* Who set this tempo *)
  set_at: string option;     (* When this tempo was set *)
} [@@deriving show]

let default_tempo_config = {
  mode = Normal;
  delay_ms = 0;
  reason = None;
  set_by = None;
  set_at = None;
}

let tempo_config_to_yojson c =
  `Assoc [
    ("mode", tempo_mode_to_yojson c.mode);
    ("delay_ms", `Int c.delay_ms);
    ("reason", Json_util.string_opt_to_json c.reason);
    ("set_by", Json_util.string_opt_to_json c.set_by);
    ("set_at", Json_util.string_opt_to_json c.set_at);
  ]

let tempo_config_of_yojson json =
  try
    let mode_str = Json_util.get_string_with_default json ~key:"mode" ~default:"" in
    let delay_ms = Json_util.get_int json "delay_ms" |> Option.value ~default:0 in
    let reason = Json_util.get_string json "reason" in
    let set_by = Json_util.get_string json "set_by" in
    let set_at = Json_util.get_string json "set_at" in
    match tempo_mode_of_string mode_str with
    | Ok mode -> Ok { mode; delay_ms; reason; set_by; set_at }
    | Error e -> Error e
  with e -> Error (Printexc.to_string e)

(** Backlog (task collection) *)
type backlog = {
  tasks: task list;
  last_updated: string;
  version: int;
} [@@deriving show]

let backlog_to_yojson b =
  `Assoc [
    ("tasks", `List (List.map task_to_yojson b.tasks));
    ("last_updated", `String b.last_updated);
    ("version", `Int b.version);
  ]

let backlog_of_yojson = function
  | `Assoc fields ->
    let fields =
      List.sort (fun (left, _) (right, _) -> String.compare left right) fields
    in
    (match fields with
     | [ "last_updated", `String last_updated
       ; "tasks", `List task_values
       ; "version", version_json
       ] when not (String.equal (String.trim last_updated) "") ->
       let rec decode_tasks index acc = function
         | [] -> Ok (List.rev acc)
         | task_json :: rest ->
           (match task_of_yojson task_json with
            | Ok task -> decode_tasks (index + 1) (task :: acc) rest
            | Error message ->
              Error
                (Printf.sprintf
                   "backlog.tasks[%d] corrupt: %s"
                   index
                   message))
       in
       let version_result =
         match version_json with
         | `Int value when value >= 1 -> Ok value
         | `Intlit raw ->
           (match int_of_string_opt raw with
            | Some value when value >= 1 -> Ok value
            | Some _ | None ->
              Error (Printf.sprintf "backlog.version corrupt: %s" raw))
         | other ->
           Error
             (Printf.sprintf
                "backlog.version corrupt: %s"
                (Yojson.Safe.to_string other))
       in
       (match decode_tasks 0 [] task_values, version_result with
        | Ok tasks, Ok version -> Ok { tasks; last_updated; version }
        | Error _ as error, _ | _, (Error _ as error) -> error)
     | [ "last_updated", `String _; "tasks", `List _; "version", _ ] ->
       Error "backlog.last_updated must be a non-blank string"
     | _ ->
       Error
         "backlog must contain exactly one tasks list, last_updated string, and positive version")
  | other ->
    Error
      (Printf.sprintf
         "backlog must be an object, got %s"
         (Yojson.Safe.to_string other))

(** SSE Session info (for tracking connected agents) *)
type sse_session = {
  agent_name: string;
  connected_at: string;
  last_activity: float; (* Unix timestamp for easy comparison *)
  is_listening: bool;
} [@@deriving show]

(** MCP Tool result *)
type tool_result = {
  success: bool;
  message: string;
  data: Yojson.Safe.t option; [@default None]
} [@@deriving show]

let tool_result_to_yojson r =
  let base = [
    ("success", `Bool r.success);
    ("message", `String r.message);
  ] in
  match r.data with
  | Some d -> `Assoc (base @ [("data", d)])
  | None -> `Assoc base

(** Tool schema for MCP *)
type tool_schema = {
  name: string;
  description: string;
  input_schema: Yojson.Safe.t;
}

(** Structured result for claim_next scheduling (avoids brittle string parsing).
    Defined here so that both Workspace_task_schedule (producer) and consumers
    (tool_task, orchestrator) can reference the type without
    triggering warning 34 from [include] re-export. *)
type claim_next_result =
  | Claim_next_claimed of {
      task_id : string;
      title : string;
      priority : int;
      message : string;
      scope_widened : bool;
          (** True when goal-scope was widened to all_tasks because no scoped
              task was admission-eligible (schedule-level fallback). Lets the
              operator distinguish a scope-overriding claim from an ordinary
              in-scope claim. *)
    }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of
      { excluded_count : int
      ; scope_excluded_count : int
      ; explicit_excluded_count : int
      ; claim_pool_candidate_count : int
      }
  | Claim_next_error of string
