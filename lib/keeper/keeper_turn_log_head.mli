(** What a Keeper's saved Agent-Core history says to the turn log
    (RFC librarian-call-only-proposes §5.1, §5.2): how many of its messages
    are closed, how many are open, and which turns hold the closed ones.

    Only the head is read. No message object is loaded. *)

module Objects := Agent_core.Checkpoint_objects
module Marks := Keeper_turn_log_marks

type t =
  { closed_messages : int
  ; open_messages : int
  (** Messages of the open turn. A mark does not count them. *)
  ; covered : Marks.covered
  }

(** A history that holds nothing. *)
val empty : t

val of_history : Objects.history -> t

(** The saved history of [session_id].

    A history this build does not interpret is read as {!empty}, the way the
    turn that starts from it sees it
    ({!Keeper_checkpoint_store_load.turn_history_of_load}): there is no
    checkpoint, or an earlier build wrote it in a version this one replaces.
    The first save of that turn puts the new history under the same session.

    Every other failure is an error. The head is there and was not read, so a
    count of 0 would be a guess. *)
val read
  :  session_dir:string
  -> session_id:string
  -> (t, Keeper_checkpoint_store_decode.checkpoint_load_error) result

type segment_unread =
  | Segment_missing
  | Segment_unreadable of string
  | Segment_invalid of Objects.load_error
  (** The bytes under the name are not a segment, or not what the name says. *)

val segment_unread_to_string : segment_unread -> string

type covering_error =
  | Range of Marks.range_error
  (** The run ends after the last closed message, or is backwards. *)
  | Segment of segment_unread Marks.segment_error

(** What [ask] answers. While it answers that its run starts before what is
    covered, the segment before is read from [session_dir], put in front, and
    [ask] is asked again. Each segment is read by the name the turns after it
    hold and is checked against that name. *)
val with_segments_as_needed
  :  session_dir:string
  -> Marks.covered
  -> (Marks.covered -> ('a, Marks.range_error) result)
  -> ('a, covering_error) result
