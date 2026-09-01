(* RFC-0361 Part 5 — the memory journal records failed librarian passes, not
   only committed ones, and a reader decodes both without guessing.

   Before this suite the journal had exactly one consumer in the tree and it
   deleted the file; nothing parsed a line. These cases exist so the write and
   the read are checked against each other rather than against a restatement of
   the encoder: every expectation below is a literal, and the decoder is never
   used to build the value it is compared with. *)

open Alcotest

module Current = Masc.Keeper_memory_os_current
module Types = Masc.Keeper_memory_os_types

let with_keepers_dir f =
  let dir = Filename.temp_file "librarian-journal" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Sys.readdir dir
      |> Array.iter (fun entry -> try Sys.remove (Filename.concat dir entry) with _ -> ());
      try Unix.rmdir dir with _ -> ())
    (fun () -> f dir)
;;

let keeper_id = "omicron-improver"

let append_raw ~keepers_dir line =
  let path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let out = open_out_gen [ Open_append; Open_creat ] 0o644 path in
  output_string out (line ^ "\n");
  close_out out
;;

(* Every kind the journal can hold, listed here rather than derived from a
   function in the module under test: if a variant is added without a wire
   spelling, this list stops compiling. *)
let all_kinds : Current.librarian_failure_kind list =
  [ Prompt_render_failure
  ; Execution_clock_unavailable
  ; Exact_setup_failure
  ; Exact_execution_failure
  ; Domain_output_invalid
  ; Memory_snapshot_write_failure
  ; Runtime_context_unavailable
  ; Lane_cancelled
  ; Unhandled_exception
  ]
;;

let kind_label (kind : Current.librarian_failure_kind) =
  match kind with
  | Prompt_render_failure -> "Prompt_render_failure"
  | Execution_clock_unavailable -> "Execution_clock_unavailable"
  | Exact_setup_failure -> "Exact_setup_failure"
  | Exact_execution_failure -> "Exact_execution_failure"
  | Domain_output_invalid -> "Domain_output_invalid"
  | Memory_snapshot_write_failure -> "Memory_snapshot_write_failure"
  | Runtime_context_unavailable -> "Runtime_context_unavailable"
  | Lane_cancelled -> "Lane_cancelled"
  | Unhandled_exception -> "Unhandled_exception"
;;

let test_missing_journal_reads_empty () =
  with_keepers_dir (fun keepers_dir ->
    check
      int
      "no journal file yields no lines"
      0
      (List.length (Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:10)))
;;

let test_failure_round_trips () =
  with_keepers_dir (fun keepers_dir ->
    Current.append_librarian_failure
      ~keepers_dir
      ~keeper_id
      ~now:1_700_000_000.0
      ~trace_id:"trace-a"
      ~kind:Exact_execution_failure
      ~detail:"provider returned 503"
      ~snapshot_present:true
      ~cadence_deferred:true;
    match Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:10 with
    | [ Ok (Journal_failed entry) ] ->
      check (float 0.0) "recorded_at" 1_700_000_000.0 entry.recorded_at;
      check string "trace_id" "trace-a" entry.trace_id;
      check string "kind" "Exact_execution_failure" (kind_label entry.kind);
      check string "detail" "provider returned 503" entry.detail;
      check bool "snapshot_present" true entry.snapshot_present;
      check bool "cadence_deferred" true entry.cadence_deferred
    | [ Ok (Journal_committed _) ] -> fail "a failure decoded as a commit"
    | [ Error reason ] -> fail ("failure line did not decode: " ^ reason)
    | entries ->
      fail (Printf.sprintf "expected exactly one line, got %d" (List.length entries)))
;;

let test_every_kind_round_trips () =
  with_keepers_dir (fun keepers_dir ->
    List.iteri
      (fun index kind ->
         Current.append_librarian_failure
           ~keepers_dir
           ~keeper_id
           ~now:(float_of_int index)
           ~trace_id:(Printf.sprintf "trace-%d" index)
           ~kind
           ~detail:"detail"
           ~snapshot_present:false
           ~cadence_deferred:false)
      all_kinds;
    let decoded =
      Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:100
      |> List.map (function
        | Ok (Current.Journal_failed entry) -> kind_label entry.kind
        | Ok (Current.Journal_committed _) -> "committed"
        | Error reason -> "error: " ^ reason)
    in
    check
      (list string)
      "each kind survives the wire under its own name"
      (List.map kind_label all_kinds)
      decoded)
