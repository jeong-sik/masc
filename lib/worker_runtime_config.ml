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

let trim_opt value =
  match value with
  | None -> None
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed

let backend_of_env () =
  match Sys.getenv_opt "MASC_WORKER_RUNTIME_BACKEND" |> trim_opt with
  | Some raw -> Worker_execution_backend.of_string raw
  | None -> None

let env_image_opt () =
  Sys.getenv_opt "MASC_WORKER_RUNTIME_DOCKER_IMAGE" |> trim_opt

let env_host_mcp_base_url_opt () =
  Sys.getenv_opt "MASC_WORKER_RUNTIME_HOST_MCP_BASE_URL" |> trim_opt

let load_file_config path =
  if Sys.file_exists path then
    try
      let json = Safe_ops.read_json_eio path in
        let open Yojson.Safe.Util in
        let spawn_json = member "worker_spawn" json in
        let backend =
          match spawn_json |> member "backend" with
          | `String value -> (
              match Worker_execution_backend.of_string value with
              | Some backend -> backend
              | None -> default.worker_spawn.backend)
          | _ -> default.worker_spawn.backend
        in
        let docker_json = spawn_json |> member "docker" in
        let image =
          match docker_json |> member "image" with
          | `String value when String.trim value <> "" -> value
          | _ -> default.worker_spawn.docker.image
        in
        let host_mcp_base_url =
          match docker_json |> member "host_mcp_base_url" with
          | `String value ->
              let trimmed = String.trim value in
              if trimmed = "" then None else Some trimmed
          | _ -> None
        in
        {
          worker_spawn =
            {
              backend;
              docker = { image; host_mcp_base_url };
            };
        }
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
        Log.CmdPlane.warn "worker-runtime config malformed at %s: %s" path
          (Printexc.to_string exn);
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
