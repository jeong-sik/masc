(* The corpus tap RFC execute-subset-dispositions §3.5 names.

   The live tap classifies argv-shaped shells as they arrive, which answers for
   traffic from the moment it shipped.  The same question has a recorded
   answer: every Execute call is already on disk with its argv, and running the
   same classifier over those files reads a month instead of an afternoon.

   Same classifier, deliberately.  A census that reimplemented the recogniser
   would drift from the tap it is meant to stand in for, and the number it
   printed would be about itself. *)

module Costume = Keeper_tooling.Shell_costume
module Execute_input = Masc.Keeper_tool_execute_typed_input
module Rewrite = Keeper_tooling.Subset_rewrite
module Gate = Masc_exec_command_gate.Shell_command_gate

let syntax_policy : Gate.syntax_policy =
  { Gate.redirect_allowed = true; allow_pipes = true }
;;

let argv_of_record json =
  match Yojson.Safe.Util.member "tool" json with
  | `String "Execute" ->
    (match Yojson.Safe.Util.member "input" json with
     | `Assoc _ as input ->
       (match Yojson.Safe.Util.member "argv" input with
        | `List items ->
          Some (List.filter_map (function `String s -> Some s | _ -> None) items)
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let bump table key =
  Hashtbl.replace table key (1 + Option.value (Hashtbl.find_opt table key) ~default:0)
;;

let () =
  let files = List.tl (Array.to_list Sys.argv) in
  let executes = ref 0 in
  (* RFC execute-boundary-is-the-sandbox §8. The field names the execution
     model, so the census counts models rather than whether a parser coped.
     [lowered] answered the old question -- did step 4 take this costume into
     the IR -- and there is no longer a costume it does not take. *)
  let ran_typed = ref 0 in
  let ran_shell = ref 0 in
  let advised = ref 0 in
  let argv_form = ref 0 in
  let costumes = ref 0 in
  let unreadable = ref 0 in
  let findings = Hashtbl.create 32 in
  let rewrites = Hashtbl.create 32 in
  let shells = Hashtbl.create 8 in
  List.iter
    (fun path ->
       let channel = open_in path in
       (try
          while true do
            let line = input_line channel in
            match Yojson.Safe.from_string line with
            | json ->
              (match Yojson.Safe.Util.member "tool" json with
               | `String "Execute" ->
                 incr executes;
                 (* Every call, not only the ones wearing a costume: the
                    question is which execution model the call got, and a
                    plain [argv] answers it as much as a script does. *)
                 (match Yojson.Safe.Util.member "input" json with
                  | `Assoc _ as input ->
                    (match Execute_input.of_json input with
                     | Ok parsed ->
                       (match Execute_input.to_shell_ir_unvalidated parsed with
                        | Ok ir ->
                          if Costume.ir_keeps_a_shell ir
                          then incr ran_shell
                          else incr ran_typed
                        | Error _ -> ())
                     | Error _ -> ())
                  | _ -> ())
               | _ -> ());
              (match argv_of_record json with
               | None | Some [] -> ()
               | Some argv ->
                 incr argv_form;
                 (match Costume.of_argv argv with
                  | None -> ()
                  | Some costume ->
                    incr costumes;
                    bump shells costume.Costume.shell;
                    let finding =
                      Costume.classify
                        ~syntax_policy
                        ~sandbox:Gate.host_sandbox
                        costume
                    in
                    bump findings (Costume.finding_tag finding);
                    (* Not an estimate of what step 4 lowers: the real
                       lowering is called, so the guards it applies are the
                       ones counted. A costume still wearing its shell after
                       lowering was held back by one of them.

                       Every stage is asked, and by a predicate that strips the
                       directory. Counting a [Pipeline] as lowered because it
                       was not a [Simple], and reading [/bin/zsh] as a program
                       that is not a shell, both counted up. *)
                    (match finding with
                     | Costume.Outside_the_subset reason ->
                       (* The third disposition: it ran, and the judge had
                          something to say about how it could have been
                          written. *)
                       incr advised;
                       bump rewrites (Rewrite.tag (Rewrite.of_reason reason))
                     | _ -> ())))
            | exception Yojson.Json_error _ -> incr unreadable
          done
        with
         | End_of_file -> ());
       close_in channel)
    files;
  let report title table =
    Printf.printf "\n%s\n" title;
    Hashtbl.fold (fun key count acc -> (key, count) :: acc) table []
    |> List.sort (fun (_, a) (_, b) -> compare b a)
    |> List.iter (fun (key, count) -> Printf.printf "%8d  %s\n" count key)
  in
  Printf.printf
    "files=%d execute=%d argv_form=%d costumes=%d unreadable_lines=%d\n"
    (List.length files)
    !executes
    !argv_form
    !costumes
    !unreadable;
  Printf.printf
    "ran_typed=%d ran_shell=%d advised=%d\n"
    !ran_typed
    !ran_shell
    !advised;
  report "what the gate would have said" findings;
  report "what the caller should have called" rewrites;
  report "which shell wore the costume" shells
;;
