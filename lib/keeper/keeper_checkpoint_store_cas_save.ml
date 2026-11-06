module Objects = Agent_core.Checkpoint_objects
open Keeper_checkpoint_store_history_files
open Keeper_checkpoint_store_decode
open Keeper_checkpoint_store_summary
open Keeper_checkpoint_store_session
open Keeper_checkpoint_store_canonical
open Keeper_checkpoint_store_ref_errors
open Keeper_checkpoint_store_installation
open Keeper_checkpoint_store_exact_snapshot

(* What the canonical file holds, against the reference a candidate claims to
   advance. *)
type canonical_source =
  | Source_absent
  | Source_is_expected
  | Source_is_other of Keeper_checkpoint_ref.t

(* RFC-0225 §3.2 admission: the reference is the content digest, which the
   head gives without a message object read (RFC-0476 §3.2), and its session
   and turn are the head's. The head is read and parsed under the lock every
   time, so a file rewritten in place under the summary's identity (#43575)
   cannot pass for the expected source. A head that does not parse refuses
   the write. *)
let canonical_source_locked
      ~session_dir
      ~(expected_source_ref : Keeper_checkpoint_ref.t)
  =
  let expected_session_id = expected_source_ref.trace_id in
  let canonical_path =
    agent_core_checkpoint_path
      ~session_dir
      ~session_id:(Keeper_id.Trace_id.to_string expected_session_id)
  in
  match parsed_canonical ~canonical_path with
  | Error error -> Error (Ref_read_failed error)
  | Ok None -> Ok Source_absent
  | Ok (Some ((_ : canonical_identity), head)) ->
    (match Keeper_id.Trace_id.of_string head.header.session_id with
     | Error reason -> Error (Ref_identity_invalid (Session_id_invalid reason))
     | Ok trace_id when not (Keeper_id.Trace_id.equal trace_id expected_session_id) ->
       Error (Ref_session_mismatch { expected = expected_session_id; actual = trace_id })
     | Ok trace_id ->
       (match
          Keeper_checkpoint_ref.of_persisted
            ~trace_id
            ~turn_count:head.header.turn_count
            ~sha256:(Objects.head_content_digest head :> string)
        with
        | Error error -> Error (Ref_identity_invalid (Ref_create_failed error))
        | Ok reference ->
          Ok
            (if Keeper_checkpoint_ref.equal reference expected_source_ref
             then Source_is_expected
             else Source_is_other reference)))
;;

let lock_failure_not_installed error =
  not_installed
    (Source_unavailable
       (Ref_lock_failed (File_lock_eio.durable_lock_error_to_string error)))
;;

let installation_of_lock_observation = function
  | File_lock_eio.Lock_not_acquired error -> lock_failure_not_installed error
  | File_lock_eio.Body_completed { value; release_error = None } -> value
  | File_lock_eio.Body_completed { value; release_error = Some error } ->
    append_installation_auxiliary value (Release_process_lock_failed error)
;;

let with_checkpoint_cas_lock ~session_dir f =
  match canonical_session_location session_dir with
  | Error error ->
    not_installed
      (Source_unavailable
         (Ref_lock_failed (save_agent_core_error_to_string error)))
  | Ok session_dir ->
    let lock_path = session_dir ^ ".checkpoint.lock" in
    File_lock_eio.with_durable_lock_observed
      ~lock_path
      (fun () -> f session_dir)
    |> installation_of_lock_observation

(* A plan's layout follows the canonical as it is when the plan is made
   (RFC-0476 §3.3), and writes again what that head names but the session
   does not hold. Objects are not removed while a head names them, so the
   plan stays valid when the canonical moves before a lock is taken; the
   source check under the lock decides whether it is installed. A canonical
   that cannot be read gives no layout to follow, and the source check then
   refuses the install. *)
let plan_for_session ~session_dir ~boundary (checkpoint : Agent_core.Checkpoint.t) =
  let known =
    if not (leaf_is_real_segment checkpoint.session_id)
    then None
    else (
      match
        known_canonical
          ~canonical_path:
            (agent_core_checkpoint_path ~session_dir ~session_id:checkpoint.session_id)
      with
      | Ok known -> known
      | Error (_ : checkpoint_load_error) -> None)
  in
  let previous = Option.map (fun known -> known.known_head) known in
  let absent = Option.fold ~none:[] ~some:(absent_objects ~session_dir) known in
  offload_checkpoint_cpu (fun () ->
    Objects.plan_save (Objects.create_memo ()) ?previous ~absent boundary checkpoint)

