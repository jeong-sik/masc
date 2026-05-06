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

    Spec lines 5-6 already cite this module:
    "[submit_and_await] at line 751, [submit_pending] at line 772,
    [expire_stale] at line 941".  This block is the reverse-direction
    citation so code search for "KeeperApprovalQueue" lands here.

    Action mapping (TLA+ -> OCaml):
      Submit                 [submit_and_await] (~line 751) /
                             [submit_pending] (~line 772) record a
                             new pending entry and suspend the fiber
                             on [Eio.Promise.await].
      Resolve                operator approves/rejects via the HTTP
                             handler in [server_dashboard_http.ml],
                             which calls [resolve] on the queue and
                             wakes the suspended fiber.
      ExpireStale            [expire_stale] (~line 941) sweeps
                             timed-out entries and forces
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

type pending_approval = {
  id : string;
  keeper_name : string;
  tool_name : string;
  action_key : string;
  input_hash : string;
  sandbox_target : string;
  input : Yojson.Safe.t;
  risk_level : risk_level;
  requested_at : float;
  turn_id : int option;
  task_id : string option;
  goal_id : string option;
  goal_ids : string list;
  runtime_contract : Yojson.Safe.t option;
  selected_model : string option;
  disposition : string option;
  disposition_reason : string option;
  audit_base_path : string option;
  resolver : Agent_sdk.Hooks.approval_decision Eio.Promise.u option;
  on_resolution : (Agent_sdk.Hooks.approval_decision -> unit) option;
}

type decision = Agent_sdk.Hooks.approval_decision

type approval_audit_decision =
  | Approval_resolved of decision
  | Approval_expired of string

type approval_rule = {
  id : string;
  keeper_name : string;
  tool_name : string;
  sandbox_profile : string option;
  backend : string option;
  request_fingerprint : string;
  request_fingerprint_preview : string;
  max_risk : risk_level;
  created_at : float;
  created_by : string option;
  last_matched_at : float option;
  match_count : int;
  source_approval_id : string option;
}

type rule_match = {
  rule_id : string;
  matched_by : string;
}

type resolution_result = {
  remembered_rule : approval_rule option;
}

let risk_level_to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Critical -> "critical"

let risk_level_to_int = function
  | Low -> 1
  | Medium -> 2
  | High -> 3
  | Critical -> 4

let risk_level_of_string = function
  | "low" -> Some Low
  | "medium" -> Some Medium
  | "high" -> Some High
  | "critical" -> Some Critical
  | _ -> None

let approval_decision_to_string = function
  | Agent_sdk.Hooks.Approve -> "approve"
  | Agent_sdk.Hooks.Reject reason -> "reject:" ^ reason
  | Agent_sdk.Hooks.Edit _ -> "edit"

let approval_audit_decision_to_string = function
  | Approval_resolved decision -> approval_decision_to_string decision
  | Approval_expired reason -> "reject:" ^ reason

let string_opt_of_json = function
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let string_opt_member key json =
  match Yojson.Safe.Util.member key json with
  | exception _ -> None
  | value -> string_opt_of_json value

let bool_member key json ~default =
  match Yojson.Safe.Util.member key json with
  | `Bool value -> value
  | _ -> default

let rule_match_to_yojson (matched : rule_match) =
  `Assoc
    [
      ("rule_id", `String matched.rule_id);
      ("matched_by", `String matched.matched_by);
    ]

