(** Keeper_approval_queue — Eio.Promise-based HITL approval for keeper tools.

    When a keeper's OAS Agent invokes a tool that requires approval,
    the agent fiber is suspended via [Eio.Promise.await].  An operator
    can then approve/reject via the dashboard approval HTTP handler
    ([server_dashboard_http.ml]), which resolves the promise and
    resumes the agent.

    This replaces the manual "pending_approval" state machine with
    actual execution-level suspension using Eio structured concurrency.

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
  input : Yojson.Safe.t;
  risk_level : risk_level;
  requested_at : float;
  turn_id : int option;
  task_id : string option;
  goal_id : string option;
  goal_ids : string list;
  runtime_contract : Yojson.Safe.t option;
  resolver : Oas.Hooks.approval_decision Eio.Promise.u option;
  on_resolution : (Oas.Hooks.approval_decision -> unit) option;
}

type decision = Oas.Hooks.approval_decision

let risk_level_to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Critical -> "critical"

(* ── Global queue (Lock-free Atomic.t) ───────────────────── *)

module SMap = Map.Make(String)

let rec atomic_update atomic f =
  let old_val = Atomic.get atomic in
  let new_val = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then ()
  else atomic_update atomic f

let pending : pending_approval SMap.t Atomic.t = Atomic.make SMap.empty

(* ── Persistent audit log ────────────────────────────────── *)

(** Dated JSONL audit trail for approval events.
    Stored at [<base_path>/.masc/audit-approvals/YYYY-MM/DD.jsonl].
    Independent of Coord.config — approval is a global resource. *)
let audit_store_ref : Dated_jsonl.t option ref = ref None

let get_audit_store () =
  match !audit_store_ref with
  | Some s -> Some s
  | None ->
    let base = Env_config_core.base_path () in
    let dir = Filename.concat base ".masc/audit-approvals" in
    (match Dated_jsonl.create ~base_dir:dir () with
     | store ->
       audit_store_ref := Some store;
       Some store
     | exception (Eio.Cancel.Cancelled _ as e) -> raise e
     | exception exn ->
       Log.Keeper.warn "approval_queue: audit store creation failed: %s"
         (Printexc.to_string exn);
       None)

let audit_approval_event ~event_type ~id ~keeper_name ~tool_name
    ~risk_level ?turn_id ?task_id ?goal_id ?(goal_ids = [])
    ?runtime_contract ?(decision="") () =
  match get_audit_store () with
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
         ]
         @
         match runtime_contract with
         | Some json -> [("runtime_contract", json)]
         | None -> [])
    in
    Safe_ops.protect ~default:() (fun () ->
      Dated_jsonl.append store json)

let generate_id () =
  let entropy =
    Printf.sprintf "appr|%d|%.6f|%d"
      (Unix.getpid ()) (Unix.gettimeofday ()) (Random.bits ())
  in
  let digest = Digestif.SHA256.(digest_string entropy |> to_hex) in
  "appr_" ^ String.sub digest 0 12

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
    ~resolver ~on_resolution () =
  {
    id;
    keeper_name;
    tool_name;
    input;
    risk_level;
    requested_at = Unix.gettimeofday ();
    turn_id;
    task_id;
    goal_id;
    goal_ids;
    runtime_contract;
    resolver;
    on_resolution;
  }

let broadcast_pending entry =
  try
    Sse.broadcast
      (`Assoc [
         ("type", `String "approval:pending");
         ("payload", `Assoc [
            ("id", `String entry.id);
            ("keeper_name", `String entry.keeper_name);
            ("tool_name", `String entry.tool_name);
            ("risk_level", `String (risk_level_to_string entry.risk_level));
            ("requested_at", `Float entry.requested_at);
            ("input_preview", `String (input_preview_of_json entry.input));
            ("turn_id", Json_util.int_opt_to_json entry.turn_id);
            ("task_id", Json_util.string_opt_to_json entry.task_id);
            ("goal_id", Json_util.string_opt_to_json entry.goal_id);
            ("goal_ids", `List (List.map (fun goal -> `String goal) entry.goal_ids));
            ( "runtime_contract",
              match entry.runtime_contract with
              | Some json -> json
              | None -> `Null );
          ]);
       ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> ()

let record_pending entry =
  Log.Keeper.info
    "HITL_APPROVAL_PENDING: id=%s keeper=%s tool=%s risk=%s"
    entry.id entry.keeper_name entry.tool_name
    (risk_level_to_string entry.risk_level);
  audit_approval_event ~event_type:"pending" ~id:entry.id
    ~keeper_name:entry.keeper_name ~tool_name:entry.tool_name
    ~risk_level:entry.risk_level ?turn_id:entry.turn_id ?task_id:entry.task_id
    ?goal_id:entry.goal_id ~goal_ids:entry.goal_ids
    ?runtime_contract:entry.runtime_contract ();
  broadcast_pending entry

