type 'msg mailbox = 'msg Eio.Stream.t

type 'msg t = {
  name : string;
  inbox : 'msg mailbox;
  stop_signal : bool Atomic.t;
}

type handler_outcome =
  | Continue
  | Stop
