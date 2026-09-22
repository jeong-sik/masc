(* masc_fusion 의 실행별 명단 인자 (RFC fusion-seat-routes §2.4).

   도구는 받을 때 인자 모양을 보고, 적힌 경로를 풀고, 명단을 preset 에 얹어 다시
   검사한다. 셋 중 하나라도 걸리면 실행을 만들지 않는다: 계산이 불리지 않고, 전달
   약속도 실행 기록도 생기지 않는다. 통과한 명단은 계산이 받는 요청, 전달 약속, 실행
   기록에 같은 값으로 남는다. *)

open Alcotest
open Masc

let () = Mirage_crypto_rng_unix.use_default ()

(* test_fusion_official_client_panel 의 런타임 표와 같다. 경로 셋을 준다: HTTP 런타임
   id, CLI 런타임 id, 그리고 둘을 후보로 가진 lane. claude_code 의 command 는 풀기만
   하고 실행하지 않으므로 /usr/bin/true 로 충분하다. *)
let runtime_fixture =
  {|
[runtime]
default = "stub-http.stub-model"

[providers.stub-http]
display-name = "Stub HTTP"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[providers.claude_code]
display-name = "Claude Code Max Subscription"
protocol = "claude-code"
command = "/usr/bin/true"
is-non-interactive = true

[models.stub-model]
api-name = "gpt-5.4"
max-context = 200000
tools-support = true
streaming = true

[stub-http.stub-model]

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true
streaming = true
turn-timeout-s = 0

[claude_code."claude-sonnet-5"]

[runtime.lanes.fusion-judge]
candidates = ["claude_code.claude-sonnet-5", "stub-http.stub-model"]
|}
;;

let http_runtime = "stub-http.stub-model"
let cli_runtime = "claude_code.claude-sonnet-5"
let judge_lane = "fusion-judge"
let keeper = "roster-keeper"
let compute_deadline_s = 10.0

let with_runtime f =
  let path = Filename.temp_file "fusion-tool-roster" ".toml" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       Out_channel.with_open_bin path (fun channel ->
         Out_channel.output_string channel runtime_fixture);
       match Runtime.init_default ~config_path:path with
       | Error detail -> failf "fixture runtime must initialize: %s" detail
       | Ok () -> f ())
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""
;;

(* test_fusion_delivery_obligation 의 [with_temp_base] 와 같은 격리: 이 실행의
   base path, Board 전역 초기화, Eio 파일 시스템. *)
let with_temp_base f =
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "fusion-tool-roster-%d-%06x" (Unix.getpid ()) (Random.bits ()))
  in
  let old_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  let registry = Fusion_run_registry.create () in
  Unix.mkdir base_path 0o700;
  Unix.putenv "MASC_BASE_PATH" base_path;
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Fun.protect
    ~finally:(fun () ->
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      restore_env "MASC_BASE_PATH" old_base_path;
      remove_tree base_path)
    (fun () -> f base_path registry)
;;

let panel_group models : Fusion_policy.panel_group =
  { models
  ; label = ""
  ; system_prompt = "panel system prompt"
  ; web_tools = false
  ; max_output_tokens = None
  ; timeout_s = None
  }
;;

let validated (preset : Fusion_policy.preset) =
  match Fusion_policy.Validated_preset.of_preset preset with
  | Ok preset -> preset
  | Error invalid ->
    failf "test setup: preset %s failed validation: %s" preset.name
      (Fusion_policy.Validated_preset.invalid_to_string invalid)
;;

let preset ~name ~models ~min_answered : Fusion_policy.preset =
  { name
  ; panels = [ panel_group models ]
  ; judge = "judge.model"
  ; judge_system_prompt = "judge system prompt"
  ; judge_max_output_tokens = None
  ; judge_timeout_s = None
  ; judges = []
  ; min_answered
  }
;;

(* "unit" 은 자리 하나에 min_answered 1, "quorum" 은 자리 둘에 min_answered 2. *)
let policy () : Fusion_policy.t =
  { enabled = true
  ; default_preset = "unit"
  ; staged_judge_group_size = Fusion_policy.default_staged_judge_group_size
  ; presets =
      [ validated (preset ~name:"unit" ~models:[ "panel.model" ] ~min_answered:1)
      ; validated
          (preset ~name:"quorum" ~models:[ "panel.a"; "panel.b" ] ~min_answered:2)
      ]
  }
