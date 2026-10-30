let ( let* ) = Result.bind

type record = {
  source_id : string;
  kind : string;
  visibilities : string list;
  repository_id : string option;
  paths : string list;
}

let as_string = function Otoml.TomlString s -> Some s | _ -> None

let as_string_list = function
  | Otoml.TomlArray items ->
      let strings = List.filter_map as_string items in
      if List.length strings = List.length items then Some strings else None
  | _ -> None

let entry_of_toml = function
  | Otoml.TomlTable fields ->
      let field key = Option.bind (List.assoc_opt key fields) Fun.id in
      (match Option.bind (field "source_id") as_string, Option.bind (field "kind") as_string with
       | Some source_id, Some kind ->
           let list key =
             match field key with
             | None -> Ok []
             | Some value ->
                 (match as_string_list value with
                  | Some strings -> Ok strings
                  | None -> Error (Printf.sprintf "record %s holds a %s that is not an array of strings" source_id key)) in
           let* visibilities = list "visibilities" in
           let* paths = list "paths" in
           let repository_id = Option.bind (field "repository_id") as_string in
           (match field "repository_id", repository_id with
            | Some _, None -> Error (Printf.sprintf "record %s holds a repository_id that is not a string" source_id)
            | _ -> Ok { source_id; kind; visibilities; repository_id; paths })
       | _ -> Error "a [[binding.records]] entry needs string source_id and kind")
  | _ -> Error "a [[binding.records]] entry must be a table"

let parse text =
  try
    match Otoml.Parser.from_string_result text with
    | Error detail -> Error detail
    | Ok doc ->
        let child table key =
          match table with Otoml.TomlTable fields -> List.assoc_opt key fields | _ -> None in
        (match Option.bind (child doc "binding") (fun binding -> child binding "records") with
         | None -> Ok []
         | Some (Otoml.TomlTableArray entries) ->
             List.fold_right
               (fun entry acc ->
                 let* acc = acc in
                 let* record = entry_of_toml entry in
                 Ok (record :: acc))
               entries (Ok [])
         | Some _ -> Error "[binding] records is not an array of tables")
  with Otoml.Duplicate_key detail -> Error detail

