open Masc
module Owner = Lane_addon_tool_request_owner
module Store = Lane_addon_store
module Progress = Lane_addon_request_progress
module Census = Server_settled_original_census

let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let owned value = get (Result.map_error Owner.error_to_string value)
let date = "2026-10-27"
let curator = Workspace_memory_execution_capture.scope
let history = "keeper-librarian-history-execution-owner"
let history_gate = "keeper-librarian-durable-gate/owner"
let floor = "keeper-librarian-floor-step-owner"
let floor_gate = "keeper-librarian-floor-step-gate/owner"

let with_store f =
  let parent = Filename.temp_dir "settled-census" "" in
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Unix.chmod path 0o700;
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Sys.remove path in
  Fun.protect ~finally:(fun () -> remove parent) (fun () ->
    let root = Filename.concat parent "store" in f root (Store.create ~root))

let request id = `Assoc ["input",`String id]
let retain ?request_json store ~scope id =
  let request = Option.value request_json ~default:(request id) in
  owned (Owner.retain ~store ~scope ~request_id:id ~installation_id:"original-installation"
    ~package_id:"owner-package" ~tool:"owner-tool" ~summary:`Null ~request);
  match owned (Owner.load ~store ~scope ~request_id:id) with
  | Some original -> original
  | None -> Alcotest.fail "retained original is absent"
let advance store original event =
  match get (Result.map_error Owner.update_error_to_string (Owner.advance ~store ~expected:original ~event)) with
  | Owner.Stored next -> next
  | Owner.Already_stored _ | Owner.Unconfirmed _ -> Alcotest.fail "progress event not stored"
let settle store original =
  match Owner.settle ~store ~date (Owner.listed original) with
  | Ok () -> ()
  | Error error -> Alcotest.fail (Owner.settle_error_to_string error)
(* A record nothing names, settled beside the named one in the same scope. *)
let settle_stray store ~scope = settle store (retain store ~scope "stray")
let gate_request ~kind ~id ~execution = `Assoc [
  "version",`Int 3;"kind",`String kind;"request_id",`String id;"owner",`Null;
  "execution_id",`String execution;"execution_digest",`String "parent-digest";
  "proposal",`Null;"authority",`Null;"guidance",`Null;"predecessor",`Null]
let run store = match Census.run ~store with
  | Ok report -> report
  | Error error -> Alcotest.fail (Census.error_to_string error)
let refused store = match Census.run ~store with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "the census counted a store it cannot classify"
let check_one_unnamed_of_two (report : Census.report) =
  Alcotest.(check int) "both settled records are counted" 2 report.archived_records;
  Alcotest.(check int) "only the record no live record names is unnamed" 1 report.unnamed_records;
  Alcotest.(check int) "each settled record left its body" 2 report.archived_bodies

(* Server_workspace_memory_addon.finish_settling asks for a Subdivided
   successor. *)
let test_curator_successor_is_named () = with_store (fun _ store ->
  let child = retain store ~scope:curator "child" in
  let parent = retain store ~scope:curator "parent" in
  let parent = advance store parent Progress.Dispatch_intended in
  let parent = advance store parent (Progress.Refused {stage=Progress.Execution;evidence=`String "too large"}) in
  let digest = get (Owner.request_digest (request "child")) in
  let parent = advance store parent (Progress.Successor_intended {request_id="child";request_digest=digest}) in
  ignore (advance store parent (Progress.Successor_observed "child"));
  settle store child;
  settle_stray store ~scope:curator;
  let report = run store in
  check_one_unnamed_of_two report;
  Alcotest.(check int) "the live parent is the only live record" 1 report.live_records)

(* Keeper_librarian_durable_execution asks for a confirmed replacement. *)
let test_history_replacement_is_named () = with_store (fun _ store ->
  let child = retain store ~scope:history "replacement" in
  let parent = retain store ~scope:history "conflicted" in
  let parent = advance store parent Progress.Dispatch_intended in
  let parent = advance store parent (Progress.Judgment_retained (`String "judged")) in
  let parent = advance store parent
      (Progress.Commit_intended {before=`String "before";after=`String "after"}) in
  let parent = advance store parent (Progress.Commit_conflicted (`String "other")) in
  let parent = advance store parent
      (Progress.Replacement_intended {request_id="replacement";request=request "replacement"}) in
  ignore (advance store parent (Progress.Replacement_observed "replacement"));
  settle store child;
  settle_stray store ~scope:history;
  check_one_unnamed_of_two (run store))

(* The history and floor gate inventories ask for the execution their
   records name. The floor gate scope also starts with the floor step
   prefix, so this is read as a gate only when gates are asked first. *)
let gate_names_its_execution ~gate_scope ~kind ~execution_scope () = with_store (fun _ store ->
  let execution = retain store ~scope:execution_scope "execution" in
  ignore (retain store ~scope:gate_scope "gate"
    ~request_json:(gate_request ~kind ~id:"gate" ~execution:"execution"));
  settle store execution;
  settle_stray store ~scope:execution_scope;
  check_one_unnamed_of_two (run store))

let test_unclaimed_scope_refuses () = with_store (fun _ store ->
  ignore (retain store ~scope:"an-owner-no-census-knows" "original");
  refused store)

let test_unknown_archive_directory_refuses () = with_store (fun root store ->
  settle_stray store ~scope:curator;
  ignore (run store);
  let day = Filename.concat root (Filename.concat Store.tool_request_archive_directory
    (Filename.concat (Store.digest curator) date)) in
  Unix.mkdir (Filename.concat day "notes") 0o700;
  refused store)

let () = Alcotest.run "settled original census" ["census", [
  Alcotest.test_case "a Curator successor keeps its settled record" `Quick test_curator_successor_is_named;
  Alcotest.test_case "a history replacement keeps its settled record" `Quick test_history_replacement_is_named;
  Alcotest.test_case "a history gate keeps its settled execution" `Quick
    (gate_names_its_execution ~gate_scope:history_gate ~kind:"librarian-durable-gate" ~execution_scope:history);
  Alcotest.test_case "a floor step gate keeps its settled execution" `Quick
    (gate_names_its_execution ~gate_scope:floor_gate ~kind:"librarian-floor-step-gate" ~execution_scope:floor);
  Alcotest.test_case "a scope no owner claims refuses the count" `Quick test_unclaimed_scope_refuses;
  Alcotest.test_case "an unknown archive directory refuses the count" `Quick test_unknown_archive_directory_refuses;
]]
