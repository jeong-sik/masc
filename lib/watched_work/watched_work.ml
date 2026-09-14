type 'a raced =
  | Work of 'a
  | Watcher of 'a

let run ~watcher work =
  match
    Eio.Fiber.first
      ~combine:(fun first later ->
        match first with
        | Work _ -> first
        | Watcher _ -> later)
      (fun () -> Work (work ()))
      (fun () -> Watcher (watcher ()))
  with
  | Work outcome | Watcher outcome -> outcome
