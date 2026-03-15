#!/usr/bin/env bash
# =============================================================================
# mythic-entrypoint.sh
# =============================================================================
# Bootstrap wrapper for the ich777/fivemserver base image.
#
# Execution order:
#   1. (First run only) Deploy Mythic txAdmin recipe → SERVER_DIR/
#   2. (First run only) Inject DB connection strings into server.cfg
#   3. (First run only) Pre-configure txAdmin — skips the browser wizard
#   4. Exec /opt/scripts/start.sh  (ich777 original: downloads artifact, starts FXServer)
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GRN}[MYTHIC]${NC} $*"; }
warn()  { echo -e "${YEL}[MYTHIC WARN]${NC} $*"; }
error() { echo -e "${RED}[MYTHIC ERROR]${NC} $*" >&2; exit 1; }
step()  { echo -e "${CYN}[MYTHIC ====]${NC} $*"; }

# ── Paths — must match ich777 conventions ────────────────────────────────────
# ich777 mounts the volume at /serverdata/serverfiles  (= SERVER_DIR)
# All txAdmin recipe paths like ./resources/... are relative to SERVER_DIR
SERVER_DIR="${SERVER_DIR:-/serverdata/serverfiles}"
TXDATA_DIR="/serverdata/txData"
DEPLOY_LOCK="${SERVER_DIR}/.mythic_deploy_complete"

mkdir -p "${SERVER_DIR}" "${TXDATA_DIR}"

# ── Required env var checks ───────────────────────────────────────────────────
: "${SERVER_KEY:?SERVER_KEY (Cfx.re license) must be set in .env}"
: "${MYSQL_PASSWORD:?MYSQL_PASSWORD must be set in .env}"
: "${TXADMIN_MASTER_PASSWORD:?TXADMIN_MASTER_PASSWORD must be set in .env}"

# Defaults
TXADMIN_PORT="${TXADMIN_PORT:-40120}"
FIVEM_PORT="${FIVEM_PORT:-30120}"
SERVER_NAME="${SERVER_NAME:-My Mythic Server}"
TXADMIN_MASTER_USERNAME="${TXADMIN_MASTER_USERNAME:-admin}"
RECIPE_URL="${RECIPE_URL:-https://raw.githubusercontent.com/Mythic-Framework/txAdminRecipe/main/mythic-stable.yaml}"

# =============================================================================
# STEP 1 — Deploy the Mythic txAdmin recipe
# =============================================================================
deploy_recipe() {
    step "Deploying Mythic txAdmin recipe..."
    info "Recipe URL: ${RECIPE_URL}"

    local RECIPE_FILE="/tmp/mythic-recipe.yaml"
    local RETRIES=5 WAIT=5

    for i in $(seq 1 ${RETRIES}); do
        if curl -fsSL --retry 3 --retry-delay 3 "${RECIPE_URL}" -o "${RECIPE_FILE}" 2>/dev/null; then
            info "Recipe downloaded successfully."
            break
        fi
        [[ ${i} -eq ${RETRIES} ]] && error "Failed to download recipe after ${RETRIES} attempts."
        warn "Attempt ${i}/${RETRIES} failed — retrying in ${WAIT}s..."
        sleep ${WAIT}
        WAIT=$((WAIT * 2))
    done

    write_node_deployer
    info "Running Node.js recipe deployer..."
    node /tmp/deploy_recipe.mjs "${RECIPE_FILE}" "${SERVER_DIR}"
    info "Recipe deployment complete."
}

