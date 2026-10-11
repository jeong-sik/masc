open Alcotest

module Gate = Masc.Keeper_tool_approval_gate
module Registry = Masc.Keeper_tool_approval_registry
module Late = Masc.Keeper_late_approval
module Events = Masc.Keeper_chat_events

let keeper = "keeper.one"
let workspace = "/tmp/test-workspace"
let invocation ~tool_use_id =
  Agent_core.Tool_contract.Invocation.create ~tool_use_id ~turn:1
    ~schedule:
      { Agent_core.Tool_contract.planned_index = 0
      ; batch_index = 0
      ; batch_size = 1
      ; execution_mode = Agent_core.Tool_contract.Serial
      }
    ~completion:Agent_core.Tool_contract.Continue_after_success

let request ~tool_call_id ~tool_name ~input =
  { Agent_core.Hooks.prompt =
      { question = "Run it?"; because = "policy: needs an operator's eye" }
  ; invocation = invocation ~tool_use_id:tool_call_id
  ; tool_name
  ; input
  }

let approval_to_string : Agent_core.Hooks.tool_approval -> string = function
  | Agent_core.Hooks.Approved -> "approved"
  | Agent_core.Hooks.Denied -> "denied"
  | Agent_core.Hooks.Timed_out -> "timed_out"

let approval = testable (Fmt.of_to_string approval_to_string) ( = )

let remember_outcome_to_string : Late.remember_outcome -> string = function
  | Late.Remembered { tool_name } -> "remembered:" ^ tool_name
  | Late.No_matching_ask -> "no-matching-ask"

let remember_outcome =
  testable (Fmt.of_to_string remember_outcome_to_string) ( = )

(* The gate and the store the way the server wires them: per-test instances,
   a timeout short enough that "nobody answered" is the outcome of every
   wait. *)
let with_gate f =
  Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let registry = Registry.create () in
      let late = Late.create () in
      let events = Events.create () in
      let gate =
        Gate.create ~redact_text:Fun.id ~registry ~late_approvals:late
          ~publish:(Events.publish events)
          ~clock ~base_path:workspace ~keeper_name:keeper ~timeout_sec:0.05
      in
      f ~clock ~late ~events ~gate)

(* The durability harness (design D2): a store bound to a journal in a
   fresh temp directory, so a test can drop the store and re-bind a new one
   the way a restart does. [bind] is the boot path: synchronous restore
   from the journal before anything consults the store. *)
let with_journal (f :
    clock:'a -> journal:'b -> make:(unit -> Late.t) ->
    remove:(unit -> unit) -> unit) =
  Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let dir =
        Filename.concat
          (Filename.get_temp_dir_name ())
          (Printf.sprintf "masc-late-approval-%d" (Unix.getpid ()))
      in
      if Sys.file_exists dir then
        Array.iter
          (fun name -> Sys.remove (Filename.concat dir name))
          (Sys.readdir dir)
      else Unix.mkdir dir 0o755;
      let journal = Masc.Keeper_gate_path.late_approval_log ~base_path:dir in
      let remove () =
        (* The log path nests under <dir>/.masc/gate/, so the cleanup
           removes whatever accumulated there recursively, not only the
           top level. *)
        let rec clear path =
          if Sys.is_directory path then begin
            Array.iter
              (fun name -> clear (Filename.concat path name))
              (Sys.readdir path);
            Unix.rmdir path
          end
          else if Sys.file_exists path then Sys.remove path
        in
        if Sys.file_exists dir then clear dir
      in
      Fun.protect
        (fun () ->
          let make () =
            let store = Late.create () in
            Late.bind_to_journal ~base_path:dir store;
            store
          in
          f ~clock ~journal ~make ~remove)
        ~finally:remove)

(* Drain what the stream holds without blocking on an empty one. *)
let rec drain events acc =
  match Events.take_nonblocking events with
  | None -> List.rev acc
  | Some event -> drain events (event :: acc)

