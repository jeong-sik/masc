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
  let ( let* ) = Result.bind in
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
  ; sel_access : string
  ; sel_snapshot_revision : string
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
    (match
       List.assoc_opt "reference" fields,
       List.assoc_opt "source_text" fields,
       List.assoc_opt "access" fields,
       List.assoc_opt "snapshot_revision" fields
     with
     | Some reference_json, Some (`String source_text), Some (`String access),
       Some (`String snapshot_revision) ->
       (match Skill_reference.of_yojson reference_json with
        | Ok reference ->
          Ok
            { sel_reference = reference
            ; sel_source_text = source_text
            ; sel_access = access
            ; sel_snapshot_revision = snapshot_revision
            }
        | Error _ -> Error "Skill editor returned an invalid exact reference")
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
    let reason =
      match List.assoc_opt "reason" fields with
      | Some (`String value) -> value
      | Some _ | None -> "publication did not complete"
    in
    let status =
      match List.assoc_opt "status" fields with
      | Some (`String "unchanged") -> Ok Skill_unchanged
      | Some (`String "saved_and_published") -> Ok Skill_saved_and_published
      | Some (`String "saved_but_unpublished") ->
        Ok (Skill_saved_but_unpublished reason)
      | Some (`String unknown) -> Error ("unknown Skill save status: " ^ unknown)
      | Some _ | None -> Error "Skill save status is missing"
    in
    let reference =
      match List.assoc_opt "preview" fields with
      | Some (`Assoc preview_fields) ->
        (match List.assoc_opt "reference" preview_fields with
         | Some json -> Skill_reference.of_yojson json
         | None -> Error (Skill_reference.Missing_field
                            { object_name = "preview"; field = "reference" }))
      | Some _ | None ->
        Error
          (Skill_reference.Missing_field
             { object_name = "Skill save response"; field = "preview" })
    in
    (match status, reference with
     | Ok ses_status, Ok ses_reference ->
       Ok { ses_status; ses_reference; ses_snapshot_revision = snapshot_revision }
     | Error detail, _ -> Error detail
     | _, Error _ -> Error "Skill save response reference is invalid")
  | _ -> Error "Skill save response must be an object"
;;
