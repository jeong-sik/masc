type phase =
  | Admitting
  | Blocked_phase of { kind : string; since : float }

type edge =
  | No_edge
  | Entered_block of { kind : string }
  | Kind_changed of { from_kind : string; to_kind : string }
  | Resumed of { was_kind : string; blocked_for_sec : float }

(* One process-global phase shared by the whole fleet. The CAS in [observe]
   makes exactly one keeper cross each edge and log; losers re-read the updated
   phase and classify [No_edge]. *)
let phase_state : phase Atomic.t = Atomic.make Admitting

let classify ~prev ~admitted_kind ~now =
  match prev, admitted_kind with
  | Admitting, None -> Admitting, No_edge
  | Admitting, Some kind -> Blocked_phase { kind; since = now }, Entered_block { kind }
  | Blocked_phase { kind = was_kind; since }, None ->
    Admitting, Resumed { was_kind; blocked_for_sec = now -. since }
  | Blocked_phase { kind = from_kind; since }, Some to_kind ->
    if String.equal from_kind to_kind
    then Blocked_phase { kind = from_kind; since }, No_edge
    else
      Blocked_phase { kind = to_kind; since = now }, Kind_changed { from_kind; to_kind }
;;

(* [summary] is the rich typed-number line for the *current* block, available
   only when the decision is [Blocked]; resume edges carry no block so they log
   the kind alone. *)
let log_edge ~summary edge =
  match edge with
  | No_edge -> ()
  | Entered_block { kind } ->
    Log.Keeper.warn
      "turn admission: fleet turns suspended (%s): %s"
      kind
      (Option.value summary ~default:kind)
  | Kind_changed { from_kind; to_kind } ->
    Log.Keeper.warn
      "turn admission: block reason changed %s -> %s: %s"
      from_kind
      to_kind
      (Option.value summary ~default:to_kind)
  | Resumed { was_kind; blocked_for_sec } ->
    Log.Keeper.warn
      "turn admission: fleet turns resumed after %.0fs (was %s)"
      blocked_for_sec
      was_kind
;;

let observe decision =
  let now = Time_compat.now () in
  let admitted_kind, summary =
    match decision with
    | Keeper_pressure_admission.Admitted -> None, None
    | Keeper_pressure_admission.Blocked block ->
      ( Some (Keeper_pressure_admission.block_kind block)
      , Some (Keeper_pressure_admission.block_summary block) )
  in
  let rec attempt () =
    let prev = Atomic.get phase_state in
    let next, edge = classify ~prev ~admitted_kind ~now in
    match edge with
    | No_edge -> ()
    | Entered_block _ | Kind_changed _ | Resumed _ ->
      if Atomic.compare_and_set phase_state prev next
      then log_edge ~summary edge
      else attempt ()
  in
  attempt ()
;;

let decide_observed ~masc_root ~active_keepers () =
  let decision = Keeper_pressure_admission.decide ~masc_root ~active_keepers () in
  observe decision;
  decision
;;

let reset_for_tests () = Atomic.set phase_state Admitting
