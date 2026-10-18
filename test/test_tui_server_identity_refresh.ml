module Tui_decode = Masc.Tui_decode

let identity base_path : Tui_decode.server_identity =
  { Tui_decode.sid_version = "0.24.0"
  ; sid_binary_commit = "abc1234"
  ; sid_binary_commit_age_s = Some 10.
  ; sid_base_path = base_path
  ; sid_masc_root = base_path ^ "/.masc"
  ; sid_executable_in_worktree = Some false
  ; sid_state_ready = Some true
  ; sid_uptime = None
  ; sid_sse_clients = None
  ; sid_gc = None
  ; sid_scheduler = None
  }

let test_same_endpoint_restart_replaces_a_with_b () =
  let current = ref None in
  let apply reading =
    current := Masc_tui_types.server_identity_of_refresh reading
  in
  apply (Ok (identity "/a"));
  apply (Ok (identity "/b"));
  match !current with
  | None -> Alcotest.fail "a successful B probe removed the identity"
  | Some reading ->
    Alcotest.(check string) "current base path" "/b"
      reading.Tui_decode.sid_base_path

let test_failed_probe_is_unread_not_stale () =
  Alcotest.(check bool) "failed probe has no current identity" true
    (Option.is_none
       (Masc_tui_types.server_identity_of_refresh (Error "one failed tick")))

let test_workspace_identity_matches_canonical_paths () =
  let dir = Filename.temp_file "tui-workspace-identity-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Unix.mkdir (Filename.concat dir ".masc") 0o755;
  let alias = dir ^ "-alias" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove alias with Sys_error _ -> ());
      Unix.rmdir (Filename.concat dir ".masc");
      Unix.rmdir dir)
    (fun () ->
       Unix.symlink dir alias;
       Alcotest.(check bool) "same canonical base and runtime root retain request authority" true
         (Masc_tui_types.server_workspace_matches ~expected:(Some (identity alias))
            (Ok (identity dir)));
       match
         Masc_tui_types.workspace_identity_of_refresh
           ~local_base_path:alias
           (Ok (identity dir))
       with
       | Masc_tui_types.Workspace_identity_match -> ()
       | _ -> Alcotest.fail "canonical aliases did not match")

let test_workspace_identity_mismatch_keeps_both_paths () =
  match
    Masc_tui_types.workspace_identity_of_refresh
      ~local_base_path:"/workspace/local"
      (Ok (identity "/workspace/server"))
  with
  | Masc_tui_types.Workspace_identity_mismatch
      { local_base_path; server_base_path } ->
    Alcotest.(check string) "local path" "/workspace/local" local_base_path;
    Alcotest.(check string) "server path" "/workspace/server" server_base_path
  | _ -> Alcotest.fail "different workspaces were not blocked"

(* The server reports [<base>/.masc] as its root and the TUI composes its
   own the same way. The same base matches; a server reporting another root
   under the same base is another store. *)
let test_workspace_identity_compares_the_masc_root () =
  let base = "/workspace/local" in
  let classify masc_root =
    Masc_tui_types.workspace_identity_of_refresh ~local_base_path:base
      (Ok { (identity base) with Tui_decode.sid_masc_root = masc_root })
  in
  let is_match = function
    | Masc_tui_types.Workspace_identity_match -> true
    | Masc_tui_types.Workspace_identity_match_unconfirmed _
    | Masc_tui_types.Workspace_identity_mismatch _
    | Masc_tui_types.Workspace_identity_unread -> false
  in
  Alcotest.(check bool) "the base's .masc is this workspace" true
    (is_match (classify (Filename.concat base ".masc")));
  Alcotest.(check bool) "another root under the same base is another store" false
    (is_match (classify (Filename.concat base "elsewhere/.masc")))

let test_broadcast_retry_scope_follows_verified_workspace () =
  let scope reading = Masc_tui_types.broadcast_workspace_scope
    ~local_base_path:"/workspace/local" reading in
  let original = identity "/workspace/local" in
  let restarted = { original with Tui_decode.sid_binary_commit = "after-restart";
    sid_uptime = Some "new process" } in
  Alcotest.(check (option string)) "port-independent workspace retry scope"
    (scope (Some original)) (scope (Some restarted));
  Alcotest.(check bool) "another MASC store has another scope" true
    (scope (Some original) <> scope (Some { restarted with sid_masc_root = "/workspace/other/.masc" }));
  Alcotest.(check (option string)) "foreign workspace refuses admission" None
    (scope (Some (identity "/workspace/foreign")));
  Alcotest.(check (option string)) "unread server refuses admission" None (scope None);
  Alcotest.(check (option string)) "booting server refuses admission" None
    (scope (Some { original with sid_state_ready = Some false }))

let test_detail_intents_wait_for_comparable_identity () =
  let state = Masc_tui_types.create_state ~workspace:"a"
    ~local_base_path:"/workspace/a" ~port:0 ~refresh_interval:0. () in
  let origin = identity "/workspace/a" in
  state.detail_focus_recovery <- Some (origin, "same-keeper", Masc_tui_types.Detail_instructions);
  state.connector_unbind_offer_pending <- ["same-keeper"];
  state.connector_unbind_offer_origin <- Some origin;
  state.keeper_sandbox_logs_requested <- Some "same-keeper";
  state.keeper_sandbox_logs_origin <- Some origin;
  let apply = Masc_tui_types.reconcile_detail_intent_origins state in
  let retained label =
    Alcotest.(check bool) (label ^ " source-bound detail focus") true
      (state.detail_focus_recovery = Some (origin, "same-keeper", Masc_tui_types.Detail_instructions));
    Alcotest.(check (list string)) (label ^ " connector intent")
      ["same-keeper"] state.connector_unbind_offer_pending;
    Alcotest.(check (option string)) (label ^ " Sandbox intent")
      (Some "same-keeper") state.keeper_sandbox_logs_requested;
    Alcotest.(check bool) (label ^ " origins remain bound") true
      (state.connector_unbind_offer_origin = Some origin
       && state.keeper_sandbox_logs_origin = Some origin)
  in
  apply (Error "health unavailable"); retained "failed probe";
  apply (Ok { origin with sid_base_path = "" }); retained "missing base";
  apply (Ok { origin with sid_masc_root = "" }); retained "missing root";
  apply (Ok { origin with sid_base_path = ""; sid_masc_root = "";
    sid_state_ready = Some false }); retained "booting unread";
  apply (Ok origin); retained "same workspace recovery";
  (* Same Keeper name and base, different runtime store: no inherited log
     request or post-action offer may become an action in that new store. *)
  apply (Ok { origin with sid_masc_root = "/workspace/a/another-masc-root" });
  Alcotest.(check bool) "foreign root retires detail focus" true
    (state.detail_focus_recovery = None);
  Alcotest.(check (list string)) "foreign root clears connector intent"
    [] state.connector_unbind_offer_pending;
  Alcotest.(check (option string)) "foreign root clears Sandbox intent"
    None state.keeper_sandbox_logs_requested;
  Alcotest.(check bool) "foreign root retires both origins" true
    (state.connector_unbind_offer_origin = None && state.keeper_sandbox_logs_origin = None);
  apply (Ok origin);
  Alcotest.(check bool) "return to A does not recreate detail focus" true
    (state.detail_focus_recovery = None);
  Alcotest.(check (option string)) "return to A does not recreate Sandbox intent"
    None state.keeper_sandbox_logs_requested

let test_same_base_with_different_masc_root_cannot_restore_inputs () =
  let a = identity "/workspace/shared" in
  let b = { a with sid_masc_root = "/workspace/other-store/.masc" } in
  (match Masc_tui_types.workspace_identity_of_refresh
      ~local_base_path:"/workspace/shared" (Ok b) with
   | Masc_tui_types.Workspace_identity_mismatch _ -> ()
   | _ -> Alcotest.fail "a different MASC root authorized local metadata");
  let key identity = Masc_tui_types.workspace_input_identity_of_server (Some identity) in
  let retained = [key a, "A's queued input and draft"] in
  Alcotest.(check (option string)) "B cannot restore A's retained input" None
    (List.assoc_opt (key b) retained);
  Alcotest.(check (option string)) "returning to A retains explicit resume"
    (Some "A's queued input and draft") (List.assoc_opt (key a) retained)

