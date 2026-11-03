module Decode = Masc.Tui_decode

let amount_text amount =
  let padded = if String.length amount < 4 then String.make (4 - String.length amount) '0' ^ amount else amount in
  let split = String.length padded - 3 in
  String.sub padded 0 split ^ "." ^ String.sub padded split 3

(* The basis answers no instant before the last Candle event it holds. A TUI
   clock behind that event draws the values at the event, the earliest
   instant the basis answers (RFC-0481 §6). *)
let instant ~now (basis : Candle_decay_basis.t) =
  match Ptime.of_float_s now with
  | None -> Error "the clock is out of range"
  | Some now ->
      let now = Candle_time.of_ptime now in
      Ok
        (match basis.Candle_decay_basis.decay with
         | Candle_decay_basis.No_decaying_balance -> now
         | Candle_decay_basis.Decaying { keepers; _ } ->
             List.fold_left
               (fun latest (_, (held : Candle_decay_basis.keeper)) ->
                 if Candle_time.compare held.Candle_decay_basis.since latest > 0 then held.since
                 else latest)
               now keepers)

let decayed result = Result.map_error Candle_decay.error_to_string result

let supply ~now basis =
  Result.bind (instant ~now basis) (fun at -> decayed (Candle_decay_basis.supply_at basis ~at))

let balance ~now basis ~keeper =
  Result.bind (instant ~now basis) (fun at -> decayed (Candle_decay_basis.balance_at basis ~keeper ~at))

let summary_lines ~now = function
  | None | Some (Ok Decode.Candle_off) -> []
  | Some (Error detail) -> ["Candle unavailable: " ^ detail]
  | Some (Ok (Decode.Candle_disabled reason)) -> ["Candle disabled: " ^ reason]
  | Some (Ok (Decode.Candle_ready basis)) -> (
      match supply ~now basis with
      | Ok supply ->
          ["Candle issued: " ^ amount_text supply.Candle_balance.issued_milli;
           "Candle burned: " ^ amount_text supply.burned_milli;
           "Candle circulating: " ^ amount_text supply.circulating_milli]
      | Error detail -> ["Candle unavailable: " ^ detail])

let balance_text ~now reading ~keeper = match reading with
  | None -> Some "not yet read"
  | Some (Ok Decode.Candle_off) -> None
  | Some (Error detail) -> Some ("unavailable: " ^ detail)
  | Some (Ok (Decode.Candle_disabled reason)) -> Some ("disabled: " ^ reason)
  | Some (Ok (Decode.Candle_ready basis)) ->
    Some (match balance ~now basis ~keeper with
      | Ok milli -> amount_text (string_of_int milli) ^ " Candle"
      | Error detail -> "unavailable: " ^ detail)

let balance_milli ~now reading ~keeper = match reading with
  | Some (Ok (Decode.Candle_ready basis)) -> Result.to_option (balance ~now basis ~keeper)
  | Some (Ok (Decode.Candle_off | Decode.Candle_disabled _)) | Some (Error _) | None -> None

let keeper_basis reading ~keeper = match reading with
  | Some (Ok (Decode.Candle_ready { Candle_decay_basis.decay = Decaying { keepers; _ }; _ })) ->
    List.assoc_opt keeper keepers
  | Some (Ok (Decode.Candle_ready { Candle_decay_basis.decay = No_decaying_balance; _ }))
  | Some (Ok (Decode.Candle_off | Decode.Candle_disabled _)) | Some (Error _) | None -> None

let compact_status = function
  | None | Some (Ok Decode.Candle_off) -> None
  | Some (Error _) -> Some "Candle unavailable: ?:Candle details"
  | Some (Ok (Decode.Candle_disabled _)) -> Some "Candle disabled: ?:Candle details"
  | Some (Ok (Decode.Candle_ready _)) -> Some "Candle ready: ?:Candle details"
