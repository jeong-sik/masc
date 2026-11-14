(* masc_runtime_verify against a discovered endpoint: the row for one
   endpoint reports what discovery observed and nothing it did not. *)

let respond_json body = Cohttp_eio.Server.respond_string ~status:`OK ~body ()

(* A llama.cpp-shaped server whose /slots request fails. Its slot count is
   still known, from /props. *)
let handler _conn req body =
  ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
  match Uri.path (Cohttp.Request.uri req) with
  | "/health" -> Cohttp_eio.Server.respond_string ~status:`OK ~body:"ok" ()
  | "/v1/models" -> respond_json {|{"data":[{"id":"qwen-local","owned_by":"llamacpp"}]}|}
  | "/props" ->
    respond_json
      {|{"total_slots":4,"default_generation_settings":{"n_ctx":8192,"model":"qwen-local"}}|}
  | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()

let verify_against_mock_endpoint () =
  let result = ref None in
  (Eio_main.run @@ fun env ->
   try
     Eio.Switch.run @@ fun sw ->
     let socket =
       Eio.Net.listen env#net ~sw ~backlog:16 ~reuse_addr:true
         (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
     in
     let port =
       match Eio.Net.listening_addr socket with
       | `Tcp (_, port) -> port
       | `Unix _ -> Alcotest.fail "expected a TCP listener"
     in
     let server = Cohttp_eio.Server.make ~callback:handler () in
     Eio.Fiber.fork ~sw (fun () ->
       Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
     let url = Printf.sprintf "http://127.0.0.1:%d" port in
     let net = (env#net :> [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t) in
     let clock = (env#clock :> float Eio.Time.clock_ty Eio.Resource.t) in
     Discovery_cache.set_env ~sw ~net ~clock;
     let declared =
       Llm_provider.Discovery.endpoint
         ~protocol:Llm_provider.Discovery.Openai_compatible
         ~capabilities:Llm_provider.Capabilities.openai_compat_chat_capabilities url
     in
     (match
        Llm_provider.Provider_registry.refresh_llama_endpoints ~sw ~net
          ~endpoints:[ declared ] ()
      with
      | Ok _ -> ()
      | Error _ -> Alcotest.fail "mock endpoint was not admitted by discovery");
     result := Some (Masc.Tool_local_runtime_verify.runtime_verify_json ());
     Eio.Switch.fail sw Exit
   with
   | Unix.Unix_error ((Unix.EPERM | Unix.EADDRINUSE), "bind", _) -> Alcotest.skip ()
   | Exit -> ());
  match !result with
  | Some json -> json
  | None -> Alcotest.fail "verification did not run"

let test_row_reports_only_what_discovery_observed () =
  let open Yojson.Safe.Util in
  let result = verify_against_mock_endpoint () in
  let row =
    match result |> member "runtimes" |> to_list with
    | [ row ] -> row
    | rows -> Alcotest.failf "expected one runtime row, got %d" (List.length rows)
  in
  (* The /slots request answered 404 and the health request is the only one
     whose status discovery ever looked at, so no key may state an HTTP
     status. *)
  Alcotest.(check (list string)) "row states no HTTP status" []
    (List.filter (String.ends_with ~suffix:"_status_code") (keys row));
  Alcotest.(check bool) "endpoint answered discovery" true
    (row |> member "provider_reachable" |> to_bool);
  Alcotest.(check bool) "props answer is present" true
    (row |> member "props_observed" |> to_bool);
  Alcotest.(check bool) "model list is present" true
    (row |> member "models_observed" |> to_bool);
  Alcotest.(check (option int)) "slot count comes from props" (Some 4)
    (row |> member "actual_slots" |> to_int_option);
  Alcotest.(check (option int)) "ctx comes from props" (Some 8192)
    (row |> member "actual_ctx" |> to_int_option)

let () =
  Alcotest.run "test_runtime_verify_discovered_row"
    [
      ( "runtime_verify",
        [
          Alcotest.test_case "row reports only what discovery observed" `Quick
            test_row_reports_only_what_discovery_observed;
        ] );
    ]
