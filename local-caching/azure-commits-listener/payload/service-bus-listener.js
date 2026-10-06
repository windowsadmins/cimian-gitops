// service-bus-listener.js
//
// Windows Cimian caching server: listener that consumes Azure Service Bus
// messages and refreshes a local Cimian working copy from Azure Blob Storage.
//
// • Every cloud-specific value comes from the environment — NEVER hard-code a
//   connection string or queue name in this file.
// • Uses "azcopy sync" for fast, resumable transfers.
// ----------------------------------------------------------------------

import fs   from 'fs';
import path from 'path';
import util from 'util';
import { exec } from 'child_process';
import { ServiceBusClient } from '@azure/service-bus';

const execAsync = util.promisify(exec);

// ────────────────
// CONFIG — driven entirely by environment variables. Set these in the
// Scheduled Task definition or a machine-level env block. Examples:
//   CIMIAN_SB_CONNECTION = Endpoint=sb://<namespace>.servicebus.windows.net/;...
//   CIMIAN_BLOB_URL      = https://<storage-account>.blob.core.windows.net/repo
//   CIMIAN_BLOB_SAS      = ?sv=...&sig=...
// ────────────────
const CONFIG = {
  sbConnection : process.env.CIMIAN_SB_CONNECTION,
  sbTopic      : process.env.CIMIAN_SB_TOPIC || 'cimian-commits',
  sbSub        : process.env.CIMIAN_SB_SUB   || 'cache-server-1',

  // Optional: a command that prints a short-lived bearer token for the git
  // remote, e.g. `az account get-access-token --resource <devops-resource-id>
  // --query accessToken -o tsv` on a machine with a managed identity. When unset,
  // git uses whatever credential helper the machine already has.
  gitTokenCmd  : process.env.CIMIAN_GIT_TOKEN_COMMAND || '',
  repoUrl      : process.env.CIMIAN_REPO_URL,
  workingCopy  : process.env.CIMIAN_WORKING_COPY || 'C:\\ProgramData\\Cimian\\repo',

  blobUrl      : process.env.CIMIAN_BLOB_URL,
  sas          : process.env.CIMIAN_BLOB_SAS || '',

  azcopy       : process.env.CIMIAN_AZCOPY || 'azcopy',
  logDir       : process.env.CIMIAN_LOG_DIR || 'C:\\ProgramData\\ManagedInstalls\\logs\\listener',
};

for (const k of ['sbConnection', 'repoUrl', 'blobUrl']) {
  if (!CONFIG[k]) { console.error(`Missing required env for CONFIG.${k}`); process.exit(2); }
}

// ────────────────
function ts() { return new Date().toISOString().split('.')[0].replace('T', ' '); }

fs.mkdirSync(CONFIG.logDir, { recursive: true });
const log = fs.createWriteStream(path.join(CONFIG.logDir, 'listener.log'),       { flags: 'a' });
const err = fs.createWriteStream(path.join(CONFIG.logDir, 'listener_error.log'), { flags: 'a' });

console.log   = m => log.write(`[${ts()}] ${m}\n`);
console.error = m => err.write(`[${ts()}] ${m}\n`);

// Keep bearer tokens out of the logs, including the command line that exec
// echoes back in its error message.
const redact = t => String(t).replace(/Bearer [^"\s]+/g, 'Bearer ***');

async function run(cmd, opts = {}) {
  try {
    const { stdout, stderr } = await execAsync(cmd, { ...opts, maxBuffer: 1024 ** 2 * 5 });
    if (stdout) console.log(redact(stdout.trim()));
    if (stderr) console.error(redact(stderr.trim()));
  } catch (e) {
    throw new Error(redact(e.message));
  }
}

async function syncFromBlob(sub) {
  const src = `${CONFIG.blobUrl}/deployment/${sub}${CONFIG.sas}`;
  const dst = `${CONFIG.workingCopy}\\deployment\\${sub}`;
  await run(`"${CONFIG.azcopy}" sync "${src}" "${dst}" --recursive --delete-destination=true`);
}

// ────────────────
// Git auth. Short-lived tokens expire while the listener sits idle between
// commits, so refresh ahead of expiry and once more on an auth failure, rather
// than failing every refresh until the service restarts.
// ────────────────
const TOKEN_TTL_MS = 40 * 60 * 1000;
let gitToken = '';
let gitTokenAt = 0;

async function refreshGitToken() {
  if (!CONFIG.gitTokenCmd) return;
  const { stdout } = await execAsync(CONFIG.gitTokenCmd, { maxBuffer: 1024 ** 2 });
  const t = stdout.trim();
  if (!t) throw new Error('git token command printed nothing');
  gitToken = t;
  gitTokenAt = Date.now();
  console.log('Refreshed git access token');
}

function gitAuthArgs() {
  // Passed per command, never written to a global git config.
  return gitToken ? `-c http.extraHeader="Authorization: Bearer ${gitToken}" ` : '';
}

function isAuthFailure(e) {
  return /Authentication failed|could not read Username|could not read Password|HTTP 401|HTTP 403/i.test(e.message || '');
}

async function git(args, opts = {}) {
  if (CONFIG.gitTokenCmd && Date.now() - gitTokenAt >= TOKEN_TTL_MS) await refreshGitToken();
  const env = { ...process.env, GIT_TERMINAL_PROMPT: '0' };
  try {
    await run(`git ${gitAuthArgs()}${args}`, { ...opts, env });
  } catch (e) {
    if (!CONFIG.gitTokenCmd || !isAuthFailure(e)) throw e;
    console.log('Git authentication failed; refreshing the token and retrying once');
    await refreshGitToken();
    await run(`git ${gitAuthArgs()}${args}`, { ...opts, env });
  }
}

async function ensureRepo() {
  if (!fs.existsSync(path.join(CONFIG.workingCopy, '.git'))) {
    console.log('Cloning repo…');
    await git(`clone ${CONFIG.repoUrl} "${CONFIG.workingCopy}"`);
  }
}

async function refreshRepo() {
  const o = { cwd: CONFIG.workingCopy };
  await git('reset --hard', o);
  await git('clean -fd',    o);
  await git('fetch --all',  o);
  await git('pull --rebase', o);
}

async function main() {
  await ensureRepo();

  const sb = new ServiceBusClient(CONFIG.sbConnection);
  const rx = sb.createReceiver(CONFIG.sbTopic, CONFIG.sbSub);

  rx.subscribe({
    processMessage: async msg => {
      console.log('Commit event received – refreshing cache');
      try {
        await refreshRepo();
        await syncFromBlob('pkgs');
        await syncFromBlob('catalogs');
        await syncFromBlob('icons');
        await syncFromBlob('pkgsinfo');
        await rx.completeMessage(msg);
        console.log('Cache refresh complete');
      } catch (e) {
        console.error(`Process error: ${e.message}`);
        await rx.abandonMessage(msg);
      }
    },
    processError: e => console.error(`Service Bus error: ${e.message}`),
  });

  console.log(`Listening on topic ${CONFIG.sbTopic} / subscription ${CONFIG.sbSub}`);
}

main().catch(e => { console.error(`Fatal: ${e.message}`); process.exitCode = 1; });
