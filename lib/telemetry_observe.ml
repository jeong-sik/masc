let observe_or_fail ~kind ?keeper_name f =
  try Ok (f ())
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      let msg = Printexc.to_string exn in
      Log.Backend.warn ?keeper_name
        "[telemetry_observe] kind=%s caught exception: %s"
        kind msg;
      Error msg

let observe_silent ~kind:_ f =
  try f ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> ()

let observe_or_default ~kind ?keeper_name ~default f =
  match observe_or_fail ~kind ?keeper_name f with
  | Ok v -> v
  | Error _ -> default
