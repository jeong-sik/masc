(** Real original/blob/GC stores and one borrowed MCP channel through the real
    local shim. Dispatch facts in store-only cases are fixture inputs. This is
    not a Gate grant, an SSH/VM execution or a DOCX conversion. *)
open Alcotest
open Masc
module Original = Keeper_media_reading_original
module Owner = Keeper_media_reading_owner
module Reply = Keeper_media_reading_reply
module Generic = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Store = Lane_addon_store
module Blob = Tool_blob_store
module Output = Tool_output
module History = Agent_core.History
module Remote = Keeper_sandbox_remote
module Request = Remote.Stdio_request
module Sdk = Agent_core_protocol.Mcp_schema.Sdk_types

let self = ref ""
let shim = ref ""
exception Receipt_failed
type late_failure = Receipt_failure | Cancel_after_reply
let get show = function Ok value -> value | Error error -> fail (show error)
let strings result = get Fun.id result
let owned result = get Owner.error_to_string result
let original result = get Original.error_to_string result
let save path bytes = Out_channel.with_open_bin path (fun out -> output_string out bytes)
let read path = In_channel.with_open_bin path In_channel.input_all
let json label a b = check bool label true (Yojson.Safe.equal a b)
let rejects label = function Ok _ -> fail (label ^ " unexpectedly succeeded") | Error _ -> ()

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let server = {|import json, os, signal, sys
signal.signal(signal.SIGTERM, signal.SIG_DFL)
calls = 0
for line in sys.stdin:
    req = json.loads(line)
    if req.get("method") == "initialize":
        result = {"protocolVersion":req["params"]["protocolVersion"],
                  "capabilities":{"tools":{}},"serverInfo":{"name":"reply-fixture","version":"1"}}
    elif req.get("method") == "tools/call":
        calls += 1
        open("calls", "w").write(str(calls))
        result = {"content":[{"type":"text","text":"full\u0000reply"},
                             {"type":"image","mimeType":"image/png","data":"AAEC"}],
                  "isError":True,"structuredContent":{"arguments":req["params"]["arguments"],
                  "nested":[None,False,0,""]},"_meta":{"retained":True}}
    else:
        continue
    print(json.dumps({"jsonrpc":"2.0","id":req["id"],"result":result}), flush=True)
|}

let carrier dir binary args =
  Unix.putenv Exec_ssh_protocol.shim_config_env_var (Filename.concat dir "shim.conf");
  Unix.execv binary (Array.of_list (binary :: args))

type fixture = {
  dir : string; base : string; remote_root : string; store : Store.t;
  blob : Blob.t; owner : Original.owner; input : History.stored;
  captured : Original.t; prepared : Request.t;
}

let with_fixture f =
  let dir = Unix.realpath (Filename.temp_dir "media-reply-" "") in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () ->
    let base = Filename.concat dir "workspace" in
    let remote = Filename.concat dir "remote" in
    Unix.mkdir base 0o700; Unix.mkdir remote 0o700;
    let masc_dir = Config_dir_resolver.masc_root ~base_path:base in
    Unix.mkdir masc_dir 0o700;
    let store = Store.create ~root:(Store.directory ~masc_dir) in
    let blob = Blob.create ~base_path:base in
    let keeper_name = "reply-fixture" in
    let owner = original (Original.observe_owner ~base_path:base ~keeper_name) in
    let media = Tool_blob_media_store.create blob in
    let media_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document" in
    let input = get History.show_media_error (media.put ~media_type ~raw:"fixture media\000\255") in
    let subject = original (Original.subject owner ~kind:Document ~media_type input) in
    let source = original (Original.verify_source ~media_store:media subject) in
    let declaration : Runtime_schema.media_reader_decl =
      { id="reply-fixture"; revision="one"; kind=Document; media_types=[media_type];
        adapter=Markitdown_mcp; command="python3"; args=["-c";server] } in
    save (Filename.concat dir "shim.conf")
      (Printf.sprintf "remote_root=%s\nscratch_root=%s\n" remote remote);
    Unix.chmod (Filename.concat dir "shim.conf") 0o644;
    let endpoint = Remote.of_container_exec ~base_path:base ~keeper_name
        ~remote_root:remote ~gh_config_dir:(Filename.concat remote "gh")
        ~injected_env:[] ~env_allowlist:[] ~connect_timeout_sec:1 ~max_concurrent_sessions:1
        {prefix=[!self;"--carrier";dir]; probe_prefix=None;
         container_name=Filename.basename dir; shim_path= !shim} in
    let remote_root = Remote.workspace_root endpoint in
    Unix.mkdir remote_root 0o700;
    let argv = declaration.command :: declaration.args in
    let prepared = get (fun _ -> "fixture preparation refused")
        (Request.prepare ~timeout_sec:15. endpoint ~argv ~env:[||] ~cwd:None) in
    let launch = get (fun _ -> "fixture binding refused")
        (Request.binding prepared ~base_path:base ~keeper_name ~expected_argv:argv) in
    let captured = original (Original.create ~execution_id:"reply-reserved-execution" ~source
        ~declaration ~launch ~causal_context:None ~task_id:None
        ~continuation_channel:(Keeper_continuation_channel.unrouted "isolated fixture")) in
    f {dir;base;remote_root;store;blob;owner;input;captured;prepared})

