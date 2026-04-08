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
    let dir = Filename.concat base_path ".masc/discovery" in
    let s = Dated_jsonl.create ~base_dir:dir () in
    store_ref := Some (base_path, s);
    s

(* ── Serialization ────────────────────────────────────────── *)

type probe_record = {
  ts : float;
  endpoint_url : string;
  healthy : bool;
  model_id : string option;
  ctx_size : int option;
  total_slots : int option;
  busy_slots : int option;
  idle_slots : int option;
}

let endpoint_to_record (e : Llm_provider.Discovery.endpoint_status) : probe_record =
  let open Llm_provider.Discovery in
  {
    ts = Time_compat.now ();
    endpoint_url = e.url;
    healthy = e.healthy;
    model_id = (match e.models with m :: _ -> Some m.id | [] -> None);
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
  let extras =
    opt "model_id" (fun s -> `String s) r.model_id
    @ opt "ctx_size" (fun n -> `Int n) r.ctx_size
    @ opt "total_slots" (fun n -> `Int n) r.total_slots
    @ opt "busy_slots" (fun n -> `Int n) r.busy_slots
    @ opt "idle_slots" (fun n -> `Int n) r.idle_slots
  in
  `Assoc (base @ extras)

(* ── Write ────────────────────────────────────────────────── *)

let record_probe ~base_path (endpoints : Llm_provider.Discovery.endpoint_status list) =
  try
    let store = get_or_create_store ~base_path in
    List.iter (fun ep ->
      let r = endpoint_to_record ep in
      let json = record_to_json r in
      Dated_jsonl.append store json
    ) endpoints
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Discovery.error "discovery_history: append failed: %s"
      (Printexc.to_string exn)

(* ── Read ─────────────────────────────────────────────────── *)

let read_recent ~base_path ~count : Yojson.Safe.t list =
  try
    let store = get_or_create_store ~base_path in
    Dated_jsonl.read_recent store count
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Discovery.error "discovery_history: read failed: %s"
      (Printexc.to_string exn);
    []

let read_range ~base_path ~since ~until : Yojson.Safe.t list =
  try
    let store = get_or_create_store ~base_path in
    Dated_jsonl.read_range store ~since ~until
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Discovery.error "discovery_history: read_range failed: %s"
      (Printexc.to_string exn);
    []

(* ── Prune ────────────────────────────────────────────────── *)

let prune ~base_path ~days =
  try
    let store = get_or_create_store ~base_path in
    let deleted = Dated_jsonl.prune store ~days in
    if deleted > 0 then
      Log.Discovery.info "discovery_history: pruned %d old day-files" deleted
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Discovery.error "discovery_history: prune failed: %s"
      (Printexc.to_string exn)
