module O = Masc.Exact_lane_slot_observation
module R = Masc.Exact_lane_run_registry
module E = Agent_core.Exact_output

let owner = Runtime_schema.Builtin Standalone_lane.Librarian
let foreign = Runtime_schema.Builtin Standalone_lane.Board_attention

let binding_for base_url =
  let catalog = Printf.sprintf {|[[providers]]
id="fixture"
kind="openai_compat"
capabilities_base="models_only"
base_url="%s"
request_path="/v1/chat/completions"
auth="none"
[[models]]
model_id="model"
provider_name="fixture"
max_context_tokens=8192
max_output_tokens=1024
[[targets]]
id="A"
provider_ref="fixture"
model_id="model"
connect_timeout_s=30.0
body_timeout_s=30.0
|} base_url in
  let snapshot = match E.load_resolver_snapshot
      ~catalog:(E.Full_replacement {source="owned slot grouping";contents=catalog}) () with
    | Ok value -> value | Error _ -> failwith "owned catalog rejected"
  in
  match E.admit_target_ref snapshot "A" with
  | Ok admitted -> E.admitted_target_binding admitted
  | Error _ -> failwith "owned target rejected"

let binding = binding_for "https://fixture.invalid"
let ignored_binding = binding_for "https://ignored.invalid"

let execution_failed = O.Execution_failed (Masc.Keeper_exact_walk_failure.api_observation
    (E.Provider_response_refused {http_status=429;refusal=E.Rate_limited;retry_after_s=None}))

let outcome index = match index mod 5 with
  | 0 -> O.Accepted
  | 1 -> O.Semantic_rejected
  | 2 -> O.Admission_rejected Preparation_failed
  | 3 -> O.Unresolved
  | _ -> execution_failed

let observation ~slot_id index =
  let selected_owner = if index mod 11 = 0 then foreign else owner in
  let at = float_of_int (index mod 7) in
  let outcome = outcome index in
  let value =
    if index mod 3 = 0 then
      O.cli ~slot_id ~started_at:(if index mod 5 = 0 then None else Some at)
        ~finished_at:(if index mod 5 = 0 then None else Some (at +. 1.))
        ~generation_dispatched:(index mod 5 <> 0) ~outcome
    else
      let json = `Assoc [
        "slot_id",`String slot_id;"lane_key",`String "librarian_exact";
        "binding",O.binding_to_yojson (O.Http {provider_id=Some "fixture";model_id="model";
          provider_kind="openai_compat";endpoint="https://original.invalid/v1/chat/completions"});
        "call_id",`String ("call-"^slot_id);"flow_id",`String "owned-flow";
        "visit_ordinal",`Int (index + 1);
        "plan_fingerprint",`String (String.make 64 'a');"request_body_sha256",`String (String.make 64 'b');
        "catalog_generation",`String (String.make 64 'c');"catalog_evidence",`String (String.make 64 'd');
        "target_identity",`String (String.make 64 'e');"phase",O.phase_to_yojson Terminal;
        "generation_dispatched",`Bool true;"started_at",`Float at;"finished_at",`Float (at +. 1.);
        "outcome",O.outcome_to_yojson outcome]
      in
      match O.of_yojson json with Ok value -> value | Error error -> failwith error
  in
  O.with_owner selected_owner value

type case =
  { declared_http : string list
  ; declared_cli : string list
  ; current_http : (string * E.binding_observation) list
  ; runs : R.run list
  }

