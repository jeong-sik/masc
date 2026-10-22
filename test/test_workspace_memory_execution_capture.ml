open Masc
module C = Workspace_memory_execution_capture
module L = Workspace_memory_ledger
module R = Workspace_memory_request
module B = Workspace_memory_briefing
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
  {fact=L.Ordinary {keeper_id=keeper;claim_sha256=Digestif.SHA256.(digest_string claim |> to_hex)};claim}
let classification workspace =
  let a = fact "writer" "Complete source evidence A" and b = fact "writer" "Complete source evidence B" in
  let render = render Prompt_names.workspace_memory_curator "workspace_memory_changes" classification_prompt in
  let full = some (requested (R.prepare ~neighbor_limit:0 ~render ~ledger:L.empty ~current:[a;b] ~pending:[a;b])) in
  let batch = some (requested (R.narrow ~render full)) in
  a,b,batch,get (C.classification ~request_id:id ~workspace ~destination ~prompt:classification_prompt ~ledger:L.empty ~batch)
let retain ?(scope=C.scope) ?(installation_id=destination.installation_id) ?(tool=destination.tool)
    ~request store =
  let request_id = C.Request_id.to_string id in
  owned (Owner.retain ~store ~scope ~request_id ~installation_id ~package_id:destination.package_id ~tool ~request);
  some (owned (Owner.load ~store:(Store.create ~root:(Store.root store)) ~scope ~request_id))
let rejected = function Error _ -> () | Ok _ -> Alcotest.fail "invalid host capture accepted"

let test_canonical_storage_preserves_original_prompt_and_selected_judgment () = with_workspace (fun root store ->
  let workspace = get (C.observe_workspace ~base_path:root) in
  let a,b,batch,capture = classification workspace in
  let retained = retain ~request:(C.to_json capture) store in
  let restored = get (C.restore ~workspace:(get (C.observe_workspace ~base_path:root)) retained) in
  Alcotest.(check string) "original substitution bytes survive canonical object ordering"
    (Yojson.Safe.to_string batch.input) (C.input_text restored);
  Alcotest.(check string) "actual original prompt is restored" batch.rendered_prompt (C.rendered_prompt restored);
  Alcotest.check json "schema preserved" Workspace_memory_decision.output_schema (C.output_schema restored);
  let answer = `Assoc ["decisions", `List [`Assoc ["fact_id",`String (R.fact_id a.fact);
    "kind",`String "create_claim";"value",`String "A source-attributed interpretation"]]] in
  (match get (C.validate_output restored answer) with
   | C.Classification_commit ledger ->
     Alcotest.(check bool) "only selected fact has an expected disposition" true
       (List.map fst (L.dispositions ledger) = [a.fact]);
     (match C.work restored with
      | C.Classification {batch;_} -> Alcotest.(check bool) "original suffix retained" true (batch.remaining=[b])
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
      batch.rendered_prompt (C.rendered_prompt (get (C.restore ~workspace retained)))))

