(* Real scheduler/submission sources; preparation and socket ports are fixtures. *)
let pool_checks=ref 0
let pool_check label condition =
 incr pool_checks; if not condition then failwith label

let route_request target =
 let request=Httpun.Request.create
   ~headers:(Httpun.Headers.of_list ["authorization","Bearer admin"]) `GET target in
 let response={Http_reqd.status=`Internal_server_error;body="";headers=[];request} in
 let routes=Server_diagnostics_memprof.register_counter_routes [] in
 let handler=List.assoc (Uri.path(Uri.of_string target)) routes in
 handler request response;response

exception Cancel_diagnostic_fixture

let native_pool_checks () =
 let module P=Alloc_profile in
 let module D=Server_diagnostics_memprof in
 P.For_testing.reset ();
 ignore(P.For_testing.observe_alloc ~key:"operator-native-fixture" ~n_samples:1);
 (* Match actual server startup: the worker domains inherit this profile. *)
 P.start ~sampling_rate:0.001;
 Fun.protect ~finally:(fun ()->
   Pool_wait.hook:=(fun ()->());
   Http_server_eio.Response.prepare_hook:=(fun ()->());
   P.stop ();P.For_testing.reset ()) (fun ()->
 Eio_main.run @@ fun env ->
 Eio.Switch.run @@ fun sw ->
 let pool=Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
 Executor_pool_ref.For_testing.with_pool pool @@ fun ()->
 let main=(Domain.self ():>int) in
 let before=P.counter_snapshot () in
 pool_check "request domain samples" before.sampling;
 let ready=Atomic.make false and release=Atomic.make false in
 Pool_wait.hook:=(fun ()->
   Atomic.set ready true;
   while not(Atomic.get release) do Domain.cpu_relax () done);
 let response=Eio.Fiber.fork_promise ~sw (fun ()->route_request D.counters_path) in
 let rec await_worker () =
   if Atomic.get ready then ()
   else if Eio.Promise.is_resolved response then failwith "response never entered CPU worker"
   else (Eio.Fiber.yield ();await_worker ()) in
 await_worker ();
 pool_check "main domain progressed while CPU worker held a pure loop" (not(Eio.Promise.is_resolved response));
 Atomic.set release true;
 let response=Eio.Promise.await_exn response in
 Pool_wait.hook:=(fun ()->());
 pool_check "pooled response succeeded" (response.status=`OK);
 let open Yojson.Safe.Util in
 let json=Yojson.Safe.from_string response.body in
 pool_check "worker observes inherited active sampler" (json |>member "sampling" |>to_bool);
 pool_check "worker retained epoch and rate" (memprof_identity_query json=
   ["runtime_instance_id",[Build_identity.runtime_instance_id];
    "epoch",[string_of_int before.identity.epoch];"sampling_rate",["0.001"]]);
 pool_check "producer and encoder each entered CPU-weight work"
   (List.length !Pool_wait.entries=2 && List.for_all(fun(domain,weight)->domain<>main && weight=1.) !Pool_wait.entries);
 pool_check "actual CPU response body prepares off request domain with inherited sampler"
   (match !Http_server_eio.Response.prepared with [(domain,true)]->domain<>main|_->false);
 pool_check "success preserves no-store" (List.mem ("cache-control","no-store") response.headers);
 pool_check "actual CPU response writes on request domain" (!Http_reqd.write_domains=[main]);
 let guarded=Uri.to_string(Uri.make ~path:D.counters_path ~query:
   ["expected_base_path",["/fixture"];"expected_masc_root",["/fixture/.masc"]] ()) in
 let admitted=route_request guarded in
 pool_check "pooled response preserves admitted workspace header"
   (admitted.status=`OK && List.mem Auth_ports.Workspace.read_precondition_admission_header admitted.headers
    && List.mem("cache-control","no-store") admitted.headers);
 let targets=[D.counters_path^"?unsupported=value";
   Uri.to_string(Uri.make ~path:D.stacks_path
     ~query:(memprof_identity_query json@["id",["1"]]) ())] in
 List.iter(fun target->
   let response=route_request target in
   pool_check "pooled error/selected-stack status" (response.status=`Bad_request || response.status=`OK);
   pool_check "pooled error/selected-stack no-store" (List.mem("cache-control","no-store") response.headers)) targets;
 (* Cancellation arrives after encoding enters, and cleanup is deliberately held. *)
 let entered,entered_u=Eio.Promise.create () in
 let cleanup,cleanup_u=Eio.Promise.create () in
 let cleanup_release,cleanup_release_u=Eio.Promise.create () in
 let owner,owner_u=Eio.Promise.create () in
 let cleaned=Atomic.make false and calls=Atomic.make 0 in
 Http_server_eio.Response.prepare_hook:=(fun ()->
   ignore(Atomic.fetch_and_add calls 1);
   Eio.Switch.run(fun worker_sw->
     Eio.Switch.on_release worker_sw (fun ()->
       Eio.Promise.resolve cleanup_u ();
       Eio.Promise.await cleanup_release;Atomic.set cleaned true);
     Eio.Promise.resolve entered_u ();Eio.Fiber.await_cancel ()));
 let response_port=ref None in
 let cancelled=Eio.Fiber.fork_promise ~sw (fun ()->
   match Eio.Switch.run(fun owner_sw->
     Eio.Promise.resolve owner_u owner_sw;
     let request=Httpun.Request.create ~headers:(Httpun.Headers.of_list
       ["authorization","Bearer admin"]) `GET D.counters_path in
     let response={Http_reqd.status=`Internal_server_error;body="";headers=[];request} in
     response_port:=Some response;
     let handler=List.assoc D.counters_path (D.register_counter_routes []) in
     Http_server_eio.Response.with_scoped_headers ["x-native-fixture","outer"] (fun ()->handler request response)) with
   | ()->failwith "cancelled diagnostic returned normally"
   | exception Cancel_diagnostic_fixture->()) in
 Eio.Promise.await entered;
 Eio.Switch.fail (Eio.Promise.await owner) Cancel_diagnostic_fixture;
 Eio.Promise.await cleanup;
 pool_check "request cancellation waits for actual entered worker cleanup" (not(Eio.Promise.is_resolved cancelled));
 Eio.Promise.resolve cleanup_release_u ();
 Eio.Promise.await_exn cancelled;
 pool_check "worker cleanup joined before cancellation returned" (Atomic.get cleaned);
 pool_check "encoder invoked once without replay" (Atomic.get calls=1);
 pool_check "cancelled response was not written" (match !response_port with Some response->response.body=""|None->false);
 pool_check "request scope restored after cancellation" (Http_server_eio.Response.scoped_headers ()=[]);
 Http_server_eio.Response.prepare_hook:=(fun ()->());
 pool_check "same pool answers after cancellation" ((route_request D.counters_path).status=`OK))
