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
  channel : string;
  messages : string;
  usage : string;
  latency : string;
  cost : string;
  work : string;
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

let cost_label = function
  | Some cost -> Printf.sprintf "$%.3f" cost
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

let log_time_width = 8
let log_kind_width = 4
let log_channel_width = 8
let log_messages_width = 5
let log_usage_width = 13
let log_latency_width = 9
let log_cost_width = 9
let log_work_width = 10
let log_cell_gap = 1
let log_row_indent = "  "

let log_cells (entry : Tui_decode.log_entry) =
  { kind = log_kind_label entry.le_kind;
    channel = log_channel_label entry.le_channel;
    messages = message_count_label entry.le_message_count;
    usage =
      usage_label ~input:entry.le_input_tokens ~output:entry.le_output_tokens;
    latency = latency_label entry.le_latency_ms;
    cost = cost_label entry.le_cost_usd;
    work = Option.value ~default:"" entry.le_work_kind;
  }

let log_table_cells ~time cells =
  let right = Masc_tui_table.Right in
  [ Masc_tui_table.cell ~header:"TIME" ~width:log_time_width time
  ; Masc_tui_table.cell ~header:"KIND" ~width:log_kind_width cells.kind
  ; Masc_tui_table.cell ~header:"CHANNEL" ~width:log_channel_width
      cells.channel
  ; Masc_tui_table.cell ~align:right ~header:"MSGS" ~width:log_messages_width
      cells.messages
  ; Masc_tui_table.cell ~align:right ~header:"IN/OUT" ~width:log_usage_width
      cells.usage
  ; Masc_tui_table.cell ~align:right ~header:"LAT" ~width:log_latency_width
      cells.latency
  ; Masc_tui_table.cell ~align:right ~header:"COST" ~width:log_cost_width
      cells.cost
  ; Masc_tui_table.cell ~header:"WORK" ~width:log_work_width cells.work
  ]

let empty_log_cells =
  { kind = ""
  ; channel = ""
  ; messages = ""
  ; usage = ""
  ; latency = ""
  ; cost = ""
  ; work = ""
  }

let plain_log_header =
  log_row_indent
  ^ Masc_tui_table.header_row ~gap:log_cell_gap
      (log_table_cells ~time:"" empty_log_cells)

let plain_log_row ~time entry =
  log_row_indent
  ^ Masc_tui_table.row ~gap:log_cell_gap
      (log_table_cells ~time (log_cells entry))

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

let context_header_item ~max_cells observation =
  match context_summary observation with
  | Context_measured { ratio; tokens; maximum; _ } ->
      (* The key travels with the number. This line was the only place the
         pane said how full the context is, and there was no way in from it:
         the breakdown lived behind [/context], which is in [/help] and
         nowhere a reader looking at this figure would find it.

         Dropped first when the header runs out of room -- the figure is what
         the line is for, and a reader who has met the key once does not need
         it printed again. *)
      let grouped_int value =
        let digits = string_of_int value in
        let length = String.length digits in
        let grouped = Buffer.create (length + (length / 3)) in
        String.iteri
          (fun index char ->
            if index > 0 && (length - index) mod 3 = 0 then
              Buffer.add_char grouped ',';
            Buffer.add_char grouped char)
          digits;
        Buffer.contents grouped
      in
      let figure = Printf.sprintf "Context %.0f%% used" (ratio *. 100.0) in
      let measured =
        Printf.sprintf "Context %.0f%% \xc2\xb7 %s/%s tok" (ratio *. 100.0)
          (grouped_int tokens) (grouped_int maximum)
      in
      [ measured ^ " \xc2\xb7 ^X"; measured; figure ^ " \xc2\xb7 ^X"; figure ]
      |> List.find_opt (fun candidate -> max_cells >= cells candidate)
  | Context_partial _ | Context_unavailable _ -> None
