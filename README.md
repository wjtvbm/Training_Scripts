# Training_Scripts
## 簡介
這邊是放教育訓練時會用到的 script，通常是 bash, batch, PowerShell 跟 Python

### check_disabled_and_expired_rule.sh 
這是一個用 bash 寫的 Script, 主要功能是連線到 SMS 後，取得所有的 time objects 並找出他們的 End time，再把所有 rule 中有用到 time object 都找出來，看那些是已經到期跟快要到期的 rules，順便把 disable 的 rules 也列出來。

![check_disabled_and_expired_rule.sh](/ima/check_disabled_and_expired_rule.sh-1.png "Sample Report")
