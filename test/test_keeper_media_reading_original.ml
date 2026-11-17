(** Real original/store fixtures. Guest requests are prepared and bound, never
    connected. Progress facts below are retained test inputs, not observations
    of a tool execution, Gate grant or remote sandbox. *)
open Alcotest
open Masc
module Original = Keeper_media_reading_original
module Owner = Keeper_media_reading_owner
module Generic = Lane_addon_tool_request_owner
module Store = Lane_addon_store
module History = Agent_core.History
module Request = Keeper_sandbox_remote.Stdio_request
module Progress = Lane_addon_request_progress
module Channel = Keeper_continuation_channel

let get show = function Ok value -> value | Error error -> fail (show error)
let original result = get Original.error_to_string result
let owned result = get Owner.error_to_string result
let generic result = get Generic.error_to_string result
let strings result = get Fun.id result
let rejects label = function Ok _ -> fail (label ^ " unexpectedly succeeded") | Error _ -> ()
let json_equal label expected actual = check bool label true (Yojson.Safe.equal expected actual)
let canonical json = strings (Lane_addon_action.canonical json)

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.(S_REG | S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK); _ } -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let save path bytes = Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let load path = In_channel.with_open_bin path In_channel.input_all
let mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
let other_mime = "application/x-media-fixture"
(* Arbitrary retained binary bytes; this is not a valid-DOCX fixture. *)
let raw = "PK\003\004original\000\255\r\n" ^ String.make 8192 'x'

let declaration : Runtime_schema.media_reader_decl =
  { id = " fixture-reader "; revision = " revision-1 "; kind = Media_reading_kind.Document;
    media_types = [mime; other_mime; mime]; adapter = Runtime_schema.Markitdown_mcp;
    command = " fixture-reader-command "; args = [""; " --stdio "; "value with spaces"] }

type fixture =
  { outer : string; base : string; store : Store.t; owner : Original.owner;
    media : History.media_store; stored : History.stored; subject : Original.subject;
    source : Original.verified_source }

let make_store base =
  let masc = Config_dir_resolver.masc_root ~base_path:base in
  Unix.mkdir masc 0o700;
  let root = Store.directory ~masc_dir:masc in
  Unix.mkdir root 0o700;
  Store.create ~root

let with_fixture f =
  let outer = Unix.realpath (Filename.temp_dir "media-original-" "") in
  Fun.protect ~finally:(fun () -> remove_tree outer) (fun () ->
    let base = Filename.concat outer "workspace" in
    Unix.mkdir base 0o700;
    let store = make_store base in
    let owner = original (Original.observe_owner ~base_path:base ~keeper_name:"reader-fixture") in
    let media = History.Memory_store.create () in
    let stored = get History.show_media_error (media.put ~media_type:mime ~raw) in
    let subject = original (Original.subject owner ~kind:Document ~media_type:mime stored) in
    let source = original (Original.verify_source ~media_store:media subject) in
    f { outer; base; store; owner; media; stored; subject; source })

let prepare fixture ~keeper_name argv =
  let endpoint = Keeper_sandbox_remote.of_agent_socket
      ~base_path:fixture.base ~keeper_name ~remote_root:"/workspace"
      ~gh_config_dir:"/workspace/.config/gh" ~injected_env:[] ~env_allowlist:[]
      ~connect_timeout_sec:1 ~max_concurrent_sessions:1 ~container_name:"media-fixture"
      ~shim_path:"/usr/local/bin/masc-exec-shim"
      ~host_socket:(Filename.concat fixture.base "never-connected.sock")
      ~expected:{Keeper_guest_socket.uid=Unix.getuid (); gid=Unix.getgid ()} in
  get (fun _ -> "real Guest request preparation refused")
    (Request.prepare ~timeout_sec:10.0 endpoint ~argv ~env:[||] ~cwd:None)

