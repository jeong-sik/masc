(** Rows for the tool inventory surface: domain headings, family headings,
    tool rows.

    The family layer is spelling — [a_b_c] shares [a_b] — and spelling is a
    poor proxy for purpose: the task tools land in five different families
    ([masc_add], [masc_batch], [masc_task], [masc_goal], [masc_plan]) with two
    more stranded family-less ([masc_tasks], [masc_transition]), so the list
    read as ninety unrelated names. The domain layer answers what the tools
    are for. It is matched on tool names, one rule per domain, so a new tool
    joins its domain through its name alone; a name no rule claims lands in
    [unsorted] — visible on the surface, not silently filed under a
    neighbour. *)

type row =
  | Domain of { name : string; count : int }
  | Family of {
      name : string;
      count : int;
    }
  | Tool of Masc.Tui_decode.tool_entry

(* Fixed display order: the operator's centre of gravity first — boards and
   work items — then running, then the keeper's own instruments, then the
   long tail of system plumbing. *)
let domain_order =
  [ "board"; "work"; "run"; "keeper ops"; "keeper self"; "system"; "unsorted" ]

(* One rule per domain, tried in order; the first match wins. Names are
   matched exactly or by prefix followed by [_], so [masc_task] does not
   capture [masc_tasks_audit]. *)
let domain_of_tool name =
  let is prefix =
    String.equal name prefix
    || (String.length name > String.length prefix
        && String.starts_with ~prefix:(prefix ^ "_") name)
  in
  if is "masc_board" then Some "board"
  else if
    is "masc_task" || is "masc_tasks" || is "masc_goal" || is "masc_plan"
    || is "masc_transition" || is "masc_add_task" || is "masc_batch_add_tasks"
    || is "masc_update_priority" || is "keeper_task_create"
    || is "keeper_task_claim" || is "keeper_task_done"
    || is "keeper_tasks_audit"
  then Some "work"
  else if
    is "masc_run" || is "masc_fusion" || is "masc_start" || is "masc_pause"
    || is "masc_resume" || is "masc_deliver" || is "masc_gc"
  then Some "run"
  else if is "masc_keeper" then Some "keeper ops"
  else if
    is "tool_read_file" || is "tool_edit_file" || is "tool_write_file"
    || is "tool_search_files" || is "keeper_memory" || is "keeper_voice"
    || is "keeper_broadcast" || is "keeper_context_status"
    || is "keeper_time_now" || is "keeper_tools_list"
  then Some "keeper self"
  else if
    is "masc_config" || is "masc_tool_help" || is "masc_runtime"
    || is "masc_dashboard" || is "masc_messages" || is "masc_broadcast"
    || is "masc_note_add"
  then Some "system"
  else None

let family_of name =
  match String.split_on_char '_' name with
  | first :: second :: _ :: _ -> Some (first ^ "_" ^ second)
  | _ -> None

let rows tools =
  let domain_of (tool : Masc.Tui_decode.tool_entry) =
    match domain_of_tool tool.Masc.Tui_decode.tl_name with
    | Some domain -> domain
    | None -> "unsorted"
  in
  let domain_counts = Hashtbl.create 16 in
  List.iter
    (fun tool ->
       let domain = domain_of tool in
       Hashtbl.replace domain_counts domain
         (1 + Option.value ~default:0 (Hashtbl.find_opt domain_counts domain)))
    tools;
  (* The family layer keeps its spelling rule but drops the two-tool minimum:
     domains already do the grouping work, and a lone [masc_add] under
     [work] is a spelling fact worth showing, not noise. *)
  let family_counts = Hashtbl.create 32 in
  List.iter
    (fun (tool : Masc.Tui_decode.tool_entry) ->
       match family_of tool.Masc.Tui_decode.tl_name with
       | None -> ()
       | Some family ->
           Hashtbl.replace family_counts family
             (1 + Option.value ~default:0 (Hashtbl.find_opt family_counts family)))
    tools;
  let rec walk current_domain current_family acc = function
    | [] -> List.rev acc
    | (tool : Masc.Tui_decode.tool_entry) :: rest -> (
        let domain = domain_of tool in
        let acc =
          if current_domain <> Some domain then
            let count =
              Option.value ~default:0 (Hashtbl.find_opt domain_counts domain)
            in
            Domain { name = domain; count } :: acc
          else acc
        in
        match family_of tool.Masc.Tui_decode.tl_name with
        | Some family when current_family <> Some (Some family) ->
            let count =
              Option.value ~default:0 (Hashtbl.find_opt family_counts family)
            in
            walk (Some domain) (Some (Some family))
              (Tool tool :: Family { name = family; count } :: acc)
              rest
        | family ->
            walk (Some domain) (Some family) (Tool tool :: acc) rest)
  in
  (* Group by domain first, then name order inside, so the fixed display
     order reads top to bottom regardless of how the inventory arrived. *)
  let by_domain tools =
    List.sort
      (fun (a : Masc.Tui_decode.tool_entry) (b : Masc.Tui_decode.tool_entry) ->
         let rank name =
           let domain =
             match domain_of_tool name with Some d -> d | None -> "unsorted"
           in
           let order =
             List.find_index (String.equal domain) domain_order
             |> Option.value ~default:(List.length domain_order)
           in
           (order, name)
         in
         compare (rank a.Masc.Tui_decode.tl_name)
           (rank b.Masc.Tui_decode.tl_name))
      tools
  in
  walk None None [] (by_domain tools)

let tool_count rows =
  List.fold_left
    (fun total row ->
       match row with Tool _ -> total + 1 | Domain _ | Family _ -> total)
    0 rows