let make_case ~slots ~runs ~visits ~seed ~foreign_only =
  let ids = List.init slots (fun index -> Printf.sprintf "slot-%04d" index) in
  let declared_http = ids @ (if seed mod 2 = 0 then ids else []) in
  let declared_cli = List.filteri (fun index _ -> index mod 2 = 0) ids in
  let current_http = List.map (fun id -> id,binding) ids
    @ List.map (fun id -> id,ignored_binding) ids in
  let runs = List.init runs (fun run_index ->
      let observations = List.init visits (fun index ->
          let serial = seed + run_index * visits + index in
          let slot_id = Printf.sprintf "slot-%04d" (serial mod (max 1 slots)) in
          let value = observation ~slot_id serial in
          if foreign_only then O.with_owner foreign value else value)
      in
      { R.run_id = Printf.sprintf "run-%04d" (run_index mod 7)
      ; lane = R.Librarian;actor="owned";started_at=float_of_int (1000 - run_index)
      ; input=R.Exact_input `Null
      ; status=R.Completed {outcome=R.Succeeded;origin=R.Producer;elapsed_s=Some 1.;output=`Null;selected_slot=None;usage=None}
      ; slot_observations=(if run_index mod 17 = 16 then Some (Error "owned unavailable")
          else if run_index mod 19 = 18 then None else Some (Ok observations))
      ; input_availability=R.Available;output_availability=Some R.Available }) in
  {declared_http;declared_cli;current_http;runs}

let project project case =
  project ~owner ~current_http:case.current_http
    ~declared_http:case.declared_http ~declared_cli:case.declared_cli ~runs:case.runs

let oracle () =
  Maintained_base.test_slot_history_keeps_original_binding_after_republication ();
  Maintained_test.test_slot_history_keeps_original_binding_after_republication ();
  for seed = 0 to 239 do
    let case = make_case ~slots:(seed mod 17) ~runs:(seed mod 19)
        ~visits:(seed mod 13) ~seed ~foreign_only:(seed mod 13 = 0) in
    let baseline = project Slot_under_base.slots_json case |> Yojson.Safe.to_string in
    let candidate = project Slot_under_test.slots_json case |> Yojson.Safe.to_string in
    if not (String.equal baseline candidate) then
      failwith (Printf.sprintf "different complete JSON at seed %d" seed)
  done;
  print_endline {|{"result":"PASS","exact_json_comparisons":240,"complete_maintained_case_calls":2}|}

let costs side =
  let implementation = match side with
    | "baseline" -> Slot_under_base.slots_json
    | "candidate" -> Slot_under_test.slots_json
    | _ -> invalid_arg "owned backend"
  in
  let rows = ["empty",0,0,0,100000,false;"one",1,1,1,10000,false;
    "foreign",0,64,8,2000,true;"small",4,32,4,2000,false;
    "wide",16,128,8,200,false;"large",64,512,16,20,false] in
  List.iter (fun (name,slots,runs,visits,iterations,foreign_only) ->
    let case = make_case ~slots ~runs ~visits ~seed:1 ~foreign_only in
    let expected = project implementation case |> Yojson.Safe.to_string in
    let output_sha256 = Agent_core_sha256.(to_hex (digest_string expected)) in
    let sink = ref `Null in
    for _ = 1 to 3 do sink := project implementation case done;
    Gc.full_major ();
    let cpu = Sys.time () and wall = Unix.gettimeofday () and allocated = Gc.allocated_bytes () in
    for _ = 1 to iterations do sink := Sys.opaque_identity (project implementation case) done;
    let cpu = Sys.time () -. cpu and wall = Unix.gettimeofday () -. wall
    and allocated = Gc.allocated_bytes () -. allocated in
    if not (String.equal expected (Yojson.Safe.to_string !sink)) then failwith "unstable final output";
    `Assoc ["side",`String side;"name",`String name;"slots",`Int slots;"runs",`Int runs;
      "visits_per_run",`Int visits;"iterations",`Int iterations;
      "cpu_seconds",`Float cpu;"wall_seconds",`Float wall;"allocated_bytes",`Float allocated;
      "output_bytes",`Int (String.length expected);"output_sha256",`String output_sha256]
    |> Yojson.Safe.to_string |> print_endline) rows

let () =
  match Array.to_list Sys.argv with
  | [_;"oracle"] -> oracle ()
  | [_;("baseline" | "candidate" as side)] -> costs side
  | _ -> invalid_arg "owned oracle or backend argument"