(* The keeper, task and log lists start empty and are read only once the server
   vouches for this workspace, so before that an empty list is not an empty
   workspace (#35747). *)
let test_local_rows_are_unread_until_the_workspace_is_read () =
  let state =
    Masc_tui_types.create_state ~workspace:"local"
      ~local_base_path:"/workspace/local" ~port:0 ~refresh_interval:0. ()
  in
  let page error =
    match Masc_tui_types.local_rows_page state ~error with
    | Masc_tui_types.Page_unread -> "unread"
    | Masc_tui_types.Page_failed -> "failed"
    | Masc_tui_types.Page_empty -> "empty"
  in
  Alcotest.(check string) "a fresh state has read nothing" "unread" (page None);
  state.Masc_tui_types.local_workspace <- Masc_tui_types.Local_workspace_read;
  Alcotest.(check string) "a read with no rows is empty" "empty" (page None);
  Alcotest.(check string) "a read with an error failed" "failed"
    (page (Some "keeper metadata unavailable"))

let test_request_authority_requires_complete_current_identity () =
  let before = identity "/a" in
  let accepts after =
    Masc_tui_types.server_workspace_matches ~expected:(Some before) after
  in
  Alcotest.(check bool) "same workspace" true (accepts (Ok before));
  Alcotest.(check bool) "dynamic health does not revoke" true
    (accepts (Ok { before with sid_uptime = Some "30s" }));
  Alcotest.(check bool) "different base" false (accepts (Ok (identity "/b")));
  Alcotest.(check bool) "different runtime root" false
    (accepts (Ok { before with sid_masc_root = "/a/other-root" }));
  Alcotest.(check bool) "booting successor" false
    (accepts (Ok { before with sid_state_ready = Some false }));
  Alcotest.(check bool) "unavailable successor" false (accepts (Error "unavailable"));
  Alcotest.(check bool) "no prior identity" false
    (Masc_tui_types.server_workspace_matches ~expected:None (Ok before));
  Alcotest.(check bool) "missing root cannot authorize" false
    (let incomplete = { before with sid_masc_root = "" } in
     Masc_tui_types.server_workspace_matches ~expected:(Some incomplete) (Ok incomplete))

let test_detail_focus_waits_for_authoritative_roster () =
  let open Masc_tui_types in
  let origin = identity "/workspace/a" in
  let keeper name : keeper = { k_origin = Tui_decode.Persisted_keeper; k_name = name;
    k_paused = false; k_identity = Error "not needed for navigation"; k_activity = None } in
  let suspended () =
    let state = create_state ~workspace:"local" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
    state.workspace_identity <- Workspace_identity_match;
    state.server_identity <- Some origin;
    state.local_workspace <- Local_workspace_read;
    state.local_keepers <- Local_workspace_read;
    state.keepers <- [keeper "other"; keeper "focused"];
    state.keeper_cursor <- 1;
    state.view <- Keepers Keeper_detail;
    state.detail_tab <- Detail_instructions;
    remember_keeper_detail_focus state;
    state.keepers <- [];
    state.keeper_cursor <- 0;
    state.server_identity <- None;
    state.workspace_identity <- Workspace_identity_unread;
    state.local_workspace <- Local_workspace_unread;
    state.local_keepers <- Local_workspace_unread;
    state
  in
  let ready state keepers =
    state.server_identity <- Some origin;
    state.workspace_identity <- Workspace_identity_match;
    state.local_workspace <- Local_workspace_read;
    state.local_keepers <- Local_workspace_read;
    state.keepers <- keepers;
    (* Model the loader's list fallback after untrusted rows were cleared. *)
    state.view <- Keepers Keeper_list
  in
  let state = suspended () in
  reconcile_detail_intent_origins state (Ok {origin with sid_masc_root=""});
  Alcotest.(check bool) "incomplete identity cannot restore" false (restore_keeper_detail_focus state);
  Alcotest.(check int) "navigation retains no untrusted rows" 0 (List.length state.keepers);
  ready state [keeper "focused";keeper "other"];
  state.keepers_error <- Some "roster unavailable";
  Alcotest.(check bool) "failed roster cannot restore" false (restore_keeper_detail_focus state);
  state.keepers_error <- None;
  Alcotest.(check bool) "matching complete roster restores focus" true (restore_keeper_detail_focus state);
  Alcotest.(check bool) "name and tab survive reorder" true
    (state.view=Keepers Keeper_detail && state.keeper_cursor=0 && state.detail_tab=Detail_instructions);
  Alcotest.(check bool) "restoration is consumed once" false (restore_keeper_detail_focus state);
  let left = suspended () in
  ready left [keeper "focused"];
  left.view <- Overview;
  Alcotest.(check bool) "leaving fallback list prevents recovery navigation" false
    (restore_keeper_detail_focus left);
  Alcotest.(check bool) "explicit exit retires focus" true (left.detail_focus_recovery=None);
  let missing = suspended () in
  ready missing [keeper "other"];
  Alcotest.(check bool) "missing name cannot reopen another Keeper" false (restore_keeper_detail_focus missing);
  Alcotest.(check bool) "trusted absence retires intent" true (missing.detail_focus_recovery=None);
  let foreign = suspended () in
  reconcile_detail_intent_origins foreign (Ok {origin with sid_masc_root="/workspace/a/foreign"});
  ready foreign [keeper "focused"];
  Alcotest.(check bool) "foreign store retires intent even after returning" false (restore_keeper_detail_focus foreign)

(* A read that cannot name the server's workspace does not say it serves
   another one. After a match it keeps that match, unconfirmed; only a read
   that names a different workspace changes it. *)
let test_unread_after_a_match_keeps_it_unconfirmed () =
  let local = "/workspace/local" in
  let next previous reading =
    Masc_tui_types.next_workspace_identity ~previous ~local_base_path:local reading
  in
  let label = function
    | Masc_tui_types.Workspace_identity_unread -> "unread"
    | Workspace_identity_match -> "match"
    | Workspace_identity_match_unconfirmed reason -> "unconfirmed: " ^ reason
    | Workspace_identity_mismatch { server_base_path; _ } ->
      "mismatch: " ^ server_base_path
  in
  let check name expected previous reading =
    Alcotest.(check string) name expected (label (next previous reading))
  in
  let booting = { (identity local) with sid_state_ready = Some false } in
  check "a failed read after a match keeps it" "unconfirmed: one failed tick"
    Workspace_identity_match (Error "one failed tick");
  check "a booting server after a match keeps it" "unconfirmed: the server is starting"
    Workspace_identity_match (Ok booting);
  check "another failed read stays unconfirmed" "unconfirmed: still down"
    (Workspace_identity_match_unconfirmed "one failed tick") (Error "still down");
  check "the same workspace confirms it again" "match"
    (Workspace_identity_match_unconfirmed "one failed tick") (Ok (identity local));
  check "a different workspace is still a mismatch" "mismatch: /workspace/other"
    (Workspace_identity_match_unconfirmed "one failed tick")
    (Ok (identity "/workspace/other"));
  check "a failed read with no match before is unread" "unread"
    Workspace_identity_unread (Error "boot");
  check "a failed read after a mismatch is unread" "unread"
    (Workspace_identity_mismatch
       { local_base_path = local; server_base_path = "/workspace/other" })
    (Error "one failed tick");
  (* A booting server's paths name its workspace even though it cannot
     serve yet: another workspace withdraws the match. *)
  check "a booting server of another workspace withdraws the match" "unread"
    Workspace_identity_match
    (Ok { (identity "/workspace/other") with sid_state_ready = Some false })

(* A write goes out only while the authority it was launched under is current
   and the server identity is confirmed. *)
let test_writes_wait_for_a_confirmed_identity () =
  let state = Masc_tui_types.create_state ~workspace:"a"
    ~local_base_path:"/workspace/a" ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Masc_tui_types.Workspace_identity_match;
  let authority = state.workspace_authority in
  let refusal () = Masc_tui_types.write_authority_refusal state authority in
  Alcotest.(check (option string)) "a confirmed match sends" None (refusal ());
  state.workspace_identity <-
    Masc_tui_types.Workspace_identity_match_unconfirmed "one failed tick";
  Alcotest.(check (option string)) "an unconfirmed match waits"
    (Some "Workspace identity is unconfirmed") (refusal ());
  state.workspace_identity <- Masc_tui_types.Workspace_identity_match;
  let (Masc_tui_types.Workspace_authority generation) = state.workspace_authority in
  state.workspace_authority <- Masc_tui_types.Workspace_authority (generation + 1);
  Alcotest.(check (option string)) "a moved authority refuses"
    (Some "Workspace authority withdrawn") (refusal ())

let test_partial_identity_keeps_definite_mismatches () =
  let local = "/workspace/a" in
  let original = identity local in
  let different_partial_paths =
    [ { original with sid_base_path = "/workspace/b"; sid_masc_root = "" }
    ; { original with sid_base_path = ""; sid_masc_root = "/workspace/b/.masc" } ] in
  List.iter (fun observed ->
    List.iter (fun previous ->
      match Masc_tui_types.next_workspace_identity ~previous ~local_base_path:local (Ok observed) with
      | Masc_tui_types.Workspace_identity_mismatch _ -> ()
      | Workspace_identity_unread | Workspace_identity_match
      | Workspace_identity_match_unconfirmed _ ->
        Alcotest.fail "one missing path hid the other path's definite mismatch")
      [ Masc_tui_types.Workspace_identity_match
      ; Workspace_identity_match_unconfirmed "health failed" ])
    different_partial_paths;
  List.iter (fun observed ->
    match Masc_tui_types.next_workspace_identity
        ~previous:Workspace_identity_match ~local_base_path:local
        (Ok { observed with sid_state_ready = Some false }) with
    | Masc_tui_types.Workspace_identity_unread -> ()
    | Workspace_identity_match | Workspace_identity_mismatch _
    | Workspace_identity_match_unconfirmed _ ->
      Alcotest.fail "a booting replacement must withdraw the retained match")
    different_partial_paths;
  List.iter (fun observed ->
    match Masc_tui_types.next_workspace_identity
        ~previous:Workspace_identity_match ~local_base_path:local (Ok observed) with
    | Masc_tui_types.Workspace_identity_match_unconfirmed _ -> ()
    | Workspace_identity_unread | Workspace_identity_match | Workspace_identity_mismatch _ ->
      Alcotest.fail "a missing path without contradictory evidence must stay unconfirmed")
    [ { original with sid_base_path = "" }; { original with sid_masc_root = "" } ]

let test_deletion_inventory_waits_for_reconfirmed_workspace () =
  let open Masc_tui_types in
  let module Deletions = Masc_tui_keeper_control in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match;
  let record keeper_name : Deletions.deletion_row =
    { operation = Deletions.Configuration_removal
        { Masc.Keeper_configuration_removal.operation_id = Masc.Keeper_shutdown_types.Operation_id.generate ()
        ; keeper_name; actor = "test"; source_sha256 = ""; source_path = ""
        ; requested_at = ""; updated_at = ""
        ; state = Masc.Keeper_configuration_removal.Cleanup_required "pending cleanup"
        ; last_error = None }
    ; completed = false; can_retry = true }
  in
  let first = record "workspace-a-first" in
  let selected = record "workspace-a-selected" in
  let a : Deletions.deletion_inventory = { operations = [ first; selected ]; errors = [] } in
  let b : Deletions.deletion_inventory = { operations = [ record "workspace-b" ]; errors = [] } in
  let begin_read () = match begin_keeper_deletions_read state with
    | Some generation -> generation
    | None -> Alcotest.fail "confirmed workspace should admit inventory read" in
  apply_keeper_deletions_read state ~generation:(begin_read ()) (Ok a);
  state.keeper_deletions_cursor <- 1;
  let before_failure = begin_read () in
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
      ~local_base_path:state.local_base_path (Error "health unavailable");
  (* The identity transition retires only the request, not its cached rows. *)
  suspend_keeper_deletions_read state;
  let check_preserved label =
    Alcotest.(check bool) (label ^ ": A inventory remains visible") true
      (state.keeper_deletions = Some (Ok a));
    Alcotest.(check int) (label ^ ": selected row stays selected") 1 state.keeper_deletions_cursor in
  apply_keeper_deletions_read state ~generation:before_failure (Ok b);
  check_preserved "B responds during uncertainty";
  Alcotest.(check (option int)) "D/r does not launch an unconfirmed read" None
    (begin_keeper_deletions_read state);
  (* Completion checks identity itself as well as generation. *)
  apply_keeper_deletions_read state ~generation:state.keeper_deletions_generation (Ok b);
  check_preserved "matching generation cannot replace unconfirmed rows";
  apply_keeper_deletions_read state ~generation:state.keeper_deletions_generation (Error "HTTP 503");
  check_preserved "failed unconfirmed read";
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
      ~local_base_path:state.local_base_path (Ok (identity "/workspace/a"));
  apply_keeper_deletions_read state ~generation:before_failure (Ok b);
  check_preserved "late response remains stale after A reconfirms";
  let refreshed = { a with operations = [ selected; first ] } in
  apply_keeper_deletions_read state ~generation:(begin_read ()) (Ok refreshed);
  Alcotest.(check bool) "a new confirmed read replaces the inventory" true
    (state.keeper_deletions = Some (Ok refreshed));
  Alcotest.(check int) "selection follows its operation after reorder" 0 state.keeper_deletions_cursor

(* An Info refresh queued behind an in-flight Keeper lanes read belongs to
   that read's authority. Suspension retires the read; the replacement read
   launched after reconfirmation leaves later than the queued request, so it
   satisfies it. A flag left behind would start a second, redundant read
   when the replacement answers, and that read's failure would overwrite the
   recovered reading with a stale error. *)
let test_suspension_folds_queued_lanes_reread_into_resume () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.keeper_lanes_inflight <- true;
  state.keeper_lanes_reread_pending <- true;
  suspend_workspace_readings state;
  Alcotest.(check bool) "in-flight read released" false state.keeper_lanes_inflight;
  Alcotest.(check bool) "queued reread retired with its authority" false
    state.keeper_lanes_reread_pending;
  Alcotest.(check bool) "replacement read still requested" true state.keeper_lanes_resume;
  (* A queued reread whose read was already released (not run) still asks
     for a replacement after reconfirmation. *)
  state.keeper_lanes_resume <- false;
  state.keeper_lanes_reread_pending <- true;
  suspend_workspace_readings state;
  Alcotest.(check bool) "queued reread retired without an in-flight read" false
    state.keeper_lanes_reread_pending;
  Alcotest.(check bool) "its demand carried into resume" true state.keeper_lanes_resume

let test_uncertain_identity_retires_reads_not_admitted_operations () =
  let open Masc_tui_types in
  let module Detail = Masc_tui_board_detail in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match;
  let post body : board_post =
    { bp_id = "same-id"; bp_author = "author"; bp_title = "Thread";
      bp_body = body; bp_votes = 0; bp_comment_count = 0;
      bp_created_at = "2026-10-07"; bp_created_at_unix = None; bp_updated_at = None;
      bp_hearth = None; bp_kind = None; bp_closed = None; bp_attachments = [] } in
  let a = post "A's retained post" and b = post "B's delayed post" in
  let begin_read () = match Detail.start state.board_detail ~post_id:a.bp_id with
    | Detail.Started (next, request) -> state.board_detail <- next; request
    | Detail.Already_loading -> Alcotest.fail "retired Board read still owns its slot" in
  let initial = begin_read () in
  state.board_detail <- Detail.complete state.board_detail initial (Ok (a, [], None));
  let delayed = begin_read () in
  let authority = state.workspace_authority in
  let reading = Some state.workspace_read_authority in
  let admitted kind = workspace_reply_admitted state ~authority ~reading ~kind in
  let cancelled_write = ref false and cancelled_observation = ref false in
  state.workspace_cancellations <- [ref (), (fun () -> cancelled_write := true)];
  state.workspace_observation_cancellations <- [ref (), (fun () -> cancelled_observation := true)];
  Masc_tui_message_input.insert state.msg_input "unsent draft";
  state.keeper_yolo_names <- ["A-keeper"];
  state.keeper_turns_inflight <- true;
  let browser = Browser_lane_view.create () in
  state.browser_lane <- Some {browser with load=Browser_lane_view.Loading (1, Read)};
  state.keeper_queue_inflight <- ["reading"; "writing"];
  state.keeper_queue_readings <- ["reading"];
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
      ~local_base_path:state.local_base_path (Error "health failed");
  suspend_workspace_readings state;
  Alcotest.(check bool) "old Board/mode read is inadmissible during uncertainty" false
    (admitted Workspace_observation);
  Alcotest.(check bool) "admitted write and chat receipt keep their authority" true
    (admitted Workspace_operation_outcome);
  Alcotest.(check bool) "observation stream is cancelled" true !cancelled_observation;
  Alcotest.(check bool) "admitted operation is not cancelled" false !cancelled_write;
  Alcotest.(check bool) "read-only in-flight slot is released" false state.keeper_turns_inflight;
  Alcotest.(check string) "draft is preserved" "unsent draft"
    (Masc_tui_message_input.contents state.msg_input);
  Alcotest.(check (list string)) "retained mode rows are preserved" ["A-keeper"] state.keeper_yolo_names;

  Alcotest.(check (list string)) "queue observation releases only its own slot" ["writing"]
    state.keeper_queue_inflight;
  (match state.browser_lane with
   | Some {load=Browser_lane_view.Idle; _} -> ()
   | _ -> Alcotest.fail "browser read stayed pending");
  state.browser_lane <- Some {browser with load=Browser_lane_view.Loading (2, Goto "https://example.test")};
  suspend_workspace_readings state;
  (match state.browser_lane with
   | Some {load=Browser_lane_view.Loading (2, Goto _); _} -> ()
   | _ -> Alcotest.fail "admitted browser navigation lost its receipt owner");
  state.board_detail <- Detail.complete state.board_detail delayed (Ok (b, [], None));
  (match Detail.view_for state.board_detail ~post_id:a.bp_id with
   | Detail.Ready (shown, _, _) -> Alcotest.(check string) "A stays on screen" a.bp_body shown.bp_body
   | Detail.Absent | Detail.Loading | Detail.Failed _ -> Alcotest.fail "retirement erased A's detail");
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
      ~local_base_path:state.local_base_path (Ok (identity "/workspace/a"));
  Alcotest.(check bool) "reconfirming A cannot revive B's old read stamp" false
    (admitted Workspace_observation);
  Alcotest.(check bool) "a read dispatched during uncertainty cannot enter on reconfirmation" false
    (workspace_reply_admitted state ~authority ~reading:None ~kind:Workspace_observation);
  let refreshed = begin_read () in
  Alcotest.(check bool) "reconfirmed reads get a fresh Board request" false
    (Detail.same_request delayed refreshed);
  Alcotest.(check bool) "new confirmed read is admitted" true
    (workspace_reply_admitted state ~authority ~reading:(Some state.workspace_read_authority)
      ~kind:Workspace_observation);
  state.board_detail <- Detail.complete state.board_detail refreshed (Ok (a, [], None))

let test_operation_receipt_outlives_queued_followup_read () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match;
  let authority = state.workspace_authority in
  let reading = Some state.workspace_read_authority in
  (* The POST has completed; its later GET has produced B's snapshot and
     the combined result is already queued, before health failure applies. *)
  let queued = ("saved-A-revision", Ok "B's follow-up snapshot") in
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
      ~local_base_path:state.local_base_path (Error "health failed");
  suspend_workspace_readings state;
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
      ~local_base_path:state.local_base_path (Ok (identity "/workspace/a"));
  let receipt, observation = workspace_operation_reply state ~authority ~reading queued in
  Alcotest.(check string) "POST revision receipt survives reconfirmation" "saved-A-revision" receipt;
  Alcotest.(check bool) "queued GET snapshot stays retired after A returns" true (Result.is_error observation);
  let fresh_receipt, fresh_observation = workspace_operation_reply state ~authority
      ~reading:(Some state.workspace_read_authority) ("next-receipt", Ok "A's current snapshot") in
  Alcotest.(check string) "fresh receipt retained" "next-receipt" fresh_receipt;
  Alcotest.(check (result string string)) "new epoch can observe A" (Ok "A's current snapshot") fresh_observation;
  let module Login = Masc_tui_account_login in
  let view = Login.create "test" in
  view.phase <- Login.Finished {saved=Login.Saved_verified;
    activation=Login.Active {exact_output_available=true}; refresh_failed=false};
  suspend_account_login_read view;
  (match view.phase with
   | Login.Finished {saved=Login.Saved_verified; activation=Login.Active _; refresh_failed=true} -> ()
   | _ -> Alcotest.fail "retired account inventory lost the save/activation receipt")

let test_unknown_voice_save_read_retirement () =
  let open Masc_tui_types in
  let module Wizard = Masc_tui_voice_wizard_session in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  let opened = Wizard.voice_wizard_open ~section:Voice_setup.Tts
      ~provider:Voice_wizard.Elevenlabs ~revision:"before-save" in
  let sending = Wizard.voice_wizard_sending opened ~request:7 in
  state.voice_wizard <- Some sending;
  suspend_workspace_readings state;
  (match state.voice_wizard with
   | Some {vws_save=Wizard.Save_sending 7; _} -> ()
   | _ -> Alcotest.fail "admitted voice save lost its receipt owner");
  let unanswered = match Wizard.voice_wizard_after_save sending ~request:7
      (Wizard.Save_unanswered_reply "connection lost") with
    | Some session -> session | None -> Alcotest.fail "save receipt lost" in
  let check_retired () = match state.voice_wizard with
    | Some {vws_save=Wizard.Save_needs_reopen _; vws_revision; vws_draft; _} ->
        Alcotest.(check string) "original revision retained" "before-save" vws_revision;
        Alcotest.(check bool) "voice draft retained" true (vws_draft = opened.vws_draft)
    | _ -> Alcotest.fail "unanswered save still waits for a retired reread" in
  state.voice_wizard <- Some unanswered;
  suspend_workspace_readings state;
  check_retired ();
  (* The receipt can first arrive after retirement; refused read admission
     must settle only its observation owner, leaving the save unknown. *)
  state.voice_wizard <- Some unanswered;
  suspend_voice_wizard_read state;
  check_retired ()

let test_nested_read_owners_retire_without_losing_selection () =
  let open Masc_tui_types in
  let module Wizard = Masc_tui_voice_wizard_session in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  let opened = Wizard.voice_wizard_open ~section:Voice_setup.Tts
      ~provider:Voice_wizard.Elevenlabs ~revision:"saved" in
  state.voice_wizard <- Some {opened with vws_save=Wizard.Save_probing 7};
  state.runtime_catalog_reading <- Runtime_catalog_loading;
  let generation = state.runtime_catalog_generation in
  state.context_inspector_open <- true;
  state.context_inspector_keeper <- Some "alpha";
  state.context_inspector_loading <- true;
  state.schedule_detail_id <- Some "schedule-a";
  state.schedule_wake_history_inflight <- Some "schedule-a";
  state.patch_modal_open <- true;
  state.patch_modal_path <- Some "lib/example.ml";
  state.resource_pending_uri <- Some "masc://selected/resource";
  state.prompts_librarian_input_requested <- Some "librarian-input";
  state.prompts_librarian_input_loading <- true;
  suspend_workspace_readings state;
  Alcotest.(check (option string)) "resource URI survives retirement" (Some "masc://selected/resource") state.resource_pending_uri;
  Alcotest.(check (option string)) "Librarian target survives retirement" (Some "librarian-input") state.prompts_librarian_input_requested;
  Alcotest.(check bool) "catalog owner can be restarted" true
    (state.runtime_catalog_reading = Runtime_catalog_unread);
  Alcotest.(check bool) "catalog generation retired" true
    (state.runtime_catalog_generation > generation);
  Alcotest.(check bool) "context owner released" false state.context_inspector_loading;
  Alcotest.(check (option string)) "context selection retained" (Some "alpha") state.context_inspector_keeper;
  Alcotest.(check (option string)) "schedule owner released" None state.schedule_wake_history_inflight;
  Alcotest.(check (option string)) "schedule selection retained" (Some "schedule-a") state.schedule_detail_id;
  Alcotest.(check (option string)) "patch selection retained" (Some "lib/example.ml") state.patch_modal_path;
  (match state.voice_wizard with
   | Some ({vws_save=Wizard.Save_settled; _} as session) ->
       Alcotest.(check bool) "retired probe cannot populate the wizard" true
         (Option.is_none (Wizard.voice_wizard_after_probe session ~request:7 (Ok ["foreign endpoint"])));
       Alcotest.(check bool) "saved draft is preserved" true (session.vws_draft = opened.vws_draft)
   | _ -> Alcotest.fail "probe still owns the saved wizard")

let test_discarded_bundle_retires_readings_before_reconfirming_a () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match;
  let authority = state.workspace_authority in
  let reading = Some state.workspace_read_authority in
  Masc_tui_message_input.insert state.msg_input "retained draft";
  (* The refresh crossed B, but its final probe already sees A again. *)
  let latest = retire_refused_workspace_readings state ~detail:"mixed workspace bundle"
      (Some (Ok (identity "/workspace/a"))) in
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
      ~local_base_path:state.local_base_path latest;
  Alcotest.(check bool) "A is confirmed again" true (server_authority_ready state);
  Alcotest.(check bool) "independent B response cannot enter the reconfirmed A screen" false
    (workspace_reply_admitted state ~authority ~reading ~kind:Workspace_observation);
  Alcotest.(check bool) "A's admitted operation receipt is retained" true
    (workspace_reply_admitted state ~authority ~reading ~kind:Workspace_operation_outcome);
  Alcotest.(check string) "draft survives discarded bundle" "retained draft"
    (Masc_tui_message_input.contents state.msg_input)

let test_preset_selection_waits_without_owning_an_unconfirmed_read () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- next_workspace_identity ~previous:Workspace_identity_match
      ~local_base_path:state.local_base_path (Error "health unavailable");
  Alcotest.(check bool) "unconfirmed selection does not start a read" true
    (Option.is_none (begin_preset_detail_read state ~name:"selected-preset"));
  Alcotest.(check bool) "no stuck Loading owner is created" true
    (Option.is_none (Masc_tui_fetched.current_request state.preset_detail));
  state.workspace_identity <- Workspace_identity_match;
  Alcotest.(check bool) "same preset can load once A is confirmed" true
    (Option.is_some (begin_preset_detail_read state ~name:"selected-preset"));
  Alcotest.(check bool) "an admitted read is still deduplicated" true
    (Option.is_none (begin_preset_detail_read state ~name:"selected-preset"))

let test_pending_nested_reader_intents_survive_repeated_suspension () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.msg_target_keeper_name <- Some "alpha";
  state.msg_older_cursor <- Some "server-cursor-42";
  state.msg_older_loading <- true;
  let loading, _ = match Masc_tui_fetched.start ~equal:String.equal state.code_file ~key:"src/a.ml" with
    | Started (reading, request) -> reading, request
    | Already_loading -> Alcotest.fail "unexpected initial file owner" in
  state.code_file <- loading;
  let installer = Masc_tui_lane_installer.browse () in
  let installer = Result.get_ok (Masc_tui_lane_installer.begin_catalog ~request_id:7 ~directory:(Some "packages") installer) in
  state.lane_addons <- Some {state.lane_addons_cached with generation=7; loading=true; installer=Some installer};
  state.lane_addons_reading <- Some 7;
  suspend_workspace_readings state;
  suspend_workspace_readings state;
  Alcotest.(check (option (pair string (option string)))) "older page cursor survives" (Some ("alpha",Some "server-cursor-42")) state.msg_older_resume;
  Alcotest.(check (option string)) "pending file key survives" (Some "src/a.ml") (Masc_tui_fetched.current_key state.code_file);
  Alcotest.(check bool) "package catalog parameters survive" true
    (state.lane_installer_read_resume = Some (7, Masc_tui_lane_installer.Read_catalog (Some "packages")))

let test_task_receipts_wait_for_identity_and_roster () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  let origin = identity "/workspace/a" in
  state.server_identity <- Some origin;
  state.workspace_identity <- Workspace_identity_match_unconfirmed "health timed out";
  let handoff = Task_handoff {keeper="alpha"; task_id="task-9"; title="accepted"; body="body"} in
  let cancelled = Task_cancel_refresh "task-8" in
  remember_task_followup state ~expected_workspace:origin handoff;
  remember_task_followup state ~expected_workspace:origin cancelled;
  let run, withdrawn = take_task_followups state ~ready:(fun _ -> true) in
  Alcotest.(check bool) "no sends or foreign-workspace claims while unconfirmed" true
    (run = [] && withdrawn = [] && List.length state.pending_task_followups = 2);
  suspend_workspace_readings state;
  state.workspace_identity <- Workspace_identity_match;
  let run, withdrawn = take_task_followups state ~ready:(function
    | Task_handoff _ -> false | Task_cancel_refresh _ -> true) in
  Alcotest.(check bool) "cancel refresh resumes while handoff waits for roster" true
    (run = [cancelled] && withdrawn = [] && List.length state.pending_task_followups = 1);
  let run, withdrawn = take_task_followups state ~ready:(fun _ -> true) in
  Alcotest.(check bool) "same workspace resumes the original handoff" true
    (run = [handoff] && withdrawn = []);
  Alcotest.(check bool) "later refresh cannot send it twice" true
    (take_task_followups state ~ready:(fun _ -> true) = ([], []));
  remember_task_followup state ~expected_workspace:origin handoff;
  state.server_identity <- Some {origin with sid_masc_root="/workspace/other/.masc";
    sid_state_ready=Some false};
  state.workspace_identity <- Workspace_identity_unread;
  let run, withdrawn = take_task_followups state ~ready:(fun _ -> true) in
  Alcotest.(check bool) "booting foreign root withdraws handoff" true
    (run = [] && withdrawn = [handoff]);
  state.server_identity <- Some origin;
  state.workspace_identity <- Workspace_identity_match;
  Alcotest.(check bool) "return to A never resurrects withdrawn task" true
    (take_task_followups state ~ready:(fun _ -> true) = ([], []));
  remember_task_followup state ~expected_workspace:origin handoff;
  let Workspace_authority generation = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation + 1);
  Alcotest.(check bool) "A-B-A with unchanged final paths still retires original authority" true
    (take_task_followups state ~ready:(fun _ -> true) = ([], [handoff]))

let test_account_read_intents_survive_repeated_suspension () =
  let open Masc_tui_types in
  let module Login = Masc_tui_account_login in
  let provider : Login.provider = {id="codex"; label="Codex"; client=Login.Codex;
    origin=Login.Configured; enabled=true; setup_supported=true} in
  List.iter (fun action ->
    let state = create_state ~workspace:"a" ~port:0 ~refresh_interval:0. () in
    let view = Login.create "codex" in
    view.generation <- 7;
    view.account_ref <- Some "selected-account";
    view.login_id <- Some "selected-session";
    view.provider <- Some provider;
    state.account_login <- Some view;
    state.account_login_readings <- [view, 7, action];
    suspend_workspace_readings state;
    suspend_workspace_readings state;
    Alcotest.(check bool) "exact read survives repeated retirement" true
      (match state.account_login_read_resume with
       | [(pending, generation, saved_action)] ->
           pending == view && generation = 7 && saved_action = action
       | _ -> false);
    Alcotest.(check (option string)) "selected account is preserved"
      (Some "selected-account") view.account_ref;
    Alcotest.(check bool) "selected provider is preserved" true
      (view.provider = Some provider);
    let saving = Login.create "codex" in
    saving.generation <- 8;
    saving.phase <- Login.Saving;
    state.account_login_readings <- [saving, 7, Login.Inventory];
    suspend_workspace_readings state;
    Alcotest.(check bool) "superseded read cannot retire newer mutation" true
      (saving.phase = Login.Saving && saving.generation = 8);
    Alcotest.(check int) "superseded read is not queued" 1
      (List.length state.account_login_read_resume))
    [Login.Inventory; Discover; Recover;
     Preview_removal {provider; refused=Some "retained refusal"}]

let test_unsent_resource_and_log_intents_survive_reconfirmation () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match_unconfirmed "health failed";
  state.resource_content <- Some ("masc://old", []);
  state.resource_scroll <- 12;
  retain_resource_read state ~uri:"masc://new";
  retain_sandbox_log_read state ~keeper_name:"selected-keeper";
  Alcotest.(check bool) "intent does not authorize network reads" false
    (server_authority_ready state);
  Alcotest.(check bool) "new selection cannot display old resource" true
    (state.resource_content = None && state.resource_scroll = 0);
  suspend_workspace_readings state;
  state.workspace_identity <- Workspace_identity_match;
  Alcotest.(check (option string)) "resource recovery selects the unsent URI"
    (Some "masc://new") state.resource_pending_uri;
  Alcotest.(check (option string)) "first log open survives without a previous result"
    (Some "selected-keeper") state.keeper_sandbox_logs_requested;
  Alcotest.(check bool) "unsent logs retain their originating workspace" true
    (state.keeper_sandbox_logs_origin = Some (identity "/workspace/a"));
  reconcile_detail_intent_origins state (Ok (identity "/workspace/b"));
  Alcotest.(check (option string)) "foreign workspace cannot inherit unsent logs"
    None state.keeper_sandbox_logs_requested

let test_effect_observations_resume_without_repeating_effects () =
  let open Masc_tui_types in
  let module Browser = Browser_lane_view in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match_unconfirmed "health failed";
  let initial = Browser.create () in
  let prior = {initial with selected_tab=Some 7} in
  state.browser_lane_generation <- 3;
  state.browser_lane <- Some {prior with load=Browser.Failed "observation retired"};
  let gestures = [Browser.Scene_scroll {tab_id=7; document_id="doc";
      expected_url="https://example.test"; scene_view=Browser_lane.Content; scope=None; delta_y=100};
    Browser.Scene_click {tab_id=7; document_id="doc"; node_id="node";
      expected_url="https://example.test"; scope=None}] in
  List.iter (fun gesture ->
    let read = match Browser.observation_after_effect gesture with
      | Some read -> read | None -> Alcotest.fail "effect lost its observation intent" in
    Alcotest.(check bool) "the retry is a read, never the gesture" true
      (Browser.operation_is_read read);
    Alcotest.(check bool) "settled matching effect retains its observation" true
      (retain_operation_observation state (Browser_scene_observation (3, prior, read)));
    suspend_workspace_readings state;
    Alcotest.(check bool) "repeated uncertainty preserves selected scene read" true
      (match state.browser_lane_read_resume with
       | Some (3, _, Browser.Scene_refresh {tab_id=7; _}) -> true | _ -> false)) gestures;
  state.browser_lane_generation <- 4;
  Alcotest.(check bool) "late receipt cannot replace a newer selection" false
    (retain_operation_observation state (Browser_scene_observation (3, prior, Browser.Scene_read 7)));
  let panel = Masc_tui_lane_subscriptions.initial ~keepers:[] ~targets:[] in
  let saved = {Masc_tui_lane_addons.initial with generation=9; loading=false;
    subscription_panel=Some panel} in
  state.lane_addons <- Some saved;
  Alcotest.(check bool) "settled save retains only subscription inspection" true
    (retain_operation_observation state (Lane_subscriptions_observation 9));
  suspend_workspace_readings state;
  state.workspace_identity <- Workspace_identity_match;
  Alcotest.(check bool) "late save recovery targets open subscriptions panel" true
    (state.lane_nested_read_resume = Some (9, Lane_subscriptions_read));
  state.lane_addons <- Some {saved with generation=10};
  Alcotest.(check bool) "old save cannot replace newer panel read" false
    (retain_operation_observation state (Lane_subscriptions_observation 9))

let test_child_read_epoch_retains_running_audit () =
  let open Masc_tui_types in
  let state=create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match;
  let authority=state.workspace_authority in
  let original_reading=Some state.workspace_read_authority in
  let cached=["alpha",Masc_tui_child_content.empty] in
  state.msg_child_content <- cached;
  state.msg_child_content_inflight <-
    ["alpha",Masc_tui_child_content.Audit;"beta",Masc_tui_child_content.Poll];
  state.msg_child_content_audit_pending <- ["alpha";"gamma"];
  suspend_workspace_readings state;
  Alcotest.(check bool) "all retired Child slots released" true
    (state.msg_child_content_inflight=[]);
  Alcotest.(check bool) "Child snapshots retain physical cache identity" true
    (state.msg_child_content==cached);
  Alcotest.(check (list string)) "running audit coalesces with queued audit; poll is not promoted"
    ["alpha";"gamma"] state.msg_child_content_audit_pending;
  state.workspace_identity <- Workspace_identity_match_unconfirmed "temporary identity failure";
  suspend_workspace_readings state;
  Alcotest.(check (list string)) "repeated suspension retains exact audit intent"
    ["alpha";"gamma"] state.msg_child_content_audit_pending;
  state.workspace_identity <- Workspace_identity_match;
  state.msg_child_content_inflight <- ["alpha",Masc_tui_child_content.Audit];
  Alcotest.(check bool) "retired Child completion cannot own the successor slot" false
    (workspace_reply_admitted state ~authority ~reading:original_reading ~kind:Workspace_observation);
  Alcotest.(check bool) "successor observation is admitted" true
    (workspace_reply_admitted state ~authority ~reading:(Some state.workspace_read_authority)
      ~kind:Workspace_observation);
  state.msg_child_content_audit_pending <- [];
  suspend_workspace_readings state;
  Alcotest.(check (list string)) "a started audit without queued intent is restored"
    ["alpha"] state.msg_child_content_audit_pending

let test_native_task_read_epoch_retirement () =
  let open Masc_tui_types in
  let state=create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match;
  let authority=state.workspace_authority in
  let reading=Some state.workspace_read_authority in
  Alcotest.(check bool) "current read completion is admitted" true
    (workspace_reply_admitted state ~authority ~reading ~kind:Workspace_observation);
  let cached=["alpha",Masc_tui_native_tasks.empty] in
  state.msg_native_tasks <- cached;
  state.msg_native_tasks_inflight <- ["alpha",Masc_tui_native_tasks.Audit];
  state.msg_native_tasks_audit_pending <- [];
  suspend_workspace_readings state;
  Alcotest.(check bool) "retired native slot releases" true (state.msg_native_tasks_inflight=[]);
  Alcotest.(check bool) "cached task evidence survives" true (state.msg_native_tasks==cached);
  Alcotest.(check (list string)) "manual audit intent survives same workspace suspension"
    ["alpha"] state.msg_native_tasks_audit_pending;
  suspend_workspace_readings state;
  Alcotest.(check (list string)) "repeated retirement retains restored audit"
    ["alpha"] state.msg_native_tasks_audit_pending;
  state.msg_native_tasks_inflight <- ["beta",Masc_tui_native_tasks.Poll];
  suspend_workspace_readings state;
  Alcotest.(check (list string)) "poll is never promoted to audit"
    ["alpha"] state.msg_native_tasks_audit_pending;
  state.msg_native_tasks_inflight <- ["alpha",Masc_tui_native_tasks.Audit];
  Alcotest.(check bool) "old completion cannot release successor slot" false
    (workspace_reply_admitted state ~authority ~reading ~kind:Workspace_observation);
  Alcotest.(check bool) "successor read is admitted" true
    (workspace_reply_admitted state ~authority
       ~reading:(Some state.workspace_read_authority) ~kind:Workspace_observation)

let overview_snapshot health : Masc_tui_types.overview_snapshot =
  { ov_workspace_health = health
  ; ov_keepers = 0
  ; ov_keeper_listing = Masc.Keeper_snapshot_unread.Not_listed
  ; ov_keeper_liveness =
      { klc_active = 0; klc_offline = 0; klc_idle = 0; klc_paused = 0; klc_unreadable = 0 }
  ; ov_mcp_agents = 0
  ; ov_attention_items = []
  ; ov_generated_at = "fixture"
  }

let overview_preview_fixture () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"preview" ~local_base_path:"/workspace/preview"
      ~port:0 ~refresh_interval:0. () in
  let confirmed = overview_snapshot Workspace_health_warning in
  state.overview <- Some confirmed;
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket ~started_ns:0L;
  let preview =
    { op_ticket = ticket; op_authority = state.workspace_authority
    ; op_identity = identity state.local_base_path
    ; op_snapshot = overview_snapshot Workspace_health_ok } in
  state, confirmed, preview

let test_overview_preview_rejects_superseded_reading () =
  let open Masc_tui_types in
  let state, _, old = overview_preview_fixture () in
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket ~started_ns:1L;
  accept_overview_preview state old;
  Alcotest.(check bool) "superseded result leaves the new refresh unread" true
    (state.overview_preview = None);
  let current = { old with op_ticket = ticket } in
  accept_overview_preview state current;
  accept_overview_preview state old;
  Alcotest.(check bool) "late old result cannot replace a current preview" true
    (state.overview_preview = Some current)

let test_overview_preview_preserves_confirmed_state_and_authority () =
  let open Masc_tui_types in
  let state, confirmed, preview = overview_preview_fixture () in
  let authority = state.workspace_authority in
  let identity = state.server_identity and workspace = state.workspace_identity in
  accept_overview_preview state preview;
  Alcotest.(check bool) "current observation is retained" true
    (state.overview_preview = Some preview);
  Alcotest.(check bool) "readonly reading selects the preview data" true
    (overview_refresh_reading state = (None, Some preview.op_snapshot));
  Alcotest.(check bool) "confirmed overview is unchanged" true
    (state.overview = Some confirmed && state.overview_error = None);
  Alcotest.(check bool) "preview grants no workspace or server authority" true
    (state.workspace_authority = authority && state.server_identity = identity
     && state.workspace_identity = workspace)

let test_overview_refresh_finish_retires_preview_and_late_delivery () =
  let open Masc_tui_types in
  let state, confirmed, preview = overview_preview_fixture () in
  accept_overview_preview state preview;
  finish_http_refresh_state state;
  Alcotest.(check bool) "completion retires progress and its observation" true
    (state.http_refresh_started_ns = None && state.overview_preview = None);
  Alcotest.(check bool) "readonly reading returns confirmed data after completion" true
    (overview_refresh_reading state = (None, Some confirmed));
  accept_overview_preview state preview;
  Alcotest.(check bool) "late result cannot revive a completed refresh" true
    (state.overview_preview = None)

let test_overview_preview_refuses_foreign_or_retired_authority () =
  let open Masc_tui_types in
  let state, confirmed, preview = overview_preview_fixture () in
  accept_overview_preview state
    { preview with op_identity = identity "/workspace/foreign" };
  Alcotest.(check bool) "foreign reading cannot enter the preview" true
    (state.overview_preview = None);
  accept_overview_preview state preview;
  let Workspace_authority generation = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation + 1);
  Alcotest.(check bool) "retired authority cannot select cached preview data" true
    (overview_refresh_reading state = (None, Some confirmed));
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket ~started_ns:1L;
  accept_overview_preview state { preview with op_ticket = ticket };
  Alcotest.(check bool) "current ticket cannot spend retired workspace authority" true
    (state.overview_preview = None)

let early_asks_fixture () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"asks" ~local_base_path:"/workspace/asks"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity state.local_base_path);
  state.workspace_identity <- Workspace_identity_match;
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket ~started_ns:0L;
  let request = match begin_asks_read state with
    | Some request -> request
    | None -> Alcotest.fail "initial question read was refused" in
  let snapshot : Masc.Tui_decode_asks.asks_snapshot =
    { asn_keeper = None; asn_open_count = 1
    ; asn_rows =
        [{ ar_keeper = "alpha"; ar_id = "ask-1"; ar_asked_at = 1.; ar_source_turn_ref = None; ar_context = None
         ; ar_questions =
             [{ aq_id = "q1"; aq_header = "Choice"; aq_prompt = "Continue?"
              ; aq_mode = Masc.Tui_decode_asks.Ask_single
              ; aq_free_text = Masc.Tui_decode_asks.Ask_choices_only
              ; aq_choices = [{ac_id = "yes"; ac_label = "Yes"; ac_description = None}] }]
         ; ar_resolution = Masc.Tui_decode_asks.Ask_open }] } in
  state,
    { ea_ticket = ticket; ea_authority = state.workspace_authority
    ; ea_identity = identity state.local_base_path
    ; ea_observation = { asks_request = request; asks_result = Ok snapshot } }

