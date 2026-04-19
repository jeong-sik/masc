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

(* ============================================ *)
(* Agent Role - task assignment roles           *)
(* ============================================ *)

(** Agent role for task assignment. *)
type role =
  | Writer     (** Produces artifacts: code, docs, designs *)
  | Reviewer   (** Reviews artifacts: code review, QA, ethics *)
  | Admin      (** Administrative: orchestration, assignment *)
  | Unassigned (** No specific role (legacy/default) *)

let pp_role fmt r =
  Format.fprintf fmt "%s"
    (match r with
     | Writer -> "Writer"
     | Reviewer -> "Reviewer"
     | Admin -> "Admin"
     | Unassigned -> "Unassigned")

let equal_role a b =
  match a, b with
  | Writer, Writer | Reviewer, Reviewer | Admin, Admin | Unassigned, Unassigned -> true
  | _ -> false

let show_role r =
  Format.asprintf "%a" pp_role r

let role_to_string = function
  | Writer -> "writer"
  | Reviewer -> "reviewer"
  | Admin -> "admin"
  | Unassigned -> "unassigned"

let role_of_string_opt = function
  | "writer" | "write" | "author" | "implementer" -> Some Writer
  | "reviewer" | "review" | "qa" | "auditor" -> Some Reviewer
  | "admin" | "administrator" | "orchestrator" -> Some Admin
  | "unassigned" -> Some Unassigned
  | _ -> None

let role_of_string s =
  role_of_string_opt s |> Option.value ~default:Unassigned

let role_to_yojson r = `String (role_to_string r)

let role_of_yojson = function
  | `String s ->
    (match role_of_string_opt s with
     | Some r -> Ok r
     | None -> Error (Printf.sprintf "role_of_yojson: unknown role %S" s))
  | _ -> Error "role_of_yojson: expected string"

(** Check if agent role satisfies a required role.
    Admin can satisfy any requirement. Unassigned requirement is satisfied by any role. *)
let role_satisfies ~(required : role) ~(agent_role : role) : bool =
  match required, agent_role with
  | Unassigned, _ -> true
  | _, Admin -> true
  | Writer, Writer -> true
  | Reviewer, Reviewer -> true
  | Admin, _ -> false
  | _ -> false

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

let agent_status_of_string s =
  match agent_status_of_string_opt s with
  | Some status -> status
  | None -> Active  (* Safe default instead of failwith *)

(* Custom yojson converters for lowercase JSON compatibility *)
let agent_status_to_yojson status = `String (agent_status_to_string status)

let agent_status_of_yojson = function
  | `String s ->
      (match agent_status_of_string_opt s with
       | Some status -> Ok status
       | None -> Error ("Unknown agent status: " ^ s))
  | _ -> Error "agent_status: expected string"

(** Agent metadata - session identification and environment info *)
type agent_meta = {
  session_id: string;                     (* short UUID for unique identification *)
  agent_type: string;                     (* claude, gemini, codex *)
  pid: int option; [@default None]        (* process ID *)
  hostname: string option; [@default None] (* machine hostname *)
  tty: string option; [@default None]     (* terminal identifier *)
  worktree: string option; [@default None] (* git worktree path *)
  parent_task: string option; [@default None] (* task that spawned this agent *)
} [@@deriving yojson { strict = false }, show]

(** Agent info *)
type agent = {
  name: string;                           (* unique nickname: claude-swift-fox *)
  agent_type: string; [@default "unknown"] (* original type: claude, gemini, codex *)
  status: agent_status;
  capabilities: string list;
  current_task: string option; [@default None]
  joined_at: string;
  last_seen: string;
  meta: agent_meta option; [@default None] (* session metadata *)
} [@@deriving yojson { strict = false }, show]

let agent_of_yojson_generated = agent_of_yojson

