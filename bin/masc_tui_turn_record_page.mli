(** One page of a Keeper's [/turn-records?limit=N] read. The Memory pane reads
    it for request sizes and the Story window for the newest turns, and both
    refuse the same pages. *)

val decode : keeper:string -> Yojson.Safe.t -> (Turn_record.t list, string) result
(** The page's records in the order the endpoint gave them, which is oldest
    first. An empty page decodes to the empty list. Every record must belong
    to the requested Keeper. A malformed record or a nonzero [skipped_rows]
    fails the page: an omitted newest row must not make an older one look like
    the last. *)
