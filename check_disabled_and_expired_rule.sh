# ==============================================================================
#  MAIL Disabled / Expired / Expiring‑Soon Rules in R82 Management via Web API
#  Author: Visual Wu
#  Date: 2025‑05‑20
# ==============================================================================

#!/usr/bin/env bash
set -euo pipefail
#set -x

# ====== 以下是設定 ======
# ====== SMTP 設定 ======
SMTP_SERVER="smtp.domain.com"
SMTP_PORT=587
SMTP_USER="THIS_IS_USERNAME_FOR_SMTP"
SMTP_PASS="THIS_IS_PASSWORD_FOR_SMTP"
MAIL_FROM="CP-REPORT-DO-NOT-REPLY@domain.com"
MAIL_TO="user1@domain.com;user2@domain.com" # 多人用 ; 或 , 分隔
# ====== SMS 資料 ======
MGMT_SERVER="127.0.0.1"
MGMT_USER="admin"
MGMT_PASS="Hi,CheckPoint"
# ====== 定義幾天算是 "soon" ======
DAYS=30
# ====== 寄信後要不要刪除 report (1 = 刪除, 0 = 保留) ======
DELETE_AFTER_MAIL=1
# ====== 以上是設定 ======

NOW=$(date +%s)
IN_X_DAYS=$(date --date="$DAYS days" +%s)

if [[ "$(id -u)" -eq 0 && ( "$MGMT_SERVER" == "127.0.0.1" || "$MGMT_SERVER" == "localhost" ) ]]; then
  mgmt_cli login -r true --format json > session.json
else
  mgmt_cli login -r true -m "$MGMT_SERVER" -u "$MGMT_USER" -p "$MGMT_PASS" \
    --format json > session.json
fi

# ====== 抓所有 time object 的結束時間 ======
declare -A TIME_ENDS
RESP=$(mgmt_cli show-objects type time --format json --session-file session.json)
for TUID in $(echo "$RESP" | jq -r '.objects[].uid'); do
  DETAIL=$(mgmt_cli show-time uid "$TUID" details-level full \
             --format json --session-file session.json)
  ISO=$(echo "$DETAIL" | jq -r '.end["iso-8601"] // empty')
  if [[ -n "$ISO" ]]; then
    TS=$(date --date="$ISO" +%s)
  else
    POS=$(echo "$DETAIL" | jq -r '.end.posix // empty')
    (( POS )) && TS=$(( POS/1000 )) || continue
  fi
  TIME_ENDS["$TUID"]=$TS
done

# ====== 抓所有 Packages & Layers ======
mgmt_cli show-packages --format json --session-file session.json > packages.json
mapfile -t PACKAGES < <(jq -r '.packages[].name' packages.json)

# ====== 報表 ======
TS=$(date +'%Y%m%d_%H%M%S')
OUTDIR="./CheckRules_HTML_$TS"; mkdir -p "$OUTDIR"
HTML="$OUTDIR/report.html"
GEN_DATE=$(date +"%Y-%m-%d %H:%M:%S")