let event_labels events =
  drain events []
  |> List.filter_map (function
       | Events.Tool_approval_requested { tool_call_id; question; because; _ } ->
           Some
             (Printf.sprintf "requested(%s,%s,%s)" tool_call_id question because)
       | Events.Tool_approval_settled { tool_call_id; outcome } ->
           Some (Printf.sprintf "settled(%s,%s)" tool_call_id outcome)
       | _ -> None)

let edit_input file = `Assoc [ "file_path", `String file ]

(* A gated call nobody answers: the wait times out, the turn is over, and the
   ask's description is what a late answer will be attributed to. *)
let time_out gate ~tool_call_id ~tool_name ~input =
  let answer = gate.Gate.tool_approval (request ~tool_call_id ~tool_name ~input) in
  check approval "the ask times out" Agent_core.Hooks.Timed_out answer

(* ── remembering a late answer ────────────────────────────────────── *)

let test_an_answer_after_the_timeout_is_remembered () =
  with_gate (fun ~clock:_ ~late ~events:_ ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:(edit_input "lib/a.ml");
      (* What handle_keeper_tool_approval does when settle says the wait is
         gone. *)
      check remember_outcome
        "the late answer descends from an ask that really timed out here"
        (Late.Remembered { tool_name = "Edit" })
        (Late.remember_late late ~base_path:workspace ~keeper_name:keeper
           ~tool_call_id:"call-1" ~actor:"mode-operator"
           Registry.Approve ()))

let test_an_answer_that_names_no_ask_is_dropped () =
  with_gate (fun ~clock:_ ~late ~events:_ ~gate:_ ->
      check remember_outcome
        "an answer that cannot be attributed to an ask is not kept"
        Late.No_matching_ask
        (Late.remember_late late ~base_path:workspace ~keeper_name:keeper
           ~tool_call_id:"call-never-held" ~actor:"mode-operator"
           Registry.Approve ()))

let test_an_ask_that_timed_out_long_ago_cannot_be_answered () =
  with_gate (fun ~clock:_ ~late ~events:_ ~gate:_ ->
      Late.note_timed_out late ~now:1000.0 ~base_path:workspace
        ~keeper_name:keeper ~tool_call_id:"call-old" ~tool_name:"Edit"
        ~args:(edit_input "lib/a.ml") ();
      check remember_outcome
        "an ask older than the operator's moment is reaped before it can be \
         answered"
        Late.No_matching_ask
        (Late.remember_late late ~now:(1000.0 +. Late.ttl_sec +. 1.0)
           ~base_path:workspace ~keeper_name:keeper ~tool_call_id:"call-old"
           ~actor:"mode-operator" Registry.Approve ()))

(* ── settling the retried call ────────────────────────────────────── *)

let test_the_identical_retried_call_is_settled_once () =
  with_gate (fun ~clock:_ ~late ~events ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:(edit_input "lib/a.ml");
      ignore
        (Late.remember_late late ~base_path:workspace ~keeper_name:keeper
           ~tool_call_id:"call-1" ~actor:"mode-operator"
           Registry.Approve ());
      ignore (drain events []);
      (* The retry carries a fresh call id; identity is the call itself. *)
      let retry =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-2" ~tool_name:"Edit"
             ~input:(edit_input "lib/a.ml"))
      in
      check approval "the retry is settled by the remembered answer"
        Agent_core.Hooks.Approved retry;
      check (list string)
        "the stream shows the question was raised and settled from memory"
        [ "requested(call-2,Run it?,policy: needs an operator's eye)"
        ; "settled(call-2,remembered_approve)" ]
        (event_labels events);
      let again =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-3" ~tool_name:"Edit"
             ~input:(edit_input "lib/a.ml"))
      in
      check approval "one use consumes it; the next identical call asks again"
        Agent_core.Hooks.Timed_out again)

