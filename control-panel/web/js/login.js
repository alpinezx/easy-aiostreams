import "./debugsize.js";
import "./viewport.js";
const f = document.getElementById("f");
const err = document.getElementById("err");
const go = document.getElementById("go");
const eye = document.getElementById("pw-eye");

// Show or hide what's typed in the password box
eye.addEventListener("click", () => {
  const show = f.elements.password.type === "password";
  f.elements.password.type = show ? "text" : "password";
  eye.setAttribute("aria-pressed", String(show));
  eye.setAttribute("aria-label", show ? "Hide password" : "Show password");
});

f.addEventListener("submit", async (e) => {
  e.preventDefault();
  err.textContent = "";
  go.disabled = true;
  const data = new FormData(f);
  try {
    const res = await fetch("/api/login", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-UI-Request": "1" },
      body: JSON.stringify({ username: data.get("username"), password: data.get("password") }),
    });
    if (res.ok) { location.href = "/"; return; }
    let msg = "Couldn't sign in. Try again.";
    try { msg = (await res.json()).detail || msg; } catch (_) {}
    err.textContent = msg;
  } catch (_) {
    err.textContent = "Can't reach the server.";
  }
  go.disabled = false;
  f.elements.password.select();
});