let reload fixture =
  match owned (Owner.load ~store:fixture.store ~owner:fixture.owner
      ~request_id:(Original.request_id fixture.captured)) with
  | Some value -> value | None -> fail "original disappeared"

let published = function
  | Owner.Stored value | Already_stored value -> value
  | Unconfirmed detail -> fail detail

let advance fixture retained events =
  (match Generic.advance_events ~store:fixture.store ~expected:(Owner.record retained) ~events with
   | Ok (Generic.Stored _ | Already_stored _) -> ()
   | Ok (Unconfirmed detail) -> fail detail
   | Error error -> fail (Generic.update_error_to_string error));
  reload fixture

let captured fixture = owned (Owner.retain ~store:fixture.store fixture.captured)
let dispatched fixture =
  let retained = captured fixture in
  let intent = strings (Keeper_media_reading_approval.intent fixture.captured) in
  advance fixture retained [Progress.Approval_intended intent; Progress.Dispatch_intended]

let sdk ?(structured_content=Some (`Assoc ["nested",`List [`Null;`Bool false;`Int 0;`String ""]]))
    ?(meta=Some (`Assoc ["opaque",`Bool true])) () : Sdk.tool_result =
  {content=[TextContent {type_="text";text="all\000text";annotations=None};
            ImageContent {type_="image";data="AAEC";mime_type="image/png";annotations=None}];
   is_error=Some true; structured_content; _meta=meta}

let reply value = strings (Reply.capture_sdk_reply value)
let retained_reply fixture item =
  match owned (Owner.load_reply ~store:fixture.store item) with
  | Some value -> value | None -> fail "retained reply disappeared"
let reply_ref item =
  match strings (Reply.validate_progress ~original:(Owner.original item) (Owner.record item).progress) with
  | Some link -> Reply.artifact link | None -> fail "reply link disappeared"

