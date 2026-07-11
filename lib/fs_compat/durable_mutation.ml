module Segment = struct
  type t = string

  type error =
    | Empty
    | Dot
    | Dot_dot
    | Contains_separator
    | Contains_nul

  let of_string = function
    | "" -> Error Empty
    | "." -> Error Dot
    | ".." -> Error Dot_dot
    | value when String.contains value '/' -> Error Contains_separator
    | value when String.contains value '\000' -> Error Contains_nul
    | value -> Ok value
  ;;

  let to_string value = value
end

type diagnostic_stage =
  | Temporary_close
  | Temporary_cleanup
  | Parent_close
  | Observer

type diagnostic =
  { stage : diagnostic_stage
  ; cause : exn
  ; backtrace : Printexc.raw_backtrace
  }

type 'a progress =
  | Not_committed of
      { cause : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Committed_not_durable of
      { value : 'a
      ; cause : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Durable of 'a

type 'a report =
  { progress : 'a progress
  ; diagnostics : diagnostic list
  }

type observation =
  | Observed
  | Observer_failed of diagnostic

external open_parent : string -> Unix.file_descr = "masc_durable_mutation_open_parent"

external create_exclusive
  :  Unix.file_descr
  -> string
  -> int
  -> Unix.file_descr
  = "masc_durable_mutation_create_exclusive"

external rename_entry
  :  Unix.file_descr
  -> string
  -> string
  -> unit
  = "masc_durable_mutation_rename"

external unlink_entry
  :  Unix.file_descr
  -> string
  -> unit
  = "masc_durable_mutation_unlink"

let diagnostic stage cause backtrace = { stage; cause; backtrace }

let diagnostic_stage_to_string = function
  | Temporary_close -> "temporary close"
  | Temporary_cleanup -> "temporary cleanup"
  | Parent_close -> "parent close"
  | Observer -> "observer"
;;

let diagnostic_to_string diagnostic =
  Printf.sprintf
    "%s: %s"
    (diagnostic_stage_to_string diagnostic.stage)
    (Printexc.to_string diagnostic.cause)
;;

let report_to_string report =
  let progress =
    match report.progress with
    | Not_committed { cause; _ } ->
      Printf.sprintf "not committed: %s" (Printexc.to_string cause)
    | Committed_not_durable { cause; _ } ->
      Printf.sprintf "committed but not durable: %s" (Printexc.to_string cause)
    | Durable _ -> "durable"
  in
  match report.diagnostics with
  | [] -> progress
  | diagnostics ->
    Printf.sprintf
      "%s; diagnostics: %s"
      progress
      (String.concat "; " (List.map diagnostic_to_string diagnostics))
;;

let fold_report report ~not_committed ~committed_not_durable ~durable =
  match report.progress with
  | Not_committed _ -> not_committed report
  | Committed_not_durable _ -> committed_not_durable report
  | Durable _ -> durable report
;;

let temporary_prefix = ".atomic_"
let temporary_suffix = ".tmp"

let is_temporary_name name =
  let name_length = String.length name in
  let prefix_length = String.length temporary_prefix in
  let suffix_length = String.length temporary_suffix in
  name_length >= prefix_length + suffix_length
  && String.starts_with name ~prefix:temporary_prefix
  && String.ends_with name ~suffix:temporary_suffix
;;

type durability_confirmation =
  | Confirmed
  | Not_confirmed of
      { cause : exn
      ; backtrace : Printexc.raw_backtrace
      }

type durability_confirmation_report =
  { confirmation : durability_confirmation
  ; confirmation_diagnostics : diagnostic list
  }

let confirm_directory_durable_blocking path =
  match open_parent path with
  | exception cause ->
    { confirmation =
        Not_confirmed { cause; backtrace = Printexc.get_raw_backtrace () }
    ; confirmation_diagnostics = []
    }
  | descriptor ->
    let confirmation =
      match Unix.fsync descriptor with
      | () -> Confirmed
      | exception cause ->
        Not_confirmed { cause; backtrace = Printexc.get_raw_backtrace () }
    in
    let diagnostics =
      match Unix.close descriptor with
      | () -> []
      | exception cause ->
        [ diagnostic Parent_close cause (Printexc.get_raw_backtrace ()) ]
    in
    { confirmation; confirmation_diagnostics = diagnostics }
;;

let confirm_directory_durable_eio path =
  Eio.Cancel.protect (fun () ->
    Eio_unix.run_in_systhread ~label:"durability-confirmation" (fun () ->
      confirm_directory_durable_blocking path))
;;

let run_state_machine ~prepare ~commit ~publish ~cleanup =
  let not_committed cause backtrace =
    { progress = Not_committed { cause; backtrace }; diagnostics = cleanup () }
  in
  match prepare () with
  | exception cause -> not_committed cause (Printexc.get_raw_backtrace ())
  | () ->
    (match commit () with
     | exception cause -> not_committed cause (Printexc.get_raw_backtrace ())
     | () ->
       (match publish () with
        | () -> { progress = Durable (); diagnostics = [] }
        | exception cause ->
          { progress =
              Committed_not_durable
                { value = (); cause; backtrace = Printexc.get_raw_backtrace () }
          ; diagnostics = []
          }))
;;

module For_testing = struct
  let run_state_machine = run_state_machine
end

type temporary_owner =
  | Not_created
  | Open of Unix.file_descr
  | Released

let temp_counter = Atomic.make 0

let rec create_temporary parent =
  let sequence = Atomic.fetch_and_add temp_counter 1 in
  (* NDT-OK: the process ID only mints an O_EXCL entry name. No policy, replay,
     ordering, or identity decision depends on its value. *)
  let process_id = Unix.getpid () in
  let raw =
    Printf.sprintf
      "%s%x_%x%s"
      temporary_prefix
      process_id
      sequence
      temporary_suffix
  in
  match create_exclusive parent raw 0o600 with
  | descriptor -> raw, descriptor
  | exception Unix.Unix_error (Unix.EEXIST, _, _) -> create_temporary parent
;;

let write_all descriptor content =
  let rec loop offset =
    if offset < String.length content
    then
      match
        Unix.write_substring
          descriptor
          content
          offset
          (String.length content - offset)
      with
      | 0 -> raise (Unix.Unix_error (Unix.EIO, "durable_mutation_write", ""))
      | count -> loop (offset + count)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop offset
  in
  loop 0
;;

let close_once owner stage =
  match !owner with
  | Not_created | Released -> []
  | Open descriptor ->
    owner := Released;
    (match Unix.close descriptor with
     | () -> []
     | exception cause ->
       [ diagnostic stage cause (Printexc.get_raw_backtrace ()) ])
;;

let cleanup_temporary parent temp_name owner =
  let close_diagnostics = close_once owner Temporary_close in
  match !temp_name with
  | None -> close_diagnostics
  | Some name ->
    temp_name := None;
    (match unlink_entry parent name with
     | () ->
       (match Unix.fsync parent with
        | () -> close_diagnostics
        | exception cause ->
          close_diagnostics
          @ [ diagnostic
                Temporary_cleanup
                cause
                (Printexc.get_raw_backtrace ())
            ])
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> close_diagnostics
     | exception cause ->
       close_diagnostics
       @ [ diagnostic
             Temporary_cleanup
             cause
             (Printexc.get_raw_backtrace ())
         ])
;;

let atomic_replace_at parent ~name ~perm content =
  let temp_name = ref None in
  let owner = ref Not_created in
  let prepare () =
    let name, descriptor = create_temporary parent in
    temp_name := Some name;
    owner := Open descriptor;
    write_all descriptor content;
    Unix.fchmod descriptor perm;
    Unix.fsync descriptor;
    match close_once owner Temporary_close with
    | [] -> ()
    | { cause; backtrace; _ } :: _ ->
      Printexc.raise_with_backtrace cause backtrace
  in
  let commit () =
    match !temp_name with
    | None -> invalid_arg "durable mutation temporary entry is not prepared"
    | Some temporary ->
      rename_entry parent temporary (Segment.to_string name);
      temp_name := None
  in
  run_state_machine
    ~prepare
    ~commit
    ~publish:(fun () -> Unix.fsync parent)
    ~cleanup:(fun () -> cleanup_temporary parent temp_name owner)
;;

let add_parent_close (report : 'a report) parent =
  match Unix.close parent with
  | () -> report
  | exception cause ->
    { report with
      diagnostics =
        report.diagnostics
        @ [ diagnostic Parent_close cause (Printexc.get_raw_backtrace ()) ]
    }
;;

let atomic_replace_blocking ~parent ~name ~perm content =
  match open_parent parent with
  | exception cause ->
    { progress =
        Not_committed { cause; backtrace = Printexc.get_raw_backtrace () }
    ; diagnostics = []
    }
  | parent_descriptor ->
    let report = atomic_replace_at parent_descriptor ~name ~perm content in
    add_parent_close report parent_descriptor
;;

let atomic_replace_eio ~parent ~name ~perm content =
  Eio.Cancel.protect (fun () ->
    Eio_unix.run_in_systhread ~label:"durable-mutation" (fun () ->
      atomic_replace_blocking ~parent ~name ~perm content))
;;

let observe observer report =
  match observer report with
  | () -> Observed
  | exception (Eio.Cancel.Cancelled _ as cause) -> raise cause
  | exception cause ->
    Observer_failed
      (diagnostic Observer cause (Printexc.get_raw_backtrace ()))
;;

let observe_and_retain observer report =
  match observe observer report with
  | Observed -> report
  | Observer_failed observer_diagnostic ->
    { report with diagnostics = report.diagnostics @ [ observer_diagnostic ] }
;;

let observe_confirmation_and_retain observer report =
  match observe observer report with
  | Observed -> report
  | Observer_failed observer_diagnostic ->
    { report with
      confirmation_diagnostics =
        report.confirmation_diagnostics @ [ observer_diagnostic ]
    }
;;