let item_schema =
  `Assoc
    [
      ("type", `String "object");
      ("required", `List [`String "source_id"; `String "kind"]);
      ( "properties",
        `Assoc
          [
            ("source_id", `Assoc [("type", `String "string"); ("description", `String "Unique name, e.g. wkbl")]);
            ( "kind",
              `Assoc
                [
                  ("type", `String "string");
                  ("enum", `List [`String "board"; `String "repository"; `String "wiki"; `String "github_pulls"]);
                  ("description", `String "What the installation may read");
                ] );
            ( "visibilities",
              `Assoc
                [
                  ("type", `String "array");
                  ("items", `Assoc [("type", `String "string")]);
                  ("description", `String "board only: any of public, unlisted, internal, direct");
                ] );
            ( "repository_id",
              `Assoc
                [("type", `String "string"); ("description", `String "repository and github_pulls only: a registered repository id")] );
            ( "paths",
              `Assoc
                [
                  ("type", `String "array");
                  ("items", `Assoc [("type", `String "string")]);
                  ("description", `String "repository only: relative paths; a trailing / covers a directory");
                ] );
          ] );
    ]

let closed_kinds = ["board"; "repository"; "wiki"; "github_pulls"]

(* The entry exactly as the host reads it: only the kind's own keys, values
   verbatim from the form so the host's own check reports mistyped fields. *)
let entry_json json =
  match json with
  | `Assoc fields ->
      let* source_id =
        match List.assoc_opt "source_id" fields with
        | Some (`String id) when String.trim id <> "" && String.trim id = id -> Ok id
        | _ -> Error "source_id requires a non-blank string" in
      let* kind =
        match List.assoc_opt "kind" fields with
        | Some (`String kind) when List.mem kind closed_kinds -> Ok kind
        | Some (`String kind) -> Error ("this host has no record kind " ^ kind)
        | _ -> Error "a record grant requires a string kind" in
      let value key neutral = Option.value ~default:neutral (List.assoc_opt key fields) in
      let entry =
        match kind with
        | "board" -> [("source_id", `String source_id); ("kind", `String kind); ("visibilities", value "visibilities" (`List []))]
        | "repository" ->
            [
              ("source_id", `String source_id);
              ("kind", `String kind);
              ("repository_id", value "repository_id" (`String ""));
              ("paths", value "paths" (`List []));
            ]
        | "wiki" -> [("source_id", `String source_id); ("kind", `String kind)]
        | _ ->
            [("source_id", `String source_id); ("kind", `String kind); ("repository_id", value "repository_id" (`String ""))] in
      Ok (source_id, entry)
  | _ -> Error "a record grant must be an object"

let block_of_entry ~source_id ~kind ~visibilities ~repository_id ~paths =
  let open Toml_line_editor in
  let lines =
    ["[[binding.records]]"; scalar_line ~key:"source_id" ~value:source_id; scalar_line ~key:"kind" ~value:kind]
    @ (match kind with
       | "board" -> [string_array_line ~key:"visibilities" ~values:visibilities]
       | "repository" -> [scalar_line ~key:"repository_id" ~value:repository_id; string_array_line ~key:"paths" ~values:paths]
       | "github_pulls" -> [scalar_line ~key:"repository_id" ~value:repository_id]
       | _ -> []) in
  lines

let insert_block text block =
  let open Toml_line_editor in
  let lines, trailing = split_lines text in
  let structural = structural_lines lines in
  let structural_at i = match List.nth_opt structural i with Some outside -> outside | None -> false in
  let is_records i line = structural_at i && is_table_array ~path:"binding.records" line in
  let is_binding i line = structural_at i && is_table ~path:"binding" line in
  let is_header i line = structural_at i && is_table_header line in
  let indexed = List.mapi (fun i line -> (i, line)) lines in
  let last_records =
    List.fold_left (fun acc (i, line) -> if is_records i line then Some i else acc) None indexed in
  let next_header after =
    List.find_opt (fun (i, line) -> i > after && is_header i line) indexed
    |> Option.map fst in
  let* at =
    match last_records with
    | Some start -> Ok (Option.value ~default:(List.length lines) (next_header start))
    | None ->
        (match List.find_opt (fun (i, line) -> is_binding i line) indexed with
         | None -> Error "this TOML has no [binding] table; E edits the raw text"
         | Some (start, _) -> Ok (Option.value ~default:(List.length lines) (next_header start))) in
  let prefix, suffix = split_at at lines in
  let block =
    match List.rev prefix with
    | [] -> block
    | last :: _ when String.trim last = "" -> block
    | _ -> "" :: block in
  Ok (join_lines (prefix @ block @ suffix) ~trailing_newline:trailing)

let add text json =
  let* source_id, entry = entry_json json in
  if List.mem source_id (Toml_line_editor.table_array_entry_ids text ~path:"binding.records" ~id_key:"source_id") then
    Error (source_id ^ " is already granted; d drops it first")
  else
    let* _grants = Masc.Lane_addon_records.grants ~operator_owned:true (`Assoc ["records", `List [`Assoc entry]]) in
    let strings key = match List.assoc_opt key entry with
      | Some (`List items) -> List.filter_map (function `String s -> Some s | _ -> None) items
      | _ -> [] in
    let scalar key = match List.assoc_opt key entry with
      | Some (`String s) -> s | _ -> "" in
    let kind = scalar "kind" in
    insert_block text
      (block_of_entry ~source_id ~kind ~visibilities:(strings "visibilities")
         ~repository_id:(scalar "repository_id") ~paths:(strings "paths"))

let remove text ~source_id =
  let next = Toml_line_editor.remove_table_array_entry text ~path:"binding.records" ~id_key:"source_id" ~id:source_id in
  if String.equal next text then Error ("no record names " ^ source_id) else Ok next

type t = {
  title : string;
  text : string;
  records : record list;
  cursor : int;
  form : Masc_tui_schema_form.t option;
  message : string option;
}

let open_ ~title ~text =
  let* records = parse text in
  Ok { title; text; records; cursor = 0; form = None; message = None }

let text overlay = overlay.text
let text_entry_open overlay = Option.is_some overlay.form

let insert_text ~text overlay =
  match overlay.form with
  | Some form -> { overlay with form = Some (Masc_tui_schema_form.insert_text ~text form) }
  | None -> overlay

let clamp records cursor = max 0 (min (max 0 (List.length records - 1)) cursor)

let submit_form overlay json =
  match add overlay.text json with
  | Error detail -> Ok (Updated { overlay with message = Some detail })
  | Ok text -> (
      match parse text with
      | Error detail -> Ok (Updated { overlay with message = Some detail })
      | Ok records ->
          let name =
            match json with
            | `Assoc fields -> (
                match List.assoc_opt "source_id" fields with Some (`String id) -> id | _ -> "record")
            | _ -> "record" in
          let overlay =
            { overlay with text; records; form = None; cursor = clamp records overlay.cursor; message = Some (name ^ " added — s saves") } in
          Ok (Apply (overlay, text)))

let drop_selected overlay =
  match List.nth_opt overlay.records overlay.cursor with
  | None -> Ok (Updated { overlay with message = Some "No record to remove" })
  | Some record -> (
      match remove overlay.text ~source_id:record.source_id with
      | Error detail -> Ok (Updated { overlay with message = Some detail })
      | Ok text -> (
          match parse text with
          | Error detail -> Ok (Updated { overlay with message = Some detail })
          | Ok records ->
              let overlay =
                {
                  overlay with
                  text;
                  records;
                  cursor = clamp records overlay.cursor;
                  message = Some (record.source_id ^ " removed — s saves");
                } in
              Ok (Apply (overlay, text))))

let handle ~key overlay =
  match overlay.form with
  | Some form -> (
      match Masc_tui_schema_form.handle ~key form with
      | Error detail -> Error detail
      | Ok Masc_tui_schema_form.Cancel -> Ok (Updated { overlay with form = None; message = None })
      | Ok (Updated form) -> Ok (Updated { overlay with form = Some form })
      | Ok (Submit json) -> submit_form overlay json)
  | None -> (
      match key with
      | "esc" | "q" -> Ok Cancel
      | "j" | "down" -> Ok (Updated { overlay with cursor = clamp overlay.records (overlay.cursor + 1) })
      | "k" | "up" -> Ok (Updated { overlay with cursor = clamp overlay.records (overlay.cursor - 1) })
      | "a" -> (
          match Masc_tui_schema_form.create ~schema:item_schema ~initial:(`Assoc []) with
          | Error detail -> Error detail
          | Ok form -> Ok (Updated { overlay with form = Some form; message = None }))
      | "d" -> drop_selected overlay
      | _ -> Ok (Updated overlay))

let describe record =
  let specific =
    match record.kind with
    | "board" -> "visibilities: " ^ String.concat ", " record.visibilities
    | "repository" ->
        Option.value ~default:"no repository" record.repository_id
        ^ " · "
        ^ (match record.paths with [] -> "no paths" | paths -> String.concat ", " paths)
    | "wiki" -> "workspace wiki"
    | "github_pulls" -> Option.value ~default:"no repository" record.repository_id
    | _ -> "unknown kind" in
  record.source_id ^ " · " ^ record.kind ^ " · " ^ specific

let lines overlay =
  let header = ["Record grants · " ^ overlay.title; ""] in
  let rows =
    match overlay.records with
    | [] -> ["No record grants yet · a adds one"]
    | records ->
        List.mapi
          (fun i record -> (if i = overlay.cursor then "> " else "  ") ^ describe record)
          records in
  let message = match overlay.message with None -> [] | Some text -> [""; text] in
  let form = match overlay.form with None -> [] | Some form -> "" :: Masc_tui_schema_form.lines form in
  header @ rows @ message @ form @ [""; "a:add  d:remove  j/k:move  Esc:back to document · s saves"]
