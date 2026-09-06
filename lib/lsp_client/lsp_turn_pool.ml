(** See [lsp_turn_pool.mli]. *)

(* Created once at module init: the key's identity is what [with_binding] and
   [get] look each other up by, and a key made per call would bind a pool no
   read could find. *)
let pool_key : Lsp_workspace_pool.t Eio.Fiber.key = Eio.Fiber.create_key ()

let with_turn_pool ~servers f =
  match Eio_context.get_env_opt () with
  | None -> f ()
  | Some env ->
    Lsp_workspace_pool.with_pool
      ~clock:(Eio.Stdenv.clock env)
      ~proc_mgr:Posix_spawn_process_mgr.mgr
      ~servers
      (fun pool -> Eio.Fiber.with_binding pool_key pool f)
;;

let get_opt () = Eio.Fiber.get pool_key
