open Masc
module Source = Source_under_test
module Runtime = Runtime_under_test
module Owner = Owner_under_test
module Request = Request_before
module Question = Question_under_test
let get = function Ok x -> x | Error detail -> failwith detail
let check_count = ref 0
let check label condition = incr check_count; if not condition then failwith label
let member name json = Yojson.Safe.Util.member name json
let string = Yojson.Safe.Util.to_string
let canonical json = get (Lane_addon_action.canonical json)
let encode json = Yojson.Safe.to_string (canonical json)
let hash = Lane_addon_store.digest
let keeper_name = "ownership-fixture"
let trace = "ownership-trace"
let json_text value = `String (Yojson.Safe.to_string value)
let resolution text : Prompt_registry.prompt_resolution =
  {source=Prompt_registry.Override;effective=text;override_value=Some text;
   file_value=None;file_exists=false;has_override=true;file_path=None}
let owned_root () = match Sys.getenv_opt "MASC_BASE_PATH" with
  | Some path -> check "owned temporary fixture root" (Sys.file_exists (Filename.concat path "owned-fixture-marker")); path
  | None -> failwith "MASC_BASE_PATH absent"
let owner root =
  let stat=Unix.stat root in
  let physical=`Assoc ["path",`String root;"device",`Int stat.st_dev;"inode",`Int stat.st_ino] in
  get (Request.owner_of_json (`Assoc ["workspace",physical;"keepers",physical;"runtime",physical;
    "keeper_id",`String keeper_name;"epoch",`String "ownership-epoch"]))
let source root bytes =
  let payload=String.init bytes (fun i -> "a\"\\\n0123456789".[i mod 14]) in
  let input : Keeper_librarian.input = {
    turn_ref=Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:1;
    goal_context=Keeper_librarian.No_task;historical_task_contexts=[];
    keeper_id=Option.get (Keeper_identity.Keeper_id.of_string keeper_name);
    keeper_instructions="Synthetic ownership fixture";current=None;
    working_context=Keeper_librarian_context.empty;
    messages=[Agent_core.Types.make_message ~role:Agent_core.Types.User [Agent_core.Types.Text payload]];
    tool_observations=[];counterpart_observations=[]} in
  let digest=String.make 64 'a' in
  let span=`Assoc ["count",`Int 1;"digest",`String digest] in
  let range=`Assoc ["history_start_boundary_line",`Int 1;"start_atom",`Int 0;"end_atom",`Int 1;
    "last_atom_digest",`String digest] in
  let held=`List [`String "checkpoint";`Assoc ["trace_id",`String trace;"range",range;
    "boundary_lines_seen",`Int 1;"end_boundary_line",`Int 1;"messages",span]] in
  let receipt : Keeper_memory_os_current_types.durable_range_id = {
    receipt_scope=root;trace_id=trace;history_start_boundary_line=1;start_atom=0;end_atom=1;
    last_atom_digest=digest;end_boundary_line=1;boundary_lines_seen=1;unread_messages=[]} in
  let counterparts=`Assoc ["keeper_name",`String keeper_name;"after",`Null;"before",`Float 1.;
    "external_after",`Null;"external_through",`Int 0;"chat_rows",`List [];"external_log",`List []] in
  let observation=`Assoc ["after",`Int 0;"pending",`Null] in
  let json=`Assoc ["schema",`Int 2;"purpose",`String "durable_history";
    "runtime_keepers_dir",`String root;"extent",`String "all_unread";"boundaries",span;
    "positions",`Assoc ["current",`Null;"selection",`Null;"counterpart",`Null;"official",`Null];
    "source_text",json_text held;
    "counterparts_text",json_text counterparts;
    "external_before",observation;"external_prepared",observation;"expected_revision",`Null;
    "range_id",Keeper_memory_os_current_range_codec.durable_range_id_to_json receipt;
    "official_range_id",`Null;"input_text",json_text (Keeper_librarian_input_capture.to_json input)] in
  get (Result.map_error Source.error_to_string (Source.of_json json))
let preparation input =
  let policy : Runtime.durable_policy = {facts_max_bytes=4096;facts_source_lines=[];
    category_cap=8;facts_per_category_cap=8} in
  let turn_prompts : Runtime.turn_input_prompts = {
    working_context_input=resolution "Working context: {{working_context}}";
    turn_inputs=resolution "History: {{conversation_history}}"} in
  get (Runtime.restore_durable_preparation ~source_input:input ~parsing_now:1. ~policy
    ~rule_prompt:(resolution "Preserve evidence") ~turn_prompts
    ~prompt:(resolution "{{working_contexts_rule}}\n{{turn_inputs}}")
    ~output_schema:Keeper_structured_output_schema.librarian_current_output_schema)
let destination : Request.destination = {
  installation_id=Owner.installation_id (Owner.Configuration "ownership-fixture");
  package_id=Request.package_id;tool=Request.tool;source_revision="synthetic-source";
  configuration_revision="synthetic-configuration"}
type serialized = {scope:string;id:string;digest:string;bytes:string;metadata:Yojson.Safe.t}
let serialize root bytes nonce =
  let owner=owner root in
  let source=source root bytes in
  let preparation=preparation (Source.input source) in
  let id=Yojson.Safe.to_string (`List [`String "keeper-librarian-history";
    `String (let scope=Request.scope owner in String.sub scope (String.length scope-64) 64);
    `String nonce]) in
  let body=`Assoc ["schema",`Int 2;"kind",`String "completed-history-execution";
    "request_id",`String id;"owner",Request.owner_to_json owner;
    "destination",Lane_addon_captured_destination.to_json destination;
    "source_text",json_text (Source.to_json source);"predecessor",`Null;
    "preparation",Question.to_json preparation] |> canonical in
  let restored=get (Request.of_json ~owner body) in
  let summary=Request.index_to_json (get (Request.index restored)) |> canonical in
  let bytes=encode body in
  let digest=hash bytes and scope=Request.scope owner in
  let metadata=`Assoc ["schema",`String "lane.addon.tool-request-owner.v4";
    "scope",`String scope;"request_id",`String id;"installation_id",`String destination.installation_id;
    "package_id",`String destination.package_id;"tool",`String destination.tool;
    "request_digest",`String digest;"summary",summary;
    "progress",Lane_addon_request_progress.to_json Lane_addon_request_progress.captured] in
  {scope;id;digest;bytes;metadata}
type pair = Owner.retained * Request.t
let read reader serialized =
  get (Owner.Published_reader.read reader ~directory_name:(hash serialized.scope)
    ~file_name:(hash serialized.id ^ ".json") serialized.metadata)
let make_pair root serialized =
  let reader=Owner.Published_reader.create ~read_body:(fun ~scope ~request_digest ->
    check "expected read identity" (scope=serialized.scope && request_digest=serialized.digest);
    Ok (Some serialized.bytes)) in
  let record=read reader serialized in
  let request=get (Request.restore_payload ~owner:(owner root) record) in
  record,request
