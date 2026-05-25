(** Keeper_approval_queue — Eio.Promise-based HITL approval for keeper tools.

    When a keeper's OAS Agent invokes a tool that requires approval,
    the agent fiber is suspended via [Eio.Promise.await].  An operator
    can then approve/reject via the dashboard approval HTTP handler
    ([server_dashboard_http.ml]), which resolves the promise and
    resumes the agent.

    This replaces the manual "pending_approval" state machine with
    actual execution-level suspension using Eio structured concurrency.

    Spec navigation (OCaml -> TLA+) — plan §19 Cycle 29 anchor for
    B3 (Approval Queue).  Authoritative spec mirror is
    [specs/keeper-state-machine/KeeperApprovalQueue.tla] (Cycle 9 /
    Tier B3, PR #11417).

    The spec preamble cites this module by function name
    ([submit_and_await], [submit_pending], [expire_stale]).  It used to
    carry line numbers (751 / 772 / 941) but iter 64 N-2.a removed them
    after the OCaml line drift reached +245..+413 — function names are
    stable, line numbers are not.  This block is the reverse-direction
    citation so code search for "KeeperApprovalQueue" lands here.

    Action mapping (TLA+ -> OCaml):
      Submit                 [submit_and_await] / [submit_pending]
                             record a new pending entry and suspend
                             the fiber on [Eio.Promise.await].
      Resolve                operator approves/rejects via the HTTP
                             handler in [server_dashboard_http.ml],
                             which calls [resolve] on the queue and
                             wakes the suspended fiber.
      ExpireStale            [expire_stale] sweeps timed-out entries
                             and forces
                             [Eio.Promise.resolve resolver (Reject ...)]
                             so no fiber is left blocked indefinitely.
      ExpireStaleNoResolve   bug action — entries are removed from
                             [pending] without resolving the promise.
                             Spec invariants SuspensionMatchesPending
                             and QuiescentImpliesResolved catch this;
                             in code, the structural invariant is
                             that every removal from [pending] is
                             paired with an [Eio.Promise.resolve]
                             on the same control-flow path.

    @since 2.262.0 (#5907) *)

(* ── Types ────────────────────────────────────────────────── *)

type risk_level =
  | Low
  | Medium
  | High
  | Critical

type pending_approval =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; action_key : string
  ; input_hash : string
  ; sandbox_target : string
  ; input : Yojson.Safe.t
  ; risk_level : risk_level
  ; requested_at : float
  ; turn_id : int option
  ; task_id : string option
  ; goal_id : string option
  ; goal_ids : string list
  ; runtime_contract : Yojson.Safe.t option
  ; selected_model : string option
  ; disposition : string option
  ; disposition_reason : string option
  ; audit_base_path : string option
  ; resolver : Agent_sdk.Hooks.approval_decision Eio.Promise.u option
  ; on_resolution : (Agent_sdk.Hooks.approval_decision -> unit) option
  }

type decision = Agent_sdk.Hooks.approval_decision

type approval_audit_decision =
  | Approval_resolved of decision
  | Approval_expired of string

type approval_rule =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; sandbox_profile : string option
  ; backend : string option
  ; request_fingerprint : string
  ; request_fingerprint_preview : string
  ; max_risk : risk_level
  ; created_at : float
  ; created_by : string option
  ; last_matched_at : float option
  ; match_count : int
  ; source_approval_id : string option
  }

type rule_match =
  { rule_id : string
  ; matched_by : string
  }

type resolution_result = { remembered_rule : approval_rule option }

let risk_level_to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Critical -> "critical"
;;

let risk_level_to_int = function
  | Low -> 1
  | Medium -> 2
  | High -> 3
  | Critical -> 4
;;

let risk_level_of_string = function
  | "low" -> Some Low
  | "medium" -> Some Medium
  | "high" -> Some High
  | "critical" -> Some Critical
  | _ -> None
;;

let approval_decision_to_string = function
  | Agent_sdk.Hooks.Approve -> "approve"
  | Agent_sdk.Hooks.Reject reason -> "reject:" ^ reason
  | Agent_sdk.Hooks.Edit _ -> "edit"
;;

let record_queue_failure ~keeper_name ~site ?(id = "-") ?(event_type = "-") exn =
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_approval_queue_failures
    ~labels:[ "keeper", keeper_name; "site", site ]
    ();
  Log.Keeper.warn
    "approval_queue: %s failed keeper=%s id=%s event=%s err=%s"
    site
    keeper_name
    id
    event_type
    (Printexc.to_string exn)
;;

let approval_audit_decision_to_string = function
  | Approval_resolved decision -> approval_decision_to_string decision
  | Approval_expired reason -> "reject:" ^ reason
;;

let string_opt_of_json = function
  | `String value ->
    let trimmed = String.trim value in
    if trimmed = "" then None else Some trimmed
  | _ -> None
;;

(* RFC-0145 — narrow the wildcard catch-all to the only exception
   [Yojson.Safe.Util.member] can raise on non-object inputs.  An
   unrelated runtime exception (e.g. [Out_of_memory], async failure,
   unexpected internal contract break) will now propagate to the
   caller instead of being silently coerced to [None]. *)
let string_opt_member key json =
  match Yojson.Safe.Util.member key json with
  | exception Yojson.Safe.Util.Type_error _ -> None
  | value -> string_opt_of_json value
;;

let bool_member key json ~default =
  match Yojson.Safe.Util.member key json with
  | `Bool value -> value
  | _ -> default
;;

let rule_match_to_yojson (matched : rule_match) =
  `Assoc [ "rule_id", `String matched.rule_id; "matched_by", `String matched.matched_by ]
;;

let approval_rule_to_yojson (rule : approval_rule) =
  `Assoc
    [ "id", `String rule.id
    ; "keeper_name", `String rule.keeper_name
    ; "tool_name", `String rule.tool_name
    ; "sandbox_profile", Json_util.string_opt_to_json rule.sandbox_profile
    ; "backend", Json_util.string_opt_to_json rule.backend
    ; "request_fingerprint", `String rule.request_fingerprint
    ; "request_fingerprint_preview", `String rule.request_fingerprint_preview
    ; "max_risk", `String (risk_level_to_string rule.max_risk)
    ; "created_at", `Float rule.created_at
    ; "created_at_iso", `String (Masc_domain.iso8601_of_unix_seconds rule.created_at)
    ; "created_by", Json_util.string_opt_to_json rule.created_by
    ; "last_matched_at", Json_util.float_opt_to_json rule.last_matched_at
    ; ( "last_matched_at_iso"
      , match rule.last_matched_at with
        | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
        | None -> `Null )
    ; "match_count", `Int rule.match_count
    ; "source_approval_id", Json_util.string_opt_to_json rule.source_approval_id
    ]
;;

let approval_rule_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let id = json |> member "id" |> to_string in
    let keeper_name = json |> member "keeper_name" |> to_string in
    let tool_name = json |> member "tool_name" |> to_string in
    let sandbox_profile = json |> member "sandbox_profile" |> to_string_option in
    let backend = json |> member "backend" |> to_string_option in
    let request_fingerprint = json |> member "request_fingerprint" |> to_string in
    let request_fingerprint_preview =
      json
      |> member "request_fingerprint_preview"
      |> to_string_option
      |> Option.value
           ~default:
             (String.sub
                request_fingerprint
                0
                (min 12 (String.length request_fingerprint)))
    in
    let max_risk =
      json
      |> member "max_risk"
      |> to_string
      |> risk_level_of_string
      |> Option.value ~default:High
    in
    let created_at =
      json
      |> member "created_at"
      |> to_float_option
      |> Option.value ~default:(Unix.gettimeofday ())
    in
    let created_by = json |> member "created_by" |> to_string_option in
    let last_matched_at = json |> member "last_matched_at" |> to_float_option in
    let match_count =
      json |> member "match_count" |> to_int_option |> Option.value ~default:0
    in
    let source_approval_id = json |> member "source_approval_id" |> to_string_option in
    Some
      { id
      ; keeper_name
      ; tool_name
      ; sandbox_profile
      ; backend
      ; request_fingerprint
      ; request_fingerprint_preview
      ; max_risk
      ; created_at
      ; created_by
      ; last_matched_at
      ; match_count
      ; source_approval_id
      }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> None
;;

(* ── Global queue (Lock-free Atomic.t) ───────────────────── *)

module SMap = Set_util.StringMap

let rec atomic_update atomic f =
  let old_val = Atomic.get atomic in
  let new_val = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then () else atomic_update atomic f
;;

let pending : pending_approval SMap.t Atomic.t = Atomic.make SMap.empty

let make_generated_id prefix =
  let entropy =
    Printf.sprintf
      "%s|%d|%.6f|%d"
      prefix
      (Unix.getpid ())
      (Unix.gettimeofday ())
      (Random.bits ())
  in
  let digest = Digestif.SHA256.(digest_string entropy |> to_hex) in
  prefix ^ "_" ^ String.sub digest 0 12
;;

(* Stdlib.Mutex: rule reads/writes are short filesystem critical sections and
   are also reached by synchronous dashboard/test paths. Eio.Mutex requires an
   Eio fiber context and raises Cancel.Get_context outside one. *)
let rules_mu = Stdlib.Mutex.create ()

let mutex_protect_allow_reentrant mutex f =
  try Stdlib.Mutex.protect mutex f with
  | Sys_error msg when String.equal msg "Mutex.lock: Resource deadlock avoided" -> f ()
;;

let with_rules_lock f = mutex_protect_allow_reentrant rules_mu f

let rules_path ?base_path () =
  let base_path =
    match base_path with
    | Some base_path -> base_path
    | None -> Env_config_core.base_path ()
  in
  Filename.concat (Coord_utils.masc_dir_from_base_path ~base_path) "approval-rules.json"
;;

let stable_request_key_blocklist =
  [ "id"
  ; "turn_id"
  ; "timestamp"
  ; "requested_at"
  ; "requested_at_iso"
  ; "ts"
  ; "created_at"
  ; "updated_at"
  ; "trace_id"
  ; "session_id"
  ; "keeper_turn_id"
  ; "approval_id"
  ; "rule_id"
  ; "nonce"
  ]
;;

let rec normalize_request_json = function
  | `Assoc fields ->
    fields
    |> List.filter (fun (key, _) -> not (List.mem key stable_request_key_blocklist))
    |> List.map (fun (key, value) -> key, normalize_request_json value)
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
    |> fun normalized -> `Assoc normalized
  | `List items -> `List (List.map normalize_request_json items)
  | other -> other
;;

let request_fingerprint (input : Yojson.Safe.t) =
  let stable_json = normalize_request_json input |> Yojson.Safe.to_string in
  Digestif.SHA256.(digest_string stable_json |> to_hex)
;;

let request_fingerprint_preview fingerprint =
  String.sub fingerprint 0 (min 12 (String.length fingerprint))
;;

let sandbox_profile_of_runtime_contract runtime_contract =
  Option.bind runtime_contract (string_opt_member "sandbox_profile")
;;

let backend_of_runtime_contract runtime_contract =
  Option.bind runtime_contract (string_opt_member "backend")
;;

let load_rules_unlocked ?base_path () =
  match Safe_ops.read_json_file_safe (rules_path ?base_path ()) with
  | Ok (`List entries) -> entries |> List.filter_map approval_rule_of_yojson
  | _ -> []
;;

let save_rules_unlocked ?base_path rules : (unit, string) result =
  let path = rules_path ?base_path () in
  Fs_compat.mkdir_p (Filename.dirname path);
  let json = `List (List.map approval_rule_to_yojson rules) in
  Fs_compat.save_file_atomic path (Yojson.Safe.pretty_to_string json)
;;

let list_rules ?base_path () =
  with_rules_lock (fun () -> load_rules_unlocked ?base_path ())
;;

let list_rules_dashboard_json ?base_path () =
  let rules =
    list_rules ?base_path ()
    |> List.sort (fun left right -> Float.compare right.created_at left.created_at)
  in
  `List (List.map approval_rule_to_yojson rules)
;;

let policy_summary_json ~base_path ~keeper_name : Yojson.Safe.t =
  let persisted_rules =
    list_rules ~base_path ()
    |> List.fold_left
         (fun count (rule : approval_rule) ->
            if String.equal rule.keeper_name keeper_name then count + 1 else count)
         0
  in
  `Assoc
    [ "allow_rules", `Int persisted_rules
    ; "deny_rules", `Int 0
    ; "persisted_rules", `Int persisted_rules
    ]
;;

let rule_identity_matches left right =
  String.equal left.keeper_name right.keeper_name
  && String.equal left.tool_name right.tool_name
  && left.sandbox_profile = right.sandbox_profile
  && left.backend = right.backend
  && String.equal left.request_fingerprint right.request_fingerprint
  && left.max_risk = right.max_risk
;;

let upsert_rule
      ?base_path
      ~keeper_name
      ~tool_name
      ~input
      ~risk_level
      ?runtime_contract
      ?created_by
      ?source_approval_id
      ()
  =
  with_rules_lock (fun () ->
    let rules = load_rules_unlocked ?base_path () in
    let request_fingerprint = request_fingerprint input in
    let candidate =
      { id = make_generated_id "rule"
      ; keeper_name
      ; tool_name
      ; sandbox_profile = sandbox_profile_of_runtime_contract runtime_contract
      ; backend = backend_of_runtime_contract runtime_contract
      ; request_fingerprint
      ; request_fingerprint_preview = request_fingerprint_preview request_fingerprint
      ; max_risk = risk_level
      ; created_at = Unix.gettimeofday ()
      ; created_by
      ; last_matched_at = None
      ; match_count = 0
      ; source_approval_id
      }
    in
    match List.find_opt (fun rule -> rule_identity_matches rule candidate) rules with
    | Some existing -> existing, false
    | None ->
      (match save_rules_unlocked ?base_path (candidate :: rules) with
       | Ok () -> ()
       | Error msg ->
         Prometheus.inc_counter
           Keeper_metrics.metric_keeper_approval_queue_failures
           ~labels:[ "keeper", keeper_name; "site", Keeper_approval_queue_failure_site.(to_label Upsert_rule_save) ]
           ();
         Log.Keeper.warn "upsert_rule: save failed: %s" msg);
      candidate, true)
;;

let delete_rule ?base_path ~id () =
  with_rules_lock (fun () ->
    let rules = load_rules_unlocked ?base_path () in
    match List.find_opt (fun rule -> String.equal rule.id id) rules with
    | None -> Error (Printf.sprintf "approval rule %s not found" id)
    | Some deleted ->
      let remaining = List.filter (fun rule -> not (String.equal rule.id id)) rules in
      (match save_rules_unlocked ?base_path remaining with
       | Ok () -> Ok deleted
       | Error msg -> Error msg))
;;

let find_matching_rule
      ?base_path
      ~keeper_name
      ~tool_name
      ~input
      ~risk_level
      ?runtime_contract
      ()
  =
  with_rules_lock (fun () ->
    let rules = load_rules_unlocked ?base_path () in
    let request_fingerprint = request_fingerprint input in
    let sandbox_profile = sandbox_profile_of_runtime_contract runtime_contract in
    let backend = backend_of_runtime_contract runtime_contract in
    match
      List.find_opt
        (fun rule ->
           String.equal rule.keeper_name keeper_name
           && String.equal rule.tool_name tool_name
           && rule.sandbox_profile = sandbox_profile
           && rule.backend = backend
           && String.equal rule.request_fingerprint request_fingerprint
           && risk_level_to_int risk_level <= risk_level_to_int rule.max_risk)
        rules
    with
    | None -> None
    | Some rule ->
      let now = Unix.gettimeofday () in
      let updated_rules =
        List.map
          (fun current ->
             if String.equal current.id rule.id
             then
               { current with
                 last_matched_at = Some now
               ; match_count = current.match_count + 1
               }
             else current)
          rules
      in
      (match save_rules_unlocked ?base_path updated_rules with
       | Ok () -> ()
       | Error msg ->
         Prometheus.inc_counter
           Keeper_metrics.metric_keeper_approval_queue_failures
           ~labels:[ "keeper", keeper_name; "site", Keeper_approval_queue_failure_site.(to_label Matching_rule_save) ]
           ();
         Log.Keeper.warn "find_matching_rule: save failed: %s" msg);
      Some { rule_id = rule.id; matched_by = "always_rule" })
;;
