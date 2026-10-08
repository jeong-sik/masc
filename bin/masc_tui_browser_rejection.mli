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

(** The refusal on one row: the case code, then what the connection leaves
    out and how many connected browsers serve it, or the refusal's own
    next-step sentence. [lacking] is the caller's clause for a transport that
    leaves a piece of live work out, the one its other rows use. *)
val line
  :  lacking:(Browser_lane.live_transport -> Browser_lane.live_capability -> string)
  -> t
  -> string

(** What a Keeper chat row shows for a call's recorded result. [failed] is the
    row's own verdict: only a failed call's text is read for a refusal, and it
    then shows as {!line}. Every other text is shown as it was recorded. *)
val preview
  :  failed:bool
  -> lacking:(Browser_lane.live_transport -> Browser_lane.live_capability -> string)
  -> string
  -> string
