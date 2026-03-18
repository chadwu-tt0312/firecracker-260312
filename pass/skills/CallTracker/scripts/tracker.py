import argparse
import datetime
import json
import os
from pathlib import Path


# 負責接收 CLI 參數並將結果寫入持久化檔案。
def record_call():
    parser = argparse.ArgumentParser(description="OpenClaw Call Tracker Skill")
    parser.add_argument("task", help="任務名稱")
    parser.add_argument("--agent", default="Default_Agent", help="代理 ID")
    parser.add_argument("--remarks", default="", help="備註訊息")
    parser.add_argument("--status", default="INFO", help="狀態等級")

    args = parser.parse_args()

    # 設定日誌路徑 (可透過環境變數 LOG_PATH 覆蓋)
    log_dir = Path(os.environ.get("LOG_PATH", "./logs"))
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "audit_trails.jsonl"

    timestamp = datetime.datetime.now().isoformat()

    log_entry = {
        "timestamp": timestamp,
        "agent": args.agent,
        "task": args.task,
        "remarks": args.remarks,
        "status": args.status,
    }

    try:
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(json.dumps(log_entry, ensure_ascii=False) + "\n")

        # 標準輸出供 Agent 讀取回傳值
        print(f"✅ [SUCCESS] 紀錄已儲存。任務：{args.task}，時間：{timestamp}")
    except Exception as e:
        print(f"❌ [ERROR] 寫入失敗：{str(e)}")


if __name__ == "__main__":
    record_call()
