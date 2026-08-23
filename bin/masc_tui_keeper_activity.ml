module Decode = Masc.Tui_decode

type tool_use = {
  tu_name : string;
  tu_calls : int;
}

type window = {
  aw_turns : int;
  aw_heartbeats : int;
  aw_input_tokens : int;
  aw_output_tokens : int;
  aw_cost_usd : float;
  aw_tool_calls : int;
  aw_top_tools : tool_use list;
  aw_covered : bool;
  aw_oldest_ts : string option;
}

let empty =
  {
    aw_turns = 0;
    aw_heartbeats = 0;
    aw_input_tokens = 0;
    aw_output_tokens = 0;
    aw_cost_usd = 0.;
    aw_tool_calls = 0;
    aw_top_tools = [];
    aw_covered = false;
    aw_oldest_ts = None;
  }

let seconds_per_hour = 3600.

let cutoff_of ~now ~hours =
  let tm = Unix.gmtime (now -. (float_of_int hours *. seconds_per_hour)) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

let top_tools counts ~limit =
  Hashtbl.fold (fun name calls acc -> { tu_name = name; tu_calls = calls } :: acc) counts []
  |> List.sort (fun a b ->
         match compare b.tu_calls a.tu_calls with
         | 0 -> String.compare a.tu_name b.tu_name
         | order -> order)
  |> List.filteri (fun index _ -> index < limit)

let summarize ~since entries =
  let counts = Hashtbl.create 16 in
  let oldest = ref None in
  let window =
    List.fold_left
      (fun acc (entry : Decode.log_entry) ->
        (* Row timestamps and [since] share the metrics [ts] shape, so the
           lexicographic order is the chronological one. *)
        if String.compare entry.Decode.le_ts since < 0 then acc
        else begin
          (match !oldest with
           | Some current when String.compare current entry.Decode.le_ts <= 0 -> ()
           | Some _ | None -> oldest := Some entry.Decode.le_ts);
          List.iter
            (fun tool ->
              let previous = Option.value (Hashtbl.find_opt counts tool) ~default:0 in
              Hashtbl.replace counts tool (previous + 1))
            entry.Decode.le_tools_used;
          {
            acc with
            aw_turns =
              (match entry.Decode.le_kind with
               | Decode.Log_turn -> acc.aw_turns + 1
               | Decode.Log_heartbeat -> acc.aw_turns);
            aw_heartbeats =
              (match entry.Decode.le_kind with
               | Decode.Log_heartbeat -> acc.aw_heartbeats + 1
               | Decode.Log_turn -> acc.aw_heartbeats);
            aw_input_tokens =
              acc.aw_input_tokens + Option.value entry.Decode.le_input_tokens ~default:0;
            aw_output_tokens =
              acc.aw_output_tokens + Option.value entry.Decode.le_output_tokens ~default:0;
            aw_cost_usd =
              acc.aw_cost_usd +. Option.value entry.Decode.le_cost_usd ~default:0.;
            aw_tool_calls =
              acc.aw_tool_calls + List.length entry.Decode.le_tools_used;
          }
        end)
      empty entries
  in
  let covered =
    match entries with
    | [] -> false
    | _ ->
      List.exists
        (fun (entry : Decode.log_entry) ->
          String.compare entry.Decode.le_ts since < 0)
        entries
  in
  {
    window with
    aw_top_tools = top_tools counts ~limit:3;
    aw_covered = covered;
    aw_oldest_ts = !oldest;
  }
