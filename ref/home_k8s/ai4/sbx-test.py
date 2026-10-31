import os, json, urllib.request, sys
k = os.environ.get("AIGW_API_KEY", "")
print("key seen inside sandbox:", (k[:10] + "...") if k else "none", "(placeholder, not the real f5vk_ key)" if k and not k.startswith("f5vk_") else "")
def call(url, data=None, hdr=None):
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, data=data, headers=hdr or {}), timeout=120)
        return r.status, r.read().decode(errors="replace")
    except Exception as e:
        return "ERR", str(e)[:160]
body = json.dumps({"model": "qwen2.5-0.5b", "messages": [{"role": "user", "content": "Say hello"}], "max_tokens": 8}).encode()
s, b = call("http://10.10.12.33/v1/chat/completions", body, {"Authorization": "Bearer " + k, "Content-Type": "application/json"})
print("ALLOWED  AI Gateway ->", s, json.loads(b)["choices"][0]["message"]["content"] if s == 200 else b)
print("DENIED?  github.com  ->", *call("https://github.com"))
print("DENIED?  R5 telnet   ->", *call("http://10.10.12.20/"))
