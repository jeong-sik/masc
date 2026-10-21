module Capture = Workspace_memory_execution_capture
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Receipt = Lane_addon_request_receipt
module Exact = Lane_addon_exact
let ( let* ) = Result.bind
type registration = {run_id:string;actor:string;input:Yojson.Safe.t;receipt:Receipt.receipt}
let same_receipt left right =
  if Yojson.Safe.equal (Receipt.to_json left) (Receipt.to_json right) then Ok ()
  else Error "Curator observer receipt differs from its complete original domain binding"
let consistent publication receipt = match publication with
  | Receipt.Unobserved -> Ok ()
  | Receipt.Pending original | Receipt.Acknowledged original -> same_receipt original receipt
let binding ~capture ~(original:Owner.retained) =
  let* input = Lane_addon_action.canonical (Capture.to_json capture) in
  let destination = Capture.destination capture in
  let* installation = Owner.installation_of_id destination.installation_id in
  let* () = match installation with Owner.Configuration _ -> Ok ()
    | Owner.Manual _ -> Error "Curator observation requires its original configured installation" in
  if String.equal original.scope Capture.scope
      && String.equal original.request_id (Capture.Request_id.to_string (Capture.request_id capture))
      && String.equal original.installation_id destination.installation_id
      && String.equal original.package_id Capture.package_id
      && String.equal original.package_id destination.package_id
      && String.equal original.tool Capture.tool && String.equal original.tool destination.tool
      && Yojson.Safe.equal input original.request
      && String.equal original.request_digest (Lane_addon_store.digest (Yojson.Safe.to_string input))
  then Ok input else Error "Curator observer receipt differs from its original captured owner"
let registration ~capture ~original ~observed_at =
  let* input = binding ~capture ~original in
  let run_id = "workspace-curator-" ^ original.Owner.request_id in
  let actor = Capture.base_path capture in
  let payload = `Assoc ["schema",`String "workspace.memory.observer.registration.v1";
    "run_id",`String run_id;"request_id",`String original.request_id;
    "request_digest",`String original.request_digest;"actor",`String actor;"input",input;
    "timing_basis",`String "first_observer_observation"] in
  let* receipt = Receipt.make ~observed_at ~payload in
  let* () = consistent (Progress.observer original.progress).registration receipt in
  Ok {run_id;actor;input;receipt}
let restore_registration ~capture ~original (receipt:Receipt.receipt) =
  let* expected = registration ~capture ~original ~observed_at:receipt.observed_at in
  let* () = same_receipt receipt expected.receipt in Ok expected
type disposition = Confirmed_commit of Progress.commit
  | Domain_conflict of Progress.commit * Yojson.Safe.t
  | Before_dispatch_refusal of Yojson.Safe.t | Execution_refusal of Exact.final
type completion = {registration:registration;disposition:disposition;selected_slot:string option;
  provider_usage:Exact.usage option;receipt:Receipt.receipt}
let checked_commit capture (commit:Progress.commit) =
  let* _,change = Capture.commit_plan capture ~judgment:commit.judgment in
  if Yojson.Safe.equal change.before commit.change.before && Yojson.Safe.equal change.after commit.change.after
  then Ok () else Error "Curator observation commit differs from its original complete before/after plan"
let disposition capture phase = match phase with
  | Progress.Finished commit -> let* () = checked_commit capture commit in Ok (Confirmed_commit commit)
  | Progress.Conflicted (commit,observed) ->
    let* () = checked_commit capture commit in Ok (Domain_conflict (commit,observed))
  | Progress.Rejected {stage=Before_dispatch;evidence}
  | Progress.Subdividing ({stage=Before_dispatch;evidence},_)
  | Progress.Subdivided ({stage=Before_dispatch;evidence},_) -> Ok (Before_dispatch_refusal evidence)
  | Progress.Rejected {stage=Execution;evidence}
  | Progress.Subdividing ({stage=Execution;evidence},_)
  | Progress.Subdivided ({stage=Execution;evidence},_) ->
    let* final = Exact.final_of_json ~schema:(Capture.output_schema capture) evidence in
    (match final with
     | Exact.Call_final (Exact.Answered _) -> Error "An original refusal cannot contain an Answered judgment"
     | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
     | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused -> Ok (Execution_refusal final))
  | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _
  | Progress.Committing _ | Progress.Commit_unknown _ -> Error "Curator observation has no confirmed terminal domain fact"
let commit_json (commit:Progress.commit) = `Assoc ["judgment",commit.judgment;
  "before",commit.change.before;"after",commit.change.after]
let disposition_json = function
  | Confirmed_commit commit -> `Assoc ["kind",`String "committed";"commit",commit_json commit]
  | Domain_conflict (commit,observed) -> `Assoc ["kind",`String "domain_conflict";
      "commit",commit_json commit;"observed",observed]
  | Before_dispatch_refusal evidence -> `Assoc ["kind",`String "before_dispatch_refusal";"evidence",evidence]
  | Execution_refusal final -> `Assoc ["kind",`String "execution_refusal";"final",Exact.final_to_json final]
let provider capture = function
  | Confirmed_commit commit | Domain_conflict (commit,_) ->
    let* final = Exact.final_of_json ~schema:(Capture.output_schema capture) commit.judgment in
    (match final with
     | Exact.Call_final (Exact.Answered {slot;usage;_}) -> Ok (Some slot,usage)
     | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
     | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused ->
       Error "An original committed judgment must be Answered")
  | Before_dispatch_refusal _ | Execution_refusal _ -> Ok (None,None)
let completion ~capture ~original ~(registration:registration) ~observed_at =
  let* registration = restore_registration ~capture ~original registration.receipt in
  let* () = match (Progress.observer original.progress).registration with
    | Receipt.Pending retained | Receipt.Acknowledged retained -> same_receipt retained registration.receipt
    | Receipt.Unobserved -> Error "Retain the original observer registration before its completion" in
  let* disposition = disposition capture (Progress.phase original.Owner.progress) in
  let* selected_slot,provider_usage = provider capture disposition in
  let optional f = Option.fold ~none:`Null ~some:f in
  let usage (usage:Exact.usage) = `Assoc ["input_tokens",`Int usage.input_tokens;
    "output_tokens",`Int usage.output_tokens] in
  let payload = `Assoc ["schema",`String "workspace.memory.observer.completion.v1";
    "run_id",`String registration.run_id;"request_id",`String original.request_id;
    "request_digest",`String original.request_digest;
    "registration_digest",`String registration.receipt.digest;
    "result",disposition_json disposition;"selected_slot",optional (fun s -> `String s) selected_slot;
    "provider_usage",optional usage provider_usage;
    "timing",`Assoc ["basis",`String "observer_receipt";"provider_started_at",`Null;
      "provider_elapsed_s",`Null;"cache_usage",`Null;"cost_usd",`Null]] in
  let* receipt = Receipt.make ~observed_at ~payload in
  let* () = consistent (Progress.observer original.progress).completion receipt in
  Ok {registration;disposition;selected_slot;provider_usage;receipt}
let restore_completion ~capture ~original ~registration (receipt:Receipt.receipt) =
  let* expected = completion ~capture ~original ~registration ~observed_at:receipt.observed_at in
  let* () = same_receipt receipt expected.receipt in Ok expected