let test_initial_probe_requires_current_cold_workspace () =
  let open Masc_tui_types in
  let state, early = early_asks_fixture () in
  state.workspace_identity <- Workspace_identity_unread;
  state.server_identity <- None;
  let admitted identity = can_admit_initial_http_identity state
      ~ticket:early.ea_ticket ~authority:early.ea_authority identity in
  Alcotest.(check bool) "ready current matching cold probe can hand off" true
    (admitted early.ea_identity);
  Alcotest.(check bool) "offering a probe does not grant workspace authority" true
    (state.workspace_identity = Workspace_identity_unread
     && state.server_identity = None
     && state.workspace_authority = early.ea_authority
     && Snapshot_read.in_flight state.asks_read);
  List.iter (fun candidate ->
    Alcotest.(check bool) "foreign incomplete or booting probes cannot hand off" false
      (admitted candidate))
    [ identity "/workspace/foreign"
    ; {early.ea_identity with sid_masc_root = "/workspace/foreign/.masc"}
    ; {early.ea_identity with sid_masc_root = ""}
    ; {early.ea_identity with sid_base_path = ""}
    ; {early.ea_identity with sid_state_ready = Some false}
    ; {early.ea_identity with sid_state_ready = None} ];
  List.iter (fun workspace ->
    state.workspace_identity <- workspace;
    Alcotest.(check bool) "warm suspended and foreign states retain their existing path" false
      (admitted early.ea_identity))
    [Workspace_identity_match; Workspace_identity_match_unconfirmed "unavailable";
     Workspace_identity_mismatch
       {local_base_path=state.local_base_path; server_base_path="/workspace/foreign"}];
  state.workspace_identity <- Workspace_identity_unread;
  let Workspace_authority generation = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation + 1);
  Alcotest.(check bool) "old authority cannot confirm a replacement workspace" false
    (admitted early.ea_identity)

