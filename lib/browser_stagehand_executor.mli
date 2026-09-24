(** The Stagehand backend's page verbs as Stagehand calls
    (RFC-browser-lane-stagehand §3.2).

    The backend owns the session and its lifecycle. This module turns one
    Browser Lane verb into the calls it needs, sends them through the [call]
    it is given, and turns the replies into the lane's answer. *)

(** masc tab ids for Stagehand page ids (CDP target ids), one table per
    session. A page keeps its id; an id is never given to another page, so a
    tab id read before a page closed cannot reach a different page. *)
module Tabs : sig
  type t

  val create : unit -> t
  val id_of_page : t -> string -> int

  (** [None] for an id this table never gave. *)
  val page_of_id : t -> int -> string option
end

type call =
  Browser_stagehand_wire.call -> (Yojson.Safe.t, Browser_stagehand_session.call_failure) result

val failure_message : Browser_stagehand_session.call_failure -> string

(** A [page.evaluate] expression that defines the scene runtime, runs [body]
    as a function called with [args], and answers its result as a JSON
    string. The BiDi peer runs the same page scripts this way, so a page reads
    the same on every lane. *)
val evaluate_expression : body:string -> args:Yojson.Safe.t -> string

(** Serves [Tabs_list], [Page_goto], [Page_capture], the reads [Page_read],
    [Page_elements] and [Page_scene] (with the automation lane's page scripts,
    so observations have one shape), and the sentence verbs.
    Every other verb, sessions included, is refused before any call: the
    backend answers sessions itself, and
    {!Browser_lane.verb_allowed_on_stagehand} keeps the rest from arriving.

    A failure before the verb's effect is [Rejected_before_effect]. Once a
    navigation or a sentence verb has been sent, a failure is [Refused]: it
    may have taken effect. *)
val execute : tabs:Tabs.t -> call:call -> Browser_lane.verb -> Browser_lane.answer
