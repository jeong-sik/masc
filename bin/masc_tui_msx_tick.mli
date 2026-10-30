(** The spectator's single advancing POST. Only pixels are retained: every
    successful response supplies fresh machine and player metadata. *)
type t
val create : unit -> t
type refusal = Off | Activity_unobserved | Workspace_changed
type activity = Enabled | Refused of refusal
type response = Advanced of Masc_tui_types.msx_frame option * Masc_tui_machine_live.mark option
  | Not_started of refusal
  | Worker_unavailable of string option
      (** HTTP 503 [worker_unavailable]: the server had no worker to send the tick
          to. Nothing ran, the retained pixels stay, and the next poll may ask
          again. The detail is the server's message. *)
type poll_policy = Advancing | Observing of refusal | Outcome_unknown
val policy_after_tick : (response, string) result -> poll_policy
val policy_after_activity : poll_policy -> (activity, string) result -> poll_policy
(** Only a known pre-execution refusal can recover from an activity read.
    Reading activity never clears an unknown mutation outcome or a workspace
    refusal; workspace control requires fresh explicit admission. *)
val refusal_notice : refusal -> string
val worker_unavailable_notice : string option -> string
val notice_after_advance :
  notice:string option -> worker_down_notice:string option -> string option
(** The notice to show once a tick advances. [worker_down_notice] is the value
    a tick wrote while no worker answered; it is retired only while [notice] is
    still that same value, told by identity and not by its words, so a notice
    written since by anything else stays. *)
val refusal_sentence : string -> string option
(** The sentence for the body of a refused MSX answer, read with {!Msx_wire}:
    the code says what the operator may do next and the server's message says
    why. [None] for a body that is not an MSX refusal, so the caller keeps its
    own wording. *)
val decode_activity : Yojson.Safe.t -> (activity, string) result

val fetch :
  ?body_fields:(string * Yojson.Safe.t) list ->
  t -> host:string -> port:int -> headers:(string * string) list ->
  request:(body:string -> (int * Yojson.Safe.t, string) result) ->
  (response, string) result
(** Capture the host/port/authorization scope before requesting exactly once.
    Reuse pixels only when the response matches this request's advertised
    revision and dimensions. Typed HTTP 409 activity/workspace refusals retain pixels
    and establish that no execution started, as does a 503 [worker_unavailable];
    that one keeps the poll advancing. A 503 [outcome_unknown], and any other
    error, clears the cache, leaves the outcome unknown and never retries the
    mutation. Network and decoding do not hold the cache lock.
    A loaded reply must also carry the mark captured with its pixels. A late
    request cannot publish over a newer request's cache. [body_fields] are
    added to the request body, ahead of the pixel fields, on every call. *)
