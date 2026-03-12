import os
import requests

# ========== 配置（敏感信息请用环境变量） ==========
# 设置环境变量 GITHUB_TOKEN 后运行，例如: export GITHUB_TOKEN=ghp_xxx
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
OWNER = os.environ.get("GITHUB_OWNER", "lzzhangsan")
REPO = os.environ.get("GITHUB_REPO", "my_app")
KEEP = 10  # 要保留的最新条数
# ======================================

if not GITHUB_TOKEN:
    print("错误：请设置环境变量 GITHUB_TOKEN 后再运行")
    exit(1)

headers = {
    "Authorization": f"token {GITHUB_TOKEN}",
    "Accept": "application/vnd.github+json"
}

def get_all_runs():
    runs = []
    page = 1
    while True:
        url = f"https://api.github.com/repos/{OWNER}/{REPO}/actions/runs?per_page=100&page={page}"
        resp = requests.get(url, headers=headers)
        if resp.status_code != 200:
            print("获取数据失败，请检查Token/仓库名/网络！")
            print(resp.text)
            break
        data = resp.json()
        runs.extend(data.get("workflow_runs", []))
        if "next" not in resp.links:
            break
        page += 1
    return runs

def delete_run(run_id):
    url = f"https://api.github.com/repos/{OWNER}/{REPO}/actions/runs/{run_id}"
    resp = requests.delete(url, headers=headers)
    return resp.status_code == 204

if __name__ == "__main__":
    print("正在获取所有 workflow 运行记录...")
    runs = get_all_runs()
    print(f"共获取到 {len(runs)} 条记录")
    runs = sorted(runs, key=lambda x: x["created_at"], reverse=True)
    old_runs = runs[KEEP:]
    print(f"将删除 {len(old_runs)} 条旧记录，只保留最新的 {KEEP} 条")
    for run in old_runs:
        print(f"正在删除 run_id={run['id']}，创建时间={run['created_at']}")
        ok = delete_run(run["id"])
        print("成功" if ok else "失败")
    print("操作完成")