let binding fixture (decl : Runtime_schema.media_reader_decl) =
  let keeper_name = Original.owner_keeper_name fixture.owner in
  let argv = decl.command :: decl.args in
  let prepared = prepare fixture ~keeper_name argv in
  let bound = get (fun _ -> "real prepared binding refused")
      (Request.binding prepared ~base_path:fixture.base ~keeper_name ~expected_argv:argv) in
  prepared, bound

let context () =
  let admitted = strings (Keeper_approval_origin.admitted_source
      ~snapshot_ref:(Store.digest "fixture intake") ~admitted_revision:3L ~board_post_id:None) in
  let origin = strings (Keeper_approval_origin.admitted_sources ~sources:[admitted]
      ~turn_ref:(Ids.Turn_ref.make ~trace_id:"media-fixture" ~absolute_turn:7)) in
  { Keeper_gate.turn_id=Some 7; origin; snapshot=`Assoc ["captured", `List [`String "first"; `Int 2]] }

let capture ?(decl=declaration) ?(execution_id="reserved-media-1") ?channel fixture =
  let _, launch = binding fixture decl in
  let channel = match channel with
    | Some channel -> channel
    | None -> strings (Channel.slack ~team_id:(Some "team") ~channel_id:"channel"
        ~thread_ts:(Some "thread") ~user_id:"person") in
  original (Original.create ~execution_id ~source:fixture.source ~declaration:decl ~launch
    ~causal_context:(Some (context ())) ~task_id:(Some "task-fixture") ~continuation_channel:channel)

