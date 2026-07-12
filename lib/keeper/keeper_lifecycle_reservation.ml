module StringMap = Set_util.StringMap

type purpose = Keeper_registry_types.lifecycle_transaction_purpose = Dead_revival

type snapshot = Keeper_registry_types.lifecycle_reservation_snapshot =
  { owner_id : string
  ; expected_generation : int
  ; purpose : purpose
  }

type token =
  { key : string
  ; base_path : string
  ; keeper_name : string
  ; snapshot : snapshot
  }

type acquire_error = Already_reserved of snapshot

type release_outcome =
  | Released
  | Release_missing
  | Release_not_owner of snapshot

let reservations : snapshot StringMap.t Atomic.t = Atomic.make StringMap.empty
let key_locks : Mutex.t StringMap.t Atomic.t = Atomic.make StringMap.empty

let purpose_to_string = function
  | Dead_revival -> "dead_revival"
;;

let snapshot_to_string snapshot =
  Printf.sprintf
    "owner=%s expected_generation=%d purpose=%s"
    snapshot.owner_id
    snapshot.expected_generation
    (purpose_to_string snapshot.purpose)
;;

let canonical_key ~base_path ~keeper_name =
  Keeper_registry_types.registry_key ~base_path (String.trim keeper_name)
;;

let lock_for_key key =
  let rec loop () =
    let current = Atomic.get key_locks in
    match StringMap.find_opt key current with
    | Some lock -> lock
    | None ->
      let lock = Mutex.create () in
      let updated = StringMap.add key lock current in
      if Atomic.compare_and_set key_locks current updated then lock else loop ()
  in
  loop ()
;;

let with_key_lock ~base_path ~keeper_name f =
  let key = canonical_key ~base_path ~keeper_name in
  Mutex.protect (lock_for_key key) f
;;

let acquire ~base_path ~keeper_name ~expected_generation ~purpose =
  let base_path = Keeper_registry_types.canonical_base_path_exn base_path in
  let keeper_name = String.trim keeper_name in
  let key = canonical_key ~base_path ~keeper_name in
  let snapshot =
    { owner_id = Keeper_id.Uid.(generate () |> to_string)
    ; expected_generation
    ; purpose
    }
  in
  with_key_lock ~base_path ~keeper_name (fun () ->
    let current = Atomic.get reservations in
    match StringMap.find_opt key current with
    | Some owner -> Error (Already_reserved owner)
    | None ->
      Atomic.set reservations (StringMap.add key snapshot current);
      Ok { key; base_path; keeper_name; snapshot })
;;

let token_owns_current token current =
  String.equal token.snapshot.owner_id current.owner_id
  && Int.equal token.snapshot.expected_generation current.expected_generation
  && token.snapshot.purpose = current.purpose
;;

let authorize ?token ~base_path ~keeper_name () =
  let key = canonical_key ~base_path ~keeper_name in
  match StringMap.find_opt key (Atomic.get reservations) with
  | None -> Ok ()
  | Some current ->
    (match token with
     | Some token when String.equal token.key key && token_owns_current token current -> Ok ()
     | Some _ | None -> Error current)
;;

let owner_id token = token.snapshot.owner_id
let expected_generation token = token.snapshot.expected_generation

let release token =
  with_key_lock ~base_path:token.base_path ~keeper_name:token.keeper_name (fun () ->
    let current = Atomic.get reservations in
    match StringMap.find_opt token.key current with
    | None -> Release_missing
    | Some owner when not (token_owns_current token owner) -> Release_not_owner owner
    | Some _ ->
      Atomic.set reservations (StringMap.remove token.key current);
      Released)
;;

let current ~base_path ~keeper_name =
  StringMap.find_opt
    (canonical_key ~base_path ~keeper_name)
    (Atomic.get reservations)
;;
