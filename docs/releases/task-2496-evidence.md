# task-2496 증거

## diff (git diff origin/main)
```
diff --git a/lib/browser_observation.ml b/lib/browser_observation.ml
index d8697039ee9..64c9f8bd0d2 100644
--- a/lib/browser_observation.ml
+++ b/lib/browser_observation.ml
@@ -11,7 +11,8 @@ module Field_names = Set.Make (String)
 (* Durable bytes are also read by non-OCaml consumers. Reject ambiguous JSON
    throughout the observation instead of depending on their duplicate-key
    selection policy (including nested node and geometry fields). *)
-let rec unambiguous_json = function
+let rec unambiguous_json (json : Yojson.Safe.t) =
+  match json with
   | `Assoc fields ->
     let rec loop seen = function
       | [] -> Ok ()
@@ -29,7 +30,6 @@ let rec unambiguous_json = function
       | value :: rest -> let* () = unambiguous_json value in loop rest
     in loop values
   | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> Ok ()
-  | `Tuple _ | `Variant _ -> Error "retained observation requires standard JSON"
 
 let of_json json =
   let* () = unambiguous_json json in
diff --git a/lib/keeper/keeper_msg_async_record.ml b/lib/keeper/keeper_msg_async_record.ml
index 23b20e653c8..acf9d335a0a 100644
--- a/lib/keeper/keeper_msg_async_record.ml
+++ b/lib/keeper/keeper_msg_async_record.ml
@@ -282,7 +282,8 @@ let entry_record_to_json (e : entry) : Yojson.Safe.t =
 let same_entry_record (left : entry) (right : entry) = left = right
 
 let normalize_request_context request_context =
-  let rec normalize_json path = function
+  let rec normalize_json path (json : Yojson.Safe.t) =
+    match json with
     | `Assoc fields ->
       let rec normalize_fields seen normalized = function
         | [] ->
@@ -322,8 +323,6 @@ let normalize_request_context request_context =
     | `Float _ -> Error "request_context float must be finite"
     | (`Null | `Bool _ | `Int _ | `String _) as value ->
       Ok value
-    | `Tuple _ | `Variant _ ->
-      Error "request_context must contain JSON-compatible values"
   in
   match request_context with
   | None -> Ok None
diff --git a/lib/keeper/keeper_projection_change.ml b/lib/keeper/keeper_projection_change.ml
index b11da811637..79e4df3a6ec 100644
--- a/lib/keeper/keeper_projection_change.ml
+++ b/lib/keeper/keeper_projection_change.ml
@@ -15,7 +15,7 @@ type request_digests =
    fields again with float bits preserved: the common value-equal path still
    avoids both provider encoding and SHA-256, without calling different wire
    bytes identical. *)
-let rec json_wire_equal left right =
+let rec json_wire_equal (left : Yojson.Safe.t) (right : Yojson.Safe.t) =
   match left, right with
   | `Null, `Null -> true
   | `Bool left, `Bool right -> Bool.equal left right
@@ -30,14 +30,12 @@ let rec json_wire_equal left right =
          String.equal left_key right_key && json_wire_equal left_value right_value)
       left
       right
-  | `List left, `List right | `Tuple left, `Tuple right ->
+  | `List left, `List right ->
     List.equal json_wire_equal left right
-  | `Variant (left_tag, left_value), `Variant (right_tag, right_value) ->
-    String.equal left_tag right_tag && Option.equal json_wire_equal left_value right_value
   | ( (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _
-      | `List _ | `Tuple _ | `Variant _)
+      | `List _)
     , (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _
-      | `List _ | `Tuple _ | `Variant _) ) -> false
+      | `List _) ) -> false
 ;;
 
 let reasoning_detail_wire_equal
diff --git a/lib/keeper/keeper_tool_plan.ml b/lib/keeper/keeper_tool_plan.ml
index c2ed7176f90..ed71c6c043d 100644
--- a/lib/keeper/keeper_tool_plan.ml
+++ b/lib/keeper/keeper_tool_plan.ml
@@ -1512,10 +1512,9 @@ type parameter_binding_error =
   | Instantiated_plan_rejected of error
 
 let instantiate_params ~descriptors ~args plan =
-  let lookup name = match args with
+  let lookup name = match (args : Yojson.Safe.t) with
     | `Assoc fields -> List.assoc_opt name fields
-    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _
-    | `Tuple _ | `Variant _ -> None in
+    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None in
   let rec rebuild rebuilt = function
     | [] -> create_compiled ~descriptors ~children:plan.children ~arguments:plan.arguments
         ~branch_failure_policy:plan.branch_failure_policy ~exports:plan.exports (List.rev rebuilt)
```

## dune build 실행 결과
```
# task-2496 실행 영수증

실행: dune build lib/browser_observation.ml lib/keeper/keeper_msg_async_record.ml lib/keeper/keeper_projection_change.ml lib/keeper/keeper_tool_plan.ml
날짜: 2026-10-23T01:54:35Z
결과: exit=0 (성공)

변경 파일: 4개 (browser_observation.ml, keeper_msg_async_record.ml, keeper_projection_change.ml, keeper_tool_plan.ml)
변경 통계: 10 insertions(+), 14 deletions(-)
```
