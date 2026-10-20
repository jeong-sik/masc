let reference (artifact:Tool_output.artifact_ref) =
  `Assoc ["reference",Tool_output.normalized_artifact_ref_to_json artifact;
    "reader",`String "keeper_artifact_read";
    "arguments",`Assoc ["sha256",`String artifact.sha256];"bytes",`Int artifact.bytes]
let publish ~base_path path =
  try
    let artifact = Tool_blob_store.put_file_durable
        (Tool_blob_store.create ~base_path) ~path ~mime:"application/octet-stream" in
    Ok (reference artifact)
  with Sys_error detail -> Error detail

let publish_descriptor ~store ~socket descriptor =
  try Eio_unix.run_in_systhread (fun () ->
    Browser_addon_socket.with_download_snapshot socket descriptor (fun source ->
      let artifact=Tool_blob_store.put_file_descriptor_durable_blocking store ~source
        ~expected_sha256:descriptor.Browser_addon_downloads.sha256 ~mime:"application/octet-stream" in
      if artifact.bytes<>descriptor.bytes then Error "download snapshot byte count changed"
      else Ok (reference artifact)))
  with (Sys_error _|Unix.Unix_error _) as exn -> Error (Printexc.to_string exn)
