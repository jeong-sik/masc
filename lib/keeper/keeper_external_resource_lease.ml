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
       (* The mutex protects admission, not mutable in-memory state. A cancelled
          external operation must unlock without poisoning future holders. *)
       Eio.Mutex.use_ro (Keeper_fs.path_lock_mutex lock) f)
;;
