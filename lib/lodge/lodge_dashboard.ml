(** Lodge_dashboard -- DEPRECATED stub (#1596, Phase 3).
    Lodge dashboard removed. The /dashboard/lodge route returns a
    deprecation notice. *)

(** ETag for cached response. *)
let etag () =
  let v = Version.version in
  let hash = Digest.string ("lodge-deprecated-" ^ v) |> Digest.to_hex in
  String.sub hash 0 12

(** Returns a simple deprecation notice page. *)
let html () = {|<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Lodge Selection (Deprecated)</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
      background: #0f0c29; color: #e0e0e0;
      display: flex; justify-content: center; align-items: center;
      min-height: 100vh; margin: 0;
    }
    .card {
      text-align: center; padding: 40px;
      background: rgba(255,255,255,0.05);
      border-radius: 12px; border: 1px solid rgba(255,255,255,0.1);
    }
    h1 { color: #888; font-size: 24px; }
    p { color: #666; margin-top: 10px; }
    a { color: #4ade80; text-decoration: none; }
    a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Lodge Selection Dashboard</h1>
    <p>This dashboard has been deprecated. Keeper is the sole autonomous runtime.</p>
    <p><a href="/dashboard">Back to Dashboard</a></p>
  </div>
</body>
</html>|}
