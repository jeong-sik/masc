type t =
  { path : string
  ; inode : int
  }

let of_stat ~path (stats : Unix.stats) = { path; inode = stats.st_ino }
let equal a b = String.equal a.path b.path && Int.equal a.inode b.inode
let to_json t = `Assoc [ "path", `String t.path; "inode", `Int t.inode ]
let invalid_value = Error "a durable file identity needs an absolute path and a non-negative inode"
let invalid_fields = Error "a durable file identity has exactly the fields path and inode"

let of_fields path inode =
  match path with
  | `String path when String.trim path <> "" && not (Filename.is_relative path) ->
    (match inode with
     | `Int inode when inode >= 0 -> Ok { path; inode }
     | `Int _ | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
       invalid_value)
  | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
    invalid_value
;;

let of_json = function
  | `Assoc [ ("path", path); ("inode", inode) ] | `Assoc [ ("inode", inode); ("path", path) ] ->
    of_fields path inode
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    invalid_fields
;;
