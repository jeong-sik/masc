(** Stagehand's actual callback, original worker queue and shared HTTP runner.
    No real browser, extension or external provider is started. *)
open Alcotest
open Masc
module Model=Browser_addon_stagehand_model
module Models=Browser_addon_models
module Owner=Browser_addon_owner
module Exact=Lane_addon_exact
module F=Exact_output_fixture
let ok = function Ok value -> value | Error _ -> fail "Stagehand Add-on operation failed"
let incarnation="0b000000-0000-4000-8000-000000000010"
let set key value = function `Assoc fields -> `Assoc ((key,value)::List.remove_assoc key fields)
  | _ -> fail "object fixture expected"
let scenario manifest fixture =
  let base_path=Filename.temp_dir "browser-addon-stagehand-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path "config")) (fun () ->
  F.with_official_client_runtimes (fun () ->
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let clock=Eio.Stdenv.clock env and net=Eio.Stdenv.net env in
    Time_compat.set_clock clock;Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Time.with_timeout_exn clock 20. (fun () ->
    Eio_context.with_test_env ~sw ~clock ~net ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
      let package=match Lane_addon_manifest.load ~path:manifest with
        | Ok package -> package
        | Error error -> failf "Stagehand manifest %s: %s" manifest
            (Lane_addon_manifest.error_to_string error) in
      let owner=Owner.create ~incarnation |> ok in
      check bool "unselected model publishes no callback" true (Model.for_owner owner=Ok None);
      let models=Models.create ~incarnation ~configuration:{Models.store_root=Filename.concat base_path "receipts";
        outputs=package.exact_outputs} |> ok in
      Owner.attach_models owner models |> ok;
      let model=match Model.for_owner owner |> ok with Some model -> model | None -> fail "selected Stagehand callback" in
      let params=match Yojson.Safe.from_file fixture with `List [_;_;act] -> act | _ -> fail "captured three-request fixture" in
      let messages=Yojson.Safe.Util.(params |> member "messages" |> to_list) @ [
        `Assoc ["role",`String "assistant";"content",`Assoc ["type",`String "text";"text",`String "Earlier observation."]];
        `Assoc ["role",`String "user";"content",`List [
          `Assoc ["type",`String "text";"text",`String "Continue"];
          `Assoc ["type",`String "text";"text",`String "with this observation."]]]] in
      let params=set "messages" (`List messages) params in
      let output=`Assoc ["action",`Null;"twoStep",`Bool false] in
      let server=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response output)) in
      ignore (F.publish_registry ~lane_id:"browser/stagehand" ~slot_ids:["http"]
        (F.resolver_snapshot ~source:base_path [{F.id="http";base_url=server.base_url}]) : Runtime_exact_output_registry.t);
      let state ()=Models.wait models ~after:None |> ok in
      let begin_call () =
        let before=state () in
        let waiting=Eio.Fiber.fork_promise ~sw (fun () -> model params) in
        ignore (Models.wait models ~after:(Some before.revision) |> ok);
        let request=match Models.listing models |> ok |> Lane_addon_host_request.listing_of_json |> ok with
          | [Exact_output request] -> request | _ -> fail "one original Stagehand model request" in
        waiting,request in
      let deliver request result = match Owner.dispatch owner {Browser_addon_wire.incarnation;
        command=Model_result (Lane_addon_host_request.result_arguments ~request_id:request.Exact.request_id ~result)} with
        | Model_reply value -> check bool "durable model receipt accepted" true (value=`Assoc ["accepted",`Bool true])
        | _ -> fail "model result was refused" in
      let waiting,request=begin_call () in
      check string "only the Add-on output route is used" "stagehand" request.output;
      check (list string) "assistant role and text-block order survive the bridge"
        ["Earlier observation.";"Continue\n\nwith this observation."]
        (match request.messages with [_;{role=Assistant;text=a};{role=User;text=b}] -> [a;b]
          | _ -> fail "original user/assistant/user history");
      let attempt=Exact.run ~store:(Lane_addon_store.create ~root:(Filename.concat base_path "host-store"))
        ~declaration_id:"browser" ~package ~runner:(Server_lane_addon_exact.runner ~base_path) request |> ok in
      (match attempt with Exact.Final final -> deliver request (Exact.final_to_json final)
       | Not_final _ -> fail "loopback model did not finish");
      let answer=Eio.Promise.await_exn waiting |> ok in
      let open Yojson.Safe.Util in
      check string "actual Stagehand protocol role" "assistant" (answer |> member "role" |> to_string);
      check string "actual Stagehand protocol format" "json_schema" (answer |> member "output_format" |> to_string);
      check bool "structured model value is not wrapped" true (member "structured_content" answer=output);
      check string "text and structured content agree" (Yojson.Safe.to_string output)
        (answer |> member "content" |> member "text" |> to_string);
      check int "reported usage is preserved" 2 (answer |> member "usage" |> member "total_tokens" |> to_int);
      check bool "unknown cache counts are omitted" true (answer |> member "usage" |> member "cached_input_tokens" = `Null);
      (match F.request_bodies server with [body] ->
        check (list string) "shared HTTP transport retains conversation roles" ["system";"user";"assistant";"user"]
          (Yojson.Safe.from_string body |> member "messages" |> to_list |> List.map (fun value -> value |> member "role" |> to_string))
       | _ -> fail "one provider request expected");
      List.iter (fun malformed -> check bool "unsupported input is refused before publishing" true (Result.is_error (model malformed)))
        [set "temperature" (`Float 0.2) params;set "stop_sequences" (`List [`String "stop"]) params;
         set "response_format" (`Assoc ["type",`String "text"]) params;
         set "messages" (`List [`Assoc ["role",`String "user";"content",`Assoc ["type",`String "image";"data",`String "AA==";"mime_type",`String "image/png"]]]) params];
      check (list string) "preflight failures leave no model work" [] (state ()).request_ids;
      let waiting,request=begin_call () in
      deliver request (Exact.final_to_json Outcome_unknown);
      check bool "an uncertain model outcome refuses the original call" true (Result.is_error (Eio.Promise.await_exn waiting));
      check int "no hidden retry reaches the provider" 1 (F.post_count server);
      let before=state () in
      ignore (Eio.Fiber.first (fun () -> ignore (model params))
        (fun () -> ignore (Models.wait models ~after:(Some before.revision) |> ok)));
      check (list string) "caller cancellation withdraws the original model waiter" [] (state ()).request_ids;
      let waiting,_=begin_call () in
      Owner.revoke owner;
      check bool "detach wakes the waiting Stagehand callback" true (Result.is_error (Eio.Promise.await_exn waiting));
      check bool "retired output exposes no callback" true (Model.for_owner owner=Ok None)))))))))
let () =
  Mirage_crypto_rng_unix.use_default ();
  let manifest,fixture=match Array.to_list Sys.argv with [_;manifest;fixture] -> manifest,fixture
    | _ -> fail "manifest and captured Stagehand params are required" in
  run ~argv:[|Sys.argv.(0)|] "Stagehand Add-on model consumer" ["integration",[
    test_case "captured protocol through shared model broker" `Quick (fun () -> scenario manifest fixture)]]
