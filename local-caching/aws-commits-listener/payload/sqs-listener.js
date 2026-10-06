// sqs-listener.js — "all-AWS" cache refresher for a Windows Cimian caching server.
//
// • Every value comes from the environment — NEVER hard-code a queue URL,
//   bucket, or credential in this file. Provide AWS creds via the standard
//   AWS_* env / instance profile.
// • Uses "aws s3 sync" for fast, resumable transfers.
// ----------------------------------------------------------------------

import fs   from 'fs';
import path from 'path';
import util from 'util';
import { exec } from 'child_process';
import {
  SQSClient,
  ReceiveMessageCommand,
  DeleteMessageCommand,
} from '@aws-sdk/client-sqs';

const execAsync = util.promisify(exec);

// ────────────────
// CONFIG — driven entirely by environment variables. Examples:
//   CIMIAN_AWS_REGION  = us-east-1
//   CIMIAN_SQS_URL     = https://sqs.<region>.amazonaws.com/<account-id>/cimian-commits
//   CIMIAN_BUCKET_URL  = s3://<your-bucket>
// ────────────────
const CONFIG = {
  region      : process.env.CIMIAN_AWS_REGION || 'us-east-1',
  queueUrl    : process.env.CIMIAN_SQS_URL,

  // Optional: a command that prints a short-lived bearer token for the git
  // remote, e.g. `az account get-access-token --resource <devops-resource-id>
  // --query accessToken -o tsv` on a machine with a managed identity. When unset,
  // git uses whatever credential helper the machine already has.
  gitTokenCmd  : process.env.CIMIAN_GIT_TOKEN_COMMAND || '',
  repoUrl     : process.env.CIMIAN_REPO_URL,
  workingCopy : process.env.CIMIAN_WORKING_COPY || 'C:\\ProgramData\\Cimian\\repo',
  bucketUrl   : process.env.CIMIAN_BUCKET_URL,

  awsCli      : process.env.CIMIAN_AWS_CLI || 'aws',
  logDir      : process.env.CIMIAN_LOG_DIR || 'C:\\ProgramData\\ManagedInstalls\\logs\\listener',
};

for (const k of ['queueUrl', 'repoUrl', 'bucketUrl']) {
  if (!CONFIG[k]) { console.error(`Missing required env for CONFIG.${k}`); process.exit(2); }
}

// ────────────────
function ts() { return new Date().toISOString().split('.')[0].replace('T', ' '); }

fs.mkdirSync(CONFIG.logDir, { recursive: true });
const log = fs.createWriteStream(path.join(CONFIG.logDir, 'listener.log'),       { flags: 'a' });
const err = fs.createWriteStream(path.join(CONFIG.logDir, 'listener_error.log'), { flags: 'a' });

console.log   = m => log.write(`[${ts()}] ${m}\n`);
console.error = m => err.write(`[${ts()}] ${m}\n`);

// Keep bearer tokens out of the logs, in case git or a token command echoes one.
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

async function syncFromS3(sub) {
  const src = `${CONFIG.bucketUrl}/deployment/${sub}`;
  const dst = `${CONFIG.workingCopy}\\deployment\\${sub}`;
  await run(`"${CONFIG.awsCli}" s3 sync ${src} "${dst}" --delete`);
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

function gitEnv() {
  // The header goes in through git's environment config (GIT_CONFIG_COUNT and
  // friends), never on the command line, where any local user could read it
  // from the process list, and never into a git config file on disk.
  const env = { ...process.env, GIT_TERMINAL_PROMPT: '0' };
  if (gitToken) {
    env.GIT_CONFIG_COUNT = '1';
    env.GIT_CONFIG_KEY_0 = 'http.extraHeader';
    env.GIT_CONFIG_VALUE_0 = `Authorization: Bearer ${gitToken}`;
  }
  return env;
}

function isAuthFailure(e) {
  return /Authentication failed|could not read Username|could not read Password|HTTP 401|HTTP 403/i.test(e.message || '');
}

async function git(args, opts = {}) {
  if (CONFIG.gitTokenCmd && Date.now() - gitTokenAt >= TOKEN_TTL_MS) await refreshGitToken();
  try {
    await run(`git ${args}`, { ...opts, env: gitEnv() });
  } catch (e) {
    if (!CONFIG.gitTokenCmd || !isAuthFailure(e)) throw e;
    console.log('Git authentication failed; refreshing the token and retrying once');
    await refreshGitToken();
    await run(`git ${args}`, { ...opts, env: gitEnv() });
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

async function pollQueue() {
  const sqs = new SQSClient({ region: CONFIG.region });
  let backOff = 0;

  while (true) {
    const resp = await sqs.send(new ReceiveMessageCommand({
      QueueUrl: CONFIG.queueUrl,
      WaitTimeSeconds: 20,
      MaxNumberOfMessages: 1,
    }));

    if (!resp.Messages?.length) {
      backOff = Math.min(backOff + 5, 60);
      await new Promise(r => setTimeout(r, backOff * 1000));
      continue;
    }
    backOff = 0;

    const m = resp.Messages[0];
    console.log('Commit event received – refreshing cache');

    try {
      await refreshRepo();
      await syncFromS3('pkgs');
      await syncFromS3('catalogs');
      await syncFromS3('icons');
      await syncFromS3('pkgsinfo');

      await sqs.send(new DeleteMessageCommand({
        QueueUrl: CONFIG.queueUrl,
        ReceiptHandle: m.ReceiptHandle,
      }));
      console.log('Cache refresh complete');
    } catch (e) {
      console.error(`Processing error: ${e.message}`);
      /* message re-appears after visibility timeout */
    }
  }
}

// ─── bootstrap ───
(async () => {
  await ensureRepo();
  console.log(`Polling ${CONFIG.queueUrl}`);
  await pollQueue();
})().catch(e => { console.error(`Fatal: ${e.message}`); process.exitCode = 1; });
