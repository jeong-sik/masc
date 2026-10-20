(* masc#29077 — masc_keeper_list must say how much of the directory it answered
   with.

   The list is sorted by name and cut at [limit], and the response reported only
   the post-truncation [count]. A caller could not tell a short answer from a
   complete one, so a 129-keeper workspace answering 50 read as "there are 50
   keepers" — and because throwaway benchmark keepers sort first, the ones with
   live channel bindings were the ones that fell off the end.

   These assertions pin [total] (before the cut), [limit] (what was applied) and
   [truncated] on both response shapes, through the public tool dispatch. *)

open Alcotest
open Masc

let with_temp_dir prefix f =
  let path = Filename.temp_dir prefix ".workspace" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)
;;

(* keeper_list_row_json resolves the default runtime id per row, which fails
   closed when no runtime is loaded (RFC-0206 §2.1). Minimal catalog, loaded
   once for the executable. *)
let test_runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}
;;

let runtime_initialized = ref false

let ensure_runtime () =
  if not !runtime_initialized
  then (
    let path = Filename.temp_file "keeper-list-truncation-runtime-" ".toml" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
      (fun () ->
        Out_channel.with_open_bin path (fun oc ->
          output_string oc test_runtime_toml);
        match Runtime.init_default ~config_path:path with
        | Ok () -> runtime_initialized := true
        | Error error -> failf "Runtime.init_default failed: %s" error))
;;

let make_meta name =
  let json =
    `Assoc
      [ "name", `String name
      ; "trace_id", `String ("trace-" ^ name)
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error error -> fail ("meta_of_json failed: " ^ error)
;;

(* A keeper is two files. The snapshot holds runtime state; the TOML holds
   what config owns, and since #32078 that includes a sandbox_profile no
   keeper has an effective meta without. A keeper seeded as a snapshot alone
   reads back as Error, and the list publishes keeper_list_error_row_json --
   a row with no phase and no health, which is what the axis cases below saw.

   The directory comes from the resolver rather than being spelled here,
   because where a keeper's TOML lives is its answer. *)
let rec mkdir_p dir =
  if not (Sys.file_exists dir)
  then (
    mkdir_p (Filename.dirname dir);
    if not (Sys.file_exists dir) then Sys.mkdir dir 0o755)
;;

let write_keeper_toml ~base_path name =
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  mkdir_p keepers_dir;
  Out_channel.with_open_bin
    (Filename.concat keepers_dir (name ^ ".toml"))
    (fun oc ->
      output_string
        oc
        "[keeper]\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\ninstructions = \"keeper list fixture\"\n")
;;

let seed_keepers config names =
  List.iter
    (fun name ->
      write_keeper_toml ~base_path:config.Workspace.base_path name;
      match Keeper_meta_store.replace_snapshot config (make_meta name) with
      | Ok () -> ()
      | Error error -> failf "replace_snapshot %s failed: %s" name error)
    names
;;

let int_field json key =
  match json |> Yojson.Safe.Util.member key with
  | `Int value -> value
  | other ->
    failf "expected int at %S, got %s" key (Yojson.Safe.to_string other)
;;

let bool_field json key =
  match json |> Yojson.Safe.Util.member key with
  | `Bool value -> value
  | other ->
    failf "expected bool at %S, got %s" key (Yojson.Safe.to_string other)
;;

let string_field json key =
  match json |> Yojson.Safe.Util.member key with
  | `String value -> value
  | other ->
    failf "expected string at %S, got %s" key (Yojson.Safe.to_string other)
;;