let test_initial_probe_rejects_retired_refresh () =
  let open Masc_tui_types in
  let state, early = early_asks_fixture () in
  state.workspace_identity <- Workspace_identity_unread;
  let current = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket:current ~started_ns:10L;
  let admitted ticket = can_admit_initial_http_identity state
      ~ticket ~authority:state.workspace_authority early.ea_identity in
  Alcotest.(check bool) "superseded pass cannot hand off" false
    (admitted early.ea_ticket);
  Alcotest.(check bool) "current cold pass remains eligible" true (admitted current);
  finish_http_refresh_state ~finished_ns:20L state;
  Alcotest.(check bool) "finished pass cannot reopen through a delayed probe" false
    (admitted current)

let test_early_asks_apply_once_without_granting_authority () =
  let open Masc_tui_types in
  List.iter (fun result ->
    let state, early = early_asks_fixture () in
    let early = {early with ea_observation =
      {early.ea_observation with asks_result = result early.ea_observation.asks_result}} in
    let authority = state.workspace_authority and server = state.server_identity in
    accept_http_progress state {hp_ticket=early.ea_ticket;hp_authority=authority;
      hp_event=Http_refresh_progress.Started (Surface_data Surface_read_source.Planning,1L)};
    Alcotest.(check bool) "matching early result settles while unrelated data is pending" true
      (take_early_asks_observation state early = Some early.ea_observation.asks_result);
    Alcotest.(check bool) "terminal copy cannot be applied a second time" true
      (take_asks_observation state early.ea_observation = None);
    Alcotest.(check bool) "question result grants no authority and ends only its own request" true
      (state.workspace_authority = authority && state.server_identity = server
       && state.workspace_identity = Workspace_identity_match
       && not (Snapshot_read.in_flight state.asks_read)
       && state.http_refresh_started_ns = Some 0L))
    [Fun.id; (fun _ -> Error "question store unavailable")]

let test_unadmitted_cold_asks_defer_without_consuming_the_read () =
  let open Masc_tui_types in
  let state, early = early_asks_fixture () in
  state.workspace_identity <- Workspace_identity_unread;
  state.server_identity <- None;
  Alcotest.(check bool) "cold start cannot admit early questions" true
    (take_early_asks_observation state early = None);
  finish_http_refresh_state state;
  Alcotest.(check bool) "terminal bundle still owns the unconsumed question read" true
    (take_asks_observation state early.ea_observation = Some early.ea_observation.asks_result)

let test_early_asks_reject_foreign_stale_and_retired_authority () =
  let open Masc_tui_types in
  let state, early = early_asks_fixture () in
  let wrong_root = { early.ea_identity with sid_masc_root = "/workspace/foreign/.masc" } in
  Alcotest.(check bool) "same endpoint with a foreign root is refused" true
    (take_early_asks_observation state {early with ea_identity = wrong_root} = None);
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  state.http_refresh_order <- ticket;
  Alcotest.(check bool) "superseded full response cannot admit questions" true
    (take_early_asks_observation state early = None);
  let Workspace_authority generation = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation + 1);
  Alcotest.(check bool) "current ticket cannot spend retired workspace authority" true
    (take_early_asks_observation state {early with ea_ticket = ticket} = None);
  let current = {early with ea_ticket = ticket; ea_authority = state.workspace_authority} in
  finish_http_refresh_state state;
  Alcotest.(check bool) "completed full refresh cannot admit late questions" true
    (take_early_asks_observation state current = None)

let test_question_answer_retires_pre_answer_reads () =
  let open Masc_tui_types in
  let state, early = early_asks_fixture () in
  begin_ask_submission_state state;
  Alcotest.(check bool) "a pending answer does not start another listing" true
    (begin_asks_read state = None);
  state.ask_submit_inflight <- false;
  let answered : Masc.Tui_decode_asks.asks_snapshot =
    { asn_keeper = None; asn_open_count = 0; asn_rows = [] } in
  state.asks_snapshot <- Some answered;
  Alcotest.(check bool) "delayed early read cannot reopen the answered question" true
    (take_early_asks_observation state early = None);
  let failed = {early with ea_observation =
    {early.ea_observation with asks_result=Error "pre-answer request failed late"}} in
  Alcotest.(check bool) "delayed pre-answer failure cannot settle the post-answer state" true
    (take_early_asks_observation state failed = None);
  Alcotest.(check bool) "terminal bundle cannot replay the pre-answer snapshot" true
    (take_asks_observation state early.ea_observation = None
     && state.asks_snapshot = Some answered);
  let request = match begin_asks_read state with
    | Some request -> request | None -> Alcotest.fail "post-answer read did not resume" in
  Alcotest.(check bool) "a newly dispatched post-answer listing is admitted" true
    (take_asks_observation state {asks_request = request; asks_result = Ok answered}
     = Some (Ok answered))

let test_question_read_supersession_and_workspace_suspension () =
  let open Masc_tui_types in
  let state, early = early_asks_fixture () in
  let request = match begin_asks_read state with
    | Some request -> request | None -> Alcotest.fail "successor listing did not start" in
  Alcotest.(check bool) "newer scoped listing supersedes the full listing" true
    (take_asks_observation state early.ea_observation = None);
  let current = {early.ea_observation with asks_request = request} in
  suspend_workspace_readings state;
  Alcotest.(check bool) "workspace suspension retires the current question listing" true
    (take_asks_observation state current = None)

let test_refresh_progress_tracks_independent_sources_and_interruption () =
  let open Masc_tui_types in
  let module Progress = Http_refresh_progress in
  let state = create_state ~workspace:"progress" ~local_base_path:"/workspace/progress"
      ~port:0 ~refresh_interval:0. () in
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  let authority = state.workspace_authority in
  let original_identity = state.workspace_identity in
  let needs = {nothing with needs_planning=true; needs_overview_goals=true} in
  let reads, _ = Surface_read_order.dispatch ~kind:Surface_read_order.Full
      ~needs ~started_ns:10_000_000L state.http_surface_reads in
  state.http_surface_reads <- reads;
  begin_http_refresh_state state ~ticket ~started_ns:10_000_000L;
  let deliver hp_event = accept_http_progress state
    { hp_ticket = ticket; hp_authority = authority; hp_event } in
  let progress () = match state.http_refresh_progress with
    | Some (_, progress) -> progress
    | None -> Alcotest.fail "refresh lost its observation" in
  deliver (Progress.Started (Progress.Questions, 20_000_000L));
  deliver (Progress.Started (Progress.Keepers, 30_000_000L));
  let work = Progress.Surface_data Surface_read_order.Planning in
  let goals = Progress.Surface_data Surface_read_order.Overview_goals in
  deliver (Progress.Started (work, 40_000_000L));
  deliver (Progress.Started (goals, 45_000_000L));
  deliver (Progress.Completed (Progress.Questions, 60_000_000L, Progress.Received));
  deliver (Progress.Completed (Progress.Keepers, 70_000_000L, Progress.Received));
  deliver (Progress.Completed (work, 75_000_000L, Progress.Failed));
  Alcotest.(check bool) "a pending Goal read does not hide the failed Work read" true
    (Progress.counts (progress ()) = (1, 2, 1, 0)
     && Progress.pending_sources (progress ()) = [goals]
     && Progress.settled_sources ~outcome:Progress.Failed (progress ()) = [work]);
  let settled = state.http_refresh_progress in
  deliver (Progress.Completed (Progress.Questions, 80_000_000L, Progress.Failed));
  deliver (Progress.Completed (work, 80_000_000L, Progress.Received));
  deliver (Progress.Completed (Progress.Overview, 80_000_000L, Progress.Received));
  Alcotest.(check bool) "duplicate and undispatched settlements preserve the actual observation" true
    (state.http_refresh_progress = settled);
  Alcotest.(check bool) "diagnostics never confirm workspace identity or publish data" true
    (state.workspace_identity = original_identity && state.workspace_authority = authority
     && state.overview = None && state.asks_snapshot = None
     && Surface_read_order.pending ~needs state.http_surface_reads
          = [Surface_read_order.Planning;Surface_read_order.Overview_goals]
     && Surface_read_order.pending_scoped ~needs state.http_surface_reads = []);
  finish_http_refresh_state ~finished_ns:100_000_000L state;
  Alcotest.(check bool) "a stopped refresh records its remaining read as interrupted" true
    (Progress.counts (progress ()) = (0, 2, 1, 1)
     && Progress.settled_sources ~outcome:Progress.Interrupted (progress ()) = [goals]);
  Alcotest.(check (float 0.)) "total duration uses the same monotonic interval" 90.
    Yojson.Safe.Util.(Progress.to_json (progress ()) |> member "elapsed_ms" |> to_number);
  let finished = state.http_refresh_progress in
  deliver (Progress.Started (Progress.Identity_after, 110_000_000L));
  Alcotest.(check bool) "late diagnostics cannot reopen a completed refresh" true
    (state.http_refresh_progress = finished)

let test_refresh_progress_rejects_old_request_and_workspace () =
  let open Masc_tui_types in
  let module Progress = Http_refresh_progress in
  let state = create_state ~workspace:"progress" ~local_base_path:"/workspace/progress"
      ~port:0 ~refresh_interval:0. () in
  let old_ticket = Http_refresh_order.dispatch state.http_refresh_order in
  let authority = state.workspace_authority in
  begin_http_refresh_state state ~ticket:old_ticket ~started_ns:0L;
  let ticket = Http_refresh_order.dispatch old_ticket in
  begin_http_refresh_state state ~ticket ~started_ns:10L;
  let untouched = state.http_refresh_progress in
  accept_http_progress state { hp_ticket = old_ticket; hp_authority = authority;
    hp_event = Progress.Started (Progress.Questions, 20L) };
  Alcotest.(check bool) "superseded request cannot add a source" true
    (state.http_refresh_progress = untouched);
  let Workspace_authority generation = authority in
  state.workspace_authority <- Workspace_authority (generation + 1);
  accept_http_progress state { hp_ticket = ticket; hp_authority = authority;
    hp_event = Progress.Started (Progress.Questions, 30L) };
  accept_http_progress state { hp_ticket = ticket; hp_authority = state.workspace_authority;
    hp_event = Progress.Started (Progress.Questions, 40L) };
  Alcotest.(check bool) "neither retired nor replacement authority can spend the old read" true
    (state.http_refresh_progress = untouched)

let early_roster_fixture () =
  let open Masc_tui_types in
  let base = "/workspace/early-roster" in
  let state = create_state ~workspace:"early-roster" ~local_base_path:base
      ~port:0 ~refresh_interval:0. () in
  let server = identity base in
  state.workspace_identity <- Workspace_identity_match;
  state.server_identity <- Some server;
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket ~started_ns:0L;
  let request = match begin_keeper_roster_read state with
    | Some request -> request | None -> Alcotest.fail "roster read did not start" in
  state,
  { er_ticket=ticket; er_authority=state.workspace_authority; er_identity=server;
    er_observation={roster_request=request;
      roster_result=Ok (Masc_tui_keeper_control.Roster_complete [],Error "Candle unavailable")} }

let test_early_roster_settles_before_slow_siblings_once () =
  let open Masc_tui_types in
  let state,early = early_roster_fixture () in
  let authority=state.workspace_authority and server=state.server_identity in
  accept_http_progress state {hp_ticket=early.er_ticket;hp_authority=authority;
    hp_event=Http_refresh_progress.Started (Surface_data Surface_read_source.Planning,1L)};
  Alcotest.(check bool) "verified roster is usable while another reader is pending" true
    (take_early_keeper_roster_observation state early = Some early.er_observation.roster_result);
  Alcotest.(check bool) "early delivery neither ends refresh nor confirms new authority" true
    (state.http_refresh_started_ns=Some 0L && state.workspace_authority=authority
     && state.server_identity=server);
  Alcotest.(check bool) "terminal copy cannot replay roster or dependent refresh" true
    (take_keeper_roster_observation state early.er_observation=None);
  let state,early = early_roster_fixture () in
  state.workspace_identity <- Workspace_identity_unread;
  state.server_identity <- None;
  Alcotest.(check bool) "cold start retains final identity admission" true
    (take_early_keeper_roster_observation state early=None);
  finish_http_refresh_state state;
  Alcotest.(check bool) "cold start's terminal bundle still owns its read" true
    (take_keeper_roster_observation state early.er_observation=Some early.er_observation.roster_result)

