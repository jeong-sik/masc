(** What a live connection's peer receives and answers, whichever browser it
    drives: the WebDriver BiDi peer and the ego lite peer decode the same
    verbs from the MASC poll wire and share the same failure dispositions. *)

type partial_failure = { tab_id : int; message : string; receipt : Yojson.Safe.t }
type disposition = Not_started | Uncertain

type failure =
  | Before_effect of string
  | Partial_failure of partial_failure
      (** The browser confirmed part of a step on a tab, then refused or
          failed the rest: a created tab whose navigation failed, or a
          navigation the browser answered with an error and that was read
          again afterwards. [receipt] is what is known of the tab now. The
          connection remains usable and [tab_id] remains owned by it; inspect
          this tab, never replay the step. *)
  | Outcome_unknown of string
  | Observed_failure of { disposition : disposition; message : string; receipt : Yojson.Safe.t }
      (** Validated browser observations from a failed step. [disposition] is
          derived from workflow progress, never from native diagnostic flags.
          [Not_started] marks [effectPhase] as [not_started]; [Uncertain]
          makes no phase claim. Connection handling belongs to the host.
          [receipt] preserves native diagnostics but never authorizes replay. *)

(** Native host verbs, decoded once from the MASC poll wire. *)
type verb = Browser_info | Tabs_list | Page_read | Page_elements | Page_capture | Page_scene | Page_interact | Page_act
  | Page_goto | Page_context | Page_snapshot | Page_downloads | Page_native_workflow

(** The name a verb goes by on the wire and in the host's record. *)
val verb_to_wire : verb -> string
val verb_of_wire : string -> verb option

(** The verb, its arguments and the acting Keeper of one command the server
    queued for a live connection the browser Add-on worker owns. *)
val decode : Browser_lane.issued -> (verb * Yojson.Safe.t * string option, string) result

(** The result envelope a live connection delivers for one command. *)
val payload : (Yojson.Safe.t, failure) result -> Yojson.Safe.t
