module Store = Keeper_owned_job_store
type t =
  { completion : Keeper_event_queue.owned_job_completion
  ; result : (Store.record, Store.error) result }
let read ~base_path ~keeper_name completion =
  let result = Result.bind (Store.load ~base_path ~keeper_name completion.Keeper_event_queue.oj_job_id)
      (fun record ->
        if Store.source_to_json record.source <> Store.source_to_json completion.oj_source
           || Keeper_continuation_channel.to_yojson record.completion_channel
              <> Keeper_continuation_channel.to_yojson completion.oj_channel
        then Error (Store.Invalid_authority "completion source or channel differs from its original owner")
        else if Store.result_ready record then Ok record
        else Error (Store.Invalid_authority "completion has no complete terminal result")) in
  {completion;result}
let check {result;_} = Result.map (fun _ -> ()) result
let to_json {completion;result} =
  let reference = `Assoc ["tool", `String "keeper_job_result";
    "arguments", `Assoc ["job_id", `String (Store.Job_id.to_string completion.oj_job_id)]] in
  let fields = ["job_id", `String (Store.Job_id.to_string completion.oj_job_id);
    "source", Store.source_to_json completion.oj_source;
    "channel", Keeper_continuation_channel.to_yojson completion.oj_channel;
    "result_reference", reference] in
  match result with
  | Ok record -> `Assoc (fields @ ["result_available", `Bool true;"result", Store.result_json record])
  | Error error -> `Assoc (fields @ ["result_available", `Bool false;
      "result_error", `String (Store.error_to_string error)])