let iso8601_of_unix_seconds ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let normalize_agent_last_seen ~joined_at = function
  | `String _ as value -> Some value
  | `Int seconds ->
      Some (`String (iso8601_of_unix_seconds (float_of_int seconds)))
  | `Float seconds ->
      Some (`String (iso8601_of_unix_seconds seconds))
  | `Null -> joined_at  (* bootstrap from joined_at — see #7947 *)
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
          let joined_at_value =
            match List.assoc_opt "joined_at" fields with
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
          (match
             match last_seen_raw with
             | Some value -> normalize_agent_last_seen ~joined_at:joined_at_value value
             | None -> joined_at_value  (* missing last_seen → bootstrap *)
           with
          | Some normalized_last_seen ->
              let normalized_fields =
                ("last_seen", normalized_last_seen)
                :: List.remove_assoc "last_seen" fields
              in
              (match agent_of_yojson_generated (`Assoc normalized_fields) with
               | Ok _ as ok -> ok
               | Error _ -> Error (annotated_error ()))
          | None -> Error (annotated_error ()))
      | _ -> Error original_error)

(* ============================================ *)
(* Multi-Coord Types                             *)
(* ============================================ *)

(** Coord metadata - information about a coordination room *)
type room_info = {
  id: string;                                 (* unique ID: slugified name *)
  name: string;                               (* display name *)
  description: string option; [@default None] (* optional description *)
  created_at: string;                         (* ISO timestamp *)
  created_by: string option; [@default None]  (* agent who created the room *)
  agent_count: int; [@default 0]              (* current agent count *)
  task_count: int; [@default 0]               (* active task count *)
} [@@deriving yojson { strict = false }, show]

(** Coord registry - tracks all available rooms *)
type room_registry = {
  rooms: room_info list; [@default []]        (* list of rooms *)
  default_room: string; [@default "default"]  (* default room ID *)
  current_room: string option; [@default None] (* currently active room *)
} [@@deriving yojson { strict = false }, show]

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
[@@deriving show]

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
  | other -> Error (Printf.sprintf "Unknown task action: %s" other)

(** Issue #8312: callers (especially small LLM keepers) often pass target-state
    aliases such as "claimed" or status verbs from the lifecycle vocabulary.
    [task_action_of_alias] returns [Some action] when the input maps to a
    canonical action via a documented alias, and [None] when it does not.
    Compose with [task_action_of_string] for "permissive input, strict output":
    canonical strings still parse via [task_action_of_string]; only foreign
    inputs fall through to the alias map. *)
let task_action_of_alias s =
  match String.lowercase_ascii s with
  | "claimed" -> Some Claim
  | "started" | "in_progress" | "inprogress" | "running" -> Some Start
  | "completed" | "complete" | "finished" -> Some Done_action
  | "cancelled" | "canceled" | "abort" | "aborted" -> Some Cancel
  | "todo" | "released" | "unclaim" | "unclaimed" -> Some Release
  | "awaiting_verification" | "submit" -> Some Submit_for_verification
  | "approved" -> Some Approve_verification
  | "rejected" -> Some Reject_verification
  | _ -> None

(** Lenient parser: tries strict canonical first, then alias map.
    Strict callers (registry validation, schema docs) keep using
    [task_action_of_string]; user-facing tool dispatch uses this. *)
let task_action_of_string_lenient s =
  match task_action_of_string s with
  | Ok _ as ok -> ok
  | Error _ as err ->
    (match task_action_of_alias s with
     | Some action -> Ok action
     | None -> err)

let task_action_to_string = function
  | Claim -> "claim"
  | Start -> "start"
  | Done_action -> "done"
  | Cancel -> "cancel"
  | Release -> "release"
  | Submit_for_verification -> "submit_for_verification"
  | Approve_verification -> "approve"
  | Reject_verification -> "reject"

(** All valid task actions, derived from the ADT (single source of truth). *)
let all_task_actions =
  [ Claim; Start; Done_action; Cancel; Release;
    Submit_for_verification; Approve_verification; Reject_verification ]
let valid_task_action_strings = List.map task_action_to_string all_task_actions

type task_status =
  | Todo
  | Claimed of { assignee: string; claimed_at: string }
  | InProgress of { assignee: string; started_at: string }
  | AwaitingVerification of {
      assignee: string;
      submitted_at: string;
      verification_id: string;
      required_verifier_role: role;
      deadline: string option;
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

(** Issue #8354: schema enums for [task_status] used to be hand-rolled in
    [tool_shard.ml] and [mcp_server.ml], dropping [awaiting_verification].
    [task_status] carries record payloads so we cannot enumerate dummy
    values like [task_action]. Instead, this helper uses an exhaustive
    [match] driven by a witness function: adding a 7th constructor to
    [task_status] forces this match to be updated by the compiler, so
    schema enums cannot silently drift again.

    Order matches the FSM lifecycle (Todo -> Claimed -> InProgress ->
    AwaitingVerification -> Done | Cancelled) for readable schema docs. *)
let all_task_status_names : string list =
  let witness =
    function
    | Todo -> "todo"
    | Claimed _ -> "claimed"
    | InProgress _ -> "in_progress"
    | AwaitingVerification _ -> "awaiting_verification"
    | Done _ -> "done"
    | Cancelled _ -> "cancelled"
  in
  let _ = witness in
  [ "todo"; "claimed"; "in_progress"; "awaiting_verification"; "done"; "cancelled" ]

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
  | AwaitingVerification { assignee; submitted_at; verification_id;
                           required_verifier_role; deadline } ->
      `Assoc [
        ("status", `String "awaiting_verification");
        ("assignee", `String assignee);
        ("submitted_at", `String submitted_at);
        ("verification_id", `String verification_id);
        ("required_verifier_role", `String (role_to_string required_verifier_role));
        ("deadline", Json_util.string_opt_to_json deadline);
      ]
  | Cancelled { cancelled_by; cancelled_at; reason } ->
      `Assoc [
        ("status", `String "cancelled");
        ("cancelled_by", `String cancelled_by);
        ("cancelled_at", `String cancelled_at);
        ("reason", Json_util.string_opt_to_json reason);
      ]

let task_status_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let status = json |> member "status" |> to_string in
    match status with
    | "todo" -> Ok Todo
    | "claimed" ->
        let assignee = json |> member "assignee" |> to_string in
        let claimed_at = json |> member "claimed_at" |> to_string in
        Ok (Claimed { assignee; claimed_at })
    | "in_progress" ->
        let assignee = json |> member "assignee" |> to_string in
        let started_at = json |> member "started_at" |> to_string in
        Ok (InProgress { assignee; started_at })
    | "done" ->
        let assignee = json |> member "assignee" |> to_string in
        let completed_at = json |> member "completed_at" |> to_string in
        let notes = json |> member "notes" |> to_string_option in
        Ok (Done { assignee; completed_at; notes })
    | "awaiting_verification" ->
        let assignee = json |> member "assignee" |> to_string in
        let submitted_at = json |> member "submitted_at" |> to_string in
        let verification_id = json |> member "verification_id" |> to_string in
        let required_verifier_role =
          (* Issue #8615: was [role_of_string s] (lossy default to
             [Unassigned]). [role_satisfies ~required:Unassigned]
             returns true for ANY agent role — that silently bypasses
             the verification gate when the JSON value is a typo or
             a fabricated role string. Fail closed to [Reviewer] (the
             same default the [None] arm uses) so an unrecognised
             value at least demands the strictest sane interpretation. *)
          match json |> member "required_verifier_role" |> to_string_option with
          | Some s ->
              role_of_string_opt s |> Option.value ~default:Reviewer
          | None -> Reviewer in
        let deadline = json |> member "deadline" |> to_string_option in
        Ok (AwaitingVerification { assignee; submitted_at; verification_id;
                                   required_verifier_role; deadline })
    | "cancelled" ->
        let cancelled_by = json |> member "cancelled_by" |> to_string in
        let cancelled_at = json |> member "cancelled_at" |> to_string in
        let reason = json |> member "reason" |> to_string_option in
        Ok (Cancelled { cancelled_by; cancelled_at; reason })
    | s -> Error ("Unknown task status: " ^ s)
  with e -> Error (Printexc.to_string e)

(** Worktree info - tracks which worktree is used for a task *)
type worktree_info = {
  branch: string;                              (* git branch name *)
  path: string;                                (* worktree path relative to git root *)
  git_root: string;                            (* absolute path to .git parent *)
  repo_name: string;                           (* repository name (basename of git_root) *)
} [@@deriving show]

let worktree_info_to_yojson wt =
  `Assoc [
    ("branch", `String wt.branch);
    ("path", `String wt.path);
    ("git_root", `String wt.git_root);
    ("repo_name", `String wt.repo_name);
  ]

let worktree_info_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let branch = json |> member "branch" |> to_string in
    let path = json |> member "path" |> to_string in
    let git_root = json |> member "git_root" |> to_string in
    let repo_name = json |> member "repo_name" |> to_string in
    Ok { branch; path; git_root; repo_name }
  with e -> Error (Printexc.to_string e)

(** Task execution links - tie task state to runtime evidence producers *)
type task_execution_links = {
  operation_id : string option;
  session_id : string option;
  autoresearch_loop_id : string option;
} [@@deriving show]

let task_execution_links_to_yojson (links : task_execution_links) =
  `Assoc
    [
      ("operation_id", Json_util.string_opt_to_json links.operation_id);
      ("session_id", Json_util.string_opt_to_json links.session_id);
      ( "autoresearch_loop_id",
        Json_util.string_opt_to_json links.autoresearch_loop_id );
    ]

let task_execution_links_of_yojson json =
  let open Yojson.Safe.Util in
  try
    Ok
      {
        operation_id = json |> member "operation_id" |> to_string_option;
        session_id = json |> member "session_id" |> to_string_option;
        autoresearch_loop_id =
          json |> member "autoresearch_loop_id" |> to_string_option;
      }
  with e -> Error (Printexc.to_string e)

(** Task contract - persisted deterministic gate inputs *)
type task_contract = {
  strict : bool;
  completion_contract : string list;
  required_evidence : string list;
  inspect_gate_evidence : string list;
  verify_gate_evidence : string list;
  links : task_execution_links;
} [@@deriving show]

let task_contract_string_list json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `List items ->
      items
      |> List.filter_map (function
           | `String value ->
               let trimmed = String.trim value in
               if trimmed = "" then None else Some trimmed
           | _ -> None)
  | _ -> []

let string_list_to_yojson values =
  `List (List.map (fun value -> `String value) values)

let task_contract_to_yojson (contract : task_contract) =
  `Assoc
    [
      ("strict", `Bool contract.strict);
      ( "completion_contract",
        string_list_to_yojson contract.completion_contract );
      ("required_evidence", string_list_to_yojson contract.required_evidence);
      ( "inspect_gate_evidence",
        string_list_to_yojson contract.inspect_gate_evidence );
      ( "verify_gate_evidence",
        string_list_to_yojson contract.verify_gate_evidence );
      ("links", task_execution_links_to_yojson contract.links);
    ]

let task_contract_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let strict =
      json |> member "strict" |> to_bool_option |> Option.value ~default:false
    in
    let links =
      match json |> member "links" with
      | `Null ->
          {
            operation_id = None;
            session_id = None;
            autoresearch_loop_id = None;
          }
      | links_json -> (
          match task_execution_links_of_yojson links_json with
          | Ok links -> links
          | Error _ ->
              {
                operation_id = None;
                session_id = None;
                autoresearch_loop_id = None;
              })
    in
    Ok
      {
        strict;
        completion_contract = task_contract_string_list json "completion_contract";
        required_evidence = task_contract_string_list json "required_evidence";
        inspect_gate_evidence =
          task_contract_string_list json "inspect_gate_evidence";
        verify_gate_evidence =
          task_contract_string_list json "verify_gate_evidence";
        links;
      }
  with e -> Error (Printexc.to_string e)

(** Handoff context persisted across release/reclaim cycles *)
type task_handoff_context = {
  summary : string;
  reason : string option;
  next_step : string option;
  failure_mode : string option;
  evidence_refs : string list;
  updated_at : string option;
  updated_by : string option;
} [@@deriving show]

let task_handoff_context_to_yojson (context : task_handoff_context) =
  `Assoc
    [
      ("summary", `String context.summary);
      ("reason", Json_util.string_opt_to_json context.reason);
      ("next_step", Json_util.string_opt_to_json context.next_step);
      ("failure_mode", Json_util.string_opt_to_json context.failure_mode);
      ("evidence_refs", string_list_to_yojson context.evidence_refs);
      ("updated_at", Json_util.string_opt_to_json context.updated_at);
      ("updated_by", Json_util.string_opt_to_json context.updated_by);
    ]

let task_handoff_context_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let summary =
      json |> member "summary" |> to_string_option |> Option.value ~default:""
    in
    Ok
      {
        summary;
        reason = json |> member "reason" |> to_string_option;
        next_step = json |> member "next_step" |> to_string_option;
        failure_mode = json |> member "failure_mode" |> to_string_option;
        evidence_refs = task_contract_string_list json "evidence_refs";
        updated_at = json |> member "updated_at" |> to_string_option;
        updated_by = json |> member "updated_by" |> to_string_option;
      }
  with e -> Error (Printexc.to_string e)

(** Task definition *)
type task = {
  id: string;
  title: string;
  description: string;
  task_status: task_status; [@key "status"]
  priority: int; [@default 3]
  files: string list; [@default []]
  created_at: string;
  worktree: worktree_info option; [@default None]  (* linked worktree info *)
  required_role: role; [@default Unassigned]  (** Role required to claim this task *)
  required_preset: string option; [@default None]  (** Tool preset required to claim this task *)
  stage: Task_stage.t option; [@default None]  (** Coding task stage gate *)
  contract: task_contract option; [@default None]
  handoff_context: task_handoff_context option; [@default None]
  cycle_count: int; [@default 0]
  do_not_reclaim_reason: string option; [@default None]
} [@@deriving show]

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
  (* Add worktree field if present *)
  let with_worktree = match t.worktree with
    | None -> base
    | Some wt -> base @ [("worktree", worktree_info_to_yojson wt)]
  in
  (* Add required_role if not Unassigned *)
  let with_role = match t.required_role with
    | Unassigned -> with_worktree
    | role -> with_worktree @ [("required_role", role_to_yojson role)]
  in
  (* Add required_preset if present *)
  let with_preset = match t.required_preset with
    | None -> with_role
    | Some p -> with_role @ [("required_preset", `String p)]
  in
  (* Add stage if present *)
  let with_stage = match t.stage with
    | None -> with_preset
    | Some s -> with_preset @ [("stage", Task_stage.to_yojson s)]
  in
  let with_contract = match t.contract with
    | None -> with_stage
    | Some contract ->
        with_stage @ [ ("contract", task_contract_to_yojson contract) ]
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
  let with_do_not_reclaim = match t.do_not_reclaim_reason with
    | None -> with_cycle_count
    | Some r -> with_cycle_count @ [("do_not_reclaim_reason", `String r)]
  in
  let with_role = with_do_not_reclaim in
  (* Merge status fields into task *)
  match status_json with
  | `Assoc status_fields -> `Assoc (with_role @ status_fields)
  | _ -> `Assoc with_role

let task_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let id = json |> member "id" |> to_string in
    let title = json |> member "title" |> to_string in
    let description = json |> member "description" |> to_string_option |> Option.value ~default:"" in
    let priority = json |> member "priority" |> to_int_option |> Option.value ~default:3 in
    let files = json |> member "files" |> to_list |> List.map to_string in
    let created_at = json |> member "created_at" |> to_string in
    (* Parse optional worktree field *)
    let worktree = match json |> member "worktree" with
      | `Null -> None
      | wt_json ->
          match worktree_info_of_yojson wt_json with
          | Ok wt -> Some wt
          | Error _ -> None  (* Graceful fallback for backwards compat *)
    in
    (* Parse optional required_role field — defaults to Unassigned for backward compat *)
    let required_role = match json |> member "required_role" |> to_string_option with
      | Some s -> role_of_string s
      | None -> Unassigned
    in
    let required_preset = json |> member "required_preset" |> to_string_option in
    (* Parse optional stage field *)
    let stage = match json |> member "stage" |> to_string_option with
      | Some s -> (match Task_stage.of_string s with Ok st -> Some st | Error _ -> None)
      | None -> None
    in
    let contract = match json |> member "contract" with
      | `Null -> None
      | contract_json ->
          (match task_contract_of_yojson contract_json with
           | Ok contract -> Some contract
           | Error _ -> None)
    in
    let handoff_context = match json |> member "handoff_context" with
      | `Null -> None
      | handoff_json ->
          (match task_handoff_context_of_yojson handoff_json with
           | Ok handoff_context -> Some handoff_context
           | Error _ -> None)
    in
    let cycle_count =
      json |> member "cycle_count" |> to_int_option |> Option.value ~default:0
    in
    let do_not_reclaim_reason =
      json |> member "do_not_reclaim_reason" |> to_string_option
    in
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
            worktree;
            required_role;
            required_preset;
            stage;
            contract;
            handoff_context;
            cycle_count;
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
} [@@deriving yojson { strict = false }, show]

(** Coord state *)
type room_state = {
  protocol_version: string;
  project: string;
  started_at: string;
  message_seq: int;
  active_agents: string list;
  paused: bool; [@default false]  (** Global pause flag - when true, orchestrator won't spawn *)
  pause_reason: string option; [@default None]  (** Reason for pause *)
  paused_by: string option; [@default None]  (** Who paused the room *)
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
  | _ -> Error "Expected string for tempo_mode"

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
  let open Yojson.Safe.Util in
  try
    let mode_str = json |> member "mode" |> to_string in
    let delay_ms = json |> member "delay_ms" |> to_int_option |> Option.value ~default:0 in
    let reason = json |> member "reason" |> to_string_option in
    let set_by = json |> member "set_by" |> to_string_option in
    let set_at = json |> member "set_at" |> to_string_option in
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
  let open Yojson.Safe.Util in
  try
    let tasks_json = json |> member "tasks" |> to_list in
    let tasks = List.filter_map (fun j ->
      match task_of_yojson j with Ok t -> Some t | Error _ -> None
    ) tasks_json in
    (* [last_updated] and [version] are display metadata; writers may
       omit them (observed in live basepath [~/me/.masc/tasks/backlog.json]
       where the top-level is just [{"tasks": [...]}]).  Strict
       [to_string]/[to_int] decoders rejected such payloads as
       [Type_error("Expected string, got null")], forcing every reader
       onto the [read_backlog] empty fallback and wiping every claim
       from the reader's view (hundreds of [read_backlog backlog decode
       failed] entries/day driven [stale-claims] GC to skip mutation,
       so claims never transitioned).  Tolerate missing/null fields. *)
    let last_updated =
      json |> member "last_updated" |> to_string_option
      |> Option.value ~default:""
    in
    let version =
      json |> member "version" |> to_int_option
      |> Option.value ~default:1
    in
    Ok { tasks; last_updated; version }
  with e -> Error (Printexc.to_string e)

(** A2A Task status - enforced at compile time *)
type a2a_task_status =
  | A2APending
  | A2ARunning
  | A2ACompleted
  | A2AFailed
  | A2ACanceled
[@@deriving show { with_path = false }]

let a2a_task_status_to_string = function
  | A2APending -> "pending"
  | A2ARunning -> "running"
  | A2ACompleted -> "completed"
  | A2AFailed -> "failed"
  | A2ACanceled -> "canceled"

let a2a_task_status_of_string = function
  | "pending" -> Ok A2APending
  | "running" -> Ok A2ARunning
  | "completed" -> Ok A2ACompleted
  | "failed" -> Ok A2AFailed
  | "canceled" -> Ok A2ACanceled
  | s -> Error ("Unknown A2A task status: " ^ s)

let a2a_task_status_to_yojson s = `String (a2a_task_status_to_string s)

let a2a_task_status_of_yojson = function
  | `String s -> a2a_task_status_of_string s
  | _ -> Error "Expected string for A2A task status"

(** Portal status - enforced at compile time *)
type portal_state =
  | PortalOpen
  | PortalClosed
[@@deriving show { with_path = false }]

let portal_state_to_string = function
  | PortalOpen -> "open"
  | PortalClosed -> "closed"

let portal_state_of_string = function
  | "open" -> Ok PortalOpen
  | "closed" -> Ok PortalClosed
  | s -> Error ("Unknown portal state: " ^ s)

let portal_state_to_yojson s = `String (portal_state_to_string s)

let portal_state_of_yojson = function
  | `String s -> portal_state_of_string s
  | _ -> Error "Expected string for portal state"

(** A2A Task - Google A2A Protocol task object *)
type a2a_task = {
  a2a_id: string; [@key "id"]
  from_agent: string; [@key "from"]
  to_agent: string; [@key "to"]
  a2a_message: string; [@key "message"]
  a2a_status: a2a_task_status; [@key "status"]
  a2a_result: string option; [@key "result"] [@default None]
  created_at: string; [@key "createdAt"]
  updated_at: string; [@key "updatedAt"]
} [@@deriving show]

(* Manual JSON conversion for a2a_task *)
let a2a_task_to_yojson t =
  `Assoc [
    ("id", `String t.a2a_id);
    ("from", `String t.from_agent);
    ("to", `String t.to_agent);
    ("message", `String t.a2a_message);
    ("status", a2a_task_status_to_yojson t.a2a_status);
    ("result", Json_util.string_opt_to_json t.a2a_result);
    ("createdAt", `String t.created_at);
    ("updatedAt", `String t.updated_at);
  ]

let a2a_task_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let a2a_id = json |> member "id" |> to_string in
    let from_agent = json |> member "from" |> to_string in
    let to_agent = json |> member "to" |> to_string in
    let a2a_message = json |> member "message" |> to_string in
    let status_str = json |> member "status" |> to_string in
    let a2a_result = json |> member "result" |> to_string_option in
    let created_at = json |> member "createdAt" |> to_string in
    let updated_at = json |> member "updatedAt" |> to_string in
    match a2a_task_status_of_string status_str with
    | Ok a2a_status -> Ok { a2a_id; from_agent; to_agent; a2a_message; a2a_status; a2a_result; created_at; updated_at }
    | Error e -> Error e
  with e -> Error (Printexc.to_string e)

(** Portal - bidirectional A2A connection *)
type portal = {
  portal_from: string; [@key "from"]
  portal_target: string; [@key "target"]
  portal_opened_at: string; [@key "openedAt"]
  portal_status: portal_state; [@key "status"]
  task_count: int; [@key "taskCount"]
} [@@deriving show]

(* Manual JSON conversion for portal *)
let portal_to_yojson p =
  `Assoc [
    ("from", `String p.portal_from);
    ("target", `String p.portal_target);
    ("openedAt", `String p.portal_opened_at);
    ("status", portal_state_to_yojson p.portal_status);
    ("taskCount", `Int p.task_count);
  ]

let portal_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let portal_from = json |> member "from" |> to_string in
    let portal_target = json |> member "target" |> to_string in
    let portal_opened_at = json |> member "openedAt" |> to_string in
    let status_str = json |> member "status" |> to_string in
    let task_count = json |> member "taskCount" |> to_int in
    match portal_state_of_string status_str with
    | Ok portal_status -> Ok { portal_from; portal_target; portal_opened_at; portal_status; task_count }
    | Error e -> Error e
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
    Defined here so that both Coord_task_schedule (producer) and consumers
    (tool_task, orchestrator) can reference the type without
    triggering warning 34 from [include] re-export. *)
type claim_next_result =
  | Claim_next_claimed of {
      task_id : string;
      title : string;
      priority : int;
      released_task_id : string option;  (** Previous task auto-released, if any *)
      message : string;
    }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of { excluded_count : int; preset_filtered : int }
  | Claim_next_error of string
