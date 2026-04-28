type t = {
  config : Coord.config;
  meta : Keeper_types.keeper_meta;
  cache : ((bool * string), Keeper_turn_sandbox_runtime.t) Hashtbl.t;
  mutex : Mutex.t;
}

let create ~(config : Coord.config) ~(meta : Keeper_types.keeper_meta) =
  {
    config;
    meta;
    cache = Hashtbl.create 4;
    mutex = Mutex.create ();
  }

let with_lock (t : t) f =
  Mutex.lock t.mutex;
  Fun.protect
    ~finally:(fun () -> try Mutex.unlock t.mutex with _ -> ())
    f

let resolve (t : t) ~in_playground ~cwd =
  with_lock t (fun () ->
    let key = (in_playground, cwd) in
    match Hashtbl.find_opt t.cache key with
    | Some r -> Some r
    | None ->
      let (effective_profile, effective_network) =
        Keeper_shell_docker.effective_sandbox_profile
          ~meta:t.meta ~in_playground
      in
      (match effective_profile with
       | Keeper_types.Docker ->
         let r =
           Keeper_turn_sandbox_runtime.create
             ~config:t.config
             ~meta:t.meta
             ~network_mode:effective_network
             ()
         in
         Hashtbl.add t.cache key r;
         Some r
       | Keeper_types.Local -> None))

let cleanup (t : t) =
  with_lock t (fun () ->
    Hashtbl.iter
      (fun _ r -> Keeper_turn_sandbox_runtime.cleanup r)
      t.cache;
    Hashtbl.reset t.cache)
