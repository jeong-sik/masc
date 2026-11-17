// Evaluate in a page that is signed in to the account server under test (its
// JavaScript console takes it as it is). The value is the status of
// GET /api/v1/auth/integrations and, for each integration, a line with its
// id, name, call verdict, refusal and model count, then its models.
(async () => {
  const response = await fetch("/api/v1/auth/integrations", { credentials: "same-origin" });
  const body = await response.text();
  const lines = ["status " + response.status];
  let parsed = null;
  try {
    parsed = JSON.parse(body);
  } catch (error) {
    parsed = null;
  }
  if (parsed && Array.isArray(parsed.integrations)) {
    for (const integration of parsed.integrations) {
      lines.push(
        [
          integration.integration_id,
          integration.display_name,
          integration.calls,
          integration.refusal || "-",
          integration.models.length + " models",
        ].join(" | "),
      );
      lines.push("  " + integration.models.join(" "));
    }
  } else {
    lines.push(body);
  }
  return lines.join("\n");
})()
