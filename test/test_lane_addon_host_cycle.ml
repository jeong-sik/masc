(** The host request cycle of a declared installation (RFC operator-quiz
    §4.4): TOML declaration, reconcile, the instance fiber, retention and the
    registry subscription are real. Only the worker and the exact runner are
    replaced. *)
open Alcotest
open Masc
module Runtime = Lane_addon_runtime
module Exact = Lane_addon_exact
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

let manifest = {|id="quiz-package"
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
max_reply_bytes=4096
|}
let author_schema = {|{"type":"object","properties":{"question":{"type":"string"}},"required":["question"],"additionalProperties":false}|}
let declaration = {|id="quiz"
run_id="quiz-world"
manifest_path="../../package.toml"
[binding]
sources=[]
|}

let exact id = `Assoc [ "kind", `String "exact_output"; "request_id", `String id; "output", `String "author"
                      ; "messages", `List [ `String "Write one question." ] ]

(* What the fake worker lists and what it received. *)
type worker = {
  listing : Yojson.Safe.t list ref;
  delivered : Yojson.Safe.t list ref;
  consume : bool ref;  (** Whether a delivery removes the request and answers accepted. *)
  observations : int ref;
}

(* What the fake runner does: answer with this value, or report the lane off. *)
type runner_mode = Answer of Yojson.Safe.t | Off
type runner_state = { mode : runner_mode ref; resolutions : int ref }

let runner state : Exact.runner = fun ~lane_key:_ ~schema:_ _ ->
  incr state.resolutions;
  match !(state.mode) with
  | Off -> Error Exact.Lane_off
  | Answer json ->
      Ok (fun ~validate ->
        match validate json with
        | Ok output -> Exact.Call_ended (Exact.Answered { output; slot = "fixture"; usage = None })
        | Error detail -> Exact.Call_ended (Exact.Invalid_output { detail }))

let port ?await_change ?(before_listing = fun _ -> ()) worker : Runtime.For_testing.host_port = {
  await_change;
  list_requests = (fun () ->
    let requests= !(worker.listing) in
    before_listing requests;
    Ok (`Assoc [ "requests", `List requests ]));
  deliver = (fun ~arguments ->
    worker.delivered := arguments :: !(worker.delivered);
    let request_id = text "request_id" arguments in
    if !(worker.consume) then
      worker.listing := List.filter (fun request -> text "request_id" request <> request_id) !(worker.listing);
    Ok (`Assoc [ "accepted", `Bool !(worker.consume) ]));
}

