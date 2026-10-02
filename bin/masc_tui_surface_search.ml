(** Searchable surface rows and match counts. *)

open Masc_tui_types

let code_file_search_focused (state : state) =
  not state.repository_changes_open
  && state.code_focus_file = Right_pane
  && not state.code_history_open && not state.code_diff_open && not state.code_notes_open

(* The Git changes overlay before the surface it is drawn over. It draws over
   three surfaces -- [scrolled_surface_rows] names them -- and an arm per
   surface answered for two of them: over the Keepers roster the rows here
   were keeper names, so a settled query counted the hidden roster and [n]
   stepped the keeper cursor instead of landing on a matching path.
   [goto_surface] closes the overlay on any move to another surface, which is
   what makes the flag alone enough to say it is on screen. Its diff replaces
   the list with text, and text has no row for a cursor to name. *)
let surface_row_texts (state : state) : surface -> string list option =
 fun surface ->
  if state.repository_changes_open then
    (match state.repository_changes_diff_path with
     | Some _ -> None
     | None ->
         Option.map
           (fun s ->
             List.map (fun row -> row.Tui_decode.rc_path)
               s.Tui_decode.rcs_changes)
           state.repository_changes)
  else
  match surface with
  | Keepers Keeper_list ->
      Some (List.map (fun (k : keeper) -> k.k_name) state.keepers)
  | Keepers Keeper_detail when state.context_inspector_open ->
      (* The request tab's item labels, so the surface search (/) walks the
         same rows j/k moves. Other tabs keep no searchable list. *)
      if
        state.context_inspector_tab = Masc_tui_context_inspector.Exact_input
      then
        match state.context_inspector_reading with
        | Some
            ( _
            , Masc_tui_context_inspector.Turn_read
                { provider_input = Ok input; _ } ) ->
            let labels =
              List.map
                (fun (item : Masc_tui_context_inspector.exact_input_item) ->
                   Masc_tui_context_inspector.exact_input_label item.kind)
                (Masc_tui_context_inspector.exact_input_items input)
            in
            (match labels with [] -> None | _ -> Some labels)
        | _ -> None
      else None
  | Lanes ->
      (match state.lanes_mode with
       | Lanes_run_list _ | Lanes_run_detail _ | Lanes_measurement_detail _ -> None
       | Lanes_overview ->
           let standalone =
             match state.standalone_lanes with
             | None -> []
             | Some snapshot ->
                 List.map
                   (fun (lane : Tui_decode.standalone_lane) -> lane.sl_label)
                   snapshot.Tui_decode.sls_lanes
           in
           (match standalone with [] -> None | _ -> Some standalone))
  | Clients ->
      let names =
        match state.clients_surface with
        | None -> []
        | Some snapshot ->
            List.map
              (fun (row : Tui_decode.client_row) -> row.Tui_decode.cr_name)
              snapshot.Tui_decode.cls_clients
      in
      (match names with [] -> None | _ -> Some names)
  | Verification ->
      if Option.is_some state.verification_detail_request_id then None
      else
        Option.map
          (fun s ->
            List.map
              (fun r ->
                r.Tui_decode.vr_task_id ^ " " ^ r.Tui_decode.vr_task_title ^ " "
                ^ r.Tui_decode.vr_submitted_by)
              s.Tui_decode.vs_requests)
          state.verification
  | Harness ->
      if Option.is_some state.harness_detail then None
      else Option.map
        (fun s ->
          List.map
            (fun v -> v.Tui_decode.hv_task_id ^ " " ^ v.Tui_decode.hv_task_title)
            s.Tui_decode.hs_verdicts)
        state.harness
  | Repositories ->
      (* Workspace Activity replaces the repository list with one repository's
         own rows and its own cursor, and its handler takes every key the
         surface has, "/" and n and N among them. The rows here are the list
         behind it, which a settled query would then count and report. *)
      if Option.is_some state.workspace_activity_repo then None
      else
        Option.map
          (fun s ->
            List.map
              (fun r ->
                r.Tui_decode.rp_name ^ " " ^ r.Tui_decode.rp_default_branch)
              s.Tui_decode.rs_repositories)
          state.repositories
  | Memory ->
      if Option.is_some state.memory_facts_keeper then
        Option.map
          (fun _ ->
             let rows = memory_fact_rows state in
             (* The exact filter projection, including field order: a phrase
                crossing a field boundary must remain countable and reachable. *)
             List.map memory_fact_search_text rows)
          (memory_facts_snapshot state)
      else
        Option.map
          (* Keeper id and the state label, which is the pair
             [visible_memory_keepers] keeps a row for. Leaving the label out
             kept rows on screen that the search could neither count nor
             reach. *)
          (fun _ ->
            List.map
              (fun k ->
                k.Masc.Tui_decode_memory_health.mkh_keeper_id ^ " "
                ^ memory_state_label (memory_state k))
              (visible_memory_keepers state))
          state.memory_health
  | Connectors when Option.is_some (browser_lane_on_screen state) -> None
  | Connectors ->
      Option.map
        (fun s ->
          List.map
            (fun c -> c.Masc.Tui_decode_connectors.cn_id ^ " " ^ c.Masc.Tui_decode_connectors.cn_display_name)
            s.Masc.Tui_decode_connectors.cs_connectors)
        state.connectors
  | Runtime ->
      if Option.is_some state.runtime_detail_target then None
      else
      Option.map
        (fun s ->
          match state.runtime_mode with
          | Runtime_lanes ->
              List.map
                (fun c ->
                  c.Tui_decode.rcr_lane_id ^ " "
                  ^ c.Tui_decode.rcr_runtime.Tui_decode.ro_id)
                s.Tui_decode.rss_candidates
          | Runtime_all ->
              List.map (fun runtime -> runtime.Tui_decode.ro_id)
                s.Tui_decode.rss_resolved.Tui_decode.rrs_runtimes)
        state.runtime_surface
  | System_logs ->
      if Option.is_some state.system_logs_detail_seq then None
      else Option.map
        (fun _ ->
          visible_system_log_entries state
          |> List.map
            (fun e ->
              e.Tui_decode.sl_module ^ " "
              ^ Option.value ~default:"" e.Tui_decode.sl_keeper
              ^ " " ^ e.Tui_decode.sl_message))
        state.system_logs
  | Code ->
      (* With a file focused (and no file overlay over it), "/" searches the
         file's lines; the tree remains the default search list. The Git
         changes overlay is answered above, before any surface. *)
      if code_file_search_focused state then
        (match Masc_tui_fetched.current state.code_file with
         | Some (_, Masc_tui_fetched.Ready rows) ->
           Some
             (Array.to_list
                (Array.map
                   (fun segments -> String.concat "" (List.map fst segments))
                   rows))
         (* Nothing to search through while the file is still being read, and
            nothing to search through if it failed. *)
         | Some (_, (Masc_tui_fetched.Loading | Masc_tui_fetched.Stale _ | Masc_tui_fetched.Failed _))
         | Some (_, Masc_tui_fetched.Absent)
         | None -> None)
      else
        Some
          (List.map
             (fun (n : Tui_decode.workspace_tree_node) -> n.Tui_decode.wt_label)
             (code_entries state))
  (* Cursorless or otherwise-navigated surfaces: no row list to search. *)
  (* The list, and only while the list is the pane: reading a post or
     writing one draws something else, and "/" there would move a cursor
     nobody can see. The text is what identifies a row -- its id, who wrote
     it, its title -- which is what a reader has in mind when they reach for
     the key. *)
  | Board ->
      (match state.board_mode with
       | Board_read _ | Board_compose -> None
       | Board_list ->
           (match state.board_posts with
            | [] -> None
            | posts ->
                Some
                  (List.map
                     (fun (post : board_post) ->
                       post.bp_id ^ " " ^ post.bp_author ^ " " ^ post.bp_title)
                     posts)))
  (* The goals the filter and sort left on screen, in the order they are
     drawn: the cursor counts positions in that list, not in the snapshot. *)
  | Planning ->
      (match state.planning_mode with
       | Planning_detail _ -> None
       | Planning_list
         when Masc_tui_overview_tasks.is_focused state.task_focus ->
           (match Masc_tui_overview_tasks.work_rows state.tasks with
            | [] -> None
            | rows ->
                Some
                  (List.map
                     (fun (task : Tui_decode.task) -> task.id ^ " " ^ task.title)
                     rows))
       | Planning_list ->
           Option.bind state.planning (fun snapshot ->
               match
                 planning_visible_goals ~filter:state.planning_filter
                   ~sort:state.planning_sort snapshot.pl_goals
               with
               | [] -> None
               | goals ->
                   Some
                     (List.map
                        (fun (goal : planning_goal) ->
                          goal.pg_id ^ " " ^ goal.pg_title)
                        goals)))
  (* Approvals is absent on purpose. Its rows would search well, but [n] on
     that surface is deny, unarmed and immediate: offering "/" there invites
     the reflex that follows it, and on this surface that reflex refuses an
     approval instead of stepping to the next match. Verification met the
     same collision and moved its rejection to [x]; until Approvals makes
     that call, the safe answer is no row search. *)
  (* Two lists that grew a row cursor with the jump keys and had no way to be
     searched. Each is named by what an operator has in mind reaching for the
     key: the run and who called it, the file that was written.

     Approvals and Schedules are not here, and the reason is [n]. The key
     that steps to the next match is the key those two surfaces give to
     "deny this approval" and "write a new schedule". A search whose own
     follow-through refuses an approval is worse than no search, so offering
     it there needs a different step key rather than another arm here
     (#35306). *)
  | Fusion -> (
      match state.fusion_mode with
      | Fusion_detail _ | Fusion_historical_detail _ -> None
      | Fusion_list -> (
          match Masc_tui_fusion_model.fusion_list_entries state with
          | [] -> None
          | entries ->
              Some
                (List.map
                   (fun entry ->
                     match entry with
                     | Masc.Tui_decode_fusion.Fusion_retained_run run ->
                         run.Masc.Tui_decode_fusion.fur_run_id ^ " "
                         ^ run.Masc.Tui_decode_fusion.fur_keeper ^ " "
                         ^ run.Masc.Tui_decode_fusion.fur_preset
                     | Masc.Tui_decode_fusion.Fusion_historical_evidence evidence ->
                         evidence.Masc.Tui_decode_fusion.fhe_post_id ^ " "
                         ^ evidence.Masc.Tui_decode_fusion.fhe_title)
                   entries)))
  | Changes when Option.is_some (opened_file_change state) -> None
  | Changes -> (
      match state.changes with
      | None -> None
      | Some snapshot -> (
          match snapshot.Tui_decode.fcs_changes with
          | [] -> None
          | changes ->
              (* The address the row is drawn under, read from the one place
                 that spells it. A second match here would find a row under an
                 address the pane never shows. *)
              Some
                (List.map
                   (fun change -> Tui_decode.file_change_address change)
                   changes)))
  (* The list pane only. With the text focused j/k scrolls the reading and
     there is no row cursor for a match to land on, so the same condition the
     cursor arm reads answers here: a search offered on one focus and silent
     on the other would be the drift this pairing exists to prevent. *)
  | Resources when state.resource_focus = Left_pane ->
      Option.map (List.map Masc_tui_mcp.display_name) state.resources_list
  | Overview | Acting | Metrics | Keepers _ | Approvals | Schedules
  | Resources | Config | Tools ->
      None

(* The fetched file's rows are replaced when content changes, like the lists
   behind [chat_rows_memo]. Keep one derived reading keyed by that identity
   and the query, not by the pane or path: a repaint reuses it, while a refresh
   of the same file must recount. Other surfaces retain their live projection. *)
type code_search_count_memo =
  { csc_rows : (string * string) list array
  ; csc_query : string
  ; csc_count : int
  }

let code_search_count_memo : code_search_count_memo option ref = ref None

module For_testing = struct
  type memo_snapshot = code_search_count_memo option
  let code_search_count_snapshot () = !code_search_count_memo
end

let code_file_search_count ~query rows =
  match !code_search_count_memo with
  | Some memo when memo.csc_rows == rows && String.equal memo.csc_query query ->
      memo.csc_count
  | Some _ | None ->
      let count =
        Array.fold_left (fun count segments ->
          let text = String.concat "" (List.map fst segments) in
          if Masc_tui_pick_list.lowercase_contains ~needle:query text then count + 1 else count) 0 rows
      in
      code_search_count_memo := Some { csc_rows = rows; csc_query = query; csc_count = count };
      count

let surface_search_count (state : state) surface ~query =
  let query = surface_search_query surface query in
  match surface with
  | Code when code_file_search_focused state ->
      (match Masc_tui_fetched.current state.code_file with
       | Some (_, Masc_tui_fetched.Ready rows) ->
           Some (if String.equal query "" then 0 else code_file_search_count ~query rows)
       | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading | Masc_tui_fetched.Stale _ | Masc_tui_fetched.Failed _))
       | None -> None)
  | _ ->
      Option.map
        (fun rows ->
          if String.equal query "" then 0
          else List.fold_left (fun count text ->
            if Masc_tui_pick_list.lowercase_contains ~needle:query text then count + 1 else count) 0 rows)
        (surface_row_texts state surface)
