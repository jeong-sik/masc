(** Keeper_tool_call_log — Full I/O logging for keeper tool calls.

    Persists complete tool call records (input arguments + output text)
    to [.masc/tool_calls/YYYY-MM/DD.jsonl] via {!Dated_jsonl}.

    Unlike {!Tool_usage_log} (metadata only) and {!Tool_metrics_persist}
    (aggregated counts), this module stores the actual I/O for debugging
    and dashboard inspection.

    Output is truncated to {!max_output_len} bytes to prevent disk
    explosion from large tool results (e.g. full file reads).

    @since 2.250.0 — Keeper observability *)

let max_output_len = 4000

let store_ref : Dated_jsonl.t option ref = ref None

let init ~base_path =
  let dir = Filename.concat base_path ".masc/tool_calls" in
  (try
     let store = Dated_jsonl.create ~base_dir:dir () in
     store_ref := Some store
   with exn ->
     Log.Misc.warn "keeper_tool_call_log: init failed: %s"
       (Printexc.to_string exn))

let truncate_output s =
  if String.length s <= max_output_len then s
  else String.sub s 0 max_output_len ^ "...(truncated)"

let input_to_json (input : Yojson.Safe.t) : Yojson.Safe.t =
  let s = Yojson.Safe.to_string input in
  if String.length s > max_output_len then
    `String (String.sub s 0 max_output_len ^ "...(truncated)")
  else input

let log_call ~keeper_name ~tool_name ~(input : Yojson.Safe.t)
    ~(output_text : string) ~(success : bool) ~(duration_ms : float) =
  match !store_ref with
  | None -> ()
  | Some store ->
    let json =
      `Assoc
        [ ("ts", `Float (Time_compat.now ()))
        ; ("keeper", `String keeper_name)
        ; ("tool", `String tool_name)
        ; ("input", input_to_json input)
        ; ("output", `String (truncate_output output_text))
        ; ("success", `Bool success)
        ; ("duration_ms", `Float duration_ms)
        ]
    in
    (try Dated_jsonl.append store json
     with exn ->
       Log.Misc.warn "keeper_tool_call_log: append failed for %s/%s: %s"
         keeper_name tool_name (Printexc.to_string exn))

let read_recent ?(keeper_name : string option) ?(n = 100) () : Yojson.Safe.t list =
  match !store_ref with
  | None -> []
  | Some store ->
    let entries = Dated_jsonl.read_recent store (n * 5) in
    let filtered = match keeper_name with
      | None -> entries
      | Some name ->
        List.filter (fun json ->
          match Safe_ops.json_string_opt "keeper" json with
          | Some k -> String.equal k name
          | None -> false
        ) entries
    in
    let len = List.length filtered in
    if len <= n then filtered
    else
      (* take last n entries *)
      let to_drop = len - n in
      let rec drop lst count =
        if count <= 0 then lst
        else match lst with [] -> [] | _ :: tl -> drop tl (count - 1)
      in
      drop filtered to_drop
