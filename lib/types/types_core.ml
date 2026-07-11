(** MASC MCP Types - Domain Model *)

(* Newtypes are in ids.ml *)
include Ids

(* ============================================ *)
(* Timestamp utilities                          *)
(* ============================================ *)

(** Timestamp utilities *)
let now_iso () =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

(** Parse ISO8601 "YYYY-MM-DDTHH:MM:SSZ" to Unix float (UTC). *)
let parse_iso8601_opt s =
  try
    Scanf.sscanf s "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (fun year mon day hour min sec ->
        let tm = {
          Unix.tm_sec = sec; tm_min = min; tm_hour = hour;
          tm_mday = day; tm_mon = mon - 1; tm_year = year - 1900;
          tm_wday = 0; tm_yday = 0; tm_isdst = false;
        } in
        let local_epoch, _ = Unix.mktime tm in
        let utc_of_local = Unix.gmtime local_epoch in
        let utc_as_local, _ = Unix.mktime utc_of_local in
        let tz_offset = local_epoch -. utc_as_local in
        Some (local_epoch +. tz_offset))
  with Scanf.Scan_failure _ | Failure _ | End_of_file -> None

(** Parse ISO8601 timestamp to Unix float. Returns default_time on parse failure. *)
let parse_iso8601 ?(default_time = Time_compat.now () -. 60.0) timestamp =
  match parse_iso8601_opt timestamp with
  | Some unix_ts -> unix_ts
  | None -> default_time

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

let agent_of_yojson_generated = agent_of_yojson

let iso8601_of_unix_seconds ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let normalize_agent_last_seen ~session_bound_at = function
  | `String _ as value -> Some value
  | `Int seconds ->
      Some (`String (iso8601_of_unix_seconds (float_of_int seconds)))
  | `Float seconds ->
      Some (`String (iso8601_of_unix_seconds seconds))
  | `Null -> session_bound_at  (* bootstrap from session_bound_at — see #7947 *)
  | _ -> None

let short_json_repr = function
  | `Null -> "null"
  | `Bool b -> Printf.sprintf "%b" b
  | `Int i -> string_of_int i
  | `Float f -> Printf.sprintf "%g" f
  | `String s ->
      if String.length s <= 40 then Printf.sprintf "\"%s\"" s
      else Printf.sprintf "\"%s...\"" (String.sub s 0 37)
  | `Assoc _ -> "<object>"
  | `List _ -> "<array>"
  | `Intlit s -> s
  | `Tuple _ -> "<tuple>"
  | `Variant _ -> "<variant>"

let agent_of_yojson json =
  match agent_of_yojson_generated json with
  | Ok _ as ok -> ok
  | Error original_error -> (
      match json with
      | `Assoc fields ->
          let session_bound_at_value =
            match List.assoc_opt "session_bound_at" fields with
            | Some (`String _ as v) -> Some v
            | _ -> None
          in
          let last_seen_raw = List.assoc_opt "last_seen" fields in
          let annotated_error () =
            let last_seen_repr =
              match last_seen_raw with
              | Some v -> short_json_repr v
              | None -> "<missing>"
            in
            Printf.sprintf "%s (last_seen=%s)" original_error last_seen_repr
          in
          let now_iso () =
            `String (iso8601_of_unix_seconds (Unix.gettimeofday ()))
          in
          let normalized_last_seen =
            match last_seen_raw with
            | Some value ->
                normalize_agent_last_seen ~session_bound_at:session_bound_at_value value
            | None ->
                (* Missing last_seen → bootstrap from session_bound_at when
                   present, otherwise fall back to the current wall-clock
                   time (#9751).  [last_seen] is a liveness marker, not
                   identity-critical; a recent-but-approximate timestamp
                   is strictly better than failing the whole record
                   deserialisation for an optional field. *)
                (match session_bound_at_value with
                 | Some _ as v -> v
                 | None -> Some (now_iso ()))
          in
          (match normalized_last_seen with
          | Some normalized_last_seen ->
              let fields_without_last_seen =
                ("last_seen", normalized_last_seen)
                :: List.remove_assoc "last_seen" fields
              in
              (* If session_bound_at is also unusable, inject a now() value so
                 the generated deserialiser's required-field check passes.
                 The agent record can always be rebuilt from a heartbeat;
                 losing the whole entry because of a missing timestamp is
                 strictly worse (#9751). *)
              let normalized_fields =
                match session_bound_at_value with
                | Some _ -> fields_without_last_seen
                | None ->
                    ("session_bound_at", now_iso ())
                    :: List.remove_assoc "session_bound_at" fields_without_last_seen
              in
              (match agent_of_yojson_generated (`Assoc normalized_fields) with
               | Ok _ as ok -> ok
               | Error _ -> Error (annotated_error ()))
          | None -> Error (annotated_error ()))
      | _ -> Error original_error)

