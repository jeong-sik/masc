type 'clock t =
  | Unbounded
  | Bounded of
      { clock : 'clock
      ; timeout_s : float
      ; deadline_at : float
      }

let open_ = function
  | Http_client.Unbounded -> Unbounded
  | Http_client.Bounded (clock, timeout_s) ->
    Bounded { clock; timeout_s; deadline_at = Eio.Time.now clock +. timeout_s }
;;

let remaining = function
  | Unbounded -> `Unbounded
  | Bounded { clock; timeout_s; deadline_at } ->
    let remaining_s = deadline_at -. Eio.Time.now clock in
    if Float.compare remaining_s 0.0 <= 0 then `Spent timeout_s else `Remaining remaining_s
;;
