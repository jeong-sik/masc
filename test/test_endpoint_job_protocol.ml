open Alcotest
module P = Endpoint_job_protocol

let require = function Ok x -> x | Error e -> fail e
let get = function Ok x -> x | Error e -> fail (P.error_to_string e)
let id suffix = P.Id.of_string ("019a0000-0000-7000-8000-0000000000" ^ suffix) |> require
let digest text = P.Sha256.of_string Agent_core_sha256.(digest_string text |> to_hex) |> require
let isolated : P.isolated_preparation =
  {preparation_id=id "04";image_sha256=digest "immutable image";input_manifest_sha256=digest "verified inputs"}
let spec ?(domain=P.Workspace_process) ?(argv=["/bin/echo";"original \255 argument"])
    ?(env=["VALUE","private \255 bytes"]) ?(cwd="/work/checkout") ?(remote_root="/work")
    ?(stdin="original\000stdin\255") ?(mode=Exec_ssh_protocol.Effect) ?(network_policy_sha256=None) () =
  P.spec ~domain ~argv ~env ~cwd ~remote_root ~stdin ~mode ~network_policy_sha256
let binding ?(backend=P.Remote_ssh) ?(endpoint_incarnation=id "01") ?(boot_id=id "02")
    ?(workspace_id=id "03") ?(keeper_name="keeper-original") ?(operation_id=id "05")
    ?(invocation_sha256=digest "original invocation") spec =
  P.binding ~route:{backend;endpoint_incarnation;boot_id} ~owner:{workspace_id;keeper_name}
    ~operation_id ~invocation_sha256 ~spec_sha256:(P.spec_sha256 spec) |> require
let requests binding spec : P.request list =
  [Start {binding;spec};Inspect binding;
   Read_output {binding;stream=Stdout;offset=0L;max_bytes=4096};Cancel binding;
   Release {binding;result_sha256=digest "original result manifest"}]
let responses binding : P.response list =
  let observations : P.response list =
  [Status {binding;revision=0L;phase=Queued;cancel_requested=false;result=Result_pending;stdout=Growing 0L;stderr=Growing 0L};
   Status {binding;revision=1L;phase=Starting;cancel_requested=true;result=Result_pending;stdout=Growing 0L;stderr=Growing 0L};
   Status {binding;revision=2L;phase=Running;cancel_requested=true;result=Result_pending;stdout=Growing 4L;stderr=Growing 0L};
   Status {binding;revision=3L;phase=Finished (Exited 0);cancel_requested=false;result=Result_pending;
     stdout=Sealed {byte_length=4L;sha256=digest "data"};stderr=Growing 0L};
   Status {binding;revision=3L;phase=Finished (Signaled 15);cancel_requested=true;result=Result_pending;
     stdout=Growing 4L;stderr=Sealed {byte_length=0L;sha256=digest ""}};
   Status {binding;revision=4L;phase=Finished (Exited 0);cancel_requested=false;
     result=Result_ready (digest "original result manifest");
     stdout=Sealed {byte_length=4L;sha256=digest "data"};
     stderr=Sealed {byte_length=0L;sha256=digest ""}};
   Status {binding;revision=2L;phase=Not_started Cancelled_before_activation;
     cancel_requested=true;result=Result_pending;stdout=Growing 0L;stderr=Growing 0L};
   Status {binding;revision=3L;phase=Not_started Launch_rejected;
     cancel_requested=false;result=Result_pending;
     stdout=Sealed {byte_length=0L;sha256=digest ""};stderr=Growing 0L};
   Status {binding;revision=4L;phase=Not_started Cancelled_before_activation;
     cancel_requested=true;result=Result_ready (digest "original non-start result manifest");
     stdout=Sealed {byte_length=0L;sha256=digest ""};stderr=Sealed {byte_length=0L;sha256=digest ""}};
   Output {binding;revision=3L;stream=Stdout;offset=0L;data="data";
     extent=Sealed {byte_length=4L;sha256=digest "data"}};
   Output {binding;revision=2L;stream=Stderr;offset=9007199254740993L;data="\000\255";
     extent=Growing 9007199254740995L};
   Released {binding;revision=4L;result_sha256=digest "original result manifest"}] in
  observations @ List.map (fun reason -> P.Refused {binding;reason})
      P.[Unsupported;Unauthenticated;Owner_mismatch;Request_conflict;Endpoint_replaced;Admission_refused;Release_refused]
  @ List.map (fun reason -> P.Held {binding;reason})
      P.[Registry_unavailable;Supervisor_unavailable;Operation_not_found;Output_unavailable Stdout;Output_unavailable Stderr]

