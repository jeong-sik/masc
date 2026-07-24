module Persistence = Keeper_event_queue_persistence

module Owner_identity = struct
  type t = Persistence.owner_identity

  let equal = Persistence.owner_identity_equal
  let hash = Persistence.owner_identity_hash
end

module Owner_claims = Hashtbl.Make (Owner_identity)

type projection_outcome =
  | No_pending_transition
  | Transition_converged
  | Claim_busy

type projection_error =
  | Owner_unavailable of Persistence.owner_identity_error
  | Outbox_unavailable of string
  | Ledger_projection_failed of string
  | Unexpected_projection_failure of Eio.Exn.with_bt

type discovery_error = Snapshot_discovery_failed of string

type owner_failure =
  { keeper_name : string
  ; error : projection_error
  }

type sweep_report =
  { discovered : int
  ; no_pending : int
  ; converged : int
  ; claim_busy : int
  ; failures : owner_failure list
  ; discovery_error : discovery_error option
  }

let projection_error_to_string = function
  | Owner_unavailable error ->
    Persistence.owner_identity_error_to_string error
  | Outbox_unavailable detail ->
    "event queue transition outbox unavailable: " ^ detail
  | Ledger_projection_failed detail ->
    "event queue transition ledger projection failed: " ^ detail
  | Unexpected_projection_failure (exn, backtrace) ->
    Printf.sprintf
      "event queue transition projection raised: %s\n%s"
      (Printexc.to_string exn)
      (Printexc.raw_backtrace_to_string backtrace)
;;

let discovery_error_to_string (Snapshot_discovery_failed detail) =
  "event queue snapshot discovery failed: " ^ detail
;;

let owner_claims = Owner_claims.create 16
let owner_claims_mutex = Mutex.create ()

let with_owner_claims_lock f =
  Mutex.lock owner_claims_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock owner_claims_mutex) f
;;

let try_acquire_owner_claim owner =
  with_owner_claims_lock (fun () ->
    if Owner_claims.mem owner_claims owner
    then false
    else (
      Owner_claims.add owner_claims owner ();
      true))
;;

let release_owner_claim owner =
  with_owner_claims_lock (fun () -> Owner_claims.remove owner_claims owner)
;;

type 'a owner_claim_outcome =
  | Owner_claim_acquired of 'a
  | Owner_claim_busy

let with_owner_claim owner f =
  if not (try_acquire_owner_claim owner)
  then Owner_claim_busy
  else
    Fun.protect
      ~finally:(fun () -> release_owner_claim owner)
      (fun () -> Owner_claim_acquired (f ()))
;;

let project_claimed_owner owner =
  let base_path = Persistence.owner_identity_base_path owner in
  let keeper_name = Persistence.owner_identity_keeper_name owner in
  match
    Persistence.transition_outbox_result
      ~base_path
      ~keeper_name
  with
  | Error detail -> Error (Outbox_unavailable detail)
  | Ok [] -> Ok No_pending_transition
  | Ok (_ :: _) ->
    (match
       Keeper_reaction_ledger.project_event_queue_transition_outbox_result
         ~base_path
         ~keeper_name
     with
     | Ok () -> Ok Transition_converged
     | Error detail -> Error (Ledger_projection_failed detail))
;;

let project_resolved_owner owner =
  match
    with_owner_claim owner (fun () ->
      try project_claimed_owner owner with
      | Eio.Cancel.Cancelled _ as exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        Printexc.raise_with_backtrace exn backtrace
      | exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        Error (Unexpected_projection_failure (exn, backtrace)))
  with
  | Owner_claim_busy -> Ok Claim_busy
  | Owner_claim_acquired result -> result
;;

let project_owner_result ~base_path ~keeper_name =
  match Persistence.resolve_owner_identity ~base_path ~keeper_name with
  | Error error -> Error (Owner_unavailable error)
  | Ok owner -> project_resolved_owner owner
;;

let project_discovered ~base_path =
  let discovery =
    Keeper_event_queue_persistence.discover_keeper_names_with_snapshots
      ~base_path
  in
  let initial =
    { discovered = List.length discovery.keeper_names
    ; no_pending = 0
    ; converged = 0
    ; claim_busy = 0
    ; failures = []
    ; discovery_error =
        Option.map
          (fun detail -> Snapshot_discovery_failed detail)
          discovery.read_error
    }
  in
  let report =
    List.fold_left
      (fun report keeper_name ->
         match project_owner_result ~base_path ~keeper_name with
         | Ok No_pending_transition ->
           { report with no_pending = report.no_pending + 1 }
         | Ok Transition_converged ->
           { report with converged = report.converged + 1 }
         | Ok Claim_busy ->
           { report with claim_busy = report.claim_busy + 1 }
         | Error error ->
           { report with
             failures = { keeper_name; error } :: report.failures
           })
      initial
      discovery.keeper_names
  in
  { report with failures = List.rev report.failures }
;;

module For_testing = struct
  type 'a claim_outcome =
    | Claim_acquired of 'a
    | Claim_already_held

  let with_owner_claim ~base_path ~keeper_name f =
    match Persistence.resolve_owner_identity ~base_path ~keeper_name with
    | Error error -> Error (Owner_unavailable error)
    | Ok owner ->
      (match with_owner_claim owner f with
       | Owner_claim_busy -> Ok Claim_already_held
       | Owner_claim_acquired value -> Ok (Claim_acquired value))
  ;;
end
