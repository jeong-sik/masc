(** Nonblocking stream lifecycle shared by the shim and guest relay.
    This leaf owns no child process and consumes no stream bytes. *)

type peer_state =
  | Connected
  | Send_closed
      (** The peer ended its sending direction; output may still be delivered. *)
  | Disconnected
      (** Hangup, error or invalid descriptor: output is unavailable. *)

val peer_state : Unix.file_descr -> peer_state
(** Immediate poll. Linux RDHUP observes send-half-close even with queued
    unread bytes. HUP/ERR/NVAL take precedence. On platforms without RDHUP,
    the caller also learns send-half-close from a zero-byte read. Raises
    [Unix.Unix_error] on a failed poll. *)

val with_nonblocking : Unix.file_descr -> (unit -> 'a) -> 'a
(** Restore the descriptor's prior flags after the callback. A descriptor
    already closed by its owner cannot have its flags restored. *)

val lifecycle_poll_sec : float
(** Existing supervisor polling quantum, also used when stream queues are full. *)

val drain_grace_sec : float
(** Existing post-reap cleanup grace for inherited pipes and final output.
    This is not a new payload execution timeout. *)
