import { spawn } from 'node:child_process';
import { createWriteStream, mkdirSync, copyFileSync, existsSync, unlinkSync } from 'node:fs';
import { availableParallelism } from 'node:os';
import { resolve } from 'node:path';
import { Worker } from 'node:worker_threads';

// Bursts leave background processes unscheduled long enough to expose short
// wall-clock polling deadlines, while idle periods let the suite make progress.
// --cooperative copies a fixture into Tests/ and removes it after the runs;
// the fixture stays disabled without SWIFTYRS_COOPERATIVE_LOAD=1.
// Test events and 30-second watchdogs are documented in docs/testing.md.
const options = { runs: 3, workers: availableParallelism() * 2, busyMs: 3000, idleMs: 1000, logs: '/tmp/swiftyrs-ci-load' };
const args = process.argv.slice(2);
const swiftArgs = [];
let cooperative = false;
for (let i = 0; i < args.length; i++) {
    if (args[i] === '--cooperative') { cooperative = true; continue; }
    if (args[i] === '--') { swiftArgs.push(...args.slice(i + 1)); break; }
    const names = { '--runs': 'runs', '--workers': 'workers', '--busy-ms': 'busyMs', '--idle-ms': 'idleMs', '--logs': 'logs' };
    const key = names[args[i]];
    if (!key || !args[i + 1]) throw new Error(`Unknown or incomplete option: ${args[i]}`);
    const value = args[++i];
    options[key] = key === 'logs' ? value : Number(value);
}
for (const key of ['runs', 'busyMs', 'idleMs']) {
    if (!Number.isInteger(options[key]) || options[key] <= 0) throw new Error(`${key} must be a positive integer`);
}
if (!Number.isInteger(options.workers) || options.workers < 0) throw new Error('workers must be a nonnegative integer');
if (process.platform !== 'darwin') throw new Error('This reproduction requires macOS taskpolicy');
mkdirSync(options.logs, { recursive: true });
const loadFixture = resolve('Tests/SwiftYrsHocuspocusTests/CooperativePoolLoadTests.swift');
if (cooperative) {
    if (existsSync(loadFixture)) throw new Error('Load fixture already exists; refusing to overwrite it');
    if (swiftArgs.includes('--skip-build')) throw new Error('Cooperative load must compile its temporary fixture; omit --skip-build');
    for (let i = 0; i < swiftArgs.length; i++) {
        if (swiftArgs[i] === "--filter" && swiftArgs[i + 1]) swiftArgs[++i] += "|cooperativePoolLoad";
    }
    copyFileSync(new URL('./fixtures/CooperativePoolLoadTests.swift', import.meta.url), loadFixture);
}
// A common monotonic epoch guarantees an idle window across all workers.
// Independent bursts drift and can otherwise saturate every CPU continuously.
const epochNs = process.hrtime.bigint() + 1_000_000_000n;
const workers = Array.from({ length: options.workers }, () => new Worker(`
    const { workerData } = require('node:worker_threads');
    const lock = new Int32Array(new SharedArrayBuffer(4));
    const cycleMs = workerData.busyMs + workerData.idleMs;
    const elapsedMs = () => Number(process.hrtime.bigint() - workerData.epochNs) / 1e6;
    let x = 1;
    for (;;) {
        const elapsed = elapsedMs();
        if (elapsed < 0) { Atomics.wait(lock, 0, 0, -elapsed); continue; }
        const phase = elapsed % cycleMs;
        if (phase >= workerData.busyMs) {
            Atomics.wait(lock, 0, 0, cycleMs - phase);
            continue;
        }
        const end = elapsed - phase + workerData.busyMs;
        while (elapsedMs() < end) {
            for (let i = 0; i < 1000; i++) x = Math.sin(x + i);
        }
    }
`, { eval: true, workerData: { ...options, epochNs } }));
let child;
let interrupted = false;
function stop(signal) {
    interrupted = true;
    if (child) { try { process.kill(-child.pid, signal); } catch {} }
    for (const worker of workers) void worker.terminate();
}
process.on('SIGINT', () => stop('SIGINT'));
process.on('SIGTERM', () => stop('SIGTERM'));
try {
    for (let run = 1; run <= options.runs && !interrupted; run++) {
        const log = resolve(options.logs, `run-${run}.log`);
        const output = createWriteStream(log);
        console.log(`Run ${run}/${options.runs}: ${cooperative ? '64 cooperative blocking cases; ' : ''}${options.workers} CPU workers, synchronized ${options.busyMs} ms busy / ${options.idleMs} ms idle; ${log}`);
        child = spawn('/usr/sbin/taskpolicy', ['-c', 'background', '/usr/bin/xcrun', 'swift', 'test', ...swiftArgs], { detached: true, env: { ...process.env, ...(cooperative ? { SWIFTYRS_COOPERATIVE_LOAD: '1' } : {}) } });
        child.stdout.pipe(output, { end: false });
        child.stderr.pipe(output, { end: false });
        const result = await new Promise((resolve, reject) => {
            child.once('error', reject);
            child.once('close', (code, signal) => resolve({ code, signal }));
        });
        child = undefined;
        await new Promise(resolve => output.end(resolve));
        console.log(JSON.stringify({ run, log, ...result }));
        if (result.code !== 0) process.exitCode = result.code ?? 1;
    }
} finally {
    await Promise.all(workers.map(worker => worker.terminate()));
    if (cooperative) unlinkSync(loadFixture);
    if (interrupted) process.exitCode = 130;
}
