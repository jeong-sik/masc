type builds =
  { cleaned : int
  ; failed : int
  }

type workspace =
  { removed : int
  ; skipped : int
  ; failed : int
  ; freed_kib : int
  ; available_kib : int
  }

type 'report outcome =
  | Reclaimed of 'report
  | Deferred of string
  | Not_running
  | Failed of string

type attempt =
  | Guest_builds of builds outcome
  | Remote_workspace of workspace outcome

let step = function
  | Guest_builds _ -> Keeper_cleanup_step.Guest_builds
  | Remote_workspace _ -> Keeper_cleanup_step.Remote_workspace
;;

type row =
  { keeper : string
  ; attempt : attempt
  ; finished_at : float
  ; reclaimed_at : float option
  }

type exclusion =
  | Without_meta
  | Unreadable of string
  | No_step
  | Switched_off

type disposition =
  | Excluded of exclusion
  | Scheduled of Keeper_cleanup_step.t list
  | Still_running of Keeper_cleanup_step.t list

type owner =
  | Unnamed
  | Named of string * disposition

type step_pass =
  { step : Keeper_cleanup_step.t
  ; enabled : bool
  ; selected : int
  }

type unreadable =
  { keeper : string
  ; reason : string
  }

type pass =
  { started_at : float
  ; interval_sec : float
  ; owners : int
  ; without_meta : int
  ; unreadable : unreadable list
  ; no_step : int
  ; switched_off : int
  ; scheduled : int
  ; still_running : string list
  ; steps : step_pass list
  }

type t =
  { pass : pass option
  ; rows : row list
  }

let empty = { pass = None; rows = [] }

let same_row ~keeper ~step:wanted (row : row) =
  String.equal row.keeper keeper && Keeper_cleanup_step.equal (step row.attempt) wanted
;;

let chosen_steps = function
  | Named (keeper, (Scheduled steps | Still_running steps)) ->
    List.map (fun chosen -> keeper, chosen) steps
  | Unnamed | Named (_, Excluded (Without_meta | Unreadable _ | No_step | Switched_off)) -> []
;;

(* Every count comes from the one list of Owners, so an Owner the pass looked
   at is in exactly one of them. *)
let conclude_pass ~started_at ~interval_sec ~enabled owners =
  let selected = List.concat_map chosen_steps owners in
  let steps =
    List.map
      (fun candidate ->
        { step = candidate
        ; enabled = enabled candidate
        ; selected =
            List.length
              (List.filter
                 (fun (_, chosen) -> Keeper_cleanup_step.equal chosen candidate)
                 selected)
        })
      Keeper_cleanup_step.all
  in
  let count (pass : pass) = function
    | Unnamed | Named (_, Excluded Without_meta) ->
      { pass with without_meta = pass.without_meta + 1 }
    | Named (keeper, Excluded (Unreadable reason)) ->
      { pass with unreadable = ({ keeper; reason } : unreadable) :: pass.unreadable }
    | Named (_, Excluded No_step) -> { pass with no_step = pass.no_step + 1 }
    | Named (_, Excluded Switched_off) -> { pass with switched_off = pass.switched_off + 1 }
    | Named (_, Scheduled _) -> { pass with scheduled = pass.scheduled + 1 }
    | Named (keeper, Still_running _) ->
      { pass with still_running = keeper :: pass.still_running }
  in
  (* Folded from the right, so the two lists keep the order of [owners]. *)
  let pass =
    List.fold_right
      (fun owner pass -> count pass owner)
      owners
      { started_at
      ; interval_sec
      ; owners = List.length owners
      ; without_meta = 0
      ; unreadable = []
      ; no_step = 0
      ; switched_off = 0
      ; scheduled = 0
      ; still_running = []
      ; steps
      }
  in
  let chosen (row : row) =
    List.exists (fun (keeper, chosen) -> same_row ~keeper ~step:chosen row) selected
  in
  pass, fun t -> { pass = Some pass; rows = List.filter chosen t.rows }
;;

let record_attempt ~keeper ~finished_at attempt t =
  let previous, others = List.partition (same_row ~keeper ~step:(step attempt)) t.rows in
  let reclaimed_at =
    match attempt with
    | Guest_builds (Reclaimed _) | Remote_workspace (Reclaimed _) -> Some finished_at
    | Guest_builds (Deferred _ | Not_running | Failed _)
    | Remote_workspace (Deferred _ | Not_running | Failed _) ->
      List.find_map (fun (row : row) -> row.reclaimed_at) previous
  in
  { t with rows = ({ keeper; attempt; finished_at; reclaimed_at } : row) :: others }
