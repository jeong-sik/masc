open Alcotest
module Window = Masc.Browser_ego_native_window
module Raw = Masc.Browser_ego_raw_type
module Release = Masc.Browser_ego_release
module Input = Masc.Browser_ego_input
open Yojson.Safe.Util

let ok = function Ok value -> value | Error detail -> fail detail
let source : Window.page = {space_id=7;native={Masc.Browser_surface.label=Some "p1";
  target_id="target";opened_by=Masc.Browser_surface.Unknown_origin}}
let page_json (page:Window.page) = `Assoc (("spaceId",`Int page.space_id)
  :: Masc.Browser_surface.ego_page_fields page.native)
let begin_input input command = ok (ok (Input.within_command input ~command_id:command
  (fun () -> Input.begin_holding input ~now:100. ~scope:Input.Page_scope ~tab_id:3
    ~page_label:"p1" ~operation:"native_type")))
let with_native_cases context consume =
  let directory=Filename.temp_dir ~perms:0o700 "masc-raw-type-" "" in
  Fun.protect ~finally:(fun () ->
    Array.iter (fun name -> Sys.remove (Filename.concat directory name)) (Sys.readdir directory);
    Unix.rmdir directory) (fun () ->
    let arguments=Filename.concat directory "arguments.json"
    and script=Filename.concat directory "producer.js"
    and captures=Filename.concat directory "captures.json" in
    Yojson.Safe.to_file arguments (`Assoc ["source",page_json source;"binding",Raw.arguments context]);
    let channel=open_out script in output_string channel Raw.script;close_out channel;
    let pid=Unix.create_process "node" [|"node";"test_browser_ego_raw_type.cjs";
      arguments;script;captures|] Unix.stdin Unix.stdout Unix.stderr in
    let _,status=Unix.waitpid [] pid in
    (match status with Unix.WEXITED 0 -> ()
      | WEXITED _ | WSIGNALED _ | WSTOPPED _ -> fail "native stand-in did not complete");
    consume (Yojson.Safe.from_file captures |> to_list))
let with_cases consume =
  let input=Input.create ~space_id:7 in
  let pending=begin_input input "actual-issued-command" in
  let context=ok (Raw.prepare ~command_id:pending.command_id ~generation:pending.generation
    ~source ~indices:[0]) in
  with_native_cases context (consume input pending context)
let case name cases = List.find (fun value -> value |> member "mode" |> to_string = name) cases
let capture name cases = case name cases |> member "capture"
let decoded context cases name = ok (Raw.decode context ~index:0 ~current:source (capture name cases))
let completed context cases name = match decoded context cases name with
  | Raw.Completed {expected;completion;_} -> expected,completion
  | Not_entered _ | Entered_unconfirmed _ -> fail "native tail did not verify"
let released answers = match Release.judge answers with
  | Release.Settled (Released proof) -> proof
  | Settled No_hold | Unconfirmed _ -> fail "completion evidence did not settle"
let contains text fragment =
  try ignore (Str.search_forward (Str.regexp_string fragment) text 0);true with Not_found -> false

let producer_and_decoder () = with_cases (fun _ pending context cases ->
  check int "all stand-in paths returned" 8 (List.length cases);
  List.iter (fun value ->
    let name=value |> member "mode" |> to_string in
    let public=match decoded context cases name with
      | Raw.Completed {completion;cleanup;_} ->
        check bool "only independent clean intervals continue" true
          (List.mem name ["normal";"child";"post-end";"cleanup"]);
        check bool "cleanup failure remains separate" (name="cleanup") (cleanup=Raw.Unconfirmed);
        Window.public_summary completion
      | Not_entered failure ->
        check string "known guard failed before raw call" "guard" name;
        Raw.public_failure failure
      | Entered_unconfirmed failure ->
        check bool "interrupted or non-void raw calls remain uncertain" true
          (List.mem name ["dialog";"context";"value"]);
        Raw.public_failure failure in
    check bool "private native header never enters public evidence" false
      (contains (Yojson.Safe.to_string public) "PRIVATE_NATIVE_HEADER_SENTINEL");
    let other=ok (Raw.prepare ~command_id:"different-command" ~generation:pending.Input.generation
      ~source ~indices:[0]) in
    check bool "even pre-raw capture cannot rebind invocation" true
      (Result.is_error (Raw.decode other ~index:0 ~current:source (member "capture" value)))) cases)

let cleanup_and_duplicate_evidence () = with_cases (fun _ pending context cases ->
  let expected,completion=completed context cases "normal" in
  let answer=ok (Release.answer_of_window ~expected completion) in
  let malformed=match capture "normal" cases with
    | `Assoc fields -> `Assoc (("cleanup",`Assoc ["kind",`String "returned";
        "kind",`String "unconfirmed"]) :: List.remove_assoc "cleanup" fields)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "capture not object" in
  (match ok (Raw.decode context ~index:0 ~current:source malformed) with
   | Raw.Completed {cleanup=Unconfirmed;_} -> ()
   | Completed {cleanup=(Not_attempted|Returned);_} | Not_entered _ | Entered_unconfirmed _ ->
     fail "malformed cleanup erased or misreported independently verified completion");
  let proof=released [0,answer;0,answer;1,Release.answer_of_json (`Assoc [])] in
  check int "identical window is not duplicated or stripped by later receipt" 1
    (List.length (Release.window_bindings proof));
  List.iter (fun answers -> match Release.judge answers with
    | Unconfirmed (Step_not_released {answer=Conflicting_evidence;_}) -> ()
    | Unconfirmed (Step_not_released {answer=(Receipt_with_dialog|Void_answer|Undeclared_answer
        |Never_returned|Native_window_unconfirmed _);_}|Held_by_script_report)
    | Settled _ -> fail "contradictory evidence became completion")
    [[0,answer;0,Release.answer_of_json (`Assoc [])];
     [0,Release.answer_of_json (`Assoc []);0,answer]];
  let repeated=ok (Raw.prepare ~command_id:pending.Input.command_id
    ~generation:pending.generation ~source ~indices:[0]) in
  with_native_cases repeated (fun repeated_cases ->
    let other_expected,other_completion=completed repeated repeated_cases "normal" in
    check bool "same public binding still has distinct private invocation" false
      (Window.same_completion completion other_completion);
    let other_answer=ok (Release.answer_of_window ~expected:other_expected other_completion) in
    match Release.judge [0,answer;0,other_answer] with
    | Unconfirmed (Step_not_released {answer=Conflicting_evidence;_}) -> ()
    | Unconfirmed (Step_not_released {answer=(Receipt_with_dialog|Void_answer|Undeclared_answer
        |Never_returned|Native_window_unconfirmed _);_}|Held_by_script_report)
    | Settled _ -> fail "distinct nonce/world/binding invocations were merged"))

let pending_and_space_fences () = with_cases (fun input pending context cases ->
  let expected,completion=completed context cases "normal" in
  let proof=released [0,ok (Release.answer_of_window ~expected completion)] in
  check bool "stale generation cannot settle actual pending" true
    (Result.is_error (Input.command_settled input ~generation:"stale" proof));
  check bool "stale generation leaves the pending input" true (Input.status input=Input.Uncertain pending);
  let elsewhere=Input.create ~space_id:8 in
  let other=begin_input elsewhere "actual-issued-command" in
  check bool "another Space cannot settle this Space's native-window proof" true
    (Result.is_error (Input.command_settled elsewhere ~generation:other.Input.generation proof));
  ok (Input.command_settled input ~generation:pending.Input.generation proof);
  check bool "the exact pending generation settles from its native completion" true
    (Input.status input=Input.Ready Command_settled))

let pre_raw_rollback () = with_cases (fun input pending _ _ ->
  let next=begin_input input "later-unentered-raw" in
  let context=ok (Raw.prepare ~command_id:next.command_id ~generation:next.generation
    ~source ~indices:[0]) in
  with_native_cases context (fun cases ->
    (match decoded context cases "guard" with
     | Raw.Not_entered _ -> ()
     | Entered_unconfirmed _ | Completed _ -> fail "guard was not proven unentered");
    ok (Input.not_started input ~generation:next.generation);
    check bool "proven-unentered restores the earlier unconfirmed input" true
      (Input.status input=Input.Ready (Input.Release_uncertain pending))))

let () = run "Ego native raw typing" ["shared producer and authority",[
  test_case "local continuation and independent private capture decoder" `Quick producer_and_decoder;
  test_case "cleanup separation and duplicate mixed evidence" `Quick cleanup_and_duplicate_evidence;
  test_case "exact pending generation and Space authority" `Quick pending_and_space_fences;
  test_case "pre-raw rollback restores the earlier unconfirmed input" `Quick pre_raw_rollback]]
