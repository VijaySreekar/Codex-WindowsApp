;(() => {
  if (window.__codexAccountSwitcherPreloadV7) {
    return;
  }
  window.__codexAccountSwitcherPreloadV7 = true;

  const listChannel = "codex_desktop:accounts:list";
  const currentChannel = "codex_desktop:accounts:current";
  const switchChannel = "codex_desktop:accounts:switch";

  try {
    const bridge = window.electronBridge;
    if (bridge && typeof bridge === "object" && typeof bridge.listAccounts !== "function") {
      bridge.listAccounts = () => n.ipcRenderer.invoke(listChannel);
    }
    if (bridge && typeof bridge === "object" && typeof bridge.getCurrentAccount !== "function") {
      bridge.getCurrentAccount = () => n.ipcRenderer.invoke(currentChannel);
    }
    if (bridge && typeof bridge === "object" && typeof bridge.switchAccount !== "function") {
      bridge.switchAccount = (accountName, options) =>
        n.ipcRenderer.invoke(switchChannel, accountName, options);
    }
  } catch {}

  function mountUI() {
    const rootId = "codex-account-switcher-preload";
    const existing = document.getElementById(rootId);
    if (existing) {
      try { existing.remove(); } catch {}
    }

    const root = document.createElement("div");
    root.id = rootId;
    root.style.position = "fixed";
    root.style.bottom = "14px";
    root.style.right = "14px";
    root.style.zIndex = "2147483647";
    root.style.fontFamily = "ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif";

    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = "Accounts";
    btn.style.border = "1px solid #0ea5e9";
    btn.style.background = "#082f49";
    btn.style.color = "#e0f2fe";
    btn.style.borderRadius = "999px";
    btn.style.padding = "8px 12px";
    btn.style.fontSize = "12px";
    btn.style.fontWeight = "600";
    btn.style.cursor = "pointer";
    btn.style.boxShadow = "0 8px 18px rgba(0,0,0,0.35)";

    const panel = document.createElement("div");
    panel.style.display = "none";
    panel.style.width = "320px";
    panel.style.marginTop = "8px";
    panel.style.border = "1px solid #1f2937";
    panel.style.background = "#020617";
    panel.style.color = "#e5e7eb";
    panel.style.borderRadius = "10px";
    panel.style.padding = "10px";
    panel.style.boxShadow = "0 12px 30px rgba(0,0,0,0.45)";

    const title = document.createElement("div");
    title.textContent = "Codex Accounts";
    title.style.fontSize = "12px";
    title.style.fontWeight = "700";
    title.style.marginBottom = "8px";

    const current = document.createElement("div");
    current.style.fontSize = "11px";
    current.style.opacity = "0.85";
    current.style.marginBottom = "6px";
    current.textContent = "Current: loading...";

    const info = document.createElement("div");
    info.style.fontSize = "10px";
    info.style.opacity = "0.7";
    info.style.marginBottom = "8px";

    const select = document.createElement("select");
    select.style.width = "100%";
    select.style.marginBottom = "8px";
    select.style.padding = "7px";
    select.style.borderRadius = "8px";
    select.style.border = "1px solid #334155";
    select.style.background = "#0f172a";
    select.style.color = "#f8fafc";
    select.style.fontSize = "12px";

    const input = document.createElement("input");
    input.type = "text";
    input.placeholder = "type new account name";
    input.style.width = "100%";
    input.style.marginBottom = "8px";
    input.style.padding = "7px";
    input.style.borderRadius = "8px";
    input.style.border = "1px solid #334155";
    input.style.background = "#0f172a";
    input.style.color = "#f8fafc";
    input.style.fontSize = "12px";

    const actions = document.createElement("div");
    actions.style.display = "flex";
    actions.style.gap = "8px";

    const switchBtn = document.createElement("button");
    switchBtn.type = "button";
    switchBtn.textContent = "Switch";
    switchBtn.style.flex = "1";
    switchBtn.style.border = "1px solid #22c55e";
    switchBtn.style.background = "#14532d";
    switchBtn.style.color = "#dcfce7";
    switchBtn.style.borderRadius = "8px";
    switchBtn.style.padding = "7px";
    switchBtn.style.cursor = "pointer";

    const refreshBtn = document.createElement("button");
    refreshBtn.type = "button";
    refreshBtn.textContent = "Refresh";
    refreshBtn.style.flex = "1";
    refreshBtn.style.border = "1px solid #475569";
    refreshBtn.style.background = "#0f172a";
    refreshBtn.style.color = "#e2e8f0";
    refreshBtn.style.borderRadius = "8px";
    refreshBtn.style.padding = "7px";
    refreshBtn.style.cursor = "pointer";

    const status = document.createElement("div");
    status.style.marginTop = "8px";
    status.style.fontSize = "11px";
    status.style.opacity = "0.9";

    const sanitize = (v) =>
      String(v || "")
        .trim()
        .toLowerCase()
        .replace(/\s+/g, "-")
        .replace(/[^a-z0-9_-]/g, "");

    const setStatus = (m) => {
      status.textContent = m || "";
    };

    const fill = (accounts, selected) => {
      select.innerHTML = "";
      const empty = document.createElement("option");
      empty.value = "";
      empty.textContent = "Select account...";
      select.appendChild(empty);

      for (const a of accounts) {
        const opt = document.createElement("option");
        opt.value = a.name;
        const bits = [a.name];
        if (a.label) bits.push(a.label);
        if (a.email) bits.push(a.email);
        bits.push(a.hasAuth ? "signed in" : "no auth");
        opt.textContent = bits.join(" | ");
        select.appendChild(opt);
      }
      if (selected) {
        select.value = selected;
      }
    };

    const refresh = async () => {
      setStatus("Loading...");
      try {
        const result = await n.ipcRenderer.invoke(listChannel);
        const accounts = Array.isArray(result?.accounts) ? result.accounts : [];
        current.textContent = `Current: ${result?.current || "unknown"}`;
        info.textContent = result?.root ? `Base: ${result.root}` : "";
        fill(accounts, result?.current || "");
        setStatus("");
      } catch (err) {
        setStatus(`Load failed: ${err?.message || "unknown error"}`);
      }
    };

    const doSwitch = async () => {
      const requested = sanitize((input.value || "").trim() || select.value);
      if (!requested) {
        setStatus("Use letters/numbers for account name.");
        return;
      }
      setStatus(`Opening ${requested}...`);
      try {
        const result = await n.ipcRenderer.invoke(switchChannel, requested, { closeCurrent: false });
        if (!result?.ok) {
          setStatus(result?.error || "Switch failed.");
          return;
        }
        setStatus("Opened new instance. You can keep this one open.");
      } catch (err) {
        setStatus(`Open failed: ${err?.message || "unknown error"}`);
      }
    };

    btn.addEventListener("click", () => {
      panel.style.display = panel.style.display === "none" ? "block" : "none";
      if (panel.style.display === "block") refresh();
    });
    refreshBtn.addEventListener("click", refresh);
    switchBtn.addEventListener("click", doSwitch);
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        doSwitch();
      }
    });

    actions.appendChild(switchBtn);
    actions.appendChild(refreshBtn);
    panel.appendChild(title);
    panel.appendChild(current);
    panel.appendChild(info);
    panel.appendChild(select);
    panel.appendChild(input);
    panel.appendChild(actions);
    panel.appendChild(status);

    root.appendChild(btn);
    root.appendChild(panel);
    document.body.appendChild(root);
  }

  function startMountLoop() {
    let attempts = 0;
    const timer = setInterval(() => {
      attempts += 1;
      if (document.body) {
        try {
          mountUI();
          clearInterval(timer);
          return;
        } catch {}
      }
      if (attempts >= 80) {
        clearInterval(timer);
      }
    }, 250);
  }

  if (document.readyState === "loading") {
    window.addEventListener("DOMContentLoaded", startMountLoop, { once: true });
  } else {
    startMountLoop();
  }
})();
