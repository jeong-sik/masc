"use strict";

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { resolveBase } = require("../lane-config.js");

function shellQuote(value) {
  return "'" + value.replaceAll("'", "'\"'\"'") + "'";
}

function install() {
  const base = resolveBase();
  if (!process.env.HOME || !path.isAbsolute(process.env.HOME)) throw new Error("HOME must be absolute");
  const source = path.resolve(__dirname, "..");
  const target = path.join(process.env.HOME, "Library", "Application Support", "Mozilla", "NativeMessagingHosts");
  const installed = path.join(target, "masc_browser_host");
  const wrapper = path.join(installed, "masc-browser-host");
  const host = path.join(installed, "host", "masc-browser-host.js");
  fs.mkdirSync(path.dirname(host), { recursive: true, mode: 0o700 });
  fs.mkdirSync(base, { recursive: true, mode: 0o700 });

  const tokenPath = path.join(base, "token");
  try {
    fs.writeFileSync(tokenPath, crypto.randomBytes(24).toString("hex") + "\n", { flag: "wx", mode: 0o600 });
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    if (fs.readFileSync(tokenPath, "utf8").trim().length < 16) {
      throw new Error(`existing lane token is invalid: ${tokenPath}`);
    }
  }
  fs.chmodSync(tokenPath, 0o600);

  function write(destination, contents, mode) {
    const temporary = `${destination}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, contents, { mode });
    fs.renameSync(temporary, destination);
  }
  write(host, fs.readFileSync(path.join(source, "host", "masc-browser-host.js")), 0o600);
  write(path.join(installed, "lane-config.js"), fs.readFileSync(path.join(source, "lane-config.js")), 0o600);
  write(wrapper, `#!/bin/sh\nexec ${shellQuote(process.execPath)} ${shellQuote(host)} --base ${shellQuote(base)} "$@"\n`, 0o700);
  const manifest = {
    name: "masc_browser_host",
    description: "masc browser lane host: bridges lane commands to this browser",
    path: wrapper,
    type: "stdio",
    allowed_extensions: ["browser-lane@masc.local"],
  };
  const manifestPath = path.join(target, "masc_browser_host.json");
  write(manifestPath, JSON.stringify(manifest, null, 2) + "\n", 0o600);
  process.stdout.write(`installed: ${manifestPath}\nlane token: ${tokenPath} (0600)\n`);
  process.stdout.write(`Load the extension separately in Firefox/Zen (about:debugging):\n  ${path.join(source, "extension", "manifest.json")}\n`);
}

try {
  install();
} catch (error) {
  process.stderr.write(`browser host installation failed: ${error.message}\n`);
  process.exitCode = 1;
}
