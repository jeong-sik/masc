(* Checks for the external store: the bytes of each line, the rules that a line
   must follow the lines before it, what the file adds up to, and what opening
   a file with a torn or broken line gives. Every case that touches a file runs
   on real files in a fresh temporary directory, through the production path of
   [Fs_compat]. *)

open Authz_types
open Authz_records
module S = Authz_external_store
module H = Authz_record.Hash
module C = S.Change

(* ---- fixtures ---- *)

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let hash_of character =
  match H.of_hex (String.make 64 character) with
  | Some hash -> hash
  | None -> Alcotest.fail "fixture hash rejected"
;;

let before = hash_of 'a'
let digest = hash_of 'b'
let other_digest = hash_of 'c'
let grant = Subject.Grant (get (Grant_id.of_string "grant-1"))
let credential = Subject.Credential (get (Provider_account_id.of_string "account-1"))
let runtime = Subject.Runtime (get (Runtime_id.of_string "runtime-1"))
let human = Subject.Principal (Principal.Human (get (User_id.of_string "alice")))
let service = Subject.Principal (Principal.Service (get (Service_id.of_string "keeper-1")))
let workspace = get (Workspace_id.of_string "workspace-1")
let other_workspace = get (Workspace_id.of_string "workspace-2")
let subjects = [ grant; credential; runtime; human; service ]
let authz event subject = C.Authz { event; subject }
let mode event workspace_id = C.Mode { event; workspace_id }

let intent ?(previous = before) ?(digest = digest) change : S.intent =
  { S.previous_record_hash = previous; intended_next_record_digest = digest; change }
;;

let revoke_grant = authz C.Revoke grant
let block_runtime = authz C.Block runtime
let bootstrap = mode C.Fresh_bootstrap workspace
let pending ?previous ?digest change = S.Intent_pending (intent ?previous ?digest change)
let aborted ?previous ?digest change = S.Aborted_intent (intent ?previous ?digest change)
let committed record_hash = S.Committed { record_hash }

(* The first two lines of a store that is set up: a bootstrap and its answer.
   Every change but a bootstrap needs them in front. *)
let boot_digest = hash_of 'f'
let bootstrap_entries = [ pending ~digest:boot_digest bootstrap; committed boot_digest ]

(* The changes that a store refuses as its first intent, and the mode changes
   that name a workspace. The append cases and the replay cases use the same
   tables, so the two paths are held to the same rules. *)
let first_intent_refusals =
  [ "a revocation first", revoke_grant
  ; "a grant first", authz C.Grant human
  ; "a switch off first", mode C.Off workspace
  ; "a reactivation first", mode C.Reactivate workspace
  ]
;;

let mode_changes_for workspace_id =
  [ "a switch off for " ^ Workspace_id.to_string workspace_id, mode C.Off workspace_id
  ; "a reactivation for " ^ Workspace_id.to_string workspace_id, mode C.Reactivate workspace_id
  ]
;;

(* ---- text and files ---- *)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path text =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text)
;;

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

(* A fresh path, inside an Eio event loop because the zone is an [Eio.Mutex]. *)
let with_path f =
  Eio_main.run (fun _env ->
    let dir = Filename.temp_dir "authz-external-store-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree dir)
      (fun () -> f (Filename.concat (Filename.concat dir "store") "external.jsonl")))
;;

let text_of entries = String.concat "" (List.map (fun entry -> S.to_line entry ^ "\n") entries)

let find_sub ~sub text =
  let sub_length = String.length sub in
  let rec go at =
    if at + sub_length > String.length text
    then None
    else if String.equal (String.sub text at sub_length) sub
    then Some at
    else go (at + 1)
  in
  go 0
;;

let contains ~sub text = Option.is_some (find_sub ~sub text)

let replace ~sub ~by text =
  match find_sub ~sub text with
  | None -> Alcotest.failf "fixture text does not hold %s" sub
  | Some at ->
    let after = at + String.length sub in
    String.sub text 0 at ^ by ^ String.sub text after (String.length text - after)
;;

(* ---- names, so that a new constructor fails to compile until it is placed ---- *)

let violation_name : S.violation -> string = function
  | S.Intent_while_pending -> "Intent_while_pending"
  | S.Committed_without_intent -> "Committed_without_intent"
  | S.Committed_other_digest -> "Committed_other_digest"
  | S.Aborted_without_intent -> "Aborted_without_intent"
  | S.Aborted_other_intent -> "Aborted_other_intent"
  | S.Intent_before_bootstrap -> "Intent_before_bootstrap"
  | S.Bootstrap_already_committed -> "Bootstrap_already_committed"
  | S.Workspace_mismatch -> "Workspace_mismatch"
;;

