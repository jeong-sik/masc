(* RFC-0491 §3.2: a keeper's System keeps the articles it was rendered with
   while the carried range keeps its front, and the articles written or taken
   back since then ride the end context. These cases pin the rule over plain
   values: where the range opens, which articles render the System, and what
   the amendments name. *)

open Masc
module Render = World_constitution_render
module Types = World_constitution_types
module System = Keeper_turn_system

let repo_source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()
;;

(* The amendments block renders a registry slot, so resolution points at the
   repository's own prompt files. *)
let () =
  Prompt_registry.set_markdown_dir (Filename.concat (repo_source_root ()) "config/prompts");
  Prompt_defaults.init ()
;;

let contains ~sub text =
  let n = String.length text
  and m = String.length sub in
  let rec scan i = i + m <= n && (String.equal (String.sub text i m) sub || scan (i + 1)) in
  scan 0
;;

let article text =
  match
    Types.make ~id:(Types.Article_id.generate ()) ~text ~author:"lane-smith" ~at:1.0
      ~evidence:[]
  with
  | Ok article -> article
  | Error invalid -> Alcotest.failf "article rejected: %s" (Types.invalid_to_string invalid)
;;

let render articles = "<identity>keeper</identity>\n" ^ Render.articles articles
let render_with_other_instructions articles = "<identity>other</identity>\n" ^ Render.articles articles

let seed ~first_atom front : Keeper_carried_front.seed =
  { first_atom; front; source = Keeper_carried_front.Ledger }
;;

let front_name = function
  | System.Same_front -> "same"
  | System.Moved_front -> "moved"
  | System.No_previous_request -> "none"
;;

let check_front label expected actual =
  Alcotest.(check string) label (front_name expected) (front_name actual)
;;

(* Atom [i] opens with digest ["d<i>"]; atoms past 5 do not exist. *)
let digest_at atom = if atom >= 0 && atom < 6 then Some (Printf.sprintf "d%d" atom) else None

let test_the_front_is_the_same_only_at_the_same_atom_and_message () =
  let previous = Some (seed ~first_atom:2 (Model_input_front.At_atom "d2")) in
  check_front "same atom, same opening message" System.Same_front
    (System.front ~digest_at ~first_atom:2 ~previous);
  check_front "another atom" System.Moved_front (System.front ~digest_at ~first_atom:3 ~previous);
  check_front "another atom opened by an identical message" System.Moved_front
    (System.front ~digest_at:(fun _ -> Some "d2") ~first_atom:3 ~previous);
  check_front "the message at the atom changed" System.Moved_front
    (System.front ~digest_at:(fun _ -> Some "rewritten") ~first_atom:2 ~previous);
  check_front "an omitted history is not an opened atom" System.Moved_front
    (System.front ~digest_at ~first_atom:2
       ~previous:(Some (seed ~first_atom:2 (Model_input_front.After_history "d2"))));
  check_front "no previous request" System.No_previous_request
    (System.front ~digest_at ~first_atom:2 ~previous:None)
;;

(* An in-memory ledger: each article list read is a position, and reading a
   position back gives the list. *)
let ledger_reads : (string, Types.t list) Hashtbl.t = Hashtbl.create 8

let at_of articles : World_constitution_store.position =
  let digest = String.concat "," (List.map (fun (a : Types.t) -> Types.Article_id.to_string a.id) articles) in
  Hashtbl.replace ledger_reads digest articles;
  { end_offset = List.length articles; digest }
;;

let articles_at (position : World_constitution_store.position) =
  Ok (Hashtbl.find_opt ledger_reads position.digest)
;;

let basis_of ~render current = System.basis ~articles:current ~at:(at_of current) ~system:(render current)

(* (a) An article written while the front holds: the System is the bytes the
   basis rendered, and the amendments carry the new article. *)
let test_an_added_article_keeps_the_system_and_names_the_article () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let basis = basis_of ~render [ kept ] in
  match
    System.decide ~front:System.Same_front ~basis:(Some basis) ~render
      ~current:[ kept; written ]
  with
  | System.From_current _ -> Alcotest.fail "a held front keeps the basis"
  | System.From_basis { text; amendments; basis = _ } ->
    Alcotest.(check string) "the System is the basis rendering" (render [ kept ]) text;
    (match amendments with
     | None -> Alcotest.fail "the written article is an amendment"
     | Some amendments ->
       Alcotest.(check string) "the amendment is the written article's line"
         (Render.articles [ written ]) (Render.added_lines amendments);
       Alcotest.(check string) "nothing was taken back" "" (Render.removed_lines amendments))
;;

let test_the_same_articles_keep_the_system_with_no_amendments () =
  let kept = article "open before you record" in
  let basis = basis_of ~render [ kept ] in
  match System.decide ~front:System.Same_front ~basis:(Some basis) ~render ~current:[ kept ] with
  | System.From_current _ -> Alcotest.fail "a held front keeps the basis"
  | System.From_basis { text; amendments; basis = _ } ->
    Alcotest.(check string) "the System is unchanged" (render [ kept ]) text;
    Alcotest.(check bool) "no amendments" true (Option.is_none amendments)
;;

let expect_current label ~current = function
  | System.From_current { text; _ } ->
    Alcotest.(check string) label (render current) text
  | System.From_basis _ -> Alcotest.failf "%s: the System is rendered with the current articles" label
;;

(* (b) A moved front loses the history cache anyway, so the System takes the
   current articles. *)
let test_a_moved_front_renders_the_current_articles () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let basis = basis_of ~render [ kept ] in
  let current = [ kept; written ] in
  expect_current "moved front" ~current
    (System.decide ~front:System.Moved_front ~basis:(Some basis) ~render ~current);
  expect_current "no previous request" ~current
    (System.decide ~front:System.No_previous_request ~basis:(Some basis) ~render ~current)
;;

(* (c) Instructions edited since the basis: the basis no longer renders to
   the bytes it recorded, so the System is rebuilt with the current
   articles. *)
let test_changed_instructions_rebuild_the_system () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let basis = basis_of ~render [ kept ] in
  let current = [ kept; written ] in
  match
    System.decide ~front:System.Same_front ~basis:(Some basis)
      ~render:render_with_other_instructions ~current
  with
  | System.From_basis _ -> Alcotest.fail "a basis that renders other bytes is not kept"
  | System.From_current { text; _ } ->
    Alcotest.(check string) "rebuilt with the new instructions and current articles"
      (render_with_other_instructions current) text
;;

(* (d) No basis yet. *)
let test_no_basis_renders_the_current_articles () =
  let current = [ article "open before you record" ] in
  expect_current "no basis" ~current
    (System.decide ~front:System.Same_front ~basis:None ~render ~current)
;;

(* (e) A taken-back article stays in the System; its id is the amendment. *)
let test_a_removed_article_is_named_by_its_id () =
  let kept = article "open before you record" in
  let taken_back = article "cite the ledger row, not the frame" in
  let basis = basis_of ~render [ kept; taken_back ] in
  match System.decide ~front:System.Same_front ~basis:(Some basis) ~render ~current:[ kept ] with
  | System.From_current _ -> Alcotest.fail "a held front keeps the basis"
  | System.From_basis { text; amendments; basis = _ } ->
    Alcotest.(check string) "the System still holds the taken-back article"
      (render [ kept; taken_back ]) text;
    (match amendments with
     | None -> Alcotest.fail "a taken-back article is an amendment"
     | Some amendments ->
       Alcotest.(check string) "its id"
         (Printf.sprintf "- [%s]" (Types.Article_id.to_string taken_back.id))
         (Render.removed_lines amendments);
       Alcotest.(check string) "nothing was added" "" (Render.added_lines amendments))
;;

let agent_core ?(runtime_id = "fixture.agent") front = System.Agent_core { runtime_id; front }

let ok = function
  | Ok value -> value
  | Error () -> Alcotest.fail "the in-memory ledger does not fail"
;;

let issue ?held ~lane current =
  ok (System.issue ~held ~lane ~render ~current ~at:(at_of current) ~articles_at)
;;

let resend ~held ~runtime_id ~current recorded =
  ok (System.resend ~held ~runtime_id ~current ~articles_at recorded)
;;

(* A session's checkpoint carries what the first turn issued; the next turn
   with a held front sends the same bytes and the block. *)
let test_a_later_turn_sends_the_stored_basis_and_the_block () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let first, held = issue ~lane:(agent_core System.No_previous_request) [ kept ] in
  Alcotest.(check bool) "the first System has no amendments" true (Option.is_none first.amendments);
  let next, (_ : System.held) = issue ~held ~lane:(agent_core System.Same_front) [ kept; written ] in
  Alcotest.(check string) "the System bytes are the first turn's" first.text next.text;
  match next.amendments with
  | None -> Alcotest.fail "the written article rides the end context"
  | Some block ->
    Alcotest.(check bool) "the block holds the written article's line" true
      (contains ~sub:(Render.articles [ written ]) block);
    Alcotest.(check bool) "the block does not repeat the kept article" false
      (contains ~sub:(Types.Article_id.to_string kept.id) block)
;;

let test_a_moved_front_replaces_the_basis () =
  let first_article = article "open before you record" in
  let second_article = article "cite the ledger row, not the frame" in
  let third_article = article "name the file you read" in
  let (_ : System.t), held = issue ~lane:(agent_core System.No_previous_request) [ first_article ] in
  let moved, held =
    issue ~held ~lane:(agent_core System.Moved_front) [ first_article; second_article ]
  in
  Alcotest.(check string) "the moved front renders the current articles"
    (render [ first_article; second_article ]) moved.text;
  let next, (_ : System.held) =
    issue ~held ~lane:(agent_core System.Same_front)
      [ first_article; second_article; third_article ]
  in
  Alcotest.(check string) "the next held front keeps the moved turn's System" moved.text next.text;
  match next.amendments with
  | None -> Alcotest.fail "the third article rides the end context"
  | Some block ->
    Alcotest.(check bool) "only the article written after the moved turn" false
      (contains ~sub:(Types.Article_id.to_string second_article.id) block);
    Alcotest.(check bool) "the third article is named" true
      (contains ~sub:(Types.Article_id.to_string third_article.id) block)
;;

(* The front is compared per runtime, and so is the basis: a session that
   alternates two Agent Core runtimes sends each the System it last issued
   to that runtime. *)
let test_each_runtime_keeps_the_basis_it_was_issued () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let later = article "name the file you read" in
  let on_a = agent_core ~runtime_id:"fixture.a" and on_b = agent_core ~runtime_id:"fixture.b" in
  let first_a, held = issue ~lane:(on_a System.No_previous_request) [ kept ] in
  let first_b, held = issue ~held ~lane:(on_b System.No_previous_request) [ kept; written ] in
  Alcotest.(check string) "a runtime with no request renders the current articles"
    (render [ kept; written ]) first_b.text;
  let next_a, held = issue ~held ~lane:(on_a System.Same_front) [ kept; written; later ] in
  Alcotest.(check string) "runtime a still gets its own System" first_a.text next_a.text;
  Alcotest.(check bool) "with both articles written since in the block" true
    (Option.fold ~none:false
       ~some:(fun block ->
         contains ~sub:(Types.Article_id.to_string written.id) block
         && contains ~sub:(Types.Article_id.to_string later.id) block)
       next_a.amendments);
  let next_b, (_ : System.held) = issue ~held ~lane:(on_b System.Same_front) [ kept; written; later ] in
  Alcotest.(check string) "runtime b gets the System it was issued" first_b.text next_b.text;
  match next_b.amendments with
  | None -> Alcotest.fail "the article written after b's System rides the end context"
  | Some block ->
    Alcotest.(check bool) "b's block does not repeat what b's System holds" false
      (contains ~sub:(Types.Article_id.to_string written.id) block)
;;

(* (g) An official client's vendor session holds its own System: the turn
   renders the current articles and leaves the runtime bases alone. *)
let test_an_official_client_turn_neither_reads_nor_writes_the_basis () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let later = article "name the file you read" in
  let first, held = issue ~lane:(agent_core System.No_previous_request) [ kept ] in
  let official, held = issue ~held ~lane:System.Without_basis [ kept; written ] in
  Alcotest.(check string) "the official client gets the current articles"
    (render [ kept; written ]) official.text;
  Alcotest.(check bool) "with no amendments" true (Option.is_none official.amendments);
  let next, (_ : System.held) =
    issue ~held ~lane:(agent_core System.Same_front) [ kept; written; later ]
  in
  Alcotest.(check string) "the Agent Core basis is the one before the official turn" first.text
    next.text;
  match next.amendments with
  | None -> Alcotest.fail "both articles written since the basis ride the end context"
  | Some block ->
    Alcotest.(check bool) "the article the official turn saw is still an amendment" true
      (contains ~sub:(Types.Article_id.to_string written.id) block)
;;

(* A basis names its articles by the ledger bytes they were read from. When
   the ledger no longer begins with those bytes, which articles the System
   was rendered with is not known, so it is rendered with the current ones. *)
let test_a_basis_whose_ledger_bytes_changed_is_not_used () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let (_ : System.t), held = issue ~lane:(agent_core System.No_previous_request) [ kept ] in
  Hashtbl.remove ledger_reads (at_of [ kept ]).digest;
  let next, (_ : System.held) = issue ~held ~lane:(agent_core System.Same_front) [ kept; written ] in
  Alcotest.(check string) "the System takes the current articles" (render [ kept; written ]) next.text;
  Alcotest.(check bool) "with no amendments" true (Option.is_none next.amendments)
;;

let test_other_bytes_carry_no_amendments () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let (_ : System.t), held = issue ~lane:(agent_core System.No_previous_request) [ kept ] in
  let issued, (_ : System.held) = issue ~held ~lane:(agent_core System.Same_front) [ kept; written ] in
  let same = System.with_bytes ~issued issued.text in
  Alcotest.(check bool) "the issued bytes keep their amendments" true
    (Option.equal String.equal issued.amendments same.amendments && Option.is_some same.amendments);
  let recorded = System.with_bytes ~issued "a recorded System" in
  Alcotest.(check string) "other bytes are sent as they are" "a recorded System" recorded.text;
  Alcotest.(check bool) "with no amendments" true (Option.is_none recorded.amendments)
;;

(* A native continuation resends its seed's System. The seed's checkpoint
   says which articles rendered those bytes, so the block names what changed
   since, even after the process that issued them is gone. *)
let test_a_resent_system_names_what_changed_since_its_seed () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let later = article "name the file you read" in
  let (_ : System.t), held = issue ~lane:(agent_core System.No_previous_request) [ kept ] in
  let seeded, seed_held = issue ~held ~lane:(agent_core System.Same_front) [ kept; written ] in
  let resent, resent_held =
    resend ~held:(Some seed_held) ~runtime_id:"fixture.fallback"
      ~current:[ kept; written; later ] seeded.text
  in
  Alcotest.(check string) "the recorded bytes are sent" seeded.text resent.text;
  (match resent.amendments with
   | None -> Alcotest.fail "the articles written since the seed's System ride the end context"
   | Some block ->
     Alcotest.(check bool) "the article the seed's block named" true
       (contains ~sub:(Types.Article_id.to_string written.id) block);
     Alcotest.(check bool) "and the one written after the seed" true
       (contains ~sub:(Types.Article_id.to_string later.id) block));
  match resent_held with
  | None -> Alcotest.fail "the resent turn keeps what the seed held"
  | Some resent_held ->
    let next, (_ : System.held) =
      issue ~held:resent_held
        ~lane:(agent_core ~runtime_id:"fixture.fallback" System.Same_front)
        [ kept; written; later ]
    in
    Alcotest.(check string) "the runtime that ran the call next gets the bytes it was sent"
      seeded.text next.text
;;

let test_a_resent_system_of_unknown_provenance_has_no_block () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let (_ : System.t), held = issue ~lane:(agent_core System.No_previous_request) [ kept ] in
  let unrecorded, (_ : System.held option) =
    resend ~held:None ~runtime_id:"fixture.agent" ~current:[ kept; written ] (render [ kept ])
  in
  Alcotest.(check bool) "a seed with nothing held sends no block" true
    (Option.is_none unrecorded.amendments);
  let other, (_ : System.held option) =
    resend ~held:(Some held) ~runtime_id:"fixture.agent" ~current:[ kept; written ]
      "bytes no held basis rendered"
  in
  Alcotest.(check string) "the recorded bytes are sent" "bytes no held basis rendered" other.text;
  Alcotest.(check bool) "with no block" true (Option.is_none other.amendments)
;;

(* Current withholding is independent of the historical System's basis. A
   native call must keep its recorded bytes while every request, including a
   tool continuation or an override, receives the current authority notice.
   Where the notice rides follows the owner of the request. Agent Core carries
   it in the issued System, so a request that follows tool results adds no
   User tail. An official client receives it as the context block. *)
let check_withholding_reaches_requests (system : System.t) =
  let withheld = match system.current_norms with
    | Some block -> block
    | None -> Alcotest.fail "the current withholding notice is required"
  in
  let assemble checkpoint_owner ~previous_assembly =
    Keeper_run_prompt.assemble_request_context ~checkpoint_owner ~system
      ~post_tool_round:(Option.is_some previous_assembly) ~previous_assembly
      ~dynamic_context_partition:None ~existing_extra_system_context:None ~blocks:[]
  in
  let in_system (assembly : Keeper_context_assembly.t) =
    match assembly.system_prompt with
    | None -> []
    | Some issued ->
      List.filter_map (function
        | Keeper_context_assembly.Current_norms text -> Some text
        | Active_goals _ | Direct_input_source _ | Goals_awaiting_proof _ -> None)
        issued.observations
  in
  let as_block (assembly : Keeper_context_assembly.t) =
    List.assoc_opt Prompt_block_id.Constitution_amendments assembly.blocks
  in
  let check_agent_core label (assembly : Keeper_context_assembly.t) =
    Alcotest.(check (list string)) (label ^ ": the issued System carries the whole notice once")
      [ withheld ] (in_system assembly);
    Alcotest.(check string) (label ^ ": the System is its own bytes, then the notice")
      (system.text ^ "\n\n" ^ withheld)
      (Keeper_context_assembly.effective_system_prompt ~base_text:system.text assembly);
    Alcotest.(check (option string)) (label ^ ": no context block repeats the notice") None
      (as_block assembly)
  in
  let check_official label (assembly : Keeper_context_assembly.t) =
    Alcotest.(check (option string)) (label ^ ": the context block carries the whole notice")
      (Some withheld) (as_block assembly);
    Alcotest.(check (list string)) (label ^ ": the vendor System is not given the notice") []
      (in_system assembly)
  in
  let agent_first = assemble Runtime_execution.Masc_agent_core ~previous_assembly:None in
  let agent_later =
    assemble Runtime_execution.Masc_agent_core ~previous_assembly:(Some agent_first) in
  check_agent_core "Agent Core first request" agent_first;
  check_agent_core "Agent Core after a tool result" agent_later;
  Alcotest.(check (option string)) "Agent Core adds no User tail after a tool result" None
    agent_later.extra_system_context;
  let official_first = assemble Runtime_execution.Official_client ~previous_assembly:None in
  let official_later =
    assemble Runtime_execution.Official_client ~previous_assembly:(Some official_first) in
  check_official "official first request" official_first;
  check_official "official after a tool result" official_later;
  (* A fallback changes the owner between two rounds of one turn. *)
  check_official "official after an Agent Core round"
    (assemble Runtime_execution.Official_client ~previous_assembly:(Some agent_first));
  check_agent_core "Agent Core after an official round"
    (assemble Runtime_execution.Masc_agent_core ~previous_assembly:(Some official_first))
;;

let test_withholding_survives_unknown_native_bases_and_overrides () =
  let taken = article "a norm whose retirement cannot be resolved" in
  let seeded, held = issue ~lane:(agent_core System.No_previous_request) [taken] in
  let missing_prefix _ = Ok None in
  let missing, (_ : System.held option) =
    ok (System.resend ~held:(Some held) ~runtime_id:"fixture.agent" ~current:[]
          ~articles_at:missing_prefix seeded.text)
  in
  let unknown, (_ : System.held option) =
    resend ~held:None ~runtime_id:"fixture.agent" ~current:[] seeded.text
  in
  let mismatched, (_ : System.held option) =
    resend ~held:(Some held) ~runtime_id:"fixture.agent" ~current:[] "different recorded bytes"
  in
  List.iter
    (fun (system : System.t) ->
      let issued = System.with_current_norms [] system in
      Alcotest.(check string) "native System bytes stay exact" system.text issued.text;
      check_withholding_reaches_requests issued;
      let overridden = System.with_bytes ~issued "an independently supplied override" in
      Alcotest.(check (option string)) "overriding bytes retains current withholding"
        issued.current_norms overridden.current_norms;
      check_withholding_reaches_requests overridden)
    [missing; unknown; mismatched]
;;

(* What a turn writes is what the next turn reads back from the session
   context; a malformed entry is refused, not read as nothing. *)
let test_the_session_context_reads_back_what_was_written () =
  let kept = article "open before you record \"quoted\" </norms>" in
  let written = article "cite the ledger row, not the frame" in
  let first, held = issue ~lane:(agent_core System.No_previous_request) [ kept ] in
  let context = Agent_core.Context.create_sync () in
  Alcotest.(check bool) "an empty context holds nothing" true
    (match System.read context with Ok None -> true | Ok (Some _) | Error _ -> false);
  System.write context held;
  let read_back =
    match System.read context with
    | Ok (Some held) -> held
    | Ok None -> Alcotest.fail "the written entry is read back"
    | Error detail -> Alcotest.fail detail
  in
  let next, (_ : System.held) =
    issue ~held:read_back ~lane:(agent_core System.Same_front) [ kept; written ]
  in
  Alcotest.(check string) "the read-back basis renders the first System" first.text next.text;
  Agent_core.Context.set_scoped context Agent_core.Context.Session "keeper_turn_system"
    (`Assoc [ "issued", `Null ]);
  Alcotest.(check bool) "a malformed entry is an error" true
    (match System.read context with Error _ -> true | Ok (Some _ | None) -> false)
