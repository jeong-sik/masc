(** keeper_memory_write with [supersedes]: one commit removes the keeper's own
    earlier claim and writes its successor, and every refusal writes nothing. *)

module Runtime = Masc.Keeper_tool_memory_runtime
module Current = Masc.Keeper_memory_os_current
module Types = Masc.Keeper_memory_os_types
module Events = Masc.Keeper_memory_os_events

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir f =
  let dir = Filename.temp_file "keeper-memory-supersedes-" ".tmp" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ])
  with
  | Error error -> Alcotest.fail ("meta fixture failed: " ^ error)
  | Ok meta -> meta
;;

let json_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> Alcotest.failf "missing JSON field: %s" key)
  | _ -> Alcotest.fail "expected JSON object"
;;

let string_field key json =
  match json_field key json with
  | `String value -> value
  | _ -> Alcotest.failf "expected string field: %s" key
;;

let snapshot ~keepers_dir ~keeper_id =
  match Current.read_for_keepers_dir ~keepers_dir ~keeper_id with
  | Ok snapshot -> snapshot
  | Error detail -> Alcotest.fail detail
;;

let current_ids ~keepers_dir ~keeper_id =
  match snapshot ~keepers_dir ~keeper_id with
  | None -> []
  | Some snapshot -> List.map Types.memory_id snapshot.facts
;;

let revision ~keepers_dir ~keeper_id =
  Option.map (fun (snapshot : Current.t) -> snapshot.revision) (snapshot ~keepers_dir ~keeper_id)
;;

let events_for ~keepers_dir ~keeper_id =
  match Events.read ~keepers_dir ~keeper_id with
  | Error error -> Alcotest.fail (Events.file_read_error_to_string error)
  | Ok rows ->
    List.map
      (fun (index, row) ->
         match row with
         | Ok event -> event
         | Error error ->
           Alcotest.failf "event line %d: %s" index (Events.read_error_to_string error))
      rows
;;

type env =
  { config : Masc.Workspace.config
  ; keepers_dir : string
  }

let with_env f =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  f { config; keepers_dir }
;;

let write env meta ?supersedes ?derivation content =
  let args =
    `Assoc
      ([ "content", `String content ]
       @ Option.fold ~none:[] ~some:(fun id -> [ "supersedes", `String id ]) supersedes
       @ Option.fold
           ~none:[]
           ~some:(fun (rule_id, premise_ids) ->
             [ "rule_id", `String rule_id
             ; "premise_ids", `List (List.map (fun id -> `String id) premise_ids)
             ])
           derivation)
  in
  (Runtime.keeper_memory_write_with_outcome ~config:env.config ~meta ~args)
    .Masc.Keeper_tool_execution.raw_output
  |> Yojson.Safe.from_string
;;

let check_ok label response =
  Alcotest.(check bool) label true (json_field "ok" response = `Bool true)
;;

let check_refused ~error_kind label response =
  Alcotest.(check bool) (label ^ ": refused") true (json_field "ok" response = `Bool false);
  Alcotest.(check string) (label ^ ": error_kind") error_kind (string_field "error_kind" response)
;;

(* Refusals must leave the snapshot revision, its facts and the event sidecar
   exactly as they were. *)
let check_nothing_written env ~keeper_id ~before_ids ~before_revision ~before_events label =
  let keepers_dir = env.keepers_dir in
  Alcotest.(check (list string))
    (label ^ ": current facts unchanged")
    before_ids
    (current_ids ~keepers_dir ~keeper_id);
  Alcotest.(check (option int))
    (label ^ ": no new revision")
    before_revision
    (revision ~keepers_dir ~keeper_id);
  Alcotest.(check int)
    (label ^ ": no event recorded")
    before_events
    (List.length (events_for ~keepers_dir ~keeper_id))
;;

let revised_events events =
  List.filter_map
    (fun (event : Events.event) ->
       match event.kind with
       | Events.Revised { superseded_by } -> Some (event.memory_id, superseded_by)
       | Events.Retrieved _ | Events.Retracted -> None)
    events
;;

let test_supersede_replaces_the_earlier_claim () =
  with_env
  @@ fun env ->
  let meta = make_meta "supersede-a" in
  let keeper_id = meta.name in
  let first = write env meta "position: stage 1, checkpoint 3" in
  check_ok "first write" first;
  let first_id = string_field "memory_id" first in
  let second = write env meta ~supersedes:first_id "position: stage 2, checkpoint 1" in
  check_ok "superseding write" second;
  let second_id = string_field "memory_id" second in
  Alcotest.(check string)
    "receipt names the superseded fact"
    first_id
    (string_field "superseded_memory_id" second);
  Alcotest.(check string)
    "the successor is a new fact"
    "inserted"
    (string_field "identity_disposition" second);
  Alcotest.(check (list string))
    "only the successor is current"
    [ second_id ]
    (current_ids ~keepers_dir:env.keepers_dir ~keeper_id);
  (match snapshot ~keepers_dir:env.keepers_dir ~keeper_id with
   | Some { facts = [ successor ]; updated_at; _ } ->
     Alcotest.(check (float 0.))
       "the successor's first_seen is the commit that wrote it"
       updated_at
       successor.first_seen;
     Alcotest.(check (float 0.))
       "and so is its last_seen"
       updated_at
       successor.last_seen
   | Some _ | None -> Alcotest.fail "expected exactly one current fact");
  Alcotest.(check (list (pair string string)))
    "exactly one Revised event, old id to new id"
    [ first_id, second_id ]
    (revised_events (events_for ~keepers_dir:env.keepers_dir ~keeper_id));
  match Current.read_journal_tail ~keepers_dir:env.keepers_dir ~keeper_id ~limit:1 with
  | [ Ok (Current.Journal_committed { dropped = Some [ statement ]; _ }) ] ->
    Alcotest.(check string)
      "the journal names the removed fact"
      first_id
      statement.Types.memory_id
  | _ -> Alcotest.fail "expected one committed journal line with one drop statement"
;;

(* Bytes already current under another identity are a re-observation of that
   fact, exactly as a plain write of them would be: its first_seen and origin
   stay, only last_seen moves. *)
let string_list_field key json =
  match json_field key json with
  | `List values ->
    List.map
      (function
        | `String value -> value
        | _ -> Alcotest.failf "expected strings in %s" key)
      values
  | _ -> Alcotest.failf "expected list field: %s" key
;;

(* A derived fact resting only on the superseded fact loses its support in
   the same commit, and the receipt names it the way a retraction does. *)
let test_supersede_reports_the_derived_facts_it_invalidates () =
  with_env
  @@ fun env ->
  let meta = make_meta "supersede-cascade" in
  let keeper_id = meta.name in
  let premise_id = string_field "memory_id" (write env meta "the build is green") in
  let derived = write env meta ~derivation:("green_means_ready", [ premise_id ]) "ready to release" in
  check_ok "derived write" derived;
  let derived_id = string_field "memory_id" derived in
  let response = write env meta ~supersedes:premise_id "the build is red" in
  check_ok "superseding the premise" response;
  let successor_id = string_field "memory_id" response in
  Alcotest.(check (list string))
    "the derived fact left with its premise"
    [ successor_id ]
    (current_ids ~keepers_dir:env.keepers_dir ~keeper_id);
  Alcotest.(check (list string))
    "removed_memory_ids names the superseded and the derived fact"
    (List.sort compare [ premise_id; derived_id ])
    (List.sort compare (string_list_field "removed_memory_ids" response));
  match json_field "support_invalidations" response with
  | `List [ invalidation ] ->
    Alcotest.(check string) "the invalidated fact" derived_id (string_field "memory_id" invalidation);
    Alcotest.(check (list string))
      "its missing premise"
      [ premise_id ]
      (string_list_field "missing_premise_ids" invalidation)
  | _ -> Alcotest.fail "expected exactly one support invalidation"
;;

(* A successor derived from the fact it replaces would lose its own support
   in the commit that writes it. That is told apart from a premise the store
   never had. *)
let test_successor_cannot_rest_on_the_fact_it_replaces () =
  with_env
  @@ fun env ->
  let meta = make_meta "supersede-own-premise" in
  let keeper_id = meta.name in
  let premise_id = string_field "memory_id" (write env meta "stage 1 cleared") in
  let before_ids = current_ids ~keepers_dir:env.keepers_dir ~keeper_id in
  let before_revision = revision ~keepers_dir:env.keepers_dir ~keeper_id in
  let label = "successor rests on the target" in
  let response =
    write
      env
      meta
      ~supersedes:premise_id
      ~derivation:("next_stage", [ premise_id ])
      "stage 2 is open"
  in
  check_refused ~error_kind:"supersedes_premise_of_successor" label response;
  Alcotest.(check string) "rejected field" "premise_ids" (string_field "rejected_field" response);
  Alcotest.(check (list string))
    "missing premise is the superseded fact"
    [ premise_id ]
    (string_list_field "missing_premise_ids" response);
  check_nothing_written env ~keeper_id ~before_ids ~before_revision ~before_events:0 label;
  let absent = "sha256:" ^ String.make 64 'c' in
  let label = "successor rests on an absent fact" in
  let response =
    write
      env
      meta
      ~supersedes:premise_id
      ~derivation:("next_stage", [ absent ])
      "stage 2 is open"
  in
  check_refused ~error_kind:"unsupported_derivation" label response;
  Alcotest.(check (list string))
    "missing premise is the absent fact"
    [ absent ]
    (string_list_field "missing_premise_ids" response);
  check_nothing_written env ~keeper_id ~before_ids ~before_revision ~before_events:0 label
;;

let test_supersede_into_an_existing_claim_reobserves_it () =
  with_env
  @@ fun env ->
  let meta = make_meta "supersede-existing" in
  let keeper_id = meta.name in
  let authored claim first_seen : Types.fact =
    Types.observed
      ~claim
      ~category:Types.Fact
      ~now:first_seen
      ~origin:{ kind = Types.Authored; trace_id = "seed" }
  in
  let old_fact = authored "status: blocked on review" 100. in
  let kept_fact = authored "status: merged" 200. in
  (match
     Current.replace
       ~keepers_dir:env.keepers_dir
       ~keeper_id
       ~expected_revision:None
       ~now:200.
       ~source:{ Current.kind = Current.Explicit_write; trace_id = "seed" }
       ~facts:[ old_fact; kept_fact ]
       ()
   with
   | Ok _ -> ()
   | Error detail -> Alcotest.fail detail);
  let response =
    write env meta ~supersedes:(Types.memory_id old_fact) kept_fact.claim
  in
  check_ok "superseding into an existing claim" response;
  Alcotest.(check string)
    "the existing claim is re-observed, not copied"
    "reobserved"
    (string_field "identity_disposition" response);
  (match snapshot ~keepers_dir:env.keepers_dir ~keeper_id with
   | Some { facts = [ kept ]; _ } ->
     Alcotest.(check string)
       "the existing claim is the one left"
       (Types.memory_id kept_fact)
       (Types.memory_id kept);
     Alcotest.(check (float 0.)) "its first_seen is kept" 200. kept.first_seen;
     Alcotest.(check bool) "its last_seen moves forward" true (kept.last_seen > 200.)
   | Some _ | None -> Alcotest.fail "expected exactly one current fact");
  Alcotest.(check (list (pair string string)))
    "one Revised event pointing at the existing claim"
    [ Types.memory_id old_fact, Types.memory_id kept_fact ]
    (revised_events (events_for ~keepers_dir:env.keepers_dir ~keeper_id))
;;

let test_refusals_write_nothing () =
  with_env
  @@ fun env ->
  let meta = make_meta "supersede-refusals" in
  let other = make_meta "supersede-other" in
  let keeper_id = meta.name in
  let own = write env meta "position: stage 1" in
  let own_id = string_field "memory_id" own in
  let others_id = string_field "memory_id" (write env other "someone else's claim") in
  let before_ids = current_ids ~keepers_dir:env.keepers_dir ~keeper_id in
  let before_revision = revision ~keepers_dir:env.keepers_dir ~keeper_id in
  let before_events = List.length (events_for ~keepers_dir:env.keepers_dir ~keeper_id) in
  let refused ~error_kind label response =
    check_refused ~error_kind label response;
    check_nothing_written env ~keeper_id ~before_ids ~before_revision ~before_events label
  in
  refused
    ~error_kind:"supersedes_not_current"
    "unknown id"
    (write env meta ~supersedes:("sha256:" ^ String.make 64 'a') "position: stage 2");
  refused
    ~error_kind:"supersedes_not_current"
    "another keeper's id"
    (write env meta ~supersedes:others_id "position: stage 2");
  refused
    ~error_kind:"supersedes_self"
    "the same bytes as the superseded claim"
    (write env meta ~supersedes:own_id "position: stage 1");
  refused
    ~error_kind:"supersedes_invalid"
    "an id that is not a memory identity"
    (write env meta ~supersedes:"mem_01K4Z5" "position: stage 2");
  refused
    ~error_kind:"supersedes_invalid"
    "a padded memory identity"
    (write env meta ~supersedes:(" " ^ own_id) "position: stage 2");
  Alcotest.(check (list string))
    "the other keeper's claim is untouched"
    [ others_id ]
    (current_ids ~keepers_dir:env.keepers_dir ~keeper_id:other.name)
;;

let test_librarian_copy_is_not_supersedable () =
  with_env
  @@ fun env ->
  let meta = make_meta "supersede-injected" in
  let keeper_id = meta.name in
  let injected : Types.fact =
    Types.observed
      ~claim:"librarian summary of the session"
      ~category:Types.Fact
      ~now:100.
      ~origin:{ kind = Types.Injected; trace_id = "pass" }
  in
  (match
     Current.replace
       ~keepers_dir:env.keepers_dir
       ~keeper_id
       ~expected_revision:None
       ~now:100.
       ~source:{ Current.kind = Current.Librarian; trace_id = "pass" }
       ~facts:[ injected ]
       ()
   with
   | Ok _ -> ()
   | Error detail -> Alcotest.fail detail);
  let before_ids = current_ids ~keepers_dir:env.keepers_dir ~keeper_id in
  let before_revision = revision ~keepers_dir:env.keepers_dir ~keeper_id in
  let label = "librarian copy" in
  check_refused
    ~error_kind:"supersedes_not_authored"
    label
    (write env meta ~supersedes:(Types.memory_id injected) "my own summary");
  check_nothing_written env ~keeper_id ~before_ids ~before_revision ~before_events:0 label
;;

let test_supersedes_cannot_ride_a_source_bound_claim () =
  match
    Runtime.validate_memory_write_args
      (`Assoc
          [ "content", `String "config says eu-west-1"
          ; "source_path", `String "config/deploy.env"
          ; "supersedes", `String ("sha256:" ^ String.make 64 'b')
          ])
  with
  | Runtime.Memory_write_invalid { error_kind; _ } ->
    Alcotest.(check string)
      "error kind"
      "supersedes_with_source_path_unsupported"
      (Runtime.memory_write_error_kind_to_string error_kind)
  | Runtime.Memory_write_ok _ -> Alcotest.fail "supersedes with source_path was accepted"
;;

let () =
  Alcotest.run
    "keeper_memory_write_supersedes"
    [ ( "supersedes"
      , [ Alcotest.test_case
            "replaces the earlier claim in one commit"
            `Quick
            test_supersede_replaces_the_earlier_claim
        ; Alcotest.test_case
            "into an existing claim re-observes it"
            `Quick
            test_supersede_into_an_existing_claim_reobserves_it
        ; Alcotest.test_case
            "reports the derived facts it invalidates"
            `Quick
            test_supersede_reports_the_derived_facts_it_invalidates
        ; Alcotest.test_case
            "a successor cannot rest on the fact it replaces"
            `Quick
            test_successor_cannot_rest_on_the_fact_it_replaces
        ; Alcotest.test_case "refusals write nothing" `Quick test_refusals_write_nothing
        ; Alcotest.test_case
            "a librarian copy is not supersedable"
            `Quick
            test_librarian_copy_is_not_supersedable
        ; Alcotest.test_case
            "cannot ride a source-bound claim"
            `Quick
            test_supersedes_cannot_ride_a_source_bound_claim
        ] )
    ]
;;
