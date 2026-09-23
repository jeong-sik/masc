(* How long ago a wire timestamp was, for a screen that draws its own clock.

   Cells and phrases used to draw the clock alone, on the reading that the
   header's clock gives it a distance. That holds only while the two are the
   same day.
   On the live workspace a dashboard session last seen on 2026-09-21 drew
   "11:49:28" under a header reading 09:31:39 on 2026-09-23 -- the only
   distance a reader could take from that pointed two hours ahead, for a row
   that had been gone a day and a half.

   A span carries its own day, so nothing that draws it needs the header to
   be read. *)

module Message_layout = Masc_tui_message_layout

let never = "never"

let text ~now last_seen =
  if String.equal last_seen "" then never
  else
    match Time_codec.parse_rfc3339_opt last_seen with
    | Some since -> (
        match Message_layout.age_text ~now ~since with
        (* A stamp ahead of this clock. Drawing a span would say how long ago
           something that has not happened yet happened, so the text stands
           as it came and the reader can see which clock is wrong. *)
        | None -> Masc.Tui_decode.sanitize_terminal_text last_seen
        | Some age -> age)
    (* A stamp this build cannot read is shown as it arrived rather than as
       an age it did not measure. *)
    | None -> Masc.Tui_decode.sanitize_terminal_text last_seen
