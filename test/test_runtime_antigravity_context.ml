open Alcotest
module Context = Runtime_antigravity_context
module Setup = Runtime_antigravity_setup

let model : Setup.model = { id = "selected-model"; label = "Selected Model" }

let payload
      ?(id = "Selected Model")
      ?(version = "1.2.0")
      ?(tokens = 0)
      ?(size = 1048576)
      ()
  =
  `Assoc
    [ "model", `Assoc [ "id", `String id; "display_name", `String "Selected Model" ]
    ; "version", `String version
    ; ( "context_window"
      , `Assoc
          [ "total_input_tokens", `Int tokens
          ; "total_output_tokens", `Int 0
          ; "current_usage", `Null
          ; "context_window_size", `Int size
          ] )
    ]
;;

let transport rows =
  Yojson.Safe.to_string
    (`Assoc
        [ "schema", `String "masc.antigravity_status_transport.v1"
        ; "status", `String "captured"
        ; "records", `List rows
        ])
;;

let parse rows =
  Context.For_testing.parse_transport
    ~model
    ~cli_version:"1.2.0"
    (Unix.WEXITED 0, transport rows, "")
;;

let transport_status status =
  Yojson.Safe.to_string
    (`Assoc
        [ "schema", `String "masc.antigravity_status_transport.v1"
        ; "status", `String status
        ; "records", `List []
        ])
;;

(* Proves that a transport run that did not capture keeps its evidence: the
   shim dying with a non-zero exit carries that status and its stderr tail,
   and the two failure statuses the script writes on exit 0 are told apart as
   typed outcomes. On origin/main every one of these was the bare
   [Command_failed], and an unknown status string was a command failure
   instead of an invalid observation. *)
let test_transport_failure_payload () =
  let run status body stderr =
    Context.For_testing.parse_transport ~model ~cli_version:"1.2.0" (status, body, stderr)
  in
  check
    bool
    "shim exit carries status and stderr tail"
    true
    (run (Unix.WEXITED 1) "" "Traceback\nValueError: invalid context transport arguments\n"
     = Error
         (Context.Command_failed
            { phase = Context.Status_transport
            ; status = Some (Unix.WEXITED 1)
            ; stderr_tail = "Traceback\nValueError: invalid context transport arguments"
            }));
  check
    bool
    "transport failed status is a typed outcome"
    true
    (run (Unix.WEXITED 0) (transport_status "failed") ""
     = Error
         (Context.Command_failed
            { phase = Context.Transport_reported Context.Transport_failed
            ; status = Some (Unix.WEXITED 0)
            ; stderr_tail = ""
            }));
  check
    bool
    "transport interrupted status is a typed outcome"
    true
    (run (Unix.WEXITED 0) (transport_status "interrupted") ""
     = Error
         (Context.Command_failed
            { phase = Context.Transport_reported Context.Transport_interrupted
            ; status = Some (Unix.WEXITED 0)
            ; stderr_tail = ""
            }));
  check
    bool
    "status the script never writes is an invalid observation"
    true
    (run (Unix.WEXITED 0) (transport_status "captured-later") "" = Error Context.Invalid_observation)
;;

let test_authoritative_join () =
  check
    bool
    "exact zero-turn model/version context"
    true
    (parse [ payload () ] = Ok (Setup.Observed_context 1048576));
  List.iter
    (fun rows ->
       check
         bool
         "identity/usage/capacity inconsistency rejected"
         true
         (parse rows = Error Context.Invalid_observation))
    [ [ payload ~id:"another-model" () ]
    ; [ payload ~version:"1.3.0" () ]
    ; [ payload ~tokens:1 () ]
    ; [ payload (); payload ~size:200000 () ]
    ];
  check
    bool
    "reported zero capacity stays unknown"
    true
    (parse [ payload ~size:0 () ] = Ok Setup.Unknown_context)
;;

let python () =
  match
    Process_eio.run_argv_with_status_split_or_refusal
      [ "python3"; "-c"; "import sys; print(sys.executable)" ]
  with
  | Ok (Unix.WEXITED 0, path, _) -> String.trim path
  | _ -> fail "native context fixture requires Python"
;;

