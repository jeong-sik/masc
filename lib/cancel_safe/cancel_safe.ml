let protect ~on_exn f =
  try f ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> on_exn exn

let observe ~on_exn f = protect ~on_exn f
