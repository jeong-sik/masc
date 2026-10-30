module B = Keeper_turn_boundaries
module P = Keeper_librarian_progress
module O = Keeper_librarian_official_progress
module R = Keeper_librarian_range
module F = Keeper_turn_fragments
module C = Keeper_checkpoint_store
module M = Keeper_memory_os_current
module I = Keeper_librarian_input_capture
module S = Keeper_librarian_input_sources
module E = Keeper_external_read_cursor
module W = Keeper_memory_os_types
let ( let* ) = Result.bind
let ( let+ ) value fn = Result.map fn value

type error = Checkpoint_source of C.Saved_history.ref_error | Inconsistent_source of string
let error_to_string = function
  | Checkpoint_source error -> C.saved_history_ref_error_to_string error
  | Inconsistent_source detail -> detail
let refuse detail = Error (Inconsistent_source detail)
let check condition detail = if condition then Ok () else refuse detail
let fields expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare expected -> Ok fields
  | _ -> refuse "Durable capture has unknown, repeated or missing fields"
let field key values = List.assoc key values
let text = function `String value -> Ok value | _ -> refuse "Durable capture expects text"
let int = function `Int value -> Ok value | _ -> refuse "Durable capture expects an integer"
let number = function
  | `Float value when Float.is_finite value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> refuse "Durable capture expects a finite number"
let list decode = function
  | `List values -> List.fold_right (fun value rest -> let* value=decode value in let+ rest=rest in value::rest) values (Ok [])
  | _ -> refuse "Durable capture expects an array"
let option decode = function `Null -> Ok None | value -> let+ value=decode value in Some value
let optional encode = function None -> `Null | Some value -> encode value
let json_text value = `String (Yojson.Safe.to_string value)
let decode_text decode value =
  let* raw=text value in
  match Yojson.Safe.from_string raw with
  | json -> decode json
  | exception Yojson.Json_error detail -> refuse detail
let string_error result = Result.map_error (fun detail -> Inconsistent_source detail) result
let wire result = Result.map_error (fun error -> Inconsistent_source (W.wire_error_to_string error)) result
let pair_json left right = `List [left;right]

type boundary_lines = (int * (B.record,B.read_error) result) list
type checkpoint = {
  trace_id : Keeper_id.Trace_id.t;
  messages : Agent_core.Types.message list;
  range : R.range;
  boundary_lines_seen : int;
  end_boundary_line : int;
}
let checkpoint ~snapshot ~range ~boundary_lines_seen ~end_boundary_line =
  {trace_id=(C.exact_snapshot_reference snapshot).Keeper_checkpoint_ref.trace_id;
   messages=C.exact_snapshot_messages snapshot;range;boundary_lines_seen;end_boundary_line}
type official_trace = {trace_id:string;main:(int * (F.line,F.read_error) result) list;
  internal:(int * (F.line,F.read_error) result) list}
type official = {selected:R.official_line list;traces:official_trace list}
type source = Checkpoint_only of checkpoint | Official_only of official | Mixed of checkpoint * official
module Held = struct
  type span = {count:int;digest:string}
  type checkpoint = {trace_id:Keeper_id.Trace_id.t;range:R.range;boundary_lines_seen:int;
    end_boundary_line:int;messages:span}
  type trace = {id:string;main:span;internal:span}
  type official = {selected:R.official_line list;traces:trace list}
  type source = Checkpoint_only of checkpoint | Official_only of official | Mixed of checkpoint * official
end
type positions = {current:P.t option;selection:P.t option;counterpart:P.t option;official:O.t option}
type t = {root:string;read_extent:R.extent;boundary_span:Held.span;original_positions:positions;
  held_source:Held.source;original_counterparts:S.counterpart_snapshot;before:E.observation;prepared:E.observation;
  revision:int option;atom_receipt:M.durable_range_id option;official_receipt:M.official_range_id option;
  original_input:Keeper_librarian.input}
let input original = original.original_input
let expected_revision original = original.revision
let range_id original = original.atom_receipt
let official_range_id original = original.official_receipt
let positions original = original.original_positions
let source original = original.held_source
let counterparts original = original.original_counterparts
let external_before original = original.before
let external_prepared original = original.prepared
let runtime_keepers_dir original = original.root
let extent original = original.read_extent

