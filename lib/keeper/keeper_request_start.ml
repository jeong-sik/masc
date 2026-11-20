module Store = Keeper_turn_log_store
module Scan = Private_jsonl_scan
module Window = Runtime_model_input_tail_window

type log_end =
  | Ended_at of int
  | Unread

type t =
  { trace_id : string
  ; sends_from : int
  ; log_end : log_end
  }

(* Atom labels never go down along the history, so the last message labelled
   below [first_atom] is the last one the request leaves out. *)
let sends_from messages ~first_atom =
  let labelled, (_ : int) = Window.annotate messages in
  let (_ : int), sends_from =
    List.fold_left
      (fun (position, sends_from) ((_ : Agent_core.Types.message), (label : Window.label)) ->
         match label with
         | Atom atom when atom < first_atom -> position + 1, position + 1
         | Atom _ | Pinned -> position + 1, sends_from)
      (0, 0)
      labelled
  in
  sends_from
;;

let turns_path ~config ~keeper_name =
  Store.path_for_keepers_dir
    ~keepers_dir:(Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper_name
;;

let read_error_detail : Store.read_error -> string = function
  | Read_failed { path; detail } -> Printf.sprintf "%s: %s" path detail
  | Row_undecodable { offset; reason = Not_json } ->
    Printf.sprintf "the line at byte %d is not JSON" offset
  | Row_undecodable { offset; reason = Malformed (_ : Keeper_memory_os_types.wire_error) } ->
    Printf.sprintf "the line at byte %d does not decode" offset
  | Log_start_missing -> "no line starts the log"
  | Moved_while_reading -> "the file moved while it was read"
;;

let of_request ~config ~keeper_name ~trace_id ~sends_from =
  let log_end =
    match Store.read_tail (turns_path ~config ~keeper_name) with
    | Ok Nothing_written -> Ended_at 0
    | Ok (Written { rows_end; _ }) -> Ended_at rows_end
    | Error error ->
      Log.Keeper.warn
        ~keeper_name
        "request start: the turn log tail is unreadable, so this start cannot be compared with \
         the Memory read end: %s"
        (read_error_detail error);
      Unread
  in
  { trace_id; sends_from; log_end }
;;

let starts : (string * string, t) Hashtbl.t = Hashtbl.create 16
let mutex = Stdlib.Mutex.create ()
let key ~config ~keeper_name = Workspace.keepers_runtime_dir config, keeper_name

let announce ~config ~keeper_name =
  Keeper_memory_health_input.written
    ~keepers_dir:(Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper_name
;;

let record ~config ~keeper_name start =
  Stdlib.Mutex.protect mutex (fun () ->
    Hashtbl.replace starts (key ~config ~keeper_name) start);
  announce ~config ~keeper_name
;;

let latest ~config ~keeper_name =
  Stdlib.Mutex.protect mutex (fun () -> Hashtbl.find_opt starts (key ~config ~keeper_name))
;;

let forget ~config ~keeper_name =
  Stdlib.Mutex.protect mutex (fun () -> Hashtbl.remove starts (key ~config ~keeper_name));
  announce ~config ~keeper_name
;;

type unresolved =
  | Other_trace
  | Reset_between of { offset : int }
  | Log_end_unread
  | Lines_unread

type standing =
  | Unknown_until_next_request
  | View_unavailable
  | No_read_end
  | Not_behind of
      { sends_from : int
      ; read_end : int
      }
  | Behind of
      { sends_from : int
      ; read_end : int
      }
  | Not_comparable of unresolved

type lines =
  | From_read_unit of
      { line : int
      ; within : Librarian_log.within
      }
  | From_request of { log_end : int }

(* The trace and the turn log come first, as they do for the request's own
   start ([Keeper_covered_point.place_of]): two counts compare only on one
   trace with no [Reset] between them. Which lines lie between depends on
   which was written first, the writer's read unit or the request. *)
let of_view ~lines_since start (view : Librarian_writer.view) =
  match view.covers_through with
  | Librarian_log.Before_first -> No_read_end
  | Librarian_log.Through { line; within } ->
    if not (String.equal view.covered.trace start.trace_id)
    then Not_comparable Other_trace
    else (
      match start.log_end with
      | Unread -> Not_comparable Log_end_unread
      | Ended_at log_end ->
        let lines =
          if line < log_end then From_read_unit { line; within } else From_request { log_end }
        in
        (match (lines_since lines : Keeper_covered_point.unread_lines) with
         | Reset_at { offset } -> Not_comparable (Reset_between { offset })
         | Not_scanned { detail = (_ : string) } -> Not_comparable Lines_unread
         | No_reset ->
           let read_end = view.covered.closed_messages in
           if start.sends_from > read_end
           then Behind { sends_from = start.sends_from; read_end }
           else Not_behind { sends_from = start.sends_from; read_end }))
;;

let resets_from ~turns_path ~from : Keeper_covered_point.unread_lines =
  let step () (scanned : Store.scanned) =
    match scanned.line with
    | Error (_ : Store.undecodable) ->
      Scan.Stop
        (Keeper_covered_point.Not_scanned
           { detail = Printf.sprintf "the turn log line at byte %d does not decode" scanned.at })
    | Ok (Keeper_turn_log.Reset _) ->
      Scan.Stop (Keeper_covered_point.Reset_at { offset = scanned.at })
    | Ok (Keeper_turn_log.Log_started _ | Keeper_turn_log.Opened _ | Keeper_turn_log.Closed _) ->
      Scan.Continue ()
  in
  match Store.fold_from turns_path ~from ~init:() ~f:step with
  | Ok (Scan.Stopped found) -> found
  | Ok (Scan.Reached_end ()) -> Keeper_covered_point.No_reset
  | Error (Scan.Not_a_row_start { from; length }) ->
    Keeper_covered_point.Not_scanned
      { detail =
          Printf.sprintf
            "byte %d starts no line of the turn log, which is %d bytes long"
            from
            length
      }
  | Error (Scan.Scan_failed error) ->
    Keeper_covered_point.Not_scanned { detail = Scan.error_to_string error }
;;

let standing ~(config : Workspace.config) ~keeper_name =
  match latest ~config ~keeper_name with
  | None -> Unknown_until_next_request
  | Some start ->
    (match Keeper_memory_writers.find ~base_path:config.base_path with
     | None -> View_unavailable
     | Some writers ->
       (match Librarian_writers.view writers keeper_name with
        | Error (`Booting | `Stopped (_ : Librarian_store.stop) | `No_writer) -> View_unavailable
        | Ok view ->
          let turns_path = turns_path ~config ~keeper_name in
          of_view start view ~lines_since:(function
            | From_read_unit { line; within } ->
              Keeper_covered_point.read_unread_lines ~turns_path ~line ~within
            | From_request { log_end } -> resets_from ~turns_path ~from:log_end)))
;;