let approval_rule_to_yojson (rule : approval_rule) =
  `Assoc
    [
      ("id", `String rule.id);
      ("keeper_name", `String rule.keeper_name);
      ("tool_name", `String rule.tool_name);
      ("sandbox_profile", Json_util.string_opt_to_json rule.sandbox_profile);
      ("backend", Json_util.string_opt_to_json rule.backend);
      ("request_fingerprint", `String rule.request_fingerprint);
      ("request_fingerprint_preview", `String rule.request_fingerprint_preview);
      ("max_risk", `String (risk_level_to_string rule.max_risk));
      ("created_at", `Float rule.created_at);
      ("created_at_iso", `String (Masc_domain.iso8601_of_unix_seconds rule.created_at));
      ("created_by", Json_util.string_opt_to_json rule.created_by);
      ("last_matched_at", Json_util.float_opt_to_json rule.last_matched_at);
      ( "last_matched_at_iso",
        match rule.last_matched_at with
        | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
        | None -> `Null );
      ("match_count", `Int rule.match_count);
      ("source_approval_id", Json_util.string_opt_to_json rule.source_approval_id);
    ]

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
      json |> member "request_fingerprint_preview" |> to_string_option
      |> Option.value ~default:
           (String.sub request_fingerprint 0 (min 12 (String.length request_fingerprint)))
    in
    let max_risk =
      json |> member "max_risk" |> to_string |> risk_level_of_string
      |> Option.value ~default:High
    in
    let created_at =
      json |> member "created_at" |> to_float_option
      |> Option.value ~default:(Unix.gettimeofday ())
    in
    let created_by = json |> member "created_by" |> to_string_option in
    let last_matched_at = json |> member "last_matched_at" |> to_float_option in
    let match_count =
      json |> member "match_count" |> to_int_option |> Option.value ~default:0
    in
    let source_approval_id =
      json |> member "source_approval_id" |> to_string_option
    in
    Some
      {
        id;
        keeper_name;
        tool_name;
        sandbox_profile;
        backend;
        request_fingerprint;
        request_fingerprint_preview;
        max_risk;
        created_at;
        created_by;
        last_matched_at;
        match_count;
        source_approval_id;
      }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> None

(* ── Global queue (Lock-free Atomic.t) ───────────────────── *)

module SMap = Map.Make(String)

let rec atomic_update atomic f =
  let old_val = Atomic.get atomic in
  let new_val = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then ()
  else atomic_update atomic f

let pending : pending_approval SMap.t Atomic.t = Atomic.make SMap.empty

let make_generated_id prefix =
  let entropy =
    Printf.sprintf "%s|%d|%.6f|%d" prefix
      (Unix.getpid ()) (Unix.gettimeofday ()) (Random.bits ())
  in
  let digest = Digestif.SHA256.(digest_string entropy |> to_hex) in
  prefix ^ "_" ^ String.sub digest 0 12

(* Eio.Mutex: rules read/write happens from approval-flow Eio fibers in a
   single domain. Stdlib.Mutex with PTHREAD_MUTEX_ERRORCHECK turns fiber
   contention into EDEADLK (memory: feedback_eio-mutex-vs-stdlib). *)
let rules_mu = Eio.Mutex.create ()

let with_rules_lock f =
  Eio.Mutex.use_rw ~protect:true rules_mu f

let rules_path ?base_path () =
  let base_path =
    Option.value ~default:(Env_config_core.base_path ()) base_path
  in
  Filename.concat (Coord_utils.masc_dir_from_base_path ~base_path)
    "approval-rules.json"

let stable_request_key_blocklist =
  [ "id"; "turn_id"; "timestamp"; "requested_at"; "requested_at_iso"; "ts";
    "created_at"; "updated_at"; "trace_id"; "session_id"; "keeper_turn_id";
    "approval_id"; "rule_id"; "nonce" ]

let rec normalize_request_json = function
  | `Assoc fields ->
      fields
      |> List.filter (fun (key, _) -> not (List.mem key stable_request_key_blocklist))
      |> List.map (fun (key, value) -> (key, normalize_request_json value))
      |> List.sort (fun (left, _) (right, _) -> String.compare left right)
      |> fun normalized -> `Assoc normalized
  | `List items -> `List (List.map normalize_request_json items)
  | other -> other

let request_fingerprint (input : Yojson.Safe.t) =
  let stable_json = normalize_request_json input |> Yojson.Safe.to_string in
  Digestif.SHA256.(digest_string stable_json |> to_hex)

let request_fingerprint_preview fingerprint =
  String.sub fingerprint 0 (min 12 (String.length fingerprint))

let sandbox_profile_of_runtime_contract runtime_contract =
  Option.bind runtime_contract (string_opt_member "sandbox_profile")

let backend_of_runtime_contract runtime_contract =
  Option.bind runtime_contract (string_opt_member "backend")

let load_rules_unlocked ?base_path () =
  match Safe_ops.read_json_file_safe (rules_path ?base_path ()) with
  | Ok (`List entries) ->
      entries |> List.filter_map approval_rule_of_yojson
  | _ -> []

let save_rules_unlocked ?base_path rules : (unit, string) result =
  let path = rules_path ?base_path () in
  Fs_compat.mkdir_p (Filename.dirname path);
  let json = `List (List.map approval_rule_to_yojson rules) in
  Fs_compat.save_file_atomic path (Yojson.Safe.pretty_to_string json)

let list_rules ?base_path () =
  with_rules_lock (fun () -> load_rules_unlocked ?base_path ())

let list_rules_dashboard_json ?base_path () =
  let rules =
    list_rules ?base_path ()
    |> List.sort (fun left right -> Float.compare right.created_at left.created_at)
  in
  `List (List.map approval_rule_to_yojson rules)

let policy_summary_json ~base_path ~keeper_name : Yojson.Safe.t =
  let persisted_rules =
    list_rules ~base_path ()
    |> List.fold_left
         (fun count (rule : approval_rule) ->
           if String.equal rule.keeper_name keeper_name then count + 1 else count)
         0
  in
  `Assoc
    [
      ("allow_rules", `Int persisted_rules);
      ("deny_rules", `Int 0);
      ("persisted_rules", `Int persisted_rules);
    ]

let rule_identity_matches left right =
  String.equal left.keeper_name right.keeper_name
  && String.equal left.tool_name right.tool_name
  && left.sandbox_profile = right.sandbox_profile
  && left.backend = right.backend
  && String.equal left.request_fingerprint right.request_fingerprint
  && left.max_risk = right.max_risk

