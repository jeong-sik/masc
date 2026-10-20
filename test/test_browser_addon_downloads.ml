open Alcotest
module Broker = Masc.Browser_addon_downloads
module B = Browser_lane
let ok = function Ok value -> value|Error detail -> fail detail
let route=B.Automation_route
let actor="keeper/download-reader"
let verb=B.Page_downloads {tab_id=7}
let write path contents = Out_channel.with_open_bin path (fun out -> output_string out contents)
let read path = In_channel.with_open_bin path In_channel.input_all
let with_download f =
  let root=Unix.realpath (Filename.temp_dir ~perms:0o700 "browser-download-broker-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let downloads=Filename.concat root "downloads" in Unix.mkdir downloads 0o700;
    let session=Filename.concat downloads "original-session" in Unix.mkdir session 0o700;
    let source=Filename.concat session "report.bin" in
    let contents=String.init (Sys.io_buffer_size*3+19) (fun index -> Char.chr (index mod 251)) in
    write source contents;Unix.chmod source 0o600;
    let broker=ok (Broker.create ~directory:root) in f root source contents broker)
let payload source marker = `Assoc ["sessionId",`String "original-session";
  "downloads",`List [`Assoc ["downloadId",`String "remote-download";"status",`String "completed";
    "path",`String source;"artifact",marker]];"observation",`String "connected";"reason",`Null]
let grant broker source marker =
  let bound=ok (Broker.bind broker ~actor ~route ~verb (payload source marker)) in
  match Yojson.Safe.Util.member "downloads" bound with
  | `List [row] ->
      check bool "private source path is removed" true (Yojson.Safe.Util.member "path" row=`Null);
      Yojson.Safe.Util.(member "artifact" row |> member "downloadGrant" |> to_string)
  | _ -> fail "missing bound download row"
let claim broker id = ok (Broker.claim broker ~id ~actor ~route ~verb)
let descriptor = function Broker.Snapshot descriptor -> descriptor
  | Published _ -> fail "first import must own a snapshot"
let publication_is expected = function
  | Broker.Published actual -> Yojson.Safe.equal actual expected
  | Snapshot _ -> false
let publish root descriptor =
  let path=ok (Broker.snapshot_path ~directory:root ~snapshot_id:descriptor.Broker.snapshot_id) in
  ok (Masc.Browser_download_artifact.publish ~base_path:root path)
let commit broker id receipt = ok (Broker.commit broker ~id ~actor ~route ~verb ~receipt)
let release broker id = ok (Broker.release broker ~id ~actor ~route ~verb)
let durable_roundtrip () = with_download (fun root source contents broker ->
  let marker=ok (Broker.publish broker source) in
  let id=grant broker source marker in
  check bool "a different caller cannot import" true
    (Result.is_error (Broker.claim broker ~id ~actor:"keeper/other" ~route ~verb));
  check bool "a changed command cannot import" true
    (Result.is_error (Broker.claim broker ~id ~actor ~route ~verb:(B.Page_downloads {tab_id=8})));
  let first=claim broker id in
  let descriptor=descriptor first in
  check bool "private descriptor codec is exact" true (ok (Broker.claim_of_json (Broker.claim_to_json first))=first);
  let path=ok (Broker.snapshot_path ~directory:root ~snapshot_id:descriptor.snapshot_id) in
  check string "immutable copy preserves binary content" contents (read path);
  let receipt=publish root descriptor in
  commit broker id receipt;commit broker id receipt;release broker id;
  let another=grant broker source marker in
  check bool "each call owns a distinct grant" true (id<>another);
  check bool "cached snapshot reuses durable publication" true (publication_is receipt (claim broker another));
  commit broker another receipt;
  Broker.revoke broker;
  check bool "committed receipt remains readable after retirement" true (publication_is receipt (claim broker id));
  check bool "wrong caller cannot settle after retirement" true
    (Result.is_error (Broker.release broker ~id ~actor:"keeper/other" ~route ~verb));
  release broker another;
  let before=Unix.stat source in
  Unix.utimes source before.st_atime (before.st_mtime -. 1.);
  check bool "completed source metadata changed after publication" true
    ((Unix.stat source).st_mtime<>before.st_mtime);
  ok (Broker.cleanup broker);ok (Broker.cleanup broker);
  check bool "published original is removed after backend teardown" false (Sys.file_exists source);
  check bool "private snapshot is removed after settlement" false (Sys.file_exists path);
  let reference=Yojson.Safe.Util.(member "arguments" receipt |> member "sha256" |> to_string) in
  match Tool_blob_store.fetch (Tool_blob_store.create ~base_path:root) ~sha256:reference with
  | Ok (Some saved) -> check string "durable artifact outlives worker snapshots" contents saved
  | Ok None|Error _ -> fail "durable artifact disappeared")
let retirement_and_unpublished () = with_download (fun _root source _contents broker ->
  let marker=ok (Broker.publish broker source) in
  let id=grant broker source marker in
  ignore (claim broker id);
  Broker.revoke broker;
  release broker id;
  check bool "a released original claim cannot restart after retirement" true
    (Result.is_error (Broker.claim broker ~id ~actor ~route ~verb));
  check bool "unknown release cannot create a grant" true
    (Result.is_error (Broker.release broker ~id:"0b000000-0000-4000-8000-000000000099" ~actor ~route ~verb));
  check bool "unpublished original is unconfirmed" true (Result.is_error (Broker.cleanup broker));
  check bool "unpublished source remains" true (Sys.file_exists source))
let with_committed_download f = with_download (fun root source contents broker ->
  let marker=ok (Broker.publish broker source) in let id=grant broker source marker in
  let descriptor=descriptor (claim broker id) in commit broker id (publish root descriptor);
  release broker id;
  f root source contents broker)
let changed_source_is_preserved () = with_committed_download (fun _root source contents broker ->
  let original=Unix.stat source in
  Unix.unlink source;write source contents;Unix.chmod source original.st_perm;
  check bool "identical replacement is a different inode" true ((Unix.stat source).st_ino<>original.st_ino);
  check bool "replaced original blocks cleanup" true (Result.is_error (Broker.cleanup broker));
  check string "identical replacement is preserved" contents (read source);
  check bool "failed cleanup stays unconfirmed" true (Result.is_error (Broker.cleanup broker)))
let changed_contents_are_preserved () = with_committed_download (fun _root source contents broker ->
  let original=Unix.stat source in
  let changed=Bytes.of_string contents in Bytes.set changed 0 '\001';
  write source (Bytes.to_string changed);Unix.utimes source original.st_atime original.st_mtime;
  check int "overwrite preserves the published length" original.st_size (Unix.stat source).st_size;
  check bool "restoring mtime cannot authorize changed bytes" true (Result.is_error (Broker.cleanup broker));
  check string "changed bytes remain" (Bytes.to_string changed) (read source))
let changed_permissions_are_preserved () = with_committed_download (fun _root source contents broker ->
  Unix.chmod source 0o400;
  let first=Broker.cleanup broker in
  check bool "changed permissions block cleanup" true (Result.is_error first);
  Unix.chmod source 0o600;
  let fd=Unix.openfile source [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    check bool "restored properties do not clear the original failure" true (Broker.cleanup broker=first);
    check int "repeated cleanup does not close a reused descriptor" (String.length contents) (Unix.fstat fd).st_size);
  check string "permission failure preserves source" contents (read source))
let changed_parent_is_preserved () = with_committed_download (fun _root source contents broker ->
  let parent=Filename.dirname source in
  let previous=parent ^ ".previous" in
  Unix.rename parent previous;Unix.mkdir parent 0o700;
  Unix.rename (Filename.concat previous (Filename.basename source)) source;
  Unix.rmdir previous;
  check bool "replacement parent cannot authorize deletion of the same file" true (Result.is_error (Broker.cleanup broker));
  check string "source in replaced parent remains" contents (read source))
let duplicate_snapshots_settle () = with_committed_download (fun root source _contents broker ->
  let marker=ok (Broker.publish broker source) in let id=grant broker source marker in
  let descriptor=descriptor (claim broker id) in commit broker id (publish root descriptor);
  release broker id;
  ok (Broker.cleanup broker);ok (Broker.cleanup broker);
  check bool "duplicate snapshots share only the original source deletion" false (Sys.file_exists source))
let unconfirmed_backend_preserves_files () = with_committed_download (fun _root source contents broker ->
  let first=Broker.abandon broker in
  check bool "unconfirmed backend cannot authorize deletion" true (Result.is_error first);
  check bool "abandoned descriptors cannot be readmitted" true (Result.is_error (Broker.publish broker source));
  check bool "later cleanup retains the unconfirmed result" true (Broker.cleanup broker=first);
  check string "unconfirmed backend preserves source" contents (read source))
let partial_is_preserved () = with_download (fun _root source _contents broker ->
  check bool "unobserved completed or partial files block cleanup" true (Result.is_error (Broker.cleanup broker));
  check bool "unobserved source is retained" true (Sys.file_exists source))
let () = run "browser Addon download ownership" ["transfer",[
  test_case "published bytes survive retirement after source metadata finalization" `Quick durable_roundtrip;
  test_case "retirement fences claims but permits exact release" `Quick retirement_and_unpublished;
  test_case "original source replacement cannot authorize deletion" `Quick changed_source_is_preserved;
  test_case "same-length contents cannot inherit the published digest" `Quick changed_contents_are_preserved;
  test_case "changed permissions retain a sticky failure and release descriptors" `Quick changed_permissions_are_preserved;
  test_case "replacement parent cannot inherit source ownership" `Quick changed_parent_is_preserved;
  test_case "duplicate snapshots settle one original source" `Quick duplicate_snapshots_settle;
  test_case "unconfirmed backend releases pins without deleting files" `Quick unconfirmed_backend_preserves_files;
  test_case "unknown downloads survive retirement" `Quick partial_is_preserved]]
