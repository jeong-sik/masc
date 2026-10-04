module Batch = Runtime_setup_batch
let get = function Ok value -> value | Error error -> Alcotest.fail (Batch.error_message error)
let text path = In_channel.with_open_bin path In_channel.input_all
let save path value = Out_channel.with_open_bin path (fun out -> output_string out value)
let fixture run =
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let base = Filename.temp_dir "masc-batch-test-" "" |> Unix.realpath in
    Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base);
    let masc = Common.masc_dir_from_base_path ~base_path:base in
    Unix.mkdir masc 0o700;
    let config = Filename.concat masc "config" in Unix.mkdir config 0o700;
    let runtime = Filename.concat config "runtime.toml" in
    let spec model = Runtime_setup_spec.of_json (`Assoc [
      "choice",`String "codex";"model",`String model;"max_context",`Int 1024;
      "tools",`Bool true;"streaming",`Bool true]) |> function
      | Ok value -> value | Error error -> Alcotest.fail (Runtime_setup_spec.error_message error) in
    let old = Runtime_setup_spec.render (spec "old-model") in
    let original = "# retained operator comment\n[runtime]\ndefault = " ^ Yojson.Safe.to_string (`String old.runtime_id)
      ^ "\n[runtime.assignments]\nother = " ^ Yojson.Safe.to_string (`String old.runtime_id) ^ "\n" ^ old.runtime_toml in
    save runtime original; Unix.chmod runtime 0o640;
    let binary = Filename.concat base "native-fixture" in
    run base runtime binary spec original))