let upsert_rule ?base_path ~keeper_name ~tool_name ~input ~risk_level
    ?runtime_contract ?created_by ?source_approval_id () =
  with_rules_lock (fun () ->
    let rules = load_rules_unlocked ?base_path () in
    let request_fingerprint = request_fingerprint input in
    let candidate =
      {
        id = make_generated_id "rule";
        keeper_name;
        tool_name;
        sandbox_profile = sandbox_profile_of_runtime_contract runtime_contract;
        backend = backend_of_runtime_contract runtime_contract;
        request_fingerprint;
        request_fingerprint_preview =
          request_fingerprint_preview request_fingerprint;
        max_risk = risk_level;
        created_at = Unix.gettimeofday ();
        created_by;
        last_matched_at = None;
        match_count = 0;
        source_approval_id;
      }
    in
    match List.find_opt (fun rule -> rule_identity_matches rule candidate) rules with
    | Some existing -> (existing, false)
    | None ->
        (match save_rules_unlocked ?base_path (candidate :: rules) with
         | Ok () -> ()
         | Error msg ->
           Prometheus.inc_counter
             Prometheus.metric_keeper_approval_queue_failures
             ~labels:[("keeper", keeper_name); ("site", "upsert_rule_save")]
             ();
           Log.Keeper.warn "upsert_rule: save failed: %s" msg);
        (candidate, true))

let delete_rule ?base_path ~id () =
  with_rules_lock (fun () ->
    let rules = load_rules_unlocked ?base_path () in
    match List.find_opt (fun rule -> String.equal rule.id id) rules with
    | None -> Error (Printf.sprintf "approval rule %s not found" id)
    | Some deleted ->
        let remaining =
          List.filter (fun rule -> not (String.equal rule.id id)) rules
        in
        (match save_rules_unlocked ?base_path remaining with
         | Ok () -> Ok deleted
         | Error msg -> Error msg))

let find_matching_rule ?base_path ~keeper_name ~tool_name ~input ~risk_level
    ?runtime_contract () =
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
              if String.equal current.id rule.id then
                {
                  current with
                  last_matched_at = Some now;
                  match_count = current.match_count + 1;
                }
              else current)
            rules
        in
        (match save_rules_unlocked ?base_path updated_rules with
         | Ok () -> ()
         | Error msg ->
           Prometheus.inc_counter
             Prometheus.metric_keeper_approval_queue_failures
             ~labels:[("keeper", keeper_name); ("site", "matching_rule_save")]
             ();
           Log.Keeper.warn "find_matching_rule: save failed: %s" msg);
        Some { rule_id = rule.id; matched_by = "always_rule" })

(* ── Persistent audit log ────────────────────────────────── *)

(** Dated JSONL audit trail for approval events.
    Stored at [<base_path>/.masc/audit-approvals/YYYY-MM/DD.jsonl].
    Dashboard and room-scoped keeper runs pass [base_path] explicitly so approval
    history stays with the room that made the decision. *)
(* Eio.Mutex: audit store map and audit-IO are accessed from approval-flow
   Eio fibers (single domain). Stdlib.Mutex with PTHREAD_MUTEX_ERRORCHECK
   raises EDEADLK on fiber contention (memory: feedback_eio-mutex-vs-stdlib). *)
let audit_stores_mu = Eio.Mutex.create ()
let audit_io_mu = Eio.Mutex.create ()
let audit_stores : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 4

let audit_today_path base_dir =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  let month =
    Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)
  in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  let dir = Filename.concat base_dir month in
  Fs_compat.mkdir_p dir;
  Filename.concat dir day

let get_audit_store ?base_path () =
  let base = Option.value ~default:(Env_config_core.base_path ()) base_path in
  try
    Eio.Mutex.use_rw ~protect:true audit_stores_mu (fun () ->
      match Hashtbl.find_opt audit_stores base with
      | Some store -> Some store
      | None ->
          let dir =
            Filename.concat
              (Common.masc_dir_from_base_path ~base_path:base)
              "audit-approvals"
          in
          let store = Dated_jsonl.create ~base_dir:dir () in
          Hashtbl.replace audit_stores base store;
          Some store)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Prometheus.inc_counter
        Prometheus.metric_keeper_approval_queue_failures
        ~labels:[("keeper", "aggregate"); ("site", "audit_store_create")]
        ();
      Log.Keeper.warn "approval_queue: audit store creation failed: %s"
        (Printexc.to_string exn);
      None

