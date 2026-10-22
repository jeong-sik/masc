(** The host request cycle of a declared installation (RFC operator-quiz
    §4.4): TOML declaration, reconcile, the instance fiber, retention and the
    registry subscription are real. Only the worker and the exact runner are
    replaced. *)
open Alcotest
open Masc
module Runtime = Lane_addon_runtime
module Exact = Lane_addon_exact

(* These fixtures exercise host publication, not real provider capture. Their
   explicit synthetic CLI success never claims API-only failure coverage. *)
let executed outcome =
  let module Receipt = Masc.Keeper_exact_walk_receipt in
  let declared_cli, dispatched, result = match outcome with
    | Exact.Call_ended (Exact.Answered {slot; _}) -> [slot], [slot], Receipt.Answered slot
    | Exact.Call_ended (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
    | Exact.Call_refused _ -> [], [], Receipt.Not_reached in
  let receipt = match Receipt.make ~declared_http:[] ~excluded_http:[] ~declared_cli
      ~http:(Receipt.http_not_started ~detail:"synthetic host publication fixture")
      ~cli:(Receipt.cli ~visited:dispatched ~dispatched ~failures:[] ~result) with
    | Ok receipt -> receipt | Error detail -> Alcotest.fail detail in
  {Exact.outcome; receipt}
module F = Exact_output_fixture

let member = Yojson.Safe.Util.member
let text key json = member key json |> Yojson.Safe.Util.to_string
let unwrap = function Ok v -> v | Error message -> fail message
let write path bytes =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let with_env name value f =
  let previous = Sys.getenv_opt name in Unix.putenv name value;
  Fun.protect ~finally:(fun () -> Unix.putenv name (Option.value ~default:"" previous)) f

let fixture_frame = 4096
let manifest = Printf.sprintf {|id="quiz-package"
revision="1"
title="Host request fixture"
contributions=["observe"]
image="fixture/image"
command=["fixture"]
[world.exact_outputs.author]
schema="schemas/author.json"
[resources]
cpus=0.5
memory_bytes=67108864
pids=16
max_reply_bytes=%d
|} fixture_frame
let author_schema = {|{"type":"object","properties":{"question":{"type":"string"}},"required":["question"],"additionalProperties":false}|}
let declaration = {|id="quiz"
run_id="quiz-world"
manifest_path="../../package.toml"
[binding]
sources=[]
|}

let exact id = `Assoc [ "kind", `String "exact_output"; "request_id", `String id; "output", `String "author"
                      ; "messages", `List [ `Assoc [ "role", `String "user"; "text", `String "Write one question." ] ] ]

(* What the fake worker lists and what it received. *)
type worker = {
  listing : Yojson.Safe.t list ref;
  delivered : Yojson.Safe.t list ref;
  consume : bool ref;  (** Whether a delivery removes the request and answers accepted. *)
  observations : int ref;
  on_deliver : (Yojson.Safe.t -> unit) ref;  (** What the package does with a delivered result. *)
}

(* What the fake runner does: answer with this value, or report the lane off. *)
type runner_mode = Answer of Yojson.Safe.t | Off
type runner_state = { mode : runner_mode ref; resolutions : int ref }

let runner state : Exact.runner = fun ~admission_class:_ ~lane_key:_ ~schema:_ _ ->
  incr state.resolutions;
  match !(state.mode) with
  | Off -> Error Exact.Lane_off
  | Answer json ->
      Ok (fun ~validate ->
        match validate json with
        | Ok output -> executed (Exact.Call_ended (Exact.Answered { output; slot = "fixture"; usage = None }))
        | Error detail -> executed (Exact.Call_ended (Exact.Invalid_output { detail })))

let port ?await_change ?deliver_reply ?(during_delivery=fun _ -> ()) ?(before_listing = fun _ -> ()) worker : Runtime.For_testing.host_port = {
  await_change;
  list_requests = (fun () ->
    let requests= !(worker.listing) in
    before_listing requests;
    Ok (`Assoc [ "requests", `List requests ]));
  deliver = (fun ~arguments ->
    during_delivery true;
    Fun.protect ~finally:(fun () -> during_delivery false) (fun () ->
    worker.delivered := arguments :: !(worker.delivered);
    let request_id = text "request_id" arguments in
    if !(worker.consume) then
      worker.listing := List.filter (fun request -> text "request_id" request <> request_id) !(worker.listing);
    !(worker.on_deliver) arguments;
    match deliver_reply with
    | None -> Ok (`Assoc [ "accepted", `Bool !(worker.consume) ])
    | Some reply -> reply arguments));
}

