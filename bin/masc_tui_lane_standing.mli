(** How a lane or a Lane Add-on stands, read from what the TUI already
    decoded. The Lanes list and the Lane Add-ons screen draw a mark and a
    colour from it, so an installed, working Add-on reads apart from one that
    failed, one that is switched off and a built-in lane nobody set up.

    It is a reading for the screen. Nothing decides from it what a lane may
    do, and the row order does not follow it. *)

type t =
  | Ready  (** Set up and usable now. *)
  | Configured  (** An exact model route admits candidates. This establishes
                    configuration, not executor or provider readiness. *)
  | Waiting  (** Switched on, but what it needs has not arrived: no browser
                 connected, no executor registered, no screen yet. *)
  | Changing  (** A worker is starting, stopping or being replaced. *)
  | Failing  (** It refused, failed or cannot run what was declared. *)
  | Off  (** Switched off by the operator. *)
  | Not_set_up  (** Nothing declares or configures it. *)
  | Unobserved  (** The server did not say. *)

val all : t list
(** Every standing, in the order counts are written. *)

val mark : t -> string
(** One cell drawn before the row. *)

val word : korean:bool -> t -> string
(** The standing in a word or two. [korean] picks the display label and
    leaves the observed standing as it is. *)

val status : t -> Masc_tui_theme.status
(** The status colour of the mark. *)

val colour : t -> string
(** The SGR of {!status}, made readable against the terminal's own palette
    when it answered. Both screens draw the mark with this, so one standing
    is one colour everywhere. *)

val recedes : t -> bool
(** Whether the whole row is drawn behind the others: switched off, never
    set up, or not observed. *)

val count_items : korean:bool -> t list -> string list
(** [["3 ready"; "1 failing"; "2 off"]]: each standing present, with its
    count, in {!all} order. Korean labels precede their counts.
    [[]] for an empty list. These are observations, not required actions. *)
