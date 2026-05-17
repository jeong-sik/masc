(** See .mli for contract. *)

let _max_concurrency =
  match Sys.getenv_opt "MASC_DOCKER_SPAWN_CONCURRENCY" with
  | Some s ->
    (match int_of_string_opt (String.trim s) with
     | Some n when n >= 1 && n <= 64 -> n
     | _ -> 8)
  | None -> 8
;;

let _sem = Eio.Semaphore.make _max_concurrency

let _degraded_mutex = Eio.Mutex.create ()

let with_slot f =
  Eio.Semaphore.acquire _sem;
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> Eio.Semaphore.release _sem);
  if Keeper_fd_pressure.active () then
    Eio.Mutex.use_rw ~protect:true _degraded_mutex f
  else
    f ()
;;

let effective_concurrency () =
  if Keeper_fd_pressure.active () then 1 else _max_concurrency
;;

let configured_max () = _max_concurrency
