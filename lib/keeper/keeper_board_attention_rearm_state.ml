type ticket =
  { ticket_id : int
  ; delay_s : float
  }

type phase = Idle | Pending of ticket | Inflight of ticket

type t =
  { next_delay_s : float
  ; phase : phase
  }

let base_delay_s = 0.05
let max_delay_s = 5.0
let initial = { next_delay_s = base_delay_s; phase = Idle }
let phase state = state.phase

type reservation =
  { state : t
  ; ticket : ticket
  ; next_ticket_id : int
  }

let reserve ~next_ticket_id state =
  let ticket = { ticket_id = next_ticket_id; delay_s = state.next_delay_s } in
  { state =
      { next_delay_s = Float.min max_delay_s (state.next_delay_s *. 2.0)
      ; phase = Pending ticket
      }
  ; ticket
  ; next_ticket_id = next_ticket_id + 1
  }
;;

type schedule =
  | Scheduled of reservation
  | Already_pending of ticket
  | Already_inflight of ticket

let schedule ~next_ticket_id state =
  match state.phase with
  | Idle -> Scheduled (reserve ~next_ticket_id state)
  | Pending ticket -> Already_pending ticket
  | Inflight ticket -> Already_inflight ticket
;;

let begin_delivery state ticket =
  match state.phase with
  | Pending current when Int.equal current.ticket_id ticket.ticket_id ->
    Some { state with phase = Inflight ticket }
  | Pending _ | Inflight _ | Idle -> None
;;

let cancel_pending state ticket =
  match state.phase with
  | Pending current when Int.equal current.ticket_id ticket.ticket_id ->
    Some { state with phase = Idle }
  | Pending _ | Inflight _ | Idle -> None
;;

type 'a completion =
  | Delivered of t * 'a
  | Retry of reservation
  | Suppressed

let complete_delivery ~next_ticket_id state ticket delivery =
  match state.phase with
  | Inflight current when Int.equal current.ticket_id ticket.ticket_id ->
    (match delivery with
     | Ok wake -> Delivered ({ state with phase = Idle }, wake)
     | Error _ -> Retry (reserve ~next_ticket_id state))
  | Inflight _ | Pending _ | Idle -> Suppressed
;;