let line_error_name : S.line_error -> string = function
  | S.Not_json -> "Not_json"
  | S.Unexpected_shape -> "Unexpected_shape"
  | S.Unknown_kind label -> Printf.sprintf "Unknown_kind %s" label
  | S.Invalid_hash -> "Invalid_hash"
  | S.Invalid_change -> "Invalid_change"
  | S.Breaks_a_rule violation -> "Breaks_a_rule " ^ violation_name violation
  | S.Non_canonical -> "Non_canonical"
;;

let append_error_name : S.append_error -> string = function
  | S.Writer_expired -> "Writer_expired"
  | S.Stopped _ -> "Stopped"
  | S.Rejected { index; reject } ->
    Printf.sprintf "Rejected index=%d %s" index (violation_name reject)
  | S.Would_not_read_back { index; error } ->
    Printf.sprintf "Would_not_read_back index=%d %s" index (line_error_name error)
  | S.Read_back_changed { index } -> Printf.sprintf "Read_back_changed index=%d" index
  | S.Write_locked _ -> "Write_locked"
  | S.Diverged _ -> "Diverged"
  | S.Write_failed _ -> "Write_failed"
;;

let open_error_name : _ S.open_error -> string = function
  | S.Locked _ -> "Locked"
  | S.Unreadable _ -> "Unreadable"
  | S.Line_rejected { line_number; error; _ } ->
    Printf.sprintf "Line_rejected line=%d %s" line_number (line_error_name error)
  | S.Fold_refused { line_number; _ } -> Printf.sprintf "Fold_refused line=%d" line_number
;;

let contents_name = function
  | S.Missing -> "Missing"
  | S.Empty -> "Empty"
  | S.Lines count -> Printf.sprintf "Lines %d" count
;;

(* ---- opening and writing, as the cases use them ---- *)

let collect state entry = Ok (entry :: state)

let open_ok ~path =
  match S.open_at_start ~path ~init:[] ~step:collect with
  | Ok (store, entries, recovered) -> store, List.rev entries, recovered
  | Error error ->
    Alcotest.failf "open refused: %s" (S.open_error_to_string (fun () -> "") error)
;;

let check_open_error label expected ~path =
  match S.open_at_start ~path ~init:[] ~step:collect with
  | Ok _ -> Alcotest.failf "%s: open succeeded where it should have been refused" label
  | Error error -> Alcotest.(check string) label expected (open_error_name error)
;;

let in_zone store f =
  match S.with_writer store f with
  | Ok value -> value
  | Error stop -> Alcotest.failf "the store is stopped: %s" stop.S.reason
;;

let state_of store = in_zone store (fun _writer state -> state)

let append_ok store entries =
  in_zone store (fun writer _state ->
    match S.append writer entries with
    | Ok state -> state
    | Error error -> Alcotest.failf "append refused: %s" (S.append_error_to_string error))
;;

let check_append label expected store entries =
  let outcome =
    in_zone store (fun writer _state ->
      match S.append writer entries with
      | Ok _ -> "Ok"
      | Error error -> append_error_name error)
  in
  Alcotest.(check string) label expected outcome
;;

let hash_name = function
  | None -> "none"
  | Some hash -> H.to_hex hash
;;

let check_hash label expected actual =
  Alcotest.(check string) label (hash_name expected) (hash_name actual)
;;

let check_intents label expected actual =
  let lines intents = List.map (fun intent -> S.to_line (S.Intent_pending intent)) intents in
  Alcotest.(check (list string)) label (lines expected) (lines actual)
;;

let check_pending label expected state =
  check_intents label (Option.to_list expected) (Option.to_list (S.State.pending state))
;;

(* ---- the bytes of a line ---- *)

let a64 = String.make 64 'a'
let b64 = String.make 64 'b'

let intent_prefix kind =
  Printf.sprintf
    {|{"kind":"%s","previous_record_hash":"%s","intended_next_record_digest":"%s","change":|}
    kind
    a64
    b64
;;

let lines_are_pinned () =
  let check label expected entry = Alcotest.(check string) label expected (S.to_line entry) in
  check
    "an intent about a grant"
    (intent_prefix "intent_pending"
     ^ {|{"type":"authz","event":"revoke","subject":{"type":"grant","id":"grant-1"}}}|})
    (pending revoke_grant);
  check
    "an intent about a person"
    (intent_prefix "intent_pending"
     ^ {|{"type":"authz","event":"disable","subject":{"type":"principal","principal":{"type":"human","id":"alice"}}}}|})
    (pending (authz C.Disable human));
  check
    "an intent about a service"
    (intent_prefix "intent_pending"
     ^ {|{"type":"authz","event":"disable","subject":{"type":"principal","principal":{"type":"service","id":"keeper-1"}}}}|})
    (pending (authz C.Disable service));
  check
    "an intent about the mode"
    (intent_prefix "intent_pending"
     ^ {|{"type":"mode","event":"fresh_bootstrap","workspace_id":"workspace-1"}}|})
    (pending bootstrap);
  check
    "the answer that the record is in the log"
    (Printf.sprintf {|{"kind":"committed","record_hash":"%s"}|} b64)
    (committed digest);
  check
    "the answer that the intent is given up"
    (intent_prefix "aborted_intent"
     ^ {|{"type":"authz","event":"revoke","subject":{"type":"grant","id":"grant-1"}}}|})
    (aborted revoke_grant)