let test_a_remembered_denial_refuses_the_identical_retry () =
  with_gate (fun ~clock:_ ~late ~events ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:(edit_input "lib/a.ml");
      ignore
        (Late.remember_late late ~base_path:workspace ~keeper_name:keeper
           ~tool_call_id:"call-1" ~actor:"mode-operator"
           Registry.Deny ());
      ignore (drain events []);
      let retry =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-2" ~tool_name:"Edit"
             ~input:(edit_input "lib/a.ml"))
      in
      check approval "a remembered refusal spares asking the same no twice"
        Agent_core.Hooks.Denied retry;
      check (list string) "the refusal is on the stream as remembered"
        [ "requested(call-2,Run it?,policy: needs an operator's eye)"
        ; "settled(call-2,remembered_deny)" ]
        (event_labels events))

let test_a_call_with_different_arguments_is_asked_about () =
  with_gate (fun ~clock:_ ~late ~events:_ ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:(edit_input "lib/a.ml");
      ignore
        (Late.remember_late late ~base_path:workspace ~keeper_name:keeper
           ~tool_call_id:"call-1" ~actor:"mode-operator"
           Registry.Approve ());
      let other =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-2" ~tool_name:"Edit"
             ~input:(edit_input "lib/b.ml"))
      in
      check approval
        "different arguments are a different call; the memory does not reach it"
        Agent_core.Hooks.Timed_out other)

let test_the_same_arguments_in_another_order_are_the_same_call () =
  (* The retried call's arguments are model-regenerated JSON, so identity
     rides the canonical fingerprint rather than byte equality. *)
  with_gate (fun ~clock:_ ~late ~events:_ ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:
          (`Assoc
             [ "file_path", `String "lib/a.ml"; "old_string", `String "x" ]);
      ignore
        (Late.remember_late late ~base_path:workspace ~keeper_name:keeper
           ~tool_call_id:"call-1" ~actor:"mode-operator"
           Registry.Approve ());
      let retry =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-2" ~tool_name:"Edit"
             ~input:
               (`Assoc
                  [ "old_string", `String "x"; "file_path", `String "lib/a.ml" ]))
      in
      check approval "reordered keys are the same call"
        Agent_core.Hooks.Approved retry)

let test_a_remembered_answer_does_not_cross_keepers () =
  with_gate (fun ~clock ~late ~events:_ ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:(edit_input "lib/a.ml");
      ignore
        (Late.remember_late late ~base_path:workspace ~keeper_name:keeper
           ~tool_call_id:"call-1" ~actor:"mode-operator"
           Registry.Approve ());
      (* Same store, another keeper's gate: the identity carries the keeper
         name, so the identical call from somebody else is asked about. *)
      let other_gate =
        Gate.create ~redact_text:Fun.id ~registry:(Registry.create ()) ~late_approvals:late
          ~publish:(Events.publish (Events.create ()))
          ~clock ~base_path:workspace ~keeper_name:"keeper.two" ~timeout_sec:0.05
      in
      let answer =
        other_gate.Gate.tool_approval
          (request ~tool_call_id:"call-1" ~tool_name:"Edit"
             ~input:(edit_input "lib/a.ml"))
      in
      check approval "another keeper's identical call is not covered"
        Agent_core.Hooks.Timed_out answer;
      let retry =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-2" ~tool_name:"Edit"
             ~input:(edit_input "lib/a.ml"))
      in
      check approval "the keeper the answer was given to still holds it"
        Agent_core.Hooks.Approved retry)

(* ── staleness ────────────────────────────────────────────────────── *)

let test_a_fresh_remembered_answer_applies () =
  (* The settle-once test above is this with the store's own clock; here the
     remembered entry's age is pinned explicitly just under the bound. *)
  with_gate (fun ~clock ~late ~events:_ ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:(edit_input "lib/a.ml");
      ignore
        (Late.remember_late late
           ~now:(Eio.Time.now clock -. 1.0)
           ~base_path:workspace ~keeper_name:keeper ~tool_call_id:"call-1"
           ~actor:"mode-operator" Registry.Approve ());
      let retry =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-2" ~tool_name:"Edit"
             ~input:(edit_input "lib/a.ml"))
      in
      check approval "a second-old answer is still the operator's moment"
        Agent_core.Hooks.Approved retry)

