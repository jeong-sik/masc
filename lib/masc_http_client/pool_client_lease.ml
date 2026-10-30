type ownership = Request_owned | Pool_owned | Close_requested
type t = ownership ref

let park ownership ~publish =
  Eio.Cancel.protect (fun () ->
    publish ();
    ownership := Pool_owned)

let close ownership ~signal =
  Eio.Cancel.protect (fun () ->
    signal ();
    ownership := Close_requested)

let with_client ~release ~close:signal work =
  let ownership = ref Request_owned in
  let release_once ~close_only =
    match !ownership with
    | Request_owned -> release ownership ~close_only
    | Pool_owned | Close_requested -> ()
  in
  let finally () =
    match !ownership with
    | Pool_owned | Close_requested -> ()
    | Request_owned ->
      (try close ownership ~signal with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Log.Http.warn "HTTP client lease close failed: %s"
           (Format.asprintf "@[<h>%a@]" Eio.Exn.pp exn))
  in
  Fun.protect ~finally (fun () -> work ~release:release_once)
