(** Hourly and daily totals of the retained tool-call events.

    The store keeps one row per tool call. A dashboard that plots how many
    calls ran, how many failed and how long they took needs those rows grouped
    by clock hour or clock day. This module does the grouping. It reads no
    file and holds no lock: a caller streams samples into a {!builder} and
    reads the result with {!finish}.

    Bucket edges follow the viewer's clock, not UTC. A day that starts at
    midnight in Seoul starts at 15:00 UTC the day before, so the window carries
    the viewer's offset from UTC. The offset is one fixed number per request;
    a daylight-saving change inside the window is not followed.

    Every bucket between the window's first and last edge is present, with
    zero calls and no latency when nothing ran in it. A bucket with no calls
    has no p50, p95 or max, because there is no call to take them from.

    A percentile uses the rule of [Tool_metrics]: the sample at rank
    [round ((n - 1) * p)] of the ascending durations. The retained snapshot's
    top-20 table and this series therefore agree on the same calls. *)

(** How a call ended, as recorded in the store's [disposition] column. *)
type disposition =
  | Completed
  | Deferred
  | Failed

val disposition_of_string : string -> (disposition, string) result

(** The size of one bucket. *)
type width =
  | Hour
  | Day

val width_of_string : string -> (width, string) result
val string_of_width : width -> string

(** Which part of the clock a series covers, and where its buckets start. *)
type window

val max_window_days : int
(** The longest window {!window} accepts. *)

val window
  :  since:float
  -> until:float
  -> width:width
  -> utc_offset_min:int
  -> (window, string) result
(** [window ~since ~until ~width ~utc_offset_min] covers the epoch seconds
    from [since] (included) to [until] (excluded).
    [utc_offset_min] is minutes east of UTC. It returns [Error] when a bound
    is not a finite, supported timestamp, when the window is empty or longer
    than {!max_window_days}, or when the offset is outside +-14 hours. *)

val window_bounds : window -> float * float
(** [(since, until)] as given to {!window}. A reader that selects rows
    from a store uses it as the bounds of that selection. *)

val sliding_window :
  span_s:float -> until:float -> width:width -> utc_offset_min:int ->
  (window, string) result
(** The same bounds as {!window} with [since = until - span_s], retaining
    the requested span for exact floating-point deadline calculation. *)

val next_change_at :
  window -> oldest_sample:float option -> next_sample:float option -> float
(** The first epoch time at which the same sliding window can change its
    rows or bucket labels. [oldest_sample] is the oldest selected row and
    [next_sample] the first row at or beyond the exclusive upper bound.
    Both must be finite timestamps from the store. The lower bound includes
    a row at its timestamp, so expiry is strictly after it; admission is
    strictly after the future row's timestamp. Empty windows still change
    their emitted bucket labels at the next viewer-clock bucket boundary.
    This computes a deadline; it creates no timer or retained subscription. *)

(** One recorded tool call. *)
type sample =
  { ts : float
  ; tool_name : string
  ; disposition : disposition
  ; duration_ms : float
  }

type builder

val builder : window -> builder

val add : builder -> sample -> (unit, string) result
(** [add builder sample] counts [sample]. It returns [Error] and counts
    nothing when the timestamp is outside the window or the duration is
    negative or not finite. *)

(** Totals of a set of calls. [p50_ms], [p95_ms] and [max_ms] are [None] when
    the set is empty. Durations of completed, deferred and failed calls are
    all included. *)
type stat =
  { call_count : int
  ; failure_count : int
  ; deferred_count : int
  ; total_ms : float
  ; p50_ms : float option
  ; p95_ms : float option
  ; max_ms : float option
  }

type bucket =
  { start : float  (** First second of the bucket, in epoch seconds. *)
  ; summary : stat
  }

type tool_usage =
  { name : string
  ; usage : stat
  }

type t =
  { window : window  (** The window the samples were counted in. *)
  ; buckets : bucket list  (** Oldest first, one per {!width} step. *)
  ; total : stat  (** Every sample in the window. *)
  ; top_by_time : tool_usage list
        (** The tools that spent the most time, longest first. *)
  }

val top_tool_limit : int
(** How many tools [top_by_time] keeps. *)

val finish : builder -> t

val to_json
  :  generated_at:float
  -> ?tool_name:string
  -> ?public_names:(string -> string list)
  -> t
  -> Yojson.Safe.t
(** The response body of the series endpoint. Its [window] is the window of
    the series. [generated_at] is when the series was read, in epoch seconds. [tool_name] is the filter the samples
    were selected with, [None] for all tools. [public_names] lists the names
    under which a stored tool name is offered to a model; each row of
    [top_by_time] carries that list, empty by default. *)
