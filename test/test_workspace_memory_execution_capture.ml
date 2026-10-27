open Masc
module C = Workspace_memory_execution_capture
module L = Workspace_memory_ledger
module R = Workspace_memory_request
module B = Workspace_memory_briefing
module Revision = Workspace_memory_revision
module Owner = Lane_addon_tool_request_owner
module Store = Lane_addon_store
let get = function Ok v -> v | Error e -> Alcotest.fail e
let owned v = get (Result.map_error Owner.error_to_string v)
let requested v = get (Result.map_error R.error_to_string v)
let some = function Some v -> v | None -> Alcotest.fail "missing original capture"
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let member = Yojson.Safe.Util.member
let replace key value = function
  | `Assoc f -> `Assoc (List.map (fun (k,v) -> k, if k=key then value else v) f)
  | _ -> Alcotest.fail "expected object"
let with_workspace f =
  let parent = Filename.temp_dir "curator-host-capture" "" in
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Sys.remove path in
  Fun.protect ~finally:(fun () -> remove parent) (fun () ->
    let root = Filename.concat parent "workspace" in Unix.mkdir root 0o700;
    f root (Store.create ~root:(Filename.concat root "store")))
let id = get (C.Request_id.of_string "019c0000-0000-7000-8000-000000000001")
let destination : C.destination = {installation_id="curator-original";package_id="curator";
  tool="classify";source_revision="package-source-1";configuration_revision="config-1"}
let prompt effective : Prompt_registry.prompt_resolution =
  {effective;source=Prompt_registry.Override;file_value=None;override_value=Some effective;
   file_path=None;file_exists=false;has_override=true}
let classification_prompt = prompt "Original instructions:\n{{workspace_memory_changes}}"
let render key variable p input =
  Prompt_registry.render_resolved_prompt_template key p [variable,Yojson.Safe.to_string input]
let fact keeper claim : L.pending_fact =
  {fact=L.Ordinary {keeper_id=keeper;claim_sha256=Agent_core_sha256.(digest_string claim |> to_hex)};claim}
let stored_ledger base_path ledger =
  get (Revision.write_ledger ~base_path ledger |> Result.map_error Revision.write_error_to_string)
let classification ?(ledger=L.empty) ?(narrowed=true) ?(request_id=id) ~base_path workspace =
  let a = fact "writer" "Complete source evidence A" and b = fact "writer" "Complete source evidence B" in
  let render = render Prompt_names.workspace_memory_curator "workspace_memory_changes" classification_prompt in
  let full = some (requested (R.prepare ~neighbor_limit:0 ~render ~ledger ~current:[a;b] ~pending:[a;b]
      ~size:R.Fill_frame ~frame:max_int ~measure:(fun _ -> Ok 0))) in
  let batch = if narrowed then some (requested (R.narrow ~render ~ledger full)) else full in
  a,b,batch,get (C.classification ~request_id ~workspace ~destination ~prompt:classification_prompt ~ledger ~stored_ledger:(stored_ledger base_path ledger) ~batch)
let summary_of capture = C.Summary.to_json (get (C.summary capture))
let retain ?(scope=C.scope) ?(installation_id=destination.installation_id) ?(tool=destination.tool)
    ~summary ~request store =
  let request_id = C.Request_id.to_string id in
  owned (Owner.retain ~store ~scope ~request_id ~installation_id ~package_id:destination.package_id ~tool
    ~summary ~request);
  some (owned (Owner.load ~store:(Store.create ~root:(Store.root store)) ~scope ~request_id))
let restore store ~workspace record = C.restore ~workspace
  ~load:(fun ~request_id -> Owner.load ~store ~scope:C.scope ~request_id
    |> Result.map_error Owner.error_to_string) record
let rejected = function Error _ -> () | Ok _ -> Alcotest.fail "invalid host capture accepted"
let occurrences sub text =
  let n = String.length sub in
  let rec count from total = match String.index_from_opt text from sub.[0] with
    | Some i when i + n <= String.length text ->
      if String.equal (String.sub text i n) sub then count (i + n) (total + 1) else count (i + 1) total
    | Some _ | None -> total in
  count 0 0