let test_early_roster_preserves_read_ownership () =
  let open Masc_tui_types in
  let state,early = early_roster_fixture () in
  let foreign={early.er_identity with sid_masc_root="/workspace/foreign/.masc"} in
  Alcotest.(check bool) "foreign endpoint cannot admit roster" true
    (take_early_keeper_roster_observation state {early with er_identity=foreign}=None);
  let failure={early.er_observation with
    roster_result=Error (Masc_tui_keeper_control.Roster_unreachable "unreachable")} in
  Alcotest.(check bool) "a foreign failure cannot retire the current roster" true
    (take_early_keeper_roster_observation state
       {early with er_identity=foreign;er_observation=failure}=None
     && Snapshot_read.in_flight state.keeper_roster_read);
  Alcotest.(check bool) "owned failure settles without waiting for the full refresh" true
    (take_early_keeper_roster_observation state {early with er_observation=failure}
       =Some failure.roster_result
     && not (Snapshot_read.in_flight state.keeper_roster_read)
     && state.http_refresh_started_ns=Some 0L);
  Alcotest.(check bool) "terminal failure no longer owns a roster reading" true
    (take_keeper_roster_observation state failure=None);
  let successor=match begin_keeper_roster_read state with
    | Some request -> request | None -> Alcotest.fail "successor roster did not start" in
  Alcotest.(check bool) "newer scoped roster supersedes the old full copy" true
    (take_early_keeper_roster_observation state early=None
     && take_early_keeper_roster_observation state {early with er_observation=failure}=None
     && take_keeper_roster_observation state early.er_observation=None
     && Snapshot_read.in_flight state.keeper_roster_read);
  let newer={early.er_observation with roster_request=successor} in
  suspend_workspace_readings state;
  Alcotest.(check bool) "workspace suspension retires the successor too" true
    (take_keeper_roster_observation state newer=None);
  let state,early = early_roster_fixture () in
  state.http_refresh_order <- Http_refresh_order.dispatch state.http_refresh_order;
  Alcotest.(check bool) "superseded full refresh cannot publish a roster" true
    (take_early_keeper_roster_observation state early=None);
  let state,early = early_roster_fixture () in
  let Workspace_authority generation=state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation+1);
  Alcotest.(check bool) "retired workspace cannot publish a roster" true
    (take_early_keeper_roster_observation state early=None)

let local_workspace_request_exn state source at =
  match Masc_tui_types.begin_local_workspace_read state ~intent:Masc_tui_types.Snapshot_read.Poll ~source
          ~base_path:state.Masc_tui_types.local_base_path ~started_ns:at with
  | Some request -> request
  | None -> Alcotest.fail "local workspace read did not start"

let test_local_read_and_http_sources_progress_independently () =
  let open Masc_tui_types in
  let state, early = early_roster_fixture () in
  let request = local_workspace_request_exn state Local_work 5L in
  Alcotest.(check bool) "cadence cannot duplicate the local worker" true
    (begin_local_workspace_read state ~intent:Snapshot_read.Poll ~source:Local_work ~base_path:state.local_base_path ~started_ns:6L = None);
  Alcotest.(check bool) "local pending does not gate HTTP source admission" true
    (Option.is_some (take_early_keeper_roster_observation state early)
     && Local_read_order.in_flight state.local_workspace_read_order);
  let reading : Masc_tui_loader.local_reading =
    { lr_agents = []; lr_rows = Masc_tui_overview_tasks.Rows_read []
    ; lr_tasks_domain = []; lr_tasks_error = None; lr_task_flow = None
    ; lr_operator_stalled = Masc_tui_agenda.Read []; lr_goal_task_links = Goal_links_not_read
    ; lr_goals_to_confirm = Masc_tui_agenda.Read [] } in
  (match take_local_workspace_read state ~source:Local_work request (Ok reading) with
   | Some (Ok observed) -> Masc_tui_loader.apply_local_workspace state observed
   | Some (Error _) | None -> Alcotest.fail "current local result was not admitted");
  Alcotest.(check bool) "local observation lands before enclosing collector completes" true
    (state.local_workspace = Local_workspace_read && state.http_refresh_started_ns = Some 0L);
  Alcotest.(check bool) "duplicate completion cannot apply again" true
    (take_local_workspace_read state ~source:Local_work request (Ok reading) = None)

let test_local_read_refuses_retired_epoch_and_wrong_path () =
  let open Masc_tui_types in
  let state, _ = early_roster_fixture () in
  let old = local_workspace_request_exn state Local_work 5L in
  suspend_workspace_readings state;
  state.workspace_identity <- Workspace_identity_match;
  let current = local_workspace_request_exn state Local_work 7L in
  Alcotest.(check bool) "same path after suspension cannot accept the old epoch" true
    (take_local_workspace_read state ~source:Local_work old (Error "old failure") = None
     && Local_read_order.in_flight state.local_workspace_read_order
     && state.local_workspace = Local_workspace_unread);
  let wrong_path = { current with lwr_base_path = "/workspace/foreign" } in
  Alcotest.(check bool) "foreign path cannot settle the successor slot" true
    (take_local_workspace_read state ~source:Local_work wrong_path (Ok ()) = None);
  let Workspace_authority generation = state.workspace_authority in
  let wrong_epoch = { current with lwr_authority = Workspace_authority (generation + 1) } in
  Alcotest.(check bool) "foreign authority cannot spend a matching path and request" true
    (take_local_workspace_read state ~source:Local_work wrong_epoch (Ok ()) = None);
  Alcotest.(check bool) "only the successor can settle" true
    (take_local_workspace_read state ~source:Local_work current (Ok ()) = Some (Ok ()))

let test_local_read_failure_settles_and_can_be_retried () =
  let open Masc_tui_types in
  let state, _ = early_roster_fixture () in
  let request = local_workspace_request_exn state Local_work 5L in
  Alcotest.(check bool) "owned failure is observed" true
    (take_local_workspace_read state ~source:Local_work request (Error "directory unavailable") = Some (Error "directory unavailable"));
  Alcotest.(check bool) "failure is distinct from unread or empty and releases its slot" true
    (state.local_workspace = Local_workspace_failed "directory unavailable"
     && not (Local_read_order.in_flight state.local_workspace_read_order)
     && local_rows_page state ~error:None = Page_failed);
  let retry = local_workspace_request_exn state Local_work 7L in
  Alcotest.(check bool) "late failed attempt cannot release the retry" true
    (take_local_workspace_read state ~source:Local_work request (Error "late failure") = None
     && Local_read_order.in_flight state.local_workspace_read_order);
  Alcotest.(check bool) "fresh retry can settle" true
    (take_local_workspace_read state ~source:Local_work retry (Ok ()) = Some (Ok ()))

let local_keeper_source_fixture () =
  let state, _ = early_roster_fixture () in
  let keeper : Masc_tui_types.keeper =
    { k_origin = Masc.Tui_decode.Persisted_keeper; k_name = "alpha"; k_paused = false
    ; k_identity = Ok { k_trace_id = "local-keeper-source"; k_created_at = "fixture"; k_updated_at = "fixture" }
    ; k_activity = None } in
  let metadata : Masc_tui_loader.local_keeper_reading =
    { lkr_keepers = [ keeper ]; lkr_error = None } in
  state, keeper, metadata

let apply_metadata_observation state request metadata =
  match Masc_tui_types.take_local_workspace_read state ~source:Local_keepers request (Ok metadata) with
  | Some (Ok observed) -> Masc_tui_loader.apply_local_keepers state observed
  | Some (Error _) | None -> Alcotest.fail "metadata observation was not admitted"

let request_local_refresh state source at =
  Masc_tui_types.begin_local_workspace_read state ~intent:Masc_tui_types.Snapshot_read.Refresh
    ~source ~base_path:state.Masc_tui_types.local_base_path ~started_ns:at

let test_local_refresh_burst_keeps_active_read_and_one_followup () =
  let open Masc_tui_types in
  let state, _, metadata = local_keeper_source_fixture () in
  Masc_tui_loader.apply_local_keepers state metadata;
  let active = local_workspace_request_exn state Local_keepers 1L in
  let work = local_workspace_request_exn state Local_work 2L in
  let old_token = ref () and new_token = ref () in
  let cancelled = ref 0 in
  supersede_local_source_read state Local_keepers (Some (old_token, fun () -> incr cancelled));
  List.iter (fun at -> Alcotest.(check bool) "refresh burst shares the active read" true
      (request_local_refresh state Local_keepers at = None)) [3L; 4L; 5L];
  let required = Local_read_order.demanded_revision state.local_keeper_read_order in
  Alcotest.(check int) "coalescing did not cancel active work" 0 !cancelled;
  apply_metadata_observation state active metadata;
  Alcotest.(check bool) "completion publishes observation but does not consume newer demand" true
    (Local_read_order.has_followup state.local_keeper_read_order
     && not (Local_read_order.covers state.local_keeper_read_order required));
  finish_local_source_read state Local_keepers old_token;
  let followup = local_workspace_request_exn state Local_keepers 6L in
  Alcotest.(check bool) "one followup carries refresh provenance" true
    (followup.lwr_intent = Snapshot_read.Refresh
     && not (Local_read_order.has_followup state.local_keeper_read_order));
  supersede_local_source_read state Local_keepers (Some (new_token, fun () -> incr cancelled));
  finish_local_source_read state Local_keepers old_token;
  Alcotest.(check bool) "old cleanup cannot clear followup cancellation owner" true
    (match local_source_cancellation state Local_keepers with
     | Some (held, _) -> held == new_token
     | None -> false);
  Alcotest.(check bool) "duplicate earlier result cannot settle the followup" true
    (take_local_workspace_read state ~source:Local_keepers active (Error "duplicate") = None
     && Local_read_order.in_flight state.local_keeper_read_order);
  apply_metadata_observation state followup metadata;
  Alcotest.(check bool) "followup covers the accumulated burst" true
    (Local_read_order.covers state.local_keeper_read_order required
     && not (Local_read_order.has_followup state.local_keeper_read_order));
  Alcotest.(check bool) "optional Work kept its own active request" true
    (take_local_workspace_read state ~source:Local_work work (Ok ()) = Some (Ok ()))

