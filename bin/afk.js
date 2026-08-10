#!/usr/bin/env node
"use strict";

// afk: scaffold and manage unattended AFK agents (cron + bash + Telegram).
// Zero dependencies, Node stdlib only. The agents it generates are plain bash
// with no runtime dependencies; this CLI is just the authoring tool.

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execFileSync } = require("child_process");

const TEMPLATES = path.join(__dirname, "..", "templates");
const AGENTS_HOME = process.env.AGENTS_HOME || path.join(os.homedir(), "agents");
// Overridable so tests (and dry runs) never touch the real crontab.
const CRONTAB_CMD = process.env.AFK_CRONTAB_CMD || "crontab";

const TYPES = { monitor: "run.sh", worker: "worker.sh", digest: "digest.sh" };

function die(msg) {
  console.error(`afk: ${msg}`);
  process.exit(1);
}

function readTemplate(file) {
  return fs.readFileSync(path.join(TEMPLATES, file), "utf8");
}

// ---- cron helpers -----------------------------------------------------------

// Build a cron schedule from friendly flags.
//   --every 30m|1h|5m         -> */30 * * * *  /  0 * * * *  /  */5 * * * *
//   --day sun --at 19:00      -> 0 19 * * 0
//   --at 09:00                -> 0 9 * * *      (daily)
//   --schedule "raw 5 fields" -> used verbatim
function buildSchedule(opts) {
  if (opts.schedule) return opts.schedule.trim();

  const DAYS = { sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6 };

  if (opts.every) {
    const m = /^(\d+)(m|h)$/.exec(opts.every.trim());
    if (!m) die(`--every expects e.g. 15m or 1h, got "${opts.every}"`);
    const n = Number(m[1]);
    if (m[2] === "m") {
      if (n < 1 || n > 59) die("--every minutes must be 1..59 (use 1h for hourly)");
      return `*/${n} * * * *`;
    }
    if (n < 1 || n > 23) die("--every hours must be 1..23");
    return `0 */${n} * * *`;
  }

  if (opts.at || opts.day) {
    const at = opts.at || "09:00";
    const hm = /^(\d{1,2}):(\d{2})$/.exec(at);
    if (!hm) die(`--at expects HH:MM, got "${at}"`);
    const hour = Number(hm[1]), min = Number(hm[2]);
    if (hour > 23 || min > 59) die("--at out of range");
    let dow = "*";
    if (opts.day) {
      const key = opts.day.toLowerCase().slice(0, 3);
      if (!(key in DAYS)) die(`--day expects sun..sat, got "${opts.day}"`);
      dow = String(DAYS[key]);
    }
    return `${min} ${hour} * * ${dow}`;
  }

  return null; // no schedule requested
}

function readCrontab() {
  try {
    return execFileSync(CRONTAB_CMD, ["-l"], { encoding: "utf8" });
  } catch (e) {
    // No crontab yet exits non-zero with a message on stderr; treat as empty.
    return "";
  }
}

function writeCrontab(text) {
  execFileSync(CRONTAB_CMD, ["-"], { input: text.endsWith("\n") ? text : text + "\n" });
}

// Install/replace the cron line for one agent, tagged with a stable marker.
function installCron(name, schedule, entryPath) {
  const marker = `# afk:${name}`;
  const line = `${schedule} /bin/bash ${entryPath} ${marker}`;
  const current = readCrontab();
  const kept = current
    .split("\n")
    .filter((l) => l.trim() && !l.includes(marker));
  kept.push(line);
  writeCrontab(kept.join("\n"));
  return line;
}

function cronLineFor(name) {
  const marker = `# afk:${name}`;
  const line = readCrontab().split("\n").find((l) => l.includes(marker));
  if (!line) return null;
  // Keep only the 5 schedule fields, not the command that follows them.
  return line.slice(0, line.indexOf(marker)).trim().split(/\s+/).slice(0, 5).join(" ");
}

// ---- meta -------------------------------------------------------------------

function metaPath(name) {
  return path.join(AGENTS_HOME, name, ".afk");
}