let audit_approval_event ?base_path ~event_type ~id ~keeper_name ~tool_name
    ~risk_level ?turn_id ?task_id ?goal_id ?(goal_ids = [])
    ?runtime_contract ?selected_model ?disposition ?disposition_reason
    ?rule_match ?source_approval_id ?auto_approved ?decision () =
  let decision =
    decision
    |> Option.map approval_audit_decision_to_string
    |> Option.value ~default:""
  in
  match get_audit_store ?base_path () with
  | None -> ()
  | Some store ->
    let json =
      `Assoc
        ([
           ("ts", `Float (Unix.gettimeofday ()));
           ("event", `String event_type);
           ("id", `String id);
           ("keeper", `String keeper_name);
           ("tool", `String tool_name);
           ("risk", `String (risk_level_to_string risk_level));
           ("decision", `String decision);
           ("turn_id", Json_util.int_opt_to_json turn_id);
           ("task_id", Json_util.string_opt_to_json task_id);
           ("goal_id", Json_util.string_opt_to_json goal_id);
           ("goal_ids", `List (List.map (fun goal -> `String goal) goal_ids));
           ("selected_model", Json_util.string_opt_to_json selected_model);
           ("disposition", Json_util.string_opt_to_json disposition);
           ("disposition_reason", Json_util.string_opt_to_json disposition_reason);
         ]
         @
         (match runtime_contract with
         | Some json -> [ ("runtime_contract", json) ]
         | None -> [])
         @
         (match rule_match with
         | Some matched -> [ ("rule_match", rule_match_to_yojson matched) ]
         | None -> [])
         @
         (match source_approval_id with
         | Some approval_id -> [ ("source_approval_id", `String approval_id) ]
         | None -> [])
         @
         (match auto_approved with
         | Some value -> [ ("auto_approved", `Bool value) ]
         | None -> []))
    in
    Safe_ops.protect ~default:() (fun () ->
      Eio.Mutex.use_rw ~protect:true audit_io_mu (fun () ->
        Fs_compat.append_jsonl
          (audit_today_path (Dated_jsonl.base_dir store))
          json))

let audit_rule_event ?base_path ~event_type (rule : approval_rule) =
  audit_approval_event ?base_path ~event_type ~id:rule.id
    ~keeper_name:rule.keeper_name ~tool_name:rule.tool_name
    ~risk_level:rule.max_risk ?source_approval_id:rule.source_approval_id ()

let audit_scan_window ?keeper_name n =
  match keeper_name with
  | None -> max n 1
  | Some _ ->
      (* Approval audit is global, but runtime trust asks for per-keeper
         "latest" records. Scan a bounded wider window before filtering so a
         busy fleet cannot hide the target keeper behind unrelated events. *)
      max 500 (max n 1 * 64)

let read_recent_audit ?base_path ?keeper_name ?(n = 20) () : Yojson.Safe.t list =
  if n <= 0 then []
  else
    match get_audit_store ?base_path () with
    | None -> []
    | Some store ->
        let raw = Dated_jsonl.read_recent store (audit_scan_window ?keeper_name n) in
        let filtered =
          match keeper_name with
          | None -> raw
          | Some name ->
              raw
              |> List.filter (fun json ->
                     String.equal name
                       (Safe_ops.json_string ~default:"" "keeper" json))
        in
        filtered
        |> List.rev
        |> List.filteri (fun idx _ -> idx < n)

module For_testing = struct
  let reset_audit_store () =
    Eio.Mutex.use_rw ~protect:true audit_stores_mu (fun () ->
      Hashtbl.clear audit_stores)
end

let generate_id () =
  make_generated_id "appr"

let normalized_input_hash (input : Yojson.Safe.t) =
  Digestif.SHA256.(digest_string (Yojson.Safe.to_string input) |> to_hex)

let first_cmd_token (cmd : string) =
  cmd
  |> String.trim
  |> String.split_on_char ' '
  |> List.find_map (fun token ->
         let trimmed = String.trim token in
         if trimmed = "" then None else Some trimmed)

let action_key_of_input ~tool_name ~(input : Yojson.Safe.t) =
  match Safe_ops.json_string_opt "op" input with
  | Some op when String.trim op <> "" ->
      "op:" ^ String.trim op
  | _ -> (
      match Safe_ops.json_string_opt "action" input with
      | Some action when String.trim action <> "" ->
          "action:" ^ String.trim action
      | _ -> (
          match Safe_ops.json_string_opt "kind" input with
          | Some kind when String.trim kind <> "" ->
              "kind:" ^ String.trim kind
          | _ -> (
              match
                Safe_ops.json_string_opt "cmd" input
                |> fun value -> Option.bind value first_cmd_token
              with
              | Some token -> "cmd:" ^ token
              | None -> "tool:" ^ tool_name)))

let sandbox_target_of_runtime_contract = function
  | Some runtime_contract -> (
      match Safe_ops.json_string_opt "sandbox_target" runtime_contract with
      | Some target when String.trim target <> "" -> String.trim target
      | _ -> (
          match Safe_ops.json_string_opt "backend" runtime_contract with
          | Some backend when String.trim backend <> "" -> String.trim backend
          | _ -> "unknown"))
  | None -> "unknown"

