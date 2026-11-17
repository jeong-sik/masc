(** Real validate-stores invocation over public media-original constructors.
    No reader, shim, socket or remote program is executed by this fixture. *)
open Alcotest
open Masc

module History = Agent_core.History
module Original = Keeper_media_reading_original
module Media_owner = Keeper_media_reading_owner
module Owner = Lane_addon_tool_request_owner
module Store = Lane_addon_store
module Request = Keeper_sandbox_remote.Stdio_request

let get = function Ok value -> value | Error detail -> fail detail
let original result = get (Result.map_error Original.error_to_string result)
let media_owned result = get (Result.map_error Media_owner.error_to_string result)
let owned result = get (Result.map_error Owner.error_to_string result)

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
    Unix.unlink path

type fixture =
  { parent : string
  ; base_path : string
  ; store : Store.t
  ; retained : Owner.retained
  }

let with_fixture use =
  let parent = Unix.realpath (Filename.temp_dir "media-original-preflight-" "") in
  Fun.protect ~finally:(fun () -> remove_tree parent) (fun () ->
    let base_path = Filename.concat parent "workspace" in
    Unix.mkdir base_path 0o700;
    let masc_dir = Config_dir_resolver.masc_root ~base_path in
    Unix.mkdir masc_dir 0o700;
    let store = Store.create ~root:(Store.directory ~masc_dir) in
    let keeper_name = "preflight-reader" in
    let owner = original (Original.observe_owner ~base_path ~keeper_name) in
    let media_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document" in
    let media_store = Tool_blob_media_store.of_base_path ~base_path in
    (* This checks retained input integrity, not whether these bytes form DOCX. *)
    let stored = get (Result.map_error History.show_media_error
      (media_store.put ~media_type ~raw:"preflight media bytes\000\255")) in
    let subject = original (Original.subject owner ~kind:Media_reading_kind.Document
      ~media_type stored) in
    let source = original (Original.verify_source ~media_store subject) in
    let declaration : Runtime_schema.media_reader_decl =
      { id = "preflight-reader"; revision = "fixture-v1";
        kind = Media_reading_kind.Document; media_types = [media_type];
        adapter = Runtime_schema.Markitdown_mcp;
        command = "/never-executed-media-reader"; args = ["--stdio"; ""] }
    in
    let endpoint = Keeper_sandbox_remote.of_agent_socket ~base_path ~keeper_name
        ~remote_root:(Filename.concat base_path "remote")
        ~gh_config_dir:(Filename.concat base_path "remote-gh") ~injected_env:[]
        ~env_allowlist:[] ~connect_timeout_sec:1 ~max_concurrent_sessions:1
        ~container_name:"media-preflight" ~shim_path:"masc-exec-shim"
        ~host_socket:(Filename.concat base_path "never-connect.sock")
        ~expected:{Keeper_guest_socket.uid=Unix.getuid (); gid=Unix.getgid ()} in
    let argv = declaration.command :: declaration.args in
    let prepared = match Request.prepare ~timeout_sec:10. endpoint ~argv ~env:[||] ~cwd:None with
      | Ok prepared -> prepared
      | Error _ -> fail "public preparation refused the isolated fixture" in
    let launch = match Request.binding prepared ~base_path ~keeper_name ~expected_argv:argv with
      | Ok launch -> launch
      | Error (Request.Owner_mismatch | Request.Payload_argv_mismatch) ->
        fail "public binding refused the fixture owner or declaration" in
    let continuation_channel = get (Keeper_continuation_channel.dashboard
      ~thread_id:"media-preflight-thread") in
    let captured = original (Original.create ~execution_id:"preflight-reserved-execution"
      ~source ~declaration ~launch ~causal_context:None ~task_id:None ~continuation_channel) in
    let retained = Media_owner.record (media_owned (Media_owner.retain ~store captured)) in
    use { parent; base_path; store; retained })

let canonical json = get (Lane_addon_action.canonical json)

let replace key value = function
  | `Assoc fields when List.mem_assoc key fields ->
    `Assoc (List.map (fun (name, old) -> name, if name = key then value else old) fields)
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    fail ("fixture expected object field " ^ key)

let member key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value | None -> fail ("fixture missing field " ^ key))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    fail "fixture expected an object"

let generic_load fixture =
  match owned (Owner.load ~store:fixture.store ~scope:Media_owner.scope
      ~request_id:fixture.retained.request_id) with
  | Some retained -> retained
  | None -> fail "fixture owner record disappeared"

