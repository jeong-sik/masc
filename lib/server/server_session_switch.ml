exception Session_ended

let run body =
  match Eio.Switch.run (fun sw -> body sw; raise Session_ended) with
  | () -> ()
  | exception Session_ended -> ()
;;
