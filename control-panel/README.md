# Easy AIOStreams Control Panel (beta)

A private web dashboard for the Easy AIOStreams stack. How to install and use it: [Basic guide](../docs/basic/control-panel.md) · [Advanced guide](../docs/advanced/control-panel.md).

This folder is installed to `/opt/aiostreams/control-panel` and built from there by `setup-ui.sh`.

## Try it without a server

```bash
pip install -r requirements.txt
UI_DEMO=1 UI_STATE_DIR=/tmp/aios-state uvicorn app.main:app --port 8099
```

Open `http://localhost:8099` and sign in as `demo` / `demo`. The demo terminal key is `demo-terminal-key` and opens a harmless local shell. Add `UI_DEMO_SCENARIO=down` or `paused` to see those states.

## Tests

```bash
UI_DEMO=1 pytest tests/test_app.py tests/test_terminal.py
pytest tests/test_stack.py
```
