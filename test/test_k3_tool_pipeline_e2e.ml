(* Tier K3 — tool-result → multimodal pipeline e2e.

   Layer above K2: K2 proved the producer/consumer chain works
   when something explicitly calls Keeper_emitter.emit. K3 proves
   that {b tool authors do not need to know about Keeper_emitter}
   — they only need to mark their JSON output with two reserved
   keys, and Tool_emission turns the result into the same chain.

   Pipeline:

     tool surface
       │
       │ emits result_json with __multimodal_kind / __multimodal_id
       ▼
     Tool_emission.emit_from_tool_results  ← K3 (this PR)
       │
       ▼ working_context["multimodal_artifacts"]
       │
       │ Wirein_helpers.extract_raw_artifacts ← K1
       │ Multimodal_keeper_bridge.hydrate    ← W3
       │ Workspace_holder.update              ← K1
       │ list_response                        ← D1
       ▼ dashboard JSON

   The test mixes 4 tagged tool results with 2 untagged ones to
   verify that the detector ignores untagged outputs. *)

module H = Multimodal.Workspace_holder
module W = Multimodal.Workspace
module B = Multimodal.Multimodal_keeper_bridge
module Wirein = Multimodal.Wirein_helpers
module T = Multimodal.Tool_emission
module Routes = Server_routes_http_routes_multimodal

let emit = Multimodal.Keeper_emitter.emit

let now = 1_700_001_000.0

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

let make_tagged ~kind ~id ~payload_extra ~metadata : Yojson.Safe.t =
  `Assoc
    ([
       (T.multimodal_kind_key, `String kind);
       (T.multimodal_id_key, `String id);
       (T.multimodal_metadata_key, metadata);
     ]
    @ payload_extra)

let make_untagged (key : string) (value : string) : Yojson.Safe.t =
  `Assoc [ (key, `String value); ("ts", `Int 12345) ]

(* ── Phase 1: simulated tool surface emits 6 results ─────────── *)
let phase1_tool_surface_emits () =
  print_endline "── Phase 1: tool surface emits 6 results ──";
  let results =
    [
      (* Tagged — should flow through *)
      make_tagged ~kind:"code"
        ~id:"01900000-0000-7000-8000-000000000201"
        ~payload_extra:[ ("source", `String "let x = 1") ]
        ~metadata:(`Assoc [ ("lang", `String "ml") ]);
      make_tagged ~kind:"image"
        ~id:"01900000-0000-7000-8000-000000000202"
        ~payload_extra:[ ("data_url", `String "data:image/png") ]
        ~metadata:(`Assoc [ ("dim", `String "1024x768") ]);
      (* Untagged — should be ignored *)
      make_untagged "echoed_text" "tool returned plain string";
      make_tagged ~kind:"audio"
        ~id:"01900000-0000-7000-8000-000000000203"
        ~payload_extra:[ ("wav_b64", `String "RIFF...") ]
        ~metadata:(`Assoc [ ("dur_ms", `Int 800) ]);
      (* Untagged — should be ignored *)
      make_untagged "search_hits" "no multimodal tag here";
      make_tagged ~kind:"doc"
        ~id:"01900000-0000-7000-8000-000000000204"
        ~payload_extra:[ ("body", `String "# Title\n") ]
        ~metadata:(`Assoc [ ("format", `String "md") ]);
    ]
  in
  let wc = T.emit_from_tool_results ~emit ~working_context:None results in
  let raws_in_wc =
    match wc with
    | Some (`Assoc kv) -> (
        match List.assoc_opt "multimodal_artifacts" kv with
        | Some (`List xs) -> xs
        | _ -> [])
    | _ -> []
  in
  assert_eq_int ~label:"emitted_count" 4 (List.length raws_in_wc);
  print_endline "  6 results in, 4 emitted (2 untagged ignored)";
  wc

(* ── Phase 2: K1 wirein consumes ──────────────────────────────── *)
let phase2_consumer wc =
  print_endline "── Phase 2: K1 wirein consumes ──";
  let raws, wc_rest = Result.get_ok (Wirein.extract_raw_artifacts wc) in
  assert_eq_int ~label:"extracted" 4 (List.length raws);
  (match wc_rest with
   | Some (`Assoc kv) ->
       assert (List.assoc_opt "multimodal_artifacts" kv = None)
   | _ -> ());
  print_endline "  4 raws extracted, key drained";
  raws

(* ── Phase 3: hydrate + workspace_holder ─────────────────────── *)
let phase3_hydrate raws =
  print_endline "── Phase 3: hydrate + workspace_holder ──";
  H.reset ();
  H.update (fun ws ->
      let ws', added =
        B.hydrate_with_workspace ws raws ~now ~created_by:"k3-test"
      in
      assert_eq_int ~label:"hydrated" 4 (List.length added);
      ws');
  let snap = H.get () in
  assert_eq_int ~label:"workspace_size" 4 (W.size snap);
  print_endline "  4 typed artifacts in workspace_holder"

(* ── Phase 4: D1 HTTP envelope ────────────────────────────────── *)
let phase4_dashboard () =
  print_endline "── Phase 4: D1 HTTP envelope ──";
  Routes.bind_workspace_getter H.get;
  let json = Routes.list_response () in
  assert_eq_int ~label:"d1_count" 4 (pluck_count_field json);
  let arts = pluck_artifacts_field json in
  assert_eq_int ~label:"d1_arts_len" 4 (List.length arts);
  print_endline "  dashboard sees 4 artifacts"

(* ── Phase 5: payload_json reserved-key strip verification ───── *)
let phase5_payload_strip_verification () =
  print_endline "── Phase 5: payload_json reserved-key strip ──";
  let snap = H.get () in
  let arts = W.all snap in
  List.iter
    (fun (any : Multimodal.Artifact.any) ->
      let json = Multimodal.Artifact.any_to_json any in
      let payload =
        match json with
        | `Assoc kv -> (
            match List.assoc_opt "payload" kv with
            | Some p -> p
            | None -> `Null)
        | _ -> `Null
      in
      let payload_json =
        match payload with
        | `Assoc pkv -> (
            match List.assoc_opt "lazy" pkv with
            | Some j -> j
            | None -> payload)
        | other -> other
      in
      (match payload_json with
       | `Assoc kv ->
           assert (
             List.assoc_opt T.multimodal_kind_key kv = None);
           assert (List.assoc_opt T.multimodal_id_key kv = None);
           assert (
             List.assoc_opt T.multimodal_metadata_key kv = None)
       | _ -> ()))
    arts;
  print_endline "  no reserved keys leak into hydrated payload"

let () =
  print_endline "=== K3 e2e tool pipeline (Cycle 27 — tool author seam) ===";
  let wc = phase1_tool_surface_emits () in
  let raws = phase2_consumer wc in
  phase3_hydrate raws;
  phase4_dashboard ();
  phase5_payload_strip_verification ();
  print_endline "=== K3 e2e: 5/5 phases passed ===";
  print_endline
    "    Tool authors only need to set 2 reserved keys —";
  print_endline
    "    Tool_emission converts to typed artifacts deterministically."
