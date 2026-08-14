# Python Scripts

When writing throwaway or one-off Python scripts, always use `uv` with a local venv. Never install packages globally with `pip install --break-system-packages`.

```bash
# Create a temporary venv, install deps, run the script
uv venv /tmp/throwaway-venv
source /tmp/throwaway-venv/bin/activate
uv pip install <packages>
python3 script.py
deactivate
rm -rf /tmp/throwaway-venv
```

Or for a single inline script:

```bash
uv run --with google-auth --with requests python3 -c "..."
```
