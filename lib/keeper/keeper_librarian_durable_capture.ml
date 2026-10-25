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
let pair decode_left decode_right = function
  | `List [left;right] -> let* left=decode_left left in let+ right=decode_right right in left,right
  | _ -> refuse "Durable capture expects an ordered pair"

type boundary_lines = (int * (B.record,B.read_error) result) list
type checkpoint = {
  reference : Keeper_checkpoint_ref.t;
  canonical_bytes : string;
  messages : Agent_core.Types.message list;
  range : R.range;
  boundary_lines_seen : int;
  end_boundary_line : int;
}
let checkpoint ~snapshot ~range ~boundary_lines_seen ~end_boundary_line =
  {reference=C.exact_snapshot_reference snapshot;canonical_bytes=C.exact_snapshot_canonical_bytes snapshot;
   messages=C.exact_snapshot_messages snapshot;range;boundary_lines_seen;end_boundary_line}
type official_trace = {trace_id:string;main:(int * (F.line,F.read_error) result) list;
  internal:(int * (F.line,F.read_error) result) list}
type official = {selected:R.official_line list;traces:official_trace list}
type source = Checkpoint_only of checkpoint | Official_only of official | Mixed of checkpoint * official
type positions = {current:P.t option;selection:P.t option;counterpart:P.t option;official:O.t option}
type t = {root:string;read_extent:R.extent;original_boundaries:boundary_lines;original_positions:positions;
  original_source:source;original_counterparts:S.counterpart_snapshot;before:E.observation;prepared:E.observation;
  revision:int option;atom_receipt:M.durable_range_id option;official_receipt:M.official_range_id option;
  original_input:Keeper_librarian.input;include_message_origin:bool}
let input original = original.original_input
let expected_revision original = original.revision
let range_id original = original.atom_receipt
let official_range_id original = original.official_receipt
let boundaries original = original.original_boundaries
let positions original = original.original_positions
let source original = original.original_source
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
let reason_of_json = function
  | `List [`String "object"] -> Ok W.Expected_object | `List [`String "array"] -> Ok W.Expected_array
  | `List [`String "string"] -> Ok W.Expected_string | `List [`String "int"] -> Ok W.Expected_int
  | `List [`String "number"] -> Ok W.Expected_number | `List [`String "blank"] -> Ok W.Blank_string
  | `List [`String "not_finite"] -> Ok W.Not_finite | `List [`String "negative"] -> Ok W.Negative
  | `List [`String "not_positive"] -> Ok W.Not_positive | `List [`String "empty"] -> Ok W.Empty_list
  | `List [`String "not_ascending"] -> Ok W.Not_ascending
  | `List [`String "duplicate_field";`String value] -> Ok (W.Duplicate_field value)
  | `List [`String "unknown_token";`String value] -> Ok (W.Unknown_token value)
  | `List [`String "memory_id";`String value] -> Ok (W.Not_a_memory_id value)
  | `List [`String "post_id";`String value] -> Ok (W.Not_a_board_post_id value)
  | `List [`String "comment_id";`String value] -> Ok (W.Not_a_board_comment_id value)
  | `List [`String "turn_ref";`String value] -> Ok (W.Not_a_turn_ref value)
  | `List [`String "task_context";`String value] -> Ok (W.Invalid_task_context value)
  | `List [`String "duplicate_entry";`String value] -> Ok (W.Duplicate_entry value)
  | `List [`String "field_set";missing;unexpected] ->
    let* missing=list text missing in let+ unexpected=list text unexpected in W.Field_set_mismatch {missing;unexpected}
  | _ -> refuse "Unknown durable source wire rejection"
let wire_error_json (error:W.wire_error) = `Assoc ["path",`List (List.map (function
  | W.Wire_field name -> `List [`String "field";`String name]
  | Wire_index index -> `List [`String "index";`Int index]) error.path);"reason",reason_json error.reason]
let wire_error_of_json json =
  let* f=fields ["path";"reason"] json in
  let* path=list (function
    | `List [`String "field";`String name] -> Ok (W.Wire_field name)
    | `List [`String "index";`Int index] -> Ok (W.Wire_index index)
    | _ -> refuse "Invalid durable source rejection path") (field "path" f) in
  let+ reason=reason_of_json (field "reason" f) in {W.path;reason}
let boundary_error_json = function
  | B.Not_json detail -> `List [`String "not_json";`String detail]
  | Malformed error -> `List [`String "malformed";wire_error_json error]
  | Incomplete_line -> `List [`String "incomplete"]
let boundary_error_of_json = function
  | `List [`String "not_json";`String detail] -> Ok (B.Not_json detail)
  | `List [`String "malformed";error] -> let+ error=wire_error_of_json error in B.Malformed error
  | `List [`String "incomplete"] -> Ok B.Incomplete_line
  | _ -> refuse "Unknown durable boundary rejection"
let result_json ok error = function Ok value -> `List [`String "ok";ok value] | Error value -> `List [`String "error";error value]
let result_of_json ok error = function
  | `List [`String "ok";value] -> let+ value=ok value in Ok value
  | `List [`String "error";value] -> let+ value=error value in Error value
  | _ -> refuse "Invalid durable source row result"
let boundaries_json lines = `List (List.map (fun (line,value) ->
  pair_json (`Int line) (result_json B.record_to_json boundary_error_json value)) lines)
let boundaries_of_json = list (pair int (result_of_json (fun json -> wire (B.record_of_json json)) boundary_error_of_json))
let turn_of_json json = let* value=text json in
  match Ids.Turn_ref.of_string value with Some reference -> Ok reference | None -> refuse "Invalid captured turn reference"
let fragment_json ~include_origin = function
  | F.Message {turn_ref;recorded_at;source;message} -> `Assoc ["kind",`String "message";
      "turn_ref",Ids.Turn_ref.to_yojson turn_ref;"recorded_at",`Float recorded_at;
      "source",optional (fun value -> `String value) source;
      "message",I.message_json_with_origin ~include_origin message]
  | F.Tool_observation {turn_ref;recorded_at;observation} -> `Assoc ["kind",`String "tool";
      "turn_ref",Ids.Turn_ref.to_yojson turn_ref;"recorded_at",`Float recorded_at;
      "tool_name",`String observation.tool_name;"outcome",`String (match observation.outcome with
        | Keeper_librarian.Succeeded -> "succeeded" | Failed -> "failed" | Unknown -> "unknown")]
let fragment_of_json json =
  let* kind=match json with `Assoc f -> (match List.assoc_opt "kind" f with
    | Some value -> text value | None -> refuse "Fragment kind is missing") | _ -> refuse "Fragment is not an object" in
  match kind with
  | "message" ->
    let* f=fields ["kind";"turn_ref";"recorded_at";"source";"message"] json in
    let* turn_ref=turn_of_json (field "turn_ref" f) in let* recorded_at=number (field "recorded_at" f) in
    let* source=option text (field "source" f) in let+ message=string_error (I.message_of_json (field "message" f)) in
    F.Message {turn_ref;recorded_at;source;message}
  | "tool" ->
    let* f=fields ["kind";"turn_ref";"recorded_at";"tool_name";"outcome"] json in
    let* turn_ref=turn_of_json (field "turn_ref" f) in let* recorded_at=number (field "recorded_at" f) in
    let* tool_name=text (field "tool_name" f) in
    let+ outcome=match field "outcome" f with
      | `String "succeeded" -> Ok Keeper_librarian.Succeeded | `String "failed" -> Ok Keeper_librarian.Failed
      | `String "unknown" -> Ok Keeper_librarian.Unknown | _ -> refuse "Unknown captured tool outcome" in
    F.Tool_observation {turn_ref;recorded_at;observation={tool_name;outcome}}
  | _ -> refuse "Unknown captured fragment kind"
let fragment_error_json = function
  | F.Not_json detail -> `List [`String "not_json";`String detail]
  | Malformed error -> `List [`String "malformed";wire_error_json error]
  | Message_rejected detail -> `List [`String "message_rejected";`String detail]
  | Incomplete_line -> `List [`String "incomplete"]
let fragment_error_of_json = function
  | `List [`String "not_json";`String detail] -> Ok (F.Not_json detail)
  | `List [`String "malformed";error] -> let+ error=wire_error_of_json error in F.Malformed error
  | `List [`String "message_rejected";`String detail] -> Ok (F.Message_rejected detail)
  | `List [`String "incomplete"] -> Ok F.Incomplete_line
  | _ -> refuse "Unknown captured fragment rejection"
let fragment_line_json ~include_origin = function
  | F.Untagged -> `List [`String "untagged"]
  | Fragment fragment -> `List [`String "fragment";fragment_json ~include_origin fragment]
let fragment_line_of_json = function
  | `List [`String "untagged"] -> Ok F.Untagged
  | `List [`String "fragment";fragment] -> let+ fragment=fragment_of_json fragment in F.Fragment fragment
  | _ -> refuse "Unknown captured fragment row"
let fragment_rows_json ~include_origin rows = `List (List.map (fun (line,value) -> pair_json (`Int line)
  (result_json (fragment_line_json ~include_origin) fragment_error_json value)) rows)
let fragment_rows_of_json = list (pair int (result_of_json fragment_line_of_json fragment_error_of_json))

let range_json (range:R.range) = `Assoc ["history_start_boundary_line",`Int range.history_start_boundary_line;
  "start_atom",`Int range.start_atom;"end_atom",`Int range.end_atom;"last_atom_digest",`String range.last_atom_digest]
let range_of_json json =
  let* f=fields ["history_start_boundary_line";"start_atom";"end_atom";"last_atom_digest"] json in
  let* history_start_boundary_line=int (field "history_start_boundary_line" f) in
  let* start_atom=int (field "start_atom" f) in let* end_atom=int (field "end_atom" f) in
  let+ last_atom_digest=text (field "last_atom_digest" f) in {R.history_start_boundary_line;start_atom;end_atom;last_atom_digest}
let unique_assoc_field name fields =
  match List.filter_map (fun (k, v) -> if String.equal k name then Some v else None) fields with
  | [value] -> Some value
  | [] | _ :: _ :: _ -> None
let persisted_message_json ~include_origin message =
  match Agent_core.Checkpoint.message_to_json message with
  | `Assoc fields when not include_origin ->
    `Assoc (List.filter (fun (name, _) -> not (String.equal name "origin")) fields)
  | json -> json
let persisted_messages_json ~include_origin messages =
  `List (List.map (persisted_message_json ~include_origin) messages)
let json_list_first_has_origin = function
  | `List (first :: _) -> Some (I.message_json_has_origin first)
  | `List []
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> None
let checkpoint_uses_message_origin (checkpoint : checkpoint) =
  match Yojson.Safe.from_string checkpoint.canonical_bytes with
  | `Assoc fields ->
    let from_messages =
      Option.bind (unique_assoc_field "messages" fields) json_list_first_has_origin
    in
    (match from_messages with
     | Some has_origin -> has_origin
     | None ->
       (match unique_assoc_field "version" fields with
        | Some (`Int version) -> version >= 14
        | Some (`Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _)
        | None -> true))
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _)
  | exception Yojson.Json_error _ -> true
let checkpoint_json ~include_origin source = `Assoc ["trace_id",`String (Keeper_id.Trace_id.to_string source.reference.trace_id);
  "turn_count",`Int source.reference.turn_count;"sha256",`String source.reference.sha256;
  "canonical_bytes",`String source.canonical_bytes;
  "messages",`List (List.map (I.message_json_with_origin ~include_origin) source.messages);
  "range",range_json source.range;"boundary_lines_seen",`Int source.boundary_lines_seen;"end_boundary_line",`Int source.end_boundary_line]
let checkpoint_of_json json =
  let* f=fields ["trace_id";"turn_count";"sha256";"canonical_bytes";"messages";"range";"boundary_lines_seen";"end_boundary_line"] json in
  let* trace=text (field "trace_id" f) in let* trace_id=string_error (Keeper_id.Trace_id.of_string trace) in
  let* turn_count=int (field "turn_count" f) in let* sha256=text (field "sha256" f) in
  let* reference=Keeper_checkpoint_ref.of_persisted ~trace_id ~turn_count ~sha256
    |> Result.map_error (fun error -> Inconsistent_source (C.checkpoint_ref_create_error_to_string error)) in
  let* canonical_bytes=text (field "canonical_bytes" f) in
  let* messages=list (fun json -> string_error (I.message_of_json json)) (field "messages" f) in
  (* Lineage values can retain richer ToolResult JSON than the checkpoint
     codec persists. Bind every persisted message field to the original bytes,
     while keeping that richer complete value in the separate input codec. *)
  let* () =
    match C.exact_snapshot_of_canonical_bytes ~expected_session_id:reference.trace_id canonical_bytes with
    | Ok decoded ->
      let* ()=check (Keeper_checkpoint_ref.equal reference (C.exact_snapshot_reference decoded))
        "Restored checkpoint bytes differ from the original reference" in
      check
        (Yojson.Safe.equal
           (persisted_messages_json ~include_origin:true messages)
           (persisted_messages_json ~include_origin:true (C.exact_snapshot_messages decoded)))
        "Restored checkpoint messages differ from the original canonical bytes"
    | Error (C.Ref_read_failed (C.Superseded_version _)) ->
      let actual_sha256 = Keeper_checkpoint_ref.sha256_of_canonical_bytes canonical_bytes in
      let* () =
        check
          (String.equal actual_sha256 reference.sha256)
          "Restored checkpoint bytes differ from the original reference"
      in
      (match Yojson.Safe.from_string canonical_bytes with
       | exception Yojson.Json_error detail -> refuse detail
       | `Assoc cb_fields ->
         let expected_trace = Keeper_id.Trace_id.to_string reference.trace_id in
         let* () =
           check
             (unique_assoc_field "session_id" cb_fields = Some (`String expected_trace)
              && unique_assoc_field "turn_count" cb_fields = Some (`Int reference.turn_count))
             "Restored checkpoint bytes differ from the original reference"
         in
         (match unique_assoc_field "messages" cb_fields with
          | Some cb_messages ->
            let cb_has_origin =
              Option.value ~default:false (json_list_first_has_origin cb_messages)
            in
            check
              (Yojson.Safe.equal (persisted_messages_json ~include_origin:cb_has_origin messages) cb_messages)
              "Restored checkpoint messages differ from the original canonical bytes"
          | None -> refuse "Restored checkpoint canonical bytes have no messages array")
       | _ -> refuse "Restored checkpoint canonical bytes are not an object")
    | Error
        ( C.Ref_read_failed
            ( C.Not_found
            | C.Newer_version _
            | C.Parse_error _
            | C.Store_error _
            | C.Io_error _
            | C.Read_failed _
            | C.Agent_core_error _ )
        | C.Ref_not_found
        | C.Ref_identity_invalid _
        | C.Ref_session_mismatch _
        | C.Ref_lock_failed _ as error ) ->
      Error (Inconsistent_source (C.checkpoint_ref_load_error_to_string error))
  in
  let* range=range_of_json (field "range" f) in
  let* boundary_lines_seen=int (field "boundary_lines_seen" f) in
  let+ end_boundary_line=int (field "end_boundary_line" f) in
  {reference;canonical_bytes;messages;range;boundary_lines_seen;end_boundary_line}
let official_json ~include_origin source = `Assoc ["selected",`List (List.map (fun (line:R.official_line) ->
  `Assoc ["line",`Int line.line;"turn_ref",Ids.Turn_ref.to_yojson line.turn_ref;"recorded_at",`Float line.recorded_at]) source.selected);
  "traces",`List (List.map (fun trace -> `Assoc ["trace_id",`String trace.trace_id;
    "main",fragment_rows_json ~include_origin trace.main;
    "internal",fragment_rows_json ~include_origin trace.internal]) source.traces)]
let official_of_json json =
  let* f=fields ["selected";"traces"] json in
  let* selected=list (fun json -> let* f=fields ["line";"turn_ref";"recorded_at"] json in
    let* line=int (field "line" f) in let* turn_ref=turn_of_json (field "turn_ref" f) in
    let+ recorded_at=number (field "recorded_at" f) in {R.line;turn_ref;recorded_at}) (field "selected" f) in
  let+ traces=list (fun json -> let* f=fields ["trace_id";"main";"internal"] json in
    let* trace_id=text (field "trace_id" f) in let* main=fragment_rows_of_json (field "main" f) in
    let+ internal=fragment_rows_of_json (field "internal" f) in {trace_id;main;internal}) (field "traces" f) in
  {selected;traces}
let source_json ~include_origin = function
  | Checkpoint_only checkpoint -> `List [`String "checkpoint";checkpoint_json ~include_origin checkpoint]
  | Official_only official -> `List [`String "official";official_json ~include_origin official]
  | Mixed (checkpoint,official) -> `List [`String "mixed";checkpoint_json ~include_origin checkpoint;official_json ~include_origin official]
let source_of_json = function
  | `List [`String "checkpoint";value] -> let+ value=checkpoint_of_json value in Checkpoint_only value
  | `List [`String "official";value] -> let+ value=official_of_json value in Official_only value
  | `List [`String "mixed";atom;official] -> let* atom=checkpoint_of_json atom in
    let+ official=official_of_json official in Mixed (atom,official)
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
           (fun (calls_rev, results) block ->
              match Agent_core.Canonical_tool.tool_call_of_block block with
              | Some call -> (call :: calls_rev), results
              | None ->
                (match Agent_core.Canonical_tool.tool_result_of_block block with
                 | None -> calls_rev, results
                 | Some result ->
                   calls_rev, Tool_map.add result.call_id result.outcome results))
           (calls_rev, results)
           message.content)
      ([], Tool_map.empty)
      messages
  in
  List.rev_map
    (fun (call : Agent_core.Canonical_tool.provider_tool_call) ->
       let outcome =
         match Tool_map.find_opt call.call_id results with
         | None -> Keeper_librarian.Unknown
         | Some result ->
           if Agent_core.Types.tool_result_outcome_is_error result
           then Keeper_librarian.Failed
           else Keeper_librarian.Succeeded
       in
       ({ tool_name =
            Keeper_tool_descriptor_resolution.canonical_tool_name call.name
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
      let include_origin=checkpoint_uses_message_origin atom in
      let trace_id=Keeper_id.Trace_id.to_string atom.reference.trace_id in
      let cuts=R.cut_lines ~include_origin ~trace_id ~lines:boundaries ~messages:atom.messages atom.range in
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
      let include_origin=checkpoint_uses_message_origin atom in
      let trace_id=Keeper_id.Trace_id.to_string atom.reference.trace_id in
      let scopes=Historical.atom_spans ~trace_id
        ~digest_at:(Runtime_model_input_tail_window.atom_opening_digest ~include_origin atom.messages)
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
let validate original =
  let input=original.original_input and positions=original.original_positions in
  let atom,official=source_parts original.original_source in
  let* ()=check (String.trim original.root<>"") "Durable receipt scope is blank" in
  let* ()=check (contiguous original.original_boundaries) "Durable boundary rows are not the original numbered sequence" in
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
  let* atom_pieces=match atom,original.atom_receipt with
    | None,None -> Ok []
    | Some checkpoint,Some receipt ->
      let include_origin=checkpoint_uses_message_origin checkpoint in
      let trace_id=Keeper_id.Trace_id.to_string checkpoint.reference.trace_id in
      let* ()=match R.select ~include_origin ~trace_id ~lines:original.original_boundaries
          ~progress:positions.selection ~messages:checkpoint.messages original.read_extent with
        | R.Read {range;boundary_lines_seen} ->
          check (range=checkpoint.range && boundary_lines_seen=checkpoint.boundary_lines_seen)
            "Durable checkpoint selection differs from its original witnesses"
        | R.Nothing_to_read | R.Baseline _ | R.Position_in_other_trace _ | R.Stop _ ->
          refuse "Durable checkpoint source has no matching selected range" in
      let* ()=check (receipt.receipt_scope=original.root && receipt.trace_id=trace_id
        && receipt.history_start_boundary_line=checkpoint.range.history_start_boundary_line
        && receipt.start_atom=checkpoint.range.start_atom && receipt.end_atom=checkpoint.range.end_atom
        && receipt.last_atom_digest=checkpoint.range.last_atom_digest
        && receipt.end_boundary_line=checkpoint.end_boundary_line
        && receipt.boundary_lines_seen=checkpoint.boundary_lines_seen && receipt.unread_messages=[])
        "Durable atom receipt differs from its selected source" in
      let* ()=match B.witness_line ~trace_id ~end_atom:checkpoint.range.end_atom
          ~last_atom_digest:checkpoint.range.last_atom_digest original.original_boundaries with
        | Some (line,_,_) -> check (line=checkpoint.end_boundary_line) "Durable atom endpoint boundary changed"
        | None -> refuse "Durable atom endpoint has no original boundary" in
      let cuts=R.cut_lines ~include_origin ~trace_id ~lines:original.original_boundaries ~messages:checkpoint.messages checkpoint.range in
      let cuts=match cuts with
        | [] -> [{R.cut_line=checkpoint.end_boundary_line;cut_end_atom=checkpoint.range.end_atom;
            cut_recorded_at=0.;cut_turn_ref=input.turn_ref}]
        | _::_ -> cuts in
      Ok (List.map (fun (cut:R.atom_cut) -> cut.cut_line,cut.cut_turn_ref) cuts)
    | None,Some _ | Some _,None -> refuse "Durable atom source and receipt presence disagree" in
  let* official_pieces=match official,original.official_receipt with
    | None,None -> Ok []
    | Some official,Some receipt ->
      let* ()=check (official.selected<>[]) "Durable official source is empty" in
      let selected=match R.select_official ~lines:original.original_boundaries ~cursor:positions.official original.read_extent with
        | R.Official_read selected -> selected
        | R.Nothing_official | R.Official_stop _ -> [] in
      let* ()=check (selected=official.selected) "Durable official selection differs from its original cursor/boundaries" in
      let* ()=check (receipt.receipt_scope=original.root && receipt.unread_messages=[]
        && receipt.after_boundary_line=Option.fold ~none:0 ~some:(fun (cursor:O.t) -> cursor.boundary_line) positions.official
        && receipt.turns=List.map (fun (line:R.official_line) -> line.line,line.turn_ref) official.selected)
        "Durable official receipt differs from its original selected turns" in
      let traces=List.map (fun trace -> trace.trace_id) official.traces in
      let selected_traces=List.map (fun (line:R.official_line) -> Ids.Turn_ref.trace_id line.turn_ref) official.selected |> List.sort_uniq String.compare in
      let* ()=check (List.sort String.compare traces=selected_traces) "Durable official trace inventory differs from selected turns" in
      let* ()=List.fold_left (fun result trace -> let* ()=result in
        let* ()=check (contiguous trace.main && contiguous trace.internal) "Durable official file rows are renumbered" in
        check (F.first_refused trace.main=None && F.first_refused trace.internal=None)
          "Durable official source contains a refused named row") (Ok ()) official.traces in
      Ok (List.map (fun (line:R.official_line) -> line.line,line.turn_ref) official.selected)
    | None,Some _ | Some _,None -> refuse "Durable official source and receipt presence disagree" in
  let pieces=List.sort (fun (left,_) (right,_) -> Int.compare left right) (atom_pieces @ official_pieces) in
  let* first_line,last_line=match pieces,List.rev pieces with
    | (first,_)::_,(last,_)::_ -> Ok (first,last)
    | [],_ | _,[] -> refuse "Durable capture has no selected source" in
  let* atom_bound=match positions.counterpart with
    | None -> Ok None
    | Some progress ->
      (match B.witness_line ~through:progress.P.boundary_lines_seen ~trace_id:progress.position.trace_id
          ~end_atom:progress.position.end_atom ~last_atom_digest:progress.position.last_atom_digest original.original_boundaries with
       | Some (line,time,_) -> Ok (if line<first_line then Some time else None)
       | None -> refuse "Durable counterpart position has no original boundary") in
  let* official_bound=match positions.official with
    | None -> Ok None
    | Some cursor ->
      (match List.assoc_opt cursor.O.boundary_line original.original_boundaries with
       | Some (Ok {B.recorded_at;event=B.Turn_ended {position=B.No_atom_history;_}}) ->
         Ok (if cursor.boundary_line<first_line then Some recorded_at else None)
       | Some (Ok {B.event=B.Turn_ended {position=(B.Atom_history _ | B.Empty_atom_history | B.Stale_noop);_};_})
       | Some (Ok {B.event=B.History_restarted _;_}) | Some (Error _) | None ->
         refuse "Durable official cursor has no original official boundary") in
  let after=List.fold_left (fun acc value -> match acc,value with
    | None,None -> None | Some value,None | None,Some value -> Some value
    | Some left,Some right -> Some (Float.max left right)) None [atom_bound;official_bound] in
  let* before=match List.assoc_opt last_line original.original_boundaries with
    | Some (Ok record) -> Ok record.B.recorded_at
    | Some (Error _) | None -> refuse "Durable source endpoint has no original boundary time" in
  let* ()=check (S.counterpart_snapshot_matches_selection original.original_counterparts
    ~external_after:(E.observation_offset original.before) ~after ~before)
    "Durable counterpart capture belongs to another cursor or source interval" in
  let* ()=match List.rev pieces with
    | (_,turn_ref)::_ -> check (Ids.Turn_ref.equal input.turn_ref turn_ref) "Durable input ends at another original turn"
    | [] -> refuse "Durable capture has no selected source" in
  let* projected=project_source ~boundaries:original.original_boundaries original.original_source in
  let* ()=check (projected.messages=input.messages && projected.tool_observations=input.tool_observations
      && projected.historical_task_contexts=input.historical_task_contexts)
    "Durable input tools or historical attribution differ from its original sources" in
  let* ()=check (input.goal_context=Keeper_librarian.No_task) "Durable history cannot borrow the current task's Goal context" in
  Ok ()

let create_with_origin_format ~include_message_origin ~runtime_keepers_dir ~extent ~boundaries ~positions
    ~source ~counterparts ~external_before ~external_prepared ~expected_revision ~range_id ~official_range_id input =
  let original={root=runtime_keepers_dir;read_extent=extent;original_boundaries=boundaries;
    original_positions=positions;original_source=source;original_counterparts=counterparts;
    before=external_before;prepared=external_prepared;revision=expected_revision;
    atom_receipt=range_id;official_receipt=official_range_id;original_input=input;
    include_message_origin} in
  let+ ()=validate original in original
let create ~runtime_keepers_dir ~extent ~boundaries ~positions ~source ~counterparts
    ~external_before ~external_prepared ~expected_revision ~range_id ~official_range_id input =
  create_with_origin_format ~include_message_origin:true ~runtime_keepers_dir ~extent ~boundaries ~positions
    ~source ~counterparts ~external_before ~external_prepared ~expected_revision ~range_id ~official_range_id input
let with_current ~expected_revision ~current original =
  let original={original with revision=expected_revision;
    original_input={original.original_input with current}} in
  let+ ()=validate original in original
let to_json original =
  let include_origin=original.include_message_origin in
  `Assoc ["schema",`Int 1;"purpose",`String "durable_history";
    "runtime_keepers_dir",`String original.root;"extent",`String (match original.read_extent with
      | R.All_unread -> "all_unread" | To_first_cut_point -> "first_cut");
    "boundaries",boundaries_json original.original_boundaries;"positions",positions_json original.original_positions;
    "source_text",json_text (source_json ~include_origin original.original_source);
    "counterparts_text",json_text (S.counterpart_snapshot_to_json original.original_counterparts);
    "external_before",E.observation_to_json original.before;"external_prepared",E.observation_to_json original.prepared;
    "expected_revision",optional (fun value -> `Int value) original.revision;
    "range_id",optional M.durable_range_id_to_json original.atom_receipt;
    "official_range_id",optional M.official_range_id_to_json original.official_receipt;
    "input_text",json_text (I.to_json_with_origin ~include_origin original.original_input)]
let fragment_rows_message_origin rows =
  List.find_map
    (function
      | `List [_; `List [`String "ok"; `List [`String "fragment"; `Assoc f]]] ->
        (match List.assoc_opt "kind" f, List.assoc_opt "message" f with
         | Some (`String "message"), Some msg -> Some (I.message_json_has_origin msg)
         | Some _, (Some _ | None) | None, (Some _ | None) -> None)
      | _ -> None)
    rows
let official_json_message_origin = function
  | `Assoc f ->
    (match List.assoc_opt "traces" f with
     | Some (`List traces) ->
       List.find_map
         (function
           | `Assoc tf ->
             (match List.assoc_opt "main" tf, List.assoc_opt "internal" tf with
              | Some (`List main), Some (`List internal) ->
                (match fragment_rows_message_origin main with
                 | Some _ as result -> result
                 | None -> fragment_rows_message_origin internal)
              | Some _, (Some _ | None) | None, (Some _ | None) -> None)
           | _ -> None)
         traces
     | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _)
     | None -> None)
  | _ -> None
let checkpoint_json_message_origin = function
  | `Assoc f ->
    Option.bind (List.assoc_opt "messages" f) json_list_first_has_origin
  | _ -> None
let source_json_message_origin = function
  | `List [`String "checkpoint"; cp] -> checkpoint_json_message_origin cp
  | `List [`String "official"; off] -> official_json_message_origin off
  | `List [`String "mixed"; cp; off] ->
    (match checkpoint_json_message_origin cp with
     | Some _ as result -> result
     | None -> official_json_message_origin off)
  | _ -> None
let input_json_message_origin = function
  | `Assoc f ->
    Option.bind (List.assoc_opt "messages" f) json_list_first_has_origin
  | _ -> None
let of_json json =
  let* f=fields ["schema";"purpose";"runtime_keepers_dir";"extent";"boundaries";"positions";
    "source_text";"counterparts_text";"external_before";"external_prepared";"expected_revision";"range_id";"official_range_id";"input_text"] json in
  let* ()=check (field "schema" f=`Int 1 && field "purpose" f=`String "durable_history") "Unknown durable capture schema/purpose" in
  let* runtime_keepers_dir=text (field "runtime_keepers_dir" f) in
  let* extent=match field "extent" f with
    | `String "all_unread" -> Ok R.All_unread | `String "first_cut" -> Ok R.To_first_cut_point
    | _ -> refuse "Unknown durable selection extent" in
  let* boundaries=boundaries_of_json (field "boundaries" f) in
  let* positions=positions_of_json (field "positions" f) in
  let* source_raw=decode_text Result.ok (field "source_text" f) in
  let* source=source_of_json source_raw in
  let* counterparts=decode_text (fun json -> string_error (S.counterpart_snapshot_of_json json)) (field "counterparts_text" f) in
  let* external_before=string_error (E.observation_of_json (field "external_before" f)) in
  let* external_prepared=string_error (E.observation_of_json (field "external_prepared" f)) in
  let* expected_revision=option int (field "expected_revision" f) in
  let* range_id=option (fun value -> wire (M.durable_range_id_of_json value)) (field "range_id" f) in
  let* official_range_id=option (fun value -> wire (M.official_range_id_of_json value)) (field "official_range_id" f) in
  let* input_raw=decode_text Result.ok (field "input_text" f) in
  let* input=string_error (I.of_json input_raw) in
  let include_message_origin =
    match input_json_message_origin input_raw with
    | Some has_origin -> has_origin
    | None -> Option.value ~default:true (source_json_message_origin source_raw)
  in
  create_with_origin_format ~include_message_origin ~runtime_keepers_dir ~extent ~boundaries ~positions ~source ~counterparts
    ~external_before ~external_prepared ~expected_revision ~range_id ~official_range_id input
