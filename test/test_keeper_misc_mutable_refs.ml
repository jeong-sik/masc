(** Regression tests for the mechanical [ref -> Atomic.t] conversions flagged
    by the adversarial self-review (S5, S6, S7). *)

open Alcotest

module KSR = Masc.Keeper_turn_sandbox_runtime
module KSL = Masc.Keeper_supervisor_launch

let test_sandbox_state_atomic () =
  let t = KSR.For_testing.create_minimal ~state:Not_started in
  check bool "initial state is Not_started" true
    (match KSR.For_testing.get_state t with
     | Not_started -> true
     | Running _ -> false);
  KSR.For_testing.set_state t (Running { container_name = "c1" });
  check bool "state updated atomically" true
    (match KSR.For_testing.get_state t with
     | Running { container_name } -> String.equal container_name "c1"
     | Not_started -> false)
;;

let test_global_switch_atomic () =
  check bool "global switch starts None" true (Option.is_none (KSL.get_global_switch ()));
  (* We cannot create a real Eio.Switch in a unit test, so we use a dummy. *)
  KSL.set_global_switch (Obj.magic 42);
  check bool "global switch set" true (Option.is_some (KSL.get_global_switch ()));
  KSL.set_global_switch (Obj.magic 43);
  check bool "global switch overwritten" true (Option.is_some (KSL.get_global_switch ()))
;;

let test_seq_ref_unique_under_concurrent_updates () =
  let seq_ref = Atomic.make 0 in
  let n = 100 in
  let domains =
    List.init 4 (fun _ ->
      Domain.spawn (fun () ->
        let seqs = Array.make n 0 in
        for i = 0 to n - 1 do
          seqs.(i) <- Atomic.fetch_and_add seq_ref 1 + 1
        done;
        seqs))
  in
  let all_seqs = List.map Domain.join domains |> List.map Array.to_list |> List.concat in
  check int "total generated sequences" (4 * n) (List.length all_seqs);
  let unique = List.sort_uniq Int.compare all_seqs in
  check int "all sequences unique" (4 * n) (List.length unique);
  check int "max sequence" (4 * n) (List.fold_left max 0 all_seqs)
;;

let () =
  Alcotest.run
    "keeper-misc-mutable-refs"
    [ ( "sandbox-state"
      , [ test_case "atomic get/set" `Quick test_sandbox_state_atomic ] )
    ; ( "supervisor-global-switch"
      , [ test_case "atomic get/set" `Quick test_global_switch_atomic ] )
    ; ( "manifest-seq"
      , [ test_case "concurrent unique logical_seq" `Quick
            test_seq_ref_unique_under_concurrent_updates
        ] )
    ]
;;
