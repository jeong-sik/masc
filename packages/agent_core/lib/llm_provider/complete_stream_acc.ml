(** Sequential effect shell for the pure stream state machine. *)

type stream_acc = { state : Complete_stream_state.t ref }

let create_stream_acc () = { state = ref Complete_stream_state.empty }
let stream_failed acc = Complete_stream_state.has_failed !(acc.state)

let accumulate_event acc event =
  acc.state := Complete_stream_state.transition !(acc.state) event
;;

let finalize_stream_acc acc =
  match Complete_stream_state.finalize !(acc.state) with
  | Complete_stream_state.Completed response -> Ok response
  | Complete_stream_state.Failed failure -> Error failure
;;
