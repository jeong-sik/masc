open Alcotest
open Masc
module T = Agent_core.Types
module Host = Keeper_official_client_host
module Choice = Keeper_turn_driver_try_provider

(* History in these fixtures holds media by reference; every agent, runtime
   config and projector here reads the bytes back from this store. *)
let test_media_store = Agent_core.History.Memory_store.create ()

let stored_source ~media_type raw =
  match test_media_store.put ~media_type ~raw with
  | Ok stored -> Agent_core.Types.Stored stored
  | Error error -> failwith (Agent_core.Error.to_string (Agent_core.Error.Media error))

let require = function Ok value -> value | Error detail -> fail detail
let rec remove path = match Unix.lstat path with
  | {Unix.st_kind=Unix.S_DIR;_} ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
let with_path ?(blocked=false) body =
  let base = Filename.temp_file "official-argument-window-" "" in
  if not blocked then (Unix.unlink base; Unix.mkdir base 0o700);
  Fun.protect ~finally:(fun () -> remove base) (fun () -> body base)
let with_base body =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  with_path body

let text role value = T.make_message ~role [T.Text value]
let alpha = `Assoc ["command",`String (String.make 4000 'a')]
let beta = `Assoc ["command",`String (String.make 4000 'b')]
let exchange id input =
  [T.make_message ~role:T.Assistant [T.ToolUse {id;name="record";input}];
   T.make_message ~role:T.Tool ~tool_call_id:id
     [T.ToolResult {tool_use_id=id;content="done";outcome=T.Tool_succeeded;json=None;content_blocks=None}]]
let raw_seed = text T.User "The Librarian read this." :: (exchange "alpha" alpha @ exchange "beta" beta)
let current = `Assoc ["command",`String (String.make 4000 'c')]
let raw_history = raw_seed @ [text T.User "Use the earlier commands."] @ exchange "current" current
let completed_before = snd (Runtime_model_input_tail_window.annotate raw_seed)
let turn_start = Keeper_carried_front.Turn_boundary {end_atom=completed_before}
let position point : Host.librarian_position =
  {point;unread=Keeper_librarian_request_unread.empty}
let progress = position (Choice.Librarian_progress {end_atom=1})
let measure = Host.measure_message_bytes
let size messages = List.fold_left (fun sum message -> sum+measure message) 0 messages

let reader base_path =
  let schema = Keeper_runtime_schemas_toml.artifact_read in
  Tool_bridge.agent_core_tool_of_masc_with_execution_env ~base_path
    ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
    ~model_projection:(fun () -> Tool_output.bounded_inline_model_projection)
    ~name:schema.name ~description:schema.description ~input_schema:schema.input_schema
    (fun _ args ->
      let execution = Keeper_artifact_read.handle ~base_path ~args in
      match execution.disposition with
      | Tool_result.Completed () -> Tool_result.make_ok ~tool_name:schema.name
          ~start_time:(Tool_timing.start ()) ?data:execution.data ()
      | Tool_result.Failed class_ -> Tool_result.make_err ~tool_name:schema.name ~class_
          ~start_time:(Tool_timing.start ()) execution.raw_output
      | Tool_result.Deferred () -> fail "the canonical reader cannot defer")

let source ?(input_policy=Keeper_input_policy.Small) ?(seed=Some raw_seed)
    ?(replay_prefix=Keeper_replay_prefix.unchanged) ?(turn_start=turn_start) base_path =
  Host.create_argument_source ~input_policy ~base_path ~keeper_name:"official-arguments"
    ~seed ~replay_prefix ~turn_start
let projection ?(history_prefix=[]) ?tools source base_path =
  let tools = match tools with None -> [reader base_path] | Some tools -> tools in
  Option.bind source (fun source -> Host.argument_projection source ~tools ~history_prefix)
