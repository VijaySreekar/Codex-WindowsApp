"use strict";

const { app, ipcMain } = require("electron");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const CHANNEL_LIST = "codex_desktop:accounts:list";
const CHANNEL_CURRENT = "codex_desktop:accounts:current";
const CHANNEL_SWITCH = "codex_desktop:accounts:switch";

function sanitizeAccountName(value) {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  if (!trimmed) {
    return null;
  }
  const sanitized = trimmed
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9_-]/g, "");
  return sanitized || null;
}

function normalizeDir(value) {
  if (!value || typeof value !== "string") {
    return null;
  }

  return path.normalize(value);
}

function getAccountsRoot() {
  const envRoot = normalizeDir(process.env.CODEX_ACCOUNTS_ROOT);
  if (envRoot) {
    return envRoot;
  }
  const home = os.homedir();
  if (home) {
    return path.join(home, ".codex-accounts");
  }
  return null;
}

function getSourceHome() {
  const envSource = normalizeDir(process.env.CODEX_ACCOUNTS_SOURCE_HOME);
  if (envSource) {
    return envSource;
  }
  const home = os.homedir();
  if (!home) {
    return null;
  }
  return path.join(home, ".codex");
}

function getAccountHome(accountName) {
  const root = getAccountsRoot();
  if (!root) {
    return null;
  }
  return path.join(root, accountName);
}

function getCurrentAccountName() {
  const explicit = sanitizeAccountName(process.env.CODEX_ACCOUNTS_CURRENT || "");
  if (explicit) {
    return explicit;
  }
  const root = getAccountsRoot();
  const codexHome = normalizeDir(process.env.CODEX_HOME || "");
  if (root && codexHome) {
    const rootWithSep = root.endsWith(path.sep) ? root : root + path.sep;
    const lowerCodexHome = codexHome.toLowerCase();
    const lowerRootWithSep = rootWithSep.toLowerCase();
    if (lowerCodexHome.startsWith(lowerRootWithSep)) {
      const relative = codexHome.slice(rootWithSep.length);
      const parts = relative.split(/[\\/]+/).filter(Boolean);
      if (parts.length >= 1) {
        const name = sanitizeAccountName(parts[0]);
        if (name) {
          return name;
        }
      }
    }
  }
  const userDataDir = normalizeDir(app.getPath("userData"));
  if (!root || !userDataDir) {
    return null;
  }
  const rootWithSep = root.endsWith(path.sep) ? root : root + path.sep;
  const lowerUserData = userDataDir.toLowerCase();
  const lowerRootWithSep = rootWithSep.toLowerCase();
  const lowerSuffix = `${path.sep}electron-userdata`.toLowerCase();
  if (!lowerUserData.startsWith(lowerRootWithSep) || !lowerUserData.endsWith(lowerSuffix)) {
    return null;
  }
  const relative = userDataDir.slice(rootWithSep.length);
  const parts = relative.split(/[\\/]+/).filter(Boolean);
  if (parts.length >= 2 && parts[1].toLowerCase() === "electron-userdata") {
    return sanitizeAccountName(parts[0]);
  }
  return null;
}

