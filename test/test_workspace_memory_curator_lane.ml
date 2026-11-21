open Alcotest
open Masc
module Curator = Server_workspace_memory_curator
module Ledger = Workspace_memory_ledger
module Briefing = Workspace_memory_briefing
module Request = Workspace_memory_request
module Log_store = Workspace_memory_log
module Current = Keeper_memory_os_current
module Types = Keeper_memory_os_types
module F = Exact_output_fixture

let get = function Ok value -> value | Error detail -> fail detail
let member = Yojson.Safe.Util.member
let () = Mirage_crypto_rng_unix.use_default ()

let commit_facts ~base_path ~keeper_id claims =
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let now = 1_700_000_000. in
  let expected_revision =
    match get (Current.read_for_keepers_dir ~keepers_dir ~keeper_id) with
    | None -> None
    | Some current -> Some current.revision
  in
  let facts =
    List.map
      (fun claim ->
         Types.observed
           ~claim
           ~category:Types.Fact
           ~now
           ~origin:{ kind = Types.Authored; trace_id = "curator-test-fixture" })
      claims
  in
  Current.replace
    ~keepers_dir
    ~keeper_id
    ~expected_revision
    ~now
    ~source:{ kind = Current.Librarian; trace_id = "curator-test-fixture" }
    ~facts
    ()
  |> get
  |> ignore
;;

let await_owner clock base_path condition =
  Eio.Time.with_timeout_exn clock F.fixture_wait_seconds (fun () ->
    let rec loop () =
      if condition () then () else (Eio.Fiber.yield (); loop ())
    in
    loop ())
;;

let briefing_observation base_path =
  let directory = Ledger.directory ~base_path in
  let ledger = get (Ledger.load ~base_path) in
  let state = get (Briefing.load ~directory) in
  let template = (Prompt_registry.resolve_prompt Prompt_names.workspace_memory_briefing).effective in
  Briefing.observe ~sources:(Ledger.briefing_sources ledger) ~contract:(Briefing.contract ~template) state
;;

let ready_summary base_path =
  match briefing_observation base_path with
  | Briefing.Current _ -> true
  | Missing | Stale _ -> false
;;

let curator_lane_id = Standalone_lane.to_id Standalone_lane.Workspace_memory_curator

let publish_lane ?(lane_id = curator_lane_id) base_path urls =
  let slots =
    List.mapi (fun i url -> { F.id = "candidate-" ^ string_of_int i; base_url = url }) urls
  in
  ignore
    (F.publish_registry
       ~lane_id
       ~slot_ids:(List.map (fun (s : F.target_fixture) -> s.id) slots)
       (F.resolver_snapshot ~source:base_path slots))
;;

let with_fixture f =
  let base_path = Filename.temp_dir "curator-standalone-owner-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) (fun () ->
      Masc_test_deps.with_process_env Env_config_core.config_dir_env_key
        (Some (Filename.concat base_path ".masc/config"))
        (fun () ->
          Eio_main.run (fun env ->
            Eio.Switch.run (fun sw ->
              Eio_guard.enable ();
              Eio.Switch.on_release sw Eio_guard.disable;
              Fs_compat.set_fs (Eio.Stdenv.fs env);
              Masc_test_deps.init_eio_clock env;
              Process_eio.init
                ~cwd_default:(Eio.Stdenv.cwd env)
                ~proc_mgr:(Eio.Stdenv.process_mgr env)
                ~clock:(Eio.Stdenv.clock env);
              Fun.protect
                ~finally:(fun () ->
                  Mcp_subscriptions.reset_for_test ();
                  Process_eio.reset_for_testing ();
                  Fs_compat.clear_fs ())
                (fun () ->
                  Eio_context.with_test_env
                    ~sw
                    ~net:(Eio.Stdenv.net env)
                    ~clock:(Eio.Stdenv.clock env)
                    ~mono_clock:(Eio.Stdenv.mono_clock env)
                    (fun () ->
                      let prompts_dir =
                        if Sys.file_exists "config/prompts" then
                          "config/prompts"
                        else
                          "../config/prompts"
                      in
                      Prompt_registry.set_markdown_dir prompts_dir;
                      Prompt_defaults.init ();
                      Prompt_registry.clear_prompt_override Prompt_names.workspace_memory_curator;
                      Prompt_registry.clear_prompt_override Prompt_names.workspace_memory_briefing;
                      let config = Workspace.default_config base_path in
                      f ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) ~base_path ~config)))))))
;;

let user_content body =
  let messages = Yojson.Safe.from_string body |> member "messages" |> Yojson.Safe.Util.to_list in
  List.find_map
    (fun msg ->
       match member "role" msg, member "content" msg with
       | `String "user", `String content -> Some content
       | _ -> None)
    messages
  |> Option.value ~default:""
