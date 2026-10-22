type owner = Effective_user | Real_user
type mode = Exact of int | Clear of int | Any_mode
type links = Exactly_one | Any_count
type t = { kind : Unix.file_kind; owner : owner; mode : mode; links : links }

let private_directory =
  { kind = Unix.S_DIR; owner = Effective_user; mode = Exact 0o700; links = Any_count }
let private_file =
  { kind = Unix.S_REG; owner = Effective_user; mode = Exact 0o600; links = Exactly_one }

let kind_name = function
  | Unix.S_REG -> "regular file"
  | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character device"
  | Unix.S_BLK -> "block device"
  | Unix.S_LNK -> "symbolic link"
  | Unix.S_FIFO -> "named pipe"
  | Unix.S_SOCK -> "socket"

let mode_holds mode permissions = match mode with
  | Exact value -> permissions = value
  | Clear mask -> permissions land mask = 0
  | Any_mode -> true

let links_hold links count = match links with
  | Exactly_one -> count = 1
  | Any_count -> true

let required_clauses requirement =
  let mode = match requirement.mode with
    | Exact value -> [Printf.sprintf "mode %04o" value]
    | Clear mask -> [Printf.sprintf "none of the mode bits %04o set" mask]
    | Any_mode -> [] in
  let links = match requirement.links with
    | Exactly_one -> ["exactly one link"]
    | Any_count -> [] in
  match mode @ links with
  | [] -> ""
  | clauses -> " with " ^ String.concat " and " clauses

let found_links requirement count = match requirement.links with
  | Exactly_one -> if count = 1 then " and 1 link" else Printf.sprintf " and %d links" count
  | Any_count -> ""

let owner_uid = function
  | Effective_user -> Unix.geteuid ()
  | Real_user -> Unix.getuid ()

let check ~label requirement ~path (stats : Unix.stats) =
  let uid = owner_uid requirement.owner in
  if stats.st_kind = requirement.kind && stats.st_uid = uid
     && mode_holds requirement.mode stats.st_perm
     && links_hold requirement.links stats.st_nlink
  then Ok ()
  else Error (Printf.sprintf "%s %s must be a %s owned by uid %d%s; it is a %s owned by uid %d with mode %04o%s"
    label path (kind_name requirement.kind) uid (required_clauses requirement)
    (kind_name stats.st_kind) stats.st_uid stats.st_perm (found_links requirement stats.st_nlink))

let lstat ~label requirement path =
  let stats = Unix.lstat path in
  Result.map (fun () -> stats) (check ~label requirement ~path stats)

let canonical ~label path =
  let resolved = Unix.realpath path in
  if String.equal resolved path then Ok ()
  else Error (Printf.sprintf "%s %s must be its own canonical path; it resolves to %s" label path resolved)

type identity = { device : int; inode : int }

let identity (stats : Unix.stats) = { device = stats.st_dev; inode = stats.st_ino }

let replaced ~label ~path ~expected ~observed =
  Printf.sprintf "%s %s was replaced: it was device %d inode %d and is now device %d inode %d"
    label path expected.device expected.inode observed.device observed.inode

let keys ~label ~found ~required =
  let names = function
    | [] -> "none"
    | names -> String.concat ", " (List.sort String.compare names) in
  Printf.sprintf "%s must have exactly the keys %s; it has %s" label (names required) (names found)
