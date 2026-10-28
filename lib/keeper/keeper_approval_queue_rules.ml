(** Durable, nonblocking HITL queue state and exact Always Allowed rules.

    This module does not classify an effect, interpret an operation name, or
    own a Keeper lane. *)

(** Types, conversions, and JSON serialization extracted to
    [Keeper_approval_queue_rules_types].  State management below. *)

include Keeper_approval_queue_rules_types

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

(* This module used to own an RNG and a mutex to reimplement what [Random_id]
   already provides. Its own entropy source meant the guarantee here was
   whatever [Random.State.make_self_init] gives, separate from the one the
   other 28 call sites rely on. *)
let make_generated_id prefix = prefix ^ "_" ^ Random_id.uuid_v7 ()

(* Rule reads and writes include Eio file operations and are also reached by
   synchronous dashboard/test callers. Both contexts therefore share one
   cross-context authority; writes defer cancellation after acquisition while
   reads remain cancellable. *)
let rules_mutex = Cross_context_mutex.create ()

let with_rules_read_lock f = Cross_context_mutex.with_lock rules_mutex f
let with_rules_write_lock f = Cross_context_mutex.with_durable_lock rules_mutex f

let rules_path ~base_path () =
  Keeper_gate_path.always_allowed ~base_path
;;

let approval_rules_persistence_surface = "keeper_approval_rules"

let report_rules_read_drop ~reason ~path ~detail =
  let reason_wire = Read_drop_reason.to_wire reason in
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_persistence_read_drops
        ~labels:[ "surface", approval_rules_persistence_surface; "reason", reason_wire ]
        ())
    ~surface:approval_rules_persistence_surface
    ~reason
    ~path
    ~detail
;;

let nonempty_string_opt = function
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None
;;

module Application_store = Keeper_approval_rule_application_store

let rule_identity_matches = Application_store.rule_identity_matches

let load_rule_store_unlocked ~base_path () =
  let path = rules_path ~base_path () in
  let rejected reason =
    report_rules_read_drop ~reason:Read_drop_reason.Invalid_payload ~path ~detail:reason;
    Error { path; reason }
  in
  try
    if not (Sys.file_exists path) then Ok Application_store.empty
    else
      match Safe_ops.read_json_file_safe path with
      | Ok json ->
        (match Application_store.of_yojson json with
         | Ok store -> Ok store
         | Error reason -> rejected reason)
      | Error reason ->
        report_rules_read_drop ~reason:Read_drop_reason.Entry_load_error ~path ~detail:reason;
        Error { path; reason }
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let reason = Printexc.to_string exn in
    report_rules_read_drop ~reason:Read_drop_reason.Entry_load_error ~path ~detail:reason;
    Error { path; reason }
;;

let load_rules_unlocked ~base_path () =
  Result.map (fun (store : Application_store.t) -> store.rules)
    (load_rule_store_unlocked ~base_path ())
;;

let save_rule_store_unlocked ~base_path store : (unit, rule_store_error) result =
  let path = rules_path ~base_path () in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    let json = Application_store.to_yojson store in
    match Fs_compat.save_file_atomic path (Yojson.Safe.pretty_to_string json) with
    | Ok () -> Ok ()
    | Error reason -> Error { path; reason }
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error { path; reason = Printexc.to_string exn }
;;

let list_rules ~base_path () =
  with_rules_read_lock (fun () -> load_rules_unlocked ~base_path ())
;;

