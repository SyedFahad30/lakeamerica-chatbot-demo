/**
 * chat-widget.js
 * ------------------------------------------------------------------
 * A standalone, embeddable chat widget — the same pattern real tools
 * like Intercom, Drift, and Tidio use: one <script> tag, and this file
 * builds its own HTML/CSS and injects itself into whatever page it's
 * loaded on. No changes to the host page's existing HTML required.
 *
 * HOW TO USE:
 *   1. Host this file somewhere (or keep it next to your HTML for local testing)
 *   2. Add this line right before </body> on any page:
 *        <script src="chat-widget.js"></script>
 *   3. Reload the page — a chat bubble appears bottom-right automatically.
 *
 * PRODUCTION VERSION:
 *   This file does NOT call the Anthropic API directly. It calls YOUR
 *   backend (API Gateway -> Lambda -> lambda_function.py in this same
 *   folder), which holds the Anthropic API key server-side. The widget
 *   never sees or sends the key, and the system prompt lives in the
 *   Lambda too — so it can't be read or overridden from browser devtools.
 *
 *   After running deploy.sh, run:
 *     ./update-widget-endpoint.sh "https://your-api-id.execute-api.REGION.amazonaws.com/"
 *   to point apiEndpoint (below) at your live backend automatically.
 * ------------------------------------------------------------------
 */

