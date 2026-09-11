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
let fake base binary action =
  let python = match Process_eio.run_argv_with_status_split_or_refusal
    ["python3";"-c";"import sys;print(sys.executable)"] with
    | Ok (Unix.WEXITED 0,s,_) -> String.trim s | _ -> Alcotest.fail "Python fixture unavailable" in
  save binary (Printf.sprintf {|#!%s
import json,os,pathlib,sys
base=pathlib.Path(%s)
a=sys.argv[1:]
assert a[1]=='--base-path'
stage=pathlib.Path(a[2]); config=stage/'.masc/config'
assert os.environ['MASC_BASE_PATH']==str(stage)
assert os.environ['MASC_CONFIG_DIR']==str(config)
assert stage!=base
if a[0]=='runtime-default-set':
    assert a[4:6]==['--setup-lanes','--setup-imp']
    (base/'selected.json').write_text(json.dumps([a[3]]+a[7::2]))
    (base/'stage-path').write_text(str(stage))
    p=config/'runtime.toml'
    p.write_text(p.read_text()+'\n# native lane writer fixture\n')
    %s
elif a[0]=='runtime-verify':
    print(json.dumps({'schema':'masc.runtime_verification.v1','runtime_id':a[3],
      'status':'verified','checks':{'response':True,'tool_roundtrip':True}}))
else: raise AssertionError(a)
|} python (Yojson.Safe.to_string (`String base)) action);
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
let test_cas () = fixture (fun base runtime binary spec original ->
  fake base binary "(base/'.masc/config/runtime.toml').write_text('operator concurrent update')";
  let specs=[spec "new"] in let ids=List.map (fun s -> (Runtime_setup_spec.render s).runtime_id) specs in
  let revision=get (Batch.observe ~base_path:base) in
  Alcotest.check Alcotest.bool "concurrent update refused after validator" true
    (apply base binary specs ids revision false=Error Batch.Changed_configuration);
  Alcotest.check Alcotest.string "concurrent bytes preserved" "operator concurrent update" (text runtime);
  save runtime original;
  let revision=get (Batch.observe ~base_path:base) in
  let overlay=Filename.concat (Filename.dirname runtime) "agent-core-models-overlay.toml" in
  save overlay "# independently added overlay\n";
  Alcotest.check Alcotest.bool "overlay participates in revision" true
    (apply base binary specs ids revision false=Error Batch.Changed_configuration))
let test_refusal () = fixture (fun base runtime binary spec original ->
  fake base binary "sys.exit(7)";
  let specs=[spec "new"] in let ids=List.map (fun s -> (Runtime_setup_spec.render s).runtime_id) specs in
  let revision=get (Batch.observe ~base_path:base) in
  Alcotest.check Alcotest.bool "native validation failure preserved" true
    (apply base binary specs ids revision false=Error Batch.Validation_failed);
  Alcotest.check Alcotest.string "runtime bytes untouched" original (text runtime);
  Alcotest.check Alcotest.bool "overlay not published" false
    (Sys.file_exists (Filename.concat (Filename.dirname runtime) "agent-core-models-overlay.toml")))
let test_rollback () = fixture (fun _base runtime _binary _spec original ->
  let overlay = Filename.concat (Filename.dirname runtime) "agent-core-models-overlay.toml" in
  let real path mode contents = Fs_compat.write_file_atomic_strict_staged path ~write:(fun out ->
    Unix.fchmod (Unix.descr_of_out_channel out) mode; output_string out contents) in
  List.iter (fun stage ->
    let injected = ref false in
    let replace path mode contents =
      if path = runtime && not !injected then (
        injected := true;
        (match stage with Fs_compat.Before_rename -> () | Fs_compat.After_rename ->
          (match real path mode contents with Ok () -> () | Error _ -> Alcotest.fail "fixture write failed"));
        Error {Fs_compat.path;stage;exception_=Sys_error "fixture replacement failure";
               backtrace=Printexc.get_callstack 0})
      else real path mode contents in
    Alcotest.check Alcotest.bool "reported write failure restores both files" true
      (Batch.For_testing.publish ~replace ~files:[overlay,"new overlay";runtime,"new runtime"] = Error Batch.Write_failed);
    Alcotest.check Alcotest.string "runtime restored even after visible failed rename" original (text runtime);
    Alcotest.check Alcotest.bool "new overlay removed by rollback" false (Sys.file_exists overlay);
    Alcotest.check Alcotest.int "rollback retains permissions" 0o640 (Unix.stat runtime).st_perm)
    [Fs_compat.Before_rename;Fs_compat.After_rename])
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
let () = Alcotest.run "runtime setup batch" ["workspace",[
  Alcotest.test_case "ordered multi-selection and existing bytes" `Quick test_batch;
  Alcotest.test_case "runtime and overlay compare-and-swap" `Quick test_cas;
  Alcotest.test_case "native refusal publishes nothing" `Quick test_refusal;
  Alcotest.test_case "before and after rename failures restore pair" `Quick test_rollback;
  Alcotest.test_case "credential lifetime joins commit" `Quick test_credential_commit_join]]