;;

let is_briefing_request user_content =
  String_util.contains_substring user_content "## Shared context input"
;;

(* The JSON input of a classification request. *)
let classification_input user_content =
  let after_heading =
    match String.index_opt user_content '{' with
    | Some idx -> String.sub user_content idx (String.length user_content - idx)
    | None -> user_content
  in
  let trimmed = String.trim after_heading in
  (* strip schema instruction suffix if appended *)
  let line_end = Option.value (String.index_opt trimmed '\n') ~default:(String.length trimmed) in
  Yojson.Safe.from_string (String.sub trimmed 0 line_end)
;;

let classify_or_briefing_response ?(bad = false) ?(shared_claim = false) body =
  let user_content = user_content body in
  if is_briefing_request user_content then
    `Assoc
      [ ( "briefing"
        , `String (if bad then "   " else "Workspace uses dune with canonical memory tracking.") )
      ]
  else if bad then
    `Assoc [ "decisions", `List [] ]
  else
    let json = classification_input user_content in
    let facts_tbl = Hashtbl.create 16 in
    (match member "facts" json with
     | `List items ->
       List.iter
         (fun item ->
            match member "id" item, member "claim" item with
            | `String id, `String claim -> Hashtbl.replace facts_tbl id claim
            | _ -> ())
         items
     | _ -> ());
    let new_fact_ids =
      match member "new_facts" json with
      | `List items ->
        List.filter_map
          (fun item ->
             match member "id" item with
             | `String id -> Some id
             | _ -> None)
          items
      | _ -> []
    in
    let decisions =
      List.map
        (fun id ->
           let claim = Option.value ~default:id (Hashtbl.find_opt facts_tbl id) in
           let value = if shared_claim then "Build uses dune" else claim in
           `Assoc [ "fact_id", `String id; "kind", `String "create_claim"; "value", `String value ])
        new_fact_ids
    in
    `Assoc [ "decisions", `List decisions ]
;;

let test_in_process_pipeline_and_mcp_resources () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let received_uris = ref [] in
    let token =
      Mcp_subscriptions.register
        ~subscription_id:(`Int 1)
        ~filter:
          { Mcp_transport_protocol.tools_list_changed = false
          ; prompts_list_changed = false
          ; resources_list_changed = false
          ; resource_subscriptions =
              [ Mcp_server_eio_resource.world_memory_claims_uri
              ; Mcp_server_eio_resource.world_memory_log_uri
              ]
          }
        ~send:(fun msg ->
          let uri = member "params" msg |> member "uri" |> Yojson.Safe.Util.to_string in
          received_uris := uri :: !received_uris;
          true)
    in
    Fun.protect ~finally:(fun () -> Mcp_subscriptions.unregister token) (fun () ->
      let bad_server =
        F.start_server ~sw ~net ~clock
          (F.Reply_with (fun _ body -> `OK, F.openai_response (classify_or_briefing_response ~bad:true body)))
      in
      let good_server =
        F.start_server ~sw ~net ~clock
          (F.Reply_with (fun _ body -> `OK, F.openai_response (classify_or_briefing_response ~bad:false body)))
      in
      publish_lane base_path [ bad_server.base_url; good_server.base_url ];
      commit_facts ~base_path ~keeper_id:"writer" [ "Dune compiles masc cleanly" ];
      Curator.start ~sw ~config;
      Fun.protect ~finally:(fun () -> Curator.For_testing.stop ~base_path) (fun () ->
        await_owner clock base_path (fun () ->
          Curator.For_testing.is_idle ~base_path && ready_summary base_path);
        check bool "invalid output failed over to good candidate" true (F.post_count good_server >= 2);
        let ledger = get (Ledger.load ~base_path) in
        check int "one classified claim in ledger" 1 (List.length (Ledger.claims ledger));
        let log_report =
          Log_store.recover_file ~path:(Log_store.log_path ~base_path)
          |> Result.map_error Log_store.error_to_string
          |> get
        in
        check int "no incomplete log batches" 0 (List.length log_report.incomplete_batches);
        check bool "2-phase log committed entries" true (List.length log_report.committed_changes >= 2);
        check bool "MCP notified world-memory/claims" true
          (List.mem Mcp_server_eio_resource.world_memory_claims_uri !received_uris);
        check bool "MCP notified world-memory/log" true
          (List.mem Mcp_server_eio_resource.world_memory_log_uri !received_uris);
        (* Verify MCP 2026-07-28 resource reads *)
        let state = Mcp_server.For_testing.create_state ~base_path in
        let read_resource uri =
          let resp =
            Mcp_server_eio_resource.handle_read_resource_eio
              state
              (`Int 1)
              (Some (`Assoc [ "uri", `String uri ]))
          in
          let text =
            member "result" resp |> member "contents" |> Yojson.Safe.Util.index 0 |> member "text"
            |> Yojson.Safe.Util.to_string
          in
          Yojson.Safe.from_string text
        in
        let claims_json = read_resource Mcp_server_eio_resource.world_memory_claims_uri in
        check string "claims resource status available" "available"
          (member "status" claims_json |> Yojson.Safe.Util.to_string);
        check int "claims resource shows 1 claim" 1
          (member "claims" claims_json |> Yojson.Safe.Util.to_list |> List.length);
        let log_json = read_resource Mcp_server_eio_resource.world_memory_log_uri in
        check bool "log resource shows committed_changes" true
          (member "committed_changes" log_json |> Yojson.Safe.Util.to_list <> []);
        let page1 =
          read_resource (Mcp_server_eio_resource.world_memory_log_uri ^ "?since_seq=0&limit=1")
        in
        let p1_changes = member "committed_changes" page1 |> Yojson.Safe.Util.to_list in
        check int "world-memory/log limit=1 returns 1 change" 1 (List.length p1_changes);
        check bool "world-memory/log page1 reports has_more" true
          (member "has_more" page1 |> Yojson.Safe.Util.to_bool);
        let cursor1 = member "next_since_seq" page1 |> Yojson.Safe.Util.to_int in
        check bool "next_since_seq advances" true (cursor1 > 0);
        let page2 =
          read_resource
            (Printf.sprintf "%s?since_seq=%d&limit=1"
               Mcp_server_eio_resource.world_memory_log_uri cursor1)
        in
        let p2_changes = member "committed_changes" page2 |> Yojson.Safe.Util.to_list in
        check int "world-memory/log page2 returns next change" 1 (List.length p2_changes);
        let p2_seq = List.hd p2_changes |> member "seq" |> Yojson.Safe.Util.to_int in
        check bool "page2 advances strictly past cursor1" true (p2_seq > cursor1))))
;;

(* --- Classification scenes (RFC curator-narrows-a-refused-batch-and-sets-a-
   refused-fact-aside §8.2). Each is judged by the ledger and the requests the
   fake provider received. --- *)

(* The claims a classification request selected; [] for a briefing request. *)
let selected_claims body =
  let user_content = user_content body in
  if is_briefing_request user_content then []
  else (
    let json = classification_input user_content in
    let claims =
      match member "facts" json with
      | `List items ->
        List.filter_map
          (fun item ->
             match member "id" item, member "claim" item with
             | `String id, `String claim -> Some (id, claim)
             | _ -> None)
          items
      | _ -> []
    in
    match member "new_facts" json with
    | `List items ->
      List.filter_map
        (fun item ->
           match member "id" item with
           | `String id -> List.assoc_opt id claims
           | _ -> None)
        items
    | _ -> [])
;;

let answered body = `OK, F.openai_response (classify_or_briefing_response body)
let bad_request = `Bad_request, {|{"error":{"message":"bad request","type":"invalid_request_error"}}|}
let overloaded = `Service_unavailable, {|{"error":{"message":"overloaded","type":"server_error"}}|}

let too_large =
  ( `Request_entity_too_large
  , {|{"error":{"message":"payload too large","type":"invalid_request_error"}}|} )
;;

let not_json =
  ( `OK
  , {|{"id":"curator-not-json","model":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":"not json"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
  )
;;

(* A provider for the scenes. [reply] answers a classification request from
   the claims it selected, sorted; a briefing request is answered. The second
   value lists the classification requests received, oldest first, each by its
   sorted claims. *)
let scene_server ~sw ~net ~clock reply =
  let asked = Atomic.make [] in
  let rec record claims =
    let seen = Atomic.get asked in
    if not (Atomic.compare_and_set asked seen (claims :: seen)) then record claims
  in
  let server =
    F.start_server ~sw ~net ~clock
      (F.Reply_with (fun _ body ->
         match List.sort String.compare (selected_claims body) with
         | [] -> answered body
         | claims ->
           record claims;
           reply claims body))
  in
  server, fun () -> List.rev (Atomic.get asked)
;;

let snapshot base_path =
  match Curator.For_testing.snapshot ~base_path with
  | Some snapshot -> snapshot
  | None -> fail "curator owner missing"
;;

let claim_count base_path = List.length (Ledger.claims (get (Ledger.load ~base_path)))
let set_aside base_path = List.length (snapshot base_path).set_aside

let classification_end base_path =
  match (snapshot base_path).classification with
  | None -> "none"
  | Some Curator.Nothing_pending -> "nothing pending"
  | Some (Curator.Not_asked _) -> "not asked"
  | Some Curator.Drained -> "drained"
  | Some Curator.Lane_silent -> "lane silent"
  | Some (Curator.Host_failed (_, detail)) -> "host failed: " ^ detail
;;

(* Start the owner on the facts already committed, wait for its passes to
   end, then run [body]. *)
let run_scene ~sw ~clock ~base_path ~config body =
  Curator.start ~sw ~config;
  Fun.protect ~finally:(fun () -> Curator.For_testing.stop ~base_path) (fun () ->
    await_owner clock base_path (fun () -> Curator.For_testing.is_idle ~base_path);
    body ())
;;

(* Run [step] and wait for the passes it wakes to end. *)
let after_pass ~clock base_path step =
  Eio.Time.with_timeout_exn clock F.fixture_wait_seconds (fun () ->
    let checkpoint =
      match Curator.For_testing.await_idle ~base_path () with
      | Curator.For_testing.Owner_idle checkpoint -> checkpoint
      | Owner_stopped | Owner_missing -> fail "curator should be idle"
    in
    step ();
    match Curator.For_testing.await_idle ~after:checkpoint ~base_path () with
    | Curator.For_testing.Owner_idle _ -> ()
    | Owner_stopped | Owner_missing -> fail "curator should end the pass")
;;

let tick ~clock base_path =
  after_pass ~clock base_path (fun () -> Curator.retry_pending_observations ~base_path)
;;

let count_of claims asked = List.length (List.filter (( = ) claims) asked)

(* A size refusal narrows the batch, and the size it came down to is kept:
   the next commit's facts go one at a time. *)
let test_capacity_refusal_bisects_batch () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let server, asked =
      scene_server ~sw ~net ~clock (fun claims body ->
        if List.length claims > 1 then too_large else answered body)
    in
    publish_lane base_path [ server.base_url ];
    commit_facts ~base_path ~keeper_id:"writer" [ "Fact one"; "Fact two"; "Fact three" ];
    run_scene ~sw ~clock ~base_path ~config (fun () ->
      check int "all 3 facts survived capacity bisection" 3 (claim_count base_path);
      after_pass ~clock base_path (fun () ->
        commit_facts ~base_path ~keeper_id:"reviewer" [ "Fact four"; "Fact five"; "Fact six" ]);
      check int "the next facts are classified" 6 (claim_count base_path);
      check int "no batch over the kept size is sent again" 1
        (List.length (List.filter (fun claims -> List.length claims > 1) (asked ())))))
;;

(* A 400 narrows the batch and its halves are answered. A refusal with no
   size keeps no size: the next commit's facts go as one batch. *)
let test_unsized_refusal_keeps_no_size () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let first = Atomic.make true in
    let server, asked =
      scene_server ~sw ~net ~clock (fun _ body ->
        if Atomic.exchange first false then bad_request else answered body)
    in
    publish_lane base_path [ server.base_url ];
    commit_facts ~base_path ~keeper_id:"writer" [ "Fact one"; "Fact two"; "Fact three" ];
    run_scene ~sw ~clock ~base_path ~config (fun () ->
      after_pass ~clock base_path (fun () ->
        commit_facts ~base_path ~keeper_id:"reviewer" [ "Fact four"; "Fact five"; "Fact six" ]);
      check (list int) "narrowed once, then one batch" [ 3; 1; 2; 3 ]
        (List.map List.length (asked ()));
      check int "every fact is classified" 6 (claim_count base_path)))
;;

(* A 400 on every request that holds one Keeper's fact. The other facts are
   classified in the same pass; that fact is asked alone once and set aside,
   and the tick has nothing to wake for. *)
let test_refused_fact_is_set_aside () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let server, asked =
      scene_server ~sw ~net ~clock (fun claims body ->
        if List.mem "Poison fact" claims then bad_request else answered body)
    in
    publish_lane base_path [ server.base_url ];
    commit_facts ~base_path ~keeper_id:"first" [ "Fact one" ];
    commit_facts ~base_path ~keeper_id:"second" [ "Fact two" ];
    commit_facts ~base_path ~keeper_id:"third" [ "Poison fact" ];
    run_scene ~sw ~clock ~base_path ~config (fun () ->
      check int "the other facts are classified" 2 (claim_count base_path);
      check int "the refused fact is set aside" 1 (set_aside base_path);
      check int "the refused fact is asked alone once" 1 (count_of [ "Poison fact" ] (asked ()));
      check string "the pass drained" "drained" (classification_end base_path);
      check bool "the tick has nothing to wake for" false (snapshot base_path).observation_retry))
;;

(* A 400 on every request. With one slot, N facts take 2N - 1 requests and
   are all set aside. Another Keeper's commit asks only its own fact, and an
   ask to start over asks every fact again. *)
let test_every_request_refused () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let server, asked = scene_server ~sw ~net ~clock (fun _ _ -> bad_request) in
    publish_lane base_path [ server.base_url ];
    commit_facts ~base_path ~keeper_id:"writer" [ "Fact one"; "Fact two"; "Fact three" ];
    run_scene ~sw ~clock ~base_path ~config (fun () ->
      check int "2N - 1 requests for three facts" 5 (List.length (asked ()));
      check int "every fact is set aside" 3 (set_aside base_path);
      check int "nothing is classified" 0 (claim_count base_path);
      check bool "the tick has nothing to wake for" false (snapshot base_path).observation_retry;
      after_pass ~clock base_path (fun () ->
        commit_facts ~base_path ~keeper_id:"reviewer" [ "Fact four" ]);
      check (list (list string)) "a commit asks only the new fact" [ [ "Fact four" ] ]
        (List.filteri (fun index _ -> index >= 5) (asked ()));
      check int "the new fact is set aside too" 4 (set_aside base_path);
      after_pass ~clock base_path (fun () -> ignore (Curator.request ~base_path));
      check int "starting over asks the four facts again in 2N - 1" 13 (List.length (asked ()));
      check int "they are set aside again" 4 (set_aside base_path)))
;;

(* A 503 on every request, which says nothing about the request. Nothing is
   set aside. Each tick asks the same batch once more; a commit asks only the
   new fact. *)
let test_silent_lane_waits_for_the_tick () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let server, asked = scene_server ~sw ~net ~clock (fun _ _ -> overloaded) in
    publish_lane base_path [ server.base_url ];
    commit_facts ~base_path ~keeper_id:"writer" [ "Fact one"; "Fact two" ];
    run_scene ~sw ~clock ~base_path ~config (fun () ->
      check string "the lane said nothing" "lane silent" (classification_end base_path);
      check bool "the tick wakes the owner" true (snapshot base_path).observation_retry;
      tick ~clock base_path;
      after_pass ~clock base_path (fun () ->
        commit_facts ~base_path ~keeper_id:"reviewer" [ "Fact three" ]);
      check (list (list string)) "the batch once a pass, then the new fact alone"
        [ [ "Fact one"; "Fact two" ]; [ "Fact one"; "Fact two" ]; [ "Fact three" ] ]
        (asked ());
      check int "nothing is set aside" 0 (set_aside base_path)))
;;

(* A 400 narrows the first batch and both halves meet a 503. The tick asks
   each half as it is; the first batch is not asked again. *)
let test_narrowed_halves_wait_as_they_are () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let server, asked =
      scene_server ~sw ~net ~clock (fun claims _ ->
        if List.length claims = 4 then bad_request else overloaded)
    in
    publish_lane base_path [ server.base_url ];
    commit_facts ~base_path ~keeper_id:"writer"
      [ "Fact one"; "Fact two"; "Fact three"; "Fact four" ];
    run_scene ~sw ~clock ~base_path ~config (fun () ->
      tick ~clock base_path;
      check (list int) "the batch, its halves, then the halves again" [ 4; 2; 2; 2; 2 ]
        (List.map List.length (asked ()));
      check int "nothing is set aside" 0 (set_aside base_path)))
;;

(* Two slots: the first refuses with a 400, the second meets a 503 and later
   answers. The fact is not set aside; the tick asks only the second slot, and
   its answer classifies the fact. *)
let test_fact_waits_for_the_slot_that_did_not_refuse () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let busy = Atomic.make true in
    let refusing, refused = scene_server ~sw ~net ~clock (fun _ _ -> bad_request) in
    let waiting, waited =
      scene_server ~sw ~net ~clock (fun _ body ->
        if Atomic.get busy then overloaded else answered body)
    in
    publish_lane base_path [ refusing.base_url; waiting.base_url ];
    commit_facts ~base_path ~keeper_id:"writer" [ "Fact one" ];
    run_scene ~sw ~clock ~base_path ~config (fun () ->
      check int "not set aside" 0 (set_aside base_path);
      tick ~clock base_path;
      check int "the refusing slot is asked once" 1 (List.length (refused ()));
      check int "the other slot is asked again" 2 (List.length (waited ()));
      Atomic.set busy false;
      tick ~clock base_path;
      check int "the refusing slot is still asked once" 1 (List.length (refused ()));
      check int "the answer classifies the fact" 1 (claim_count base_path)))
;;

(* The answer to every request that holds one fact is not JSON. The other
   facts are classified in the same pass. That fact is not set aside, and each
   tick asks it alone once more. *)
let test_unusable_fact_is_asked_on_each_tick () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let server, asked =
      scene_server ~sw ~net ~clock (fun claims body ->
        if List.mem "Garbled fact" claims then not_json else answered body)
    in
    publish_lane base_path [ server.base_url ];
    commit_facts ~base_path ~keeper_id:"writer" [ "Fact one"; "Fact two"; "Garbled fact" ];
    run_scene ~sw ~clock ~base_path ~config (fun () ->
      check int "the other facts are classified" 2 (claim_count base_path);
      check int "not set aside" 0 (set_aside base_path);
      check int "asked alone once" 1 (count_of [ "Garbled fact" ] (asked ()));
      tick ~clock base_path;
      check int "asked alone once more on the tick" 2 (count_of [ "Garbled fact" ] (asked ()))))
;;

(* An answer cut at the slot's output budget. *)
let length_cut_response =
  {|{"id":"curator-output-limit","model":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":"{}"},"finish_reason":"length"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
;;

let test_output_limit_narrows_classification_batch () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let server =
      F.start_server ~sw ~net ~clock
        (F.Reply_with (fun _ body ->
           let payload = classify_or_briefing_response body in
           let decision_count =
             match member "decisions" payload with `List xs -> List.length xs | _ -> 0
           in
           if decision_count > 1 then `OK, length_cut_response
           else `OK, F.openai_response payload))
    in
    publish_lane base_path [ server.base_url ];
    commit_facts ~base_path ~keeper_id:"writer" [ "Fact one"; "Fact two"; "Fact three" ];
    Curator.start ~sw ~config;
    Fun.protect ~finally:(fun () -> Curator.For_testing.stop ~base_path) (fun () ->
      await_owner clock base_path (fun () ->
        Curator.For_testing.is_idle ~base_path
        && List.length (Ledger.claims (get (Ledger.load ~base_path))) = 3
        && ready_summary base_path);
      check int "all 3 facts survived output-limit narrowing" 3
        (List.length (Ledger.claims (get (Ledger.load ~base_path))))))
;;

(* --- Briefing scenes (RFC curator §4.5, §8.2). --- *)

(* How many entries the briefing Keepers read covers. *)
let published_entries base_path =
  match briefing_observation base_path with
  | Briefing.Missing -> 0
  | Briefing.Current summary | Briefing.Stale summary -> List.length summary.source_ids
;;

(* A provider that answers every classification request. [briefing] answers
   each briefing request by its prompt; the second value counts them. *)
let briefing_server ~sw ~net ~clock briefing =
  let asked = Atomic.make 0 in
  let server =
    F.start_server ~sw ~net ~clock
      (F.Reply_with (fun _ body ->
         let content = user_content body in
         if is_briefing_request content then (
           Atomic.incr asked;
           briefing content body)
         else answered body))
  in
  server, fun () -> Atomic.get asked
;;

(* A 400 on every briefing request that holds one Keeper's claim. The
   briefing stands at that claim: the briefing Keepers read stays the last
   complete one, the classification goes on, and a commit asks the briefing
   nothing. An ask to start over asks it once more. *)
let test_refused_briefing_entry_stands () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let server, briefings =
      briefing_server ~sw ~net ~clock (fun content body ->
        if String_util.contains_substring content "Poison fact" then bad_request
        else answered body)
    in
    publish_lane base_path [ server.base_url ];
    commit_facts ~base_path ~keeper_id:"first" [ "Fact one" ];
    run_scene ~sw ~clock ~base_path ~config (fun () ->
      check int "the first briefing covers the first claim" 1 (published_entries base_path);
      after_pass ~clock base_path (fun () ->
        commit_facts ~base_path ~keeper_id:"second" [ "Poison fact" ]);
      check int "the refused claim is asked alone once" 2 (briefings ());
      after_pass ~clock base_path (fun () ->
        commit_facts ~base_path ~keeper_id:"third" [ "Fact three" ]);
      check int "the classification goes on" 3 (claim_count base_path);
      check int "a commit asks the briefing nothing" 2 (briefings ());
      check int "the briefing read is the last complete one" 1 (published_entries base_path);
      check bool "the tick has nothing to wake for" false (snapshot base_path).observation_retry;
      after_pass ~clock base_path (fun () -> ignore (Curator.request ~base_path));
      check int "starting over asks the refused claim once more" 3 (briefings ());
      check int "the briefing read stays" 1 (published_entries base_path)))
;;

(* Every briefing request is cut at the output budget. The briefing does not
   narrow, the pass stands, and nothing waits for the tick. *)
let test_output_limit_briefing_stands_without_narrowing () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let server, briefings =
      briefing_server ~sw ~net ~clock (fun _ _ -> `OK, length_cut_response)
    in
    publish_lane base_path [ server.base_url ];
    commit_facts ~base_path ~keeper_id:"writer" [ "Fact one"; "Fact two"; "Fact three" ];
    run_scene ~sw ~clock ~base_path ~config (fun () ->
      check int "every fact is classified" 3 (claim_count base_path);
      check int "the briefing is asked once, not narrowed" 1 (briefings ());
      check int "no briefing is published" 0 (published_entries base_path);
      check bool "the tick has nothing to wake for" false (snapshot base_path).observation_retry))
;;

(* Two slots: the first refuses the briefing of one claim with a 400, the
   second meets a 503 and later answers. The briefing does not stand; the
   tick asks only the second slot, and its answer publishes the briefing. *)
let test_briefing_waits_for_the_slot_that_did_not_refuse () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let busy = Atomic.make true in
    let refusing, refused = briefing_server ~sw ~net ~clock (fun _ _ -> bad_request) in
    let waiting, waited =
      briefing_server ~sw ~net ~clock (fun _ body ->
        if Atomic.get busy then overloaded else answered body)
    in
    publish_lane base_path [ refusing.base_url; waiting.base_url ];
    commit_facts ~base_path ~keeper_id:"writer" [ "Fact one" ];
    run_scene ~sw ~clock ~base_path ~config (fun () ->
      check bool "the tick wakes the owner" true (snapshot base_path).observation_retry;
      tick ~clock base_path;
      check int "the refusing slot is asked once" 1 (refused ());
      check int "the other slot is asked again" 2 (waited ());
      Atomic.set busy false;
      tick ~clock base_path;
      check int "the refusing slot is still asked once" 1 (refused ());
      check int "the answer publishes the briefing" 1 (published_entries base_path)))
;;

let test_startup_recovery_and_partial_member_survival () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let log_path = Log_store.log_path ~base_path in
    let crashed : Log_store.batch_header =
      { batch_id = "crashed-batch"
      ; author = "curator"
      ; started_at = "2026-10-14T09:00:00Z"
      ; expected_changes = 1
      }
    in
    Log_store.append_record ~path:log_path (Log_store.Prepared crashed)
    |> Result.map_error Log_store.error_to_string
    |> get;
    let server =
      F.start_server ~sw ~net ~clock
        (F.Reply_with (fun _ body ->
           `OK, F.openai_response (classify_or_briefing_response ~shared_claim:true body)))
    in
    publish_lane base_path [ server.base_url ];
    commit_facts ~base_path ~keeper_id:"writer" [ "Build uses dune" ];
    commit_facts ~base_path ~keeper_id:"reviewer" [ "Build uses dune" ];
    Curator.start ~sw ~config;
    Fun.protect ~finally:(fun () -> Curator.For_testing.stop ~base_path) (fun () ->
      await_owner clock base_path (fun () ->
        Curator.For_testing.is_idle ~base_path && ready_summary base_path);
      let log_report =
        Log_store.recover_file ~path:log_path
        |> Result.map_error Log_store.error_to_string
        |> get
      in
      check (list string) "startup aborted crashed incomplete batch" [ "crashed-batch" ]
        log_report.aborted_batches;
      check (list string) "no incomplete batches remain" []
        (List.map (fun (h : Log_store.batch_header) -> h.batch_id) log_report.incomplete_batches);
      let ledger = get (Ledger.load ~base_path) in
      check int "two keepers consolidated into 1 claim" 1 (List.length (Ledger.claims ledger));
      let claim_id = fst (List.hd (Ledger.claims ledger)) in
      check (option int) "claim has 2 supporting keepers" (Some 2)
        (Option.map (fun (p : Ledger.claim_provenance) -> p.support_count)
           (Ledger.claim_provenance ledger ~claim_id));
      (* Drop reviewer's fact -> partial member survival *)
      let checkpoint =
        match Curator.For_testing.await_idle ~base_path () with
        | Curator.For_testing.Owner_idle c -> c
        | Owner_stopped | Owner_missing -> fail "curator should be idle"
      in
      commit_facts ~base_path ~keeper_id:"reviewer" [];
      ignore (Curator.request ~base_path);
      (match Curator.For_testing.await_idle ~after:checkpoint ~base_path () with
       | Curator.For_testing.Owner_idle _ -> ()
       | Owner_stopped | Owner_missing -> fail "curator should finish reconciliation");
      let ledger_after = get (Ledger.load ~base_path) in
      check int "shared claim survives with 1 remaining keeper" 1
        (List.length (Ledger.claims ledger_after));
      check (option int) "support_count shrinks to 1" (Some 1)
        (Option.map (fun (p : Ledger.claim_provenance) -> p.support_count)
           (Ledger.claim_provenance ledger_after ~claim_id))))
