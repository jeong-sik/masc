(* The fleet stream's async answers: the type [Masc_tui_async_protocol]
   carries in [Fleet_msg], and how each answer changes the reader. *)

open Masc_tui_types

type msg =
  | Fleet_stream_view of Masc_tui_fleet_stream.view
  | Fleet_stream_reader_ended of string

type answer_kind = Read

let answer_kind = function
  | Fleet_stream_view _ | Fleet_stream_reader_ended _ -> Read

let apply state = function
  | Fleet_stream_view view ->
      (* A view from a job that is no longer followed has no screen to go to. *)
      (match state.fleet_stream_reader with
       | Fleet_stream_following _ -> state.fleet_stream_reader <- Fleet_stream_following view
       | Fleet_stream_idle -> ())
  | Fleet_stream_reader_ended detail ->
      (* The job reconnects by itself and ends only when withdrawn, so an end
         it reports is a failure of the job: say so, draw nothing more from
         it, and let the next refresh start another. *)
      Log.Transport.warn "tui_fleet_stream_reader_ended detail=%s" detail;
      state.fleet_stream_reader <- Fleet_stream_idle
