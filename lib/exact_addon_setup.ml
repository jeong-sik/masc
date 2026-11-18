open Result.Syntax

type scope = Every_carried | Declared

type image_outcome = Built | Already_built

type installed = {
  manifest_path : string;
  folder : Lane_addon_carried.folder_outcome;
  image : string;
  image_outcome : image_outcome;
}

type failure =
  | Folder of Lane_addon_carried.install_error
  | Manifest_unloadable of { path : string; reason : string }
  | Image_not_built of { image : string; reason : string }

type report = { package : Lane_addon_carried.id; result : (installed, failure) result }

type outcome = { reports : report list; unread : Lane_addon_config.issue list }

type error =
  | Base_path_not_absolute of string
  | Config_root_invalid of string

let io_detail = function
  | Unix.Unix_error (error, call, arg) -> call ^ " " ^ arg ^ ": " ^ Unix.error_message error
  | Sys_error message -> message
  | exn -> raise exn

let status_detail = function
  | Unix.WEXITED code -> Printf.sprintf "exited with %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "was killed by signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "was stopped by signal %d" signal

(* [docker image inspect] prints the labels as a JSON object, or null for an
   image without labels. Anything but this label with [digest] means build:
   an absent image, an engine that does not answer, another label. The
   build that follows reports what is wrong. *)
let holds_label ~docker ~image digest =
  match
    With_process.with_process_args_in docker
      [| docker; "image"; "inspect"; "--format"; "{{json .Config.Labels}}"; image |]
      In_channel.input_all
  with
  | raw, Unix.WEXITED 0 ->
    (match Yojson.Safe.from_string raw with
     | `Assoc labels -> List.assoc_opt Lane_addon_carried.image_label labels = Some (`String digest)
     | _ -> false
     | exception Yojson.Json_error _ -> false)
  | _, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) -> false
  | exception (Unix.Unix_error _ | Sys_error _) -> false

let write_context context files =
  List.iter (fun (file : Lane_addon_carried.file) ->
      Out_channel.with_open_bin (Filename.concat context file.path)
        (fun channel -> Out_channel.output_string channel file.contents))
    files

(* The context holds the image inputs and nothing else, laid out as the
   Dockerfile reads them, so the label names everything the image is built
   from. [--quiet] leaves the terminal to docker's errors. *)
let build ~docker ~image id =
  let digest = Lane_addon_carried.image_digest id in
  if holds_label ~docker ~image digest then Ok Already_built
  else
    match Filename.temp_dir "masc-exact-image-" "" with
    | exception Sys_error reason -> Error (Image_not_built { image; reason })
    | context ->
      let result =
        match
          write_context context (Lane_addon_carried.image_inputs id);
          With_process.with_process_args_in docker
            [| docker; "build"; "--quiet"; "--label"; Lane_addon_carried.image_label ^ "=" ^ digest;
               "--tag"; image; context |]
            In_channel.input_all
        with
        | _, Unix.WEXITED 0 -> Ok Built
        | _, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ as status) ->
          Error (Image_not_built { image; reason = "docker build " ^ status_detail status })
        | exception ((Unix.Unix_error _ | Sys_error _) as exn) ->
          Error (Image_not_built { image; reason = io_detail exn })
      in
      (* The context is in the system's temporary directory and holds only
         carried files. One that cannot be removed is left to the system. *)
      (match Fs_compat.remove_tree context with
       | () -> ()
       | exception (Unix.Unix_error _ | Sys_error _) -> ());
      result

let install ~docker ~packages id =
  let* manifest_path, folder = Lane_addon_carried.install ~packages id
    |> Result.map_error (fun error -> Folder error) in
  let* package = Lane_addon_manifest.load ~path:manifest_path
    |> Result.map_error (fun error ->
        Manifest_unloadable { path = manifest_path; reason = Lane_addon_manifest.error_to_string error }) in
  let* container = Lane_addon_types.container package
    |> Result.map_error (fun reason -> Manifest_unloadable { path = manifest_path; reason }) in
  let image = container.Lane_addon_types.image in
  let* image_outcome = match container.Lane_addon_types.runtime with
    | Lane_addon_types.Docker -> build ~docker ~image id
    | Lane_addon_types.Apple_container ->
      Error (Image_not_built { image; reason = "the package runs on Apple container; this setup builds Docker images" }) in
  Ok { manifest_path; folder; image; image_outcome }

(* The declarations are read where the server reads them. *)
let selected ~base_path = function
  | Every_carried -> Ok (Lane_addon_carried.all, [])
  | Declared ->
    let resolution = Config_dir_resolver.resolve_for_base_path ~base_path in
    (match resolution.Config_dir_resolver.status with
     | Config_dir_resolver.Invalid_env_status ->
       Error (Config_root_invalid (String.concat "; " resolution.warnings))
     | Config_dir_resolver.Missing_status -> Ok ([], [])
     | Config_dir_resolver.Ready | Config_dir_resolver.Warn ->
       Ok (Lane_addon_config.declared_carried
             ~directory:(Lane_addon_config.directory ~config_root:resolution.config_root.path)))

let run ~base_path ~docker ~scope =
  if Filename.is_relative base_path then Error (Base_path_not_absolute base_path)
  else
    let* chosen, unread = selected ~base_path scope in
    let packages = Config_dir_resolver.packages_dir ~base_path in
    Ok { reports = List.map (fun id -> { package = id; result = install ~docker ~packages id }) chosen;
         unread }

let error_message = function
  | Base_path_not_absolute path -> "the base path is not absolute: " ^ path
  | Config_root_invalid detail -> "the workspace's config root is invalid: " ^ detail

let folder_word = function
  | Lane_addon_carried.Written -> "written"
  | Lane_addon_carried.Already_installed -> "already installed"

let image_word = function Built -> "built" | Already_built -> "already built"

let failure_message id = function
  | Folder error -> Lane_addon_carried.install_error_to_string id error
  | Manifest_unloadable { path; reason } -> Printf.sprintf "%s does not load: %s" path reason
  | Image_not_built { image; reason } -> Printf.sprintf "image %s was not built: %s" image reason

let report_line { package; result } =
  let name = Lane_addon_carried.name package in
  match result with
  | Ok { manifest_path; folder; image; image_outcome } ->
    Printf.sprintf "%s: %s %s, image %s %s" name (Filename.dirname manifest_path)
      (folder_word folder) image (image_word image_outcome)
  | Error failure -> Printf.sprintf "%s: %s" name (failure_message package failure)

let unread_line (issue : Lane_addon_config.issue) =
  Printf.sprintf "%s was not read: %s" issue.source_path issue.message
