(** Actual Gate/original/blob stores and borrowed MCP over the real local shim.
    Only endpoint acquisition and explicit original-publication faults are
    substituted. The Python MCP fixture checks full source bytes; it is not
    MarkItDown, a DOCX conversion, SSH, or a running MicroVM. *)
open Alcotest
open Masc
module Producer = Keeper_media_reading_producer
module Media = Keeper_media_reading
module Original = Keeper_media_reading_original
module Owner = Keeper_media_reading_owner
module Reply = Keeper_media_reading_reply
module Progress = Lane_addon_request_progress
module Journal = Lane_addon_tool_request_owner
module Queue = Keeper_approval_queue
module Queue_result = Keeper_approval_queue_result
module Remote = Keeper_sandbox_remote

let self = ref ""
let shim = ref ""
let mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
let raw = "complete fixture attachment\000\255\n한글"
let get show = function Ok value -> value | Error error -> fail (show error)
let strings value = get Fun.id value
let owned value = get Owner.error_to_string value
let original value = get Original.error_to_string value
let save path text = Out_channel.with_open_bin path (fun channel -> output_string channel text)
let load path = In_channel.with_open_bin path In_channel.input_all

let server = {|import base64, json, os, sys
mode = sys.argv[1]
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        result = {"protocolVersion": request["params"]["protocolVersion"],
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "media-producer-fixture", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": [{"name": "convert_to_markdown", "inputSchema": {
                  "type": "object", "properties": {"uri": {"type": "string"}}, "required": ["uri"]}}]}
    elif method == "tools/call":
        assert request["params"]["name"] == "convert_to_markdown"
        arguments = request["params"]["arguments"]
        assert list(arguments) == ["uri"]
        prefix, encoded = arguments["uri"].split(",", 1)
        assert prefix == "data:application/vnd.openxmlformats-officedocument.wordprocessingml.document;base64"
        original = base64.b64decode(encoded, validate=True)
        with open("calls", "a") as calls:
            calls.write("call\n")
        if mode == "disconnect":
            os._exit(0)
        result = {"content": [{"type": "text", "text": "reading:" + base64.b64encode(original).decode()}],
                  "isError": False, "structuredContent": {"opaque": [None, False, 0]},
                  "_meta": {"private_fixture": True}}
    else:
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
|}

let carrier dir mode binary args =
  if args = ["--probe"] && mode = "disabled" then (
    print_endline {|{"name":"masc-exec-shim","version":"3.0.0","capabilities":[]}|};
    exit 0);
  Unix.putenv Exec_ssh_protocol.shim_config_env_var (Filename.concat dir "shim.conf");
  Unix.execv binary (Array.of_list (binary :: args))

type fixture = {
  dir : string;
  config : Workspace.config;
  meta : Keeper_meta_contract.keeper_meta;
  store : Lane_addon_store.t;
  media : Agent_core.History.media_store;
  stored : Agent_core.History.stored;
  subject : Original.subject;
  declaration : Runtime_schema.media_reader_decl;
  endpoint : Remote.t;
  acquisitions : int ref;
}

