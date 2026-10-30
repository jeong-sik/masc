type key =
  | Existing_target of
      { target_dev : int64
      ; target_ino : int64
      ; parent_dev : int64
      ; parent_ino : int64
      }
  | Absent_target_parent of
      { parent_dev : int64
      ; parent_ino : int64
      }
  | Existing_publication_parent of
      { parent_dev : int64
      ; parent_ino : int64
      }

module Identity = struct
  type t = int64 * int64

  let equal (left_dev, left_ino) (right_dev, right_ino) =
    Int64.equal left_dev right_dev && Int64.equal left_ino right_ino
  ;;

  let hash = Hashtbl.hash
end

module Identity_table = Hashtbl.Make (Identity)

type t =
  { key : key
  ; mutable released : bool
  }

let registry_mutex = Stdlib.Mutex.create ()
let existing_targets = Identity_table.create 0
let absent_target_parents = Identity_table.create 0
let existing_publication_counts = Identity_table.create 0

let identity ~dev ~ino = dev, ino

let existing_publication_count parent =
  Option.value (Identity_table.find_opt existing_publication_counts parent) ~default:0
;;

let increment_existing_publication_count parent =
  let count = existing_publication_count parent in
  if count = max_int
  then invalid_arg "capability mutation publication count overflow"
  else Identity_table.replace existing_publication_counts parent (count + 1)
;;

let decrement_existing_publication_count parent =
  match Identity_table.find_opt existing_publication_counts parent with
  | Some 1 -> Identity_table.remove existing_publication_counts parent
  | Some count when count > 1 ->
    Identity_table.replace existing_publication_counts parent (count - 1)
  | Some _ | None ->
    invalid_arg "capability mutation publication count invariant lost"
;;

let try_acquire key =
  Stdlib.Mutex.protect registry_mutex (fun () ->
    match key with
    | Existing_target
        { target_dev; target_ino; parent_dev; parent_ino } ->
      let target = identity ~dev:target_dev ~ino:target_ino in
      let parent = identity ~dev:parent_dev ~ino:parent_ino in
      if
        Identity_table.mem absent_target_parents parent
        || Identity_table.mem existing_targets target
      then None
      else (
        Identity_table.add existing_targets target ();
        Some { key; released = false })
    | Absent_target_parent { parent_dev; parent_ino } ->
      let parent = identity ~dev:parent_dev ~ino:parent_ino in
      if
        Identity_table.mem absent_target_parents parent
        || existing_publication_count parent > 0
      then None
      else (
        Identity_table.add absent_target_parents parent ();
        Some { key; released = false })
    | Existing_publication_parent { parent_dev; parent_ino } ->
      let parent = identity ~dev:parent_dev ~ino:parent_ino in
      if Identity_table.mem absent_target_parents parent
      then None
      else (
        increment_existing_publication_count parent;
        Some { key; released = false }))
;;

let release lease =
  Stdlib.Mutex.protect registry_mutex (fun () ->
    if lease.released
    then invalid_arg "capability mutation lease released more than once"
    else
      match lease.key with
      | Existing_target { target_dev; target_ino; _ } ->
        let target = identity ~dev:target_dev ~ino:target_ino in
        if not (Identity_table.mem existing_targets target)
        then invalid_arg "capability mutation lease target invariant lost"
        else (
          Identity_table.remove existing_targets target;
          lease.released <- true)
      | Absent_target_parent { parent_dev; parent_ino } ->
        let parent = identity ~dev:parent_dev ~ino:parent_ino in
        if not (Identity_table.mem absent_target_parents parent)
        then invalid_arg "capability mutation lease parent invariant lost"
        else (
          Identity_table.remove absent_target_parents parent;
          lease.released <- true)
      | Existing_publication_parent { parent_dev; parent_ino } ->
        let parent = identity ~dev:parent_dev ~ino:parent_ino in
        decrement_existing_publication_count parent;
        lease.released <- true)
;;