;;

let roster_t = testable Fusion_types.pp_roster Fusion_types.equal_roster

let response_fields response =
  match Yojson.Safe.from_string response with
  | `Assoc fields -> fields
  | json -> failf "tool response is not an object: %s" (Yojson.Safe.to_string json)
;;

let string_member label fields key =
  match List.assoc_opt key fields with
  | Some (`String value) -> value
  | Some json -> failf "%s.%s is not a string: %s" label key (Yojson.Safe.to_string json)
  | None -> failf "%s has no %s" label key
;;

let ok_member fields =
  match List.assoc_opt "ok" fields with
  | Some (`Bool ok) -> ok
  | Some _ | None -> fail "tool response has no boolean ok"
;;

(* 인자 [extra] 로 도구를 한 번 부르고, 거절됐는지와 아무 흔적도 남지 않았는지 본다.
   계산은 뒤쪽 fiber 에서 돌므로, 불렸는지는 switch 가 끝난 뒤에 본다. *)
let expect_rejected_without_run ?(preset = "unit") ~label extra =
  with_runtime (fun () ->
    with_temp_base (fun base_path registry ->
      let compute_called = ref false in
      let fields =
        Eio_main.run (fun env ->
          Fs_compat.set_fs (Eio.Stdenv.fs env);
          Eio.Switch.run (fun sw ->
            let compute ~sw:_ ~net:_ ~policy:_ ~topology:_ ~request:_ () =
              compute_called := true;
              Fusion_orchestrator.Compute_denied Fusion_types.Disabled
            in
            let fields =
              Fusion_tool.For_test.handle_with_compute ~compute ~sw
                ~net:(Eio.Stdenv.net env) ~base_dir:base_path ~keeper ~now_unix:1.0
                ~policy:(policy ()) ~registry
                ~args:
                  (`Assoc
                     (("prompt", `String "Which route should judge this?")
                      :: ("preset", `String preset)
                      :: extra))
                ()
              |> response_fields
            in
            let inventory =
              match Fusion_delivery_obligation.inventory ~base_path with
              | Ok inventory -> inventory
              | Error error -> fail (Fusion_delivery_obligation.error_to_string error)
            in
            check int (label ^ ": no delivery obligation") 0
              (List.length inventory.obligations);
            fields))
      in
      check bool (label ^ ": rejected") false (ok_member fields);
      check int (label ^ ": no run registered") 0
        (List.length (Fusion_run_registry.list_runs registry));
      check bool (label ^ ": computation never ran") false !compute_called;
      fields))
;;

let test_unknown_judge_route_creates_no_run () =
  let fields =
    expect_rejected_without_run ~label:"unknown judge"
      [ "judge", `String "no-such-route" ]
  in
  check string "reason" "unknown_route" (string_member "response" fields "reason");
  check string "the route is named" "no-such-route" (string_member "response" fields "route")
;;

let test_unknown_panel_route_creates_no_run () =
  let fields =
    expect_rejected_without_run ~label:"unknown panel route"
      [ "panel", `List [ `String http_runtime; `String "missing.runtime" ] ]
  in
  check string "reason" "unknown_route" (string_member "response" fields "reason");
  check string "the unknown route is named" "missing.runtime"
    (string_member "response" fields "route")
;;