let test_complete_sdk_and_null () =
  with_fixture @@ fun fixture ->
  let pending = dispatched fixture in
  let value = reply (sdk ~structured_content:(Some `Null) ~meta:(Some `Null) ()) in
  let omitted = reply (sdk ~structured_content:None ~meta:None ()) in
  check bool "explicit SDK nulls remain distinct from absent fields" false
    (String.equal (Reply.reply_bytes value) (Reply.reply_bytes omitted));
  let stored = owned (Owner.retain_reply ~store:fixture.store ~expected:pending ~reply:value) |> published in
  let reopened_store = Store.create ~root:(Store.root fixture.store) in
  let reopened = match owned (Owner.load ~store:reopened_store ~owner:fixture.owner
      ~request_id:(Original.request_id fixture.captured)) with
    | Some item -> item | None -> fail "reopen lost original" in
  let restored = match owned (Owner.load_reply ~store:reopened_store reopened) with
    | Some value -> value | None -> fail "reopen lost reply" in
  check string "complete canonical response bytes survive restart" (Reply.reply_bytes value) (Reply.reply_bytes restored);
  json "all SDK fields, including explicit nulls" (Reply.reply_json value) (Reply.reply_json restored);
  let fields value = match Reply.reply_json value with
    | `Assoc fields -> fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "SDK reply must be an object" in
  List.iter (fun key ->
    check bool (key ^ " is explicitly present as null") true
      (List.assoc_opt key (fields restored) = Some `Null);
    check bool (key ^ " stays absent when SDK field is absent") true
      (List.assoc_opt key (fields omitted) = None)) ["structuredContent";"_meta"];
  json "original SDK error flag is retained" (`Bool true) (List.assoc "isError" (fields restored));
  json "both original content blocks and bytes are retained"
    (`List [`Assoc ["type",`String "text";"text",`String "all\000text"];
            `Assoc ["type",`String "image";"data",`String "AAEC";"mimeType",`String "image/png"]])
    (List.assoc "content" (fields restored));
  let artifact = reply_ref stored in
  check string "private body has no inline preview" "" artifact.preview;
  check string "reply JSON is opaque blob data" "application/json" artifact.mime;
  let after = advance fixture stored [Progress.Commit_intended {before=`Null;after=`Bool true};
      Progress.Commit_observed (`Bool true)] in
  let again = owned (Owner.retain_reply ~store:fixture.store ~expected:pending ~reply:value) |> published in
  check bool "idempotent old acknowledgement preserves later commit progress" true
    (Generic.same_record (Owner.record after) (Owner.record again));
  rejects "a different second reply cannot overwrite the first"
    (Owner.retain_reply ~store:fixture.store ~expected:again ~reply:omitted);
  check string "conflict leaves first full response" (Reply.reply_bytes value)
    (Reply.reply_bytes (retained_reply fixture again));
  strings (Store.save_tool_request_owner fixture.store ~scope:Owner.scope
    ~request_id:(Original.request_id fixture.captured) (Generic.to_json (Owner.record pending)));
  rejects "a known response cannot disappear through valid-looking progress rollback"
    (Owner.load_reply ~store:fixture.store again)

let test_link_publication_failures () =
  with_fixture @@ fun fixture ->
  let pending = dispatched fixture and value = reply (sdk ()) in
  let fail_save _ ~scope:_ ~request_id:_ _ = Error "fixture record write failure" in
  (match owned (Owner.For_testing.retain_reply ~save:fail_save ~store:fixture.store
      ~expected:pending ~reply:value ()) with
   | Owner.Unconfirmed _ -> () | Stored _ | Already_stored _ -> fail "write failure became success");
  check bool "a loose blob does not establish a linked response" true
    (owned (Owner.load_reply ~store:fixture.store pending) = None);
  let lost_ack store ~scope ~request_id json =
    strings (Store.save_tool_request_owner store ~scope ~request_id json);
    Error "fixture lost acknowledgement after the real save" in
  (match owned (Owner.For_testing.retain_reply ~save:lost_ack ~store:fixture.store
      ~expected:pending ~reply:value ()) with
   | Owner.Unconfirmed _ -> () | Stored _ | Already_stored _ -> fail "lost ACK was fabricated");
  let no_blob _ ~bytes:_ ~mime:_ = fail "existing reply was republished" in
  let no_save _ ~scope:_ ~request_id:_ _ = fail "existing reply was rewritten" in
  (match owned (Owner.For_testing.retain_reply ~put_blob:no_blob ~save:no_save
      ~store:fixture.store ~expected:pending ~reply:value ()) with
   | Owner.Already_stored restored ->
     check string "same-ID read recovers lost ACK" (Reply.reply_bytes value)
       (Reply.reply_bytes (retained_reply fixture restored))
   | Stored _ | Unconfirmed _ -> fail "visible original response was not acknowledged")

let test_missing_corrupt_and_wrong_length () =
  List.iter (fun corrupt -> with_fixture @@ fun fixture ->
    let pending = dispatched fixture and value = reply (sdk ()) in
    let stored = owned (Owner.retain_reply ~store:fixture.store ~expected:pending ~reply:value) |> published in
    let artifact = reply_ref stored in
    let path = Filename.concat (Blob.root_dir fixture.blob)
        (Filename.concat (String.sub artifact.sha256 0 2) artifact.sha256) in
    if corrupt then save path "changed response" else Unix.unlink path;
    rejects "linked response integrity failure is not absence" (Owner.load_reply ~store:fixture.store stored);
    let no_write _ ~bytes:_ ~mime:_ = fail "linked damaged response was silently rewritten" in
    rejects "idempotent retention cannot repair linked missing/corrupt bytes"
      (Owner.For_testing.retain_reply ~put_blob:no_write ~store:fixture.store ~expected:pending ~reply:value ())) [false;true];
  with_fixture @@ fun fixture ->
  let pending = dispatched fixture and value = reply (sdk ()) in
  let artifact = Blob.put_durable fixture.blob ~bytes:(Reply.reply_bytes value) ~mime:Reply.mime_type in
  let wrong = get Output.make_error_to_string (Output.make_artifact_ref ~sha256:artifact.sha256
      ~bytes:(artifact.bytes+1) ~preview:"" ~mime:artifact.mime) in
  let link = strings (Reply.link ~original:fixture.captured wrong) in
  let stored = advance fixture pending [Progress.Judgment_retained (Reply.link_to_json link)] in
  rejects "actual blob length must match retained reference" (Owner.load_reply ~store:fixture.store stored)

let test_wrong_owner_phase_and_link () =
  with_fixture @@ fun fixture ->
  let initial = captured fixture and value = reply (sdk ()) in
  let writes = ref 0 in
  let no_write _ ~bytes:_ ~mime:_ = incr writes; fail "invalid ownership reached blob writer" in
  rejects "reply before dispatch" (Owner.For_testing.retain_reply ~put_blob:no_write
    ~store:fixture.store ~expected:initial ~reply:value ());
  let pending = dispatched fixture in
  rejects "stale no-reply expected state" (Owner.For_testing.retain_reply ~put_blob:no_write
    ~store:fixture.store ~expected:initial ~reply:value ());
  let foreign = Store.create ~root:(Filename.concat fixture.dir "foreign-store") in
  rejects "wrong workspace store" (Owner.For_testing.retain_reply ~put_blob:no_write
    ~store:foreign ~expected:pending ~reply:value ());
  check int "all preconditions precede blob effects" 0 !writes;
  let artifact = Blob.put_durable fixture.blob ~bytes:(Reply.reply_bytes value) ~mime:Reply.mime_type
      |> fun value -> Output.with_preview value "" in
  let link = strings (Reply.link ~original:fixture.captured artifact) |> Reply.link_to_json in
  let wrong = match link with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
        key, if key="execution_id" then `String "another-execution" else value) fields)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "link must be an object" in
  (match Generic.advance ~store:fixture.store ~expected:(Owner.record pending)
      ~event:(Progress.Judgment_retained wrong) with
   | Ok (Generic.Stored _ | Already_stored _) -> ()
   | Ok (Unconfirmed detail) -> fail detail | Error error -> fail (Generic.update_error_to_string error));
  rejects "generic valid progress cannot launder a foreign reply link"
    (Owner.load ~store:fixture.store ~owner:fixture.owner ~request_id:(Original.request_id fixture.captured))

let test_opaque_reply_gc () =
  with_fixture @@ fun fixture ->
  let dead = Blob.put_durable fixture.blob ~bytes:"unrelated artifact" ~mime:"text/plain" in
  let media = Tool_blob_media_store.create fixture.blob in
  let dead_media = get History.show_media_error (media.put ~media_type:"image/png" ~raw:"unrelated media") in
  let structured = `Assoc [
    "valid_artifact",Output.normalized_artifact_ref_to_json dead;
    "valid_media",History.stored_source_to_json ~media_type:"image/png" dead_media;
    "malformed_artifact",`Assoc ["_blob",`Bool false];
    "malformed_media",`Assoc ["type",`String "stored";"sha256",`String "bad"];
    "marker",`String (Output.encode_for_agent_core (Output.Stored dead))] in
  let value = reply (sdk ~structured_content:(Some structured) ()) in
  let stored = owned (Owner.retain_reply ~store:fixture.store ~expected:(dispatched fixture) ~reply:value) |> published in
  let run mode = get Tool_blob_maintenance.error_to_string
      (Tool_blob_maintenance.run ~base_path:fixture.base ~scope:Server_tool_blob_scope.scope ~mode) in
  let observed = run Observe_only in
  check (list string) "all actual consumer stores classified" [] observed.unclassified;
  let swept = run Delete_previous_candidates in
  check (list string) "no unknown store silently disables deletion" [] swept.unclassified;
  check int "both unrelated blobs actually deleted" 2 swept.deleted;
  let fetch sha256 = get Blob.fetch_error_to_string (Blob.fetch fixture.blob ~sha256) in
  check (option string) "untrusted nested artifact does not pin another blob" None (fetch dead.sha256);
  check (option string) "untrusted Stored-shaped JSON does not pin other media" None (fetch dead_media.sha256);
  check bool "original official source remains live" true (Option.is_some (fetch fixture.input.sha256));
  check string "real GC leaves complete opaque response readable" (Reply.reply_bytes value)
    (Reply.reply_bytes (retained_reply fixture stored))

