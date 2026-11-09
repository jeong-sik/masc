type stop =
  | Stopped of string
  | No_stop_reason

type turn =
  { at : float
  ; stop : stop
  }

let page_limit = 3

let turn_of_record (record : Turn_record.t) =
  { at = record.ts
  ; stop =
      (match record.finish_reason with
       | Some reason -> Stopped reason
       | None -> No_stop_reason)
  }
;;

let decode ~keeper json =
  Result.map
    (fun records ->
       List.stable_sort
         (fun left right -> Float.compare left.at right.at)
         (List.map turn_of_record records))
    (Masc_tui_turn_record_page.decode ~keeper json)
;;