let test_changed_capture_provenance_and_owner_are_refused () = with_workspace (fun root _ ->
  let workspace = get (C.observe_workspace ~base_path:root) in
  let _,_,batch,capture = classification workspace in
  rejected (C.classification ~request_id:id ~workspace ~destination ~ledger:L.empty ~batch
    ~prompt:(prompt "Different initial template: {{workspace_memory_changes}}"));
  rejected (C.classification ~request_id:id ~workspace ~destination ~ledger:L.empty ~batch
    ~prompt:{classification_prompt with file_path=Some ""});
  let original = C.to_json capture in
  let canonical_input = get (Lane_addon_action.canonical batch.input) |> Yojson.Safe.to_string in
  Alcotest.(check bool) "fixture exercises canonical key reordering" true
    (canonical_input <> Yojson.Safe.to_string batch.input);
  let changed_prompt = member "prompt" original
    |> replace "effective" (`String "Other template: {{workspace_memory_changes}}")
    |> replace "override_value" (`String "Other template: {{workspace_memory_changes}}") in
  let invalid = [replace "input_text" (`String canonical_input) original;
    replace "input_text" (`String "{\"new_facts\":[]}") original;
    replace "prompt" changed_prompt original;
    replace "prompt" (replace "has_override" (`Bool false) (member "prompt" original)) original;
    replace "output_schema" (`Assoc ["type",`String "string"]) original;
    replace "destination" (replace "installation_id" (`String "other") (member "destination" original)) original;
    replace "request_id" (`String "019c0000-0000-7000-8000-000000000002") original] in
  List.iteri (fun i request ->
    let store = Store.create ~root:(Filename.concat root ("invalid-" ^ string_of_int i)) in
    rejected (C.restore ~workspace (retain ~request store))) invalid;
  let wrong_scope = Store.create ~root:(Filename.concat root "wrong-scope") in
  rejected (C.restore ~workspace (retain ~scope:"different-consumer" ~request:original wrong_scope));
  let wrong_tool = Store.create ~root:(Filename.concat root "wrong-tool") in
  rejected (C.restore ~workspace (retain ~tool:"different" ~request:original wrong_tool)))

let test_physical_root_replacement_and_copy_are_refused () = with_workspace (fun root store ->
  let workspace = get (C.observe_workspace ~base_path:root) in
  let _,_,_,capture = classification workspace in
  let retained = retain ~request:(C.to_json capture) store in
  let other = Filename.concat (Filename.dirname root) "other-workspace" in Unix.mkdir other 0o700;
  let copy = retain ~request:retained.request (Store.create ~root:(Filename.concat other "store")) in
  rejected (C.restore ~workspace:(get (C.observe_workspace ~base_path:other)) copy);
  let moved = root ^ "-original" in
  Unix.rename root moved; Unix.mkdir root 0o700;
  rejected (C.restore ~workspace:(get (C.observe_workspace ~base_path:root)) retained);
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
  let restored = get (C.restore ~workspace (retain ~request:(C.to_json capture) store)) in
  match get (C.validate_output restored (`Assoc ["briefing",`String "Partial original summary"])) with
  | C.Briefing_commit partial ->
    (match B.observe ~sources ~contract:(B.contract ~template:p.effective) partial with
     | B.Missing -> ()
     | B.Current _ | B.Stale _ -> Alcotest.fail "partial result published");
    rejected (C.validate_output restored (`Assoc ["briefing",`String " "]))
  | C.Classification_commit _ -> Alcotest.fail "briefing changed domain")

let test_descriptor_scope_refuses_replaced_root_before_return () = with_workspace (fun root _ ->
  let before = Unix.stat root in
  let observed = Fs_compat.with_owned_inventory_root root (fun held ->
    let stat = Fs_compat.owned_inventory_root_stat held in
    Alcotest.(check bool) "getter uses the actual held descriptor observation" true
      (stat.Unix.st_dev=before.st_dev && stat.st_ino=before.st_ino);
    Unix.rename root (root ^ "-original"); Unix.mkdir root 0o700;
    Ok "unpublished candidate") in
  rejected observed)

let () = Alcotest.run "Curator trusted host capture" ["capture",[
  Alcotest.test_case "canonical storage preserves exact original prompt and judgment" `Quick test_canonical_storage_preserves_original_prompt_and_selected_judgment;
  Alcotest.test_case "changed provenance, schema and original owner" `Quick test_changed_capture_provenance_and_owner_are_refused;
  Alcotest.test_case "physical root copy and replacement" `Quick test_physical_root_replacement_and_copy_are_refused;
  Alcotest.test_case "briefing original contract and partial publication" `Quick test_briefing_contract_and_partial_publication_are_original;
  Alcotest.test_case "descriptor scope rejects a replaced root" `Quick test_descriptor_scope_refuses_replaced_root_before_return]]