;;

(* The word that each event is written as. Every constructor is named, so that
   a new event fails to compile until its word is decided. *)
let expected_authz_label : C.authz_event -> string = function
  | C.Grant -> "grant"
  | C.Revoke -> "revoke"
  | C.Disable -> "disable"
  | C.Delete -> "delete"
  | C.Block -> "block"
  | C.Purge -> "purge"
  | C.Policy_revoke -> "policy_revoke"
  | C.Credential_replace -> "credential_replace"
;;

let expected_mode_label : C.mode_event -> string = function
  | C.Fresh_bootstrap -> "fresh_bootstrap"
  | C.Off -> "off"
  | C.Reactivate -> "reactivate"
;;

let event_words_are_pinned () =
  let event_member word = Printf.sprintf {|"event":"%s"|} word in
  List.iter
    (fun event ->
      Alcotest.(check bool)
        (expected_authz_label event)
        true
        (contains ~sub:(event_member (expected_authz_label event)) (S.to_line (pending (authz event grant)))))
    C.authz_events;
  List.iter
    (fun event ->
      Alcotest.(check bool)
        (expected_mode_label event)
        true
        (contains ~sub:(event_member (expected_mode_label event)) (S.to_line (pending (mode event workspace)))))
    C.mode_events
;;

let all_changes =
  List.concat_map
    (fun event -> List.map (fun subject -> authz event subject) subjects)
    C.authz_events
  @ List.map (fun event -> mode event workspace) C.mode_events
;;

(* The entries hold hashes, ids and variants only, so [=] compares every member. *)
let check_reads_back label state entry =
  let line = S.to_line entry in
  match S.of_line state line with
  | Ok read ->
    Alcotest.(check string) label line (S.to_line read);
    Alcotest.(check bool) (label ^ ": the same entry") true (read = entry)
  | Error error -> Alcotest.failf "%s: %s" label (S.line_error_to_string error)
;;

let every_change_reads_back () =
  Alcotest.(check int)
    "eight authorization events with five subjects each, and three mode events"
    43
    (List.length all_changes);
  with_path (fun path ->
    let store, _, _ = open_ok ~path in
    let bootstrapped = append_ok store bootstrap_entries in
    List.iter
      (fun change ->
        (* A bootstrap reads at the start of a store, every other change after one. *)
        let state = if C.equal change bootstrap then S.State.empty else bootstrapped in
        check_reads_back (C.to_string change) state (pending change))
      all_changes)
;;

let answers_read_back_after_their_intent () =
  with_path (fun path ->
    let store, _, _ = open_ok ~path in
    let state = append_ok store [ pending bootstrap ] in
    List.iter
      (fun entry -> check_reads_back "an answer" state entry)
      [ committed digest; aborted bootstrap ])
;;

(* Every change goes through [append], which reads each line back and compares
   it with the entry, and through the replay of a reopened file. *)
let every_change_is_appended_and_replayed () =
  with_path (fun path ->
    let store, _, _ = open_ok ~path in
    ignore (append_ok store [ pending bootstrap; aborted bootstrap ] : S.State.t);
    ignore (append_ok store bootstrap_entries : S.State.t);
    let others = List.filter (fun change -> not (C.equal change bootstrap)) all_changes in
    let state =
      append_ok store (List.concat_map (fun change -> [ pending change; aborted change ]) others)
    in
    let expected = List.map (fun change -> intent change) (bootstrap :: others) in
    check_intents "every change is kept, in file order" expected (S.State.aborted state);
    let reopened, entries, _ = open_ok ~path in
    Alcotest.(check int)
      "every line is replayed"
      (4 + (2 * List.length others))
      (List.length entries);
    let again = state_of reopened in
    check_intents "a reopened file adds up to the same" expected (S.State.aborted again);
    check_hash "with the commit of the bootstrap" (Some boot_digest) (S.State.last_committed again);
    check_pending "and nothing pending" None again;
    Alcotest.(check bool) "and the workspace of the bootstrap" true
      (match S.State.workspace_id again with
       | Some id -> Workspace_id.equal id workspace
       | None -> false))
;;

(* ---- what a change is ---- *)

let expected_reduction : C.authz_event -> bool = function
  | C.Grant -> false
  | C.Revoke | C.Disable | C.Delete | C.Block | C.Purge | C.Policy_revoke | C.Credential_replace
    -> true
;;

