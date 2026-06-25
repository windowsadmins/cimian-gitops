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

  repoUrl      : process.env.CIMIAN_REPO_URL,
  workingCopy  : process.env.CIMIAN_WORKING_COPY || 'C:\\ProgramData\\Cimian\\repo',

  blobUrl      : process.env.CIMIAN_BLOB_URL,
  sas          : process.env.CIMIAN_BLOB_SAS || '',

  azcopy       : process.env.CIMIAN_AZCOPY || 'azcopy',
  logDir       : process.env.CIMIAN_LOG_DIR || 'C:\\ProgramData\\Cimian\\Logs\\Listener',
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

async function run(cmd, opts = {}) {
  const { stdout, stderr } = await execAsync(cmd, { ...opts, maxBuffer: 1024 ** 2 * 5 });
  if (stdout) console.log(stdout.trim());
  if (stderr) console.error(stderr.trim());
}

async function syncFromBlob(sub) {
  const src = `${CONFIG.blobUrl}/deployment/${sub}${CONFIG.sas}`;
  const dst = `${CONFIG.workingCopy}\\deployment\\${sub}`;
  await run(`"${CONFIG.azcopy}" sync "${src}" "${dst}" --recursive --delete-destination=true`);
}

async function ensureRepo() {
  if (!fs.existsSync(path.join(CONFIG.workingCopy, '.git'))) {
    console.log('Cloning repo…');
    await run(`git clone ${CONFIG.repoUrl} "${CONFIG.workingCopy}"`);
  }
}

async function refreshRepo() {
  const o = { cwd: CONFIG.workingCopy };
  await run('git reset --hard', o);
  await run('git clean -fd',    o);
  await run('git fetch --all',  o);
  await run('git pull --rebase', o);
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

main().catch(e => console.error(`Fatal: ${e.message}`));
