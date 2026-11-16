
let assertions=ref 0
let expect label yes=incr assertions;if not yes then failwith label
let measure label count f =
 Gc.full_major ();
 let allocated=Gc.allocated_bytes () and cpu=Sys.time () in
 for _=1 to count do ignore(Sys.opaque_identity(f ())) done;
 `Assoc ["label",`String label;"iterations",`Int count;
   "cpu_s",`Float(Sys.time ()-.cpu);"allocated_bytes",`Float(Gc.allocated_bytes ()-.allocated)]

let auth_requests () =
 let module D=Server_diagnostics_memprof in
 let module P=Alloc_profile in
 with_memprof_fixture @@ fun () ->
 let initial=match D.counters_json ~query:[] with Ok j->j|Error _->failwith "capture" in
 let identity=memprof_identity_query initial in
 let paths=[D.counters_path;Uri.to_string(Uri.make ~path:D.stacks_path ~query:(identity@["id",["1"]]) ())] in
 let routes=D.register_counter_routes [] in
 let dispatch ?token target =
  let headers=Httpun.Headers.of_list (match token with None->[]|Some token->["authorization","Bearer "^token]) in
  let request=Httpun.Request.create ~headers `GET target in
  let response={Http_server_eio.status=`Internal_server_error;body="";headers=[]} in
  let handler=List.assoc (Uri.path(Uri.of_string target)) routes in
  handler request response;response in
 List.iter (fun path ->
  List.iter (fun (token,status) ->
    let before=List.length !Auth_ports.quota_calls in
    let response=dispatch ?token path in
    expect "actual token authorizer role/status" (Httpun.Status.to_code response.status=status);
    if status=200 then begin
      expect "uncached numeric diagnostic" (List.mem ("cache-control","no-store") response.headers);
      expect "GET used actual read quota classification" (List.length !Auth_ports.quota_calls=before+1
        && List.hd !Auth_ports.quota_calls=Auth_ports.Exempt_observation)
    end else expect "refused credentials do not reach quota or handler" (List.length !Auth_ports.quota_calls=before))
    [None,401;Some "bad",401;Some "worker",403;Some "admin",200];
  let uri=Uri.of_string path in
  let guarded base root=Uri.to_string(Uri.with_query uri (Uri.query uri@
    ["expected_base_path",[base];"expected_masc_root",[root]])) in
  let matching=dispatch ~token:"admin" (guarded "/fixture" "/fixture/.masc") in
  expect "matching query workspace accepted" (matching.status=`OK);
  expect "workspace admission header survives diagnostic no-store scope"
    (List.mem Auth_ports.Workspace.read_precondition_admission_header matching.headers);
  expect "wrong query workspace refused" ((dispatch ~token:"admin" (guarded "/other" "/other/.masc")).status=`Conflict);
  expect "malformed query workspace refused" ((dispatch ~token:"admin" (Uri.to_string(Uri.with_query uri
    (Uri.query uri@["expected_base_path",["/fixture"]])))).status=`Bad_request)) paths;
 let old_epoch=(P.counter_snapshot ()).identity.epoch in
 P.For_testing.reset ();
 expect "epoch advances independently of process identity" ((P.counter_snapshot ()).identity.epoch<>old_epoch)

let () =
 test_memprof_counter_wire_and_selective_stacks ();
 test_memprof_query_identity_refusals ();
 auth_requests ();
 let module B=Baseline_alloc_profile in
 let module P=Alloc_profile in
 B.For_testing.reset (); P.For_testing.reset ();
 B.For_testing.set_sampling_rate 0.01;P.For_testing.set_sampling_rate 0.01;
 for index=1 to 3000 do
  let key=Printf.sprintf "fixture-%04d\n%s\n%s\n%s\n%s\n%s\n" index
    (String.make 100 'a') (String.make 100 'b') (String.make 100 'c')
    (String.make 100 'd') (String.make 100 'e') in
  let b=B.For_testing.observe_alloc_on_starting_domain ~key ~n_samples:index
  and c=P.For_testing.observe_alloc_on_starting_domain ~key ~n_samples:index in
  B.For_testing.observe_promote b; P.For_testing.observe_promote c
 done;
 let before=B.report_to_yojson(B.report ~top:30) in
 let after=P.report_to_yojson(P.report ~top:30) in
 expect "default JSON exact parity including key set/row order/values" (before=after);
 let snapshot=P.counter_snapshot () in
 let sample_sum=List.fold_left(fun total (row:P.site_counters)->total+row.counts.allocated_samples) 0 snapshot.counters in
 expect "all rows add up to retained allocation total" (sample_sum=snapshot.totals.allocated_samples);
 expect "all3000 sites returned" (List.length snapshot.counters=3000);
 let full ()=P.report_to_yojson(P.report ~top:(P.max_sites+1)) |>Yojson.Safe.to_string in
 let compact ()=match Server_diagnostics_memprof.counters_json ~query:[] with
  | Ok json->Yojson.Safe.to_string json|Error _->failwith "compact capture" in
 let full_bytes=String.length(full ()) and compact_bytes=String.length(compact ()) in
 let picked=List.filteri(fun i _->i<3) snapshot.counters |>List.map(fun(row:P.site_counters)->row.id) in
 let stacks ()=P.callstacks ~expected:snapshot.identity picked in
 expect "selective lookup returns only requested keys" (match stacks () with Ok xs->List.length xs=3|Error _->false);
 let measurements=[measure "full_existing_report_and_json3000" 3 full;
  measure "compact_counters_and_json3000" 3 compact;
  measure "selected3_stack_lookup3000" 3 stacks] in
 Printf.printf "%s\n" (Yojson.Safe.to_string(`Assoc[
  "checks",`Int !assertions;"pure_api_test_bodies_passed",`Int 2;
  "full_payload_bytes",`Int full_bytes;"compact_payload_bytes",`Int compact_bytes;
  "measurements",`List measurements]));
 B.For_testing.reset ();P.For_testing.reset ()
