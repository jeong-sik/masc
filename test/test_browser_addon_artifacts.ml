open Alcotest
module B = Browser_lane
module W = Masc.Browser_addon_wire
module Owner = Masc.Browser_addon_owner
module Broker = Masc.Browser_addon_downloads
module Client = Masc.Browser_addon_client
module Socket = Masc.Browser_addon_socket
module Lease = Native_addon_lease
let ok = function Ok value -> value | Error detail -> fail detail
let private_root prefix = Unix.realpath (Filename.temp_dir ~perms:0o700 prefix "")
let write path bytes = Out_channel.with_open_bin path (fun out -> output_string out bytes)
let member key = Yojson.Safe.Util.member key
let descriptor_ingestion () =
  let root=private_root "browser-artifact-descriptor-" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let path=Filename.concat root "input.bin" in
    let bytes="original\000download" in write path bytes;
    let source=Unix.openfile path [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 in
    Fun.protect ~finally:(fun () -> Unix.close source) (fun () ->
      Unix.rename path (path ^ ".original");write path "replacement";
      let store=Tool_blob_store.create ~base_path:root in
      let digest=Digestif.SHA256.(to_hex (digest_string bytes)) in
      let wrong_digest=String.make 64 '0' in
      check bool "a mismatched grant cannot publish another digest" true
        (try ignore (Tool_blob_store.put_file_descriptor_durable_blocking store ~source
          ~expected_sha256:wrong_digest ~mime:"application/octet-stream");false with Sys_error _ -> true);
      check bool "rejected bytes were not published" false (Sys.file_exists (Tool_blob_store.root_dir store));
      let artifact=Tool_blob_store.put_file_descriptor_durable_blocking store ~source
        ~expected_sha256:digest ~mime:"application/octet-stream" in
      check string "ingestion uses the held original descriptor" digest artifact.sha256;
      check int "the caller retains its open source" (String.length bytes) (Unix.fstat source).st_size;
      check (option string) "path replacement cannot change stored bytes" (Some bytes)
        (Tool_blob_store.fetch store ~sha256:artifact.sha256 |> Result.map_error Tool_blob_store.fetch_error_to_string |> ok)))