let test_a_remembered_answer_past_its_moment_is_asked_about_again () =
  with_gate (fun ~clock ~late ~events ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:(edit_input "lib/a.ml");
      (* The answer arrived, but longer ago than one operator moment spans:
         by the time the identical call returns it is a new occurrence, not
         the retry the operator answered. *)
      ignore
        (Late.remember_late late
           ~now:(Eio.Time.now clock -. Late.ttl_sec -. 1.0)
           ~base_path:workspace ~keeper_name:keeper ~tool_call_id:"call-1"
           ~actor:"mode-operator" Registry.Approve ());
      ignore (drain events []);
      let retry =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-2" ~tool_name:"Edit"
             ~input:(edit_input "lib/a.ml"))
      in
      check approval "a stale memory is no memory; the call is asked about"
        Agent_core.Hooks.Timed_out retry;
      check (list string) "and the stream shows a fresh ask, not a memory"
        [ "requested(call-2,Run it?,policy: needs an operator's eye)"
        ; "settled(call-2,timed_out)" ]
        (event_labels events))

(* ── durability across a restart (design D2) ─────────────────────── *)

let test_a_remembered_answer_survives_a_restart_and_settles_the_retry () =
  with_journal (fun ~clock:_ ~journal:_ ~make ~remove:_ ->
      (* First life: the ask times out and the operator answers late; both
         rows are durable before the process "dies". *)
      let first = make () in
      Late.note_timed_out first ~base_path:workspace ~keeper_name:keeper
        ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~args:(edit_input "lib/a.ml") ();
      check remember_outcome
        "the late answer stands only when its journal row does"
        (Late.Remembered { tool_name = "Edit" })
        (Late.remember_late first ~base_path:workspace ~keeper_name:keeper
           ~tool_call_id:"call-1" ~actor:"mode-operator"
           Registry.Approve ());
      (* Restart: a fresh store, nothing in memory, bound from the journal
         the way boot binds it. *)
      let second = make () in
      check bool "a fresh store holds no memory of its own"
        (Late.take second ~base_path:workspace ~keeper_name:keeper
           ~tool_name:"Edit" ~args:(edit_input "other-file.ml") ()
        = None)
        true;
      (* The identical retry after the restart is settled by the restored
         answer, and only once. *)
      check bool "the restored answer settles the retried call"
        (Late.take second ~base_path:workspace ~keeper_name:keeper
           ~tool_name:"Edit" ~args:(edit_input "lib/a.ml") ()
        = Some Registry.Approve)
        true;
      let consumed =
        Late.take second ~base_path:workspace ~keeper_name:keeper
          ~tool_name:"Edit" ~args:(edit_input "lib/a.ml") ()
      in
      check bool "one use consumes it across the restart too"
        (consumed = None)
        true)

let test_a_workspace_cannot_consume_another_workspaces_answer () =
  with_journal (fun ~clock:_ ~journal:_ ~make ~remove:_ ->
      let first = make () in
      Late.note_timed_out first ~base_path:"/ws/a" ~keeper_name:keeper
        ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~args:(edit_input "lib/a.ml") ();
      check remember_outcome
        "the answer is attributed to the workspace that asked"
        (Late.Remembered { tool_name = "Edit" })
        (Late.remember_late first ~base_path:"/ws/a" ~keeper_name:keeper
           ~tool_call_id:"call-1" ~actor:"mode-operator-a"
           Registry.Approve ());
      (* Same journal root, another workspace: the identity carries the
         workspace, so the identical call from there is asked about. *)
      let second = make () in
      check bool
        "another workspace's identical call is not covered by the answer"
        (Late.take second ~base_path:"/ws/b" ~keeper_name:keeper
           ~tool_name:"Edit" ~args:(edit_input "lib/a.ml") ()
        = None)
        true;
      check bool "the asking workspace still holds it"
        (Late.take second ~base_path:"/ws/a" ~keeper_name:keeper
           ~tool_name:"Edit" ~args:(edit_input "lib/a.ml") ()
        = Some Registry.Approve)
        true)

