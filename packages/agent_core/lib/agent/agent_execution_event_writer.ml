type t = Durable_event.journal
type event = Durable_event.event

let append journal event =
  match Durable_event.append journal event with
  | Ok () -> ()
  | Error { exception_; backtrace } -> Printexc.raise_with_backtrace exception_ backtrace
;;
