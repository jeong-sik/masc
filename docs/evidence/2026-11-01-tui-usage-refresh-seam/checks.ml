open Masc_tui_types
open Seam
let require label value = if not value then failwith label
let mailbox () = Queue.create ()
let press state key scoped full follow messages =
  handle_key state ~server_peer_host:"localhost" ~http_scoped_refresh_inflight:scoped
    ~http_refresh_inflight:full ~scoped_refresh_followup:follow ~async_messages:messages (Some key)
let successful messages =
  Queue.fold (fun count -> function Http_surface_read_completed (_,Http_scoped_refresh_done _) -> count+1 | _ -> count) 0 messages
let refused messages =
  Queue.fold (fun count -> function Http_surface_read_completed (_,Http_scoped_refresh_failed _) -> count+1 | _ -> count) 0 messages
let key_dispatch key initial expected =
  reset ();let state=create () in state.provider_history_days<-initial;
  let scoped=ref false and full=ref false and follow=ref () and messages=mailbox () in
  press state key scoped full follow messages;
  require "actual key arm must select the requested period" (state.provider_history_days=expected);
  require "actual key arm must dispatch a scoped collector" (Queue.length jobs=1 && !scoped);
  require "actual launch must install Navigation ownership before transport" (Surface_read_order.navigation_count state.http_surface_reads=1);
  drain ();
  (match !calls with
   | [call] ->
       require "actual loader must receive captured selected days" (call.days=expected);
       require "actual loader must receive Navigation request" (Surface_read_order.request_kind call.request=Navigation);
       require "actual key dispatch must request only provider history" (call.needs={nothing with needs_provider_history=true});
       require "actual key arm must forward endpoint" (call.host="localhost" && call.port=state.port)
   | _ -> failwith "actual key arm did not reach the HTTP loader exactly once");
  require "actual collector must complete after two matching identity probes" (!probes=2 && successful messages=1 && refused messages=0);
  require "window change must preserve account and reset reading" (state.usage_scope_id=Some "selected-account"
    && state.provider_history=Provider_history_unread && state.metrics_scroll=0 && state.usage_section=Usage_trend)
let overlap () =
  reset ();let state=create () in
  let initial_needs={nothing with needs_provider_history=true;needs_keeper_usage=true} in
  let reads,old=Surface_read_order.dispatch ~kind:Full ~needs:initial_needs ~started_ns:0L state.http_surface_reads in
  state.http_surface_reads<-reads;
  state.http_refresh_order<-Http_refresh_order.dispatch state.http_refresh_order;
  let generation=state.http_refresh_order in
  let scoped=ref false and full=ref true and follow=ref () and messages=mailbox () in
  press state "w" scoped full follow messages;
  require "overlapping full refresh must share authority generation" (state.http_refresh_order=generation);
  require "new window must supersede only old history" (not (Surface_read_order.owns_dataset state.http_surface_reads old Provider_history_data)
    && Surface_read_order.owns_dataset state.http_surface_reads old Keeper_usage_data);
  full:=false;press state "W" scoped full follow messages;press state "w" scoped full follow messages;
  require "scoped overlap must keep generation" (state.http_refresh_order=generation);
  drain ();
  require "queued collectors must retain dispatch-time days" (List.map (fun call -> call.days) !calls=[1;7;14]);
  require "all overlapping requests must be Navigation in same generation"
    (List.for_all (fun call -> Surface_read_order.request_kind call.request=Navigation && call.ticket=generation) !calls);
  (match !calls with
   | [first;middle;latest] ->
       require "old and ABA data ownership must stay superseded"
         (not (Surface_read_order.owns_dataset state.http_surface_reads first.request Provider_history_data)
          && not (Surface_read_order.owns_dataset state.http_surface_reads middle.request Provider_history_data)
          && Surface_read_order.owns_dataset state.http_surface_reads latest.request Provider_history_data)
   | _ -> failwith "overlap did not dispatch three actual requests");
  require "unrelated full-refresh source must retain ownership" (Surface_read_order.owns_dataset state.http_surface_reads old Keeper_usage_data)
let refusal phase =
  reset ();let state=create () in
  let scoped=ref false and full=ref false and follow=ref () and messages=mailbox () in
  press state "w" scoped full follow messages;
  require "authority scenario must enter actual launch" (Queue.length jobs=1);
  let foreign={identity with sid_base_path="/other";sid_masc_root="/other/.masc"} in
  (match phase with
   | 0 -> state.workspace_authority<-2
   | 1 -> on_probe:=(fun n -> if n=1 then state.workspace_authority<-2)
   | 2 -> Queue.add (Ok foreign) identity_readings
   | 3 -> on_transport:=(fun () -> state.workspace_authority<-2)
   | _ -> Queue.add (Ok identity) identity_readings;Queue.add (Ok foreign) identity_readings);
  drain ();
  require "actual collector must refuse withdrawn authority or foreign identity" (refused messages=1 && successful messages=0);
  require "pre-admission refusal must avoid HTTP datasets" (List.length !calls=(if phase<3 then 0 else 1))
let guarded () =
  reset ();let state=create () in state.usage_telemetry_open<-true;
  press state "w" (ref false) (ref false) (ref ()) (mailbox ());
  require "telemetry guard must not dispatch Usage history" (Queue.is_empty jobs && state.provider_history_days=14)
let synchronous () =
  reset ();Eio_context.switch:=None;let state=create () in
  let scoped=ref false in press state "W" scoped (ref false) (ref ()) (mailbox ());
  require "synchronous actual launch must capture days and finish its request"
    (List.map (fun call -> call.days) !calls=[1] && state.applied=1 && not !scoped
     && Surface_read_order.navigation_count state.http_surface_reads=0)
let () =
  let failures=ref 0 in
  let check label work=try work ();Printf.printf "PASS %s\n%!" label
    with Failure detail -> incr failures;Printf.printf "FAIL %s: %s\n%!" label detail in
  check "actual lowercase w arm and HTTP launch" (fun () -> key_dispatch "w" 14 1);
  check "actual uppercase W arm and HTTP launch" (fun () -> key_dispatch "W" 7 14);
  if Array.length Sys.argv=1 then (
    check "overlapping full/scoped generation and captured ABA periods" overlap;
    List.iter (fun phase -> check (Printf.sprintf "authority refusal %d" phase) (fun () -> refusal phase)) [0;1;2;3;4];
    check "telemetry key guard" guarded;check "synchronous launch cleanup" synchronous);
  if !failures>0 then exit 1
