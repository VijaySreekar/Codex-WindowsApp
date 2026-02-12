(() => {
  const rootId = "codex-account-switcher";
  const NAME_PATTERN = /[^a-z0-9_-]/g;

  function sanitizeName(value) {
    if (!value || typeof value !== "string") {
      return "";
    }
    return value.trim().toLowerCase().replace(/\s+/g, "-").replace(NAME_PATTERN, "");
  }

  function getBridge() {
    const bridge = window.electronBridge;
    if (!bridge) {
      return null;
    }
    if (typeof bridge.listAccounts !== "function") {
      return null;
    }
    if (typeof bridge.switchAccount !== "function") {
      return null;
    }
    return bridge;
  }

  function ensureRoot() {
    const existing = document.getElementById(rootId);
    if (existing) {
      return existing;
    }

    const root = document.createElement("div");
    root.id = rootId;
    root.style.position = "fixed";
    root.style.top = "10px";
    root.style.right = "12px";
    root.style.zIndex = "2147483647";
    root.style.fontFamily = "ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif";
    document.body.appendChild(root);
    return root;
  }

  function createButton(text) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = text;
    button.style.border = "1px solid #4b5563";
    button.style.background = "#111827";
    button.style.color = "#f9fafb";
    button.style.borderRadius = "8px";
    button.style.padding = "7px 10px";
    button.style.fontSize = "12px";
    button.style.cursor = "pointer";
    return button;
  }

  async function mount() {
    const bridge = getBridge();
    if (!bridge) {
      return;
    }

    const root = ensureRoot();
    if (root.dataset.ready === "1") {
      return;
    }

    const toggle = createButton("Accounts");
    const panel = document.createElement("div");
    panel.style.marginTop = "8px";
    panel.style.width = "250px";
    panel.style.display = "none";
    panel.style.border = "1px solid #374151";
    panel.style.background = "#0b1220";
    panel.style.color = "#f3f4f6";
    panel.style.borderRadius = "10px";
    panel.style.padding = "10px";
    panel.style.boxShadow = "0 10px 30px rgba(0,0,0,0.35)";

    const title = document.createElement("div");
    title.textContent = "Switch account";
    title.style.fontSize = "12px";
    title.style.fontWeight = "600";
    title.style.marginBottom = "8px";

    const current = document.createElement("div");
    current.style.fontSize = "11px";
    current.style.opacity = "0.8";
    current.style.marginBottom = "6px";
    current.textContent = "Current: default";

    const roots = document.createElement("div");
    roots.style.fontSize = "10px";
    roots.style.opacity = "0.65";
    roots.style.marginBottom = "8px";
    roots.textContent = "";

    const select = document.createElement("select");
    select.style.width = "100%";
    select.style.marginBottom = "8px";
    select.style.padding = "6px";
    select.style.borderRadius = "6px";
    select.style.border = "1px solid #4b5563";
    select.style.background = "#111827";
    select.style.color = "#f9fafb";
    select.style.fontSize = "12px";

    const input = document.createElement("input");
    input.type = "text";
    input.placeholder = "Or type account name";
    input.style.width = "100%";
    input.style.marginBottom = "8px";
    input.style.padding = "6px";
    input.style.borderRadius = "6px";
    input.style.border = "1px solid #4b5563";
    input.style.background = "#111827";
    input.style.color = "#f9fafb";
    input.style.fontSize = "12px";

    const actions = document.createElement("div");
    actions.style.display = "flex";
    actions.style.gap = "8px";

    const switchButton = createButton("Switch");
    switchButton.style.flex = "1";

    const refreshButton = createButton("Refresh");
    refreshButton.style.flex = "1";

    const status = document.createElement("div");
    status.style.marginTop = "8px";
    status.style.fontSize = "11px";
    status.style.opacity = "0.85";
    status.textContent = "";

    const setStatus = (message) => {
      status.textContent = message || "";
    };

    const toLabel = (account) => {
      const bits = [account.name];
      if (account.label) {
        bits.push(account.label);
      }
      if (account.email) {
        bits.push(account.email);
      }
      bits.push(account.hasAuth ? "signed in" : "no auth");
      return bits.join(" | ");
    };

    const fillOptions = (accounts, selected) => {
      select.innerHTML = "";
      const empty = document.createElement("option");
      empty.value = "";
      empty.textContent = "Select account...";
      select.appendChild(empty);
      for (const account of accounts) {
        const option = document.createElement("option");
        option.value = account.name;
        option.textContent = toLabel(account);
        select.appendChild(option);
      }
      if (selected) {
        select.value = selected;
      }
    };

    const refresh = async () => {
      setStatus("Loading...");
      try {
        const result = await bridge.listAccounts();
        const accounts = Array.isArray(result?.accounts)
          ? result.accounts.filter((x) => x && typeof x.name === "string")
          : [];
        const currentName = result?.current || "default";
        current.textContent = `Current: ${currentName}`;
        roots.textContent = result?.root ? `Base: ${result.root}` : "";
        fillOptions(accounts, result?.current || "");
        setStatus("");
      } catch {
        setStatus("Failed to load accounts.");
      }
    };

    const doSwitch = async () => {
      const requested = sanitizeName((input.value || "").trim() || select.value);
      if (!requested) {
        setStatus("Use letters/numbers for account name.");
        return;
      }
      setStatus(`Opening ${requested}...`);
      try {
        const result = await bridge.switchAccount(requested, { closeCurrent: false });
        if (!result?.ok) {
          setStatus(result?.error || "Switch failed.");
          return;
        }
        const syncBits = [];
        if (result?.synced?.configCopied) {
          syncBits.push("config synced");
        }
        if (result?.synced?.rulesCopied) {
          syncBits.push("rules synced");
        }
        if (syncBits.length > 0) {
          setStatus(`Opened new instance (${syncBits.join(", ")}).`);
        } else if (result?.synced?.warning) {
          setStatus(`Opened new instance (sync warning: ${result.synced.warning}).`);
        } else {
          setStatus("Opened new instance.");
        }
      } catch {
        setStatus("Open failed.");
      }
    };

    toggle.addEventListener("click", () => {
      panel.style.display = panel.style.display === "none" ? "block" : "none";
      if (panel.style.display === "block") {
        refresh();
      }
    });

    refreshButton.addEventListener("click", refresh);
    switchButton.addEventListener("click", doSwitch);
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        doSwitch();
      }
    });

    actions.appendChild(switchButton);
    actions.appendChild(refreshButton);
    panel.appendChild(title);
    panel.appendChild(current);
    panel.appendChild(roots);
    panel.appendChild(select);
    panel.appendChild(input);
    panel.appendChild(actions);
    panel.appendChild(status);
    root.appendChild(toggle);
    root.appendChild(panel);
    root.dataset.ready = "1";
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mount, { once: true });
  } else {
    mount();
  }
})();
