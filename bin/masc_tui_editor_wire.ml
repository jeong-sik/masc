type runtime_config_save_error =
  | Runtime_config_conflict of Masc_tui_runtime_config_edit.document
  | Runtime_config_save_refused of string
  | Runtime_config_save_unconfirmed of string

let runtime_config_save_error_message = function
  | Runtime_config_conflict _ -> "The file changed after this draft was opened. Compare the current file before saving."
  | Runtime_config_save_refused detail -> detail
  | Runtime_config_save_unconfirmed detail ->
    detail ^ " The file may already have changed; read the current file before retrying."

let runtime_config_text_revision source_text =
  Runtime.config_source_revision_of_text source_text
  |> Runtime.config_source_revision_to_string

let runtime_config_conflict_document body =
  let open Result.Syntax in
  let* json = try Ok (Yojson.Safe.from_string body)
    with Yojson.Json_error detail -> Error detail in
  let* current = match Json_util.assoc_member_opt "code" json, Json_util.assoc_member_opt "current" json with
    | Some (`String "revision_conflict"), Some (`Assoc _ as current) -> Ok current
    | _ -> Error "Malformed configuration conflict response" in
  match Json_util.assoc_member_opt "source_path" current,
        Json_util.assoc_member_opt "source_text" current,
        Json_util.assoc_member_opt "source_revision" current with
  | Some (`String path), Some (`String source_text), Some (`String source_revision)
    when path <> "" && String_util.is_lowercase_sha256_hex source_revision
      && String.equal source_revision (runtime_config_text_revision source_text) ->
    Ok { Masc_tui_runtime_config_edit.path; source_text; source_revision }
  | _ -> Error "Configuration conflict document has an invalid source revision"
type skill_editor_loaded =
  { sel_reference : Skill_reference.t
  ; sel_source_text : string
  ; sel_access : Skill_source_config.access
  }

type skill_editor_save_status =
  | Skill_unchanged
  | Skill_saved_and_published
  | Skill_saved_but_unpublished of string

type skill_editor_save_receipt =
  { ses_status : skill_editor_save_status
  ; ses_reference : Skill_reference.t
  ; ses_snapshot_revision : string option
  }

type skill_editor_create_status =
  | Skill_created_and_published
  | Skill_created_but_shadowed of Skill_reference.identity
  | Skill_created_but_unpublished of string

type skill_editor_create_receipt =
  { sec_status : skill_editor_create_status
  ; sec_reference : Skill_reference.t
  }

type skill_editor_write_error =
  | Skill_write_refused of string
  | Skill_write_unconfirmed of string

let skill_editor_create_body ~composition ~source_id ~package_id ~source_text =
  Yojson.Safe.to_string (`Assoc
    [ "kind", `String (if composition then "composition" else "instruction")
    ; "source_id", `String source_id; "package_id", `String package_id
    ; "source_text", `String source_text ])
;;

let preview_reference fields =
  let open Result.Syntax in
  let* json = match List.assoc_opt "preview" fields with
    | Some (`Assoc preview) ->
      (match List.assoc_opt "profile" preview with
       | Some (`Assoc profile) ->
         (match List.assoc_opt "reference" profile with
          | Some json -> Ok json | None -> Error "Skill preview profile reference is missing")
       | _ -> Error "Skill preview profile is missing")
    | _ -> Error "Skill response preview is missing" in
  Skill_reference.of_yojson json
  |> Result.map_error (fun _ -> "Skill response exact reference is invalid")
;;

let decode_skill_editor_create_receipt ~source_id ~package_id ~source_text = function
  | `Assoc fields ->
    let open Result.Syntax in
    let* sec_reference = preview_reference fields in
    let* () =
      if String.equal source_id (Skill_reference.identity_source_id_to_string sec_reference.identity)
         && String.equal package_id (Skill_reference.identity_package_id_to_string sec_reference.identity)
         && String.equal package_id sec_reference.identity.name
         && Skill_reference.equal_content_revision sec_reference.content_revision
              (Skill_reference.content_revision_of_source_text source_text)
      then Ok () else Error "Skill create receipt does not match the submitted identity and bytes" in
    let* sec_status = match List.assoc_opt "status" fields with
      | Some (`String "created_and_published") -> Ok Skill_created_and_published
      | Some (`String "created_but_shadowed") ->
        (match List.assoc_opt "winner" fields with
         | Some json -> Skill_reference.identity_of_yojson json
             |> Result.map (fun winner -> Skill_created_but_shadowed winner)
             |> Result.map_error (fun _ -> "Shadowed create receipt has no valid winner")
         | None -> Error "Shadowed create receipt has no winner")
      | Some (`String "created_but_unpublished") ->
        (match List.assoc_opt "reason" fields with
         | Some (`String reason) -> Ok (Skill_created_but_unpublished reason)
         | _ -> Error "Unpublished create receipt has no reason")
      | _ -> Error "Skill create response has an unknown or missing status" in
    Ok { sec_status; sec_reference }
  | _ -> Error "Skill create response must be an object"
;;

let skill_editor_body reference source_text =
  `Assoc
    ([ "reference", Skill_reference.to_yojson reference ]
     @
     match source_text with
     | None -> []
     | Some text -> [ "source_text", `String text ])
  |> Yojson.Safe.to_string
;;

let decode_skill_editor_loaded = function
  | `Assoc fields ->
    let open Result.Syntax in
    (match List.assoc_opt "reference" fields,
           List.assoc_opt "source_text" fields,
           List.assoc_opt "access" fields with
     | Some reference_json, Some (`String source_text), Some (`String access) ->
       let* sel_reference =
         Skill_reference.of_yojson reference_json
         |> Result.map_error (fun _ -> "Skill editor returned an invalid exact reference")
       in
       let* sel_access =
         match access with
         | "read_only" -> Ok Skill_source_config.Read_only
         | "read_write" -> Ok Skill_source_config.Read_write
         | _ -> Error "Skill editor returned an unknown access mode"
       in
       Ok { sel_reference; sel_source_text = source_text; sel_access }
     | _ -> Error "Skill editor read response is incomplete")
  | _ -> Error "Skill editor read response must be an object"
;;

let decode_skill_editor_save_receipt = function
  | `Assoc fields ->
    let snapshot_revision =
      match List.assoc_opt "snapshot_revision" fields with
      | Some (`String value) -> Some value
      | Some _ | None -> None
    in
    let status =
      match List.assoc_opt "status" fields with
      | Some (`String "unchanged") when Option.is_some snapshot_revision -> Ok Skill_unchanged
      | Some (`String "saved_and_published") when Option.is_some snapshot_revision -> Ok Skill_saved_and_published
      | Some (`String ("unchanged" | "saved_and_published")) -> Error "Published Skill save receipt has no snapshot revision"
      | Some (`String "saved_but_unpublished") ->
        (match List.assoc_opt "reason" fields with
         | Some (`String reason) -> Ok (Skill_saved_but_unpublished reason)
         | _ -> Error "Unpublished Skill save receipt has no reason")
      | Some (`String unknown) -> Error ("unknown Skill save status: " ^ unknown)
      | Some _ | None -> Error "Skill save status is missing"
    in
    let reference = preview_reference fields in
    (match status, reference with
     | Ok ses_status, Ok ses_reference ->
       Ok { ses_status; ses_reference; ses_snapshot_revision = snapshot_revision }
     | Error detail, _ -> Error detail
     | _, Error detail -> Error detail)
  | _ -> Error "Skill save response must be an object"
;;
