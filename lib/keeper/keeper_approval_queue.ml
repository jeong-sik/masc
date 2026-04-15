(** Keeper_approval_queue — Eio.Promise-based HITL approval for keeper tools.

    When a keeper's OAS Agent invokes a tool that requires approval,
    the agent fiber is suspended via [Eio.Promise.await].  An operator
    can then approve/reject via the command plane API, which resolves
    the promise and resumes the agent.

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
  resolver : Oas.Hooks.approval_decision Eio.Promise.u option;
  on_resolution : (Oas.Hooks.approval_decision -> unit) option;
}

type decision = Oas.Hooks.approval_decision

let risk_level_to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Critical -> "critical"

(* ── Global queue (Eio.Mutex-protected) ───────────────────── *)

let mu = Eio.Mutex.create ()
let pending : (string, pending_approval) Hashtbl.t = Hashtbl.create 8

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
    ~risk_level ?(decision="") () =
  match get_audit_store () with
  | None -> ()
  | Some store ->
    let json = `Assoc [
      ("ts", `Float (Unix.gettimeofday ()));
      ("event", `String event_type);
      ("id", `String id);
      ("keeper", `String keeper_name);
      ("tool", `String tool_name);
      ("risk", `String (risk_level_to_string risk_level));
      ("decision", `String decision);
    ] in
    (try Dated_jsonl.append store json
     with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ())

let generate_id () =
  let entropy =
    Printf.sprintf "appr|%d|%.6f|%d"
      (Unix.getpid ()) (Unix.gettimeofday ()) (Random.bits ())
  in
  let digest = Digestif.SHA256.(digest_string entropy |> to_hex) in
  "appr_" ^ String.sub digest 0 12

let input_preview_of_json (json : Yojson.Safe.t) =
  let raw = Yojson.Safe.to_string json in
  String.sub raw 0 (min 200 (String.length raw))

