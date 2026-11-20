module T = Masc_tui_types

(* Owed reads wait on this clock, so a wall-clock step cannot stretch a
   retry. *)
let max_reconnect_s = 30.0

(* A failed read leaves its record waiting, whoever started it: a read on
   entering a surface, which the record never saw start, retries on the same
   clock as one it started. *)
let failed_read owed =
  Masc_tui_owed_read.failed ~retry_s:Masc_tui_transport.Event_streams.stream_reconnect_s
    ~max_retry_s:max_reconnect_s ~now:(Masc_tui_wake.Mono.now ())
    (Masc_tui_owed_read.answering owed)

(* A background read's own answer, for zone 4 (RFC tui-one-screen-grammar
   §2). Called where the read's answer arrives, never where an error is put
   in place of one. The session event list still gets its line from the
   caller. *)
let note_read (state : T.state) read result =
  T.note_read_answer state read ~at:(Unix.gettimeofday ()) result

let remember_surface_error (state : T.state) ~surface ~current_error ~set_error err =
  let changed =
    match current_error with
    | Some current -> not (String.equal current err)
    | None -> true
  in
  set_error (Some err);
  if changed then
    Masc_tui_loader.add_event state "error"
      (Printf.sprintf "%s data unreliable: %s" surface err)

let pushed_read (state : T.state) source =
  Option.value ~default:Masc_tui_owed_read.settled (List.assoc_opt source state.T.pushed_reads)

let set_pushed_read (state : T.state) source read =
  state.T.pushed_reads <- (source, read) :: List.remove_assoc source state.T.pushed_reads

(* A bundle source in [pushed_sources] reads again when the server announces
   its change while its surface is on screen, and after a failed read
   (RFC-0480 §3.4). Entering the surface and a revalidation read it in the
   surface bundle. *)
let owe_pushed_read (state : T.state) source =
  set_pushed_read state source (Masc_tui_owed_read.changed (pushed_read state source))

(* An answer for a pushed source, whichever bundle asked, moves its owed
   read: a failure waits and reads again, and a success settles a read that
   was in flight. A success that lands while a change is still owed leaves it
   owed, so one more read follows. *)
let settle_pushed_dataset (state : T.state) dataset ~received =
  let source = T.Surface_read_order.dataset_source dataset in
  if List.mem source T.pushed_sources then
    set_pushed_read state source
      (if received then Masc_tui_owed_read.succeeded (pushed_read state source)
       else failed_read (pushed_read state source))
