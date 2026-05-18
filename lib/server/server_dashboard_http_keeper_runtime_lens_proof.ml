(** Runtime-lens proof aggregation for keeper runtime trace responses.

    Split from {!Server_dashboard_http_keeper_api}; this module keeps the
    tool-call proof scanner independent from HTTP handler assembly. *)

open Server_dashboard_http_keeper_api_types

type runtime_lens_proof_acc =
  { mutable matched_tool_call_count : int
  ; mutable successful_tool_call_count : int
  ; mutable failed_tool_call_count : int
  ; mutable latest_ts : float option
  ; mutable docker_visible : bool
  ; mutable git_credentials_enabled : bool
  ; mutable github_identity_materialized : bool
  ; mutable pr_create_observed : bool
  ; tools : (string, unit) Hashtbl.t
  ; successful_tools : (string, unit) Hashtbl.t
  ; failed_tools : (string, unit) Hashtbl.t
  ; sandbox_profiles : (string, unit) Hashtbl.t
  ; network_modes : (string, unit) Hashtbl.t
  }

let runtime_lens_proof_acc () =
  { matched_tool_call_count = 0
  ; successful_tool_call_count = 0
  ; failed_tool_call_count = 0
  ; latest_ts = None
  ; docker_visible = false
  ; git_credentials_enabled = false
  ; github_identity_materialized = false
  ; pr_create_observed = false
  ; tools = Hashtbl.create 8
  ; successful_tools = Hashtbl.create 8
  ; failed_tools = Hashtbl.create 8
  ; sandbox_profiles = Hashtbl.create 4
  ; network_modes = Hashtbl.create 4
  }

let json_string_list values = `List (List.map (fun value -> `String value) values)

let string_contains ~needle value =
  let value = String.lowercase_ascii value in
  let needle = String.lowercase_ascii needle in
  let value_len = String.length value in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else
    let rec loop idx =
      idx + needle_len <= value_len
      && (String.equal (String.sub value idx needle_len) needle || loop (idx + 1))
    in
    loop 0

let runtime_lens_set_add table value =
  let value = String.trim value in
  if value <> "" then Hashtbl.replace table value ()

let runtime_lens_sorted_set table =
  Hashtbl.fold (fun value () acc -> value :: acc) table []
  |> List.sort_uniq String.compare

let runtime_lens_update_latest_ts acc json =
  let ts_opt =
    match Yojson.Safe.Util.member "ts" json with
    | `Float value -> Some value
    | `Int value -> Some (Float.of_int value)
    | _ -> None
  in
  match ts_opt with
  | Some ts ->
      acc.latest_ts <-
        (match acc.latest_ts with
         | Some previous when previous >= ts -> acc.latest_ts
         | _ -> Some ts)
  | None -> ()

