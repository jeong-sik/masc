(* The words a /collab command leaves in the chat pane. Pure, so a test can
   read the exact lines an operator sees — including the one thing a share
   must never hide: which link steers (control) and which only watches. *)

module D = Masc.Tui_decode

let split_lines text =
  let lines = String.split_on_char '\n' text in
  (* The formatter leaves one trailing newline; it is not a row. *)
  match List.rev lines with
  | "" :: rest -> List.rev rest
  | _ -> lines
;;

(* Half-block QR: two modules per row, quiet zone included so phones
   scan it off the terminal. [None] is a URL past QR capacity — ours
   are ~130 bytes, but a failure must read as one, not as a blank. *)
let qr_lines url =
  match Qrc.encode url with
  | None -> [ "(QR render failed for this link; copy the URL above)" ]
  | Some matrix ->
    let pp ppf m = Qrc_fmt.pp_utf_8_half ppf m in
    split_lines (Format.asprintf "%a" pp matrix)
;;

let is_loopback_host host =
  String.equal (String.lowercase_ascii host) "localhost"
  || String.equal host "0.0.0.0"
  || String.equal host "::1"
  || String.equal host "[::1]"
  || String.starts_with ~prefix:"127." host
;;

(* The server only answers validated origins, so the host is whatever
   follows the scheme up to the first ':' (port), '/' or end. *)
let is_loopback_base base_url =
  let after_scheme =
    if String.starts_with ~prefix:"http://" base_url
    then Some (String.sub base_url 7 (String.length base_url - 7))
    else if String.starts_with ~prefix:"https://" base_url
    then Some (String.sub base_url 8 (String.length base_url - 8))
    else None
  in
  match after_scheme with
  | None -> false
  | Some rest ->
    (* A bracketed literal ends at ']'; anything else at the first port
       colon or slash. *)
    let host =
      if String.starts_with ~prefix:"[" rest
      then (
        match String.index_opt rest ']' with
        | None -> rest
        | Some close -> String.sub rest 0 (close + 1))
      else (
        let stop =
          match String.index_opt rest ':', String.index_opt rest '/' with
          | None, None -> String.length rest
          | Some c, None | None, Some c -> c
          | Some c, Some s -> min c s
        in
        String.sub rest 0 stop)
    in
    is_loopback_host host
;;

let loopback_warning (session : D.collab_host_session) =
  if is_loopback_base session.D.chs_base_url
  then
    [ ""
    ; "note: "
      ^ session.D.chs_base_url
      ^ " only reaches this machine — remote guests need "
      ^ "/collab https://host:port re-run on a public base"
    ]
  else []
;;

let hosted_lines (session : D.collab_host_session) =
  let headline =
    if session.D.chs_resumed
    then
      Printf.sprintf
        "sharing %s — resumed the live room (no second room minted)"
        session.D.chs_keeper
    else Printf.sprintf "sharing %s — hand someone a link, they're in" session.D.chs_keeper
  in
  let links =
    [ headline
    ; "view (terminal):    " ^ session.D.chs_view_link
    ; "control (terminal): " ^ session.D.chs_control_link
    ; "view (browser):     " ^ session.D.chs_web_link
    ; "control (browser):  " ^ session.D.chs_control_web_link
    ]
  in
  links @ loopback_warning session @ [ ""; "scan to join in a browser:" ]
  @ qr_lines session.D.chs_web_link
;;

let hosted_view_lines (session : D.collab_host_session) =
  let headline =
    if session.D.chs_resumed
    then
      Printf.sprintf
        "sharing %s — view links only (live room resumed)"
        session.D.chs_keeper
    else Printf.sprintf "sharing %s — view links only" session.D.chs_keeper
  in
  [ headline
  ; "view (terminal): " ^ session.D.chs_view_link
  ; "view (browser):  " ^ session.D.chs_web_link
  ]
  @ loopback_warning session
  @ [ ""; "scan to join in a browser:" ]
  @ qr_lines session.D.chs_web_link
;;

let stopped_lines (report : D.collab_stop_report) =
  match report.D.csr_stopped with
  | 0 -> [ Printf.sprintf "not sharing %s — nothing to stop" report.D.csr_keeper ]
  | 1 -> [ Printf.sprintf "stopped sharing %s" report.D.csr_keeper ]
  | n -> [ Printf.sprintf "stopped sharing %s (%d rooms)" report.D.csr_keeper n ]
;;
