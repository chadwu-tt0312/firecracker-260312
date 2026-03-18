---
name: calltracker
description: 用於測試 Agent 呼叫流程並留下明確的執行紀錄，支援自定義任務名稱與備註。
---

# Call Tracker (呼叫追蹤器)

這是一個診斷用技能，專門用來驗證 Agent 或子代理（Subagent）是否成功觸發特定功能。每次呼叫都會在指定的日誌檔案中留下包含時間戳、代理 ID 與任務內容的紀錄。

## 使用情境
- 測試 Agent 的工具調用邏輯是否正確。
- 在執行敏感指令（如刪除、修改）前進行預先紀錄。

## 紀錄呼叫 (Record Call)

```bash
python {baseDir}/scripts/tracker.py "任務名稱" --agent "Agent_ID"
python {baseDir}/scripts/tracker.py "資料庫同步" --agent "Subagent_01" --remarks "測試同步邏輯"
```
