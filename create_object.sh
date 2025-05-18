# ==============================================================================
#  Example of using mgmt_cli to create objects
#  Author: Visual Wu
#  Date: 2025‑05‑02
# ==============================================================================
#!/usr/bin/env bash
set -euo pipefail

# mgmt_cli 路徑 (若 mgmt_cli 不在 PATH 需填完整路徑)
MGMT_CLI="mgmt_cli"

read -rp "請輸入 SMS IP [127.0.0.1]: " MGMT_SERVER
MGMT_SERVER=${MGMT_SERVER:-127.0.0.1}
read -rp "請輸入管理帳號 [admin]: " MGMT_USER
MGMT_USER=${MGMT_USER:-admin}
read -rsp "請輸入管理密碼: " MGMT_PASS
echo

API_PORT=443

# ====== Login, 取 SID ======
echo -n "登入到 $MGMT_SERVER, 請稍候..."
SID=$(
  $MGMT_CLI login \
    --user       "$MGMT_USER" \
    --password   "$MGMT_PASS" \
    --management "$MGMT_SERVER" \
    --port       $API_PORT \
    --format     json \
  | jq -r '.sid'
)
if [[ -z "$SID" || "$SID" == "null" ]]; then
  echo "ERROR: 無法取得 SID, 請檢查伺服器位址，帳號或密碼。"
  exit 1
fi
echo
echo "取得 SID = $SID"

# ====== Helper 函式：以免執行 mgmt_cli 遇到錯誤退出 ======
run_cli() {
  set +e
  out=$("$MGMT_CLI" "$@" 2>&1)
  code=$?
  json=$(printf '%s\n' "$out" | sed -n '/^{/,$p')
  echo "$json" | jq .
  set -e
  if [[ $code -ne 0 ]]; then
    echo "!!!請檢查!!! 這個命令以 exit code $code 結束。"
  fi
}

# ====== 互動選單 ======
print_menu() {
  echo
  echo "請選擇操作："
  echo " 1) 新增 Network 物件"
  echo " 2) 新增 Host 物件"
  echo " 3) 新增 Service-TCP"
  echo " 4) 新增 Service-UDP"
  echo " 5) Publish 變更"
  echo " 6) Exit (登出並離開)"
  echo
}

# ====== 互動主迴圈 ======
while true; do
  print_menu
  read -rp "請輸入編號 [1-6]: " choice
  case $choice in

    1)  # 新增 Network
      read -rp "輸入物件名稱: " NAME
      read -rp "輸入網段 (e.g. 10.0.1.0/24): " NET
      IFS=/ read SUBNET MASK <<<"$NET"
      echo ">>> 建立 Network '$NAME' => $SUBNET/$MASK"
      run_cli add network \
        name        "$NAME" \
        subnet      "$SUBNET" \
        mask-length "$MASK" \
        --session-id "$SID" \
        --format     json
      ;;

    2)  # 新增 Host
      read -rp "輸入物件名稱: " NAME
      read -rp "輸入主機 IP (e.g. 10.0.1.100): " IP
      echo ">>> 建立 Host '$NAME' => $IP"
      run_cli add host \
        name        "$NAME" \
        ip-address  "$IP" \
        --session-id "$SID" \
        --format     json
      ;;

    3)  # 新增 Service-TCP
      read -rp "輸入服務名稱: " NAME
      read -rp "輸入 TCP 連接埠 (e.g. 8080): " PORT
      echo ">>> 建立 Service-TCP '$NAME' => TCP/$PORT"
      run_cli add service-tcp \
        name        "$NAME" \
        port        "$PORT" \
        --session-id "$SID" \
        --format     json
      ;;

    4)  # 新增 Service-UDP
      read -rp "輸入服務名稱: " NAME
      read -rp "輸入 UDP 連接埠 (e.g. 8181): " PORT
      echo ">>> 建立 Service-UDP '$NAME' => UDP/$PORT"
      run_cli add service-udp \
        name        "$NAME" \
        port        "$PORT" \
        --session-id "$SID" \
        --format     json
      ;;

    5)  # Publish 變更
      echo ">>> 發佈變更..."
      run_cli publish \
        --session-id "$SID" \
        --format     json
      ;;

    6)  # Exit 前先檢查未發佈變更
      echo ">>> 檢查未發佈的變更…"
      # 抓 raw（包含 banner + JSON）
      raw=$($MGMT_CLI show-changes \
        --session-id "$SID" \
        --format     json 2>&1)
      # 只留下從第一個 { 開始的 JSON
      json=$(echo "$raw" | sed -n '/^{/,$p')
      # 計算所有頂層陣列的長度總和（若都沒有 array，結果為 0）
      PENDING=$(echo "$json" \
        | jq -r '[ .[] | select(type=="array") | length ] | add // 0')

      if (( PENDING > 0 )); then
        echo "目前有 $PENDING 筆變更尚未發佈。"
        read -rp "是否要現在發佈？ [y/N]: " yn
        if [[ "$yn" =~ ^[Yy] ]]; then
          echo ">>> 發佈變更…"
          run_cli publish \
            --session-id "$SID" \
            --format     json
        else
          echo "跳過發佈，登出。"
        fi
      else
        echo "無未發佈變更，登出。"
      fi

      echo ">>> 登出中..."
      run_cli logout \
        --session-id "$SID" \
        --format     json
      break
      ;;


    *)  echo "無效選項，請輸入 1–6。" ;;
  esac
done

echo "Bye!"
