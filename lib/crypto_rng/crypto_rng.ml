let mutex = Mutex.create ()

let default_unlocked () =
  match Mirage_crypto_rng.default_generator () with
  | rng -> rng
  | exception Mirage_crypto_rng.No_default_generator ->
    Mirage_crypto_rng_unix.use_default ();
    Mirage_crypto_rng.default_generator ()
;;

let with_generator fn =
  Mutex.protect mutex (fun () -> fn (default_unlocked ()))
;;

let ensure_default () = with_generator ignore

let generate bytes = with_generator (fun rng -> Mirage_crypto_rng.generate ~g:rng bytes)
