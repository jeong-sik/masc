(* HIGH-RISK-UNREVIEWED: see the interface. *)

let ( let* ) = Result.bind

module Exchange = Oidc_google_exchange
module Transaction = Oidc_login_transaction

type started =
  { sealed : Transaction.Sealed.t
  ; authorization_url : string
  }

type start_error =
  | Google_unavailable of Exchange.error
  | Return_path_too_long

let start_error_to_string = function
  | Google_unavailable error -> Exchange.error_to_string error
  | Return_path_too_long -> "the path to return to is too long for the cookie of a login"
;;

(* Milliseconds since the epoch. A float holds them exactly for the next few
   hundred thousand years. *)
let ms_of instant = Float.to_int (Ptime.to_float_s instant *. 1000.)

(* The clock is read again after the endpoints, because their read can take a
   round trip to Google and the ten minutes of the transaction start when it
   is sealed. *)
let start ~get cache transactions client ~now ~invite ~return_to ~replaces =
  let* endpoints =
    Exchange.endpoints ~get cache ~now_ms:(ms_of (now ()))
    |> Result.map_error (fun error -> Google_unavailable error)
  in
  match Transaction.start transactions ~now_ms:(ms_of (now ())) Transaction.Google ~invite ~return_to ~replaces with
  | Error Transaction.Too_long -> Error Return_path_too_long
  | Ok started ->
    Ok
      { sealed = started.sealed
      ; authorization_url = Exchange.authorization_url endpoints client started
      }
;;

type answer =
  | Code of string
  | Refused

type completed =
  { outcome : Authz_login.outcome
  ; return_to : Transaction.Local_path.t
  ; replaces : Authz_types.Session_id.t option
  }

type callback_error =
  | Transaction_refused of Transaction.open_error
  | Refused_at_google
  | Exchange_failed of Exchange.error
  | Login_refused of Authz_login.refusal

let callback_error_to_string = function
  | Transaction_refused error -> Transaction.open_error_to_string error
  | Refused_at_google -> "Google did not sign the person in"
  | Exchange_failed error -> Exchange.error_to_string error
  | Login_refused refusal -> Authz_login.refusal_to_string refusal
;;

let callback ~get ~post cache transactions zone client ~now ~draw sealed ~state answer =
  let instant = now () in
  let* taken =
    Transaction.open_ transactions ~now_ms:(ms_of instant) Transaction.Google sealed ~state
    |> Result.map_error (fun error -> Transaction_refused error)
  in
  let* code =
    match answer with
    | Code code -> Ok code
    | Refused -> Error Refused_at_google
  in
  let* identity =
    Exchange.identity ~get ~post cache ~now:instant ~now_ms:(ms_of instant) client ~code taken
    |> Result.map_error (fun error -> Exchange_failed error)
  in
  let* outcome =
    Authz_login.sign_in
      zone
      ~now_ms:(fun () -> ms_of (now ()))
      ~draw
      ~identity
      ~invite:taken.invite
    |> Result.map_error (fun refusal -> Login_refused refusal)
  in
  Ok { outcome; return_to = taken.return_to; replaces = taken.replaces }
;;
