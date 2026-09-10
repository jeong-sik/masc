type t = Text of string | Artifact of Tool_output.artifact_ref
type error = Invalid of string | Unavailable of string
let of_args = function
  | `Assoc fields ->
    (match List.assoc_opt "content_artifact" fields, List.assoc_opt "content" fields with
     | Some _, Some _ -> Error (Invalid "Provide content or content_artifact, never both")
     | Some reference, None ->
       (match Tool_output.normalized_artifact_ref_of_json reference with
        | Tool_output.Decoded_normalized_artifact_ref reference ->
          (match List.assoc_opt "mode" fields with
           | Some (`String "overwrite") -> Ok (Artifact reference)
           | Some _ | None -> Error (Invalid "Artifact content requires overwrite mode"))
        | Tool_output.Invalid_normalized_artifact_ref {detail} -> Error (Invalid detail)
        | Tool_output.Not_normalized_artifact_ref -> Error (Invalid "Expected an exported artifact reference"))
     | None, Some (`String content) -> Ok (Text content)
     | None, None -> Ok (Text "")
     | None, Some _ -> Error (Invalid "content must be a string"))
  | _ -> Error (Invalid "Write arguments must be an object")
let bytes ~config = function
  | Text content -> Ok content
  | Artifact reference ->
    (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path:config.Workspace.base_path)
         ~sha256:reference.sha256 with
     | Error error -> Error (Unavailable (Tool_blob_store.fetch_error_to_string error))
     | Ok None -> Error (Unavailable "Write artifact is missing")
     | Ok (Some content) when String.length content = reference.bytes -> Ok content
     | Ok (Some _) -> Error (Unavailable "Write artifact size mismatch"))
let fields = function
  | Text content -> ["content", `String content]
  | Artifact reference -> ["content_artifact", Tool_output.normalized_artifact_ref_to_json reference]
let failure = function
  | Invalid detail -> Keeper_tool_execution.failure ~class_:Tool_result.Policy_rejection detail
  | Unavailable detail -> Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure detail