;;

(* The System a prepared turn sends ({!Keeper_run_context.prepare_run_context}):
   the same rule over a real world, with the range predicted from the saved
   history, the runtime's request ledger and the Librarian's position. *)

let agent_core_runtime = "fixture.sample"
let official_runtime = "official.held"

let message role text : Agent_core.Types.message =
  { origin = Llm_provider.Types.Conversation
  ; role
  ; content = [ Agent_core.Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

(* Six exchanges: each user and assistant message opens an atom, so twelve. *)
let history =
  List.concat_map
    (fun index ->
      let text = Printf.sprintf "exchange %d" index in
      [ message Agent_core.Types.User text; message Agent_core.Types.Assistant text ])
    (List.init 6 Fun.id)
;;

let history_atoms = List.length history
let digest_at = Runtime_model_input_tail_window.atom_opening_digest history
let unwrap = function Ok value -> value | Error detail -> Alcotest.fail detail

type world =
  { config : Workspace.config
  ; meta : Keeper_meta_contract.keeper_meta
  ; trace_id : string
  }

let runtime_toml =
  {|[runtime]
default = "fixture.sample"
[providers.fixture]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1/v1"
[models.sample]
api-name = "turn-system-model"
max-context = 4096
[fixture.sample]
[providers.official]
protocol = "claude-code"
command = "/bin/true"
is-non-interactive = true
[models.held]
api-name = "turn-system-official"
max-context = 400000
tools-support = true
[official.held]
|}
;;

let with_world ~keeper_name f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let previous_fs = Fs_compat.get_fs_opt () in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Catalog_snapshot.current () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Masc_test_deps.setup_test_workspace () in
  Eio.Switch.on_release sw (fun () ->
    Masc_test_deps.cleanup_test_workspace base_path;
    Llm_provider.Catalog_snapshot.publish catalog_snapshot;
    Runtime.For_testing.restore runtime_snapshot;
    match previous_fs with
    | Some fs -> Fs_compat.set_fs fs
    | None -> Fs_compat.clear_fs ());
  let write path contents =
    Out_channel.with_open_bin path (fun out -> output_string out contents)
  in
  let catalog_path = Filename.concat base_path "models.toml" in
  write catalog_path
    "[[models]]\nmodel_id = \"turn-system-model\"\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 4096\nmax_output_tokens = 128\nsupports_tools = true\n";
  Llm_provider.Model_catalog.load_file catalog_path
  |> unwrap
  |> (fun models ->
       Llm_provider.Catalog_snapshot.publish
         (Masc_test_deps.admit_catalogs ~models:(Some models) ~providers:None));
  let config_path = Filename.concat base_path "runtime.toml" in
  write config_path runtime_toml;
  (match Runtime.init_default_degraded_report ~config_path with
   | Ok Runtime.Initialized -> ()
   | Ok (Runtime.Initialized_degraded _) -> Alcotest.fail "the fixture runtimes must materialize"
   | Error error -> Alcotest.fail (Runtime.strict_init_error_to_string error));
  let config = Workspace.default_config base_path in
  let meta =
    Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String keeper_name ]) |> unwrap
  in
  Keeper_meta_store.replace_snapshot config meta |> unwrap;
  (* The constitution reader resolves durable names, not the transient test
     registry. The article and removal helpers below act as these keepers. *)
  List.iter
    (fun name ->
      let subject = Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ]) |> unwrap in
      Keeper_meta_store.replace_snapshot config subject |> unwrap)
    ["lane-smith"; "critic"];
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let checkpoint : Agent_core.Checkpoint.t =
    { provider_binding = None; version = Agent_core.Checkpoint.checkpoint_version
    ; session_id = trace_id; agent_name = keeper_name; model = "turn-system-model"
    ; system_prompt = None; messages = history; usage = Agent_core.Types.empty_usage
    ; turn_count = 1; created_at = 1000.; tools = []; tool_choice = None
    ; disable_parallel_tool_use = false; temperature = None; top_p = None; top_k = None
    ; min_p = None; reasoning_effort = None; enable_thinking = None
    ; preserve_thinking = None; response_format = Agent_core.Types.Off
    ; cache_system_prompt = false; context = Agent_core.Context.create_sync ()
    ; pending_input = None; mcp_sessions = []; working_context = None
    }
  in
  (match
     Keeper_checkpoint_store.save_agent_core_classified
       ~boundary:Agent_core.Checkpoint_objects.Turn_closes
       ~session_dir:(Keeper_types_support.keeper_session_dir config trace_id)
       ~history_retained:0 checkpoint
   with
   | Ok _ -> ()
   | Error detail -> Alcotest.fail detail);
  f { config; meta; trace_id }
