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

type concern =
  | Attempt_failed of string
  | Entries_left of int

let left_behind failed = if failed > 0 then Some (Entries_left failed) else None

let concern = function
  | Guest_builds (Failed reason) | Remote_workspace (Failed reason) ->
    Some (Attempt_failed reason)
  | Guest_builds (Reclaimed ({ failed; cleaned = _ } : builds)) -> left_behind failed
  | Remote_workspace
      (Reclaimed
        ({ failed; removed = _; skipped = _; freed_kib = _; available_kib = _ } : workspace))
    -> left_behind failed
  | Guest_builds (Deferred _ | Not_running) | Remote_workspace (Deferred _ | Not_running) ->
    None
;;
