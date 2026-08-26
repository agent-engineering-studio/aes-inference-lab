/* AES Inference Lab — streaming chat, embedding, theme */
(() => {
  "use strict";

  /* ---------- theme ---------- */
  const root = document.documentElement;
  try {
    const saved = localStorage.getItem("lab-theme");
    if (saved) root.setAttribute("data-theme", saved);
  } catch (_) { /* storage not available */ }

  document.getElementById("theme-toggle")?.addEventListener("click", () => {
    const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    const now = root.getAttribute("data-theme") || (dark ? "dark" : "light");
    const next = now === "dark" ? "light" : "dark";
    root.setAttribute("data-theme", next);
    try { localStorage.setItem("lab-theme", next); } catch (_) { /* ignore */ }
  });

  /* ---------- streaming chat ---------- */
  const form = document.getElementById("chat-form");
  const out = document.getElementById("c-out");
  const stats = document.getElementById("c-stats");
  const sendBtn = document.getElementById("c-send");
  let controller = null;

  const fmt = (v, d = 0) => (v == null ? "—" : Number(v).toFixed(d));

  document.getElementById("c-stop")?.addEventListener("click", () => controller?.abort());

  form?.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    controller?.abort();
    controller = new AbortController();
    out.textContent = "";
    stats.innerHTML = "";
    sendBtn.disabled = true;
    sendBtn.textContent = "in progress…";

    const sel = document.getElementById("c-endpoint");
    const body = {
      endpoint: sel.value,
      model: document.getElementById("c-model").value.trim()
             || sel.selectedOptions[0]?.dataset.default || "auto",
      prompt: document.getElementById("c-prompt").value,
      max_tokens: Number(document.getElementById("c-max").value) || 256,
    };

    try {
      const res = await fetch("/api/chat/stream", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const blocks = buffer.split("\n\n");
        buffer = blocks.pop() ?? "";
        for (const block of blocks) {
          let event = "message", data = "";
          for (const line of block.split("\n")) {
            if (line.startsWith("event:")) event = line.slice(6).trim();
            else if (line.startsWith("data:")) data += line.slice(5).trim();
          }
          if (!data) continue;
          const payload = JSON.parse(data);
          if (event === "delta") {
            out.textContent += payload.text;
            out.scrollTop = out.scrollHeight;
          } else if (event === "done") {
            stats.innerHTML = [
              ["first token", `${fmt(payload.ttft_ms)} ms`],
              ["total", `${fmt(payload.total_ms)} ms`],
              ["token", `${payload.output_tokens}`],
              ["speed", `${fmt(payload.tokens_per_s, 2)} tok/s`],
            ].map(([k, v]) => `<span>${k} <b>${v}</b></span>`).join("");
          } else if (event === "error") {
            out.textContent += `\n\n[error] ${payload.error}`;
          }
        }
      }
    } catch (err) {
      if (err.name !== "AbortError") out.textContent += `\n\n[error] ${err.message}`;
    } finally {
      sendBtn.disabled = false;
      sendBtn.textContent = "Send streaming";
      controller = null;
    }
  });

  /* ---------- embedding ---------- */
  const eForm = document.getElementById("embed-form");
  const eOut = document.getElementById("e-out");

  const shade = (v) => {
    const t = Math.max(0, Math.min(1, (v + 1) / 2));
    return `color-mix(in srgb, var(--amber) ${Math.round(t * 70)}%, transparent)`;
  };

  eForm?.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const texts = document.getElementById("e-texts").value
      .split("\n").map((s) => s.trim()).filter(Boolean);
    if (texts.length < 2) {
      eOut.innerHTML = '<p class="empty" style="color:var(--bad)">At least two sentences are required.</p>';
      return;
    }
    eOut.innerHTML = '<p class="empty">Computing…</p>';
    try {
      const res = await fetch("/api/embed", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          endpoint: document.getElementById("e-endpoint").value,
          model: document.getElementById("e-model").value.trim() || "embed",
          texts,
        }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);

      const head = data.texts.map((_, i) => `<th class="num">${i + 1}</th>`).join("");
      const rows = data.similarity.map((row, i) => `
        <tr><td style="max-width:420px">${i + 1}. ${data.texts[i]
          .replace(/[<>&]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" }[c]))}</td>
        ${row.map((v, j) => `<td class="h" style="background:${i === j ? "transparent" : shade(v)}">${v.toFixed(3)}</td>`).join("")}</tr>`).join("");

      eOut.innerHTML = `
        <div class="tablewrap"><table class="heat">
          <thead><tr><th>Sentence</th>${head}</tr></thead>
          <tbody>${rows}</tbody></table></div>
        <div class="statline"><span>dimensions <b>${data.dimensions}</b></span>
          <span>latency <b>${fmt(data.latency_ms)} ms</b></span>
          <span>model <b>${data.model}</b></span></div>`;
    } catch (err) {
      eOut.innerHTML = `<p class="empty" style="color:var(--bad)">${err.message}</p>`;
    }
  });
})();
