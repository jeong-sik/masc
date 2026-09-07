let publish ~base_path path =
  try
    let artifact = Tool_blob_store.put_file_durable
        (Tool_blob_store.create ~base_path) ~path ~mime:"application/octet-stream" in
    Ok (`Assoc ["reference", Tool_output.normalized_artifact_ref_to_json artifact;
      "reader", `String "keeper_artifact_read";
      "arguments", `Assoc ["sha256", `String artifact.sha256];
      "bytes", `Int artifact.bytes])
  with Sys_error detail -> Error detail
