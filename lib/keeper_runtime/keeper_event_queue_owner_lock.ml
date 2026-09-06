(** Per-owner synchronization for durable Keeper event queues. *)

type resolve_error =
  | Invalid_base_path of string
  | Invalid_keeper_name of string

module Owner_key = struct
  type nonrec t = string * Keeper_id.Keeper_name.t

  let equal (left_base, left_name) (right_base, right_name) =
    String.equal left_base right_base
    && Keeper_id.Keeper_name.equal left_name right_name
  ;;

  let hash (base_path, keeper_name) =
    Hashtbl.hash (base_path, Keeper_id.Keeper_name.to_string keeper_name)
  ;;
end

type t =
  { owner_key : Owner_key.t
  ; lock : Cross_context_mutex.t
  }

module Owner_table = Ephemeron.K1.Make (Owner_key)

(* No fleet-size estimate belongs at this boundary; the table grows from its
   implementation-defined minimum as canonical owners are resolved. Ephemeron
   keys let inactive owners disappear without an arbitrary eviction policy;
   every active caller keeps [owner_key] strongly reachable through [t]. *)
let owners : t Owner_table.t = Owner_table.create 0
let owners_mutex = Stdlib.Mutex.create ()

let resolve_error_to_string = function
  | Invalid_base_path reason -> "invalid event-queue base path: " ^ reason
  | Invalid_keeper_name reason -> reason
;;

let canonical_base_path raw =
  Config_dir_resolver.canonical_base_path raw
  |> Result.map_error (fun error ->
    Invalid_base_path
      (Config_dir_resolver.canonical_base_path_error_to_string error))
;;

let resolve ~base_path ~keeper_name =
  match canonical_base_path base_path, Keeper_id.Keeper_name.of_string keeper_name with
  | Error error, _ -> Error error
  | Ok _, Error reason -> Error (Invalid_keeper_name reason)
  | Ok base_path, Ok keeper_name ->
    let key = base_path, keeper_name in
    Ok
      (Stdlib.Mutex.protect owners_mutex (fun () ->
         match Owner_table.find_opt owners key with
         | Some owner -> owner
         | None ->
           Owner_table.clean owners;
           let owner =
             { owner_key = key; lock = Cross_context_mutex.create () }
           in
           Owner_table.add owners key owner;
           owner))
;;

let base_path owner = fst owner.owner_key
let keeper_name owner = snd owner.owner_key

let with_durable_lock owner f = Cross_context_mutex.with_durable_lock owner.lock f
;;