;;

let append world entry =
  let base_path = world.config.Workspace.base_path in
  let ledger =
    World_constitution_store.load ~base_path ~resolve_subject:(fun _ -> true)
    |> Result.map_error World_constitution_store.read_error_to_string
    |> unwrap
  in
  World_constitution_store.append_at ~base_path
    ~expected_end_offset:ledger.World_constitution_store.end_offset entry
  |> Result.map_error World_constitution_store.append_error_to_string
  |> unwrap
;;

let write_article world text =
  let written = article text in
  append world (Types.Added written);
  written
;;

let take_back world (taken : Types.t) =
  append world (Types.Removed { id = taken.id; by = "critic"; at = 2.0; reason = None })
;;

(* The last request on [runtime_id] carried the whole saved history. *)
let observe_request world ~runtime_id =
  let module Ledger = Keeper_model_input_ledger in
  let ends =
    match digest_at 0, digest_at (history_atoms - 1) with
    | Some front_digest, Some end_digest -> Ledger.Carried_atoms { front_digest; end_digest }
    | None, (Some _ | None) | Some _, None -> Alcotest.fail "the fixture history opens its atoms"
  in
  let request : Ledger.request =
    { prefix_digest = "turn-system-prefix"; first_atom = 0; atom_count = history_atoms; ends
    ; tail_bytes = 0; turn_context = false; demote_before = 0 }
  in
  ignore
    (Ledger.Table.observe ~keeper_name:world.meta.name ~runtime_id ~session_id:world.trace_id
       ~digest_at ~request ~usage:None)