let reductions () =
  List.iter
    (fun event ->
      List.iter
        (fun subject ->
          Alcotest.(check bool)
            (C.to_string (authz event subject))
            (expected_reduction event)
            (C.is_reduction (authz event subject)))
        subjects)
    C.authz_events;
  List.iter
    (fun event ->
      Alcotest.(check bool)
        (C.to_string (mode event workspace))
        false
        (C.is_reduction (mode event workspace)))
    C.mode_events
;;

let changes_are_equal_field_for_field () =
  Alcotest.(check bool) "the same change" true (C.equal revoke_grant (authz C.Revoke grant));
  Alcotest.(check bool) "another event" false (C.equal revoke_grant (authz C.Disable grant));
  Alcotest.(check bool) "another subject" false (C.equal revoke_grant (authz C.Revoke runtime));
  Alcotest.(check bool) "a person is not the same person" false (C.equal (authz C.Disable human) (authz C.Disable service));
  Alcotest.(check bool) "the same mode change" true (C.equal bootstrap (mode C.Fresh_bootstrap workspace));
  Alcotest.(check bool) "another mode event" false (C.equal bootstrap (mode C.Off workspace));
  Alcotest.(check bool) "another workspace" false (C.equal bootstrap (mode C.Fresh_bootstrap other_workspace));
  Alcotest.(check bool) "a mode change is not an authorization change" false (C.equal bootstrap revoke_grant)
;;

(* ---- the rules, when a line is appended ---- *)

let rules_when_appending () =
  with_path (fun path ->
    let store, _, _ = open_ok ~path in
    check_append "an answer needs an intent" "Rejected index=0 Committed_without_intent" store [ committed digest ];
    check_append "an abort needs an intent" "Rejected index=0 Aborted_without_intent" store [ aborted revoke_grant ];
    Alcotest.(check bool) "nothing was written" false (Sys.file_exists path);
    ignore (append_ok store bootstrap_entries : S.State.t);
    ignore (append_ok store [ pending revoke_grant ] : S.State.t);
    let one_intent = text_of (bootstrap_entries @ [ pending revoke_grant ]) in
    check_append "a second intent while one is pending" "Rejected index=0 Intent_while_pending" store [ pending block_runtime ];
    check_append "an answer with another hash" "Rejected index=0 Committed_other_digest" store [ committed other_digest ];
    List.iter
      (fun (label, entry) ->
        check_append label "Rejected index=0 Aborted_other_intent" store [ entry ])
      [ "an abort with another previous hash", aborted ~previous:other_digest revoke_grant
      ; "an abort with another digest", aborted ~digest:other_digest revoke_grant
      ; "an abort with another event", aborted (authz C.Disable grant)
      ; "an abort with another subject", aborted (authz C.Revoke runtime)
      ];
    Alcotest.(check string) "the refusals wrote nothing" one_intent (read_file path);
    ignore (append_ok store [ committed digest ] : S.State.t);
    check_append
      "a list is checked entry by entry: the second intent finds the first one pending"
      "Rejected index=1 Intent_while_pending"
      store
      [ pending ~digest:other_digest block_runtime; pending revoke_grant ];
    Alcotest.(check string) "and no byte of the list was written" (one_intent ^ text_of [ committed digest ]) (read_file path);
    check_append "an intent and its answer in one list" "Ok" store [ pending ~digest:other_digest block_runtime; committed other_digest ])
;;

(* A store starts with a bootstrap. Until one is committed the file takes only a
   bootstrap. After it, a second bootstrap is refused, and a switch off or a
   reactivation names the workspace that the bootstrap set up. *)
let a_store_starts_with_a_bootstrap () =
  with_path (fun path ->
    let store, _, _ = open_ok ~path in
    List.iter
      (fun (label, change) ->
        check_append label "Rejected index=0 Intent_before_bootstrap" store [ pending change ])
      first_intent_refusals;
    Alcotest.(check bool) "nothing was written" false (Sys.file_exists path);
    ignore (append_ok store [ pending bootstrap; aborted bootstrap ] : S.State.t);
    check_append
      "a bootstrap that is given up does not open the file"
      "Rejected index=0 Intent_before_bootstrap"
      store
      [ pending revoke_grant ];
    let second = mode C.Fresh_bootstrap other_workspace in
    ignore (append_ok store [ pending ~digest:other_digest second; committed other_digest ] : S.State.t);
    Alcotest.(check bool) "the committed bootstrap sets the workspace" true
      (match S.State.workspace_id (state_of store) with
       | Some id -> Workspace_id.equal id other_workspace
       | None -> false);
    List.iter
      (fun (label, change) ->
        check_append label "Rejected index=0 Bootstrap_already_committed" store [ pending change ])
      [ "a second bootstrap for the same workspace", second
      ; "a second bootstrap for another workspace", bootstrap
      ];
    List.iter
      (fun (label, change) ->
        check_append label "Rejected index=0 Workspace_mismatch" store [ pending change ])
      (mode_changes_for workspace);
    check_append "an authorization change" "Ok" store [ pending revoke_grant; aborted revoke_grant ];
    List.iter
      (fun (label, change) -> check_append label "Ok" store [ pending change; aborted change ])
      (mode_changes_for other_workspace);
    check_append
      "an abort of a mode change that differs only in the workspace"
      "Rejected index=1 Aborted_other_intent"
      store
      [ pending (mode C.Off other_workspace); aborted (mode C.Off workspace) ])