let list_length json key =
  match json |> Yojson.Safe.Util.member key with
  | `List items -> List.length items
  | other ->
    failf "expected list at %S, got %s" key (Yojson.Safe.to_string other)
;;

(* Run masc_keeper_list against a workspace seeded with [names], through the
   same dispatch an MCP client and the HTTP route use. *)
let keeper_list ?(before_list = fun _ -> ()) ?after_list ~names ~args f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ensure_runtime ();
  with_temp_dir "masc-keeper-list-truncation-" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:None);
  Fun.protect
    ~finally:(fun () ->
      ignore (Workspace.reset config);
      Keeper_registry.For_testing.clear ();
      Keeper_tool_surface.For_testing.reset_keeper_list_cache ();
      Keeper_runtime.reset_test_state base_path)
    (fun () ->
      seed_keepers config names;
      before_list config;
      Keeper_tool_surface.For_testing.reset_keeper_list_cache ();
      Eio.Switch.run @@ fun sw ->
      let ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = "test-caller"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = Some (Eio.Stdenv.net env)
        ; publication_recovery_provider =
            Masc_test_deps.non_runtime_publication_recovery_provider
        }
      in
      let read () = match Keeper_tool_surface.dispatch ctx ~name:"masc_keeper_list" ~args with
        | None -> fail "masc_keeper_list did not dispatch"
        | Some result ->
          let body = Tool_result.message result in
          match Yojson.Safe.from_string body with
          | exception Yojson.Json_error error -> failf "masc_keeper_list returned invalid JSON: %s" error
          | json -> json in
      f (read ());
      Option.iter (fun observe -> observe config read) after_list)
;;

(* Ten names, sorted, so a limit of 4 keeps k00..k03 and drops the rest —
   the same "the tail disappears" shape the live workspace hit. *)
let ten_names = List.init 10 (fun i -> Printf.sprintf "k%02d" i)

let test_truncated_reports_the_whole_directory () =
  keeper_list
    ~names:ten_names
    ~args:(`Assoc [ "limit", `Int 4; "detailed", `Bool true ])
    (fun json ->
      check int "total counts every keeper, not the page" 10 (int_field json "total");
      check int "limit is what was applied" 4 (int_field json "limit");
      check bool "truncated" true (bool_field json "truncated");
      check int "count is the page" 4 (int_field json "count");
      check int "rows match count" 4 (list_length json "keepers"))
;;

let test_complete_answer_is_not_marked_truncated () =
  keeper_list
    ~names:ten_names
    ~args:(`Assoc [ "limit", `Int 50; "detailed", `Bool true ])
    (fun json ->
      check int "total" 10 (int_field json "total");
      check bool "not truncated when the limit is not reached" false
        (bool_field json "truncated");
      check int "count" 10 (int_field json "count"))
;;

let test_limit_equal_to_total_is_not_truncated () =
  (* Boundary: cutting at exactly the directory size drops nothing. *)
  keeper_list
    ~names:ten_names
    ~args:(`Assoc [ "limit", `Int 10; "detailed", `Bool true ])
    (fun json ->
      check bool "limit = total is complete" false (bool_field json "truncated");
      check int "count" 10 (int_field json "count"))
;;

