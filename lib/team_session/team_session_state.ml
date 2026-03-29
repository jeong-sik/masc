type running
type terminal

type terminal_status =
  | Completed
  | Interrupted
  | Failed
  | Cancelled

type _ t = Session : Team_session_types.session -> 'state t

let session (Session value) = value

let terminal_status_to_session_status = function
  | Completed -> Team_session_types.Completed
  | Interrupted -> Team_session_types.Interrupted
  | Failed -> Team_session_types.Failed
  | Cancelled -> Team_session_types.Cancelled

let terminal_status_of_session_status = function
  | Team_session_types.Completed -> Some Completed
  | Interrupted -> Some Interrupted
  | Failed -> Some Failed
  | Cancelled -> Some Cancelled
  | Running | Paused -> None

let of_running (value : Team_session_types.session) =
  if value.status = Team_session_types.Running then Some (Session value)
  else None

let require_running (value : Team_session_types.session) =
  match of_running value with
  | Some running -> Ok running
  | None ->
      Error
        (Printf.sprintf "session is not running (status: %s)"
           (Team_session_types.status_to_string value.status))

let finalize (Session value : running t)
    ~(final_status : terminal_status)
    ~(reason : string)
    ~(now : float) : terminal t =
  let updated =
    {
      value with
      status = terminal_status_to_session_status final_status;
      stopped_at = Some now;
      stop_reason = Some reason;
      last_event_at = Some now;
      updated_at_iso = Types.now_iso ();
    }
  in
  Session updated
