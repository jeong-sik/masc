type key =
  { parent_dev : int64
  ; parent_ino : int64
  ; leaf : Capability_leaf.t
  }

module Key = struct
  type t = key

  let equal left right =
    Int64.equal left.parent_dev right.parent_dev
    && Int64.equal left.parent_ino right.parent_ino
    && Capability_leaf.equal left.leaf right.leaf
  ;;

  let hash key =
    Hashtbl.hash
      ( key.parent_dev
      , key.parent_ino
      , Capability_leaf.to_string key.leaf )
  ;;
end

module Table = Hashtbl.Make (Key)

type entry =
  { held : bool Atomic.t
  ; mutable users : int
  }

type t =
  { key : key
  ; entry : entry
  ; released : bool Atomic.t
  }

let registry_mutex = Stdlib.Mutex.create ()
let registry = Table.create 0

let release_user key entry =
  Stdlib.Mutex.protect registry_mutex (fun () ->
    entry.users <- entry.users - 1;
    if entry.users = 0
    then
      match Table.find_opt registry key with
      | Some current when current == entry -> Table.remove registry key
      | Some _ | None -> ())
;;

let try_acquire ~parent_dev ~parent_ino ~leaf =
  let key = { parent_dev; parent_ino; leaf } in
  let entry =
    Stdlib.Mutex.protect registry_mutex (fun () ->
      match Table.find_opt registry key with
      | Some entry ->
        entry.users <- entry.users + 1;
        entry
      | None ->
        let entry = { held = Atomic.make false; users = 1 } in
        Table.add registry key entry;
        entry)
  in
  if Atomic.compare_and_set entry.held false true
  then Some { key; entry; released = Atomic.make false }
  else (
    release_user key entry;
    None)
;;

let release lease =
  if Atomic.compare_and_set lease.released false true
  then (
    Atomic.set lease.entry.held false;
    release_user lease.key lease.entry)
  else invalid_arg "capability mutation lease released more than once"
;;
