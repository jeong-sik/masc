let ( let* ) = Result.bind
type observation = Waiting of Yojson.Safe.t | Outcome_unknown of Yojson.Safe.t
  | Absent of Yojson.Safe.t
type refusal_stage = Before_dispatch | Execution
type refusal = { stage : refusal_stage; evidence : Yojson.Safe.t }
type change = { before : Yojson.Safe.t; after : Yojson.Safe.t }
type commit = { judgment : Yojson.Safe.t; change : change }
type event = Dispatch_intended | Admission_declined of Yojson.Safe.t | Execution_observed of observation
  | Judgment_retained of Yojson.Safe.t | Commit_intended of change
  | Commit_uncertain of Yojson.Safe.t | Commit_retry_observed of Yojson.Safe.t
  | Commit_observed of Yojson.Safe.t | Commit_conflicted of Yojson.Safe.t
  | Refused of refusal
type phase = Captured | Admission_wait of Yojson.Safe.t | Dispatch_pending of observation option
  | Judged of Yojson.Safe.t | Committing of commit
  | Commit_unknown of commit * Yojson.Safe.t | Finished of commit
  | Conflicted of commit * Yojson.Safe.t | Rejected of refusal
type t = { events_rev : event list; phase : phase }
let captured = {events_rev=[];phase=Captured}
let phase t = t.phase
let events t = List.rev t.events_rev
let object_fields names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) =
      List.sort String.compare names -> Ok fields
  | _ -> Error "invalid request progress event fields"
