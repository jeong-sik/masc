(** Native MASC chain run log (JSONL) - Pure Eio Version

    This is designed for lightweight observability and data collection.
    It intentionally avoids logging prompts/responses; only lengths + metadata.

    Pure Eio: Uses Eio.Mutex and Eio.Path for async-safe file operations.
*)

open Types

let enabled () =
  match Sys.getenv_opt "MASC_CHAIN_RUN_LOG" with
  | Some "0" | Some "false" | Some "no" -> false
  | _ -> true

let stream_enabled () =
  match Sys.getenv_opt "MASC_CHAIN_RUN_LOG_STREAM" with
  | Some "1" | Some "true" | Some "yes" | Some "on" -> true
  | _ -> false

let default_log_path () =
  let home =
    match Sys.getenv_opt "HOME" with
    | Some path when String.trim path <> "" -> path
    | _ -> "/tmp"
  in
  Filename.concat home "logs/masc_chain_runs.jsonl"

let ensure_dir path =
  let rec ensure current =
    if not (Sys.file_exists current) then (
      ensure (Filename.dirname current);
      try Unix.mkdir current 0o755 with Unix.Unix_error _ -> ())
  in
  ensure path

let read_lines_tail ~max_bytes:_ ~max_lines path =
  let lines = ref [] in
  let ic = open_in path in
  Common.protect ~module_name:"run_log_eio" ~finally_label:"close_in"
    ~finally:(fun () -> close_in_noerr ic) (fun () ->
      (try
         while true do
           lines := input_line ic :: !lines
         done
       with End_of_file -> ());
      let rec take n xs =
        if n <= 0 then []
        else
          match xs with
          | [] -> []
          | hd :: tl -> hd :: take (n - 1) tl
      in
      List.rev !lines |> take max_lines)

let log_path () =
  match Sys.getenv_opt "MASC_CHAIN_RUN_LOG_PATH" with
  | Some p when String.length p > 0 -> p
  | _ -> default_log_path ()

(** Write mutex - created lazily per-domain *)
let write_mutex = Eio.Mutex.create ()

let ensure_log_dir () =
  let path = log_path () in
  ensure_dir (Filename.dirname path);
  path

