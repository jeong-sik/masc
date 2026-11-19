(** keeper_memory_write with [supersedes]: one commit removes the named fact
    and writes the claim, and every refusal writes nothing. The tool writes
    through the Keeper's Memory writer, so what a write did is read from the
    receipt, the snapshot and the commit log. *)

module Runtime = Masc.Keeper_tool_memory_runtime
module Current = Masc.Keeper_memory_os_current
module Types = Masc.Keeper_memory_os_types
module Log = Masc.Librarian_log
module Log_store = Masc.Librarian_log_store
module Effects = Masc.Librarian_effects

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

let log_path env ~keeper_id =
  Log_store.path_for_keepers_dir ~keepers_dir:env.keepers_dir ~keeper_id
;;

(* The commit lines of the Keeper's commit log, oldest first. *)
let commits env ~keeper_id =
  match
    Log_store.fold (log_path env ~keeper_id) ~init:[] ~f:(fun seen (scanned : Log_store.scanned) ->
      match scanned.line with
      | Ok (Committed commit) -> commit :: seen
      | Ok (Started _) -> seen
      | Error (_ : Log_store.undecodable) -> Alcotest.fail "a commit log line does not decode")
  with
  | Ok seen -> List.rev seen
  | Error error -> Alcotest.fail (Masc.Private_jsonl_scan.error_to_string error)
;;

let last_commit env ~keeper_id : Log.commit =
  match List.rev (commits env ~keeper_id) with
  | commit :: _ -> commit
  | [] -> Alcotest.fail "the commit log holds no commit"
;;

let removal_text : Effects.removal -> string = function
  | Dropped { reason } -> "dropped: " ^ reason
  | Merged_into successor -> "merged into " ^ successor
  | Revised_into successor -> "revised into " ^ successor
  | Superseded_by successor -> "superseded by " ^ successor
  | Retracted { by = Keeper; reason } -> "retracted by the keeper: " ^ reason
  | Retracted { by = Operator operator; reason } -> "retracted by " ^ operator ^ ": " ^ reason
  | Support_lost { missing } -> "support lost: " ^ String.concat "," missing
;;

let removed (commit : Log.commit) =
  List.map
    (fun ((fact : Types.fact), removal) -> Types.memory_id fact, removal_text removal)
    commit.effects.removed
;;

let write env (meta : Masc.Keeper_meta_contract.keeper_meta) ?supersedes ?derivation content =
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
  Masc_test_deps.Memory_tool_case.writer ~config:env.config meta.name;
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

let has_field key = function
  | `Assoc fields -> List.mem_assoc key fields
  | _ -> Alcotest.fail "expected JSON object"
;;

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

(* A claim the Keeper wrote itself, through the tool. *)
let seed env meta claim =
  let response = write env meta claim in
  check_ok ("seed: " ^ claim) response;
  string_field "memory_id" response
;;

(* What a write may not move when it writes nothing. *)
type before =
  { ids : string list
  ; revision : int option
  ; commits : int
  }

let before env ~keeper_id =
  { ids = current_ids ~keepers_dir:env.keepers_dir ~keeper_id
  ; revision = revision ~keepers_dir:env.keepers_dir ~keeper_id
  ; commits = List.length (commits env ~keeper_id)
  }
;;

let check_nothing_written env ~keeper_id (was : before) label =
  let keepers_dir = env.keepers_dir in
  Alcotest.(check (list string))
    (label ^ ": current facts unchanged")
    was.ids
    (current_ids ~keepers_dir ~keeper_id);
  Alcotest.(check (option int))
    (label ^ ": no new revision")
    was.revision
    (revision ~keepers_dir ~keeper_id);
  Alcotest.(check int)
    (label ^ ": no commit line")
    was.commits
    (List.length (commits env ~keeper_id))
;;

let test_supersede_replaces_the_earlier_claim () =
  with_env
  @@ fun env ->
  let meta = make_meta "supersede-a" in
  let keeper_id = meta.name in
  let first_id = seed env meta "position: stage 1, checkpoint 3" in
  let lines_before = List.length (commits env ~keeper_id) in
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
    "the receipt names what left"
    [ first_id ]
    (string_list_field "removed_memory_ids" second);
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
  Alcotest.(check int)
    "one commit line for the removal and the claim together"
    (lines_before + 1)
    (List.length (commits env ~keeper_id));
  let commit = last_commit env ~keeper_id in
  Alcotest.(check (list (pair string string)))
    "the line keeps the removed fact with what replaced it"
    [ first_id, "superseded by " ^ second_id ]
    (removed commit);
  Alcotest.(check (list string))
    "and the claim it added"
    [ second_id ]
    (List.map Types.memory_id commit.effects.added)
;;

(* A derived fact resting only on the superseded fact loses its support in
   the same commit, and the receipt names it the way a retraction does. *)
let test_supersede_reports_the_derived_facts_it_invalidates () =
  with_env
  @@ fun env ->
  let meta = make_meta "supersede-cascade" in
  let keeper_id = meta.name in
  let premise_id = seed env meta "the build is green" in
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
  let premise_id = seed env meta "stage 1 cleared" in
  let was = before env ~keeper_id in
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
  check_nothing_written env ~keeper_id was label;
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
  check_nothing_written env ~keeper_id was label
;;

(* Bytes already current under another identity are seen again, exactly as a
   plain write of them would be: first_seen and origin stay, only last_seen
   moves. The receipt carries no basis: the commit does not hold the one the
   fact has. *)
let test_supersede_into_an_existing_claim_reobserves_it () =
  with_env
  @@ fun env ->
  let meta = make_meta "supersede-existing" in
  let keeper_id = meta.name in
  let old_id = seed env meta "status: blocked on review" in
  let kept_id = seed env meta "status: merged" in
  let kept_before =
    match snapshot ~keepers_dir:env.keepers_dir ~keeper_id with
    | Some { facts; _ } ->
      (match List.find_opt (fun fact -> String.equal (Types.memory_id fact) kept_id) facts with
       | Some fact -> fact
       | None -> Alcotest.fail "the kept claim is not current")
    | None -> Alcotest.fail "no snapshot after the seeds"
  in
  let response = write env meta ~supersedes:old_id "status: merged" in
  check_ok "superseding into an existing claim" response;
  Alcotest.(check string)
    "the existing claim is seen again, not copied"
    "reobserved"
    (string_field "identity_disposition" response);
  Alcotest.(check bool) "a claim seen again has no basis in the receipt" false
    (has_field "basis" response);
  (match snapshot ~keepers_dir:env.keepers_dir ~keeper_id with
   | Some { facts = [ kept ]; updated_at; _ } ->
     Alcotest.(check string) "the existing claim is the one left" kept_id (Types.memory_id kept);
     Alcotest.(check (float 0.)) "its first_seen is kept" kept_before.first_seen kept.first_seen;
     Alcotest.(check (float 0.)) "its last_seen is the commit's" updated_at kept.last_seen
   | Some _ | None -> Alcotest.fail "expected exactly one current fact");
  let commit = last_commit env ~keeper_id in
  Alcotest.(check (list (pair string string)))
    "the old claim left for the existing one"
    [ old_id, "superseded by " ^ kept_id ]
    (removed commit);
  Alcotest.(check (list string)) "which the line only touches" [ kept_id ] commit.effects.touched;
  Alcotest.(check int) "nothing is added" 0 (List.length commit.effects.added)
;;

let test_refusals_write_nothing () =
  with_env
  @@ fun env ->
  let meta = make_meta "supersede-refusals" in
  let other = make_meta "supersede-other" in
  let keeper_id = meta.name in
  let own_id = seed env meta "position: stage 1" in
  let others_id = seed env other "someone else's claim" in
  let was = before env ~keeper_id in
  let refused ~error_kind label response =
    check_refused ~error_kind label response;
    check_nothing_written env ~keeper_id was label
  in
  let unknown = write env meta ~supersedes:("sha256:" ^ String.make 64 'a') "position: stage 2" in
  refused ~error_kind:"supersedes_not_current" "unknown id" unknown;
  Alcotest.(check string) "the refusal names the field" "supersedes"
    (string_field "rejected_field" unknown);
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

(* Whose fact it was does not matter: one the Librarian put in Memory is
   superseded like one the Keeper wrote. The snapshot is there before the
   Keeper's writer first opens its store, which takes it as Memory. *)
let test_a_librarian_fact_is_superseded_like_the_keepers_own () =
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
  let injected_id = Types.memory_id injected in
  let response = write env meta ~supersedes:injected_id "my own summary of the session" in
  check_ok "superseding the Librarian's fact" response;
  Alcotest.(check string) "the receipt names it" injected_id
    (string_field "superseded_memory_id" response);
  Alcotest.(check (list string))
    "only the Keeper's claim is current"
    [ string_field "memory_id" response ]
    (current_ids ~keepers_dir:env.keepers_dir ~keeper_id);
  Alcotest.(check (list (pair string string)))
    "the line keeps the Librarian's fact with what replaced it"
    [ injected_id, "superseded by " ^ string_field "memory_id" response ]
    (removed (last_commit env ~keeper_id))
;;

(* A [supersedes] that names a fact already gone is answered from what is
   current now. The same call again finds its claim current and says so;
   another claim finds neither and is refused. Removed facts are not looked
   up. *)
let test_a_target_that_already_left () =
  with_env
  @@ fun env ->
  let meta = make_meta "supersede-twice" in
  let keeper_id = meta.name in
  let first_id = seed env meta "deploy window: tuesday" in
  let second = write env meta ~supersedes:first_id "deploy window: thursday" in
  check_ok "first supersession" second;
  let was = before env ~keeper_id in
  let again = write env meta ~supersedes:first_id "deploy window: thursday" in
  check_ok "the same call again" again;
  Alcotest.(check string) "says the claim is already current in its place"
    "already_superseded" (string_field "outcome" again);
  Alcotest.(check string) "with the claim's identity" (string_field "memory_id" second)
    (string_field "memory_id" again);
  Alcotest.(check bool) "and no rows written" true (json_field "rows_written" again = `Int 0);
  check_nothing_written env ~keeper_id was "the same call again";
  let other = write env meta ~supersedes:first_id "deploy window: friday" in
  check_refused ~error_kind:"supersedes_not_current" "another claim for the gone target" other;
  Alcotest.(check bool) "the refusal carries no removal record" false
    (has_field "supersedes_removed" other);
  check_nothing_written env ~keeper_id was "another claim for the gone target"