let transfer_id result =
  let data=Option.get result.Mcp_protocol.Mcp_types.structured_content in
  let rows=member "answer" data |> member "payload" |> member "data" |> member "downloads" in
  match rows with `List [row] -> member "artifact" row |> member "downloadGrant" |> Yojson.Safe.Util.to_string
  | _ -> fail "expected the actual bound transfer row"
let scenario () = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  let clock=Eio.Stdenv.clock env and net=Eio.Stdenv.net env in
  Eio_context.with_test_env ~sw ~clock ~net ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
  Time_compat.set_clock clock;
  let base=private_root "browser-artifact-host-" in
  let incarnation="0b000000-0000-4000-8000-000000000051" in
  let context=ok (Socket.context ~instance_id:incarnation ~automation:None ~stagehand:None ~live_bidi:None ~models:None) in
  let allocation=member "directory" context |> Yojson.Safe.Util.to_string in
  Fun.protect ~finally:(fun () ->
    if Sys.file_exists allocation then Fs_compat.remove_tree allocation;
    Fs_compat.remove_tree base) (fun () ->
  let admission=Lease.prepare ~directories:[base] ~instance_id:incarnation ~cleanup_context:(Some context)
    |> Result.map_error Lease.error_to_string |> ok in
  let socket=ok (Socket.acquire ~admission ~directory:base) in
  let broker=ok (Broker.create ~directory:allocation) in
  let owner=ok (Owner.create ~incarnation) in
  ok (Owner.attach_downloads owner broker);
  let downloads=Filename.concat allocation "downloads" in Unix.mkdir downloads 0o700;
  let session=Filename.concat downloads "session" in Unix.mkdir session 0o700;
  let source=Filename.concat session "report.bin" in
  let bytes=String.init (Sys.io_buffer_size*3+7) (fun index -> Char.chr (index mod 251)) in
  write source bytes;Unix.chmod source 0o600;
  let marker=ref (ok (Owner.publish_download owner source)) in
  let calls=ref 0 in
  let closed,set_closed=Eio.Promise.create () in
  ok (Owner.attach_automation owner ~locate:false ~session:(fun () -> B.Browser_open)
    ~document:(fun ~tab_id:_ -> fail "downloads do not read a document")
    ~execute:(function
      | B.Page_downloads _ -> incr calls;B.Answered (`Assoc ["ok",`Bool true;"data",`Assoc [
          "sessionId",`String "session";"downloads",`List [`Assoc ["downloadId",`String "download";
            "status",`String "completed";"path",`String source;"artifact",!marker]]]])
      | _ -> fail "only the original download read may execute")
    ~cleanup:(fun () -> ignore (Eio.Promise.try_resolve set_closed ());Ok ()));
  let principal=Lane_addon_call_context.Keeper "download-reader" in
  let actor=Lane_addon_call_context.actor_label principal in
  let route=B.Automation_route and verb=B.Page_downloads {tab_id=7} in
  let arguments=`Assoc ["lane",`String "automation";"command",B.verb_json verb] in
  let command ()=Masc.Browser_addon_tool.invoke ~owner ~principal arguments in
  let client=ok (Client.create ~socket_path:(Socket.socket_path socket) ~incarnation
    ~max_message_bytes:65536 ~control_timeout_sec:2. ~available:(fun () -> true)) in
  let store=Tool_blob_store.create ~base_path:base in
  let finalize raw=ok (Masc.Browser_addon_artifacts.finalize ~socket ~client ~store
    ~name:Masc.Browser_addon_tool.definition.name ~arguments ~principal ~result:raw) in
  Eio.Fiber.first
    (fun () -> Masc.Browser_addon_service.serve ~net ~owner ~socket_path:(Socket.socket_path socket) ~max_message_bytes:65536)
    (fun () ->
      let rec ready ()=if Sys.file_exists (Socket.socket_path socket) then () else (Eio.Fiber.yield ();ready ()) in ready ();
      let raw=command () in ignore (transfer_id raw);
      let result=finalize raw in
      check (option bool) "ordinary export succeeds" (Some false) result.is_error;
      check bool "original metadata is retained" true (raw._meta=result._meta);
      let data=Option.get result.structured_content |> member "answer" |> member "payload" |> member "data" in
      let artifact=match member "downloads" data with `List [row] ->
          check bool "worker source path stays private" true (member "path" row=`Null);member "artifact" row
        | _ -> fail "missing final download" in
      let sha256=member "arguments" artifact |> member "sha256" |> Yojson.Safe.Util.to_string in
      check (option string) "artifact reader restores the exact binary content" (Some bytes)
        (Tool_blob_store.fetch store ~sha256 |> Result.map_error Tool_blob_store.fetch_error_to_string |> ok);
      let blob=Filename.concat (Filename.concat (Tool_blob_store.root_dir store) (String.sub sha256 0 2)) sha256 in
      let inode=(Unix.stat blob).Unix.st_ino in
      ignore (finalize (command ()));
      check int "cached snapshot does not republish its durable blob" inode (Unix.stat blob).Unix.st_ino;
      let live=`Assoc ["lane",`String "live";"clientId",`String "0b000000-0000-4000-8000-000000000052";
        "command",`Assoc ["verb",`String "page.interact";"args",`Assoc ["action",`String "activate_tab";"tabId",`Int 7;"expectedUrl",`String "https://example.org/"]]] in
      let live_id=`String "0b000000-0000-4000-8000-000000000052" in
      let live_data=`Assoc ["reply",`String "issue";"answer",`Assoc ["status",`String "answered";
        "payload",`Assoc ["ok",`Bool true;"data",`Assoc ["activated",`Bool true]]];
        "browserSelection",`Assoc ["lane",`String "live";"clientId",live_id;"reason",`String "explicit_browser"];
        "browserConnection",`Assoc ["clientId",live_id;"transport",`String "web_extension"]] in
      let live_result={raw with structured_content=Some live_data;
        content=[Mcp_protocol.Mcp_types.TextContent {type_="text";text=Yojson.Safe.to_string live_data;annotations=None}]} in
      check bool "successful live activation passes through unchanged" true
        (ok (Masc.Browser_addon_artifacts.finalize ~socket ~client ~store
          ~name:Masc.Browser_addon_tool.definition.name ~arguments:live ~principal ~result:live_result)=live_result);
      let later=Filename.concat session "later.bin" in write later "later";Unix.chmod later 0o600;
      marker:=ok (Owner.publish_download owner later);
      let id=transfer_id (command ()) in
      let retired,set_retired=Eio.Promise.create () in
      let retiring,start_retiring=Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.await retiring;
        Eio.Promise.resolve set_retired (Owner.dispatch owner {W.incarnation;command=Retire}));
      let receipt=ok (Client.transfer_download client ~id ~actor ~route ~verb ~publish:(fun descriptor ->
        check bool "a changed descriptor is refused before import" true
          (Result.is_error (Socket.with_download_snapshot socket {descriptor with inode=descriptor.inode+1} (fun _ -> Ok ())));
        Client.revoke client;
        Eio.Promise.resolve start_retiring ();
        Eio.Promise.await closed;
        Eio.Fiber.yield ();
        check bool "retirement joins the original active transfer" true (Eio.Promise.peek retired=None);
        check bool "revocation still fences fresh claims" true
          (Result.is_error (Client.call client ~on_cancel_after_dispatch:(fun () -> ())
            (W.Download_claim {id;actor;route;verb})));
        Masc.Browser_download_artifact.publish_descriptor ~socket ~store descriptor)) in
      check bool "retired owner accepts exact commit and release" true (member "reader" receipt=`String "keeper_artifact_read");
      check bool "retirement completes after release" true (Eio.Promise.await retired=W.Receipt);
      check int "no browser read is replayed during transfer" 3 !calls;
      check bool "published bytes outlive worker cleanup" true (Result.is_ok (Tool_blob_store.fetch store ~sha256));
      check bool "only confirmed source files are released" false (Sys.file_exists source || Sys.file_exists later);
      Lease.retire admission |> Result.map_error Lease.error_to_string |> ok)))))
let ()=run "browser Addon host artifact finalization" ["transfer",[
  test_case "descriptor authority and digest precede publication" `Quick descriptor_ingestion;
  test_case "export and private socket preserve artifact authority through retirement" `Quick scenario]]
