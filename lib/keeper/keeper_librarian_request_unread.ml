type reading = Available of Keeper_librarian_unread.t list | Unavailable
type t = { snapshot : reading; memory : reading }
let empty = {snapshot=Available [];memory=Available []}
let of_results ~snapshot ~memory =
  let reading = function Ok messages -> Available messages | Error _ -> Unavailable in
  {snapshot=reading snapshot;memory=reading memory}
let reading_to_json = function
  | Available messages -> `Assoc ["status",`String "available";
      "messages",Keeper_librarian_unread.list_to_json messages]
  | Unavailable -> `Assoc ["status",`String "unavailable"]
let to_json value = `Assoc ["schema_version",`Int 1;
  "snapshot",reading_to_json value.snapshot;"memory",reading_to_json value.memory]
let reading_is_empty = function
  | Available [] -> true
  | Available (_ :: _) | Unavailable -> false
let known_empty value =
  reading_is_empty value.snapshot && reading_is_empty value.memory
let text ?(include_empty=false) value =
  if known_empty value && not include_empty then Ok None
  else
    Prompt_registry.render_prompt_template Prompt_names.keeper_context_librarian_unread []
    |> Result.map (fun guidance ->
         Some (String.trim guidance ^ "\n" ^ Yojson.Safe.to_string (to_json value)))
let attach ?(include_empty=false) ~role value messages =
  let messages=List.filter (fun message ->
    not (Runtime_model_input_tail_window.is_unread_context message)) messages in
  let carry text metadata =
    { origin = Llm_provider.Types.Agent_instruction; Agent_core.Types.role;content=[Agent_core.Types.Text text];name=None;tool_call_id=None;
      metadata} :: messages in
  let metadata = Runtime_model_input_tail_window.unread_context_metadata in
  match text ~include_empty value with
  | Ok None -> messages
  | Ok (Some text) -> carry text metadata
  | Error detail ->
    (* Guidance is advisory. Preserve the frozen evidence even when its managed
       explanation is unavailable, and expose that failure on the carrier. *)
    carry ("\n" ^ Yojson.Safe.to_string (to_json value))
      (("masc.librarian_unread_guidance_error", `String detail) :: metadata)