;;

(* The file keeps the workspace of the bootstrap and not the mode. The design does
   not say which mode event may follow which, so the file takes a switch off
   twice, a reactivation twice, and an authorization change after a switch off.
   The layers that write them decide the order. A rule added here later would
   refuse files that are taken today, so this case holds the present choice. *)
let mode_events_may_repeat_and_come_in_any_order () =
  with_path (fun path ->
    let store, _, _ = open_ok ~path in
    ignore (append_ok store bootstrap_entries : S.State.t);
    let steps =
      [ mode C.Off workspace
      ; mode C.Off workspace
      ; mode C.Reactivate workspace
      ; mode C.Reactivate workspace
      ; mode C.Off workspace
      ; revoke_grant
      ]
    in
    let digests = List.map hash_of [ '1'; '2'; '3'; '4'; '5'; '6' ] in
    let entries =
      List.concat (List.map2 (fun change digest -> [ pending ~digest change; committed digest ]) steps digests)
    in
    let state = append_ok store entries in
    check_pending "nothing is pending" None state;
    check_hash "the last answer" (Some (hash_of '6')) (S.State.last_committed state);
    let reopened, replayed, _ = open_ok ~path in
    Alcotest.(check int)
      "every line is replayed"
      (List.length bootstrap_entries + List.length entries)
      (List.length replayed);
    check_hash "a reopened file says the same" (Some (hash_of '6')) (S.State.last_committed (state_of reopened)))
;;

(* Two writers that both start from a missing file. The one that appends second
   finds the file where the first left it, and its entries are not written. *)
let a_second_writer_that_starts_from_a_missing_file_is_refused () =
  with_path (fun path ->
    let first, _, _ = open_ok ~path in
    let second, _, _ = open_ok ~path in
    ignore (append_ok first [ pending bootstrap ] : S.State.t);
    let written = read_file path in
    check_append "the second writer" "Diverged" second [ pending ~digest:other_digest bootstrap ];
    Alcotest.(check string) "the file holds the first line only" written (read_file path))
;;

(* [apply] is the rule set that [append] and [of_line] use, without a file. It
   refuses with the same rule, and the state it gives is the state that a file
   holding the same entries adds up to. *)
let apply_refuses_with_the_rule_of_the_file () =
  let booted_state = List.fold_left (fun state entry ->
    match S.apply state entry with
    | Ok state -> state
    | Error violation -> Alcotest.failf "the fixture breaks a rule: %s" (violation_name violation))
    S.State.empty
    bootstrap_entries
  in
  List.iter
    (fun (label, state, entry, expected) ->
      match S.apply state entry with
      | Ok _ -> Alcotest.failf "%s: the entry was taken" label
      | Error violation -> Alcotest.(check string) label expected (violation_name violation))
    [ "an answer needs an intent", S.State.empty, committed digest, "Committed_without_intent"
    ; "an abort needs an intent", S.State.empty, aborted revoke_grant, "Aborted_without_intent"
    ; "a store starts with a bootstrap", S.State.empty, pending revoke_grant, "Intent_before_bootstrap"
    ; ( "a second bootstrap"
      , booted_state
      , pending ~digest:other_digest (mode C.Fresh_bootstrap other_workspace)
      , "Bootstrap_already_committed" )
    ; ( "a switch off for another workspace"
      , booted_state
      , pending ~digest:other_digest (mode C.Off other_workspace)
      , "Workspace_mismatch" )
    ]
;;

let apply_gives_the_state_of_the_file () =
  with_path (fun path ->
    let store, _, _ = open_ok ~path in
    let entries =
      bootstrap_entries
      @ [ pending revoke_grant
        ; aborted revoke_grant
        ; pending ~digest:other_digest block_runtime
        ; committed other_digest
        ; pending ~previous:other_digest ~digest:(hash_of 'd') (mode C.Off workspace)
        ]
    in
    let from_file = append_ok store entries in
    let from_apply =
      List.fold_left
        (fun state entry ->
          match S.apply state entry with
          | Ok state -> state
          | Error violation ->
            Alcotest.failf "the fixture breaks a rule: %s" (violation_name violation))
        S.State.empty
        entries
    in
    check_pending "the pending intent" (S.State.pending from_file) from_apply;
    check_hash "the last commit" (S.State.last_committed from_file) (S.State.last_committed from_apply);
    check_intents "the given-up intents" (S.State.aborted from_file) (S.State.aborted from_apply);
    let workspace_name state =
      Option.map Workspace_id.to_string (S.State.workspace_id state)
    in
    Alcotest.(check (option string))
      "the workspace"
      (workspace_name from_file)
      (workspace_name from_apply))