let test_exact_bytes_and_routes () =
  List.iter (fun backend -> List.iter (fun domain ->
    List.iter (fun mode -> List.iter (fun network_policy_sha256 ->
      let s = spec ~domain ~mode ~network_policy_sha256 () |> require in
      let b = binding ~backend s in
      List.iter (fun request ->
        let wire = P.request_to_json request |> get |> Yojson.Safe.to_string in
        let decoded = Yojson.Safe.from_string wire |> P.request_of_json |> get in
        check bool "full original request bytes and identity survive JSON transport" true (request=decoded))
        (requests b s);
      List.iter (fun response ->
        let wire = P.response_to_json response |> get |> Yojson.Safe.to_string in
        let decoded = Yojson.Safe.from_string wire |> P.response_of_json |> get in
        check bool "typed observation, exact offsets and retained bytes survive transport" true (response=decoded))
        (responses b)) [None;Some (digest "frozen network policy")])
      Exec_ssh_protocol.[Effect;Observe;Guest_local])
      P.[Workspace_process;Isolated_job isolated])
    P.[Apple_container;Microsandbox;Nerdctl_kata;Remote_ssh]

(* Apply malformed object mutations at every actual nested object, preserving
   the surrounding valid envelope. Unknown/duplicate/missing fields may never
   be silently accepted by a selector, optional default or inner decoder. *)
let rec hostile_objects value =
  match value with
  | `Assoc fields ->
    let here = `Assoc (("PRIVATE_SECRET_KEY",`String "private payload")::fields)
      :: List.concat_map (fun (key,value) ->
           [`Assoc ((key,value)::fields);`Assoc (List.remove_assoc key fields)]) fields in
    here @ List.concat_map (fun (key,child) -> List.map (fun replacement ->
      `Assoc (List.map (fun (k,v) -> if k=key then k,replacement else k,v) fields))
      (hostile_objects child)) fields
  | `List values -> List.concat (List.mapi (fun index child -> List.map (fun replacement ->
      `List (List.mapi (fun i v -> if i=index then replacement else v) values))
      (hostile_objects child)) values)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> []

let test_closed_nested_objects () =
  let s = spec ~domain:(P.Isolated_job isolated) () |> require in
  let b = binding s in
  let reject decode wire = List.iter (fun hostile ->
    match decode hostile with
    | Ok _ -> fail "malformed nested object decoded"
    | Error error -> check bool "diagnostics do not expose unknown field or payload secrets" false
        (let message=P.error_to_string error in
         let contains needle =
           let rec loop i = i+String.length needle<=String.length message &&
             (String.sub message i (String.length needle)=needle || loop (i+1)) in loop 0 in
         contains "PRIVATE_SECRET_KEY" || contains "private payload")) (hostile_objects wire) in
  List.iter (fun request -> reject P.request_of_json (P.request_to_json request |> get)) (requests b s);
  List.iter (fun response -> reject P.response_of_json (P.response_to_json response |> get)) (responses b)