let rec runtime_lens_json_string_values field = function
  | `Assoc fields ->
      let direct =
        match List.assoc_opt field fields with
        | Some (`String value) -> [ value ]
        | _ -> []
      in
      direct
      @ List.concat_map
          (fun (_, value) -> runtime_lens_json_string_values field value)
          fields
  | `List values -> List.concat_map (runtime_lens_json_string_values field) values
  | _ -> []

let rec runtime_lens_json_bool_values field = function
  | `Assoc fields ->
      let direct =
        match List.assoc_opt field fields with
        | Some (`Bool value) -> [ value ]
        | _ -> []
      in
      direct
      @ List.concat_map
          (fun (_, value) -> runtime_lens_json_bool_values field value)
          fields
  | `List values -> List.concat_map (runtime_lens_json_bool_values field) values
  | _ -> []

let runtime_lens_has_string_field json field expected =
  runtime_lens_json_string_values field json
  |> List.exists (String.equal expected)

let runtime_lens_has_true_field json field =
  runtime_lens_json_bool_values field json |> List.exists Fun.id

let runtime_lens_tool_text json =
  let input = Yojson.Safe.Util.member "input" json |> Yojson.Safe.to_string in
  let output = Option.value (tool_call_output_text_opt json) ~default:"" in
  input ^ "\n" ^ output

let runtime_lens_text_contains text needle =
  string_contains ~needle text

let runtime_lens_call_has_docker_proof json output_opt text =
  json_string_member_opt "sandbox_profile" json = Some "docker"
  || json_string_member_opt "sandbox_profile" (tool_call_runtime_contract json)
     = Some "docker"
  || runtime_lens_text_contains text "\"sandbox_profile\":\"docker\""
  || runtime_lens_text_contains text "\"via\":\"docker\""
  ||
  match output_opt with
  | Some output ->
      runtime_lens_has_string_field output "sandbox_profile" "docker"
      || runtime_lens_has_string_field output "via" "docker"
  | None -> false

let runtime_lens_call_has_git_credentials output_opt text =
  runtime_lens_text_contains text "\"git_creds_enabled\":true"
  ||
  match output_opt with
  | Some output -> runtime_lens_has_true_field output "git_creds_enabled"
  | None -> false

let runtime_lens_call_has_github_identity output_opt text =
  let structured =
    match output_opt with
    | Some output ->
        runtime_lens_has_string_field output "credential_scope" "keeper_identity"
        &&
        (runtime_lens_has_string_field output "git_identity_mode" "github_identity"
         || runtime_lens_has_string_field output "state" "materialized")
    | None -> false
  in
  structured
  ||
  (runtime_lens_text_contains text "\"credential_scope\":\"keeper_identity\""
   &&
   (runtime_lens_text_contains text "\"git_identity_mode\":\"github_identity\""
    || runtime_lens_text_contains text
         "\"credential_state\":{\"state\":\"materialized\""))

let runtime_lens_collect_profile acc json =
  let add_from table field source =
    match json_string_member_opt field source with
    | Some value -> runtime_lens_set_add table value
    | None -> ()
  in
  add_from acc.sandbox_profiles "sandbox_profile" json;
  add_from acc.sandbox_profiles "sandbox_profile" (tool_call_runtime_contract json);
  add_from acc.network_modes "network_mode" json;
  add_from acc.network_modes "network_mode" (tool_call_runtime_contract json)

let runtime_lens_accumulate_tool_proof acc json =
  acc.matched_tool_call_count <- acc.matched_tool_call_count + 1;
  runtime_lens_update_latest_ts acc json;
  let tool = Option.value (json_string_member_opt "tool" json) ~default:"unknown_tool" in
  runtime_lens_set_add acc.tools tool;
  if json_bool_member_opt "success" json = Some true then (
    acc.successful_tool_call_count <- acc.successful_tool_call_count + 1;
    runtime_lens_set_add acc.successful_tools tool)
  else (
    acc.failed_tool_call_count <- acc.failed_tool_call_count + 1;
    runtime_lens_set_add acc.failed_tools tool);
  if String.equal tool "keeper_pr_create" then acc.pr_create_observed <- true;
  runtime_lens_collect_profile acc json;
  let output_opt = parse_tool_output_json_opt json in
  let text = runtime_lens_tool_text json in
  if runtime_lens_call_has_docker_proof json output_opt text
  then acc.docker_visible <- true;
  if runtime_lens_call_has_git_credentials output_opt text
  then acc.git_credentials_enabled <- true;
  if runtime_lens_call_has_github_identity output_opt text
  then acc.github_identity_materialized <- true

let runtime_lens_runtime_proof_json ~keeper_name ~trace_id ?turn_id () =
  let acc = runtime_lens_proof_acc () in
  Keeper_tool_call_log.read_recent ~keeper_name ~n:200 ()
  |> List.iter (fun json ->
       if tool_call_matches_trace ?turn_id ~keeper_name ~trace_id json
       then runtime_lens_accumulate_tool_proof acc json);
  let status =
    if
      acc.docker_visible
      && (acc.git_credentials_enabled || acc.github_identity_materialized)
    then "pass"
    else if
      acc.matched_tool_call_count > 0
      && (acc.docker_visible
          || acc.git_credentials_enabled
          || acc.github_identity_materialized)
    then "warn"
    else "missing"
  in
  `Assoc
    [ ("source", `String "keeper_tool_call_log")
    ; ("status", `String status)
    ; ("matched_tool_call_count", `Int acc.matched_tool_call_count)
    ; ("successful_tool_call_count", `Int acc.successful_tool_call_count)
    ; ("failed_tool_call_count", `Int acc.failed_tool_call_count)
    ; ("tools", json_string_list (runtime_lens_sorted_set acc.tools))
    ; ( "successful_tools",
        json_string_list (runtime_lens_sorted_set acc.successful_tools) )
    ; ("failed_tools", json_string_list (runtime_lens_sorted_set acc.failed_tools))
    ; ( "sandbox_profiles",
        json_string_list (runtime_lens_sorted_set acc.sandbox_profiles) )
    ; ("network_modes", json_string_list (runtime_lens_sorted_set acc.network_modes))
    ; ("docker_visible", `Bool acc.docker_visible)
    ; ("git_credentials_enabled", `Bool acc.git_credentials_enabled)
    ; ("github_identity_materialized", `Bool acc.github_identity_materialized)
    ; ("pr_create_observed", `Bool acc.pr_create_observed)
    ; ( "latest_at",
        match acc.latest_ts with
        | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
        | None -> `Null )
    ]
