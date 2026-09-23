(* [String.split_on_char '\n'] counts a trailing newline as an extra empty line
   ("a\nb\n" -> 3 elements), so count newline-separated lines treating a final
   '\n' as terminating the last line rather than starting a new one. *)
let line_count text =
  if String.length text = 0
  then 0
  else (
    let newlines =
      String.fold_left (fun n c -> if Char.equal c '\n' then n + 1 else n) 0 text
    in
    if Char.equal text.[String.length text - 1] '\n' then newlines else newlines + 1)
;;

let record config ~agent_id ~reference ~source_text ~status ?evidence ~outcome () =
  let evidence_field =
    match evidence with
    | None -> []
    | Some entries -> [ "evidence", `List (List.map (fun entry -> `String entry) entries) ]
  in
  try
    Audit_log.log_action
      config
      ~agent_id
      ~action:(Audit_log.Custom "skill_write")
      ~details:
        (`Assoc
           ([ "reference", Skill_reference.to_yojson reference
            ; ( "candidate_revision"
              , `String
                  (Skill_reference.content_revision_of_source_text source_text
                   |> Skill_reference.content_revision_to_string) )
            ; "bytes", `Int (String.length source_text)
            ; "lines", `Int (line_count source_text)
            ; "status", `String status
            ]
            @ evidence_field))
      ~outcome
      ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Log.Server.warn "Skill write audit failed: %s" (Printexc.to_string exn)
;;