let with_fixture ?(mode="reply") f =
  let dir = Unix.realpath (Filename.temp_dir "media-producer-" "") in
  Queue.For_testing.reset_runtime_state ();
  Keeper_approval.Audit.For_testing.reset_store ();
  Fun.protect ~finally:(fun () ->
    Process_eio.reset_for_testing (); Fs_compat.clear_fs ();
    Queue.For_testing.reset_runtime_state ();
    Keeper_approval.Audit.For_testing.reset_store ();
    Fs_compat.remove_tree dir) (fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Process_eio.init ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
        ~proc_mgr:Posix_spawn_process_mgr.mgr ~clock:(Eio.Stdenv.clock env);
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 25. (fun () ->
        let base = Filename.concat dir "workspace" in
        let remote = Filename.concat dir "remote" in
        Unix.mkdir base 0o700; Unix.mkdir remote 0o700;
        let config = Workspace.default_config base in
        let keeper_name = "media-producer-fixture" in
        let meta = strings (Masc_test_deps.meta_of_json_fixture
            (`Assoc ["name",`String keeper_name; "trace_id",`String "media-producer"])) in
        strings (Keeper_meta_store.replace_snapshot config meta);
        ignore (get Queue_result.install_error_to_string (Queue.install_persistence ~base_path:base));
        ignore (strings (Keeper_gate_mode.set config ~actor:"fixture" Keeper_gate_mode.Always_allow));
        let store = Lane_addon_store.of_config config in
        let media = Tool_blob_media_store.of_base_path ~base_path:base in
        let stored = get Agent_core.History.show_media_error (media.put ~media_type:mime ~raw) in
        let owner = original (Original.observe_owner ~base_path:base ~keeper_name) in
        let subject = original (Original.subject owner ~kind:Document ~media_type:mime stored) in
        let declaration : Runtime_schema.media_reader_decl =
          {id="fixture-reader"; revision="one"; kind=Document; media_types=[mime];
           adapter=Markitdown_mcp; command="python3"; args=["-c";server;mode]} in
        save (Filename.concat dir "shim.conf")
          (Printf.sprintf "remote_root=%s\nscratch_root=%s\n" remote remote);
        Unix.chmod (Filename.concat dir "shim.conf") 0o644;
        let endpoint = Remote.of_container_exec ~base_path:base ~keeper_name
            ~remote_root:remote ~gh_config_dir:(Filename.concat remote "gh")
            ~injected_env:[] ~env_allowlist:[] ~connect_timeout_sec:1 ~max_concurrent_sessions:1
            {prefix=[!self;"--carrier";dir;mode];probe_prefix=None;
             container_name=Filename.basename dir;shim_path= !shim} in
        Unix.mkdir (Remote.workspace_root endpoint) 0o700;
        f {dir;config;meta;store;media;stored;subject;declaration;endpoint;acquisitions=ref 0})))

let producer ?retain_original ?declarations fixture =
  Producer.For_testing.create
    ~endpoint:(fun () -> incr fixture.acquisitions; Ok fixture.endpoint)
    ?retain_original ~config:fixture.config ~meta:fixture.meta ~turn_sandbox_factory:None
    ~media_store:fixture.media
    ~declarations:(Some (Option.value declarations ~default:[fixture.declaration]))
    ~causal_context:None ~continuation_channel:None ()

let read producer fixture = Producer.read producer ~kind:Document ~media_type:mime fixture.stored
let inventory fixture = Owner.originals (owned (Owner.discover_subject ~store:fixture.store fixture.subject))
let one fixture = match inventory fixture with
  | [value] -> value | [] | _ :: _ :: _ -> fail "expected exactly one original"
let calls fixture =
  let path = Filename.concat (Remote.workspace_root fixture.endpoint) "calls" in
  if Sys.file_exists path then String.split_on_char '\n' (String.trim (load path)) else []
let reading = function
  | Media.Owned (Media.Read reading) -> reading
  | Use_builtin | Owned (Unavailable _ | Pending _) -> fail "expected an owned reading"
let has_pending wanted = function
  | Media.Owned (Media.Pending (first, rest)) ->
    List.exists (fun (item : Media.pending_observation) -> item.disposition = wanted) (first :: rest)
  | Use_builtin | Owned (Read _ | Unavailable _) -> false

let test_actual_reply_and_observe () = with_fixture (fun fixture ->
  let producer = producer fixture in
  (match Producer.observe producer ~kind:Document ~media_type:mime fixture.stored with
   | Media.Owned (Unavailable failure) ->
     check bool "observation reports a reader not yet started" true
       (failure = Media.External_failed Media.Reader_not_started)
   | Use_builtin | Owned (Read _ | Pending _) -> fail "observation must not start a new reader");
  check int "observe acquires no endpoint" 0 !(fixture.acquisitions);
  check int "observe retains no original" 0 (List.length (inventory fixture));
  let first = reading (read producer fixture) in
  check string "complete binary source reaches actual MCP tool" ("reading:" ^ Base64.encode_string raw) first.text;
  let retained = one fixture in
  let reply = match owned (Owner.load_reply ~store:fixture.store retained) with
    | Some reply -> reply | None -> fail "reading preceded reply retention" in
  check bool "full private SDK metadata retained" true
    (Yojson.Safe.Util.member "_meta" (Reply.reply_json reply)
     = `Assoc ["private_fixture",`Bool true]);
  (match owned (Owner.load_transport ~store:fixture.store retained) with
   | Some (Remote.Execution_observed _) -> ()
   | None | Some (Remote.Execution_unavailable _) -> fail "actual shim receipt missing");
  let second = reading (read producer fixture) in
  check string "same retained reading" first.text second.text;
  check (list string) "one actual tools/call" ["call"] (calls fixture);
  check int "one endpoint acquisition" 1 !(fixture.acquisitions))

let test_unknown_never_reinvokes () = with_fixture ~mode:"disconnect" (fun fixture ->
  let first = producer fixture in
  ignore (read first fixture);
  check (list string) "fixture received one call before disconnect" ["call"] (calls fixture);
  check bool "same walk retains unknown" true (has_pending Media.Outcome_unknown (read first fixture));
  let next = producer ~declarations:[] fixture in
  check bool "unknown precedes removed declaration" true (has_pending Media.Outcome_unknown (read next fixture));
  check (list string) "unknown is never a new call" ["call"] (calls fixture);
  check int "unknown never reacquires endpoint" 1 !(fixture.acquisitions);
  check int "unknown retains original identity" 1 (List.length (inventory fixture)))

let test_no_send_new_walk_requires_fresh_gate () = with_fixture ~mode:"disabled" (fun fixture ->
  (* A prior walk retained the real original but lost its acknowledgement
     before any Gate/dispatch. The next walk must mark an attempt on this
     pre-existing original too, not just on originals it created itself. *)
  let retain_original ~store original =
    match Owner.retain ~store original with
    | Error error -> Error error
    | Ok _ -> Error (Owner.Store_error (Journal.Store_unavailable "fixture lost original ACK")) in
  let prior = producer ~retain_original fixture in
  ignore (read prior fixture);
  ignore (one fixture);
  let first = producer fixture in
  ignore (read first fixture);
  let before = one fixture in
  check bool "actual disabled probe proves request not sent" true
    (owned (Owner.load_transport ~store:fixture.store before) =
     Some (Remote.Execution_unavailable Remote.Request_not_sent));
  ignore (strings (Keeper_gate_mode.set fixture.config ~actor:"fixture" Keeper_gate_mode.Manual));
  check bool "same walk explicitly reports no-send" true
    (has_pending Media.Request_not_sent (read first fixture));
  check int "same walk does not create a replacement original" 1 (List.length (inventory fixture));
  let next = producer fixture in
  ignore (read next fixture);
  let originals = inventory fixture in
  check int "new walk has a fresh original" 2 (List.length originals);
  let fresh = match List.filter (fun retained ->
      Original.request_id (Owner.original retained) <> Original.request_id (Owner.original before)) originals with
    | [value] -> value | [] | _ :: _ :: _ -> fail "fresh original identity missing" in
  (match Progress.approval (Owner.record fresh).progress with
   | Some (Progress.Waiting_for_approval (intent, wait)) ->
     let observed = get Queue_result.storage_error_to_string
         (Queue.observe_exact_request ~approval_id:(Lane_addon_request_approval.approval_id wait)
           (Lane_addon_request_approval.request intent)) in
     (match observed with
      | Queue_result.Exact_found {exact_state=Exact_pending;_} -> ()
      | Exact_absent | Exact_ambiguous _ | Known_approval_missing _ | Known_approval_mismatch _
      | Exact_found {exact_state=(Exact_rejected _ | Exact_approved_unconsumed | Exact_approved_consumed _);_} ->
        fail "fresh original did not ask the actual new Manual Gate")
   | None | Some (Progress.Intent_pending _) -> fail "fresh Gate wait is not retained");
  check (list string) "neither disabled nor deferred request calls MCP" [] (calls fixture))

let test_uncertain_original_reuses_same_id () = with_fixture (fun fixture ->
  let retained_ids = ref [] in
  let retain_original ~store original =
    retained_ids := Original.request_id original :: !retained_ids;
    match !retained_ids with
    | [_] -> Error (Owner.Store_error (Journal.Store_unavailable "fixture failure before publication"))
    | [] | _ :: _ :: _ -> Owner.retain ~store original in
  let producer = producer ~retain_original fixture in
  ignore (read producer fixture);
  check int "failed retention invokes no endpoint twice" 1 !(fixture.acquisitions);
  check int "injected pre-publication failure left no record" 0 (List.length (inventory fixture));
  ignore (reading (read producer fixture));
  (match !retained_ids with
   | [second; first] -> check string "retention-only retry keeps exact original ID" first second
   | [] | [_] | _ :: _ :: _ :: _ -> fail "expected exactly two retention attempts");
  check int "staged request reuses captured endpoint" 1 !(fixture.acquisitions);
  check (list string) "retention retry calls MCP only once" ["call"] (calls fixture))

let () = match Array.to_list Sys.argv with
  | _ :: "--carrier" :: dir :: mode :: binary :: args -> carrier dir mode binary args
  | [program; shim_path] ->
    self := Unix.realpath program; shim := Unix.realpath shim_path;
    Alcotest.run ~argv:[|program|] "owned media producer"
      ["producer", [
        test_case "actual Channel reply and transport precede reading" `Quick test_actual_reply_and_observe;
        test_case "unknown survives removed declaration without another call" `Quick test_unknown_never_reinvokes;
        test_case "no-send closes one invocation and next walk asks a fresh Gate" `Quick test_no_send_new_walk_requires_fresh_gate;
        test_case "uncertain original publication retries its same identity" `Quick test_uncertain_original_reuses_same_id]]
  | _ -> failwith "expected actual masc_exec_shim binary path"
