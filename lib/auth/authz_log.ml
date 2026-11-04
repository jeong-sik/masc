(* HIGH-RISK-UNREVIEWED: this module opens, replays, and appends to the
   authorization log. A line it writes is a grant, revocation, or principal that
   the whole system treats as true, and a line that does not read back stops
   every later start. *)

(* See authz_log.mli. *)

let file_name = "authz.jsonl"

let path_of_base_path ~base_path =
  Filename.concat (Common.auth_dir_from_base_path ~base_path) file_name
;;

type reject =
  | Wrong_seq of
      { expected : int
      ; actual : int
      }
  | Wrong_previous_hash

(* The lines of the log are the records of [Authz_record], and the state of the
   file is the head of their chain. *)
module Chain_format = struct
  type state = Authz_record.head
  type record = Authz_record.t
  type line_error = Authz_record.decode_error
  type nonrec reject = reject

  let description = "authorization log"
  let thread_label = "authz-log"
  let genesis = Authz_record.genesis
  let of_line head line = Authz_record.of_line ~head line
  let to_line = Authz_record.to_line
  (* A record is plain data: ints, strings, variants and a body that holds no
     float. [=] compares every member, one that is added later too. A member
     that is not plain data needs a typed comparison here. *)
  let equal_record (left : Authz_record.t) right = left = right
  let advance _head record = Authz_record.head_after record

  let check_next head (record : Authz_record.t) =
    let expected = Authz_record.next_seq head in
    if record.Authz_record.seq <> expected
    then Error (Wrong_seq { expected; actual = record.Authz_record.seq })
    else if
      not
        (Authz_record.Hash.equal
           record.Authz_record.previous_hash
           (Authz_record.head_hash head))
    then Error Wrong_previous_hash
    else Ok ()
  ;;

  let describe_state head =
    Printf.sprintf
      "next seq %d after hash %s"
      (Authz_record.next_seq head)
      (Authz_record.Hash.to_hex (Authz_record.head_hash head))
  ;;

  let line_error_to_string = Authz_record.decode_error_to_string

  let reject_to_string = function
    | Wrong_seq { expected; actual } ->
      Printf.sprintf "its seq is %d where %d was expected" actual expected
    | Wrong_previous_hash -> "it does not name the record before it"
  ;;
end

module File = Authz_jsonl_file.Make (Chain_format)

type t = File.t
type writer = File.writer

type stop = Authz_jsonl_file.stop =
  { path : string
  ; reason : string
  }

type contents = Authz_jsonl_file.contents =
  | Missing
  | Empty
  | Lines of int

type tail = Authz_jsonl_file.tail =
  | Complete
  | Cut of
      { kept_bytes : int
      ; discarded_bytes : int
      }

type recovered = Authz_jsonl_file.recovered =
  { contents : contents
  ; tail : tail
  }

type 'reason open_error = 'reason File.open_error =
  | Locked of { path : string }
  | Unreadable of
      { path : string
      ; detail : string
      }
  | Line_rejected of
      { path : string
      ; line_number : int
      ; error : Authz_record.decode_error
      }
  | Fold_refused of
      { path : string
      ; line_number : int
      ; reason : 'reason
      }

type append_error = File.append_error =
  | Writer_expired
  | Stopped of stop
  | Rejected of
      { index : int
      ; reject : reject
      }
  | Would_not_read_back of
      { index : int
      ; error : Authz_record.decode_error
      }
  | Read_back_changed of { index : int }
  | Write_locked of { path : string }
  | Diverged of { path : string }
  | Write_failed of
      { path : string
      ; detail : string
      }

let stopped = File.stopped
let open_error_to_string = File.open_error_to_string
let open_at_start = File.open_at_start
let with_writer = File.with_writer
let append_error_to_string = File.append_error_to_string
let append = File.append
