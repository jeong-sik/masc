(** What a live connection's peer receives and answers, whichever browser it
    drives: the WebDriver BiDi peer and the ego lite peer decode the same
    verbs from the MASC poll wire and fail in the same three ways. *)

type partial_failure = { tab_id : int; message : string; receipt : Yojson.Safe.t }
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

(** Native host verbs, decoded once from the MASC poll wire. *)
type verb = Browser_info | Tabs_list | Page_read | Page_elements | Page_capture | Page_scene | Page_interact | Page_act
  | Page_goto

(** The name a verb goes by on the wire and in the host's record. *)
val verb_to_wire : verb -> string
val verb_of_wire : string -> verb option
