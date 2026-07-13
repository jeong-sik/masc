module Keeper_name_set = Set.Make (String)

type block_reason =
  | Recovery_failed
  | Reconciliation_required

type snapshot =
  { base_path : base_path_identity
  ; mode : mode
  }

and mode =
  | Recovered of
      { recovery_failed : Keeper_name_set.t
      ; reconciliation_required : Keeper_name_set.t
      }

and base_path_identity =
  { raw : string
  ; canonical : string
  }

type install_error =
  | Base_path_identity_unavailable of
      { base_path : string
      ; cause : exn
      }

let block_reason_to_wire = function
  | Recovery_failed -> "persistence_recovery_failed"
  | Reconciliation_required -> "persistence_reconciliation_required"
;;

let current : snapshot list Atomic.t = Atomic.make []

let install_error_to_string = function
  | Base_path_identity_unavailable { base_path; cause } ->
    Printf.sprintf
      "persistence admission could not resolve BasePath %S: %s"
      base_path
      (Printexc.to_string cause)
;;

let install ~base_path ~blocked_keeper_names =
  match Fs_compat.realpath base_path with
  | canonical ->
    Atomic.set
      current
      [ { base_path = { raw = base_path; canonical }
        ; mode =
            Recovered
              { recovery_failed = Keeper_name_set.of_list blocked_keeper_names
              ; reconciliation_required = Keeper_name_set.empty
              }
        }
      ];
    Ok ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception ((Unix.Unix_error _ | Sys_error _) as cause) ->
    Error (Base_path_identity_unavailable { base_path; cause })
;;

let block_reason ~base_path ~keeper_name =
  Atomic.get current
  |> List.find_map (fun snapshot ->
    if
      String.equal snapshot.base_path.raw base_path
      || String.equal snapshot.base_path.canonical base_path
    then
      match snapshot.mode with
      | Recovered { recovery_failed; reconciliation_required } ->
        if Keeper_name_set.mem keeper_name recovery_failed
        then Some Recovery_failed
        else if Keeper_name_set.mem keeper_name reconciliation_required
        then Some Reconciliation_required
        else None
    else None)
;;

let block_reconciliation_required ~base_path ~keeper_name =
  let rec update () =
    let before = Atomic.get current in
    let matched, after =
      List.fold_right
        (fun snapshot (matched, snapshots) ->
           if
             String.equal snapshot.base_path.raw base_path
             || String.equal snapshot.base_path.canonical base_path
           then
             match snapshot.mode with
             | Recovered { recovery_failed; reconciliation_required } ->
               ( true
               , { snapshot with
                   mode =
                     Recovered
                       { recovery_failed
                       ; reconciliation_required =
                           Keeper_name_set.add keeper_name reconciliation_required
                       }
                 }
                 :: snapshots )
           else matched, snapshot :: snapshots)
        before
        (false, [])
    in
    let after =
      if matched
      then after
      else
        { base_path = { raw = base_path; canonical = base_path }
        ; mode =
            Recovered
              { recovery_failed = Keeper_name_set.empty
              ; reconciliation_required = Keeper_name_set.singleton keeper_name
              }
        }
        :: after
    in
    if Atomic.compare_and_set current before after then () else update ()
  in
  update ()
;;

let is_blocked ~base_path ~keeper_name =
  Option.is_some (block_reason ~base_path ~keeper_name)
;;

module For_testing = struct
  let clear () = Atomic.set current []
end