let test_native_observe_private_home () =
  let root = Filename.temp_dir "masc-context-native-test-" "" |> Unix.realpath in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree root)
    (fun () ->
       let source = Filename.concat root "selected-oauth" in
       let home_record = Filename.concat root "observed-home" in
       let cli_path = Filename.concat root "fake-agy" in
       let python_path = python () in
       let original = "fixture-oauth-token-never-log" in
       Out_channel.with_open_bin source (fun out -> output_string out original);
       Unix.chmod source 0o600;
       let script =
         Printf.sprintf
           {|#!%s
import json,os,pathlib,subprocess,sys,time
if sys.argv[1:] == ['--version']:
    print('1.2.0')
    sys.exit(0)
assert sys.argv[1:] == ['--model','selected-model']
assert sys.stdin.isatty() and sys.stdout.isatty()
home=pathlib.Path(os.environ['HOME'])
assert pathlib.Path.cwd()==home
pathlib.Path(%s).write_text(str(home))
settings=json.loads((home/'.gemini/antigravity-cli/settings.json').read_text())
assert settings['permissions']['allow']==[]
assert 'command(*)' in settings['permissions']['deny']
assert not (home/'.gemini/antigravity-cli/mcp_config.json').exists()
payload={'model':{'id':'Selected Model','display_name':'Selected Model'},'version':'1.2.0',
 'context_window':{'total_input_tokens':0,'total_output_tokens':0,'context_window_size':1048576,'current_usage':None},
 'email':'do-not-project@example.invalid'}
subprocess.run(settings['statusLine']['command'],shell=True,input=json.dumps(payload),text=True,check=True)
time.sleep(60)
|}
           python_path
           (Yojson.Safe.to_string (`String home_record))
       in
       Out_channel.with_open_bin cli_path (fun out -> output_string out script);
       Unix.chmod cli_path 0o700;
       (match
          Context.observe
            ~python_path
            ~cli_path
            ~timeout_s:10.
            ~oauth_source:source
            ~model
        with
        | Ok (Setup.Observed_context size) ->
          check int "native measured exact context" 1048576 size
        | Ok Unknown_context -> fail "fixture context unexpectedly unknown"
        | Error error -> fail (Context.error_message error));
       check
         string
         "selected auth source unchanged"
         original
         (In_channel.with_open_bin source In_channel.input_all);
       let observed_home = In_channel.with_open_bin home_record In_channel.input_all in
       check
         bool
         "private HOME removed after child cleanup"
         false
         (Sys.file_exists observed_home))
;;

(* Proves that a version probe that exits non-zero reaches the caller with
   the phase, the exit status and the stderr text, and that the receipt
   message renders all three. On origin/main the same fixture yielded the
   bare [Command_failed] whose message named none of them. *)
let test_native_version_probe_failure () =
  let root = Filename.temp_dir "masc-context-probe-test-" "" |> Unix.realpath in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree root)
    (fun () ->
       let source = Filename.concat root "selected-oauth" in
       let cli_path = Filename.concat root "fake-agy" in
       let python_path = python () in
       Out_channel.with_open_bin source (fun out ->
         output_string out "fixture-oauth-token-never-log");
       Unix.chmod source 0o600;
       let refusal = "fixture refuses the version probe" in
       let script =
         Printf.sprintf
           {|#!%s
import sys
assert sys.argv[1:] == ['--version']
sys.stderr.write(%s + '\n')
sys.exit(3)
|}
           python_path
           (Yojson.Safe.to_string (`String refusal))
       in
       Out_channel.with_open_bin cli_path (fun out -> output_string out script);
       Unix.chmod cli_path 0o700;
       match
         Context.observe ~python_path ~cli_path ~timeout_s:10. ~oauth_source:source ~model
       with
       | Ok _ -> fail "fixture version probe unexpectedly succeeded"
       | Error error ->
         check
           bool
           "version probe failure carries phase, exit 3 and stderr"
           true
           (error
            = Context.Command_failed
                { phase = Context.Version_probe
                ; status = Some (Unix.WEXITED 3)
                ; stderr_tail = refusal
                });
         let message = Context.error_message error in
         let mentions needle =
           check
             bool
             (Printf.sprintf "receipt message names %S" needle)
             true
             (String_util.contains_substring message needle)
         in
         mentions "the CLI version probe";
         mentions "exited(3)";
         mentions refusal)
;;

let () =
  run
    "Antigravity context"
    [ ( "status-line authority"
      , [ test_case
            "selected model/version and zero-turn proof"
            `Quick
            test_authoritative_join
        ; test_case
            "transport failure keeps status and stderr"
            `Quick
            test_transport_failure_payload
        ; test_case
            "native transport and private HOME lifecycle"
            `Quick
            test_native_observe_private_home
        ; test_case
            "native version probe failure names phase, exit and stderr"
            `Quick
            test_native_version_probe_failure
        ] )
    ]
;;
