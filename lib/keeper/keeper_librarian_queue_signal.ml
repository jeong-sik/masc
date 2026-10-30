let observer = Atomic.make (fun ~base_path:_ ~keeper_name:_ -> ())
let install f = Atomic.set observer f
let changed ~base_path ~keeper_name =
  try (Atomic.get observer) ~base_path ~keeper_name with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Log.Keeper.warn ~keeper_name
      "Librarian queue notification failed; ordinary wake remains available: %s"
      (Printexc.to_string exn)
