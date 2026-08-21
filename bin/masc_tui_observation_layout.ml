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

let fit width value =
  let length = String.length value in
  if length <= width then value
  else if width <= 1 then String.make width '~'
  else String.sub value 0 (width - 1) ^ "~"

let pad_left width value =
  let value = fit width value in
  String.make (width - String.length value) ' ' ^ value

let pad_right width value =
  let value = fit width value in
  value ^ String.make (width - String.length value) ' '

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
