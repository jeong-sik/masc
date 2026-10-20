(** The Stagehand backend's page verbs as Stagehand calls
    (RFC-browser-lane-stagehand §3.2).

    The backend owns the session and its lifecycle. This module turns one
    Browser Lane verb into the calls it needs, sends them through the [call]
    it is given, and turns the replies into the lane's answer. *)

val attach_error_message : Browser_stagehand_session.attach_error -> string

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

  (** Retires a confirmed closed page's id; later pages never reuse it. *)
  val forget_page : t -> string -> unit
end

type call =
  Browser_stagehand_wire.call -> (Yojson.Safe.t, Browser_stagehand_session.call_failure) result

val failure_message : Browser_stagehand_session.call_failure -> string

(** Whether a page script calls [browserScene], so the scene runtime is
    defined before it. Every caller says which: a script that needs the
    runtime and runs without it fails only inside the page. *)
type page_runtime = Scene_runtime | No_runtime

(** A [page.evaluate] expression that runs [body] as a function called with
    [args], after [runtime], and answers its result as a JSON string, or a
    throw as an object [{thrown}] with the thrown message. The BiDi peer runs
    the same page scripts this way. *)
val evaluate_expression : runtime:page_runtime -> body:string -> args:Yojson.Safe.t -> string

(** Serves [Tabs_list], [Page_goto], [Page_capture], the reads [Page_read],
    [Page_elements] and [Page_scene] (with the automation lane's page scripts,
    so observations have one shape), interactions, and the sentence verbs.
    [Page_act] serves only [Open_tab] and top-level [Back], [Forward],
    [Reload], and [Close_tab], through native runtime methods. A confirmed
    creation followed by navigation or summary failure returns an [ok=false]
    partial-effect receipt with the created tab id and owning lane. It never
    creates another page to retry. Confirmed close retires that tab id.
    Semantic click, hover and drag resolve observed targets without scrolling, then
    recheck their URL and viewport before native Stagehand pointer input.
    Custom drag paths become CSS-pixel runtime routes; the default visits the
    midpoint before the destination. Semantic drags also visit a distinct
    hit-tested point inside the observed destination when one is available,
    so native dragenter can precede dragover at the final point. Nonzero movement duration is refused
    before any input: the runtime's delay option is not movement duration.
    Every other verb, sessions included, is refused before any call: the
    backend answers sessions itself, and
    {!Browser_lane.verb_allowed_on_stagehand} keeps the rest from arriving.

    A failure before the verb's effect is [Rejected_before_effect]. Once a
    navigation or a sentence verb has been sent, a failure is [Refused]: it
    may have taken effect. An act Stagehand answers with
    [data.success = false] is such a failure, carrying Stagehand's message. *)
val execute : tabs:Tabs.t -> call:call -> ?actor:string -> Browser_lane.verb -> Browser_lane.answer
(** An explicitly attributed interaction displays observational agent feedback.
    Anonymous direct calls do not invent an owner. Overlay failures cannot
    change the interaction result or trigger another input. *)
