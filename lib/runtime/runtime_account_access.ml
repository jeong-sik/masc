(* HIGH-RISK-UNREVIEWED: see the interface. *)

type 'client sealed = 'client Runtime_official_account.t
type 'client authorized = 'client Runtime_official_account.t

let seal account = account
let account authorized = authorized

type t = Single_user of Authz_boot_mode_read.single_user
type publish_error = Already_published

let publish_error_to_string Already_published =
  "this process published whether a CLI may start on an account before, and publishes it once"
;;

type state =
  | Unpublished
  | Published of t

let state = Atomic.make Unpublished

let publish access =
  let observed = Atomic.get state in
  match observed with
  | Published (_ : t) -> Error Already_published
  | Unpublished ->
    (* A failed exchange means another call published in between. *)
    if Atomic.compare_and_set state observed (Published access)
    then Ok ()
    else Error Already_published
;;

type request =
  | Keeper_turn of
      { keeper_name : string
      ; channel : Authz_types.Channel.t
      ; runtime_id : string
      }
  | Operator_call

type refusal = Not_published

let refusal_to_string Not_published =
  "this process has not published whether a CLI may start on an account"
;;

let authorize (_ : request) sealed =
  match Atomic.get state with
  | Unpublished -> Error Not_published
  | Published (Single_user (_ : Authz_boot_mode_read.single_user)) -> Ok sealed
;;