;;

(* ---- what the lines add up to ---- *)

let state_follows_the_lines () =
  with_path (fun path ->
    let store, _, _ = open_ok ~path in
    let first = intent revoke_grant in
    let second = intent ~previous:digest ~digest:other_digest block_runtime in
    let third = intent ~previous:other_digest ~digest:(hash_of 'd') (authz C.Purge credential) in
    let empty = state_of store in
    check_pending "no intent in an empty file" None empty;
    check_hash "no commit" None (S.State.last_committed empty);
    check_intents "no abort" [] (S.State.aborted empty);
    let state = append_ok store bootstrap_entries in
    check_hash "the commit of the bootstrap" (Some boot_digest) (S.State.last_committed state);
    check_pending "an intent is pending" (Some first) (append_ok store [ S.Intent_pending first ]);
    let state = append_ok store [ S.Aborted_intent first ] in
    check_pending "an abort answers it" None state;
    check_intents "and is kept" [ first ] (S.State.aborted state);
    check_hash "without a new commit" (Some boot_digest) (S.State.last_committed state);
    ignore (append_ok store [ S.Intent_pending second ] : S.State.t);
    let state = append_ok store [ committed other_digest ] in
    check_pending "a commit answers the next one" None state;
    check_hash "and keeps its hash" (Some other_digest) (S.State.last_committed state);
    ignore (append_ok store [ S.Intent_pending third ] : S.State.t);
    let state = append_ok store [ S.Aborted_intent third ] in
    check_intents "aborts are kept in file order" [ first; third ] (S.State.aborted state);
    check_hash "a later abort leaves the commit" (Some other_digest) (S.State.last_committed state))
;;

let workspace_is_set_by_the_committed_bootstrap () =
  with_path (fun path ->
    let store, _, _ = open_ok ~path in
    let workspace_name state =
      match S.State.workspace_id state with
      | Some id -> Workspace_id.to_string id
      | None -> "none"
    in
    Alcotest.(check string) "none in an empty file" "none" (workspace_name (state_of store));
    Alcotest.(check string)
      "none while the bootstrap is only an intent"
      "none"
      (workspace_name (append_ok store [ pending bootstrap ]));
    Alcotest.(check string)
      "none after it is given up"
      "none"
      (workspace_name (append_ok store [ aborted bootstrap ]));
    Alcotest.(check string)
      "set when it is committed"
      "workspace-1"
      (workspace_name (append_ok store [ pending bootstrap; committed digest ]));
    Alcotest.(check string)
      "the same after a later mode change"
      "workspace-1"
      (workspace_name
         (append_ok
            store
            [ pending ~previous:digest ~digest:other_digest (mode C.Off workspace)
            ; committed other_digest
            ])))
;;

(* ---- the file ---- *)

let first_append_creates_the_file_and_reopening_keeps_the_state () =
  with_path (fun path ->
    let store, entries, recovered = open_ok ~path in
    Alcotest.(check string) "no file" "Missing" (contents_name recovered.S.contents);
    Alcotest.(check int) "nothing replayed" 0 (List.length entries);
    Alcotest.(check bool) "opening does not create the file" false (Sys.file_exists path);
    ignore (append_ok store [ pending bootstrap ] : S.State.t);
    Alcotest.(check string) "the bytes of the file" (text_of [ pending bootstrap ]) (read_file path);
    let reopened, entries, recovered = open_ok ~path in
    Alcotest.(check string) "one line" "Lines 1" (contents_name recovered.S.contents);
    Alcotest.(check (list string)) "the entry" [ S.to_line (pending bootstrap) ] (List.map S.to_line entries);
    check_pending "the intent is still pending" (Some (intent bootstrap)) (state_of reopened);
    ignore (append_ok reopened [ committed digest ] : S.State.t);
    let again, _, _ = open_ok ~path in
    let state = state_of again in
    check_pending "answered" None state;
    check_hash "committed" (Some digest) (S.State.last_committed state))
;;

