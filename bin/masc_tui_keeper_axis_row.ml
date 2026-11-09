type columns =
  | Activity_columns
  | Memory_columns
  | Age_columns

type shape =
  | List_columns
  | Wall_columns
  | Grid of columns

(* The runtime and day views draw the state view's columns until their own are
   drawn; each view has its own arm, so giving a view its columns touches no
   other view. *)
let shape_of_view = function
  | Masc_tui_keeper_list_model.Plain -> List_columns
  | Masc_tui_keeper_list_model.By_state | Masc_tui_keeper_list_model.By_cause
  | Masc_tui_keeper_list_model.By_time -> Grid Activity_columns
  | Masc_tui_keeper_list_model.By_memory -> Grid Memory_columns
  | Masc_tui_keeper_list_model.By_age -> Grid Age_columns
  | Masc_tui_keeper_list_model.By_runtime -> Grid Activity_columns
  | Masc_tui_keeper_list_model.Day_wall -> Wall_columns

type second_line =
  | No_second_line
  | List_detail
  | Failure_chain

let second_line view density (trail : Masc_tui_keeper_trail.trail) =
  match density with
  | Masc_tui_keeper_list_model.One_line -> No_second_line
  | Masc_tui_keeper_list_model.Two_lines -> (
      match view with
      | Masc_tui_keeper_list_model.Plain -> List_detail
      | Masc_tui_keeper_list_model.By_state | Masc_tui_keeper_list_model.By_cause -> (
          match trail with
          | Masc_tui_keeper_trail.Trail_failed _ -> Failure_chain
          | Masc_tui_keeper_trail.Trail_sound -> No_second_line)
      | Masc_tui_keeper_list_model.By_time | Masc_tui_keeper_list_model.By_memory
      | Masc_tui_keeper_list_model.By_age | Masc_tui_keeper_list_model.By_runtime
      | Masc_tui_keeper_list_model.Day_wall -> No_second_line)