;;

(* The Librarian has read the first [end_atom] atoms, so the next range
   opens there. *)
let read_by_librarian world ~end_atom =
  match digest_at (end_atom - 1) with
  | None -> Alcotest.fail "the fixture history holds the read atom"
  | Some last_atom_digest ->
    Keeper_librarian_progress.write
      ~keepers_dir:(Workspace.keepers_runtime_dir world.config)
      ~keeper_id:world.meta.name
      { Keeper_librarian_progress.position =
          { Keeper_librarian_progress.trace_id = world.trace_id; end_atom; last_atom_digest }
      ; boundary_lines_seen = 0
      }
    |> Result.map_error Keeper_librarian_progress.write_error_to_string
    |> unwrap
;;

(* The checkpoint a dispatched turn leaves: its history with the context the
   turn wrote, which is what the next turn loads. *)
let checkpoint_of_turn (ctx : Keeper_run_context.run_context) =
  match ctx.resume_agent_core_checkpoint with
  | Some checkpoint ->
    { checkpoint with
      Agent_core.Checkpoint.system_prompt = Some ctx.system.text
    ; context = Agent_core.Context.copy ctx.shared_context
    }
  | None -> Alcotest.fail "the fixture session has a saved checkpoint"
;;

let save world checkpoint =
  match
    Keeper_checkpoint_store.save_agent_core_classified
      ~boundary:Agent_core.Checkpoint_objects.Turn_closes
      ~session_dir:(Keeper_types_support.keeper_session_dir world.config world.trace_id)
      ~history_retained:0 checkpoint
  with
  | Ok _ -> ()
  | Error detail -> Alcotest.fail detail
