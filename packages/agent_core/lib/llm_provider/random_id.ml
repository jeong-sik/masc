let hex ~bytes =
  if bytes <= 0
  then Error "random identifier byte count must be positive"
  else (
    try
      Ok
        (Mirage_crypto_rng_unix.getrandom bytes
         |> Cstruct.of_string
         |> Cstruct.to_hex_string)
    with
    | exn ->
      Reserved_exn.reraise_if_reserved exn;
      Error ("operating-system entropy unavailable: " ^ Printexc.to_string exn))
;;

let create () = hex ~bytes:16
