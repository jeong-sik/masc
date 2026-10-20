let ( let* ) = Result.bind

type grant =
  | Board of { source_id : string; visibilities : Board_types.visibility list }
  | Repository of { source_id : string; repository_id : string; paths : string list }

let source_id = function Board { source_id; _ } | Repository { source_id; _ } -> source_id

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
