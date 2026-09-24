let ( let* ) = Result.bind

let request = function
  | `Assoc fields when List.length fields = 2 ->
    (match List.assoc_opt "artifact" fields, List.assoc_opt "package_id" fields with
     | Some artifact, Some (`String directory) ->
       let* artifact = Keeper_peer_artifact.reference artifact in
       let* package_id =
         Skill_reference.package_id_of_directory directory
         |> Result.map_error (fun error ->
           "package_id " ^ Skill_reference.package_id_error_to_string error)
       in
       Ok (artifact, package_id)
     | _ -> Error "artifact and string package_id are required")
  | _ -> Error "Expected exactly artifact and package_id"
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
   normalized reference anywhere in a result makes [Tool_bridge.project_result]
   require a durable result manifest, and a manifest projection would replace
   this inline verdict with a blob marker whose preview is empty. Without the
   manifest every call failed as "tool output artifact storage failed"
   (#37493). *)
let source_identity ~filename source_text =
  `Assoc
    [ "sha256", `String Digestif.SHA256.(digest_string source_text |> to_hex)
    ; "bytes", `Int (String.length source_text)
    ; "filename", `String filename
    ]
;;

let handle ~config ~args =
  match request args with
  | Error message ->
    failure ~class_:Tool_result.Policy_rejection ~code:"invalid_skill_validation_request"
      ~message []
  | Ok (artifact, package_id) ->
    (match Keeper_peer_artifact.fetch ~config artifact with
     | Error message ->
       failure ~class_:Tool_result.Runtime_failure ~code:"artifact_read_failed" ~message []
     | Ok source_text ->
       let directory = Skill_reference.package_id_to_string package_id in
       let identity =
         [ "source"
           , source_identity
               ~filename:artifact.Keeper_peer_artifact_ref.filename
               source_text
         ; "package_id", `String directory
         ; "validation", `String "static"
         ]
       in
       match Keeper_skill_catalog.validate_authored_source ~directory source_text with
       | Error (Source_too_large { bytes; max_bytes }) ->
         failure ~class_:Tool_result.Policy_rejection ~code:"source_too_large"
           ~message:(Printf.sprintf "Skill source is %d bytes; maximum is %d bytes" bytes max_bytes)
           (identity @ [ "bytes", `Int bytes; "max_bytes", `Int max_bytes ])
       | Error (Invalid_document error) ->
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