let project ?argument_projection ?(capacity_bytes=max_int) ?carried_front_seed
    ?(librarian_front=progress) ?on_carried_front ?on_model_input_window_observation messages =
  Host.start_range_projection ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "official-arguments" }) ?argument_projection ~measure_message_bytes:measure
    ~capacity_bytes ~unbounded_capacity_bytes:max_int ~reserved_bytes:0
    ?carried_front_seed ~librarian_front:(fun _ -> Ok librarian_front)
    ?on_carried_front ?on_model_input_window_observation
    ~turn_start ~keeper_name:"official-arguments" ~runtime_id:"official.sample" messages
  |> Result.map_error Agent_core.Error.to_string |> require
let inputs messages = List.concat_map (fun (message : T.message) ->
  List.filter_map (function
    | T.ToolUse {id;input;_} -> Some (id,input)
    | T.Text _ | Thinking _ | RedactedThinking _ | ReasoningDetails _ | ToolResult _ | Image _ | Document _ | Audio _ -> None)
    message.content) messages
let input id messages = match List.assoc_opt id (inputs messages) with
  | Some value -> value | None -> fail ("missing tool occurrence " ^ id)
let reference value = match Tool_output.normalized_artifact_ref_of_json value with
  | Tool_output.Decoded_normalized_artifact_ref reference -> reference
  | Tool_output.Not_normalized_artifact_ref | Invalid_normalized_artifact_ref _ -> fail "expected normalized reference"

