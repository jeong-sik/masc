(** Keeper_tool_call_log — Full I/O logging for keeper tool calls.

    Persists complete tool call records (input arguments + output text)
    to [.masc/tool_calls/YYYY-MM/DD.jsonl] via {!Dated_jsonl}.

    Unlike {!Tool_usage_log} (metadata only) and {!Tool_metrics_persist}
    (aggregated counts), this module stores the actual I/O for debugging
    and dashboard inspection.

    Output is truncated to {!max_output_len} bytes to prevent disk
    explosion from large tool results (e.g. full file reads).

    @since 2.249.0 — Keeper observability *)

let max_output_len = 4000

(** Pre-truncation info, keyed by keeper name.
    Set by the tool handler wrapper (keeper_tools_oas), consumed by the
    OAS on_tool_result hook (keeper_hooks_oas).  Per-keeper isolation
    prevents cross-keeper corruption when multiple keepers call tools
    concurrently. Within a single keeper's Agent.run, tool calls are
    sequential so set→consume ordering is guaranteed. *)
let pending_truncation : (string, int * int option) Hashtbl.t = Hashtbl.create 8

type turn_context = {
  lane: string option;
  tool_choice: string option;
  thinking_enabled: bool option;
  thinking_budget: int option;
}

let empty_turn_context = {
  lane = None;
  tool_choice = None;
  thinking_enabled = None;
  thinking_budget = None;
}

let pending_turn_context : (string, turn_context) Hashtbl.t = Hashtbl.create 8

let set_truncation_info ~keeper_name ~original_bytes ?truncated_to () =
  Hashtbl.replace pending_truncation keeper_name (original_bytes, truncated_to)

let consume_truncation_info ~keeper_name () =
  match Hashtbl.find_opt pending_truncation keeper_name with
  | Some info -> Hashtbl.remove pending_truncation keeper_name; info
  | None -> (0, None)

let set_turn_context ~keeper_name ?lane ?tool_choice ?thinking_enabled
    ?thinking_budget () =
  Hashtbl.replace pending_turn_context keeper_name
    { lane; tool_choice; thinking_enabled; thinking_budget }

let get_turn_context ~keeper_name () =
  let ctx =
    match Hashtbl.find_opt pending_turn_context keeper_name with
    | Some ctx -> ctx
    | None -> empty_turn_context
  in
  (ctx.lane, ctx.tool_choice, ctx.thinking_enabled, ctx.thinking_budget)

let store_ref : Dated_jsonl.t option ref = ref None

let init ~base_path =
  let dir = Filename.concat base_path ".masc/tool_calls" in
  (try
     let store = Dated_jsonl.create ~base_dir:dir () in
     store_ref := Some store
   with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
     Log.Misc.warn "keeper_tool_call_log: init failed: %s"
       (Printexc.to_string exn))

let reset_for_testing () =
  store_ref := None;
  Hashtbl.reset pending_truncation;
  Hashtbl.reset pending_turn_context

let suffix = "...(truncated)"
let suffix_len = String.length suffix

let input_to_json (input : Yojson.Safe.t) : Yojson.Safe.t =
  let s = Yojson.Safe.to_string input in
  if String.length s > max_output_len then
    `String (String.sub s 0 (max_output_len - suffix_len) ^ suffix)
  else input

let log_call ~keeper_name ~tool_name ~(input : Yojson.Safe.t)
    ~(output_text : string) ~(success : bool) ~(duration_ms : float)
    ?(model : string = "") ?lane ?tool_choice ?thinking_enabled
    ?thinking_budget ?result_bytes ?truncated_to () =
  if Observability_redact.is_denied_tool ~tool_name then ()
  else
    match !store_ref with
    | None -> ()
    | Some store ->
      let ctx_lane, ctx_tool_choice, ctx_thinking_enabled, ctx_thinking_budget =
        get_turn_context ~keeper_name ()
      in
      let lane = match lane with Some _ -> lane | None -> ctx_lane in
      let tool_choice =
        match tool_choice with Some _ -> tool_choice | None -> ctx_tool_choice
      in
      let thinking_enabled =
        match thinking_enabled with
        | Some _ -> thinking_enabled
        | None -> ctx_thinking_enabled
      in
      let thinking_budget =
        match thinking_budget with
        | Some _ -> thinking_budget
        | None -> ctx_thinking_budget
      in
      let model_field =
        if model = "" then [] else [("model", `String model)]
      in
      let result_bytes_field = match result_bytes with
        | Some n -> [("result_bytes", `Int n)]
        | None -> []
      in
      let truncated_to_field = match truncated_to with
        | Some n -> [("truncated_to", `Int n)]
        | None -> []
      in
      let lane_field = match lane with
        | Some value -> [("lane", `String value)]
        | None -> []
      in
      let tool_choice_field = match tool_choice with
        | Some value -> [("tool_choice", `String value)]
        | None -> []
      in
      let thinking_enabled_field = match thinking_enabled with
        | Some value -> [("thinking_enabled", `Bool value)]
        | None -> []
      in
      let thinking_budget_field = match thinking_budget with
        | Some value -> [("thinking_budget", `Int value)]
        | None -> []
      in
      let safe_input = input_to_json (Observability_redact.redact_json_value input) in
      let safe_output = Observability_redact.redact_preview ~max_len:max_output_len output_text in
      let json =
        `Assoc
          ([ ("ts", `Float (Time_compat.now ()))
          ; ("keeper", `String keeper_name)
          ; ("tool", `String tool_name)
          ; ("input", safe_input)
          ; ("output", `String safe_output)
          ; ("success", `Bool success)
          ; ("duration_ms", `Float duration_ms)
          ] @ model_field @ lane_field @ tool_choice_field
            @ thinking_enabled_field @ thinking_budget_field
            @ result_bytes_field @ truncated_to_field)
      in
      (try Dated_jsonl.append store json
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Log.Misc.warn "keeper_tool_call_log: append failed for %s/%s: %s"
           keeper_name tool_name (Printexc.to_string exn))

let read_recent ?keeper_name ?(n = 100) () : Yojson.Safe.t list =
  if n <= 0 then []
  else
  match !store_ref with
  | None -> []
  | Some store ->
    (* Single-pass: read from store, filter, and collect last n in one traversal *)
    let raw = Dated_jsonl.read_recent store (n * 5) in
    let matches name json =
      match Safe_ops.json_string_opt "keeper" json with
      | Some k -> String.equal k name
      | None -> false
    in
    let buf = Array.make n (`Null : Yojson.Safe.t) in
    let pos = ref 0 in
    let total = ref 0 in
    List.iter (fun json ->
      let dominated = match keeper_name with
        | None -> true
        | Some name -> matches name json
      in
      if dominated then begin
        buf.(!pos mod n) <- json;
        incr pos;
        incr total
      end
    ) raw;
    let count = min !total n in
    if count = 0 then []
    else
      let start = if !total <= n then 0 else !pos mod n in
      List.init count (fun i -> buf.((start + i) mod n))
