type phase =
  | Admitting
  | Blocked_phase of { kind : string; since : float }

(* A block's display projection: its canonical kind tag and the rich
   typed-number [summary] line, both present exactly when the decision is
   [Blocked]. Carrying [summary] in the block edges makes "a block edge always
   has a summary" a type invariant, so [log_edge] needs no option fallback
   default — that fallback was both dead (block edges only arise from [Blocked])
   and flagged by the DET deterministic-boundary ratchet as a permissive
   option-default at a value boundary. Eliminating it is the parse-don't-validate
   fix, not a rephrase to dodge the text scan. *)
type block_view = { kind : string; summary : string }

type edge =
  | No_edge
  | Entered_block of { kind : string; summary : string }
  | Kind_changed of { from_kind : string; to_kind : string; summary : string }
  | Resumed of { was_kind : string; blocked_for_sec : float }

(* One process-global phase shared by the whole fleet. The CAS in [observe]
   makes exactly one keeper cross each edge and log; losers re-read the updated
   phase and classify [No_edge]. *)
let phase_state : phase Atomic.t = Atomic.make Admitting

let classify ~prev ~block ~now =
  match prev, block with
  | Admitting, None -> Admitting, No_edge
  | Admitting, Some { kind; summary } ->
    Blocked_phase { kind; since = now }, Entered_block { kind; summary }
  | Blocked_phase { kind = was_kind; since }, None ->
    Admitting, Resumed { was_kind; blocked_for_sec = now -. since }
  | Blocked_phase { kind = from_kind; since }, Some { kind = to_kind; summary } ->
    if String.equal from_kind to_kind
    then Blocked_phase { kind = from_kind; since }, No_edge
    else
      Blocked_phase { kind = to_kind; since = now }
      , Kind_changed { from_kind; to_kind; summary }
;;

let log_edge edge =
  match edge with
  | No_edge -> ()
  | Entered_block { kind; summary } ->
    Log.Keeper.warn "turn admission: fleet turns suspended (%s): %s" kind summary
  | Kind_changed { from_kind; to_kind; summary } ->
    Log.Keeper.warn
      "turn admission: block reason changed %s -> %s: %s"
      from_kind
      to_kind
      summary
  | Resumed { was_kind; blocked_for_sec } ->
    Log.Keeper.warn
      "turn admission: fleet turns resumed after %.0fs (was %s)"
      blocked_for_sec
      was_kind
;;

let observe decision =
  let now = Time_compat.now () in
  let block =
    match decision with
    | Keeper_pressure_admission.Admitted -> None
    | Keeper_pressure_admission.Blocked block ->
      Some
        { kind = Keeper_pressure_admission.block_kind block
        ; summary = Keeper_pressure_admission.block_summary block
        }
  in
  let rec attempt () =
    let prev = Atomic.get phase_state in
    let next, edge = classify ~prev ~block ~now in
    match edge with
    | No_edge -> ()
    | Entered_block _ | Kind_changed _ | Resumed _ ->
      if Atomic.compare_and_set phase_state prev next
      then log_edge edge
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