let test_created_keeper_waits_for_owned_metadata_without_work () =
  let open Masc_tui_types in
  List.iter (fun include_created ->
  let state, keeper, metadata = local_keeper_source_fixture () in
  Masc_tui_loader.apply_local_keepers state metadata;
  let created = {keeper with k_name = "created"} in
  state.view <- Keepers Keeper_message;
  state.msg_target_keeper_name <- Some created.k_name;
  Masc_tui_message_input.insert state.msg_input "draft entered after creation";
  let work = local_workspace_request_exn state Local_work 1L in
  let before_creation = local_workspace_request_exn state Local_keepers 2L in
  ignore (request_local_refresh state Local_keepers 3L);
  wait_for_created_keeper_metadata state created.k_name;
  (* Even an older read that happens to observe the new name does not prove
     that the creation's requested refresh has completed. *)
  apply_metadata_observation state before_creation
    (if include_created then {metadata with lkr_keepers = [keeper; created]} else metadata);
  Alcotest.(check bool) "older metadata cannot admit creation input" false
    (keeper_available_for_new_message state created.k_name);
  Alcotest.(check bool) "older absence cannot close the pending created chat" true
    (state.view = Keepers Keeper_message && state.msg_target_keeper_name = Some created.k_name);
  let after_creation = local_workspace_request_exn state Local_keepers 4L in
  apply_metadata_observation state after_creation {metadata with lkr_keepers = [keeper; created]};
  Alcotest.(check bool) "created Keeper is available without optional Work" true
    (keeper_available_for_new_message state created.k_name
     && Local_read_order.in_flight state.local_workspace_read_order);
  Alcotest.(check string) "creation refresh retained draft"
    "draft entered after creation" (Masc_tui_message_input.contents state.msg_input);
  ignore (take_local_workspace_read state ~source:Local_work work (Error "optional work unavailable"));
  Alcotest.(check bool) "Work failure cannot revoke creation coverage" true
    (keeper_available_for_new_message state created.k_name)) [false; true]

let test_deleted_keeper_reconciles_after_fresh_metadata () =
  let open Masc_tui_types in
  let state, keeper, metadata = local_keeper_source_fixture () in
  let survivor = {keeper with k_name = "survivor"} in
  Masc_tui_loader.apply_local_keepers state {metadata with lkr_keepers = [keeper; survivor]};
  state.view <- Keepers Keeper_detail;
  state.keeper_cursor <- 0;
  Masc_tui_message_input.insert state.msg_input "retained draft";
  let old = local_workspace_request_exn state Local_keepers 1L in
  ignore (request_local_refresh state Local_keepers 2L);
  apply_metadata_observation state old {metadata with lkr_keepers = [keeper; survivor]};
  let fresh = local_workspace_request_exn state Local_keepers 3L in
  apply_metadata_observation state fresh {metadata with lkr_keepers = [survivor]};
  Alcotest.(check bool) "confirmed deletion leaves removed detail without retargeting it" true
    (state.view = Keepers Keeper_list && state.keepers = [survivor]
     && not (keeper_available_for_new_message state keeper.k_name));
  Alcotest.(check bool) "late older rows cannot restore deleted Keeper" true
    (take_local_workspace_read state ~source:Local_keepers old (Ok metadata) = None);
  Alcotest.(check string) "reconciliation retains draft"
    "retained draft" (Masc_tui_message_input.contents state.msg_input)

let test_concurrent_created_keepers_retain_individual_refresh_coverage () =
  let open Masc_tui_types in
  let state, keeper, metadata = local_keeper_source_fixture () in
  Masc_tui_loader.apply_local_keepers state metadata;
  let first = {keeper with k_name = "first"} and second = {keeper with k_name = "second"} in
  let first_read = match request_local_refresh state Local_keepers 1L with
    | Some request -> request
    | None -> Alcotest.fail "first creation refresh did not start" in
  wait_for_created_keeper_metadata state first.k_name;
  ignore (request_local_refresh state Local_keepers 2L);
  wait_for_created_keeper_metadata state second.k_name;
  let observed = {metadata with lkr_keepers = [keeper; first; second]} in
  apply_metadata_observation state first_read observed;
  Alcotest.(check bool) "first creation can proceed on its completed refresh" true
    (keeper_available_for_new_message state first.k_name);
  Alcotest.(check bool) "second creation retains its own later barrier" false
    (keeper_available_for_new_message state second.k_name);
  let followup = local_workspace_request_exn state Local_keepers 3L in
  apply_metadata_observation state followup observed;
  Alcotest.(check bool) "one followup covers both creation waiters" true
    (keeper_available_for_new_message state first.k_name
     && keeper_available_for_new_message state second.k_name)

let test_failed_read_keeps_followup_and_withdrawal_retires_it () =
  let open Masc_tui_types in
  let state, _, _ = local_keeper_source_fixture () in
  let active = local_workspace_request_exn state Local_work 1L in
  ignore (request_local_refresh state Local_work 2L);
  ignore (take_local_workspace_read state ~source:Local_work active (Error "read failed"));
  Alcotest.(check bool) "owned failure leaves accumulated demand eligible" true
    (state.local_workspace = Local_workspace_failed "read failed"
     && Local_read_order.has_followup state.local_workspace_read_order);
  let followup = local_workspace_request_exn state Local_work 3L in
  ignore (request_local_refresh state Local_work 4L);
  suspend_workspace_readings state;
  state.workspace_identity <- Workspace_identity_match;
  Alcotest.(check bool) "withdrawal retires active read and queued demand" true
    (not (Local_read_order.has_followup state.local_workspace_read_order)
     && take_local_workspace_read state ~source:Local_work followup (Ok ()) = None);
  let resumed = local_workspace_request_exn state Local_work 5L in
  Alcotest.(check bool) "reconfirmed workspace can observe a new source read" true
    (take_local_workspace_read state ~source:Local_work resumed (Ok ()) = Some (Ok ()))

let test_archive_cache_does_not_cross_equal_stat_files () =
  let first = Filename.temp_file "tui-archive-source-a-" ".json" in
  let second = Filename.temp_file "tui-archive-source-b-" ".json" in
  Fun.protect ~finally:(fun () -> Sys.remove first; Sys.remove second) (fun () ->
    let write path contents =
      let channel = open_out_bin path in
      Fun.protect ~finally:(fun () -> close_out_noerr channel)
        (fun () -> output_string channel contents) in
    let first_json = "{\"tasks\":[0]}" and second_json = "{\"tasks\":[]}" in
    write first first_json;
    write second (second_json ^ String.make (String.length first_json - String.length second_json) ' ');
    let stamp = (Unix.stat first).Unix.st_mtime in
    Unix.utimes first stamp stamp;
    Unix.utimes second stamp stamp;
    Alcotest.(check bool) "distinct archive files have equal cache stat keys" true
      ((Unix.stat first).Unix.st_size = (Unix.stat second).Unix.st_size
       && Float.equal (Unix.stat first).Unix.st_mtime (Unix.stat second).Unix.st_mtime);
    let undecoded path = match Masc_tui_loader.read_archived_tasks path with
      | Ok (_, undecoded) -> undecoded
      | Error detail -> Alcotest.fail detail in
    Alcotest.(check int) "first archive retains invalid-row evidence" 1 (undecoded first);
    Alcotest.(check int) "second path cannot reuse first archive evidence" 0 (undecoded second))

let test_local_cache_cancel_releases_source_for_followup () =
  let exception Read_replaced in
  Eio_main.run (fun _env ->
    let mutex = Eio.Mutex.create () in
    let entered, signal_entered = Eio.Promise.create () in
    let finished, signal_finished = Eio.Promise.create () in
    let blocked, _unblock = Eio.Promise.create () in
    let cancellation = ref None and propagated = ref false in
    Eio.Switch.run (fun sw ->
      Eio.Fiber.fork ~sw (fun () ->
        (try Eio.Cancel.sub (fun context ->
           cancellation := Some context;
           Masc_tui_loader.with_local_read_mutex mutex (fun () ->
             Eio.Promise.resolve signal_entered ();
             Eio.Promise.await blocked))
         with Eio.Cancel.Cancelled Read_replaced -> propagated := true);
        Eio.Promise.resolve signal_finished ());
      Eio.Promise.await entered;
      (match !cancellation with
       | None -> Alcotest.fail "reader never owned a cancellation scope"
       | Some context -> Eio.Cancel.cancel context Read_replaced);
      Eio.Promise.await finished;
      Alcotest.(check bool) "original cancellation propagated" true !propagated;
      let seen_failure =
        try Masc_tui_loader.with_local_read_mutex mutex (fun () -> raise (Sys_error "source failure")); false
        with Sys_error _ -> true in
      Alcotest.(check bool) "read failure is still observable" true seen_failure;
      let next = Masc_tui_loader.with_local_read_mutex mutex (fun () -> 42) in
      Alcotest.(check int) "later source reader can use the released cache resource" 42 next))

let start_live_context_exn state keeper =
  match Masc_tui_context_state.start state.Masc_tui_types.live_context
          ~key:(Masc_tui_types.live_context_key state keeper) with
  | Masc_tui_context_state.Started (next, request) -> state.live_context <- next; request
  | Masc_tui_context_state.Already_loading -> Alcotest.fail "context request already pending"

let live_context_fixture () =
  let state, keeper, metadata = local_keeper_source_fixture () in
  Masc_tui_loader.apply_local_keepers state metadata;
  state.view <- Masc_tui_types.Keepers Keeper_detail;
  state.keeper_cursor <- 0;
  state, keeper

let test_live_context_refuses_changed_trace_before_reconciliation () =
  let open Masc_tui_types in
  let state, keeper = live_context_fixture () in
  let old = start_live_context_exn state keeper in
  let current = { keeper with k_identity =
      Result.map (fun (identity : Tui_decode.keeper_identity) ->
        { identity with k_trace_id = "successor-trace" }) keeper.k_identity } in
  state.keepers <- [ current ];
  Alcotest.(check bool) "queued old trace cannot land before reconciliation" false
    (take_live_context_observation state old (Error "previous trace"));
  Alcotest.(check bool) "discarded completion also retires its pending owner" true
    (Masc_tui_context_state.current_key state.live_context = None);
  (* A return to the original identity before the next reconciliation must
     start a new worker, rather than coalesce onto the discarded result. *)
  state.keepers <- [ keeper ];
  let returned = start_live_context_exn state keeper in
  Alcotest.(check bool) "return to the original key can settle afresh" true
    (take_live_context_observation state returned (Error "returned key"));
  state.keepers <- [ current ];
  let fresh = start_live_context_exn state current in
  Alcotest.(check bool) "late old result cannot settle the successor" true
    (not (take_live_context_observation state old (Error "late result"))
     && Masc_tui_context_state.is_current state.live_context fresh);
  Alcotest.(check bool) "current failure is admitted exactly once" true
    (take_live_context_observation state fresh (Error "current store failure")
     && not (take_live_context_observation state fresh (Error "duplicate")))

let test_live_context_chat_target_is_independent_of_roster_cursor () =
  let open Masc_tui_types in
  let state, keeper = live_context_fixture () in
  let other = { keeper with k_name = "beta" } in
  state.keepers <- [ keeper; other ];
  state.view <- Keepers Keeper_message;
  state.msg_target_keeper_name <- Some keeper.k_name;
  state.keeper_cursor <- 1;
  Alcotest.(check bool) "chat target owns the source, rather than the roster cursor" true
    (live_context_keeper state = Some keeper);
  let request = start_live_context_exn state keeper in
  Alcotest.(check bool) "moving the roster does not steal the chat source" true
    (take_live_context_observation state request (Error "target context unavailable"));
  state.msg_target_keeper_name <- Some "missing";
  Alcotest.(check bool) "missing chat target cannot fall back to a roster row" true
    (live_context_keeper state = None);
  state.view <- Overview;
  Alcotest.(check bool) "unrelated surface does not request a Keeper context" true
    (live_context_keeper state = None)

let test_live_context_suspension_cancels_and_retires_same_path_read () =
  let open Masc_tui_types in
  let state, keeper = live_context_fixture () in
  let request = start_live_context_exn state keeper in
  let cancelled = ref 0 in
  supersede_live_context_read state (Some (fun () -> incr cancelled));
  suspend_workspace_readings state;
  state.workspace_identity <- Workspace_identity_match;
  state.local_keepers <- Local_workspace_read;
  Alcotest.(check int) "workspace suspension requested source cancellation" 1 !cancelled;
  Alcotest.(check bool) "same path after reconfirmation cannot revive old scope" false
    (take_live_context_observation state request (Error "old scope"));
  let current = start_live_context_exn state keeper in
  Alcotest.(check bool) "new scope owns its observation" true
    (take_live_context_observation state current (Error "current scope"))

let test_keeper_metadata_admits_input_before_work_completes () =
  let open Masc_tui_types in
  let state, keeper, metadata = local_keeper_source_fixture () in
  let work = local_workspace_request_exn state Local_work 5L in
  let required = local_workspace_request_exn state Local_keepers 6L in
  Alcotest.(check bool) "unread metadata cannot authorize input" false
    (keeper_available_for_new_message state keeper.k_name);
  apply_metadata_observation state required metadata;
  Alcotest.(check bool) "input is ready while work and HTTP collection are unfinished" true
    (keeper_available_for_new_message state keeper.k_name
     && state.local_workspace = Local_workspace_unread
     && Local_read_order.in_flight state.local_workspace_read_order
     && state.http_refresh_started_ns = Some 0L);
  let work_reading : Masc_tui_loader.local_reading =
    { lr_agents = []; lr_rows = Masc_tui_overview_tasks.Rows_read []
    ; lr_tasks_domain = []; lr_tasks_error = None; lr_task_flow = None
    ; lr_operator_stalled = Masc_tui_agenda.Read []; lr_goal_task_links = Goal_links_not_read
    ; lr_goals_to_confirm = Masc_tui_agenda.Read [] } in
  (match take_local_workspace_read state ~source:Local_work work (Ok work_reading) with
   | Some (Ok observed) -> Masc_tui_loader.apply_local_workspace state observed
   | Some (Error _) | None -> Alcotest.fail "work result was not admitted");
  Alcotest.(check bool) "later work cannot replace metadata or revoke input" true
    (state.keepers = [ keeper ] && state.local_keepers = Local_workspace_read
     && keeper_available_for_new_message state keeper.k_name)

let test_local_source_failures_are_independent () =
  let open Masc_tui_types in
  let state, keeper, metadata = local_keeper_source_fixture () in
  let work = local_workspace_request_exn state Local_work 5L in
  let required = local_workspace_request_exn state Local_keepers 6L in
  ignore (take_local_workspace_read state ~source:Local_work work (Error "archive unavailable"));
  Alcotest.(check bool) "work failure leaves metadata pending and unmodified" true
    (state.local_workspace = Local_workspace_failed "archive unavailable"
     && state.local_keepers = Local_workspace_unread
     && Local_read_order.in_flight state.local_keeper_read_order);
  apply_metadata_observation state required metadata;
  Alcotest.(check bool) "work failure does not prevent metadata-authorized input" true
    (keeper_available_for_new_message state keeper.k_name);
  let retry = local_workspace_request_exn state Local_keepers 7L in
  ignore (take_local_workspace_read state ~source:Local_keepers retry (Error "metadata unavailable"));
  Alcotest.(check bool) "metadata failure withdraws input without rewriting work state" true
    (not (keeper_available_for_new_message state keeper.k_name)
     && state.local_workspace = Local_workspace_failed "archive unavailable"
     && state.local_keepers = Local_workspace_failed "metadata unavailable")

let test_local_source_tickets_cannot_cross_or_survive_suspension () =
  let open Masc_tui_types in
  let state, _, _ = local_keeper_source_fixture () in
  let work = local_workspace_request_exn state Local_work 5L in
  let required = local_workspace_request_exn state Local_keepers 6L in
  Alcotest.(check int) "source counters may legitimately coincide"
    (Local_read_order.request_id work.lwr_request) (Local_read_order.request_id required.lwr_request);
  Alcotest.(check bool) "matching numeric ticket cannot spend the other source owner" true
    (take_local_workspace_read state ~source:Local_keepers work (Ok ()) = None
     && take_local_workspace_read state ~source:Local_work required (Ok ()) = None
     && Local_read_order.in_flight state.local_keeper_read_order
     && Local_read_order.in_flight state.local_workspace_read_order);
  suspend_workspace_readings state;
  let new_work = local_workspace_request_exn state Local_work 7L in
  let new_required = local_workspace_request_exn state Local_keepers 8L in
  Alcotest.(check bool) "same-path late results cannot retire either successor" true
    (take_local_workspace_read state ~source:Local_work work (Error "old work") = None
     && take_local_workspace_read state ~source:Local_keepers required (Error "old metadata") = None
     && Local_read_order.in_flight state.local_keeper_read_order
     && Local_read_order.in_flight state.local_workspace_read_order);
  Alcotest.(check bool) "each current source still settles independently" true
    (take_local_workspace_read state ~source:Local_work new_work (Ok ()) = Some (Ok ())
     && take_local_workspace_read state ~source:Local_keepers new_required (Ok ()) = Some (Ok ()))

let test_question_origin_survives_answer_and_workspace_change () =
  let open Masc_tui_types in
  let module Ask = Masc_tui_ask_projection in
  let state,early = early_asks_fixture () in
  let original_ref = Ids.Turn_ref.make ~trace_id:"original-question-source" ~absolute_turn:17 in
  let snapshot = match early.ea_observation.asks_result with
    | Ok snapshot -> snapshot | Error error -> Alcotest.fail error in
  let original = match snapshot.asn_rows with
    | [row] -> {row with ar_source_turn_ref=Some original_ref}
    | _ -> Alcotest.fail "one original question" in
  let origin = Ask.origin_of_row original in
  toggle_ask_origin state origin;
  let submission : ask_submission =
    {as_request=ref ();as_authority=state.workspace_authority;
     as_keeper_name=original.ar_keeper;as_ask_id=original.ar_id;as_answered_label="private choice";
     as_source_turn_ref=original.ar_source_turn_ref} in
  begin_ask_submission_state ~submission state;
  let later = {original with ar_id="later-question";
      ar_source_turn_ref=Some (Ids.Turn_ref.make ~trace_id:"later-source" ~absolute_turn:900)} in
  state.asks_snapshot <- Some {snapshot with asn_rows=[later]};
  state.asks_error <- Some "reread unavailable";
  let feedback = retain_ask_answer_feedback state submission
      (Ok (Masc.Tui_decode_asks.Ask_answer_recorded Masc.Tui_decode_asks.Ask_wake_stored))
      |> Option.get in
  Alcotest.(check (option string)) "receipt preserves the transmitted question's source"
    (Some "original-question-source#17") (Option.map Ids.Turn_ref.to_string feedback.af_source_turn_ref);
  Alcotest.(check bool) "a later selected question does not replace opened original diagnostics" true
    (Option.exists (Ask.same_origin origin) (current_ask_origin state));
  let json = Ask.origin_to_json (Ask.origin_of_feedback feedback) in
  Alcotest.(check string) "source telemetry belongs to the original question"
    original.ar_id Yojson.Safe.Util.(json |> member "ask_id" |> to_string);
  let Workspace_authority generation = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation+1);
  Alcotest.(check bool) "previous workspace cannot retain visible source diagnostics" true
    (current_ask_origin state=None);
  Alcotest.(check bool) "previous receipt cannot supply a new workspace source" true
    (current_ask_answer_feedback state=None);
  let unknown = Ask.origin_of_row {later with ar_source_turn_ref=None} in
  state.workspace_identity <- Workspace_identity_unread;
  toggle_ask_origin state unknown;
  Alcotest.(check bool) "unconfirmed workspace cannot open source from an old row" true
    (current_ask_origin state=None);
  state.workspace_identity <- Workspace_identity_match;
  toggle_ask_origin state unknown;
  let unknown = current_ask_origin state |> Option.get |> Ask.origin_to_json in
  Alcotest.(check bool) "unknown source is never filled from earlier diagnostics" true
    Yojson.Safe.Util.((unknown |> member "source_turn_ref") = `Null)

let test_answer_receipt_has_one_original_submission_owner () =
  let open Masc_tui_types in
  let module Decode = Masc.Tui_decode_asks in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
    ~port:0 ~refresh_interval:0. () in
  state.workspace_identity <- Workspace_identity_match;
  state.server_identity <- Some (identity "/workspace/a");
  let submission ask_id : ask_submission =
    { as_request = ref (); as_authority = state.workspace_authority;
      as_keeper_name = "reader"; as_ask_id = ask_id; as_source_turn_ref = None; as_answered_label = "reader: choice" } in
  let first = submission "first" in
  begin_ask_submission_state ~submission:first state;
  let receipt = Ok (Decode.Ask_answer_recorded Decode.Ask_wake_stored) in
  let feedback = match retain_ask_answer_feedback state first receipt with
    | Some feedback -> feedback
    | None -> Alcotest.fail "current original receipt was not retained" in
  state.asks_error <- Some "reread failed";
  state.asks_snapshot <- None;
  finish_http_refresh_state state;
  Alcotest.(check bool) "ordinary refresh and failed reread preserve the receipt" true
    (current_ask_answer_feedback state = Some feedback);
  Alcotest.(check bool) "terminal duplicate cannot replace the earlier POST receipt" true
    (Option.is_none (retain_ask_answer_feedback state first (Error "later observation failed")));
  let second = submission "second" in
  begin_ask_submission_state ~submission:second state;
  let next = match retain_ask_answer_feedback state second (Error "recording unknown") with
    | Some next -> next | None -> Alcotest.fail "new original submission must own its receipt" in
  Alcotest.(check bool) "an older request cannot overwrite the newer receipt" true
    (Option.is_none (retain_ask_answer_feedback state first receipt));
  Alcotest.(check bool) "newer unconfirmed result remains unconfirmed" true
    (current_ask_answer_feedback state = Some next);
  let Workspace_authority generation = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation + 1);
  Alcotest.(check bool) "old workspace receipt is hidden" true
    (Option.is_none (current_ask_answer_feedback state));
  Alcotest.(check bool) "old submission cannot enter a replacement workspace" true
    (Option.is_none (retain_ask_answer_feedback state second receipt));
  let unread = submission "unread" in
  begin_ask_submission_state ~submission:unread state;
  state.workspace_identity <- Workspace_identity_unread;
  Alcotest.(check bool) "unconfirmed workspace grants no receipt admission" true
    (Option.is_none (retain_ask_answer_feedback state unread receipt))

let test_answer_followup_retains_current_source_observations () =
  let open Masc_tui_types in
  let module Decode = Masc.Tui_decode_asks in
  let state = create_state ~workspace:"followup" ~local_base_path:"/workspace/followup"
      ~port:0 ~refresh_interval:0. () in
  state.workspace_identity <- Workspace_identity_match;
  state.server_identity <- Some (identity state.local_base_path);
  let submission name : ask_submission = {as_request=ref ();as_authority=state.workspace_authority;
      as_keeper_name="alpha";as_ask_id=name;as_source_turn_ref=None;as_answered_label="choice"} in
  let first = submission "original" in
  begin_ask_submission_state ~submission:first state;
  ignore (retain_ask_answer_feedback state first (Ok (Decode.Ask_answer_recorded Decode.Ask_wake_stored)));
  let begin_read () = match begin_ask_followup_read state with
    | Some value -> value | None -> Alcotest.fail "confirmed original answer did not own a read" in
  let request, owner = begin_read () in
  Alcotest.(check bool) "cadence shares one inflight observation" true
    (Option.is_none (begin_ask_followup_read state));
  let observed : Decode.ask_followup = {af_answered_at=200.;af_stimulus_id="original-source";
    af_turn_started_at=Some 201.;af_turn_finished_at=None;af_queue_settled_at=None;
    af_queue_cancelled_at=None;af_evidence_complete=true;
    af_tool_actions=Decode.Ask_tools_observed {at_count=1;at_first_recorded_at=Some 202.;
      at_latest=Some {ata_execution_id="original-tool";ata_physical_execution_id="original-call";ata_trace_id="original-trace";
        ata_keeper_turn_id=17;ata_tool="Read";ata_recorded_at=202.};at_evidence_current=true};
    af_linked_task=Decode.Ask_task_observed {akt_task_id="task-original";akt_location=Ask_task_backlog;
      akt_status=Masc_domain.Todo;akt_observed_at=203.;akt_evidence_current=true}} in
  ignore (take_ask_followup state request owner (Ok observed));
  Alcotest.(check bool) "original observation survives without releasing the POST gate" true
    (current_ask_followup state=Some observed && state.ask_submit_inflight);
  Alcotest.(check bool) "duplicate observation cannot replace accepted facts" true
    (Option.is_none (take_ask_followup state request owner (Error "duplicate")));
  let request, owner = begin_read () in
  ignore (take_ask_followup state request owner (Error "read unavailable"));
  Alcotest.(check bool) "failed reread retains prior source facts and explicit error" true
    (Option.exists (fun value -> value.Decode.af_turn_started_at=Some 201.
       && match value.af_linked_task with
          | Decode.Ask_task_observed {akt_status=Masc_domain.Todo;akt_evidence_current=false;_} -> true
          | Ask_task_observed _ | Ask_task_unlinked | Ask_task_missing _ | Ask_task_unavailable _ -> false)
       (current_ask_followup state) && Option.is_some state.ask_followup_error);
  let request, owner = begin_read () in
  ignore (take_ask_followup state request owner
    (Ok {observed with af_turn_started_at=None;af_evidence_complete=false;
      af_tool_actions=Decode.Ask_tools_unavailable;af_linked_task=Decode.Ask_task_unavailable "task-original"}));
  Alcotest.(check bool) "missing observations cannot undo a positive fact" true
    (Option.exists (fun value -> value.Decode.af_turn_started_at=Some 201.
       && not value.af_evidence_complete
       && (match value.af_tool_actions with
          | Decode.Ask_tools_observed {at_count=1;at_evidence_current=false;_} -> true
          | Decode.Ask_tools_observed _ | Decode.Ask_tools_unavailable -> false)
       && (match value.af_linked_task with
          | Decode.Ask_task_observed {akt_evidence_current=false;_} -> true
          | Ask_task_observed _ | Ask_task_unlinked | Ask_task_missing _ | Ask_task_unavailable _ -> false))
      (current_ask_followup state));
  let request, owner = begin_read () in
  let changed = {observed with af_linked_task=Decode.Ask_task_observed
    {akt_task_id="task-original";akt_location=Ask_task_archive;akt_status=Masc_domain.Done
      {assignee="replacement-worker";completed_at="2026-10-17T00:00:00Z";notes=None};
     akt_observed_at=204.;akt_evidence_current=true}} in
  ignore (take_ask_followup state request owner (Ok changed));
  Alcotest.(check bool) "fresh canonical status replaces stale observation" true
    (current_ask_followup state=Some changed && Option.is_none state.ask_followup_error);
  let request, owner = begin_read () in
  ignore (take_ask_followup state request owner
    (Ok {changed with af_linked_task=Decode.Ask_task_missing "task-original"}));
  Alcotest.(check bool) "missing lookup retains last status as stale" true
    (Option.exists (fun value -> match value.Decode.af_linked_task with
      | Decode.Ask_task_observed {akt_status=Masc_domain.Done _;akt_evidence_current=false;_} -> true
      | Ask_task_observed _ | Ask_task_unlinked | Ask_task_missing _ | Ask_task_unavailable _ -> false)
      (current_ask_followup state));
  List.iter (fun foreign ->
    let request, owner = begin_read () in
    Alcotest.(check bool) "changed original identity is refused" true
      (match take_ask_followup state request owner (Ok foreign) with
       | Some (Error _) -> true | Some (Ok _) | None -> false))
    [{observed with af_linked_task=Decode.Ask_task_missing "task-other"};
     {observed with af_linked_task=Decode.Ask_task_unlinked};
     {observed with af_stimulus_id="another-source"};{observed with af_answered_at=300.}];
  let request, owner = begin_read () in
  ignore (take_ask_followup state request owner (Ok observed));
  Alcotest.(check bool) "new valid observation may return to an earlier phase" true
    (current_ask_followup state=Some observed);
  let retired, old_owner = begin_read () in
  let second = submission "new-answer" in
  begin_ask_submission_state ~submission:second state;
  Alcotest.(check bool) "pending newer submission cannot read the older feedback" true
    (Option.is_none (begin_ask_followup_read state));
  ignore (retain_ask_answer_feedback state second (Ok (Decode.Ask_answer_recorded Decode.Ask_wake_stored)));
  let current, owner = begin_read () in
  Alcotest.(check bool) "old reply cannot settle the successor's read" true
    (Option.is_none (take_ask_followup state retired old_owner (Ok observed))
     && Snapshot_read.in_flight state.ask_followup_read);
  state.workspace_identity <- Workspace_identity_match_unconfirmed "probe unavailable";
  Alcotest.(check bool) "uncertainty rejects publication and settles its original reader" true
    (Option.is_none (take_ask_followup state current owner (Ok observed))
     && not (Snapshot_read.in_flight state.ask_followup_read)
     && Option.is_none (current_ask_followup state))

let test_datasets_settle_independently_under_original_request () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"datasets" ~local_base_path:"/workspace/datasets"
      ~port:0 ~refresh_interval:0. () in
  let observed = identity "/workspace/datasets" in
  state.server_identity <- Some observed;
  state.workspace_identity <- Workspace_identity_match;
  let authority = state.workspace_authority in
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket ~started_ns:0L;
  let needs = {nothing with needs_board=true;needs_planning=true;needs_system_logs=true} in
  let reads, original = Surface_read_order.dispatch ~kind:Surface_read_order.Full
      ~needs ~started_ns:0L state.http_surface_reads in
  state.http_surface_reads <- reads;
  let take request source = take_early_surface_read state ~ticket ~authority
      ~identity:observed ~request ~source in
  Alcotest.(check bool) "ready Planning settles while Board and logs remain pending" true
    (take original Surface_read_order.Planning
     && Surface_read_order.pending ~needs state.http_surface_reads
        = [Surface_read_order.Board;Surface_read_order.System_logs]
     && state.http_refresh_started_ns = Some 0L);
  Alcotest.(check bool) "a second result cannot replace that settlement" false
    (take original Surface_read_order.Planning);
  let navigation_needs = {nothing with needs_board=true} in
  let reads, navigation = Surface_read_order.dispatch ~kind:Surface_read_order.Navigation
      ~needs:navigation_needs ~started_ns:1L state.http_surface_reads in
  state.http_surface_reads <- reads;
  Alcotest.(check bool) "navigation owns Board without retiring the original logs" true
    (not (take original Surface_read_order.Board)
     && take navigation Surface_read_order.Board
     && Surface_read_order.navigation_active state.http_surface_reads navigation
     && Surface_read_order.pending ~needs state.http_surface_reads = [Surface_read_order.System_logs]);
  (* Error is an owned settlement too: a later success cannot overwrite it.
     Payload application retains the existing dataset-specific error policy. *)
  Alcotest.(check bool) "the original failed logs read settles once" true
    (take original Surface_read_order.System_logs
     && not (take original Surface_read_order.System_logs));
  let reads, remaining = Surface_read_order.take state.http_surface_reads original in
  state.http_surface_reads <- reads;
  Alcotest.(check bool) "final bundle has no dataset left to apply again" true
    (remaining=[] && Surface_read_order.navigation_active state.http_surface_reads navigation);
  state.http_surface_reads <- Surface_read_order.finish state.http_surface_reads navigation;
  Alcotest.(check bool) "only its own collector completion releases navigation" false
    (Surface_read_order.navigation_in_flight state.http_surface_reads)

let test_dataset_admission_rejects_retired_workspace_and_refresh () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"datasets" ~local_base_path:"/workspace/datasets"
      ~port:0 ~refresh_interval:0. () in
  let observed = identity "/workspace/datasets" in
  state.server_identity <- Some observed;
  state.workspace_identity <- Workspace_identity_match;
  let authority = state.workspace_authority in
  let ticket = state.http_refresh_order in
  let needs = {nothing with needs_planning=true} in
  let reads, request = Surface_read_order.dispatch ~kind:Surface_read_order.Navigation
      ~needs ~started_ns:0L state.http_surface_reads in
  state.http_surface_reads <- reads;
  let take identity = take_early_surface_read state ~ticket ~authority ~identity
      ~request ~source:Surface_read_order.Planning in
  Alcotest.(check bool) "foreign response leaves the real source pending" true
    (not (take (identity "/workspace/foreign"))
     && Surface_read_order.pending ~needs state.http_surface_reads=[Surface_read_order.Planning]);
  state.workspace_identity <- Workspace_identity_match_unconfirmed "probe unavailable";
  Alcotest.(check bool) "unconfirmed authority cannot admit data" false (take observed);
  state.workspace_identity <- Workspace_identity_match;
  state.http_refresh_order <- Http_refresh_order.dispatch ticket;
  Alcotest.(check bool) "an older refresh cannot consume a current source" false (take observed);
  state.http_refresh_order <- ticket;
  Alcotest.(check bool) "navigation can settle with no enclosing full refresh" true
    (state.http_refresh_started_ns=None && take observed);
  let reads, successor = Surface_read_order.dispatch ~kind:Surface_read_order.Navigation
      ~needs ~started_ns:1L state.http_surface_reads in
  state.http_surface_reads <- reads;
  suspend_workspace_readings state;
  Alcotest.(check bool) "workspace retirement rejects the original authority" false
    (take_early_surface_read state ~ticket ~authority ~identity:observed
       ~request:successor ~source:Surface_read_order.Planning)

let with_response_decode_pool f =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let previous = Domain_pool_ref.get () in
    Eio.Switch.on_release sw (fun () -> match previous with
      | Some pool -> Domain_pool_ref.set pool
      | None -> Domain_pool_ref.clear_for_tests ());
    let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
    Domain_pool_ref.set pool;
    f ()))

let test_response_decode_keeps_cache_and_typed_results () = with_response_decode_pool (fun () ->
  let caller = Domain.self () in
  let off_domain = Atomic.make true and parsed = Atomic.make 0 in
  let document = `Assoc ["version", `String "decode-worker";
    "paths", `Assoc ["effective_base_path", `String "/workspace/decode";
      "effective_masc_root", `String "/workspace/decode/.masc"];
    "startup", `Assoc ["state_ready", `Bool true]] in
  let reads = Masc_tui_kept_reads.create () in
  let read status =
    Alcotest.(check bool) "HTTP and cache callbacks stay on their caller" true (Domain.self ()=caller);
    Masc_tui_kept_reads.read reads ~address:"owned-health"
      ~send:(fun headers ->
        if status=304 then Alcotest.(check (option string)) "conditional read retains its entity tag"
          (Some "health-v1") (List.assoc_opt "If-None-Match" headers);
        Ok {Masc_tui_kept_reads.status; headers=["ETag","health-v1"];
          body=(if status=304 then "" else Yojson.Safe.to_string document)})
      ~decode:(fun response -> Masc_tui_response_decode.run ~name:"test.http.decode_wait" (fun () ->
        Atomic.incr parsed;
        Atomic.set off_domain (Atomic.get off_domain && Domain.self ()<>caller);
        Tui_decode.decode_json_response_body ~allow_empty:false
          ~status_code:response.status ~body:response.body)) in
  let decode = function
    | Error detail -> Alcotest.fail detail
    | Ok json -> Masc_tui_response_decode.run ~name:"test.identity.decode_wait" (fun () ->
        Atomic.set off_domain (Atomic.get off_domain && Domain.self ()<>caller);
        Tui_decode.decode_server_identity json) in
  let first = decode (read 200) in
  let unchanged = decode (read 304) in
  Alcotest.(check bool) "raw and typed interpretation run on the installed CPU worker" true
    (Atomic.get off_domain);
  Alcotest.(check int) "304 reuses parsed JSON without another raw decode" 1 (Atomic.get parsed);
  Alcotest.(check bool) "typed identity survives conditional reuse unchanged" true
    (first=unchanged && match first with
      | Ok value -> value.Tui_decode.sid_base_path="/workspace/decode"
      | Error _ -> false))

