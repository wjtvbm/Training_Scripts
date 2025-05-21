# Training_Scripts
## 簡介
這邊是放教育訓練時會用到的 script，通常是 bash, batch, PowerShell 跟 Python

### check_disabled_and_expired_rule.sh 
這是一個用 bash 寫的 Script, 主要功能是連線到 SMS 後，取得所有的 time objects 並找出他們的 End time，再把所有 rule 中有用到 time object 都找出來，看那些是已經到期跟快要到期的 rules，順便把 disable 的 rules 也列出來。

![check_disabled_and_expired_rule.sh](/img/check_disabled_and_expired_rule.sh-1.png "Sample Report")

### check_disabled_and_expired_rule.ps1
這個跟[check_disabled_and_expired_rule.sh] (https://github.com/wjtvbm/Training_Scripts/blob/main/check_disabled_and_expired_rule.sh) 有 87 分像，主要是在 Windows 用 PowerShell 執行，然後只會出 csv 報表。

### check_hit-count.ps1
這個 PowerShell 主要是把 SMS 裡面所有的 rule 的 hit counts 列出到 csv 中。

![check_hit-count.ps1](/img/check_hit-count.ps1-1.jpg "Sample csv")

### check-domain-cache.sh
這個 Bash script 是檢查 **Gateway** 中 Domain object 快取的情況 (fw ctl multik print_bl dns_reverse_cache_tbl)

![check-domain-cache.sh](/img/check-domain-cache.sh-1.png "Sample")

### create_object.sh
這個 Bash script 是透過 Web Service 用選單形式讓使用者

![create_object.sh](/img/create_object.sh-1.png "Sample")
