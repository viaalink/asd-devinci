// Ends a background session at the end of the job (also after a failure or
// a cancel): runs the main action's cleanup.sh with the session's settings.
// cleanup.sh is idempotent and logs one [cleanup] line per part.
"use strict";
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

function input(name) {
  return process.env[`INPUT_${name.replace(/ /g, "_").toUpperCase()}`] || "";
}

// The same bash `shell: bash` uses: Git Bash on Windows, never WSL's.
function bashPath() {
  if (process.platform !== "win32") return "bash";
  const candidates = [
    path.join(process.env.ProgramFiles || "C:\\Program Files", "Git", "bin", "bash.exe"),
    path.join(process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)", "Git", "bin", "bash.exe"),
  ];
  return candidates.find((p) => fs.existsSync(p)) || "bash";
}

const scriptsDir = input("scripts-dir");
const projectDir = input("project-dir");
const stateDir = input("state-dir");

// This session's own CLI, never another one's: with two sessions in one job
// the job's PATH and VIA_HOME point at the CLI the last session installed
// (maybe another cli-version). install-cli.sh/.ps1 put it in
// <state-dir>/cli: bin/ (Linux/macOS) or home/bin/ (Windows), home = VIA_HOME.
const cliDirs = [path.join(stateDir, "cli", "bin"), path.join(stateDir, "cli", "home", "bin")].filter((d) =>
  fs.existsSync(d),
);
const pathKey = Object.keys(process.env).find((k) => k.toUpperCase() === "PATH") || "PATH";
const ownCli = {};
if (cliDirs.length > 0) {
  ownCli[pathKey] = [...cliDirs, process.env[pathKey] || ""].join(path.delimiter);
}
if (fs.existsSync(path.join(stateDir, "cli", "home"))) {
  ownCli.VIA_HOME = path.join(stateDir, "cli", "home");
}

const env = {
  ...process.env,
  ...ownCli,
  SCRIPTS_DIR: scriptsDir,
  STATE_DIR: stateDir,
  SESSION_NAME: input("session-name"),
  XDG_CONFIG_HOME: input("xdg-config-home"),
  VIA_WORKSPACE_DIR: input("workspace-dir"),
  VIA_BASIC_AUTH_USERNAME: input("username"),
  VIA_BASIC_AUTH_PASSWORD: input("password"),
  VIA_NON_INTERACTIVE: "1",
  GITHUB_TOKEN: input("token"),
  CLEANUP_BY: "the post step (job end)",
};
// The cleanup reads the inputs from env, not from INPUT_*.
for (const k of Object.keys(env)) if (k.startsWith("INPUT_")) delete env[k];

const cwd = projectDir && fs.existsSync(projectDir) ? projectDir : process.cwd();
const r = spawnSync(bashPath(), [path.join(scriptsDir, "cleanup.sh")], { env, cwd, stdio: "inherit" });

if (r.error) {
  console.log(`::error::Could not run the session cleanup: ${r.error.message}`);
  process.exit(1);
}
process.exit(r.status === null ? 1 : r.status);
