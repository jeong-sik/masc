(** The Stagehand backend's page verbs as Stagehand calls
    (RFC-browser-lane-stagehand §3.2).

    The backend owns the session and its lifecycle. This module turns one
    Browser Lane verb into the calls it needs, sends them through the [call]
    it is given, and turns the replies into the lane's answer. *)

(** masc tab ids for Stagehand page ids (CDP target ids), one table per
    backend. A page keeps its id; an id is never given to another page, in
    the same session or a later one, so a tab id read before a page closed
    cannot reach a different page. *)
module Tabs : sig
  type t

  val create : unit -> t
  val id_of_page : t -> string -> int

  (** [None] for an id this table never gave, and for one given to a page
      it has since forgotten. *)
  val page_of_id : t -> int -> string option

  (** Forgets every page, for a new session, and keeps counting ids. *)
  val forget_pages : t -> unit
end

type call =
  Browser_stagehand_wire.call -> (Yojson.Safe.t, Browser_stagehand_session.call_failure) result

val failure_message : Browser_stagehand_session.call_failure -> string

(** Whether a page script calls [browserScene], so the scene runtime is
    defined before it. Every caller says which: a script that needs the
    runtime and runs without it fails only inside the page. *)
type page_runtime = Scene_runtime | No_runtime

(** A [page.evaluate] expression that runs [body] as a function called with
    [args], after [runtime], and answers its result as a JSON string. The
    BiDi peer runs the same page scripts this way. *)
val evaluate_expression : runtime:page_runtime -> body:string -> args:Yojson.Safe.t -> string

(** Serves [Tabs_list], [Page_goto], [Page_capture] and the sentence verbs.
    Every other verb, sessions included, is refused before any call: the
    backend answers sessions itself, and
    {!Browser_lane.verb_allowed_on_stagehand} keeps the rest from arriving.

    A failure before the verb's effect is [Rejected_before_effect]. Once a
    navigation or a sentence verb has been sent, a failure is [Refused]: it
    may have taken effect. *)
val execute : tabs:Tabs.t -> call:call -> Browser_lane.verb -> Browser_lane.answer
