(** Filesystem observations of a publication recovery reconciliation: stat an
    entry without following symbolic links, open a directory and check its
    kind and identity against the expected one, and walk from the allowed
    root through the parent components of a locator. An observation carries
    both the obligation module's value and the public report value, or the
    failure to observe.

    This module is private to [fs_compat_internal] and has no interface file.
    [Capability_recovery_reconciler] includes it. *)

open Capability_recovery_reconciler_model

type observed_entry =
  { core : Core.entry_observation
  ; public : entry_observation
  }

type stable_directory = Eio.Fs.dir_ty Eio.Path.t

type typed_mismatch =
  { core : Core.resource_mismatch
  ; public : resource_mismatch
  }

type directory_result =
  | Directory_mismatch of typed_mismatch
  | Directory_opened of stable_directory

type parent_result =
  | Allowed_root_mismatch of typed_mismatch
  | Parent_mismatch of typed_mismatch
  | Parent_opened of stable_directory

let core_identity_of_stat ~subject (stat : Eio.File.Stat.t) =
  match Core.identity ~dev:stat.dev ~ino:stat.ino with
  | Ok identity -> Ok identity
  | Error error ->
    Error { subject; cause = Observation_identity_invalid error }
;;

let observation_of_stat ~subject stat : (observed_entry, observation_failure) result =
  match core_identity_of_stat ~subject stat with
  | Error _ as error -> error
  | Ok identity ->
    Ok
      { core = Core.Present { kind = stat.kind; identity }
      ; public =
          Entry_present
            { kind = stat.kind; identity = identity_of_core identity }
      }
;;

let absent_observation : observed_entry =
  { core = Core.Absent; public = Entry_absent }
;;

let capture_observation ~subject operation =
  try Ok (operation ()) with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Error
      { subject
      ; cause = Observation_io_failed { exception_; backtrace }
      }
;;

let observe_stat ~subject path =
  match
    capture_observation ~subject (fun () ->
      try Some (Eio.Path.stat ~follow:false path) with
      | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> None)
  with
  | Error _ as error -> error
  | Ok observation -> Ok observation
;;

let observe_entry ~subject path =
  match observe_stat ~subject path with
  | Error _ as error -> error
  | Ok None -> Ok absent_observation
  | Ok (Some stat) -> observation_of_stat ~subject stat
;;

let mismatch ~expected (observed : observed_entry) : typed_mismatch =
  let core : Core.resource_mismatch =
    { expected; observed = observed.core }
  in
  { core
  ; public = { expected = identity_of_core expected; observed = observed.public }
  }
;;

let validate_opened_directory
      ~sw
      ~subject
      ~path
      ~(observed_stat : Eio.File.Stat.t)
  =
  match
    capture_observation ~subject (fun () ->
      let directory = Eio.Path.open_dir ~sw path in
      let directory = (directory :> Eio.Fs.dir_ty Eio.Path.t) in
      let opened_file = Eio.Path.open_in ~sw Eio.Path.(directory / ".") in
      Resource_scope.track_close ~sw opened_file;
      directory, Eio.File.stat opened_file)
  with
  | Error _ as error -> error
  | Ok (directory, opened_stat) ->
    if opened_stat.kind <> `Directory
    then
      Error
        { subject
        ; cause =
            Opened_resource_kind_changed
              { observed = observed_stat.kind; opened = opened_stat.kind }
        }
    else
      (match
         core_identity_of_stat ~subject observed_stat,
         core_identity_of_stat ~subject opened_stat
       with
       | Error error, _ | _, Error error -> Error error
       | Ok observed, Ok opened ->
         if Core.equal_identity observed opened
         then Ok directory
         else
           Error
             { subject
             ; cause =
                 Opened_resource_identity_changed
                   { observed = identity_of_core observed
                   ; opened = identity_of_core opened
                   }
             })
;;

let open_expected_directory ~sw ~subject ~path ~expected =
  match observe_stat ~subject path with
  | Error _ as error -> error
  | Ok None ->
    let observed = absent_observation in
    Ok (Directory_mismatch (mismatch ~expected observed))
  | Ok (Some observed_stat) ->
    (match observation_of_stat ~subject observed_stat with
     | Error _ as error -> error
     | Ok
         ({ core = Core.Present { kind; identity }; _ } as observed) ->
       if kind <> `Directory || not (Core.equal_identity expected identity)
       then Ok (Directory_mismatch (mismatch ~expected observed))
       else
         (match
            validate_opened_directory
              ~sw
              ~subject
              ~path
              ~observed_stat
          with
          | Error _ as error -> error
          | Ok directory -> Ok (Directory_opened directory))
     | Ok { core = Core.Absent; _ } ->
       Ok (Directory_mismatch (mismatch ~expected absent_observation)))
;;

let traverse_parent ~sw ~fs locator =
  let root_path = Core.locator_allowed_root_path locator in
  let root_subject = Allowed_root root_path in
  let root = Eio.Path.(fs / root_path) in
  match
    open_expected_directory
      ~sw
      ~subject:root_subject
      ~path:root
      ~expected:(Core.locator_allowed_root locator)
  with
  | Error _ as error -> error
  | Ok (Directory_mismatch mismatch) ->
    Ok (Allowed_root_mismatch mismatch)
  | Ok (Directory_opened root) ->
    let rec traverse index parent parent_subject = function
      | [] ->
        (match
           capture_observation ~subject:parent_subject (fun () ->
             Eio.Path.with_open_in Eio.Path.(parent / ".") Eio.File.stat)
         with
         | Error _ as error -> error
         | Ok stat ->
           (match core_identity_of_stat ~subject:parent_subject stat with
            | Error _ as error -> error
            | Ok actual ->
              let expected = Core.locator_parent locator in
              if stat.kind = `Directory && Core.equal_identity expected actual
              then Ok (Parent_opened parent)
              else
                (match observation_of_stat ~subject:parent_subject stat with
                 | Error _ as error -> error
                 | Ok observed ->
                   Ok (Parent_mismatch (mismatch ~expected observed)))))
      | component :: rest ->
        let subject = Parent_component { index; component } in
        let path = Eio.Path.(parent / component) in
        (match observe_stat ~subject path with
         | Error _ as error -> error
         | Ok None ->
           Ok
             (Parent_mismatch
                (mismatch
                   ~expected:(Core.locator_parent locator)
                   absent_observation))
         | Ok (Some observed_stat) ->
           (match observation_of_stat ~subject observed_stat with
            | Error _ as error -> error
            | Ok observed when observed_stat.kind <> `Directory ->
              Ok
                (Parent_mismatch
                   (mismatch
                      ~expected:(Core.locator_parent locator)
                      observed))
            | Ok _ ->
              (match
                 validate_opened_directory
                   ~sw
                   ~subject
                   ~path
                   ~observed_stat
               with
               | Error _ as error -> error
               | Ok opened ->
                 traverse (index + 1) opened subject rest)))
    in
    traverse
      0
      root
      root_subject
      (List.map Capability_leaf.to_string (Core.locator_parent_components locator))
;;
