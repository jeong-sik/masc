(** Task-state probing detection for keeper_bash command-shape guidance. *)

open Keeper_shell_bash_words

let lowercase_contains haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec loop i =
    if n_len = 0
    then true
    else if i + n_len > h_len
    then false
    else if String.sub haystack i n_len = needle
    then true
    else loop (i + 1)
  in
  loop 0
;;

let task_state_file_probe_command_names =
  [ "cat"; "head"; "tail"; "ls"; "find"; "rg"; "grep"; "test"; "[" ]
;;

let looks_like_task_state_path_token text =
  let text = String.lowercase_ascii text in
  let scoped_masc = lowercase_contains text ".masc/" in
  let scoped_worktree = lowercase_contains text ".worktrees/" in
  (scoped_worktree && lowercase_contains text ".task.json")
  ||
  (scoped_masc
   && (lowercase_contains text "backlog.json"
       || lowercase_contains text "/tasks"
       || lowercase_contains text "current_task.json"))
;;

let rec mentions_task_state_file cmd =
  let words = shell_words_with_boundaries cmd in
  let rec loop = function
    | word :: rest when word.starts_command ->
      let command_words = strip_command_wrappers (word :: rest) in
      (match command_words with
       | bin :: args
         when List.mem (command_name bin.text) task_state_file_probe_command_names
              && List.exists
                   (fun arg -> looks_like_task_state_path_token arg.text)
                   args ->
         true
       | _ -> loop rest)
    | _ :: rest -> loop rest
    | [] -> false
  in
  loop words
  ||
  match shell_c_payload words with
  | Some payload -> mentions_task_state_file payload
  | None -> false
;;

let rec looks_like_http_probe cmd =
  let task_api_url text =
    (lowercase_contains text "localhost"
     || lowercase_contains text Masc_network_defaults.masc_http_default_host)
    && (lowercase_contains text "/api/tasks" || lowercase_contains text "api/tasks")
  in
  let http_client_names = [ "curl"; "wget"; "http"; "https"; "xh" ] in
  let words = shell_words_with_boundaries cmd in
  let rec loop = function
    | word :: rest when word.starts_command ->
      let command_words = strip_command_wrappers (word :: rest) in
      (match command_words with
       | bin :: args
         when List.mem (command_name bin.text) http_client_names
              && List.exists (fun arg -> task_api_url arg.text) args ->
         true
       | _ -> loop rest)
    | _ :: rest -> loop rest
    | [] -> false
  in
  loop words
  ||
  match shell_c_payload words with
  | Some payload -> looks_like_http_probe payload
  | None -> false
;;

let looks_like_discovery cmd =
  let task_state_marker =
    lowercase_contains cmd "backlog"
    || lowercase_contains cmd ".masc"
    || (lowercase_contains cmd "task" && lowercase_contains cmd ".json")
  in
  mentions_task_state_file cmd
  || looks_like_http_probe cmd
  ||
  ((lowercase_contains cmd "find repos" || lowercase_contains cmd "find .")
   && task_state_marker)
  ||
  (lowercase_contains cmd "rg "
   && lowercase_contains cmd "repos"
   && task_state_marker)
;;

let hint =
  "Do not inspect task state by guessing .masc/backlog.json or repo-local \
   backlog/task files from keeper_bash. Use keeper_tasks_list for \
   task/backlog state and keeper_context_status for current_task_id/sandbox \
   paths."
;;

let alternatives =
  [ "keeper_tasks_list include_done=false"
  ; "keeper_context_status"
  ; "keeper_task_claim {}"
  ]
;;