function readJson(filePath) {
  try {
    if (!fs.existsSync(filePath)) {
      return null;
    }
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

function writeJson(filePath, value) {
  try {
    fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  } catch {}
}

function ensureAccountHome(accountHome) {
  fs.mkdirSync(accountHome, { recursive: true });
  const configPath = path.join(accountHome, "config.toml");
  if (!fs.existsSync(configPath)) {
    fs.writeFileSync(configPath, "", "utf8");
  }
}

function replaceDir(sourceDir, destDir) {
  if (!fs.existsSync(sourceDir)) {
    return false;
  }
  fs.rmSync(destDir, { recursive: true, force: true });
  fs.mkdirSync(destDir, { recursive: true });
  fs.cpSync(sourceDir, destDir, { recursive: true, force: true });
  return true;
}

function syncSharedConfigToAccount(accountHome) {
  const sourceHome = getSourceHome();
  if (!sourceHome) {
    return { configCopied: false, rulesCopied: false };
  }
  const sourceConfig = path.join(sourceHome, "config.toml");
  let configCopied = false;
  if (fs.existsSync(sourceConfig)) {
    fs.copyFileSync(sourceConfig, path.join(accountHome, "config.toml"));
    configCopied = true;
  }
  const sourceRules = path.join(sourceHome, "rules");
  const rulesCopied = replaceDir(sourceRules, path.join(accountHome, "rules"));
  return { configCopied, rulesCopied };
}

function touchAccountTracking(accountHome) {
  const accountJsonPath = path.join(accountHome, "account.json");
  const meta = readJson(accountJsonPath) || {};
  const nowUtc = new Date();
  const next = { ...meta };
  const tracking = { ...(meta.tracking || {}) };
  tracking.last_launch_utc = nowUtc.toISOString();

  const parseUtc = (value) => {
    if (!value) {
      return null;
    }
    const parsed = new Date(value);
    if (Number.isNaN(parsed.getTime())) {
      return null;
    }
    return parsed;
  };

  const fiveStart = parseUtc(tracking.five_hour_window_start_utc);
  if (!fiveStart || fiveStart.getTime() + 5 * 60 * 60 * 1000 <= nowUtc.getTime()) {
    tracking.five_hour_window_start_utc = nowUtc.toISOString();
  }

  const weekStart = parseUtc(tracking.weekly_window_start_utc);
  if (!weekStart || weekStart.getTime() + 7 * 24 * 60 * 60 * 1000 <= nowUtc.getTime()) {
    tracking.weekly_window_start_utc = nowUtc.toISOString();
  }

  next.tracking = tracking;
  writeJson(accountJsonPath, next);
}

function getAccountInfo(name, accountHome) {
  const meta = readJson(path.join(accountHome, "account.json")) || {};
  return {
    name,
    label: typeof meta.label === "string" ? meta.label : null,
    email: typeof meta.email === "string" ? meta.email : null,
    hasAuth: fs.existsSync(path.join(accountHome, "auth.json")),
  };
}

function listAccounts() {
  const root = getAccountsRoot();
  if (!root || !fs.existsSync(root)) {
    return [];
  }
  try {
    return fs
      .readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => sanitizeAccountName(entry.name))
      .filter((name) => !!name)
      .sort((a, b) => a.localeCompare(b))
      .map((name) => {
        const accountHome = getAccountHome(name);
        return getAccountInfo(name, accountHome);
      });
  } catch {
    return [];
  }
}

function buildLaunchArgs(nextUserDataDir, nextCacheDir) {
  const args = process.argv.slice(1).filter((value) => {
    const flag = String(value || "").toLowerCase();
    if (flag.startsWith("--user-data-dir") || flag.startsWith("--disk-cache-dir")) {
      return false;
    }
    return true;
  });

  args.push(`--user-data-dir=${nextUserDataDir}`);
  args.push(`--disk-cache-dir=${nextCacheDir}`);
  return args;
}

function switchAccount(rawAccountName, options = {}) {
  const accountName = sanitizeAccountName(rawAccountName);
  if (!accountName) {
    return { ok: false, error: "Invalid account name." };
  }

  const accountsRoot = getAccountsRoot();
  if (!accountsRoot) {
    return { ok: false, error: "Accounts root is unavailable." };
  }
  const profileRoot = getAccountHome(accountName);
  ensureAccountHome(profileRoot);
  const userDataDir = path.join(profileRoot, "electron-userdata");
  const cacheDir = path.join(profileRoot, "electron-cache");
  fs.mkdirSync(userDataDir, { recursive: true });
  fs.mkdirSync(cacheDir, { recursive: true });
  let syncResult = { configCopied: false, rulesCopied: false };
  try {
    syncResult = syncSharedConfigToAccount(profileRoot);
  } catch (error) {
    syncResult = {
      configCopied: false,
      rulesCopied: false,
      warning: error instanceof Error ? error.message : "sync failed",
    };
  }
  try {
    touchAccountTracking(profileRoot);
  } catch {}

  const env = {
    ...process.env,
    CODEX_ACCOUNTS_ROOT: accountsRoot,
    CODEX_ACCOUNTS_SOURCE_HOME: getSourceHome() || "",
    CODEX_ACCOUNTS_CURRENT: accountName,
    CODEX_HOME: profileRoot,
  };
  const args = buildLaunchArgs(userDataDir, cacheDir);
  const closeCurrent = options && options.closeCurrent === true;

  try {
    const child = spawn(process.execPath, args, {
      detached: true,
      stdio: "ignore",
      windowsHide: false,
      env,
    });
    child.unref();
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : "Failed to launch new instance.",
    };
  }

  if (closeCurrent) {
    setTimeout(() => {
      app.exit(0);
    }, 120);
  }

  return {
    ok: true,
    account: accountName,
    openedNewInstance: true,
    closedCurrent: closeCurrent,
    synced: syncResult,
  };
}

ipcMain.handle(CHANNEL_LIST, async () => {
  return {
    accounts: listAccounts(),
    current: getCurrentAccountName(),
    root: getAccountsRoot(),
  };
});

ipcMain.handle(CHANNEL_CURRENT, async () => {
  return {
    current: getCurrentAccountName(),
    root: getAccountsRoot(),
    sourceHome: getSourceHome(),
  };
});

ipcMain.handle(CHANNEL_SWITCH, async (_event, accountName, options) => {
  return switchAccount(accountName, options);
});
