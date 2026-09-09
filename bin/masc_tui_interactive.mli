(** An interactive surface: a pane that owns its own loop (RFC-0439 §6.2's
    real-time side, a game, a VM console one day) and that the TUI hosts
    rather than draws.

    The contract is deliberately renderer-independent: [frame] carries
    either pixels or pre-rendered rows, so the terminal side — ANSI
    half-blocks today, Kitty pixels where the probe found them, Notty if
    that migration ever happens — picks how to draw it without the surface
    knowing. Input flows the other way as decoded key names; the surface
    says whether it consumed the key, which is the focus model the MSX
    spectator already improvises with [msx_open]. Nothing here names a
    renderer, the HTTP client, or the terminal. *)

type frame =
  | Pixels of { width : int; height : int; rgb : string }
      (** A raw framebuffer: [rgb] is width*height*3 bytes, row-major. *)
  | Rows of string
      (** Pre-rendered ANSI rows; the host paints them as-is. *)

module type S = sig
  val title : string
  (** Panel title while this surface is on screen. *)

  val current : unit -> frame option
  (** The frame to draw now. [None] keeps whatever the host last painted. *)

  val handle_input : string -> bool
  (** A decoded key while the surface holds focus. [true] means consumed;
      [false] hands it back — the escape that leaves the surface says
      [false] and the host closes the pane. *)

  val focus_changed : bool -> unit
  (** The pane gained or lost the terminal. A surface that animates pauses
      here instead of burning frames nobody sees. *)

  val tick : dt:float -> unit
  (** Host-driven time step in seconds. Where the real-time ticker lands
      (server poll today, a dedicated loop later), this is the beat it
      arrives on. *)

  val stop : unit -> unit
  (** The pane is closing; release what the surface holds. *)
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
