val run : mgr:_ Eio.Process.mgr -> clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t -> directory:string -> account_home:string option -> cli_path:string -> timeout_s:float ->
  (Yojson.Safe.t, string) result
(** The caller owns a fresh empty private directory and its cleanup. Copies only
    selected [account_home] connection/auth configuration (or the caller's
    native home when absent), never the original model cache.
    Returns exact listed models joined to the isolated CLI-written context cache.
    No thread, prompt, or original-home mutation is performed. *)