let input_preview_of_json (json : Yojson.Safe.t) =
  (* Per-leaf sentinel-aware truncation: a naive [String.sub] on the
     serialized form would chop a [masc:blob ...] marker mid-field and
     leave sha256/bytes/mime malformed so the approval-queue viewer
     cannot round-trip the preview. *)
  let json = Observability_redact.preview_json_strings ~max_len:200 json in
  let raw = Yojson.Safe.to_string json in
  Observability_redact.redact_preview ~max_len:200 raw

let create_entry ~id ~keeper_name ~tool_name ~input ~risk_level
    ?turn_id ?task_id ?goal_id ?(goal_ids = []) ?runtime_contract
    ?selected_model ?disposition ?disposition_reason ?audit_base_path
    ~resolver ~on_resolution () =
  let action_key = action_key_of_input ~tool_name ~input in
  let input_hash = normalized_input_hash input in
  let sandbox_target = sandbox_target_of_runtime_contract runtime_contract in
  {
    id;
    keeper_name;
    tool_name;
    action_key;
    input_hash;
    sandbox_target;
    input;
    risk_level;
    requested_at = Unix.gettimeofday ();
    turn_id;
    task_id;
    goal_id;
    goal_ids;
    runtime_contract;
    selected_model;
    disposition;
    disposition_reason;
    audit_base_path;
    resolver;
    on_resolution;
  }

let pending_entry_json_fields ?(include_requested_at_iso = false)
    ?(include_runtime_contract = false) ?(include_input = false)
    (entry : pending_approval) =
  [
    ("id", `String entry.id);
    ("keeper_name", `String entry.keeper_name);
    ("tool_name", `String entry.tool_name);
    ("action_key", `String entry.action_key);
    ("sandbox_target", `String entry.sandbox_target);
    ("risk_level", `String (risk_level_to_string entry.risk_level));
    ("requested_at", `Float entry.requested_at);
    ("waiting_s", `Float (Unix.gettimeofday () -. entry.requested_at));
    ("turn_id", Json_util.int_opt_to_json entry.turn_id);
    ("task_id", Json_util.string_opt_to_json entry.task_id);
    ("goal_id", Json_util.string_opt_to_json entry.goal_id);
    ("goal_ids", `List (List.map (fun goal -> `String goal) entry.goal_ids));
    ("selected_model", Json_util.string_opt_to_json entry.selected_model);
    ("disposition", Json_util.string_opt_to_json entry.disposition);
    ("disposition_reason", Json_util.string_opt_to_json entry.disposition_reason);
  ]
  @ (if include_requested_at_iso then
       [ ("requested_at_iso", `String (Masc_domain.iso8601_of_unix_seconds entry.requested_at)) ]
     else [])
  @ (if include_runtime_contract then
       [
         ( "runtime_contract",
           match entry.runtime_contract with
           | Some json -> json
           | None when String.equal entry.sandbox_target "unknown" -> `Null
           | None ->
               `Assoc
                 [
                   ("backend", `String entry.sandbox_target);
                   ("sandbox_target", `String entry.sandbox_target);
                 ] );
       ]
     else [])
  @ (if include_input then
       [
         ("input", entry.input);
         ("input_preview", `String (input_preview_of_json entry.input));
       ]
     else [])

