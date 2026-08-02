type response =
  | Snapshot of { revision : string; value : Yojson.Safe.t }
  | Unchanged of { revision : string }

let if_revision json =
  match json with
  | `Null -> Ok None
  | `Assoc fields ->
    (match List.assoc_opt "if_revision" fields with
     | None | Some `Null -> Ok None
     | Some (`String revision) when String.trim revision <> "" ->
       Ok (Some (String.trim revision))
     | Some (`String _) -> Error "if_revision must not be blank"
     | Some _ -> Error "if_revision must be a string")
  | _ -> Error "tool arguments must be an object"
;;

let unchanged_if_revision_matches ~revision ~if_revision =
  match if_revision with
  | Some expected when String.equal expected revision -> Some (Unchanged { revision })
  | Some _ | None -> None
;;

let respond ~revision ~if_revision value =
  match unchanged_if_revision_matches ~revision ~if_revision with
  | Some response -> response
  | None -> Snapshot { revision; value }
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

let rec canonical_json = function
  | `Assoc fields ->
    `Assoc
      (List.sort
         (fun (left, _) (right, _) -> String.compare left right)
         (List.map (fun (key, value) -> key, canonical_json value) fields))
  | `List values -> `List (List.map canonical_json values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value -> value
;;

let revision_of_json ~namespace value =
  let canonical = canonical_json value |> Yojson.Safe.to_string in
  Printf.sprintf "%s:%s" namespace (Digestif.SHA256.(digest_string canonical |> to_hex))
;;
