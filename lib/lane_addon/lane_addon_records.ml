let ( let* ) = Result.bind

type grant =
  | Board of { source_id : string; visibilities : Board_types.visibility list }
  | Repository of { source_id : string; repository_id : string; paths : string list }

let source_id = function Board { source_id; _ } | Repository { source_id; _ } -> source_id
let source_id_of = source_id

let exact_keys keys fields =
  match List.find_opt (fun (key, _) -> not (List.mem key keys)) fields with
  | Some (key, _) -> Error ("a record grant has no key " ^ key)
  | None -> Ok ()

let text fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" && String.trim value = value -> Ok value
  | Some _ | None -> Error (key ^ " requires a non-blank string")

let strings fields key =
  match List.assoc_opt key fields with
  | Some (`List (_ :: _ as values)) ->
    let* values =
      List.fold_right
        (fun value acc ->
           let* acc = acc in
           match value with
           | `String text -> Ok (text :: acc)
           | _ -> Error (key ^ " holds strings"))
        values (Ok [])
    in
    if List.length (List.sort_uniq String.compare values) = List.length values then Ok values
    else Error (key ^ " names a value twice")
  | Some _ | None -> Error (key ^ " requires a non-empty array")

(* A path is relative to the repository root and never leaves it. *)
let valid_path path =
  path <> "" && path.[0] <> '/'
  && List.for_all (fun segment -> segment <> ".." && segment <> ".")
       (List.filter (fun segment -> segment <> "") (String.split_on_char '/' path))

let grant_of_json = function
  | `Assoc fields ->
    let* source_id = text fields "source_id" in
    (match List.assoc_opt "kind" fields with
     | Some (`String "board") ->
       let* () = exact_keys [ "source_id"; "kind"; "visibilities" ] fields in
       let* names = strings fields "visibilities" in
       let* visibilities =
         List.fold_right
           (fun name acc ->
              let* acc = acc in
              match Board_core_classify.visibility_of_string name with
              | Some visibility -> Ok (visibility :: acc)
              | None -> Error ("visibilities has no value " ^ name))
           names (Ok [])
       in
       Ok (Board { source_id; visibilities })
     | Some (`String "repository") ->
       let* () = exact_keys [ "source_id"; "kind"; "repository_id"; "paths" ] fields in
       let* repository_id = text fields "repository_id" in
       let* paths = strings fields "paths" in
       (match List.find_opt (fun path -> not (valid_path path)) paths with
        | Some path -> Error ("paths must stay inside the repository: " ^ path)
        | None -> Ok (Repository { source_id; repository_id; paths }))
     | Some (`String kind) -> Error ("this host has no record kind " ^ kind)
     | Some _ | None -> Error "a record grant requires a string kind")
  | _ -> Error "a record grant must be an object"

let grants ~operator_owned = function
  | `Assoc fields ->
    (match List.assoc_opt "records" fields with
     | None -> Ok []
     | Some _ when not operator_owned -> Error "only an operator-owned declaration may hold record grants"
     | Some (`List values) ->
       let* grants =
         List.fold_right
           (fun value acc ->
              let* acc = acc in
              let* grant = grant_of_json value in
              Ok (grant :: acc))
           values (Ok [])
       in
       let ids = List.map source_id grants in
       if List.length (List.sort_uniq String.compare ids) = List.length ids then Ok grants
       else Error "records names the same source_id twice"
     | Some _ -> Error "records requires an array of grants")
  | _ -> Error "a binding must be an object"

let covers ~paths file =
  valid_path file
  && List.exists
    (fun path ->
       if String.ends_with ~suffix:"/" path then String.starts_with ~prefix:path file
       else String.equal path file)
    paths

type read =
  | Page of Yojson.Safe.t
  | Not_allowed of string
  | Unavailable of string

(* A record's place in the oldest-first order. The package gets it back as an
   opaque cursor. *)
type key = { at : float; kind : string; id : string }

let compare_key a b =
  match Float.compare a.at b.at with
  | 0 -> (match String.compare a.kind b.kind with 0 -> String.compare a.id b.id | order -> order)
  | order -> order

let cursor_of_key key = Printf.sprintf "%h|%s|%s" key.at key.kind key.id

let key_of_cursor cursor =
  match String.index_opt cursor '|' with
  | None -> None
  | Some first ->
    (match String.index_from_opt cursor (first + 1) '|' with
     | None -> None
     | Some second ->
       let at = float_of_string_opt (String.sub cursor 0 first) in
       let kind = String.sub cursor (first + 1) (second - first - 1) in
       let id = String.sub cursor (second + 1) (String.length cursor - second - 1) in
       (match at, kind with
        | Some at, ("post" | "comment") when Float.is_finite at && id <> "" -> Some { at; kind; id }
        | (Some _ | None), _ -> None))

