(** The spectator's single advancing POST. Only pixels are retained: every
    successful response supplies fresh machine and player metadata. *)
type t
val create : unit -> t
type refusal = Off | Activity_unobserved
type activity = Enabled | Refused of refusal
type response = Advanced of Masc_tui_types.msx_frame option * Masc_tui_machine_live.mark option
  | Not_started of refusal
type poll_policy = Advancing | Observing of refusal | Outcome_unknown
val policy_after_tick : (response, string) result -> poll_policy
val policy_after_activity : poll_policy -> (activity, string) result -> poll_policy
(** Only a known pre-execution refusal can recover from an activity read.
    Reading activity never clears an unknown mutation outcome. *)
val refusal_notice : refusal -> string
val decode_activity : Yojson.Safe.t -> (activity, string) result

val fetch :
  t -> host:string -> port:int -> headers:(string * string) list ->
  request:(body:string -> (int * Yojson.Safe.t, string) result) ->
  (response, string) result
(** Capture the host/port/authorization scope before requesting exactly once.
    Reuse pixels only when the response matches this request's advertised
    revision and dimensions. Typed HTTP 409 activity refusals retain pixels
    and establish that no execution started. Other errors clear the cache and
    never retry the mutation. Network and decoding do not hold the cache lock.
    A loaded reply must also carry the mark captured with its pixels. A late
    request cannot publish over a newer request's cache. *)
