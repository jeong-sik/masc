module B=Masc.Keeper_turn_boundaries
module P=Masc.Keeper_librarian_progress
let checks=ref 0
let expect label yes=incr checks;if not yes then failwith label
let trace="fixture"
let plain index:Agent_core.Types.message={origin=Conversation;role=(if index mod 2=0 then User else Assistant);
 content=[Text(string_of_int index)];name=None;tool_call_id=None;metadata=[]}
let digest messages atom=Option.get(Before.atom_opening_digest messages atom)
let ended ?(history_at_start=B.Continued_history) ?(trace_id=trace) turn end_atom last_atom_digest:B.record=
 {recorded_at=float_of_int turn;event=Turn_ended{task_context=Masc.Keeper_turn_task_context.No_task;
 turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:turn;history_at_start;
 position=Atom_history{end_atom;last_atom_digest}}}
let restarted:B.record={recorded_at=0.;event=History_restarted{trace_id=trace}}
let numbered rows=List.mapi(fun index row->index+1,row)rows
let progress ?(trace_id=trace) ~seen messages end_atom:P.t=
 {position={trace_id;end_atom;last_atom_digest=digest messages(end_atom-1)};boundary_lines_seen=seen}
type case={messages:Agent_core.Types.message list;lines:(int*(B.record,B.read_error)result)list;position:P.t option}
let cases=
 let ordinary=List.concat_map(fun n->
  let messages=List.init n plain in
  let ended_rows=List.init n(fun index->Ok(ended(index+1)(index+1)(digest messages index))) in
  let lines=numbered(Ok restarted::ended_rows) in
  let positions=if n=0 then [None] else
   [None;Some(progress ~seen:(n+1) messages 1);Some(progress ~seen:(n+1) messages n);
    Some(progress ~trace_id:"other" ~seen:(n+1) messages n);
    Some(progress ~seen:(n+8) messages n);
    Some{(progress ~seen:(n+1) messages n)with position={trace_id=trace;end_atom=n;last_atom_digest=String.make 64 '0'}}] in
  List.concat_map(fun position->
   [{messages;lines;position};{messages;lines=lines@[n+2,Error(B.Not_json "fixture")];position};
    {messages;lines=lines@[n+2,Error B.Incomplete_line];position};
    {messages;lines=lines@[n+2,Ok restarted];position}])positions)
  [0;1;2;5;12] in
 let messages=List.init 3 plain in
 let start=B.Continued_history_from{start_atom=2;start_atom_digest=digest messages 1} in
 let dead=numbered[Ok(ended 1 1(digest messages 0));Error(B.Not_json "fixture");
  Ok(ended ~history_at_start:start 2 3(digest messages 2))] in
 let settled=List.map(fun position->{messages;lines=dead;position})
  [None;Some(progress ~seen:1 messages 2);Some(progress ~seen:3 messages 3)] in
 let bad={(plain 0) with content=[ToolUse{id="fixture";name="fixture";input=`Float nan}]} in
 let messages=[bad;plain 1] in
 let lines=numbered[Ok(ended 1 1(String.make 64 'a'));Ok(ended 2 2(digest messages 1))] in
 let failed=[{messages;lines;position=Some(progress ~seen:2 messages 2)};
  {messages;lines;position=None}] in
 ordinary@settled@failed
let outcome f=try `Ok(Marshal.to_string(f ())[Marshal.No_sharing]) with Yojson.Json_error detail->`Error detail
let compare label before after=
 before_trace:=[];let left=outcome before in let left_trace=List.rev !before_trace in
 after_trace:=[];let right=outcome after in let right_trace=List.rev !after_trace in
 expect(label^" result/error") (left=right);
 expect(label^" exact digest lookup order") (left_trace=right_trace)
let ()=
 List.iter(fun case->
  compare "select all"
   (fun()->Before_range.select ~trace_id:trace ~lines:case.lines ~progress:case.position ~messages:case.messages Before_range.All_unread)
   (fun()->After_range.select ~trace_id:trace ~lines:case.lines ~progress:case.position ~messages:case.messages After_range.All_unread);
  compare "select first"
   (fun()->Before_range.select ~trace_id:trace ~lines:case.lines ~progress:case.position ~messages:case.messages Before_range.To_first_cut_point)
   (fun()->After_range.select ~trace_id:trace ~lines:case.lines ~progress:case.position ~messages:case.messages After_range.To_first_cut_point);
  compare "unread"
   (fun()->Before_range.unread_turns ~trace_id:trace ~lines:case.lines ~progress:case.position ~messages:case.messages)
   (fun()->After_range.unread_turns ~trace_id:trace ~lines:case.lines ~progress:case.position ~messages:case.messages))cases;
 Printf.printf "%s\n" (Yojson.Safe.to_string(`Assoc["cases",`Int(List.length cases);
  "checks",`Int !checks;"existing_baseline_tests",`Int !before_tests;"existing_candidate_tests",`Int !after_tests]))