let test_decode_completion_cannot_consume_new_navigation () = with_response_decode_pool (fun () ->
  let open Masc_tui_types in
  let state = create_state ~workspace:"decode" ~local_base_path:"/workspace/decode"
      ~port:0 ~refresh_interval:0. () in
  let observed = identity "/workspace/decode" in
  state.server_identity <- Some observed;
  state.workspace_identity <- Workspace_identity_match;
  let authority = state.workspace_authority in
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket ~started_ns:0L;
  let needs = {nothing with needs_overview_goals=true} in
  let reads, original = Surface_read_order.dispatch ~kind:Surface_read_order.Full
      ~needs ~started_ns:0L state.http_surface_reads in
  state.http_surface_reads <- reads;
  let started, start = Eio.Promise.create () and released, release = Eio.Promise.create () in
  let successor = ref None and caller = Domain.self () in
  Eio.Fiber.both
    (fun () ->
      let result = Masc_tui_response_decode.run ~name:"test.goals.decode_wait" (fun () ->
        Eio.Promise.resolve start (Domain.self ()<>caller);
        Eio.Promise.await released;
        Tui_decode.decode_overview_goals (`Assoc ["tree", `List []])) in
      Alcotest.(check bool) "the original immutable response finishes normally" true (result=Ok []);
      Alcotest.(check bool) "late decoding cannot consume a successor's dataset" false
        (take_early_surface_read state ~ticket ~authority ~identity:observed
          ~request:original ~source:Surface_read_order.Overview_goals))
    (fun () ->
      Alcotest.(check bool) "UI can navigate while the actual worker is waiting" true
        (Eio.Promise.await started);
      let reads, request = Surface_read_order.dispatch ~kind:Surface_read_order.Navigation
          ~needs ~started_ns:1L state.http_surface_reads in
      state.http_surface_reads <- reads;
      successor := Some request;
      Eio.Promise.resolve release ());
  let successor = match !successor with Some request -> request
    | None -> Alcotest.fail "navigation was not dispatched" in
  Alcotest.(check bool) "the new dataset retains its original admission authority" true
    (take_early_surface_read state ~ticket ~authority ~identity:observed
      ~request:successor ~source:Surface_read_order.Overview_goals))

exception Response_decode_failed

let test_response_decode_preserves_nested_failures () = with_response_decode_pool (fun () ->
  let malformed = "{" in
  let expected = Tui_decode.decode_json_response_body ~allow_empty:false ~status_code:200 ~body:malformed in
  let actual = Masc_tui_response_decode.run ~name:"test.invalid.decode_wait" (fun () ->
    Tui_decode.decode_json_response_body ~allow_empty:false ~status_code:200 ~body:malformed) in
  Alcotest.(check bool) "malformed JSON keeps its original error" true
    (Result.is_error expected && expected=actual);
  let outer, inner = Masc_tui_response_decode.run ~name:"test.outer.decode_wait" (fun () ->
    let outer = Domain.self () in
    outer, Masc_tui_response_decode.run ~name:"test.inner.decode_wait" Domain.self) in
  Alcotest.(check bool) "nested decoding stays on the original single worker" true (outer=inner);
  let attempts = Atomic.make 0 in
  (match Masc_tui_response_decode.run ~name:"test.raised.decode_wait" (fun () ->
      Atomic.incr attempts; raise Response_decode_failed) with
   | _ -> Alcotest.fail "decoder exception was swallowed"
   | exception Response_decode_failed -> ());
  Alcotest.(check int) "decoder failure is not replayed" 1 (Atomic.get attempts))

let test_response_decode_without_runtime_stays_synchronous () =
  let previous = Domain_pool_ref.get () in
  Fun.protect ~finally:(fun () -> match previous with
    | Some pool -> Domain_pool_ref.set pool | None -> Domain_pool_ref.clear_for_tests ()) (fun () ->
    Domain_pool_ref.clear_for_tests ();
    let caller = Domain.self () in
    Alcotest.(check bool) "no-pool non-Eio callers retain their synchronous API" true
      (Masc_tui_response_decode.run ~name:"test.sync.decode_wait" Domain.self=caller))

let creation_state () =
  let state = Masc_tui_types.create_state ~workspace:"creation"
      ~local_base_path:"/workspace/creation" ~port:0 ~refresh_interval:0. () in
  state.workspace_identity <- Masc_tui_types.Workspace_identity_match;
  state.server_identity <- Some (identity "/workspace/creation");
  state

let creation_request state name declaration =
  let open Masc_tui_types in
  state.keeper_creation_draft <- Some declaration;
  state.keeper_creation_draft_owner <- ref ();
  match begin_keeper_creation state ~keeper_name:name ~declaration
      ~return_to:Keeper_chat_return_home ~started_ns:0L with
  | Ok request -> request
  | Error detail -> Alcotest.fail detail