;;

let test_transient_retry_and_idle_barrier () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let fail_temporarily = ref true in
    let server =
      F.start_server ~sw ~net ~clock
        (F.Reply_with (fun _ body ->
           if !fail_temporarily then
             `Service_unavailable, "{\"error\":{\"message\":\"overloaded\",\"type\":\"server_error\"}}"
           else `OK, F.openai_response (classify_or_briefing_response body)))
    in
    publish_lane base_path [ server.base_url ];
    commit_facts ~base_path ~keeper_id:"writer" [ "Retry recovers after 503" ];
    Curator.start ~sw ~config;
    Fun.protect ~finally:(fun () -> Curator.For_testing.stop ~base_path) (fun () ->
      await_owner clock base_path (fun () -> Curator.For_testing.is_idle ~base_path);
      let snap =
        match Curator.For_testing.snapshot ~base_path with
        | Some s -> s
        | None -> fail "curator owner missing"
      in
      check bool "transient outage queued observation_retry" true snap.observation_retry;
      fail_temporarily := false;
      Curator.retry_pending_observations ~base_path;
      await_owner clock base_path (fun () ->
        Curator.For_testing.is_idle ~base_path && ready_summary base_path);
      let snap2 =
        match Curator.For_testing.snapshot ~base_path with
        | Some s -> s
        | None -> fail "curator owner missing after retry"
      in
      check bool "completed retry cleared observation_retry" false snap2.observation_retry;
      Curator.For_testing.stop ~base_path;
      check bool "stopped owner returns No_owner on request" true
        (Curator.request ~base_path = Curator.No_owner)))