cat > "$HTML" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Check Point Rule Report</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 20px; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 40px; }
    th, td { border: 1px solid #ccc; padding: 8px; text-align: left; }
    th { background: #f2f2f2; }
    h2 { margin-top: 40px; }
  </style>
</head>
<body>
  <h1>Check Point Rule Report</h1>
  <p>Generated: $GEN_DATE</p>
EOF

# ====== render_table ======
function render_table {
  local title=$1; shift
  local lines=("$@")
  echo "  <h2>$title</h2>" >> "$HTML"
  if (( ${#lines[@]} == 1 )); then
    echo "  <p><em>No rules in this category.</em></p>" >> "$HTML"
    return
  fi
  echo "  <table>" >> "$HTML"
  IFS=',' read -ra HEAD <<< "${lines[0]}"
  echo "    <tr>" >> "$HTML"
  for cell in "${HEAD[@]}"; do echo "      <th>${cell}</th>" >> "$HTML"; done
  echo "    </tr>" >> "$HTML"
  for ((i=1; i<${#lines[@]}; i++)); do
    IFS=',' read -ra COLS <<< "${lines[i]}"
    echo "    <tr>" >> "$HTML"
    for cell in "${COLS[@]}"; do echo "      <td>${cell}</td>" >> "$HTML"; done
    echo "    </tr>" >> "$HTML"
  done
  echo "  </table>" >> "$HTML"
}

# ====== 抓取並分類所有 Rules ======
declare -a DISABLED EXPIRED SOON
declare -A SEEN
HEADER="Package,Layer,UID,Name,Comment,Number,Action,Enabled,Source,Destination,Service,TimeObjs"
DISABLED+=("$HEADER"); EXPIRED+=("$HEADER"); SOON+=("$HEADER")

for PACKAGE in "${PACKAGES[@]}"; do
  mgmt_cli show-package name "$PACKAGE" --format json --session-file session.json \
    > "$OUTDIR/pkg_$PACKAGE.json"
  mapfile -t LAYERS < <(jq -r '.["access-layers"][] | .name' "$OUTDIR/pkg_$PACKAGE.json")
  for LAYER in "${LAYERS[@]}"; do
    LIMIT=500; OFFSET=0
    while :; do
      RESP=$(mgmt_cli show-access-rulebase \
        name "$LAYER" package "$PACKAGE" \
        limit "$LIMIT" offset "$OFFSET" \
        details-level full use-object-dictionary false \
        --format json --session-file session.json)
      CODE=$(echo "$RESP" | jq -r '.code // empty')
      (( CODE )) && break

      mapfile -t RULES < <(echo "$RESP" \
        | jq -c '.rulebase[] | recurse(.rulebase[]?) | select(.type=="access-rule")')
      for RULE in "${RULES[@]}"; do
        RULE_UID=$(echo "$RULE" | jq -r '.uid')
        key="$PACKAGE|$LAYER|$RULE_UID"
        [[ -n "${SEEN[$key]:-}" ]] && continue
        SEEN[$key]=1

        NAME=$(echo "$RULE" | jq -r '.name' | sed 's/,/;/g')
        COMMENT=$(echo "$RULE" | jq -r '.comments//""' | sed 's/,/;/g')
        NUM=$(echo "$RULE" | jq -r '."rule-number"')
        ACT=$(echo "$RULE" | jq -r 'if (.action|type)=="object" then .action.name else .action end')
        EN=$(echo "$RULE" | jq -r '.enabled')
        SRC=$(echo "$RULE" | jq -r '[.source[]?|if type=="string" then . else .name end]|unique|join(";")')
        DST=$(echo "$RULE" | jq -r '[.destination[]?|if type=="string" then . else .name end]|unique|join(";")')
        SVC=$(echo "$RULE" | jq -r '[.service[]?|if type=="string" then . else .name end]|unique|join(";")')
        TM=$(echo "$RULE" | jq -r '[.time[]?|if type=="string" then . else .name end]|unique|join(";")')

        EXP="none"; HAS_TIME=false
        for TUID in $(echo "$RULE" | jq -r '[.time[]?|if type=="string" then . else .uid end]|join(" ")'); do
          if [[ -n "${TIME_ENDS[$TUID]:-}" ]]; then
            HAS_TIME=true
            TS_END=${TIME_ENDS[$TUID]}
            (( TS_END < NOW )) && { EXP="expired"; break; }
            (( TS_END <= IN_X_DAYS )) && EXP="soon"
          fi
        done

        LINE="$PACKAGE,$LAYER,$RULE_UID,$NAME,$COMMENT,$NUM,$ACT,$EN,$SRC,$DST,$SVC,$TM"
        [[ "$EN" != "true" ]] && DISABLED+=("$LINE")
        if [[ "$HAS_TIME" == true ]]; then
          [[ "$EXP" == "expired" ]] && EXPIRED+=("$LINE")
          [[ "$EXP" == "soon"    ]] && SOON+=("$LINE")
        fi
      done

      TOTAL=$(echo "$RESP" | jq -r '.total')
      COUNT=$(echo "$RESP" | jq -r '.rulebase|length')
      OFFSET=$(( OFFSET + COUNT ))
      (( OFFSET >= TOTAL )) && break
    done
  done
done

# ====== 輸出 ======
render_table "Disabled Rules"    "${DISABLED[@]}"
render_table "Expired Rules"     "${EXPIRED[@]}"
render_table "Expiring Soon Rules" "${SOON[@]}"

cat >> "$HTML" <<EOF
</body>
</html>
EOF

# ====== 用 Python 發信 ======
python3 <<PYCODE
import smtplib
from email.mime.text import MIMEText

with open("$HTML", encoding="utf-8") as f:
    html = f.read()

raw = """$MAIL_TO"""
addrs = [a.strip() for a in raw.replace(';',',').split(',') if a.strip()]

msg = MIMEText(html, 'html', 'utf-8')
msg['Subject'] = "Check Point Rule Report $GEN_DATE"
msg['From']    = "$MAIL_FROM"
msg['To']      = ", ".join(addrs)

server = smtplib.SMTP("$SMTP_SERVER", $SMTP_PORT)
server.starttls()
server.login("$SMTP_USER", "$SMTP_PASS")
server.send_message(msg, from_addr="$MAIL_FROM", to_addrs=addrs)
server.quit()
PYCODE

# ====== logout ======
mgmt_cli logout --session-file session.json &> /dev/null
rm -rf packages.json session.json $OUTDIR/pkg_$PACKAGE.json
if (( DELETE_AFTER_MAIL )); then
        rm -rf $OUTDIR
fi
