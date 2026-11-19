(* The bytes of a Memory snapshot, pinned.

   The rebuilt Librarian writes [memory-current.json] with the codec that
   exists today and names a snapshot by the SHA-256 of these bytes
   (RFC librarian-call-only-proposes §8.2, step 3). A change to the codec or
   to the fact types that moves one byte would make every stored snapshot
   differ from the commit line that names it, so it has to fail here first.

   The snapshot below holds every shape a fact can take: read from the
   transcript, from a Board post, from a Board comment, and derived along two
   paths; a familiar category and a newly named one; both origins. *)

open Alcotest
module Codec = Masc.Keeper_memory_os_snapshot_codec
module Current = Masc.Keeper_memory_os_current_types
module Types = Masc.Keeper_memory_os_types

let board ?comment_id post_id =
  match Types.board_ref_of_ids ~post_id ~comment_id with
  | Ok board -> Types.Observed (Types.Board board)
  | Error error -> fail (Types.wire_error_to_string error)
;;

let observed ?(basis = Types.Observed Types.Transcript) ~category ~kind ~first_seen
  ~last_seen claim : Types.fact
  =
  { claim; category; first_seen; last_seen; origin = { kind; trace_id = "turn-golden" }; basis }
;;

let derived ~category ~now ~derivations claim =
  match
    Types.derived ~claim ~category ~now
      ~origin:{ kind = Types.Authored; trace_id = "turn-golden" }
      ~derivations
  with
  | Ok fact -> fact
  | Error detail -> fail detail
;;

let custom_category name =
  match Types.category_of_string name with
  | Some category -> category
  | None -> failf "%s is not a category name" name
;;

let post = "p-0123456789abcdef0123456789abcdef"
let comment = "c-0123456789abcdef0123456789abcdef"

let port =
  observed ~category:Types.Fact ~kind:Types.Authored ~first_seen:1763300000.0
    ~last_seen:1763300600.25 "서버는 8935 포트에서 듣는다"
;;

let notes =
  observed ~basis:(board post) ~category:(custom_category "release_notes")
    ~kind:Types.Injected ~first_seen:1763300100.0 ~last_seen:1763300100.0
    "release notes go to the release channel"
;;

let dry_run =
  observed ~basis:(board ~comment_id:comment post) ~category:Types.Validated_approach
    ~kind:Types.Injected ~first_seen:1763300200.5 ~last_seen:1763300900.0
    "the reviewer said: \"dry run\"\nfirst"
;;

let release_order =
  derived ~category:Types.Constraint ~now:1763301000.0
    ~derivations:
      [ { rule_id = "release-order"
        ; premise_ids = [ Types.memory_id notes; Types.memory_id dry_run ]
        }
      ; { rule_id = "port-check"; premise_ids = [ Types.memory_id port ] }
      ]
    "a release needs a dry run before the notes go out"
;;

let old_port =
  observed ~category:Types.Fact ~kind:Types.Authored ~first_seen:1763200000.0
    ~last_seen:1763200000.0 "the server listened on port 8080"
;;

let old_probe =
  derived ~category:Types.Lesson ~now:1763200500.0
    ~derivations:[ { rule_id = "old-port"; premise_ids = [ Types.memory_id old_port ] } ]
    "the probe has to call port 8080"
;;

let snapshot : Current.t =
  { revision = 7
  ; updated_at = 1763301000.0
  ; source = { kind = Current.Librarian; trace_id = "trace-golden" }
  ; facts = [ port; notes; dry_run; release_order ]
  ; change =
      { added = [ release_order ]
      ; removed = [ old_port ]
      ; retained = 3
      ; invalidated =
          [ { fact = old_probe; missing_premise_ids = [ Types.memory_id old_port ] } ]
      }
  }
;;