let board_records ~visibilities =
  let* () =
    Board_dispatch.require_persisted_sources_readable () |> Result.map_error Board.show_board_error
  in
  match Board_dispatch.backend () with
  | Board_dispatch.Jsonl store ->
    let posts =
      Board.search_posts store
        ~predicate:(fun (post : Board.post) -> List.mem post.visibility visibilities)
        ~limit:max_int
    in
    let post_record (post : Board.post) =
      let id = Board.Post_id.to_string post.id in
      ( { at = post.created_at; kind = "post"; id }
      , `Assoc
          [ "kind", `String "post"; "id", `String id
          ; "author", `String (Board.Agent_id.to_string post.author)
          ; "created_at", `Float post.created_at; "updated_at", `Float post.updated_at
          ; "visibility", `String (Board_core_classify.visibility_to_string post.visibility)
          ; "title", `String post.title; "body", `String post.body ] )
    in
    let comment_record (comment : Board.comment) =
      let id = Board.Comment_id.to_string comment.id in
      ( { at = comment.created_at; kind = "comment"; id }
      , `Assoc
          [ "kind", `String "comment"; "id", `String id
          ; "post_id", `String (Board.Post_id.to_string comment.post_id)
          ; "author", `String (Board.Agent_id.to_string comment.author)
          ; "created_at", `Float comment.created_at; "body", `String comment.content ] )
    in
    let* comments =
      List.fold_left
        (fun acc (post : Board.post) ->
           let* acc = acc in
           match Board.read_comments store ~post_id:(Board.Post_id.to_string post.id) with
           | Ok comments -> Ok (List.rev_append (List.map comment_record comments) acc)
           | Error error -> Error (Board.show_board_read_error error))
        (Ok []) posts
    in
    Ok (List.rev_append (List.map post_record posts) comments)

(* The page body for the records taken so far. *)
let page_body ~source_id ~records ~next_cursor ~complete ~sha256 =
  `Assoc
    [ "status", `String "records"; "source_id", `String source_id; "records", `List records
    ; "next_cursor", (match next_cursor with None -> `Null | Some cursor -> `String cursor)
    ; "complete", `Bool complete; "sha256", `String sha256 ]

(* Every page has a 64-hex SHA-256; measuring with a placeholder of that size
   gives the exact size of the answered body. *)
let sha256_placeholder = String.make 64 '0'

let take_page ~measure ~max_bytes ~source_id pending =
  (* [Yojson] writes an array as its elements joined by commas, so a page's
     size is the size of the same body with no records, plus each record, plus
     one comma between two. *)
  let rec take taken bytes = function
    | [] -> List.rev taken, true
    | ((key, json) as record) :: rest ->
      let encoded = String.length (Yojson.Safe.to_string json) in
      let separator = match taken with [] -> 0 | _ :: _ -> 1 in
      let base =
        measure
          (page_body ~source_id ~records:[] ~next_cursor:(Some (cursor_of_key key)) ~complete:false
             ~sha256:sha256_placeholder)
      in
      if base + bytes + separator + encoded <= max_bytes || taken = []
      then take (record :: taken) (bytes + separator + encoded) rest
      else List.rev taken, false
  in
  take [] 0 pending

let read_records ~store ~grants ~measure ~max_bytes ~source_id ~after =
  match List.find_opt (fun grant -> String.equal (source_id_of grant) source_id) grants with
  | None -> Not_allowed ("source " ^ source_id ^ " is not granted to this installation")
  | Some (Repository _) -> Unavailable "this host reads no repository records yet"
  | Some (Board { visibilities; _ }) ->
    let after_key = Option.map key_of_cursor after in
    (match after_key with
     | Some None -> Not_allowed "after is not a cursor this host gave"
     | None | Some (Some _) ->
       (match board_records ~visibilities with
        | Error detail -> Unavailable ("the Board cannot be read: " ^ detail)
        | Ok records ->
          let sorted = List.sort (fun (a, _) (b, _) -> compare_key a b) records in
          let pending =
            match after_key with
            | Some (Some after) -> List.filter (fun (key, _) -> compare_key key after > 0) sorted
            | None | Some None -> sorted
          in
          let taken, complete = take_page ~measure ~max_bytes ~source_id pending in
          let next_cursor =
            match List.rev taken with
            | (key, _) :: _ -> Some (cursor_of_key key)
            | [] -> after
          in
          let records = List.map snd taken in
          (match
             Eio_unix.run_in_systhread (fun () ->
               Lane_addon_store.write_blob store (Yojson.Safe.to_string (`List records)))
           with
           | Error detail -> Unavailable ("the page could not be retained: " ^ detail)
           | Ok { Lane_addon_types.sha256 = None; _ } -> Unavailable "the retained page has no digest"
           | Ok { Lane_addon_types.sha256 = Some sha256; _ } ->
             Page (page_body ~source_id ~records ~next_cursor ~complete ~sha256))))
