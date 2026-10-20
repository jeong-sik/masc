"""Exercise production history request slots, launch and application arms without Dune.

Eio, promises, atomic slots and the extracted production functions are real.
HTTP, workspace checks, row projection, journals and the workspace job registration
are fixtures. No terminal text/layout or wall-clock thresholds are tested.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
types = (root / 'bin/masc_tui_types.ml').read_text()
main = (root / 'bin/masc_tui.ml').read_text()
protocol = (root / 'bin/masc_tui_async_protocol.ml').read_text()
setter = 'let set_keeper_chat_sources ' + types.split('let set_keeper_chat_sources ', 1)[1].split('let restore_keeper_chat_page', 1)[0]
slots = 'module Keeper_history_read : sig' + types.split('module Keeper_history_read : sig', 1)[1].split('\n(* The Memory lane', 1)[0]
launch = 'let launch_keeper_history_load ' + main.split('let launch_keeper_history_load ', 1)[1].split('\nlet enter_keeper_chat ', 1)[0]
arm = '  | Keeper_chat_history_loaded (request, source, result) ->' + main.split('  | Keeper_chat_history_loaded (request, source, result) ->', 1)[1].split('  | Keeper_chat_operation_loaded', 1)[0]
collect = protocol.split('let collect_owned_results state =\n', 1)[1].split('  let receipts =', 1)[0]
header = r'''
type workspace_authority = Workspace_authority of int
module Masc_tui_keeper_chat_history = struct
 type row = {id:int; memory:bool; at:float}
 type decoded = {rows:row list; dropped:int}
 type page = {decoded:decoded;has_more:bool;next_cursor:string option}
 type page_error = Page_stale | Page_read_failed of string
 let page_error_to_string = function Page_stale -> "stale" | Page_read_failed detail -> detail
end
module Keeper_chat_history = Masc_tui_keeper_chat_history
'''
stubs = r'''
type role = Message_history | Message_memory
type entry = {id:int; me_role:role}
type keeper_chat_sources = {kcs_history:entry list option; kcs_memory:entry list}
let empty_keeper_chat_sources = {kcs_history=None;kcs_memory=[]}
type state = {
 mutable msg_history_inflight: Keeper_history_read.t option;
 mutable msg_history_load_generation:int;
 mutable msg_target_keeper_name:string option;
 mutable msg_loaded_sources:keeper_chat_sources;
 mutable msg_loaded:entry list;
 mutable msg_loaded_keeper:string option;
 mutable msg_loaded_error:string option;
 mutable msg_loaded_dropped:int;
 mutable msg_memory_error:string option;
 mutable msg_memory_dropped:int;
 mutable msg_older_loading:bool;
 mutable msg_older_cursor:string option;
 mutable msg_older_exist:bool;
 mutable msg_older_error:string option;
 mutable msg_journal_reads_refused:bool;
 mutable msg_journal_unavailable:unit list;
 mutable msg_preparation_details:unit;
 mutable workspace_authority:workspace_authority;
 mutable workspace_read_authority:unit ref;
 server_identity:unit; port:int;
 mutable ready:bool;
}
type message =
 | Workspace_scoped of workspace_authority * unit ref option * message
 | Keeper_chat_history_loaded of Keeper_history_read.t * Keeper_history_read.source * Keeper_history_read.result
 | Keeper_chat_first_page_loaded of Keeper_history_read.t * Keeper_history_read.page_result
type 'a mailed = {ready_at_ns:int64; message:'a}
let collect state =
'''
after_collect = r'''
 history
let fresh () = {
 msg_history_inflight=None;msg_history_load_generation=0;msg_target_keeper_name=Some "a";
 msg_loaded_sources=empty_keeper_chat_sources;msg_loaded=[];msg_loaded_keeper=None;msg_loaded_error=None;msg_loaded_dropped=0;
 msg_memory_error=None;msg_memory_dropped=0;msg_older_loading=false;msg_older_cursor=None;
 msg_older_exist=false;msg_older_error=None;msg_journal_reads_refused=false;
 msg_journal_unavailable=[];msg_preparation_details=();workspace_authority=Workspace_authority 1;
 workspace_read_authority=ref ();server_identity=();port=0;ready=true;
}
module Masc_tui_preparation_details = struct let refresh ~keeper_name:_ () = () end
let launch_keeper_child_content_load ~mode:_ _ ~mailbox:_ ~keeper_name:_ = ()
module Masc_tui_child_content = struct type mode = Audit | Poll end
module Masc_tui_native_tasks = struct type mode = Audit | Poll end
let launch_keeper_native_tasks_load ~mode:_ _ ~mailbox:_ ~keeper_name:_ = ()
let launch_keeper_chat_tool_details_load _ ~mailbox:_ ~keeper_name:_ = ()
let server_authority_ready state = state.ready
let keeper_available_for_new_message _ _ = true
let server_peer_host = "fixture"
let probe_count = ref 0
let workspace_check_sequence state ~mailbox:_ ~authority ~identity:_ ~host:_ ~port:_ =
 let reading = state.workspace_read_authority in
 fun () -> incr probe_count;
  if state.ready && state.workspace_authority=authority && state.workspace_read_authority==reading
  then Ok () else Error "workspace retired"
let current_switch = ref None
module Eio_context = struct let get_switch_opt () = !current_switch end
let refuse_launch = ref false
let fork_workspace_job _ ~sw run =
 if !refuse_launch then failwith "refused launch";
 Eio.Fiber.fork_daemon ~sw (fun () -> run (); `Stop_daemon)
let history_fetch = ref (fun () -> Error "unset history")
let memory_fetch = ref (fun () -> Error "unset memory")
let page_fetch = ref (fun () -> Error(Keeper_chat_history.Page_read_failed "page fixture unavailable"))
module Masc_tui_http = struct
 let fetch_keeper_chat_history_page ~host:_ ~port:_ ~keeper_name:_ ~cursor = assert(cursor=None); !page_fetch ()
 let fetch_keeper_chat_history ~host:_ ~port:_ ~keeper_name:_ = !history_fetch ()
 let fetch_keeper_memory_journal ~host:_ ~port:_ ~keeper_name:_ = !memory_fetch ()
end
let msg_entries_of_history_rows _ _ rows = List.map (fun (row:Keeper_chat_history.row) ->
 {id=row.id;me_role=if row.memory then Message_memory else Message_history}) rows
let journal_source_of_history (row:Keeper_chat_history.row) = Some row.id
let journal_held_keys _ _ = []
let journal_source_fetch_targets ~keeper_name:_ ~held:_ ~unavailable:_ rows = rows
let journal_resume_position _ ~keeper_name:_ _ = ()
let enrich_held_logs_from_rows _ ~keeper_name:_ _ = ()
let merge_paged_history ~paged ~fresh = fresh @ List.filter (fun e -> not(List.exists (fun n -> e.id=n.id) fresh)) paged
let prepend_older_history_page ~older ~held = merge_paged_history ~paged:older ~fresh:held
let forget_session_rows_the_transcript_holds _ _ _ ~fresh:_ = ()
let journal_launches = ref 0
let launch_keeper_chat_journal_loads state ~mailbox:_ ~keeper_name rows =
 assert(state.msg_loaded_keeper=Some keeper_name); journal_launches:= !journal_launches + List.length rows
let launch_current_autonomous_journals _ ~mailbox:_ ~keeper_name:_ = ()
let launch_unavailable_journal_operations _ ~mailbox:_ ~keeper_name:_ = ()
'''
checks = r'''
let drain state =
 List.iter (fun ready -> match ready.message with
 | Workspace_scoped(authority,Some reading,message)
   when state.ready && state.workspace_authority=authority && state.workspace_read_authority==reading -> apply state ~mailbox:() message
 | Workspace_scoped _ -> ()
 | Keeper_chat_history_loaded _ | Keeper_chat_first_page_loaded _ -> failwith "unscoped result") (collect state)
let decoded ~memory id = Ok {Keeper_chat_history.rows=[{id;memory;at=1.}];dropped=0}
let request state = Option.get state.msg_history_inflight
let has state id = List.exists (fun e -> e.id=id) state.msg_loaded
let launch ?(force=false) state = launch_keeper_history_load ~load_file_changes:false ~force state ~mailbox:() ~keeper_name:"a"
let settle_all state = drain state; assert(state.msg_history_inflight=None)
let yield_until predicate = while not(predicate ()) do Eio.Fiber.yield () done
let ordering ~memory_first ~system_history ~empty_memory =
 Eio.Switch.run (fun sw -> current_switch:=Some sw;
  let state=fresh () in
  state.msg_loaded_keeper<-Some "a";state.msg_loaded_sources<-{kcs_history=Some[];kcs_memory=[]};state.msg_older_exist<-true;
  let hp,hu=Eio.Promise.create () and mp,mu=Eio.Promise.create () in
  let hs=ref false and ms=ref false in
  history_fetch:=(fun () -> hs:=true;Eio.Promise.await hp);
  memory_fetch:=(fun () -> ms:=true;Eio.Promise.await mp);
  let probes= !probe_count in
  launch state; let owner=request state in
  yield_until (fun () -> !hs && !ms);
  (* Both actual production GET callbacks started while neither had returned. *)
  assert(!probe_count=probes+2);
  if memory_first then Eio.Promise.resolve mu ((if empty_memory then Ok {Keeper_chat_history.rows=[];dropped=0} else decoded ~memory:true 2))
  else Eio.Promise.resolve hu (decoded ~memory:system_history 1);
  let first=if memory_first then Keeper_history_read.Memory else History in
  (* Taking reserves the slot; it cannot be offered twice or make a poll replace its sibling. *)
  let offered=ref [] in
  yield_until (fun () -> offered:=collect state; !offered<>[]);
  assert(Keeper_history_read.pending owner);assert(collect state=[]);
  launch state;assert(request state==owner);
  List.iter (fun ready -> match ready.message with
   | Workspace_scoped(_,_,message) -> apply state ~mailbox:() message
   | Keeper_chat_history_loaded _ | Keeper_chat_first_page_loaded _ -> assert false) !offered;
  if not(memory_first && empty_memory) then assert(has state (if memory_first then 2 else 1));assert(not(has state (if memory_first then 1 else 2)));
  assert(Keeper_history_read.pending owner);
  assert(not(Keeper_history_read.settle owner first));
  if memory_first then Eio.Promise.resolve hu (decoded ~memory:system_history 1)
  else Eio.Promise.resolve mu ((if empty_memory then Ok {Keeper_chat_history.rows=[];dropped=0} else decoded ~memory:true 2));
  yield_until (fun () -> drain state;state.msg_history_inflight=None);
  assert(has state 1 && has state 2 <> empty_memory);assert(state.msg_older_exist);
  assert(!probe_count=probes+4))
let forced_cold_refresh () =
 Eio.Switch.run(fun sw -> current_switch:=Some sw;
  let state=fresh () in
  let hp,hu=Eio.Promise.create () in
  history_fetch:=(fun () -> Eio.Promise.await hp);memory_fetch:=(fun () -> decoded ~memory:true 11);
  launch state;
  yield_until(fun () -> drain state;has state 11);
  assert(state.msg_loaded_sources.kcs_history=None && not state.msg_older_exist);
  let old=request state in
  history_fetch:=(fun () -> decoded ~memory:true 12);
  launch ~force:true state;assert(request state != old);
  yield_until(fun () -> drain state;state.msg_history_inflight=None);
  assert(has state 11 && has state 12 && state.msg_older_exist);
  Eio.Promise.resolve hu (decoded ~memory:false 13);
  Eio.Fiber.yield ();drain state;assert(not(has state 13)))
let state_cases () =
 let state=fresh () in
 let old=Keeper_history_read.create ~generation:1 ~keeper:"a" ~authority:state.workspace_authority ~reading:state.workspace_read_authority ~first_page:false  in
 state.msg_history_load_generation<-1; state.msg_history_inflight<-Some old;
 Keeper_history_read.publish old History ~ready_at_ns:1L (decoded ~memory:false 1);
 let offered=collect state in
 let newer=Keeper_history_read.create ~generation:2 ~keeper:"a" ~authority:state.workspace_authority ~reading:state.workspace_read_authority ~first_page:false  in
 state.msg_history_load_generation<-2;state.msg_history_inflight<-Some newer;
 List.iter (fun ready -> match ready.message with Workspace_scoped(_,_,msg) -> apply state ~mailbox:() msg | _ -> assert false) offered;
 assert(state.msg_loaded=[] && request state==newer);
 Keeper_history_read.publish old Memory ~ready_at_ns:2L (decoded ~memory:true 2);assert(collect state=[]);
 (* Source failure cannot erase held sibling rows/errors or its own last good data. *)
 state.msg_loaded_keeper<-Some "a";set_keeper_chat_sources state {kcs_history=Some[{id=3;me_role=Message_history}];kcs_memory=[{id=4;me_role=Message_memory}]};
 state.msg_memory_error<-Some "old memory error";
 Keeper_history_read.publish newer History ~ready_at_ns:3L (Error "history refused");drain state;
 assert(has state 3 && has state 4 && state.msg_memory_error=Some "old memory error");
 Keeper_history_read.publish newer Memory ~ready_at_ns:4L (decoded ~memory:true 5);settle_all state;
 assert(has state 3 && has state 5 && not(has state 4));assert(state.msg_loaded_error=Some "history refused" && state.msg_memory_error=None);
 (* A queued old workspace reading is rejected, including an A -> B -> A reading epoch. *)
 let stale=Keeper_history_read.create ~generation:2 ~keeper:"a" ~authority:state.workspace_authority ~reading:state.workspace_read_authority ~first_page:false  in
 state.msg_history_inflight<-Some stale; Keeper_history_read.publish stale History ~ready_at_ns:5L (decoded ~memory:false 6);
 state.workspace_read_authority<-ref ();drain state;assert(not(has state 6));
 (* Generation and selected Keeper remain independent admission checks. *)
 state.msg_history_inflight<-Some stale;Keeper_history_read.publish stale Memory ~ready_at_ns:6L (decoded ~memory:true 7);
 List.iter (fun (source,obs) -> apply state ~mailbox:() (Keeper_chat_history_loaded(stale,source,obs.Keeper_history_read.result))) (Keeper_history_read.take_ready stale);
 assert(has state 7);
 let wrong=Keeper_history_read.create ~generation:1 ~keeper:"a" ~authority:state.workspace_authority ~reading:state.workspace_read_authority ~first_page:false  in
 state.msg_history_inflight<-Some wrong;Keeper_history_read.publish wrong History ~ready_at_ns:7L (decoded ~memory:false 8);drain state;assert(not(has state 8));
 let wrong=Keeper_history_read.create ~generation:2 ~keeper:"b" ~authority:state.workspace_authority ~reading:state.workspace_read_authority ~first_page:false  in
 state.msg_history_inflight<-Some wrong;Keeper_history_read.publish wrong History ~ready_at_ns:8L (decoded ~memory:false 9);drain state;assert(not(has state 9));
 current_switch:=None;let state=fresh () in launch state;settle_all state;
 assert(state.msg_loaded_error=Some "Eio switch is unavailable" && state.msg_memory_error=Some "Eio switch is unavailable")

let first_page_cases () =
 let orders = [[0;1;2];[0;2;1];[1;0;2];[1;2;0];[2;0;1];[2;1;0]] in
 List.iter(fun order -> Eio.Switch.run(fun sw -> current_switch:=Some sw;
  let state=fresh () in
  let started=Array.make 3 false in
  let hp,hu=Eio.Promise.create () and mp,mu=Eio.Promise.create () and pp,pu=Eio.Promise.create () in
  history_fetch:=(fun () -> started.(0)<-true;Eio.Promise.await hp);
  memory_fetch:=(fun () -> started.(1)<-true;Eio.Promise.await mp);
  page_fetch:=(fun () -> started.(2)<-true;Eio.Promise.await pp);
  launch state;
  yield_until(fun () -> Array.for_all Fun.id started);
  assert(state.msg_loaded_sources.kcs_history=None && state.msg_older_loading);
  List.iter(fun source ->
   (match source with
    | 0 -> Eio.Promise.resolve hu (Ok {Keeper_chat_history.rows=[{id=21;memory=false;at=1.};{id=22;memory=true;at=2.}];dropped=0})
    | 1 -> Eio.Promise.resolve mu (decoded ~memory:true 23)
    | 2 -> Eio.Promise.resolve pu (Ok {Keeper_chat_history.decoded={rows=[{id=21;memory=true;at=1.};{id=24;memory=false;at=3.}];dropped=0};has_more=true;next_cursor=Some "opaque-page-cursor"})
    | _ -> assert false);
   yield_until(fun () -> drain state; match source with 0 -> has state 22 | 1 -> has state 23 | 2 -> has state 24 | _ -> false);
   if source=2 then assert(state.msg_older_cursor=Some "opaque-page-cursor" && state.msg_older_exist && not state.msg_older_loading)
  ) order;
  assert(List.for_all(has state)[21;22;23;24]);
  assert(List.length(List.filter(fun entry -> entry.id=21) state.msg_loaded)=1);
  assert((List.find(fun entry -> entry.id=21) state.msg_loaded).me_role=Message_history);
  assert(state.msg_history_inflight=None && state.msg_older_cursor=Some "opaque-page-cursor")
 )) orders;
 (* A page failure stays a page failure regardless of aggregate completion order. *)
 List.iter(fun page_first -> Eio.Switch.run(fun sw -> current_switch:=Some sw;
  let state=fresh () in
  let hp,hu=Eio.Promise.create () and pp,pu=Eio.Promise.create () in
  history_fetch:=(fun () -> Eio.Promise.await hp);memory_fetch:=(fun () -> decoded ~memory:true 30);
  page_fetch:=(fun () -> Eio.Promise.await pp);launch state;
  let history ()=Eio.Promise.resolve hu(decoded ~memory:false 31) in
  let page ()=Eio.Promise.resolve pu(Error(Keeper_chat_history.Page_read_failed "page refusal")) in
  if page_first then (page();yield_until(fun () -> drain state;state.msg_older_error<>None);history())
  else (history();yield_until(fun () -> drain state;has state 31);page());
  yield_until(fun () -> drain state;state.msg_history_inflight=None);
  assert(has state 30 && has state 31 && state.msg_older_error=Some "page refusal" && state.msg_loaded_error=None)
 )) [false;true];
 (* A later explicit page owner can withdraw an already offered first page. *)
 let state=fresh () in
 let req=Keeper_history_read.create ~generation:0 ~keeper:"a" ~authority:state.workspace_authority ~reading:state.workspace_read_authority ~first_page:true in
 state.msg_history_inflight<-Some req;
 Keeper_history_read.publish_page req ~ready_at_ns:1L (Ok {Keeper_chat_history.decoded={rows=[];dropped=0};has_more=true;next_cursor=Some "obsolete"});
 let offered=collect state in assert(List.length offered=1);
 Keeper_history_read.retire_page req; assert(not(Keeper_history_read.page_pending req));
 state.msg_older_cursor<-Some "explicit-owner-cursor";
 List.iter(fun ready -> match ready.message with Workspace_scoped(_,_,msg) -> apply state ~mailbox:() msg | _ -> assert false) offered;
 assert(state.msg_older_cursor=Some "explicit-owner-cursor");
 (* Received empty history is a warm source and must not request a first page. *)
 Eio.Switch.run(fun sw -> current_switch:=Some sw;
  let state=fresh () in state.msg_loaded_keeper<-Some "a";
  set_keeper_chat_sources state {kcs_history=Some[];kcs_memory=[]};
  history_fetch:=(fun () -> decoded ~memory:false 40);memory_fetch:=(fun () -> decoded ~memory:true 41);
  page_fetch:=(fun () -> failwith "warm source unexpectedly requested first page");
  launch state;yield_until(fun () -> drain state;state.msg_history_inflight=None);
  assert(has state 40 && has state 41 && state.msg_older_error=None))
let () =
 Eio_main.run (fun _ -> List.iter(fun memory_first -> List.iter(fun system_history -> List.iter(fun empty_memory ->
 ordering ~memory_first ~system_history ~empty_memory) [false;true]) [false;true]) [false;true];
 forced_cold_refresh ();state_cases ();first_page_cases ();
 Eio.Switch.run(fun sw -> current_switch:=Some sw;refuse_launch:=true;
  let state=fresh () in launch state;settle_all state;refuse_launch:=false;
  assert(Option.is_some state.msg_loaded_error && Option.is_some state.msg_memory_error)));
 Printf.printf "first_page_arrival_orders=6_PASS page_failure_order_independence=PASS explicit_page_retirement=PASS warm_source_no_page=PASS independent_GET_start=PASS arrival_source_combinations=8_PASS cold_memory_force_paging=PASS offered_busy=PASS source_failure_preservation=PASS stale_owner_generation_keeper_workspace=PASS no_switch_refused_launch=PASS\n%!"
'''
with tempfile.TemporaryDirectory(prefix='masc-history-flow-') as directory:
    work = Path(directory)
    (work / 'probe.ml').write_text(header + slots + stubs + collect + after_collect + setter + launch + '\nlet apply state ~mailbox = function\n' + arm + ' | Workspace_scoped _ -> assert false\n' + checks)
    subprocess.run(['ocamlfind', 'ocamlopt', '-thread', '-package', 'eio_main,mtime.clock', '-linkpkg', 'probe.ml', '-o', 'probe'], cwd=work, check=True)
    subprocess.run([str(work / 'probe')], cwd=work, check=True)