let test_canonical_storage_preserves_original_prompt_and_selected_judgment () = with_workspace (fun root store ->
  let workspace = get (C.observe_workspace ~base_path:root) in
  let a,_,batch,capture = classification ~base_path:root workspace in
  let retained = retain ~summary:(summary_of capture) ~request:(C.to_json capture) store in
  let restored = get (restore store ~workspace:(get (C.observe_workspace ~base_path:root)) retained) in
  Alcotest.(check int) "the stored capture holds the model input once" 1
    (occurrences a.claim (Yojson.Safe.to_string retained.request));
  Alcotest.(check string) "actual original prompt is restored" batch.rendered_prompt (C.rendered_prompt restored);
  Alcotest.check json "schema preserved" Workspace_memory_decision.output_schema (C.output_schema restored);
  let local = match R.selected_ids batch with
    | [(id, _)] -> id | [] | _ :: _ :: _ -> Alcotest.fail "one narrowed selection" in
  let answer = `Assoc ["decisions", `List [`Assoc ["fact_id",`String local;
    "kind",`String "create_claim";"value",`String "A source-attributed interpretation"]]] in
  (match get (C.validate_output restored answer) with
   | C.Classification_commit ledger ->
     Alcotest.(check bool) "only selected fact has an expected disposition" true
       (List.map fst (L.dispositions ledger) = [a.fact]);
     (match C.work restored with
      | C.Classification {batch;_} -> Alcotest.(check bool) "the narrowed selection is the oldest fact" true (batch.selected=[a])
      | C.Briefing _ -> Alcotest.fail "request kind changed")
   | C.Briefing_commit _ -> Alcotest.fail "classification changed domain");
  rejected (C.validate_output restored (`Assoc ["decisions",`List []]));
  (* Current configuration must not supply new bytes to an accepted request. *)
  let key = Prompt_names.workspace_memory_curator in
  let prompts = Filename.concat root "fixture-prompts" in Unix.mkdir prompts 0o700;
  Out_channel.with_open_bin (Filename.concat prompts (key ^ ".md")) (fun oc ->
    output_string oc ("---\ndescription: captured Curator fixture\ncategory: test\n"
      ^ "template_variables: [workspace_memory_changes]\n---\n" ^ classification_prompt.effective));
  Prompt_registry.clear ();
  Fun.protect ~finally:Prompt_registry.clear (fun () ->
    Prompt_registry.set_markdown_dir prompts;
    ignore (get (Prompt_registry.set_override key "Replacement instructions: {{workspace_memory_changes}}"));
    Alcotest.(check string) "new override does not replace captured template"
      batch.rendered_prompt (C.rendered_prompt (get (restore store ~workspace retained)))))

let test_changed_capture_provenance_and_owner_are_refused () = with_workspace (fun root store ->
  let workspace = get (C.observe_workspace ~base_path:root) in
  let _,_,batch,capture = classification ~base_path:root workspace in
  rejected (C.classification ~request_id:id ~workspace ~destination ~ledger:L.empty ~stored_ledger:(stored_ledger root L.empty) ~batch
    ~prompt:(prompt "Different initial template: {{workspace_memory_changes}}"));
  rejected (C.classification ~request_id:id ~workspace ~destination ~ledger:L.empty ~stored_ledger:(stored_ledger root L.empty) ~batch
    ~prompt:{classification_prompt with file_path=Some ""});
  let original = C.to_json capture in
  (* A consistent template that renders another prompt than the one sent. *)
  let changed_prompt = member "prompt" original
    |> replace "effective" (`String "Other template: {{workspace_memory_changes}}")
    |> replace "override_value" (`String "Other template: {{workspace_memory_changes}}") in
  let invalid = [replace "rendered_prompt_sha256" (`String (String.make 64 '0')) original;
    replace "prompt" changed_prompt original;
    replace "prompt" (replace "has_override" (`Bool false) (member "prompt" original)) original;
    replace "output_schema" (`Assoc ["type",`String "string"]) original;
    replace "destination" (replace "installation_id" (`String "other") (member "destination" original)) original;
    replace "request_id" (`String "019c0000-0000-7000-8000-000000000002") original] in
  List.iteri (fun i request ->
    let store = Store.create ~root:(Filename.concat root ("invalid-" ^ string_of_int i)) in
    rejected (restore store ~workspace (retain ~summary:(summary_of capture) ~request store))) invalid;
  let wrong_scope = Store.create ~root:(Filename.concat root "wrong-scope") in
  rejected (restore store ~workspace
    (retain ~scope:"different-consumer" ~summary:(summary_of capture) ~request:original wrong_scope));
  let wrong_tool = Store.create ~root:(Filename.concat root "wrong-tool") in
  rejected (restore store ~workspace
    (retain ~tool:"different" ~summary:(summary_of capture) ~request:original wrong_tool)))

let test_physical_root_replacement_and_copy_are_refused () = with_workspace (fun root store ->
  let workspace = get (C.observe_workspace ~base_path:root) in
  let _,_,_,capture = classification ~base_path:root workspace in
  let retained = retain ~summary:(summary_of capture) ~request:(C.to_json capture) store in
  let other = Filename.concat (Filename.dirname root) "other-workspace" in Unix.mkdir other 0o700;
  let copy = retain ~summary:retained.summary ~request:retained.request (Store.create ~root:(Filename.concat other "store")) in
  rejected (restore store ~workspace:(get (C.observe_workspace ~base_path:other)) copy);
  let moved = root ^ "-original" in
  Unix.rename root moved; Unix.mkdir root 0o700;
  rejected (restore store ~workspace:(get (C.observe_workspace ~base_path:root)) retained);
  Unix.rmdir root;
  rejected (C.observe_workspace ~base_path:root))

