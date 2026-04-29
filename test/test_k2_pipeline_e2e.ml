(* Tier K2 — multimodal producer→consumer→workspace→HTTP chain.

   This test exercises the complete production-loop path that the
   K1 wire-in seam exists to support:

     keeper agent (simulated)
       │
       ▼
     Keeper_emitter.emit  (K2: producer)
       │  writes working_context["multimodal_artifacts"]
       ▼
     Wirein_helpers.extract_raw_artifacts  (K1: consumer)
       │  drains and parses
       ▼
     Multimodal_keeper_bridge.hydrate_with_workspace
       │  typed Artifact construction + DAG insertion
       ▼
     Workspace_holder.update  (K1)
       │  process-wide live workspace
       ▼
     Server_routes_http_routes_multimodal.list_response  (D1)
       │  read-only HTTP envelope
       ▼
     dashboard JSON

   Every link is verified deterministically — no LLM calls, no
   network I/O. If any stage drops or duplicates artifacts the
   final assertion fails.

   The test does NOT call apply_post_turn_lifecycle — that brings
   in the entire keeper FSM including OAS Checkpoint construction.
   The pieces excerpted here are the same modules
   apply_multimodal_wirein dispatches to, so the chain is identical
   from the artifact's point of view. *)

module H = Multimodal.Workspace_holder
module W = Multimodal.Workspace
module B = Multimodal.Multimodal_keeper_bridge
module E = Multimodal.Keeper_emitter
module Wirein = Multimodal.Wirein_helpers
module A = Multimodal.Artifact
module Aid = Shared_types.Artifact_id
module Multimodal_routes = Masc_mcp.Server_routes_http_routes_multimodal

let now = 1_700_000_000.0

let assert_eq_int ~label expected actual =
  if expected <> actual then (
    Printf.printf "FAIL [%s]: expected %d, actual %d\n" label expected actual;
    exit 1)

let pluck_count_field json =
  match json with
  | `Assoc kv -> (
      match List.assoc_opt "count" kv with
      | Some (`Int n) -> n
      | _ -> -1)
  | _ -> -1

let pluck_artifacts_field json =
  match json with
  | `Assoc kv -> (
      match List.assoc_opt "artifacts" kv with
      | Some (`List xs) -> xs
      | _ -> [])
  | _ -> []

let kind_hint_of_artifact_json (art : Yojson.Safe.t) : string =
  match art with
  | `Assoc kv -> (
      match List.assoc_opt "kind" kv with
      | Some (`String s) -> s
      | _ -> "")
  | _ -> ""