let test_creation_interleaving_preserves_new_draft_and_focus () =
  let open Masc_tui_types in
  let state = creation_state () in
  let first = creation_request state "first" "first declaration" in
  Alcotest.(check bool) "one pending mutation per target" true
    (Result.is_error (begin_keeper_creation state ~keeper_name:"first"
       ~declaration:"duplicate" ~return_to:Keeper_chat_return_home ~started_ns:1L));
  let second = creation_request state "second" "second declaration" in
  Alcotest.(check bool) "first POST phase is admitted" true
    (apply_keeper_creation_status state first Creation_posting);
  Alcotest.(check bool) "first receipt is retained" true
    (apply_keeper_creation_status state first (Creation_finished Creation_created));
  Alcotest.(check bool) "earlier success cannot clear a newly edited declaration" false
    (clear_created_keeper_draft state first);
  Alcotest.(check (option string)) "later declaration remains editable"
    (Some "second declaration") state.keeper_creation_draft;
  Alcotest.(check bool) "earlier receipt cannot consume successor focus" false
    (take_keeper_creation_focus state first);
  Alcotest.(check bool) "late progress cannot reopen completed creation" false
    (apply_keeper_creation_status state first Creation_posting);
  Alcotest.(check bool) "successor receipt is admitted" true
    (apply_keeper_creation_status state second (Creation_finished Creation_created));
  Alcotest.(check bool) "successor owns its focus" true
    (take_keeper_creation_focus state second);
  Alcotest.(check bool) "confirmed successor clears only its own draft" true
    (clear_created_keeper_draft state second);
  Alcotest.(check bool) "duplicate receipt cannot apply twice" false
    (apply_keeper_creation_status state second (Creation_finished Creation_created))

let test_creation_receipt_retains_original_scope_after_withdrawal () =
  let open Masc_tui_types in
  let state = creation_state () in
  let original = creation_request state "same-name" "original declaration" in
  ignore (apply_keeper_creation_status state original Creation_posting);
  suspend_workspace_readings state;
  Alcotest.(check bool) "read retirement does not consume the operation receipt" true
    (apply_keeper_creation_status state original
       (Creation_finished (Creation_unconfirmed "interrupted after POST began")));
  let Workspace_authority epoch = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (epoch + 1);
  state.server_identity <- Some (identity "/workspace/other");
  let successor = creation_request state "same-name" "other workspace declaration" in
  (* Even an A -> B -> A path match cannot authorize the old request. *)
  state.workspace_authority <- Workspace_authority (epoch + 2);
  state.server_identity <- Some original.kcr_workspace;
  Alcotest.(check bool) "returning to a path does not restore original authority" false
    (keeper_creation_origin_current state original);
  Alcotest.(check bool) "old receipt cannot clear another declaration" false
    (clear_created_keeper_draft state original);
  Alcotest.(check bool) "old receipt cannot consume successor focus" false
    (take_keeper_creation_focus state original);
  Alcotest.(check bool) "successor remains pending under its own ticket" true
    (List.exists (fun attempt -> attempt.kca_request.kcr_token == successor.kcr_token
       && attempt.kca_status = Creation_checking) state.keeper_creations);
  Alcotest.(check bool) "uncertain original retains its declaration and scope" true
    (List.exists (fun attempt -> attempt.kca_request.kcr_token == original.kcr_token
       && attempt.kca_declaration = Some "original declaration"
       && attempt.kca_status = Creation_finished (Creation_unconfirmed "interrupted after POST began"))
       state.keeper_creations)

let test_creation_unknown_requires_explicit_create_only_retry () =
  let open Masc_tui_types in
  let state = creation_state () in
  let unsent = creation_request state "preflight" "unsent declaration" in
  ignore (apply_keeper_creation_status state unsent
    (Creation_finished (Creation_not_sent "identity unavailable")));
  Alcotest.(check bool) "unsent request cannot clear its draft" false
    (clear_created_keeper_draft state unsent);
  let original = creation_request state "retry" "retained declaration" in
  ignore (apply_keeper_creation_status state original Creation_posting);
  state.keeper_creation_focus <- None;
  ignore (apply_keeper_creation_status state original
    (Creation_finished (Creation_unconfirmed "response lost")));
  Alcotest.(check bool) "input detaches late auto-navigation" false
    (take_keeper_creation_focus state original);
  Alcotest.(check (option string)) "unconfirmed declaration can reopen in editor"
    (Some "retained declaration") (keeper_creation_recovery_draft state);
  Alcotest.(check bool) "unconfirmed is not retroactively called successful" false
    (apply_keeper_creation_status state original (Creation_finished Creation_created));
  let retry = creation_request state "retry" "explicitly edited declaration" in
  ignore (apply_keeper_creation_status state retry (Creation_finished Creation_created));
  Alcotest.(check bool) "explicit success releases only resolved target retry bodies" true
    (List.for_all (fun attempt ->
       if String.equal attempt.kca_request.kcr_keeper "retry"
       then Option.is_none attempt.kca_declaration else Option.is_some attempt.kca_declaration)
       state.keeper_creations);
  Alcotest.(check bool) "original uncertainty receipt remains" true
    (List.exists (fun attempt -> attempt.kca_request.kcr_token == original.kcr_token
       && attempt.kca_status = Creation_finished (Creation_unconfirmed "response lost"))
       state.keeper_creations)

let test_creation_receipt_survives_full_notification_queue_cancel () =
  let open Masc_tui_types in
  let exception Creation_test_cancelled in
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let state = creation_state () in
    let request = creation_request state "queued" "original declaration" in
    let notifications = Eio.Stream.create 1 in
    Eio.Stream.add notifications ();
    let entered, enter = Eio.Promise.create () in
    let published, publish = Eio.Promise.create () in
    let finished, finish = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      try Eio.Cancel.sub (fun context ->
        Eio.Promise.resolve enter context;
        ignore (publish_keeper_creation_status request ~observed_ns:1L Creation_posting);
        ignore (publish_keeper_creation_status request ~observed_ns:2L
          (Creation_finished Creation_created));
        Eio.Promise.resolve publish ();
        (* Same bounded notification boundary as the creation worker. It must
           remain cancellable after its immutable terminal result is published. *)
        Eio.Stream.add notifications ())
      with Eio.Cancel.Cancelled Creation_test_cancelled -> Eio.Promise.resolve finish ());
    let context = Eio.Promise.await entered in
    Eio.Promise.await published;
    Eio.Cancel.cancel context Creation_test_cancelled;
    Eio.Promise.await finished;
    match pending_keeper_creation_receipt state with
    | None -> Alcotest.fail "cancellation lost the original mutation receipt"
    | Some (owner, status, ready_at_ns) ->
      Alcotest.(check bool) "receipt keeps the original owner" true
        (owner.kcr_token == request.kcr_token);
      Alcotest.(check int64) "receipt uses publication time" 2L ready_at_ns;
      Alcotest.(check bool) "cancellation cannot downgrade a confirmed receipt" false
        (publish_keeper_creation_status request ~observed_ns:3L
          (Creation_finished (Creation_unconfirmed "notification cancelled")));
      Alcotest.(check bool) "UI can admit the original receipt without its notification" true
        (apply_keeper_creation_status state owner status);
      Alcotest.(check bool) "terminal pending slot is retired" true
        (Option.is_none (pending_keeper_creation_receipt state));
      Alcotest.(check bool) "only the confirmed original form is cleared" true
        (clear_created_keeper_draft state owner)))

let () =
  Alcotest.run "tui_server_identity_refresh"
    [ ( "server-identity-refresh"
      , [ Alcotest.test_case "creation cancellation retains receipt when notification queue is full" `Quick
            test_creation_receipt_survives_full_notification_queue_cancel
        ; Alcotest.test_case "creation interleaving preserves successor draft and focus" `Quick
            test_creation_interleaving_preserves_new_draft_and_focus
        ; Alcotest.test_case "creation receipts retain original scope after withdrawal" `Quick
            test_creation_receipt_retains_original_scope_after_withdrawal
        ; Alcotest.test_case "creation uncertainty requires explicit retry" `Quick
            test_creation_unknown_requires_explicit_create_only_retry
        ; Alcotest.test_case "response decode preserves cache and typed results" `Quick
            test_response_decode_keeps_cache_and_typed_results
        ; Alcotest.test_case "decode completion cannot consume new navigation" `Quick
            test_decode_completion_cannot_consume_new_navigation
        ; Alcotest.test_case "response decode preserves nested failures" `Quick
            test_response_decode_preserves_nested_failures
        ; Alcotest.test_case "response decode without runtime stays synchronous" `Quick
            test_response_decode_without_runtime_stays_synchronous
        ; Alcotest.test_case "datasets settle independently under original request ownership" `Quick
            test_datasets_settle_independently_under_original_request
        ; Alcotest.test_case "dataset admission rejects retired workspace and refresh" `Quick
            test_dataset_admission_rejects_retired_workspace_and_refresh
        ; Alcotest.test_case "answer followup retains exact current source observations" `Quick
            test_answer_followup_retains_current_source_observations
        ; Alcotest.test_case "initial probe requires current cold workspace" `Quick
            test_initial_probe_requires_current_cold_workspace
        ; Alcotest.test_case "initial probe cannot revive a retired refresh" `Quick
            test_initial_probe_rejects_retired_refresh
        ; Alcotest.test_case "roster arrives before unrelated readers and settles once" `Quick
            test_early_roster_settles_before_slow_siblings_once
        ; Alcotest.test_case "question origin survives answer and workspace change" `Quick
            test_question_origin_survives_answer_and_workspace_change
        ; Alcotest.test_case "answer receipt has one original submission owner" `Quick
            test_answer_receipt_has_one_original_submission_owner
        ; Alcotest.test_case "local and HTTP sources progress independently" `Quick
            test_local_read_and_http_sources_progress_independently
        ; Alcotest.test_case "local read refuses retired epochs and foreign paths" `Quick
            test_local_read_refuses_retired_epoch_and_wrong_path
        ; Alcotest.test_case "local read failure releases its slot for retry" `Quick
            test_local_read_failure_settles_and_can_be_retried
        ; Alcotest.test_case "metadata admits input before work completes" `Quick
            test_keeper_metadata_admits_input_before_work_completes
        ; Alcotest.test_case "local source failures remain independent" `Quick
            test_local_source_failures_are_independent
        ; Alcotest.test_case "local refresh burst keeps active read and one followup" `Quick
            test_local_refresh_burst_keeps_active_read_and_one_followup
        ; Alcotest.test_case "failure preserves followup and withdrawal retires it" `Quick
            test_failed_read_keeps_followup_and_withdrawal_retires_it
        ; Alcotest.test_case "concurrent creations retain individual refresh coverage" `Quick
            test_concurrent_created_keepers_retain_individual_refresh_coverage
        ; Alcotest.test_case "archive cache does not cross equal-stat source files" `Quick
            test_archive_cache_does_not_cross_equal_stat_files
        ; Alcotest.test_case "created Keeper waits for owned metadata without Work" `Quick
            test_created_keeper_waits_for_owned_metadata_without_work
        ; Alcotest.test_case "fresh metadata confirms deletion without detail retargeting" `Quick
            test_deleted_keeper_reconciles_after_fresh_metadata
        ; Alcotest.test_case "cancelled local cache read releases the source for follow-up" `Quick
            test_local_cache_cancel_releases_source_for_followup
        ; Alcotest.test_case "context refuses queued prior-trace results" `Quick
            test_live_context_refuses_changed_trace_before_reconciliation
        ; Alcotest.test_case "chat target owns context independently of roster cursor" `Quick
            test_live_context_chat_target_is_independent_of_roster_cursor
        ; Alcotest.test_case "context suspension cancels and retires the source" `Quick
            test_live_context_suspension_cancels_and_retires_same_path_read
        ; Alcotest.test_case "local tickets cannot cross sources or suspension" `Quick
            test_local_source_tickets_cannot_cross_or_survive_suspension
        ; Alcotest.test_case "early roster preserves source and workspace ownership" `Quick
            test_early_roster_preserves_read_ownership
        ; Alcotest.test_case "refresh observations retain independent source outcomes" `Quick
            test_refresh_progress_tracks_independent_sources_and_interruption
        ; Alcotest.test_case "refresh observations reject superseded source authority" `Quick
            test_refresh_progress_rejects_old_request_and_workspace
        ; Alcotest.test_case "early questions settle once without granting authority" `Quick
            test_early_asks_apply_once_without_granting_authority
        ; Alcotest.test_case "unadmitted cold questions retain their source owner" `Quick
            test_unadmitted_cold_asks_defer_without_consuming_the_read
        ; Alcotest.test_case "early questions reject foreign stale and retired readings" `Quick
            test_early_asks_reject_foreign_stale_and_retired_authority
        ; Alcotest.test_case "answer submission retires pre-answer listings" `Quick
            test_question_answer_retires_pre_answer_reads
        ; Alcotest.test_case "question listings respect supersession and workspace suspension" `Quick
            test_question_read_supersession_and_workspace_suspension
        ; Alcotest.test_case "overview rejects superseded refresh observations" `Quick
            test_overview_preview_rejects_superseded_reading
        ; Alcotest.test_case "overview preview preserves confirmed state and authority" `Quick
            test_overview_preview_preserves_confirmed_state_and_authority
        ; Alcotest.test_case "overview completion retires previews and late delivery" `Quick
            test_overview_refresh_finish_retires_preview_and_late_delivery
        ; Alcotest.test_case "overview preview refuses foreign and retired authority" `Quick
            test_overview_preview_refuses_foreign_or_retired_authority
        ; Alcotest.test_case "Child retirement preserves a running full audit" `Quick
            test_child_read_epoch_retains_running_audit
        ; Alcotest.test_case "native observations retire without losing queued audit" `Quick
            test_native_task_read_epoch_retirement
        ; Alcotest.test_case "unsent resource and log intents survive reconfirmation" `Quick
            test_unsent_resource_and_log_intents_survive_reconfirmation
        ; Alcotest.test_case "effect observations resume without repeating effects" `Quick
            test_effect_observations_resume_without_repeating_effects
        ; Alcotest.test_case "account read intents survive repeated suspension" `Quick
            test_account_read_intents_survive_repeated_suspension
        ; Alcotest.test_case "nested reader intents survive repeated suspension" `Quick
            test_pending_nested_reader_intents_survive_repeated_suspension
        ; Alcotest.test_case "task receipts wait for identity and roster" `Quick
            test_task_receipts_wait_for_identity_and_roster
        ; Alcotest.test_case "nested read owners retire without losing selection" `Quick
            test_nested_read_owners_retire_without_losing_selection
        ; Alcotest.test_case "discarded bundle retires readings before reconfirming A" `Quick
            test_discarded_bundle_retires_readings_before_reconfirming_a
        ; Alcotest.test_case "preset selection waits without an unconfirmed read" `Quick
            test_preset_selection_waits_without_owning_an_unconfirmed_read
        ; Alcotest.test_case "operation receipt outlives queued follow-up read" `Quick
            test_operation_receipt_outlives_queued_followup_read
        ; Alcotest.test_case "unknown voice save read retirement" `Quick
            test_unknown_voice_save_read_retirement
        ; Alcotest.test_case "detail focus waits for authoritative roster" `Quick
            test_detail_focus_waits_for_authoritative_roster
        ; Alcotest.test_case "same base and different MASC root retain separate inputs" `Quick
            test_same_base_with_different_masc_root_cannot_restore_inputs
        ; Alcotest.test_case "request authority requires complete current identity" `Quick
            test_request_authority_requires_complete_current_identity
        ; Alcotest.test_case "same endpoint replaces A with B" `Quick
            test_same_endpoint_restart_replaces_a_with_b
        ; Alcotest.test_case "failed probe is unread, not stale" `Quick
            test_failed_probe_is_unread_not_stale
        ; Alcotest.test_case "canonical aliases match" `Quick
            test_workspace_identity_matches_canonical_paths
        ; Alcotest.test_case "workspace identity compares the masc root" `Quick
            test_workspace_identity_compares_the_masc_root
        ; Alcotest.test_case "mismatch preserves both paths" `Quick
            test_workspace_identity_mismatch_keeps_both_paths
        ; Alcotest.test_case "Broadcast retry uses verified workspace store" `Quick
            test_broadcast_retry_scope_follows_verified_workspace
        ; Alcotest.test_case "detail intents wait for comparable identity" `Quick
            test_detail_intents_wait_for_comparable_identity
        ; Alcotest.test_case "local rows are unread until read" `Quick
            test_local_rows_are_unread_until_the_workspace_is_read
        ; Alcotest.test_case "an unread after a match keeps it unconfirmed" `Quick
            test_unread_after_a_match_keeps_it_unconfirmed
        ; Alcotest.test_case "writes wait for a confirmed identity" `Quick
            test_writes_wait_for_a_confirmed_identity
        ; Alcotest.test_case "a missing path does not hide a mismatch" `Quick
            test_partial_identity_keeps_definite_mismatches
        ; Alcotest.test_case "deletion inventory waits for workspace reconfirmation" `Quick
            test_deletion_inventory_waits_for_reconfirmed_workspace
        ; Alcotest.test_case "uncertainty retires reads while admitted operations survive" `Quick
            test_uncertain_identity_retires_reads_not_admitted_operations
        ; Alcotest.test_case "suspension folds a queued lanes reread into resume" `Quick
            test_suspension_folds_queued_lanes_reread_into_resume
        ] )
    ]