;;

let envelope_field = "keeper_cleanup"
let pass_field = "pass"
let rows_field = "rows"
let started_at_field = "started_at"
let interval_sec_field = "interval_sec"
let owners_field = "owners"
let without_meta_field = "without_meta"
let unreadable_field = "unreadable"
let no_step_field = "no_step"
let switched_off_field = "switched_off"
let scheduled_field = "scheduled"
let still_running_field = "still_running"
let steps_field = "steps"
let enabled_field = "enabled"
let selected_field = "selected"
let keeper_field = "keeper"
let step_field = "step"
let finished_at_field = "finished_at"
let reclaimed_at_field = "reclaimed_at"
let outcome_field = "outcome"
let report_field = "report"
let reason_field = "reason"
let reclaimed_name = "reclaimed"
let deferred_name = "deferred"
let not_running_name = "not_running"
let failed_name = "failed"
let cleaned_field = "cleaned"
let removed_field = "removed"
let skipped_field = "skipped"
let failed_field = "failed"
let freed_kib_field = "freed_kib"
let available_kib_field = "available_kib"

let builds_to_json ({ cleaned; failed } : builds) : Yojson.Safe.t =
  `Assoc [ cleaned_field, `Int cleaned; failed_field, `Int failed ]
;;

let workspace_to_json ({ removed; skipped; failed; freed_kib; available_kib } : workspace)
  : Yojson.Safe.t
  =
  `Assoc
    [ removed_field, `Int removed
    ; skipped_field, `Int skipped
    ; failed_field, `Int failed
    ; freed_kib_field, `Int freed_kib
    ; available_kib_field, `Int available_kib
    ]
;;

let outcome_to_fields (report_to_json : 'report -> Yojson.Safe.t)
  : 'report outcome -> (string * Yojson.Safe.t) list
  = function
  | Reclaimed report ->
    [ outcome_field, `String reclaimed_name; report_field, report_to_json report ]
  | Deferred reason -> [ outcome_field, `String deferred_name; reason_field, `String reason ]
  | Not_running -> [ outcome_field, `String not_running_name ]
  | Failed reason -> [ outcome_field, `String failed_name; reason_field, `String reason ]
;;

let row_to_json (row : row) : Yojson.Safe.t =
  let outcome =
    match row.attempt with
    | Guest_builds outcome -> outcome_to_fields builds_to_json outcome
    | Remote_workspace outcome -> outcome_to_fields workspace_to_json outcome
  in
  `Assoc
    ([ keeper_field, `String row.keeper
     ; step_field, `String (Keeper_cleanup_step.to_string (step row.attempt))
     ; finished_at_field, `Float row.finished_at
     ; reclaimed_at_field, Json_util.float_opt_to_json row.reclaimed_at
     ]
     @ outcome)
;;

let step_pass_to_json ({ step; enabled; selected } : step_pass) : Yojson.Safe.t =
  `Assoc
    [ step_field, `String (Keeper_cleanup_step.to_string step)
    ; enabled_field, `Bool enabled
    ; selected_field, `Int selected
    ]
;;

let unreadable_to_json ({ keeper; reason } : unreadable) : Yojson.Safe.t =
  `Assoc [ keeper_field, `String keeper; reason_field, `String reason ]
;;

let pass_to_json (pass : pass) : Yojson.Safe.t =
  `Assoc
    [ started_at_field, `Float pass.started_at
    ; interval_sec_field, `Float pass.interval_sec
    ; owners_field, `Int pass.owners
    ; without_meta_field, `Int pass.without_meta
    ; unreadable_field, `List (List.map unreadable_to_json pass.unreadable)
    ; no_step_field, `Int pass.no_step
    ; switched_off_field, `Int pass.switched_off
    ; scheduled_field, `Int pass.scheduled
    ; ( still_running_field
      , `List (List.map (fun keeper -> `String keeper) pass.still_running) )
    ; steps_field, `List (List.map step_pass_to_json pass.steps)
    ]
;;

let to_json t : Yojson.Safe.t =
  let pass =
    match t.pass with
    | None -> `Null
    | Some pass -> pass_to_json pass
  in
  `Assoc [ pass_field, pass; rows_field, `List (List.map row_to_json t.rows) ]
;;