let list_rules_dashboard_json ~base_path () =
  Result.map
    (fun rules ->
       let rules =
         List.sort (fun left right -> Float.compare right.created_at left.created_at) rules
       in
       `List (List.map approval_rule_to_yojson rules))
    (list_rules ~base_path ())
;;

type rule_upsert_disposition =
  | Created
  | Existing
  | Renewed of { previous_expires_at : float option }

type rule_upsert_result =
  | Applied of { rule : approval_rule; disposition : rule_upsert_disposition }
  | Already_applied of approval_rule option
  | Superseded of approval_rule option

(* Both expiry and approval identity are deliberate inputs. New approvals
   record a witness even at equal expiry; an exact retry never writes again. *)
let upsert_rule_with_save
      ~save
      ~base_path ~keeper_name ~tool_name ~input ?created_by
      ~source_approval_id ~resolution_sequence ~expires_at ()
  =
  with_rules_write_lock (fun () ->
    let application : Application_store.application =
      { approval_id = source_approval_id; resolution_sequence; keeper_name; tool_name
      ; request_fingerprint = Keeper_approval_request_fingerprint.request_fingerprint input
      ; expires_at; actor = created_by }
    in
    let open Result.Syntax in
    let* () = Application_store.validate_application application
      |> Result.map_error (fun reason -> { path = rules_path ~base_path (); reason }) in
    let* store = load_rule_store_unlocked ~base_path () in
    match Application_store.find_application store ~approval_id:source_approval_id with
    | Some receipt ->
      if Application_store.same_application application receipt.application then
        let rule = List.find_opt
          (fun (rule : approval_rule) -> String.equal rule.id receipt.rule_id) store.rules in
        Ok (match receipt.settlement with
          | Application_store.Rule_applied -> Already_applied rule
          | Application_store.Superseded -> Superseded rule)
      else Error
        { path = rules_path ~base_path ()
        ; reason = "remembered approval application identity conflicts with its durable receipt" }
    | None ->
      if List.exists (fun (receipt : Application_store.receipt) ->
          Int.equal receipt.application.resolution_sequence resolution_sequence)
          store.applications
      then Error { path = rules_path ~base_path (); reason = "resolution sequence belongs to another approval" }
      else
      let persist ~rule_id ~settlement outcome rules =
        let receipt : Application_store.receipt = { application; rule_id; settlement } in
        let next = { Application_store.rules; applications = receipt :: store.applications } in
        match save ~base_path next with
        | Ok () -> Ok outcome
        | Error error ->
          Otel_metric_store.inc_counter Keeper_metrics.(to_string ApprovalQueueFailures)
            ~labels:[ "keeper", keeper_name
                    ; "site", Keeper_approval_queue_failure_site.(to_label Upsert_rule_save) ] ();
          Log.Keeper.warn "upsert_rule: save failed: %s" (rule_store_error_to_string error);
          Error error
      in
      match Application_store.latest_application store application with
      | Some latest when latest.application.resolution_sequence > resolution_sequence ->
        let rule = List.find_opt
          (fun (rule : approval_rule) -> String.equal rule.id latest.rule_id) store.rules in
        persist ~rule_id:latest.rule_id ~settlement:Application_store.Superseded
          (Superseded rule) store.rules
      | Some _ | None ->
      let candidate =
        { id = make_generated_id "rule"; keeper_name; tool_name
        ; request_fingerprint = application.request_fingerprint
        ; created_at = Unix.gettimeofday (); created_by
        ; source_approval_id = Some source_approval_id; expires_at }
      in
      let persist rule disposition rules =
        persist ~rule_id:rule.id ~settlement:Application_store.Rule_applied
          (Applied { rule; disposition }) rules
      in
      match List.find_opt (fun rule -> rule_identity_matches rule candidate) store.rules with
      | Some existing when Option.equal Float.equal existing.expires_at expires_at ->
        persist existing Existing store.rules
      | Some existing ->
        let rule = { existing with expires_at } in
        let rules = List.map
          (fun previous -> if String.equal previous.id existing.id then rule else previous)
          store.rules in
        persist rule (Renewed { previous_expires_at = existing.expires_at }) rules
      | None -> persist candidate Created (candidate :: store.rules))
;;

let upsert_rule
      ~base_path ~keeper_name ~tool_name ~input ?created_by
      ~source_approval_id ~resolution_sequence ~expires_at ()
  =
  upsert_rule_with_save ~save:save_rule_store_unlocked
    ~base_path ~keeper_name ~tool_name ~input ?created_by
    ~source_approval_id ~resolution_sequence ~expires_at ()
;;

module For_testing = struct
  let upsert_rule_with_save = upsert_rule_with_save
  let save_rule_store = save_rule_store_unlocked
end

let delete_rule ~base_path ~id () =
  with_rules_write_lock (fun () ->
    match load_rule_store_unlocked ~base_path () with
    | Error _ as error -> error
    | Ok store ->
      (match List.find_opt (fun rule -> String.equal rule.id id) store.rules with
       | None ->
         Error
           { path = rules_path ~base_path ()
           ; reason = Printf.sprintf "approval rule %s not found" id
           }
       | Some deleted ->
         let rules = List.filter (fun rule -> not (String.equal rule.id id)) store.rules in
         (match save_rule_store_unlocked ~base_path { store with rules } with
          | Ok () -> Ok deleted
          | Error _ as error -> error)))
;;

let find_matching_rule
      ~base_path
      ~keeper_name
      ~tool_name
      ~input
      (* NDT-OK: wall-clock default at this store I/O boundary; callers inject ~now. *)
      ?(now = Unix.gettimeofday ())
      ()
  =
  with_rules_read_lock (fun () ->
    match load_rules_unlocked ~base_path () with
    | Error _ as error -> error
    | Ok rules ->
      let request_fingerprint =
        Keeper_approval_request_fingerprint.request_fingerprint input
      in
      (match
         List.find_opt
           (fun rule ->
              String.equal rule.keeper_name keeper_name
              && String.equal rule.tool_name tool_name
              && String.equal rule.request_fingerprint request_fingerprint)
           rules
       with
       | None -> Ok Rule_match_absent
       | Some rule ->
         let matched = { rule_id = rule.id } in
         if rule_expired ~now rule
         then Ok (Rule_match_expired matched)
         else Ok (Rule_match_active matched)))
;;