;;

let prepare_context ?(instructions = "keeper fixture instructions") ?checkpoint ?recorded_system
      world ~runtime_id =
  let profile_defaults =
    { Keeper_types_profile_defaults.empty_keeper_profile_defaults with
      Keeper_types_profile_defaults.instructions = Some instructions
    }
  in
  let shared_context =
    Option.map (fun (cp : Agent_core.Checkpoint.t) -> Agent_core.Context.copy cp.context) checkpoint
  in
  match
    Keeper_run_context.prepare_run_context ~config:world.config ~meta:world.meta
      ~profile_defaults ~base_dir:(Keeper_types_support.session_base_dir_ world.config)
      ~runtime_id ?shared_context ?checkpoint ?recorded_system ()
  with
  | Ok ctx -> ctx
  | Error (Keeper_run_context.Checkpoint_unread error) ->
    Alcotest.fail (Keeper_checkpoint_store.checkpoint_load_error_to_string error)
  | Error (Keeper_run_context.Base_prompt_unavailable error) ->
    Alcotest.fail (Keeper_run_context.base_prompt_error_to_string error)
  | Error (Keeper_run_context.Prompt_unrenderable detail)
  | Error (Keeper_run_context.Turn_system_unreadable detail) -> Alcotest.fail detail
;;