let test_name_only_shape_carries_the_same_verdict () =
  (* The non-detailed shape is a different branch and had the same silence. *)
  keeper_list
    ~names:ten_names
    ~args:(`Assoc [ "limit", `Int 3; "detailed", `Bool false ])
    (fun json ->
      check int "total" 10 (int_field json "total");
      check int "limit" 3 (int_field json "limit");
      check bool "truncated" true (bool_field json "truncated");
      check int "names returned" 3 (list_length json "keepers"))
;;

let test_default_limit_is_reported_not_assumed () =
  (* A caller that passes no limit still learns which one applied — the tool
     default is 50, and nothing in the old response said so. *)
  keeper_list
    ~names:ten_names
    ~args:(`Assoc [ "detailed", `Bool true ])
    (fun json ->
      check int "default limit is stated" 50 (int_field json "limit");
      check int "total" 10 (int_field json "total");
      check bool "not truncated" false (bool_field json "truncated"))
;;

let test_detailed_row_carries_lifecycle_phase () =
  keeper_list
    ~names:[ "alpha" ]
    ~args:(`Assoc [ "detailed", `Bool true ])
    (fun json ->
      match Yojson.Safe.Util.member "keepers" json with
      | `List (row :: _) ->
        check string "unregistered keeper is offline" "offline"
          (string_field row "phase")
      | `List [] -> fail "detailed keeper list returned no rows"
      | other ->
        failf "expected keeper rows, got %s" (Yojson.Safe.to_string other))
;;

(* Four separate readings describe one keeper, and a row that answers all four
   with a single word forces its readers to guess which question the word
   answers. Each axis gets its own field so no reader has to fold or unfold
   anything. *)
let detailed_row f =
  keeper_list
    ~names:[ "alpha" ]
    ~args:(`Assoc [ "detailed", `Bool true ])
    (fun json ->
      match Yojson.Safe.Util.member "keepers" json with
      | `List (row :: _) -> f row
      | `List [] -> fail "detailed keeper list returned no rows"
      | other ->
        failf "expected keeper rows, got %s" (Yojson.Safe.to_string other))
;;

let test_detailed_row_carries_every_axis () =
  detailed_row (fun row ->
    List.iter
      (fun field ->
        check bool
          (Printf.sprintf "row publishes %s" field)
          true
          (Yojson.Safe.Util.member field row <> `Null))
      [ "phase"; "health"; "paused" ])
;;

(* The two vocabularies share "idle" and "offline", so a keeper sitting on a
   shared value proves nothing about which one a field answers with. Only the
   words unique to each side can tell them apart. *)
let health_only_words = [ "healthy"; "failing" ]
let surface_only_words = [ "active"; "busy"; "listening" ]

let test_health_is_a_health_word_not_a_surface_word () =
  (* [status] answers with the surface vocabulary. [health] must answer from
     the keeper_health vocabulary, or the new field is the old fold under a
     new name. *)
  detailed_row (fun row ->
    let health = string_field row "health" in
    check bool
      (Printf.sprintf "health %S is never a surface-only word" health)
      false
      (List.mem health surface_only_words);
    check bool
      (Printf.sprintf "health %S is a keeper_health value" health)
      true
      (List.mem health (health_only_words @ [ "idle"; "offline" ])))
;;

(* What this file cannot show: a keeper seeded here has no keepalive fiber, so
   its health is "offline" and [status] spells it "offline" too - legitimately
   the one value both vocabularies share. Publishing [status] under the
   [health] key passes every assertion above, and did, until the mutation was
   run. The two fields are told apart in test_keeper_surface_status
   ([test_two_readers_of_one_diagnostic_differ_on_healthy]), which feeds one
   diagnostic to both readers and pins that "healthy" survives one and
   becomes "active" in the other. *)

let test_absent_next_action_is_null_not_empty () =
  (* An action the diagnostic did not name is absent, not the empty string:
     "" would read as an action whose name happens to be blank. *)
  detailed_row (fun row ->
    match Yojson.Safe.Util.member "next_action" row with
    | `Null -> ()
    | `String "" -> fail "next_action published an empty string instead of null"
    | `String value ->
      check bool
        (Printf.sprintf "next_action %S is a known action" value)
        true
        (List.mem value [ "recover"; "probe"; "direct_message" ])
    | other ->
      failf "next_action must be a string or null, got %s"
        (Yojson.Safe.to_string other))
;;

(* The same roster drives the TUI's current failure reading. The registry's
   last_error is a separate observation and must not stand in for this one. *)
let timeout_error =
  Agent_core.Error.Api
    (Llm_provider.Retry.Timeout
       { message = "fixture response body stopped"
       ; phase = Some Llm_provider.Http_client.Non_streaming_body
       })
;;

let timeout_reason () =
  let raw_error = Agent_core.Error.to_string timeout_error in
  let terminal = Keeper_turn_terminal.of_failure ~raw_error timeout_error in
  match Keeper_unified_turn_types.registry_failure_reason_of_terminal_reason
          ~core_error:timeout_error terminal ~raw_error with
  | Some (Keeper_registry.Provider_runtime_error { detail; _ } as reason) ->
    check string "original typed error detail survives" raw_error detail;
    reason
  | Some _ | None -> fail "API timeout did not produce a runtime failure"
;;

(* This is a wiring test, not another definition of status wording. *)
let timeout_summary () =
  match (Keeper_status_bridge.runtime_blocker_surface_of_failure_reason
      ~latest_receipt:(fun () -> Masc.Keeper_execution_receipt.No_receipt)) (timeout_reason ()) with
  | Some surface -> Lazy.force surface.summary
  | None -> fail "runtime failure did not produce a status summary"
;;

let register_failed_keeper config =
  let base_path = config.Workspace.base_path in
  ignore (Keeper_registry.For_testing.register ~base_path "alpha" (make_meta "alpha"));
  Keeper_registry.set_failure_reason ~base_path "alpha" (Some (timeout_reason ()))
;;

let check_roster_failure expected json =
  match Yojson.Safe.Util.member "keepers" json with
  | `List [ row ] ->
    Printf.printf "KEEPER_ROSTER_FIXTURE %s\n%!" (Yojson.Safe.to_string json);
    check (option string) "current failure is explicitly published" expected
      (match Json_util.assoc_member_opt "runtime_blocker_summary" row with
       | Some (`String summary) -> Some summary
       | Some `Null -> None
       | Some other -> failf "invalid summary: %s" (Yojson.Safe.to_string other)
       | None -> fail "roster omitted runtime_blocker_summary");
    (match Tui_decode.decode_keeper_runtime_list json with
     | Ok ([decoded], [], false, 1, _) ->
       check (option string) "typed TUI projection retains the current failure"
         expected decoded.kr_runtime_blocker_summary;
       check (option string)
         "the timeout blocker carries no replacement signature"
         None decoded.kr_runtime_blocker_signature
     | Ok _ -> fail "the current roster must decode one complete reading"
     | Error detail -> failf "TUI rejected the actual roster: %s" detail)
  | other -> failf "expected one Keeper row: %s" (Yojson.Safe.to_string other)
;;

let failure_roster ?before_list f =
  keeper_list ?before_list ~names:[ "alpha" ]
    ~args:(`Assoc [ "detailed", `Bool true ]) f
;;

let test_current_failure_without_last_error () =
  failure_roster ~before_list:register_failed_keeper
    (check_roster_failure (Some (timeout_summary ())))
;;

let test_last_error_is_not_the_current_failure () =
  failure_roster
    ~before_list:(fun config ->
      register_failed_keeper config;
      Keeper_registry.set_last_error_entry ~base_path:config.Workspace.base_path
        ~name:"alpha" "older launch failure")
    (check_roster_failure (Some (timeout_summary ())))
;;

let test_success_clears_current_failure_but_retains_last_error () =
  failure_roster
    ~before_list:(fun config ->
      register_failed_keeper config;
      let base_path = config.Workspace.base_path in
      Keeper_registry.set_last_error_entry ~base_path ~name:"alpha" "older launch failure";
      check bool "production success reset commits" true
        (Keeper_turn_failure_streak.reset ~base_path ~keeper_name:"alpha");
      check (option string) "last error remains a distinct observation"
        (Some "older launch failure")
        (Option.bind (Keeper_registry.get ~base_path "alpha")
           (fun entry -> entry.last_error)))
    (check_roster_failure None)
;;

(* A fenced empty assistant turn leads with a human sentence and keeps the
   machine wire as its signature. The roster row is what the TUI reads, so
   both must arrive through the real list tool and the TUI decoder. *)
let fenced_empty_turn_reason () =
  let scope = "openrouter" in
  let fence =
    Keeper_internal_error.Provider_attempt_effect_fenced
      { runtime_id = scope
      ; effect_disposition = Keeper_provider_attempt_effect_core.No_effect_observed
      ; cause =
          Keeper_internal_error.Fenced_masc
            (Keeper_internal_error.Accept_rejected
               { scope
               ; model = None
               ; reason_kind = Some Keeper_internal_error.Accept_no_usable_progress
               ; response_shape = Some Keeper_internal_error.Accept_response_empty
               ; stop_reason = None
               ; reason = "empty assistant turn"
               })
      }
  in
  let err = Keeper_internal_error.core_error_of_masc_internal_error fence in
  let raw_error = Agent_core.Error.to_string err in
  let terminal = Keeper_turn_terminal.of_failure ~raw_error err in
  match Keeper_unified_turn_types.registry_failure_reason_of_terminal_reason
          ~core_error:err terminal ~raw_error with
  | Some reason -> reason
  | None -> fail "a fenced empty turn must record a failure reason"
;;

let test_fenced_empty_turn_row_carries_its_signature () =
  let reason = fenced_empty_turn_reason () in
  let summary, signature =
    match (Keeper_status_bridge.runtime_blocker_surface_of_failure_reason
        ~latest_receipt:(fun () -> Masc.Keeper_execution_receipt.No_receipt)) reason with
    | Some surface -> Lazy.force surface.summary, surface.signature
    | None -> fail "a fenced empty turn must produce a status surface"
  in
  check bool "the fenced surface has a machine wire to carry" true
    (Option.is_some signature);
  failure_roster
    ~before_list:(fun config ->
      let base_path = config.Workspace.base_path in
      ignore (Keeper_registry.For_testing.register ~base_path "alpha" (make_meta "alpha"));
      Keeper_registry.set_failure_reason ~base_path "alpha" (Some reason))
    (fun json ->
      match Yojson.Safe.Util.member "keepers" json with
      | `List [ row ] ->
        check (option string) "the roster row carries the machine wire" signature
          (match Json_util.assoc_member_opt "runtime_blocker_signature" row with
           | Some (`String value) -> Some value
           | Some `Null -> None
           | Some other -> failf "invalid signature: %s" (Yojson.Safe.to_string other)
           | None -> fail "roster omitted runtime_blocker_signature");
        (match Tui_decode.decode_keeper_runtime_list json with
         | Ok ([decoded], [], false, 1, _) ->
           check (option string) "the TUI reads the human sentence"
             (Some summary) decoded.kr_runtime_blocker_summary;
           check (option string) "the TUI reads the machine wire"
             signature decoded.kr_runtime_blocker_signature
         | Ok _ -> fail "the current roster must decode one complete reading"
         | Error detail -> failf "TUI rejected the actual roster: %s" detail)
      | other -> failf "expected one Keeper row: %s" (Yojson.Safe.to_string other))
;;

let test_missing_current_failure_is_not_clear () =
  failure_roster (fun json ->
    let json =
      match json with
      | `Assoc fields ->
        `Assoc (List.map (fun (key, value) ->
          if String.equal key "keepers" then
            key, `List (List.map (function
              | `Assoc row -> `Assoc (List.remove_assoc "runtime_blocker_summary" row)
              | value -> value) (Yojson.Safe.Util.to_list value))
          else key, value) fields)
      | value -> value
    in
    match Tui_decode.decode_keeper_runtime_list json with
    | Error _ -> ()
    | Ok _ -> fail "missing current-failure field was accepted as a clear reading")
