(** Concurrent private browser model ports, durable result receipt and exact
    request cancellation. No provider or real browser is involved. *)
open Alcotest
open Masc
module Models=Browser_addon_models
module W=Browser_addon_wire
module Owner=Browser_addon_owner
let ok=function Ok value -> value | Error _ -> fail "model broker operation failed"
let incarnation="0b000000-0000-4000-8000-000000000007"
let schema=`Assoc ["type",`String "object";"properties",`Assoc ["node_id",`Assoc ["type",`String "string"]];
  "required",`List [`String "node_id"];"additionalProperties",`Bool false]
let request ?schema id=Lane_addon_exact.request_of_json (`Assoc (["kind",`String "exact_output";
  "request_id",`String id;"output",`String "locate";"messages",`List [`Assoc ["role",`String "user";"text",`String "Locate the menu."]]]
  @ (match schema with None -> [] | Some schema -> ["schema",schema]))) |> ok
let answer node=`Assoc ["status",`String "answered";"output",`Assoc ["node_id",`String node];"slot",`String "fixture"]
let scenario () =
  let root=Filename.temp_dir "browser-models-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let clock=Eio.Stdenv.clock env and net=Eio.Stdenv.net env in
    Eio.Time.with_timeout_exn clock 15. (fun () ->
    Eio_context.with_test_env ~sw ~clock ~net ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
      let configuration={Models.store_root=Filename.concat root "receipts";
        outputs=[{Lane_addon_types.name="locate";schema;request_schema=Lane_addon_types.Package_schema_only}]} in
      let models=Models.create ~incarnation ~configuration |> ok in
      let disabled=Models.create ~incarnation ~configuration:{configuration with outputs=[]} |> ok in
      check bool "selection off refuses immediately" true
        (Models.request disabled (request "disabled")=Error (Models.Output_disabled "locate"));
      let owner=Owner.create ~incarnation |> ok in
      Owner.attach_models owner models |> ok;
      let socket_path=Filename.concat root "s" in
      let client=Browser_addon_client.create ~socket_path ~incarnation ~max_message_bytes:65536
        ~control_timeout_sec:1. ~available:(fun () -> true) |> ok in
      let call command=match Browser_addon_client.call client ~on_cancel_after_dispatch:(fun () -> ()) command |> ok with
        | W.Model_reply value -> value
        | Service_refusal {message;_} -> fail message
        | Snapshot_result _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> fail "unexpected model service result" in
      let state after=call (W.Model_wait {after}) |> Lane_addon_host_request.availability_of_json |> ok in
      let deliver id result=call (W.Model_result (Lane_addon_host_request.result_arguments ~request_id:id ~result)) in
      let work () =
        let rec ready ()=if Sys.file_exists socket_path then () else (Eio.Fiber.yield ();ready ()) in ready ();
        let initial=state None in
        check (list string) "initial queue" [] initial.request_ids;
        Eio.Switch.check sw;
        let waiting=Eio.Fiber.fork_promise ~sw (fun () -> Models.request models (request "first")) in
        let pending=state (Some initial.revision) in
        check (list string) "a waiting command wakes the independent socket" ["first"] pending.request_ids;
        check int "listing stays available during model wait" 1
          (match Lane_addon_host_request.listing_of_json (call W.Model_requests) |> ok with requests -> List.length requests);
        check bool "wrong incarnation cannot access a model port" true
          (match Owner.dispatch owner {W.incarnation="0b000000-0000-4000-8000-000000000008";command=W.Model_requests} with
           | W.Service_refusal _ -> true | Snapshot_result _|Model_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> false);
        let invalid=Owner.dispatch owner {W.incarnation;command=W.Model_result
          (Lane_addon_host_request.result_arguments ~request_id:"first" ~result:(answer "menu" |> function
            | `Assoc fields -> `Assoc (("extra",`Bool true)::fields) | value -> value))} in
        check bool "unknown final fields refuse before consumption" true
          (match invalid with W.Service_refusal _ -> true | Snapshot_result _|Model_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> false);
        check bool "no answer was supplied by a malformed result" true (not (Eio.Promise.is_resolved waiting));
        check bool "valid result durably received" true
          (deliver "first" (answer "menu")=`Assoc ["accepted",`Bool true]);
        check bool "original waiter receives a schema checked answer" true
          (match Eio.Promise.await_exn waiting |> ok with Models.Final (Lane_addon_exact.Call_final (Answered {output;_})) ->
            Lane_addon_exact.checked_json output=`Assoc ["node_id",`String "menu"]
           | Models.Final _|Exceeds_frame _ -> false);
        let retained=Lane_addon_store.load_exact_request (Lane_addon_store.create ~root:configuration.store_root)
          ~declaration_id:incarnation ~request_id:"first" |> ok in
        check bool "original request and result have a durable receipt" true (Option.is_some retained);
        check bool "same delivery is idempotent" true (deliver "first" (answer "menu")=`Assoc ["accepted",`Bool true]);
        check bool "same id cannot bind a second command" true (Models.request models (request "first")=Error Models.Request_in_use);
        check bool "changed result cannot overwrite receipt" true
          (Result.is_error (Models.deliver models ~arguments:(Lane_addon_host_request.result_arguments ~request_id:"first" ~result:(answer "other"))));
        let before=state None in
        let cancelled=Eio.Fiber.first
          (fun () -> ignore (Models.request models (request "cancelled"));false)
          (fun () -> ignore (state (Some before.revision));true) in
        check bool "the original command can cancel its own wait" true cancelled;
        let after=state None in
        check (list string) "withdrawal wakes watcher and removes pending id" [] after.request_ids;
        check bool "late result cannot wake a replacement" true
          (deliver "cancelled" (answer "menu")=`Assoc ["accepted",`Bool false]);
        Eio.Switch.check sw;
        let retiring=Eio.Fiber.fork_promise ~sw (fun () -> Models.request models (request "retiring")) in
        ignore (state (Some after.revision));
        Owner.revoke owner;
        check bool "retirement wakes original caller" true (Eio.Promise.await_exn retiring=Error Models.Retired);
        check bool "retirement wakes model watcher" true (Models.wait models ~after:None=Error Models.Retired);
        true in
      check bool "private socket scenario completed" true (Eio.Fiber.first
        (fun () -> Browser_addon_service.serve ~net ~owner ~socket_path ~max_message_bytes:65536;false) work))))))
