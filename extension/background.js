// Sends what you're looking at to the omarchy-working-memory inbox, via
// Chromium's native messaging: the browser starts the app's native host
// (registered by install.sh as com.omarchy.working_memory), which hands the
// capture to the running app, or writes it to the inbox itself if the app
// isn't open. See src/capture.h.
//
// Three ways in: the right-click menu (on a selection, a link, or the
// page), the toolbar button, and Alt+Shift+W. The toolbar badge shows ✓ or
// ! for a few seconds, with the reason in its tooltip.

const HOST = "com.omarchy.working_memory";

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: "selection", title: "Send selection to Working Memory inbox", contexts: ["selection"] });
    chrome.contextMenus.create({ id: "link", title: "Send link to Working Memory inbox", contexts: ["link"] });
    chrome.contextMenus.create({ id: "page", title: "Send page to Working Memory inbox", contexts: ["page"] });
  });
});

// The selection with its line breaks intact (the context menu's own
// selectionText flattens them). Fails on pages scripts can't run on, like
// chrome:// ones; the caller falls back.
async function selectionIn(tab) {
  try {
    const [r] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => window.getSelection().toString(),
    });
    return (r && r.result) || "";
  } catch (e) {
    return "";
  }
}

function badge(tab, ok, message) {
  chrome.action.setBadgeBackgroundColor({ color: ok ? "#2e7d32" : "#c0392b", tabId: tab.id });
  chrome.action.setBadgeText({ text: ok ? "✓" : "!", tabId: tab.id });
  chrome.action.setTitle({ title: "Working Memory: " + message, tabId: tab.id });
  setTimeout(() => chrome.action.setBadgeText({ text: "", tabId: tab.id }), 3000);
}

function send(tab, capture) {
  chrome.runtime.sendNativeMessage(HOST, { cmd: "capture", ...capture }, (reply) => {
    if (chrome.runtime.lastError) {
      badge(tab, false, chrome.runtime.lastError.message + " (has install.sh been run?)");
    } else if (!reply || !reply.ok) {
      badge(tab, false, (reply && reply.error) || "no reply from the app");
    } else {
      badge(tab, true, "in the inbox (" + reply.inbox + " waiting)");
    }
  });
}

// Toolbar button and keyboard shortcut: the selection if there is one,
// else just the page.
async function captureTab(tab) {
  send(tab, { text: await selectionIn(tab), title: tab.title, url: tab.url });
}

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === "selection") {
    const text = (await selectionIn(tab)) || info.selectionText || "";
    send(tab, { text, title: tab.title, url: tab.url });
  } else if (info.menuItemId === "link") {
    // The link's own address; the page it was on goes in as the title, so
    // the capture still says where it was found.
    send(tab, { text: info.selectionText || "", title: "Link on: " + tab.title, url: info.linkUrl });
  } else {
    send(tab, { text: "", title: tab.title, url: tab.url });
  }
});

chrome.action.onClicked.addListener(captureTab);

chrome.commands.onCommand.addListener(async (command, tab) => {
  if (command !== "capture") return;
  if (!tab) [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab) captureTab(tab);
});
