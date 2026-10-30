(* The caller owns the queue transaction lock. Ordinary readers only need to
   inspect the journal entry: decoding it is reserved for explicit recovery. *)
open Result.Syntax
let filename = "event-queue-quarantine-v1.json"
let path ~snapshot = Filename.concat (Filename.dirname snapshot) filename

type slot = Snapshot | Transition_wal

type identity =
  { device : int
  ; inode : int
  ; kind : Unix.file_kind
  ; payload : string option
  }

type entry = Absent | Present of { destination : string; identity : identity }
type t = { rejected : slot; snapshot_entry : entry; wal_entry : entry }
type moved = { path : string; rejected_path : string; moved_with : (string * string) option }

let capture f =
  try Ok (f ()) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let stat path =
  match Unix.lstat path with
  | value -> Ok (Some value)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exception (Unix.Unix_error _ as exn) -> Error (Printexc.to_string exn)
;;

type guard_failure =
  | Intent_present of string
  | Inspection_failed of string

let guard_failure_to_string = function
  | Intent_present intent ->
    Printf.sprintf
      "event queue quarantine is incomplete at %s; queue access is refused; resume with explicit store quarantine or repair the recorded entries" intent
  | Inspection_failed detail -> detail
;;

let guard ~snapshot =
  let intent = path ~snapshot in
  match stat intent with
  | Error detail -> Error (Inspection_failed detail)
  | Ok None -> Ok ()
  | Ok (Some _) -> Error (Intent_present intent)
;;

let same_stat (a : Unix.stats) (b : Unix.stats) =
  a.st_dev = b.st_dev && a.st_ino = b.st_ino && a.st_kind = b.st_kind
  && a.st_size = b.st_size && Float.equal a.st_mtime b.st_mtime
  && Float.equal a.st_ctime b.st_ctime
;;

let identity path =
  let* before = stat path in
  match before with
  | None -> Ok None
  | Some before ->
    let* payload = capture (fun () ->
      match before.Unix.st_kind with
      | Unix.S_REG ->
        Some (Fs_compat.load_file path |> Agent_core_sha256.digest_string |> Agent_core_sha256.to_hex)
      | Unix.S_LNK -> Some (Unix.readlink path)
      | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> None)
    in
    let* after = stat path in
    (match after with
     | Some after when same_stat before after ->
       Ok (Some {device=before.st_dev; inode=before.st_ino; kind=before.st_kind; payload})
     | None | Some _ -> Error ("queue quarantine entry changed while being read: " ^ path))
;;

let kind_to_string = function
  | Unix.S_REG -> "regular" | Unix.S_LNK -> "link" | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character" | Unix.S_BLK -> "block" | Unix.S_FIFO -> "fifo"
  | Unix.S_SOCK -> "socket"
;;

let invalid = Error "invalid event queue quarantine intent"
let object_fields keys = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare keys -> Ok fields
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> invalid
;;
let field fields name = List.assoc name fields
let string = function
  | `String s -> Ok s
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ -> invalid
;;
let integer = function
  | `Int n -> Ok n
  | `Assoc _ | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `List _ -> invalid
;;
let kind_of_json json =
  let* value = string json in
  match value with
  | "regular" -> Ok Unix.S_REG | "link" -> Ok Unix.S_LNK | "directory" -> Ok Unix.S_DIR
  | "character" -> Ok Unix.S_CHR | "block" -> Ok Unix.S_BLK | "fifo" -> Ok Unix.S_FIFO
  | "socket" -> Ok Unix.S_SOCK | _ -> invalid
;;
let identity_to_json i =
  `Assoc ["device", `Int i.device; "inode", `Int i.inode;
          "kind", `String (kind_to_string i.kind);
          "payload", (match i.payload with None -> `Null | Some s -> `String s)]