(function () {
  "use strict";

  // ============================================================
  // CONFIG — this is the part you'd customize per client
  // ============================================================
  const CONFIG = {
    businessName: "Lake America Family Physicians",
    launcherIcon: "💬",
    accentColor: "#1b4b63",
    accentLight: "#eee5d3",
    goldAccent: "#d9a441",
    greeting:
      "Hi, thanks for reaching out to Lake America Family Physicians. I can help with appointments, refills, billing questions, or general info — what do you need today?",
    // Replaced automatically by update-widget-endpoint.sh after deploy.sh runs.
    // Until then this points nowhere real — the widget will show an error if you try it.
    apiEndpoint: "https://ev1ptob7n2.execute-api.us-east-1.amazonaws.com/",
  };

  // ============================================================
  // STATE
  // ============================================================
  // sessionId ties every message from this browser back to one row in
  // DynamoDB server-side, and lets the Lambda avoid emailing the front
  // desk twice for the same conversation. Persisted in sessionStorage so
  // a page refresh doesn't start a brand new "session" mid-conversation.
  let sessionId = null;
  try {
    sessionId = window.sessionStorage.getItem("cw-session-id");
  } catch (e) {
    /* sessionStorage unavailable (e.g. some privacy modes) — fall back below */
  }
  if (!sessionId) {
    sessionId =
      (window.crypto && window.crypto.randomUUID && window.crypto.randomUUID()) ||
      "sess-" + Date.now() + "-" + Math.random().toString(16).slice(2);
    try {
      window.sessionStorage.setItem("cw-session-id", sessionId);
    } catch (e) {
      /* ignore */
    }
  }

  let conversationHistory = [];
  let hasOpenedOnce = false;

  // ============================================================
  // INJECT CSS
  // ============================================================
  const style = document.createElement("style");
  style.textContent = `
    #cw-launcher {
      position: fixed; bottom: 24px; right: 24px;
      width: 58px; height: 58px; border-radius: 50%;
      background: ${CONFIG.accentColor}; color: #fff;
      display: flex; align-items: center; justify-content: center;
      font-size: 26px; cursor: pointer; border: none;
      box-shadow: 0 8px 24px rgba(0,0,0,0.25); z-index: 999999;
      font-family: Arial, sans-serif;
    }
    #cw-window {
      position: fixed; bottom: 96px; right: 24px;
      width: 340px; max-width: 90vw; height: 460px;
      background: #fff; border-radius: 14px;
      box-shadow: 0 20px 50px rgba(0,0,0,0.3);
      display: none; flex-direction: column; overflow: hidden;
      z-index: 999999; font-family: Arial, sans-serif;
      border: 1px solid #e2d9c8;
    }
    #cw-window.cw-open { display: flex; }
    #cw-header {
      background: ${CONFIG.accentColor}; color: #fff;
      padding: 14px 16px; display: flex; justify-content: space-between;
      align-items: center; font-size: 14px;
    }
    #cw-header .cw-dot {
      width: 8px; height: 8px; border-radius: 50%;
      background: ${CONFIG.goldAccent}; display: inline-block; margin-right: 8px;
    }
    #cw-close { cursor: pointer; background: none; border: none; color: #fff; font-size: 18px; }
    #cw-thread { flex: 1; overflow-y: auto; padding: 14px; display: flex; flex-direction: column; gap: 9px; background: #faf7f0; }
    .cw-msg { max-width: 82%; padding: 9px 13px; border-radius: 13px; font-size: 13px; line-height: 1.45; }
    .cw-msg.cw-bot { align-self: flex-start; background: ${CONFIG.accentLight}; color: #26313a; border-bottom-left-radius: 3px; }
    .cw-msg.cw-user { align-self: flex-end; background: ${CONFIG.accentColor}; color: #fff; border-bottom-right-radius: 3px; }
    #cw-input-row { display: flex; gap: 8px; padding: 10px; border-top: 1px solid #e2d9c8; background: #fff; }
    #cw-input { flex: 1; border: 1px solid #dcd3bf; border-radius: 18px; padding: 9px 13px; font-size: 13px; outline: none; }
    #cw-send { background: ${CONFIG.accentColor}; color: #fff; border: none; border-radius: 18px; padding: 9px 16px; font-size: 12px; cursor: pointer; }
    .cw-typing { display: flex; gap: 4px; padding: 10px 13px; }
    .cw-typing span { width: 5px; height: 5px; border-radius: 50%; background: #a39a86; display: inline-block; animation: cwBlink 1.2s infinite ease-in-out; }
    .cw-typing span:nth-child(2) { animation-delay: 0.2s; }
    .cw-typing span:nth-child(3) { animation-delay: 0.4s; }
    @keyframes cwBlink { 0%, 80%, 100% { opacity: 0.3; } 40% { opacity: 1; } }
  `;
  document.head.appendChild(style);

  // ============================================================
  // BUILD DOM
  // ============================================================
  const launcher = document.createElement("button");
  launcher.id = "cw-launcher";
  launcher.textContent = CONFIG.launcherIcon;

  const win = document.createElement("div");
  win.id = "cw-window";
  win.innerHTML = `
    <div id="cw-header">
      <div><span class="cw-dot"></span>Chat with ${CONFIG.businessName}</div>
      <button id="cw-close">✕</button>
    </div>
    <div id="cw-thread"></div>
    <div id="cw-input-row">
      <input id="cw-input" type="text" placeholder="Type a message…" />
      <button id="cw-send">Send</button>
    </div>
  `;

  document.body.appendChild(launcher);
  document.body.appendChild(win);

  // ============================================================
  // BEHAVIOR
  // ============================================================
  function addMessage(text, cls) {
    const thread = document.getElementById("cw-thread");
    const div = document.createElement("div");
    div.className = "cw-msg " + cls;
    div.textContent = text;
    thread.appendChild(div);
    thread.scrollTop = thread.scrollHeight;
  }

  function addBotMessage(text) {
    addMessage(text, "cw-bot");
    conversationHistory.push({ role: "assistant", content: text });
  }

  function showTyping() {
    const thread = document.getElementById("cw-thread");
    const div = document.createElement("div");
    div.className = "cw-msg cw-bot";
    div.id = "cw-typing-indicator";
    div.innerHTML = '<div class="cw-typing"><span></span><span></span><span></span></div>';
    thread.appendChild(div);
    thread.scrollTop = thread.scrollHeight;
  }

  function hideTyping() {
    const el = document.getElementById("cw-typing-indicator");
    if (el) el.remove();
  }

  async function sendMessage() {
    const input = document.getElementById("cw-input");
    const text = input.value.trim();
    if (!text) return;
    addMessage(text, "cw-user");
    conversationHistory.push({ role: "user", content: text });
    input.value = "";
    showTyping();

    try {
      // Note what's NOT here anymore: no model name, no system prompt, no
      // API key. Those all live server-side in lambda_function.py now —
      // this request only sends the conversation itself.
      const response = await fetch(CONFIG.apiEndpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          sessionId: sessionId,
          messages: conversationHistory,
        }),
      });

      if (!response.ok) {
        throw new Error("Backend returned " + response.status);
      }

      const data = await response.json();
      hideTyping();
      addBotMessage(data.reply || "Sorry, could you try that again?");
    } catch (err) {
      hideTyping();
      addBotMessage(
        "Sorry, something went wrong — please call us directly at (352) 432-3939."
      );
    }
  }

  function toggleChat() {
    win.classList.toggle("cw-open");
    if (win.classList.contains("cw-open") && !hasOpenedOnce) {
      hasOpenedOnce = true;
      addBotMessage(CONFIG.greeting);
    }
  }

  launcher.addEventListener("click", toggleChat);
  win.querySelector("#cw-close").addEventListener("click", toggleChat);
  win.querySelector("#cw-send").addEventListener("click", sendMessage);
  win.querySelector("#cw-input").addEventListener("keydown", function (e) {
    if (e.key === "Enter") sendMessage();
  });
})();