(* 틀린 모양은 "안 바꿈" 으로 읽지 않는다. *)
let test_wrong_shapes_are_rejected () =
  List.iter
    (fun (label, arg) -> ignore (expect_rejected_without_run ~label [ arg ]))
    [ "judge null", ("judge", `Null)
    ; "judge number", ("judge", `Int 5)
    ; "judge blank", ("judge", `String "   ")
    ; "panel empty", ("panel", `List [])
    ; "panel string", ("panel", `String http_runtime)
    ; "panel with a number", ("panel", `List [ `String http_runtime; `Int 1 ])
    ; "panel with a blank", ("panel", `List [ `String http_runtime; `String "" ])
    ]
;;

(* "quorum" 은 min_answered 2 다. 자리 하나짜리 명단은 줄여 맞추지 않고 거절한다. *)
let test_min_answered_above_new_panel_creates_no_run () =
  let fields =
    expect_rejected_without_run ~preset:"quorum" ~label:"panel below quorum"
      [ "panel", `List [ `String http_runtime ] ]
  in
  check string "reason" "roster_invalid" (string_member "response" fields "reason")
;;

let test_duplicate_panel_route_creates_no_run () =
  let fields =
    expect_rejected_without_run ~label:"duplicate panel route"
      [ "panel", `List [ `String http_runtime; `String http_runtime ] ]
  in
  check string "reason" "roster_invalid" (string_member "response" fields "reason")
;;

let test_accepted_roster_reaches_compute_obligation_and_registry () =
  let expected : Fusion_types.roster =
    { judge_route = Some judge_lane; panel_routes = Some [ http_runtime; cli_runtime ] }
  in
  with_runtime (fun () ->
    with_temp_base (fun base_path registry ->
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Eio.Switch.run (fun sw ->
          let computed, resolve_computed = Eio.Promise.create () in
          let prompt = "Which route should judge this?" in
          let evidence : Fusion_types.deliberation_evidence =
            { question = prompt
            ; panel = []
            ; judge = Error (Fusion_types.Internal_error "roster test terminal")
            ; judges = []
            ; judge_usage = Fusion_types.zero_usage
            ; tool_trace = Fusion_types.empty_tool_trace
            ; seat_routes = []
            }
          in
          let compute ~sw:_ ~net:_ ~policy:_ ~topology:_
                ~(request : Fusion_types.fusion_request) () =
            Eio.Promise.resolve resolve_computed request.roster;
            Fusion_orchestrator.Computed evidence
          in
          let fields =
            Fusion_tool.For_test.handle_with_compute ~compute ~sw
              ~net:(Eio.Stdenv.net env) ~base_dir:base_path ~keeper ~now_unix:2.0
              ~policy:(policy ()) ~registry
              ~args:
                (`Assoc
                   [ "prompt", `String prompt
                   ; "judge", `String (" " ^ judge_lane ^ " ")
                   ; "panel", `List [ `String http_runtime; `String cli_runtime ]
                   ])
              ()
            |> response_fields
          in
          check bool "accepted" true (ok_member fields);
          let run_id = string_member "response" fields "run_id" in
          let obligation =
            match Keeper_chat_delivery_identity.Request_id.of_string run_id with
            | Error detail -> fail detail
            | Ok request_id ->
              (match Fusion_delivery_obligation.load ~base_path ~request_id with
               | Ok obligation -> obligation
               | Error error -> fail (Fusion_delivery_obligation.error_to_string error))
          in
          check roster_t "the delivery obligation carries the trimmed roster" expected
            obligation.payload.roster;
          (match Fusion_run_registry.get registry ~run_id with
           | Some run -> check roster_t "the run registry carries the roster" expected run.roster
           | None -> fail "accepted run is not registered");
          let received =
            Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) compute_deadline_s (fun () ->
              Eio.Promise.await computed)
          in
          check roster_t "the computation receives the roster" expected received))))
;;

let () =
  run
    "fusion_tool_roster"
    [ ( "rfc-fusion-seat-routes-2.4"
      , [ test_case "unknown judge route creates no run" `Quick
            test_unknown_judge_route_creates_no_run
        ; test_case "unknown panel route creates no run" `Quick
            test_unknown_panel_route_creates_no_run
        ; test_case "wrong argument shapes are rejected" `Quick
            test_wrong_shapes_are_rejected
        ; test_case "min_answered above the new panel creates no run" `Quick
            test_min_answered_above_new_panel_creates_no_run
        ; test_case "duplicate panel route creates no run" `Quick
            test_duplicate_panel_route_creates_no_run
        ; test_case "accepted roster reaches compute, obligation and registry" `Quick
            test_accepted_roster_reaches_compute_obligation_and_registry
        ] )
    ]
;;
