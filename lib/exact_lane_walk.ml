module Provider_admission = Llm_provider.Provider_admission

type kind =
  | Http
  | Cli

type seats =
  | Seats_of of Provider_admission.seat_source
  | Seatless

type ('value, 'failure, 'stop) visit_end =
  | Answer of 'value
  | Advance of 'failure
  | Stop of 'stop

type ('slot, 'failure) passed =
  | Held of
      { slot : 'slot
      ; until : float
      }
  | Seats_full of 'slot
  | Failed of
      { slot : 'slot
      ; failure : 'failure
      }

type standing =
  | Every_slot_resting
  | Not_every_slot_resting

type ('slot, 'value, 'failure, 'stop) walk_result =
  | Answered of
      { slot : 'slot
      ; value : 'value
      ; passed : ('slot, 'failure) passed list
      }
  | Exhausted of
      { passed : ('slot, 'failure) passed list
      ; standing : standing
      }
  | Stopped of
      { slot : 'slot
      ; stop : 'stop
      ; passed : ('slot, 'failure) passed list
      }

(* A slot with its place in the list given, which tells two slots apart
   whatever the lane's slot values are. *)
type 'slot placed =
  { place : int
  ; slot : 'slot
  }

let same_place a b = Int.equal a.place b.place

let is_kind ~kind wanted placed =
  match wanted, kind placed.slot with
  | Http, Http | Cli, Cli -> true
  | Http, Cli | Cli, Http -> false
;;

(* WORKAROUND: the registry lists HTTP slots before CLI slots until the hard
   cut, and lanes order each kind apart today. Root fix: RFC
   exact-lane-walks-one-slot-list section 4 orders the one slot list in one
   [order_exact]. *)
let order_by_kind ~now ~kind ~quota_scope_of ~candidate_backpressure_of remaining =
  let order_of wanted =
    Runtime_candidate_standing.order_exact
      ~now
      ~quota_scope_of:(fun placed -> quota_scope_of placed.slot)
      ~candidate_backpressure_of:(fun placed -> candidate_backpressure_of placed.slot)
      (List.filter (is_kind ~kind wanted) remaining)
  in
  let http = order_of Http in
  let cli = order_of Cli in
  ( http.Runtime_candidate_standing.walk @ cli.Runtime_candidate_standing.walk
  , http.Runtime_candidate_standing.held @ cli.Runtime_candidate_standing.held )
;;

(* The slots with seats ahead of the first seatless one, in order. *)
type 'slot front =
  | Reaches_seatless of
      { seated : ('slot placed * Provider_admission.seat_source) list
      ; seatless : 'slot placed
      }
  | Every_one_seated of ('slot placed * Provider_admission.seat_source) list

let front ~seats slots =
  let rec scan seated = function
    | [] -> Every_one_seated (List.rev seated)
    | placed :: more ->
      (match seats placed.slot with
       | Seats_of source -> scan ((placed, source) :: seated) more
       | Seatless -> Reaches_seatless { seated = List.rev seated; seatless = placed })
  in
  scan [] slots
;;

let rec ahead_of called = function
  | [] -> []
  | (placed, (_ : Provider_admission.seat_source)) :: more ->
    if same_place placed called then [] else placed :: ahead_of called more
;;

(* The slot this step calls, the slots passed ahead of it as full, and the
   seat it holds. *)
type 'slot choice =
  { called : 'slot placed
  ; full : 'slot placed list
  ; seat : Provider_admission.seat option
  }

let choose ~seats first rest =
  match seats first.slot with
  | Seatless -> { called = first; full = []; seat = None }
  | Seats_of first_source ->
    (match front ~seats rest with
     | Reaches_seatless { seated; seatless } ->
       let seated = (first, first_source) :: seated in
       (match Provider_admission.try_first_seat seated with
        | Some (called, seat) -> { called; full = ahead_of called seated; seat = Some seat }
        | None -> { called = seatless; full = List.map fst seated; seat = None })
     | Every_one_seated more ->
       let called, seat = Provider_admission.take_first_seat (first, first_source) more in
       { called; full = ahead_of called ((first, first_source) :: more); seat = Some seat })
;;

let standing ~rests passed =
  let rests_on_standing = function
    | Held { slot = _; until = _ } -> true
    | Seats_full _ -> false
    | Failed { slot = _; failure } -> rests failure
  in
  match passed with
  | [] -> Not_every_slot_resting
  | _ :: _ ->
    if List.for_all rests_on_standing passed
    then Every_slot_resting
    else Not_every_slot_resting
;;

let visit_called ~visit ~on_advance ~last_failure choice =
  let run () =
    match last_failure with
    | None -> Ok (visit choice.called.slot choice.seat)
    | Some failed ->
      Result.map
        (fun () -> visit choice.called.slot choice.seat)
        (on_advance ~failed ~next:choice.called.slot)
  in
  match choice.seat with
  | None -> run ()
  | Some seat -> Fun.protect ~finally:(fun () -> Provider_admission.release_seat seat) run
;;

let walk
      ~now
      ~kind
      ~quota_scope_of
      ~candidate_backpressure_of
      ~seats
      ~visit
      ~on_advance
      ~on_pass
      ~rests
      slots
  =
  (* [passed] is kept newest first. Every pass goes through [pass], so
     [on_pass] hears them in the order of [passed]. *)
  let pass passed entry =
    on_pass entry;
    entry :: passed
  in
  let rec step ~remaining ~last_failure ~passed =
    let callable, held =
      order_by_kind ~now:(now ()) ~kind ~quota_scope_of ~candidate_backpressure_of remaining
    in
    let passed =
      List.fold_left
        (fun passed (placed, until) -> pass passed (Held { slot = placed.slot; until }))
        passed
        held
    in
    match callable with
    | [] -> Exhausted { passed = List.rev passed; standing = standing ~rests passed }
    | first :: rest ->
      let choice = choose ~seats first rest in
      let passed =
        List.fold_left (fun passed placed -> pass passed (Seats_full placed.slot)) passed choice.full
      in
      let gone = (choice.called :: choice.full) @ List.map fst held in
      let remaining =
        List.filter (fun placed -> not (List.exists (same_place placed) gone)) remaining
      in
      let slot = choice.called.slot in
      (match visit_called ~visit ~on_advance ~last_failure choice with
       | Error stop | Ok (Stop stop) -> Stopped { slot; stop; passed = List.rev passed }
       | Ok (Answer value) -> Answered { slot; value; passed = List.rev passed }
       | Ok (Advance failure) ->
         step ~remaining ~last_failure:(Some failure) ~passed:(pass passed (Failed { slot; failure })))
  in
  step
    ~remaining:(List.mapi (fun place slot -> { place; slot }) slots)
    ~last_failure:None
    ~passed:[]
;;
