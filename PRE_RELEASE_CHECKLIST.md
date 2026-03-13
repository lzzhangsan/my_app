# 正式发布前检查清单

## 构建命令

- **推荐**：`flutter build apk --release` — 构建正式发布版 APK
- **可选**：`flutter build apk --release --split-per-abi` — 按 ABI 拆分，APK 体积更小
- **上架 Google Play**：`flutter build appbundle` — 生成 AAB 格式

---

## 已完成的优化

| 项目 | 状态 |
|------|------|
| 敏感文件 (.gitignore) | ✅ key.properties、*.keystore、.continue/ 已排除 |
| API Key 存储 | ✅ Telegram Bot Token 存 SharedPreferences，用户自行配置 |
| SQL 注入防护 | ✅ 使用参数化查询 |
| Zip 路径遍历 | ✅ resolveSafeExtractPath 防护 |
| 明文 HTTP | ✅ usesCleartextTraffic 未启用 |
| Release 签名 | ✅ 使用 debug 签名，保证与旧版覆盖安装时签名一致、数据保留 |

---

## 发布前必做

1. **确认使用 debug 签名**：当前 release 使用 debug 签名，便于与旧版覆盖安装、保留数据。若将来需要上架商店，再配置正式 keystore。

2. **（可选）确认 key.properties 未被 git 跟踪**：
   ```bash
   git status android/key.properties
   ```
   应显示为未跟踪或忽略。

---

## 已知风险与可选优化

| 项目 | 说明 | 建议 |
|------|------|------|
| SSL 证书 bypass | `browser_page.dart` 中 `onReceivedServerTrustAuthRequest` 返回 PROCEED，会跳过证书校验 | 若需更高安全性，可改为 DENY 或实现白名单 |
| 混淆/压缩 | minifyEnabled、shrinkResources 均为 false | 可启用以减小包体积，需测试 ProGuard 规则 |
| CI keystore 密码 | `.github/workflows/flutter_build.yml` 中临时 keystore 使用简单密码 | 仅用于 CI，生产签名应使用本地 key.properties |

---

## 构建步骤

```bash
# 1. 清理
flutter clean

# 2. 获取依赖
flutter pub get

# 3. 构建正式版 APK
flutter build apk --release
```

产物位置：`build/app/outputs/flutter-apk/app-release.apk`
