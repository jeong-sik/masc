(** A browser tool's refusal, as a Keeper was told it.

    [Tool_misc_browser_lane] writes a refusal that dispatched nothing as one
    JSON object naming the case in [error]. The tool bridge appends its
    failure-class line after the tool's own text, so in a recorded result the
    refusal is the first line. [of_result] reads that line back into the
    lane's own vocabulary; any other text is [None]. *)

type detail =
  | Unserved of
      { transport : Browser_lane.live_transport
      ; capability : Browser_lane.live_capability
      ; serving_clients : int
      (** Connected browsers that serve the work, at the time of the call. *)
      }
  | Next_step of string
  (** The sentence the refusal gave for what happens next. *)

type t =
  { case : Browser_lane.selection_case
  ; detail : detail
  }

val of_result : string -> t option

(** The refusal on one row: the case code, then what was asked of which kind
    of connection or the refusal's own next-step sentence. The caller supplies
    the operator's words for a transport and for a piece of live work. *)
val line
  :  transport_label:(Browser_lane.live_transport -> string)
  -> capability_word:(Browser_lane.live_capability -> string)
  -> t
  -> string
