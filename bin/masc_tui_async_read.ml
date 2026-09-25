(* The shared launch for TUI reads: catch the read's exceptions, answer on
   the mailbox, answer "Eio switch is unavailable" when there is no switch,
   and survive a refused launch. A failure is labelled once, here, when the
   caller names a subject. *)

let label ?subject cause =
  match subject with
  | None -> cause
  | Some subject -> subject ^ " load failed: " ^ cause

let launch ?on_not_run ?subject ~deliver read =
  let deliver result = deliver (Result.map_error (label ?subject) result) in
  let not_run cause =
    Option.iter (fun release -> release ()) on_not_run;
    deliver (Error cause)
  in
  match Eio_context.get_switch_opt () with
  | None -> not_run "Eio switch is unavailable"
  | Some sw ->
      Masc_tui_fork_guard.launch ~sw ~on_sync_failure:not_run (fun () ->
          let result =
            try read () with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn -> Error (Printexc.to_string exn)
          in
          deliver result;
          `Stop_daemon)
