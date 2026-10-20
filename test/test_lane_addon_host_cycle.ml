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
  on_deliver : (Yojson.Safe.t -> unit) ref;  (** What the package does with a delivered result. *)
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

let port worker : Runtime.For_testing.host_port = {
  list_requests = (fun () -> Ok (`Assoc [ "requests", `List !(worker.listing) ]));
  deliver = (fun ~arguments ->
    worker.delivered := arguments :: !(worker.delivered);
    let request_id = text "request_id" arguments in
    if !(worker.consume) then
      worker.listing := List.filter (fun request -> text "request_id" request <> request_id) !(worker.listing);
    !(worker.on_deliver) arguments;
    Ok (`Assoc [ "accepted", `Bool !(worker.consume) ]));
}

let backend worker : Runtime.For_testing.backend = {
  start = (fun ~sw:_ ~state_owner:_ ~instance_id ~package:_ ~binding:_ ~on_engine ~is_live_instance:_ ~on_created ->
    let connection : Runtime.For_testing.connection = {
      observe = (fun ~binding:_ ~sources:_ -> incr worker.observations; Ok { rows = []; coverage = [] });
      exported_tools = (fun () -> []);
      call_exported_tool = (fun ~on_result:_ ~authorize:_ ~principal:_ ~name:_ ~arguments:_ ->
        Error (Lane_addon_call_context.Transport_error "no exported tools"));
      action_schema = (fun () -> None); act = (fun ~arguments:_ -> Error "read-only");
      stop = (fun () -> Ok ()); container_id = instance_id; host = Some (port worker) } in
    ignore (on_engine (Lane_addon_lifecycle.Docker_engine "fixture-engine"));
    on_created connection; Ok connection);
  image_ready = (fun ~package:_ -> Ok ());
  acquire = (fun ~access:_ ~store:_ ~package:_ ~resolve_machine_output:_ ~resolve_lane_output:_ ~binding:_ -> Ok (`List []));
  recover_stop = (fun ~runtime:_ ~state_owner:_ ~instance_id:_ ~engine:_ ~container_id:_ -> Ok ());
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

let with_installation ?(declaration = declaration) ?(listing = []) ?(mode = Answer (`Assoc [ "question", `String "Q?" ])) ?(consume = true) f =
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
                Runtime.register_exact_runner (runner state);
                let config = Workspace.default_config root in
                Runtime.For_testing.with_backend (backend worker) (fun () ->
                  ignore (Runtime.reconcile_configuration ~config ~directory |> unwrap);
                  f clock config worker state root;
                  Sys.remove (Filename.concat directory "quiz.toml");
                  ignore (Runtime.reconcile_configuration ~config ~directory |> unwrap);
                  await clock (fun () -> host_requests config = `Null))))))))))

(* Event 4. The registry is process-wide, so each call names a new slot: a
   publication that changes nothing about the lane wakes no one. *)
let publications = ref 0
let publish_lane_change () =
  incr publications;
  let slot = Printf.sprintf "slot-%d" !publications in
  let snapshot = F.resolver_snapshot ~source:"host-cycle" [ { F.id = slot; base_url = "http://127.0.0.1:9" } ] in
  ignore (F.publish_registry ~lane_id:"quiz/author" ~slot_ids:[ slot ] snapshot : Runtime_exact_output_registry.t)

let delivered_status arguments = text "status" (member "result" arguments)

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

let read ?after id source_id =
  `Assoc ([ "kind", `String "read_records"; "request_id", `String id; "source_id", `String source_id ]
          @ match after with None -> [] | Some cursor -> [ "after", `String cursor ])

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

let test_an_ungranted_source_or_a_foreign_cursor_is_not_allowed () =
  with_installation ~declaration:board_granted (fun clock _config worker _ _root ->
    worker.listing := [ read "n1" "wiki"; read ~after:"not-a-cursor" "n2" "board" ];
    publish_lane_change ();
    await clock (fun () -> List.length !(worker.delivered) >= 2);
    check string "an ungranted source" "not_allowed" (text "status" (result_of "n1" worker));
    check string "a cursor this host did not give" "not_allowed" (text "status" (result_of "n2" worker)))

let () =
  Mirage_crypto_rng_unix.use_default ();
  run "lane add-on host request cycle"
    [ ( "cycle"
      , [ test_case "a started worker gets its final result once" `Quick test_a_started_worker_gets_its_final_result_once
        ; test_case "a request that is not final waits for the next event" `Quick
            test_a_request_that_is_not_final_waits_for_the_next_event
        ; test_case "a request listed again after delivery ends the cycle" `Quick
            test_a_request_listed_again_after_delivery_ends_the_cycle
        ; test_case "a result larger than the frame is delivered as its size" `Quick
            test_a_result_larger_than_the_frame_is_delivered_as_its_size
        ; test_case "a listing with an unknown kind is refused whole" `Quick
            test_a_listing_with_an_unknown_kind_is_refused_whole ] )
    ; ( "grants"
      , [ test_case "an operator declaration attaches with its grants" `Quick
            test_an_operator_declaration_attaches_with_its_grants
        ; test_case "a manual attach with grants is refused" `Quick test_a_manual_attach_with_grants_is_refused ] )
    ; ( "board reads"
      , [ test_case "a granted board is read oldest first and retained" `Quick
            test_a_granted_board_is_read_oldest_first_and_retained
        ; test_case "a cursor reads only what came after" `Quick test_a_cursor_reads_only_what_came_after
        ; test_case "a page holds what fits the frame" `Quick test_a_page_holds_what_fits_the_frame
        ; test_case "an ungranted source or a foreign cursor is not allowed" `Quick
            test_an_ungranted_source_or_a_foreign_cursor_is_not_allowed ] ) ]