let append_jsonl_unlocked ~fs json =
  let path = ensure_log_dir () in
  let line = Yojson.Safe.to_string json ^ "\n" in
  let file_path = Eio.Path.(fs / path) in
  (* Open with O_APPEND for atomic appends *)
  Eio.Path.with_open_out
    ~append:true
    ~create:(`If_missing 0o644)
    file_path
    (fun flow -> Eio.Flow.copy_string line flow)

let append_jsonl_sys json =
  let path = ensure_log_dir () in
  let line = Yojson.Safe.to_string json ^ "\n" in
  Out_channel.with_open_gen [Open_creat; Open_append; Open_wronly] 0o644 path
    (fun oc ->
      output_string oc line
    )

let assoc_of_kv (kvs : (string * string) list) =
  `Assoc (List.map (fun (k, v) -> (k, `String v)) kvs)

let assoc_of_json (kvs : (string * Yojson.Safe.t) list) =
  `Assoc kvs

let seq_counter = ref 0

let build_fields ?run_id ?chain_id ?node_id ?node_type ?attempt ?duration_ms ?success
    ?model ?tool ?streamed ?prompt_chars ?response_chars ?error_class ?error
    ?(extra = []) ?(extra_json = []) ~event ~seq () =
  let base = [
    ("ts", `Int (int_of_float (Time_compat.now ())));
    ("iso", `String (now_iso ()));
    ("event", `String event);
    ("seq", `Int seq);
  ] in
  let add_opt name = function
    | None -> fun acc -> acc
    | Some v -> fun acc -> (name, v) :: acc
  in
  let fields = base in
  let fields = add_opt "run_id" (Option.map (fun s -> `String s) run_id) fields in
  let fields = add_opt "chain_id" (Option.map (fun s -> `String s) chain_id) fields in
  let fields = add_opt "node_id" (Option.map (fun s -> `String s) node_id) fields in
  let fields = add_opt "node_type" (Option.map (fun s -> `String s) node_type) fields in
  let fields = add_opt "attempt" (Option.map (fun i -> `Int i) attempt) fields in
  let fields = add_opt "duration_ms" (Option.map (fun i -> `Int i) duration_ms) fields in
  let fields = add_opt "success" (Option.map (fun b -> `Bool b) success) fields in
  let fields = add_opt "model" (Option.map (fun s -> `String s) model) fields in
  let fields = add_opt "tool" (Option.map (fun s -> `String s) tool) fields in
  let fields = add_opt "streamed" (Option.map (fun b -> `Bool b) streamed) fields in
  let fields = add_opt "prompt_chars" (Option.map (fun i -> `Int i) prompt_chars) fields in
  let fields = add_opt "response_chars" (Option.map (fun i -> `Int i) response_chars) fields in
  let fields = add_opt "error_class" (Option.map (fun s -> `String s) error_class) fields in
  let fields = add_opt "error" (Option.map (fun s -> `String s) error) fields in
  let extra_fields = match (extra, extra_json) with
    | [], [] -> []
    | _ -> [
        ("extra", `Assoc ((match assoc_of_kv extra with `Assoc l -> l | _ -> []) @
                            (match assoc_of_json extra_json with `Assoc l -> l | _ -> [])))
      ]
  in
  `Assoc (fields @ extra_fields)

(** Record an event to the run log *)
let record_event
    ?fs
    ?run_id
    ?chain_id
    ?node_id
    ?node_type
    ?attempt
    ?duration_ms
    ?success
    ?model
    ?tool
    ?streamed
    ?prompt_chars
    ?response_chars
    ?error_class
    ?error
    ?(extra = [])
    ?(extra_json = [])
    ~event
    () =
  if not (enabled ()) then ()
  else
    (try
       Eio.Mutex.use_rw ~protect:true write_mutex (fun () ->
         incr seq_counter;
         let seq = !seq_counter in
         let json = build_fields
           ?run_id ?chain_id ?node_id ?node_type ?attempt ?duration_ms ?success
           ?model ?tool ?streamed ?prompt_chars ?response_chars ?error_class ?error
           ~extra ~extra_json ~event ~seq () in
         match fs with
         | Some f -> append_jsonl_unlocked ~fs:f json
         | None -> append_jsonl_sys json;
         if stream_enabled () then
           (try Sse.broadcast json with exn ->
             Log.Misc.error "SSE broadcast failed: %s" (Printexc.to_string exn)))
     with exn ->
       Log.Misc.error "Write failed: %s" (Printexc.to_string exn))

(** Record a tool execution to the run log *)
let record ~fs ~(tool : string) ~(streamed : bool) ~(prompt_chars : int) ~(duration_ms : int)
    (result : tool_result) =
  record_event
    ~fs
    ~event:"tool_call"
    ~tool
    ~streamed
    ~prompt_chars
    ~response_chars:(String.length result.message)
    ~duration_ms
    ~success:result.success
    ()

(** Read all events from the log file (Pure OCaml - no Eio needed) *)
let read_events () =
  let path = log_path () in
  if not (Sys.file_exists path) then []
  else
    let max_bytes = Safe_parse.env_int ~var:"MASC_CHAIN_RUN_LOG_MAX_BYTES" ~default:(10 * 1024 * 1024) in
    let max_lines = Safe_parse.env_int ~var:"MASC_CHAIN_RUN_LOG_MAX_LINES" ~default:100_000 in
    read_lines_tail ~max_bytes ~max_lines path
    |> List.filter_map (fun line ->
      let line = String.trim line in
      if line = "" then None
      else
        try Some (Yojson.Safe.from_string line)
        with Yojson.Json_error _ -> None)

let int_field json key ~default =
  Safe_parse.json_int ~context:"run_log" ~default json key

let string_field json key ~default =
  Safe_parse.json_string ~context:"run_log" ~default json key

let take_last n lst =
  if n <= 0 then []
  else
    let len = List.length lst in
    let drop = max 0 (len - n) in
    let rec drop_n i xs =
      if i <= 0 then xs
      else match xs with [] -> [] | _ :: tl -> drop_n (i - 1) tl
    in
    drop_n drop lst

(** Read recent events since a timestamp *)
let read_recent ~since_ts ~limit =
  let events =
    read_events ()
    |> List.filter (fun ev -> int_field ev "ts" ~default:0 >= since_ts)
  in
  take_last limit events

(** Compute statistics over events in a time range *)
let stats ~since_ts ~until_ts =
  let events =
    read_events ()
    |> List.filter (fun ev ->
      let ts = int_field ev "ts" ~default:0 in
      ts >= since_ts && (until_ts = 0 || ts <= until_ts))
  in
  let total = List.length events in
  let success =
    List.fold_left
      (fun acc ev -> if int_field ev "returncode" ~default:(-1) = 0 then acc + 1 else acc)
      0
      events
  in
  let durations =
    events |> List.map (fun ev -> int_field ev "duration_ms" ~default:0)
  in
  let duration_sum = List.fold_left ( + ) 0 durations in
  let duration_avg = if total = 0 then 0 else duration_sum / total in

  let by_tool = Hashtbl.create 16 in
  List.iter (fun ev ->
    let tool = string_field ev "tool" ~default:"unknown" in
    let cur = match Hashtbl.find_opt by_tool tool with Some n -> n | None -> 0 in
    Hashtbl.replace by_tool tool (cur + 1)
  ) events;
  let by_tool_json =
    Hashtbl.fold (fun tool count acc -> (tool, `Int count) :: acc) by_tool []
    |> List.sort (fun (a, _) (b, _) -> compare a b)
    |> fun fields -> `Assoc fields
  in

  `Assoc [
    ("since_ts", `Int since_ts);
    ("until_ts", `Int until_ts);
    ("total", `Int total);
    ("success", `Int success);
    ("failure", `Int (total - success));
    ("avg_duration_ms", `Int duration_avg);
    ("by_tool", by_tool_json);
  ]