let install_plan_if_source
    ~require_absent
    ~with_checkpoint_cas_lock
    ~write_checkpoint_bytes
    ~(on_checkpoint_commit_observer : Keeper_checkpoint_ref.t -> unit)
    ~session_dir
    ~(expected_source_ref : Keeper_checkpoint_ref.t)
    ~(candidate_ref : Keeper_checkpoint_ref.t)
    (plan : Objects.plan) =
    let expected_session_id = expected_source_ref.trace_id in
    let observed_ref = ref None in
    let committed_installation = ref None in
    (* Every path through here has installed the plan's head, so the file is
       the candidate: its summary is the plan's head, without reading the
       file back. *)
    let publish ~canonical_path auxiliary =
      ignore (publish_summary_after_write ~canonical_path plan.head : canonical_identity option);
      let installed = { installed_ref = candidate_ref; auxiliary } in
      committed_installation := Some installed;
      Installed installed
    in
    let observe_commit () =
      observed_ref := Some candidate_ref;
      on_checkpoint_commit_observer candidate_ref
    in
    let outcome =
      try
        `Returned
          (with_checkpoint_cas_lock ~session_dir (fun session_dir ->
         let source =
           match canonical_source_locked ~session_dir ~expected_source_ref with
           | Error error -> Error (Source_unavailable error)
           | Ok Source_absent ->
             if require_absent then Ok () else Error (Source_unavailable Ref_not_found)
           | Ok Source_is_expected ->
             if require_absent
             then Error (Source_changed expected_source_ref)
             else Ok ()
           | Ok (Source_is_other reference) -> Error (Source_changed reference)
         in
         match source with
         | Error error -> not_installed error
         | Ok () ->
           let canonical_path =
             agent_core_checkpoint_path
               ~session_dir
               ~session_id:(Keeper_id.Trace_id.to_string expected_session_id)
           in
           let ownership_root = Filename.dirname session_dir in
           (match Keeper_checkpoint_object_store.write ~session_dir plan.objects with
            | Error error -> not_installed (Objects_not_installed error)
            | Ok (_ : int) ->
              (match
                 write_checkpoint_bytes
                   ~on_durable_commit:observe_commit
                   ~ownership_root
                   ~path:canonical_path
                   ~bytes:plan.head_bytes
               with
               | Error error when error.Keeper_fs.renamed ->
                 publish ~canonical_path [ Commit_durability_unknown error ]
               | Error error -> not_installed (Commit_not_installed error)
               | Ok Keeper_fs.Committed ->
                 (* The durable writer installs the plan's head verbatim, and
                    [candidate_ref] is that plan's content digest, so the
                    published file and the returned ref agree by
                    construction. The hint is auxiliary and cannot downgrade
                    that fact. *)
                 publish ~canonical_path []
               | Ok (Keeper_fs.Committed_but_observer_failed failure) ->
                 publish ~canonical_path [ Commit_observer_failed failure ]))))
      with
      | Eio.Cancel.Cancelled _ as cancelled ->
        Printexc.raise_with_backtrace cancelled (Printexc.get_raw_backtrace ())
      | exn -> `Raised (exn, Printexc.get_raw_backtrace ())
    in
    let observed_installation installed_ref =
      match !committed_installation with
      | Some installed -> installed
      | None -> { installed_ref; auxiliary = [] }
    in
    let known_installed_ref () =
      match !committed_installation with
      | Some installed -> Some installed.installed_ref
      | None -> !observed_ref
    in
    (match outcome with
     | `Returned installation -> installation
     | `Raised (exn, backtrace) ->
       (match known_installed_ref () with
        | Some installed_ref ->
          append_installation_auxiliary
            (Installed (observed_installation installed_ref))
            (Post_commit_unwind_interrupted (exn, backtrace))
        | None -> Printexc.raise_with_backtrace exn backtrace))

let save_agent_core_if_source_with
    ?(require_absent = false)
    ~with_checkpoint_cas_lock
    ~write_checkpoint_bytes
    ~(on_checkpoint_commit_observer : Keeper_checkpoint_ref.t -> unit)
    ~session_dir
    ~(expected_source_ref : Keeper_checkpoint_ref.t)
    ~boundary
    (candidate : Agent_core.Checkpoint.t) =
  match plan_for_session ~session_dir ~boundary candidate with
  | Error error -> not_installed (Candidate_unencodable error)
  | Ok plan ->
    (match checkpoint_ref_of_content plan.content candidate with
     | Error error -> not_installed (Candidate_identity_invalid error)
     | Ok candidate_ref
       when not
              (Keeper_id.Trace_id.equal
                 expected_source_ref.trace_id candidate_ref.trace_id) ->
       not_installed
         (Candidate_session_mismatch
            { expected = expected_source_ref.trace_id
            ; candidate = candidate_ref.trace_id
            })
     | Ok candidate_ref
       when candidate_ref.turn_count < expected_source_ref.turn_count ->
       not_installed
         (Candidate_turn_regressed
            { source_turn = expected_source_ref.turn_count
            ; candidate_turn = candidate_ref.turn_count
            })
     | Ok candidate_ref ->
       install_plan_if_source
         ~require_absent ~with_checkpoint_cas_lock ~write_checkpoint_bytes
         ~on_checkpoint_commit_observer ~session_dir ~expected_source_ref ~candidate_ref plan)

let write_checkpoint_bytes
    ~on_durable_commit
    ~ownership_root
    ~path
    ~bytes =
  Keeper_fs.save_bytes_durable_atomic_observed
    ~on_durable_commit
    ~ownership_root
    path
    bytes
;;

let save_agent_core_if_source ~session_dir ~expected_source_ref ~boundary candidate =
  save_agent_core_if_source_with
    ~with_checkpoint_cas_lock
    ~write_checkpoint_bytes
    ~on_checkpoint_commit_observer:(fun _ -> ())
    ~session_dir
    ~expected_source_ref
    ~boundary
    candidate
;;

let save_agent_core_if_absent ~session_dir ~boundary candidate =
  match plan_for_session ~session_dir ~boundary candidate with
  | Error error -> not_installed (Candidate_unencodable error)
  | Ok plan ->
    (match checkpoint_ref_of_content plan.content candidate with
     | Error error -> not_installed (Candidate_identity_invalid error)
     | Ok candidate_ref ->
       install_plan_if_source
         ~require_absent:true ~with_checkpoint_cas_lock ~write_checkpoint_bytes
         ~on_checkpoint_commit_observer:(fun _ -> ())
         ~session_dir ~expected_source_ref:candidate_ref ~candidate_ref plan)
;;