let torn_last_entry_is_cut () =
  with_path (fun path ->
    let complete = text_of [ pending bootstrap ] in
    let answer = S.to_line (committed digest) in
    let fragment = String.sub answer 0 (String.length answer / 2) in
    write_file path (complete ^ fragment);
    let store, entries, recovered = open_ok ~path in
    Alcotest.(check string) "one line survives" "Lines 1" (contents_name recovered.S.contents);
    (match recovered.S.tail with
     | S.Cut { kept_bytes; discarded_bytes } ->
       Alcotest.(check int) "kept bytes" (String.length complete) kept_bytes;
       Alcotest.(check int) "discarded bytes" (String.length fragment) discarded_bytes
     | S.Complete -> Alcotest.fail "the torn tail was not reported");
    Alcotest.(check int) "the entries before it" 1 (List.length entries);
    Alcotest.(check string) "the file ends after the last complete line" complete (read_file path);
    check_pending "the intent is still pending" (Some (intent bootstrap)) (state_of store);
    ignore (append_ok store [ committed digest ] : S.State.t);
    let again, _, _ = open_ok ~path in
    check_hash "the answer written after the cut" (Some digest) (S.State.last_committed (state_of again)))
;;

let fold_refusal_names_the_line () =
  with_path (fun path ->
    write_file path (text_of [ pending bootstrap; committed digest ]);
    match
      S.open_at_start
        ~path
        ~init:()
        ~step:(fun () entry ->
          match entry with
          | S.Committed _ -> Error "refused"
          | S.Intent_pending _ | S.Aborted_intent _ -> Ok ())
    with
    | Error error -> Alcotest.(check string) "the line of the refused entry" "Fold_refused line=2" (open_error_name error)
    | Ok _ -> Alcotest.fail "the fold did not refuse")
;;

(* ---- files that are not a store ---- *)

let files_that_break_the_rules () =
  let again = mode C.Fresh_bootstrap other_workspace in
  List.iter
    (fun (label, text, expected) ->
      with_path (fun path ->
        write_file path text;
        check_open_error label expected ~path;
        Alcotest.(check string) (label ^ ": the file is left alone") text (read_file path)))
    ([ ( "an answer first"
      , text_of [ committed digest ]
      , "Line_rejected line=1 Breaks_a_rule Committed_without_intent" )
    ; ( "an abort first"
      , text_of [ aborted bootstrap ]
      , "Line_rejected line=1 Breaks_a_rule Aborted_without_intent" )
    ; ( "two intents"
      , text_of [ pending bootstrap; pending ~digest:other_digest bootstrap ]
      , "Line_rejected line=2 Breaks_a_rule Intent_while_pending" )
    ; ( "a commit that names another hash"
      , text_of [ pending bootstrap; committed other_digest ]
      , "Line_rejected line=2 Breaks_a_rule Committed_other_digest" )
    ; ( "an abort of another intent"
      , text_of [ pending bootstrap; aborted again ]
      , "Line_rejected line=2 Breaks_a_rule Aborted_other_intent" )
    ; ( "a second bootstrap after a committed one"
      , text_of (bootstrap_entries @ [ pending ~digest:other_digest again ])
      , "Line_rejected line=3 Breaks_a_rule Bootstrap_already_committed" )
    ]
    @ List.map
        (fun (label, change) ->
          ( label ^ ", in a file"
          , text_of [ pending change ]
          , "Line_rejected line=1 Breaks_a_rule Intent_before_bootstrap" ))
        first_intent_refusals
    @ List.map
        (fun (label, change) ->
          ( label ^ ", in a file"
          , text_of (bootstrap_entries @ [ pending ~digest:other_digest change ])
          , "Line_rejected line=3 Breaks_a_rule Workspace_mismatch" ))
        (mode_changes_for other_workspace))
;;

let lines_that_are_not_entries () =
  let committed_text = S.to_line (committed digest) in
  let intent_text = S.to_line (pending revoke_grant) in
  let bootstrap_text = S.to_line (pending bootstrap) in
  List.iter
    (fun (label, line, expected) ->
      with_path (fun path ->
        write_file path (line ^ "\n");
        check_open_error label ("Line_rejected line=1 " ^ expected) ~path))
    [ "not json", "{", "Not_json"
    ; "an unknown kind", replace ~sub:"committed" ~by:"expired" committed_text, "Unknown_kind expired"
    ; "an unknown kind comes before the members", {|{"kind":"expired","at":1}|}, "Unknown_kind expired"
    ; "a member too many", replace ~sub:{|"}|} ~by:{|","at":1}|} committed_text, "Unexpected_shape"
    ; ( "members in another order"
      , Printf.sprintf {|{"record_hash":"%s","kind":"committed"}|} b64
      , "Unexpected_shape" )
    ; ( "an intent without its change"
      , replace ~sub:{|,"change":|} ~by:{|,"modification":|} bootstrap_text
      , "Unexpected_shape" )
    ; "a short hash", {|{"kind":"committed","record_hash":"abc"}|}, "Invalid_hash"
    ; ( "a hash in upper case"
      , Printf.sprintf {|{"kind":"committed","record_hash":"%s"}|} (String.make 64 'B')
      , "Invalid_hash" )
    ; "a short hash in an intent", replace ~sub:a64 ~by:"abc" bootstrap_text, "Invalid_hash"
    ; "an unknown event", replace ~sub:"revoke" ~by:"erase" intent_text, "Invalid_change"
    ; "a subject of another shape", replace ~sub:{|"type":"grant"|} ~by:{|"type":"team"|} intent_text, "Invalid_change"
    ; ( "an authorization event on a mode change"
      , replace ~sub:{|"type":"authz","event":"revoke","subject":{"type":"grant","id":"grant-1"}|} ~by:{|"type":"mode","event":"revoke","workspace_id":"workspace-1"|} intent_text
      , "Invalid_change" )
    ; ( "a mode event with a subject"
      , replace ~sub:{|"type":"authz","event":"revoke","subject":{"type":"grant","id":"grant-1"}|} ~by:{|"type":"authz","event":"off","subject":{"type":"grant","id":"grant-1"}|} intent_text
      , "Invalid_change" )
    ; ( "a rule is read before the form of the text"
      , replace ~sub:{|"kind":"|} ~by:{|"kind": "|} intent_text
      , "Breaks_a_rule Intent_before_bootstrap" )
    ; "a space after a colon", replace ~sub:{|"kind":"|} ~by:{|"kind": "|} bootstrap_text, "Non_canonical"
    ]
