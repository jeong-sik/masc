(** Keeper_approval_queue — Eio.Promise-based HITL approval for keeper tools.

    When a keeper's OAS Agent invokes a tool that requires approval,
    the agent fiber is suspended via [Eio.Promise.await].  An operator
    can then approve/reject via the command plane API, which resolves
    the promise and resumes the agent.

    This replaces the manual "pending_approval" state machine with
    actual execution-level suspension using Eio structured concurrency.

    @since 2.262.0 (#5907) *)

(* ── Types ────────────────────────────────────────────────── *)

type pending_approval = {
  id : string;
  keeper_name : string;
  tool_name : string;
  input : Yojson.Safe.t;
  risk_level : string;
  requested_at : float;
  resolver : Oas.Hooks.approval_decision Eio.Promise.u;
}

type decision = Oas.Hooks.approval_decision

(* ── Global queue (Eio.Mutex-protected) ───────────────────── *)

let mu = Eio.Mutex.create ()
let pending : (string, pending_approval) Hashtbl.t = Hashtbl.create 8

(* ── Persistent audit log ────────────────────────────────── *)

(** Dated JSONL audit trail for approval events.
    Stored at [<base_path>/.masc/audit-approvals/YYYY-MM/DD.jsonl].
    Independent of Room.config — approval is a global resource. *)
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
     | exception _ -> None)

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
      ("risk", `String risk_level);
      ("decision", `String decision);
    ] in
    (try Dated_jsonl.append store json
     with _ -> ())

let generate_id () =
  let entropy =
    Printf.sprintf "appr|%d|%.6f|%d"
      (Unix.getpid ()) (Unix.gettimeofday ()) (Random.bits ())
  in
  let digest = Digestif.SHA256.(digest_string entropy |> to_hex) in
  "appr_" ^ String.sub digest 0 12

(* ── Submit & await ───────────────────────────────────────── *)

(** Submit a tool call for approval and suspend the calling fiber.
    Returns the operator's decision when the promise is resolved.
    Called from the OAS approval_callback (inside agent fiber). *)
let submit_and_await ~keeper_name ~tool_name ~input ~risk_level
  : Oas.Hooks.approval_decision =
  let id = generate_id () in
  let promise, resolver = Eio.Promise.create () in
  let entry = {
    id; keeper_name; tool_name; input; risk_level;
    requested_at = Unix.gettimeofday ();
    resolver;
  } in
  Eio.Mutex.use_rw ~protect:true mu (fun () ->
    Hashtbl.replace pending id entry);
  Log.Keeper.info
    "HITL_APPROVAL_PENDING: id=%s keeper=%s tool=%s risk=%s"
    id keeper_name tool_name risk_level;
  audit_approval_event ~event_type:"pending" ~id ~keeper_name
    ~tool_name ~risk_level ();
  (* Broadcast SSE event so dashboard picks it up *)
  (try
     Sse.broadcast
       (`Assoc [
          ("type", `String "approval:pending");
          ("payload", `Assoc [
             ("id", `String id);
             ("keeper_name", `String keeper_name);
             ("tool_name", `String tool_name);
             ("risk_level", `String risk_level);
             ("requested_at", `Float entry.requested_at);
             ("input_preview",
              `String (String.sub
                         (Yojson.Safe.to_string input)
                         0
                         (min 200 (String.length (Yojson.Safe.to_string input)))));
           ]);
        ])
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | _ -> ());
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
       with _ -> ()))

(* ── Resolve (operator action) ────────────────────────────── *)

(** Resolve a pending approval. Returns [Ok ()] if found, [Error msg] if not.
    Called from the command plane HTTP handler. *)
let resolve ~id ~(decision : Oas.Hooks.approval_decision) : (unit, string) result =
  Eio.Mutex.use_rw ~protect:true mu (fun () ->
    match Hashtbl.find_opt pending id with
    | None -> Error (Printf.sprintf "approval %s not found or already resolved" id)
    | Some entry ->
      Hashtbl.remove pending id;
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
      Eio.Promise.resolve entry.resolver decision;
      (* Broadcast resolution *)
      (try
         Sse.broadcast
           (`Assoc [
              ("type", `String "approval:resolved");
              ("payload", `Assoc [
                 ("id", `String id);
                 ("keeper_name", `String entry.keeper_name);
                 ("tool_name", `String entry.tool_name);
                 ("decision", `String decision_str);
               ]);
            ])
       with _ -> ());
      Ok ())

(* ── Query ────────────────────────────────────────────────── *)

(** List all pending approvals as JSON. *)
let list_pending_json () : Yojson.Safe.t =
  Eio.Mutex.use_ro mu (fun () ->
    let entries = Hashtbl.fold (fun _id entry acc ->
      `Assoc [
        ("id", `String entry.id);
        ("keeper_name", `String entry.keeper_name);
        ("tool_name", `String entry.tool_name);
        ("risk_level", `String entry.risk_level);
        ("requested_at", `Float entry.requested_at);
        ("waiting_s", `Float (Unix.gettimeofday () -. entry.requested_at));
      ] :: acc
    ) pending [] in
    `List (List.sort (fun a b ->
      let ts_a = Yojson.Safe.Util.(member "requested_at" a |> to_float) in
      let ts_b = Yojson.Safe.Util.(member "requested_at" b |> to_float) in
      Float.compare ts_a ts_b
    ) entries))

let pending_count () : int =
  Eio.Mutex.use_ro mu (fun () -> Hashtbl.length pending)

(* ── Timeout cleanup ──────────────────────────────────────── *)

(** Reject all approvals that have been waiting longer than [max_wait_s].
    Call periodically from a health loop. *)
let expire_stale ~max_wait_s =
  let now = Unix.gettimeofday () in
  Eio.Mutex.use_rw ~protect:true mu (fun () ->
    let stale = Hashtbl.fold (fun id entry acc ->
      if now -. entry.requested_at > max_wait_s
      then (id, entry) :: acc
      else acc
    ) pending [] in
    List.iter (fun (id, entry) ->
      Hashtbl.remove pending id;
      let reason = Printf.sprintf
        "approval timed out after %.0fs" (now -. entry.requested_at) in
      Log.Keeper.warn "HITL_APPROVAL_EXPIRED: id=%s keeper=%s tool=%s"
        id entry.keeper_name entry.tool_name;
      audit_approval_event ~event_type:"expired" ~id
        ~keeper_name:entry.keeper_name ~tool_name:entry.tool_name
        ~risk_level:entry.risk_level ~decision:("reject:" ^ reason) ();
      Eio.Promise.resolve entry.resolver (Oas.Hooks.Reject reason)
    ) stale)