let verified_report = "print(report(a[3]))"
let fake ?(verify=verified_report) base binary action =
  let python = match Process_eio.run_argv_with_status_split_or_refusal
    ["python3";"-c";"import sys;print(sys.executable)"] with
    | Ok (Unix.WEXITED 0,s,_) -> String.trim s | _ -> Alcotest.fail "Python fixture unavailable" in
  save binary (Printf.sprintf {|#!%s
import json,os,pathlib,sys
base=pathlib.Path(%s)
def report(runtime_id,status='verified',failure=None,model='fixture-model'):
    ok=failure is None
    return json.dumps({'schema':'masc.runtime_verification.v1','runtime_id':runtime_id,'model':model,
      'observed_model':model,'status':status,'checks':{'response':ok,'tool_called':ok,'tool_roundtrip':ok},'failure':failure})
a=sys.argv[1:]
assert a[1]=='--base-path'
stage=pathlib.Path(a[2]); config=stage/'.masc/config'
assert os.environ['MASC_BASE_PATH']==str(stage)
assert os.environ['MASC_CONFIG_DIR']==str(config)
assert stage!=base
if a[0]=='runtime-default-set':
    if len(a)>4: assert a[4:6]==['--setup-lanes','--setup-imp']
    (base/'selected.json').write_text(json.dumps([a[3]]+a[7::2]))
    (base/'stage-path').write_text(str(stage))
    p=config/'runtime.toml'
    p.write_text(p.read_text()+'\n# native lane writer fixture\n')
    %s
elif a[0]=='runtime-verify':
    with (base/'verified.jsonl').open('a') as f: f.write(json.dumps(a[3])+'\n')
    %s
else: raise AssertionError(a)
|} python (Yojson.Safe.to_string (`String base)) action verify);
  Unix.chmod binary 0o700
let apply base binary specs ids revision verify =
  Batch.configure ~binary ~base_path:base ~expected_revision:revision ~specs
    ~runtime_ids:ids ~default_runtime_id:(List.hd ids) ~verify ()
let test_batch () = fixture (fun base runtime binary spec original ->
  fake base binary "pass";
  let specs = [spec "new-a";spec "new-b"] in
  let ids = List.map (fun s -> (Runtime_setup_spec.render s).runtime_id) specs |> List.rev in
  let revision = get (Batch.observe ~base_path:base) in
  let receipt = get (apply base binary specs ids revision true) in
  Alcotest.check (Alcotest.list Alcotest.string) "explicit ordered primary/fallback" ids receipt.runtime_ids;
  Alcotest.check Alcotest.bool "verified only after both native probes" true (receipt.readiness=Batch.Verified);
  let command_ids = Yojson.Safe.from_file (Filename.concat base "selected.json") |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_string in
  Alcotest.check (Alcotest.list Alcotest.string) "native lane/imp writer receives order" ids command_ids;
  Alcotest.check Alcotest.bool "operator prefix and assignment retained" true (String.starts_with ~prefix:original (text runtime));
  Alcotest.check Alcotest.int "original permissions retained" 0o640 (Unix.stat runtime).st_perm;
  Alcotest.check Alcotest.bool "stage removed" false (Sys.file_exists (text (Filename.concat base "stage-path")));
  let after = text runtime in
  let next = get (Batch.observe ~base_path:base) in
  ignore (get (apply base binary specs ids next false));
  (* Existing identities must not append the provider/model definitions again. *)
  Alcotest.check Alcotest.string "idempotent connection definitions" (after ^ "\n# native lane writer fixture\n") (text runtime))
let test_named_default_lane () = fixture (fun base runtime binary spec original ->
  let first = (Runtime_setup_spec.render (spec "old-model")).runtime_id in
  let second = Runtime_setup_spec.render (spec "old-fallback") in
  let added = spec "new-account-model" in
  let added_id = (Runtime_setup_spec.render added).runtime_id in
  let lane_id = "conversation.priority" in
  let table lane candidates content = Toml_line_editor.edit_table_multiline_array content
    ~path:("runtime.lanes." ^ Toml_line_editor.render_key lane) ~key:"candidates" ~values:candidates in
  let configured = Toml_line_editor.edit_table_scalar (original ^ second.runtime_toml)
    ~path:"runtime" ~key:"default" ~value:(Some lane_id)
    |> table lane_id [second.runtime_id; first]
    |> table "other-lane" [first] in
  let configured = Toml_line_editor.edit_table_scalar configured
    ~path:"runtime.assignments" ~key:"imp" ~value:(Some "other-lane") in
  let configured = Toml_line_editor.edit_table_multiline_array configured
    ~path:"runtime.exact_output_lanes.hitl_auto_judge" ~key:"cli_slots" ~values:[first] in
  save runtime configured;
  let parsed () = match Runtime_toml.parse_file runtime with
    | Ok config -> config | Error _ -> Alcotest.fail "named route fixture must parse" in
  let before = parsed () in
  let selected = [second.runtime_id; first; added_id] in
  let revision = get (Batch.observe ~base_path:base) in
  fake base binary "assert len(a)==4, 'named route must not reset setup lanes or imp'";
  let receipt = Batch.configure ~default_lane_id:lane_id ~binary ~base_path:base
    ~expected_revision:revision ~specs:[added] ~runtime_ids:selected
    ~default_runtime_id:second.runtime_id ~verify:true () |> get in
  Alcotest.check Alcotest.string "receipt retains named default" lane_id receipt.runtime_id;
  Alcotest.check (Alcotest.list Alcotest.string) "receipt reports concrete candidate order" selected receipt.runtime_ids;
  let after = parsed () in
  Alcotest.check (Alcotest.option Alcotest.string) "default route is not flattened" (Some lane_id) after.default_runtime_id;
  let candidates id = List.find (fun (lane:Runtime_schema.lane_decl) -> lane.id=id) after.lane_decls in
  Alcotest.check (Alcotest.list Alcotest.string) "existing candidates keep order before appended account"
    selected (candidates lane_id).candidate_ids;
  Alcotest.check (Alcotest.list Alcotest.string) "unrelated lane untouched" [first] (candidates "other-lane").candidate_ids;
  Alcotest.check Alcotest.bool "all keeper assignments retained" true (before.keeper_assignments=after.keeper_assignments);
  Alcotest.check Alcotest.bool "exact-output lanes retained" true (before.exact_output_lane_decls=after.exact_output_lane_decls);
  let probes = text (Filename.concat base "verified.jsonl") |> String.split_on_char '\n'
    |> List.filter (fun line -> line<>"") |> List.map (fun line -> Yojson.Safe.from_string line |> Yojson.Safe.Util.to_string) in
  Alcotest.check (Alcotest.list Alcotest.string) "verification probes only the added candidate, never route ID or an existing one" [added_id] probes;
  let saved = text runtime in
  let revision = get (Batch.observe ~base_path:base) in
  Alcotest.check Alcotest.bool "preserve cannot silently switch to an unrelated lane" true
    (Batch.configure ~default_lane_id:"other-lane" ~binary ~base_path:base ~expected_revision:revision
      ~specs:[] ~runtime_ids:selected ~default_runtime_id:second.runtime_id ~verify:false () = Error Batch.Invalid_selection);
  Alcotest.check Alcotest.string "refused lane switch leaves bytes unchanged" saved (text runtime))
(* Verification calls what the save adds, plus the runtime that becomes the
   first call. A runtime already bound stays unprobed when the chain merely
   contains it, so one exhausted old account cannot block adding another. *)
let test_probes_only_what_changes () = fixture (fun base _runtime binary spec _original ->
  let old_id = (Runtime_setup_spec.render (spec "old-model")).runtime_id in
  let added = spec "added-model" in
  let added_id = (Runtime_setup_spec.render added).runtime_id in
  let probed () = let path = Filename.concat base "verified.jsonl" in
    if not (Sys.file_exists path) then [] else
    text path |> String.split_on_char '\n' |> List.filter (fun line -> line<>"")
    |> List.map (fun line -> Yojson.Safe.from_string line |> Yojson.Safe.Util.to_string) in
  fake base binary "pass";
  let revision = get (Batch.observe ~base_path:base) in
  let receipt = get (apply base binary [added] [old_id; added_id] revision true) in
  Alcotest.check (Alcotest.list Alcotest.string) "unchanged primary is not probed, the addition is" [added_id] (probed ());
  Alcotest.check Alcotest.bool "a save that kept a bound runtime unchecked is not verified" true
    (receipt.readiness = Batch.Partly_checked { limited = []; not_rechecked = [old_id] });
  Alcotest.check Alcotest.string "the receipt names what was not checked again" "partly_checked"
    Yojson.Safe.Util.(Batch.receipt_json receipt |> member "readiness" |> to_string);
  Alcotest.check (Alcotest.list Alcotest.string) "the receipt lists it" [old_id]
    Yojson.Safe.Util.(Batch.receipt_json receipt |> member "not_rechecked" |> to_list |> List.map to_string);
  Sys.remove (Filename.concat base "verified.jsonl");
  let promoted = Runtime_setup_spec.render (spec "promoted") in
  let saved = text (Filename.concat (Common.masc_dir_from_base_path ~base_path:base) "config/runtime.toml") in
  save (Filename.concat (Common.masc_dir_from_base_path ~base_path:base) "config/runtime.toml") (saved ^ "\n" ^ promoted.runtime_toml);
  let revision = get (Batch.observe ~base_path:base) in
  let receipt = get (apply base binary [] [promoted.runtime_id; old_id] revision true) in
  Alcotest.check (Alcotest.list Alcotest.string) "an existing runtime promoted to first call is probed alone"
    [promoted.runtime_id] (probed ());
  Alcotest.check Alcotest.bool "the runtime left behind is reported as not checked again" true
    (receipt.readiness = Batch.Partly_checked { limited = []; not_rechecked = [old_id] });
  (* Nothing selected needs a call: no probe runs, and the receipt must not
     read as a verification. *)
  Sys.remove (Filename.concat base "verified.jsonl");
  let revision = get (Batch.observe ~base_path:base) in
  let receipt = get (apply base binary [] [old_id] revision true) in
  Alcotest.check (Alcotest.list Alcotest.string) "reselecting the bound default calls nothing" [] (probed ());
  Alcotest.check Alcotest.bool "reselecting the bound default reports it as not checked again" true
    (receipt.readiness = Batch.Partly_checked { limited = []; not_rechecked = [old_id] }))
let test_cas () = fixture (fun base runtime binary spec original ->
  fake base binary "(base/'.masc/config/runtime.toml').write_text('operator concurrent update')";
  let specs=[spec "new"] in let ids=List.map (fun s -> (Runtime_setup_spec.render s).runtime_id) specs in
  let revision=get (Batch.observe ~base_path:base) in
  Alcotest.check Alcotest.bool "concurrent update refused after validator" true
    (apply base binary specs ids revision false=Error Batch.Changed_configuration);
  Alcotest.check Alcotest.string "concurrent bytes preserved" "operator concurrent update" (text runtime);
  save runtime original)
(* Proves a refusing validator reports how it ended and what it said: exit 2
   with stderr arrives as [Validation_failed { exit; stderr }]. On origin/main
   the same child reports a payload-free [Validation_failed]. *)
let test_refusal () = fixture (fun base runtime binary spec original ->
  fake base binary "sys.stderr.write('fixture: stage rejected\\n'); sys.exit(2)";
  let specs=[spec "new"] in let ids=List.map (fun s -> (Runtime_setup_spec.render s).runtime_id) specs in
  let revision=get (Batch.observe ~base_path:base) in
  Alcotest.check Alcotest.bool "native validation failure carries exit and stderr" true
    (apply base binary specs ids revision false
     = Error (Batch.Validation_failed { exit = Unix.WEXITED 2; stderr = "fixture: stage rejected\n" }));
  Alcotest.check Alcotest.string "runtime bytes untouched" original (text runtime))
(* Proves the verification child's report is read back typed instead of
   string-matched: a failing report carries its code and detail, an unmeasured
   report carries the command's own code, and a document whose status says
   verified while it carries a failure, that carries a key the writer never
   writes, or that names another runtime is refused as unreadable. On
   origin/main the extra-key document passes the literal schema/status/checks
   match and the batch reports the runtime verified; the verified-with-failure
   document was already rejected there, but as a plain verification failure
   rather than as an unreadable report. *)
let test_verification_report () = fixture (fun base _runtime binary spec _original ->
  let specs=[spec "new"] in
  let id=(Runtime_setup_spec.render (spec "new")).runtime_id in
  let revision=get (Batch.observe ~base_path:base) in
  let outcome verify = fake ~verify base binary "pass"; apply base binary specs [id] revision true in
  Alcotest.check Alcotest.bool "failed report carries code, message and detail" true
    (outcome "print(report(a[3],status='failed',failure={'code':'provider_rejected','message':'refused','detail':'HTTP 400 from fixture'})); sys.exit(1)"
     = Error (Batch.Verification_failed { runtime_id = id; code = "provider_rejected"
                                        ; message = "The selected model request failed; check model access, endpoint and authentication."
                                        ; detail = Some "HTTP 400 from fixture" }));
  Alcotest.check Alcotest.bool "unmeasured report carries the command's code" true
    (outcome "print(json.dumps({'schema':'masc.runtime_verification.v1','runtime_id':a[3],'model':None,'observed_model':None,'status':'unavailable','checks':{'response':False,'tool_called':False,'tool_roundtrip':False},'failure':{'code':'runtime_not_configured','message':'not configured','detail':None}})); sys.exit(2)"
     = Error (Batch.Verification_failed { runtime_id = id; code = "runtime_not_configured"; message = "not configured"; detail = None }));
  let unreadable verify = match outcome verify with
    | Error (Batch.Verification_unreadable { runtime_id; exit = Unix.WEXITED 0; stderr = ""; reason = _ }) -> runtime_id = id
    | Ok _
    | Error (Batch.Invalid_selection | Invalid_configuration | Changed_configuration | Configuration_unavailable
            | Child_not_started _ | Validation_failed _ | Commit_refused _ | Verification_failed _
            | Verification_unreadable _ | Write_failed _ | Lock_unavailable) -> false in
  Alcotest.check Alcotest.bool "verified status with a failure attached is refused" true
    (unreadable "print(report(a[3],failure={'code':'timed_out','message':'late','detail':None}))");
  Alcotest.check Alcotest.bool "a key the writer never writes is refused" true
    (unreadable "d=json.loads(report(a[3])); d['extra']='x'; print(json.dumps(d))");
  Alcotest.check Alcotest.bool "a report naming another runtime is refused" true
    (unreadable "print(report('other.runtime'))"))
let contains text part =
  let n = String.length part in
  let rec at i = i + n <= String.length text && (String.sub text i n = part || at (i + 1)) in
  at 0
(* A spent quota or a rate limit is the provider declining for the account's
   usage, not a wrong selection: the runtime is published and named as
   unmeasured while the other selected runtime is still verified. Each code
   starts from the original file, so each pass proves its own publication. A
   different failure later in the same batch still refuses the save and
   publishes nothing. *)
let test_usage_limit_publishes () = fixture (fun base runtime binary spec original ->
  let specs=[spec "verified";spec "limited"] in
  let verified_id, limited_id = match List.map (fun s -> (Runtime_setup_spec.render s).runtime_id) specs with
    | [v; l] -> v, l | _ -> Alcotest.fail "two fixture specs" in
  let limited = Yojson.Safe.to_string (`String limited_id) in
  List.iter (fun code ->
    let verify = Printf.sprintf
      "l=%s; print(report(a[3],status='failed',failure={'code':'%s','message':'m','detail':'fixture %s'}) if a[3]==l else report(a[3])); sys.exit(1 if a[3]==l else 0)"
      limited code code in
    fake ~verify base binary "pass";
    save runtime original;
    let revision=get (Batch.observe ~base_path:base) in
    match apply base binary specs [verified_id; limited_id] revision true with
    | Ok ({ Batch.readiness = Batch.Usage_limited ({ Batch.runtime_id; code = reported }, []); _ } as receipt) ->
      Alcotest.check Alcotest.string (code ^ ": the limited runtime is named") limited_id runtime_id;
      let json = Batch.receipt_json receipt in
      Alcotest.check Alcotest.string (code ^ ": the receipt says usage_limited") "usage_limited"
        Yojson.Safe.Util.(json |> member "readiness" |> to_string);
      Alcotest.check (Alcotest.list (Alcotest.pair Alcotest.string Alcotest.string)) (code ^ ": the receipt lists what was not measured")
        [limited_id, code]
        Yojson.Safe.Util.(json |> member "unverified" |> to_list
          |> List.map (fun row -> (row |> member "runtime_id" |> to_string), (row |> member "code" |> to_string)));
      Alcotest.check Alcotest.string (code ^ ": the report's code is kept") code reported;
      Alcotest.check Alcotest.bool (code ^ ": the limited runtime is published") true
        (contains (text runtime) (Runtime_setup_spec.render (spec "limited")).runtime_toml)
    | Ok _ -> Alcotest.fail (code ^ ": the usage limit was not reported")
    | Error error -> Alcotest.fail (code ^ ": " ^ Batch.error_message error))
    ["quota_exhausted"; "rate_limited"];
  let verify = Printf.sprintf
    "l=%s; print(report(a[3],status='failed',failure=({'code':'quota_exhausted','message':'m','detail':'fixture quota'} if a[3]==l else {'code':'provider_rejected','message':'refused','detail':'HTTP 400 from fixture'}))); sys.exit(1)"
    limited in
  fake ~verify base binary "pass";
  (* The passes above published both runtimes; restore the original so this
     case adds them again and both are probed. *)
  save runtime original;
  let before = text runtime in
  let revision=get (Batch.observe ~base_path:base) in
  Alcotest.check Alcotest.bool "a later non-usage failure still refuses the save" true
    (match apply base binary specs [limited_id; verified_id] revision true with
     | Error (Batch.Verification_failed { runtime_id; code = "provider_rejected"; _ }) -> runtime_id = verified_id
     | Ok _ | Error _ -> false);
  Alcotest.check Alcotest.string "a refused save publishes nothing" before (text runtime))
let test_commit_failures () =
  List.iter (fun stage -> fixture (fun base runtime binary spec original ->
    let registry = Runtime.For_testing.snapshot () in
    Fun.protect ~finally:(fun () -> Runtime.For_testing.restore registry) (fun () ->
      fake base binary "pass";
      let added = spec "atomic-account" in
      let id = (Runtime_setup_spec.render added).runtime_id in
      let revision = get (Batch.observe ~base_path:base) in
      let before = Runtime.get_runtimes () in
      let replace_file path mode contents =
        (match stage with Fs_compat.Before_rename -> () | Fs_compat.After_rename ->
          match Fs_compat.write_file_atomic_strict_staged path ~write:(fun out ->
            Unix.fchmod (Unix.descr_of_out_channel out) mode; output_string out contents) with
          | Ok () -> () | Error _ -> Alcotest.fail "fixture rename failed");
        Error {Fs_compat.path;stage;exception_=Sys_error "fixture storage failure";
               backtrace=Printexc.get_callstack 0} in
      let result = Batch.For_testing.configure ~replace_file ~binary ~base_path:base
        ~expected_revision:revision ~specs:[added] ~runtime_ids:[id]
        ~default_runtime_id:id ~verify:false () in
      match stage, result with
      | Fs_compat.Before_rename, Error (Batch.Write_failed _) ->
        Alcotest.check Alcotest.string "prior bytes preserved" original (text runtime);
        Alcotest.check Alcotest.bool "registry unchanged before rename" true
          (before = Runtime.get_runtimes ())
      | Fs_compat.After_rename, Ok receipt ->
        Alcotest.check Alcotest.bool "visible source is retained" true (text runtime <> original);
        Alcotest.check Alcotest.bool "visible account published" true
          (List.exists (fun (runtime:Runtime_instance.t) -> runtime.id=id) (Runtime.get_runtimes ()));
        Alcotest.check Alcotest.string "HTTP and CLI receipt retains uncertainty" "unconfirmed"
          Yojson.Safe.Util.(Batch.receipt_json receipt |> member "commit" |> member "durability" |> to_string);
        Alcotest.check Alcotest.bool "typed receipt retains uncertainty" true
          (match receipt.commit.durability with Runtime.Durability_unconfirmed _ -> true | Durable -> false)
      | _, Error error -> Alcotest.fail (Batch.error_message error)
      | _, Ok _ -> Alcotest.fail "pre-rename failure reported a commit")))
    [Fs_compat.Before_rename; Fs_compat.After_rename]
let test_lock_release_warning_reaches_receipt () = fixture (fun base runtime binary spec _original ->
  let registry = Runtime.For_testing.snapshot () in
  Fun.protect ~finally:(fun () -> Runtime.For_testing.restore registry) (fun () ->
    fake base binary "pass";
    let added = spec "lock-warning-account" in
    let id = (Runtime_setup_spec.render added).runtime_id in
    let release_failure = { File_lock_eio.lock_path=runtime ^ ".lock";
      phase=File_lock_eio.Release_process_lock;
      cause={File_lock_eio.error=Unix.EIO;operation="private-release-fixture";argument=runtime};
      cleanup_failure=None } in
    let replace_file path mode contents = Fs_compat.write_file_atomic_strict_staged path ~write:(fun out ->
      Unix.fchmod (Unix.descr_of_out_channel out) mode; output_string out contents) in
    let receipt = get (Batch.For_testing.configure ~release_failure ~replace_file ~binary ~base_path:base
      ~expected_revision:(get (Batch.observe ~base_path:base)) ~specs:[added]
      ~runtime_ids:[id] ~default_runtime_id:id ~verify:false ()) in
    Alcotest.check Alcotest.int "completed setup retains its owning lock warning" 1
      (List.length receipt.commit.lock_warnings);
    Alcotest.check Alcotest.bool "lock uncertainty is distinct from storage durability" true
      (receipt.commit.durability=Runtime.Durable);
    let json = Batch.receipt_json receipt in
    Alcotest.check Alcotest.string "safe warning code reaches public receipt"
      {|[{"code":"runtime_config_lock_release_unconfirmed"}]|}
      Yojson.Safe.Util.(json |> member "commit" |> member "warnings" |> Yojson.Safe.to_string);
    Alcotest.check Alcotest.bool "private release diagnostic is not published" false
      (contains (Yojson.Safe.to_string json) "private-release-fixture")))

let test_final_validation_refusal () = fixture (fun base runtime binary spec original ->
  fake base binary "p.write_text('invalid = [')";
  let added = spec "refused-account" in
  let id = (Runtime_setup_spec.render added).runtime_id in
  let revision = get (Batch.observe ~base_path:base) in
  Alcotest.check Alcotest.bool "final validation remains a refusal, not storage failure" true
    (match apply base binary [added] [id] revision false with
     | Error (Batch.Commit_refused _) -> true | Ok _ | Error _ -> false);
  Alcotest.check Alcotest.string "refusal retains original bytes" original (text runtime))
let test_credential_commit_join () = fixture (fun base _runtime binary _spec _original ->
  Eio.Switch.run (fun sw ->
    let previous = Sys.getenv_opt "XDG_CONFIG_HOME" in
    Unix.putenv "XDG_CONFIG_HOME" base;
    Eio.Switch.on_release sw (fun () -> Unix.putenv "XDG_CONFIG_HOME" (Option.value previous ~default:""));
    let pending = match Runtime_setup_credentials.save ~secret:"fixture-private-api-key" () with
      | Ok pending -> pending | Error e -> Alcotest.fail (Runtime_setup_credentials.error_message e) in
    Eio.Switch.on_release sw (fun () -> Runtime_setup_credentials.remove_uncommitted pending);
    let path = Runtime_setup_credentials.reference_path pending in
    let spec = match Runtime_setup_spec.of_json (`Assoc [
      "choice",`String "openai_compatible";"model",`String "selected-model";
      "max_context",`Int 1024;"tools",`Bool true;"streaming",`Bool true;
      "endpoint",`String "https://fixture.invalid/v1";"credential_file",`String path]) with
      | Ok spec -> spec | Error e -> Alcotest.fail (Runtime_setup_spec.error_message e) in
    let id = (Runtime_setup_spec.render spec).runtime_id in
    let revision=get (Batch.observe ~base_path:base) in
    fake base binary "pass";
    ignore (get (Batch.configure ~pending_credentials:[pending] ~binary ~base_path:base
      ~expected_revision:revision ~specs:[spec] ~runtime_ids:[id] ~default_runtime_id:id ~verify:false ()));
    Runtime_setup_credentials.remove_uncommitted pending;
    Alcotest.check Alcotest.bool "committed key survives caller cleanup" true (Sys.file_exists path);
    let rejected = match Runtime_setup_credentials.save ~secret:"unused-fixture-key" () with
      | Ok pending -> pending | Error e -> Alcotest.fail (Runtime_setup_credentials.error_message e) in
    let rejected_path=Runtime_setup_credentials.reference_path rejected in
    ignore (Batch.configure ~pending_credentials:[rejected] ~binary ~base_path:base
      ~expected_revision:revision ~specs:[] ~runtime_ids:[id] ~default_runtime_id:id ~verify:false ());
    Runtime_setup_credentials.remove_uncommitted rejected;
    Alcotest.check Alcotest.bool "stale transaction does not retain unused key" false (Sys.file_exists rejected_path)))
