(** Shared actor-scoped projection caching for dashboard surfaces.

    Execution and mission both derive top-level summaries from the same
    operator snapshot. Reuse short-lived actor-scoped cache entries so warm
    refresh loops and repeated navigation do not recompute identical reads. *)

(* Same partition the server-side dashboard cache uses: the directory the
   cached state lives in, not a constant (#24504). *)
let cache_partition_segment (config : Workspace_utils.config) =
  Workspace_utils.masc_dir config

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
  let previous = Stdlib.Mutex.protect candle_observation_mu (fun () ->
    Hashtbl.find_opt candle_observations base_path) in
  (* Comparing immutable observations may traverse the ledger event history.
     Do that outside the short publication lock, then confirm the same memo. *)
  let unchanged_request = match previous with
    | Some (latest_request, _, previous)
      when request_sequence = latest_request + 1 && observation = previous ->
      Some latest_request
    | Some _ | None -> None in
  Stdlib.Mutex.protect candle_observation_mu (fun () ->
    match Hashtbl.find_opt candle_observations base_path with
    | Some (latest_request, sequence, _) when request_sequence > latest_request ->
      (* A gap may hide an older in-flight read of different state. Reusing an
         earlier identity would let that read outrank this newer observation. *)
      let sequence =
        if unchanged_request = Some latest_request then sequence else request_sequence in
      Hashtbl.replace candle_observations base_path (request_sequence, sequence, observation);
      sequence
    | Some _ -> request_sequence
    | None ->
      Hashtbl.add candle_observations base_path (request_sequence, request_sequence, observation);
      request_sequence)

module String_set = Set_util.StringSet
module String_map = Set_util.StringMap

let keeper_names_in_snapshot snapshot =
  let note_row (seen, rev_acc) = function
    | `Assoc _ as json ->
      (match Json_util.assoc_string_opt "name" json with
       | Some keeper when not (String_set.mem keeper seen) ->
         String_set.add keeper seen, keeper :: rev_acc
       | Some _ | None -> seen, rev_acc)
    | _ -> seen, rev_acc
  in
  let note_rows state rows = List.fold_left note_row state rows in
  let _, rev_acc =
    match snapshot with
    | `Assoc fields ->
      List.fold_left
        (fun state -> function
          | "keepers", `Assoc section_fields ->
            List.fold_left
              (fun state -> function
                | "items", `List rows -> note_rows state rows
                | _ -> state)
              state
              section_fields
          | ("keepers" | "keeper_briefs" | "continuity_briefs"), `List rows ->
            note_rows state rows
          | "operator_targets", `Assoc target_fields ->
            List.fold_left
              (fun state -> function
                | "keepers", `List rows -> note_rows state rows
                | _ -> state)
              state
              target_fields
          | _ -> state)
        (String_set.empty, [])
        fields
    | _ -> String_set.empty, []
  in
  List.rev rev_acc

(* Equipment, balances and supply share one fresh ledger view per response.
   The ordering witness below is taken before that view is read. *)
let read_candle_for_response ~read =
  let request_sequence = Atomic.fetch_and_add candle_read_sequence 1 in
  request_sequence, read ()

let project_keeper_observations ~request_sequence ~candle ~(config : Workspace_utils.config)
    snapshot =
  let equipment = Candle_observe.equipment candle in
  let account_revision = Candle_observe.account_revision_reader candle in
  let summary = Candle_observation.to_json (Candle_observe.summary candle) in
  let board_addresses =
    match keeper_names_in_snapshot snapshot with
    | [] -> String_map.empty
    | names ->
      let pairs =
        Eio_guard.run_in_systhread
          ~label:"dashboard-keeper-board-addresses"
          (fun () ->
            List.map
              (fun keeper -> keeper, Keeper_board_address.read config keeper)
              names)
      in
      List.fold_left
        (fun acc (keeper, address) -> String_map.add keeper address acc)
        String_map.empty
        pairs
  in
  let set key value fields =
    if List.mem_assoc key fields then
      List.map (fun (name, previous) -> name, if name = key then value else previous) fields
    else (key, value) :: fields in
  (* Keep exactly the fields inserted below as the observation identity.
     The opaque ledger view also contains replay timestamps: those may change
     without changing any public value. Read authority on every request and
     share each Keeper's immutable result across this response's sections. *)
  let keeper_observations = Hashtbl.create 16 in
  let observed_fields keeper =
    match Hashtbl.find_opt keeper_observations keeper with
    | Some fields -> fields
    | None ->
      let portrait, balance, revision, address = match keeper with
        | Some keeper ->
          let portrait = match equipment ~keeper with
            | Ok value -> Keeper_portrait_equipment.Ready value
            | Error reason -> Keeper_portrait_equipment.Unavailable reason in
          let address =
            match String_map.find_opt keeper board_addresses with
            | Some address -> address
            | None -> Keeper_board_address.read config keeper
          in
          portrait, Candle_observe.balance candle ~keeper,
          account_revision ~keeper,
          address
        | None ->
          Keeper_portrait_equipment.Unavailable "Keeper name unavailable", None, None,
          Keeper_board_address.Unavailable Keeper_board_address.Metadata_absent in
      let fields = [
        "board_address", Keeper_board_address.to_yojson address;
        "portrait", Keeper_portrait_equipment.reading_to_json portrait;
        "candle_balance_milli", Json_util.option_to_yojson (fun value -> `String value) balance;
        "candle_account_revision", Json_util.option_to_yojson (fun value -> `String value) revision;
      ] in
      Hashtbl.add keeper_observations keeper fields;
      fields
  in
  let row = function
    | `Assoc fields as json ->
      let observation = observed_fields (Json_util.assoc_string_opt "name" json) in
      `Assoc (List.fold_left (fun fields (key, value) -> set key value fields) fields observation)
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
    (* This ordering witness covers every fresh row observation, including
       addresses. Equal Candle state alone must not let a delayed response
       restore an older alias after a newer configuration was displayed. *)
    let observations = Hashtbl.to_seq keeper_observations |> List.of_seq
      |> List.sort (fun (left, _) (right, _) -> Option.compare String.compare left right) in
    let observation_sequence = candle_observation_sequence
      ~base_path:config.base_path ~request_sequence (summary, observations) in
    let projected = set "candle_observation_sequence" (`Int observation_sequence) projected in
    (match List.assoc_opt "keepers" fields with
     | Some (`Assoc _) -> `Assoc projected
     | _ -> `Assoc (set "candle" summary projected))
  | json -> json

let with_current_keeper_observations_using ~read ~config snapshot =
  (* Execution and briefing read operator rows, not the Keeper HTTP roster. *)
  let request_sequence, candle = read_candle_for_response ~read in
  project_keeper_observations ~request_sequence ~candle ~config snapshot

let with_current_keeper_observations ~(config : Workspace_utils.config) snapshot =
  with_current_keeper_observations_using
    ~read:(fun () -> Candle_observe.read ~now:Time_compat.now ~base_path:config.base_path)
    ~config snapshot

let with_current_gate_keeper_observations ~(config : Workspace_utils.config) snapshot =
  let request_sequence, candle =
    read_candle_for_response
      ~read:(fun () -> Candle_observe.read ~now:Time_compat.now ~base_path:config.base_path)
  in
  let project = project_keeper_observations ~request_sequence ~candle ~config in
  (* The roster answer carries the fold's basis beside [candle], from the same
     ledger view, so a reader computes the balances and the supply at a later
     time without reading again (RFC-0481 §3.7). *)
  let decay =
    match Candle_observe.decay_basis candle with
    | Some (Ok basis) -> Candle_decay_basis.to_json basis
    | None -> `Null
    | Some (Error reason) ->
        (* The same events just folded inside the observation, so this does
           not happen; the reader then reports a ready Candle without a basis. *)
        Log.Dashboard.warn "gate roster Candle decay basis unavailable: %s" reason;
        `Null
  in
  (* Project only compact row objects; the independent [keepers] name list
     must remain untouched, including when the response also contains items. *)
  match snapshot with
  | `Assoc fields when List.mem_assoc "items" fields ->
      let items = List.assoc "items" fields in
      let projected = project (`Assoc ["keepers", items]) in
      let rows = Yojson.Safe.Util.member "keepers" projected in
      let summary = Yojson.Safe.Util.member "candle" projected in
      `Assoc (("candle", summary) :: ("candle_decay", decay) ::
        (List.remove_assoc "candle_decay" (List.remove_assoc "candle" fields)
         |> List.map (fun (key, value) -> key, if key = "items" then rows else value)))
  | _ ->
      match project snapshot with
      | `Assoc fields ->
          `Assoc (("candle_decay", decay)
                  :: List.remove_assoc "candle_observation_sequence" fields)
      | json -> json

module For_test = struct
  let with_current_keeper_observations = with_current_keeper_observations_using
end

let get_or_compute_snapshot_json ~config ~actor work =
  let actor_name = normalize_actor_name actor in
  Dashboard_cache.get_or_compute
    (actor_cache_key config "snapshot" actor_name)
    ~ttl:snapshot_cache_ttl_s (work actor_name)
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

let get_or_compute_digest_json ~config ~actor work =
  let actor_name = normalize_actor_name actor in
  Dashboard_cache.get_or_compute
    (actor_cache_key config "digest" actor_name)
    ~ttl:digest_cache_ttl_s (work actor_name)

type snapshot_read = Cached_json of Yojson.Safe.t | Observed of Dashboard_projection_read.observation

type operator_snapshot_fn = {
  snapshot : 'a.
    ?read_policy:Dashboard_projection_read.t ->
    ?actor:string ->
    ?view:string ->
    ?include_messages:bool ->
    ?include_keepers:bool ->
    ?include_summary_fields:bool ->
    ?lightweight_summary:bool ->
    'a Tool_operator.context ->
    snapshot_read;
}

type digest_observation = Dashboard_projection_read.observation = {
  json : Yojson.Safe.t;
  next_deadline_unix : float option;
  completeness : Dashboard_projection_read.completeness;
}

type operator_digest_observer = {
  observe_digest : 'a.
    ?actor:string ->
    ?target_type:string ->
    ?target_id:string ->
    ?include_workers:bool ->
    'a Tool_operator.context ->
    (digest_observation, string) result;
}

let operator_snapshot_json_ref : operator_snapshot_fn ref =
  ref { snapshot = (fun ?read_policy:_ ?actor:_ ?view:_ ?include_messages:_ ?include_keepers:_ ?include_summary_fields:_ ?lightweight_summary:_ _ctx ->
    Cached_json `Null) }

let register_operator_snapshot_json fn =
  operator_snapshot_json_ref := fn

let operator_digest_observer_ref : operator_digest_observer ref =
  ref { observe_digest = (fun ?actor:_ ?target_type:_ ?target_id:_ ?include_workers:_ _ctx ->
    Error "Operator digest observer is not registered") }

let register_operator_digest_observer fn =
  operator_digest_observer_ref := fn

let operator_snapshot_json ?read_policy ?actor ?view ?include_messages ?include_keepers ?include_summary_fields ?lightweight_summary ctx =
  (!operator_snapshot_json_ref).snapshot ?read_policy ?actor ?view ?include_messages ?include_keepers ?include_summary_fields ?lightweight_summary ctx
  |> function Cached_json json -> json | Observed observation -> observation.json

let operator_snapshot_observation ?actor ?view ?include_messages ?include_keepers ?include_summary_fields ?lightweight_summary ctx =
  match (!operator_snapshot_json_ref).snapshot ~read_policy:Dashboard_projection_read.Current
      ?actor ?view ?include_messages ?include_keepers ?include_summary_fields ?lightweight_summary ctx with
  | Observed observation -> observation
  | Cached_json _ -> invalid_arg "Current Operator Snapshot reader returned cached bytes"

let operator_digest_observation ?actor ?target_type ?target_id ?include_workers ctx =
  (!operator_digest_observer_ref).observe_digest ?actor ?target_type ?target_id ?include_workers ctx

let operator_digest_json ?actor ?target_type ?target_id ?include_workers ctx =
  operator_digest_observation ?actor ?target_type ?target_id ?include_workers ctx
  |> Result.map (fun observation -> observation.json)