let corrupt_semantic_body fixture =
  let request = fixture.retained.request in
  let capture = member "capture" request in
  let arguments = replace "uri" (`String "data:application/pdf;base64,YQ==")
      (member "arguments" capture) in
  let request = canonical (replace "capture" (replace "arguments" arguments capture) request) in
  let bytes = Yojson.Safe.to_string request in
  let digest = Store.digest bytes in
  get (Store.save_tool_request_body fixture.store ~scope:Media_owner.scope
    ~request_digest:digest bytes);
  let summary = replace "original_digest" (`String digest) fixture.retained.summary in
  let record = Owner.to_json fixture.retained
    |> replace "request_digest" (`String digest)
    |> replace "summary" summary |> canonical in
  get (Store.save_tool_request_owner fixture.store ~scope:Media_owner.scope
    ~request_id:fixture.retained.request_id record);
  let loaded = generic_load fixture in
  check string "generic reader verified the replacement body digest" digest loaded.request_digest;
  check bool "generic reader restored the complete corrupt semantic body" true
    (Yojson.Safe.equal request loaded.request)

let corrupt_host_header fixture =
  let foreign = Owner.installation_id (Owner.Manual "different-media-host") in
  let record = Owner.to_json fixture.retained
    |> replace "installation_id" (`String foreign) |> canonical in
  get (Store.save_tool_request_owner fixture.store ~scope:Media_owner.scope
    ~request_id:fixture.retained.request_id record);
  let loaded = generic_load fixture in
  check string "generic reader accepts the well-formed foreign host identity"
    foreign loaded.installation_id;
  check string "header corruption keeps the valid body digest"
    fixture.retained.request_digest loaded.request_digest

type output = { status : Unix.process_status; stdout : string; stderr : string }

let invoke helper fixture =
  let out_path = Filename.concat fixture.parent "preflight.stdout" in
  let err_path = Filename.concat fixture.parent "preflight.stderr" in
  let out_fd = Unix.openfile out_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC] 0o600 in
  let pid = Fun.protect ~finally:(fun () -> Unix.close out_fd) (fun () ->
    let err_fd = Unix.openfile err_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC] 0o600 in
    Fun.protect ~finally:(fun () -> Unix.close err_fd) (fun () ->
      let env = Config_dir_resolver.environment_for_workspace ~cwd:fixture.base_path
          ~base_path:fixture.base_path ~env:(Unix.environment ()) in
      Unix.create_process_env helper
        [|helper; "validate-stores"; "--base-path"; fixture.base_path; "--jobs"; "1"|]
        env Unix.stdin out_fd err_fd)) in
  let rec wait () =
    match Unix.waitpid [] pid with
    | _, status -> status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait () in
  let status = wait () in
  let read path = In_channel.with_open_bin path In_channel.input_all in
  { status; stdout = read out_path; stderr = read err_path }

let contains text part =
  let rec loop offset =
    offset + String.length part <= String.length text
    && (String.sub text offset (String.length part) = part || loop (offset + 1)) in
  loop 0

let check_output output condition detail =
  if not condition then failf "%s\nstdout:\n%s\nstderr:\n%s"
    detail output.stdout output.stderr

let check_unchanged fixture before =
  let after = generic_load fixture in
  check bool "preflight preserves owner metadata" true
    (Yojson.Safe.equal (Owner.to_json before) (Owner.to_json after));
  check bool "preflight preserves original body" true
    (Yojson.Safe.equal before.Owner.request after.request)

let test_valid helper () = with_fixture (fun fixture ->
  let before = generic_load fixture in
  let output = invoke helper fixture in
  check_output output (output.status = Unix.WEXITED 0) "valid original was refused";
  check_output output
    (List.mem "lane-addon tool request owners rows=1 refused=0" (String.split_on_char '\n' output.stdout))
    "real helper did not accept the retained original row";
  check_unchanged fixture before)

let test_refused helper corrupt expected_detail () = with_fixture (fun fixture ->
  corrupt fixture;
  (* Generic restoration must succeed, so the CLI failure cannot be a raw
     owner/body digest failure instead of the media consumer's decoder. *)
  let before = generic_load fixture in
  let output = invoke helper fixture in
  let refused = match output.status with
    | Unix.WEXITED code -> code <> 0
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false in
  check_output output refused "semantic corruption did not produce a normal CLI refusal";
  check_output output
    (List.mem "lane-addon tool request owners rows=1 refused=1" (String.split_on_char '\n' output.stdout))
    "real helper did not refuse exactly the media original row";
  check_output output (contains output.stdout "consumer original request payload")
    "refusal did not come from the registered consumer decoder";
  check_output output (contains output.stdout expected_detail)
    "refusal did not identify the intended semantic boundary";
  check_unchanged fixture before)

let () =
  match Array.to_list Sys.argv with
  | [program; helper] ->
    let helper = Unix.realpath helper in
    Alcotest.run ~argv:[|program|] "media original deployment preflight"
      ["real helper",
       [test_case "valid retained original is accepted" `Quick (test_valid helper);
        test_case "valid hashes do not hide corrupt adapter input" `Quick
          (test_refused helper corrupt_semantic_body "input URI does not name the exact source MIME");
        test_case "foreign host header is refused" `Quick
          (test_refused helper corrupt_host_header "different host scope, installation, package or tool")]]
  | [] | [_] | _ :: _ :: _ :: _ -> fail "expected the real deployment preflight helper path"
