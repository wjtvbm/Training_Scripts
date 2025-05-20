# ==============================================================================
#  Check domain in cache
#  Author: Visual Wu
#  Date: 2025‑05‑02
# ==============================================================================

#!/bin/bash

read -p "請輸入要檢查的網域名稱: " DOMAIN

# 查 CNAME
CNAME_TARGET=$(dig +short "$DOMAIN" CNAME | sed 's/\.$//')

if [ -n "$CNAME_TARGET" ]; then
  echo " 正解查詢結果："
  echo " - $DOMAIN 是 CNAME，實際指向 ➜ $CNAME_TARGET"
  DOMAIN_REAL=$CNAME_TARGET
else
  echo " 正解查詢結果："
  echo " - $DOMAIN 沒有 CNAME 轉向"
  DOMAIN_REAL=$DOMAIN
fi

echo ""

# 查 A record
IP_LIST=$(dig +short "$DOMAIN_REAL" | grep -Eo '^[0-9.]+$')
echo " A Record 結果："
echo "$IP_LIST"
echo ""

# 快取資料
CACHE_RAW=$(fw ctl multik print_bl dns_reverse_cache_tbl)

echo " 快取 + TTL + PTR 結果"
echo "------------------------------------------------------------"

for IP in $IP_LIST; do
    IFS='.' read -r A B C D <<< "$IP"
    HEX_IP=$(printf "%02x%02x%02x%02x" $A $B $C $D | tr '[:lower:]' '[:upper:]')
    LINE=$(echo "$CACHE_RAW" | grep -i "$HEX_IP")
    PTR_NAME=$(dig +short -x "$IP" | sed 's/\.$//')

    if [ -n "$LINE" ]; then
        TTL_REMAIN=$(echo "$LINE" | grep -oP '\d+/\d+')
        echo " $IP → 快取中，TTL：$TTL_REMAIN，PTR：$PTR_NAME"
    else
        echo " $IP → 未快取，PTR：$PTR_NAME"
    fi
done

echo "------------------------------------------------------------"
