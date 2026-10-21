module A = Candle_appraisal
let ( let* ) = Result.bind
type t = { id : string; original : A.request; snapshot : Yojson.Safe.t }
let non_blank name value =
  if String.trim value = "" then Error ("Candle appraisal intent requires " ^ name)
  else Ok ()
let make ~(identity : A.identity) ~prompt original =
  let* () = non_blank "goal_id" identity.goal_id in
  let* () = non_blank "request_id" identity.request_id in
  let* () = non_blank "verification_run_id" identity.verification_run_id in
  let* () = non_blank "rendered prompt" prompt in
  let* task_fields = match original with
    | A.Relation {task_id;_} ->
      let* () = non_blank "Relation task_id" task_id in
      Ok ["task_id", `String task_id]
    | A.Grade _ | A.Weights _ -> Ok [] in
  let fields = [
    "identity", `Assoc ["goal_id", `String identity.goal_id;
      "request_id", `String identity.request_id;
      "verification_run_id", `String identity.verification_run_id];
    "stage", `String (A.stage original);
    "input", A.input original;
    "schema", A.schema original;
    "prompt", `String prompt] @ task_fields in
  (* Object field order is encoding, not a different captured request. Array
     order remains part of model input. No timestamp or random retry ID enters
     this identity, so rebuilding the same snapshot cannot dispatch fresh work. *)
  let canonical = Yojson.Safe.sort (`Assoc fields) |> Yojson.Safe.to_string in
  let id = "candle-appraisal-" ^ Digestif.SHA256.(to_hex (digest_string canonical)) in
  Ok {id; original; snapshot=Yojson.Safe.sort (`Assoc (("request_id", `String id) :: fields))}
let request_id t = t.id
let request t = t.original
let to_worker_request t = t.snapshot
let submit_arguments t = `Assoc ["kind", `String "submit"; "request", t.snapshot]
let read_arguments t = `Assoc ["kind", `String "read"; "request_id", `String t.id]
