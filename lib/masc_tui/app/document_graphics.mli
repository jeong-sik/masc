(** Prepares visible Markdown diagrams offline and owns one Kitty placement.
    The cells containing the diagram remain the text fallback until its raster
    has arrived. *)

type t
type placement

val create : unit -> t
val take_dirty : t -> bool

val prepare :
  t ->
  sw:Eio.Switch.t ->
  base_path:string ->
  on_ready:(unit -> unit) ->
  probe:Masc_tui_term.Probe.observation ->
  term_program:string option ->
  in_tmux:bool ->
  theme:Masc_tui_core.Theme.t ->
  Masc_tui_term.Cell_grid.t ->
  placement option

val mask_fallback : Masc_tui_term.Cell_grid.t -> style:Masc_tui_term.Style.t -> placement -> unit
val cancel_pending : t -> unit
val clear : t -> in_tmux:bool -> string * bool
val before_present : t -> in_tmux:bool -> placement option -> string * bool
val after_present : t -> in_tmux:bool -> full_repaint:bool -> placement option -> string
