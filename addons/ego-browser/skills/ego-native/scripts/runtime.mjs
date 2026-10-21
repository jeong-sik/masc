// Fixed program; request values are JSON data, never evaluated as JavaScript.
const fs = await import("node:fs/promises");
const result = {
  request_id: request.request_id, operation: request.operation,
  status: "outcome_unknown", session, completed_steps: 0, failed_step: null,
  url: null, title: null, snapshot: null, error: null, screenshot: null,
};
let task, page;
try {
  if (session) {
    task = await taskSpace(session.space_id);
  } else if (request.operation === "recover") {
    // Resolve only the retained installation-owned name. Never create, claim,
    // take over or choose another space to recover a lost first-open reply.
    const matches = (await listTaskSpaces()).filter(space => space.name === intent.native_name);
    if (matches.length !== 1 || matches[0].ownership !== "agent") {
      throw new Error("The retained space is absent, ambiguous or user-controlled; operator recovery is required");
    }
    task = await taskSpace(matches[0].id);
  } else {
    task = await taskSpace(intent.native_name);
  }
  result.session = session ?? {...intent, space_id: task.spaceId, page: "p1"};
  page = task.page("p1");
  if (request.operation === "finish") {
    await task.finish({keep: []});
    result.status = "closed";
  } else {
    let admitted = true;
    if (request.operation === "batch" && await page.url() !== request.expected_url) {
      admitted = false;
      result.status = "rejected_before_effect";
      result.error = {code: "url_changed", message: "Page URL changed; observe the bound page again"};
    }
    if (admitted) {
      for (const [index, step] of (request.steps ?? []).entries()) {
        result.failed_step = index;
        switch (step.action) {
          case "goto": await page.goto(step.url); break;
          case "click": await page.click(step.selector); break;
          case "dblclick": await page.dblclick(step.selector); break;
          case "hover": await page.hover(step.selector); break;
          case "drag": await page.dragAndDrop(step.source, step.destination); break;
          case "fill": await page.fill(step.selector, step.text); break;
          case "press": await page.press(step.selector, step.key); break;
          case "wait_for_selector": await page.waitForSelector(step.selector, {state: step.state}); break;
          case "wait_for_url": await page.waitForURL(step.url); break;
          default: throw new Error("Unsupported action");
        }
        result.completed_steps++;
      }
      result.failed_step = null;
      if (request.expect?.url) await page.waitForURL(request.expect.url);
      if (request.expect?.selector) {
        await page.waitForSelector(request.expect.selector, {state: request.expect.state ?? "visible"});
      }
      result.status = request.expect ? "postcondition_met" : "observed";
    }
    result.url = await page.url();
    result.title = await page.title();
    result.snapshot = request.scope === "full_page"
      ? await page.snapshot({scope: "full_page"}) : await page.snapshot();
    if (request.screenshot) result.screenshot = await page.screenshot({path: screenshotPath});
  }
} catch (error) {
  result.status = "outcome_unknown";
  result.error = {code: error.code == null ? null : String(error.code), message: String(error.message ?? error)};
  // A new observation is useful for recovery; it never upgrades failed input.
  if (page && request.operation !== "finish") {
    try {
      result.url = await page.url();
      result.title = await page.title();
      result.snapshot = await page.snapshot();
    } catch (observationError) {
      result.error.observation = String(observationError.message ?? observationError);
    }
  }
}
// The calling host requires this channel; CLI exit status is not task success.
await fs.writeFile(resultPath, JSON.stringify(result), {mode: 0o600});
