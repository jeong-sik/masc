(* See .mli. *)

type version =
  { device : int
  ; inode : int
  ; size : int
  ; mtime : float
  }

let version_of_path path =
  match Unix.stat path with
  | stats ->
    Some
      { device = stats.Unix.st_dev
      ; inode = stats.Unix.st_ino
      ; size = stats.Unix.st_size
      ; mtime = stats.Unix.st_mtime
      }
  | exception Unix.Unix_error _ -> None
;;

let same_version left right =
  left.device = right.device
  && left.inode = right.inode
  && left.size = right.size
  && Float.equal left.mtime right.mtime
;;

type 'a entry =
  { decoded_from : version
  ; value : 'a
  }

type 'a t =
  { entries : (string, 'a entry) Hashtbl.t
  ; mutex : Mutex.t
  }

let create () = { entries = Hashtbl.create 1; mutex = Mutex.create () }
let kept t path = Mutex.protect t.mutex (fun () -> Hashtbl.find_opt t.entries path)
let keep t path entry = Mutex.protect t.mutex (fun () -> Hashtbl.replace t.entries path entry)
let forget t path = Mutex.protect t.mutex (fun () -> Hashtbl.remove t.entries path)

let load t path ~decode =
  let current = version_of_path path in
  match kept t path, current with
  | Some entry, Some version when same_version entry.decoded_from version -> Ok entry.value
  | (Some _ | None), (Some _ | None) ->
    let decoded = decode () in
    (match decoded, current, version_of_path path with
     | Ok value, Some before, Some after when same_version before after ->
       keep t path { decoded_from = after; value }
     | (Ok _ | Error _), (Some _ | None), (Some _ | None) -> ());
    decoded
;;