let test_actual_channel_reply_survives_late_failure late_failure () =
  with_fixture @@ fun fixture ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:Posix_spawn_process_mgr.mgr ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
    let initial = captured fixture and received = ref None in
    let on_dispatch () =
      let intent = strings (Keeper_media_reading_approval.intent fixture.captured) in
      ignore (advance fixture initial [Progress.Approval_intended intent;Progress.Dispatch_intended]);
      Ok () in
    (match Eio.Cancel.sub (fun cancel ->
      Keeper_sandbox_remote_stdio.with_stdio fixture.prepared ~on_dispatch
        ~on_receipt:(fun _ -> match late_failure with
          | Receipt_failure -> raise Receipt_failed | Cancel_after_reply -> ())
        ~on_stderr_chunk:ignore ~on_stdout_tail:ignore
        (fun ~input ~output ->
          let channel = strings (Agent_core.Mcp.Channel.create ~input ~output ()) in
          get Agent_core.Error.to_string (Agent_core.Mcp.Channel.initialize channel ~client_version:"reply-fixture");
          let sdk = get Agent_core.Error.to_string (Agent_core.Mcp.Channel.call_tool_full channel
              ~name:"convert" ~arguments:(Original.arguments fixture.captured)) in
          let value = reply sdk in received := Some value;
          let pending = reload fixture in
          (match Owner.For_testing.retain_reply
              ~put_blob:(fun _ ~bytes:_ ~mime:_ -> raise (Sys_error "fixture disk failure"))
              ~store:fixture.store ~expected:pending ~reply:value () with
           | Error (Owner.Reply_blob_write_failed _) -> ()
           | Ok _
           | Error (Owner.Store_error _ | Invalid_original _ | Store_workspace_mismatch _
             | Invalid_reply _ | Reply_blob_missing _ | Reply_blob_unavailable _ | Reply_update_error _) ->
             fail "blob failure was not reported as a retention failure");
          ignore (owned (Owner.retain_reply ~store:fixture.store ~expected:pending ~reply:value) |> published);
          Agent_core.Mcp.Channel.close channel;
          match late_failure with
          | Receipt_failure -> ()
          | Cancel_after_reply -> Eio.Cancel.cancel cancel Receipt_failed; Eio.Cancel.check cancel)) with
     | Ok _ | Error _ -> fail "late receipt exception was swallowed"
     | exception Receipt_failed ->
       (match late_failure with Receipt_failure -> () | Cancel_after_reply -> fail "cancellation changed into receipt failure")
     | exception Eio.Cancel.Cancelled _ ->
       (match late_failure with Cancel_after_reply -> () | Receipt_failure -> fail "receipt failure changed into cancellation"));
    let expected = match !received with Some value -> value | None -> fail "MCP returned no result" in
    let restored = retained_reply fixture (reload fixture) in
    check string "full SDK response survives receipt callback failure or cancellation"
      (Reply.reply_bytes expected) (Reply.reply_bytes restored);
    check string "retention retry did not repeat the actual RPC" "1" (read (Filename.concat fixture.remote_root "calls"));
    json "actual SDK error remains response data" (`Bool true)
      (Yojson.Safe.Util.member "isError" (Reply.reply_json restored));
    check int "actual content blocks survive" 2
      (Yojson.Safe.Util.member "content" (Reply.reply_json restored) |> Yojson.Safe.Util.to_list |> List.length))

let () = match Array.to_list Sys.argv with
  | _ :: "--carrier" :: dir :: binary :: args -> carrier dir binary args
  | [program;shim_path] ->
    self := Unix.realpath program; shim := Unix.realpath shim_path;
    Alcotest.run ~argv:[|program|] "media reply ownership"
      ["retention",[
        test_case "complete SDK and explicit null survive reload" `Quick test_complete_sdk_and_null;
        test_case "failed publication and lost acknowledgement" `Quick test_link_publication_failures;
        test_case "linked missing corrupt or wrong-length blob refuses" `Quick test_missing_corrupt_and_wrong_length;
        test_case "owner phase and complete link binding" `Quick test_wrong_owner_phase_and_link;
        test_case "actual GC treats untrusted reply JSON as opaque" `Quick test_opaque_reply_gc;
        test_case "actual MCP reply survives retention and cleanup failures" `Quick
          (test_actual_channel_reply_survives_late_failure Receipt_failure);
        test_case "actual MCP reply survives callback cancellation" `Quick
          (test_actual_channel_reply_survives_late_failure Cancel_after_reply)]]
  | _ -> failwith "expected real masc_exec_shim binary path"
