(** Observational facts for one terminal probe. No clock, I/O, input bytes or
    execution authority. Missing fields remain unobserved, including when a
    caller stops before its worker returns. *)
type stop_reason =
  | User_input_ready | Replies_ready | Deadline_reached
  | Read_returned_no_byte | Byte_cap_reached
type failure = Raised | Interrupted
type worker_outcome =
  | Captured of {reason:stop_reason; bytes_read:int; replies:Masc_tui_terminal_probe.observation}
  | Capture_failed of {failure:failure; bytes_read:int}
type caller_outcome = Returned_to_caller | Call_failed of failure
(** The systhread wait's observed return/exception, before decoder installation.
    A capture result is not physical worker quiescence. *)
type input_kind = Key | Paste | Pointer
type event =
  | Dispatched
  | Worker_started
  | Capture_finished of worker_outcome
  | Caller_observed of caller_outcome
  | Decoder_installed
  | Capabilities_applied of Masc_tui_terminal_probe.observation
  | First_input_decoded of input_kind
  | First_input_received of input_kind
type t = private {
  pid:int; dispatched_ns:int64;
  worker_started_ns:int64 option;
  capture_finished:(int64 * worker_outcome) option;
  caller_observed:(int64 * caller_outcome) option;
  decoder_installed_ns:int64 option;
  capabilities_applied:(int64 * Masc_tui_terminal_probe.observation) option;
  first_input_decoded:(int64 * input_kind) option;
  first_input_received:(int64 * input_kind) option;
}
val create : pid:int -> dispatched_ns:int64 -> t
val record : t -> at_ns:int64 -> event -> t * bool
(** First facts are retained; the latest actual capability application replaces
    only that projection. The boolean selects diagnostic emission only. It
    must never decide whether input or a terminal effect may run. *)
val event_json : t -> at_ns:int64 -> event -> Yojson.Safe.t
val snapshot_json : t -> at_ns:int64 -> Yojson.Safe.t
(** Same-process monotonic timestamps, actual observed counts and capability
    availability only. No key, paste, raw reply/refusal text, bearer or path.
    Received input is not accepted work, rendered output or physical paint. *)