let test_a_consumed_answer_is_never_reoffered_after_a_restart () =
  with_journal (fun ~clock:_ ~journal:_ ~make ~remove:_ ->
      let first = make () in
      Late.note_timed_out first ~base_path:workspace ~keeper_name:keeper
        ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~args:(edit_input "lib/a.ml") ();
      ignore
        (Late.remember_late first ~base_path:workspace ~keeper_name:keeper
           ~tool_call_id:"call-1" ~actor:"mode-operator"
           Registry.Approve ());
      (* The retry consumes it in the first life, deliver row included. *)
      check bool "the first life's retry is settled"
        (Late.take first ~base_path:workspace ~keeper_name:keeper
           ~tool_name:"Edit" ~args:(edit_input "lib/a.ml") ()
        = Some Registry.Approve)
        true;
      (* The restart replays the journal: the consume row already spent
         the answer, so the same decision is not handed out twice. *)
      let second = make () in
      check bool
        "a consumed answer is not reoffered after a restart"
        (Late.take second ~base_path:workspace ~keeper_name:keeper
           ~tool_name:"Edit" ~args:(edit_input "lib/a.ml") ()
        = None)
        true;
      check bool "a delivered consume leaves no uncertain window"
        (Late.journal_uncertain second = 0)
        true)

let test_a_consume_without_deliver_reads_as_uncertain () =
  with_journal (fun ~clock:_ ~journal ~make ~remove ->
      let first = make () in
      Late.note_timed_out first ~base_path:workspace ~keeper_name:keeper
        ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~args:(edit_input "lib/a.ml") ();
      ignore
        (Late.remember_late first ~base_path:workspace ~keeper_name:keeper
           ~tool_call_id:"call-1" ~actor:"mode-operator"
           Registry.Approve ());
      check bool "the first life's retry is settled"
        (Late.take first ~base_path:workspace ~keeper_name:keeper
           ~tool_name:"Edit" ~args:(edit_input "lib/a.ml") ()
        = Some Registry.Approve)
        true;
      (* Simulate the crash window by hand: the process died between the
         consume append and the deliver append, so the journal holds a
         consume row with no closing deliver row. The row carries the
         identity the ack will name (the same fingerprint [take] wrote in
         the first life). *)
      let oc = open_out_gen [ Open_append ] 0o644 journal in
      output_string oc
        (Yojson.Safe.to_string
           (`Assoc
             [ ("schema", `String "masc.late_approval.v2")
             ; ("consume_id", `String "fixture-interrupted-consume")
             ; ("op", `String "consume")
             ; ("base_path", `String workspace)
             ; ("keeper", `String keeper)
             ; ("tool", `String "Edit")
             ; ( "fingerprint"
               , `String
                   (Masc.Keeper_approval_request_fingerprint.request_fingerprint
                      (edit_input "lib/a.ml")) )
             ; ("at", `Float (Unix.gettimeofday ()))
             ])
        ^ "\n");
      close_out oc;
      let second = make () in
      check bool
        "the consume whose deliver never landed is the uncertain count"
        (Late.journal_uncertain second = 1)
        true;
      (* The D4 ack: the operator has seen the outcome-unknown warning. The
         ack drops the count, stands in the journal across a restart, and
         never turns into a re-offered decision. *)
      check bool
        "an ack names an existing uncertain tail"
        (Late.ack_uncertain second ~base_path:workspace ~keeper_name:keeper ~consume_id:"fixture-interrupted-consume" ()
        = Late.Acked)
        true;
      check bool "the acked tail leaves the uncertain count"
        (Late.journal_uncertain second = 0)
        true;
      (* The restart replays the ack row: the tail stays acknowledged, and
         the ack never restores a remembered answer to re-authorize the
         call (an ack is not a rearm). *)
      let third = make () in
      check bool "an ack survives the restart"
        (Late.journal_uncertain third = 0)
        true;
      check bool
        "an ack never re-authorizes the call"
        (Late.take third ~base_path:workspace ~keeper_name:keeper
           ~tool_name:"Edit" ~args:(edit_input "lib/a.ml") ()
        = None)
        true;
      check bool
        "acking a tail that stands nowhere is refused"
        (Late.ack_uncertain third ~base_path:workspace ~keeper_name:keeper ~consume_id:"fixture-interrupted-consume" ()
        = Late.Not_uncertain)
        true)

let test_later_delivery_preserves_earlier_attempt () =
  with_journal (fun ~clock:_ ~journal ~make ~remove:_ ->
    let store = make () in
    let args = edit_input "lib/a.ml" in
    let now = Unix.gettimeofday () -. Late.ttl_sec -. 100. in
    let consume call_id =
      Late.note_timed_out store ~now ~base_path:workspace ~keeper_name:keeper
        ~tool_call_id:call_id ~tool_name:"Edit" ~args ();
      ignore (Late.remember_late store ~now ~base_path:workspace ~keeper_name:keeper
        ~tool_call_id:call_id ~actor:"operator" Registry.Approve ());
      check bool "actual consume still returns decision" true
        (Late.take store ~now ~base_path:workspace ~keeper_name:keeper ~tool_name:"Edit" ~args () = Some Registry.Approve) in
    (* The interrupted-attempt shape is planted in the journal itself, the
       way the crash leaves it: a consume row whose closing deliver row
       never landed. The store keeps no test-only fail seam (the
       task-1665 review removed [For_testing.fail_next_deliver]); a real
       append failure would fence the store, so the file is the seam. *)
    let plant_consume_only_tail consume_id =
      let oc = open_out_gen [ Open_append ] 0o644 journal in
      output_string oc
        (Yojson.Safe.to_string
           (`Assoc
             [ ("schema", `String "masc.late_approval.v2")
             ; ("consume_id", `String consume_id)
             ; ("op", `String "consume")
             ; ("base_path", `String workspace)
             ; ("keeper", `String keeper)
             ; ("tool", `String "Edit")
             ; ( "fingerprint"
               , `String
                   (Masc.Keeper_approval_request_fingerprint.request_fingerprint
                      args) )
             ; ("at", `Float now)
             ])
        ^ "\n");
      close_out oc
    in
    consume "first";
    plant_consume_only_tail "fixture-interrupted-first";
    let first = "fixture-interrupted-first" in
    consume "second";
    let restarted = make () in
    let restored = Result.get_ok (Late.uncertain_attempts restarted ~base_path:workspace) in
    check int "later success leaves only the interrupted first tail" 1 (List.length restored);
    check string "same first attempt remains" first (List.hd restored).consume_id;
    consume "third";
    plant_consume_only_tail "fixture-interrupted-third";
    let restarted = make () in
    check int "both failed attempts remain" 2 (Late.journal_uncertain restarted);
    check bool "wrong workspace cannot ack attempt" true
      (Late.ack_uncertain restarted ~base_path:"/other" ~keeper_name:keeper
        ~consume_id:first () = Late.Not_uncertain);
    check bool "ack exactly first attempt" true
      (Late.ack_uncertain restarted ~base_path:workspace ~keeper_name:keeper
        ~consume_id:first () = Late.Acked);
    check int "ack leaves other attempt" 1 (Late.journal_uncertain restarted);
    let final = make () in
    check int "exact ack survives restart" 1 (Late.journal_uncertain final);
    check bool "ack never reauthorizes" true
      (Late.take final ~base_path:workspace ~keeper_name:keeper ~tool_name:"Edit" ~args () = None))

