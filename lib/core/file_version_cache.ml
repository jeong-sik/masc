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
  ; (* [forget] calls so far. A decode keeps its value only when none ran
       while it decoded: a [forget] stands for a write the version may not
       show, and the decode may have read the file from before it. The count
       covers every path, so a write to one file also stops keeping a decode
       of another that runs at the same moment; writes are rare next to
       reads, and that costs one more decode. *)
    mutable forgets : int
  ; mutex : Mutex.t
  }

let create () = { entries = Hashtbl.create 1; forgets = 0; mutex = Mutex.create () }

let kept t path =
  Mutex.protect t.mutex (fun () -> Hashtbl.find_opt t.entries path, t.forgets)
;;

(* A value a [forget] stopped from being kept still says which version this
   decode saw. An entry kept for another version goes too, as a keep would
   have replaced it: left in place, a file that later returned to that
   version with other bytes, through a writer that never forgets, would be
   answered from it. The entry may instead be newer than this decode, kept
   by a reader that started after the [forget]; the next read then decodes
   again. An entry for the same version stays: a decode no [forget]
   interrupted kept it, after the last [forget] of [path]. *)
let keep t path entry ~forgets_before =
  Mutex.protect t.mutex (fun () ->
    if t.forgets = forgets_before
    then Hashtbl.replace t.entries path entry
    else
      match Hashtbl.find_opt t.entries path with
      | Some kept when not (same_version kept.decoded_from entry.decoded_from) ->
        Hashtbl.remove t.entries path
      | Some _ | None -> ())
;;

let forget t path =
  Mutex.protect t.mutex (fun () ->
    Hashtbl.remove t.entries path;
    t.forgets <- t.forgets + 1)
;;

let load t path ~decode =
  let current = version_of_path path in
  let held, forgets_before = kept t path in
  match held, current with
  | Some entry, Some version when same_version entry.decoded_from version -> Ok entry.value
  | (Some _ | None), (Some _ | None) ->
    let decoded = decode () in
    (match decoded, current, version_of_path path with
     | Ok value, Some before, Some after when same_version before after ->
       keep t path { decoded_from = after; value } ~forgets_before
     | (Ok _ | Error _), (Some _ | None), (Some _ | None) -> ());
    decoded
;;
