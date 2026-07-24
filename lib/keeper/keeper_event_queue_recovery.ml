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

type owner_budget_error = Invalid_owner_budget of int
type owner_budget = Owner_budget of int
type sweep_cursor = Sweep_cursor of string option

type owner_projection =
  { keeper_name : string
  ; outcome : (projection_outcome, projection_error) result
  }

type sweep_report =
  { discovered : int
  ; processed : int
  ; deferred : int
  ; no_pending : int
  ; converged : int
  ; claim_busy : int
  ; projections : owner_projection list
  ; failures : owner_failure list
  ; discovery_error : discovery_error option
  }

type sweep_page =
  { report : sweep_report
  ; next_cursor : sweep_cursor
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

let owner_budget_error_to_string (Invalid_owner_budget max_owners) =
  Printf.sprintf
    "event queue transition projection owner budget must be positive (got %d)"
    max_owners
;;

let owner_budget ~max_owners =
  if max_owners > 0
  then Ok (Owner_budget max_owners)
  else Error (Invalid_owner_budget max_owners)
;;

let initial_sweep_cursor = Sweep_cursor None

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
    Persistence.load_state_result
      ~base_path
      ~keeper_name
  with
  | Error detail -> Error (Outbox_unavailable detail)
  | Ok state ->
    (match Keeper_event_queue_state.transition_outbox state with
     | [] -> Ok No_pending_transition
     | _ :: _ ->
       (match
          Keeper_reaction_ledger.project_event_queue_transition_outbox_result
            ~base_path
            ~keeper_name
        with
        | Ok () -> Ok Transition_converged
        | Error detail -> Error (Ledger_projection_failed detail)))
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

let project_owner_result_inline ~base_path ~keeper_name =
  match Persistence.resolve_owner_identity ~base_path ~keeper_name with
  | Error error -> Error (Owner_unavailable error)
  | Ok owner -> project_resolved_owner owner
;;

let project_owner_result ~base_path ~keeper_name =
  Executor_pool_ref.submit_or_inline (fun () ->
    project_owner_result_inline ~base_path ~keeper_name)
;;

let ordered_owner_page ~budget:(Owner_budget max_owners) ~cursor:(Sweep_cursor cursor) names =
  let names = List.sort_uniq String.compare names in
  let ordered =
    match cursor with
    | None -> names
    | Some after ->
      let later, earlier =
        List.partition (fun keeper_name -> String.compare keeper_name after > 0) names
      in
      later @ earlier
  in
  let rec take remaining acc = function
    | _ when remaining = 0 -> List.rev acc
    | [] -> List.rev acc
    | keeper_name :: rest -> take (remaining - 1) (keeper_name :: acc) rest
  in
  let selected = take max_owners [] ordered in
  let deferred = List.length names - List.length selected in
  let next_cursor =
    if deferred = 0
    then initial_sweep_cursor
    else
      match List.rev selected with
      | [] -> initial_sweep_cursor
      | keeper_name :: _ -> Sweep_cursor (Some keeper_name)
  in
  names, selected, deferred, next_cursor
;;

let project_discovery_inline
    ~base_path
    ~budget
    ~cursor
    (discovery : Persistence.snapshot_discovery) =
  let names, selected, deferred, next_cursor =
    ordered_owner_page ~budget ~cursor discovery.keeper_names
  in
  let initial =
    { discovered = List.length names
    ; processed = List.length selected
    ; deferred
    ; no_pending = 0
    ; converged = 0
    ; claim_busy = 0
    ; projections = []
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
         let outcome = project_owner_result_inline ~base_path ~keeper_name in
         let report =
           { report with
             projections = { keeper_name; outcome } :: report.projections
           }
         in
         match outcome with
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
      selected
  in
  { report =
      { report with
        projections = List.rev report.projections
      ; failures = List.rev report.failures
      }
  ; next_cursor
  }
;;

let project_discovered_bounded ~base_path ~budget ~cursor =
  Executor_pool_ref.submit_or_inline (fun () ->
    let discovery =
      Keeper_event_queue_persistence.discover_keeper_names_with_snapshots
        ~base_path
    in
    project_discovery_inline ~base_path ~budget ~cursor discovery)
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

  let pending_transition_count_result ~base_path ~keeper_name =
    match Persistence.resolve_owner_identity ~base_path ~keeper_name with
    | Error error -> Error (Owner_unavailable error)
    | Ok owner ->
      let base_path = Persistence.owner_identity_base_path owner in
      let keeper_name = Persistence.owner_identity_keeper_name owner in
      (match Persistence.load_state_result ~base_path ~keeper_name with
       | Ok state ->
         Ok (List.length (Keeper_event_queue_state.transition_outbox state))
       | Error detail -> Error (Outbox_unavailable detail))
  ;;
end
