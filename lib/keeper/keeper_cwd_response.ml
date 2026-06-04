type t =
  | Local of { abs : string }
  | Sandboxed of { host_abs : string; container_abs : string }

let local ~host_cwd = Local { abs = host_cwd }

let docker ~host_cwd ~container_cwd =
  Sandboxed { host_abs = host_cwd; container_abs = container_cwd }

let init ~backend ~host_cwd ~container_cwd_for_docker =
  match backend with
  | "local" -> local ~host_cwd
  | "docker" ->
    docker ~host_cwd ~container_cwd:container_cwd_for_docker
  | _ ->
    Log.Keeper.warn (fun m ->
      m "Keeper_cwd_response.init: unknown backend %S, falling back to local"
        backend);
    local ~host_cwd

let of_sandbox ~(sandbox : Keeper_sandbox.t) ~host_cwd
    ~container_cwd_for_docker =
  init ~backend:(Keeper_sandbox.backend_name sandbox) ~host_cwd
    ~container_cwd_for_docker

let keeper_visible = function
  | Local { abs } -> abs
  | Sandboxed { container_abs; _ } -> container_abs

let operator_host = function
  | Local { abs } -> abs
  | Sandboxed { host_abs; _ } -> host_abs

let to_yojson_response t = `String (keeper_visible t)
