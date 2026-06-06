"""
switch_provider.py — One-click provider switch via queue command.

Usage:
  python switch_provider.py zhipu   # Switch to GLM
  python switch_provider.py xiaomi  # Switch back to xiaomi
  python switch_provider.py status  # Check current provider
"""
import urllib.request, json, sys

PROXY_URL = "http://127.0.0.1:4000"

def main():
    if len(sys.argv) < 2:
        print("Usage: switch_provider.py <zhipu|xiaomi|status>")
        sys.exit(1)

    action = sys.argv[1].lower()

    if action == "status":
        try:
            resp = urllib.request.urlopen(f"{PROXY_URL}/admin/status", timeout=5)
            data = json.loads(resp.read().decode())
            print(json.dumps(data, ensure_ascii=False, indent=2))
        except Exception as e:
            print(f"ERROR: {e}")
        return

    # POST /admin/provider to switch
    body = json.dumps({"provider": action}).encode("utf-8")
    req = urllib.request.Request(
        f"{PROXY_URL}/admin/provider",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    try:
        resp = urllib.request.urlopen(req, timeout=10)
        data = json.loads(resp.read().decode())
        print(json.dumps(data, ensure_ascii=False, indent=2))
        if data.get("status") == "ok":
            print(f"\nProvider switched to '{data['provider']}' successfully!")
    except urllib.error.HTTPError as e:
        print(f"ERROR {e.code}: {e.read().decode()[:200]}")
    except Exception as e:
        print(f"ERROR: {e}")

if __name__ == "__main__":
    main()
