(** MASC Cost Tracking CLI
    Track token usage and costs per agent/task. *)

open Printf

type cost_entry =
  { agent : string
  ; task_id : string option
  ; model : string
  ; input_tokens : int option
  ; output_tokens : int option
  ; cost_usd : float option
  ; timestamp : string
  ; ts_unix : float
  }

type period =
  | Hourly
  | Daily
  | Weekly
  | Monthly
  | All

type agent_total =
  { agent : string
  ; tokens : int
  ; cost_usd : float
  ; model : string
  ; usage_missing_entries : int
  }

let ( let* ) = Result.bind

let get_masc_root () =
  let base_path = Config_dir_resolver.base_path_or_cwd () in
  Config_dir_resolver.masc_root ~base_path
;;

let costs_dir () = Filename.concat (get_masc_root ()) "costs"

let nonblank value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed
;;

let required_string fields key =
  match List.assoc_opt key fields with
  | Some (`String value) ->
    (match nonblank value with
     | Some value -> Ok value
     | None -> Error (key ^ " must be a non-empty string"))
  | _ -> Error (key ^ " must be a non-empty string")
;;

let required_optional_string fields key =
  match List.assoc_opt key fields with
  | Some `Null -> Ok None
  | Some (`String value) ->
    (match nonblank value with
     | Some value -> Ok (Some value)
     | None -> Error (key ^ " must be null or a non-empty string"))
  | _ -> Error (key ^ " must be null or a non-empty string")
;;

let required_bool fields key =
  match List.assoc_opt key fields with
  | Some (`Bool value) -> Ok value
  | _ -> Error (key ^ " must be a boolean")
;;

let required_nonnegative_int fields key =
  match List.assoc_opt key fields with
  | Some (`Int value) when value >= 0 -> Ok value
  | _ -> Error (key ^ " must be a non-negative integer")
;;

let required_nonnegative_float fields key =
  let value =
    match List.assoc_opt key fields with
    | Some (`Float value) -> Some value
    | Some (`Int value) -> Some (Float.of_int value)
    | _ -> None
  in
  match value with
  | Some value when Float.is_finite value && value >= 0.0 -> Ok value
  | _ -> Error (key ^ " must be a finite non-negative number")
;;

let required_null fields key =
  match List.assoc_opt key fields with
  | Some `Null -> Ok ()
  | _ -> Error (key ^ " must be null when usage_missing is true")
;;

let parse_cost_json = function
  | `Assoc fields ->
    let* agent = required_string fields "agent" in
    let* task_id = required_optional_string fields "task_id" in
    let* model = required_string fields "model" in
    let* timestamp = required_string fields "timestamp" in
    let* _source = required_string fields "source" in
    let* usage_missing = required_bool fields "usage_missing" in
    let* ts_unix =
      match Masc_domain.parse_iso8601_opt timestamp with
      | Some value -> Ok value
      | None -> Error "timestamp must be a valid ISO-8601 UTC value"
    in
    let* input_tokens, output_tokens, cost_usd =
      if usage_missing
      then (
        let* () = required_null fields "input_tokens" in
        let* () = required_null fields "output_tokens" in
        let* () = required_null fields "cost_usd" in
        Ok (None, None, None))
      else (
        let* input_tokens = required_nonnegative_int fields "input_tokens" in
        let* output_tokens = required_nonnegative_int fields "output_tokens" in
        let* cost_usd = required_nonnegative_float fields "cost_usd" in
        Ok (Some input_tokens, Some output_tokens, Some cost_usd))
    in
    Ok
      { agent
      ; task_id
      ; model
      ; input_tokens
      ; output_tokens
      ; cost_usd
      ; timestamp
      ; ts_unix
      }
  | _ -> Error "cost row must be a JSON object"
;;

let cost_json ~agent ~task_id ~model ~input_tokens ~output_tokens ~cost_usd =
  `Assoc
    [ "agent", `String agent
    ; ( "task_id"
      , match task_id with
        | Some value -> `String value
        | None -> `Null )
    ; "model", `String model
    ; "input_tokens", `Int input_tokens
    ; "output_tokens", `Int output_tokens
    ; "cost_usd", `Float cost_usd
    ; "usage_missing", `Bool false
    ; "timestamp", `String (Masc_domain.now_iso ())
    ; "source", `String "manual_cli"
    ]
;;

let validate_log_input ~agent ~model ~input_tokens ~output_tokens ~cost_usd =
  if nonblank agent = None
  then Error "--agent is required for --log"
  else if nonblank model = None
  then Error "--model is required for --log"
  else if input_tokens < 0
  then Error "--input-tokens must be non-negative"
  else if output_tokens < 0
  then Error "--output-tokens must be non-negative"
  else if not (Float.is_finite cost_usd) || cost_usd < 0.0
  then Error "--cost must be a finite non-negative number"
  else Ok ()
;;

let log_cost ~agent ~task_id ~model ~input_tokens ~output_tokens ~cost_usd =
  let store = Dated_jsonl.create ~base_dir:(costs_dir ()) () in
  Dated_jsonl.append
    store
    (cost_json ~agent ~task_id ~model ~input_tokens ~output_tokens ~cost_usd);
  printf "Cost logged: %s → $%.4f\n" agent cost_usd
;;

let line_label path line_number =
  match line_number with
  | Some line_number -> sprintf "%s:%d" path line_number
  | None -> path
;;

let read_costs () =
  let store = Dated_jsonl.create ~base_dir:(costs_dir ()) () in
  let entries = ref [] in
  let invalid_rows = ref 0 in
  let note_invalid location reason =
    incr invalid_rows;
    eprintf "Warning: skipped invalid cost row at %s: %s\n" location reason
  in
  match
    Dated_jsonl.iter_all_entries_result store (function
      | Dated_jsonl.Malformed_json { path; line_number; detail } ->
        note_invalid (line_label path line_number) detail
      | Dated_jsonl.Parsed json ->
        (match parse_cost_json json with
         | Ok entry -> entries := entry :: !entries
         | Error reason ->
           note_invalid (Dated_jsonl.base_dir store) reason))
  with
  | Ok () -> Ok (List.rev !entries, !invalid_rows)
  | Error error -> Error (Dated_jsonl.read_error_to_string error)
;;

let period_of_string = function
  | "hourly" -> Ok Hourly
  | "daily" -> Ok Daily
  | "weekly" -> Ok Weekly
  | "monthly" -> Ok Monthly
  | "all" -> Ok All
  | value ->
    Error
      (sprintf
         "invalid --period %S (expected hourly|daily|weekly|monthly|all)"
         value)
;;

let period_label = function
  | Hourly -> "hourly"
  | Daily -> "daily"
  | Weekly -> "weekly"
  | Monthly -> "monthly"
  | All -> "all"
;;

let filter_by_period period (entries : cost_entry list) =
  let now = Unix.gettimeofday () in
  let cutoff =
    match period with
    | Hourly -> now -. 3600.0
    | Daily -> now -. 86400.0
    | Weekly -> now -. 604800.0
    | Monthly -> now -. 2592000.0
    | All -> 0.0
  in
  List.filter (fun (entry : cost_entry) -> entry.ts_unix >= cutoff) entries
;;

let filter_by_agent agent (entries : cost_entry list) =
  if String.equal agent ""
  then entries
  else
    List.filter (fun (entry : cost_entry) -> String.equal entry.agent agent) entries
;;

let filter_by_task task_id (entries : cost_entry list) =
  if String.equal task_id ""
  then entries
  else List.filter (fun (entry : cost_entry) -> entry.task_id = Some task_id) entries
;;

let known_tokens (entry : cost_entry) =
  let input =
    match entry.input_tokens with
    | Some value -> value
    | None -> 0
  in
  let output =
    match entry.output_tokens with
    | Some value -> value
    | None -> 0
  in
  input + output
;;

let known_cost (entry : cost_entry) =
  match entry.cost_usd with
  | Some value -> value
  | None -> 0.0
;;

let usage_missing (entry : cost_entry) =
  entry.input_tokens = None || entry.output_tokens = None || entry.cost_usd = None
;;

let aggregate_by_agent (entries : cost_entry list) =
  let totals = Hashtbl.create 8 in
  List.iter
    (fun (entry : cost_entry) ->
       let previous =
         match Hashtbl.find_opt totals entry.agent with
         | Some value -> value
         | None ->
           { agent = entry.agent
           ; tokens = 0
           ; cost_usd = 0.0
           ; model = entry.model
           ; usage_missing_entries = 0
           }
       in
       Hashtbl.replace
         totals
         entry.agent
         { previous with
           tokens = previous.tokens + known_tokens entry
         ; cost_usd = previous.cost_usd +. known_cost entry
         ; usage_missing_entries =
             previous.usage_missing_entries
             +
             if usage_missing entry then 1 else 0
         })
    entries;
  Hashtbl.fold (fun _ value acc -> value :: acc) totals []
;;

let filtered_costs ~agent ~task_id ~period =
  let* entries, invalid_rows = read_costs () in
  Ok
    ( entries
      |> filter_by_period period
      |> filter_by_agent agent
      |> filter_by_task task_id
    , invalid_rows )
;;

let print_report ~agent ~task_id ~period =
  let* filtered, invalid_rows = filtered_costs ~agent ~task_id ~period in
  let period_name = period_label period in
  if filtered = []
  then (
    printf "📊 No cost data for period: %s\n" period_name;
    Ok ())
  else (
    let total_tokens =
      List.fold_left (fun acc entry -> acc + known_tokens entry) 0 filtered
    in
    let total_cost =
      List.fold_left (fun acc entry -> acc +. known_cost entry) 0.0 filtered
    in
    let usage_missing_entries =
      List.fold_left
        (fun acc entry -> acc + if usage_missing entry then 1 else 0)
        0
        filtered
    in
    let by_agent = aggregate_by_agent filtered in
    printf "\n";
    printf "╔══════════════════════════════════════════════╗\n";
    printf "║  💰 MASC Cost Report (%s)              \n" period_name;
    printf "╠══════════════════════════════════════════════╣\n";
    printf "║  Period: %s                              \n" period_name;
    printf "║  Entries: %d                              \n" (List.length filtered);
    printf "║  Usage-missing entries: %d                 \n" usage_missing_entries;
    printf "║  Invalid rows skipped: %d                  \n" invalid_rows;
    printf "╠══════════════════════════════════════════════╣\n";
    printf "║  📊 By Agent:                              \n";
    by_agent
    |> List.sort (fun left right -> Float.compare right.cost_usd left.cost_usd)
    |> List.iter (fun total ->
      let pct =
        if total_cost > 0.0 then total.cost_usd /. total_cost *. 100.0 else 0.0
      in
      printf
        "║    %-10s %8d known tokens  $%7.2f (%4.1f%%), missing=%d\n"
        total.agent
        total.tokens
        total.cost_usd
        pct
        total.usage_missing_entries);
    printf "╠══════════════════════════════════════════════╣\n";
    printf "║  📈 KNOWN TOTAL: %d tokens, $%.2f            \n" total_tokens total_cost;
    printf "╚══════════════════════════════════════════════╝\n";
    Ok ())
;;

let agent_total_to_json total =
  `Assoc
    [ "agent", `String total.agent
    ; "tokens_known", `Int total.tokens
    ; "cost_usd_known", `Float total.cost_usd
    ; "model", `String total.model
    ; "usage_missing_entries", `Int total.usage_missing_entries
    ]
;;

let print_json_report ~agent ~task_id ~period =
  let* filtered, invalid_rows = filtered_costs ~agent ~task_id ~period in
  let by_agent = aggregate_by_agent filtered in
  let total_tokens =
    List.fold_left (fun acc entry -> acc + known_tokens entry) 0 filtered
  in
  let total_cost =
    List.fold_left (fun acc entry -> acc +. known_cost entry) 0.0 filtered
  in
  let usage_missing_entries =
    List.fold_left
      (fun acc entry -> acc + if usage_missing entry then 1 else 0)
      0
      filtered
  in
  `Assoc
    [ "period", `String (period_label period)
    ; "total_entries", `Int (List.length filtered)
    ; "total_tokens_known", `Int total_tokens
    ; "total_cost_usd_known", `Float total_cost
    ; "usage_missing_entries", `Int usage_missing_entries
    ; "invalid_rows_skipped", `Int invalid_rows
    ; "by_agent", `List (List.map agent_total_to_json by_agent)
    ]
  |> Yojson.Safe.to_string
  |> print_endline;
  Ok ()
