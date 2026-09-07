"use strict";

const fs = require("node:fs");
const path = require("node:path");

function absolutePath(value, name, env) {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${name} must name a directory`);
  const expanded = value === "~" ? env.HOME
    : value.startsWith("~/") && env.HOME ? path.join(env.HOME, value.slice(2)) : value;
  if (!expanded || !path.isAbsolute(expanded)) throw new Error(`${name} must be absolute`);
  return path.normalize(expanded);
}

function resolveBase(args = process.argv.slice(2), env = process.env) {
  const index = args.indexOf("--base");
  if (index >= 0) return absolutePath(args[index + 1], "--base", env);
  if (env.MASC_BROWSER_LANE_BASE !== undefined) {
    return absolutePath(env.MASC_BROWSER_LANE_BASE, "MASC_BROWSER_LANE_BASE", env);
  }
  if (env.MASC_BASE_PATH !== undefined) {
    return path.join(absolutePath(env.MASC_BASE_PATH, "MASC_BASE_PATH", env), ".masc", "browser-lane");
  }
  throw new Error("set MASC_BASE_PATH or MASC_BROWSER_LANE_BASE (or pass --base)");
}

// Read on each request, as the server does. An explicit environment token
// overrides the file; a missing/empty credential never becomes an anonymous poll.
function readToken(base, env = process.env) {
  let token;
  if (env.MASC_BROWSER_LANE_TOKEN !== undefined) {
    token = env.MASC_BROWSER_LANE_TOKEN.trim();
  } else {
    try {
      token = fs.readFileSync(path.join(base, "token"), "utf8").trim();
    } catch (error) {
      throw new Error(`cannot read browser lane token (${error.code})`);
    }
  }
  if (token.length < 16) throw new Error("browser lane token must contain at least 16 characters");
  return token;
}

module.exports = { resolveBase, readToken };
