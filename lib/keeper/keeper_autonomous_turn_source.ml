(* Dashboard read model for autonomous keeper turns — see the .mli for why
   these turns are absent from the keeper chat store and must stay absent. *)

type block =
  | Thinking of string
  | Text of string
  | Tool_use of {
      name : string;
      input : Yojson.Safe.t option;
    }

type turn = {
  turn_id : string;
  started_at : float;
  finished_at : float option;
  model : string option;
  stop_reason : string option;
  blocks : block list;
  final_text : string option;
}

let default_limit = 200

(* Newest [limit] trace files of [dir], chronological. The writer stamps a
   zero-padded millisecond prefix on each file name, so lexicographic order
   is chronological — the same ordering
   [Keeper_types_support.prune_keeper_raw_trace_turn_files] deletes by. *)
let recent_trace_files ~dir ~limit =
  let entries =
    try Sys.readdir dir with
    | Sys_error _ -> [||]
  in
  let files =
    entries
    |> Array.to_list
    |> List.filter (fun entry ->
      Filename.check_suffix entry Keeper_types_support.raw_trace_file_extension)
    |> List.sort String.compare
  in
  let excess = List.length files - limit in
  if excess <= 0 then files else List.filteri (fun index _ -> index >= excess) files
;;

(* Decoding an OAS assistant block, not classifying keeper content: OAS
   types [block_kind] as a wire string, so the reader matches the labels
   that format defines and reports anything else instead of guessing. *)
type block_decode =
  | Rendered of block
  | Rendered_by_execution_record
  | Undecodable

let assistant_block_field ~field json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt field fields with
     | Some (`String value) -> Some value
     | Some _ | None -> None)
  | _ -> None
;;

let decode_assistant_block (record : Agent_sdk.Raw_trace.record) =
  match record.block_kind, record.assistant_block with
  | Some "thinking", Some json ->
    (match assistant_block_field ~field:"thinking" json with
     | Some content -> Rendered (Thinking content)
     | None -> Undecodable)
  | Some "text", Some json ->
    (match assistant_block_field ~field:"text" json with
     | Some content -> Rendered (Text content)
     | None -> Undecodable)
  | Some "tool_use", _ ->
    (* The dispatched call is rendered from [Tool_execution_started], which
       carries the name and input the runtime resolved. Rendering the
       assistant block too would show the call twice. *)
    Rendered_by_execution_record
  | Some _, _ | None, _ -> Undecodable
;;

type acc = {
  a_started : float option;
  a_finished : float option;
  a_model : string option;
  a_stop_reason : string option;
  a_final_text : string option;
  a_is_wake : bool;
  a_blocks_rev : block list;
  a_undecodable : int;
}

let empty_acc =
  {
    a_started = None;
    a_finished = None;
    a_model = None;
    a_stop_reason = None;
    a_final_text = None;
    a_is_wake = false;
    a_blocks_rev = [];
    a_undecodable = 0;
  }
;;

let fold_record acc (record : Agent_sdk.Raw_trace.record) =
  match record.record_type with
  | Agent_sdk.Raw_trace.Run_started ->
    {
      acc with
      a_started = (match acc.a_started with None -> Some record.ts | some -> some);
      a_model = (match acc.a_model with None -> record.model | some -> some);
      (* A prompt the trace did not record cannot be shown to be a wake, so
         the turn stays out rather than defaulting in. *)
      a_is_wake =
        acc.a_is_wake
        ||
        (match record.prompt with
         | Some prompt -> Keeper_unified_prompt.is_autonomous_wake_prompt prompt
         | None -> false);
    }
  | Agent_sdk.Raw_trace.Assistant_block ->
    (match decode_assistant_block record with
     | Rendered block -> { acc with a_blocks_rev = block :: acc.a_blocks_rev }
     | Rendered_by_execution_record -> acc
     | Undecodable -> { acc with a_undecodable = acc.a_undecodable + 1 })
  | Agent_sdk.Raw_trace.Tool_execution_started ->
    (match record.tool_name with
     | Some name ->
       {
         acc with
         a_blocks_rev = Tool_use { name; input = record.tool_input } :: acc.a_blocks_rev;
       }
     | None -> { acc with a_undecodable = acc.a_undecodable + 1 })
  | Agent_sdk.Raw_trace.Tool_execution_finished ->
    (* Results are the tool's output, not the keeper's turn; the transcript
       renders the call. *)
    acc
  | Agent_sdk.Raw_trace.Hook_invoked -> acc
  | Agent_sdk.Raw_trace.Run_finished ->
    {
      acc with
      a_finished = Some record.ts;
      a_stop_reason = record.stop_reason;
      a_final_text = record.final_text;
    }
;;

let turn_of_records ~keeper_name ~turn_id records =
  let ordered =
    List.stable_sort
      (fun (left : Agent_sdk.Raw_trace.record) (right : Agent_sdk.Raw_trace.record) ->
        Int.compare left.seq right.seq)
      records
  in
  let acc = List.fold_left fold_record empty_acc ordered in
  if acc.a_undecodable > 0
  then
    Log.Keeper.warn ~keeper_name
      "autonomous turn source: %d record(s) in %s carried no renderable block"
      acc.a_undecodable turn_id;
  match acc.a_is_wake, acc.a_started with
  | false, _ ->
    (* A direct [masc_keeper_msg] turn: already in the chat store. *)
    None
  | true, None ->
    Log.Keeper.warn ~keeper_name
      "autonomous turn source: %s recorded no run_started timestamp; skipped" turn_id;
    None
  | true, Some started_at ->
    Some
      {
        turn_id;
        started_at;
        finished_at = acc.a_finished;
        model = acc.a_model;
        stop_reason = acc.a_stop_reason;
        blocks = List.rev acc.a_blocks_rev;
        final_text = acc.a_final_text;
      }
;;

let records_of_trace_file ~keeper_name ~path =
  match Agent_sdk.Raw_trace_query.read_runs ~path () with
  | Error err ->
    Log.Keeper.warn ~keeper_name "autonomous turn source: cannot list runs in %s: %s"
      path (Agent_sdk.Error.to_string err);
    []
  | Ok run_refs ->
    List.concat_map
      (fun run_ref ->
        match Agent_sdk.Raw_trace_query.read_run run_ref with
        | Ok records -> records
        | Error err ->
          Log.Keeper.warn ~keeper_name "autonomous turn source: cannot read run in %s: %s"
            path (Agent_sdk.Error.to_string err);
          [])
      run_refs
;;

let load_recent ~config ~keeper_name ?(limit = default_limit) ?since () =
  let dir = Keeper_types_support.keeper_raw_trace_dir config keeper_name in
  recent_trace_files ~dir ~limit
  |> List.filter_map (fun entry ->
    let path = Filename.concat dir entry in
    match records_of_trace_file ~keeper_name ~path with
    | [] -> None
    | records -> turn_of_records ~keeper_name ~turn_id:entry records)
  |> List.filter (fun turn ->
    match since with
    | Some cutoff -> Float.compare turn.started_at cutoff > 0
    | None -> true)
;;
