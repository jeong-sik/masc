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

type context_pressure =
  | Quiet
  | Pressure
  | Danger

(* The detail row shows one decimal place. Returning that displayed unit keeps
   its label, pressure thresholds, and bar fill on one rounding authority. *)
let percentage_tenths_full = 1000

let percentage_tenths ratio =
  int_of_float (Float.round (ratio *. float_of_int percentage_tenths_full))

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

(* A metrics record that left a reading out says so with the unreported mark
   of RFC tui-one-screen-grammar 6.4, not [--]. Counts group their thousands
   (6.3) and a latency reads on the finished-length ladder (6.2): [1.2s], not
   [1200ms]. A negative latency is a reading that failed. *)
let unreported = Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unreported

let message_count_label = function
  | Some count -> Masc_tui_value.Count.grouped count
  | None -> unreported

let usage_value = function
  | Some value -> Masc_tui_value.Count.grouped value
  | None -> unreported

let usage_label ~input ~output =
  Printf.sprintf "%s/%s" (usage_value input) (usage_value output)

let latency_label = function
  | Some latency ->
      Option.value
        ~default:(Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Read_failed)
        (Masc_tui_message_layout.elapsed_text (float_of_int latency /. 1000.))
  | None -> unreported

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
      | None -> unreported
      | Some cost -> Printf.sprintf "$%.4f" cost))
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

(* The context reading as facts of the chat's Keeper status block: the share,
   the token counts behind it, and the key that opens the breakdown. The key
   travels with the number. This block is the only place the pane says how
   full the context is, and the breakdown otherwise lives behind [/context],
   which is in [/help] and nowhere a reader looking at this figure would find
   it. The key says what it opens, because a narrow block can put it on a row
   of its own. *)
let context_facts ?(pressure_tone = fun _ -> Masc_tui_chat_facts.Amount)
    ~ko ~inspect_key observation =
  let say korean english = if ko then korean else english in
  let fact = Masc_tui_chat_facts.fact in
  let context = say "컨텍스트 " "Context " in
  let tok = say "토큰" "tok" in
  let key =
    fact Masc_tui_chat_facts.Plain
      (inspect_key ^ say ":컨텍스트" ":context")
  in
  match context_summary observation with
  | Context_measured { ratio; tokens; maximum; _ } ->
      let grouped_int = Masc_tui_value.Count.grouped in
      (* The share and the counts behind it are one fact: the counts alone on
         the next row would not say what they count. *)
      [ fact ~label:context (pressure_tone (context_pressure ratio))
          (Printf.sprintf "%.0f%% (%s/%s %s)" (ratio *. 100.0) (grouped_int tokens)
             (grouped_int maximum) tok)
      ; key
      ]
  | Context_partial { tokens; _ } ->
      [ fact ~label:context Masc_tui_chat_facts.Amount
          (Printf.sprintf "%s %s (%s —)" (Masc_tui_value.Count.grouped tokens) tok
             (say "한도" "limit"))
      ]
  | Context_unavailable _ ->
      [ fact ~label:context Masc_tui_chat_facts.Plain (say "미측정" "unmeasured"); key ]