let test_briefing_contract_and_partial_publication_are_original () = with_workspace (fun root store ->
  let workspace = get (C.observe_workspace ~base_path:root) in
  let source id : B.source = {id;kind=B.Claim;text="Uncut evidence " ^ id} in
  let sources = [source "a";source "b"] in
  let p = prompt "Original briefing: {{workspace_memory_briefing}}" in
  let render = render Prompt_names.workspace_memory_briefing "workspace_memory_briefing" p in
  let prepared contract = match get (B.prepare ~sources ~contract ~render B.empty) with
    | B.Prepared batch -> batch
    | B.Unchanged | B.Cleanup _ -> Alcotest.fail "expected original briefing" in
  let make batch = C.briefing ~request_id:id ~workspace ~destination ~prompt:p ~batch in
  rejected (make (prepared (B.contract ~template:"different-template")));
  let batch = some (get (B.narrow ~render (prepared (B.contract ~template:p.effective)))) in
  let capture = get (make batch) in
  let restored = get (restore store ~workspace (retain ~summary:(summary_of capture) ~request:(C.to_json capture) store)) in
  match get (C.validate_output restored (`Assoc ["briefing",`String "Partial original summary"])) with
  | C.Briefing_commit partial ->
    (match B.observe ~sources ~contract:(B.contract ~template:p.effective) partial with
     | B.Missing -> ()
     | B.Current _ | B.Stale _ -> Alcotest.fail "partial result published");
    rejected (C.validate_output restored (`Assoc ["briefing",`String " "]))
  | C.Classification_commit _ -> Alcotest.fail "briefing changed domain")

(* Each change below still decodes: the rows, id map, ledger, pass and the
   record's summary agree with it. Only the digest of the prompt that was
   sent tells it apart. *)
let test_a_restore_refuses_a_changed_input_that_still_decodes () = with_workspace (fun root _ ->
  let workspace = get (C.observe_workspace ~base_path:root) in
  let restores_after name ?(summary=Fun.id) edit capture =
    let store = Store.create ~root:(Filename.concat root name) in
    restore store ~workspace (retain ~summary:(summary (summary_of capture)) ~request:(edit (C.to_json capture)) store) in
  let in_batch f capture =
    let work = member "work" capture in
    replace "work" (replace "batch" (f (member "batch" work)) work) capture in
  let rows f = function `List rows -> `List (List.map f rows) | _ -> Alcotest.fail "expected array" in
  let a,_,_,classified = classification ~base_path:root workspace in
  let forged = "Forged source evidence A" in
  let sha text = `String Agent_core_sha256.(digest_string text |> to_hex) in
  let forge_claim batch =
    let input = member "input" batch in
    let claims = rows (fun row ->
        if member "claim" row = `String a.claim then replace "claim" (`String forged) row else row)
        (member "facts" input) in
    let refs = rows (fun row ->
        let fact = member "fact" row in
        if member "claim_sha256" fact = sha a.claim then replace "fact" (replace "claim_sha256" (sha forged) fact) row
        else row) (member "facts" batch) in
    batch |> replace "input" (replace "facts" claims input) |> replace "facts" refs in
  let forge_selected summary = replace "selected" (rows (fun fact ->
      if member "claim_sha256" fact = sha a.claim then replace "claim_sha256" (sha forged) fact else fact)
      (member "selected" summary)) summary in
  ignore (get (restores_after "classification-as-sent" Fun.id classified));
  rejected (restores_after "classification-forged-claim" ~summary:forge_selected (in_batch forge_claim) classified);
  let source id : B.source = {id;kind=B.Claim;text="Uncut evidence " ^ id} in
  let sources = [source "a";source "b";source "c"] in
  let p = prompt "Original briefing: {{workspace_memory_briefing}}" in
  let render = render Prompt_names.workspace_memory_briefing "workspace_memory_briefing" p in
  let prepared state = match get (B.prepare ~sources ~contract:(B.contract ~template:p.effective) ~render state) with
    | B.Prepared batch -> batch
    | B.Unchanged | B.Cleanup _ -> Alcotest.fail "expected briefing work" in
  let partial = get (B.accept (some (get (B.narrow ~render (prepared B.empty)))) ~text:"Partial original summary") in
  let briefed = get (C.briefing ~request_id:id ~workspace ~destination ~prompt:p
      ~batch:(some (get (B.narrow ~render (prepared partial))))) in
  let stored = (retain ~summary:(summary_of briefed) ~request:(C.to_json briefed)
      (Store.create ~root:(Filename.concat root "briefing-stored"))).request in
  Alcotest.(check int) "the stored briefing holds each unconsumed entry once" 1
    (occurrences "Uncut evidence b" (Yojson.Safe.to_string stored));
  let forge_summary batch =
    let state = member "state" batch in
    replace "state" (replace "building" (replace "text" (`String "Forged prior summary") (member "building" state)) state)
      batch in
  let forged_state = member "state" (forge_summary (member "batch" (member "work" (C.to_json briefed)))) in
  let forged_state_sha256 = Workspace_memory_revision.briefing_sha256
      (Workspace_memory_revision.of_briefing (get (B.of_json forged_state))) in
  ignore (get (restores_after "briefing-as-sent" Fun.id briefed));
  rejected (restores_after "briefing-forged-summary"
    ~summary:(replace "prepared_state_sha256" (`String forged_state_sha256)) (in_batch forge_summary) briefed);
  rejected (restores_after "briefing-wider-selection" ~summary:(replace "selected_count" (`Int 2))
    (in_batch (replace "selected_count" (`Int 2))) briefed))

(* The record's summary is what a pass reads without restoring; a capture
   whose summary says something else is refused. *)
let test_a_restore_refuses_a_summary_other_than_its_capture () = with_workspace (fun root _ ->
  let workspace = get (C.observe_workspace ~base_path:root) in
  let restores_with name summary capture =
    let store = Store.create ~root:(Filename.concat root name) in
    restore store ~workspace (retain ~summary ~request:(C.to_json capture) store) in
  let _,_,_,classified = classification ~base_path:root workspace in
  ignore (get (restores_with "classification-as-kept" (summary_of classified) classified));
  rejected (restores_with "classification-other-size" (replace "up_to" (`Int 7) (summary_of classified)) classified);
  rejected (restores_with "classification-no-facts" (replace "selected" (`List []) (summary_of classified)) classified);
  rejected (restores_with "classification-root" (replace "predecessor" (`String (C.Request_id.to_string id))
    (summary_of classified)) classified);
  rejected (restores_with "classification-no-summary" `Null classified);
  let other_schema = replace "schema" (`String "workspace.memory.execution-summary.v0") (summary_of classified) in
  Alcotest.(check bool) "a summary of another schema is refused when read" true
    (Result.is_error (C.Summary.of_json other_schema));
  rejected (restores_with "classification-other-schema" other_schema classified);
  rejected (restores_with "classification-other-workspace"
    (replace "workspace" (`Assoc ["path",`String (Filename.dirname root);"device",`Int 0;"inode",`Int 0])
      (summary_of classified)) classified);
  let source id : B.source = {id;kind=B.Claim;text="Kept evidence " ^ id} in
  let p = prompt "Original briefing: {{workspace_memory_briefing}}" in
  let render = render Prompt_names.workspace_memory_briefing "workspace_memory_briefing" p in
  let briefed = match get (B.prepare ~sources:[source "a";source "b"] ~contract:(B.contract ~template:p.effective)
      ~render B.empty) with
    | B.Prepared batch -> get (C.briefing ~request_id:id ~workspace ~destination ~prompt:p ~batch)
    | B.Unchanged | B.Cleanup _ -> Alcotest.fail "expected briefing work" in
  ignore (get (restores_with "briefing-as-kept" (summary_of briefed) briefed));
  rejected (restores_with "briefing-other-state"
    (replace "prepared_state_sha256" (`String (String.make 64 '0')) (summary_of briefed)) briefed);
  rejected (restores_with "briefing-other-count" (replace "selected_count" (`Int 1) (summary_of briefed)) briefed))

