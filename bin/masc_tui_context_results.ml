(* The Context inspector's async answers: the type [Masc_tui_async_protocol]
   carries in [Context_msg], and how each answer changes the pane. *)

open Masc_tui_types

type msg =
  | Context_inspector_loaded of
      int * string * Masc_tui_context_inspector.reading
  | Context_inspector_part_loaded of
      Masc_tui_context_inspector.part_key Masc_tui_fetched.request
      * (string, string) result

type answer_kind = Read

let answer_kind = function
  | Context_inspector_loaded _ | Context_inspector_part_loaded _ -> Read

let apply state = function
  | Context_inspector_loaded (generation, keeper_name, reading) ->
      if
        state.context_inspector_open
        && generation = state.context_inspector_generation
        && Option.exists (String.equal keeper_name)
             state.context_inspector_keeper
      then begin
        let previous = Option.map snd state.context_inspector_reading in
        let reading = Masc_tui_context_inspector.merge_progress
            ~previous reading in
        let proof_active =
          state.context_inspector_tab = Masc_tui_context_inspector.Input_map
          || (state.context_inspector_tab = Masc_tui_context_inspector.Response
              && state.context_inspector_response_return = Masc_tui_context_inspector.Input_map)
        in
        let proof_changed = proof_active
          && Masc_tui_context_inspector.proof_scroll_should_reset
               ~target:state.context_inspector_target ~previous reading in
        if Masc_tui_context_inspector.page_scroll_should_reset ~previous reading
        then begin
          state.context_inspector_scroll <- 0;
          state.context_inspector_response_scroll <- 0
        end;
        if proof_changed then begin
          state.context_inspector_scroll <- 0;
          state.context_inspector_cursor <- 0;
          state.context_inspector_detail_scroll <- 0;
          state.context_inspector_exact <- None;
          supersede_context_inspector_part_load state None;
          (* Withdraw the in-flight read, retaining a completed immutable part
             for the same turn and digest if the observation returns. *)
          state.context_inspector_part <-
            Masc_tui_fetched.cancel_pending ~reason:"Proof source changed"
              state.context_inspector_part
        end;
        state.context_inspector_loading <- Masc_tui_context_inspector.is_loading reading;
        state.context_inspector_reading <- Some (keeper_name, reading);
        state.context_inspector_read_at <- Some (Unix.gettimeofday ());
        (* A refresh reads a failed part again. A part already read stays:
           the same turn, index and digest name the same bytes. *)
        (match Masc_tui_fetched.current state.context_inspector_part with
         | Some (_, Masc_tui_fetched.Failed _) ->
             state.context_inspector_part <-
               Masc_tui_fetched.clear state.context_inspector_part
         | Some
             ( _
             , ( Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
               | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Stale _ ) )
         | None -> ())
      end
  | Context_inspector_part_loaded (request, result) ->
      (* An answer for a part the pane moved past is dropped by [complete]. *)
      state.context_inspector_part <-
        Masc_tui_fetched.complete
          ~equal:Masc_tui_context_inspector.same_part_key
          state.context_inspector_part request result