let read_all reader reference =
  let buffer = Buffer.create reference.Tool_output.bytes in
  let rec loop offset =
    let output = match Agent_core.Tool.execute reader
      (`Assoc ["sha256",`String reference.sha256;"offset",`Int offset]) with
      | Ok output -> output | Error error -> fail error.message in
    let page = Yojson.Safe.from_string output.content in
    let open Yojson.Safe.Util in
    let content = page |> member "content" |> to_string in
    let bytes = match page |> member "encoding" |> to_string with
      | "utf-8" -> content | "base64" -> Base64.decode_exn content
      | other -> fail ("unknown page encoding " ^ other) in
    Buffer.add_string buffer bytes;
    if page |> member "eof" |> to_bool then Buffer.contents buffer
    else loop (page |> member "next_offset" |> to_int) in
  loop 0

let test_actual_codec_and_reader_preserve_json_and_current_arguments () = with_base @@ fun base ->
  let snapshot = List.map Agent_core.Checkpoint.message_to_json raw_history in
  let argument_projection = projection (source base) base in
  let sent = project ?argument_projection raw_history in
  let alpha_ref = reference (input "alpha" sent) in
  check string "JSON MIME" "application/json" alpha_ref.mime;
  check string "actual canonical reader reconstructs the exact JSON bytes"
    (Yojson.Safe.to_string alpha) (read_all (reader base) alpha_ref);
  check bool "the current turn remains verbatim" true (input "current" sent=current);
  check bool "canonical source is unchanged" true
    (List.map Agent_core.Checkpoint.message_to_json raw_history=snapshot);
  let encoded = List.find_map (fun (message : T.message) ->
    if List.mem_assoc "alpha" (inputs [message]) then Some (Host.encode_history_message message) else None) sent in
  let encoded = match encoded with Some bytes -> Yojson.Safe.from_string bytes | None -> fail "no encoded call" in
  let blocks = Yojson.Safe.Util.(encoded |> member "message" |> member "content_blocks" |> to_list) in
  check bool "actual official codec carries the same normalized JSON" true
    (List.exists (fun block -> Yojson.Safe.Util.member "input" block=input "alpha" sent) blocks)

let accepted_seed messages first_atom =
  let digest = match Runtime_model_input_tail_window.atom_opening_digest messages first_atom with
    | Some digest -> digest | None -> fail "seed opener missing" in
  {Keeper_carried_front.first_atom;front=Model_input_front.At_atom digest;
   source=Keeper_carried_front.Turn_record {turn=1}}
let test_seed_witness_uses_raw_source_and_dropped_arguments_are_not_written () = with_base @@ fun base ->
  let seed = accepted_seed raw_history 2 and reads = ref 0 and fronts = ref [] in
  let carried_front_seed () = incr reads; {Keeper_carried_front.no_seed_read with seed=Some seed} in
  let sent = project ?argument_projection:(projection (source base) base) ~carried_front_seed
    ~librarian_front:(position Choice.No_position)
    ~on_carried_front:(fun front ~transmitted_bytes:_ -> fronts:=front::!fronts) raw_history in
  check int "one authority read across select and recut" 1 !reads;
  check bool "the raw opener still admits its carried front" true
    (match !fronts with [Host.Carried_seed _] -> true
     | [] | _::_::_ | [Host.Lane_cut | Host.Turn_start | Host.Turn_start_unknown _ | Host.Librarian_snapshot _ | Host.Librarian_progress _] -> false);
  ignore (reference (input "beta" sent));
  check bool "discarded alpha is absent" false (List.mem_assoc "alpha" (inputs sent));
  let store = Tool_blob_store.create ~base_path:base in
  let digest = Agent_core_sha256.(to_hex (digest_string (Yojson.Safe.to_string alpha))) in
  match Tool_blob_store.fetch store ~sha256:digest with
  | Ok None -> () | Ok (Some _) -> fail "discarded argument was written" | Error error -> fail (Tool_blob_store.fetch_error_to_string error)

let test_declared_pinned_prefix_and_media_replay_keep_occurrence_coordinates () = with_base @@ fun base ->
  let image = T.Image {media_type="image/png";source=(stored_source ~media_type:"image/png" "fixture")} in
  let canonical = T.make_message ~role:T.User [T.Text "The Librarian read this.";image] :: List.tl raw_seed in
  let replay_prefix = Keeper_replay_prefix.media_degraded ~canonical_prefix:canonical ~dispatch_prefix:raw_seed in
  let prefix = [text T.System "Caller-owned task reference."] in
  let argument_projection = projection ~history_prefix:prefix
    (source ~seed:(Some canonical) ~replay_prefix base) base in
  let sent = project ?argument_projection (prefix @ raw_history) in
  ignore (reference (input "alpha" sent));
  check bool "prefix is retained byte-for-byte" true (List.exists (T.Message_value.equal (List.hd prefix)) sent);
  let replacement = [text T.System "Different reference."] @ raw_history in
  let sent = project ?argument_projection replacement in
  check bool "a different declared prefix cannot reuse shifted slots" true (input "alpha" sent=alpha)

let test_absent_authority_surface_and_open_seed_leave_arguments_verbatim () = with_base @@ fun base ->
  let cases =
    [source ~input_policy:Keeper_input_policy.Wide base;
     source ~seed:None base;
     source ~turn_start:(Keeper_carried_front.Turn_boundary_unknown {reason="unreadable fixture"}) base] in
  List.iter (fun source ->
    let sent = project ?argument_projection:(projection source base) raw_history in
    check bool "missing authority keeps alpha" true (input "alpha" sent=alpha)) cases;
  let sent = project ?argument_projection:(projection ~tools:[] (source base) base) raw_history in
  check bool "no actual reader keeps alpha" true (input "alpha" sent=alpha);
  let open_seed = List.take 2 raw_seed in
  let sent = project ?argument_projection:(projection (source ~seed:(Some open_seed) base) base) raw_history in
  check bool "a synthesized later closer cannot authorize alpha" true (input "alpha" sent=alpha);
  check bool "eligibility setup made no blob directory" false
    (Sys.file_exists (Tool_blob_store.root_dir (Tool_blob_store.create ~base_path:base)))

let test_storage_failure_restores_raw_and_recuts_to_actual_capacity () = with_base @@ fun good_base ->
  let good = project ?argument_projection:(projection (source good_base) good_base) raw_history in
  let capacity_bytes = size good in
  with_path ~blocked:true @@ fun failed_base ->
  let argument_projection = projection (source failed_base) failed_base in
  let unbounded = project ?argument_projection raw_history in
  check bool "failure restores exact alpha" true (input "alpha" unbounded=alpha);
  let bounded = project ?argument_projection ~capacity_bytes raw_history in
  check bool "failed raw bytes are measured, not placeholders" true (size bounded<=capacity_bytes);
  check bool "failure emits no invented reference" true (List.for_all (fun (_,input) ->
    match Tool_output.normalized_artifact_ref_of_json input with
    | Tool_output.Not_normalized_artifact_ref -> true
    | Tool_output.Invalid_normalized_artifact_ref _ | Decoded_normalized_artifact_ref _ -> false) (inputs bounded))

let snapshot () =
  (* Cover alpha's complete exchange. The raw capacity cut reaches beta at
     atom 2, so a snapshot ending at atom 1 would lose authority before the
     summary-versus-position comparison this scenario is meant to exercise. *)
  let messages = List.take 3 raw_seed in
  let position = Keeper_turn_boundaries.position_of_messages messages |> require in
  let boundary : Keeper_turn_boundaries.record = {recorded_at=1.;event=Turn_ended
    {task_context=Keeper_turn_task_context.No_task;turn_ref=Ids.Turn_ref.make ~trace_id:"argument-summary" ~absolute_turn:1;
     history_at_start=Fresh_history;position}} in
  Librarian_continuity_snapshot.capture ~unread_messages:[] ~trace_id:"argument-summary"
    ~lines:[1,Ok boundary] ~messages
    ~working_state:(String.make (String.length (Yojson.Safe.to_string alpha)) 's')
  |> Result.map_error Librarian_continuity_snapshot.error_to_string |> require

let test_failed_materialization_repeats_summary_choice_without_displacing_atoms () = with_base @@ fun good_base ->
  let librarian_front = position (Choice.Librarian_snapshot (snapshot ())) in
  let good = project ?argument_projection:(projection (source good_base) good_base) ~librarian_front raw_history in
  let capacity_bytes = size good in
  with_path ~blocked:true @@ fun failed_base ->
  let sent = project ?argument_projection:(projection (source failed_base) failed_base)
    ~librarian_front ~capacity_bytes raw_history in
  let has_state messages = List.exists Runtime_model_input_tail_window.is_working_state messages in
  check bool "a fitting state was present before failure" true (has_state good);
  check bool "failed large raw arguments must not be displaced by the state" false (has_state sent);
  check bool "actual final capacity is respected" true (size sent<=capacity_bytes);
  check bool "position-only keeps a raw command the state would evict" true (List.mem_assoc "beta" (inputs sent));
  check bool "the retained command is its exact original JSON" true (input "beta" sent=beta)

let test_zero_history_floor_does_not_write_dropped_slots () = with_base @@ fun base ->
  let attached = Keeper_librarian_request_unread.attach ~include_empty:true ~role:T.System
    Keeper_librarian_request_unread.empty raw_history in
  let _, atom_count = Runtime_model_input_tail_window.annotate raw_history in
  let floor, capacity_bytes = Runtime_model_input_tail_window.project_from_atom
    ~allow_empty_history:true ~measure_message_bytes:measure ~first_atom:atom_count attached in
  let observed = ref None in
  let sent = project ?argument_projection:(projection (source base) base) ~capacity_bytes
    ~on_model_input_window_observation:(fun observation -> observed := Some observation) raw_history in
  check (list string) "the floor carries exactly its omission and frozen unread evidence"
    (List.map Host.encode_history_message floor.messages)
    (List.map Host.encode_history_message sent);
  (* The synthetic User preamble explains omitted history; it is not a
     durable source atom. The observation uses the source's coordinates. *)
  (match !observed with
   | None -> fail "the empty floor did not publish its window"
   | Some observation ->
     check int "the explicit capacity floor carries no durable atom" 0 observation.transmitted_atoms;
     check int "the floor retains the source denominator" atom_count observation.total_atoms;
     match observation.model_input_front with
     | Model_input_front.After_history digest ->
       check (option string) "the floor witnesses the exact end of the raw source"
         (Runtime_model_input_tail_window.atom_opening_digest raw_history (atom_count-1)) (Some digest)
     | Model_input_front.At_atom _ | Empty_history -> fail "the floor lost its raw history end");
  check bool "dropped slots caused no writes" false
    (Sys.file_exists (Tool_blob_store.root_dir (Tool_blob_store.create ~base_path:base)))

let test_completion_review_preserves_the_full_evidence_without_history_reads () =
  with_base @@ fun base ->
  let attachment = T.make_message ~role:T.User
      [T.Text "Review the attached original evidence."
      ; T.Image { media_type = "image/png"; source = (stored_source ~media_type:"image/png" "original-image-bytes") }]
  in
  let evidence = raw_history @ [attachment] in
  let original = List.map Agent_core.Checkpoint.message_to_json evidence in
  let argument_projection = match projection (source base) base with
    | Some projection -> projection
    | None -> fail "the fixture must offer an eligible argument demotion plan"
  in
  let late_seed = accepted_seed evidence 2 in
  List.iter (fun boundary ->
    let seed_reads = ref 0 and librarian_reads = ref 0 and measured = ref 0 in
    let windows = ref 0 and carried_fronts = ref 0 in
    let sent = Host.start_range_projection
        ~input_source:Masc.Keeper_request_source.Completion_review ~argument_projection
        ~measure_message_bytes:(fun message -> incr measured; measure message)
        ~capacity_bytes:1 ~unbounded_capacity_bytes:max_int ~reserved_bytes:0
        ~carried_front_seed:(fun () -> incr seed_reads;
          { Keeper_carried_front.no_seed_read with seed = Some late_seed })
        ~librarian_front:(fun _ -> incr librarian_reads;
          Error (Agent_core.Error.Internal "completion evidence must not read Keeper continuity"))
        ~on_model_input_window_observation:(fun _ -> incr windows)
        ~on_carried_front:(fun _ ~transmitted_bytes:_ -> incr carried_fronts)
        ~turn_start:boundary ~keeper_name:"completion-evidence-fixture"
        ~runtime_id:"official.sample" evidence
      |> Result.map_error Agent_core.Error.to_string |> require
    in
    check bool "all evidence, attachment and paired tool messages remain exact" true
      (List.map Agent_core.Checkpoint.message_to_json sent = original);
    check bool "large closed arguments stay inline as their original JSON" true
      (input "alpha" sent = alpha && input "beta" sent = beta && input "current" sent = current);
    check int "no durable Keeper seed read" 0 !seed_reads;
    check int "no Librarian continuity read" 0 !librarian_reads;
    check int "no capacity measurement or shrink planning" 0 !measured;
    check int "no history-window projection callback" 0 !windows;
    check int "no carried-history projection callback" 0 !carried_fronts;
    check bool "argument demotion wrote no artifact" false
      (Sys.file_exists (Tool_blob_store.root_dir (Tool_blob_store.create ~base_path:base))))
    [ turn_start
    ; Keeper_carried_front.Turn_boundary_unknown { reason = "no Keeper boundary owns completion evidence" }
    ]

let () = Alcotest.run "official argument window"
  ["source and transport",
    [test_case "completion evidence bypasses history projection" `Quick test_completion_review_preserves_the_full_evidence_without_history_reads;
     test_case "actual codec/reader and current turn" `Quick test_actual_codec_and_reader_preserve_json_and_current_arguments;
     test_case "raw seed witness and retained-only writes" `Quick test_seed_witness_uses_raw_source_and_dropped_arguments_are_not_written;
     test_case "pinned prefix and media replay" `Quick test_declared_pinned_prefix_and_media_replay_keep_occurrence_coordinates;
     test_case "authority/reader/open seed" `Quick test_absent_authority_surface_and_open_seed_leave_arguments_verbatim;
     test_case "storage failure and capacity" `Quick test_storage_failure_restores_raw_and_recuts_to_actual_capacity;
     test_case "storage failure repeats summary choice" `Quick test_failed_materialization_repeats_summary_choice_without_displacing_atoms;
     test_case "zero-history floor" `Quick test_zero_history_floor_does_not_write_dropped_slots]]
