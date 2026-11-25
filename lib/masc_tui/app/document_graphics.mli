(** Prepares visible Markdown diagrams and PNG images.
    The cells containing the diagram remain the text fallback until its raster
    fits the current frame's PNG payload budget. Visible raster requests use
    the pixel budget, and ready placements use the aggregate base64 payload
    bytes of their PNGs. *)

type t
type placement

val create : unit -> t
val take_dirty : t -> bool

val prepare :
  t ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  base_path:string ->
  endpoint:Masc_tui_net.Http_client.endpoint ->
  fetch_retained:(Masc_tui_net.Http_client.endpoint -> path:string -> max_body_bytes:int ->
    (string, Masc_tui_net.Http_client.limited_body_error) result) ->
  on_ready:(unit -> unit) ->
  probe:Masc_tui_term.Probe.observation ->
  theme:Masc_tui_core.Theme.t ->
  Masc_tui_term.Cell_grid.t ->
  placement list

val mask_fallback : Masc_tui_term.Cell_grid.t -> style:Masc_tui_term.Style.t -> placement -> unit
val cancel_pending : t -> unit
val retry_failed_retained : t -> unit
(** Admit another bounded attempt after a connection recovers. *)
val clear : t -> in_tmux:bool -> string
val before_present : t -> in_tmux:bool -> placement list -> string
val after_present : t -> in_tmux:bool -> full_repaint:bool -> placement list -> string
