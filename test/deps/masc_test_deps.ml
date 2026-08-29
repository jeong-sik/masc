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

let init_unified_tool_registry () =
  if not (Tool_dispatch.is_tag_registry_initialized ()) then
    (Masc.Unified_tool_registry.register_all ();
     Masc.Unified_tool_registry.enforce_visible_tag_coverage ())

(** Test fixture parser for current-schema [keeper_meta] JSON. Focused fixtures
    may specify only the fields relevant to a test; every omitted persisted
    field is completed from one deterministic current-schema object before the
    production parser sees it. *)
let meta_of_json_fixture (json : Yojson.Safe.t) =
  let fixture_config_keys =
    [ "mention_targets"
    ; "proactive_enabled"
    ; "always_allow"
    ; "autoboot_enabled"
    ; "telemetry_feedback_enabled"
    ; "telemetry_feedback_window_hours"
    ]
  in
  let mem_key key keys = List.exists (String.equal key) keys in
  let sanitize_trace_fragment s =
    let buf = Buffer.create (String.length s) in
    String.iter
      (fun c ->
        match c with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' ->
            Buffer.add_char buf c
        | _ -> Buffer.add_char buf '-')
      s;
    match String.trim (Buffer.contents buf) with
    | "" -> "fixture"
    | fragment -> fragment
  in
  let json', fixture_json =
    match json with
    | `Assoc fields ->
      let module Schema = Masc.Keeper_meta_json_current_schema in
      let name =
        match List.assoc_opt "name" fields with
        | Some (`String value) -> value
        | _ -> "fixture"
      in
      let trace_id =
        let candidate = "trace-" ^ sanitize_trace_fragment name in
        if String.length candidate <= 64 then candidate
        else String.sub candidate 0 64
      in
      let default_value = function
        | Schema.Schema -> `String "masc.keeper_meta.v1"
        | Schema.Name -> `String name
        | Schema.Instructions -> `String ""
        | Schema.Trace_id -> `String trace_id
        | Schema.Trace_history -> `List []
        | Schema.Last_handoff_ts -> `Float 0.
        | Schema.Created_at | Schema.Updated_at ->
          `String "1970-01-01T00:00:00Z"
        | Schema.Total_turns
        | Schema.Total_input_tokens
        | Schema.Total_output_tokens
        | Schema.Total_tokens
        | Schema.Last_input_tokens
        | Schema.Last_output_tokens
        | Schema.Last_total_tokens
        | Schema.Last_latency_ms
        | Schema.Proactive_count_total
        | Schema.Proactive_visible_count_total
        | Schema.Consecutive_noop_count -> `Int 0
        | Schema.Total_cost_usd
        | Schema.Last_turn_ts
        | Schema.Last_proactive_ts
        | Schema.Last_visible_proactive_ts -> `Float 0.
        | Schema.Last_proactive_outcome ->
          `String
            (Masc.Keeper_meta_contract.proactive_cycle_outcome_to_string
               Masc.Keeper_meta_contract.Proactive_never_started)
        | Schema.Last_proactive_reason
        | Schema.Last_proactive_preview -> `String ""
        | Schema.Message_scope_ack_id
        | Schema.Last_runtime_attempt
        | Schema.Latched_reason
        | Schema.Current_task_id
        | Schema.Keeper_id -> `Null
        | Schema.Paused -> `Bool false
        | Schema.Agent_core_env -> `Assoc []
      in
      let field_values =
        List.map
          (fun field ->
             let key = Schema.field_name field in
             let value =
               match List.assoc_opt key fields with
               | Some value -> value
               | None -> default_value field
             in
             field, value)
          Schema.all_fields
      in
      let unknown_fields =
        List.filter
          (fun (key, _) ->
             (not (mem_key key Schema.current_field_names))
             && not (mem_key key fixture_config_keys))
          fields
      in
      let canonical_fields =
        match Schema.object_of_field_values field_values with
        | `Assoc canonical_fields -> canonical_fields
        | _ -> invalid_arg "current keeper fixture schema did not produce an object"
      in
      `Assoc (canonical_fields @ unknown_fields), json
    | other -> other, other
  in
  (* Production [meta_of_json] no longer reads TOML-only config keys from JSON
     (TOML is the SSOT; the runtime JSON carries only runtime state). Focused
     fixtures still set config inline for convenience, so this test helper
     re-applies those keys onto the parsed record. This keeps config injection a
     test-only concern and does not resurrect the production JSON read path. *)
  match Masc.Keeper_meta_json_parse.meta_of_json json' with
  | Error _ as e -> e
  | Ok meta ->
    let open Masc.Keeper_meta_contract in
    let bool_opt key = Safe_ops.json_bool_opt key fixture_json in
    let apply_bool_opt key current =
      match bool_opt key with Some _ as v -> v | None -> current
    in
    let apply_bool key current =
      match bool_opt key with Some v -> v | None -> current
    in
    let apply_string_list key current =
      match Safe_ops.json_string_list key fixture_json with
      | [] -> current
      | xs -> xs
    in
    Ok
      { meta with
        mention_targets = apply_string_list "mention_targets" meta.mention_targets
      ; proactive =
          (match bool_opt "proactive_enabled" with
           | Some enabled -> { enabled }
           | None -> meta.proactive)
      ; always_allow = apply_bool_opt "always_allow" meta.always_allow
      ; autoboot_enabled = apply_bool "autoboot_enabled" meta.autoboot_enabled
      ; telemetry_feedback_enabled =
          apply_bool_opt "telemetry_feedback_enabled" meta.telemetry_feedback_enabled
      ; telemetry_feedback_window_hours =
          (match
             Safe_ops.json_int_opt "telemetry_feedback_window_hours" fixture_json
           with
           | Some _ as v -> v
           | None -> meta.telemetry_feedback_window_hours)
      }

(** Current-schema [keeper_meta] JSON exactly as the production writer emits it.

    Schema-conformance tests use this instead of a hand-written object so the
    fixture cannot drift from the writer: the only caller-supplied value is the
    name, and every other key comes from [meta_to_json]. A fixture that stopped
    matching the schema would therefore be a writer change, not a stale literal. *)
let current_meta_json_fixture ~name () =
  match meta_of_json_fixture (`Assoc [ ("name", `String name) ]) with
  | Ok meta -> Masc.Keeper_meta_json.meta_to_json meta
  | Error detail ->
    failwith ("current_meta_json_fixture could not build current meta: " ^ detail)

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
  (* [Unix.lstat], not [Sys.is_directory]: the latter follows symlinks, so a
     link to a directory would make [Sys.readdir] enumerate the *target* and
     this loop delete entries outside the workspace. [S_LNK] falls through to
     [Sys.remove], which unlinks the link itself. *)
  let rec rm_rf path =
    match Unix.lstat path with
    | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> ()
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun f -> rm_rf (Filename.concat path f)) (Sys.readdir path);
      Unix.rmdir path
    | _ -> Sys.remove path
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
