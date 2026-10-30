open Result.Syntax

type source = Artifact of Keeper_peer_artifact_ref.t | Draft of string

type source_error =
  | Artifact_read_failed of string
  | Draft_rejected of Keeper_composition_draft.error
  | Frozen_surface_required

let request = function
  | `Assoc fields when List.length fields = 2 ->
    let* package_id = match List.assoc_opt "package_id" fields with
      | Some (`String directory) -> Skill_reference.package_id_of_directory directory
          |> Result.map_error (fun error -> "package_id " ^ Skill_reference.package_id_error_to_string error)
      | _ -> Error "string package_id is required" in
    let* source = match List.assoc_opt "artifact" fields, List.assoc_opt "draft_sha256" fields with
      | Some artifact, None -> Keeper_peer_artifact.reference artifact |> Result.map (fun artifact -> Artifact artifact)
      | None, Some (`String digest) -> Ok (Draft digest)
      | _ -> Error "exactly one of artifact or draft_sha256 is required" in
    Ok (source, package_id)
  | _ -> Error "Expected package_id and exactly one of artifact or draft_sha256"
;;

let resolve_source ~draft_context ~config ~package_id = function
  | Artifact artifact ->
    Keeper_peer_artifact.fetch ~config artifact
    |> Result.map (fun text -> text, artifact.Keeper_peer_artifact_ref.filename)
    |> Result.map_error (fun detail -> Artifact_read_failed detail)
  | Draft sha256 ->
    (match draft_context with
     | None -> Error Frozen_surface_required
     | Some (capability_surface, keeper_name) ->
       Keeper_composition_draft.load_authored ~base_path:config.Workspace.base_path
         ~capability_surface ~keeper_name ~package_id ~sha256
       |> Result.map (fun source -> source.Keeper_composition_draft.source_text, "SKILL.md")
       |> Result.map_error (fun error -> Draft_rejected error))
;;

let failure ~class_ ~code ~message fields =
  Keeper_tool_execution.failure_data
    ~class_
    ~effect_disposition:Tool_result.Proven_pre_effect
    ~message
    (`Assoc
       ([ "ok", `Bool false
        ; "error", `String code
        ; "message", `String message
        ]
        @ fields))
;;

(* The verdict names the exact bytes it judged by a digest computed here from
   the bytes [Keeper_peer_artifact.fetch] returned, never by the caller's
   reference metadata and never as a normalized artifact reference. A
   normalized reference anywhere in a result makes [Tool_projection.project_result]
   require a durable result manifest, and a manifest projection would replace
   this inline verdict with a blob marker whose preview is empty. Without the
   manifest every call failed as "tool output artifact storage failed"
   (#37493). *)
let source_identity ~filename source_text =
  `Assoc
    [ "sha256", `String Agent_core_sha256.(digest_string source_text |> to_hex)
    ; "bytes", `Int (String.length source_text)
    ; "filename", `String filename
    ]
;;

let handle ~descriptors ~draft_context ~config ~args =
  match request args with
  | Error message ->
    failure ~class_:Tool_result.Policy_rejection ~code:"invalid_skill_validation_request"
      ~message []
  | Ok (source, package_id) ->
    (match resolve_source ~draft_context ~config ~package_id source with
     | Error (Artifact_read_failed message) ->
       failure ~class_:Tool_result.Runtime_failure ~code:"artifact_read_failed" ~message []
     | Error Frozen_surface_required ->
       failure ~class_:Tool_result.Policy_rejection ~code:"frozen_surface_required"
         ~message:"Prepared Skill validation requires the caller's frozen surface" []
     | Error (Draft_rejected error) ->
       let detail = Keeper_composition_draft.error_to_json error in
       let class_ = Keeper_composition_draft.failure_class error in
       failure ~class_ ~code:"composition_draft_rejected"
         ~message:(Yojson.Safe.to_string detail) [ "draft_error", detail ]
     | Ok (source_text, filename) ->
       let directory = Skill_reference.package_id_to_string package_id in
       let identity =
         [ "source"
           , source_identity
               ~filename source_text
         ; "package_id", `String directory
         ; "validation", `String "static"
         ]
       in
       match Keeper_skill_catalog.validate_authored_source ~descriptors ~directory source_text with
       | Error (Source_too_large { bytes; max_bytes }) ->
         failure ~class_:Tool_result.Policy_rejection ~code:"source_too_large"
           ~message:(Printf.sprintf "Skill source is %d bytes; maximum is %d bytes" bytes max_bytes)
           (identity @ [ "bytes", `Int bytes; "max_bytes", `Int max_bytes ])
       | Error
           (Invalid_document
              (Keeper_skill_catalog.Body_too_large_to_read { bytes; max_bytes; _ }
               as error)) ->
         failure ~class_:Tool_result.Policy_rejection
           ~code:(Keeper_skill_catalog.error_code error)
           ~message:(Keeper_skill_catalog.error_to_string error)
           (identity @ [ "bytes", `Int bytes; "max_bytes", `Int max_bytes ])
       | Error
           (Invalid_document
              (( Keeper_skill_catalog.Definition_rejected _
               | Keeper_skill_catalog.Unterminated_composition_block _
               | Keeper_skill_catalog.Multiple_composition_blocks _
               | Keeper_skill_catalog.Composition_rejected _
               | Keeper_skill_catalog.Not_exactly_one_composition _
               | Keeper_skill_catalog.Composition_name_mismatch _
               | Keeper_skill_catalog.Composition_info_near_miss _
               | Keeper_skill_catalog.Duplicate_skill _
               | Keeper_skill_catalog.Body_blank _ ) as error)) ->
         failure ~class_:Tool_result.Policy_rejection
           ~code:(Keeper_skill_catalog.error_code error)
           ~message:(Keeper_skill_catalog.error_to_string error) identity
       | Ok skill ->
         Keeper_tool_execution.success_data
           (`Assoc
              (identity
               @ [ "ok", `Bool true
                 ; "kind", `String (Keeper_skill_catalog.surface_to_string skill.surface)
                 ; "name", `String skill.name
                 ; "description", `String skill.description
                 ])))
;;
