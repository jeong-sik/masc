type t =
  { history_bytes : int
  ; internal_bytes : int
  ; chat_bytes : int
  ; external_rows : int
  }

type store =
  | Official_history
  | Official_internal
  | Chat
  | External

let store_to_string = function
  | Official_history -> "official-client history"
  | Official_internal -> "official-client internal history"
  | Chat -> "chat"
  | External -> "external attention"
;;

type error =
  { store : store
  ; path : string
  ; detail : string
  }

let error_to_string { store; path; detail } =
  Printf.sprintf "%s store %s: %s" (store_to_string store) path detail
;;

let settled = function
  | Fs_compat.Private_file_succeeded value
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { value; _ } -> Ok value
  | Fs_compat.Private_file_failed error
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; _ } -> Error error
;;

(* The locked window read finds the last line break from the end of the file.
   The one row it is asked for is not used. *)
let after_last_line_break store path =
  match
    settled
      (Fs_compat.read_private_jsonl_window_locked_result path ~from:0 ~max_rows:1
         ~previous_row_wanted:No_previous_row)
  with
  | Ok Fs_compat.Private_jsonl_window.Window_missing -> Ok 0
  | Ok (Window_present { rows_end; _ }) -> Ok rows_end
  | Error error ->
    Error { store; path; detail = Fs_compat.Private_jsonl_rows.error_to_string error }
;;

let whole_rows store path =
  match
    settled
      (Fs_compat.fold_private_jsonl_locked_result path ~init:0 ~f:(fun rows (_ : string) ->
         rows + 1))
  with
  | Ok Fs_compat.Private_jsonl_fold.Missing -> Ok 0
  | Ok (Present { value; _ }) -> Ok value
  | Error (Fs_compat.Private_jsonl_fold.Read_error error) ->
    Error { store; path; detail = Fs_compat.Private_jsonl_rows.error_to_string error }
  | Error Fs_compat.Private_jsonl_fold.Snapshot_changed ->
    Error { store; path; detail = "the file changed while its rows were counted" }
;;

let read ~session_dir ~base_path ~keeper_name =
  let ( let* ) = Result.bind in
  let* history_bytes =
    after_last_line_break Official_history (Keeper_turn_fragments.path ~session_dir Main)
  in
  let* internal_bytes =
    after_last_line_break Official_internal (Keeper_turn_fragments.path ~session_dir Internal)
  in
  let* chat_bytes =
    after_last_line_break Chat (Keeper_chat_store.chat_path ~base_dir:base_path ~keeper_name)
  in
  let* external_rows =
    whole_rows External (Keeper_external_attention.attention_path ~base_path ~keeper_name)
  in
  Ok { history_bytes; internal_bytes; chat_bytes; external_rows }
;;
