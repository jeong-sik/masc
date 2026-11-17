open Runtime_toml_base

module Names = Set.Make (String)

let ( let* ) = Result.bind

let duplicate_keys ~path entries =
  let _, errors =
    List.fold_left
      (fun (seen, errors) (key, _) ->
         if Names.mem key seen then
           seen, { path = path ^ "." ^ key; message = "duplicate reader field" } :: errors
         else Names.add key seen, errors)
      (Names.empty, [])
      entries
  in
  List.rev errors
;;

let required_string ~path tbl key =
  required_non_empty_string
    tbl
    ~path
    ~key
    ~message:(Printf.sprintf "reader requires nonblank '%s'" key)
;;

let parse_kind ~path tbl =
  let* value = required_string ~path tbl "kind" in
  match value with
  | "audio" -> Ok Media_reading_kind.Audio
  | "document" -> Ok Media_reading_kind.Document
  | value ->
    Error
      (error
         (path ^ ".kind")
         (Printf.sprintf "unknown reader kind %S; expected audio or document" value))
;;

let parse_adapter ~path tbl =
  let* value = required_string ~path tbl "adapter" in
  match value with
  | "markitdown_mcp" -> Ok Runtime_schema.Markitdown_mcp
  | value ->
    Error
      (error
         (path ^ ".adapter")
         (Printf.sprintf "unknown reader adapter %S; expected markitdown_mcp" value))
;;

let no_nul value =
  if String.contains value '\000' then Some "must not contain NUL" else None
;;

let nonblank_media_type value =
  if String.trim value = "" then Some "media type must not be blank" else None
;;

let parse_string_list ~path tbl ~key ~validate =
  let key_path = path ^ "." ^ key in
  match Otoml.find_opt tbl Fun.id [ key ] with
  | None -> Error (error key_path (Printf.sprintf "reader requires '%s'" key))
  | Some (Otoml.TomlArray values) ->
    partition_results
      (List.mapi
         (fun index value ->
            let entry_path = Printf.sprintf "%s[%d]" key_path index in
            match value with
            | Otoml.TomlString value ->
              (match validate value with
               | None -> Ok value
               | Some message -> Error (error entry_path message))
            | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
            | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
            | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
            | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ->
              Error (error entry_path "must be a string"))
         values)
  | Some
      (Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
      | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
      | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
      | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _) ->
    Error (error key_path "must be an array of strings")
;;

let parse_reader ~path = function
  | (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) as tbl ->
    let structural_errors =
      unknown_table_keys
        ~path
        ~expected:[ "id"; "revision"; "kind"; "media_types"; "adapter"; "command"; "args" ]
        entries
      @ duplicate_keys ~path entries
    in
    let* () = match structural_errors with [] -> Ok () | errors -> Error errors in
    let* id = required_string ~path tbl "id" in
    let* revision = required_string ~path tbl "revision" in
    let* kind = parse_kind ~path tbl in
    let* media_types = parse_string_list ~path tbl ~key:"media_types" ~validate:nonblank_media_type in
    let* adapter = parse_adapter ~path tbl in
    let* command = required_string ~path tbl "command" in
    let* () =
      match no_nul command with
      | None -> Ok ()
      | Some message -> Error (error (path ^ ".command") message)
    in
    let* args = parse_string_list ~path tbl ~key:"args" ~validate:no_nul in
    Ok { Runtime_schema.id; revision; kind; media_types; adapter; command; args }
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
  | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
  | Otoml.TomlTableArray _ ->
    Error (error path "reader must be a table")
;;

let unique_ids ~path readers =
  let _, _, errors =
    List.fold_left
      (fun (seen, index, errors) (reader : Runtime_schema.media_reader_decl) ->
         let errors =
           if Names.mem reader.id seen then
             { path = Printf.sprintf "%s[%d].id" path index
             ; message = Printf.sprintf "duplicate reader id %S" reader.id
             } :: errors
           else errors
         in
         Names.add reader.id seen, index + 1, errors)
      (Names.empty, 0, [])
      readers
  in
  match errors with [] -> Ok readers | errors -> Error (List.rev errors)
;;

let parse_media_readers toml =
  let path = Ns.key Ns.Media_readers in
  match toml with
  | Otoml.TomlTable entries ->
    (* Parsed documents can also be supplied directly, without Otoml's source
       duplicate-key guard. Never choose one of two competing declarations. *)
    (match List.filter (fun (key, _) -> String.equal key path) entries with
     | [] -> Ok []
     | [ (_, (Otoml.TomlArray rows | Otoml.TomlTableArray rows)) ] ->
       let* readers =
         partition_results
           (List.mapi
              (fun index row -> parse_reader ~path:(Printf.sprintf "%s[%d]" path index) row)
              rows)
       in
       unique_ids ~path readers
     | [ (_, (Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
             | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
             | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
             | Otoml.TomlLocalTime _ | Otoml.TomlTable _ | Otoml.TomlInlineTable _)) ] ->
       Error (error path "media_readers must be an array of tables")
     | _ :: _ :: _ -> Error (error path "duplicate media_readers declaration"))
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
  | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
  | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ->
    Error (error path "media reader declarations require a table document")
;;
