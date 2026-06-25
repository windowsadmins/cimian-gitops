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

  repoUrl     : process.env.CIMIAN_REPO_URL,
  workingCopy : process.env.CIMIAN_WORKING_COPY || 'C:\\ProgramData\\Cimian\\repo',
  bucketUrl   : process.env.CIMIAN_BUCKET_URL,

  awsCli      : process.env.CIMIAN_AWS_CLI || 'aws',
  logDir      : process.env.CIMIAN_LOG_DIR || 'C:\\ProgramData\\Cimian\\Logs\\Listener',
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

async function run(cmd, opts = {}) {
  const { stdout, stderr } = await execAsync(cmd, { ...opts, maxBuffer: 1024 ** 2 * 5 });
  if (stdout) console.log(stdout.trim());
  if (stderr) console.error(stderr.trim());
}

async function syncFromS3(sub) {
  const src = `${CONFIG.bucketUrl}/deployment/${sub}`;
  const dst = `${CONFIG.workingCopy}\\deployment\\${sub}`;
  await run(`"${CONFIG.awsCli}" s3 sync ${src} "${dst}" --delete`);
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
})().catch(e => console.error(`Fatal: ${e.message}`));