;;
let identity_of_json json =
  let* fs = object_fields ["device";"inode";"kind";"payload"] json in
  let* device = integer (field fs "device") in
  let* inode = integer (field fs "inode") in
  let* kind = kind_of_json (field fs "kind") in
  let* payload = match kind, field fs "payload" with
    | (Unix.S_REG | Unix.S_LNK), `String value -> Ok (Some value)
    | (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK), `Null -> Ok None
    | (Unix.S_REG | Unix.S_LNK | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK),
      (`Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) -> invalid
  in
  Ok {device; inode; kind; payload}
;;

let valid_destination source destination =
  String.equal (Filename.dirname source) (Filename.dirname destination)
  && String.starts_with ~prefix:(Filename.basename source ^ ".rejected-") (Filename.basename destination)
  && not (String.contains (Filename.basename destination) '\000')
;;

let entry_to_json = function
  | Absent -> `Null
  | Present {destination; identity} ->
    `Assoc ["destination", `String destination; "identity", identity_to_json identity]
;;
let entry_of_json source = function
  | `Null -> Ok Absent
  | (`Assoc _ | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as json ->
    let* fs = object_fields ["destination";"identity"] json in
    let* destination = string (field fs "destination") in
    let* identity = identity_of_json (field fs "identity") in
    if valid_destination source destination then Ok (Present {destination; identity}) else invalid