function writeMeta(name, meta) {
  fs.writeFileSync(metaPath(name), JSON.stringify(meta, null, 2) + "\n");
}

function readMeta(name) {
  try {
    return JSON.parse(fs.readFileSync(metaPath(name), "utf8"));
  } catch {
    return null;
  }
}

// ---- commands ---------------------------------------------------------------

function cmdInit() {
  fs.mkdirSync(AGENTS_HOME, { recursive: true });
  const sharedSrc = path.join(TEMPLATES, "shared");
  const sharedDst = path.join(AGENTS_HOME, "shared");
  fs.mkdirSync(sharedDst, { recursive: true });
  for (const f of fs.readdirSync(sharedSrc)) {
    const dst = path.join(sharedDst, f);
    // Never clobber an existing env.sh (holds real secrets).
    if (f === "env.sh.example") {
      fs.copyFileSync(path.join(sharedSrc, f), dst);
      const envReal = path.join(sharedDst, "env.sh");
      if (!fs.existsSync(envReal)) {
        fs.copyFileSync(path.join(sharedSrc, f), envReal);
        fs.chmodSync(envReal, 0o600);
        console.log(`  created shared/env.sh (chmod 600), fill in your Telegram token`);
      }
    } else {
      fs.copyFileSync(path.join(sharedSrc, f), dst);
    }
  }
  console.log(`afk: initialized fleet at ${AGENTS_HOME}`);
  console.log(`  next: edit ${path.join(sharedDst, "env.sh")}, then 'afk new monitor <name>'`);
}

function cmdNew(args) {
  const type = args._[0];
  const name = args._[1];
  if (!type || !TYPES[type]) die(`usage: afk new <monitor|worker|digest> <name> [--every 30m | --day sun --at 19:00 | --schedule "..."]`);
  if (!name || !/^[a-zA-Z0-9._-]+$/.test(name)) die(`invalid agent name "${name || ""}" (letters, numbers, dot, dash, underscore)`);

  const dir = path.join(AGENTS_HOME, name);
  if (fs.existsSync(dir)) die(`agent "${name}" already exists at ${dir}`);

  if (!fs.existsSync(path.join(AGENTS_HOME, "shared", "notify.sh"))) {
    die(`fleet not initialized (no shared/ in ${AGENTS_HOME}). Run 'afk init' first.`);
  }

  const entry = TYPES[type];
  fs.mkdirSync(path.join(dir, "logs"), { recursive: true });
  fs.writeFileSync(path.join(dir, entry), readTemplate(`${type}.sh`));
  fs.chmodSync(path.join(dir, entry), 0o755);

  const schedule = buildSchedule(args);
  let cronLine = null;
  if (schedule) cronLine = installCron(name, schedule, path.join(dir, entry));

  writeMeta(name, { type, entry, schedule: schedule || null, created: new Date().toISOString() });

  console.log(`afk: created ${type} "${name}"`);
  console.log(`  ${path.join(dir, entry)}`);
  if (cronLine) {
    console.log(`  scheduled: ${schedule}`);
  } else {
    console.log(`  not scheduled yet (add --every/--day/--at, or edit your crontab)`);
  }
  if (type === "monitor") console.log(`  edit the CHECK block, then 'afk run ${name}' to test`);
  if (type === "worker") console.log(`  drop .job files in ${path.join(dir, "queue")}/`);
  if (type === "digest") console.log(`  edit the GATHER block, then 'afk run ${name}' to test`);
}

function listAgents() {
  if (!fs.existsSync(AGENTS_HOME)) return [];
  return fs.readdirSync(AGENTS_HOME, { withFileTypes: true })
    .filter((d) => d.isDirectory() && d.name !== "shared")
    .map((d) => d.name)
    .filter((n) => readMeta(n) || TYPES.monitor); // include dirs even without meta
}

function lastLogLine(name) {
  const logDir = path.join(AGENTS_HOME, name, "logs");
  if (!fs.existsSync(logDir)) return null;
  const logs = fs.readdirSync(logDir).filter((f) => f.endsWith(".log")).sort();
  if (!logs.length) return null;
  const last = path.join(logDir, logs[logs.length - 1]);
  const lines = fs.readFileSync(last, "utf8").trim().split("\n");
  return { file: logs[logs.length - 1], line: lines[lines.length - 1] || "" };
}