(* 2026-09-15, a MacBook without this repository: the verification child died
   by SIGKILL before its first Claude turn. The summary read "(signal -7; ...)"
   followed by the child's log, and the setup screen dropped the whole sentence
   for its newlines, leaving "Runtime setup did not finish". *)
let test_error_summary_is_one_line () =
  let contains text piece =
    let n = String.length piece and m = String.length text in
    let rec at i = i + n <= m && (String.equal (String.sub text i n) piece || at (i + 1)) in
    at 0 in
  let killed = Batch.Verification_unreadable
    { runtime_id = "setup.runtime"; exit = Unix.WSIGNALED Sys.sigkill
    ; stderr = "[INFO] catalog loaded\n[INFO] bindings loaded\n"
    ; reason = "stdout is not JSON: Blank input data" } in
  let summary = Batch.error_message killed in
  Alcotest.check Alcotest.bool "the summary has no newline" false (String.contains summary '\n');
  Alcotest.check Alcotest.bool "the summary names the signal, not OCaml's number" true
    (contains summary "killed by SIGKILL" && not (contains summary "-7"));
  Alcotest.check Alcotest.bool "the summary leaves the child's log out" false (contains summary "catalog loaded");
  Alcotest.check Alcotest.(option string) "the detail keeps the child's log"
    (Some "[INFO] catalog loaded\n[INFO] bindings loaded") (Batch.error_detail killed);
  let refused = Batch.Validation_failed { exit = Unix.WEXITED 3; stderr = " \n" } in
  Alcotest.check Alcotest.string "a validation refusal says how the validator ended"
    "Selected runtime configuration did not pass validation (exit 3)" (Batch.error_message refused);
  Alcotest.check Alcotest.(option string) "a blank stderr is no detail" None (Batch.error_detail refused);
  Alcotest.check Alcotest.(option string) "an error with no child has no detail" None
    (Batch.error_detail Batch.Lock_unavailable)
