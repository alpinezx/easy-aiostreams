const f = document.getElementById("f");
const err = document.getElementById("err");
const go = document.getElementById("go");

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
