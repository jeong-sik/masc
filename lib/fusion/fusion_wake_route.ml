(* Fusion_wake_route — see .mli for the contract.

   Lock-free Atomic + CAS over persistent immutable map snapshots. There is no
   Fusion call-rate limit, so lookup/update complexity must not depend on an
   assumed small number of concurrent runs. *)

module Route_id = struct
  type t =
    { keeper : string
    ; run_id : string
    }

  let compare left right =
    match String.compare left.keeper right.keeper with
    | 0 -> String.compare left.run_id right.run_id
    | order -> order
  ;;
end

module Routes = Map.Make (Route_id)

type route =
  { owner : Keeper_registry.registry_entry option
  ; channel : Keeper_continuation_channel.t option
  }

let routes : route Routes.t Atomic.t = Atomic.make Routes.empty

let rec update f =
  let cur = Atomic.get routes in
  let next = f cur in
  if not (Atomic.compare_and_set routes cur next) then update f

let register ~base_path ~keeper ~run_id channel =
  let owner = Keeper_registry.get ~base_path keeper in
  let channel =
    Option.bind channel (fun channel ->
      if Keeper_continuation_channel.is_routable channel then Some channel else None)
  in
  match owner, channel with
  | None, None -> ()
  | _ -> update (Routes.add Route_id.{ keeper; run_id } { owner; channel })

let take ~keeper ~run_id =
  (* Read-then-CAS: the value returned is the one observed in [cur]; the CAS
     retry re-reads, so a concurrent register/take converges like the
     registry's [update]. A completion wake fires once per run, so the only
     realistic contention is with [discard] on the cancellation path — either
     order leaves the route removed. *)
  let found = ref None in
  update (fun cur ->
    let id = Route_id.{ keeper; run_id } in
    found := Routes.find_opt id cur;
    Routes.remove id cur);
  !found

let peek ~keeper ~run_id =
  Routes.find_opt Route_id.{ keeper; run_id } (Atomic.get routes)

let discard ~keeper ~run_id = update (Routes.remove Route_id.{ keeper; run_id })
