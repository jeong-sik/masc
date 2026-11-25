(** Hand the terminal to the alphaTab music viewer and take it back when the
    viewer exits.

    The viewer is the installed [masc-alphatex] executable. This module builds
    its command line and runs it on this process's stdin and stdout. The
    caller pauses and resumes the TUI around {!run} through
    {!Cmd_executor.editor_handoff}. *)

open Masc_tui_store

type command = { executable : string; args : string list }

val executable_name : string
(** The viewer's file name, looked up on [PATH]. *)

val args : base_path:string -> Cmd.terminal_program -> string list
(** The viewer's command-line arguments. Projects and recorded takes live
    under the workspace's [.masc/music] directory, so one workspace always
    reopens the same library. *)

val command :
  base_path:string -> Cmd.terminal_program -> (command, string) result
(** [Error] says what is missing: the MIDI file to import is not a regular
    file, or the viewer is not on [PATH]. *)

val run : command -> (unit, string) result
(** Run the viewer on this process's stdin and stdout and wait for it to exit.
    Blocks until then, so call it from a system thread. [Error] is a failed
    spawn, a non-zero exit, or a signal.

    The TUI keeps its own stderr pointed at a log file, so the viewer's stderr
    goes to a temp file instead. When the viewer exits, that text is copied to
    this process's stderr, under a [masc-alphatex stderr:] line. After a
    non-zero exit or a signal the last non-blank line of it, at most 200 bytes,
    also ends the [Error] text. *)