let golden = {golden|{
  "revision": 7,
  "updated_at": 1763301000.0,
  "source": { "kind": "librarian", "trace_id": "trace-golden" },
  "facts": [
    {
      "claim": "서버는 8935 포트에서 듣는다",
      "category": "fact",
      "first_seen": 1763300000.0,
      "last_seen": 1763300600.25,
      "origin": { "kind": "authored", "trace_id": "turn-golden" },
      "basis": { "kind": "observed" }
    },
    {
      "claim": "release notes go to the release channel",
      "category": "release_notes",
      "first_seen": 1763300100.0,
      "last_seen": 1763300100.0,
      "origin": { "kind": "injected", "trace_id": "turn-golden" },
      "basis": {
        "kind": "observed",
        "board": { "post_id": "p-0123456789abcdef0123456789abcdef" }
      }
    },
    {
      "claim": "the reviewer said: \"dry run\"\nfirst",
      "category": "validated_approach",
      "first_seen": 1763300200.5,
      "last_seen": 1763300900.0,
      "origin": { "kind": "injected", "trace_id": "turn-golden" },
      "basis": {
        "kind": "observed",
        "board": {
          "post_id": "p-0123456789abcdef0123456789abcdef",
          "comment_id": "c-0123456789abcdef0123456789abcdef"
        }
      }
    },
    {
      "claim": "a release needs a dry run before the notes go out",
      "category": "constraint",
      "first_seen": 1763301000.0,
      "last_seen": 1763301000.0,
      "origin": { "kind": "authored", "trace_id": "turn-golden" },
      "basis": {
        "kind": "derived",
        "derivations": [
          {
            "rule_id": "release-order",
            "premise_ids": [
              "sha256:14521bd98e7bcec90eb400a1a7608715795701763f174d798f970175e69a293e",
              "sha256:3ecad62ffe509d72f83cfa7ad8a417e4eaf7e9b97f773e8ca8cd1dca34414bf8"
            ]
          },
          {
            "rule_id": "port-check",
            "premise_ids": [
              "sha256:142b335da65df46c933c9afaed9b0761602d89988bbffc485d0706fc1a24e5e8"
            ]
          }
        ]
      }
    }
  ],
  "change": {
    "added": [
      {
        "claim": "a release needs a dry run before the notes go out",
        "category": "constraint",
        "first_seen": 1763301000.0,
        "last_seen": 1763301000.0,
        "origin": { "kind": "authored", "trace_id": "turn-golden" },
        "basis": {
          "kind": "derived",
          "derivations": [
            {
              "rule_id": "release-order",
              "premise_ids": [
                "sha256:14521bd98e7bcec90eb400a1a7608715795701763f174d798f970175e69a293e",
                "sha256:3ecad62ffe509d72f83cfa7ad8a417e4eaf7e9b97f773e8ca8cd1dca34414bf8"
              ]
            },
            {
              "rule_id": "port-check",
              "premise_ids": [
                "sha256:142b335da65df46c933c9afaed9b0761602d89988bbffc485d0706fc1a24e5e8"
              ]
            }
          ]
        }
      }
    ],
    "removed": [
      {
        "claim": "the server listened on port 8080",
        "category": "fact",
        "first_seen": 1763200000.0,
        "last_seen": 1763200000.0,
        "origin": { "kind": "authored", "trace_id": "turn-golden" },
        "basis": { "kind": "observed" }
      }
    ],
    "retained": 3,
    "invalidated": [
      {
        "fact": {
          "claim": "the probe has to call port 8080",
          "category": "lesson",
          "first_seen": 1763200500.0,
          "last_seen": 1763200500.0,
          "origin": { "kind": "authored", "trace_id": "turn-golden" },
          "basis": {
            "kind": "derived",
            "derivations": [
              {
                "rule_id": "old-port",
                "premise_ids": [
                  "sha256:5917875b9ff780d252aa947751a5698585980ee75f2d996a135d787b30667967"
                ]
              }
            ]
          }
        },
        "missing_premise_ids": [
          "sha256:5917875b9ff780d252aa947751a5698585980ee75f2d996a135d787b30667967"
        ]
      }
    ]
  }
}
|golden}

let test_encoding_is_pinned () =
  check string "snapshot bytes" golden (Codec.snapshot_bytes snapshot)
;;

let test_stored_bytes_decode_to_themselves () =
  match Codec.of_json (Yojson.Safe.from_string golden) with
  | Error rejection -> fail (Codec.snapshot_rejection_to_string rejection)
  | Ok decoded -> check string "decode then encode" golden (Codec.snapshot_bytes decoded)
;;

let () =
  run "keeper_memory_snapshot_golden"
    [ ( "bytes"
      , [ test_case "encoding" `Quick test_encoding_is_pinned
        ; test_case "decoding" `Quick test_stored_bytes_decode_to_themselves
        ] )
    ]
;;