;;

(* ---- the texts of the errors ---- *)

let texts_name_the_file_the_line_and_the_rule () =
  let path = "/base/store/external.jsonl" in
  let open_text =
    S.open_error_to_string
      Fun.id
      (S.Line_rejected
         { path; line_number = 3; error = S.Breaks_a_rule S.Intent_while_pending })
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool) ("the text of a rejected line holds " ^ needle) true (contains ~sub:needle open_text))
    [ path; "3"; S.violation_to_string S.Intent_while_pending ];
  let append_text =
    S.append_error_to_string (S.Rejected { index = 2; reject = S.Committed_other_digest })
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool) ("the text of a rejected append holds " ^ needle) true (contains ~sub:needle append_text))
    [ "2"; S.violation_to_string S.Committed_other_digest ];
  let violations =
    [ S.Intent_while_pending
    ; S.Committed_without_intent
    ; S.Committed_other_digest
    ; S.Aborted_without_intent
    ; S.Aborted_other_intent
    ; S.Intent_before_bootstrap
    ; S.Bootstrap_already_committed
    ; S.Workspace_mismatch
    ]
  in
  Alcotest.(check int)
    "each rule has its own text"
    (List.length violations)
    (List.length (List.sort_uniq String.compare (List.map S.violation_to_string violations)))
;;

let () =
  Alcotest.run
    "authz_external_store"
    [ ( "bytes of a line"
      , [ Alcotest.test_case "pinned lines" `Quick lines_are_pinned
        ; Alcotest.test_case "event words" `Quick event_words_are_pinned
        ; Alcotest.test_case "every change reads back" `Quick every_change_reads_back
        ; Alcotest.test_case "answers read back" `Quick answers_read_back_after_their_intent
        ; Alcotest.test_case
            "every change is appended and replayed"
            `Quick
            every_change_is_appended_and_replayed
        ] )
    ; ( "change"
      , [ Alcotest.test_case "reductions" `Quick reductions
        ; Alcotest.test_case "equality" `Quick changes_are_equal_field_for_field
        ] )
    ; ( "rules"
      , [ Alcotest.test_case "appending" `Quick rules_when_appending
        ; Alcotest.test_case "a store starts with a bootstrap" `Quick a_store_starts_with_a_bootstrap
        ; Alcotest.test_case "mode events in any order" `Quick mode_events_may_repeat_and_come_in_any_order
        ; Alcotest.test_case "apply refuses as the file does" `Quick apply_refuses_with_the_rule_of_the_file
        ; Alcotest.test_case "apply gives the state of the file" `Quick apply_gives_the_state_of_the_file
        ] )
    ; ( "state"
      , [ Alcotest.test_case "follows the lines" `Quick state_follows_the_lines
        ; Alcotest.test_case "workspace" `Quick workspace_is_set_by_the_committed_bootstrap
        ] )
    ; ( "file"
      , [ Alcotest.test_case
            "first append and reopening"
            `Quick
            first_append_creates_the_file_and_reopening_keeps_the_state
        ; Alcotest.test_case
            "a second writer from a missing file"
            `Quick
            a_second_writer_that_starts_from_a_missing_file_is_refused
        ; Alcotest.test_case "torn last entry" `Quick torn_last_entry_is_cut
        ; Alcotest.test_case "fold refusal" `Quick fold_refusal_names_the_line
        ] )
    ; ( "files that are not a store"
      , [ Alcotest.test_case "broken rules" `Quick files_that_break_the_rules
        ; Alcotest.test_case "lines that are not entries" `Quick lines_that_are_not_entries
        ] )
    ; "texts", [ Alcotest.test_case "file, line and rule" `Quick texts_name_the_file_the_line_and_the_rule ]
    ]
;;