let backend ?await_change ?before_listing ?(before_stop = fun () -> ()) worker : Runtime.For_testing.backend = {
  start = (fun ~sw:_ ~state_owner:_ ~instance_id ~installation_id:_ ~package:_ ~binding:_ ~on_authority ~is_live_instance:_ ~on_created ->
    let connection : Runtime.For_testing.connection = {
      observe = (fun ~binding:_ ~sources:_ -> incr worker.observations; Ok { rows = []; coverage = [] });
      exported_tools = (fun () -> []);
      call_exported_tool = (fun ~on_result:_ ~authorize:_ ~principal:_ ~name:_ ~arguments:_ ->
        Error (Lane_addon_call_context.Transport_error "no exported tools"));
      action_schema = (fun () -> None); act = (fun ~arguments:_ -> Error "read-only");
      stop = (fun () -> before_stop (); Ok (Lane_addon_lifecycle.Released {engine=Lane_addon_lifecycle.Docker_engine "fixture-engine";container_id=Some instance_id}));
      resource=Lane_addon_lifecycle.Container_resource instance_id;browser=None;host=Some (port ?await_change ?before_listing worker) } in
    ignore (on_authority (Lane_addon_lifecycle.Container_authority {runtime=Lane_addon_types.Docker;engine=Lane_addon_lifecycle.Docker_engine "fixture-engine"}));
    on_created connection; Ok connection);
  package_ready = (fun ~package:_ -> Ok ());
  acquire = (fun ~access:_ ~store:_ ~package:_ ~resolve_machine_output:_ ~resolve_lane_output:_ ~binding:_ -> Ok (`List []));
  recover_stop = (fun ~state_owner:_ ~instance_id:_ ~authority:_ ~resource:_ ->
    Ok (Lane_addon_lifecycle.Released {engine=Lane_addon_lifecycle.Docker_engine "fixture-engine";container_id=None}));
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

let with_installation ?await_change ?before_listing ?before_stop ?(make_runner = runner) ?(listing = []) ?(mode = Answer (`Assoc [ "question", `String "Q?" ])) ?(consume = true) f =
  let root = Filename.temp_dir "lane-host-cycle-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let config_root = Filename.concat root ".masc/config" in
    let directory = Filename.concat config_root "lane-addons" in
    write (Filename.concat root ".masc/package.toml") manifest;
    write (Filename.concat root ".masc/schemas/author.json") author_schema;
    write (Filename.concat directory "quiz.toml") declaration;
    with_env "MASC_CONFIG_DIR" config_root (fun () ->
      with_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" "true" (fun () ->
        Eio_main.run (fun env ->
          Fs_compat.set_fs (Eio.Stdenv.fs env);
          let clock = Eio.Stdenv.clock env in
          Eio.Time.with_timeout_exn clock 15. (fun () -> Eio.Switch.run (fun sw ->
            Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env) ~clock
              ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
                Runtime.For_testing.reset ();
                let worker = { listing = ref listing; delivered = ref []; consume = ref consume; observations = ref 0 } in
                let state = { mode = ref mode; resolutions = ref 0 } in
                Runtime.register_exact_runner (make_runner state);
                let config = Workspace.default_config root in
                Runtime.For_testing.with_backend (backend ?await_change ?before_listing ?before_stop worker) (fun () ->
                  ignore (Runtime.reconcile_configuration ~config ~directory |> unwrap);
                  f clock config worker state;
                  let source = Filename.concat directory "quiz.toml" in
                  if Sys.file_exists source then Sys.remove source;
                  ignore (Runtime.reconcile_configuration ~config ~directory |> unwrap);
                  await clock (fun () -> host_requests config = `Null)))))))))

let delivered_status arguments = text "status" (member "result" arguments)

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
  with_installation ~await_change ~before_listing (fun clock config worker state ->
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
    check int "a stale listing cannot deliver an answer" 0 (List.length !(worker.delivered)))

let test_model_events_admit_and_withdraw_an_exact_scope () =
  let revision=ref 0 and ids=ref [] and changed=Eio.Condition.create () in
  let availability ()={Lane_addon_host_request.revision=string_of_int !revision;request_ids= !ids} in
  let await_change ~after=Eio.Condition.loop_no_mutex changed (fun () ->
    let state=availability () in if after=Some state.revision then None else Some (Ok state)) in
  let cancelled, cancel=Eio.Promise.create () in
  let entered, enter=Eio.Promise.create () in
  let make_runner state ~lane_key:_ ~schema:_ (request:Exact.request) =
    incr state.resolutions;
    if request.request_id="withdraw" then Ok (fun ~validate:_ ->
      Fun.protect ~finally:(fun () -> Eio.Promise.resolve cancel ()) (fun () ->
        Eio.Promise.resolve enter ();
        Eio.Fiber.await_cancel ()))
    else runner {state with resolutions=ref 0} ~lane_key:"fixture" ~schema:(`Assoc []) request in
  with_installation ~await_change ~make_runner (fun clock config worker state ->
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
  let make_runner state ~lane_key:_ ~schema:_ _ =
    incr state.resolutions;
    Ok (fun ~validate:_ ->
      Fun.protect ~finally:(fun () -> Eio.Promise.resolve finish ()) (fun () ->
        Eio.Promise.resolve enter ();
        (* Only retirement can end this provider call. *)
        Eio.Promise.await (fst (Eio.Promise.create ()));
        Exact.Call_refused (Exact.Provider_unavailable {detail="not reached"}))) in
  let before_stop () =
    Eio.Promise.await finished;
    Eio.Promise.resolve clean ();
    Eio.Promise.await released in
  with_installation ~make_runner ~before_stop ~listing:[exact "retiring-1";exact "retiring-2"]
    (fun _clock config worker state ->
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
      ignore (Eio.Promise.await detached |> unwrap))

let test_a_started_worker_gets_its_final_result_once () =
  with_installation ~listing:[ exact "r1" ] (fun clock config worker state ->
    await clock (fun () -> cycles config >= 1);
    (match !(worker.delivered) with
     | [ arguments ] ->
       check string "for the listed request" "r1" (text "request_id" arguments);
       check string "the final result" "answered" (delivered_status arguments)
     | delivered -> failf "expected one delivery, got %d" (List.length delivered));
    check int "the runner was asked once" 1 !(state.resolutions);
    check bool "the cycle settled" true (member "issue" (host_requests config) = `Null);
    await clock (fun () -> !(worker.observations) >= 1))