let rec at path json = match path with
  | [] -> json
  | key :: rest ->
    (match json with
     | `Assoc values -> at rest (List.assoc key values)
     | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "fixture JSON path is not an object")

let rec change path f json = match path with
  | [] -> f json
  | key :: rest ->
    (match json with
     | `Assoc values ->
       check bool "fixture mutation names a real field" true (List.mem_assoc key values);
       `Assoc (List.map (fun (name, value) ->
         name, if String.equal name key then change rest f value else value) values)
     | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "fixture JSON mutation is not an object")

let retained fixture value = owned (Owner.retain ~store:fixture.store value)
let ids items = List.map (fun item -> Original.request_id (Owner.original item)) items |> List.sort String.compare

let unknown fixture item =
  match Generic.advance_events ~store:fixture.store ~expected:(Owner.record item)
      ~events:[Progress.Dispatch_intended;
               Progress.Execution_observed (Progress.Outcome_unknown (`Assoc ["fixture", `Bool true]))] with
  | Ok (Generic.Stored record | Generic.Already_stored record) -> record
  | Ok (Generic.Unconfirmed detail) -> fail detail
  | Error error -> fail (Generic.update_error_to_string error)

let check_unknown record =
  check bool "retained outcome remains unknown" true
    (Progress.phase record.Generic.progress =
       Progress.Dispatch_pending (Some (Progress.Outcome_unknown (`Assoc ["fixture", `Bool true]))))

let overwrite_record fixture record transform =
  strings (Store.save_tool_request_owner fixture.store ~scope:Owner.scope
    ~request_id:record.Generic.request_id (canonical (transform (Generic.to_json record))))

let test_complete_round_trip () = with_fixture @@ fun fixture ->
  let value = capture fixture in
  let prepared, _ = binding fixture declaration in
  let item = retained fixture value in
  let record = Owner.record item in
  let body_path = Filename.concat (Store.root fixture.store)
      (Store.tool_request_body_path ~scope:Owner.scope ~request_digest:record.request_digest) in
  let body_bytes = load body_path in
  check string "actual canonical body digest" (Original.original_digest value) (Store.digest body_bytes);
  let disk = Yojson.Safe.from_string body_bytes in
  json_equal "integral host budget is stored as an integer" (`Int 15) (at ["capture"; "launch"; "budget_sec"] disk);
  let restored = original (Original.restore record) in
  json_equal "complete original round trip" (Original.to_json value) (Original.to_json restored);
  check bool "all seven declaration fields preserve exact bytes and order" true
    (Runtime_schema.equal_media_reader_decl declaration (Original.declaration restored));
  check bool "restored launch matches actual preparation" true (Request.matches_binding prepared (Original.launch restored));
  let uri = Original.data_uri restored in
  let comma = String.index uri ',' in
  let decoded = get (fun (`Msg detail) -> detail)
      (Base64.decode (String.sub uri (comma+1) (String.length uri-comma-1))) in
  check string "all original binary input bytes survive" raw decoded;
  json_equal "adapter arguments retain the same full URI" (`Assoc ["uri", `String uri]) (Original.arguments restored);
  json_equal "original origin" (Keeper_approval_origin.to_yojson (context ()).origin)
    (Keeper_approval_origin.to_yojson (Original.origin restored));
  check (option string) "original task" (Some "task-fixture") (Original.task_id restored);
  json_equal "original continuation" (Channel.to_yojson (Original.continuation_channel value))
    (Channel.to_yojson (Original.continuation_channel restored));
  let indexed = original (Original.summary_subject ~request_id:record.request_id
      ~request_digest:record.request_digest record.summary) in
  check bool "official Stored subject survives summary" true (Original.same_subject fixture.subject indexed);
  check bool "capture did not require an existing guest socket" false
    (Sys.file_exists (Filename.concat fixture.base "never-connected.sock"))

let test_wrong_binding_and_source () = with_fixture @@ fun fixture ->
  let prepared, launch = binding fixture declaration in
  (match Request.binding prepared ~base_path:fixture.base ~keeper_name:"another-keeper"
      ~expected_argv:(declaration.command :: declaration.args) with
   | Error Request.Owner_mismatch -> ()
   | Error Request.Payload_argv_mismatch | Ok _ -> fail "wrong prepared owner was not refused");
  (match Request.binding prepared ~base_path:fixture.base ~keeper_name:"reader-fixture" ~expected_argv:["different"] with
   | Error Request.Payload_argv_mismatch -> ()
   | Error Request.Owner_mismatch | Ok _ -> fail "wrong prepared argv was not refused");
  let other = prepare fixture ~keeper_name:"another-keeper" (declaration.command :: declaration.args) in
  let other_launch = get (fun _ -> "other binding refused")
      (Request.binding other ~base_path:fixture.base ~keeper_name:"another-keeper"
        ~expected_argv:(declaration.command :: declaration.args)) in
  let make bound decl = Original.create ~execution_id:"reserved-wrong" ~source:fixture.source
      ~declaration:decl ~launch:bound ~causal_context:None ~task_id:None
      ~continuation_channel:(Channel.unrouted "fixture has no route") in
  rejects "original rejects another binding owner" (make other_launch declaration);
  rejects "original rejects another declaration argv" (make launch {declaration with args=["changed"]});
  let lying_store : History.media_store = { fixture.media with get=(fun _ -> Ok "different raw bytes") } in
  rejects "successful read with the wrong digest is refused"
    (Original.verify_source ~media_store:lying_store fixture.subject);
  let no_context = original (make launch declaration) in
  check bool "absent context retains explicit unavailable origin" true
    (Original.origin no_context = Keeper_approval_origin.unavailable);
  check bool "unrouted channel remains unrouted" false (Channel.is_routable (Original.continuation_channel no_context))

let test_captured_bytes_cannot_be_rebound () = with_fixture @@ fun fixture ->
  let value = capture fixture in
  let body = Original.to_json value in
  let mutations =
    ["source bytes", ["capture";"arguments";"uri"], `String ("data:" ^ mime ^ ";base64,Y2hhbmdlZA==");
     "remote URI", ["capture";"arguments";"uri"], `String "https://example.invalid/document.docx";
     "declaration args", ["capture";"declaration";"args"], `List [`String "other"];
     "declaration digest", ["capture";"declaration_digest"], `String (String.make 64 '0');
     "request ID", ["request_id"], `String ("media-reading-" ^ String.make 64 '0');
     "reserved execution", ["capture";"execution_id"], `String "another-execution";
     "continuation", ["capture";"continuation_channel"], Channel.to_yojson (Channel.unrouted "different route")]
  in
  List.iter (fun (label,path,replacement) -> rejects label
    (Original.of_json (change path (fun _ -> replacement) body))) mutations;
  let duplicate = match body with
    | `Assoc values -> `Assoc (("request_id", `String (Original.request_id value)) :: values)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "original is not an object" in
  rejects "duplicate original field" (Original.of_json duplicate);
  let altered = {declaration with id="overlapping-reader"} in
  let overlap = capture ~decl:altered ~execution_id:"reserved-overlap" fixture in
  check bool "overlapping support keeps the same subject" true
    (Original.same_subject (Original.original_subject value) (Original.original_subject overlap));
  check bool "full declaration changes original identity" false
    (String.equal (Original.request_id value) (Original.request_id overlap));
  List.iter (fun (label, changed) ->
    check bool (label ^ " changes semantic digest without changing ID or revision") false
      (String.equal (Original.declaration_digest declaration) (Original.declaration_digest changed)))
    ["command", {declaration with command="another-command"};
     "argument bytes", {declaration with args=[""; "--stdio"; "value with spaces"]};
     "ordered support", {declaration with media_types=[other_mime; mime; mime]}]

let test_valid_looking_wrong_subject_cannot_hide_unknown () = with_fixture @@ fun fixture ->
  let value = capture fixture in
  let record = unknown fixture (retained fixture value) in
  check_unknown record;
  overwrite_record fixture record (change ["summary";"subject";"source";"media_type"] (fun _ -> `String other_mime));
  let listed = generic (Generic.discover ~store:fixture.store ~scope:Owner.scope) in
  check int "generic metadata is still valid" 1 (List.length listed);
  let reread = match generic (Generic.load ~store:fixture.store ~scope:Owner.scope ~request_id:record.request_id) with
    | Some record -> record | None -> fail "altered summary erased the record" in
  check_unknown reread;
  check string "body digest remains unchanged" record.request_digest reread.request_digest;
  json_equal "body remains unchanged" record.request reread.request;
  rejects "valid-looking different subject cannot filter away the unknown original"
    (Owner.discover_subject ~store:fixture.store fixture.subject)

let test_idempotence_and_prior_originals () = with_fixture @@ fun fixture ->
  let first = capture fixture in
  let record = unknown fixture (retained fixture first) in
  let again = retained fixture first in
  check bool "same-ID retention preserves existing unknown progress" true
    (Generic.same_record record (Owner.record again));
  let revised = {declaration with revision="revision-2"; args=["";"changed"]} in
  let second = capture ~decl:revised ~execution_id:"reserved-media-2" fixture in
  ignore (retained fixture second);
  let absent_source = History.Memory_store.create () in
  rejects "current source is unavailable"
    (Original.verify_source ~media_store:absent_source fixture.subject);
  let restored_reference = get History.stored_error_to_string
      (History.stored ~sha256:fixture.stored.sha256 ~bytes:fixture.stored.bytes) in
  let current_subject = original (Original.subject fixture.owner ~kind:Document ~media_type:mime restored_reference) in
  let inventory = owned (Owner.discover_subject ~store:fixture.store current_subject) |> Owner.originals in
  check (list string) "both originals remain visible without current source or declaration lookup"
    (List.sort String.compare [Original.request_id first; Original.request_id second]) (ids inventory);
  let first_restored = List.find (fun item -> String.equal (Original.request_id (Owner.original item))
      (Original.request_id first)) inventory in
  check_unknown (Owner.record first_restored);
  check string "old declaration is not regenerated" declaration.revision
    (Original.declaration (Owner.original first_restored)).revision

type storage_fault = Header | Summary | Body | Malformed | Not_regular
let fault_label = function
  | Header -> "header" | Summary -> "summary" | Body -> "body"
  | Malformed -> "malformed" | Not_regular -> "not-regular"

let test_store_corruption_refuses () =
  List.iter (fun fault -> with_fixture @@ fun fixture ->
    let value = capture fixture in
    let record = Owner.record (retained fixture value) in
    (match fault with
     | Header -> overwrite_record fixture record (change ["package_id"] (fun _ -> `String "another-package"))
     | Summary -> overwrite_record fixture record (change ["summary";"original_digest"] (fun _ -> `String (String.make 64 '0')))
     | Body ->
       let path = Filename.concat (Store.root fixture.store)
           (Store.tool_request_body_path ~scope:Owner.scope ~request_digest:record.request_digest) in
       save path "{}"
     | Malformed | Not_regular ->
       let entries = strings (Store.tool_request_owner_inventory fixture.store ~scope:Owner.scope) in
       let name = match entries with [name,_] -> name | [] | _ :: _ :: _ -> fail "expected one actual record" in
       let path = Filename.concat (Filename.concat (Filename.concat (Store.root fixture.store)
           Store.tool_request_owners_directory) (Store.digest Owner.scope)) name in
       if fault = Malformed then save path "{"
       else (Unix.unlink path; Unix.mkdir path 0o700));
    rejects (fault_label fault ^ " cannot become an empty inventory") (Owner.discover_subject ~store:fixture.store fixture.subject);
    rejects (fault_label fault ^ " cannot become an absent original") (Owner.load ~store:fixture.store ~owner:fixture.owner
      ~request_id:(Original.request_id value)))
    [Header; Summary; Body; Malformed; Not_regular]

let test_cross_workspace_refuses () = with_fixture @@ fun first -> with_fixture @@ fun second ->
  let value = capture first in
  rejects "wrong store cannot retain" (Owner.retain ~store:second.store value);
  rejects "wrong store cannot load" (Owner.load ~store:second.store ~owner:first.owner ~request_id:(Original.request_id value));
  generic (Generic.retain ~store:second.store ~scope:Owner.scope ~request_id:(Original.request_id value)
    ~installation_id:(Generic.installation_id (Generic.Manual "keeper-media-reader-host"))
    ~package_id:"keeper-media-reader" ~tool:"read" ~summary:(Original.summary value) ~request:(Original.to_json value));
  rejects "another workspace's valid body cannot be filtered into absence"
    (Owner.discover_subject ~store:second.store second.subject)

let test_replaced_root_refuses_absence () = with_fixture @@ fun fixture ->
  let value = capture fixture in
  ignore (retained fixture value);
  Unix.rename fixture.base (Filename.concat fixture.outer "old-workspace");
  Unix.mkdir fixture.base 0o700;
  let replacement = make_store fixture.base in
  check int "replacement store is genuinely empty" 0
    (List.length (generic (Generic.discover ~store:replacement ~scope:Owner.scope)));
  let now = original (Original.observe_owner ~base_path:fixture.base ~keeper_name:"reader-fixture") in
  rejects "same path does not restore the old physical owner" (Original.check_owner ~expected:fixture.owner now);
  rejects "absent lookup with an old owner refuses after root replacement"
    (Owner.load ~store:replacement ~owner:fixture.owner ~request_id:(Original.request_id value));
  rejects "old subject cannot acquire an empty replacement inventory"
    (Owner.discover_subject ~store:replacement fixture.subject);
  rejects "old original cannot be freshly retained in a replacement root"
    (Owner.retain ~store:replacement value)

let () = Alcotest.run "retained media originals"
  ["storage",
   [test_case "complete source declaration context and integer budget restore" `Quick test_complete_round_trip;
    test_case "actual prepared owner argv and source mismatches refuse" `Quick test_wrong_binding_and_source;
    test_case "captured bytes and declaration identity cannot be rebound" `Quick test_captured_bytes_cannot_be_rebound;
    test_case "valid-looking wrong subject cannot hide an unknown original" `Quick test_valid_looking_wrong_subject_cannot_hide_unknown;
    test_case "idempotence and prior declarations survive missing current source" `Quick test_idempotence_and_prior_originals;
    test_case "header summary body and physical inventory corruption refuse" `Quick test_store_corruption_refuses;
    test_case "cross-workspace originals refuse before filtering" `Quick test_cross_workspace_refuses;
    test_case "physical root replacement refuses even absent lookup" `Quick test_replaced_root_refuses_absence]]
