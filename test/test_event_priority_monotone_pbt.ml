(** Property-based tests for check_event_priority_monotone_pure.

    Exercises the pure EventPriorityMonotone predicate (TLA+ I4)
    over the full cross-product of {bind_count, has_measurement, has_pending}
    to verify the invariant holds for exactly the expected states.

    The predicate is diagnostic only and carries no lifecycle authority. *)

module Obs = Masc.Keeper_composite_observer

let gen_event_priority_state =
  QCheck.Gen.(
    let* bind_count = int_range 0 3 in
    let* has_measurement = bool in
    let* has_pending = bool in
    return {
      Obs.ep_measurement_bind_count = bind_count;
      Obs.ep_has_measurement = has_measurement;
      Obs.ep_has_pending_measurement = has_pending;
    })

let arb_state =
  QCheck.make gen_event_priority_state
    ~print:(fun s ->
      Printf.sprintf
        "{bind=%d; meas=%b; pending=%b}"
        s.Obs.ep_measurement_bind_count
        s.Obs.ep_has_measurement
        s.Obs.ep_has_pending_measurement)

(** Property 1: bind_count > 1 always violates. *)
let prop_bind_gt1_violates =
  QCheck.Test.make ~count:500 ~name:"bind_count > 1 always violates"
    arb_state
    (fun s ->
      if s.Obs.ep_measurement_bind_count > 1 then
        not (Obs.check_event_priority_monotone_pure s)
      else
        true)

(** Property 2: has_measurement && has_pending always violates. *)
let prop_both_active_violates =
  QCheck.Test.make ~count:500 ~name:"has_measurement && has_pending always violates"
    arb_state
    (fun s ->
      if s.Obs.ep_has_measurement && s.Obs.ep_has_pending_measurement then
        not (Obs.check_event_priority_monotone_pure s)
      else
        true)

(** Property 3: the predicate is equivalent to the direct boolean expression. *)
let prop_equiv_direct =
  QCheck.Test.make ~count:1000 ~name:"predicate matches direct expression"
    arb_state
    (fun s ->
      let direct =
        s.Obs.ep_measurement_bind_count <= 1
        && not (s.Obs.ep_has_measurement && s.Obs.ep_has_pending_measurement)
      in
      Obs.check_event_priority_monotone_pure s = direct)

(** Property 4: known-satisfying states satisfy. *)
let prop_known_satisfying =
  QCheck.Test.make ~count:1 ~name:"canonical satisfying states hold"
    QCheck.(make QCheck.Gen.(oneof [
      return {
        Obs.ep_measurement_bind_count = 0;
        Obs.ep_has_measurement = false;
        Obs.ep_has_pending_measurement = false;
      };
      return {
        Obs.ep_measurement_bind_count = 1;
        Obs.ep_has_measurement = true;
        Obs.ep_has_pending_measurement = false;
      };
      return {
        Obs.ep_measurement_bind_count = 0;
        Obs.ep_has_measurement = false;
        Obs.ep_has_pending_measurement = true;
      };
    ]))
    (fun s -> Obs.check_event_priority_monotone_pure s)

(** Property 5: known-violating states violate. *)
let prop_known_violating =
  QCheck.Test.make ~count:1 ~name:"canonical violating states fail"
    QCheck.(make QCheck.Gen.(oneof [
      return {
        Obs.ep_measurement_bind_count = 2;
        Obs.ep_has_measurement = false;
        Obs.ep_has_pending_measurement = false;
      };
      return {
        Obs.ep_measurement_bind_count = 3;
        Obs.ep_has_measurement = true;
        Obs.ep_has_pending_measurement = false;
      };
      return {
        Obs.ep_measurement_bind_count = 1;
        Obs.ep_has_measurement = true;
        Obs.ep_has_pending_measurement = true;
      };
    ]))
    (fun s -> not (Obs.check_event_priority_monotone_pure s))

let () =
  let suite =
    List.map QCheck_alcotest.to_alcotest
      [ prop_bind_gt1_violates;
        prop_both_active_violates;
        prop_equiv_direct;
        prop_known_satisfying;
        prop_known_violating ]
  in
  Alcotest.run "event_priority_monotone_pbt" [ ("properties", suite) ]
