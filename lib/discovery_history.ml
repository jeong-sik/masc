(** Discovery_history — time-series persistence of LLM endpoint probe results.

    Records each Discovery_cache refresh to a {!Dated_jsonl} store under
    [.masc/discovery/YYYY-MM/DD.jsonl]. No buffering: appends happen inline
    with cache refresh since probes fire every ~30-60s.

    Closes #5776. @since 2.259.0 *)

(* ── Store singleton ──────────────────────────────────────── *)

let store_ref : (string * Dated_jsonl.t) option ref = ref None

let get_or_create_store ~base_path : Dated_jsonl.t =
  match !store_ref with
  | Some (cached_path, s) when String.equal cached_path base_path -> s
  | _ ->
    let dir =
      Filename.concat
        (Common.masc_dir_from_base_path ~base_path)
        "discovery"
    in
    let s = Dated_jsonl.create ~base_dir:dir () in
    store_ref := Some (base_path, s);
    s

(* ── Serialization ────────────────────────────────────────── *)

(* #10404: pre-fix this record stored only the head of [e.models] in
   [model_id], silently discarding 6 of 7 loaded ollama models.  Across
   2026-04-22..25 every one of 164 probes recorded "qwen3:8b" while
   four cascades reference "qwen3.6:27b-coding-nvfp4".  Add a [models]
   list that preserves the full probe payload, and keep [model_id]
   populated with the head for any external reader that already
   indexes by it. *)
type probe_record = {
  ts : float;
  endpoint_url : string;
  healthy : bool;
  model_id : string option;
  models : string list;
  ctx_size : int option;
  total_slots : int option;
  busy_slots : int option;
  idle_slots : int option;
}

let endpoint_to_record (e : Llm_provider.Discovery.endpoint_status) : probe_record =
  let open Llm_provider.Discovery in
  let models = List.map (fun m -> m.id) e.models in
  {
    ts = Time_compat.now ();
    endpoint_url = e.url;
    healthy = e.healthy;
    model_id = (match models with m :: _ -> Some m | [] -> None);
    models;
    ctx_size = Option.map (fun (p : server_props) -> p.ctx_size) e.props;
    total_slots = Option.map (fun (s : slot_status) -> s.total) e.slots;
    busy_slots = Option.map (fun (s : slot_status) -> s.busy) e.slots;
    idle_slots = Option.map (fun (s : slot_status) -> s.idle) e.slots;
  }

let record_to_json (r : probe_record) : Yojson.Safe.t =
  let base =
    [ ("ts", `Float r.ts)
    ; ("endpoint_url", `String r.endpoint_url)
    ; ("healthy", `Bool r.healthy)
    ]
  in
  let opt key f = function Some v -> [(key, f v)] | None -> [] in
  let models_field =
    if r.models = [] then []
    else
      [ ("models", `List (List.map (fun s -> `String s) r.models)) ]
  in
  let extras =
    opt "model_id" (fun s -> `String s) r.model_id
    @ models_field
    @ opt "ctx_size" (fun n -> `Int n) r.ctx_size
    @ opt "total_slots" (fun n -> `Int n) r.total_slots
    @ opt "busy_slots" (fun n -> `Int n) r.busy_slots
    @ opt "idle_slots" (fun n -> `Int n) r.idle_slots
  in
  `Assoc (base @ extras)

(* ── Write ────────────────────────────────────────────────── *)

let failure_site_label = function
  | "record_probe"
  | "read_recent"
  | "read_range"
  | "prune" as site -> site
  | _ -> "unknown"

let observe_failure ~site ~base_path exn =
  match exn with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      let site = failure_site_label site in
      Prometheus.inc_counter Prometheus.metric_discovery_history_failures
        ~labels:[("site", site)]
        ();
      Log.Discovery.error "discovery_history: %s failed base_path=%s: %s"
        site base_path (Printexc.to_string exn)

module For_testing = struct
  let observe_failure = observe_failure
end

let record_probe ~base_path (endpoints : Llm_provider.Discovery.endpoint_status list) =
  try
    let store = get_or_create_store ~base_path in
    List.iter (fun ep ->
      let r = endpoint_to_record ep in
      let json = record_to_json r in
      Dated_jsonl.append store json
    ) endpoints
  with exn ->
    observe_failure ~site:"record_probe" ~base_path exn

(* ── Read ─────────────────────────────────────────────────── *)

let read_recent ~base_path ~count : Yojson.Safe.t list =
  try
    let store = get_or_create_store ~base_path in
    Dated_jsonl.read_recent store count
  with exn ->
    observe_failure ~site:"read_recent" ~base_path exn;
    []

let read_range ~base_path ~since ~until : Yojson.Safe.t list =
  try
    let store = get_or_create_store ~base_path in
    Dated_jsonl.read_range store ~since ~until
  with exn ->
    observe_failure ~site:"read_range" ~base_path exn;
    []

(* ── Prune ────────────────────────────────────────────────── *)

let prune ~base_path ~days =
  try
    let store = get_or_create_store ~base_path in
    let deleted = Dated_jsonl.prune store ~days in
    if deleted > 0 then
      Log.Discovery.info "discovery_history: pruned %d old day-files" deleted
  with exn ->
    observe_failure ~site:"prune" ~base_path exn
