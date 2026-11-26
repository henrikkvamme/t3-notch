chrome.runtime.sendMessage({ type: "status" }, (s) => {
  const on = !!s?.connected;
  document.getElementById("status").className = on ? "on" : "";
  document.getElementById("text").textContent = on ? "Connected to T3 Notch" : "T3 Notch is not running";
  document.getElementById("help").textContent = on
    ? "Tap ⌃⌥ or press ⌘P in T3 Notch to pick page elements."
    : "Open T3 Notch on this Mac. The extension connects by itself.";
});
