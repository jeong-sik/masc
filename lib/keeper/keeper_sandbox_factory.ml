type resolve_result =
  | Runtime of Keeper_turn_sandbox_runtime.t
  | No_factory
  | Local_profile
  | Remote_ssh_profile

type t = {
  config : Workspace.config;
  meta : Keeper_meta_contract.keeper_meta;
  default_network_override : Keeper_types_profile_sandbox.network_mode option;
  cache :
    ((bool * string * string * string), Keeper_turn_sandbox_runtime.t) Hashtbl.t;
  mutex : Eio.Mutex.t;
}

let create ?default_network_override
    ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) () =
  {
    config;
    meta;
    default_network_override;
    cache = Hashtbl.create 4;
    mutex = Eio.Mutex.create ();
  }

let with_lock (t : t) f =
  Eio.Mutex.use_rw ~protect:true t.mutex f

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

let normalize p =
  Keeper_alerting_path.normalize_path_for_check p
  |> strip_trailing_slashes

let runtime_image (meta : Keeper_meta_contract.keeper_meta) =
  match meta.sandbox_image with
  | Some img when String.trim img <> "" -> img
  | _ -> Env_config_sandbox.Runtime.docker_image ()

let in_playground_of_cwd (t : t) ~meta ~cwd =
  let host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config:t.config meta
    |> normalize
  in
  let cwd_norm = normalize cwd in
  String.equal cwd_norm host_root
  || String.starts_with ~prefix:(host_root ^ "/") cwd_norm

let resolve (t : t) ~cwd =
  with_lock t (fun () ->
    let meta = t.meta in
    let in_playground = in_playground_of_cwd t ~meta ~cwd in
    let (effective_profile, effective_network) =
      Keeper_sandbox_runner.effective_sandbox_profile ~meta
    in
    let actual_network =
      Option.value t.default_network_override ~default:effective_network
    in
    match effective_profile with
    | Keeper_types_profile_sandbox.Local -> Local_profile
    (* Distinct from [Local_profile]: callers must not read this as
       "host execution is fine". Docker-shaped consumers fail closed on
       this constructor; SSH dispatch has its own path. *)
    | Keeper_types_profile_sandbox.Remote_ssh -> Remote_ssh_profile
    (* Both guest profiles share the runtime value; the runtime itself
       branches on [meta.sandbox_profile] for every CLI it builds (start,
       exec, inspect, stop), so a VM keeper's commands run under Apple's
       [container] and are never handed to docker (#31225, #31178). *)
    | Keeper_types_profile_sandbox.Micro_vm | Keeper_types_profile_sandbox.Docker ->
      let host_root =
        Keeper_sandbox.host_root_abs_of_meta ~config:t.config meta
        |> normalize
      in
      let image = runtime_image meta in
      let key =
        ( in_playground
        , Keeper_types_profile_sandbox.network_mode_to_string actual_network
        , host_root
        , image )
      in
      match Hashtbl.find_opt t.cache key with
      | Some r -> Runtime r
      | None ->
        let r =
          Keeper_turn_sandbox_runtime.create
            ~config:t.config
            ~meta
            ~network_mode:actual_network
            ()
        in
        Hashtbl.add t.cache key r;
        Runtime r)

let resolve_opt t_opt ~cwd =
  match t_opt with
  | None -> No_factory
  | Some t -> resolve t ~cwd

let cleanup (t : t) =
  if Hashtbl.length t.cache = 0 then ()
  else
    with_lock t (fun () ->
      Hashtbl.iter
        (fun _ r -> Keeper_turn_sandbox_runtime.cleanup r)
        t.cache;
      Hashtbl.reset t.cache)