;;
let to_json ~snapshot ~wal t =
  `Assoc ["schema", `String "masc.event_queue.quarantine.v1";
          "snapshot_path", `String snapshot; "wal_path", `String wal;
          "rejected", `String (match t.rejected with Snapshot -> "snapshot" | Transition_wal -> "wal");
          "snapshot", entry_to_json t.snapshot_entry; "wal", entry_to_json t.wal_entry]
;;
let of_json ~snapshot ~wal json =
  let* fs = object_fields ["schema";"snapshot_path";"wal_path";"rejected";"snapshot";"wal"] json in
  let* schema = string (field fs "schema") in
  let* snapshot_path = string (field fs "snapshot_path") in
  let* wal_path = string (field fs "wal_path") in
  if not (String.equal schema "masc.event_queue.quarantine.v1"
          && String.equal snapshot snapshot_path && String.equal wal wal_path) then invalid else
  let* rejected_wire = string (field fs "rejected") in
  let* rejected = match rejected_wire with
    | "snapshot" -> Ok Snapshot | "wal" -> Ok Transition_wal | _ -> invalid in
  let* snapshot_entry = entry_of_json snapshot (field fs "snapshot") in
  let* wal_entry = entry_of_json wal (field fs "wal") in
  match rejected, snapshot_entry, wal_entry with
  | Snapshot, Present _, (Absent | Present _)
  | Transition_wal, (Absent | Present _), Present _ -> Ok {rejected; snapshot_entry; wal_entry}
  | Snapshot, Absent, (Absent | Present _) | Transition_wal, (Absent | Present _), Absent -> invalid
;;

let read ~snapshot ~wal =
  let intent = path ~snapshot in
  let* before = stat intent in
  match before with
  | None -> Ok None
  | Some before ->
    if before.Unix.st_kind <> Unix.S_REG || before.st_perm land 0o077 <> 0 || before.st_nlink <> 1
    then Error ("queue quarantine intent must be a private regular entry: " ^ intent)
    else
      let* json = capture (fun () -> Yojson.Safe.from_string (Fs_compat.load_file intent)) in
      let* after = stat intent in
      (match after with
       | Some after when same_stat before after -> of_json ~snapshot ~wal json |> Result.map Option.some
       | None | Some _ -> Error ("queue quarantine intent changed while being read: " ^ intent))
;;

let start ~snapshot ~wal ~rejected ~rejected_path_of =
  let* previous = read ~snapshot ~wal in
  match previous with
  | Some _ -> Error "queue quarantine intent already exists"
  | None ->
    let inspect source =
      let* value = identity source in
      match value with
      | None -> Ok Absent
      | Some identity ->
        let* destination = capture (fun () -> rejected_path_of source) in
        if not (valid_destination source destination) then Error ("not a rejected sibling path: " ^ destination) else
        let* existing = stat destination in
        match existing with
        | Some _ -> Error ("queue quarantine destination already exists: " ^ destination)
        | None -> Ok (Present {destination; identity})
    in
    let* wal_entry = inspect wal in
    let* snapshot_entry = inspect snapshot in
    let t = {rejected; snapshot_entry; wal_entry} in
    let* _ = of_json ~snapshot ~wal (to_json ~snapshot ~wal t) in
    let* () = Fs_compat.save_file_atomic_strict (path ~snapshot) (Yojson.Safe.to_string (to_json ~snapshot ~wal t)) in
    Ok t
;;

let finish ~sync_intent ~rename ~before_clear ~snapshot ~wal t =
  (* An earlier strict publication may have returned after its rename but
     before confirming the parent sync. Visibility alone cannot authorize the
     first source move, including on an explicit retry in this process. *)
  let* current_intent = read ~snapshot ~wal in
  if current_intent <> Some t then Error "queue quarantine intent changed before recovery" else
  let* () = sync_intent (path ~snapshot) in
  let* confirmed_intent = read ~snapshot ~wal in
  if confirmed_intent <> Some t then Error "queue quarantine intent changed during sync" else
  let move source entry =
    let* current = identity source in
    match entry with
    | Absent ->
      (match current with None -> Ok () | Some _ -> Error ("originally absent queue entry appeared: " ^ source))
    | Present {destination; identity=expected} ->
      let* aside = identity destination in
      (match current, aside with
       | Some actual, None when actual = expected ->
         let* () = capture (fun () -> rename source destination)
           |> Result.map_error (fun detail -> Printf.sprintf "queue quarantine rename %s -> %s: %s" source destination detail) in
         let* moved = identity destination in
         let* remaining = stat source in
         if moved = Some expected && remaining = None then Ok ()
         else Error ("queue quarantine move identity was not preserved: " ^ destination)
       | None, Some actual when actual = expected -> Ok ()
       | (None | Some _), (None | Some _) ->
         Error (Printf.sprintf "queue quarantine entry conflict: %s -> %s" source destination))
  in
  let* () = move wal t.wal_entry in
  let* () = move snapshot t.snapshot_entry in
  let* () = Fs_compat.sync_file_and_parent_strict (Filename.dirname snapshot) in
  let* () = capture before_clear in
  (* Check the journal and both slots again before clearing the refusal. *)
  let* latest = read ~snapshot ~wal in
  if latest <> Some t then Error "queue quarantine intent changed before completion" else
  let verify source entry =
    let* current = stat source in
    match current, entry with
    | None, Absent -> Ok ()
    | None, Present {destination; identity=expected} ->
      let* aside = identity destination in
      if aside = Some expected then Ok ()
      else Error ("queue quarantine destination changed before completion: " ^ destination)
    | Some _, (Absent | Present _) -> Error ("queue quarantine source reappeared: " ^ source)
  in
  let* () = verify wal t.wal_entry in
  let* () = verify snapshot t.snapshot_entry in
  let* () = capture (fun () -> ignore (Fs_compat.unlink_if_exists (path ~snapshot))) in
  let* () = Fs_compat.sync_file_and_parent_strict (Filename.dirname snapshot) in
  let result = match t.rejected, t.snapshot_entry, t.wal_entry with
    | Snapshot, Present {destination; _}, partner ->
      Ok {path=snapshot; rejected_path=destination;
          moved_with=(match partner with Absent -> None | Present p -> Some (wal, p.destination))}
    | Transition_wal, partner, Present {destination; _} ->
      Ok {path=wal; rejected_path=destination;
          moved_with=(match partner with Absent -> None | Present p -> Some (snapshot, p.destination))}
    | Snapshot, Absent, (Absent | Present _) | Transition_wal, (Absent | Present _), Absent -> invalid
  in
  result
;;
