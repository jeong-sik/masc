(** Hand the terminal to the alphaTab music viewer and take it back when the
    viewer exits.

    The viewer is the installed [masc-alphatex] executable. This module resolves
    what the viewer needs, builds its command line, and runs it on this
    process's stdin and stdout. The caller pauses and resumes the TUI around
    {!run} through {!Cmd_executor.editor_handoff}. *)

open Masc_tui_store

type launch =
  | Workbench
  | Import_midi of string
  | Score of { bundle : string; index : int; cell_pixels : int * int }
      (** [bundle] is the path of a JSON snapshot [{"sources": [...]}] of the
          alphaTex sources. [index] counts from 1. [cell_pixels] is the
          measured width and height of one terminal cell. *)

val executable_name : string
(** The viewer's file name, looked up on [PATH]. *)

val executable : unit -> (string, string) result
(** The viewer's absolute path. [Error] says it is not installed. *)

val args : base_path:string -> launch -> string list
(** The viewer's command-line arguments. Projects and recorded takes live
    under the workspace's [.masc/music] directory, so one workspace always
    reopens the same library. *)

val with_launch :
  cell_pixels:(int * int) option ->
  Cmd.terminal_program ->
  (launch -> (unit, string) result) ->
  (unit, string) result
(** [with_launch ~cell_pixels program k] resolves [program] and passes the
    result to [k]. [Error] says what is missing: the MIDI file to import is
    not a regular file, or a score is asked for without measured cell sizes.
    [k] is not called then. A score's bundle file exists only while [k] runs. *)

val run : executable:string -> string list -> (unit, string) result
(** Run the viewer on this process's stdin and stdout and wait for it to exit.
    Blocks until then, so call it from a system thread. [Error] is a failed
    spawn, a non-zero exit, or a signal.

    The TUI keeps its own stderr pointed at a log file, so the viewer's stderr
    goes to a temp file instead. When the viewer exits, that text is copied to
    this process's stderr, under a [masc-alphatex stderr:] line. After a
    non-zero exit or a signal the last non-blank line of it, at most 200 bytes,
    also ends the [Error] text. *)
