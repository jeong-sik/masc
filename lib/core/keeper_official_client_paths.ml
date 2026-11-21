let state_dirname = "official-client-runtime"
let outbox_dirname = "undelivered-tools"
let consumed_results_dirname = "consumed-tool-results"

let state_dir ~base_path ~keeper_name =
  if not (Safe_identifier.is_portable_name keeper_name)
  then Error (Printf.sprintf "invalid official-client Keeper name %S" keeper_name)
  else
    Ok
      (Filename.concat
         (Filename.concat
            (Common.keepers_runtime_dir_of_base ~base_path)
            keeper_name)
         state_dirname)

let outbox_dir ~base_path ~keeper_name =
  Result.map (fun directory -> Filename.concat directory outbox_dirname)
    (state_dir ~base_path ~keeper_name)

let consumed_results_dir ~base_path ~keeper_name =
  Result.map (fun directory -> Filename.concat directory consumed_results_dirname)
    (state_dir ~base_path ~keeper_name)

type tool_result_source = Tool_result_source of string

let tool_result_source ~base_path ~path =
  let directory = Filename.dirname path in
  let keeper_name = Filename.basename (Filename.dirname (Filename.dirname directory)) in
  match state_dir ~base_path ~keeper_name with
  | Ok state when
      (String.equal directory (Filename.concat state outbox_dirname)
       || String.equal directory (Filename.concat state consumed_results_dirname))
      && String.equal path (Filename.concat directory (Filename.basename path)) ->
      Some (Tool_result_source path)
  | Ok _ | Error _ -> None

let tool_result_source_path (Tool_result_source path) = path
