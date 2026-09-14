(* A deadline that keeps a finished result.

   [Eio.Time.with_timeout] is [Fiber.first] with a timer: it keeps whichever
   arm finished first and drops the other's result. When the work finished in
   the same scheduler pass the timer expired -- the response's last byte and
   the deadline arriving together -- the work's result was dropped and the
   call reported as one that did not finish, its connection, permit or
   response gone with it. Here a finished [f] stands: the deadline arm wins
   only when [f] has not finished. *)
let run clock seconds f =
  Eio.Fiber.first
    ~combine:(fun first later ->
      match first with
      | Ok _ -> first
      | Error _ -> later)
    (fun () ->
       Eio.Time.sleep clock seconds;
       Error `Timeout)
    (fun () -> Ok (f ()))
;;
