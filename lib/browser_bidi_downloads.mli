(** Native BiDi connection for the Classic session's returned loopback URL.
    Requires Firefox's download events and setDownloadBehavior (149+; the
    complete download-ID contract is exercised against Firefox 155 in CI).
    [root] is the resolved runtime's staging parent. Files survive close. *)
val start : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> root:string -> publish:(string -> (Yojson.Safe.t, string) result) -> Browser_downloads.start
val verify_file : root:string -> string -> (string * int, string) result
