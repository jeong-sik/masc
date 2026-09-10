type reference = Reference of string
type error = Invalid_reference | Private_storage_unavailable | Import_failed | Scope_mismatch
let error_message = function
  | Invalid_reference -> "Select an imported account again."
  | Private_storage_unavailable -> "Private account storage could not be read or prepared."
  | Import_failed -> "Sign in to the selected CLI on this computer, then import that account again."
  | Scope_mismatch -> "This account reference belongs to another workspace or CLI. Import the account explicitly here."
let ( let* ) = Result.bind
let reference_to_string (Reference value) = value
let reference_of_string value = if Auth.is_generated_token_shape value then Ok (Reference value) else Error Invalid_reference
type imported = { credential_file:string; timeout_s:float; catalog:Yojson.Safe.t }
type binding = { credential_file:string; timeout_s:float }
let filesystem action = try action () with Unix.Unix_error _ | Sys_error _ -> Error Private_storage_unavailable
let directory ~create path =
  if create then (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST,_,_) -> ());
  let info=Unix.lstat path in
  if info.st_kind=Unix.S_DIR && info.st_uid=Unix.geteuid () && info.st_perm land 0o077=0
  then Ok () else Error Private_storage_unavailable
let root ~create () =
  match Env_config_core.default_base_path_record_path_opt () with
  | None -> Error Private_storage_unavailable
  | Some record ->
    let parent=Filename.dirname record in
    if Filename.is_relative parent then Error Private_storage_unavailable else
    let credentials=Filename.concat parent "credentials" in
    let accounts=Filename.concat credentials "setup-accounts" in
    if create then Fs_compat.mkdir_p parent;
    let* ()=directory ~create credentials in
    let* ()=directory ~create accounts in Ok (Unix.realpath accounts)
let owned_read root path =
  match Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root:root path with
  | Ok (Some file) when file.snapshot.owner_uid=Unix.geteuid () && file.snapshot.permissions land 0o077=0 -> Ok file.content
  | _ -> Error Private_storage_unavailable
let credential ~directory path =
  if Filename.is_relative path then Error Import_failed else
  let canonical=Unix.realpath path in
  if not (String.starts_with ~prefix:(directory ^ Filename.dir_sep) canonical) then Error Import_failed else
  let* contents=owned_read directory path in
  if contents="" then Error Import_failed else Ok canonical
let manifest directory = Filename.concat directory "reference.json"
let create ~workspace ~integration_id ~cli_path ~import = filesystem (fun () ->
  let workspace=Unix.realpath workspace in
  let* root=root ~create:true () in
  Eio.Switch.run (fun sw ->
    let reference=Reference (Auth.generate_token ()) in
    let directory_path=Filename.concat root (reference_to_string reference) in
    Unix.mkdir directory_path 0o700;
    let retained=ref false in
    Eio.Switch.on_release sw (fun () -> if not !retained then Fs_compat.remove_tree directory_path);
    let* (imported:imported)=import ~base_path:directory_path in
    let* credential_file=credential ~directory:directory_path imported.credential_file in
    if not (Float.is_finite imported.timeout_s && imported.timeout_s>0.) then Error Import_failed else
    let data=`Assoc ["schema",`String "masc.setup_account_reference.v1";
      "workspace",`String workspace;"integration_id",`String integration_id;"cli_path",`String cli_path;
      "credential_file",`String credential_file;"timeout_s",`Float imported.timeout_s] in
    Auth.save_private_text_file (manifest directory_path) (Yojson.Safe.to_string data);
    retained:=true;
    Ok (reference,imported.catalog)))
let resolve ~workspace ~integration_id ~cli_path (Reference reference) = filesystem (fun () ->
  let workspace=Unix.realpath workspace in
  let* root=root ~create:false () in
  let directory_path=Filename.concat root reference in
  let* ()=directory ~create:false directory_path in
  let* contents=owned_read directory_path (manifest directory_path) in
  let decoded=try Some (Yojson.Safe.from_string contents) with Yojson.Json_error _ -> None in
  match decoded with
  | Some (`Assoc fields) when List.sort String.compare (List.map fst fields)=
      List.sort String.compare ["schema";"workspace";"integration_id";"cli_path";"credential_file";"timeout_s"] ->
    let value key=List.assoc key fields in
    if value "schema"<>`String "masc.setup_account_reference.v1" then Error Invalid_reference
    else if value "workspace"<>`String workspace || value "integration_id"<>`String integration_id || value "cli_path"<>`String cli_path
    then Error Scope_mismatch else
    (match value "credential_file",value "timeout_s" with
     | `String path,`Float timeout_s when Float.is_finite timeout_s && timeout_s>0. ->
       let* credential_file=credential ~directory:directory_path path in Ok {credential_file;timeout_s}
     | _ -> Error Invalid_reference)
  | _ -> Error Invalid_reference)
