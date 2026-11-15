(** The workspace a request scope expects (#43356).

    Every request to the scope's endpoint sent from inside {!run} carries the
    two headers of {!Masc.Request_workspace_precondition} with the paths the
    TUI last confirmed on [/health]. The server compares them before routing
    and refuses a request meant for another workspace, so the scope does not
    read [/health] first. The fiber that runs the scope owns it, including the
    child fibers it forks. *)

type refusal = Masc.Request_workspace_precondition.refusal

(** What the scope's work is. An [Observation] reads; its guard trusts the
    precondition and asks no [/health] first. An [Operation] keeps the
    [/health] admission before it dispatches, so its receipt can still tell
    "not sent" from "sent, outcome unknown"; its requests carry the
    precondition as well, which closes the gap between that admission and the
    request. *)
type kind = Observation | Operation

val run :
  kind:kind ->
  host:string ->
  port:int ->
  expected:Masc.Tui_decode.server_identity ->
  on_workspace_refused:(refusal -> unit) ->
  withdrawn:(unit -> 'a) ->
  (unit -> 'a) ->
  'a
(** Run [request] in the scope and answer as the server did:
    - no request refused: [request]'s own result;
    - [Invalid_precondition]: [request]'s own result, the failure it read;
    - [Workspace_mismatch] or [Server_booting]: [on_workspace_refused] once.
      An [Observation] then answers [withdrawn ()] when that request was the
      first to leave, or [request]'s own result when an earlier one may have
      reached a handler. An [Operation] keeps [request]'s own result, the
      receipt it formed from the refusal.
    Only the first refusal counts. Outside Eio there is no fiber to own the
    scope, and [request] runs without one. *)

val expects : Masc.Tui_decode.server_identity -> bool
(** Whether the current fiber runs inside an [Observation] scope whose
    requests carry these canonical paths. *)

val without : (unit -> 'a) -> 'a
(** Run [load] outside any scope: its requests carry no precondition and
    leave the scope's record alone. Restores the scope on return. *)

(** {2 Transport side} *)

type prepared

val prepare : url:string -> (string * string) list -> prepared
(** The request's headers inside the current scope: the two precondition
    headers are added when [url] names the scope's endpoint and the request
    does not name either header itself. *)

val headers : prepared -> (string * string) list

type answer =
  | Answered of { status : int; body : string }
  | Unanswered  (** No response: the request may still have reached its handler. *)

val observe : prepared -> answer -> unit
(** Record what the server answered a request that carried the scope's
    precondition. A request sent without it records nothing. *)
