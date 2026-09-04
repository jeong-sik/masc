(* See the .mli: one module owns the name shape so the TUI writer and the
   turn-setup matcher cannot drift apart. *)

let prefix = "pasted-"
let suffix = ".txt"

let file_name ~now_iso ~nonce =
  Printf.sprintf "%s%s-%s%s" prefix now_iso nonce suffix
;;

type parsed =
  { now_iso : string
  ; nonce : string
  }

let parse name =
  let prefix_length = String.length prefix in
  let suffix_length = String.length suffix in
  if not (String.starts_with ~prefix name && String.ends_with ~suffix name)
  then None
  else
    let body =
      String.sub name prefix_length
        (String.length name - prefix_length - suffix_length)
    in
    match String.rindex_opt body '-' with
    | None -> None
    | Some dash ->
      let now_iso = String.sub body 0 dash in
      let nonce =
        String.sub body (dash + 1) (String.length body - dash - 1)
      in
      if String.equal now_iso "" || String.equal nonce ""
      then None
      else Some { now_iso; nonce }
;;

let is_paste_file name = Option.is_some (parse name)
