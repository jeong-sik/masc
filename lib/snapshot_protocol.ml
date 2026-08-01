type response =
  | Snapshot of { revision : string; value : Yojson.Safe.t }
  | Unchanged of { revision : string }

let if_revision json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "if_revision" fields with
     | None | Some `Null -> Ok None
     | Some (`String revision) when String.trim revision <> "" ->
       Ok (Some (String.trim revision))
     | Some (`String _) -> Error "if_revision must not be blank"
     | Some _ -> Error "if_revision must be a string")
  | _ -> Error "tool arguments must be an object"
;;

let respond ~revision ~if_revision value =
  match if_revision with
  | Some expected when String.equal expected revision -> Unchanged { revision }
  | Some _ | None -> Snapshot { revision; value }
;;

let to_yojson = function
  | Snapshot { revision; value } ->
    `Assoc
      [ "kind", `String "snapshot"
      ; "revision", `String revision
      ; "snapshot", value
      ]
  | Unchanged { revision } ->
    `Assoc
      [ "kind", `String "unchanged"
      ; "revision", `String revision
      ]
;;

let revision_of_backlog_version version = Printf.sprintf "backlog:%d" version

let revision_of_board_cursor (timestamp, post_id) =
  let cursor =
    match post_id with
    | None -> "none"
    | Some id -> id
  in
  Printf.sprintf "board:%.17g:%s" timestamp cursor
;;

let revision_of_json ~namespace value =
  Printf.sprintf "%s:%s" namespace (Digest.to_hex (Digest.string (Yojson.Safe.to_string value)))
;;