let backend ?await_change ?deliver_reply ?during_delivery ?before_listing ?exported_tool ?(before_stop = fun () -> ()) worker : Runtime.For_testing.backend = {
  start = (fun ~sw:_ ~state_owner:_ ~instance_id ~installation_id:_ ~package:_ ~binding:_ ~on_authority ~is_live_instance:_ ~on_created ->
    let connection : Runtime.For_testing.connection = {browser=None;
        resolved_image = (match Lane_addon_engine.image_of_inspect Lane_addon_types.Docker ("sha256:" ^ String.make 64 'a') with
          | Ok image -> Some image | Error detail -> Alcotest.fail detail);
      observe = (fun ~binding:_ ~sources:_ -> incr worker.observations; Ok { rows = []; coverage = [] });
      exported_tools = (fun () -> match exported_tool with
        | None -> [] | Some (tool, _) -> [tool]);
      call_exported_tool = (fun ~on_result ~authorize:_ ~principal:_ ~name:_ ~arguments ->
        match exported_tool with
        | None -> Error (Lane_addon_call_context.Transport_error "no exported tools")
        | Some (_, invoke) ->
          let result = invoke arguments in
          (match result with Ok reply -> on_result reply | Error _ -> ());
          result);
      action_schema = (fun () -> None); act = (fun ~arguments:_ -> Error "read-only");
      stop = (fun () -> before_stop (); Ok (Lane_addon_lifecycle.Released
        { engine = Lane_addon_lifecycle.Docker_engine "fixture-engine"; container_id = Some instance_id }));
      resource = Lane_addon_lifecycle.Container_resource instance_id;
      host = Some (port ?await_change ?deliver_reply ?during_delivery ?before_listing worker) } in
    ignore (on_authority (Lane_addon_lifecycle.Container_authority
      { runtime = Lane_addon_types.Docker; engine = Lane_addon_lifecycle.Docker_engine "fixture-engine" }));
    on_created connection; Ok connection);
  package_ready = (fun ~package:_ -> Ok ());
  acquire = (fun ~access:_ ~store:_ ~package:_ ~resolve_machine_output:_ ~resolve_lane_output:_ ~binding:_ -> Ok (`List []));
  recover_stop = (fun ~state_owner:_ ~instance_id:_ ~authority ~resource ->
    match authority, resource with
    | Lane_addon_lifecycle.Container_authority { engine; _ }, None ->
      Ok (Lane_addon_lifecycle.Released { engine; container_id = None })
    | Lane_addon_lifecycle.Container_authority { engine; _ },
        Some (Lane_addon_lifecycle.Container_resource id) ->
      Ok (Lane_addon_lifecycle.Released { engine; container_id = Some id })
    | Lane_addon_lifecycle.Container_authority _, Some (Lane_addon_lifecycle.Native_resource _)
    | Lane_addon_lifecycle.Native_admission _, (None | Some _) ->
      Error (Lane_addon_lifecycle.Cleanup_unconfirmed "container fixture cannot release native resources"));
  condition_met = (fun ~runtime:_ _ -> true);
  sweep = (fun ~runtime:_ ~is_live_instance:_ -> Ok []) }

let host_requests config =
  match
    Runtime.dispatch ~access:Lane_addon_sources.Operator_configuration ~config ~operation:Runtime.Inspect (`Assoc [])
    |> Result.map_error Runtime.error_to_string |> unwrap
    |> member "instances" |> Yojson.Safe.Util.to_list
    |> List.filter (fun item -> text "kind" (member "phase" item) <> "detached")
  with
  | [ live ] -> member "host_requests" live
  | _ -> `Null

let cycles config = match member "cycles" (host_requests config) with `Int n -> n | _ -> 0

let await clock predicate =
  let rec loop () = if predicate () then () else (Eio.Time.sleep clock 0.001; loop ()) in loop ()

let with_installation ?await_change ?deliver_reply ?during_delivery ?owner_setup ?before_listing ?before_stop ?exported_tool ?(make_runner = runner) ?(manifest = manifest) ?(declaration = declaration) ?(listing = []) ?(mode = Answer (`Assoc [ "question", `String "Q?" ])) ?(consume = true) f =
  let root = Filename.temp_dir "lane-host-cycle-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let config_root = Filename.concat root ".masc/config" in
    let directory = Filename.concat config_root "lane-addons" in
    write (Filename.concat root ".masc/package.toml") manifest;
    write (Filename.concat root ".masc/schemas/author.json") author_schema;
    write (Filename.concat directory "quiz.toml") declaration;
    with_env "MASC_BASE_PATH" root (fun () ->
    with_env "MASC_CONFIG_DIR" config_root (fun () ->
      with_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" "true" (fun () ->
        Eio_main.run (fun env ->
          Fs_compat.set_fs (Eio.Stdenv.fs env);
          let clock = Eio.Stdenv.clock env in
          Eio.Time.with_timeout_exn clock 15. (fun () -> Eio.Switch.run (fun sw ->
            Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env) ~clock
              ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
                Runtime.For_testing.reset ();
                let worker = { listing = ref listing; delivered = ref []; consume = ref consume; observations = ref 0
                             ; on_deliver = ref ignore } in
                Board.reset_global_for_test ();
                Board_dispatch.reset_for_test ();
                Board_dispatch.init_jsonl ();
                let state = { mode = ref mode; resolutions = ref 0 } in
                Runtime.register_exact_runner
                  ~authorize_request:(fun ~store:_ ~declaration_id:_ ~package:_ _ ->
                    Ok {Exact.admission_class=Agent_core.Llm_provider.Admission_class.Standard;
                        validate_output=(fun _ -> Ok ())})
                  (make_runner state);
                let config = Workspace.default_config root in
                Runtime.For_testing.with_backend (backend ?await_change ?deliver_reply ?during_delivery ?before_listing ?before_stop ?exported_tool worker) (fun () ->
                  let unsubscribe=match owner_setup with None -> (fun () -> ()) | Some setup -> setup clock config in
                  Fun.protect ~finally:unsubscribe (fun () ->
                  ignore (Runtime.reconcile_configuration ~config ~directory |> unwrap);
                  f clock config worker state root;
                  let source = Filename.concat directory "quiz.toml" in
                  if Sys.file_exists source then Sys.remove source;
                  ignore (Runtime.reconcile_configuration ~config ~directory |> unwrap);
                  await clock (fun () -> host_requests config = `Null)))))))))))

(* Event 4. The registry is process-wide, so each call names a new slot: a
   publication that changes nothing about the lane wakes no one. *)
let publications = ref 0
let publish_lane_change () =
  incr publications;
  let slot = Printf.sprintf "slot-%d" !publications in
  let snapshot = F.resolver_snapshot ~source:"host-cycle" [ { F.id = slot; base_url = "http://127.0.0.1:9" } ] in
  ignore (F.publish_registry ~lane_id:"quiz/author" ~slot_ids:[ slot ] snapshot : Runtime_exact_output_registry.t)

let delivered_status arguments = text "status" (member "result" arguments)

let test_scoped_owner_wakes_preserve_mcp_and_metadata_publication () =
  let events=ref [] and ready=ref false and other_scope=ref 0 and other_package=ref 0 and peer=ref 0 in
  let stop=ref (fun () -> ()) and mcp=ref 0 in
  let tool=Mcp_protocol.Mcp_types.tool_of_yojson (`Assoc ["name",`String "queue_question";
    "inputSchema",`Assoc ["type",`String "object"]]) |> unwrap in
  let owner_setup clock config =
    let unsubscribe=Runtime.subscribe_owner_events ~config ~package_id:"quiz-package" (fun event ->
      events:=event :: !events;
      match event with Runtime.Export_inventory_changed -> ready:=true
      | Configuration_observed | Exact_result_delivered _ -> ()) in
    stop:=unsubscribe;
    let peer=Runtime.subscribe_owner_events ~config ~package_id:"quiz-package" (fun _ -> incr peer) in
    let other=Runtime.subscribe_owner_events ~config:{config with Workspace.base_path=Filename.concat config.base_path "another"}
      ~package_id:"quiz-package" (fun _ -> incr other_scope) in
    let package=Runtime.subscribe_owner_events ~config ~package_id:"another-package" (fun _ -> incr other_package) in
    (* Hold actual metadata publication until the worker's export-ready event.
       This orders the real startup race without a timer or fake metadata. *)
    Runtime.register_skill_export_handler (fun ~config:_ _ -> await clock (fun () -> !ready);Ok ());
    fun () -> unsubscribe ();peer ();other ();package () in
  Runtime.For_testing.with_tool_change_handler (fun () -> incr mcp) (fun () ->
    with_installation ~owner_setup ~manifest:(manifest ^ "[world.tools]\nexport=[\"queue_question\"]\n")
      ~exported_tool:(tool,(fun _ -> Ok (Mcp_protocol.Mcp_types.tool_result_of_text "unused")))
      (fun clock config _ _ _ ->
        await clock (fun () -> cycles config>=1);
        check bool "the original MCP bridge still receives export changes" true (!mcp>0);
        check bool "worker readiness is followed by actual metadata publication" true
          (List.take 2 (List.rev !events) = [Runtime.Export_inventory_changed;Runtime.Configuration_observed]);
        let metadata ()=List.filter (function Runtime.Configuration_observed -> true
          | Export_inventory_changed | Exact_result_delivered _ -> false) !events |> List.length in
        let before=metadata () in
        ignore (Runtime.reconcile_configuration ~config ~directory:(Runtime.configuration_directory config) |> unwrap);
        check int "an unchanged reconciliation does not signal metadata again" before (metadata ());
        let count=List.length !events and previous_peer= !peer in
        (!stop) ();(!stop) ();
        let source=Filename.concat (Runtime.configuration_directory config) "quiz.toml" in
        write source ("enabled=false\n" ^ declaration);
        ignore (Runtime.reconcile_configuration ~config ~directory:(Runtime.configuration_directory config) |> unwrap);
        await clock (fun () -> !peer>previous_peer);
        check int "unsubscribe removes only its original registration" count (List.length !events);
        check int "another workspace receives no hint" 0 !other_scope;
        check int "another package receives no hint" 0 !other_package))

let test_exact_result_wakes_after_rpc_and_isolates_observer_failure () =
  let received=ref [] and inside_rpc=ref false in
  let owner_setup _clock config =
    let collect=Runtime.subscribe_owner_events ~config ~package_id:"quiz-package" (function
      | Runtime.Exact_result_delivered receipt ->
        check bool "owner callback runs after the worker RPC returns" false !inside_rpc;
        received:=(receipt.installation_id,receipt.instance_id,receipt.request_id) :: !received
      | Export_inventory_changed | Configuration_observed -> ()) in
    let failed=Runtime.subscribe_owner_events ~config ~package_id:"quiz-package" (function
      | Runtime.Exact_result_delivered _ -> raise Exit
      | Export_inventory_changed | Configuration_observed -> ()) in
    let cancelled=Runtime.subscribe_owner_events ~config ~package_id:"quiz-package" (function
      | Runtime.Exact_result_delivered _ -> Eio.Cancel.sub (fun context ->
          Eio.Cancel.cancel context Exit;Eio.Fiber.check ())
      | Export_inventory_changed | Configuration_observed -> ()) in
    fun () -> collect ();failed ();cancelled () in
  with_installation ~owner_setup ~during_delivery:(fun state -> inside_rpc:=state)
    ~listing:[exact "original-owner-result"] (fun clock config worker state _ ->
      await clock (fun () -> cycles config>=1);
      let expected=Lane_addon_tool_request_owner.installation_id (Lane_addon_tool_request_owner.Configuration "quiz") in
      (match !received with
       | [(installation,instance,request)] ->
         check string "accepted receipt retains configured installation identity" expected installation;
         check string "accepted receipt retains original request" "original-owner-result" request;
         check bool "receipt names the actual instance" true (instance<>"")
       | _ -> fail "an accepted result must reach the healthy owner despite observer failure");
      worker.listing:=[exact "original-owner-result"];
      publish_lane_change ();
      await clock (fun () -> List.length !received=2);
      check int "retained result restoration does not rerun the model" 1 !(state.resolutions);
      check bool "restored delivery retains original instance and request" true
        (match !received with [restored;original] -> restored=original | _ -> false))

type owner_delivery = Unaccepted | Malformed | Transport_failed | Non_exact
let test_only_accepted_exact_results_wake_owner kind () =
  let received=ref 0 in
  let owner_setup _clock config = Runtime.subscribe_owner_events ~config ~package_id:"quiz-package" (function
    | Runtime.Exact_result_delivered _ -> incr received
    | Export_inventory_changed | Configuration_observed -> ()) in
  let listing=match kind with
    | Non_exact -> [`Assoc ["kind",`String "read_records";"request_id",`String "original-read";"source_id",`String "missing"]]
    | Unaccepted | Malformed | Transport_failed -> [exact "original-unaccepted"] in
  let deliver_reply _=match kind with
    | Unaccepted -> Ok (`Assoc ["accepted",`Bool false])
    | Malformed -> Ok (`Assoc ["accepted",`String "true"])
    | Transport_failed -> Error "simulated lost result receipt"
    | Non_exact -> Ok (`Assoc ["accepted",`Bool true]) in
  with_installation ~owner_setup ~deliver_reply ~listing (fun clock config _ _ _ ->
    await clock (fun () -> cycles config>=1);
    check int "no successful Exact delivery fact is invented" 0 !received)


let test_withdrawal_event_before_stale_listing () =
  let revision=ref 0 and ids=ref [] and changed=Eio.Condition.create () in
  let listing_entered,listing_enter=Eio.Promise.create () in
  let release_listing,release=Eio.Promise.create () in
  let withdrawal_seen,seen=Eio.Promise.create () in
  let held=ref false in
  let before_listing requests=if requests<>[] && not !held then (
    held:=true;Eio.Promise.resolve listing_enter ();Eio.Promise.await release_listing) in
  let await_change ~after=Eio.Condition.loop_no_mutex changed (fun () ->
    let state={Lane_addon_host_request.revision=string_of_int !revision;request_ids= !ids} in
    if after=Some state.revision then None else (
      if !revision=2 then ignore (Eio.Promise.try_resolve seen ());
      Some (Ok state))) in
  with_installation ~await_change ~before_listing (fun clock config worker state _root ->
    Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve release ())) (fun () ->
    await clock (fun () -> cycles config>=1);
    worker.listing:=[exact "already-withdrawn"];ids:=["already-withdrawn"];
    revision:=1;Eio.Condition.broadcast changed;
    Eio.Promise.await listing_entered;
    worker.listing:=[];ids:=[];revision:=2;Eio.Condition.broadcast changed;
    Eio.Promise.await withdrawal_seen;
    let previous=cycles config in
    Eio.Promise.resolve release ();
    await clock (fun () -> cycles config>previous);
    check int "a stale listing cannot start an already withdrawn model call" 0 !(state.resolutions);
    check int "a stale listing cannot deliver an answer" 0 (List.length !(worker.delivered))))

let test_model_events_admit_and_withdraw_an_exact_scope () =
  let revision=ref 0 and ids=ref [] and changed=Eio.Condition.create () in
  let availability ()={Lane_addon_host_request.revision=string_of_int !revision;request_ids= !ids} in
  let await_change ~after=Eio.Condition.loop_no_mutex changed (fun () ->
    let state=availability () in if after=Some state.revision then None else Some (Ok state)) in
  let cancelled, cancel=Eio.Promise.create () in
  let entered, enter=Eio.Promise.create () in
  let make_runner state ~admission_class ~lane_key:_ ~schema:_ (request:Exact.request) =
    incr state.resolutions;
    if request.request_id="withdraw" then Ok (fun ~validate:_ ->
      Fun.protect ~finally:(fun () -> Eio.Promise.resolve cancel ()) (fun () ->
        Eio.Promise.resolve enter ();
        Eio.Fiber.await_cancel ()))
    else runner {state with resolutions=ref 0} ~admission_class ~lane_key:"fixture" ~schema:(`Assoc []) request in
  with_installation ~await_change ~make_runner (fun clock config worker state _root ->
    await clock (fun () -> cycles config>=1);
    let publish requests =
      worker.listing:=requests;
      ids:=List.map (text "request_id") requests;
      incr revision;Eio.Condition.broadcast changed in
    publish [exact "withdraw"];
    Eio.Promise.await entered;
    publish [];
    Eio.Promise.await cancelled;
    check int "one scoped model call was cancelled" 1 !(state.resolutions);
    check int "a withdrawn command receives no late answer" 0 (List.length !(worker.delivered));
    publish [exact "next-command"];
    await clock (fun () -> List.length !(worker.delivered)=1);
    check string "the original worker still receives a later command" "next-command"
      (text "request_id" (List.hd !(worker.delivered)));
    check int "events admit a later request without replaying the first" 2 !(state.resolutions))

let test_retirement_cancels_exact_before_worker_cleanup_finishes () =
  let entered, enter = Eio.Promise.create () and finished, finish = Eio.Promise.create () in
  let cleaning, clean = Eio.Promise.create () and released, release = Eio.Promise.create () in
  let make_runner state ~admission_class:_ ~lane_key:_ ~schema:_ _ =
    incr state.resolutions;
    Ok (fun ~validate:_ ->
      Fun.protect ~finally:(fun () -> Eio.Promise.resolve finish ()) (fun () ->
        Eio.Promise.resolve enter ();
        (* Only retirement can end this provider call. *)
        Eio.Promise.await (fst (Eio.Promise.create ())))) in
  let before_stop () =
    Eio.Promise.await finished;
    Eio.Promise.resolve clean ();
    Eio.Promise.await released in
  with_installation ~make_runner ~before_stop ~listing:[exact "retiring-1";exact "retiring-2"]
    (fun _clock config worker state _root ->
      Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve release ())) (fun () ->
      Eio.Promise.await entered;
      let detached, detach = Eio.Promise.create () in
      let sw = match Eio_context.get_switch_opt () with
        | Some sw -> sw | None -> fail "fixture switch is unavailable" in
      Eio.Switch.check sw;
      Eio.Fiber.fork ~sw (fun () ->
        let source = Filename.concat (Runtime.configuration_directory config) "quiz.toml" in
        Sys.remove source;
        Eio.Promise.resolve detach (Runtime.reconcile_configuration ~config
          ~directory:(Filename.dirname source)));
      Eio.Promise.await cleaning;
      check int "no second request starts while worker cleanup is pending" 1 !(state.resolutions);
      check int "no result is delivered to a retiring worker" 0 (List.length !(worker.delivered));
      Eio.Promise.resolve release ();
      ignore (Eio.Promise.await detached |> unwrap)))

let test_a_started_worker_gets_its_final_result_once () =
  with_installation ~listing:[ exact "r1" ] (fun clock config worker state  _root->
    await clock (fun () -> cycles config >= 1);
    (match !(worker.delivered) with
     | [ arguments ] ->
       check string "for the listed request" "r1" (text "request_id" arguments);
       check string "the final result" "answered" (delivered_status arguments)
     | delivered -> failf "expected one delivery, got %d" (List.length delivered));
    check int "the runner was asked once" 1 !(state.resolutions);
    check bool "the cycle settled" true (member "issue" (host_requests config) = `Null);
    await clock (fun () -> !(worker.observations) >= 1))

let test_an_exported_reply_starts_its_pending_host_work ~is_error () =
  let tool = Mcp_protocol.Mcp_types.tool_of_yojson (`Assoc [
    "name", `String "queue_question";
    "inputSchema", `Assoc ["type", `String "object"]]) |> unwrap in
  let current_worker = ref None in
  let invoke arguments =
    let worker = match !current_worker with
      | Some worker -> worker | None -> fail "the installation is not ready" in
    worker.listing := [exact (text "request_id" arguments)];
    Ok { (Mcp_protocol.Mcp_types.tool_result_of_text "request retained") with
      is_error = Some is_error } in
  let manifest = manifest ^ {|[world.tools]
export=["queue_question"]
|} in
  with_installation ~manifest ~exported_tool:(tool, invoke)
    (fun clock config worker state _root ->
      current_worker := Some worker;
      (* Finish initialization before submitting, so startup cannot discover
         this request. There is no await_change, registry event or reconcile. *)
      await clock (fun () -> cycles config >= 1 && !(worker.observations) >= 1);
      let before = cycles config in
      let export = match Runtime.tool_exports ~config
        ~access:Lane_addon_sources.Operator_configuration ~reserved:[] |> unwrap with
        | [export] -> export | _ -> fail "the original tool must be exported" in
      let reply = match Runtime.call_exported_tool ~config
        ~access:Lane_addon_sources.Operator_configuration ~reserved:[] ~export
        ~arguments:(`Assoc ["request_id", `String "submitted-after-startup"]) with
        | Ok reply -> reply | Error _ -> fail "the admitted worker call failed" in
      check bool "retain the original worker error flag" is_error (reply.is_error = Some true);
      await clock (fun () -> List.length !(worker.delivered) = 1);
      check string "deliver to the submitted original request" "submitted-after-startup"
        (text "request_id" (List.hd !(worker.delivered)));
      check string "the host retained an answer" "answered"
        (delivered_status (List.hd !(worker.delivered)));
      check int "one model resolution after the exported reply" 1 !(state.resolutions);
      check bool "a host cycle followed the exported reply" true (cycles config > before))

let test_original_tool_destination_survives_replacement_and_reattachment () =
  let tool = Mcp_protocol.Mcp_types.tool_of_yojson (`Assoc [
    "name", `String "queue_question"; "inputSchema", `Assoc ["type",`String "object"]]) |> unwrap in
  let calls = ref 0 in
  let invoke _ = incr calls; Ok (Mcp_protocol.Mcp_types.tool_result_of_text "unused") in
  let manifest = manifest ^ "[world.tools]\nexport=[\"queue_question\"]\n" in
  with_installation ~manifest ~exported_tool:(tool,invoke) (fun clock config _worker _state root ->
    let access = Lane_addon_sources.Operator_configuration in
    let current () = match Runtime.tool_exports ~config ~access ~reserved:[] |> unwrap with
      | [export] -> Some export | _ -> None in
    await clock (fun () -> Option.is_some (current ()));
    let original = Option.get (current ()) in
    let bind export = Runtime.retain_tool_request_owner ~config ~access ~reserved:[] ~export
      ~scope:"original-consumer" ~request_id:"original-request" ~request:(`Assoc ["input",`String "original"]) in
    let accepted = function Ok () -> () | Error _ -> fail "the original installation lost its binding" in
    accepted (bind original);
    let directory = Filename.concat root ".masc/config/lane-addons" in
    let source = Filename.concat directory "quiz.toml" in
    write source {|id="replacement"
run_id="quiz-world"
manifest_path="../../package.toml"
[binding]
sources=[]
|};
    ignore (Runtime.reconcile_configuration ~config ~directory |> unwrap);
    await clock (fun () -> match current () with
      | Some export -> not (Lane_addon_tool_export.equal_owner original.owner export.owner)
      | None -> false);
    let replacement = Option.get (current ()) in
    (match bind replacement with
     | Error (Runtime.Host_refusal (Lane_addon_call_context.Rejected _)) -> ()
     | Ok () | Error (Runtime.Unavailable _ | Runtime.Outcome_unknown _ | Runtime.Host_refusal _) ->
       fail "a replacement installation claimed original request ownership");
    write source declaration;
    ignore (Runtime.reconcile_configuration ~config ~directory |> unwrap);
    await clock (fun () -> match current () with
      | Some export -> not (Lane_addon_tool_export.equal_owner replacement.owner export.owner)
      | None -> false);
    accepted (bind (Option.get (current ())));
    (match bind original with
     | Error (Runtime.Unavailable _) -> ()
     | Ok () | Error (Runtime.Outcome_unknown _ | Runtime.Host_refusal _) -> fail "a stale worker handle retained authority");
    check int "binding never invokes a worker tool" 0 !calls)

let test_capture_factory_uses_actual_live_declaration_before_any_rpc () =
  let tool=Mcp_protocol.Mcp_types.tool_of_yojson (`Assoc ["name",`String "queue_question";
    "inputSchema",`Assoc ["type",`String "object"]]) |> unwrap in
  let calls=ref 0 in
  let invoke _=incr calls;Ok (Mcp_protocol.Mcp_types.tool_result_of_text "unused") in
  let manifest=manifest ^ "[world.tools]\nexport=[\"queue_question\"]\n" in
  with_installation ~manifest ~exported_tool:(tool,invoke) (fun clock config _worker _state _root ->
    let access=Lane_addon_sources.Operator_configuration in
    let current ()=match Runtime.tool_exports ~config ~access ~reserved:[] |> unwrap with
      | [export] -> Some export | _ -> None in
    await clock (fun () -> Option.is_some (current ()));
    let export=Option.get (current ()) in
    let source=Filename.concat (Runtime.configuration_directory config) "quiz.toml" in
    let declaration=Lane_addon_config.load_file ~path:source |> unwrap in
    let capture (destination : Runtime.tool_request_destination) =
      let json=`Assoc ["installation",`String destination.installation_id;
        "package",`String destination.package_id;"tool",`String destination.tool;
        "source_revision",`String destination.source_revision;
        "configuration_revision",`String destination.configuration_revision;
        "max_reply_bytes",`Int destination.max_reply_bytes] in Ok (json,json) in
    let captured=match Runtime.capture_tool_request_owner ~config ~access ~reserved:[] ~export
      ~scope:"trusted-capture" ~request_id:"original" ~capture with
      | Ok json -> json | Error _ -> fail "live configured capture was refused" in
    check string "source bytes come from the actual declaration" declaration.source_revision (text "source_revision" captured);
    check string "configuration comes from the admitted payload" declaration.revision (text "configuration_revision" captured);
    check int "the frame comes from the installed package declaration" fixture_frame
      (member "max_reply_bytes" captured |> Yojson.Safe.Util.to_int);
    check string "configured logical identity uses the original codec"
      (Lane_addon_tool_request_owner.installation_id (Lane_addon_tool_request_owner.Configuration declaration.id))
      (text "installation" captured);
    let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    (match Lane_addon_tool_request_owner.load ~store ~scope:"trusted-capture" ~request_id:"original" with
     | Ok (Some record) -> check bool "factory output is durably retained before return" true (Yojson.Safe.equal record.request captured)
     | Ok None | Error _ -> fail "capture returned before retaining its original request");
    (match Runtime.with_tool_request_destination ~config ~access ~reserved:[] ~export
      ~publish:(fun _ -> Error (Runtime.Outcome_unknown "controlled local publication uncertainty")) with
     | Error (Runtime.Outcome_unknown _) -> ()
     | Ok _ | Error (Runtime.Unavailable _ | Runtime.Host_refusal _) -> fail "publication uncertainty lost its typed meaning");
    (match Runtime.with_tool_request_destination ~config ~access ~reserved:[] ~export
      ~publish:(fun _ -> Eio.Fiber.yield ();raise (Sys_error "controlled local publication interruption")) with
     | exception Sys_error _ -> ()
     | Ok _ | Error _ -> fail "publication interruption was silently converted");
    (match Runtime.capture_tool_request_owner ~config ~access ~reserved:[] ~export
       ~scope:"trusted-capture" ~request_id:"original" ~capture with
     | Ok replay -> check bool "serializer survives journal callback failure and reuses original ID" true
         (Yojson.Safe.equal replay captured)
     | Error _ -> fail "local publication exception poisoned configured admission");
    let forbidden _=fail "stale or conflicting export called the capture factory" in
    (match Runtime.capture_tool_request_owner ~config ~access ~reserved:["queue_question"] ~export
       ~scope:"trusted-capture" ~request_id:"collision" ~capture:forbidden with
     | Error (Runtime.Unavailable _) -> ()
     | Ok _ | Error (Runtime.Outcome_unknown _ | Runtime.Host_refusal _) -> fail "reserved name admitted capture");
    let document=Runtime.read_declaration ~access ~config (`Assoc ["source_path",`String source])
      |> Result.map_error (fun error -> error.Lane_addon_declaration.message) |> unwrap in
    Runtime.save_declaration ~access ~config (`Assoc ["mode",`String "save";"file_name",`String "quiz.toml";
      "expected_source_revision",member "source_revision" document;
      "source_text",`String ("enabled=false\n" ^ In_channel.with_open_bin source In_channel.input_all)])
      |> Result.map_error (fun error -> error.Lane_addon_declaration.message) |> unwrap |> ignore;
    check bool "saved Off has not yet been reconciled out of the cached export" true (Option.is_some (current ()));
    (match Runtime.capture_tool_request_owner ~config ~access ~reserved:[] ~export
       ~scope:"trusted-capture" ~request_id:"off-before-reconcile" ~capture:forbidden with
     | Error (Runtime.Unavailable _) -> ()
     | Ok _ | Error (Runtime.Outcome_unknown _ | Runtime.Host_refusal _) -> fail "committed Off reused stale configured authority");
    ignore (Runtime.reconcile_configuration ~config ~directory:(Runtime.configuration_directory config) |> unwrap);
    await clock (fun () -> current ()=None);
    (match Runtime.capture_tool_request_owner ~config ~access ~reserved:[] ~export
       ~scope:"trusted-capture" ~request_id:"off" ~capture:forbidden with
     | Error (Runtime.Unavailable _) -> ()
     | Ok _ | Error (Runtime.Outcome_unknown _ | Runtime.Host_refusal _) -> fail "Off export admitted capture");
    check int "capture and refusal perform no worker RPC" 0 !calls)

let test_a_request_that_is_not_final_waits_for_the_next_event () =
  with_installation ~listing:[ exact "r2" ] ~mode:Off (fun clock config worker state  _root->
    await clock (fun () -> cycles config >= 1);
    check int "nothing was delivered" 0 (List.length !(worker.delivered));
    (match member "waiting" (host_requests config) with
     | `List [ waiting ] ->
       check string "the waiting request" "r2" (text "request_id" waiting);
       check string "and why" "lane_off" (text "reason" (member "reason" waiting))
     | _ -> fail "the not-final request must show as waiting");
    Eio.Time.sleep clock 0.05;
    check int "no clock asks again" 1 !(state.resolutions);
    state.mode := Answer (`Assoc [ "question", `String "Q?" ]);
    (* Event 4: a publication that changes this installation's add-on lane. *)
    publish_lane_change ();
    await clock (fun () -> List.length !(worker.delivered) = 1);
    check int "the lane change asked again" 2 !(state.resolutions))

let test_a_request_listed_again_after_delivery_ends_the_cycle () =
  with_installation ~listing:[ exact "r3" ] ~consume:false (fun clock config worker _  _root->
    await clock (fun () -> cycles config >= 1);
    check int "delivered once" 1 (List.length !(worker.delivered));
    match member "issue" (host_requests config) with
    | `Assoc _ as issue ->
      check string "the instance shows it" "relisted_delivered_request" (text "kind" issue);
      check string "for that request" "r3" (text "request_id" issue)
    | _ -> fail "a relisted delivered request must end the cycle with an issue")

let test_a_result_larger_than_the_frame_is_delivered_as_its_size () =
  let long = `Assoc [ "question", `String (String.make 5000 'q') ] in
  with_installation ~listing:[ exact "r4" ] ~mode:(Answer long) (fun clock config worker _  _root->
    await clock (fun () -> cycles config >= 1);
    match !(worker.delivered) with
    | [ arguments ] ->
      check string "the result does not fit" "result_exceeds_frame" (delivered_status arguments);
      check bool "and names its size" true
        (match member "bytes" (member "result" arguments) with `Int bytes -> bytes > 4096 | _ -> false)
    | delivered -> failf "expected one delivery, got %d" (List.length delivered))

let test_a_listing_with_an_unknown_kind_is_refused_whole () =
  let ask = `Assoc [ "kind", `String "ask"; "request_id", `String "q1" ] in
  with_installation ~listing:[ exact "r5"; ask ] (fun clock config worker state  _root->
    await clock (fun () -> cycles config >= 1);
    check int "nothing was run" 0 !(state.resolutions);
    check int "nothing was delivered" 0 (List.length !(worker.delivered));
    match member "issue" (host_requests config) with
    | `Assoc _ as issue -> check string "the instance shows it" "listing_refused" (text "kind" issue)
    | _ -> fail "an unknown request kind must refuse the listing")

let granted = declaration ^ {|[[binding.records]]
source_id="board"
kind="board"
visibilities=["public"]
|}

let test_an_operator_declaration_attaches_with_its_grants () =
  with_installation ~declaration:granted (fun clock config _ _ _root ->
    await clock (fun () -> cycles config >= 1);
    check bool "the declared installation runs" true (host_requests config <> `Null))

let test_a_manual_attach_with_grants_is_refused () =
  with_installation (fun clock config _ _ root ->
    await clock (fun () -> cycles config >= 1);
    let binding = `Assoc [ "sources", `List []
                         ; "records", `List [ `Assoc [ "source_id", `String "board"; "kind", `String "board"
                                                     ; "visibilities", `List [ `String "public" ] ] ] ] in
    match
      Runtime.dispatch ~access:Lane_addon_sources.Operator_configuration ~config ~operation:Runtime.Attach
        (`Assoc [ "manifest_path", `String (Filename.concat root ".masc/package.toml")
                ; "run_id", `String "manual"; "binding", binding ])
    with
    | Error _ -> ()
    | Ok _ -> fail "a manual Attach must not hold record grants")

let board_granted = declaration ^ {|[[binding.records]]
source_id="board"
kind="board"
visibilities=["public"]
|}

let read ?after ?since id source_id =
  `Assoc ([ "kind", `String "read_records"; "request_id", `String id; "source_id", `String source_id ]
          @ (match after with None -> [] | Some cursor -> [ "after", `String cursor ])
          @ match since with None -> [] | Some at -> [ "since", `Float at ])

let post ?(visibility = Board.Public) ?(body = "body") title =
  match Board_dispatch.create_post ~author:"operator" ~content:body ~title ~body ~post_kind:Board.Human_post ~visibility () with
  | Ok post -> Board.Post_id.to_string post.id
  | Error error -> fail (Board.show_board_error error)

let result_of id worker =
  match List.find_opt (fun arguments -> text "request_id" arguments = id) !(worker.delivered) with
  | Some arguments -> member "result" arguments
  | None -> failf "no result for %s" id

let record_titles result =
  member "records" result |> Yojson.Safe.Util.to_list
  |> List.map (fun record -> match member "kind" record with
    | `String "post" -> text "title" record
    | _ -> "comment:" ^ text "body" record)

let test_a_granted_board_is_read_oldest_first_and_retained () =
  with_installation ~declaration:board_granted (fun clock config worker _ root ->
    let first = post "first" in
    ignore (post ~visibility:Board.Internal "hidden");
    (match Board_dispatch.add_comment ~post_id:first ~author:"operator" ~content:"reply" () with
     | Ok _ -> () | Error error -> fail (Board.show_board_error error));
    ignore (post "second");
    worker.listing := [ read "p1" "board" ];
    publish_lane_change ();
    await clock (fun () -> List.exists (fun a -> text "request_id" a = "p1") !(worker.delivered));
    let result = result_of "p1" worker in
    check string "a page" "records" (text "status" result);
    check (list string) "granted records, oldest first" [ "first"; "comment:reply"; "second" ] (record_titles result);
    check bool "the whole board was read" true (member "complete" result = `Bool true);
    let bytes = Yojson.Safe.to_string (member "records" result) in
    check string "the result names the retained page" (Lane_addon_store.digest bytes) (text "sha256" result);
    let store = Lane_addon_store.create ~root:(Filename.concat root ".masc/lane-addons") in
    check bool "and the page is retained" true
      (Lane_addon_store.read_blob store (Lane_addon_store.blob_reference bytes) = Ok bytes))

let test_a_cursor_reads_only_what_came_after () =
  with_installation ~declaration:board_granted (fun clock config worker _ _root ->
    ignore (post "before");
    worker.listing := [ read "c1" "board" ];
    let wake = publish_lane_change in
    wake ();
    await clock (fun () -> List.exists (fun a -> text "request_id" a = "c1") !(worker.delivered));
    let cursor = text "next_cursor" (result_of "c1" worker) in
    ignore (post "after");
    worker.listing := [ read ~after:cursor "c2" "board" ];
    let cycles_before = cycles config in
    wake ();
    await clock (fun () -> cycles config > cycles_before
                           && List.exists (fun a -> text "request_id" a = "c2") !(worker.delivered));
    check (list string) "only the newer post" [ "after" ] (record_titles (result_of "c2" worker)))

let test_a_page_holds_what_fits_the_frame () =
  with_installation ~declaration:board_granted (fun clock config worker _ _root ->
    List.iter (fun title -> ignore (post ~body:(String.make 1500 'x') title)) [ "one"; "two"; "three" ];
    worker.listing := [ read "f1" "board" ];
    worker.on_deliver := (fun arguments ->
      let result = member "result" arguments in
      if text "request_id" arguments = "f1" && member "complete" result = `Bool false then
        worker.listing := [ read ~after:(text "next_cursor" result) "f2" "board" ]);
    publish_lane_change ();
    await clock (fun () -> List.exists (fun a -> text "request_id" a = "f2") !(worker.delivered));
    let first = record_titles (result_of "f1" worker) and second = record_titles (result_of "f2" worker) in
    check bool "the first page is not the whole board" true (member "complete" (result_of "f1" worker) = `Bool false);
    check (list string) "the pages together hold every record once" [ "one"; "two"; "three" ] (first @ second);
    List.iter (fun arguments ->
        check bool "every delivery fits the frame" true (String.length (Yojson.Safe.to_string arguments) <= 4096))
      !(worker.delivered);
    ignore config)

(* A package with no cursor yet reads what was made since it began, not the
   Board's whole history. *)
let test_a_since_read_keeps_what_was_made_from_that_time () =
  with_installation ~declaration:board_granted (fun clock _config worker _ _root ->
    ignore (post "before");
    let since = Unix.gettimeofday () in
    ignore (post "after");
    worker.listing := [ read ~since "s1" "board" ];
    publish_lane_change ();
    await clock (fun () -> List.exists (fun a -> text "request_id" a = "s1") !(worker.delivered));
    let result = result_of "s1" worker in
    check (list string) "only what was made from that time" [ "after" ] (record_titles result);
    worker.listing := [ read ~since:(Unix.gettimeofday () +. 3600.) "s2" "board" ];
    publish_lane_change ();
    await clock (fun () -> List.exists (fun a -> text "request_id" a = "s2") !(worker.delivered));
    let empty = result_of "s2" worker in
    check (list string) "nothing yet" [] (record_titles empty);
    check bool "and no cursor to give" true (member "next_cursor" empty = `Null))

let test_an_ungranted_source_or_a_foreign_cursor_is_not_allowed () =
  with_installation ~declaration:board_granted (fun clock _config worker _ _root ->
    worker.listing := [ read "n1" "wiki"; read ~after:"not-a-cursor" "n2" "board" ];
    publish_lane_change ();
    await clock (fun () -> List.length !(worker.delivered) >= 2);
    check string "an ungranted source" "not_allowed" (text "status" (result_of "n1" worker));
    check string "a cursor this host did not give" "not_allowed" (text "status" (result_of "n2" worker)))

let repository_granted = declaration ^ {|[[binding.records]]
source_id="masc-repo"
kind="repository"
repository_id="masc"
paths=["changelog.d/"]
|}

let git cwd args =
  let command = Filename.quote_command "git" ("-C" :: cwd :: "-c" :: "user.name=Fixture" :: "-c" :: "user.email=f@example.invalid"
                                  (* The fixture runs no hook of the machine it runs on. *)
                                  :: "-c" :: "core.hooksPath=/dev/null" :: args) in
  let channel = Unix.open_process_in command in
  let output = In_channel.input_all channel in
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 -> String.trim output
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> failf "git %s failed" (String.concat " " args)

let side = ref ""

(* A registered repository with three commits on main: two changelog
   fragments and one file outside the grant. Returns the three SHAs. *)
let repository root =
  let dir = Filename.concat root "repos/masc" in
  Fs_compat.mkdir_p dir;
  ignore (git dir [ "init"; "-q"; "-b"; "main" ]);
  let commit path bytes subject =
    write (Filename.concat dir path) bytes;
    ignore (git dir [ "add"; path ]);
    ignore (git dir [ "commit"; "-q"; "-m"; subject ]);
    git dir [ "rev-parse"; "HEAD" ]
  in
  let first = commit "changelog.d/1.md" "first fragment\n" "add the first fragment" in
  let second = commit "lib/x.ml" "let x = 1\n" "add code" in
  let third = commit "changelog.d/2.md" "second fragment\n" "add the second fragment" in
  (* A commit only another branch reaches. *)
  ignore (git dir [ "checkout"; "-q"; "-b"; "side" ]);
  side := commit "changelog.d/1.md" "rewritten on a side branch\n" "rewrite on side";
  ignore (git dir [ "checkout"; "-q"; "main" ]);
  let repository : Repo_manager_types.repository =
    { id = "masc"; name = "masc"; url = "file://" ^ dir; local_path = dir; aliases = []; default_branch = "main"
    ; keepers = []; status = Repo_manager_types.Active; auto_sync = false; sync_interval = 0
    ; created_at = 0L; updated_at = 0L } in
  ignore (Repo_store.add ~base_path:root repository |> unwrap);
  first, second, third

let read_file id ~commit ~path =
  `Assoc [ "kind", `String "read_file"; "request_id", `String id; "source_id", `String "masc-repo"
         ; "commit", `String commit; "path", `String path ]

let delivered id worker = List.exists (fun arguments -> text "request_id" arguments = id) !(worker.delivered)

(* The package asks for each bounded continuation through the same host listing
   that supplied the original request, then reassembles the original JSON. *)
let capture_retained_result worker ~id ~source_id =
  let completed = ref None and marker = ref None in
  let bytes = Buffer.create 4096 in
  let queue_chunk original sha256 offset =
    worker.listing := [Lane_addon_host_request.to_json
      (Read_result {request_id=Printf.sprintf "%s-part-%d" id offset;
        original_request_id=original; source_id; sha256; offset})] in
  worker.on_deliver := (fun arguments ->
    check bool "every delivered frame is bounded" true
      (String.length (Yojson.Safe.to_string arguments) <= 4096);
    let result = member "result" arguments in
    match member "status" result with
    | `String "result_exceeds_frame" when text "request_id" arguments=id ->
        marker := Some result;
        queue_chunk id (text "retained_sha256" result) 0
    | `String "result_chunk" when text "original_request_id" result=id ->
        Buffer.add_string bytes (Base64.decode_exn (text "content" result));
        if member "eof" result = `Bool true then (
          check string "reconstructed result matches its advertised digest"
            (text "sha256" result) (Lane_addon_store.digest (Buffer.contents bytes));
          completed := Some (Yojson.Safe.from_string (Buffer.contents bytes)))
        else queue_chunk id (text "sha256" result) Yojson.Safe.Util.(result |> member "next_offset" |> to_int)
    | _ -> ());
  completed, marker

let test_a_giant_first_record_is_delivered_without_losing_the_next_record () =
  with_installation ~declaration:board_granted (fun clock config worker _ _root ->
    ignore (post ~body:(String.make 12000 'g') "giant");
    ignore (post "after giant");
    let complete, marker = capture_retained_result worker ~id:"giant-page" ~source_id:(Some "board") in
    worker.listing := [read "giant-page" "board"];
    publish_lane_change ();
    await clock (fun () -> Option.is_some !complete);
    let result = Option.get !complete in
    check (list string) "the oversized first record is preserved" ["giant"] (record_titles result);
    check bool "the original page admits more records" true (member "complete" result = `Bool false);
    check bool "the marker preserves the same cursor" true
      (member "next_cursor" (Option.get !marker) = member "next_cursor" result);
    worker.listing := [read ~after:(text "next_cursor" result) "after-giant" "board"];
    publish_lane_change ();
    await clock (fun () -> delivered "after-giant" worker);
    check (list string) "the next record remains reachable" ["after giant"]
      (record_titles (result_of "after-giant" worker));
    ignore config)

let test_large_text_and_binary_files_reconstruct_the_original_bytes () =
  with_installation ~declaration:repository_granted (fun clock _config worker _ root ->
    ignore (repository root);
    let directory = Filename.concat root "repos/masc" in
    List.iter (fun (id, content) ->
      let path = "changelog.d/" ^ id in
      write (Filename.concat directory path) content;
      ignore (git directory ["add"; path]);
      ignore (git directory ["commit"; "-q"; "-m"; id]);
      let commit = git directory ["rev-parse"; "HEAD"] in
      let complete, _marker = capture_retained_result worker ~id ~source_id:(Some "masc-repo") in
      worker.listing := [read_file id ~commit ~path];
      publish_lane_change ();
      await clock (fun () -> Option.is_some !complete);
      let result = Option.get !complete in
      let original = match text "encoding" result with
        | "utf-8" -> text "content" result
        | "base64" -> Base64.decode_exn (text "content" result)
        | encoding -> failf "unexpected file encoding %s" encoding in
      check string "every original file byte survived delivery" content original;
      check string "the file digest is still the raw source digest"
        (Lane_addon_store.digest content) (text "sha256" result))
      ["large-text", String.make 15000 't';
       "large-binary", String.init 15000 (fun i -> Char.chr (i mod 256))])

let test_retention_failure_never_advertises_an_oversized_result () =
  List.iter (fun blocked ->
    with_installation ~mode:(Answer (`Assoc ["question", `String (String.make 12000 'q')]))
      (fun clock config worker _ root ->
        let path = Filename.concat root (".masc/lane-addons/" ^ blocked) in
        write path "not a directory";
        worker.listing := [exact "must-retain"];
        publish_lane_change ();
        await clock (fun () -> member "issue" (host_requests config) <> `Null);
        check int "no unretained reference crossed the worker port" 0 (List.length !(worker.delivered));
        check string "persistence failure is visible" "result_delivery_failed"
          (text "kind" (member "issue" (host_requests config))))) ["evidence"; "host-results"]

let test_retained_result_recovery_does_not_reopen_its_source () =
  with_installation ~declaration:repository_granted (fun clock config worker _ root ->
    ignore (repository root);
    let directory = Filename.concat root "repos/masc" in
    let path = "changelog.d/retained-file" in
    write (Filename.concat directory path) (String.make 12000 'r');
    ignore (git directory ["add"; path]);
    ignore (git directory ["commit"; "-q"; "-m"; "retained file"]);
    let commit = git directory ["rev-parse"; "HEAD"] in
    let request = read_file "recover-without-source" ~commit ~path in
    worker.listing := [request];
    publish_lane_change ();
    await clock (fun () -> delivered "recover-without-source" worker && cycles config >= 2);
    let first = result_of "recover-without-source" worker in
    check string "the original result was retained" "result_exceeds_frame" (text "status" first);
    Unix.rename directory (directory ^ ".offline");
    let before = cycles config in
    worker.listing := [request];
    publish_lane_change ();
    await clock (fun () -> cycles config > before);
    check int "the retained reference is delivered despite the unavailable repository" 2
      (List.length (List.filter (fun arguments -> text "request_id" arguments="recover-without-source") !(worker.delivered)));
    check bool "recovery uses exactly the first retained result" true
      (result_of "recover-without-source" worker = first))

let test_a_repository_is_read_by_first_parent_commits () =
  with_installation ~declaration:repository_granted (fun clock _config worker _ root ->
    let first, _second, third = repository root in
    worker.listing := [ read "g1" "masc-repo" ];
    publish_lane_change ();
    await clock (fun () -> delivered "g1" worker);
    let result = result_of "g1" worker in
    let subjects = member "records" result |> Yojson.Safe.Util.to_list |> List.map (text "subject") in
    check (list string) "oldest first" [ "add the first fragment"; "add code"; "add the second fragment" ] subjects;
    check string "the page names the head it read" third (text "head" result);
    (match member "records" result |> Yojson.Safe.Util.to_list with
     | record :: _ ->
       check string "the first commit" first (text "sha" record);
       check bool "with its changed paths" true (member "paths" record = `List [ `String "changelog.d/1.md" ])
     | [] -> fail "no commits");
    check string "the page is retained" (Lane_addon_store.digest (Yojson.Safe.to_string (member "records" result)))
      (text "sha256" result);
    worker.listing := [ read ~after:first "g2" "masc-repo" ];
    publish_lane_change ();
    await clock (fun () -> delivered "g2" worker);
    let after = member "records" (result_of "g2" worker) |> Yojson.Safe.Util.to_list |> List.map (text "subject") in
    check (list string) "a cursor reads only later commits" [ "add code"; "add the second fragment" ] after)

let test_a_since_read_compares_commit_times () =
  with_installation ~declaration:repository_granted (fun clock _config worker _ root ->
    let first, _second, third = repository root in
    let commit_time sha = float_of_string (git (Filename.concat root "repos/masc") [ "log"; "-1"; "--format=%ct"; sha ]) in
    let subjects id since =
      worker.listing := [ read ~since id "masc-repo" ];
      publish_lane_change ();
      await clock (fun () -> delivered id worker);
      member "records" (result_of id worker) |> Yojson.Safe.Util.to_list |> List.map (text "subject") in
    check (list string) "a time before the history reads all of it"
      [ "add the first fragment"; "add code"; "add the second fragment" ] (subjects "t1" 0.);
    check (list string) "a commit made at that time is kept"
      [ "add the first fragment"; "add code"; "add the second fragment" ] (subjects "t2" (commit_time first));
    check (list string) "nothing after the last commit" [] (subjects "t3" (commit_time third +. 1.));
    check bool "and the page still names the head" true (text "head" (result_of "t3" worker) = third))

let test_a_file_under_the_grant_is_read_at_a_commit () =
  with_installation ~declaration:repository_granted (fun clock _config worker _ root ->
    let first, second, _third = repository root in
    worker.listing := [ read_file "h1" ~commit:first ~path:"changelog.d/1.md"
                      ; read_file "h2" ~commit:second ~path:"lib/x.ml"
                      ; read_file "h3" ~commit:!side ~path:"changelog.d/1.md"
                      ; read_file "h4" ~commit:first ~path:"changelog.d/2.md" ];
    publish_lane_change ();
    await clock (fun () -> List.length !(worker.delivered) >= 4);
    let file = result_of "h1" worker in
    check string "the file" "file" (text "status" file);
    check string "its bytes" "first fragment\n" (text "content" file);
    check string "as text" "utf-8" (text "encoding" file);
    check string "retained" (Lane_addon_store.digest "first fragment\n") (text "sha256" file);
    check string "a path outside the grant" "not_allowed" (text "status" (result_of "h2" worker));
    check string "a commit the branch does not reach" "not_allowed" (text "status" (result_of "h3" worker));
    check string "a file that did not exist then" "not_allowed" (text "status" (result_of "h4" worker)))

let test_an_unregistered_repository_waits () =
  with_installation ~declaration:repository_granted (fun clock config worker _ _root ->
    worker.listing := [ read "u1" "masc-repo" ];
    let before = cycles config in
    publish_lane_change ();
    await clock (fun () -> cycles config > before);
    check int "nothing was delivered" 0 (List.length !(worker.delivered));
    match member "waiting" (host_requests config) with
    | `List [ waiting ] -> check string "it waits" "source_unavailable" (text "reason" (member "reason" waiting))
    | _ -> fail "a read of an unregistered repository must wait")

let wiki_granted = declaration ^ {|[[binding.records]]
source_id="wiki"
kind="wiki"
|}

(* Pages are written through the wiki's own tools, so the fixture has the
   same files and [log.md] lines a Keeper's writes leave. *)
let wiki root name args =
  match Tool_wiki.dispatch { Tool_wiki.base_path = root; agent_name = "operator" } ~name ~args:(`Assoc args) with
  | Some result when Tool_result.is_success result -> ()
  | Some result -> fail (Tool_result.message result)
  | None -> failf "no wiki tool %s" name

let create_page ?(body = "body\n") root page =
  wiki root "masc_wiki_create"
    [ "page", `String page; "title", `String ("Title of " ^ page); "summary", `String "One line"
    ; "source", `String "research"; "body", `String body ]

let update_page root page ~base_revision body =
  wiki root "masc_wiki_update"
    [ "page", `String page; "base_revision", `Int base_revision; "body", `String body; "note", `String "edit" ]

let page_versions result =
  member "records" result |> Yojson.Safe.Util.to_list
  |> List.map (fun record ->
    Printf.sprintf "%s r%d %S" (text "name" record) (Yojson.Safe.Util.to_int (member "revision" record)) (text "body" record))

let read_wiki clock worker ?after ?since id =
  worker.listing := [ read ?after ?since id "wiki" ];
  publish_lane_change ();
  await clock (fun () -> delivered id worker);
  result_of id worker

let test_a_wiki_grant_has_no_other_key () =
  let binding records = `Assoc [ "records", `List records ] in
  let wiki_grant extra = `Assoc ([ "source_id", `String "wiki"; "kind", `String "wiki" ] @ extra) in
  (match Lane_addon_records.grants ~operator_owned:true (binding [ wiki_grant [] ]) with
   | Ok [ Lane_addon_records.Wiki { source_id = "wiki" } ] -> ()
   | Ok _ | Error _ -> fail "a wiki grant names only its source_id");
  check bool "a wiki grant with paths is refused" true
    (Result.is_error (Lane_addon_records.grants ~operator_owned:true
                        (binding [ wiki_grant [ "paths", `List [ `String "a/" ] ] ])))

let test_a_granted_wiki_is_read_by_each_pages_latest_log_line () =
  with_installation ~declaration:wiki_granted (fun clock _config worker _ root ->
    create_page ~body:"first body\n" root "alpha";
    create_page ~body:"beta body\n" root "beta";
    update_page root "alpha" ~base_revision:1 "second body\n";
    let result = read_wiki clock worker "w1" in
    check string "a page" "records" (text "status" result);
    check (list string) "each page once, at its latest line, as it is now"
      [ {|beta r1 "beta body\n"|}; {|alpha r2 "second body\n"|} ] (page_versions result);
    check bool "the whole wiki was read" true (member "complete" result = `Bool true);
    let bytes = Yojson.Safe.to_string (member "records" result) in
    check string "the result names the retained page" (Lane_addon_store.digest bytes) (text "sha256" result);
    let store = Lane_addon_store.create ~root:(Filename.concat root ".masc/lane-addons") in
    check bool "and the page is retained" true
      (Lane_addon_store.read_blob store (Lane_addon_store.blob_reference bytes) = Ok bytes))

let test_a_wiki_cursor_pages_revisions_forward () =
  with_installation ~declaration:wiki_granted (fun clock _config worker _ root ->
    create_page ~body:"alpha one\n" root "alpha";
    create_page ~body:"beta one\n" root "beta";
    let first = read_wiki clock worker "v1" in
    update_page root "alpha" ~base_revision:1 "alpha two\n";
    let second = read_wiki clock worker ~after:(text "next_cursor" first) "v2" in
    check (list string) "only the newer revision" [ {|alpha r2 "alpha two\n"|} ] (page_versions second);
    let third = read_wiki clock worker ~after:(text "next_cursor" second) "v3" in
    check (list string) "nothing after the last line" [] (page_versions third);
    check bool "and that is the whole wiki" true (member "complete" third = `Bool true);
    check string "the cursor stays where it was" (text "next_cursor" second) (text "next_cursor" third))

(* The log stamps only the minute, so a since read keeps a page written in
   that minute and drops one whose minute ended before that time. *)
let test_a_since_read_of_the_wiki_compares_log_minutes () =
  with_installation ~declaration:wiki_granted (fun clock _config worker _ root ->
    create_page ~body:"old\n" root "alpha";
    create_page ~body:"new\n" root "beta";
    let log = Filename.concat (Config_dir_resolver.wiki_dir ~base_path:root) Wiki_journal.log_file in
    let restamped =
      In_channel.with_open_text log In_channel.input_all
      |> String.split_on_char '\n'
      |> List.map (fun line ->
        let page = List.nth_opt (String.split_on_char '|' line) 1 |> Option.map String.trim in
        if String.starts_with ~prefix:"## [" line && page = Some "alpha"
        then "## [2020-01-01 00:00" ^ String.sub line 20 (String.length line - 20)
        else line)
      |> String.concat "\n"
    in
    Out_channel.with_open_text log (fun channel -> Out_channel.output_string channel restamped);
    let beta =
      match List.find_opt (fun (line : Wiki_log.line) -> line.page = "beta") (Wiki_log.parse ~minute_time:Wiki_log_clock.local_minute restamped).lines with
      | Some line -> line.written_at
      | None -> fail "beta has a log line"
    in
    check (list string) "a page from that minute is read, an older one is not"
      [ {|beta r1 "new\n"|} ] (page_versions (read_wiki clock worker ~since:(beta +. 59.) "t1"));
    let later = read_wiki clock worker ~since:(beta +. 60.) "t2" in
    check (list string) "nothing after that minute" [] (page_versions later);
    check bool "and no cursor to give" true (member "next_cursor" later = `Null);
    check (list string) "time zero reads every page"
      [ {|alpha r1 "old\n"|}; {|beta r1 "new\n"|} ] (page_versions (read_wiki clock worker ~since:0. "t3")))

let test_wiki_pages_hold_what_fits_the_frame () =
  with_installation ~declaration:wiki_granted (fun clock _config worker _ root ->
    List.iter (fun page -> create_page ~body:(String.make 1500 'x') root page) [ "one"; "two"; "three" ];
    worker.on_deliver := (fun arguments ->
      let result = member "result" arguments in
      if text "request_id" arguments = "x1" && member "complete" result = `Bool false then
        worker.listing := [ read ~after:(text "next_cursor" result) "x2" "wiki" ]);
    worker.listing := [ read "x1" "wiki" ];
    publish_lane_change ();
    await clock (fun () -> delivered "x2" worker);
    let names id = member "records" (result_of id worker) |> Yojson.Safe.Util.to_list |> List.map (text "name") in
    check bool "the first page is not the whole wiki" true (member "complete" (result_of "x1" worker) = `Bool false);
    check (list string) "the pages together hold every page once" [ "one"; "two"; "three" ] (names "x1" @ names "x2");
    List.iter (fun arguments ->
        check bool "every delivery fits the frame" true (String.length (Yojson.Safe.to_string arguments) <= 4096))
      !(worker.delivered))

let test_a_page_that_is_gone_or_does_not_read_gives_no_record () =
  with_installation ~declaration:wiki_granted (fun clock _config worker _ root ->
    let empty = read_wiki clock worker "z0" in
    check (list string) "a wiki with no log has no records" [] (page_versions empty);
    check bool "and is complete" true (member "complete" empty = `Bool true);
    create_page ~body:"kept\n" root "kept";
    create_page root "gone";
    create_page root "broken";
    Sys.remove (Tool_wiki.page_path ~base_path:root "gone");
    Out_channel.with_open_text (Tool_wiki.page_path ~base_path:root "broken")
      (fun channel -> Out_channel.output_string channel "no header");
    check (list string) "only the page that reads" [ {|kept r1 "kept\n"|} ] (page_versions (read_wiki clock worker "z1")))

let test_a_wiki_refuses_a_cursor_it_did_not_give_and_read_file () =
  with_installation ~declaration:wiki_granted (fun clock _config worker _ root ->
    create_page root "alpha";
    let file id = `Assoc [ "kind", `String "read_file"; "request_id", `String id; "source_id", `String "wiki"
                         ; "commit", `String (String.make 40 'a'); "path", `String "alpha.md" ] in
    worker.listing := [ read ~after:"1|beta|1" "y1" "wiki"; read ~after:"2|alpha|1" "y2" "wiki"
                      ; read ~after:"01|alpha|1" "y3" "wiki"; file "y4" ];
    publish_lane_change ();
    await clock (fun () -> List.length !(worker.delivered) >= 4);
    check string "a line the log does not hold there" "not_allowed" (text "status" (result_of "y1" worker));
    check string "a position past the log" "not_allowed" (text "status" (result_of "y2" worker));
    check string "another spelling of a cursor" "not_allowed" (text "status" (result_of "y3" worker));
    check string "read_file on a wiki" "not_allowed" (text "status" (result_of "y4" worker)))

let github_granted = declaration ^ {|[[binding.records]]
source_id="masc-prs"
kind="github_pulls"
repository_id="masc"
|}

let contains ~needle haystack =
  let n = String.length needle in
  let rec at i = i + n <= String.length haystack && (String.sub haystack i n = needle || at (i + 1)) in
  at 0

let connection ?next nodes =
  `Assoc [ "pageInfo", `Assoc [ "hasNextPage", `Bool (Option.is_some next)
                              ; "endCursor", (match next with Some cursor -> `String cursor | None -> `Null) ]
         ; "nodes", `List nodes ]

let in_data json = `Assoc [ "data", json ]

let pull_node ?(author = `Assoc [ "login", `String "codex" ]) ~id ~number ~merged ~merge_commit () =
  `Assoc [ "id", `String id; "number", `Int number; "title", `String (Printf.sprintf "PR %d" number)
         ; "body", `String "why it changed"; "merged", `Bool merged
         ; "mergedAt", (if merged then `String "2026-10-20T10:00:00Z" else `Null)
         ; "mergeCommit", (match merge_commit with Some oid -> `Assoc [ "oid", `String oid ] | None -> `Null)
         ; "author", author ]

let review_comment id =
  `Assoc [ "databaseId", `Int id; "author", `Assoc [ "login", `String "pangyo-preachers" ]
         ; "createdAt", `String "2026-10-20T09:00:00Z"; "path", `String "lib/x.ml"; "line", `Int 3
         ; "body", `String (Printf.sprintf "comment %d" id) ]

let review ~id ~database_id ~comments =
  `Assoc [ "id", `String id; "databaseId", `Int database_id; "author", `Assoc [ "login", `String "be-sleepers" ]
         ; "submittedAt", `String "2026-10-20T09:30:00Z"; "state", `String "APPROVED"; "body", `String "looks right"
         ; "comments", comments ]

(* GitHub as the fixture answers it: the first commit is PR 11's merge commit
   and PR 11 has two pages of reviews, the first review two pages of comments;
   the second commit belongs to PR 12, which was not merged, and to PR 14,
   which was merged as another commit; the third is PR 13's merge commit,
   written by a deleted account. [merged] lists the commits a pull request
   merged; a first commit outside it is one GitHub does not hold. Every
   request is kept in [posts]. *)
let github_fixture ?(posts = ref []) ~merged (first, second, third) : Lane_addon_records.github =
  fun ~repository_id ->
  if repository_id <> "masc" then Error ("no repository " ^ repository_id)
  else
    Ok { Lane_addon_records.owner = "jeong-sik"; name = "masc"; post = fun body ->
        posts := body :: !posts;
        let query = text "query" body and variables = member "variables" body in
        let var key = match member key variables with `String value -> Some value | _ -> None in
        if contains ~needle:"associatedPullRequests" query then
          let answer nodes =
            Ok (in_data (`Assoc [ "repository", `Assoc [ "object", `Assoc [ "associatedPullRequests", connection nodes ] ] ])) in
          match var "oid" with
          | Some oid when oid = first && List.mem first merged ->
            answer [ pull_node ~id:"PR11" ~number:11 ~merged:true ~merge_commit:(Some first) () ]
          | Some oid when oid = first -> Ok (in_data (`Assoc [ "repository", `Assoc [ "object", `Null ] ]))
          | Some oid when oid = second ->
            answer [ pull_node ~id:"PR12" ~number:12 ~merged:false ~merge_commit:None ()
                   ; pull_node ~id:"PR14" ~number:14 ~merged:true ~merge_commit:(Some third) () ]
          | Some oid when oid = third && List.mem third merged ->
            answer [ pull_node ~author:`Null ~id:"PR13" ~number:13 ~merged:true ~merge_commit:(Some third) () ]
          | Some _ | None -> answer []
        else if contains ~needle:"on PullRequestReview" query then
          (match var "id", var "after" with
           | Some "R1", Some "comments-2" -> Ok (in_data (`Assoc [ "node", `Assoc [ "comments", connection [ review_comment 2 ] ] ]))
           | _ -> Error "an unexpected page of review comments")
        else if contains ~needle:"on PullRequest" query then
          (match var "id", var "after" with
           | Some "PR11", None ->
             Ok (in_data (`Assoc [ "node", `Assoc [ "reviews", connection ~next:"reviews-2"
               [ review ~id:"R1" ~database_id:101 ~comments:(connection ~next:"comments-2" [ review_comment 1 ]) ] ] ]))
           | Some "PR11", Some "reviews-2" ->
             Ok (in_data (`Assoc [ "node", `Assoc [ "reviews", connection
               [ review ~id:"R2" ~database_id:102 ~comments:(connection []) ] ] ]))
           | Some "PR13", None -> Ok (in_data (`Assoc [ "node", `Assoc [ "reviews", connection [] ] ]))
           | _ -> Error "an unexpected page of reviews")
        else Error "an unexpected query" }

let read_prs clock worker ?after id =
  worker.listing := [ read ?after id "masc-prs" ];
  publish_lane_change ();
  await clock (fun () -> delivered id worker);
  result_of id worker

let numbers result =
  member "records" result |> Yojson.Safe.Util.to_list |> List.map (fun record -> Yojson.Safe.Util.to_int (member "number" record))

let test_a_github_pulls_grant_names_its_repository () =
  let binding grant = `Assoc [ "records", `List [ `Assoc grant ] ] in
  let grant = [ "source_id", `String "prs"; "kind", `String "github_pulls"; "repository_id", `String "masc" ] in
  (match Lane_addon_records.grants ~operator_owned:true (binding grant) with
   | Ok [ Lane_addon_records.Github_pulls { source_id = "prs"; repository_id = "masc" } ] -> ()
   | Ok _ | Error _ -> fail "a github_pulls grant names its source and repository");
  check bool "one without a repository is refused" true
    (Result.is_error (Lane_addon_records.grants ~operator_owned:true (binding (List.remove_assoc "repository_id" grant))));
  check bool "one with paths is refused" true
    (Result.is_error (Lane_addon_records.grants ~operator_owned:true
                        (binding (grant @ [ "paths", `List [ `String "lib/" ] ]))))

let test_merged_pulls_come_in_commit_order_with_every_review_page () =
  with_installation ~declaration:github_granted (fun clock _config worker _ root ->
    let ((first, _, third) as commits) = repository root in
    Runtime.register_github_reader (github_fixture ~merged:[ first; third ] commits);
    let result = read_prs clock worker "gp1" in
    check (list int) "the merged pull requests, in the order of their commits" [ 11; 13 ] (numbers result);
    (match member "records" result |> Yojson.Safe.Util.to_list with
     | [ eleven; thirteen ] ->
       check string "a record names its merge commit" first (text "merge_commit" eleven);
       let reviews = member "reviews" eleven |> Yojson.Safe.Util.to_list in
       check (list int) "every page of reviews" [ 101; 102 ]
         (List.map (fun review -> Yojson.Safe.Util.to_int (member "id" review)) reviews);
       check (list string) "and every page of a review's comments" [ "comment 1"; "comment 2" ]
         (List.map (text "body") (member "comments" (List.hd reviews) |> Yojson.Safe.Util.to_list));
       check bool "a deleted account is a null author" true (member "author" thirteen = `Null)
     | _ -> fail "two records");
    check string "the cursor is the last commit read" third (text "next_cursor" result);
    check bool "and the history was read to its head" true (member "complete" result = `Bool true);
    check string "the page is retained" (Lane_addon_store.digest (Yojson.Safe.to_string (member "records" result)))
      (text "sha256" result))

let test_a_commit_no_pull_request_merged_moves_the_cursor_without_a_record () =
  with_installation ~declaration:github_granted (fun clock _config worker _ root ->
    let ((first, _, third) as commits) = repository root in
    Runtime.register_github_reader (github_fixture ~merged:[ first; third ] commits);
    let after_first = read_prs clock worker ~after:first "gp2" in
    check (list int) "only what came after the cursor" [ 13 ] (numbers after_first);
    Runtime.register_github_reader (github_fixture ~merged:[] commits);
    let all = read_prs clock worker "gp5" in
    check (list int) "a commit GitHub does not hold gives no record" [] (numbers all);
    let none = read_prs clock worker ~after:first "gp3" in
    check (list int) "commits no pull request merged give no record" [] (numbers none);
    check string "and the cursor still passes them" third (text "next_cursor" none);
    let at_head = read_prs clock worker ~after:third "gp4" in
    check (list int) "nothing after the head" [] (numbers at_head);
    check string "the cursor stays at the head" third (text "next_cursor" at_head))

(* A since read keeps the pull requests whose merge commit was made at or
   after that time. *)
let test_a_since_read_of_pull_requests_compares_merge_commit_times () =
  with_installation ~declaration:github_granted (fun clock _config worker _ root ->
    let ((first, _, third) as commits) = repository root in
    Runtime.register_github_reader (github_fixture ~merged:[ first; third ] commits);
    let commit_time sha = float_of_string (git (Filename.concat root "repos/masc") [ "log"; "-1"; "--format=%ct"; sha ]) in
    let read_since id since =
      worker.listing := [ read ~since id "masc-prs" ];
      publish_lane_change ();
      await clock (fun () -> delivered id worker);
      result_of id worker in
    check (list int) "a time before the history reads every merged pull request" [ 11; 13 ]
      (numbers (read_since "gs1" 0.));
    let later = read_since "gs2" (commit_time third +. 1.) in
    check (list int) "nothing merged after the last commit" [] (numbers later);
    check bool "and no cursor to give" true (member "next_cursor" later = `Null))

let test_github_that_cannot_be_read_waits () =
  with_installation ~declaration:github_granted (fun clock config worker _ root ->
    let commits = repository root in
    Runtime.register_github_reader (fun ~repository_id:_ -> Error "the PR reader is not ready");
    worker.listing := [ read "gw1" "masc-prs" ];
    let before = cycles config in
    publish_lane_change ();
    await clock (fun () -> cycles config > before);
    check int "nothing was delivered without a reader" 0 (List.length !(worker.delivered));
    (match member "waiting" (host_requests config) with
     | `List [ waiting ] -> check string "it waits" "source_unavailable" (text "reason" (member "reason" waiting))
     | _ -> fail "a read without a reader must wait");
    Runtime.register_github_reader (fun ~repository_id ->
      match github_fixture ~merged:[] commits ~repository_id with
      | Ok session -> Ok { session with Lane_addon_records.post = (fun _ -> Error "rate limited") }
      | Error detail -> Error detail);
    let before = cycles config in
    publish_lane_change ();
    await clock (fun () -> cycles config > before);
    check int "nor while GitHub refuses" 0 (List.length !(worker.delivered)))

let test_read_file_refuses_github_pulls () =
  with_installation ~declaration:github_granted (fun clock _config worker _ root ->
    let first, _, _ = repository root in
    worker.listing := [ `Assoc [ "kind", `String "read_file"; "request_id", `String "gf1"; "source_id", `String "masc-prs"
                               ; "commit", `String first; "path", `String "changelog.d/1.md" ] ];
    publish_lane_change ();
    await clock (fun () -> delivered "gf1" worker);
    check string "read_file reads a repository grant only" "not_allowed" (text "status" (result_of "gf1" worker)))

let asking_manifest = manifest ^ {|[world.asks]
operator=true
|}

let question_json =
  `Assoc [ "question_id", `String "pick"; "header", `String "Ledger"; "prompt", `String "What does the ledger record?"
         ; "choices", `List [ `Assoc [ "choice_id", `String "facts"; "label", `String "Facts"; "description", `Null ]
                            ; `Assoc [ "choice_id", `String "plans"; "label", `String "Plans"; "description", `Null ] ]
         ; "mode", `String "single"; "free_text", `Assoc [ "kind", `String "choices_only" ] ]

let ask id = `Assoc [ "kind", `String "ask"; "request_id", `String id; "questions", `List [ question_json ] ]
let withdraw id ask_id = `Assoc [ "kind", `String "withdraw_ask"; "request_id", `String id; "ask_id", `String ask_id
                                ; "reason", `String "superseded" ]

let operator = { Keeper_ask.surface = Surface_ref.Dashboard { session_id = None }; actor_id = None; display_name = None }

let answer config ask_id =
  Runtime.answer_installation_question ~config ~declaration_id:"quiz" ~ask_id
    ~submissions:[ "pick", Keeper_ask.Chose { choice_ids = [ "facts" ] } ] ~responder:operator

let test_a_question_waits_for_the_operator_and_the_answer_starts_a_cycle () =
  with_installation ~manifest:asking_manifest ~listing:[ ask "q1" ] (fun clock config worker _ root ->
    await clock (fun () -> cycles config >= 1);
    check int "nothing is delivered before the answer" 0 (List.length !(worker.delivered));
    (match member "waiting" (host_requests config) with
     | `List [ waiting ] -> check string "it waits for the operator" "awaiting_operator" (text "reason" (member "reason" waiting))
     | _ -> fail "an open question must wait");
    (match Runtime.installation_questions ~config with
     | Ok [ ("quiz", [ ("q1", (asked, Keeper_ask.Open)) ]) ] ->
       check string "asked by the installation" "Host request fixture" asked.Lane_addon_asks.title
     | Ok _ | Error _ -> fail "the question must be listed open under its declaration");
    check bool "the answer is recorded" true (Result.is_ok (answer config "q1"));
    await clock (fun () -> delivered "q1" worker);
    let result = result_of "q1" worker in
    check string "answered" "answered" (text "status" result);
    check bool "with the operator's choice" true
      (member "answers" result = `List [ `Assoc [ "question_id", `String "pick"
                                               ; "response", `Assoc [ "kind", `String "chose"; "choice_ids", `List [ `String "facts" ] ] ] ]);
    check bool "the Keeper question log is untouched" false (Sys.file_exists (Filename.concat root ".masc/keeper_ask")))

let test_an_answer_given_while_the_worker_is_down_reaches_the_next_worker () =
  with_installation ~manifest:asking_manifest ~listing:[ ask "q2" ] (fun clock config worker _ root ->
    await clock (fun () -> cycles config >= 1);
    let directory = Filename.concat root ".masc/config/lane-addons" in
    let path = Filename.concat directory "quiz.toml" in
    Sys.rename path (path ^ ".off");
    ignore (Runtime.reconcile_configuration ~config ~directory |> unwrap);
    await clock (fun () -> host_requests config = `Null);
    check bool "answered while no worker runs" true (Result.is_ok (answer config "q2"));
    Sys.rename (path ^ ".off") path;
    ignore (Runtime.reconcile_configuration ~config ~directory |> unwrap);
    await clock (fun () -> delivered "q2" worker);
    check string "the next worker receives it" "answered" (text "status" (result_of "q2" worker)))

let test_only_the_package_withdraws_its_question () =
  with_installation ~manifest:asking_manifest ~listing:[ ask "q3" ] (fun clock config worker _ _root ->
    await clock (fun () -> cycles config >= 1);
    worker.listing := [ withdraw "w1" "q3"; ask "q3" ];
    publish_lane_change ();
    await clock (fun () -> delivered "w1" worker && delivered "q3" worker);
    check string "the withdrawal is answered" "withdrawn" (text "status" (result_of "w1" worker));
    check string "and the question ends withdrawn" "withdrawn" (text "status" (result_of "q3" worker));
    match answer config "q3" with
    | Error (Lane_addon_asks.Already_withdrawn _) -> ()
    | Ok _ | Error _ -> fail "an answer after the package withdrew must be refused")

let test_an_oversized_operator_answer_uses_source_free_continuations () =
  let question = `Assoc ["question_id", `String "detail"; "header", `String "Details";
    "prompt", `String "Describe the evidence"; "choices", `List []; "mode", `String "single";
    "free_text", `Assoc ["kind", `String "allowed"; "hint", `String "Full explanation"]] in
  let request = `Assoc ["kind", `String "ask"; "request_id", `String "large-answer";
    "questions", `List [question]; "context", `String "Keep the complete operator answer"] in
  with_installation ~manifest:asking_manifest ~listing:[request] (fun clock config worker _ _root ->
    await clock (fun () -> cycles config >= 1);
    let complete, marker = capture_retained_result worker ~id:"large-answer" ~source_id:None in
    let answer = String.make 12000 'a' ^ "\nFull answer" in
    check bool "the large free-text answer was recorded" true
      (Result.is_ok (Runtime.answer_installation_question ~config ~declaration_id:"quiz"
        ~ask_id:"large-answer" ~submissions:["detail", Keeper_ask.Wrote answer] ~responder:operator));
    await clock (fun () -> Option.is_some !complete);
    check bool "Ask results have no record-source authority" true
      (member "source_id" (Option.get !marker) = `Null);
    let result = Option.get !complete in
    check string "the original result remains answered" "answered" (text "status" result);
    check bool "the operator's entire answer survives bounded delivery" true
      (member "answers" result = `List [`Assoc ["question_id", `String "detail";
        "response", `Assoc ["kind", `String "wrote"; "text", `String answer]]]);
    let first = Option.get !marker in
    worker.on_deliver := ignore;
    worker.listing := [request];
    publish_lane_change ();
    await clock (fun () -> List.length (List.filter (fun arguments ->
      text "request_id" arguments="large-answer") !(worker.delivered))=2);
    check bool "relisting reuses exactly the retained first answer" true
      (result_of "large-answer" worker = first))

let test_a_package_without_world_asks_is_not_allowed_to_ask () =
  with_installation ~listing:[ ask "q4" ] (fun clock config worker _ _root ->
    await clock (fun () -> delivered "q4" worker);
    check string "not allowed" "not_allowed" (text "status" (result_of "q4" worker));
    check bool "and nothing is recorded" true (Runtime.installation_questions ~config = Ok []))

let () =
  Mirage_crypto_rng_unix.use_default ();
  run "lane add-on host request cycle"
    [ ( "cycle"
      , [ test_case "a started worker gets its final result once" `Quick test_a_started_worker_gets_its_final_result_once
        ; test_case "an exported reply starts its pending host work" `Quick
            (test_an_exported_reply_starts_its_pending_host_work ~is_error:false)
        ; test_case "an exported worker error can retain pending host work" `Quick
            (test_an_exported_reply_starts_its_pending_host_work ~is_error:true)
        ; test_case "model events admit and withdraw one exact scope" `Quick test_model_events_admit_and_withdraw_an_exact_scope
        ; test_case "withdrawal event can precede a stale listing" `Quick test_withdrawal_event_before_stale_listing
        ; test_case "retirement cancels exact before worker cleanup finishes" `Quick test_retirement_cancels_exact_before_worker_cleanup_finishes
        ; test_case "original tool destination survives replacement and reattachment" `Quick
            test_original_tool_destination_survives_replacement_and_reattachment
        ; test_case "capture uses actual live provenance before RPC" `Quick
            test_capture_factory_uses_actual_live_declaration_before_any_rpc
        ; test_case "a request that is not final waits for the next event" `Quick
            test_a_request_that_is_not_final_waits_for_the_next_event
        ; test_case "a request listed again after delivery ends the cycle" `Quick
            test_a_request_listed_again_after_delivery_ends_the_cycle
        ; test_case "a result larger than the frame is delivered as its size" `Quick
            test_a_result_larger_than_the_frame_is_delivered_as_its_size
        ; test_case "a listing with an unknown kind is refused whole" `Quick
            test_a_listing_with_an_unknown_kind_is_refused_whole ] )
    ; ( "owner wakes"
      , [ test_case "scope, metadata publication and the existing MCP bridge" `Quick
            test_scoped_owner_wakes_preserve_mcp_and_metadata_publication
        ; test_case "accepted original and restored results wake outside the RPC" `Quick
            test_exact_result_wakes_after_rpc_and_isolates_observer_failure
        ; test_case "an unaccepted result does not wake its owner" `Quick
            (test_only_accepted_exact_results_wake_owner Unaccepted)
        ; test_case "a malformed receipt does not wake its owner" `Quick
            (test_only_accepted_exact_results_wake_owner Malformed)
        ; test_case "a lost receipt does not wake its owner" `Quick
            (test_only_accepted_exact_results_wake_owner Transport_failed)
        ; test_case "an accepted non-Exact request does not wake an Exact owner" `Quick
            (test_only_accepted_exact_results_wake_owner Non_exact)
        ] )
    ; ( "grants"
      , [ test_case "an operator declaration attaches with its grants" `Quick
            test_an_operator_declaration_attaches_with_its_grants
        ; test_case "a manual attach with grants is refused" `Quick test_a_manual_attach_with_grants_is_refused ] )
    ; ( "board reads"
      , [ test_case "a granted board is read oldest first and retained" `Quick
            test_a_granted_board_is_read_oldest_first_and_retained
        ; test_case "a cursor reads only what came after" `Quick test_a_cursor_reads_only_what_came_after
        ; test_case "a page holds what fits the frame" `Quick test_a_page_holds_what_fits_the_frame
        ; test_case "a since read keeps what was made from that time" `Quick
            test_a_since_read_keeps_what_was_made_from_that_time
        ; test_case "an ungranted source or a foreign cursor is not allowed" `Quick
            test_an_ungranted_source_or_a_foreign_cursor_is_not_allowed
        ; test_case "a giant first record preserves the next record" `Quick
            test_a_giant_first_record_is_delivered_without_losing_the_next_record ] )
    ; ( "repository reads"
      , [ test_case "a repository is read by first-parent commits" `Quick
            test_a_repository_is_read_by_first_parent_commits
        ; test_case "a since read compares commit times" `Quick test_a_since_read_compares_commit_times
        ; test_case "a file under the grant is read at a commit" `Quick test_a_file_under_the_grant_is_read_at_a_commit
        ; test_case "an unregistered repository waits" `Quick test_an_unregistered_repository_waits
        ; test_case "large text and binary files reconstruct their original bytes" `Quick
            test_large_text_and_binary_files_reconstruct_the_original_bytes
        ; test_case "retention failure advertises no oversized result" `Quick
            test_retention_failure_never_advertises_an_oversized_result
        ; test_case "retained recovery does not reopen its unavailable source" `Quick
            test_retained_result_recovery_does_not_reopen_its_source ] )
    ; ( "wiki reads"
      , [ test_case "a wiki grant has no other key" `Quick test_a_wiki_grant_has_no_other_key
        ; test_case "a granted wiki is read by each page's latest log line" `Quick
            test_a_granted_wiki_is_read_by_each_pages_latest_log_line
        ; test_case "a wiki cursor pages revisions forward" `Quick test_a_wiki_cursor_pages_revisions_forward
        ; test_case "a since read of the wiki compares log minutes" `Quick
            test_a_since_read_of_the_wiki_compares_log_minutes
        ; test_case "wiki pages hold what fits the frame" `Quick test_wiki_pages_hold_what_fits_the_frame
        ; test_case "a page that is gone or does not read gives no record" `Quick
            test_a_page_that_is_gone_or_does_not_read_gives_no_record
        ; test_case "a wiki refuses a cursor it did not give and read_file" `Quick
            test_a_wiki_refuses_a_cursor_it_did_not_give_and_read_file ] )
    ; ( "github pull request reads"
      , [ test_case "a github_pulls grant names its repository" `Quick test_a_github_pulls_grant_names_its_repository
        ; test_case "merged pulls come in commit order with every review page" `Quick
            test_merged_pulls_come_in_commit_order_with_every_review_page
        ; test_case "a commit no pull request merged moves the cursor without a record" `Quick
            test_a_commit_no_pull_request_merged_moves_the_cursor_without_a_record
        ; test_case "a since read of pull requests compares merge commit times" `Quick
            test_a_since_read_of_pull_requests_compares_merge_commit_times
        ; test_case "GitHub that cannot be read waits" `Quick test_github_that_cannot_be_read_waits
        ; test_case "read_file refuses github_pulls" `Quick test_read_file_refuses_github_pulls ] )
    ; ( "asks"
      , [ test_case "a question waits for the operator and the answer starts a cycle" `Quick
            test_a_question_waits_for_the_operator_and_the_answer_starts_a_cycle
        ; test_case "an answer given while the worker is down reaches the next worker" `Quick
            test_an_answer_given_while_the_worker_is_down_reaches_the_next_worker
        ; test_case "an oversized answer uses source-free continuations" `Quick
            test_an_oversized_operator_answer_uses_source_free_continuations
        ; test_case "only the package withdraws its question" `Quick test_only_the_package_withdraws_its_question
        ; test_case "a package without world.asks is not allowed to ask" `Quick
            test_a_package_without_world_asks_is_not_allowed_to_ask ] ) ]