let test_descriptor_scope_refuses_replaced_root_before_return () = with_workspace (fun root _ ->
  let before = Unix.stat root in
  let observed = Fs_compat.with_owned_inventory_root root (fun held ->
    let stat = Fs_compat.owned_inventory_root_stat held in
    Alcotest.(check bool) "getter uses the actual held descriptor observation" true
      (stat.Unix.st_dev=before.st_dev && stat.st_ino=before.st_ino);
    Unix.rename root (root ^ "-original"); Unix.mkdir root 0o700;
    Ok "unpublished candidate") in
  rejected observed)

let test_next_classification_size_follows_the_last_answer () = with_workspace (fun root _store ->
  let module P = Lane_addon_request_progress in
  let workspace = get (C.observe_workspace ~base_path:root) in
  let classify_render = render Prompt_names.workspace_memory_curator "workspace_memory_changes" classification_prompt in
  let facts = List.init 4 (fun i -> fact ("keeper-" ^ string_of_int i) ("Changed fact " ^ string_of_int i)) in
  (* [pending] facts prepared for [size]. *)
  let root_of ?(size=R.Fill_frame) pending =
    let batch = some (requested (R.prepare ~neighbor_limit:0 ~render:classify_render ~ledger:L.empty ~current:facts
        ~pending:(List.take pending facts) ~size ~frame:max_int ~measure:(fun _ -> Ok 0))) in
    get (C.classification ~request_id:(C.Request_id.fresh ()) ~workspace ~destination
           ~prompt:classification_prompt ~ledger:L.empty ~stored_ledger:(stored_ledger root L.empty) ~batch) in
  let commit : P.commit = {judgment=`Null;change={before=`Null;after=`Null}} in
  let refusal : P.refusal = {stage=P.Execution;evidence=`Null} in
  (* What a pass reads: each original's ID, summary and phase. *)
  let classification_size originals = C.classification_size
      (List.map (fun (capture, phase) -> C.request_id capture, get (C.summary capture), phase) originals) in
  let size = Alcotest.testable (fun format -> function
      | R.Fill_frame -> Format.pp_print_string format "Fill_frame"
      | R.Up_to count -> Format.fprintf format "Up_to %d" count) ( = ) in
  Alcotest.check size "no answered classification fills the frame" R.Fill_frame (classification_size []);
  Alcotest.check size "a root the frame bounded keeps filling the frame" R.Fill_frame
    (classification_size [root_of 3,P.Finished commit]);
  let older = root_of ~size:(R.Up_to 3) 3 in
  Alcotest.check size "a root that held its size tries twice that size" (R.Up_to 6)
    (classification_size [older,P.Finished commit]);
  Alcotest.check size "a root a short backlog stopped keeps its size" (R.Up_to 4)
    (classification_size [root_of ~size:(R.Up_to 4) 1,P.Finished commit]);
  let parent = root_of ~size:(R.Up_to 4) 4 in
  let child = some (get (C.narrow ~request_id:(C.Request_id.fresh ())
      ~final:(Lane_addon_exact.Call_final (Input_refused Input_capacity)) parent)) in
  let link : P.successor = {request_id=C.Request_id.to_string (C.request_id child);
    request_digest=get (Owner.request_digest (C.to_json child))} in
  Alcotest.check size "a child answered after a size refusal keeps its count" (R.Up_to 2)
    (classification_size [older,P.Finished commit;parent,P.Subdivided (refusal,link);
                            child,P.Conflicted (commit,`Null)]);
  Alcotest.check size "the latest answer decides, whatever the list order" (R.Up_to 2)
    (classification_size [child,P.Finished commit;older,P.Finished commit]);
  (* Were it evidence, this later root would double its three facts. *)
  let refused = root_of ~size:(R.Up_to 3) 3 in
  let source id : B.source = {id;kind=B.Claim;text="Briefing evidence " ^ id} in
  let briefing_prompt = prompt "Original briefing: {{workspace_memory_briefing}}" in
  let briefing_render = render Prompt_names.workspace_memory_briefing "workspace_memory_briefing" briefing_prompt in
  let briefing = match get (B.prepare ~sources:[source "a"] ~contract:(B.contract ~template:briefing_prompt.effective)
      ~render:briefing_render B.empty) with
    | B.Prepared batch -> get (C.briefing ~request_id:(C.Request_id.fresh ()) ~workspace ~destination
                                 ~prompt:briefing_prompt ~batch)
    | B.Unchanged | B.Cleanup _ -> Alcotest.fail "expected a briefing pass" in
  Alcotest.check size "refused classifications and answered briefings are not evidence" (R.Up_to 2)
    (classification_size [child,P.Finished commit;refused,P.Rejected refusal;briefing,P.Finished commit]))

(* The last millisecond of 2026-10-22 and the first of 2026-10-23, UTC. *)
let test_an_id_is_minted_on_the_utc_day_of_its_timestamp () =
  let day id = get (C.Request_id.minted_on (get (C.Request_id.of_string id))) in
  Alcotest.(check string) "the last millisecond of a day" "2026-10-22" (day "01a1660e-abff-7000-8000-000000000000");
  Alcotest.(check string) "the first millisecond of the next" "2026-10-23" (day "01a1660e-ac00-7000-8000-000000000000")

let test_settled_chains_are_the_ones_no_pass_reads () = with_workspace (fun root store ->
  let module P = Lane_addon_request_progress in
  let module Receipt = Lane_addon_request_receipt in
  let workspace = get (C.observe_workspace ~base_path:root) in
  let classify_render = render Prompt_names.workspace_memory_curator "workspace_memory_changes" classification_prompt in
  let facts = List.init 2 (fun i -> fact "writer" ("Settled source " ^ string_of_int i)) in
  let classification () =
    let batch = some (requested (R.prepare ~neighbor_limit:0 ~render:classify_render ~ledger:L.empty ~current:facts
        ~pending:facts ~size:R.Fill_frame ~frame:max_int ~measure:(fun _ -> Ok 0))) in
    get (C.classification ~request_id:(C.Request_id.fresh ()) ~workspace ~destination
           ~prompt:classification_prompt ~ledger:L.empty ~stored_ledger:(stored_ledger root L.empty) ~batch) in
  let advance record event =
    match get (Result.map_error Owner.update_error_to_string (Owner.advance ~store ~expected:record ~event)) with
    | Owner.Stored record -> record
    | Owner.Already_stored _ | Owner.Unconfirmed _ -> Alcotest.fail "fixture fact was not stored" in
  (* Retain [capture] and record [events] after it. *)
  let original capture events =
    let request_id = C.Request_id.to_string (C.request_id capture) in
    owned (Owner.retain ~store ~scope:C.scope ~request_id ~installation_id:destination.installation_id
      ~package_id:destination.package_id ~tool:destination.tool ~summary:(summary_of capture)
      ~request:(C.to_json capture));
    ignore (List.fold_left advance (some (owned (Owner.load ~store ~scope:C.scope ~request_id))) events);
    request_id in
  let receipt stage = get (Receipt.make ~observed_at:1. ~payload:(`Assoc ["stage",`String stage])) in
  let registration = receipt "registration" and completion = receipt "completion" in
  let registered = [P.Observer (Receipt.Intended (Receipt.Registration,registration));
                    P.Observer (Receipt.Recorded (Receipt.Registration,registration.Receipt.digest))] in
  let completion_intended = P.Observer (Receipt.Intended (Receipt.Completion,completion)) in
  let observed = registered @ [completion_intended;
                               P.Observer (Receipt.Recorded (Receipt.Completion,completion.Receipt.digest))] in
  let change : P.change = {before=`Null;after=`Assoc ["committed",`Bool true]} in
  let finished = [P.Dispatch_intended;P.Judgment_retained `Null;P.Commit_intended change;P.Commit_observed change.after] in
  let refused = [P.Dispatch_intended;P.Refused {stage=P.Execution;
    evidence=Lane_addon_exact.retained_final_to_json
      (Lane_addon_exact.Retained_not_allowed {reason="original fixture refusal"})}] in
  let unknown cause = [P.Dispatch_intended;P.Refused {stage=P.Execution;
    evidence=Lane_addon_exact.retained_final_to_json (Lane_addon_exact.Retained_unknown cause)}] in
  (* Minted in this order, so [latest] is the last answered classification. *)
  let older = original (classification ()) (finished @ observed) in
  let parent_capture = classification () in
  let child_capture = some (get (C.narrow ~request_id:(C.Request_id.fresh ())
      ~final:(Lane_addon_exact.Call_final (Input_refused Input_capacity)) parent_capture)) in
  let child_id = C.Request_id.to_string (C.request_id child_capture) in
  let link : P.successor = {request_id=child_id;request_digest=get (Owner.request_digest (C.to_json child_capture))} in
  let parent = original parent_capture
      (refused @ [P.Successor_intended link;P.Successor_observed child_id] @ observed) in
  let child = original child_capture (finished @ observed) in
  let unobserved = original (classification ()) (finished @ registered @ [completion_intended]) in
  let fenced = original (classification ()) (refused @ observed) in
  let interrupted = original (classification ()) (unknown Lane_addon_exact.Interrupted @ observed) in
  let interrupted_unobserved = original (classification ())
      (unknown Lane_addon_exact.Interrupted @ registered @ [completion_intended]) in
  let cut = original (classification ()) (unknown Lane_addon_exact.Cut @ observed) in
  let raised = original (classification ()) (unknown Lane_addon_exact.Raised @ observed) in
  let conflicted = original (classification ())
      ([P.Dispatch_intended;P.Judgment_retained `Null;P.Commit_intended change;
        P.Commit_conflicted (`Assoc ["changed",`Bool true])] @ observed) in
  (* Its leaf is observed, but its parent still has a completion to record. *)
  let pending_parent_capture = classification () in
  let pending_child_capture = some (get (C.narrow ~request_id:(C.Request_id.fresh ())
      ~final:(Lane_addon_exact.Call_final (Input_refused Input_capacity)) pending_parent_capture)) in
  let pending_child_id = C.Request_id.to_string (C.request_id pending_child_capture) in
  let pending_link : P.successor = {request_id=pending_child_id;
    request_digest=get (Owner.request_digest (C.to_json pending_child_capture))} in
  let pending_parent = original pending_parent_capture
      (refused @ [P.Successor_intended pending_link;P.Successor_observed pending_child_id] @ registered
       @ [completion_intended]) in
  let pending_child = original pending_child_capture (finished @ observed) in
  let latest = original (classification ()) (finished @ observed) in
  let briefing_prompt = prompt "Original briefing: {{workspace_memory_briefing}}" in
  let briefing_render = render Prompt_names.workspace_memory_briefing "workspace_memory_briefing" briefing_prompt in
  let source : B.source = {id="a";kind=B.Claim;text="Briefing evidence a"} in
  let batch = match get (B.prepare ~sources:[source] ~contract:(B.contract ~template:briefing_prompt.effective)
      ~render:briefing_render B.empty) with
    | B.Prepared batch -> batch
    | B.Unchanged | B.Cleanup _ -> Alcotest.fail "expected a briefing pass" in
  let briefing_capture () = get (C.briefing ~request_id:(C.Request_id.fresh ()) ~workspace ~destination
      ~prompt:briefing_prompt ~batch) in
  let briefing = original (briefing_capture ()) (finished @ observed) in
  let interrupted_briefing = original (briefing_capture ()) (unknown Lane_addon_exact.Interrupted @ observed) in
  let cut_briefing = original (briefing_capture ()) (unknown Lane_addon_exact.Cut @ observed) in
  let raised_briefing = original (briefing_capture ()) (unknown Lane_addon_exact.Raised @ observed) in
  let records = owned (Owner.discover ~store ~scope:C.scope)
    |> List.map (fun record -> record,get (C.Summary.of_json (Owner.Record.summary record))) in
  let settled settling = get (C.settled_chains settling records)
    |> List.map (fun (root,leaf_first) -> C.Request_id.to_string root,List.map Owner.Record.request_id leaf_first)
    |> List.sort compare in
  let chains = Alcotest.(list (pair string (list string))) in
  let kept settling =
    let moved = List.concat_map snd (settled settling) in
    List.filter_map (fun (record,_) -> let id = Owner.Record.request_id record in
      if List.mem id moved then None else Some id) records |> List.sort compare in
  Alcotest.check chains "older answered chains settle, each leaf first, a conflicted one too"
    (List.sort compare [older,[older];parent,[child;parent];conflicted,[conflicted];interrupted,[interrupted]])
    (settled C.Classifications);
  Alcotest.(check (list string))
    "the latest answer, a pending receipt anywhere in a chain, a refusal and every Briefing stay"
    (List.sort compare [unobserved;fenced;pending_parent;pending_child;latest;briefing;
      interrupted_unobserved;cut;raised;interrupted_briefing;cut_briefing;raised_briefing]) (kept C.Classifications);
  let prepared = Workspace_memory_revision.briefing_sha256
      (Workspace_memory_revision.of_briefing (B.prepared_state batch)) in
  Alcotest.check chains "Interrupted releases the current Briefing pass, Cut and Raised stay"
    [interrupted_briefing,[interrupted_briefing]] (settled (C.Briefings {state=prepared}));
  Alcotest.check chains "a Briefing that prepared another state settles, and only Briefing chains do"
    (List.sort compare [briefing,[briefing];interrupted_briefing,[interrupted_briefing]])
    (settled (C.Briefings {state=String.make 64 '0'}));
  (* An old cause-free refusal has no policy interpretation or cleanup grant. *)
  let _old = original (classification ()) [P.Dispatch_intended;
    P.Refused {stage=P.Execution;evidence=Lane_addon_exact.final_to_json Lane_addon_exact.Outcome_unknown}] in
  let invalid = owned (Owner.discover ~store ~scope:C.scope)
    |> List.map (fun record -> record,get (C.Summary.of_json (Owner.Record.summary record))) in
  rejected (C.settled_chains C.Classifications invalid))

let unrelated_ledger text =
  let claim = fact "unrelated" "Unrelated source" in
  let fact = match claim.fact with
    | L.Ordinary {keeper_id;claim_sha256} -> `Assoc ["keeper_id",`String keeper_id;
        "store",`String "ordinary";"claim_sha256",`String claim_sha256;
        "disposition",`Assoc ["kind",`String "claim";"claim_id",`String "c1"]]
    | L.Source_bound _ -> Alcotest.fail "ordinary fixture" in
  get (L.of_json (`Assoc ["schema",`String "workspace.memory.ledger.v1";
    "claims",`List [`Assoc ["claim_id",`String "c1";"claim",`String text]];
    "conflicts",`List [];"facts",`List [fact]]))
let capture_revision capture = member "work" (C.to_json capture) |> member "ledger_revision"
let ledger_file root capture =
  let digest = member "sha256" (capture_revision capture) |> Yojson.Safe.Util.to_string in
  Filename.concat (Filename.concat (L.directory ~base_path:root) "revisions/ledger") (digest ^ ".json")

let test_capture_and_child_share_the_written_revision () = with_workspace (fun root store ->
  let workspace = get (C.observe_workspace ~base_path:root) in
  let text = String.make 100_000 'z' in
  let ledger = unrelated_ledger text in
  let _,_,_,original = classification ~ledger ~narrowed:false ~base_path:root workspace in
  let _,_,_,again = classification ~ledger ~narrowed:false ~request_id:(C.Request_id.fresh ()) ~base_path:root workspace in
  let _,_,_,small = classification ~narrowed:false ~base_path:root workspace in
  let bytes capture = Yojson.Safe.to_string (C.to_json capture) in
  Alcotest.(check int) "unselected ledger size adds no capture bytes"
    (String.length (bytes small)) (String.length (bytes original));
  Alcotest.(check int) "the complete unrelated claim is absent" 0 (occurrences text (bytes original));
  Alcotest.check json "two originals name the same revision" (capture_revision original) (capture_revision again);
  Alcotest.(check bool) "no inline ledger field" true (member "ledger" (member "work" (C.to_json original))=`Null);
  let file = ledger_file root original in
  Alcotest.check json "the named file holds the full typed ledger" (L.to_json ledger)
    (In_channel.with_open_bin file (fun channel -> Yojson.Safe.from_string (In_channel.input_all channel)));
  get (L.save ~base_path:root L.empty);
  let retained = retain ~summary:(summary_of original) ~request:(C.to_json original) store in
  let restored = get (restore store ~workspace retained) in
  (match C.work restored with
   | C.Classification {ledger=before;_} -> Alcotest.check json "restore uses the old revision" (L.to_json ledger) (L.to_json before)
   | C.Briefing _ -> Alcotest.fail "classification expected");
  let child_id = C.Request_id.fresh () in
  let narrow capture = some (get (C.narrow ~request_id:child_id
      ~final:(Lane_addon_exact.Call_final (Input_refused Input_capacity)) capture)) in
  let child = narrow restored in
  Alcotest.check json "fresh and restored originals derive identical children" (C.to_json (narrow original)) (C.to_json child);
  Alcotest.check json "child keeps its parent's revision" (capture_revision original) (capture_revision child);
  Alcotest.(check (list string)) "the two ledger states each have one file"
    (List.sort String.compare [Filename.basename file;Filename.basename (ledger_file root small)])
    (Array.to_list (Sys.readdir (Filename.dirname file)) |> List.sort String.compare))

let test_restore_never_substitutes_a_missing_or_damaged_revision () = with_workspace (fun root store ->
  let workspace = get (C.observe_workspace ~base_path:root) in
  let _,_,_,capture = classification ~base_path:root workspace in
  let retained = retain ~summary:(summary_of capture) ~request:(C.to_json capture) store in
  get (L.save ~base_path:root L.empty);
  let file = ledger_file root capture in
  let digest = member "sha256" (capture_revision capture) |> Yojson.Safe.Util.to_string in
  let refuses name = match restore store ~workspace retained with
    | Ok _ -> Alcotest.fail (name ^ " revision restored")
    | Error detail ->
      Alcotest.(check bool) (name ^ " names the original") true (occurrences (C.Request_id.to_string id) detail > 0);
      Alcotest.(check bool) (name ^ " names the revision") true (occurrences digest detail > 0) in
  Sys.remove file; refuses "missing";
  Out_channel.with_open_bin file (fun channel -> output_string channel "{}"); refuses "damaged";
  Sys.remove file;
  Unix.symlink (Filename.concat (L.directory ~base_path:root) "ledger.json") file;
  refuses "unreadable symbolic link")

let test_constructor_requires_the_same_workspace_and_state_receipt () = with_workspace (fun root _ ->
  let workspace = get (C.observe_workspace ~base_path:root) in
  let _,_,batch,_ = classification ~base_path:root workspace in
  let make stored_ledger = C.classification ~request_id:id ~workspace ~destination
    ~prompt:classification_prompt ~ledger:L.empty ~stored_ledger ~batch in
  rejected (make (stored_ledger root (unrelated_ledger "A different typed state")));
  let other = Filename.concat root "another-workspace" in Unix.mkdir other 0o700;
  rejected (make (stored_ledger other L.empty));
  let written = stored_ledger root L.empty in
  Unix.rename root (root ^ "-old"); Unix.mkdir root 0o700;
  rejected (C.classification ~request_id:id ~workspace:(get (C.observe_workspace ~base_path:root)) ~destination
    ~prompt:classification_prompt ~ledger:L.empty ~stored_ledger:written ~batch))

let test_revision_shape_is_strict_without_inline_ledger_fallback () = with_workspace (fun root _ ->
  let workspace = get (C.observe_workspace ~base_path:root) in
  let _,_,_,capture = classification ~base_path:root workspace in
  let original = C.to_json capture in
  let work = member "work" original in
  let old_store = Store.create ~root:(Filename.concat root "old-inline-envelope") in
  rejected (restore old_store ~workspace
    (retain ~summary:(summary_of capture)
      ~request:(replace "schema" (`String "workspace.memory.execution-capture.v3") original) old_store));
  let inline = match work with `Assoc fields -> `Assoc (("ledger",L.to_json L.empty)::List.remove_assoc "ledger_revision" fields)
    | _ -> Alcotest.fail "work object" in
  let mixed = match work with `Assoc fields -> `Assoc (("ledger",L.to_json L.empty)::fields)
    | _ -> Alcotest.fail "work object" in
  let wrong_kind = replace "ledger_revision"
      (Revision.to_json (Revision.Briefing (Revision.of_briefing B.empty))) work in
  List.iteri (fun i changed ->
    let store = Store.create ~root:(Filename.concat root ("strict-" ^ string_of_int i)) in
    rejected (restore store ~workspace
      (retain ~summary:(summary_of capture) ~request:(replace "work" changed original) store))) [inline;mixed;wrong_kind])

let () = Alcotest.run "Curator trusted host capture" ["capture",[
  Alcotest.test_case "capture and child share the written revision" `Quick test_capture_and_child_share_the_written_revision;
  Alcotest.test_case "no substitution for missing, damaged or unreadable revision" `Quick test_restore_never_substitutes_a_missing_or_damaged_revision;
  Alcotest.test_case "constructor binds the write receipt to workspace and state" `Quick test_constructor_requires_the_same_workspace_and_state_receipt;
  Alcotest.test_case "strict revision shape without inline fallback" `Quick test_revision_shape_is_strict_without_inline_ledger_fallback;
  Alcotest.test_case "canonical storage preserves exact original prompt and judgment" `Quick test_canonical_storage_preserves_original_prompt_and_selected_judgment;
  Alcotest.test_case "changed provenance, schema and original owner" `Quick test_changed_capture_provenance_and_owner_are_refused;
  Alcotest.test_case "physical root copy and replacement" `Quick test_physical_root_replacement_and_copy_are_refused;
  Alcotest.test_case "briefing original contract and partial publication" `Quick test_briefing_contract_and_partial_publication_are_original;
  Alcotest.test_case "a changed input that still decodes" `Quick test_a_restore_refuses_a_changed_input_that_still_decodes;
  Alcotest.test_case "a summary other than its capture" `Quick test_a_restore_refuses_a_summary_other_than_its_capture;
  Alcotest.test_case "descriptor scope rejects a replaced root" `Quick test_descriptor_scope_refuses_replaced_root_before_return;
  Alcotest.test_case "next classification size follows the last answer" `Quick
    test_next_classification_size_follows_the_last_answer;
  Alcotest.test_case "settled chains are the ones no pass reads" `Quick
    test_settled_chains_are_the_ones_no_pass_reads;
  Alcotest.test_case "an ID is minted on the UTC day of its timestamp" `Quick
    test_an_id_is_minted_on_the_utc_day_of_its_timestamp]]
