module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Coord_assertions - State inspection and assertion-based verification *)

open Masc_domain
open Coord_types

type agent_state = {
  room_set : bool;
  joined : bool;
  task_claimed : bool;
  current_task_set : bool;
  worktree_active : bool;
}

type assertion_kind =
  | Room_set        (* legacy alias: namespace_ready *)
  | Joined
  | Task_claimed
  | Current_task_set
  | Worktree_active

let assertion_kind_to_string = function
  | Room_set -> "room_set"
  | Joined -> "joined"
  | Task_claimed -> "task_claimed"
  | Current_task_set -> "current_task_set"
  | Worktree_active -> "worktree_active"

let all_assertion_kinds =
  [ Room_set; Joined; Task_claimed; Current_task_set; Worktree_active ]

let valid_assertion_strings =
  List.map assertion_kind_to_string all_assertion_kinds

let assertion_kind_of_string_lenient = function
  | "room_set" | "namespace_ready" | "project_ready" -> Some Room_set
  | "joined" -> Some Joined
  | "task_claimed" -> Some Task_claimed
  | "current_task_set" -> Some Current_task_set
  | "worktree_active" -> Some Worktree_active
  | _ -> None

let assertion_fix_hint = function
  | Room_set ->
      "Call masc_start with your project root path."
  | Joined ->
      "Call masc_join to register your agent in the project namespace"
  | Task_claimed ->
      "Claim a task with masc_transition(action=claim) or masc_claim_next"
  | Current_task_set ->
      "Call masc_plan_set_task to choose or re-sync the active task when \
       current_task is unset, stale, or ambiguous"
  | Worktree_active ->
      "Call masc_worktree_create to work in an isolated branch"

let assertion_passes st = function
  | Room_set -> st.room_set
  | Joined -> st.joined
  | Task_claimed -> st.task_claimed
  | Current_task_set -> st.current_task_set
  | Worktree_active -> st.worktree_active

let check_assertion st assertion =
  match assertion_kind_of_string_lenient assertion with
  | Some kind ->
      let passed = assertion_passes st kind in
      let fix_hint = assertion_fix_hint kind in
      `Assoc [
        ("assertion", `String assertion);
        ("passed", `Bool passed);
        ("fix_hint", if passed then `Null else `String fix_hint);
      ]
  | None ->
      `Assoc [
        ("assertion", `String assertion);
        ("passed", `Bool false);
        ("fix_hint",
         `String
           (Printf.sprintf "Unknown assertion: %s (expected one of: %s)"
              assertion (String.concat ", " valid_assertion_strings)));
      ]

let state_to_json st =
  `Assoc [
    ("project_ready", `Bool st.room_set);
    ("namespace_ready", `Bool st.room_set);
    ("room_set", `Bool st.room_set);
    ("joined", `Bool st.joined);
    ("task_claimed", `Bool st.task_claimed);
    ("current_task_set", `Bool st.current_task_set);
    ("worktree_active", `Bool st.worktree_active);
    ("session_active", `Bool false);
  ]

let handle_check ~(inspect_state : context -> agent_state) ctx args =
  let st = inspect_state ctx in
  let default_assertions =
    [ "project_ready"; "joined"; "task_claimed"; "current_task_set"; "worktree_active" ]
  in
  let assertions =
    match Yojson.Safe.Util.member "assertions" args with
    | `List items ->
        let parsed = List.filter_map (function `String s -> Some s | _ -> None) items in
        (match parsed with [] -> default_assertions | _ -> parsed)
    | _ -> default_assertions
  in
  let results = List.map (check_assertion st) assertions in
  let all_passed = List.for_all (fun r ->
    match Yojson.Safe.Util.member "passed" r with
    | `Bool b -> b | _ -> false) results
  in
  let fix_hint =
    if all_passed then `Null
    else
      let first_fail = List.find_opt (fun r ->
        match Yojson.Safe.Util.member "passed" r with
        | `Bool false -> true | _ -> false) results
      in
      match first_fail with
      | Some r -> Yojson.Safe.Util.member "fix_hint" r
      | None -> `Null
  in
  let result =
    `Assoc [
      ("assertions", `List results);
      ("all_passed", `Bool all_passed);
      ("fix_hint", fix_hint);
    ]
  in
  { success = true; message = Yojson.Safe.to_string result }
