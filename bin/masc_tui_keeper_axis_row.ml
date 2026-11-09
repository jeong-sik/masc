type before = Hour_pulse | Fact_ages
type current = Activity | Librarian_pass | Update_age
type next = Wait_run_path_lag | Lag_digest_gap | Lag_stale_facts
type axis = { before : before; current : current; next : next }

type shape =
  | List_columns
  | Axis of axis

(* The cells of the state, cause and time views (§2.4). *)
let pulse_activity_next = { before = Hour_pulse; current = Activity; next = Wait_run_path_lag }

(* The runtime and day views draw the state view's cells until their own are
   drawn; each view has its own arm, so giving a view its cells touches no
   other view. *)
let shape_of_view = function
  | Masc_tui_keeper_list_model.Plain -> List_columns
  | Masc_tui_keeper_list_model.By_state | Masc_tui_keeper_list_model.By_cause
  | Masc_tui_keeper_list_model.By_time -> Axis pulse_activity_next
  | Masc_tui_keeper_list_model.By_memory ->
      Axis { before = Hour_pulse; current = Librarian_pass; next = Lag_digest_gap }
  | Masc_tui_keeper_list_model.By_age ->
      Axis { before = Fact_ages; current = Update_age; next = Lag_stale_facts }
  | Masc_tui_keeper_list_model.By_runtime -> Axis pulse_activity_next
  | Masc_tui_keeper_list_model.Day_wall -> Axis pulse_activity_next

type second_line =
  | No_second_line
  | List_detail
  | Failure_chain

let second_line shape density (trail : Masc_tui_keeper_trail.trail) =
  match density with
  | Masc_tui_keeper_list_model.One_line -> No_second_line
  | Masc_tui_keeper_list_model.Two_lines -> (
      match shape with
      | List_columns -> List_detail
      | Axis _ -> (
          match trail with
          | Masc_tui_keeper_trail.Trail_failed _ -> Failure_chain
          | Masc_tui_keeper_trail.Trail_sound -> No_second_line))