;;

let test_equipment_failure_and_repair_bypass_the_roster_cache () =
  let portrait json = match Tui_decode.decode_keeper_runtime_list json with
    | Ok ([row],[],_,_,_) -> row.Tui_decode.kr_portrait
    | _ -> fail "equipment read hid or malformed the Keeper row" in
  let expected = Keeper_portrait_equipment.Ready (Keeper_portrait_look.equipment_of_name "alpha") in
  Masc_test_deps.with_process_env "MASC_KEEPER_LIST_CACHE_TTL_S" (Some "3600") (fun () ->
    keeper_list ~names:["alpha"] ~args:(`Assoc ["detailed",`Bool true])
      ~after_list:(fun config read ->
        let path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path:config.Workspace.base_path in
        if not (String.starts_with ~prefix:config.base_path path) then fail "policy escaped fixture";
        Out_channel.with_open_bin path (fun oc -> output_string oc "malformed policy");
        let observation = Candle_observe.read ~now:Time_compat.now ~base_path:config.base_path in
        (match Candle_status.observed_view ~now:Time_compat.now ~base_path:config.base_path,
               Candle_observe.equipment observation ~keeper:"alpha" with
         | Error (Candle_status.Disabled reason), Error message ->
           check string "disabled prefix occurs once" ("Candle is disabled: " ^ reason) message
         | _ -> fail "malformed policy did not report Disabled");
        (match portrait (read ()) with
         | Keeper_portrait_equipment.Unavailable reason -> check bool "failure has evidence" true (String.length reason>0)
         | Keeper_portrait_equipment.Ready _ -> fail "cached name gear concealed an unreadable policy");
        Sys.remove path;
        check bool "repair is visible inside the same cached roster" true (portrait (read ()) = expected))
      (fun json -> check bool "Off uses server-selected starting equipment" true (portrait json = expected)))

