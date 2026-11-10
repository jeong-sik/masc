(* #50845: an official-client tool result lists the queue rows that arrived
   during the run through [Keeper_arrived_stimuli_reader], the reader of the
   Agent Core post-tool round. Actual Board, queue, registry and metadata
   stores; the projection is given no reader of its own. *)
open Alcotest
open Masc
module Host = Keeper_official_client_host

let get = function Ok value -> value | Error detail -> fail detail
let keeper_name = "preview-outsider"
let addressed_reader = "direct-reader"
let author = "direct-author"
let tool_text = "tool-text-before-the-block"
(* A stored queue names a retained tool result by its SHA-256. *)
let receipt_id = Agent_core_sha256.(digest_string "background-run" |> to_hex)
let has text needle = String_util.contains_substring text needle

let with_workspace f =
  Masc_test_deps.ensure_rng_initialized ();
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let base_path = Filename.temp_dir "keeper-arrived-preview-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:None : string);
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Fun.protect ~finally:(fun () ->
    Keeper_registry.For_testing.clear ();
    Board_dispatch.reset_for_test ();
    Board.reset_global_for_test ()) @@ fun () ->
  let recipient_lookup = Recipient_lookup.make (fun candidate ->
    Ok (Result.to_option (Board.Agent_id.parse
      (Recipient_lookup.Candidate.to_string candidate)))) in
  ignore (Result.get_ok (Board_dispatch.init_jsonl ~base_path ~recipient_lookup ()));
  f ~base_path ~config

