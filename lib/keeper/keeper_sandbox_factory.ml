type t = {
  config : Coord.config;
  meta : Keeper_types.keeper_meta;
  default_network_override : Keeper_types.network_mode option;
  cache :
    ((bool * string), Keeper_turn_sandbox_runtime.t) Hashtbl.t;
  mutex : Mutex.t;
}

let create ?default_network_override
    ~(config : Coord.config) ~(meta : Keeper_types.keeper_meta) () =
  {
    config;
    meta;
    default_network_override;
    cache = Hashtbl.create 4;
    mutex = Mutex.create ();
  }

let with_lock (t : t) f =
  Mutex.lock t.mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock t.mutex)
    f

let strip_trailing_slashes path =
  let rec loop i =
    if i > 0 && path.[i - 1] = '/' then loop (i - 1) else i
  in
  let len = loop (String.length path) in
  if len = String.length path then path else String.sub path 0 len

let normalize p =
  Keeper_alerting_path.normalize_path_for_check p
  |> strip_trailing_slashes

let in_playground_of_cwd (t : t) ~cwd =
  let host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config:t.config t.meta
    |> normalize
  in
  let cwd_norm = normalize cwd in
  String.equal cwd_norm host_root
  || String.starts_with ~prefix:(host_root ^ "/") cwd_norm

let resolve (t : t) ~cwd =
  with_lock t (fun () ->
    let in_playground = in_playground_of_cwd t ~cwd in
    let cwd_norm = normalize cwd in
    let key = (in_playground, cwd_norm) in
    match Hashtbl.find_opt t.cache key with
    | Some r -> Some r
    | None ->
      let (effective_profile, effective_network) =
        Keeper_shell_docker.effective_sandbox_profile
          ~meta:t.meta ~in_playground
      in
      let actual_network =
        Option.value t.default_network_override ~default:effective_network
      in
      (match effective_profile with
       | Keeper_types.Docker ->
         let r =
           Keeper_turn_sandbox_runtime.create
             ~config:t.config
             ~meta:t.meta
             ~network_mode:actual_network
             ()
         in
         Hashtbl.add t.cache key r;
         Some r
       | Keeper_types.Local -> None))

let resolve_opt t_opt ~cwd =
  Option.bind t_opt (fun t -> resolve t ~cwd)

let cleanup (t : t) =
  with_lock t (fun () ->
    Hashtbl.iter
      (fun _ r -> Keeper_turn_sandbox_runtime.cleanup r)
      t.cache;
    Hashtbl.reset t.cache)
