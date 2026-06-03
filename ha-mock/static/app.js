(() => {
  const arm = document.getElementById("arm");
  const car = document.getElementById("car");
  const gateBadge = document.getElementById("gateBadge");
  const gateStateText = document.getElementById("gateStateText");
  const opensCount = document.getElementById("opensCount");
  const lastVehicle = document.getElementById("lastVehicle");
  const lastRssi = document.getElementById("lastRssi");
  const lastTime = document.getElementById("lastTime");
  const logList = document.getElementById("logList");
  const eventsCount = document.getElementById("eventsCount");
  const connDot = document.getElementById("connDot");
  const connText = document.getElementById("connText");
  const manualBtn = document.getElementById("manualBtn");
  const resetBtn = document.getElementById("resetBtn");
  const webhookUrl = document.getElementById("webhookUrl");

  const STATE_LABELS = {
    closed: "Закрыт",
    opening: "Открывается",
    open: "Открыт",
    closing: "Закрывается",
  };

  webhookUrl.textContent = `${location.origin}/api/webhook/gate_open`;

  // ---- Animation ----
  function setGateState(s) {
    const label = STATE_LABELS[s] || s;
    gateBadge.textContent = label;
    gateBadge.className = `badge ${s}`;
    gateStateText.textContent = label.toUpperCase();
    gateStateText.className = `value ${s}`;
    if (s === "opening" || s === "open") {
      arm.setAttribute("transform", "rotate(-85 66 120)");
      if (s === "opening") {
        car.classList.remove("driving-out");
        car.classList.add("driving-in");
      }
    } else if (s === "closing" || s === "closed") {
      arm.setAttribute("transform", "rotate(0 66 120)");
      if (s === "closing") {
        car.classList.remove("driving-in");
        car.classList.add("driving-out");
      }
    }
  }

  // ---- Render ----
  function fmtTime(iso) {
    if (!iso) return "—";
    try {
      const d = new Date(iso);
      return d.toLocaleTimeString("ru", { hour: "2-digit", minute: "2-digit", second: "2-digit" });
    } catch {
      return iso;
    }
  }

  function applySnapshot(snap) {
    opensCount.textContent = String(snap.opens_today ?? 0);
    lastVehicle.textContent = snap.last_vehicle || "—";
    lastRssi.textContent = snap.last_rssi !== null && snap.last_rssi !== undefined ? `${snap.last_rssi} dBm` : "—";
    lastTime.textContent = fmtTime(snap.last_open_at);
    renderEvents(snap.events || []);
  }

  function renderEvents(events) {
    eventsCount.textContent = String(events.length);
    if (!events.length) {
      logList.innerHTML = '<div class="empty">Ждём события...</div>';
      return;
    }
    logList.innerHTML = "";
    for (const ev of events) {
      const row = document.createElement("div");
      row.className = `log-row ${ev.level || "info"}`;
      row.innerHTML = `
        <span class="log-time">${ev.ts}</span>
        <span class="log-text">${escapeHtml(ev.text)}</span>
      `;
      logList.appendChild(row);
    }
  }

  function addEvent(ev) {
    if (logList.querySelector(".empty")) {
      logList.innerHTML = "";
    }
    const row = document.createElement("div");
    row.className = `log-row ${ev.level || "info"}`;
    row.innerHTML = `
      <span class="log-time">${ev.ts}</span>
      <span class="log-text">${escapeHtml(ev.text)}</span>
    `;
    logList.prepend(row);
    eventsCount.textContent = String(logList.children.length);
    if (logList.children.length > 50) {
      logList.removeChild(logList.lastChild);
    }
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  // ---- WebSocket ----
  let ws = null;
  let reconnectTimer = null;

  function setConnected(connected) {
    connDot.classList.toggle("connected", connected);
    connText.textContent = connected ? "Подключено" : "Переподключение...";
  }

  function connect() {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    ws = new WebSocket(`${proto}://${location.host}/ws`);

    ws.onopen = () => {
      setConnected(true);
      if (reconnectTimer) {
        clearTimeout(reconnectTimer);
        reconnectTimer = null;
      }
    };

    ws.onclose = () => {
      setConnected(false);
      reconnectTimer = setTimeout(connect, 2000);
    };

    ws.onerror = () => {
      // onclose will fire next
    };

    ws.onmessage = (e) => {
      let msg;
      try {
        msg = JSON.parse(e.data);
      } catch {
        return;
      }
      if (msg.type === "snapshot") {
        applySnapshot(msg.snapshot);
      } else if (msg.type === "event") {
        addEvent(msg.event);
      } else if (msg.type === "gate") {
        setGateState(msg.state);
      }
    };
  }

  // ---- Buttons ----
  manualBtn.addEventListener("click", async () => {
    manualBtn.disabled = true;
    try {
      await fetch("/api/test/open", { method: "POST" });
    } finally {
      setTimeout(() => (manualBtn.disabled = false), 8000);
    }
  });

  resetBtn.addEventListener("click", async () => {
    if (!confirm("Очистить статистику и журнал?")) return;
    await fetch("/api/test/reset", { method: "POST" });
  });

  // ---- Boot ----
  setGateState("closed");
  connect();
})();