(** Task status - state transitions enforced by types *)
type task_action =
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
[@@deriving show]

(** RFC-0262: who authorizes a transition that would otherwise require the
    task's assignee. Replaces the anonymous [~force:bool] that voided ownership
    and every completion gate (RFC-0262 §1.2). Resolved once at the tool
    boundary (Parse, don't validate); never threaded as a bare bool any layer
    can flip to [true]. The closed sum is extensible by RFC: a new authority
    forces the compiler to enumerate every guarded [decide] arm. *)
type completion_authority =
  | Assignee  (** the task's current claimant acting on its own claim *)
  | Operator  (** operator control plane / explicit admin override *)
  | System
      (** code-path satisfier (RFC-0199 deterministic evidence probe, GC zombie
          cleanup); never minted by an LLM/keeper turn *)
[@@deriving show]

(* Stable wire label for transition-log serialization. Deliberately not
   [show_completion_authority] — [@@deriving show] emits the constructor name and
   its formatting is an implementation detail; the log schema (and the §9 auditor
   that reads it) must pin a fixed lowercase token. *)
let completion_authority_to_string = function
  | Assignee -> "assignee"
  | Operator -> "operator"
  | System -> "system"
;;

let task_action_of_string s =
  match String.lowercase_ascii s with
  | "claim" -> Ok Claim
  | "start" -> Ok Start
  | "done" -> Ok Done_action
  | "cancel" -> Ok Cancel
  | "release" -> Ok Release
  | "submit_for_verification" -> Ok Submit_for_verification
  | "approve" -> Ok Approve_verification
  | "reject" -> Ok Reject_verification
  | "block_for_operator" -> Ok Block_for_operator
  | "unblock" -> Ok Unblock
  | other -> Error (Printf.sprintf "Unknown task action: %s" other)

let task_action_to_string = function
  | Claim -> "claim"
  | Start -> "start"
  | Done_action -> "done"
  | Cancel -> "cancel"
  | Release -> "release"
  | Submit_for_verification -> "submit_for_verification"
  | Approve_verification -> "approve"
  | Reject_verification -> "reject"
  | Block_for_operator -> "block_for_operator"
  | Unblock -> "unblock"

(** All valid task actions, derived from the ADT (single source of truth). *)
let all_task_actions =
  [ Claim; Start; Done_action; Cancel; Release;
    Submit_for_verification; Approve_verification; Reject_verification;
    Block_for_operator; Unblock ]
let valid_task_action_strings = List.map task_action_to_string all_task_actions

(* RFC-0220: the verification sub-state (previously a separate request_status
   store: `Pending / `Assigned) is folded into [task_status] so the illegal
   "task Todo + request Pending" pair is unrepresentable. *)
type verification_phase =
  | Awaiting_verifier
      (** No verifier assigned yet (was verification request [`Pending]). *)
  | Verifier_assigned of { verifier: string }
      (** A verifier keeper is assigned (was [`Assigned verifier]). *)
[@@deriving show]

type task_status =
  | Todo
  | Claimed of { assignee: string; claimed_at: string }
  | InProgress of { assignee: string; started_at: string }
  | AwaitingVerification of {
      assignee: string;
      submitted_at: string;
      verification_id: string;
      phase: verification_phase;
        (** RFC-0220: replaces [deadline : string option]. The deadline is
            dropped per I2 (no per-obligation wall-clock deadline); the
            verification sub-state lives here so it cannot drift from a
            separate store. *)
    }
  | Done of { assignee: string; completed_at: string; notes: string option }
  | Cancelled of { cancelled_by: string; cancelled_at: string; reason: string option }
  | OperatorBlocked of { assignee: string; blocked_at: string; reason: string option }
[@@deriving show]

(** RFC-0220 §3.5: the [task_status] of an [AwaitingVerification] obligation
    once [verifier] has claimed it as its satisfier. The obligation is preserved
    (it stays in the verifier pool, and any non-submitter can still
    approve/reject it — [decide]'s approval arms match the phase with [_]) and
    the verifier is recorded in [phase]. Single construction site shared by the
    FSM decider and both claim writers ([claim_task_r], [claim_next_r]) so the
    bound-verifier shape never drifts across surfaces. The binding is advisory:
    it records who is verifying, not who is permitted to — an abandoned
    [Verifier_assigned] task is re-claimable by another verifier. *)
let bind_verifier ~verifier ~assignee ~submitted_at ~verification_id =
  AwaitingVerification
    { assignee; submitted_at; verification_id; phase = Verifier_assigned { verifier } }

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

(** Display assignee for task status.
    Cancelled surfaces [cancelled_by]; Todo yields "unclaimed".
    For ownership checks returning [option], use [task_assignee_of_status]. *)
let task_display_assignee = function
  | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ }
  | AwaitingVerification { assignee; _ } -> assignee
  | Cancelled { cancelled_by; _ } -> cancelled_by
  | Todo -> "unclaimed"

(** Extract assignee as [Some string], or [None] for Todo/Cancelled.
    Canonical ownership-check helper — used by task_state, gRPC, etc. *)
let task_assignee_of_status = function
  | Claimed { assignee; _ } -> Some assignee
  | InProgress { assignee; _ } -> Some assignee
  | AwaitingVerification { assignee; _ } -> Some assignee
  | Todo | Done _ | Cancelled _ -> None

(** Terminal states: [Done] or [Cancelled]. No further transitions possible.
    Exhaustive match — adding a constructor forces an update here. *)
let task_status_is_terminal = function
  | Done _ | Cancelled _ -> true
  | Todo | Claimed _ | InProgress _ | AwaitingVerification _ | OperatorBlocked _ -> false

(** Completed state: [Done]. Distinct from [task_status_is_terminal] which
    also includes [Cancelled]. Use this when only successful completion
    matters (e.g. convergence ratios, reputation counting). *)
let task_status_is_done = function
  | Done _ -> true
  | Todo | Claimed _ | InProgress _ | AwaitingVerification _ | Cancelled _ | OperatorBlocked _ -> false

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

    The remaining hand-coded axis is the witness list's length —
    [test_types.ml] pins it at 6, so adding a constructor without
    adding a witness here breaks that test.

    Order matches the FSM lifecycle (Todo -> Claimed -> InProgress ->
    AwaitingVerification -> Done | Cancelled) for readable schema docs. *)
let task_status_schema_witnesses : task_status list =
  let placeholder = "" in
  [ Todo
  ; Claimed { assignee = placeholder; claimed_at = placeholder }
  ; InProgress { assignee = placeholder; started_at = placeholder }
  ; AwaitingVerification
      { assignee = placeholder
      ; submitted_at = placeholder
      ; verification_id = placeholder
      ; phase = Awaiting_verifier
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
  | AwaitingVerification { assignee; submitted_at; verification_id; phase } ->
      let phase_fields =
        match phase with
        | Awaiting_verifier -> [ ("phase", `String "awaiting_verifier") ]
        | Verifier_assigned { verifier } ->
            [ ("phase", `String "verifier_assigned");
              ("verifier", `String verifier) ]
      in
      `Assoc ([
        ("status", `String "awaiting_verification");
        ("assignee", `String assignee);
        ("submitted_at", `String submitted_at);
        ("verification_id", `String verification_id);
      ] @ phase_fields)
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
        (* RFC-0220 migration tolerance: legacy backlogs carry [deadline]
           (now dropped) and no [phase]; a missing/legacy phase defaults to
           [Awaiting_verifier]. *)
        let phase =
          match opt "phase" with
          | Some "verifier_assigned" ->
              Verifier_assigned { verifier = req "verifier" }
          | Some "awaiting_verifier" | None | Some _ -> Awaiting_verifier
        in
        Ok (AwaitingVerification
              { assignee = req "assignee"
              ; submitted_at = req "submitted_at"
              ; verification_id = req "verification_id"
              ; phase
              })
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
} [@@deriving show, yojson { strict = false }]

(** Task contract - persisted deterministic gate inputs.

    [required_evidence : string list] is the live source of truth: the contract
    evidence gate ([Task_completion_gate]) substring-matches each entry against
    task-completion notes / handoff refs to decide whether a contracted task
    may complete.

    RFC-0199 Phase A added a parallel [required_evidence_typed :
    Evidence_claim.t list] meant for a future [Deterministic_evidence_evaluator]
    (Phase B). That field was removed (2026-06-03): fan-in was 0 — no producer
    ever populated it (every site wrote [[]]), no consumer ever read it, and the
    Phase B evaluator was never implemented. The [Evidence_claim] schema module
    is retained for when Phase B is built; see RFC-0199 for the deferral note.
    A future Phase B should re-introduce a typed field with a migration that
    parses legacy [required_evidence] strings (RFC-0199 open question), not a
    silently-empty parallel field.

    A [required_tools : string list] field was also removed (2026-06-03,
    same fan-in-0 pattern): it was deprecated and ignored by task claim
    routing, always normalized to [[]] by [Workspace_task_classify], had no
    production reader, and the keeper turn layer rejects the [required_tools]
    key outright (#19806, [Keeper_config_text]). Later cleanup removed the
    same-named dashboard and tool-call benchmark fields too, so the string no
    longer names any task, dashboard, or benchmark contract surface. *)
type task_contract = {
  strict : bool; [@default false]
  completion_contract : string list; [@default []]
  required_evidence : string list; [@default []]
  inspect_gate_evidence : string list; [@default []]
  verify_gate_evidence : string list; [@default []]
  evidence_claims : Evidence_claim.t list; [@default []]
  (* RFC-0199 Phase B: typed deterministic completion criteria (see .mli). *)
  stale_claim_timeout_sec : int; [@default 0]
  links : task_execution_links; [@default { operation_id = None; session_id = None }]
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
  handoff_context: task_handoff_context option; [@default None]
  cycle_count: int; [@default 0]
  reclaim_policy: task_reclaim_policy option; [@default None]
  do_not_reclaim_reason: string option; [@default None]
} [@@deriving show]

(* RFC-0323 W1 Phase A (implements RFC-0308): completion must route through
   submit -> approve when the contract opts into strict verification.
   Contract *presence* is deliberately NOT the trigger: task creation
   auto-fills an advisory contract for every task
   (ensure_task_contract_for_verification), so presence is vacuously true
   fleet-wide and would flip Phase B semantics on unannounced. [strict] is
   the explicit, persisted opt-in — it already gates release-handoff the
   same way. Phase B replaces this predicate with a default-on one. *)
let task_requires_verification (t : task) =
  match t.contract with
  | Some contract -> contract.strict
  | None -> false

(* RFC-0323 G-10: the typed reclaim claim gate is retired. #23661 removed its
   Todo producer; this change removes the Done producer, so nothing can be
   blocked-by-reclaim at claim time anymore. [reclaim_policy] survives as
   release/cancel data plumbing only (its full retirement is a recorded
   follow-up decision, RFC-0323 Radius Map). *)

type task_claim_readiness =
  | Claim_ready

type task_claim_block =
  | Claim_block_not_todo of task_status

type task_claim_decision =
  | Claim_available of task_claim_readiness
  | Claim_unavailable of task_claim_block

let task_claim_readiness (_task : task) = Claim_ready
;;

let task_claim_decision (task : task) =
  match task.task_status with
  | Todo ->
    (* Todo tasks are always claimable regardless of reclaim_policy.
       reclaim_policy only gates Done -> re-claim, not Todo -> first claim.
       task-1869: 6 TaskError fingerprints show coordination-role tasks
       with Block_reclaim policy were blocked from claiming. *)
    Claim_available (task_claim_readiness task)
  | AwaitingVerification { verification_id; _ } ->
    (* Verification tasks with a valid verification_id can be claimed by
       other agents for cross-agent verification dispatch. The actual
       cross-agent check (self-verification block) happens in claim_task_r.
       Issue #19314. verification_id is a non-empty string — always claimable. *)
    Claim_available (task_claim_readiness task)
  | Done _
  (* RFC-0323: a verified Done is terminal for every actor, regardless of
     reclaim_policy — re-running completed work creates a NEW task linked via
     predecessor_task_id. Retires the #23632 Done-reclaim mechanism (which
     was production-unreachable: creation defaults the policy to None and
     claiming wipes it). *)
  | Claimed _
  | InProgress _
  | Cancelled _ ->
    Claim_unavailable (Claim_block_not_todo task.task_status)
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
  (* Omitted when None (created_by pattern): old readers never see the key. *)
  let with_predecessor = match t.predecessor_task_id with
    | None -> with_created_by
    | Some p -> with_created_by @ [("predecessor_task_id", `String p)]
  in
  let with_contract = match t.contract with
    | None -> with_predecessor
    | Some contract ->
        with_predecessor @ [ ("contract", task_contract_to_yojson contract) ]
  in
  let with_handoff_context = match t.handoff_context with
    | None -> with_contract
    | Some handoff_context ->
        with_contract
        @
        [ ( "handoff_context",
            task_handoff_context_to_yojson handoff_context ) ]
  in
  (* cycle_count omitted when 0 for backward-compat on existing backlogs. *)
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
  (* Merge status fields into task *)
  match status_json with
  | `Assoc status_fields -> `Assoc (with_do_not_reclaim @ status_fields)
  | _ -> `Assoc with_do_not_reclaim

let task_of_yojson json =
  let req key = Json_util.get_string_with_default json ~key ~default:"" in
  let opt key = Json_util.get_string json key in
  let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key json) in
  try
    let id = req "id" in
    let title = req "title" in
    let description = opt "description" |> Option.value ~default:"" in
    let priority = Json_util.get_int json "priority" |> Option.value ~default:3 in
    let files = Json_util.get_string_list json "files" in
    let created_at = req "created_at" in
    let created_by = opt "created_by" in
    (* Absent or non-string value degrades to None — a decode Error here would
       make backlog_of_yojson silently drop the whole task. *)
    let predecessor_task_id = opt "predecessor_task_id" in
    let contract = match m "contract" with
      | `Null -> None
      | contract_json ->
          (match task_contract_of_yojson contract_json with
           | Ok contract -> Some contract
           | Error _ -> None)
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
    match task_status_of_yojson json with
    | Ok task_status ->
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
            handoff_context;
            cycle_count;
            reclaim_policy;
            do_not_reclaim_reason;
          }
    | Error e -> Error e
  with e -> Error (Printexc.to_string e)

(** Message - broadcast or direct *)
type message = {
  seq: int;
  from_agent: string; [@key "from"]
  msg_type: string; [@key "type"] [@default "broadcast"]
  content: string;
  mention: string option; [@default None]
  timestamp: string;
  trace_context: string option; [@default None]
  expires_at: float option; [@default None]
  relevance: string; [@default "medium"]
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

let backlog_of_yojson json =
  let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key json) in
  try
    let tasks_json = match m "tasks" with `List l -> l | _ -> [] in
    let tasks = List.filter_map (fun j ->
      match task_of_yojson j with Ok t -> Some t | Error _ -> None
    ) tasks_json in
    (* [last_updated] and [version] are display metadata; writers may
       omit them (observed in live basepath [<base-path>/.masc/tasks/backlog.json]
       where the top-level is just [{"tasks": [...]}]).  Strict
       [to_string]/[to_int] decoders rejected such payloads as
       [Type_error("Expected string, got null")], forcing every reader
       onto the [read_backlog] empty fallback and wiping every claim
       from the reader's view (hundreds of [read_backlog backlog decode
       failed] entries/day driven [stale-claims] GC to skip mutation,
       so claims never transitioned).  Tolerate missing/null fields. *)
    let last_updated =
      Json_util.get_string_with_default json ~key:"last_updated" ~default:""
    in
    let version =
      Json_util.get_int json "version" |> Option.value ~default:1
    in
    Ok { tasks; last_updated; version }
  with e -> Error (Printexc.to_string e)

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
      released_task_id : string option;  (** Legacy field; claim_next no longer auto-releases active work. *)
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
      ; blocked_count : int
      ; verification_blocked_count : int
      ; scope_excluded_count : int
      ; explicit_excluded_count : int
      ; claim_pool_candidate_count : int
      }
  | Claim_next_error of string