;;

let test_unknown_kind_is_an_error () =
  with_keepers_dir (fun keepers_dir ->
    append_raw
      ~keepers_dir
      {|{"outcome":"failed","recorded_at":1.0,"trace_id":"t","kind":"quota_exhausted","detail":"d","snapshot_present":true,"cadence_deferred":false}|};
    match Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:10 with
    | [ Error reason ] ->
      check
        bool
        "the reason quotes the spelling this build does not know"
        true
        (Astring.String.is_infix ~affix:"quota_exhausted" reason)
    | [ Ok _ ] -> fail "an unknown failure kind decoded into a known variant"
    | entries ->
      fail (Printf.sprintf "expected exactly one line, got %d" (List.length entries)))
;;

let test_unknown_outcome_is_an_error () =
  with_keepers_dir (fun keepers_dir ->
    append_raw ~keepers_dir {|{"outcome":"deferred","recorded_at":1.0}|};
    match Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:10 with
    | [ Error reason ] ->
      check
        bool
        "the reason quotes the outcome"
        true
        (Astring.String.is_infix ~affix:"deferred" reason)
    | [ Ok _ ] -> fail "an unknown outcome decoded into a known constructor"
    | entries ->
      fail (Printf.sprintf "expected exactly one line, got %d" (List.length entries)))
;;

let test_unknown_outer_field_is_an_error () =
  with_keepers_dir (fun keepers_dir ->
    append_raw
      ~keepers_dir
      {|{"outcome":"failed","recorded_at":1.0,"trace_id":"t","kind":"unhandled_exception","detail":"d","snapshot_present":false,"cadence_deferred":false,"unexpected":true}|};
    match Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:10 with
    | [ Error reason ] ->
      check
        bool
        "closed journal shape reports the rejected field set"
        true
        (Astring.String.is_infix ~affix:"unknown" reason)
    | [ Ok _ ] -> fail "an unknown outer field crossed the journal boundary"
    | entries ->
      fail (Printf.sprintf "expected exactly one line, got %d" (List.length entries)))
;;

let test_one_bad_line_does_not_hide_its_neighbours () =
  with_keepers_dir (fun keepers_dir ->
    Current.append_librarian_failure
      ~keepers_dir
      ~keeper_id
      ~now:1.0
      ~trace_id:"before"
      ~kind:Domain_output_invalid
      ~detail:"d"
      ~snapshot_present:true
      ~cadence_deferred:false;
    append_raw ~keepers_dir "{not json";
    Current.append_librarian_failure
      ~keepers_dir
      ~keeper_id
      ~now:2.0
      ~trace_id:"after"
      ~kind:Domain_output_invalid
      ~detail:"d"
      ~snapshot_present:true
      ~cadence_deferred:false;
    let shape =
      Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:10
      |> List.map (function
        | Ok (Current.Journal_failed entry) -> entry.trace_id
        | Ok (Current.Journal_committed _) -> "committed"
        | Error _ -> "error")
    in
    check
      (list string)
      "a malformed line occupies its own position instead of shifting the rest"
      [ "before"; "error"; "after" ]
      shape)
;;

let test_limit_keeps_the_newest_lines_oldest_first () =
  with_keepers_dir (fun keepers_dir ->
    List.iter
      (fun index ->
         Current.append_librarian_failure
           ~keepers_dir
           ~keeper_id
           ~now:(float_of_int index)
           ~trace_id:(Printf.sprintf "trace-%d" index)
           ~kind:Unhandled_exception
           ~detail:"d"
           ~snapshot_present:false
           ~cadence_deferred:false)
      [ 1; 2; 3; 4; 5 ];
    let traces =
      Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:2
      |> List.map (function
        | Ok (Current.Journal_failed entry) -> entry.trace_id
        | Ok (Current.Journal_committed _) -> "committed"
        | Error reason -> "error: " ^ reason)
    in
    check (list string) "last two, oldest first" [ "trace-4"; "trace-5" ] traces)
;;

let test_non_positive_limit_reads_nothing () =
  with_keepers_dir (fun keepers_dir ->
    Current.append_librarian_failure
      ~keepers_dir
      ~keeper_id
      ~now:1.0
      ~trace_id:"t"
      ~kind:Unhandled_exception
      ~detail:"d"
      ~snapshot_present:false
      ~cadence_deferred:false;
    check
      int
      "limit 0 is empty, not unbounded"
      0
      (List.length (Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:0)))
