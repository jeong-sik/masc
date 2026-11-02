exception Session_ended

let run body =
  Eio.Switch.run (fun runtime_sw ->
    match Eio.Switch.run (fun sw -> body ~runtime_sw sw; raise Session_ended) with
    | () -> ()
    | exception Session_ended -> ())
;;