;;

type action =
  | Log
  | Report

let fatal message =
  eprintf "Error: %s\n" message;
  exit 1
;;

let run () =
  let action = ref Report in
  let agent = ref "" in
  let task_id = ref "" in
  let model = ref "" in
  let input_tokens = ref 0 in
  let output_tokens = ref 0 in
  let cost_usd = ref 0.0 in
  let period = ref "daily" in
  let json_output = ref false in
  let specs =
    [ "--log", Arg.Unit (fun () -> action := Log), "Log a cost entry"
    ; "--report", Arg.Unit (fun () -> action := Report), "Show cost report"
    ; "--agent", Arg.Set_string agent, "Agent name"
    ; "--task", Arg.Set_string task_id, "Task ID"
    ; "--model", Arg.Set_string model, "Model name"
    ; "--input-tokens", Arg.Set_int input_tokens, "Input tokens"
    ; "--output-tokens", Arg.Set_int output_tokens, "Output tokens"
    ; "--tokens", Arg.Int (fun value -> input_tokens := value), "Input tokens (shorthand)"
    ; "--cost", Arg.Set_float cost_usd, "Cost in USD"
    ; "--period", Arg.Set_string period, "Report period: hourly|daily|weekly|monthly|all"
    ; "--json", Arg.Set json_output, "Output as JSON"
    ]
  in
  Arg.parse specs (fun _ -> ()) "masc-cost: Track multi-agent costs\n";
  match !action with
  | Log ->
    (match
       validate_log_input
         ~agent:!agent
         ~model:!model
         ~input_tokens:!input_tokens
         ~output_tokens:!output_tokens
         ~cost_usd:!cost_usd
     with
     | Error message -> fatal message
     | Ok () ->
       let task_id =
         match nonblank !task_id with
         | Some value -> Some value
         | None -> None
       in
       log_cost
         ~agent:(String.trim !agent)
         ~task_id
         ~model:(String.trim !model)
         ~input_tokens:!input_tokens
         ~output_tokens:!output_tokens
         ~cost_usd:!cost_usd)
  | Report ->
    (match period_of_string !period with
     | Error message -> fatal message
     | Ok period ->
       let result =
         if !json_output
         then print_json_report ~agent:!agent ~task_id:!task_id ~period
         else print_report ~agent:!agent ~task_id:!task_id ~period
       in
       (match result with
        | Ok () -> ()
        | Error message -> fatal message))
;;

let () =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    run ())
;;
