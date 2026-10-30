(** Who owns the browser a connection reaches: the unit one browser worker
    serves (RFC browser-backends-end-alone, invariant 1). A failure stays
    with the one who owns the browser, so the worker boundary follows it.

    The transport stays on the client: [Owned_firefox] and [External_host]
    both speak WebDriver BiDi, and only who launched the browser tells them
    apart. A new source is a new constructor, and every reader matches on
    [t] without a catch-all. *)

(** [all] (derived) lists every source in constructor order. *)
type t =
  | Automation  (** the Gecko browser masc drives through geckodriver *)
  | Stagehand  (** the Chrome masc drives through Stagehand *)
  | Owned_firefox  (** the live Firefox masc launches and reaches over BiDi *)
  | Ego  (** the ego lite task space masc opens *)
  | External_host  (** the clients an outside native host brings: a browser extension or a BiDi host *)
[@@deriving enumerate]

(** The lane a Keeper names for this source. Several sources share [Live]. *)
val lane : t -> Browser_lane_name.t

val to_wire : t -> string

(** [None] for any string that is not exactly a source's wire name. *)
val of_wire : string -> t option

(** Every wire name, for the error text about a string that is no source. *)
val expected : string