let test_a_request_that_is_not_final_waits_for_the_next_event () =
  with_installation ~listing:[ exact "r2" ] ~mode:Off (fun clock config worker state ->
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
    let snapshot = F.resolver_snapshot ~source:"host-cycle" [ { F.id = "only"; base_url = "http://127.0.0.1:9" } ] in
    ignore (F.publish_registry ~lane_id:"quiz/author" ~slot_ids:[ "only" ] snapshot : Runtime_exact_output_registry.t);
    await clock (fun () -> List.length !(worker.delivered) = 1);
    check int "the lane change asked again" 2 !(state.resolutions))

let test_a_request_listed_again_after_delivery_ends_the_cycle () =
  with_installation ~listing:[ exact "r3" ] ~consume:false (fun clock config worker _ ->
    await clock (fun () -> cycles config >= 1);
    check int "delivered once" 1 (List.length !(worker.delivered));
    match member "issue" (host_requests config) with
    | `Assoc _ as issue ->
      check string "the instance shows it" "relisted_delivered_request" (text "kind" issue);
      check string "for that request" "r3" (text "request_id" issue)
    | _ -> fail "a relisted delivered request must end the cycle with an issue")

let test_a_result_larger_than_the_frame_is_delivered_as_its_size () =
  let long = `Assoc [ "question", `String (String.make 5000 'q') ] in
  with_installation ~listing:[ exact "r4" ] ~mode:(Answer long) (fun clock config worker _ ->
    await clock (fun () -> cycles config >= 1);
    match !(worker.delivered) with
    | [ arguments ] ->
      check string "the result does not fit" "result_exceeds_frame" (delivered_status arguments);
      check bool "and names its size" true
        (match member "bytes" (member "result" arguments) with `Int bytes -> bytes > 4096 | _ -> false)
    | delivered -> failf "expected one delivery, got %d" (List.length delivered))

let test_a_listing_with_an_unknown_kind_is_refused_whole () =
  let ask = `Assoc [ "kind", `String "ask"; "request_id", `String "q1" ] in
  with_installation ~listing:[ exact "r5"; ask ] (fun clock config worker state ->
    await clock (fun () -> cycles config >= 1);
    check int "nothing was run" 0 !(state.resolutions);
    check int "nothing was delivered" 0 (List.length !(worker.delivered));
    match member "issue" (host_requests config) with
    | `Assoc _ as issue -> check string "the instance shows it" "listing_refused" (text "kind" issue)
    | _ -> fail "an unknown request kind must refuse the listing")

let () =
  Mirage_crypto_rng_unix.use_default ();
  run "lane add-on host request cycle"
    [ ( "cycle"
      , [ test_case "a started worker gets its final result once" `Quick test_a_started_worker_gets_its_final_result_once
        ; test_case "model events admit and withdraw one exact scope" `Quick test_model_events_admit_and_withdraw_an_exact_scope
        ; test_case "withdrawal event can precede a stale listing" `Quick test_withdrawal_event_before_stale_listing
        ; test_case "retirement cancels exact before worker cleanup finishes" `Quick test_retirement_cancels_exact_before_worker_cleanup_finishes
        ; test_case "a request that is not final waits for the next event" `Quick
            test_a_request_that_is_not_final_waits_for_the_next_event
        ; test_case "a request listed again after delivery ends the cycle" `Quick
            test_a_request_listed_again_after_delivery_ends_the_cycle
        ; test_case "a result larger than the frame is delivered as its size" `Quick
            test_a_result_larger_than_the_frame_is_delivered_as_its_size
        ; test_case "a listing with an unknown kind is refused whole" `Quick
            test_a_listing_with_an_unknown_kind_is_refused_whole ] ) ]