(* task-2054: the wizard save used to replace the file and stop there, so the
   account it wrote stayed out of the registry the running server serves until
   a restart. The save now commits through the same path as a routing edit,
   and the saved binding must be callable in-process the moment it lands. *)
let test_save_publishes_the_registry () = fixture (fun base _runtime binary spec _original ->
  let registry = Runtime.For_testing.snapshot () in
  Fun.protect ~finally:(fun () -> Runtime.For_testing.restore registry) (fun () ->
    fake base binary "pass";
    let added = spec "registry-account-model" in
    let id = (Runtime_setup_spec.render added).runtime_id in
    let ids runtime = List.map (fun (one : Runtime_instance.t) -> one.Runtime_instance.id) runtime in
    Alcotest.check Alcotest.bool "the account is not callable before the save" false (List.mem id (ids (Runtime.get_runtimes ())));
    let revision = get (Batch.observe ~base_path:base) in
    ignore (get (apply base binary [added] [id] revision false));
    Alcotest.check Alcotest.bool "the saved account is live in the published registry" true (List.mem id (ids (Runtime.get_runtimes ())))))
let () = Alcotest.run "runtime setup batch" ["workspace",[
  Alcotest.test_case "an error summary is one line and names the signal" `Quick test_error_summary_is_one_line;
  Alcotest.test_case "ordered multi-selection and existing bytes" `Quick test_batch;
  Alcotest.test_case "the saved account is live in the registry without a restart" `Quick test_save_publishes_the_registry;
  Alcotest.test_case "preserve named default lane and candidate order" `Quick test_named_default_lane;
  Alcotest.test_case "runtime compare-and-swap" `Quick test_cas;
  Alcotest.test_case "native refusal publishes nothing" `Quick test_refusal;
  Alcotest.test_case "verification report is read back typed" `Quick test_verification_report;
  Alcotest.test_case "a usage limit publishes the runtime unmeasured" `Quick test_usage_limit_publishes;
  Alcotest.test_case "verification probes only what the save changes" `Quick test_probes_only_what_changes;
  Alcotest.test_case "atomic commit failure preserves visibility and durability" `Quick test_commit_failures;
  Alcotest.test_case "observed lock release warning reaches safe setup receipt" `Quick test_lock_release_warning_reaches_receipt;
  Alcotest.test_case "final validation remains a typed refusal" `Quick test_final_validation_refusal;
  Alcotest.test_case "credential lifetime joins commit" `Quick test_credential_commit_join]]
