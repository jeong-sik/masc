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

(* [fit_width] pads on the right as it fits, which is exactly [pad_right]. *)
let pad_right width value = Masc_tui_message_layout.fit_width value width

let fit width value =
  if width <= 0 then ""
  else if cells value <= width then value
  else
    (* Over the budget, so [fit_width] truncates rather than pads and the
       result already measures [width]. *)
    Masc_tui_message_layout.fit_width value width

let pad_left width value =
  let value = fit width value in
  String.make (max 0 (width - cells value)) ' ' ^ value

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

let log_cells (entry : Tui_decode.log_entry) =
  { kind = pad_right 4 (log_kind_label entry.le_kind);
    channel = pad_right 8 (log_channel_label entry.le_channel);
    messages = pad_left 5 (message_count_label entry.le_message_count);
    usage =
      pad_left 13
        (usage_label ~input:entry.le_input_tokens ~output:entry.le_output_tokens);
    latency = pad_left 9 (latency_label entry.le_latency_ms);
    cost = pad_left 9 (cost_label entry.le_cost_usd);
    work = pad_right 10 (Option.value ~default:"" entry.le_work_kind);
  }

let plain_log_row ~time entry =
  let cells = log_cells entry in
  Printf.sprintf "  %-8s %s %s %s %s %s %s  %s" time cells.kind
    cells.channel cells.messages cells.usage cells.latency cells.cost cells.work

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
