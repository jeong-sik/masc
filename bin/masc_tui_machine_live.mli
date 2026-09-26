(** The spectator's read of a workspace machine's screen through
    [GET /api/v1/lane-addons/live] (RFC machine-spectating-goes-through-lanes
    §2.1). One route serves every machine that has a screen; the source kind
    names which one.

    The server answers one of three states, and {!decode} turns each into its
    own constructor or refuses the body. Nothing here does I/O: the executable
    layer sends {!path} and hands the decoded JSON back. *)

type source = Msx | Dos

val source_kind : source -> string
(** The [source_kind] query value: [msx_capture] or [dos_capture]. *)

val source_label : source -> string
(** How the screen names the machine: [MSX] or [DOS]. *)

type mark = { count : int; incarnation : string }
(** Which moment of which machine a picture is. The change count starts over
    when the server restarts, so a count alone cannot say "the same picture";
    the incarnation, fresh on every load or restore, is sent with it. *)

type time =
  | Frame of int  (** MSX: the frame number the server reports *)
  | Untimed  (** DOS: the live answer carries no machine time *)

type picture = {
  width : int;
  height : int;
  rgb : string;  (** [width * height] pixels, three bytes each *)
  mark : mark;
  time : time;
}

type answer =
  | No_machine  (** [state: "no_machine"] *)
  | Unchanged of mark  (** [state: "unchanged"]: still the mark that was sent *)
  | Picture of picture  (** [state: "changed"] *)

val path : source -> since:mark option -> string
(** The route with its query. [since] is the mark of the picture already
    drawn and is sent as [since] and [incarnation] together; without one the
    server always answers with a picture. *)

val decode : source -> Yojson.Safe.t -> (answer, string) result
(** Parse one answer. It must name the requested source kind. A picture must
    carry [frame_number] for MSX and none for DOS, a [screen] of format
    [rgb8] with positive dimensions and exactly [width * height * 3] decoded
    bytes, and its mark. An [Unchanged] answer is read without touching any
    pixel field. Anything else is an [Error] naming what was wrong. *)

type activity_entry = { at : float; who : string; action : string }
(** One line of "what a Keeper did to this machine", the wire shape of
    [Lane_activity.entry] read independently of it -- this module never links
    the server's write-side library, only its own JSON contract. *)

val activity_of : Yojson.Safe.t -> activity_entry list
(** The answer's [activity] array, read the same JSON {!decode} parses. A
    missing field, a field that is not a list, or one malformed entry inside
    it are not reasons to fail: this is a spectator convenience riding along
    with every answer (present or not, on every [state]), never a fact the
    picture depends on, so a caller gets what it can parse and drops the
    rest silently rather than turning a good picture into an [Error]. *)

(** What the spectator holds for one machine between reads. *)
type view =
  | Unread  (** nothing asked yet *)
  | Not_loaded  (** the server said no machine of this kind is loaded *)
  | Showing of picture
  | Failed of string  (** the last read failed; the reason is drawn *)

val since : view -> mark option
(** The mark to send with the next read: the drawn picture's, or [None]
    when no picture is drawn. *)

val advance : view -> (answer, string) result -> view option
(** The view after one read, or [None] when the answer changes nothing on
    screen: [Unchanged] at the drawn mark, or [No_machine] while already
    showing no machine. An [Unchanged] at any other mark is the server
    contradicting the request, and becomes [Failed]. *)
