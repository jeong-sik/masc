(** Shared actor-scoped projection caching for dashboard surfaces.

    Execution and mission both derive top-level summaries from the same
    operator snapshot. Reuse short-lived actor-scoped cache entries so warm
    refresh loops and repeated navigation do not recompute identical reads. *)

(* Same partition the server-side dashboard cache uses: the directory the
   cached state lives in, not a constant (#24504). *)
let cache_partition_segment (config : Workspace_utils.config) =
  Workspace_utils.masc_root_dir config

let actor_cache_key (config : Workspace_utils.config) prefix actor_name =
  Printf.sprintf "%s:%s:%s" prefix (cache_partition_segment config) actor_name

let normalize_actor_name = function
  | Some value ->
      let trimmed = String.trim value in
      if trimmed <> "" then trimmed else "dashboard"
  | None -> "dashboard"

let snapshot_cache_ttl_s = 10.0
let digest_cache_ttl_s = 10.0
let snapshot_publication_mu = Stdlib.Mutex.create ()
let snapshot_invalidation_generation_ref = Atomic.make 0
let snapshot_generation_observer : (int -> unit) option Atomic.t = Atomic.make None

let register_snapshot_generation_observer observer =
  Atomic.set snapshot_generation_observer (Some observer)
;;

let snapshot_invalidation_generation () =
  Atomic.get snapshot_invalidation_generation_ref
;;

let with_snapshot_publication_generation f =
  Stdlib.Mutex.protect snapshot_publication_mu (fun () ->
    f (Atomic.get snapshot_invalidation_generation_ref))
;;

(* Order read admission, independently of metadata cache invalidation. A slow
   older read keeps its older identity even when it finishes after a new read.
   Equal immutable observations reuse their identity, preserving encoded-cache
   reuse when neither ledger state nor clock-derived balances changed. *)
let candle_read_sequence = Atomic.make 0
let candle_observation_mu = Stdlib.Mutex.create ()
let candle_observations = Hashtbl.create 4

let candle_observation_sequence ~base_path ~request_sequence observation =
  Stdlib.Mutex.protect candle_observation_mu (fun () ->
    match Hashtbl.find_opt candle_observations base_path with
    | Some (latest_request, sequence, previous) when request_sequence > latest_request ->
      let sequence = if observation = previous then sequence else request_sequence in
      Hashtbl.replace candle_observations base_path (request_sequence, sequence, observation);
      sequence
    | Some _ -> request_sequence
    | None ->
      Hashtbl.add candle_observations base_path (request_sequence, request_sequence, observation);
      request_sequence)

let with_current_keeper_observations ~(config : Workspace_utils.config) snapshot =
  (* Execution and briefing read operator rows, not the Keeper HTTP roster.
     Equipment, balances and supply share one fresh ledger view per response. *)
  let request_sequence = Atomic.fetch_and_add candle_read_sequence 1 in
  let candle = Candle_observe.read ~now:Time_compat.now ~base_path:config.base_path in
  let observation_sequence = candle_observation_sequence
    ~base_path:config.base_path ~request_sequence candle in
  let equipment = Candle_observe.equipment candle in
  let revisions = Hashtbl.create 16 in
  let account_revision keeper =
    match Hashtbl.find_opt revisions keeper with
    | Some revision -> revision
    | None ->
      let revision = Candle_observe.account_revision candle ~keeper in
      Hashtbl.add revisions keeper revision;
      revision
  in
  let summary = Candle_observation.to_json (Candle_observe.summary candle) in
  let set key value fields =
    if List.mem_assoc key fields then
      List.map (fun (name, previous) -> name, if name = key then value else previous) fields
    else (key, value) :: fields in
  let row = function
    | `Assoc fields as json ->
      let portrait = match Json_util.assoc_string_opt "name" json with
        | Some keeper -> (match equipment ~keeper with
            | Ok value -> Keeper_portrait_equipment.Ready value
            | Error reason -> Keeper_portrait_equipment.Unavailable reason)
        | None -> Keeper_portrait_equipment.Unavailable "Keeper name unavailable" in
      let value = Keeper_portrait_equipment.reading_to_json portrait in
      let balance = match Json_util.assoc_string_opt "name" json with
        | Some keeper -> Candle_observe.balance candle ~keeper
        | None -> None in
      let account_revision = match Json_util.assoc_string_opt "name" json with
        | Some keeper -> account_revision keeper
        | None -> None in
      `Assoc (fields |> set "portrait" value
        |> set "candle_balance_milli" (Json_util.option_to_yojson (fun value -> `String value) balance)
        |> set "candle_account_revision" (Json_util.option_to_yojson (fun value -> `String value) account_revision))
    | json -> json in
  let section fields = List.map (function
    | "items", `List rows -> "items", `List (List.map row rows)
    | field -> field) fields |> set "candle" summary in
  match snapshot with
  | `Assoc fields ->
    let projected = List.map (function
      | "keepers", `Assoc fields -> "keepers", `Assoc (section fields)
      | ("keepers" | "keeper_briefs" | "continuity_briefs") as key, `List rows -> key, `List (List.map row rows)
      | "operator_targets", `Assoc fields ->
        "operator_targets", `Assoc (List.map (function
          | "keepers", `List rows -> "keepers", `List (List.map row rows)
          | field -> field) fields)
      | field -> field) fields in
    let projected = set "candle_observation_sequence" (`Int observation_sequence) projected in
    (match List.assoc_opt "keepers" fields with
     | Some (`Assoc _) -> `Assoc projected
     | _ -> `Assoc (set "candle" summary projected))
  | json -> json

let get_or_compute_snapshot_json ~config ~actor compute =
  let actor_name = normalize_actor_name actor in
  Dashboard_cache.get_or_compute
    (actor_cache_key config "snapshot" actor_name)
    ~ttl:snapshot_cache_ttl_s (fun () -> compute actor_name)
  |> with_current_keeper_observations ~config

let invalidate_snapshot_json ~config =
  let generation =
    Stdlib.Mutex.protect snapshot_publication_mu (fun () ->
      Dashboard_cache.invalidate_prefix (actor_cache_key config "snapshot" "");
      Dashboard_cache.invalidate_prefix (actor_cache_key config "digest" "");
      Dashboard_cache.invalidate_prefix "operator_snapshot:";
      Atomic.fetch_and_add snapshot_invalidation_generation_ref 1 + 1)
  in
  (* The callback intentionally runs after the generation lock is released.
     It must use the publication owner's generation/terminal CAS rather than
     fabricating an envelope from a later cache read: callbacks may arrive out
     of order under concurrent invalidations. *)
  match Atomic.get snapshot_generation_observer with
  | None -> ()
  | Some observer ->
    (try observer generation with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Dashboard.warn
         "snapshot generation observer failed generation=%d: %s"
         generation
         (Printexc.to_string exn))
;;

let get_or_compute_digest_json ~config ~actor compute =
  let actor_name = normalize_actor_name actor in
  Dashboard_cache.get_or_compute
    (actor_cache_key config "digest" actor_name)
    ~ttl:digest_cache_ttl_s (fun () -> compute actor_name)

type operator_snapshot_fn = {
  snapshot : 'a.
    ?actor:string ->
    ?view:string ->
    ?include_messages:bool ->
    ?include_keepers:bool ->
    ?include_summary_fields:bool ->
    ?lightweight_summary:bool ->
    'a Tool_operator.context ->
    Yojson.Safe.t;
}

type operator_digest_fn = {
  digest : 'a.
    ?actor:string ->
    ?target_type:string ->
    ?target_id:string ->
    ?include_workers:bool ->
    'a Tool_operator.context ->
    (Yojson.Safe.t, string) result;
}

let operator_snapshot_json_ref : operator_snapshot_fn ref =
  ref { snapshot = (fun ?actor:_ ?view:_ ?include_messages:_ ?include_keepers:_ ?include_summary_fields:_ ?lightweight_summary:_ _ctx ->
    `Null) }

let register_operator_snapshot_json fn =
  operator_snapshot_json_ref := fn

let operator_digest_json_ref : operator_digest_fn ref =
  ref { digest = (fun ?actor:_ ?target_type:_ ?target_id:_ ?include_workers:_ _ctx ->
    Ok `Null) }

let register_operator_digest_json fn =
  operator_digest_json_ref := fn

let operator_snapshot_json ?actor ?view ?include_messages ?include_keepers ?include_summary_fields ?lightweight_summary ctx =
  (!operator_snapshot_json_ref).snapshot ?actor ?view ?include_messages ?include_keepers ?include_summary_fields ?lightweight_summary ctx

let operator_digest_json ?actor ?target_type ?target_id ?include_workers ctx =
  (!operator_digest_json_ref).digest ?actor ?target_type ?target_id ?include_workers ctx
