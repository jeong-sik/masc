val to_json : Runtime_muse_msp.model_catalog -> Yojson.Safe.t
(** Source-aware metadata projection. Missing limits remain null and missing
    effort metadata remains unknown; no account or invocation is verified. *)

val run : mgr:_ Eio.Process.mgr -> clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t -> account_home:string -> cli_path:string ->
  timeout_s:float -> (Yojson.Safe.t, Runtime_muse_serve.error) result
(** Query the explicit account through its managed profile without opening a
    session. The caller owns process descendants and a private empty cwd. *)
