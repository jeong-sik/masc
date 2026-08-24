(** The persisted [paused] bit is the pause authority
    ([keeper_lifecycle_admission.mli]), and three surfaces answer "is this
    keeper paused" from it:

    - [Keeper_lifecycle_admission.state] classifies it with the latch,
    - [Keeper_activation_readiness] reads that state,
    - [Keeper_world_observation] reads [meta.paused] directly.

    #29356 read that spread as three hand-written verdicts. They agree today
    because the latch only labels a pause it never creates one, and nothing
    said so: a latch that started deriving a pause on its own would split the
    third surface from the first two silently. *)

open Alcotest

module Admission = Masc.Keeper_lifecycle_admission
module Latched = Keeper_latched_reason

let latches =
  [ ("none", None)
  ; ("grpc directive", Some (Latched.Operator_paused { operator_actor = Latched.Grpc_directive }))
  ; ("keeper down", Some (Latched.Operator_paused { operator_actor = Latched.Keeper_down }))
  ]
;;

let is_paused state =
  match state with Admission.Paused _ -> true | Admission.Active -> false
;;

(* The bit decides; the latch only labels. *)
let test_pause_follows_the_persisted_bit () =
  List.iter
    (fun (label, latched_reason) ->
      List.iter
        (fun paused ->
          check
            bool
            (Printf.sprintf "paused=%b latch=%s" paused label)
            paused
            (is_paused (Admission.state ~paused ~latched_reason)))
        [ true; false ])
    latches
;;

(* A latch with no bit is the case that would split Keeper_world_observation
   (which reads the bit) from the readiness surface (which reads this state). *)
let test_a_latch_alone_does_not_pause () =
  List.iter
    (fun (label, latched_reason) ->
      match latched_reason with
      | None -> ()
      | Some _ ->
        check
          bool
          (label ^ " with paused=false stays active")
          false
          (is_paused (Admission.state ~paused:false ~latched_reason)))
    latches
;;

(* Fail-closed: a pause the latch cannot explain is still a pause. *)
let test_a_bit_without_a_latch_still_pauses () =
  check
    bool
    "paused=true with no latch is a pause"
    true
    (is_paused (Admission.state ~paused:true ~latched_reason:None))
;;

let () =
  run
    "pause-authority-agrees"
    [ ( "authority"
      , [ test_case "pause follows the persisted bit" `Quick
            test_pause_follows_the_persisted_bit
        ; test_case "a latch alone does not pause" `Quick
            test_a_latch_alone_does_not_pause
        ; test_case "a bit without a latch still pauses" `Quick
            test_a_bit_without_a_latch_still_pauses
        ] )
    ]
;;
