open Alcotest

let test_parallel_generation_is_safe () =
  Crypto_rng.ensure_default ();
  let worker_count = 8 in
  let values_per_worker = 1_024 in
  let ready = Atomic.make 0 in
  let start = Atomic.make false in
  let workers =
    List.init worker_count (fun _ ->
      Domain.spawn (fun () ->
        ignore (Atomic.fetch_and_add ready 1);
        while not (Atomic.get start) do
          Domain.cpu_relax ()
        done;
        Array.init values_per_worker (fun _ -> Crypto_rng.generate 32)))
  in
  while Atomic.get ready < worker_count do
    Domain.cpu_relax ()
  done;
  Atomic.set start true;
  let values =
    List.concat_map (fun worker -> Array.to_list (Domain.join worker)) workers
  in
  check int "all values generated" (worker_count * values_per_worker) (List.length values);
  List.iter (fun value -> check int "value length" 32 (String.length value)) values
;;

let () =
  run
    "crypto_rng"
    [ "generation", [ test_case "parallel generation is safe" `Quick test_parallel_generation_is_safe ] ]
;;