let test_spec_changes_cannot_borrow_original_binding () =
  let original = spec () |> require in
  let b = binding original in
  let changed =
    [spec ~argv:["/bin/echo";"changed"] ();
     spec ~env:["VALUE","changed"] ();
     spec ~cwd:"/work/different" ();spec ~remote_root:"/different" ();
     spec ~stdin:"changed" ();spec ~mode:Exec_ssh_protocol.Guest_local ();
     spec ~mode:Exec_ssh_protocol.Observe ();
     spec ~network_policy_sha256:(Some (digest "new policy")) ();
     spec ~domain:(P.Isolated_job isolated) ();
     spec ~domain:(P.Isolated_job {isolated with input_manifest_sha256=digest "other input"}) ()] in
  List.iter (fun changed ->
    let spec = changed |> require in
    check bool "every changed launch/input/isolation/network fact changes its binding" false
      (P.spec_sha256 original=P.spec_sha256 spec);
    check bool "changed spec cannot encode under a previous operation binding" true
      (P.request_to_json (P.Start {binding=b;spec})=Error P.Spec_digest_mismatch);
    let changed_wire = P.request_to_json (P.Start {binding=binding spec;spec}) |> get in
    let original_wire = P.request_to_json (P.Start {binding=b;spec=original}) |> get in
    let old_binding = Yojson.Safe.Util.member "binding" original_wire in
    let hostile = match changed_wire with `Assoc fields ->
      `Assoc (List.map (fun (k,v) -> k,if k="binding" then old_binding else v) fields)
      | _ -> fail "expected object" in
    check bool "changed wire spec cannot decode under original binding" true
      (P.request_of_json hostile=Error P.Spec_digest_mismatch)) changed;
  let sealed = spec ~domain:(P.Isolated_job isolated) () |> require in
  List.iter (fun domain ->
    let changed = spec ~domain () |> require in
    check bool "each isolated preparation/image/input pin is included" false
      (P.spec_sha256 sealed=P.spec_sha256 changed))
    [P.Isolated_job {isolated with preparation_id=id "06"};
     P.Isolated_job {isolated with image_sha256=digest "other image"};
     P.Isolated_job {isolated with input_manifest_sha256=digest "other inputs"}]

