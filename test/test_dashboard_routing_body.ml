(** The routing body parser's wire contract: which lanes accept a
    runtime_ids array. A named conversation lane's array body reached the
    route handler dead until 2026-09-12 -- the parser folded named lanes
    into the single-runtime_id branch, so an operator rewriting a failover
    ladder over the API got "runtime_ids required" for a body the handler
    was built to accept (live incident: the ladder had to be edited by
    hand). These cases pin the parser to the handler's shape.

    The named-lane cases need a declared lane because the parser validates
    the lane id against the loaded runtime registry before the body shape
    is even read; the fixture below declares the same lane the body
    names. *)

module Routes = Server_routes_http_routes_dashboard

let parse = Routes.For_testing.parse_runtime_route_body

let rec rm_rf path =
  if Sys.file_exists path
  then (
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path)
;;

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
;;

let with_declared_lane f =
  let catalog = Filename.temp_file "routing-body-models" ".toml" in
  let previous_catalog = Llm_provider.Model_catalog.global () in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      (match previous_catalog with
       | Some value -> Llm_provider.Model_catalog.set_global value
       | None -> Llm_provider.Model_catalog.clear_global ());
      Runtime.For_testing.restore runtime_snapshot;
      rm_rf catalog)
    (fun () ->
      write_file catalog
        {|[[models]]
id_prefix = "qwen"
provider_name = "runpod_mtp"
base = "openai_chat"
max_context_tokens = 128000
supports_tools = true
|}
      ;
      (match Llm_provider.Model_catalog.load_file catalog with
       | Error detail -> Alcotest.failf "catalog fixture: %s" detail
       | Ok loaded ->
         Llm_provider.Model_catalog.set_global loaded);
      with_temp_dir "routing-body-runtime" @@ fun dir ->
      let path = Filename.concat dir "runtime.toml" in
      write_file path
        {|[providers.runpod_mtp]
display-name = "RunPod"
protocol = "openai-compatible-http"
endpoint = "https://runpod.example/v1"

[models.qwen]
api-name = "qwen"
max-context = 128000

[runpod_mtp.qwen]

[runtime]
default = "runpod_mtp.qwen"

[runtime.lanes."runpod_mtp.qwen"]
candidates = ["runpod_mtp.qwen"]
|}
      ;
      (match Runtime.init_default ~config_path:path with
       | Ok () -> ()
       | Error detail -> Alcotest.failf "runtime init failed: %s" detail);
      f ())
;;

let check_case name body lane field ids =
  with_declared_lane (fun () ->
      match parse body with
      | Error detail -> Alcotest.failf "%s: expected Ok, got %s" name detail
      | Ok (got_lane, got_field, got_ids) ->
        Alcotest.(check string) (name ^ " lane") lane got_lane;
        Alcotest.(check string) (name ^ " field") field got_field;
        Alcotest.(check (list string)) (name ^ " ids") ids got_ids)
;;

let () =
  Alcotest.run "dashboard_routing_body"
    [ ( "parse"
      , [ Alcotest.test_case "named lane accepts a runtime_ids array" `Quick
            (fun () ->
              check_case "named"
                {|{"lane":"runpod_mtp.qwen","runtime_ids":["runpod_mtp.qwen","openai.gpt"]}|}
                "runpod_mtp.qwen" "runtime_ids"
                [ "runpod_mtp.qwen"; "openai.gpt" ])
        ; Alcotest.test_case "named lane without runtime_ids is an error" `Quick
            (fun () ->
              with_declared_lane (fun () ->
                  match parse {|{"lane":"runpod_mtp.qwen"}|} with
                  | Ok _ -> Alcotest.fail "expected the array field to be required"
                  | Error detail ->
                    Alcotest.(check bool) "names the required field"
                      (String.length detail > 0)
                      true))
        ; Alcotest.test_case "default keeps the single runtime_id field" `Quick
            (fun () ->
              check_case "default"
                {|{"lane":"default","runtime_id":"runpod_mtp.qwen"}|}
                "default" "runtime_id" [ "runpod_mtp.qwen" ])
        ; Alcotest.test_case "exact lane accepts a runtime_ids array" `Quick
            (fun () ->
              check_case "exact"
                {|{"lane":"exact/verifier_exact","runtime_ids":["runpod_mtp.qwen"]}|}
                "exact/verifier_exact" "runtime_ids"
                [ "runpod_mtp.qwen" ])
        ] )
    ]
