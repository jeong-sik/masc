type t = { blob : Tool_output.artifact_ref; filename : string; purpose : string }
let make ~blob ~filename ~purpose =
  if filename = "" || filename <> Filename.basename filename || filename = "." || filename = ".."
  then Error "Artifact filename must be one filename"
  else if String.trim purpose = "" then Error "Artifact purpose is required"
  else Ok {blob; filename; purpose}
let of_json = function
  | `Assoc fields when List.length fields = 3 ->
    (match List.assoc_opt "blob" fields, List.assoc_opt "filename" fields, List.assoc_opt "purpose" fields with
     | Some blob, Some (`String filename), Some (`String purpose) ->
       (match Tool_output.normalized_artifact_ref_of_json blob with
        | Tool_output.Decoded_normalized_artifact_ref blob -> make ~blob ~filename ~purpose
        | Tool_output.Invalid_normalized_artifact_ref {detail} -> Error detail
        | Tool_output.Not_normalized_artifact_ref -> Error "Artifact blob reference is required")
     | _ -> Error "Artifact needs blob, filename and purpose")
  | _ -> Error "Artifact must contain exactly blob, filename and purpose"
let to_json reference = `Assoc ["blob", Tool_output.normalized_artifact_ref_to_json reference.blob;
  "filename", `String reference.filename; "purpose", `String reference.purpose]
