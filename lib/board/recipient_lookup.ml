open Board_types
module Candidate = Recipient_resolution.Candidate

type 'recipient resolution = 'recipient Recipient_resolution.resolution =
  { recipients : 'recipient list
  ; unresolved : string list
  }

type t = Candidate.t -> (Agent_id.t option, string) result

let make declared = declared

let none_declared _candidate = Ok None

let unavailable candidate =
  Error
    (Printf.sprintf
       "cannot tell whether @%s names a Keeper: the Board backend has no recipient lookup"
       (Candidate.to_string candidate))
;;

let same_agent left right =
  String.equal (Agent_id.to_string left) (Agent_id.to_string right)
;;

let resolve lookup candidates =
  Recipient_resolution.resolve ~equal:same_agent ~declared:lookup candidates
;;