let resolve_entry (entry : pending_approval) (decision : decision) =
  let decision_str = match decision with
    | Oas.Hooks.Approve -> "approve"
    | Oas.Hooks.Reject reason -> "reject:" ^ reason
    | Oas.Hooks.Edit _ -> "edit"
  in
  Log.Keeper.info
    "HITL_APPROVAL_RESOLVED: id=%s keeper=%s tool=%s decision=%s"
    entry.id entry.keeper_name entry.tool_name decision_str;
  audit_approval_event ~event_type:"resolved" ~id:entry.id
    ~keeper_name:entry.keeper_name ~tool_name:entry.tool_name
    ~risk_level:entry.risk_level ?turn_id:entry.turn_id ?task_id:entry.task_id
    ?goal_id:entry.goal_id ~goal_ids:entry.goal_ids
    ?runtime_contract:entry.runtime_contract ~decision:decision_str ();
  (match entry.resolver with
   | Some resolver -> Eio.Promise.resolve resolver decision
   | None -> ());
  (match entry.on_resolution with
   | Some f ->
     (try f decision
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
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
          ]);
       ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> ()

let find_pending_id ~keeper_name ~tool_name =
  SMap.fold
    (fun id entry acc ->
      match acc with
      | Some _ -> acc
      | None ->
        if String.equal entry.keeper_name keeper_name
           && String.equal entry.tool_name tool_name
        then Some id
        else None)
    (Atomic.get pending) None

let find_pending_id_in_map map ~keeper_name ~tool_name =
  SMap.fold
    (fun id entry acc ->
      match acc with
      | Some _ -> acc
      | None ->
        if String.equal entry.keeper_name keeper_name
           && String.equal entry.tool_name tool_name
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
    Called from the OAS approval_callback (inside agent fiber). *)
let submit_and_await ~keeper_name ~tool_name ~input ~risk_level
    ?turn_id ?task_id ?goal_id ?(goal_ids = []) ?runtime_contract
    ()
  : Oas.Hooks.approval_decision =
  let id = generate_id () in
  let promise, resolver = Eio.Promise.create () in
  let entry =
    create_entry ~id ~keeper_name ~tool_name ~input ~risk_level
      ?turn_id ?task_id ?goal_id ~goal_ids ?runtime_contract
      ~resolver:(Some resolver) ~on_resolution:None ()
  in
  atomic_update pending (fun map -> SMap.add id entry map);
  record_pending entry;
  Fun.protect
    (fun () -> Eio.Promise.await promise)
    ~finally:(fun () ->
      Safe_ops.protect ~default:() (fun () ->
        atomic_update pending (fun map -> SMap.remove id map)))

let submit_pending ~keeper_name ~tool_name ~input ~risk_level
    ?turn_id ?task_id ?goal_id ?(goal_ids = []) ?runtime_contract
    ~on_resolution
    ()
  : string =
  let rec submit () =
    let map = Atomic.get pending in
    match find_pending_id_in_map map ~keeper_name ~tool_name with
    | Some id -> id
    | None ->
      let id = generate_id () in
      let entry =
        create_entry ~id ~keeper_name ~tool_name ~input ~risk_level
          ?turn_id ?task_id ?goal_id ~goal_ids ?runtime_contract
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

(** Resolve a pending approval. Returns [Ok ()] if found and resolved,
    [Error (Not_found _)] if the id is not in the queue, or
    [Error (Already_resolved _)] if the atomic update found no matching
    entry (concurrent resolve race).
    Called from the dashboard approval HTTP handler
    ([server_dashboard_http.ml]) and MCP inline dispatch. *)
let resolve ~id ~(decision : Oas.Hooks.approval_decision) : (unit, resolve_error) result =
  let result = ref (Error (Not_found id)) in
  atomic_update pending (fun map ->
    match SMap.find_opt id map with
    | None -> map
    | Some entry ->
      result := Ok entry;
      SMap.remove id map
  );
  match !result with
  | Error _ as err -> err
  | Ok entry ->
    resolve_entry entry decision;
    Ok ()

(* ── Query ────────────────────────────────────────────────── *)