let reason_json reason =
  let token tag = `List [`String tag] and value tag value = `List [`String tag;`String value] in
  match reason with
  | W.Expected_object -> token "object" | Expected_array -> token "array"
  | Expected_string -> token "string" | Expected_int -> token "int" | Expected_number -> token "number"
  | Duplicate_field name -> value "duplicate_field" name
  | Field_set_mismatch {missing;unexpected} -> `List [`String "field_set";
      `List (List.map (fun value -> `String value) missing);`List (List.map (fun value -> `String value) unexpected)]
  | Unknown_token name -> value "unknown_token" name | Blank_string -> token "blank"
  | Not_a_memory_id name -> value "memory_id" name | Not_a_board_post_id name -> value "post_id" name
  | Not_a_board_comment_id name -> value "comment_id" name | Not_a_turn_ref name -> value "turn_ref" name
  | Invalid_task_context name -> value "task_context" name | Not_finite -> token "not_finite"
  | Negative -> token "negative" | Not_positive -> token "not_positive" | Empty_list -> token "empty"
  | Not_ascending -> token "not_ascending" | Duplicate_entry name -> value "duplicate_entry" name
let wire_error_json (error:W.wire_error) = `Assoc ["path",`List (List.map (function
  | W.Wire_field name -> `List [`String "field";`String name]
  | Wire_index index -> `List [`String "index";`Int index]) error.path);"reason",reason_json error.reason]
let boundary_error_json = function
  | B.Not_json detail -> `List [`String "not_json";`String detail]
  | Malformed error -> `List [`String "malformed";wire_error_json error]
  | Incomplete_line -> `List [`String "incomplete"]
let result_json ok error = function Ok value -> `List [`String "ok";ok value] | Error value -> `List [`String "error";error value]
let boundary_line_json (line,value) = pair_json (`Int line) (result_json B.record_to_json boundary_error_json value)
let turn_of_json json = let* value=text json in
  match Ids.Turn_ref.of_string value with Some reference -> Ok reference | None -> refuse "Invalid captured turn reference"
let fragment_json = function
  | F.Message {turn_ref;recorded_at;source;message} -> `Assoc ["kind",`String "message";
      "turn_ref",Ids.Turn_ref.to_yojson turn_ref;"recorded_at",`Float recorded_at;
      "source",optional (fun value -> `String value) source;
      "message",I.message_json message]
  | F.Tool_observation {turn_ref;recorded_at;observation} -> `Assoc ["kind",`String "tool";
      "turn_ref",Ids.Turn_ref.to_yojson turn_ref;"recorded_at",`Float recorded_at;
      "tool_name",`String observation.tool_name;"outcome",`String (match observation.outcome with
        | Keeper_librarian.Succeeded -> "succeeded" | Failed -> "failed" | Unknown -> "unknown")]
let fragment_error_json = function
  | F.Not_json detail -> `List [`String "not_json";`String detail]
  | Malformed error -> `List [`String "malformed";wire_error_json error]
  | Message_rejected detail -> `List [`String "message_rejected";`String detail]
  | Incomplete_line -> `List [`String "incomplete"]
let fragment_line_json = function
  | F.Untagged -> `List [`String "untagged"]
  | Fragment fragment -> `List [`String "fragment";fragment_json fragment]
let fragment_row_json (line,value) = pair_json (`Int line) (result_json fragment_line_json fragment_error_json value)

(* One digest over every element a capture saw of a source, each element
   length-prefixed so that two lists cut at other places never share one.
   Checkpoint messages are taken in the form the checkpoint persists them:
   a live checkpoint read after a restart holds only that form. *)
let digest_of encode rows =
  Agent_core_sha256.to_hex (Agent_core_sha256.get (List.fold_left (fun context row ->
    let bytes=Yojson.Safe.to_string (encode row) in
    let length=Bytes.create 8 in
    Bytes.set_int64_be length 0 (Int64.of_int (String.length bytes));
    Agent_core_sha256.feed_string (Agent_core_sha256.feed_bytes context length) bytes)
    Agent_core_sha256.empty rows))
let span_of encode rows = {Held.count=List.length rows;digest=digest_of encode rows}
let held_prefix ~changed encode (span:Held.span) rows =
  if List.length rows<span.count then refuse changed
  else
    let prefix=List.take span.count rows in
    if String.equal (digest_of encode prefix) span.digest then Ok prefix else refuse changed
let span_json (span:Held.span) = `Assoc ["count",`Int span.count;"digest",`String span.digest]
let span_of_json json =
  let* f=fields ["count";"digest"] json in
  let* count=int (field "count" f) in
  let* digest=text (field "digest" f) in
  let+ ()=check (count>=0 && String_util.is_lowercase_sha256_hex digest) "Durable source span is invalid" in
  {Held.count;digest}

let range_json (range:R.range) = `Assoc ["history_start_boundary_line",`Int range.history_start_boundary_line;
  "start_atom",`Int range.start_atom;"end_atom",`Int range.end_atom;"last_atom_digest",`String range.last_atom_digest]
let range_of_json json =
  let* f=fields ["history_start_boundary_line";"start_atom";"end_atom";"last_atom_digest"] json in
  let* history_start_boundary_line=int (field "history_start_boundary_line" f) in
  let* start_atom=int (field "start_atom" f) in let* end_atom=int (field "end_atom" f) in
  let+ last_atom_digest=text (field "last_atom_digest" f) in {R.history_start_boundary_line;start_atom;end_atom;last_atom_digest}
let hold_checkpoint (checkpoint:checkpoint) = {Held.trace_id=checkpoint.trace_id;range=checkpoint.range;
  boundary_lines_seen=checkpoint.boundary_lines_seen;end_boundary_line=checkpoint.end_boundary_line;
  messages=span_of Agent_core.Checkpoint.message_to_json checkpoint.messages}
let hold_official (official:official) = {Held.selected=official.selected;
  traces=List.map (fun (trace:official_trace) -> {Held.id=trace.trace_id;
    main=span_of fragment_row_json trace.main;internal=span_of fragment_row_json trace.internal}) official.traces}
let hold = function
  | Checkpoint_only checkpoint -> Held.Checkpoint_only (hold_checkpoint checkpoint)
  | Official_only official -> Held.Official_only (hold_official official)
  | Mixed (checkpoint,official) -> Held.Mixed (hold_checkpoint checkpoint,hold_official official)
let checkpoint_json (source:Held.checkpoint) = `Assoc ["trace_id",`String (Keeper_id.Trace_id.to_string source.trace_id);
  "messages",span_json source.messages;"range",range_json source.range;
  "boundary_lines_seen",`Int source.boundary_lines_seen;"end_boundary_line",`Int source.end_boundary_line]
let checkpoint_of_json json =
  let* f=fields ["trace_id";"messages";"range";"boundary_lines_seen";"end_boundary_line"] json in
  let* trace=text (field "trace_id" f) in let* trace_id=string_error (Keeper_id.Trace_id.of_string trace) in
  let* messages=span_of_json (field "messages" f) in
  let* range=range_of_json (field "range" f) in
  let* boundary_lines_seen=int (field "boundary_lines_seen" f) in
  let+ end_boundary_line=int (field "end_boundary_line" f) in
  {Held.trace_id;messages;range;boundary_lines_seen;end_boundary_line}
let official_json (source:Held.official) = `Assoc ["selected",`List (List.map (fun (line:R.official_line) ->
  `Assoc ["line",`Int line.line;"turn_ref",Ids.Turn_ref.to_yojson line.turn_ref;"recorded_at",`Float line.recorded_at]) source.selected);
  "traces",`List (List.map (fun (trace:Held.trace) -> `Assoc ["trace_id",`String trace.id;
    "main",span_json trace.main;"internal",span_json trace.internal]) source.traces)]
let official_of_json json =
  let* f=fields ["selected";"traces"] json in
  let* selected=list (fun json -> let* f=fields ["line";"turn_ref";"recorded_at"] json in
    let* line=int (field "line" f) in let* turn_ref=turn_of_json (field "turn_ref" f) in
    let+ recorded_at=number (field "recorded_at" f) in {R.line;turn_ref;recorded_at}) (field "selected" f) in
  let+ traces=list (fun json -> let* f=fields ["trace_id";"main";"internal"] json in
    let* id=text (field "trace_id" f) in let* main=span_of_json (field "main" f) in
    let+ internal=span_of_json (field "internal" f) in {Held.id;main;internal}) (field "traces" f) in
  {Held.selected;traces}
let source_json = function
  | Held.Checkpoint_only checkpoint -> `List [`String "checkpoint";checkpoint_json checkpoint]
  | Official_only official -> `List [`String "official";official_json official]
  | Mixed (checkpoint,official) -> `List [`String "mixed";checkpoint_json checkpoint;official_json official]
let source_of_json = function
  | `List [`String "checkpoint";value] -> let+ value=checkpoint_of_json value in Held.Checkpoint_only value
  | `List [`String "official";value] -> let+ value=official_of_json value in Held.Official_only value
  | `List [`String "mixed";atom;official] -> let* atom=checkpoint_of_json atom in
    let+ official=official_of_json official in Held.Mixed (atom,official)
  | _ -> refuse "Unknown durable source kind"
let positions_json positions = `Assoc ["current",optional P.to_json positions.current;
  "selection",optional P.to_json positions.selection;"counterpart",optional P.to_json positions.counterpart;
  "official",optional O.to_json positions.official]
let positions_of_json json =
  let* f=fields ["current";"selection";"counterpart";"official"] json in
  let progress json = option (fun value -> wire (P.of_json value)) json in
  let* current=progress (field "current" f) in let* selection=progress (field "selection" f) in
  let* counterpart=progress (field "counterpart" f) in
  let+ official=option (fun value -> wire (O.of_json value)) (field "official" f) in
  {current;selection;counterpart;official}

module Tool_map = Map.Make (String)
module Line_map = Map.Make (Int)
module Historical = Keeper_librarian_task_context
let tool_observations messages =
  let calls_rev, results =
    List.fold_left
      (fun (calls_rev, results) (message : Agent_core.Types.message) ->
         List.fold_left
           (fun (calls_rev, results) (block : Agent_core.Types.content_block) ->
              match block with
              | Agent_core.Types.ToolUse { id; name; _ } -> ((id, name) :: calls_rev), results
              | Agent_core.Types.ToolResult { tool_use_id; outcome; _ } ->
                calls_rev, Tool_map.add tool_use_id outcome results
              | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
              | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
              | Agent_core.Types.Image _ | Agent_core.Types.Document _
              | Agent_core.Types.Audio _ -> calls_rev, results)
           (calls_rev, results)
           message.content)
      ([], Tool_map.empty)
      messages
  in
  List.rev_map
    (fun (call_id, name) ->
       let outcome =
         match Tool_map.find_opt call_id results with
         | None -> Keeper_librarian.Unknown
         | Some result ->
           if Agent_core.Types.tool_result_outcome_is_error result
           then Keeper_librarian.Failed
           else Keeper_librarian.Succeeded
       in
       ({ tool_name =
            Keeper_tool_descriptor_resolution.canonical_tool_name name
        ; outcome
        }
         : Keeper_librarian.tool_observation))
    calls_rev
;;

type projection = {messages:Agent_core.Types.message list;
  tool_observations:Keeper_librarian.tool_observation list;
  historical_task_contexts:Historical.t list}
type projection_step = Atom_cut of checkpoint * R.atom_cut | Official_cut of official * R.official_line
let project_source ~boundaries source =
  let atom,official=match source with Checkpoint_only atom -> Some atom,None
    | Official_only official -> None,Some official | Mixed (atom,official) -> Some atom,Some official in
  let* atom_steps=match atom with
    | None -> Ok []
    | Some atom ->
      let trace_id=Keeper_id.Trace_id.to_string atom.trace_id in
      let cuts=R.cut_lines ~trace_id ~lines:boundaries ~messages:atom.messages atom.range in
      let* cuts=match cuts with
        | _::_ -> Ok cuts
        | [] -> (match B.witness_line ~trace_id ~end_atom:atom.range.end_atom
            ~last_atom_digest:atom.range.last_atom_digest boundaries with
          | Some (cut_line,cut_recorded_at,cut_turn_ref) ->
            Ok [{R.cut_line;cut_end_atom=atom.range.end_atom;cut_recorded_at;cut_turn_ref}]
          | None -> refuse "Durable atom projection has no endpoint boundary") in
      Ok (List.map (fun cut -> Atom_cut (atom,cut)) cuts) in
  let official_steps=match official with None -> [] | Some official ->
    List.map (fun line -> Official_cut (official,line)) official.selected in
  let line = function Atom_cut (_,cut) -> cut.R.cut_line | Official_cut (_,cut) -> cut.R.line in
  let steps=List.sort (fun left right -> Int.compare (line left) (line right)) (atom_steps @ official_steps) in
  let records=List.fold_left (fun acc (line,value) -> match value with
    | Ok record -> Line_map.add line record acc | Error _ -> acc) Line_map.empty boundaries in
  let start=match atom with None -> 0 | Some atom -> atom.range.start_atom in
  let* _,_,_,messages,tools,contexts=List.fold_left (fun result step ->
    let* prev_end,count,tool_count,messages,tools,contexts=result in
    match step with
    | Atom_cut (atom,cut) ->
      let trace_id=Keeper_id.Trace_id.to_string atom.trace_id in
      let scopes=Historical.atom_spans ~trace_id
        ~digest_at:(Runtime_model_input_tail_window.atom_opening_digest atom.messages)
        ~start_atom:prev_end ~end_atom:cut.cut_end_atom ~boundary:(Line_map.find_opt cut.cut_line records) in
      let count,tool_count,messages,tools,contexts=List.fold_left
        (fun (count,tool_count,messages,tools,contexts) scope ->
          let slice=match scope.Historical.source with
            | Historical.Atom_span {start_atom;end_atom;_} -> R.slice atom.messages {atom.range with start_atom;end_atom}
            | Historical.Official_turn | Historical.Boundary_only -> [] in
          let after_message=count+List.length slice in
          let observations=tool_observations slice in
          let after_tool_observation=tool_count+List.length observations in
          let context={Historical.scope;first_message=count;after_message;
            first_tool_observation=tool_count;after_tool_observation} in
          after_message,after_tool_observation,List.rev_append slice messages,
            List.rev_append observations tools,context::contexts)
        (count,tool_count,messages,tools,contexts) scopes in
      Ok (cut.cut_end_atom,count,tool_count,messages,tools,contexts)
    | Official_cut (official,cut) ->
      (match List.find_opt (fun trace -> trace.trace_id=Ids.Turn_ref.trace_id cut.turn_ref) official.traces with
       | None -> refuse "Durable official projection has no original file capture"
       | Some trace ->
         let after_message,after_tools,messages,tools=List.fold_left
           (fun (count,tool_count,messages,tools) -> function
             | F.Message {message;_} -> count+1,tool_count,message::messages,tools
             | F.Tool_observation {observation;_} -> count,tool_count+1,messages,observation::tools)
           (count,tool_count,messages,tools) (F.of_turn cut.turn_ref (trace.main @ trace.internal)) in
         let attribution=match Line_map.find_opt cut.line records with
           | Some {B.event=B.Turn_ended {turn_ref;task_context;_};_} -> Historical.Observed {turn_ref;task_context}
           | Some {B.event=B.History_restarted _;_} | None -> Historical.Unattributed in
         let context={Historical.scope={source=Historical.Official_turn;attribution};
           first_message=count;after_message;first_tool_observation=tool_count;after_tool_observation=after_tools} in
         Ok (prev_end,after_message,after_tools,messages,tools,context::contexts)))
    (Ok (start,0,0,[],[],[])) steps in
  Ok {messages=List.rev messages;tool_observations=List.rev tools;historical_task_contexts=List.rev contexts}

let contiguous rows = List.mapi (fun index (line,_) -> line=index+1) rows |> List.for_all Fun.id
let source_parts = function
  | Checkpoint_only checkpoint -> Some checkpoint,None
  | Official_only official -> None,Some official
  | Mixed (checkpoint,official) -> Some checkpoint,Some official
let held_parts = function
  | Held.Checkpoint_only checkpoint -> Some checkpoint,None
  | Official_only official -> None,Some official
  | Mixed (checkpoint,official) -> Some checkpoint,Some official

(* A live checkpoint read after a restart holds the checkpoint form of its
   messages, without a ToolResult's [json]. Atom messages are compared in that
   form; official-turn messages come whole from their own files. *)
let same_read_messages ~contexts projected held =
  let persisted=Array.make (List.length held) false in
  List.iter (fun (context:Historical.t) -> match context.scope.source with
    | Historical.Atom_span _ ->
      for index=max 0 context.first_message to min (Array.length persisted) context.after_message-1 do
        persisted.(index)<-true done
    | Official_turn | Boundary_only -> ()) contexts;
  let rec same index = function
    | [],[] -> true
    | left::left_rest,right::right_rest ->
      (if persisted.(index) then Yojson.Safe.equal (Agent_core.Checkpoint.message_to_json left)
         (Agent_core.Checkpoint.message_to_json right) else left=right)
      && same (index+1) (left_rest,right_rest)
    | [],_::_ | _::_,[] -> false in
  same 0 (projected,held)

(* What the original says without its sources: the receipts, cursors and
   input agree with the ranges and sources it names. *)
let validate_record original =
  let input=original.original_input and positions=original.original_positions in
  let atom,official=held_parts original.held_source in
  let* ()=check (String.trim original.root<>"") "Durable receipt scope is blank" in
  let* ()=check (Option.fold ~none:true ~some:(fun revision -> revision>=0) original.revision
    && Option.is_some input.current=Option.is_some original.revision) "Durable Memory revision/input presence disagrees" in
  let* ()=check (input.counterpart_observations=S.counterpart_observations original.original_counterparts)
    "Durable input differs from its original counterpart projection" in
  let* ()=check (E.observation_offset original.before=E.observation_offset original.prepared
    && E.observation_offset original.before<=S.external_through original.original_counterparts)
    "Durable external cursor and original frontier disagree" in
  let* ()=check (E.observation_matches_preparation original.prepared
    ~after:(E.observation_offset original.before) ~through:(S.external_through original.original_counterparts)
    ~atom:original.atom_receipt ~official:original.official_receipt)
    "Durable prepared external cursor differs from the original receipts" in
  let* ()=match atom,original.atom_receipt with
    | None,None -> Ok ()
    | Some checkpoint,Some receipt ->
      check (receipt.receipt_scope=original.root
        && receipt.trace_id=Keeper_id.Trace_id.to_string checkpoint.trace_id
        && receipt.history_start_boundary_line=checkpoint.range.history_start_boundary_line
        && receipt.start_atom=checkpoint.range.start_atom && receipt.end_atom=checkpoint.range.end_atom
        && receipt.last_atom_digest=checkpoint.range.last_atom_digest
        && receipt.end_boundary_line=checkpoint.end_boundary_line
        && receipt.boundary_lines_seen=checkpoint.boundary_lines_seen && receipt.unread_messages=[])
        "Durable atom receipt differs from its selected source"
    | None,Some _ | Some _,None -> refuse "Durable atom source and receipt presence disagree" in
  let* ()=match official,original.official_receipt with
    | None,None -> Ok ()
    | Some official,Some receipt ->
      let* ()=check (official.selected<>[]) "Durable official source is empty" in
      let* ()=check (receipt.receipt_scope=original.root && receipt.unread_messages=[]
        && receipt.after_boundary_line=Option.fold ~none:0 ~some:(fun (cursor:O.t) -> cursor.boundary_line) positions.official
        && receipt.turns=List.map (fun (line:R.official_line) -> line.line,line.turn_ref) official.selected)
        "Durable official receipt differs from its original selected turns" in
      let traces=List.map (fun (trace:Held.trace) -> trace.id) official.traces in
      let selected_traces=List.map (fun (line:R.official_line) -> Ids.Turn_ref.trace_id line.turn_ref) official.selected |> List.sort_uniq String.compare in
      check (List.sort String.compare traces=selected_traces) "Durable official trace inventory differs from selected turns"
    | None,Some _ | Some _,None -> refuse "Durable official source and receipt presence disagree" in
  check (input.goal_context=Keeper_librarian.No_task) "Durable history cannot borrow the current task's Goal context"

(* What the sources say: [boundaries] and [source] select the same range,
   cuts and official turns as the original holds, and project to its input.
   [source] is the capture's own read at creation, and the live prefixes the
   original's spans name in {!confirm_sources}. *)
let validate_selection ~boundaries ~source original =
  let input=original.original_input and positions=original.original_positions in
  let atom,official=source_parts source in
  let* ()=check (contiguous boundaries) "Durable boundary rows are not the original numbered sequence" in
  let* atom_pieces=match atom with
    | None -> Ok []
    | Some checkpoint ->
      let trace_id=Keeper_id.Trace_id.to_string checkpoint.trace_id in
      let* ()=match R.select ~trace_id ~lines:boundaries
          ~progress:positions.selection ~messages:checkpoint.messages original.read_extent with
        | R.Read {range;boundary_lines_seen} ->
          check (range=checkpoint.range && boundary_lines_seen=checkpoint.boundary_lines_seen)
            "Durable checkpoint selection differs from its original witnesses"
        | R.Nothing_to_read | R.Baseline _ | R.Position_in_other_trace _ | R.Stop _ ->
          refuse "Durable checkpoint source has no matching selected range" in
      let* ()=match B.witness_line ~trace_id ~end_atom:checkpoint.range.end_atom
          ~last_atom_digest:checkpoint.range.last_atom_digest boundaries with
        | Some (line,_,_) -> check (line=checkpoint.end_boundary_line) "Durable atom endpoint boundary changed"
        | None -> refuse "Durable atom endpoint has no original boundary" in
      let cuts=R.cut_lines ~trace_id ~lines:boundaries ~messages:checkpoint.messages checkpoint.range in
      let cuts=match cuts with
        | [] -> [{R.cut_line=checkpoint.end_boundary_line;cut_end_atom=checkpoint.range.end_atom;
            cut_recorded_at=0.;cut_turn_ref=input.turn_ref}]
        | _::_ -> cuts in
      Ok (List.map (fun (cut:R.atom_cut) -> cut.cut_line,cut.cut_turn_ref) cuts) in
  let* official_pieces=match official with
    | None -> Ok []
    | Some official ->
      let selected=match R.select_official ~lines:boundaries ~cursor:positions.official original.read_extent with
        | R.Official_read selected -> selected
        | R.Nothing_official | R.Official_stop _ -> [] in
      let* ()=check (selected=official.selected) "Durable official selection differs from its original cursor/boundaries" in
      let* ()=List.fold_left (fun result (trace:official_trace) -> let* ()=result in
        let* ()=check (contiguous trace.main && contiguous trace.internal) "Durable official file rows are renumbered" in
        check (F.first_refused trace.main=None && F.first_refused trace.internal=None)
          "Durable official source contains a refused named row") (Ok ()) official.traces in
      Ok (List.map (fun (line:R.official_line) -> line.line,line.turn_ref) official.selected) in
  let pieces=List.sort (fun (left,_) (right,_) -> Int.compare left right) (atom_pieces @ official_pieces) in
  let* first_line,last_line=match pieces,List.rev pieces with
    | (first,_)::_,(last,_)::_ -> Ok (first,last)
    | [],_ | _,[] -> refuse "Durable capture has no selected source" in
  let* atom_bound=match positions.counterpart with
    | None -> Ok None
    | Some progress ->
      (match B.witness_line ~through:progress.P.boundary_lines_seen ~trace_id:progress.position.trace_id
          ~end_atom:progress.position.end_atom ~last_atom_digest:progress.position.last_atom_digest boundaries with
       | Some (line,time,_) -> Ok (if line<first_line then Some time else None)
       | None -> refuse "Durable counterpart position has no original boundary") in
  let* official_bound=match positions.official with
    | None -> Ok None
    | Some cursor ->
      (match List.assoc_opt cursor.O.boundary_line boundaries with
       | Some (Ok {B.recorded_at;event=B.Turn_ended {position=B.No_atom_history;_}}) ->
         Ok (if cursor.boundary_line<first_line then Some recorded_at else None)
       | Some (Ok {B.event=B.Turn_ended {position=(B.Atom_history _ | B.Empty_atom_history | B.Stale_noop);_};_})
       | Some (Ok {B.event=B.History_restarted _;_}) | Some (Error _) | None ->
         refuse "Durable official cursor has no original official boundary") in
  let after=List.fold_left (fun acc value -> match acc,value with
    | None,None -> None | Some value,None | None,Some value -> Some value
    | Some left,Some right -> Some (Float.max left right)) None [atom_bound;official_bound] in
  let* before=match List.assoc_opt last_line boundaries with
    | Some (Ok record) -> Ok record.B.recorded_at
    | Some (Error _) | None -> refuse "Durable source endpoint has no original boundary time" in
  let* ()=check (S.counterpart_snapshot_matches_selection original.original_counterparts
    ~external_after:(E.observation_offset original.before) ~after ~before)
    "Durable counterpart capture belongs to another cursor or source interval" in
  let* ()=match List.rev pieces with
    | (_,turn_ref)::_ -> check (Ids.Turn_ref.equal input.turn_ref turn_ref) "Durable input ends at another original turn"
    | [] -> refuse "Durable capture has no selected source" in
  let* projected=project_source ~boundaries source in
  check (projected.tool_observations=input.tool_observations
      && projected.historical_task_contexts=input.historical_task_contexts
      && same_read_messages ~contexts:projected.historical_task_contexts projected.messages input.messages)
    "Durable input tools or historical attribution differ from its original sources"

let confirm_sources ~boundaries ~messages ~traces original =
  let* boundaries=held_prefix ~changed:"Original completed-turn boundary prefix changed"
    boundary_line_json original.boundary_span boundaries in
  let live_checkpoint (held:Held.checkpoint) = match messages with
    | None -> refuse "Original checkpoint lock observation is missing"
    | Some messages ->
      let+ messages=held_prefix ~changed:"Original checkpoint message prefix changed"
        Agent_core.Checkpoint.message_to_json held.messages messages in
      ({trace_id=held.trace_id;messages;range=held.range;boundary_lines_seen=held.boundary_lines_seen;
        end_boundary_line=held.end_boundary_line} : checkpoint) in
  let live_official (held:Held.official) =
    let changed="Original official-client fragment prefix changed" in
    let+ traces=List.fold_right (fun (held:Held.trace) rest ->
      let* rest=rest in
      match List.find_opt (fun (trace:official_trace) -> trace.trace_id=held.id) traces with
      | None -> refuse changed
      | Some trace ->
        let* main=held_prefix ~changed fragment_row_json held.main trace.main in
        let+ internal=held_prefix ~changed fragment_row_json held.internal trace.internal in
        ({trace_id=held.id;main;internal} : official_trace)::rest) held.traces (Ok []) in
    ({selected=held.selected;traces} : official) in
  let* source=match original.held_source with
    | Held.Checkpoint_only checkpoint -> let+ checkpoint=live_checkpoint checkpoint in Checkpoint_only checkpoint
    | Official_only official -> let+ official=live_official official in Official_only official
    | Mixed (checkpoint,official) ->
      let* checkpoint=live_checkpoint checkpoint in
      let+ official=live_official official in Mixed (checkpoint,official) in
  validate_selection ~boundaries ~source original

let create ~runtime_keepers_dir ~extent ~boundaries ~positions
    ~source ~counterparts ~external_before ~external_prepared ~expected_revision ~range_id ~official_range_id input =
  let original={root=runtime_keepers_dir;read_extent=extent;boundary_span=span_of boundary_line_json boundaries;
    original_positions=positions;held_source=hold source;original_counterparts=counterparts;
    before=external_before;prepared=external_prepared;revision=expected_revision;
    atom_receipt=range_id;official_receipt=official_range_id;original_input=input} in
  let* ()=validate_record original in
  let+ ()=validate_selection ~boundaries ~source original in original
let with_current ~expected_revision ~current original =
  let original={original with revision=expected_revision;
    original_input={original.original_input with current}} in
  let+ ()=validate_record original in original
let to_json original =
  `Assoc ["schema",`Int 2;"purpose",`String "durable_history";
    "runtime_keepers_dir",`String original.root;"extent",`String (match original.read_extent with
      | R.All_unread -> "all_unread" | To_first_cut_point -> "first_cut");
    "boundaries",span_json original.boundary_span;"positions",positions_json original.original_positions;
    "source_text",json_text (source_json original.held_source);
    "counterparts_text",json_text (S.counterpart_snapshot_to_json original.original_counterparts);
    "external_before",E.observation_to_json original.before;"external_prepared",E.observation_to_json original.prepared;
    "expected_revision",optional (fun value -> `Int value) original.revision;
    "range_id",optional M.durable_range_id_to_json original.atom_receipt;
    "official_range_id",optional M.official_range_id_to_json original.official_receipt;
    "input_text",json_text (I.to_json original.original_input)]
let of_json json =
  let* f=fields ["schema";"purpose";"runtime_keepers_dir";"extent";"boundaries";"positions";
    "source_text";"counterparts_text";"external_before";"external_prepared";"expected_revision";"range_id";"official_range_id";"input_text"] json in
  let* ()=check (field "schema" f=`Int 2 && field "purpose" f=`String "durable_history") "Unknown durable capture schema/purpose" in
  let* root=text (field "runtime_keepers_dir" f) in
  let* read_extent=match field "extent" f with
    | `String "all_unread" -> Ok R.All_unread | `String "first_cut" -> Ok R.To_first_cut_point
    | _ -> refuse "Unknown durable selection extent" in
  let* boundary_span=span_of_json (field "boundaries" f) in
  let* original_positions=positions_of_json (field "positions" f) in
  let* source_raw=decode_text Result.ok (field "source_text" f) in
  let* held_source=source_of_json source_raw in
  let* original_counterparts=decode_text (fun json -> string_error (S.counterpart_snapshot_of_json json)) (field "counterparts_text" f) in
  let* before=string_error (E.observation_of_json (field "external_before" f)) in
  let* prepared=string_error (E.observation_of_json (field "external_prepared" f)) in
  let* revision=option int (field "expected_revision" f) in
  let* atom_receipt=option (fun value -> wire (M.durable_range_id_of_json value)) (field "range_id" f) in
  let* official_receipt=option (fun value -> wire (M.official_range_id_of_json value)) (field "official_range_id" f) in
  let* input_raw=decode_text Result.ok (field "input_text" f) in
  let* original_input=string_error (I.of_json input_raw) in
  let original={root;read_extent;boundary_span;original_positions;held_source;original_counterparts;
    before;prepared;revision;atom_receipt;official_receipt;original_input} in
  let+ ()=validate_record original in original
