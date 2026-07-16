let initialization_mutex = Mutex.create ()

let default () =
  match Mirage_crypto_rng.default_generator () with
  | rng -> rng
  | exception Mirage_crypto_rng.No_default_generator ->
    Mutex.protect initialization_mutex (fun () ->
      match Mirage_crypto_rng.default_generator () with
      | rng -> rng
      | exception Mirage_crypto_rng.No_default_generator ->
        Mirage_crypto_rng_unix.use_default ();
        Mirage_crypto_rng.default_generator ())
;;

let ensure_default () = ignore (default ())

let generate bytes =
  Mirage_crypto_rng.generate ~g:(default ()) bytes
;;
