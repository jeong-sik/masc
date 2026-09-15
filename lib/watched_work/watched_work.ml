type 'a raced =
  | Work of 'a
  | Watcher of 'a

(* The watcher goes first. [Eio.Fiber.first] runs its first function
   immediately and schedules the second next, so whichever arm is written
   first starts before the other. With the work written first, a watcher
   counting a deadline only started counting at the work's first pause -- the
   work got its own synchronous prefix on top of the budget, and a work that
   never paused never started the count. The verdict still only arrives at a
   scheduling point; what moves here is when the count begins. *)
let run ~watcher work =
  match
    Eio.Fiber.first
      ~combine:(fun first later ->
        match first with
        | Work _ -> first
        | Watcher _ -> later)
      (fun () -> Watcher (watcher ()))
      (fun () -> Work (work ()))
  with
  | Work outcome | Watcher outcome -> outcome