;;

(* A search match says who put the fact there. *)
let test_search_names_each_current_match_origin () =
  with_env
  @@ fun env ->
  let meta = make_meta "supersede-origin" in
  let keeper_id = meta.name in
  let authored_id = seed env meta "harbor status: authored note" in
  let injected : Types.fact =
    Types.observed
      ~claim:"harbor status: librarian summary"
      ~category:Types.Fact
      ~now:100.
      ~origin:{ kind = Types.Injected; trace_id = "pass" }
  in
  let current =
    match snapshot ~keepers_dir:env.keepers_dir ~keeper_id with
    | Some current -> current
    | None -> Alcotest.fail "expected the authored write to be current"
  in
  (match
     Current.replace
       ~keepers_dir:env.keepers_dir
       ~keeper_id
       ~expected_revision:(Some current.revision)
       ~now:(Unix.gettimeofday ())
       ~source:{ Current.kind = Current.Librarian; trace_id = "pass" }
       ~facts:(current.facts @ [ injected ])
       ()
   with
   | Ok _ -> ()
   | Error detail -> Alcotest.fail detail);
  let response =
    Runtime.keeper_memory_search_json
      ~config:env.config
      ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:
        (`Assoc
           [ "query", `String "harbor status"; "source", `String "current"; "limit", `Int 10 ])
    |> Yojson.Safe.from_string
  in
  let origin_of memory_id =
    match json_field "matches" response with
    | `List matches ->
      (match
         List.find_opt (fun m -> String.equal memory_id (string_field "memory_id" m)) matches
       with
       | Some matched -> string_field "origin" matched
       | None -> Alcotest.failf "no match with memory_id %s" memory_id)
    | _ -> Alcotest.fail "expected a matches list"
  in
  Alcotest.(check string) "the keeper's own write" "authored" (origin_of authored_id);
  Alcotest.(check string)
    "the Librarian's copy"
    "injected"
    (origin_of (Types.memory_id injected))
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
  let case name body =
    Alcotest.test_case name `Quick (Masc_test_deps.Memory_tool_case.run body)
  in
  Alcotest.run
    "keeper_memory_write_supersedes"
    [ ( "supersedes"
      , [ case "replaces the earlier claim in one commit" test_supersede_replaces_the_earlier_claim
        ; case
            "into an existing claim re-observes it"
            test_supersede_into_an_existing_claim_reobserves_it
        ; case
            "reports the derived facts it invalidates"
            test_supersede_reports_the_derived_facts_it_invalidates
        ; case
            "a successor cannot rest on the fact it replaces"
            test_successor_cannot_rest_on_the_fact_it_replaces
        ; case "refusals write nothing" test_refusals_write_nothing
        ; case
            "a fact the Librarian put there is superseded like the Keeper's own"
            test_a_librarian_fact_is_superseded_like_the_keepers_own
        ; case "a target that already left" test_a_target_that_already_left
        ; case "search names each current match's origin" test_search_names_each_current_match_origin
        ; case "cannot ride a source-bound claim" test_supersedes_cannot_ride_a_source_bound_claim
        ] )
    ]
;;
