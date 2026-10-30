(** An interactive surface: a pane that owns its own loop (RFC-0439 §6.2's
    real-time side, a game, a VM console one day) and that the TUI hosts
    rather than draws.

    The contract is deliberately renderer-independent: [frame] carries the
    pixels, so the terminal side — ANSI half-blocks today, Kitty pixels
    where the probe found them, Notty if that migration ever happens —
    picks how to draw it without the surface knowing. Input flows the other
    way as decoded key names; the surface says whether it consumed the key,
    which is the focus model the MSX spectator already improvises with
    [msx_open]. Nothing here names a renderer, the HTTP client, or the
    terminal. *)

type frame = Pixels of { width : int; height : int; rgb : string }
(** A raw framebuffer: [rgb] is width*height*3 bytes, row-major.

    A [Rows of string] arm for pre-rendered ANSI sat here and nothing ever
    built one; the host's only match on it folded into the empty case
    (#34791). A surface that wants to paint its own rows adds the arm back
    with the host branch that draws it. *)

module type S = sig
  val title : string
  (** Panel title while this surface is on screen. *)

  val current : unit -> frame option
  (** The frame to draw now. [None] clears the surface body, so a stale
      frame does not linger -- what [Masc_tui_msx.render] does with it. This
      said "keeps whatever the host last painted", which was the opposite
      of the one host there is (#34791). *)

  val handle_input : string -> bool
  (** A decoded key while the surface holds focus. [true] means consumed;
      [false] hands it back — the escape that leaves the surface says
      [false] and the host closes the pane. *)
end

val msx :
  fetch:(unit -> Masc_tui_types.msx_frame option) ->
  press:(string -> bool) ->
  (module S)
(** The MSX surface over the existing spectator feed: [fetch] returns the
    latest frame the poll cached, [press] sends a key to the shared machine
    and reports whether it was delivered. Keys the machine has no place for
    come back unconsumed. The executable layer owns both effects; the
    surface decides only what a key means. *)
