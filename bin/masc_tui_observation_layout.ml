module Tui_decode = Masc.Tui_decode

type context_summary =
  | Context_measured of {
      ratio : float;
      tokens : int;
      maximum : int;
      observed_at : string;
      turn_ref : string;
    }
  | Context_partial of {
      tokens : int;
      observed_at : string;
      turn_ref : string;
    }
  | Context_unavailable of string

type log_cells = {
  kind : string;
  messages : string;
  usage : string;
  latency : string;
}

(* Cells, not bytes. [String.length] counts bytes, and a Korean label spends
   three of them a character, so an eight-character name measured twenty and
   every one of them came back cut with a tilde -- in a column it fits. The cut
   was a byte offset too, which lands inside a character and hands the terminal
   a broken one.

   [Message_layout.fit_width] already measures display cells and keeps grapheme
   clusters whole, with this same tilde marker. These three were a second copy
   of it that could not read anything but ASCII. *)
let cells = Masc_tui_message_layout.display_width

type context_pressure =
  | Quiet
  | Pressure
  | Danger

(* The detail row shows one decimal place. Returning that displayed unit keeps
   its label, pressure thresholds, and bar fill on one rounding authority. *)
let percentage_tenths ratio = int_of_float (Float.round (ratio *. 1000.0))

let context_pressure ratio =
  let percentage_tenths = percentage_tenths ratio in
  if percentage_tenths >= 800 then Danger
  else if percentage_tenths >= 500 then Pressure
  else Quiet
;;

let log_kind_label = function
  | Tui_decode.Log_turn -> "turn"
  | Tui_decode.Log_heartbeat -> "hb"

let log_channel_label = function
  | Tui_decode.Log_channel_turn -> "turn"
  | Tui_decode.Log_channel_scheduled_autonomous -> "sched"
  | Tui_decode.Log_channel_heartbeat -> "hb"

let message_count_label = function
  | Some count -> string_of_int count
  | None -> "--"

let usage_value = function
  | Some value -> string_of_int value
  | None -> "--"

let usage_label ~input ~output =
  Printf.sprintf "%s/%s" (usage_value input) (usage_value output)

let latency_label = function
  | Some latency -> Printf.sprintf "%dms" latency
  | None -> "--"

(* The metrics tail's columns.

   The eight widths were written here and the eight column names were written
   in the renderer, one file apart, and each of the two lines was padded by
   hand: the readings by [pad_left]/[pad_right] into a record, the names by a
   format string. Nothing but care held the two at the same offsets, and care
   is what failed on the Tools catalog and the harness verdicts.

   {!Masc_tui_table} draws both from this one description. Four of the eight
   readings are counts and are read against each other down the column, so
   they are right-aligned; the four that are words are not. The work kind is
   the last named column and the tools that ran follow it, unbounded, which is
   why nothing after it can be pushed. *)

let log_cells (entry : Tui_decode.log_entry) =
  { kind = log_kind_label entry.le_kind;
    messages = message_count_label entry.le_message_count;
    usage =
      usage_label ~input:entry.le_input_tokens ~output:entry.le_output_tokens;
    latency = latency_label entry.le_latency_ms;
  }

let log_entry_rows ~width ~time (entry : Tui_decode.log_entry) =
  let wrap text =
    Masc_tui_message_layout.wrap_words ~max_cells:(max 1 (width - 2))
      (Masc.Tui_terminal_text.sanitize_terminal_text text)
    |> List.map (fun line -> "  " ^ line)
  in
  let cells = log_cells entry in
  wrap
    (Printf.sprintf "%s  %s  %s"
       time
       cells.kind cells.latency)
  @ wrap ("Timestamp: " ^ entry.le_ts)
  @ wrap ("Channel: " ^ log_channel_label entry.le_channel)
  @ wrap ("Messages: " ^ cells.messages ^ "  In/out: " ^ cells.usage)
  @ wrap ("Cost: " ^ (match entry.le_cost_usd with
      | None -> "--"
      | Some cost -> "$" ^ string_of_float cost))
  @ (match entry.le_work_kind with
     | None -> []
     | Some work -> wrap ("Work: " ^ work))
  @ List.concat_map (fun tool -> wrap ("Tool: " ^ tool)) entry.le_tools_used
  @ [ "" ]

let context_summary = function
  | Tui_decode.Context_observed
      { ratio = Some ratio;
        tokens;
        maximum = Some maximum;
        observed_at;
        turn_ref;
      }
    when maximum > 0 ->
      Context_measured { ratio; tokens; maximum; observed_at; turn_ref }
  | Tui_decode.Context_observed { tokens; observed_at; turn_ref; _ } ->
      Context_partial { tokens; observed_at; turn_ref }
  | Tui_decode.Context_unavailable reason ->
      Context_unavailable
        (Tui_decode.context_unavailable_reason_to_string reason)

let context_header_item ~ko ~max_cells ~inspect_key observation =
  let say korean english = if ko then korean else english in
  let context = say "컨텍스트" "Context" in
  let tok = say "토큰" "tok" in
  match context_summary observation with
  | Context_measured { ratio; tokens; maximum; _ } ->
      (* The key travels with the number. This line was the only place the
         pane said how full the context is, and there was no way in from it:
         the breakdown lived behind [/context], which is in [/help] and
         nowhere a reader looking at this figure would find it.

         Dropped first when the header runs out of room -- the figure is what
         the line is for, and a reader who has met the key once does not need
         it printed again. *)
      let grouped_int = Masc_tui_value.Count.grouped in
      let figure =
        Printf.sprintf "%s %.0f%% %s" context (ratio *. 100.0) (say "사용" "used")
      in
      let measured =
        Printf.sprintf "%s %.0f%% \xc2\xb7 %s/%s %s" context (ratio *. 100.0)
          (grouped_int tokens) (grouped_int maximum) tok
      in
      let with_key text = text ^ " \xc2\xb7 " ^ inspect_key in
      [ with_key measured; measured; with_key figure; figure ]
      |> List.find_opt (fun candidate -> max_cells >= cells candidate)
  | Context_partial {tokens; _} ->
      [ Printf.sprintf "%s %d %s · %s —" context tokens tok (say "한도" "limit")
      ; Printf.sprintf "%s %d %s" context tokens tok ]
      |> List.find_opt (fun candidate -> max_cells >= cells candidate)
  | Context_unavailable _ ->
      let unavailable = say "컨텍스트 측정 없음" "Context unavailable" in
      [ unavailable ^ " · " ^ inspect_key; unavailable; context ^ " —" ]
      |> List.find_opt (fun candidate -> max_cells >= cells candidate)
