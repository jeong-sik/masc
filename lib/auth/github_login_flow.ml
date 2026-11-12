(* HIGH-RISK-UNREVIEWED: see the interface. *)

let ( let* ) = Result.bind

module Transaction = Oidc_login_transaction

type started =
  { sealed : Transaction.Sealed.t
  ; authorization_url : string
  }

(* Milliseconds since the epoch. A float holds them exactly for the next few
   hundred thousand years. *)
let ms_of instant = Float.to_int (Ptime.to_float_s instant *. 1000.)

let start transactions client ~now ~invite ~return_to ~replaces =
  Transaction.start transactions ~now_ms:(ms_of (now ())) Transaction.Github ~invite ~return_to ~replaces
  |> Result.map (fun (started : unit Transaction.started) ->
    { sealed = started.sealed; authorization_url = Github_oauth.authorization_url client started })
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
  | Refused_at_github
  | Exchange_failed of Github_oauth.error
  | Login_refused of Authz_login.refusal

let callback_error_to_string = function
  | Transaction_refused error -> Transaction.open_error_to_string error
  | Refused_at_github -> "GitHub did not sign the person in"
  | Exchange_failed error -> Github_oauth.error_to_string error
  | Login_refused refusal -> Authz_login.refusal_to_string refusal
;;

let callback ~get ~post transactions zone client ~now ~draw sealed ~state answer =
  let* taken =
    Transaction.open_ transactions ~now_ms:(ms_of (now ())) Transaction.Github sealed ~state
    |> Result.map_error (fun error -> Transaction_refused error)
  in
  let* code =
    match answer with
    | Code code -> Ok code
    | Refused -> Error Refused_at_github
  in
  let* identity =
    Github_oauth.identity ~get ~post client ~code taken
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
