# 安全说明

## 重要：若曾将 GitHub Token 提交到仓库

若 `delete_old_workflows.py` 曾包含硬编码的 GitHub Token 并已推送到远程仓库，请**立即**执行：

1. 登录 GitHub → Settings → Developer settings → Personal access tokens
2. 撤销（Revoke）已泄露的 Token
3. 新建 Token 后，通过环境变量使用：`export GITHUB_TOKEN=ghp_xxx`

## 安全措施

- **ZIP 解压**：导入时校验路径，防止 Zip Slip 路径遍历
- **敏感配置**：Token 等使用环境变量，不写入代码
- **错误处理**：全局 `runZonedGuarded` 捕获未处理异常