let broadcast_pending entry =
  try
    Sse.broadcast
      (`Assoc [
         ("type", `String "approval:pending");
         ( "payload",
           `Assoc
             (pending_entry_json_fields ~include_runtime_contract:true
                ~include_input:true entry) );
       ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> ()

let record_pending (entry : pending_approval) =
  Log.Keeper.info
    "HITL_APPROVAL_PENDING: id=%s keeper=%s tool=%s risk=%s"
    entry.id entry.keeper_name entry.tool_name
    (risk_level_to_string entry.risk_level);
  audit_approval_event ?base_path:entry.audit_base_path ~event_type:"pending"
    ~id:entry.id
    ~keeper_name:entry.keeper_name ~tool_name:entry.tool_name
    ~risk_level:entry.risk_level ?turn_id:entry.turn_id ?task_id:entry.task_id
    ?goal_id:entry.goal_id ~goal_ids:entry.goal_ids
    ?runtime_contract:entry.runtime_contract
    ?selected_model:entry.selected_model ?disposition:entry.disposition
    ?disposition_reason:entry.disposition_reason ();
  broadcast_pending entry

let resolve_entry ?base_path (entry : pending_approval) (decision : decision) =
  let decision_str = approval_decision_to_string decision in
  Log.Keeper.info
    "HITL_APPROVAL_RESOLVED: id=%s keeper=%s tool=%s decision=%s"
    entry.id entry.keeper_name entry.tool_name decision_str;
  audit_approval_event ?base_path ~event_type:"resolved" ~id:entry.id
    ~keeper_name:entry.keeper_name ~tool_name:entry.tool_name
    ~risk_level:entry.risk_level ?turn_id:entry.turn_id ?task_id:entry.task_id
    ?goal_id:entry.goal_id ~goal_ids:entry.goal_ids
    ?runtime_contract:entry.runtime_contract
    ?selected_model:entry.selected_model ?disposition:entry.disposition
    ?disposition_reason:entry.disposition_reason
    ~decision:(Approval_resolved decision) ();
  (match entry.resolver with
   | Some resolver -> Eio.Promise.resolve resolver decision
   | None -> ());
  (match entry.on_resolution with
   | Some f ->
     (try f decision
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Prometheus.inc_counter
          Prometheus.metric_keeper_approval_queue_failures
          ~labels:[("keeper", entry.keeper_name); ("site", "resolution_callback")]
          ();
        Log.Keeper.warn
          "approval_queue: resolution callback failed id=%s err=%s"
          entry.id (Printexc.to_string exn))
   | None -> ());
  try
    Sse.broadcast
      (`Assoc [
         ("type", `String "approval:resolved");
         ("payload", `Assoc [
            ("id", `String entry.id);
            ("keeper_name", `String entry.keeper_name);
            ("tool_name", `String entry.tool_name);
            ("decision", `String decision_str);
            ("selected_model", Json_util.string_opt_to_json entry.selected_model);
            ("disposition", Json_util.string_opt_to_json entry.disposition);
            ("disposition_reason", Json_util.string_opt_to_json entry.disposition_reason);
          ]);
       ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> ()

let pending_entry_matches (entry : pending_approval)
    ~keeper_name ~tool_name ~action_key ~input_hash
    ~task_id ~goal_id ~sandbox_target =
  String.equal entry.keeper_name keeper_name
  && String.equal entry.tool_name tool_name
  && String.equal entry.action_key action_key
  && String.equal entry.input_hash input_hash
  && String.equal entry.sandbox_target sandbox_target
  && entry.task_id = task_id
  && entry.goal_id = goal_id

let find_pending_id_in_map (map : pending_approval SMap.t) ~keeper_name ~tool_name
    ~action_key ~input_hash ~task_id ~goal_id ~sandbox_target =
  SMap.fold
    (fun id (entry : pending_approval) acc ->
      match acc with
      | Some _ -> acc
      | None ->
        if pending_entry_matches entry ~keeper_name ~tool_name ~action_key
             ~input_hash ~task_id ~goal_id ~sandbox_target
        then Some id
        else None)
    map None

let sort_entries_by_requested_at entries =
  List.sort
    (fun left right ->
      let ts_of_json json =
        Yojson.Safe.Util.(member "requested_at" json |> to_float)
      in
      Float.compare (ts_of_json left) (ts_of_json right))
    entries

(* ── Submit & await ───────────────────────────────────────── *)

(** Submit a tool call for approval and suspend the calling fiber.
    Returns the operator's decision when the promise is resolved.
    Called from the OAS approval_callback (inside agent fiber).

    [timeout_s] defaults to 600s for non-[Critical] approvals. This is
    intentionally longer than the 30s wrapper used by A2 for generic
    [Eio.Promise.await] sites: a HITL approval is bounded by an
    operator's response time, not by an SLA on autonomous progress.
    [Critical] approvals are exempt, matching [expire_stale]'s
    operator-must-decide policy. Drop the default only after measuring
    the operator-response distribution — premature shortening turns
    every distracted operator into an [Approval_expired] event. *)
let submit_and_await ~keeper_name ~tool_name ~input ~risk_level
    ?base_path ?turn_id ?task_id ?goal_id ?(goal_ids = []) ?runtime_contract
    ?selected_model ?disposition ?disposition_reason
    ?clock ?(timeout_s = 600.0)
    ()
  : Agent_sdk.Hooks.approval_decision =
  let id = generate_id () in
  let promise, resolver = Eio.Promise.create () in
  let entry =
    create_entry ~id ~keeper_name ~tool_name ~input ~risk_level
      ?turn_id ?task_id ?goal_id ~goal_ids ?runtime_contract
      ?selected_model ?disposition ?disposition_reason
      ?audit_base_path:base_path
      ~resolver:(Some resolver) ~on_resolution:None ()
  in
  atomic_update pending (fun map -> SMap.add id entry map);
  record_pending entry;
  let timeout_decision reason =
    let decision = Agent_sdk.Hooks.Reject reason in
    match Eio.Promise.peek promise with
    | Some observed -> observed
    | None ->
      (try Eio.Promise.resolve resolver decision
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | _ -> ());
      (match Eio.Promise.peek promise with
       | Some observed -> observed
       | None -> decision)
  in
  let await_with_timeout () =
    match clock, risk_level with
    | Some clock, (Low | Medium | High) ->
      (match
         Eio.Fiber.first
           (fun () -> `Decision (Eio.Promise.await promise))
           (fun () -> Eio.Time.sleep clock timeout_s; `Timeout)
       with
       | `Decision d -> d
       | `Timeout ->
         let reason =
           Printf.sprintf "approval timeout after %.0fs" timeout_s
         in
         audit_approval_event
           ?base_path:entry.audit_base_path
           ~event_type:"approval_timeout"
           ~id
           ~keeper_name
           ~tool_name
           ~risk_level
           ?turn_id
           ?task_id
           ?goal_id
           ~goal_ids
           ?runtime_contract
           ?selected_model
           ~decision:(Approval_expired reason)
           ();
         (* Mirror expire_stale's teardown, but preserve any concurrent
            operator decision that wins the promise resolution race. *)
         timeout_decision reason)
    | Some _, Critical
    | None, _ -> Eio.Promise.await promise
  in
  Fun.protect
    await_with_timeout
    ~finally:(fun () ->
      Safe_ops.protect ~default:() (fun () ->
        atomic_update pending (fun map -> SMap.remove id map)))

let submit_pending ~keeper_name ~tool_name ~input ~risk_level
    ?base_path ?turn_id ?task_id ?goal_id ?(goal_ids = []) ?runtime_contract
    ?selected_model ?disposition ?disposition_reason
    ~on_resolution
    ()
  : string =
  let action_key = action_key_of_input ~tool_name ~input in
  let input_hash = normalized_input_hash input in
  let sandbox_target = sandbox_target_of_runtime_contract runtime_contract in
  let rec submit () =
    let map = Atomic.get pending in
    match
      find_pending_id_in_map map ~keeper_name ~tool_name ~action_key
        ~input_hash ~task_id ~goal_id ~sandbox_target
    with
    | Some id -> id
    | None ->
      let id = generate_id () in
      let entry =
        create_entry ~id ~keeper_name ~tool_name ~input ~risk_level
          ?turn_id ?task_id ?goal_id ~goal_ids ?runtime_contract
          ?selected_model ?disposition ?disposition_reason
          ?audit_base_path:base_path
          ~resolver:None ~on_resolution:(Some on_resolution) ()
      in
      let updated = SMap.add id entry map in
      if Atomic.compare_and_set pending map updated then (
        record_pending entry;
        id
      ) else
        submit ()
  in
  submit ()

(* ── Resolve (operator action) ────────────────────────────── *)

type resolve_error =
  | Not_found of string
  | Already_resolved of string

let resolve_error_to_string = function
  | Not_found id -> Printf.sprintf "approval %s not found" id
  | Already_resolved id -> Printf.sprintf "approval %s already resolved" id

let remember_rule_for_entry ?base_path ?created_by (entry : pending_approval) =
  let rememberable =
    match entry.risk_level with
    | Low | Medium -> true
    | High | Critical -> false
  in
  if not rememberable then None
  else
  try
    let rule, created =
      upsert_rule ?base_path ~keeper_name:entry.keeper_name
        ~tool_name:entry.tool_name
        ~input:entry.input ~risk_level:entry.risk_level
        ?runtime_contract:entry.runtime_contract ?created_by
        ~source_approval_id:entry.id ()
    in
    if created then audit_rule_event ?base_path ~event_type:"rule_created" rule;
    Some rule
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Prometheus.inc_counter
        Prometheus.metric_keeper_approval_queue_failures
        ~labels:[("keeper", entry.keeper_name); ("site", "remember_rule")]
        ();
      Log.Keeper.warn
        "approval_queue: remember rule failed id=%s err=%s"
        entry.id (Printexc.to_string exn);
      None

let resolve_with_policy ?base_path ~id ~(decision : Agent_sdk.Hooks.approval_decision)
    ?(remember_rule = false) ?created_by ()
    : (resolution_result, resolve_error) result =
  let result = ref (Error (Not_found id)) in
  atomic_update pending (fun map ->
    match SMap.find_opt id map with
    | None -> map
    | Some entry ->
        result := Ok entry;
        SMap.remove id map);
  match !result with
  | Error _ as err -> err
  | Ok entry ->
      let remembered_rule =
        match decision with
        | Agent_sdk.Hooks.Approve when remember_rule ->
            remember_rule_for_entry ?base_path ?created_by entry
        | _ -> None
      in
      resolve_entry ?base_path entry decision;
      Ok { remembered_rule }

(** Resolve a pending approval. Returns [Ok ()] if found and resolved,
    [Error (Not_found _)] if the id is not in the queue, or
    [Error (Already_resolved _)] if the atomic update found no matching
    entry (concurrent resolve race).
    Called from the dashboard approval HTTP handler
    ([server_dashboard_http.ml]) and MCP inline dispatch. *)
let resolve ~id ~(decision : Agent_sdk.Hooks.approval_decision) : (unit, resolve_error) result =
  match resolve_with_policy ~id ~decision () with
  | Ok _ -> Ok ()
  | Error _ as err -> err

(* ── Query ────────────────────────────────────────────────── *)

(** List all pending approvals as JSON. *)
let list_pending_json () : Yojson.Safe.t =
  let entries = SMap.fold (fun _id entry acc ->
    `Assoc (pending_entry_json_fields entry) :: acc
  ) (Atomic.get pending) [] in
  `List (sort_entries_by_requested_at entries)

let list_pending_dashboard_json () : Yojson.Safe.t =
  let entries = SMap.fold (fun _id entry acc ->
    `Assoc
      (pending_entry_json_fields ~include_requested_at_iso:true
         ~include_runtime_contract:true ~include_input:true entry)
    :: acc
  ) (Atomic.get pending) [] in
  `List (sort_entries_by_requested_at entries)

let pending_entry_detail_json (entry : pending_approval) : Yojson.Safe.t =
  `Assoc
    (pending_entry_json_fields ~include_requested_at_iso:true
       ~include_runtime_contract:true ~include_input:true entry)

let get_pending_json ~id : Yojson.Safe.t option =
  match SMap.find_opt id (Atomic.get pending) with
  | None -> None
  | Some entry -> Some (pending_entry_detail_json entry)

let pending_count () : int =
  SMap.cardinal (Atomic.get pending)

let pending_count_for_keeper ~keeper_name : int =
  SMap.fold
    (fun _ (entry : pending_approval) count ->
      if String.equal entry.keeper_name keeper_name then count + 1 else count)
    (Atomic.get pending) 0

let has_pending_for_keeper ~keeper_name : bool =
  SMap.fold
    (fun _ (entry : pending_approval) acc ->
      acc || String.equal entry.keeper_name keeper_name)
    (Atomic.get pending) false

(* ── Timeout cleanup ──────────────────────────────────────── *)

(** Reject all approvals that have been waiting longer than [max_wait_s].
    Call periodically from a health loop.

    [Critical] risk-level entries are NEVER auto-expired.  They originate
    from indefinite-wait operator gates ([keeper_continue_after_reconcile],
    [keeper_continue_after_partial_commit] — see callers in
    [Keeper_supervisor] and [Keeper_unified_turn]) where:

    - Auto-rejecting would cause the supervisor's Phase-2 sweep to
      re-enqueue the same approval on the next tick (since the
      paused-meta blocker class is unchanged), creating a 30-min
      expire / re-enqueue / expire cycle that flooded the audit log
      and starved the operator of agency.
    - Critical decisions (auto-compact retry exhaustion, partial-commit
      ambiguity) are exactly the cases where a human MUST decide; a
      stale 30-min default would silently push the keeper into a
      permanent [paused = true] state that no autonomous logic can
      recover from.

    Operators escalate a stuck Critical entry by manual resolve via
    dashboard / mcp / CLI — the timeout policy applies to
    [Low / Medium / High] tool approvals only. *)
let expire_stale ~max_wait_s =
  let now = Unix.gettimeofday () in
  let stale_ref = ref [] in
  atomic_update pending (fun map ->
    let stale = SMap.fold (fun id entry acc ->
      match entry.risk_level with
      | Critical -> acc
      | Low | Medium | High ->
        if now -. entry.requested_at > max_wait_s
        then (id, entry) :: acc
        else acc
    ) map [] in
    stale_ref := stale;
    List.fold_left (fun acc (id, _) -> SMap.remove id acc) map stale
  );
  let stale = !stale_ref in
  List.iter (fun (id, entry) ->
    let reason = Printf.sprintf
      "approval timed out after %.0fs" (now -. entry.requested_at) in
    Prometheus.inc_counter
      Prometheus.metric_keeper_approval_queue_failures
      ~labels:[("keeper", entry.keeper_name); ("site", "approval_expired")]
      ();
    Log.Keeper.warn "HITL_APPROVAL_EXPIRED: id=%s keeper=%s tool=%s"
      id entry.keeper_name entry.tool_name;
    audit_approval_event ?base_path:entry.audit_base_path ~event_type:"expired"
      ~id
      ~keeper_name:entry.keeper_name ~tool_name:entry.tool_name
      ~risk_level:entry.risk_level ?turn_id:entry.turn_id
      ?task_id:entry.task_id ?goal_id:entry.goal_id
      ~goal_ids:entry.goal_ids ?runtime_contract:entry.runtime_contract
      ?selected_model:entry.selected_model ?disposition:entry.disposition
      ?disposition_reason:entry.disposition_reason
      ~decision:(Approval_expired reason) ();
    (match entry.resolver with
     | Some resolver ->
       Eio.Promise.resolve resolver (Agent_sdk.Hooks.Reject reason)
     | None -> ());
    (match entry.on_resolution with
     | Some f ->
       (try f (Agent_sdk.Hooks.Reject reason)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Prometheus.inc_counter
            Prometheus.metric_keeper_approval_queue_failures
            ~labels:[("keeper", entry.keeper_name); ("site", "expire_callback")]
            ();
          Log.Keeper.warn
            "approval_queue: expire callback failed id=%s err=%s"
            id (Printexc.to_string exn))
     | None -> ())
  ) stale
