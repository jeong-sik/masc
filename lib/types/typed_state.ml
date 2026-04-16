(** Typed_state — Phantom type + GADT PoC for compile-time state safety.

    Three patterns demonstrated:
    1. Phantom-typed task status: [active] vs [terminal] at type level
    2. GADT action state: [preview] vs [confirmed] enforced by constructor
    3. Rich validation errors: field path + expected/actual + protocol hint

    @since PoC-3 (#3526) *)

(* ──────────────────────────────────────────────────────────
   1. Phantom-typed task status
   ────────────────────────────────────────────────────────── *)

type active
type terminal

(** Internal representation — the phantom parameter is erased at runtime.
    The .mli hides the constructors, so callers cannot forge a
    [terminal task_status_t] that is actually active. *)
type _ task_status_t =
  | PTodo : active task_status_t
  | PClaimed : { assignee: string; claimed_at: string } -> active task_status_t
  | PInProgress : { assignee: string; started_at: string } -> active task_status_t
  | PDone : { assignee: string; completed_at: string; notes: string option } -> terminal task_status_t
  | PCancelled : { cancelled_by: string; cancelled_at: string; reason: string option } -> terminal task_status_t

let todo () = PTodo

let claim (type p) (status : p task_status_t) ~agent : active task_status_t =
  ignore status;
  let claimed_at = Types_core.now_iso () in
  PClaimed { assignee = agent; claimed_at }

let start (type p) (status : p task_status_t) : active task_status_t =
  match status with
  | PClaimed { assignee; _ } ->
    let started_at = Types_core.now_iso () in
    PInProgress { assignee; started_at }
  | _ ->
    let started_at = Types_core.now_iso () in
    PInProgress { assignee = "unknown"; started_at }

let complete (type p) (status : p task_status_t) ~notes : terminal task_status_t =
  let assignee = match status with
    | PClaimed { assignee; _ } -> assignee
    | PInProgress { assignee; _ } -> assignee
    | _ -> "unknown"
  in
  let completed_at = Types_core.now_iso () in
  PDone { assignee; completed_at; notes }

let cancel (type p) (status : p task_status_t) ~by ~reason : terminal task_status_t =
  ignore status;
  let cancelled_at = Types_core.now_iso () in
  PCancelled { cancelled_by = by; cancelled_at; reason }

(* Wire conversion *)

let to_wire : type p. p task_status_t -> Types_core.task_status = function
  | PTodo -> Types_core.Todo
  | PClaimed { assignee; claimed_at } ->
    Types_core.Claimed { assignee; claimed_at }
  | PInProgress { assignee; started_at } ->
    Types_core.InProgress { assignee; started_at }
  | PDone { assignee; completed_at; notes } ->
    Types_core.Done { assignee; completed_at; notes }
  | PCancelled { cancelled_by; cancelled_at; reason } ->
    Types_core.Cancelled { cancelled_by; cancelled_at; reason }

type any_task_status =
  | Active of active task_status_t
  | Terminal of terminal task_status_t

let of_wire : Types_core.task_status -> any_task_status = function
  | Types_core.Todo -> Active PTodo
  | Types_core.Claimed { assignee; claimed_at } ->
    Active (PClaimed { assignee; claimed_at })
  | Types_core.InProgress { assignee; started_at } ->
    Active (PInProgress { assignee; started_at })
  | Types_core.Done { assignee; completed_at; notes } ->
    Terminal (PDone { assignee; completed_at; notes })
  | Types_core.Cancelled { cancelled_by; cancelled_at; reason } ->
    Terminal (PCancelled { cancelled_by; cancelled_at; reason })
  | Types_core.AwaitingVerification { assignee; submitted_at; _ } ->
    (* No PAwaitingVerification variant yet; map to Active PInProgress as
       fallback — the assignee is still working until a verifier acts. *)
    Active (PInProgress { assignee; started_at = submitted_at })

let status_name : type p. p task_status_t -> string = function
  | PTodo -> "todo"
  | PClaimed _ -> "claimed"
  | PInProgress _ -> "in_progress"
  | PDone _ -> "done"
  | PCancelled _ -> "cancelled"

let is_terminal = function
  | Active _ -> false
  | Terminal _ -> true

(* ──────────────────────────────────────────────────────────
   2. GADT action state
   ────────────────────────────────────────────────────────── *)

type preview
type confirmed

type _ action_state =
  | Preview : {
      action_type: string;
      target_type: string;
      target_id: string;
      payload: Yojson.Safe.t;
    } -> preview action_state
  | Confirmed : {
      token: string;
      action_type: string;
      target_type: string;
      target_id: string;
      payload: Yojson.Safe.t;
    } -> confirmed action_state

let make_preview ~action_type ~target_type ~target_id ~payload =
  Preview { action_type; target_type; target_id; payload }

let confirm (Preview { action_type; target_type; target_id; payload }) ~token =
  Confirmed { token; action_type; target_type; target_id; payload }

let action_type_of : type p. p action_state -> string = function
  | Preview { action_type; _ } -> action_type
  | Confirmed { action_type; _ } -> action_type

let token_of (Confirmed { token; _ }) = token

(* ──────────────────────────────────────────────────────────
   3. Rich validation errors
   ────────────────────────────────────────────────────────── *)

type validation_error = {
  field_path: string list;
  expected: string;
  actual: string;
  protocol_version: string option;
  hint: string option;
}

let field_error ~path ~expected ~actual ?protocol_version ?hint () =
  { field_path = path; expected; actual; protocol_version; hint }

let validation_error_to_json (e : validation_error) : Yojson.Safe.t =
  `Assoc ([
    ("field_path", `List (List.map (fun s -> `String s) e.field_path));
    ("expected", `String e.expected);
    ("actual", `String e.actual);
  ] @ (match e.protocol_version with
       | Some v -> [("protocol_version", `String v)]
       | None -> [])
    @ (match e.hint with
       | Some h -> [("hint", `String h)]
       | None -> []))

let validation_error_to_string (e : validation_error) : string =
  let path = String.concat "." e.field_path in
  let base = Printf.sprintf "%s: expected %s, got %s" path e.expected e.actual in
  let proto = match e.protocol_version with
    | Some v -> Printf.sprintf " (protocol %s)" v
    | None -> ""
  in
  let hint_s = match e.hint with
    | Some h -> Printf.sprintf " [hint: %s]" h
    | None -> ""
  in
  base ^ proto ^ hint_s