let create_entry ~id ~keeper_name ~tool_name ~input ~risk_level
    ~resolver ~on_resolution =
  {
    id;
    keeper_name;
    tool_name;
    input;
    risk_level;
    requested_at = Unix.gettimeofday ();
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
    ~risk_level:entry.risk_level ();
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
    ~risk_level:entry.risk_level ~decision:decision_str ();
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

let find_pending_id_locked ~keeper_name ~tool_name =
  Hashtbl.fold
    (fun id entry acc ->
      match acc with
      | Some _ -> acc
      | None ->
        if String.equal entry.keeper_name keeper_name
           && String.equal entry.tool_name tool_name
        then Some id
        else None)
    pending None

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
  : Oas.Hooks.approval_decision =
  let id = generate_id () in
  let promise, resolver = Eio.Promise.create () in
  let entry =
    create_entry ~id ~keeper_name ~tool_name ~input ~risk_level
      ~resolver:(Some resolver) ~on_resolution:None
  in
  Eio.Mutex.use_rw ~protect:true mu (fun () ->
    Hashtbl.replace pending id entry);
  record_pending entry;
  (* SUSPEND the agent fiber until operator resolves.
     Fun.protect ensures the pending entry is cleaned up if the fiber
     is cancelled (e.g. keeper shutdown via Eio.Switch cancellation).
     Without this, orphan entries accumulate in the hashtbl. (#5949) *)
  Fun.protect
    (fun () -> Eio.Promise.await promise)
    ~finally:(fun () ->
      (try
         Eio.Mutex.use_rw ~protect:true mu (fun () ->
           Hashtbl.remove pending id)
       with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ()))

let submit_pending ~keeper_name ~tool_name ~input ~risk_level ~on_resolution
  : string =
  let created_entry =
    Eio.Mutex.use_rw ~protect:true mu (fun () ->
      match find_pending_id_locked ~keeper_name ~tool_name with
      | Some id -> (`Existing id)
      | None ->
        let id = generate_id () in
        let entry =
          create_entry ~id ~keeper_name ~tool_name ~input ~risk_level
            ~resolver:None ~on_resolution:(Some on_resolution)
        in
        Hashtbl.replace pending id entry;
        `Created entry)
  in
  match created_entry with
  | `Existing id -> id
  | `Created entry ->
    record_pending entry;
    entry.id

(* ── Resolve (operator action) ────────────────────────────── *)

(** Resolve a pending approval. Returns [Ok ()] if found, [Error msg] if not.
    Called from the command plane HTTP handler. *)
let resolve ~id ~(decision : Oas.Hooks.approval_decision) : (unit, string) result =
  let result =
    Eio.Mutex.use_rw ~protect:true mu (fun () ->
    match Hashtbl.find_opt pending id with
    | None -> Error (Printf.sprintf "approval %s not found or already resolved" id)
    | Some entry ->
      Hashtbl.remove pending id;
      Ok entry)
  in
  match result with
  | Error _ as err -> err
  | Ok entry ->
    resolve_entry entry decision;
    Ok ()

(* ── Query ────────────────────────────────────────────────── *)

(** List all pending approvals as JSON. *)
let list_pending_json () : Yojson.Safe.t =
  Eio.Mutex.use_ro mu (fun () ->
    let entries = Hashtbl.fold (fun _id entry acc ->
      `Assoc [
        ("id", `String entry.id);
        ("keeper_name", `String entry.keeper_name);
        ("tool_name", `String entry.tool_name);
        ("risk_level", `String (risk_level_to_string entry.risk_level));
        ("requested_at", `Float entry.requested_at);
        ("waiting_s", `Float (Unix.gettimeofday () -. entry.requested_at));
      ] :: acc
    ) pending [] in
    `List (sort_entries_by_requested_at entries))

let list_pending_dashboard_json () : Yojson.Safe.t =
  Eio.Mutex.use_ro mu (fun () ->
    let entries = Hashtbl.fold (fun _id entry acc ->
      `Assoc [
        ("id", `String entry.id);
        ("keeper_name", `String entry.keeper_name);
        ("tool_name", `String entry.tool_name);
        ("risk_level", `String (risk_level_to_string entry.risk_level));
        ("requested_at", `Float entry.requested_at);
        ("requested_at_iso", `String (Types.iso8601_of_unix_seconds entry.requested_at));
        ("waiting_s", `Float (Unix.gettimeofday () -. entry.requested_at));
        ("input", entry.input);
        ("input_preview", `String (input_preview_of_json entry.input));
      ] :: acc
    ) pending [] in
    `List (sort_entries_by_requested_at entries))

let pending_count () : int =
  Eio.Mutex.use_ro mu (fun () -> Hashtbl.length pending)

let has_pending_for_keeper ~keeper_name : bool =
  Eio.Mutex.use_ro mu (fun () ->
    Hashtbl.fold
      (fun _ entry acc ->
        acc || String.equal entry.keeper_name keeper_name)
      pending false)

(* ── Timeout cleanup ──────────────────────────────────────── *)

(** Reject all approvals that have been waiting longer than [max_wait_s].
    Call periodically from a health loop. *)
let expire_stale ~max_wait_s =
  let now = Unix.gettimeofday () in
  let stale =
    Eio.Mutex.use_rw ~protect:true mu (fun () ->
    let stale = Hashtbl.fold (fun id entry acc ->
      if now -. entry.requested_at > max_wait_s
      then (id, entry) :: acc
      else acc
    ) pending [] in
    List.iter (fun (id, _entry) -> Hashtbl.remove pending id) stale;
    stale)
  in
  List.iter (fun (id, entry) ->
    let reason = Printf.sprintf
      "approval timed out after %.0fs" (now -. entry.requested_at) in
    Log.Keeper.warn "HITL_APPROVAL_EXPIRED: id=%s keeper=%s tool=%s"
      id entry.keeper_name entry.tool_name;
    audit_approval_event ~event_type:"expired" ~id
      ~keeper_name:entry.keeper_name ~tool_name:entry.tool_name
      ~risk_level:entry.risk_level ~decision:("reject:" ^ reason) ();
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