# ── Write the Node.js recipe deployer to /tmp ─────────────────────────────────
write_node_deployer() {
    cat > /tmp/deploy_recipe.mjs << 'NODE_EOF'
/**
 * deploy_recipe.mjs — txAdmin recipe executor for Mythic Framework
 *
 * All recipe paths (src/dest) are relative to SERVER_DIR (deploy root).
 * e.g. "./resources/[mythic]/mythic-admin" → SERVER_DIR/resources/[mythic]/mythic-admin
 *
 * Supported actions:
 *   download_github  src=full-github-url  ref=branch  dest=./rel/path  [subpath=subdir]
 *   download_file    path=./tmp/file.zip  url=https://...
 *   unzip            src=./tmp/file.zip   dest=./resources/[cat]
 *   move_path        src=./rel  dest=./rel
 *   remove_path      path=./rel
 *   ensure_dir       path=./rel
 *   write_file       dest=./rel  content=...
 *   connect_database — skipped (handled by server.cfg)
 *   query_database   — skipped (handled externally)
 *   waste_time       — skipped (no throttling needed; we run sequentially already)
 */
import fs   from 'fs';
import path from 'path';
import https from 'https';
import http  from 'http';
import { spawnSync } from 'child_process';

const RECIPE_FILE = process.argv[2];
const SERVER_DIR  = process.argv[3];   // deploy root — all relative paths resolve here
const TMP_DIR     = '/tmp/mythic_deploy';

fs.mkdirSync(SERVER_DIR, { recursive: true });
fs.mkdirSync(TMP_DIR,    { recursive: true });

// ── Resolve a recipe-relative path (./foo) to an absolute path ───────────────
function R(p) {
    if (!p) throw new Error('empty path');
    // Strip leading "./" if present, then join with SERVER_DIR
    return path.join(SERVER_DIR, p.replace(/^\.\//, ''));
}

// ── YAML line parser — covers the txAdmin recipe subset ──────────────────────
function parseRecipe(text) {
    const tasks = [];
    let   cur   = null;
    let   inTasks = false;
    let   collectKey = null;
    let   collectLines = [];

    const flush = () => {
        if (!cur) return;
        if (collectKey && collectLines.length) cur[collectKey] = collectLines.join('\n');
        tasks.push(cur);
        cur = null; collectKey = null; collectLines = [];
    };

    for (const raw of text.split('\n')) {
        const line = raw.trimEnd();
        if (!line) continue;

        const stripped = line.trimStart();
        // Skip comment-only lines (but NOT inline comments — handled below)
        if (stripped.startsWith('# ') && !stripped.startsWith('#  ')) {
            // allow it to fall through — needed for "waste_time # ..." detection
        }
        if (!inTasks && stripped === 'tasks:') { inTasks = true; continue; }
        if (!inTasks) continue;

        // New task: starts with optional spaces, then "- action:"
        const tm = line.match(/^(\s*)-\s+action:\s*(.+)/);
        if (tm) {
            flush();
            // Strip inline comments from action value
            const actionRaw = tm[2].split('#')[0].trim();
            cur = { action: actionRaw };
            continue;
        }

        if (!cur) continue;

        // Multi-line block scalar continuation
        if (collectKey) {
            if (/^\s{6,}/.test(line)) { collectLines.push(line.trimStart()); continue; }
            cur[collectKey] = collectLines.join('\n');
            collectKey = null; collectLines = [];
        }

        // key: value  (indent ≥ 2)
        const kv = line.match(/^\s{2,}(\w[\w_]*):\s*(.*)/);
        if (kv) {
            const [, key, rawVal] = kv;
            const val = rawVal.trim();
            if (val === '|' || val === '>') { collectKey = key; collectLines = []; }
            else cur[key] = val.replace(/^['"]|['"]$/g, '');
        }
    }
    flush();
    return tasks;
}

// ── HTTP/S download with redirect following ───────────────────────────────────
// Uses a recursive approach: on redirect, close + delete the current file
// and start a fresh download to a new WriteStream at the same dest path.
function download(url, dest, hops = 0) {
    return new Promise((resolve, reject) => {
        if (hops > 10) return reject(new Error('Too many redirects'));
        const proto = url.startsWith('https') ? https : http;
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        const file = fs.createWriteStream(dest);
        let settled = false;
        const done = (err) => {
            if (settled) return;
            settled = true;
            if (err) reject(err); else resolve();
        };
        const req = proto.get(url, { headers: { 'User-Agent': 'fivem-mythic-deployer/3.0' } }, res => {
            if ([301, 302, 307, 308].includes(res.statusCode)) {
                res.resume(); // drain to free socket
                file.close(() => {
                    try { fs.unlinkSync(dest); } catch {}
                    download(res.headers.location, dest, hops + 1).then(resolve).catch(reject);
                });
                settled = true;
                return;
            }
            if (res.statusCode !== 200) {
                res.resume();
                file.close(() => { try { fs.unlinkSync(dest); } catch {} });
                done(new Error(`HTTP ${res.statusCode} for ${url}`));
                return;
            }
            res.pipe(file);
            file.on('finish', () => file.close(() => done(null)));
            file.on('error',  e => { try { fs.unlinkSync(dest); } catch {} done(e); });
        });
        req.on('error', e => { file.close(() => { try { fs.unlinkSync(dest); } catch {} }); done(e); });
    });
}

// ── unzip helper ──────────────────────────────────────────────────────────────
function unzipTo(zipPath, outDir) {
    fs.mkdirSync(outDir, { recursive: true });
    const r = spawnSync('unzip', ['-q', '-o', zipPath, '-d', outDir], { stdio: 'inherit' });
    if (r.status !== 0) throw new Error(`unzip failed (exit ${r.status})`);
}

// ── copy a directory tree (cp -a src/. dest) ─────────────────────────────────
function copyTree(src, dest) {
    fs.mkdirSync(dest, { recursive: true });
    const r = spawnSync('cp', ['-a', src + '/.', dest], { stdio: 'inherit' });
    if (r.status !== 0) throw new Error(`cp -a failed`);
}

// ── rmSync wrapper ────────────────────────────────────────────────────────────
function rmrf(p) {
    try { fs.rmSync(p, { recursive: true, force: true }); } catch {}
}

// ── Task handlers ─────────────────────────────────────────────────────────────
async function runTask(task) {
    const { action } = task;

    // ── download_github ───────────────────────────────────────────────────────
    // src  : full GitHub URL  e.g. https://github.com/owner/repo
    // ref  : branch/tag       e.g. main
    // dest : relative path    e.g. ./resources/[mythic]/mythic-admin
    // subpath (optional)      e.g. resources  — only copy this subdir
    if (action === 'download_github') {
        const srcUrl  = task.src;  // full URL
        const ref     = task.ref || 'main';
        const dest    = R(task.dest);
        const subpath = task.subpath || null;

        // Extract owner/repo from full URL
        const match = srcUrl.match(/github\.com\/([^/]+\/[^/]+)/i);
        if (!match) throw new Error(`Cannot parse GitHub URL: ${srcUrl}`);
        const repo = match[1].replace(/\.git$/, '');

        // Skip if destination already populated
        if (fs.existsSync(dest) && fs.readdirSync(dest).length > 0) {
            console.log(`    skip (already exists): ${dest}`);
            return;
        }

        // Use archive zip URL — works for any branch, no API rate limit
        const zipUrl  = `https://github.com/${repo}/archive/refs/heads/${ref}.zip`;
        const tmpZip  = path.join(TMP_DIR, `${repo.replace('/', '_')}_${ref}.zip`);
        const tmpOut  = path.join(TMP_DIR, `${repo.replace('/', '_')}_out`);

        console.log(`    GET ${zipUrl}`);
        await download(zipUrl, tmpZip);
        rmrf(tmpOut);
        unzipTo(tmpZip, tmpOut);

        // GitHub archives unzip to a single top-level dir: repo-branch/
        const entries = fs.readdirSync(tmpOut);
        const topDir  = entries.length === 1 ? path.join(tmpOut, entries[0]) : tmpOut;

        const srcDir  = subpath ? path.join(topDir, subpath) : topDir;
        if (!fs.existsSync(srcDir)) throw new Error(`subpath '${subpath}' not found in archive`);

        fs.mkdirSync(path.dirname(dest), { recursive: true });
        copyTree(srcDir, dest);
        rmrf(tmpOut);
        try { fs.unlinkSync(tmpZip); } catch {}
        return;
    }

    // ── download_file ─────────────────────────────────────────────────────────
    // url  : direct download URL
    // path : destination relative path  e.g. ./tmp/oxmysql.zip
    if (action === 'download_file') {
        const dest = R(task.path);
        console.log(`    GET ${task.url}`);
        await download(task.url, dest);
        return;
    }

    // ── unzip ─────────────────────────────────────────────────────────────────
    // src  : relative path to zip file  e.g. ./tmp/oxmysql.zip
    // dest : relative destination dir   e.g. ./resources/[ox]
    if (action === 'unzip') {
        const zipPath = R(task.src);
        const destDir = R(task.dest);
        console.log(`    unzip ${task.src} → ${task.dest}`);

        const tmpOut = path.join(TMP_DIR, `unzip_${Date.now()}`);
        unzipTo(zipPath, tmpOut);

        // Move each top-level entry into destDir
        // (preserves the resource folder name inside the zip)
        fs.mkdirSync(destDir, { recursive: true });
        for (const entry of fs.readdirSync(tmpOut)) {
            const src  = path.join(tmpOut, entry);
            const dst  = path.join(destDir, entry);
            if (fs.existsSync(dst)) rmrf(dst);
            fs.renameSync(src, dst);
        }
        rmrf(tmpOut);
        return;
    }

    // ── move_path ─────────────────────────────────────────────────────────────
    if (action === 'move_path') {
        const src  = R(task.src);
        const dest = R(task.dest);
        console.log(`    mv ${task.src} → ${task.dest}`);
        if (!fs.existsSync(src)) { console.warn(`    WARN: src not found: ${src}`); return; }
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        fs.renameSync(src, dest);
        return;
    }

    // ── remove_path ───────────────────────────────────────────────────────────
    if (action === 'remove_path') {
        const p = R(task.path);
        console.log(`    rm -rf ${task.path}`);
        rmrf(p);
        return;
    }

    // ── ensure_dir ────────────────────────────────────────────────────────────
    if (action === 'ensure_dir') {
        const dir = R(task.path || task.dest);
        console.log(`    mkdir -p ${task.path || task.dest}`);
        fs.mkdirSync(dir, { recursive: true });
        return;
    }

    // ── write_file ────────────────────────────────────────────────────────────
    if (action === 'write_file') {
        const dest    = R(task.dest);
        const content = task._multiline || task.content || '';
        console.log(`    write ${task.dest}`);
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        fs.writeFileSync(dest, content);
        return;
    }

    // ── intentionally skipped ─────────────────────────────────────────────────
    if (['connect_database', 'query_database', 'waste_time'].includes(action)) {
        console.log(`    skip [${action}] — handled externally`);
        return;
    }

    console.log(`    skip [${action}] — unknown action`);
}

// ── Main ──────────────────────────────────────────────────────────────────────
(async () => {
    const yaml  = fs.readFileSync(RECIPE_FILE, 'utf8');
    const tasks = parseRecipe(yaml);
    console.log(`Parsed ${tasks.length} tasks.`);

    let ok = 0, skipped = 0, failed = 0;
    for (let i = 0; i < tasks.length; i++) {
        const task = tasks[i];
        const label = task.dest || task.path || task.src || '';
        process.stdout.write(`[${String(i+1).padStart(3)}/${tasks.length}] ${task.action}  ${label}\n`);
        try {
            await runTask(task);
            ok++;
        } catch (err) {
            console.warn(`  WARN: ${err.message}`);
            failed++;
        }
    }
    console.log(`\nDone. ok=${ok}  failed=${failed}`);
    if (failed > 0) { console.warn('Some tasks failed — check output above.'); }
})();
NODE_EOF
}

# =============================================================================
# STEP 2 — Inject DB connection strings into the recipe-provided server.cfg
#           (The recipe clones its own server.cfg from txAdminRecipe repo)
# =============================================================================
patch_server_cfg() {
    step "Patching server.cfg with database connection strings..."
    local CFG="${SERVER_DIR}/server.cfg"

    if [[ ! -f "${CFG}" ]]; then
        warn "server.cfg not found at ${CFG} — writing a minimal one."
        cat > "${CFG}" << CFG_EOF
# Auto-generated minimal server.cfg — recipe server.cfg was not deployed
sv_licenseKey "${SERVER_KEY}"
sets sv_projectName "${SERVER_NAME}"
sets sv_projectDesc "Powered by Mythic Framework"
endpoint_add_tcp "0.0.0.0:${FIVEM_PORT}"
endpoint_add_udp "0.0.0.0:${FIVEM_PORT}"
set onesync on
ensure mapmanager
ensure chat
ensure spawnmanager
ensure sessionmanager
ensure fivem
ensure hardcap
ensure rconlog
ensure oxmysql
ensure ox_lib
exec "configs/resources.cfg"
CFG_EOF
    fi

    # ── Inject DB strings if not already present ──────────────────────────────
    if ! grep -q "mysql_connection_string" "${CFG}"; then
        cat >> "${CFG}" << CFG_EOF

# ── Database — injected by mythic-entrypoint.sh ───────────────────────────────
set mysql_connection_string "mysql://${MYSQL_USER}:${MYSQL_PASSWORD}@${MYSQL_HOST}:${MYSQL_PORT:-3306}/${MYSQL_DATABASE}?charset=utf8mb4"
set mongo_url "mongodb://${MONGO_USER}:${MONGO_PASSWORD}@${MONGO_HOST}:${MONGO_PORT:-27017}/${MONGO_DATABASE}?authSource=admin"
CFG_EOF
        info "DB connection strings appended to server.cfg."
    else
        info "server.cfg already has mysql_connection_string — skipping."
    fi

    # ── Ensure sv_licenseKey is present ──────────────────────────────────────
    if ! grep -q "sv_licenseKey" "${CFG}"; then
        sed -i "1s/^/sv_licenseKey \"${SERVER_KEY}\"\n/" "${CFG}"
    fi

    info "server.cfg ready."
}

# =============================================================================
# STEP 3 — Pre-configure txAdmin (skip browser wizard)
# =============================================================================
configure_txadmin() {
    step "Pre-configuring txAdmin..."

    local PROFILE_DIR="${TXDATA_DIR}/profile-default"
    mkdir -p "${PROFILE_DIR}/data"

    # ── config.json — marks setup as complete ─────────────────────────────────
    local CFG_FILE="${PROFILE_DIR}/config.json"
    if [[ ! -f "${CFG_FILE}" ]]; then
        cat > "${CFG_FILE}" << JSON
{
  "setupDone": true,
  "defaults": {
    "license": "${SERVER_KEY}",
    "serverDataPath": "${SERVER_DIR}",
    "cfgPath": "${SERVER_DIR}/server.cfg"
  },
  "server": {
    "dataPath": "${SERVER_DIR}",
    "cfgPath": "${SERVER_DIR}/server.cfg",
    "onesync": "on",
    "autostart": true,
    "quiet": false
  },
  "webServer": {
    "port": ${TXADMIN_PORT},
    "allowedOrigins": null
  },
  "discordBot": {
    "enabled": false
  },
  "playerController": {
    "onJoinCheckBan": true,
    "onJoinCheckWhitelist": false
  }
}
JSON
        info "txAdmin config.json created."
    else
        info "txAdmin config.json already exists — skipping."
    fi

    # ── admins.json — master admin account ────────────────────────────────────
    local ADMINS_FILE="${PROFILE_DIR}/admins.json"
    if [[ ! -f "${ADMINS_FILE}" ]]; then
        local PW_HASH
        PW_HASH=$(echo -n "${TXADMIN_MASTER_PASSWORD}" | sha256sum | awk '{print $1}')
        cat > "${ADMINS_FILE}" << JSON
[
  {
    "name": "${TXADMIN_MASTER_USERNAME}",
    "master": true,
    "password_hash": "${PW_HASH}",
    "providers": {},
    "permissions": []
  }
]
JSON
        info "txAdmin admin account '${TXADMIN_MASTER_USERNAME}' created."
    else
        info "txAdmin admins.json already exists — skipping."
    fi
}

# =============================================================================
# Main — first-run guard via lock file
# =============================================================================
if [[ ! -f "${DEPLOY_LOCK}" ]]; then
    echo ""
    step "========================================================"
    step " First run — Mythic Framework bootstrap starting"
    step "========================================================"
    echo ""

    # deploy_recipe exits 1 on fatal Node.js errors but we want to continue
    # to patch_server_cfg regardless (FXServer needs a cfg to start).
    # Capture the exit code instead of relying on set -e.
    if deploy_recipe; then
        info "Recipe deployed successfully."
    else
        warn "Recipe deployer exited with errors — continuing with partial deployment."
        warn "Some resources may be missing. Check logs above."
    fi

    patch_server_cfg
    configure_txadmin

    touch "${DEPLOY_LOCK}"
    echo ""
    step "========================================================"
    step " Bootstrap complete — lock file written."
    step " txAdmin URL : http://localhost:${TXADMIN_PORT}"
    step " Login       : ${TXADMIN_MASTER_USERNAME} / (your .env password)"
    step "========================================================"
    echo ""
else
    info "Existing deployment found — skipping bootstrap."
    info "Delete ${DEPLOY_LOCK} to force a fresh re-deploy."
fi

# =============================================================================
# Hand off to the ich777 start.sh
# Downloads/updates FXServer artifact from runtime.fivem.net, then starts FXServer
# =============================================================================
# =============================================================================
# Hand off to the ich777 start.sh
# Downloads/updates FXServer artifact from runtime.fivem.net, then starts FXServer
# =============================================================================
info "Handing off to ich777 start.sh..."

if [[ ! -f /opt/scripts/start.sh ]]; then
    error "$(cat <<'MSG'
/opt/scripts/start.sh not found!

This means the 'scripts/' folder was missing from your GitHub repo when the
Docker image was built. The Dockerfile clones your repo and copies scripts/
into /opt/scripts/ — if the folder is empty or absent, start.sh won't exist.

Fix:
  1. Copy the scripts/ folder from https://github.com/Phille06/docker-fivem-server
     into your mythic-framework-docker repo root.
  2. Commit and push — GitHub Actions will rebuild and push a fixed image.
  3. On your server: docker compose pull fivem && docker compose up -d fivem
MSG
)"
fi

exec /opt/scripts/start.sh "$@"
