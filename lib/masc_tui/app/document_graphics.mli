(** Prepares visible Markdown diagrams and inline raster images across Kitty,
    iTerm2, and pure-OCaml Unicode half-block fallback terminals.

    - Kitty: PNG transmission ([f=100]); requests [?format=png] for non-PNG
      [/api/v1/attachments/<id>] images.
    - iTerm2: inline OSC 1337 placement natively supporting PNG/JPEG/WebP/GIF.
    - Standard / tmux / non-graphics terminals: requests [?format=png&max_px=160]
      and paints 24-bit truecolor Unicode half-block (['▀']) previews directly
      onto {!Masc_tui_term.Cell_grid.t}. *)

type t
type placement

val create : unit -> t
val next_retry_deadline : t -> Masc_tui_core.Clock.Mono.t option
val take_dirty : t -> now:Masc_tui_core.Clock.Mono.t -> bool

val prepare :
  t ->
  sw:Eio.Switch.t ->
  now:Masc_tui_core.Clock.Mono.t ->
  base_path:string ->
  endpoint:Masc_tui_net.Http_client.endpoint ->
  fetch_retained:(Masc_tui_net.Http_client.endpoint -> path:string -> max_body_bytes:int ->
    (string, Masc_tui_net.Http_client.limited_body_error) result) ->
  on_ready:(unit -> unit) ->
  ?term_program:string option ->
  ?in_tmux:bool ->
  probe:Masc_tui_term.Probe.observation ->
  theme:Masc_tui_core.Theme.t ->
  Masc_tui_term.Cell_grid.t ->
  placement list

val mask_fallback :
  ?bg_rgb:int ->
  Masc_tui_term.Cell_grid.t ->
  style:Masc_tui_term.Style.t ->
  placement ->
  unit

val cancel_pending : t -> unit
val clear : t -> in_tmux:bool -> string
val before_present : t -> in_tmux:bool -> placement list -> string
val after_present : t -> in_tmux:bool -> full_repaint:bool -> placement list -> string