let test_malformed_consume_cannot_restore_approval () =
  List.iter (fun missing ->
    with_journal (fun ~clock:_ ~journal ~make ~remove:_ ->
      let first = make () in
      let args = edit_input "lib/a.ml" in
      Late.note_timed_out first ~base_path:workspace ~keeper_name:keeper
        ~tool_call_id:"malformed" ~tool_name:"Edit" ~args ();
      ignore (Late.remember_late first ~base_path:workspace ~keeper_name:keeper
        ~tool_call_id:"malformed" ~actor:"operator" Registry.Approve ());
      let fields =
        [ "schema", `String "masc.late_approval.v2"; "op", `String "consume";
          "consume_id", `String "malformed-consume";
          "base_path", `String workspace; "keeper", `String keeper;
          "tool", `String "Edit";
          "fingerprint", `String (Masc.Keeper_approval_request_fingerprint.request_fingerprint args);
          "at", `Float (Unix.gettimeofday ()) ]
        |> List.filter (fun (name, _) -> name <> missing)
      in
      let out = open_out_gen [Open_append] 0o600 journal in
      output_string out (Yojson.Safe.to_string (`Assoc fields) ^ "\n");
      close_out out;
      let second = make () in
      check bool ("missing " ^ missing ^ " is corrupt") true
        (match Late.journal_error second with Some (Late.Corrupt_journal _) -> true | _ -> false);
      check bool "earlier remembered answer cannot be resurrected" true
        (Late.take second ~base_path:workspace ~keeper_name:keeper ~tool_name:"Edit" ~args () = None);
      check bool "operator listing fails explicitly" true
        (Result.is_error (Late.uncertain_attempts second ~base_path:workspace))))
    ["base_path"; "keeper"; "tool"; "fingerprint"; "at"]

let test_pre_id_schema_rows_are_skipped_not_fatal () =
  (* A row from before the schema tag existed names no v2 identity, so it
     cannot settle or fence anything: restore skips it, reports it, and the
     store keeps working. *)
  with_journal (fun ~clock:_ ~journal ~make ~remove:_ ->
    Fs_compat.mkdir_p (Filename.dirname journal);
    Out_channel.with_open_bin journal (fun out ->
      output_string out "{\"op\":\"consume\",\"at\":0}\n");
    let store = make () in
    check bool "an old-schema row is not an explicit fault" true
      (Late.journal_error store = None);
    check int "the unreadable row is reported" 1 (Late.journal_skipped store);
    Late.note_timed_out store ~base_path:workspace ~keeper_name:keeper
      ~tool_call_id:"new" ~tool_name:"Edit" ~args:(edit_input "lib/a.ml") ();
    check bool "a new late answer still stands" true
      (Late.remember_late store ~base_path:workspace ~keeper_name:keeper
        ~tool_call_id:"new" ~actor:"operator" Registry.Approve ()
       = Late.Remembered { tool_name = "Edit" });
    check bool "the old row names nothing ackable" true
      (Late.ack_uncertain store ~base_path:workspace ~keeper_name:keeper
        ~consume_id:"unknown" () = Late.Not_uncertain);
    check bool "the operator read is not fenced" true
      (Result.is_ok (Late.uncertain_attempts store ~base_path:workspace)))

let test_one_foreign_row_among_valid_rows_does_not_fence_restore () =
  with_journal (fun ~clock:_ ~journal ~make ~remove:_ ->
    let first = make () in
    let args = edit_input "lib/a.ml" in
    Late.note_timed_out first ~base_path:workspace ~keeper_name:keeper
      ~tool_call_id:"call-1" ~tool_name:"Edit" ~args ();
    ignore
      (Late.remember_late first ~base_path:workspace ~keeper_name:keeper
        ~tool_call_id:"call-1" ~actor:"operator" Registry.Approve ());
    (* A future schema's row lands after the valid history, the way a
       downgrade or a stray write leaves it. *)
    let oc = open_out_gen [Open_append] 0o644 journal in
    output_string oc
      (Yojson.Safe.to_string
         (`Assoc
           [ ("schema", `String "masc.late_approval.v3")
           ; ("op", `String "remember_late") ])
      ^ "\n");
    close_out oc;
    let second = make () in
    check bool "restore succeeds past the foreign row" true
      (Late.journal_error second = None);
    check int "the foreign row is counted" 1 (Late.journal_skipped second);
    check bool "the remembered answer still settles the retry" true
      (Late.take second ~base_path:workspace ~keeper_name:keeper
        ~tool_name:"Edit" ~args () = Some Registry.Approve);
    check bool "one use still consumes it" true
      (Late.take second ~base_path:workspace ~keeper_name:keeper
        ~tool_name:"Edit" ~args () = None);
    (* Rebinding replays the same journal: the count is per restore, and a
       still-skipped foreign row proves the file kept it. *)
    let third = make () in
    check int "the count is per restore, not cumulative" 1
      (Late.journal_skipped third);
    check bool "the store stays unfenced" true
      (Late.journal_error third = None))

let test_unreadable_row_shapes_are_all_counted () =
  with_journal (fun ~clock:_ ~journal ~make ~remove:_ ->
    let first = make () in
    let args = edit_input "lib/a.ml" in
    Late.note_timed_out first ~base_path:workspace ~keeper_name:keeper
      ~tool_call_id:"call-1" ~tool_name:"Edit" ~args ();
    ignore
      (Late.remember_late first ~base_path:workspace ~keeper_name:keeper
        ~tool_call_id:"call-1" ~actor:"operator" Registry.Approve ());
    let oc = open_out_gen [Open_append] 0o644 journal in
    output_string oc "this is not json at all\n";
    output_string oc "[1,2,3]\n";
    output_string oc "{\"schema\":\"masc.late_approval.v1\"}\n";
    close_out oc;
    let second = make () in
    check int "every unreadable shape is counted" 3
      (Late.journal_skipped second);
    check bool "the restore itself stays clean" true
      (Late.journal_error second = None);
    check bool "the valid history still settles the retry" true
      (Late.take second ~base_path:workspace ~keeper_name:keeper
        ~tool_name:"Edit" ~args () = Some Registry.Approve))

let () =
  run "keeper_late_approval"
    [ ( "remembering a late answer"
      , [ test_case "later delivery and ack settle only their exact attempt" `Quick
            test_later_delivery_preserves_earlier_attempt
        ; test_case "malformed v2 consume cannot resurrect approval" `Quick
            test_malformed_consume_cannot_restore_approval
        ; test_case "pre-ID schema rows are skipped, not fatal" `Quick
            test_pre_id_schema_rows_are_skipped_not_fatal
        ; test_case "one foreign row among valid rows does not fence restore"
            `Quick test_one_foreign_row_among_valid_rows_does_not_fence_restore
        ; test_case "unreadable row shapes are all counted" `Quick
            test_unreadable_row_shapes_are_all_counted
        ; test_case "an answer after the timeout is remembered" `Quick
            test_an_answer_after_the_timeout_is_remembered
        ; test_case "an answer that names no ask is dropped" `Quick
            test_an_answer_that_names_no_ask_is_dropped
        ; test_case "an ask that timed out long ago cannot be answered" `Quick
            test_an_ask_that_timed_out_long_ago_cannot_be_answered
        ] )
    ; ( "settling the retried call"
      , [ test_case "the identical retried call is settled once" `Quick
            test_the_identical_retried_call_is_settled_once
        ; test_case "a remembered denial refuses the identical retry" `Quick
            test_a_remembered_denial_refuses_the_identical_retry
        ; test_case "a call with different arguments is asked about" `Quick
            test_a_call_with_different_arguments_is_asked_about
        ; test_case "the same arguments in another order are the same call"
            `Quick test_the_same_arguments_in_another_order_are_the_same_call
        ; test_case "a remembered answer does not cross keepers" `Quick
            test_a_remembered_answer_does_not_cross_keepers
        ] )
    ; ( "staleness"
      , [ test_case "a fresh remembered answer applies" `Quick
            test_a_fresh_remembered_answer_applies
        ; test_case "a remembered answer past its moment is asked about again"
            `Quick test_a_remembered_answer_past_its_moment_is_asked_about_again
        ] )
    ; ( "durability across a restart"
      , [ test_case
            "a remembered answer survives a restart and settles the retry"
            `Quick
            test_a_remembered_answer_survives_a_restart_and_settles_the_retry
        ; test_case "a workspace cannot consume another workspace's answer"
            `Quick test_a_workspace_cannot_consume_another_workspaces_answer
        ; test_case "a consumed answer is never reoffered after a restart"
            `Quick test_a_consumed_answer_is_never_reoffered_after_a_restart
        ; test_case "a consume without deliver reads as uncertain" `Quick
            test_a_consume_without_deliver_reads_as_uncertain
        ] )
    ]
