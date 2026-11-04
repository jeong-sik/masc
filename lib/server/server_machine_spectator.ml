let step = ref (fun ~config ~machine ->
  match machine with
  | Machine_lane.Msx ->
      Machine_addon_host.call_shared ~config
        ~principal:Lane_addon_call_context.Operator
        ~name:"masc_msx_step"
        ~arguments:(`Assoc ["frames", `Int 18; "include_frame", `Bool true])
      |> Result.map ignore
  | Machine_lane.Dos -> Ok ())

let start ~sw ~clock ~stop_promise ~machine ~config =
  Eio.Fiber.fork ~sw (fun () ->
    let rec tick () =
      match !step ~config ~machine with
      | Error detail -> Log.Server.warn "machine spectator tick stopped: %s" detail
      | Ok () ->
          Eio.Time.sleep clock 0.3;
          tick ()
    in
    ignore (Eio.Fiber.first
      (fun () -> tick (); `Tick_stopped)
      (fun () -> Eio.Promise.await stop_promise; `Observer_closed)))

module For_testing = struct
  let with_step replacement f =
    let previous = !step in
    step := replacement;
    Fun.protect ~finally:(fun () -> step := previous) f
end
