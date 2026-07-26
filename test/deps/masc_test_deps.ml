(* Shared dependency re-export for MASC test suite.
   Also hosts tiny test helpers that need a single SSOT across files. *)

module Server_grpc_tool_dispatch = Server_grpc_tool_dispatch

(** Install the Eio clock + optional switch in every registry the lib
    code reads from.

    MASC stores clock state in two places: [Time_compat] (sleep/now) and
    [Eio_context] (Dashboard_cache and other lib/ code that needs the raw
    [float Eio.Time.clock_ty]). Historically harnesses called only
    [Time_compat.set_clock], so anything hitting [Eio_context.get_clock_opt]
    failed with [failwith "Eio clock unavailable"] on the first cache-compute
    path. Main CI skipped Build and Test for 100+ dashboard-only commits, so
    the regression was invisible.

    Call this once per harness after [Eio_main.run @@ fun env ->]
    (and [Eio.Switch.run @@ fun sw ->] if the test publishes a switch). *)
let init_eio_clock ?sw env =
  let clock = Eio.Stdenv.clock env in
  Time_compat.set_clock clock;
  Eio_context.set_clock clock;
  Option.iter Eio_context.set_switch sw

let init_keeper_tool_registry () =
  if not (Tool_dispatch.is_tag_registry_initialized ()) then
    (Masc.Unified_tool_registry.register_all ();
     Masc.Unified_tool_registry.enforce_visible_tag_coverage ())

let sanitize_fixture_trace_fragment value =
  let buffer = Buffer.create (String.length value) in
  String.iter
    (fun character ->
       match character with
       | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' ->
         Buffer.add_char buffer character
       | _ -> Buffer.add_char buffer '-')
    value;
  match String.trim (Buffer.contents buffer) with
  | "" -> "fixture"
  | fragment -> fragment
;;

let fixture_trace_id name =
  let candidate = "trace-" ^ sanitize_fixture_trace_fragment name in
  if String.length candidate <= 64 then candidate else String.sub candidate 0 64
;;

