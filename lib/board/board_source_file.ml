open Board_types

type refusal =
  | Not_refused
  | Read_again
  | Read_again_once_changed of Source_file.seen

let entry path : Source_file.entry =
  match Unix.lstat path with
  | stat ->
    Present
      { kind = stat.Unix.st_kind
      ; permissions = stat.Unix.st_perm
      ; device = stat.Unix.st_dev
      ; inode = stat.Unix.st_ino
      ; size = stat.Unix.st_size
      ; modified = stat.Unix.st_mtime
      ; links = stat.Unix.st_nlink
      }
  | exception Unix.Unix_error (error, _, _) ->
    if error = Unix.ENOENT then Absent else Uninspected error

let inspect ~path : Source_file.entries =
  Fs_compat.Systhread_host.run ~label:"board-source-file" (fun () ->
    { Source_file.data = entry path; lock = entry (Fs_compat.private_jsonl_lock_path path) })

let same_entry (left : Source_file.entry) (right : Source_file.entry) =
  match left, right with
  | Absent, Absent -> true
  | Present left, Present right ->
    left.kind = right.kind
    && Int.equal left.permissions right.permissions
    && Int.equal left.device right.device
    && Int.equal left.inode right.inode
    && Int.equal left.size right.size
    && Float.equal left.modified right.modified
    && Int.equal left.links right.links
  | Uninspected left, Uninspected right -> left = right
  | Absent, (Present _ | Uninspected _)
  | Present _, (Absent | Uninspected _)
  | Uninspected _, (Absent | Present _) -> false

let same (left : Source_file.entries) (right : Source_file.entries) =
  same_entry left.data right.data && same_entry left.lock right.lock

let changed_since (seen : Source_file.seen) ~path =
  match seen with
  | Unread -> true
  | Read_at before -> not (same before (inspect ~path))

let same_seen (left : Source_file.seen) (right : Source_file.seen) =
  match left, right with
  | Unread, Unread -> true
  | Read_at left, Read_at right -> same left right
  | Unread, Read_at _ | Read_at _, Unread -> false

let still_due ~asked now =
  match asked, now with
  | (Read_again | Read_again_once_changed _), Read_again -> true
  | Read_again_once_changed asked, Read_again_once_changed now -> same_seen asked now
  | Read_again, Read_again_once_changed _
  | (Read_again | Read_again_once_changed _), Not_refused
  | Not_refused, (Not_refused | Read_again | Read_again_once_changed _) -> false
