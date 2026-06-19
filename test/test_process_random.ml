open Alcotest

module R = Masc.Process_random

let set_env name value = Unix.putenv name value
let unset_env name = Unix.putenv name ""

let with_env name value f =
  let prev = Sys.getenv_opt name in
  (match value with
   | Some v -> set_env name v
   | None -> unset_env name);
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> set_env name v
      | None -> unset_env name)
    f

let first_seeded_random_int seed =
  R.For_testing.reset_rng_state ();
  with_env "MASC_RANDOM_SEED" (Some (string_of_int seed)) (fun () ->
    let value = R.random_int 1_000_000 in
    check
      int
      "rng state initialized"
      R.For_testing.initialized_state
      (R.For_testing.rng_state ());
    value)

let test_random_int_seeded_init_is_repeatable () =
  let first = first_seeded_random_int 12345 in
  let second = first_seeded_random_int 12345 in
  check int "same seed produces same first value" first second

let () =
  run
    "process_random"
    [ ( "rng"
      , [ test_case
            "random_int lazily initializes from seed"
            `Quick
            test_random_int_seeded_init_is_repeatable
        ] )
    ]
