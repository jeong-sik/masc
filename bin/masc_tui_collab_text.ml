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

(* inet_aton number: decimal, 0x-hex, or 0-octal. Returns the value
   when the whole part parses and fits 32 bits. *)
let parse_inet_number part =
  let len = String.length part in
  if len = 0
  then None
  else (
    let base, digits =
      if len > 2 && part.[0] = '0' && (part.[1] = 'x' || part.[1] = 'X')
      then 16, String.sub part 2 (len - 2)
      else if len > 1 && part.[0] = '0'
      then 8, part
      else 10, part
    in
    let value = ref 0 in
    let ok = ref (String.length digits > 0) in
    String.iter
      (fun c ->
        let digit =
          if c >= '0' && c <= '9'
          then Char.code c - Char.code '0'
          else if c >= 'a' && c <= 'f'
          then Char.code c - Char.code 'a' + 10
          else if c >= 'A' && c <= 'F'
          then Char.code c - Char.code 'A' + 10
          else -1
        in
        if digit < 0 || digit >= base
        then ok := false
        else if !value > (0xFFFFFFFF - digit) / base
        then ok := false
        else value := (!value * base) + digit)
      digits;
    if !ok then Some !value else None)
;;

let all_some parts =
  List.fold_left
    (fun acc parsed ->
      match acc, parsed with
      | Some values, Some n -> Some (n :: values)
      | _ -> None)
    (Some []) parts
  |> Option.map List.rev
;;

(* The libc spellings getaddrinfo accepts for loopback go past dotted
   decimal: 0x7f.0.0.1, 2130706433, 0177.0.0.1. Reassemble 1-4 parts the
   inet_aton way (a | a.b24 | a.b.c16 | a.b.c.d) and test the top byte. *)
let is_loopback_inet_spelling host =
  match String.split_on_char '.' host with
  | [] -> false
  | parts when List.length parts > 4 -> false
  | parts -> (
    match all_some (List.map parse_inet_number parts) with
    | None -> false
    | Some v -> (
      let addr32 =
        match v with
        | [ a ] -> Some a
        | [ a; b ] when a <= 0xFF && b <= 0xFFFFFF -> Some ((a lsl 24) lor b)
        | [ a; b; c ] when a <= 0xFF && b <= 0xFF && c <= 0xFFFF ->
          Some ((a lsl 24) lor (b lsl 16) lor c)
        | [ a; b; c; d ]
          when a <= 0xFF && b <= 0xFF && c <= 0xFF && d <= 0xFF ->
          Some ((a lsl 24) lor (b lsl 16) lor (c lsl 8) lor d)
        | _ -> None
      in
      (match addr32 with
       | Some addr -> addr lsr 24 = 127
       | None -> false)))
;;

let is_loopback_host host =
  let stripped =
    let lower = String.lowercase_ascii host in
    if String.ends_with ~suffix:"." lower
    then String.sub lower 0 (String.length lower - 1)
    else lower
  in
  if String.equal stripped "localhost" || String.equal stripped "0.0.0.0"
  then true
  else (
    let unbracketed =
      if String.starts_with ~prefix:"[" stripped
         && String.ends_with ~suffix:"]" stripped
         && String.length stripped >= 2
      then String.sub stripped 1 (String.length stripped - 2)
      else stripped
    in
    match Ipaddr.of_string unbracketed with
    | Ok (Ipaddr.V4 v4) ->
      let octets = Ipaddr.V4.to_octets v4 in
      Char.code octets.[0] = 127 || String.equal octets "\000\000\000\000"
    | Ok (Ipaddr.V6 v6) ->
      Ipaddr.V6.compare v6 Ipaddr.V6.localhost = 0
      || (match Ipaddr.v4_of_v6 v6 with
          | Some v4 -> Char.code (Ipaddr.V4.to_octets v4).[0] = 127
          | None -> false)
    | Error _ -> is_loopback_inet_spelling unbracketed)
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