let test_shared_roster_omits_currency () =
  List.iter (fun detailed ->
    keeper_list ~names:["alpha"; "beta"] ~args:(`Assoc ["detailed", `Bool detailed])
      (fun json ->
        check bool "no shared currency envelope" true (Json_util.assoc_member_opt "candle" json = None);
        let rows = Yojson.Safe.Util.(to_list (member (if detailed then "keepers" else "items") json)) in
        List.iter (fun row ->
          check bool "no other keeper balance" true (Json_util.assoc_member_opt "candle_balance_milli" row = None);
          check bool "no other keeper account revision" true (Json_util.assoc_member_opt "candle_account_revision" row = None)) rows;
        if detailed then match Tui_decode.decode_keeper_runtime_list json with
          | Ok (rows, [], _, _, Error _) ->
            check int "strict decoder retains both public rows" 2 (List.length rows);
            check bool "account authority remains unavailable" true
              (List.for_all (fun row -> Result.is_error row.Tui_decode.kr_candle_account_revision) rows)
          | _ -> fail "private currency omission broke the public roster")) [false; true]

let with_empty_roster_cache f =
  Keeper_tool_surface.For_testing.reset_keeper_list_cache ();
  Fun.protect
    ~finally:Keeper_tool_surface.For_testing.reset_keeper_list_cache f

