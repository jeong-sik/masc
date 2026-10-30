(** The connection loop behind the Terminal tab's Execute output stream. *)

type observe_error =
  | Transport_failure of string
  | Http_refusal of { status : int; detail : string }
  | Unattested of { status : int; detail : string }

type stop_reason =
  | Http_status of int
  | Unattested_response of int
  | Unexpected_error
(** Keep the actual status and whether workspace attestation was missing;
    [Unexpected_error] names a failure outside the connection loop. *)

type ending =
  | Retry_after of { detail : string; delay_s : float }
  | Reopen_required of { reason : stop_reason; detail : string }

val run :
  clock:_ Eio.Time.clock ->
  reconnect_s:float ->
  max_reconnect_s:float ->
  stable_s:float ->
  monotonic_now:(unit -> float) ->
  post_interval_s:float ->
  reader:Masc_tui_execute_stream.t ->
  observe:(on_chunk:(string -> unit) -> (unit, observe_error) result) ->
  on_view:(Masc_tui_execute_stream.view -> unit) ->
  on_ended:(ending -> unit) ->
  unit
(** Retry transport errors, refused frames, normal closes, HTTP 408, 425, 429
    and 5xx with bounded exponential delays. Other HTTP refusals stop the job;
    the owner can reopen it when the Terminal tab is entered again.

    A short connection, even one that sent a valid snapshot, does not reset
    the backoff. Reset only after the connection has stayed open for [stable_s]
    after accepting its initial frame; [monotonic_now] measures this interval.
    The posting fiber stops with a permanent refusal or cancellation. *)
