(* Fusion_wake_route — see .mli for the contract.

   Lock-free Atomic + CAS over persistent immutable map snapshots. There is no
   Fusion call-rate limit, so lookup/update complexity must not depend on an
   assumed small number of concurrent runs. *)

module Routes = Map.Make (String)

let routes : Keeper_continuation_channel.t Routes.t Atomic.t =
  Atomic.make Routes.empty

let rec update f =
  let cur = Atomic.get routes in
  let next = f cur in
  if not (Atomic.compare_and_set routes cur next) then update f

let register ~run_id channel =
  if Keeper_continuation_channel.is_routable channel then
    update (Routes.add run_id channel)

let take ~run_id =
  (* Read-then-CAS: the value returned is the one observed in [cur]; the CAS
     retry re-reads, so a concurrent register/take converges like the
     registry's [update]. A completion wake fires once per run, so the only
     realistic contention is with [discard] on the cancellation path — either
     order leaves the route removed. *)
  let found = ref None in
  update (fun cur ->
    found := Routes.find_opt run_id cur;
    Routes.remove run_id cur);
  !found

let peek ~run_id = Routes.find_opt run_id (Atomic.get routes)

let discard ~run_id = update (Routes.remove run_id)