;;

(* The Librarian's Memory lane is another reader's table (#53982). With only
   that lane declared, the first pass finds no curator lane and ends without a
   request. *)
let test_librarian_memory_lane_starts_no_curator_call () =
  with_fixture (fun ~sw ~net ~clock ~base_path ~config ->
    let requests = ref 0 in
    let server =
      F.start_server ~sw ~net ~clock
        (F.Reply_with (fun _ body ->
           incr requests;
           `OK, F.openai_response (classify_or_briefing_response body)))
    in
    publish_lane ~lane_id:Librarian_memory_lane.lane_id base_path [ server.base_url ];
    commit_facts ~base_path ~keeper_id:"writer" [ "Only the Librarian's Memory lane is declared" ];
    Curator.start ~sw ~config;
    Fun.protect ~finally:(fun () -> Curator.For_testing.stop ~base_path) (fun () ->
      await_owner clock base_path (fun () -> Curator.For_testing.is_idle ~base_path);
      check int "no request reaches the Librarian lane's slot" 0 !requests;
      let snap =
        match Curator.For_testing.snapshot ~base_path with
        | Some s -> s
        | None -> fail "curator owner missing"
      in
      check bool "an undeclared curator lane queues no retry" false snap.observation_retry))
;;

let () =
  run
    "workspace_memory_curator_lane"
    [ ( "standalone"
      , [ test_case
            "in-process curation updates ledger, 2-phase log, briefing, and MCP resources"
            `Quick
            test_in_process_pipeline_and_mcp_resources
        ; test_case
            "a size refusal narrows the batch and the kept size holds the next one"
            `Quick
            test_capacity_refusal_bisects_batch
        ; test_case
            "a refusal with no size narrows the batch and keeps no size"
            `Quick
            test_unsized_refusal_keeps_no_size
        ; test_case
            "a fact refused alone is set aside and the others are classified"
            `Quick
            test_refused_fact_is_set_aside
        ; test_case
            "every request refused takes 2N - 1 requests and starting over asks again"
            `Quick
            test_every_request_refused
        ; test_case
            "a silent lane waits for the tick and a commit asks only the new fact"
            `Quick
            test_silent_lane_waits_for_the_tick
        ; test_case
            "narrowed halves that met a silent lane are asked as they are"
            `Quick
            test_narrowed_halves_wait_as_they_are
        ; test_case
            "a fact waits for the slot that did not refuse it"
            `Quick
            test_fact_waits_for_the_slot_that_did_not_refuse
        ; test_case
            "a fact whose answer is never JSON is asked again on each tick"
            `Quick
            test_unusable_fact_is_asked_on_each_tick
        ; test_case
            "an answer cut at the output budget narrows the classification batch"
            `Quick
            test_output_limit_narrows_classification_batch
        ; test_case
            "a briefing entry every slot refused stands and the last briefing stays"
            `Quick
            test_refused_briefing_entry_stands
        ; test_case
            "a briefing cut at the output budget stands without narrowing"
            `Quick
            test_output_limit_briefing_stands_without_narrowing
        ; test_case
            "a briefing waits for the slot that did not refuse it"
            `Quick
            test_briefing_waits_for_the_slot_that_did_not_refuse
        ; test_case
            "startup log recovery aborts incomplete batches and preserves partial-member survival"
            `Quick
            test_startup_recovery_and_partial_member_survival
        ; test_case
            "transient provider failure retries via observation maintenance and stop clears owner"
            `Quick
            test_transient_retry_and_idle_barrier
        ; test_case
            "the Librarian's Memory lane alone starts no curator request"
            `Quick
            test_librarian_memory_lane_starts_no_curator_call
        ] )
    ]