let register_keeper ~base_path =
  let meta = get (Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name", `String keeper_name; "trace_id", `String ("trace-" ^ keeper_name)])) in
  ignore (Keeper_registry.For_testing.register ~base_path keeper_name meta);
  meta

(* The Keeper's declaration. [mention_targets] names the other identities the
   Keeper reads the Board as. *)
let declare_reader_aliases ~base_path aliases =
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  Out_channel.with_open_text (Filename.concat keepers_dir (keeper_name ^ ".toml"))
    (fun channel -> Printf.fprintf channel
      "[keeper]\ninstructions = \"Read authorized Board evidence.\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nmention_targets = [%s]\n"
      (String.concat ", " (List.map (Printf.sprintf "%S") aliases)))

let post visibility title content =
  match Board_dispatch.create_post ~author ~title ~content
    ~post_kind:Board.Human_post ~visibility () with
  | Ok post -> post
  | Error error -> fail (Board.Post_publication_failure.to_string error)

(* Four rows dated after the projection was built: a Direct post addressed to
   another reader, a public post, a post whose routing is unresolved and a
   retained tool result. *)
let arrive ~base_path =
  let arrived_at = Time_compat.now () +. 60. in
  let board (post : Board.post) content : Keeper_event_queue.board_stimulus =
    { kind = Keeper_event_queue.Post_created; author; title = post.title; content; hearth = None
    ; updated_at = Some post.created_at
    ; audience = Keeper_event_queue.Audience_targets [addressed_reader] } in
  let row (post : Board.post) payload : Keeper_event_queue.stimulus =
    { post_id = Board.Post_id.to_string post.id; urgency = Keeper_event_queue.Normal
    ; arrived_at; payload } in
  let direct = post Board.Direct "DIRECT_TITLE_ONLY" ("@" ^ addressed_reader ^ " DIRECT_BODY_ONLY") in
  let public = post Board.Public "PUBLIC_TITLE_ONLY" "PUBLIC_BODY_ONLY" in
  let unrouted = post Board.Public "UNROUTED_TITLE_ONLY" "UNROUTED_BODY_ONLY" in
  let rows =
    [ row direct (Keeper_event_queue.Board_signal (board direct "DIRECT_BODY_ONLY"))
    ; row public (Keeper_event_queue.Board_signal (board public "PUBLIC_BODY_ONLY"))
    ; row unrouted (Keeper_event_queue.Board_routing_pending (board unrouted "UNROUTED_BODY_ONLY"))
    ; { post_id = "background-run"; urgency = Keeper_event_queue.Normal; arrived_at
      ; payload = Keeper_event_queue.Tool_result_ready receipt_id } ] in
  Keeper_event_queue_persistence.persist ~base_path ~keeper_name
    (List.fold_left Keeper_event_queue.enqueue Keeper_event_queue.empty rows);
  List.length rows

let project ~result_scope ~base_path =
  let tool = Agent_core.Tool.create ~name:"CompleteEffect" ~description:"Complete an effect once"
      ~parameters:[]
      (fun _ -> Ok {Agent_core.Types.content=tool_text;content_blocks=None;_meta=None}) in
  match Host.dynamic_tools ~result_scope:(Some result_scope) ~base_path
    ~content_transport:Runtime_official_client_tool.Mcp
    ~accepts_image_input:true ~tool_approval:None ~runtime_label:"arrived-preview-fixture"
    ~keeper_name ~turn_count:7 ~tools:[tool] ~loading_plan:Host.All_on_demand
    ~hooks:Agent_core.Hooks.empty ~event_bus:None ~context_injector:None
    ~context:(Some (Agent_core.Context.create_sync ()))
    ~terminal_effect_state:(fun () -> Keeper_tools_agent_core.Terminal_effect_open)
    ~terminal_error:(ref None) ~pre_tool_rejects:(ref []) ~raw_trace_run:None () with
  | Ok ([tool], _) -> tool
  | Ok _ -> fail "one projected tool required"
  | Error error -> fail (Agent_core.Error.to_string error)

let written (result : Host.dynamic_tool_result) =
  match result.on_response_sent with
  | Some notify -> notify ()
  | None -> fail "the result has no physical-write token"

let test_a_tool_result_lists_only_the_rows_the_keeper_can_read () =
  with_workspace @@ fun ~base_path ~config ->
  get (Keeper_meta_store.replace_snapshot config (register_keeper ~base_path));
  declare_reader_aliases ~base_path [];
  Eio.Switch.run @@ fun result_scope ->
  let tool = project ~result_scope ~base_path in
  let queued = arrive ~base_path in
  let as_outsider = tool.call ~call_id:"as-outsider" (`Assoc []) in
  check bool "the tool's own text comes first" true
    (String.starts_with ~prefix:tool_text as_outsider.content);
  check bool "a Board row of a post the Keeper can read is listed" true
    (has as_outsider.content "title=PUBLIC_TITLE_ONLY");
  check bool "a row that is not a Board row is listed" true
    (has as_outsider.content ("tool_result_ready receipt_id=" ^ receipt_id));
  check bool "a Direct post addressed to another reader is not named" false
    (has as_outsider.content "DIRECT_TITLE_ONLY");
  check bool "a Board row whose routing is unresolved is not listed" false
    (has as_outsider.content "board_routing_pending");
  written as_outsider;
  declare_reader_aliases ~base_path [addressed_reader];
  let as_reader = tool.call ~call_id:"as-reader" (`Assoc []) in
  check bool "the Direct row is listed once the Keeper reads as its addressee" true
    (has as_reader.content "title=DIRECT_TITLE_ONLY");
  check bool "a row the client already received is not listed again" false
    (has as_reader.content "PUBLIC_TITLE_ONLY");
  check bool "the unresolved row stays unlisted" false
    (has as_reader.content "board_routing_pending");
  check int "the block leaves every row queued" queued
    (List.length (get (Keeper_registry_event_queue.pending_selections_result ~base_path keeper_name)))

let test_without_readership_metadata_a_tool_result_lists_nothing () =
  with_workspace @@ fun ~base_path ~config:_ ->
  ignore (register_keeper ~base_path : Keeper_meta_contract.keeper_meta);
  Eio.Switch.run @@ fun result_scope ->
  let tool = project ~result_scope ~base_path in
  ignore (arrive ~base_path : int);
  let result = tool.call ~call_id:"no-metadata" (`Assoc []) in
  check string "readership cannot be judged, so the result goes out as it was" tool_text
    result.content

let () =
  run "Arrived-row preview follows Board readership"
    ["official-client tool result",
     [ test_case "lists only the rows the Keeper can read" `Quick
         test_a_tool_result_lists_only_the_rows_the_keeper_can_read
     ; test_case "lists nothing without readership metadata" `Quick
         test_without_readership_metadata_a_tool_result_lists_nothing ]]