(* A prepared turn that is dispatched: its checkpoint is saved. *)
let prepare ?instructions world ~runtime_id =
  let ctx = prepare_context ?instructions world ~runtime_id in
  save world (checkpoint_of_turn ctx);
  ctx.Keeper_run_context.system
;;

let holds (system : System.t) (held : Types.t) = contains ~sub:(Render.articles [ held ]) system.text

let check_composer label expected runtime_id =
  let name = function
    | Keeper_carried_front.Composes_from_the_history -> "agent core"
    | Keeper_carried_front.Hands_over_its_own_list -> "official client"
    | Keeper_carried_front.Not_materialized -> "not materialized"
  in
  Alcotest.(check string) label expected
    (name (Keeper_carried_front.composer_of_runtime (Runtime.get_runtime_by_id runtime_id)))
;;

(* (a) and (d): the first turn has no basis and renders the article it finds;
   an article written before the next turn rides that turn's end context while
   its System keeps the first turn's bytes. *)
let test_a_prepared_turn_keeps_its_system_when_an_article_is_written () =
  with_world ~keeper_name:"turn-system-added" @@ fun world ->
  check_composer "the fixture runtime composes from the history" "agent core" agent_core_runtime;
  let kept = write_article world "open before you record" in
  observe_request world ~runtime_id:agent_core_runtime;
  let first = prepare world ~runtime_id:agent_core_runtime in
  Alcotest.(check bool) "(d) the first System holds the article it found" true (holds first kept);
  Alcotest.(check bool) "(d) with no amendments" true (Option.is_none first.amendments);
  let written = write_article world "cite the ledger row, not the frame" in
  let next = prepare world ~runtime_id:agent_core_runtime in
  Alcotest.(check string) "(a) the System bytes are the previous turn's" first.text next.text;
  match next.amendments with
  | None -> Alcotest.fail "(a) the written article rides the end context"
  | Some block ->
    Alcotest.(check bool) "(a) the block lists the written article" true
      (contains ~sub:(Render.articles [ written ]) block)
;;

let test_without_a_request_on_the_runtime_the_system_takes_every_article () =
  with_world ~keeper_name:"turn-system-no-request" @@ fun world ->
  let (_ : Types.t) = write_article world "open before you record" in
  let (_ : System.t) = prepare world ~runtime_id:agent_core_runtime in
  let written = write_article world "cite the ledger row, not the frame" in
  let next = prepare world ~runtime_id:agent_core_runtime in
  Alcotest.(check bool) "the System holds the written article" true (holds next written);
  Alcotest.(check bool) "with no amendments" true (Option.is_none next.amendments)
;;

(* (b) The Librarian read past the front the last request opened, so the
   range moves and the history cache is lost either way. *)
let test_a_moved_front_renders_the_current_articles_on_the_wire () =
  with_world ~keeper_name:"turn-system-moved" @@ fun world ->
  let (_ : Types.t) = write_article world "open before you record" in
  observe_request world ~runtime_id:agent_core_runtime;
  let first = prepare world ~runtime_id:agent_core_runtime in
  let written = write_article world "cite the ledger row, not the frame" in
  read_by_librarian world ~end_atom:4;
  let next = prepare world ~runtime_id:agent_core_runtime in
  Alcotest.(check bool) "the System changed" false (String.equal first.text next.text);
  Alcotest.(check bool) "it holds the written article" true (holds next written);
  Alcotest.(check bool) "with no amendments" true (Option.is_none next.amendments)
;;

(* (c) Edited instructions change the System's bytes, so it is rebuilt with
   the current articles. *)
let test_changed_instructions_rebuild_the_prepared_system () =
  with_world ~keeper_name:"turn-system-instructions" @@ fun world ->
  let (_ : Types.t) = write_article world "open before you record" in
  observe_request world ~runtime_id:agent_core_runtime;
  let (_ : System.t) = prepare ~instructions:"first instructions" world ~runtime_id:agent_core_runtime in
  let written = write_article world "cite the ledger row, not the frame" in
  let next = prepare ~instructions:"second instructions" world ~runtime_id:agent_core_runtime in
  Alcotest.(check bool) "the System carries the new instructions" true
    (contains ~sub:"second instructions" next.text);
  Alcotest.(check bool) "and the written article" true (holds next written);
  Alcotest.(check bool) "with no amendments" true (Option.is_none next.amendments)
;;

(* (e) A taken-back article stays in the kept System; the block names it. *)
let test_a_taken_back_article_is_named_in_the_prepared_block () =
  with_world ~keeper_name:"turn-system-removed" @@ fun world ->
  let (_ : Types.t) = write_article world "open before you record" in
  let taken = write_article world "cite the ledger row, not the frame" in
  observe_request world ~runtime_id:agent_core_runtime;
  let first = prepare world ~runtime_id:agent_core_runtime in
  take_back world taken;
  let next = prepare world ~runtime_id:agent_core_runtime in
  Alcotest.(check string) "the System bytes are the previous turn's" first.text next.text;
  match next.amendments with
  | None -> Alcotest.fail "the taken-back article rides the end context"
  | Some block ->
    Alcotest.(check bool) "the block names its id" true
      (contains ~sub:(Printf.sprintf "- [%s]" (Types.Article_id.to_string taken.id)) block)
;;

(* (g) An official client's turn renders the current articles and leaves the
   keeper's Agent Core basis as it was. *)
let test_an_official_client_turn_takes_the_current_articles () =
  with_world ~keeper_name:"turn-system-official" @@ fun world ->
  check_composer "the official runtime hands over its own list" "official client" official_runtime;
  let (_ : Types.t) = write_article world "open before you record" in
  observe_request world ~runtime_id:agent_core_runtime;
  let first = prepare world ~runtime_id:agent_core_runtime in
  let written = write_article world "cite the ledger row, not the frame" in
  let official = prepare world ~runtime_id:official_runtime in
  Alcotest.(check bool) "the official System holds the written article" true (holds official written);
  Alcotest.(check bool) "with no amendments" true (Option.is_none official.amendments);
  let next = prepare world ~runtime_id:agent_core_runtime in
  Alcotest.(check string) "the Agent Core System is still the first turn's" first.text next.text;
  Alcotest.(check bool) "and its block lists the written article" true
    (Option.fold ~none:false ~some:(contains ~sub:(Render.articles [ written ])) next.amendments)
;;

(* F1 of the #49004 review: a direct turn sent the kept System and its block,
   then the server stopped before the native call finished. The restarted
   process holds nothing in memory; the continuation resends the seed's bytes
   and reads, from the seed's checkpoint, the articles that rendered them. *)
let test_a_native_continuation_after_a_restart_keeps_the_block () =
  with_world ~keeper_name:"turn-system-native" @@ fun world ->
  let kept = write_article world "open before you record" in
  observe_request world ~runtime_id:agent_core_runtime;
  let (_ : System.t) = prepare world ~runtime_id:agent_core_runtime in
  let written = write_article world "cite the ledger row, not the frame" in
  let seeded = prepare_context world ~runtime_id:agent_core_runtime in
  Alcotest.(check bool) "the seeded turn sent the kept System" true
    (holds seeded.system kept && not (holds seeded.system written));
  let seed = checkpoint_of_turn seeded in
  let later = write_article world "name the file you read" in
  let resumed =
    prepare_context world ~runtime_id:agent_core_runtime ~checkpoint:seed
      ~recorded_system:{ Keeper_run_context.runtime_id = agent_core_runtime; text = seeded.system.text }
  in
  Alcotest.(check string) "the continuation sends the recorded bytes" seeded.system.text
    resumed.system.text;
  match resumed.system.current_norms with
  | None -> Alcotest.fail "the articles the recorded System lacks ride the end context"
  | Some block ->
    Alcotest.(check bool) "the article written before the seed" true
      (contains ~sub:(Render.articles [ written ]) block);
    Alcotest.(check bool) "and the one written after it" true
      (contains ~sub:(Render.articles [ later ]) block)
;;

(* A seed whose original article basis is unknown still carries the complete
   current set, without rewriting its recorded System. *)
let test_a_native_continuation_without_a_recorded_basis_carries_current_norms () =
  with_world ~keeper_name:"turn-system-native-unrecorded" @@ fun world ->
  let kept = write_article world "open before you record" in
  let seeded = prepare_context world ~runtime_id:agent_core_runtime in
  let seed =
    { (checkpoint_of_turn seeded) with Agent_core.Checkpoint.context = Agent_core.Context.create_sync () }
  in
  let written = write_article world "cite the ledger row, not the frame" in
  let resumed =
    prepare_context world ~runtime_id:agent_core_runtime ~checkpoint:seed
      ~recorded_system:{ Keeper_run_context.runtime_id = agent_core_runtime; text = seeded.system.text }
  in
  Alcotest.(check string) "the continuation sends the recorded bytes" seeded.system.text
    resumed.system.text;
  Alcotest.(check (option string)) "current norms do not depend on a recorded basis"
    (Some (Keeper_prompt.constitution_current_block [kept; written])) resumed.system.current_norms
;;

(* The old fold issued a basis whose position already included an unresolved
   removal while its System still contained the earlier Added text. Replaying
   that position now yields no article: basis/current comparison alone cannot
   name the rule that survives in the native System's recorded bytes. *)
let test_a_native_seed_with_a_reinterpreted_basis_carries_current_withholding () =
  with_world ~keeper_name:"turn-system-withheld" @@ fun world ->
  let taken = write_article world "a retired rule must not regain authority" in
  observe_request world ~runtime_id:agent_core_runtime;
  let seeded = prepare_context world ~runtime_id:agent_core_runtime in
  Alcotest.(check bool) "the seed contains the earlier rule" true (holds seeded.system taken);
  append world (Types.Removed
    { id = taken.id; by = "former-operator"; at = 2.0; reason = None });
  let projection =
    World_constitution_store.load_held ~base_path:world.config.base_path
      ~resolve_subject:(fun _ -> true)
    |> Result.map_error World_constitution_store.read_error_to_string |> unwrap
  in
  let (_ : System.t), old_held =
    System.issue ~held:None ~lane:System.Without_basis
      ~render:(fun _ -> seeded.system.text) ~current:[taken] ~at:projection.at
      ~articles_at:(fun _ -> Ok (Some [taken])) |> unwrap
  in
  let seed = checkpoint_of_turn seeded in
  System.write seed.context old_held;
  let resumed =
    prepare_context world ~runtime_id:agent_core_runtime ~checkpoint:seed
      ~recorded_system:{ Keeper_run_context.runtime_id = agent_core_runtime; text = seeded.system.text }
  in
  Alcotest.(check string) "the retained native System is not rewritten"
    seeded.system.text resumed.system.text;
  Alcotest.(check bool) "reinterpreted basis alone finds no ordinary amendment" true
    (Option.is_none resumed.system.amendments);
  Alcotest.(check (option string)) "an empty current set still overrides the stale norms"
    (Some (Keeper_prompt.constitution_current_block [])) resumed.system.current_norms;
  check_withholding_reaches_requests resumed.system;
  let without_basis = { seed with Agent_core.Checkpoint.context = Agent_core.Context.create_sync () } in
  let unknown =
    prepare_context world ~runtime_id:agent_core_runtime ~checkpoint:without_basis
      ~recorded_system:{ Keeper_run_context.runtime_id = agent_core_runtime; text = seeded.system.text }
  in
  check_withholding_reaches_requests unknown.system;
  let former_operator =
    Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String "former-operator"]) |> unwrap
  in
  Keeper_meta_store.replace_snapshot world.config former_operator |> unwrap;
  let resolver = Keeper_constitution_roster.read ~config:world.config
    |> Result.map_error World_constitution_store.read_error_to_string |> unwrap in
  let now_resolved = World_constitution_store.load_held
    ~base_path:world.config.base_path ~resolve_subject:resolver
    |> Result.map_error World_constitution_store.read_error_to_string |> unwrap in
  Alcotest.(check bool) "the new durable roster now resolves every move" true
    (now_resolved.status = World_constitution_store.Resolved);
  let resolved_native =
    prepare_context world ~runtime_id:agent_core_runtime
      ~checkpoint:{ seed with Agent_core.Checkpoint.context = Agent_core.Context.create_sync () }
      ~recorded_system:{ Keeper_run_context.runtime_id = agent_core_runtime; text = seeded.system.text }
  in
  Alcotest.(check (option string)) "roster changes cannot revive the native System's old norm"
    unknown.system.current_norms resolved_native.system.current_norms;
  check_withholding_reaches_requests resolved_native.system;
  let another_isolated =
    Types.make ~id:(Types.Article_id.generate ()) ~text:"an unrelated unverified norm"
      ~author:"another-former-keeper" ~at:2.5 ~evidence:[]
    |> Result.map_error Types.invalid_to_string |> unwrap
  in
  append world (Types.Added another_isolated);
  let more_history =
    prepare_context world ~runtime_id:agent_core_runtime
      ~checkpoint:{ seed with Agent_core.Checkpoint.context = Agent_core.Context.create_sync () }
      ~recorded_system:{ Keeper_run_context.runtime_id = agent_core_runtime; text = seeded.system.text }
  in
  Alcotest.(check (option string)) "more inactive history does not enlarge the request snapshot"
    unknown.system.current_norms more_history.system.current_norms;
  let ordinary = prepare_context world ~runtime_id:agent_core_runtime ~checkpoint:seed in
  Alcotest.(check bool) "an ordinary turn rebuilds without the withdrawn text" false
    (holds ordinary.system taken);
  let readopted =
    Types.make ~id:taken.id ~text:"the explicitly readopted new text"
      ~author:"lane-smith" ~at:3.0 ~evidence:[]
    |> Result.map_error Types.invalid_to_string |> unwrap
  in
  append world (Types.Added readopted);
  let readopted_native =
    prepare_context world ~runtime_id:agent_core_runtime
      ~checkpoint:{ seed with Agent_core.Checkpoint.context = Agent_core.Context.create_sync () }
      ~recorded_system:{ Keeper_run_context.runtime_id = agent_core_runtime; text = seeded.system.text }
  in
  Alcotest.(check string) "readoption preserves the native seed bytes"
    seeded.system.text readopted_native.system.text;
  Alcotest.(check (option string)) "readoption replaces an unknown native's old same-id body"
    (Some (Keeper_prompt.constitution_current_block [readopted]))
    readopted_native.system.current_norms;
  check_withholding_reaches_requests readopted_native.system
;;

let () =
  Alcotest.run "keeper_turn_system"
    [ ( "front"
      , [ Alcotest.test_case "the same atom and message" `Quick
            test_the_front_is_the_same_only_at_the_same_atom_and_message
        ] )
    ; ( "decide"
      , [ Alcotest.test_case "(a) an added article keeps the System" `Quick
            test_an_added_article_keeps_the_system_and_names_the_article
        ; Alcotest.test_case "the same articles have no amendments" `Quick
            test_the_same_articles_keep_the_system_with_no_amendments
        ; Alcotest.test_case "(b) a moved front renders the current articles" `Quick
            test_a_moved_front_renders_the_current_articles
        ; Alcotest.test_case "(c) changed instructions rebuild the System" `Quick
            test_changed_instructions_rebuild_the_system
        ; Alcotest.test_case "(d) no basis renders the current articles" `Quick
            test_no_basis_renders_the_current_articles
        ; Alcotest.test_case "(e) a removed article is named by its id" `Quick
            test_a_removed_article_is_named_by_its_id
        ] )
    ; ( "issue"
      , [ Alcotest.test_case "a later turn sends the stored basis and the block" `Quick
            test_a_later_turn_sends_the_stored_basis_and_the_block
        ; Alcotest.test_case "a moved front replaces the basis" `Quick
            test_a_moved_front_replaces_the_basis
        ; Alcotest.test_case "each runtime keeps the basis it was issued" `Quick
            test_each_runtime_keeps_the_basis_it_was_issued
        ; Alcotest.test_case "(g) an official client turn leaves the basis" `Quick
            test_an_official_client_turn_neither_reads_nor_writes_the_basis
        ; Alcotest.test_case "a basis whose ledger bytes changed is not used" `Quick
            test_a_basis_whose_ledger_bytes_changed_is_not_used
        ; Alcotest.test_case "other bytes carry no amendments" `Quick
            test_other_bytes_carry_no_amendments
        ; Alcotest.test_case "a resent System names what changed since its seed" `Quick
            test_a_resent_system_names_what_changed_since_its_seed
        ; Alcotest.test_case "a resent System of unknown provenance has no block" `Quick
            test_a_resent_system_of_unknown_provenance_has_no_block
        ; Alcotest.test_case "current withholding survives unknown native bases and overrides" `Quick
            test_withholding_survives_unknown_native_bases_and_overrides
        ; Alcotest.test_case "the session context reads back what was written" `Quick
            test_the_session_context_reads_back_what_was_written
        ] )
    ; ( "prepared turn"
      , [ Alcotest.test_case "(a)(d) a written article keeps the System" `Quick
            test_a_prepared_turn_keeps_its_system_when_an_article_is_written
        ; Alcotest.test_case "without a request the System takes every article" `Quick
            test_without_a_request_on_the_runtime_the_system_takes_every_article
        ; Alcotest.test_case "(b) a moved front renders the current articles" `Quick
            test_a_moved_front_renders_the_current_articles_on_the_wire
        ; Alcotest.test_case "(c) changed instructions rebuild the System" `Quick
            test_changed_instructions_rebuild_the_prepared_system
        ; Alcotest.test_case "(e) a taken-back article is named" `Quick
            test_a_taken_back_article_is_named_in_the_prepared_block
        ; Alcotest.test_case "(g) an official client takes the current articles" `Quick
            test_an_official_client_turn_takes_the_current_articles
        ; Alcotest.test_case "a native continuation after a restart keeps the block" `Quick
            test_a_native_continuation_after_a_restart_keeps_the_block
        ; Alcotest.test_case "a native continuation without a recorded basis carries current norms" `Quick
            test_a_native_continuation_without_a_recorded_basis_carries_current_norms
        ; Alcotest.test_case "a reinterpreted native basis carries current withholding" `Quick
            test_a_native_seed_with_a_reinterpreted_basis_carries_current_withholding
        ] )
    ]
;;