;;

let test_committed_line_decodes_as_a_commit () =
  with_keepers_dir (fun keepers_dir ->
    let fact : Types.fact =
      Types.observed ~claim:"a claim" ~category:Fact ~now:1_700_000_000.0
        ~origin:{ kind = Authored; trace_id = "" }
    in
    match
      Current.replace
        ~keepers_dir
        ~keeper_id
        ~expected_revision:None
        ~now:1_700_000_000.0
        ~source:{ kind = Librarian; trace_id = "trace-commit" }
        ~facts:[ fact ]
        ()
    with
    | Error reason -> fail ("replace failed: " ^ reason)
    | Ok _ ->
      (match Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:10 with
       | [ Ok (Journal_committed entry) ] ->
         check int "revision" 1 entry.revision;
         check string "trace_id" "trace-commit" entry.source.trace_id;
         check int "added" 1 (List.length entry.change.added)
       | [ Ok (Journal_failed _) ] -> fail "a commit decoded as a failure"
       | [ Error reason ] -> fail ("commit line did not decode: " ^ reason)
       | entries ->
         fail (Printf.sprintf "expected exactly one line, got %d" (List.length entries))))
;;

let test_committed_line_requires_fact_basis () =
  with_keepers_dir (fun keepers_dir ->
    let fact =
      Types.observed ~claim:"a claim" ~category:Fact ~now:1_700_000_000.0
        ~origin:{ kind = Authored; trace_id = "" }
    in
    (match
       Current.replace
         ~keepers_dir
         ~keeper_id
         ~expected_revision:None
         ~now:1_700_000_000.0
         ~source:{ kind = Librarian; trace_id = "trace-commit" }
         ~facts:[ fact ]
         ()
     with
     | Ok _ -> ()
     | Error reason -> fail ("replace failed: " ^ reason));
    let path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
    let without_basis = function
      | `Assoc fields ->
        `Assoc (List.filter (fun (field, _) -> not (String.equal field "basis")) fields)
      | json -> json
    in
    let broken =
      Fs_compat.load_file path
      |> String.trim
      |> Yojson.Safe.from_string
      |> function
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (field, value) ->
                if String.equal field "change"
                then
                  match value with
                  | `Assoc change_fields ->
                    ( field
                    , `Assoc
                        (List.map
                           (fun (change_field, change_value) ->
                              if String.equal change_field "added"
                              then
                                match change_value with
                                | `List facts ->
                                  change_field, `List (List.map without_basis facts)
                                | _ -> change_field, change_value
                              else change_field, change_value)
                           change_fields) )
                  | _ -> field, value
                else field, value)
             fields)
      | json -> json
    in
    Fs_compat.save_file path (Yojson.Safe.to_string broken ^ "\n");
    match Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:10 with
    | [ Error _ ] -> ()
    | [ Ok _ ] -> fail "a journal fact without basis decoded as current"
    | entries ->
      fail (Printf.sprintf "expected exactly one line, got %d" (List.length entries)))
;;

let () =
  run
    "librarian journal failures"
    [ ( "rfc-0361-part5"
      , [ test_case "missing journal reads empty" `Quick test_missing_journal_reads_empty
        ; test_case "failure round trips" `Quick test_failure_round_trips
        ; test_case "every kind round trips" `Quick test_every_kind_round_trips
        ; test_case "unknown kind is an error" `Quick test_unknown_kind_is_an_error
        ; test_case "unknown outcome is an error" `Quick test_unknown_outcome_is_an_error
        ; test_case
            "unknown outer field is an error"
            `Quick
            test_unknown_outer_field_is_an_error
        ; test_case
            "one bad line does not hide its neighbours"
            `Quick
            test_one_bad_line_does_not_hide_its_neighbours
        ; test_case
            "limit keeps the newest lines oldest first"
            `Quick
            test_limit_keeps_the_newest_lines_oldest_first
        ; test_case "non-positive limit reads nothing" `Quick test_non_positive_limit_reads_nothing
        ; test_case
            "committed line decodes as a commit"
            `Quick
            test_committed_line_decodes_as_a_commit
        ; test_case
            "committed fact basis is required"
            `Quick
            test_committed_line_requires_fact_basis
        ] )
    ]
;;
