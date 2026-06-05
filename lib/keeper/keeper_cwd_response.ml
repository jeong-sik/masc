type t =
  | Local of { abs : string }
  | Sandboxed of { host_abs : string; container_abs : string }

let local ~host_cwd = Local { abs = host_cwd }

let docker ~host_cwd ~container_cwd =
  Sandboxed { host_abs = host_cwd; container_abs = container_cwd }

let of_sandbox ~(sandbox : Keeper_sandbox.t) ~host_cwd
    ~container_cwd_for_docker =
  match sandbox.backend with
  | Keeper_sandbox.Local -> local ~host_cwd
  | Keeper_sandbox.Docker ->
    docker ~host_cwd ~container_cwd:container_cwd_for_docker

let profile_independent_cwd ~container_root ~host_cwd =
  (* When Execute returns a container-side path for Docker keepers,
     use it directly — the path is already correct in container terms
     and doesn't need host-to-container conversion. *)
  if String.length container_root = 0 then None
  else if host_cwd = container_root then Some host_cwd
  else
    let prefix = container_root ^ "/" in
    if String.starts_with ~prefix host_cwd then Some host_cwd
    else None

let keeper_visible = function
  | Local { abs } -> abs
  | Sandboxed { container_abs; _ } -> container_abs

let operator_host = function
  | Local { abs } -> abs
  | Sandboxed { host_abs; _ } -> host_abs

let to_yojson_response t = `String (keeper_visible t)
