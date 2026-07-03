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

(** Types, conversions, and JSON serialization extracted to
    [Keeper_approval_queue_rules_types].  State management below. *)

include Keeper_approval_queue_rules_types

let default_noncritical_approval_timeout_s = 600.0
let default_critical_approval_escalation_after_s = 1800.0

let record_queue_failure ~keeper_name ~site ?(id = "-") ?(event_type = "-") exn =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
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

let rules_path ~base_path () =
  Filename.concat (Workspace_utils.masc_dir_from_base_path ~base_path) "approval-rules.json"
;;

let approval_rules_persistence_surface = "keeper_approval_rules"

let report_rules_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_persistence_read_drops
        ~labels:[ "surface", approval_rules_persistence_surface; "reason", reason ]
        ())
    ~surface:approval_rules_persistence_surface
    ~reason
    ~path
    ~detail
;;

let rule_json_preview json =
  Yojson.Safe.to_string json |> String_util.utf8_prefix ~max_bytes:240
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
  String.sub
    fingerprint
    0
    (min fingerprint_preview_length (String.length fingerprint))
;;

let sandbox_profile_of_runtime_contract runtime_contract =
  Option.bind runtime_contract (fun json ->
    Json_util.get_string_nonempty json "sandbox_profile")
;;

let backend_of_runtime_contract runtime_contract =
  Option.bind runtime_contract (fun json ->
    Json_util.get_string_nonempty json "backend")
;;

let nonempty_string_opt = function
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None
;;

let sandbox_profile_of_runtime_context ?sandbox_profile runtime_contract =
  match nonempty_string_opt sandbox_profile with
  | Some _ as value -> value
  | None -> sandbox_profile_of_runtime_contract runtime_contract
;;

let backend_of_runtime_context ?backend runtime_contract =
  match nonempty_string_opt backend with
  | Some _ as value -> value
  | None -> backend_of_runtime_contract runtime_contract
;;

let load_rules_unlocked ~base_path () =
  let path = rules_path ~base_path () in
  let rec parse_entries index acc = function
    | [] -> List.rev acc
    | entry :: rest ->
      (match approval_rule_of_yojson_with_error entry with
       | Ok rule -> parse_entries (index + 1) (rule :: acc) rest
       | Error reason ->
         report_rules_read_drop
           ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
           ~path
           ~detail:
             (Printf.sprintf
                "approval rule entry %d rejected (%s): %s"
                index
                reason
                (rule_json_preview entry));
         parse_entries (index + 1) acc rest)
  in
  if not (Sys.file_exists path)
  then []
  else (
    match Safe_ops.read_json_file_safe path with
    | Ok (`List entries) -> parse_entries 0 [] entries
    | Ok json ->
      report_rules_read_drop
        ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
        ~path
        ~detail:
          (Printf.sprintf
             "approval rules file must be a JSON list, got: %s"
             (rule_json_preview json));
      []
    | Error detail ->
      report_rules_read_drop
        ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
        ~path
        ~detail;
      [])
;;

let save_rules_unlocked ~base_path rules : (unit, string) result =
  let path = rules_path ~base_path () in
  Fs_compat.mkdir_p (Filename.dirname path);
  let json = `List (List.map approval_rule_to_yojson rules) in
  Fs_compat.save_file_atomic path (Yojson.Safe.pretty_to_string json)
;;

let list_rules ~base_path () =
  with_rules_lock (fun () -> load_rules_unlocked ~base_path ())
;;

let list_rules_dashboard_json ~base_path () =
  let rules =
    list_rules ~base_path ()
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
      ~base_path
      ~keeper_name
      ~tool_name
      ~input
      ~risk_level
      ?sandbox_profile
      ?backend
      ?runtime_contract
      ?created_by
      ?source_approval_id
      ()
  =
  with_rules_lock (fun () ->
    let rules = load_rules_unlocked ~base_path () in
    let request_fingerprint = request_fingerprint input in
    let candidate =
      { id = make_generated_id "rule"
      ; keeper_name
      ; tool_name
      ; sandbox_profile = sandbox_profile_of_runtime_context ?sandbox_profile runtime_contract
      ; backend = backend_of_runtime_context ?backend runtime_contract
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
      (match save_rules_unlocked ~base_path (candidate :: rules) with
       | Ok () -> ()
       | Error msg ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string ApprovalQueueFailures)
           ~labels:[ "keeper", keeper_name; "site", Keeper_approval_queue_failure_site.(to_label Upsert_rule_save) ]
           ();
         Log.Keeper.warn "upsert_rule: save failed: %s" msg);
      candidate, true)
;;

let delete_rule ~base_path ~id () =
  with_rules_lock (fun () ->
    let rules = load_rules_unlocked ~base_path () in
    match List.find_opt (fun rule -> String.equal rule.id id) rules with
    | None -> Error (Printf.sprintf "approval rule %s not found" id)
    | Some deleted ->
      let remaining = List.filter (fun rule -> not (String.equal rule.id id)) rules in
      (match save_rules_unlocked ~base_path remaining with
       | Ok () -> Ok deleted
       | Error msg -> Error msg))
;;

let find_matching_rule
      ~base_path
      ~keeper_name
      ~tool_name
      ~input
      ~risk_level
      ?sandbox_profile
      ?backend
      ?runtime_contract
      ()
  =
  with_rules_lock (fun () ->
    let rules = load_rules_unlocked ~base_path () in
    let request_fingerprint = request_fingerprint input in
    let sandbox_profile = sandbox_profile_of_runtime_context ?sandbox_profile runtime_contract in
    let backend = backend_of_runtime_context ?backend runtime_contract in
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
      (match save_rules_unlocked ~base_path updated_rules with
       | Ok () -> ()
       | Error msg ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string ApprovalQueueFailures)
           ~labels:[ "keeper", keeper_name; "site", Keeper_approval_queue_failure_site.(to_label Matching_rule_save) ]
           ();
         Log.Keeper.warn "find_matching_rule: save failed: %s" msg);
      Some { rule_id = rule.id; matched_by = "always_rule" })
;;