let test_another_list_query_does_not_repeat_completed_work () =
  with_empty_roster_cache (fun () ->
    let read = Keeper_tool_surface.For_testing.cached_keeper_list_data in
    let calls = ref 0 in
    let result = read ~key:"detailed" ~ttl_s:3600. (fun () ->
      incr calls;
      ignore (read ~key:"names" ~ttl_s:3600. (fun () -> `String "names"));
      `String "detailed") in
    check int "one roster computation despite another query's publication" 1 !calls;
    check string "the requested result is returned" "detailed"
      (Yojson.Safe.Util.to_string result);
    let cached = read ~key:"names" ~ttl_s:3600.
        (fun () -> fail "the newer cache publication was overwritten") in
    check string "the competing publication is retained" "names"
      (Yojson.Safe.Util.to_string cached))

let test_explicit_invalidation_repeats_the_obsolete_read () =
  with_empty_roster_cache (fun () ->
    let read = Keeper_tool_surface.For_testing.cached_keeper_list_data in
    let calls = ref 0 in
    let result = read ~key:"detailed" ~ttl_s:3600. (fun () ->
      incr calls;
      if !calls = 1 then (
        Keeper_tool_surface.For_testing.invalidate_keeper_list_cache ();
        ignore (read ~key:"names" ~ttl_s:3600. (fun () -> `String "new names"));
        `String "obsolete")
      else `String "current") in
    check int "explicit invalidation forces a fresh computation" 2 !calls;
    check string "obsolete work cannot escape through a competing publication" "current"
      (Yojson.Safe.Util.to_string result);
    let cached = read ~key:"detailed" ~ttl_s:3600.
        (fun () -> fail "the fresh result was not published") in
    check string "fresh result is cached" "current"
      (Yojson.Safe.Util.to_string cached))

(* The actual roster envelope, not a renderer or a row-shaped shortcut, is
   the TUI's boundary. These assertions only inspect typed state. *)
let test_runtime_walk_store_to_tui () =
  let module Receipt = Keeper_execution_receipt in
  let module Evidence = Keeper_runtime_walk_evidence in
  let refused = Agent_core.Error.Api (Llm_provider.Retry.InvalidRequest
    {message="Prompt exceeds max length";reason=Llm_provider.Retry.Unknown_invalid_request}) in
  let limited = Agent_core.Error.Api (Llm_provider.Retry.RateLimited
    {message="fixture quota";retry_after=None}) in
  let failures =
    [ Evidence.observe_failure ~runtime_id:"missing.binding" ~attempt:0
        ~dispatch:Runtime_attempt_dispatch.Rejected_before_dispatch
        (Agent_core.Error.Internal "binding absent")
    ; Evidence.observe_failure ~runtime_id:"repeated.runtime" ~attempt:1
        ~dispatch:Runtime_attempt_dispatch.Dispatched refused
    ; Evidence.observe_failure ~runtime_id:"repeated.runtime" ~attempt:2
        ~dispatch:Runtime_attempt_dispatch.Dispatched limited ] in
  let earlier = {Evidence.failures;terminal=Evidence.observe_terminal
    ~runtime_id:"repeated.runtime" ~attempt:1 refused} in
  let recovered = {earlier with terminal=Evidence.Terminal_not_observed} in
  let decode json = match Tui_decode.decode_keeper_runtime_list json with
    | Ok ([row], [], false, 1, _) -> row
    | Ok _ -> fail "runtime walk fixture lost the roster row"
    | Error detail -> fail detail in
  let receipt evidence = `Assoc
    ["trace_id",`String "historical-source";"turn_count",`Int 19;
     "ended_at",`String "2026-10-20T00:00:00Z";
     "runtime",`Assoc ["lane_evidence",evidence]] in
  let patch key value = function
    | `Assoc fields -> `Assoc ((key,value)::List.remove_assoc key fields)
    | _ -> fail "fixture patch expected an object" in
  let map_row transform json = match Yojson.Safe.Util.member "keepers" json with
    | `List [row] -> patch "keepers" (`List [transform row]) json
    | _ -> fail "fixture expected one roster row" in
  let check_blocker row = check (option string) "history cannot clear live blocker"
    (Some (timeout_summary ())) row.Tui_decode.kr_runtime_blocker_summary in
  let check_source (turn : Receipt.receipt_turn) =
    check string "source trace is not the current roster trace"
      "historical-source" turn.receipt_trace_id;
    check (option int) "source turn survives" (Some 19) turn.receipt_turn_count in
  failure_roster ~before_list:register_failed_keeper
    ~after_list:(fun config read ->
      let store = Keeper_types_support.keeper_execution_receipt_store config "alpha" in
      let refresh () =
        Keeper_tool_surface.For_testing.invalidate_keeper_list_cache ();
        read () in
      List.iter (fun (name,evidence) ->
        Dated_jsonl.append store (receipt evidence);
        let row=decode (refresh ()) in
        check_blocker row;
        match row.kr_runtime_lane_observation with
        | Some (Receipt.Runtime_lane_not_observed turn) ->
          check string "only null means no capture" "no capture" name;
          check_source turn
        | Some (Receipt.Runtime_lane_observed {turn;evidence=actual}) ->
          check_source turn;
          check string "same typed evidence through store, tool envelope and TUI"
            (Yojson.Safe.to_string evidence)
            (Yojson.Safe.to_string (Evidence.to_yojson actual))
        | None | Some (Receipt.Runtime_lane_unreadable _) ->
          fail ("wrong historical reading for " ^ name))
        ["no capture",`Null;"empty",Evidence.to_yojson Evidence.empty;
         "earlier",Evidence.to_yojson earlier;"recovered",Evidence.to_yojson recovered];
      let json=refresh () in
      let view=Receipt.runtime_lane_observation_of_receipt_json (receipt (Evidence.to_yojson earlier))
        |> Receipt.runtime_lane_observation_to_yojson in
      let failure_patch f = match Yojson.Safe.Util.member "evidence" view with
        | `Assoc fields ->
          (match List.assoc "failures" fields with
           | `List (first::rest) -> patch "evidence"
               (`Assoc (("failures",`List (f first::rest))::List.remove_assoc "failures" fields)) view
           | _ -> fail "fixture expected failures")
        | _ -> fail "fixture expected evidence" in
      let add_duplicate_summary = function
        | `Assoc fields -> `Assoc (("summary",`String "duplicate")::fields)
        | _ -> fail "fixture expected a failure" in
      let terminal_patch key value = match Yojson.Safe.Util.member "evidence" view with
        | `Assoc fields -> patch "evidence"
            (`Assoc (("terminal",patch key value (List.assoc "terminal" fields))
              ::List.remove_assoc "terminal" fields)) view
        | _ -> fail "fixture expected evidence" in
      let corrupt =
        ["state",patch "state" (`String "future_state") view,true;
         "extra",(match view with `Assoc fields -> `Assoc (("extra",`Null)::fields) | _ -> fail "object"),true;
         "dispatch",failure_patch (patch "dispatch" (`String "maybe_sent")),true;
         "ordinal",failure_patch (patch "attempt" (`Int (-1))),true;
         "fault",failure_patch (patch "api_candidate_fault" (`Assoc ["kind",`String "future_fault"])),true;
         "summary",failure_patch (patch "summary" (`String "invented overflow")),true;
         "duplicate summary",failure_patch add_duplicate_summary,true;
         "terminal summary",terminal_patch "summary" (`String "wrong terminal"),true;
         "terminal extra",terminal_patch "extra" `Null,true;
         "turn",patch "turn" (`String "bad identity") view,false] in
      List.iter (fun (name,view,has_source) ->
        let row=decode (map_row (patch "runtime_lane_observation" view) json) in
        check_blocker row;
        match row.kr_runtime_lane_observation with
        | Some (Receipt.Runtime_lane_unreadable {turn;_}) ->
          check bool (name ^ " retains only a valid source") has_source (Option.is_some turn);
          Option.iter check_source turn
        | None | Some (Receipt.Runtime_lane_observed _ | Receipt.Runtime_lane_not_observed _) ->
          fail (name ^ " corruption became usable evidence")) corrupt;
      List.iter (fun transform ->
        let row=decode (map_row transform json) in
        check_blocker row;
        match row.kr_runtime_lane_observation with
        | Some (Receipt.Runtime_lane_unreadable {turn=None;_}) -> ()
        | None | Some (Receipt.Runtime_lane_observed _ | Receipt.Runtime_lane_not_observed _
          | Receipt.Runtime_lane_unreadable _) -> fail "missing/duplicate observation was accepted")
        [ (function `Assoc fields -> `Assoc (List.remove_assoc "runtime_lane_observation" fields)
            | _ -> fail "row object")
        ; (function `Assoc fields -> `Assoc (("runtime_lane_observation",`Null)::fields)
            | _ -> fail "row object") ];
      Keeper_registry.set_failure_reason ~base_path:config.Workspace.base_path "alpha" None;
      let row=decode (refresh ()) in
      check (option string) "current failure clears independently" None row.kr_runtime_blocker_summary;
      match row.kr_runtime_lane_observation with
      | Some (Receipt.Runtime_lane_observed {evidence;_}) ->
        check int "earlier refusals remain after blocker clears" 3 (List.length evidence.failures);
        check bool "successful fallback invents no terminal" true
          (evidence.terminal=Evidence.Terminal_not_observed)
      | None | Some (Receipt.Runtime_lane_not_observed _ | Receipt.Runtime_lane_unreadable _) ->
        fail "clearing current failure discarded history")
    (fun json ->
      let row=decode json in
      check_blocker row;
      check bool "explicit no receipt is distinct from no capture" true
        (row.kr_runtime_lane_observation=None))

let () =
  run "keeper_list_truncation"
    [ ( "listing truth"
      , [ test_case "shared roster omits currency" `Quick test_shared_roster_omits_currency
        ; test_case "truncated answer reports the whole directory" `Quick
            test_truncated_reports_the_whole_directory
        ; test_case "complete answer is not marked truncated" `Quick
            test_complete_answer_is_not_marked_truncated
        ; test_case "limit = total is not truncated" `Quick
            test_limit_equal_to_total_is_not_truncated
        ; test_case "name-only shape carries the same verdict" `Quick
            test_name_only_shape_carries_the_same_verdict
        ; test_case "default limit is reported" `Quick
            test_default_limit_is_reported_not_assumed
        ] )
    ; ( "one axis per field"
      , [ test_case "row publishes phase, health and paused" `Quick
            test_detailed_row_carries_every_axis
        ; test_case "equipment failure and repair bypass metadata cache" `Quick test_equipment_failure_and_repair_bypass_the_roster_cache
        ; test_case "health uses the health vocabulary" `Quick
            test_health_is_a_health_word_not_a_surface_word
        ; test_case "an unnamed next action is null" `Quick
            test_absent_next_action_is_null_not_empty
        ] )
    ; ( "current failure"
      , [ test_case "runtime walk store to typed TUI boundary" `Quick test_runtime_walk_store_to_tui
        ; test_case "timeout without last_error" `Quick test_current_failure_without_last_error
        ; test_case "last_error is separate" `Quick test_last_error_is_not_the_current_failure
        ; test_case "success clears current failure" `Quick test_success_clears_current_failure_but_retains_last_error
        ; test_case "missing is not clear" `Quick test_missing_current_failure_is_not_clear
        ; test_case "fenced empty turn row carries its signature" `Quick
            test_fenced_empty_turn_row_carries_its_signature
        ] )
    ; ( "cache publication"
      , [ test_case "a competing query does not repeat completed work" `Quick
            test_another_list_query_does_not_repeat_completed_work
        ; test_case "explicit invalidation rejects obsolete work" `Quick
            test_explicit_invalidation_repeats_the_obsolete_read
        ] )
    ; ( "lifecycle"
      , [ test_case "detailed row carries lifecycle phase" `Quick
            test_detailed_row_carries_lifecycle_phase
        ] )
    ]
;;
