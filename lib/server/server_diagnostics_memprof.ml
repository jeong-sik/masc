(* Rows per table. Enough to name the subsystems that matter without
   shipping every one-off call site; the totals cover the rest. *)
let rows_per_table = 30

let report_json () =
  Alloc_profile.report_to_yojson (Alloc_profile.report ~top:rows_per_table)
;;

type request_error = Invalid_query | Instance_changed | Profile_changed | Unknown_site

let error_status = function
  | Invalid_query -> `Bad_request
  | Instance_changed | Profile_changed -> `Conflict
  | Unknown_site -> `Not_found

let error_json error =
  let code = match error with
    | Invalid_query -> "invalid_memprof_query"
    | Instance_changed -> "memprof_instance_changed"
    | Profile_changed -> "memprof_profile_changed"
    | Unknown_site -> "memprof_unknown_site" in
  `Assoc ["error", `String code; "code", `String code]

let values query name =
  List.concat_map (fun (key, values) -> if String.equal key name then values else []) query

let single query name =
  match List.filter (fun (key,_) -> String.equal key name) query with
  | [] -> Ok None
  | [(_, [value])] when not (String.equal value "") -> Ok (Some value)
  | _ :: _ -> Error Invalid_query

let ( let* ) = Result.bind

let identity_query ~required ~stacks query =
  let allowed = List.for_all (fun (name, values) -> values<>[] && match name with
    | "runtime_instance_id" | "epoch" | "sampling_rate" -> true
    | "expected_base_path" | "expected_masc_root" -> true
    | "id" -> stacks
    | _ -> false) query in
  if not allowed then Error Invalid_query else
  let* instance = single query "runtime_instance_id" in
  let* epoch = single query "epoch" in
  let* sampling_rate = single query "sampling_rate" in
  match instance, epoch, sampling_rate with
  | None, None, None when not required -> Ok None
  | Some instance, Some epoch, Some sampling_rate ->
    (match int_of_string_opt epoch, float_of_string_opt sampling_rate with
     | Some epoch, Some sampling_rate when epoch >= 0
         && Float.is_finite sampling_rate && sampling_rate >= 0.0 ->
       if not (String.equal instance Build_identity.runtime_instance_id)
       then Error Instance_changed
       else Ok (Some ({Alloc_profile.epoch; sampling_rate} : Alloc_profile.counter_identity))
     | Some _, Some _ | Some _, None | None, Some _ | None, None -> Error Invalid_query)
  | None, None, None | Some _, Some _, None | Some _, None, Some _
  | None, Some _, Some _ | Some _, None, None | None, Some _, None | None, None, Some _ ->
    Error Invalid_query

let identity_fields (identity : Alloc_profile.counter_identity) =
  [ "runtime_instance_id", `String Build_identity.runtime_instance_id
  ; "epoch", `Int identity.epoch
  ; "sampling_rate", `Float identity.sampling_rate ]

let count_fields (counts : Alloc_profile.sample_counters) =
  [ "allocated_samples", `Int counts.allocated_samples
  ; "starting_domain_samples", `Int counts.starting_domain_samples
  ; "major_samples", `Int counts.major_samples
  ; "direct_major_samples", `Int counts.direct_major_samples
  ; "live_samples", `Int counts.live_samples ]

let counters_json ~query =
  let* expected = identity_query ~required:false ~stacks:false query in
  let snapshot = Alloc_profile.counter_snapshot () in
  match expected with
  | Some expected when expected <> snapshot.identity -> Error Profile_changed
  | None | Some _ ->
    let rows = List.map (fun ({id; counts} : Alloc_profile.site_counters) ->
      `Assoc (("id", `Int (id :> int)) :: count_fields counts)) snapshot.counters in
    Ok (`Assoc (identity_fields snapshot.identity @
      [ "schema", `String "alloc-profile-counters-v1"
      ; "sampling", `Bool snapshot.sampling
      ; "word_bytes", `Int (Sys.word_size / 8)
      ; "dropped_samples", `Int snapshot.dropped_samples
      ; "pending_events", `Int snapshot.pending_events
      ; "sites", `Int (List.length snapshot.counters)
      ; "site_bound", `Int Alloc_profile.max_sites
      ; "overflow_id", (match snapshot.overflow_id with None -> `Null | Some id -> `Int (id :> int))
      ; "totals", `Assoc (count_fields snapshot.totals)
      ; "counters", `List rows ]))

let stacks_json ~query =
  let* expected = identity_query ~required:true ~stacks:true query in
  let* expected = match expected with None -> Error Invalid_query | Some identity -> Ok identity in
  let rec parse_ids acc = function
    | [] -> if acc=[] then Error Invalid_query else Ok acc
    | value :: rest ->
      (match Option.bind (int_of_string_opt value) Alloc_profile.site_id_of_int with
       | None -> Error Invalid_query
       | Some id -> parse_ids (id :: acc) rest) in
  let* ids = parse_ids [] (values query "id") in
  match Alloc_profile.callstacks ~expected ids with
  | Error Alloc_profile.Profile_changed -> Error Profile_changed
  | Error (Alloc_profile.Unknown_site _) -> Error Unknown_site
  | Ok stacks ->
    Ok (`Assoc (identity_fields expected @
      ["stacks", `List (List.map (fun ((id : Alloc_profile.site_id), stack) ->
        `Assoc ["id", `Int (id :> int); "callstack", `String stack]) stacks)]))

let counters_path = "/api/v1/diagnostics/memprof/counters"
let stacks_path = "/api/v1/diagnostics/memprof/stacks"

let register_counter_routes router =
  let handler produce _state _actor request reqd =
    let query = Uri.query (Uri.of_string request.Httpun.Request.target) in
    let result = Pool_work.submit (Pool_work.cpu ~name:__FUNCTION__ (fun () -> produce ~query)) in
    let status, json = match result with
      | Ok json -> `OK, json
      | Error error -> (error_status error :> Httpun.Status.t), error_json error in
    let inherited = Http_server_eio.Response.scoped_headers () |> List.filter (fun (name,_) ->
      not (String.equal (String.lowercase_ascii name) "cache-control")) in
    Http_server_eio.Response.with_scoped_headers (("cache-control", "no-store") :: inherited) (fun () ->
      Http_server_eio.Response.json_value_on_cpu ~status ~compress:true ~request json reqd) in
  router
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) counters_path (handler counters_json)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) stacks_path (handler stacks_json)
