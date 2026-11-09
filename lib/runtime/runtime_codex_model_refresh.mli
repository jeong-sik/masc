val run : mgr:_ Eio.Process.mgr -> clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t -> directory:string ->
  account:Runtime_codex_app_server.authorized_account -> cli_path:string -> timeout_s:float ->
  (Yojson.Safe.t, string) result
(** The caller owns a fresh empty private directory and its cleanup. Copies only
    the connection/auth configuration of the home of [account], never the
    original model cache.
    Returns exact listed models joined to the isolated CLI-written context cache,
    including each model's reported supported/default reasoning effort strings.
    No thread, prompt, or original-home mutation is performed. *)