(** List all pending approvals as JSON. *)
let list_pending_json () : Yojson.Safe.t =
  let entries = SMap.fold (fun _id entry acc ->
    `Assoc [
      ("id", `String entry.id);
      ("keeper_name", `String entry.keeper_name);
      ("tool_name", `String entry.tool_name);
      ("risk_level", `String (risk_level_to_string entry.risk_level));
      ("requested_at", `Float entry.requested_at);
      ("waiting_s", `Float (Unix.gettimeofday () -. entry.requested_at));
      ("turn_id", Json_util.int_opt_to_json entry.turn_id);
      ("task_id", Json_util.string_opt_to_json entry.task_id);
      ("goal_id", Json_util.string_opt_to_json entry.goal_id);
      ("goal_ids", `List (List.map (fun goal -> `String goal) entry.goal_ids));
    ] :: acc
  ) (Atomic.get pending) [] in
  `List (sort_entries_by_requested_at entries)

let list_pending_dashboard_json () : Yojson.Safe.t =
  let entries = SMap.fold (fun _id entry acc ->
    `Assoc [
      ("id", `String entry.id);
      ("keeper_name", `String entry.keeper_name);
      ("tool_name", `String entry.tool_name);
      ("risk_level", `String (risk_level_to_string entry.risk_level));
      ("requested_at", `Float entry.requested_at);
      ("requested_at_iso", `String (Types.iso8601_of_unix_seconds entry.requested_at));
      ("waiting_s", `Float (Unix.gettimeofday () -. entry.requested_at));
      ("turn_id", Json_util.int_opt_to_json entry.turn_id);
      ("task_id", Json_util.string_opt_to_json entry.task_id);
      ("goal_id", Json_util.string_opt_to_json entry.goal_id);
      ("goal_ids", `List (List.map (fun goal -> `String goal) entry.goal_ids));
      ( "runtime_contract",
        match entry.runtime_contract with
        | Some json -> json
        | None -> `Null );
      ("input", entry.input);
      ("input_preview", `String (input_preview_of_json entry.input));
    ] :: acc
  ) (Atomic.get pending) [] in
  `List (sort_entries_by_requested_at entries)

let pending_entry_detail_json (entry : pending_approval) : Yojson.Safe.t =
  `Assoc [
    ("id", `String entry.id);
    ("keeper_name", `String entry.keeper_name);
    ("tool_name", `String entry.tool_name);
    ("risk_level", `String (risk_level_to_string entry.risk_level));
    ("requested_at", `Float entry.requested_at);
    ("requested_at_iso", `String (Types.iso8601_of_unix_seconds entry.requested_at));
    ("waiting_s", `Float (Unix.gettimeofday () -. entry.requested_at));
    ("turn_id", Json_util.int_opt_to_json entry.turn_id);
    ("task_id", Json_util.string_opt_to_json entry.task_id);
    ("goal_id", Json_util.string_opt_to_json entry.goal_id);
    ("goal_ids", `List (List.map (fun goal -> `String goal) entry.goal_ids));
    ( "runtime_contract",
      match entry.runtime_contract with
      | Some json -> json
      | None -> `Null );
    ("input", entry.input);
    ("input_preview", `String (input_preview_of_json entry.input));
  ]

let get_pending_json ~id : Yojson.Safe.t option =
  match SMap.find_opt id (Atomic.get pending) with
  | None -> None
  | Some entry -> Some (pending_entry_detail_json entry)

let pending_count () : int =
  SMap.cardinal (Atomic.get pending)

let pending_count_for_keeper ~keeper_name : int =
  SMap.fold
    (fun _ entry count ->
      if String.equal entry.keeper_name keeper_name then count + 1 else count)
    (Atomic.get pending) 0

let has_pending_for_keeper ~keeper_name : bool =
  SMap.fold (fun _ entry acc -> acc || String.equal entry.keeper_name keeper_name) (Atomic.get pending) false

(* ── Timeout cleanup ──────────────────────────────────────── *)

(** Reject all approvals that have been waiting longer than [max_wait_s].
    Call periodically from a health loop. *)
let expire_stale ~max_wait_s =
  let now = Unix.gettimeofday () in
  let stale_ref = ref [] in
  atomic_update pending (fun map ->
    let stale = SMap.fold (fun id entry acc ->
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
    Log.Keeper.warn "HITL_APPROVAL_EXPIRED: id=%s keeper=%s tool=%s"
      id entry.keeper_name entry.tool_name;
    audit_approval_event ~event_type:"expired" ~id
      ~keeper_name:entry.keeper_name ~tool_name:entry.tool_name
      ~risk_level:entry.risk_level ?turn_id:entry.turn_id
      ?task_id:entry.task_id ?goal_id:entry.goal_id
      ~goal_ids:entry.goal_ids ?runtime_contract:entry.runtime_contract
      ~decision:("reject:" ^ reason) ();
    (match entry.resolver with
     | Some resolver ->
       Eio.Promise.resolve resolver (Oas.Hooks.Reject reason)
     | None -> ());
    (match entry.on_resolution with
     | Some f ->
       (try f (Oas.Hooks.Reject reason)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.warn
            "approval_queue: expire callback failed id=%s err=%s"
            id (Printexc.to_string exn))
     | None -> ())
  ) stale
