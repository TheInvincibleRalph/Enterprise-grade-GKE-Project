#!/usr/bin/env python3
"""Reliable client for the inference API.

Submits a prompt to /infer, then polls /result/<id> until the answer exists.
It tolerates transient 5xx responses (the API answers 503 while Redis is
briefly unavailable, or while the model is cold-starting) and gives up only
after a generous deadline, printing how to fetch the result later.

Usage:
    ai-query.py "your prompt"
    ai-query.py --url https://ai.invincibledevops.tech "your prompt"
"""
import argparse
import json
import time
import urllib.error
import urllib.request

POLL_S = 5
DEADLINE_S = 600
STATUS_EVERY_S = 15
# Cloudflare blocks the default urllib user agent ("Python-urllib/3.x"),
# so every request carries an explicit one.
UA = "devops-portfolio/1.0"
HEADERS = {"Content-Type": "application/json", "User-Agent": UA}


def api_url(base, path):
    return base.rstrip("/") + path


def main():
    parser = argparse.ArgumentParser(
        description="Submit a prompt to the inference API and wait for the answer.")
    parser.add_argument("--url", default="http://inference-api:8080",
                        help="API base URL (default: the in-cluster service)")
    parser.add_argument("prompt", nargs="+", help="the prompt to submit")
    args = parser.parse_args()
    prompt = " ".join(args.prompt)
    base = args.url

    req = urllib.request.Request(
        api_url(base, "/infer"),
        data=json.dumps({"prompt": prompt}).encode(),
        headers=HEADERS,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            task_id = json.loads(resp.read())["task_id"]
    except urllib.error.HTTPError as e:
        print(f"submit failed: HTTP {e.code}, try again")
        raise SystemExit(1)

    print(f"submitted: {prompt}")
    print(f"task_id: {task_id}")

    start = time.time()
    last_status = 0
    while time.time() - start < DEADLINE_S:
        try:
            req = urllib.request.Request(api_url(base, "/result/" + task_id), headers=HEADERS)
            with urllib.request.urlopen(req, timeout=30) as resp:
                res = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            if e.code < 500:
                raise
            print(f"transient HTTP {e.code}, retrying...")
            time.sleep(POLL_S)
            continue
        except urllib.error.URLError as e:
            print(f"connection error: {e.reason}, retrying...")
            time.sleep(POLL_S)
            continue

        if "response" in res:
            elapsed = int(time.time() - start)
            print(f"answer after {elapsed}s:")
            print(res["response"])
            return

        now = int(time.time() - start)
        if now - last_status >= STATUS_EVERY_S:
            print(f"job in flight, waiting... ({now}s)")
            last_status = now
        time.sleep(POLL_S)

    elapsed = int(time.time() - start)
    print(f"no answer within {elapsed}s.")
    print(f"check later with: curl {api_url(base, '/result/' + task_id)}")


if __name__ == "__main__":
    main()
