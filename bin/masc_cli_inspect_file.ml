open Masc

let run ~base_path ~path =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs env#fs;
  (* Inspector captures use absolute paths in the selected workspace, which
     can be outside the invoking shell's restricted cwd capability. *)
  Process_eio.init ~cwd_default:Eio.Path.(env#fs / Sys.getcwd ())
    ~proc_mgr:env#process_mgr ~clock:env#clock;
  let base_path = Env_config_core.normalize_masc_base_path_input base_path in
  let absolute path = if path = "" then path else if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path in
  let base_path = absolute base_path in
  let path = absolute path in
  let start_time = Time_compat.now () in
  let name = "inspect-file" in
  let error class_ message = Tool_result.error ~failure_class:class_ ~tool_name:name ~start_time message in
  let source = ref `Null in
  let result =
    try
      if base_path = "" || String.trim path = "" then
        error Tool_result.Workflow_rejection "Workspace and input file paths must be nonempty"
      else
      match Fs_compat.load_owned_regular_file ~ownership_root:(Filename.dirname path) path with
      | Error detail ->
        let class_ = match detail.Fs_compat.failure with
          | Ownership_boundary_rejected _ | Path_is_not_regular_file _ -> Tool_result.Policy_rejection
          | Filesystem_identity_changed _ | Owned_file_operation_failed _ -> Tool_result.Runtime_failure in
        error class_ (Fs_compat.owned_regular_file_read_error_to_string detail)
      | Ok None -> error Tool_result.Workflow_rejection "Selected input file does not exist"
      | Ok (Some bytes) ->
        source := `Assoc ["path",`String path;"bytes",`Int (String.length bytes);
          "sha256",`String Digestif.SHA256.(digest_string bytes |> to_hex)];
        (match Verification_media_inspection.detect ~path ~bytes with
         | None -> error Tool_result.Workflow_rejection "Supported whole-file inspection formats are PDF, PPTX and MP4"
         | Some kind ->
           Verification_media_inspection.inspect kind ~base_path ~name ~path ~bytes ~start_time
             ~max_image_bytes:(Env_config_keeper.KeeperVision.max_image_bytes ()))
    with
    | Sys_error detail -> error Tool_result.Runtime_failure detail
    | Unix.Unix_error (code,operation,_) -> error Tool_result.Runtime_failure
        (operation ^ ": " ^ Unix.error_message code)
  in
  let result, content = match result with
    | Tool_result.Completed output ->
      (match Runtime_official_client_tool.mcp_content
          ~content:(Tool_result.message result) ~content_blocks:output.content_blocks with
       | Ok content -> result, content
       | Error detail -> error Tool_result.Runtime_failure detail, [])
    | Tool_result.Failed _ -> result, []
    | Tool_result.Deferred _ -> error Tool_result.Runtime_failure "File inspection unexpectedly deferred", []
  in
  print_endline (Yojson.Safe.to_string (`Assoc [
    "schema",`String "masc.operator_file_inspection.v1";
    "base_path",`String base_path;"source",!source;
    "llm_verdict",`String "not_run";
    "result",Tool_result.to_json result;"content",`List content]));
  match result with Tool_result.Completed _ -> 0 | Tool_result.Failed _ | Tool_result.Deferred _ -> 1
