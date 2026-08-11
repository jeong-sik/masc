type t =
  | File_path of string
  | Host_cwd of string

let key = function
  | File_path path -> "file\000" ^ path
  | Host_cwd path -> "host-cwd\000" ^ path
;;

let with_lease resource f =
  let key = key resource in
  let lock = Keeper_fs.acquire_path_lock key in
  Fun.protect
    ~finally:(fun () -> Keeper_fs.release_path_lock key lock)
    (fun () ->
       (* [~protect:false]: [use_rw] still releases the mutex on exception or
          cancellation; [protect] only decides whether [f] itself is shielded
          from cancellation. A lease wraps long-running work (tool execution
          via [keeper_tool_execute_runtime]), so shielding it made keeper
          cancellation wait for the tool to finish — and made the
          cancellation-releases-lease contract in
          [test_keeper_external_resource_lease] unsatisfiable. *)
       Eio.Mutex.use_rw ~protect:false (Keeper_fs.path_lock_mutex lock) f)
;;
