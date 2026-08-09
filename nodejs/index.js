#!/usr/bin/env node

import { createWriteStream, existsSync, mkdtempSync, rmSync, chmodSync, readFileSync, readdirSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import AdmZip from 'adm-zip';
import { spawn } from 'child_process';
import { pipeline } from 'stream/promises';
import { extract as tarExtract } from 'tar';
import { platform, arch as osArch } from 'os';
import { exit } from 'process';

// ---------- Environment variable configuration (optional) ----------
const ARGO_DOMAIN = process.env.ARGO_DOMAIN || '';
const ARGO_AUTH   = process.env.ARGO_AUTH || '';
const USER        = process.env.USER || 'admin';
const PASSWORD    = process.env.PASSWORD || '123456';
const GOTTY_PORT  = process.env.SERVER_PORT || process.env.GOTTY_PORT || '8080';

// ========== Fixed configuration ==========
const GOTTY_VERSION = 'v1.8.0';
const CLOUDFLARED_FALLBACK_VERSION = '2025.8.0';
const GOTTY_COMMAND = ['/bin/bash', '-i'];

// ========== Global temporary directory tracking ==========
const tempDirs = [];

function registerTempDir(path) {
    tempDirs.push(path);
}

function cleanupTempDirs() {
    for (const dir of tempDirs) {
        try {
            if (existsSync(dir)) {
                rmSync(dir, { recursive: true, force: true });
                console.log(`🧹 Cleaned temporary directory: ${dir}`);
            }
        } catch (e) {
            console.log(`⚠️  Failed to clean ${dir}: ${e.message}`);
        }
    }
}

// Register cleanup on exit
process.on('exit', cleanupTempDirs);
process.on('SIGINT', () => { process.exit(0); });
process.on('SIGTERM', () => { process.exit(0); });
process.on('uncaughtException', (err) => {
    console.error('Uncaught Exception:', err);
    process.exit(1);
});

// ========== Utility functions ==========

function getSystemInfo() {
    const system = platform();
    let osName, ext, downloadName;
    if (system === 'win32') {
        osName = 'windows';
        ext = '.exe';
        downloadName = 'windows';
    } else if (system === 'darwin') {
        osName = 'darwin';
        ext = '';
        downloadName = 'darwin';
    } else {
        osName = 'linux';
        ext = '';
        downloadName = 'linux';
    }

    let arch = osArch();
    const archMap = {
        'x64': 'amd64',
        'amd64': 'amd64',
        'arm64': 'arm64',
        'aarch64': 'arm64',
        'armv7l': 'armv7',
        'armv6l': 'armv6',
    };
    arch = archMap[arch] || arch;
    return { osName, arch, ext, downloadName };
}

async function downloadFile(url, destPath, name = 'file') {
    process.stdout.write(`⬇️  Downloading ${name}... `);
    const response = await fetch(url);
    if (!response.ok) {
        throw new Error(`HTTP ${response.status} ${response.statusText}`);
    }
    await pipeline(response.body, createWriteStream(destPath));
    console.log('✅ done');
}

async function extractArchive(archivePath, extractTo, name = '压缩包') {
    if (archivePath.endsWith('.tar.gz')) {
        await tarExtract({
            file: archivePath,
            cwd: extractTo,
            filter: () => true
        });
    } else if (archivePath.endsWith('.zip')) {
        const zip = new AdmZip(archivePath);
        zip.extractAllTo(extractTo, true);
    } else {
        throw new Error(`Unknown format: ${archivePath}`);
    }
    console.log(`📦 Extraction of ${name} complete`);
}

function findExecutable(extractDir, name) {
    const walkSync = (dir) => {
        const entries = readdirSync(dir, { withFileTypes: true });
        for (const entry of entries) {
            const fullPath = join(dir, entry.name);
            if (entry.isDirectory()) {
                const result = walkSync(fullPath);
                if (result) return result;
            } else {
                if (entry.name === name || entry.name === name + '.exe') {
                    return fullPath;
                }
            }
        }
        return null;
    };
    return walkSync(extractDir);
}

// ========== Download and install ==========

async function setupGotty() {
    const { osName, arch } = getSystemInfo();
    let filename;
    if (osName === 'windows') {
        filename = `gotty_${GOTTY_VERSION}_${osName}_${arch}.zip`;
    } else {
        filename = `gotty_${GOTTY_VERSION}_${osName}_${arch}.tar.gz`;
    }
    const url = `https://github.com/sorenisanerd/gotty/releases/download/${GOTTY_VERSION}/${filename}`;

    const tmpDir = mkdtempSync(join(tmpdir(), 'gotty_'));
    registerTempDir(tmpDir);
    const archivePath = join(tmpDir, filename);

    try {
        await downloadFile(url, archivePath, 'gotty');
    } catch (e) {
        console.error(` ❌ Download failed: ${e.message}`);
        exit(1);
    }

    await extractArchive(archivePath, tmpDir, 'gotty');
    const gottyPath = findExecutable(tmpDir, 'gotty');
    if (!gottyPath) {
        console.error('❌ gotty executable not found');
        exit(1);
    }
    if (osName !== 'windows') {
        chmodSync(gottyPath, 0o755);
    }
    return gottyPath;
}

async function setupCloudflared() {
    const { osName, arch, downloadName } = getSystemInfo();
    let filename;
    if (osName === 'windows') {
        filename = `cloudflared-${downloadName}-${arch}.exe`;
    } else {
        filename = `cloudflared-${downloadName}-${arch}`;
    }

    const url = `https://github.com/cloudflare/cloudflared/releases/latest/download/${filename}`;
    const tmpDir = mkdtempSync(join(tmpdir(), 'cloudflared_'));
    registerTempDir(tmpDir);
    const destPath = join(tmpDir, filename);

    try {
        await downloadFile(url, destPath, 'cloudflared');
    } catch (e) {
        console.log('   Failed to download latest release, trying fallback version...');
        const urlV = `https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_FALLBACK_VERSION}/${filename}`;
        try {
            await downloadFile(urlV, destPath, 'cloudflared');
        } catch (e2) {
            console.error(` ❌ Download failed: ${e2.message}`);
            exit(1);
        }
    }

    if (osName !== 'windows') {
        chmodSync(destPath, 0o755);
    }
    return destPath;
}

// ========== Start services ==========

function runGotty(gottyPath) {
    const cmd = [gottyPath, '-p', GOTTY_PORT, '-w', '--credential', `${USER}:${PASSWORD}`, ...GOTTY_COMMAND];
    console.log(`🚀 Starting gotty (port ${GOTTY_PORT})`);
    const proc = spawn(cmd[0], cmd.slice(1), {
        stdio: ['ignore', 'pipe', 'pipe'],
        detached: false,
    });
    proc._gottyPath = gottyPath;
    return proc;
}

function runCloudflared(cloudflaredPath) {
    const logDir = mkdtempSync(join(tmpdir(), 'cf_log_'));
    registerTempDir(logDir);
    const logFile = join(logDir, 'cloudflared.log');

    const cmd = [
        cloudflaredPath,
        'tunnel',
        '--edge-ip-version', 'auto',
        '--no-autoupdate',
        '--protocol', 'http2',
        '--logfile', logFile,
        '--loglevel', 'info',
    ];

    if (ARGO_DOMAIN && ARGO_AUTH) {
        cmd.push('run', '--token', ARGO_AUTH);
        console.log(`🚀 Starting cloudflared (fixed tunnel: ${ARGO_DOMAIN})`);
    } else {
        cmd.push('--url', `http://localhost:${GOTTY_PORT}`);
        console.log('🚀 Starting cloudflared (temporary tunnel)');
    }

    const proc = spawn(cmd[0], cmd.slice(1), {
        stdio: ['ignore', 'pipe', 'pipe'],
        detached: false,
    });
    proc._cloudflaredPath = cloudflaredPath;
    proc._logFile = logFile;
    return proc;
}

function getTunnelUrl(proc, isFixed) {
    return new Promise((resolve) => {
        if (isFixed) {
            resolve(`https://${ARGO_DOMAIN}`);
            return;
        }
        const logFile = proc._logFile;
        let attempts = 0;
        const interval = setInterval(() => {
            if (existsSync(logFile)) {
                try {
                    const content = readFileSync(logFile, 'utf8');
                    const match = content.match(/https:\/\/[a-zA-Z0-9\-]+\.trycloudflare\.com/);
                    if (match) {
                        clearInterval(interval);
                        resolve(match[0]);
                        return;
                    }
                } catch (_) {}
            }
            attempts++;
            if (attempts >= 10) {
                clearInterval(interval);
                resolve(null);
            }
        }, 1000);
    });
}

async function printTunnelInfo(proc, isFixed) {
    if (isFixed) {
        console.log(`🔗 Fixed tunnel URL: https://${ARGO_DOMAIN}`);
        console.log('   ⚠️  Please ensure the domain is configured and resolved in Cloudflare');
    } else {
        const url = await getTunnelUrl(proc, isFixed);
        if (url) {
            console.log(`🔗 Temporary tunnel URL: ${url}`);
        } else {
            console.log('⏳ Timed out waiting for temporary tunnel URL, check the logs');
        }
    }
}

function monitorProcesses(procs) {
    setInterval(() => {
        for (const [name, proc] of Object.entries(procs)) {
            if (proc.exitCode !== null || proc.signalCode !== null) {
                console.log(`⚠️  ${name} has exited (code: ${proc.exitCode ?? 'signal'}), restarting...`);
                let newProc;
                if (name === 'gotty') {
                    newProc = runGotty(proc._gottyPath);
                } else if (name === 'cloudflared') {
                    newProc = runCloudflared(proc._cloudflaredPath);
                } else {
                    continue;
                }
                procs[name] = newProc;
            }
        }
    }, 5000);
}

// ========== Main function ==========

async function main() {
    console.log('='.repeat(50));
    console.log('🚀 gotty + cloudflared automatic deployment tool');
    console.log('='.repeat(50));

    const { osName, arch } = getSystemInfo();
    console.log(`📋 System: ${osName} / ${arch}`);

    const gottyPath = await setupGotty();
    const cloudflaredPath = await setupCloudflared();

    const gottyProc = runGotty(gottyPath);
    const cloudflaredProc = runCloudflared(cloudflaredPath);
    const isFixed = !!(ARGO_DOMAIN && ARGO_AUTH);

    await printTunnelInfo(cloudflaredProc, isFixed);

    console.log('\n' + '='.repeat(50));
    console.log('✅ All services started and monitoring... (Ctrl+C to stop)');
    if (isFixed) {
        console.log(`   Fixed domain: https://${ARGO_DOMAIN}`);
    } else {
        console.log('   Temporary domain is shown above');
    }
    console.log(`🔑 Credentials: Username: ${USER} / Password: ${PASSWORD}`);
    console.log('='.repeat(50) + '\n');

    const procs = {
        gotty: gottyProc,
        cloudflared: cloudflaredProc,
    };

    monitorProcesses(procs);

    // Keep process alive
    await new Promise(() => {});
}

main().catch(err => {
    console.error('Fatal error:', err);
    process.exit(1);
});
