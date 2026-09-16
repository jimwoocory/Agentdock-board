from __future__ import annotations

TASKBOARD_APP_HTML = r'''<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>AgentDock Task Board 2.0</title>
  <style>
    :root {
      color-scheme: light dark;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont,
        "Segoe UI", sans-serif;
      --bg: light-dark(#f7f8fa, #0d1117);
      --panel: light-dark(#ffffff, #121923);
      --panel-2: light-dark(#f4f6f8, #17202c);
      --border: light-dark(#d9dee7, #2a3748);
      --muted: light-dark(#667085, #95a4b8);
      --text: light-dark(#101828, #eef4fb);
      --accent: light-dark(#175cd3, #78a9ff);
      --good: #22a559;
      --warn: #d97706;
      --bad: #d92d20;
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; width: 100%; min-height: 100%; background: var(--bg); color: var(--text); }
    body { padding: 12px; }
    .shell { width: 100%; }
    .topbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
    .title { margin: 0; font-size: 16px; font-weight: 760; }
    .subtitle { margin-top: 3px; font-size: 11px; color: var(--muted); }
    .live { display: flex; align-items: center; gap: 6px; font-size: 11px; color: var(--muted); white-space: nowrap; }
    .dot { width: 8px; height: 8px; border-radius: 999px; background: var(--good); box-shadow: 0 0 0 3px color-mix(in srgb, var(--good) 18%, transparent); }
    .controls { display: flex; align-items: center; gap: 8px; margin: 12px 0; }
    select, button {
      border: 1px solid var(--border); background: var(--panel); color: var(--text);
      border-radius: 8px; min-height: 32px; padding: 0 10px; font: inherit; font-size: 12px;
    }
    button { cursor: pointer; }
    button:disabled { opacity: .55; cursor: wait; }
    .count { margin-left: auto; color: var(--muted); font-size: 11px; }
    .grid { display: grid; grid-template-columns: repeat(4, minmax(180px, 1fr)); gap: 10px; overflow-x: auto; padding-bottom: 2px; }
    .column { min-width: 180px; border: 1px solid var(--border); border-radius: 10px; background: var(--panel); overflow: hidden; }
    .column-head { display: flex; align-items: center; justify-content: space-between; padding: 9px 10px; border-bottom: 1px solid var(--border); font-size: 12px; font-weight: 700; }
    .badge { min-width: 20px; text-align: center; border-radius: 999px; padding: 2px 6px; background: var(--panel-2); color: var(--muted); font-size: 10px; }
    .cards { display: grid; gap: 8px; min-height: 132px; padding: 8px; align-content: start; }
    .empty { color: var(--muted); font-size: 11px; text-align: center; padding: 35px 6px; }
    .card { border: 1px solid var(--border); border-radius: 9px; padding: 9px; background: var(--panel-2); }
    .card-top { display: flex; gap: 8px; align-items: flex-start; justify-content: space-between; }
    .card-title { font-weight: 700; font-size: 12px; line-height: 1.35; overflow-wrap: anywhere; }
    .status { flex: 0 0 auto; border-radius: 999px; padding: 2px 6px; font-size: 9px; background: var(--panel); color: var(--muted); }
    .meta { margin-top: 6px; display: grid; gap: 2px; font-size: 10px; color: var(--muted); overflow-wrap: anywhere; }
    .message { margin-top: 6px; font-size: 10px; line-height: 1.4; color: var(--text); opacity: .88; overflow-wrap: anywhere; }
    .progress-row { margin-top: 8px; display: flex; align-items: center; gap: 8px; }
    .track { height: 5px; border-radius: 999px; background: color-mix(in srgb, var(--muted) 25%, transparent); overflow: hidden; flex: 1; }
    .bar { height: 100%; background: var(--accent); border-radius: inherit; }
    .pct { width: 30px; text-align: right; font-size: 9px; color: var(--muted); }
    .error { margin-top: 10px; padding: 8px 10px; border: 1px solid color-mix(in srgb, var(--bad) 50%, var(--border)); border-radius: 8px; font-size: 11px; color: var(--bad); display: none; }
    @media (max-width: 760px) { .grid { grid-template-columns: repeat(4, 230px); } }
  </style>
</head>
<body>
  <main class="shell">
    <div class="topbar">
      <div>
        <h1 class="title">AgentDock Task Board 2.0</h1>
        <div class="subtitle">真实 AgentDock Task · ChatGPT 内嵌只读视图</div>
      </div>
      <div class="live"><span class="dot"></span><span id="seq">等待数据</span></div>
    </div>
    <div class="controls">
      <select id="filter" aria-label="任务筛选">
        <option value="all">全部任务</option>
        <option value="active">仅进行中</option>
        <option value="blocked">仅阻塞 / 暂停</option>
        <option value="queued">仅待执行</option>
        <option value="done">仅已结束</option>
      </select>
      <button id="refresh" type="button">刷新</button>
      <div class="count" id="count">0 tasks</div>
    </div>
    <section class="grid" id="board"></section>
    <div class="error" id="error"></div>
  </main>
  <script>
    const columns = [
      ["active", "进行中"],
      ["blocked", "阻塞 / 暂停"],
      ["queued", "待执行"],
      ["done", "已结束"],
    ];
    let snapshot = { last_sequence: 0, tasks: [] };
    let refreshing = false;

    function asPayload(value) {
      if (!value) return null;
      if (value.structuredContent) return value.structuredContent;
      if (value.toolOutput) return asPayload(value.toolOutput);
      if (value.output) return asPayload(value.output);
      return value;
    }

    function bucket(status) {
      const s = String(status || "queued").toLowerCase();
      if (["completed", "cancelled"].includes(s)) return "done";
      if (["blocked", "paused", "failed"].includes(s)) return "blocked";
      if (["running", "resumed", "retrying"].includes(s)) return "active";
      return "queued";
    }

    function el(tag, className, text) {
      const node = document.createElement(tag);
      if (className) node.className = className;
      if (text !== undefined && text !== null) node.textContent = String(text);
      return node;
    }

    function taskCard(task) {
      const card = el("article", "card");
      const top = el("div", "card-top");
      top.append(el("div", "card-title", task.title || task.task_id || "未命名任务"));
      top.append(el("span", "status", task.status || "queued"));
      card.append(top);

      const meta = el("div", "meta");
      meta.append(el("div", "", `ID: ${task.task_id || "—"}`));
      meta.append(el("div", "", `负责人: ${task.owner || "—"}`));
      if (task.updated_at) meta.append(el("div", "", `更新: ${task.updated_at}`));
      card.append(meta);

      if (task.message) card.append(el("div", "message", task.message));

      const value = Math.max(0, Math.min(100, Number(task.progress || 0)));
      const row = el("div", "progress-row");
      const track = el("div", "track");
      const bar = el("div", "bar");
      bar.style.width = `${value}%`;
      track.append(bar);
      row.append(track, el("div", "pct", `${Math.round(value)}%`));
      card.append(row);
      return card;
    }

    function render(value) {
      const payload = asPayload(value);
      if (!payload || !Array.isArray(payload.tasks)) return;
      snapshot = payload;
      const filter = document.getElementById("filter").value;
      const all = payload.tasks || [];
      const visible = filter === "all" ? all : all.filter((task) => bucket(task.status) === filter);
      document.getElementById("seq").textContent = `实时 seq ${payload.last_sequence || 0}`;
      document.getElementById("count").textContent = `${visible.length} tasks`;

      const board = document.getElementById("board");
      board.replaceChildren();
      for (const [key, title] of columns) {
        const col = el("section", "column");
        const head = el("div", "column-head");
        const tasks = visible.filter((task) => bucket(task.status) === key);
        head.append(el("span", "", title), el("span", "badge", tasks.length));
        const cards = el("div", "cards");
        if (!tasks.length) cards.append(el("div", "empty", "暂无任务"));
        else tasks.forEach((task) => cards.append(taskCard(task)));
        col.append(head, cards);
        board.append(col);
      }
      document.getElementById("error").style.display = "none";
    }

    function showError(message) {
      const node = document.getElementById("error");
      node.textContent = message;
      node.style.display = "block";
    }

    async function refresh() {
      if (refreshing || document.hidden) return;
      if (!window.openai || typeof window.openai.callTool !== "function") return;
      refreshing = true;
      document.getElementById("refresh").disabled = true;
      try {
        const result = await window.openai.callTool("taskboard_snapshot", { limit: 200 });
        render(result);
      } catch (error) {
        showError(`刷新失败: ${error?.message || error}`);
      } finally {
        refreshing = false;
        document.getElementById("refresh").disabled = false;
      }
    }

    document.getElementById("filter").addEventListener("change", () => render(snapshot));
    document.getElementById("refresh").addEventListener("click", refresh);

    if (window.openai?.toolOutput) render(window.openai.toolOutput);
    window.addEventListener("openai:set_globals", (event) => {
      const output = event?.detail?.globals?.toolOutput;
      if (output) render(output);
    });
    window.addEventListener("message", (event) => {
      const message = event.data;
      if (message?.method === "ui/notifications/tool-result") {
        render(message.params?.structuredContent || message.params);
      }
    });

    setInterval(refresh, 5000);
  </script>
</body>
</html>
'''
