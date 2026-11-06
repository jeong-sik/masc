(** The decoding of one stored line into a chat message.

    [parse_line_decoded] reads one line of a transcript in the two ways the
    readers need it. The [message] field of the result is the row as the
    permissive reader keeps it, and [None] when the line is dropped. The
    [strict_decode_error] field is the [strict_decode_cause] that makes the
    strict reader refuse the line, and [None] when the line has no defect. A
    line that is dropped is reported through [report_persistence_read_drop].
    [parse_line] is the [message] field alone.
    A [strict_decode_error] pairs a cause with the location of the row, and
    [strict_decode_error_to_string] renders it.
    [Keeper_chat_store] includes this module. *)
open Keeper_chat_types

type strict_decode_cause =
  | Invalid_surface of string
  | Unknown_speaker_authority of string
  | Missing_speaker_authority
  | Invalid_row_contract of string
  | Unreadable_file of string

type strict_decode_error =
  { location : string
  ; cause : strict_decode_cause
  }

val strict_decode_error_to_string : strict_decode_error -> string

type parsed_line =
  { message : chat_message option
  ; strict_decode_error : strict_decode_cause option
  }

val parse_line_decoded : file_path:string -> string -> parsed_line

val parse_line :
  file_path:string -> string -> chat_message option