function cmdList() {
  const names = listAgents();
  if (!names.length) {
    console.log(`afk: no agents in ${AGENTS_HOME} (try 'afk new monitor <name>')`);
    return;
  }
  const rows = names.map((n) => {
    const meta = readMeta(n) || {};
    const sched = cronLineFor(n) || meta.schedule || "(not scheduled)";
    const log = lastLogLine(n);
    return { name: n, type: meta.type || "?", sched, log: log ? log.line : "(no runs yet)" };
  });
  const wName = Math.max(4, ...rows.map((r) => r.name.length));
  const wSched = Math.max(8, ...rows.map((r) => r.sched.length));
  for (const r of rows) {
    console.log(`${r.name.padEnd(wName)}  ${r.sched.padEnd(wSched)}  ${r.log}`);
  }
}

function cmdRun(args) {
  const name = args._[0];
  if (!name) die("usage: afk run <name>");
  const meta = readMeta(name);
  const entry = (meta && meta.entry) || "run.sh";
  const script = path.join(AGENTS_HOME, name, entry);
  if (!fs.existsSync(script)) die(`no such agent "${name}" (looked for ${script})`);
  try {
    execFileSync("/bin/bash", [script], { stdio: "inherit", env: process.env });
  } catch (e) {
    process.exit(e.status || 1);
  }
}

function cmdLogs(args) {
  const name = args._[0];
  if (!name) die("usage: afk logs <name>");
  const log = lastLogLine(name);
  if (!log) return console.log(`afk: no logs for "${name}" yet`);
  console.log(`# ${name}/logs/${log.file}`);
  const full = path.join(AGENTS_HOME, name, "logs", log.file);
  process.stdout.write(fs.readFileSync(full, "utf8"));
}

function cmdRm(args) {
  const name = args._[0];
  if (!name) die("usage: afk rm <name>");
  const dir = path.join(AGENTS_HOME, name);
  if (!fs.existsSync(dir)) die(`no such agent "${name}"`);
  // Remove its cron line too.
  const marker = `# afk:${name}`;
  const kept = readCrontab().split("\n").filter((l) => l.trim() && !l.includes(marker));
  try { writeCrontab(kept.join("\n")); } catch {}
  fs.rmSync(dir, { recursive: true, force: true });
  console.log(`afk: removed "${name}" (files and cron line)`);
}

function cmdHelp() {
  console.log(`afk: scaffold and manage unattended AFK agents

Usage:
  afk init                       set up the fleet (shared helpers + env.sh)
  afk new <type> <name> [sched]  create an agent (type: monitor | worker | digest)
  afk list                       show agents, schedules and last run
  afk run <name>                 run an agent once, now
  afk logs <name>                print today's log for an agent
  afk rm <name>                  delete an agent and its cron line

Scheduling flags for 'new':
  --every 30m | --every 2h       repeat every N minutes/hours
  --day sun --at 19:00           weekly on a day at a time
  --at 09:00                     daily at a time
  --schedule "0 2 * * *"         raw 5-field cron

Env:
  AGENTS_HOME   where agents live (default ~/agents)

Examples:
  afk init
  afk new monitor disk-watch --every 30m
  afk new digest weekly --day sun --at 19:00
  afk list`);
}

// ---- arg parsing ------------------------------------------------------------

function parse(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) out[key] = true;
      else { out[key] = next; i++; }
    } else out._.push(a);
  }
  return out;
}

function main() {
  const [, , cmd, ...rest] = process.argv;
  const args = parse(rest);
  switch (cmd) {
    case "init": return cmdInit();
    case "new": return cmdNew(args);
    case "list": case "ls": return cmdList();
    case "run": return cmdRun(args);
    case "logs": return cmdLogs(args);
    case "rm": case "remove": return cmdRm(args);
    case undefined: case "help": case "-h": case "--help": return cmdHelp();
    default: die(`unknown command "${cmd}" (try 'afk help')`);
  }
}

main();