let current_meta_json_fixture ?(name = "fixture") () : Yojson.Safe.t =
  `Assoc
    [ "name", `String name
    ; "agent_name", `String ("keeper-" ^ name ^ "-agent")
    ; "persona", `Null
    ; "instructions", `String ""
    ; "trace_id", `String (fixture_trace_id name)
    ; "multimodal_policy", `String "inherit"
    ; "trace_history", `List []
    ; "generation", `Int 0
    ; "last_handoff_ts", `Float 0.0
    ; "created_at", `String "2026-01-01T00:00:00Z"
    ; "updated_at", `String "2026-01-01T00:00:00Z"
    ; "total_turns", `Int 0
    ; "total_input_tokens", `Int 0
    ; "total_output_tokens", `Int 0
    ; "total_tokens", `Int 0
    ; "total_cost_usd", `Float 0.0
    ; "last_turn_ts", `Float 0.0
    ; "last_input_tokens", `Int 0
    ; "last_output_tokens", `Int 0
    ; "last_total_tokens", `Int 0
    ; "last_latency_ms", `Int 0
    ; "compaction_count", `Int 0
    ; "last_compaction_ts", `Float 0.0
    ; "last_compaction_before_tokens", `Int 0
    ; "last_compaction_after_tokens", `Int 0
    ; "compaction_consecutive_failures", `Int 0
    ; "proactive_count_total", `Int 0
    ; "last_proactive_ts", `Float 0.0
    ; "proactive_visible_count_total", `Int 0
    ; "last_visible_proactive_ts", `Float 0.0
    ; "last_proactive_outcome", `String "unknown"
    ; "last_proactive_reason", `String ""
    ; "last_proactive_preview", `String ""
    ; "consecutive_noop_count", `Int 0
    ; "last_compaction_check_ts", `Float 0.0
    ; "last_compaction_decision", `String "uninitialized"
    ; "active_goal_ids", `List []
    ; "last_autonomous_action_at", `String ""
    ; "autonomous_action_count", `Int 0
    ; "autonomous_turn_count", `Int 0
    ; "autonomous_text_turn_count", `Int 0
    ; "autonomous_tool_turn_count", `Int 0
    ; "board_reactive_turn_count", `Int 0
    ; "mention_reactive_turn_count", `Int 0
    ; "noop_turn_count", `Int 0
    ; "message_scope_ack_id", `Null
    ; "last_blocker", `Null
    ; "last_runtime_attempt", `Null
    ; "paused", `Bool false
    ; "latched_reason", `Null
    ; "current_task_id", `Null
    ; "keeper_id", `Null
    ; "oas_env", `Assoc []
    ; "meta_version", `Int 0
    ]

(** Closed fixture builder for the current in-memory [keeper_meta] contract.
    Persisted overrides are decoded by the production codec. Current
    configuration-owned record fields are decoded here with exact types; no
    field is ignored or defaulted after it is supplied. *)
let meta_of_json_fixture (json : Yojson.Safe.t) =
  let overlay_field_names =
    [ "sandbox_profile"
    ; "sandbox_image"
    ; "network_mode"
    ; "allowed_paths"
    ; "mention_targets"
    ; "proactive_enabled"
    ; "always_allow"
    ; "autoboot_enabled"
    ; "max_context_override"
    ; "telemetry_feedback_enabled"
    ; "telemetry_feedback_window_hours"
    ]
  in
  let find_duplicate fields =
    let rec loop seen = function
      | [] -> None
      | (key, _) :: rest ->
        if List.mem key seen then Some key else loop (key :: seen) rest
    in
    loop [] fields
  in
  let string_list key = function
    | `List values ->
      let rec decode acc = function
        | [] -> Ok (List.rev acc)
        | `String value :: rest -> decode (value :: acc) rest
        | _ ->
          Error
            (Printf.sprintf
               "current keeper fixture field %s must be a string list"
               key)
      in
      decode [] values
    | _ ->
      Error
        (Printf.sprintf
           "current keeper fixture field %s must be a string list"
           key)
  in
  let apply_overlay
      (meta : Masc.Keeper_meta_contract.keeper_meta)
      (key, value)
    =
    let wrong expected =
      Error
        (Printf.sprintf
           "current keeper fixture field %s must be %s"
           key
           expected)
    in
    match key, value with
    | "sandbox_profile", `String raw ->
      (match Masc.Keeper_types_profile.sandbox_profile_of_string raw with
       | Some sandbox_profile -> Ok { meta with sandbox_profile }
       | None -> wrong "a current sandbox profile")
    | "sandbox_profile", _ -> wrong "a current sandbox profile"
    | "sandbox_image", `String sandbox_image ->
      Ok { meta with sandbox_image = Some sandbox_image }
    | "sandbox_image", `Null -> Ok { meta with sandbox_image = None }
    | "sandbox_image", _ -> wrong "a string or null"
    | "network_mode", `String raw ->
      (match Masc.Keeper_types_profile.network_mode_of_string raw with
       | Some network_mode -> Ok { meta with network_mode }
       | None -> wrong "a current network mode")
    | "network_mode", _ -> wrong "a current network mode"
    | "allowed_paths", value ->
      Result.map
        (fun allowed_paths -> { meta with allowed_paths })
        (string_list key value)
    | "mention_targets", value ->
      Result.map
        (fun mention_targets -> { meta with mention_targets })
        (string_list key value)
    | "proactive_enabled", `Bool enabled ->
      Ok { meta with proactive = { enabled } }
    | "proactive_enabled", _ -> wrong "a boolean"
    | "always_allow", `Bool always_allow ->
      Ok { meta with always_allow = Some always_allow }
    | "always_allow", `Null -> Ok { meta with always_allow = None }
    | "always_allow", _ -> wrong "a boolean or null"
    | "autoboot_enabled", `Bool autoboot_enabled ->
      Ok { meta with autoboot_enabled }
    | "autoboot_enabled", _ -> wrong "a boolean"
    | "max_context_override", `Int max_context_override ->
      Ok { meta with max_context_override = Some max_context_override }
    | "max_context_override", `Null ->
      Ok { meta with max_context_override = None }
    | "max_context_override", _ -> wrong "an integer or null"
    | "telemetry_feedback_enabled", `Bool telemetry_feedback_enabled ->
      Ok { meta with telemetry_feedback_enabled = Some telemetry_feedback_enabled }
    | "telemetry_feedback_enabled", `Null ->
      Ok { meta with telemetry_feedback_enabled = None }
    | "telemetry_feedback_enabled", _ -> wrong "a boolean or null"
    | "telemetry_feedback_window_hours", `Int telemetry_feedback_window_hours ->
      Ok
        { meta with
          telemetry_feedback_window_hours = Some telemetry_feedback_window_hours
        }
    | "telemetry_feedback_window_hours", `Null ->
      Ok { meta with telemetry_feedback_window_hours = None }
    | "telemetry_feedback_window_hours", _ -> wrong "an integer or null"
    | _ ->
      Error
        (Printf.sprintf
           "field %s is outside the current keeper fixture contract"
           key)
  in
  match json with
  | `Assoc overrides ->
    (match find_duplicate overrides with
     | Some key ->
       Error
         (Printf.sprintf
            "current keeper fixture has duplicate field %s"
            key)
     | None ->
       let current_field_names = Masc.Keeper_meta_json.current_field_names in
       let outside_contract =
         overrides
         |> List.filter_map (fun (key, _) ->
           if
             List.mem key current_field_names
             || List.mem key overlay_field_names
           then None
           else Some key)
       in
       if outside_contract <> []
       then
         Error
           (Printf.sprintf
              "fields outside the current keeper fixture contract: %s"
              (String.concat ", " outside_contract))
       else
         let name =
           match List.assoc_opt "name" overrides with
           | Some (`String value) -> value
           | _ -> "fixture"
         in
         let base_fields =
           match current_meta_json_fixture ~name () with
           | `Assoc fields -> fields
           | _ -> assert false
         in
         let persisted_overrides =
           List.filter
             (fun (key, _) -> List.mem key current_field_names)
             overrides
         in
         let overlay_overrides =
           List.filter
             (fun (key, _) -> List.mem key overlay_field_names)
             overrides
         in
         let fields =
           List.fold_left
             (fun fields ((key, _) as field) ->
                field :: List.remove_assoc key fields)
             base_fields
             persisted_overrides
         in
         (match Masc.Keeper_meta_json_parse.meta_of_json (`Assoc fields) with
          | Error _ as error -> error
          | Ok meta ->
            List.fold_left
              (fun result field ->
                 Result.bind result (fun meta -> apply_overlay meta field))
              (Ok meta)
              overlay_overrides))
  | other -> Masc.Keeper_meta_json_parse.meta_of_json other

(** Walk up the directory tree from [Sys.getcwd()] until [dune-project] is
    found, then return that directory.
    Raises [Failure] with a descriptive message if the marker file
    cannot be found by the time the filesystem root is reached. *)
let find_project_root () =
  let marker = "dune-project" in
  let start_dir = Sys.getcwd () in
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when Sys.file_exists (Filename.concat root marker) -> root
  | _ ->
  let rec walk dir =
    if Sys.file_exists (Filename.concat dir marker) then dir
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir then
        failwith
          (Printf.sprintf
             "Could not find %s when walking upward from %s"
             marker start_dir)
      else
        walk parent
  in
  walk start_dir

let validate_source_relpath rel =
  let fail reason =
    failwith
      (Printf.sprintf
         "Masc_test_deps.source_path requires a clean repo-relative path: %S (%s)"
         rel
         reason)
  in
  if String.equal rel "" then fail "empty path";
  if not (Filename.is_relative rel) then fail "absolute path";
  if String.starts_with ~prefix:"./" rel then fail "leading ./";
  let parts = String.split_on_char '/' rel in
  List.iter
    (function
      | "" -> fail "empty path segment"
      | "." -> fail "current-directory path segment"
      | ".." -> fail "parent-directory path segment"
      | _ -> ())
    parts

let source_path rel =
  validate_source_relpath rel;
  Filename.concat (find_project_root ()) rel

let read_file path =
  try
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let n = in_channel_length ic in
        really_input_string ic n)
  (* Catch only [Sys_error] so OOM/Stack_overflow/Sys.Break and other fatal or
     async exceptions propagate instead of being folded into a [Failure]. *)
  with Sys_error msg ->
    failwith
      (Printf.sprintf
         "Masc_test_deps.read_file failed for %S: %s"
         path
         msg)

let read_source_file rel = read_file (source_path rel)

let config_dir_resolver_source_path =
  "lib/config_dir_resolver/config_dir_resolver.ml"
;;

let tla_quoted_strings content =
  let re = Str.regexp "\"\\([^\"]*\\)\"" in
  let acc = ref [] in
  let pos = ref 0 in
  let keep_scanning = ref true in
  while !keep_scanning do
    match Str.search_forward re content !pos with
    | exception Not_found -> keep_scanning := false
    | _ ->
        acc := Str.matched_group 1 content :: !acc;
        pos := Str.match_end ()
  done;
  List.rev !acc

let tla_find_quoted_set ~symbol content =
  let header = symbol ^ " ==" in
  let len = String.length content in
  let hlen = String.length header in
  let rec find_header i =
    if i + hlen > len then None
    else if String.sub content i hlen = header then Some (i + hlen)
    else find_header (i + 1)
  in
  let rec find_matching_brace depth i =
    if i >= len then None
    else
      match content.[i] with
      | '{' -> find_matching_brace (depth + 1) (i + 1)
      | '}' ->
          let depth = depth - 1 in
          if depth = 0 then Some i else find_matching_brace depth (i + 1)
      | _ -> find_matching_brace depth (i + 1)
  in
  match find_header 0 with
  | None -> None
  | Some after_header -> (
      match String.index_from_opt content after_header '{' with
      | None -> None
      | Some open_brace -> (
          match find_matching_brace 0 open_brace with
          | None -> None
          | Some close_brace ->
              let body =
                String.sub content open_brace
                  (close_brace - open_brace + 1)
              in
              Some (tla_quoted_strings body)))

let tla_quoted_set_exn ?(source = "<tla>") ~symbol content =
  match tla_find_quoted_set ~symbol content with
  | Some values -> values
  | None ->
      failwith
        (Printf.sprintf
           "%s not found in %s; set definition may have moved or been \
            renamed."
           symbol source)

let tla_quoted_set_from_repo_file_exn ~relpath ~symbol =
  let path = source_path relpath in
  tla_quoted_set_exn ~source:relpath ~symbol (read_file path)

let sorted_strings = List.sort String.compare

(** Create an isolated temporary workspace for tests that need credentials.
    The directory and its [.masc/] subtree are removed by
    {!cleanup_test_workspace}. *)
let setup_test_workspace () =
  let unique_id =
    Printf.sprintf "masc-sse-test-%d-%d"
      (Unix.getpid ())
      (int_of_float (Unix.gettimeofday () *. 1000.))
  in
  let tmp = Filename.concat (Filename.get_temp_dir_name ()) unique_id in
  Unix.mkdir tmp 0o755;
  let masc_dir = Filename.concat tmp Common.masc_dirname in
  Unix.mkdir masc_dir 0o755;
  tmp

let cleanup_test_workspace dir =
  let rec rm_rf path =
    if Sys.is_directory path then begin
      Array.iter (fun f -> rm_rf (Filename.concat path f)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Sys.remove path
  in
  try rm_rf dir with _ -> ()

(** Run a test callback with a fresh, inventoried publication-recovery registry.
    Existing startup state is rejected instead of duplicating the production
    reconciliation policy in a test helper; startup reconciliation has its own
    integration tests. [registry_root] is owned by the caller and must outlive
    [sw]. *)
let with_publication_recovery_registry ~sw ~fs ~registry_root f =
  let registry_root = Eio.Path.(fs / registry_root) in
  match
    Fs_compat.Publication_recovery.open_registry ~sw ~fs ~registry_root
  with
  | Error error ->
    failwith
      ("test publication recovery registry open failed: "
       ^ Fs_compat.Publication_recovery.registry_error_to_string error)
  | Ok publication_recovery_registry ->
    (match
       Fs_compat.Publication_recovery.discover_owners
         publication_recovery_registry
     with
     | Error error ->
       failwith
         ("test publication recovery discovery failed: "
          ^ Fs_compat.Publication_recovery.discovery_error_to_string
              error)
     | Ok [] -> f publication_recovery_registry
     | Ok rows ->
       failwith
         ("fresh test publication recovery registry contains owners: "
          ^ String.concat
              "; "
              (List.map
                 Fs_compat.Publication_recovery.owner_discovery_row_to_string
                 rows)))
;;

let publication_recovery_provider registry =
  Masc.Keeper_publication_recovery_availability.constant
    (Masc.Keeper_publication_recovery_availability.Available registry)
;;

let non_runtime_publication_recovery_provider =
  Masc.Keeper_publication_recovery_availability.non_runtime_provider
;;

let rng_initialized = Atomic.make false

let ensure_rng_initialized () =
  if Atomic.compare_and_set rng_initialized false true then
    Mirage_crypto_rng_unix.use_default ()

(** Create a valid bearer token for [agent_name] in [workspace] and return
    the [Masc.Sse.registration_auth] record used by {!Masc.Sse.register}. *)
let make_sse_auth workspace agent_name =
  ensure_rng_initialized ();
  match Auth.create_token workspace ~agent_name ~role:Masc_domain.Worker with
  | Ok (raw_token, _cred) -> { Masc.Sse.config = workspace; token = Some raw_token }
  | Error e ->
      failwith
        (Printf.sprintf "make_sse_auth failed for %s: %s"
           agent_name
           (Masc_domain.masc_error_to_string e))

let assert_same_string_set ~label ~expected ~actual =
  let expected = sorted_strings expected in
  let actual = sorted_strings actual in
  if actual <> expected then begin
    Printf.printf "Expected %s : [%s]\n" label
      (String.concat "; " expected);
    Printf.printf "Actual   %s : [%s]\n" label
      (String.concat "; " actual);
    let only_expected =
      List.filter (fun s -> not (List.mem s actual)) expected
    in
    let only_actual =
      List.filter (fun s -> not (List.mem s expected)) actual
    in
    Printf.printf "Only expected : [%s]\n"
      (String.concat "; " only_expected);
    Printf.printf "Only actual   : [%s]\n"
      (String.concat "; " only_actual);
    failwith (label ^ " differs")
  end