let test_response_cannot_retarget_control () =
  let s=spec () |> require in
  let b=binding s in
  let others=[binding ~backend:P.Apple_container s;binding ~endpoint_incarnation:(id "06") s;
    binding ~boot_id:(id "06") s;binding ~workspace_id:(id "06") s;
    binding ~keeper_name:"other keeper" s;binding ~operation_id:(id "06") s;
    binding ~invocation_sha256:(digest "other original call") s;
    binding (spec ~stdin:"changed exact input" () |> require)] in
  List.iter (fun other -> List.iter (fun response ->
    check bool "another owner/route/boot/call cannot provide an observation or hold" true
      (P.check_response ~minimum_revision:0L ~request:(P.Cancel b) response=Error P.Binding_mismatch))
      (responses other)) others;
  let wire=P.request_to_json (P.Cancel b) |> get in
  List.iter (fun name ->
    let hostile=match wire with `Assoc fields -> `Assoc ((name,`Int 99)::fields)
      | _ -> fail "expected object" in
    check bool "a PID, group or request-supplied control path never grants signal authority" true
      (Result.is_error (P.request_of_json hostile))) ["pid";"pgid";"path";"control_root"]

let test_output_ranges_and_seals () =
  let s=spec () |> require in let b=binding s in
  let read : P.request=P.Read_output {binding=b;stream=Stdout;offset=0L;max_bytes=2} in
  let output ?(revision=2L) ?(stream=P.Stdout) ?(offset=0L) ?(data="ab") ?(extent=P.Growing 4L) () : P.response =
    Output {binding=b;revision;stream;offset;data;extent} in
  check bool "an exact growing chunk is accepted" true
    (P.check_response ~minimum_revision:2L ~request:read (output ())=Ok ());
  List.iter (fun response -> check bool "wrong stream/offset/capacity is refused" true
    (P.check_response ~minimum_revision:2L ~request:read response=Error P.Output_range_mismatch))
    [output ~stream:Stderr ();output ~offset:1L ();output ~data:"abc" ()];
  check bool "offset arithmetic never wraps at Int64.max_int" true
    (P.response_to_json (output ~offset:Int64.max_int ~data:"x" ~extent:(Growing Int64.max_int) ())
      =Error P.Output_range_mismatch);
  check bool "an EOF-sized complete chunk must match its sealed content digest" true
    (P.response_to_json (output ~extent:(Sealed {byte_length=2L;sha256=digest "different"}) ())
      =Error P.Output_digest_mismatch);
  let complete=output ~extent:(Sealed {byte_length=2L;sha256=digest "ab"}) () in
  check bool "exact complete retained bytes match the original seal" true
    (P.check_response ~minimum_revision:2L ~request:read complete=Ok ());
  check bool "output can't exceed its known growing extent" true
    (Result.is_error (P.response_to_json (output ~extent:(Growing 1L) ())));
  check bool "a negative request offset is never coerced" true
    (Result.is_error (P.request_to_json (Read_output {binding=b;stream=Stdout;offset=(-1L);max_bytes=1})))

let test_revisions_response_kind_and_release () =
  let s=spec () |> require in let b=binding s in
  let response : P.response=P.Status {binding=b;revision=2L;phase=Running;
    cancel_requested=true;result=Result_pending;stdout=Growing 0L;stderr=Growing 0L} in
  check bool "a delayed earlier status cannot roll back an accepted revision" true
    (P.check_response ~minimum_revision:3L ~request:(P.Inspect b) response=Error P.Response_revision_stale);
  let result_sha256=digest "original terminal result" in
  let release=P.Release {binding=b;result_sha256} in
  check bool "a generic status cannot certify resource release" true
    (P.check_response ~minimum_revision:2L ~request:release response=Error P.Response_kind_mismatch);
  check bool "release is bound to exact original terminal result" true
    (P.check_response ~minimum_revision:2L ~request:release
      (P.Released {binding=b;revision=3L;result_sha256=digest "other result"})=Error P.Binding_mismatch);
  check bool "an exact release receipt is accepted" true
    (P.check_response ~minimum_revision:2L ~request:release
      (P.Released {binding=b;revision=3L;result_sha256})=Ok ());
  List.iter (fun reason -> check bool "unavailable/missing authority remains a hold without state rollback" true
    (P.check_response ~minimum_revision:3L ~request:(P.Inspect b) (P.Held {binding=b;reason})=Ok ()))
    P.[Registry_unavailable;Supervisor_unavailable;Operation_not_found;Output_unavailable Stdout]

let test_structural_refusals () =
  List.iter (fun invalid -> check bool "invalid exec input is refused before a control request exists" true
    (Result.is_error invalid))
    [spec ~argv:[] ();spec ~argv:[""] ();spec ~argv:["/bin/echo";"\000"] ();
     spec ~env:["VALUE","one";"VALUE","two"] ();spec ~env:["BAD=NAME","value"] ();
     spec ~env:["VALUE","\000"] ();spec ~cwd:"relative" ();spec ~remote_root:"" ()];
  let s=spec () |> require in let b=binding s in
  let wire=P.request_to_json (P.Start {binding=b;spec=s}) |> get in
  let set name value=match wire with `Assoc fields ->
    `Assoc (List.map (fun (k,v) -> k,if k=name then value else v) fields) | _ -> fail "expected object" in
  List.iter (fun hostile -> check bool "version, operation and protocol are closed" true
    (Result.is_error (P.request_of_json hostile)))
    [set "version" (`Int 2);set "version" (`String "1");set "operation" (`String "kill_pid");
     set "protocol" (`String "synchronous_exec")];
  let status : P.response=P.Status {binding=b;revision=0L;phase=Queued;cancel_requested=false;result=Result_pending;
    stdout=Sealed {byte_length=0L;sha256=digest ""};stderr=Growing 0L} in
  check bool "queued jobs cannot claim previously sealed output" true (Result.is_error (P.response_to_json status));
  let ready : P.response = Status {binding=b;revision=3L;phase=Finished (Exited 0);
    cancel_requested=false;result=Result_ready (digest "not durably complete");
    stdout=Growing 0L;stderr=Sealed {byte_length=0L;sha256=digest ""}} in
  check bool "a process exit with incomplete streams cannot certify a releasable result" true
    (Result.is_error (P.response_to_json ready))

let test_non_start_terminal () =
  let s=spec () |> require in let b=binding s in
  let empty : P.extent=P.Sealed {byte_length=0L;sha256=digest ""} in
  let terminal ?(reason=P.Cancelled_before_activation) ?(cancel_requested=true)
      ?(stdout=empty) ?(stderr=empty) ?(result=P.Result_pending) () : P.response =
    Status {binding=b;revision=3L;phase=Not_started reason;cancel_requested;result;stdout;stderr} in
  let request=P.Inspect b in
  List.iter (fun reason ->
    let response=terminal ~reason () in
    let wire=P.response_to_json response |> get in
    check bool "non-start is terminal without a fabricated exit code" true
      (P.response_of_json wire=Ok response);
    check bool "original terminal status remains bound to its request" true
      (P.check_response ~minimum_revision:3L ~request response=Ok ());
    let ready=terminal ~reason ~result:(Result_ready (digest "protected non-start result")) () in
    check bool "durably empty streams and manifest can settle a non-start" true
      (P.check_response ~minimum_revision:3L ~request ready=Ok ());
    let pending=terminal ~reason ~stdout:(Growing 0L) () in
    check bool "empty output may remain unsealed after non-start" true
      (P.check_response ~minimum_revision:3L ~request pending=Ok ());
    let wire=match wire with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,
          if key="phase" then `Assoc ["state",`String "not_started";
                                     "reason",`String "invented_failure"] else value) fields)
      | _ -> fail "expected status object" in
    check bool "unknown non-start reason never becomes cancellation or exit" true
      (Result.is_error (P.response_of_json wire)))
    P.[Cancelled_before_activation;Launch_rejected];
  List.iter (fun response ->
    check bool "non-start cannot invent output or skip cancellation/sealing authority" true
      (Result.is_error (P.response_to_json response)))
    [terminal ~cancel_requested:false ();
     terminal ~stdout:(Growing 1L) ();
     terminal ~stderr:(Sealed {byte_length=1L;sha256=digest "x"}) ();
     terminal ~stdout:(Sealed {byte_length=0L;sha256=digest "non-empty bytes"}) ();
     terminal ~stdout:(Growing 0L) ~result:(Result_ready (digest "unsealed result")) ()];
  check bool "launch rejection does not fabricate a cancellation intent" true
    (P.check_response ~minimum_revision:3L ~request
       (terminal ~reason:Launch_rejected ~cancel_requested:false ())=Ok ());
  let wire=P.response_to_json (terminal ()) |> get in
  let extra_exit=match wire with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,
        if key="phase" then `Assoc ["state",`String "not_started";
           "reason",`String "cancelled_before_activation";"code",`String "125"] else value) fields)
    | _ -> fail "expected status object" in
  check bool "bootstrap exit code cannot be smuggled into non-start" true
    (Result.is_error (P.response_of_json extra_exit))

let () = run "endpoint job protocol"
  ["protected control boundary",[
    test_case "original binary bytes, domains, routes and exact integer offsets" `Quick test_exact_bytes_and_routes;
    test_case "every nested object rejects unknown, duplicate and missing fields" `Quick test_closed_nested_objects;
    test_case "changed payload or isolation pins cannot borrow an original binding" `Quick test_spec_changes_cannot_borrow_original_binding;
    test_case "control responses cannot cross owner, route, boot, call or process authority" `Quick test_response_cannot_retarget_control;
    test_case "output read ranges and complete seals remain exact" `Quick test_output_ranges_and_seals;
    test_case "stale response, operation kind and result release remain distinct" `Quick test_revisions_response_kind_and_release;
    test_case "invalid exec, version and lifecycle claims refuse explicitly" `Quick test_structural_refusals;
    test_case "non-start settles without fabricated exit, output or result" `Quick test_non_start_terminal]]