let envelope kind fields = `Assoc (("event", `String kind) :: fields)
let evidence_event kind evidence = envelope kind ["evidence",evidence]
let event_to_json = function
  | Dispatch_intended -> envelope "dispatch_intended" []
  | Admission_declined evidence -> evidence_event "admission_declined" evidence
  | Execution_observed (Waiting evidence) -> evidence_event "waiting" evidence
  | Execution_observed (Outcome_unknown evidence) -> evidence_event "execution_unknown" evidence
  | Execution_observed (Absent evidence) -> evidence_event "worker_absent" evidence
  | Judgment_retained judgment -> envelope "judgment_retained" ["judgment",judgment]
  | Commit_intended change -> envelope "commit_intended" ["before",change.before;"after",change.after]
  | Commit_uncertain evidence -> evidence_event "commit_unknown" evidence
  | Commit_retry_observed before -> envelope "commit_retry_observed" ["before",before]
  | Commit_observed after -> envelope "commit_observed" ["after",after]
  | Commit_conflicted observed -> envelope "commit_conflicted" ["observed",observed]
  | Refused {stage;evidence} ->
    let stage = match stage with Before_dispatch -> "before_dispatch" | Execution -> "execution" in
    envelope "refused" ["stage",`String stage;"evidence",evidence]
let event_of_json json =
  let* json = Lane_addon_action.canonical json in
  let* kind = match json with
    | `Assoc fields -> (match List.assoc_opt "event" fields with
        | Some (`String kind) -> Ok kind | _ -> Error "missing request progress event")
    | _ -> Error "request progress event must be an object" in
  let fields names = object_fields ("event" :: names) json in
  let evidence ctor = let* fields = fields ["evidence"] in Ok (ctor (List.assoc "evidence" fields)) in
  let value key ctor = let* fields = fields [key] in Ok (ctor (List.assoc key fields)) in
  match kind with
  | "dispatch_intended" -> let* _ = fields [] in Ok Dispatch_intended
  | "admission_declined" -> evidence (fun value -> Admission_declined value)
  | "waiting" -> evidence (fun value -> Execution_observed (Waiting value))
  | "execution_unknown" -> evidence (fun value -> Execution_observed (Outcome_unknown value))
  | "worker_absent" -> evidence (fun value -> Execution_observed (Absent value))
  | "judgment_retained" -> value "judgment" (fun value -> Judgment_retained value)
  | "commit_intended" -> let* fields = fields ["before";"after"] in
    Ok (Commit_intended {before=List.assoc "before" fields;after=List.assoc "after" fields})
  | "commit_unknown" -> evidence (fun value -> Commit_uncertain value)
  | "commit_retry_observed" -> value "before" (fun value -> Commit_retry_observed value)
  | "commit_observed" -> value "after" (fun value -> Commit_observed value)
  | "commit_conflicted" -> value "observed" (fun value -> Commit_conflicted value)
  | "refused" -> let* fields = fields ["stage";"evidence"] in
    let* stage = match List.assoc "stage" fields with
      | `String "before_dispatch" -> Ok Before_dispatch
      | `String "execution" -> Ok Execution
      | _ -> Error "unknown request refusal stage" in
    Ok (Refused {stage;evidence=List.assoc "evidence" fields})
  | _ -> Error "unknown request progress event"
let invalid () = Error "event does not follow the original request progress"
let step phase = function
  | Dispatch_intended -> (match phase with
      | Captured | Admission_wait _ -> Ok (Dispatch_pending None)
      | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Finished _ | Conflicted _ | Rejected _ -> invalid ())
  | Admission_declined evidence -> (match phase with
      | Dispatch_pending None -> Ok (Admission_wait evidence)
      | Captured | Admission_wait _ | Dispatch_pending (Some _) | Judged _
      | Committing _ | Commit_unknown _ | Finished _ | Conflicted _ | Rejected _ -> invalid ())
  | Execution_observed observation -> (match phase with
      | Dispatch_pending _ -> Ok (Dispatch_pending (Some observation))
      | Captured | Admission_wait _ | Judged _ | Committing _ | Commit_unknown _
      | Finished _ | Conflicted _ | Rejected _ -> invalid ())
  | Judgment_retained judgment -> (match phase with
      | Dispatch_pending _ -> Ok (Judged judgment)
      | Captured | Admission_wait _ | Judged _ | Committing _ | Commit_unknown _
      | Finished _ | Conflicted _ | Rejected _ -> invalid ())
  | Commit_intended change -> (match phase with
      | Judged judgment -> Ok (Committing {judgment;change})
      | Captured | Admission_wait _ | Dispatch_pending _ | Committing _ | Commit_unknown _
      | Finished _ | Conflicted _ | Rejected _ -> invalid ())
  | Commit_uncertain evidence -> (match phase with
      | Committing commit | Commit_unknown (commit,_) -> Ok (Commit_unknown (commit,evidence))
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Finished _ | Conflicted _ | Rejected _ -> invalid ())
  | Commit_retry_observed before -> (match phase with
      | Commit_unknown (commit,_) ->
        if Yojson.Safe.equal before commit.change.before
            && not (Yojson.Safe.equal before commit.change.after) then Ok (Committing commit)
        else Error "commit retry observation does not establish the original before-state"
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
      | Finished _ | Conflicted _ | Rejected _ -> invalid ())
  | Commit_observed after -> (match phase with
      | Committing commit | Commit_unknown (commit,_) ->
        if Yojson.Safe.equal after commit.change.after then Ok (Finished commit)
        else Error "commit observation does not match the original expected state"
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Finished _ | Conflicted _ | Rejected _ -> invalid ())
  | Commit_conflicted observed -> (match phase with
      | Committing commit | Commit_unknown (commit,_) ->
        if Yojson.Safe.equal observed commit.change.after then Error "expected state is a confirmation, not a conflict"
        else Ok (Conflicted (commit,observed))
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Finished _ | Conflicted _ | Rejected _ -> invalid ())
  | Refused refusal -> (match phase,refusal.stage with
      | (Captured | Admission_wait _),Before_dispatch | Dispatch_pending _,Execution -> Ok (Rejected refusal)
      | (Captured | Admission_wait _),Execution | Dispatch_pending _,Before_dispatch
      | (Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _ | Rejected _),
        (Before_dispatch | Execution) -> invalid ())
let append t event =
  let* event = event_of_json (event_to_json event) in
  let* phase = step t.phase event in Ok {events_rev=event :: t.events_rev;phase}
let to_json t = `List (List.map event_to_json (events t))
let of_json = function
  | `List events -> List.fold_left (fun state json ->
      let* state = state in let* event = event_of_json json in
      let* phase = step state.phase event in Ok {events_rev=event :: state.events_rev;phase}) (Ok captured) events
  | _ -> Error "request progress must be an ordered event array"
