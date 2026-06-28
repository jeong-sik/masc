type docker_config = {
  image : string;
  host_mcp_base_url : string option;
}

type worker_spawn = {
  backend : Worker_execution_backend.t;
  docker : docker_config;
}

type t = {
  worker_spawn : worker_spawn;
}

let default =
  {
    worker_spawn =
      {
        backend = Worker_execution_backend.Local_playground;
        docker =
          {
            image = "masc-worker-runtime:dev";
            host_mcp_base_url = None;
          };
      };
  }

let malformed_fail_closed =
  {
    worker_spawn =
      {
        backend = Worker_execution_backend.Docker;
        docker =
          {
            image = "";
            host_mcp_base_url = None;
          };
      };
  }

let trim_opt = Env_config_core.trim_opt

let backend_of_env () =
  match Sys.getenv_opt "MASC_WORKER_RUNTIME_BACKEND" |> trim_opt with
  | Some raw -> Worker_execution_backend.of_string raw
  | None -> None

let env_image_opt () =
  Sys.getenv_opt "MASC_WORKER_RUNTIME_DOCKER_IMAGE" |> trim_opt

let env_host_mcp_base_url_opt () =
  Sys.getenv_opt "MASC_WORKER_RUNTIME_HOST_MCP_BASE_URL" |> trim_opt

let optional_object_field ~label key json =
  match Json_util.assoc_member_opt key json with
  | None -> Ok None
  | Some (`Assoc _ as value) -> Ok (Some value)
  | Some other ->
      Error
        (Printf.sprintf "field %s must be an object, got %s" label
           (Json_util.kind_name other))

let parse_backend_field spawn_json =
  match Json_util.assoc_member_opt "backend" spawn_json with
  | None -> Ok default.worker_spawn.backend
  | Some (`String value) -> (
      match Worker_execution_backend.of_string value with
      | Some backend -> Ok backend
      | None ->
          Error
            (Printf.sprintf
               "field worker_spawn.backend has unknown value %S" value))
  | Some other ->
      Error
        (Printf.sprintf "field worker_spawn.backend must be a string, got %s"
           (Json_util.kind_name other))

let parse_docker_image_field docker_json =
  match Json_util.assoc_member_opt "image" docker_json with
  | None -> Ok default.worker_spawn.docker.image
  | Some (`String value) ->
      let trimmed = String.trim value in
      if trimmed = "" then
        Error "field worker_spawn.docker.image must be non-empty when present"
      else if not (String.equal trimmed value) then
        Error "field worker_spawn.docker.image must not contain edge whitespace"
      else Ok value
  | Some other ->
      Error
        (Printf.sprintf "field worker_spawn.docker.image must be a string, got %s"
           (Json_util.kind_name other))

let parse_host_mcp_base_url_field docker_json =
  match Json_util.assoc_member_opt "host_mcp_base_url" docker_json with
  | None | Some `Null -> Ok None
  | Some (`String value) ->
      let trimmed = String.trim value in
      Ok (if trimmed = "" then None else Some trimmed)
  | Some other ->
      Error
        (Printf.sprintf
           "field worker_spawn.docker.host_mcp_base_url must be a string or null, got %s"
           (Json_util.kind_name other))

let parse_docker_config_field spawn_json =
  let ( let* ) = Result.bind in
  let* docker_json =
    optional_object_field ~label:"worker_spawn.docker" "docker" spawn_json
  in
  match docker_json with
  | None -> Ok default.worker_spawn.docker
  | Some docker_json ->
      let* image = parse_docker_image_field docker_json in
      let* host_mcp_base_url = parse_host_mcp_base_url_field docker_json in
      Ok { image; host_mcp_base_url }

let parse_file_config json =
  let ( let* ) = Result.bind in
  let* spawn_json =
    optional_object_field ~label:"worker_spawn" "worker_spawn" json
  in
  match spawn_json with
  | None -> Ok default
  | Some spawn_json ->
      let* backend = parse_backend_field spawn_json in
      let* docker = parse_docker_config_field spawn_json in
      Ok { worker_spawn = { backend; docker } }

let load_file_config path =
  if Sys.file_exists path then
    match Safe_ops.read_json_file_safe path with
    | Ok (`Assoc _ as json) -> (
        match parse_file_config json with
        | Ok config -> config
        | Error msg ->
            Log.CmdPlane.warn "worker-runtime config malformed at %s: %s" path
              msg;
            malformed_fail_closed)
    | Ok _ ->
        Log.CmdPlane.warn
          "worker-runtime config malformed at %s: expected JSON object" path;
        malformed_fail_closed
    | Error msg ->
        Log.CmdPlane.warn "worker-runtime config malformed at %s: %s" path msg;
        malformed_fail_closed
  else default

let apply_env_overrides (config : t) =
  let backend =
    match backend_of_env () with
    | Some backend -> backend
    | None -> config.worker_spawn.backend
  in
  let image =
    match env_image_opt () with
    | Some image -> image
    | None -> config.worker_spawn.docker.image
  in
  let host_mcp_base_url =
    match env_host_mcp_base_url_opt () with
    | Some value -> Some value
    | None -> config.worker_spawn.docker.host_mcp_base_url
  in
  {
    worker_spawn =
      {
        backend;
        docker = { image; host_mcp_base_url };
      };
  }

let cached : t option ref = ref None

let config_path resolution =
  Filename.concat resolution.Config_dir_resolver.config_root.path
    "worker-runtime.json"

let resolve () =
  match !cached with
  | Some config -> config
  | None ->
      let resolution = Config_dir_resolver.resolve () in
      let config = load_file_config (config_path resolution) |> apply_env_overrides in
      cached := Some config;
      config

let reset () =
  cached := None

let backend () =
  (resolve ()).worker_spawn.backend

let docker_image () =
  (resolve ()).worker_spawn.docker.image

let host_mcp_base_url_opt () =
  (resolve ()).worker_spawn.docker.host_mcp_base_url
