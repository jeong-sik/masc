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
      ; "agent_name", `String (Keeper_identity.keeper_agent_name name)
      ; "trace_id", `String ("trace-" ^ name)
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error error -> fail ("meta_of_json failed: " ^ error)
;;

let seed_keepers config names =
  List.iter
    (fun name ->
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
let keeper_list ~names ~args f =
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
      match Keeper_tool_surface.dispatch ctx ~name:"masc_keeper_list" ~args with
      | None -> fail "masc_keeper_list did not dispatch"
      | Some result ->
        let body = Tool_result.message result in
        (match Yojson.Safe.from_string body with
         | exception Yojson.Json_error error ->
           failf "masc_keeper_list returned invalid JSON: %s" error
         | json -> f json))
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
   with a single word forces its readers to guess. The TUI header read the
   folded "inactive" as running while the dashboard read it as attention -
   neither was wrong about the word, because the word does not say which
   question it answers. Each axis gets its own field so no reader has to fold
   or unfold anything. *)
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
let health_only_words = [ "healthy"; "stale"; "zombie"; "degraded" ]
let surface_only_words = [ "active"; "inactive"; "busy"; "listening" ]

let test_health_is_a_health_word_not_a_surface_word () =
  (* [status] answers with the surface vocabulary, which folds stale, degraded
     and zombie into "inactive". [health] must answer from the vocabulary those
     three come from, or the new field is the old fold under a new name. *)
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
   run. The two fields are told apart in test_keeper_surface_status, which
   feeds one diagnostic to both readers and pins that "stale", "degraded" and
   "zombie" survive one and fold to "inactive" in the other. *)

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
        (List.mem value
           [ "auto_restart"; "recover"; "probe"; "direct_message" ])
    | other ->
      failf "next_action must be a string or null, got %s"
        (Yojson.Safe.to_string other))
;;

let () =
  run "keeper_list_truncation"
    [ ( "listing truth"
      , [ test_case "truncated answer reports the whole directory" `Quick
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
        ; test_case "health uses the health vocabulary" `Quick
            test_health_is_a_health_word_not_a_surface_word
        ; test_case "an unnamed next action is null" `Quick
            test_absent_next_action_is_null_not_empty
        ] )
    ; ( "lifecycle"
      , [ test_case "detailed row carries lifecycle phase" `Quick
            test_detailed_row_carries_lifecycle_phase
        ] )
    ]
;;