(* ── Phase 1: producer side — emission ────────────────────────── *)
let phase1_producer_emission () =
  print_endline "── Phase 1: producer side ──";
  let entries =
    [
      ( "01900000-0000-7000-8000-000000000101",
        A.Tag_code,
        `String "let main = ()",
        `Assoc [ ("lang", `String "ocaml") ] );
      ( "01900000-0000-7000-8000-000000000102",
        A.Tag_image,
        `String "data:image/png;base64,iVBORw0K",
        `Assoc [ ("dim", `String "512x512") ] );
      ( "01900000-0000-7000-8000-000000000103",
        A.Tag_doc,
        `String "# Title\n\nBody",
        `Assoc [ ("format", `String "markdown") ] );
    ]
  in
  let wc = E.emit_many ~working_context:None entries in
  let raws_in_wc =
    match wc with
    | Some (`Assoc kv) -> (
        match List.assoc_opt "multimodal_artifacts" kv with
        | Some (`List xs) -> xs
        | _ -> [])
    | _ -> []
  in
  assert_eq_int ~label:"emitted_count" 3 (List.length raws_in_wc);
  print_endline "  emit_many ok (3 entries)";
  wc

(* ── Phase 2: consumer side — extraction ──────────────────────── *)
let phase2_consumer_extraction wc =
  print_endline "── Phase 2: consumer side ──";
  let raws, wc_rest = Wirein.extract_raw_artifacts wc in
  assert_eq_int ~label:"extracted_raws" 3 (List.length raws);
  (* multimodal_artifacts key drained from wc_rest *)
  (match wc_rest with
   | Some (`Assoc kv) ->
       assert (List.assoc_opt "multimodal_artifacts" kv = None)
   | None -> ()
   | _ -> assert false);
  print_endline "  extract_raw_artifacts ok (3 raws, key drained)";
  raws

(* ── Phase 3: hydration → workspace insertion ─────────────────── *)
let phase3_hydrate raws =
  print_endline "── Phase 3: hydrate + workspace ──";
  H.reset ();
  H.update (fun ws ->
      let ws', added =
        B.hydrate_with_workspace ws raws ~now
          ~created_by:"test-keeper"
      in
      assert_eq_int ~label:"hydrated" 3 (List.length added);
      ws');
  let snap = H.get () in
  assert_eq_int ~label:"workspace_size" 3 (W.size snap);
  print_endline "  hydrate_with_workspace ok (3 typed artifacts in holder)"

(* ── Phase 4: HTTP surface response — D1 list endpoint ────────── *)
let phase4_d1_response_via_holder () =
  print_endline "── Phase 4: D1 HTTP surface ──";
  Multimodal_routes.bind_workspace_getter H.get;
  let json = Multimodal_routes.list_response () in
  let count = pluck_count_field json in
  assert_eq_int ~label:"d1_count" 3 count;
  let artifacts = pluck_artifacts_field json in
  assert_eq_int ~label:"d1_artifacts_list_len" 3 (List.length artifacts);
  let kinds =
    List.map kind_hint_of_artifact_json artifacts |> List.sort compare
  in
  let expected = List.sort compare [ "code"; "image"; "doc" ] in
  if kinds <> expected then (
    Printf.printf "FAIL [d1_kinds]: expected %s, actual %s\n"
      (String.concat "," expected)
      (String.concat "," kinds);
    exit 1);
  print_endline "  list_response ok (3 artifacts visible to dashboard)"

(* ── Phase 5: incremental emission (turn 2) ───────────────────── *)
let phase5_incremental_turn () =
  print_endline "── Phase 5: incremental turn ──";
  (* A second turn emits one additional artifact. The K1 wire-in
     consumes only the new entry and accumulates it on top of the
     prior workspace. *)
  let wc =
    E.emit ~working_context:None
      ~id:"01900000-0000-7000-8000-000000000104"
      ~kind_tag:A.Tag_audio
      ~payload_json:(`String "data:audio/wav;base64,UklGRg==")
      ~metadata:(`Assoc [ ("duration_ms", `Int 1500) ])
  in
  let raws, _ = Wirein.extract_raw_artifacts wc in
  H.update (fun ws ->
      let ws', _ =
        B.hydrate_with_workspace ws raws ~now:(now +. 1.0)
          ~created_by:"test-keeper"
      in
      ws');
  let snap = H.get () in
  assert_eq_int ~label:"workspace_size_after_turn2" 4 (W.size snap);
  let json = Multimodal_routes.list_response () in
  assert_eq_int ~label:"d1_count_after_turn2" 4
    (pluck_count_field json);
  print_endline "  turn-2 emission flows through to dashboard (4 total)"

(* ── Phase 6: kind filter via Workspace.list_by_kind_tag ──────── *)
let phase6_kind_filter () =
  print_endline "── Phase 6: kind filter ──";
  let snap = H.get () in
  let images = W.list_by_kind_tag snap A.Tag_image in
  let codes = W.list_by_kind_tag snap A.Tag_code in
  let docs = W.list_by_kind_tag snap A.Tag_doc in
  let audios = W.list_by_kind_tag snap A.Tag_audio in
  assert_eq_int ~label:"images" 1 (List.length images);
  assert_eq_int ~label:"codes" 1 (List.length codes);
  assert_eq_int ~label:"docs" 1 (List.length docs);
  assert_eq_int ~label:"audios" 1 (List.length audios);
  print_endline "  per-kind filter ok (1 each across 4 kinds)"

let () =
  print_endline "=== K2 e2e pipeline (Cycle 27 Tier K2 — production loop) ===";
  let wc = phase1_producer_emission () in
  let raws = phase2_consumer_extraction wc in
  phase3_hydrate raws;
  phase4_d1_response_via_holder ();
  phase5_incremental_turn ();
  phase6_kind_filter ();
  print_endline
    "=== K2 e2e: 6/6 phases passed (production loop closed) ===";
  print_endline
    "    K1 wire-in seam is now provably live: producer → consumer";
  print_endline
    "    → workspace → HTTP surface chain GREEN end-to-end."
