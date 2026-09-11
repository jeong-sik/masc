module Actions = Server_runtime_setup_actions
let save path text = Out_channel.with_open_bin path (fun channel -> output_string channel text)
let get = function Ok value -> value | Error e -> Alcotest.fail (Actions.error_message e)
let fixture test = Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
  let base=Filename.temp_dir "masc-web-setup-test-" "" |> Unix.realpath in
  let previous=Sys.getenv_opt "XDG_CONFIG_HOME" in
  Unix.putenv "XDG_CONFIG_HOME" base;
  Eio.Switch.on_release sw (fun () -> Unix.putenv "XDG_CONFIG_HOME" (Option.value previous ~default:""); Fs_compat.remove_tree base);
  let masc=Common.masc_dir_from_base_path ~base_path:base in Unix.mkdir masc 0o700;
  let config=Filename.concat masc "config" in Unix.mkdir config 0o700;
  let runtime=Filename.concat config "runtime.toml" in
  let spec=Runtime_setup_spec.of_json (`Assoc ["choice",`String "codex";"model",`String "old";
    "max_context",`Int 1024;"tools",`Bool true;"streaming",`Bool true]) |> Result.get_ok in
  let rendered=Runtime_setup_spec.render spec in
  save runtime ("[runtime]\ndefault = " ^ Yojson.Safe.to_string (`String rendered.runtime_id) ^ "\n" ^ rendered.runtime_toml);
  let python=match Process_eio.run_argv_with_status_split_or_refusal ["python3";"-c";"import sys;print(sys.executable)"] with
    | Ok (Unix.WEXITED 0,s,_) -> String.trim s | _ -> Alcotest.fail "Python fixture unavailable" in
  let binary=Filename.concat base "native-fixture" in
  save binary ("#!" ^ python ^ {|
import json,sys
args=sys.argv[1:]
assert args[1]=='--base-path'
if args[0]=='runtime-default-set':
    assert args[4:6]==['--setup-lanes','--setup-imp']
elif args[0]=='runtime-verify':
    print(json.dumps({'schema':'masc.runtime_verification.v1','runtime_id':args[3],
      'status':'verified','checks':{'response':True,'tool_roundtrip':True}}))
else: raise AssertionError(args)
|}); Unix.chmod binary 0o700;
  test base runtime binary))
let request base source =
  let revision=Runtime_setup_batch.observe ~base_path:base |> Result.get_ok |> Runtime_setup_batch.revision_to_string in
  `Assoc ["revision",`String revision;
    "connections",`List [`Assoc ["source",source;"models",`List [
      `Assoc ["id",`String "selected-model";"context",`Int 1024;"streaming",`Bool true]]]];
    "selection",`List [`Assoc ["connection",`Int 0;"model",`Int 0]]]
let source fields = `Assoc (["integration_id",`String "vllm";"endpoint",`String "http://127.0.0.1:19001/v1"] @ fields)
let test_private_key () = fixture (fun base runtime binary ->
  let receipt=get (Actions.save ~binary ~base_path:base (request base (source ["api_key",`String "fixture-secret-key"]))) in
  let config=Runtime_toml.parse_file runtime |> Result.get_ok in
  let paths=List.filter_map (fun (p:Runtime_schema.provider) -> match p.credentials with
    | Some (Runtime_schema.File path) -> Some path | _ -> None) config.providers in
  Alcotest.check Alcotest.int "one committed private key" 1 (List.length paths);
  let path=List.hd paths in
  Alcotest.check Alcotest.int "key remains private after request cleanup" 0o600 (Unix.stat path).st_perm;
  Alcotest.check Alcotest.string "key material correct" "fixture-secret-key" (In_channel.with_open_bin path In_channel.input_all);
  let open Yojson.Safe.Util in
  Alcotest.check Alcotest.string "response/tool verified scope" "verified" (receipt |> member "readiness" |> to_string);
  let keys=receipt |> to_assoc |> List.map fst |> List.sort String.compare in
  Alcotest.check (Alcotest.list Alcotest.string) "safe receipt fields only"
    (List.sort String.compare ["runtime_id";"runtime_ids";"models";"configured";"validation";"readiness"]) keys)
let test_forbidden_reference () = fixture (fun base runtime binary ->
  let before=In_channel.with_open_bin runtime In_channel.input_all in
  List.iter (fun fields ->
    Alcotest.check Alcotest.bool "browser cannot supply private files or commands" true
      (Actions.save ~binary ~base_path:base (request base (source fields)) = Error Actions.Invalid_request))
    [["credential_file",`String "/private/credential"];["command",`String "/untrusted/program"]];
  Alcotest.check Alcotest.string "invalid request preserves configuration" before (In_channel.with_open_bin runtime In_channel.input_all))
let () = Alcotest.run "web setup actions" ["request boundary",[
  Alcotest.test_case "private key joins verified native save" `Quick test_private_key;
  Alcotest.test_case "no browser credential paths or executable override" `Quick test_forbidden_reference]]