let request_schema_scenario () =
  let root=Filename.temp_dir "browser-model-schema-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () ->
      let baseline=match schema with `Assoc fields -> `Assoc (List.remove_assoc "required" fields)
        | _ -> fail "object fixture schema" in
      let output={Lane_addon_types.name="locate";schema=baseline;request_schema=Lane_addon_types.Package_schema_only} in
      let configuration={Models.store_root=Filename.concat root "receipts";outputs=[output]} in
      let original=request ~schema "requested" in
      let fixed=Models.create ~incarnation ~configuration |> ok in
      check bool "grant refused before publishing a pending request" true
        (match Models.request fixed original with Error (Schema_refused _) -> true | _ -> false);
      let granted={configuration with outputs=[{output with request_schema=Consumer_request_schema}]} in
      check bool "grant is carried in the worker bootstrap" true
        (Models.configuration_to_json configuration<>Models.configuration_to_json granted);
      let models=Models.create ~incarnation ~configuration:granted |> ok in
      let waiting=Eio.Fiber.fork_promise ~sw (fun () -> Models.request models original) in
      ignore (Models.wait models ~after:(Some "0") |> ok);
      let deliver result=Models.deliver models ~arguments:(Lane_addon_host_request.result_arguments
        ~request_id:original.request_id ~result) in
      let malformed=`Assoc ["status",`String "answered";"output",`Assoc [];"slot",`String "fixture"] in
      check bool "request shape applies even when baseline permits the omitted key" true (Result.is_error (deliver malformed));
      check bool "invalid reply does not consume the original waiter" true (not (Eio.Promise.is_resolved waiting));
      check bool "valid result is durably delivered" true (deliver (answer "menu")=Ok true);
      ignore (Eio.Promise.await_exn waiting |> ok);
      check bool "duplicate receipt validates the original schema and grant" true (deliver (answer "menu")=Ok true);
      Models.retire models))))

let ()=Mirage_crypto_rng_unix.use_default ();
  run "browser model request ports" ["concurrency",[
    test_case "private queue, receipt, cancellation and retirement" `Quick scenario;
    test_case "request schema grant and original receipt shape" `Quick request_schema_scenario]]
