# GitHub Actions APK 构建指南

## 概述

本项目已配置GitHub Actions自动构建APK，解决了本地Android Studio Gradle同步问题。通过云端构建，您可以获得稳定可用的APK文件。

## 可用的工作流

### 1. Build Stable APK (推荐)
- **文件**: `.github/workflows/build_stable_apk.yml`
- **用途**: 专门优化的稳定APK构建流程
- **特点**: 使用Gradle 8.6 + Android Gradle Plugin 8.4.0，经过优化配置

### 2. Build Debug APK
- **文件**: `.github/workflows/build_debug_apk.yml`
- **用途**: 调试版本APK构建
- **特点**: 包含详细的构建日志和错误处理

### 3. Flutter Build
- **文件**: `.github/workflows/flutter_build.yml`
- **用途**: 完整的Flutter构建流程，包含备用方案
- **特点**: 多重构建策略，适合复杂项目

## 如何触发构建

### 自动触发
- 推送代码到 `main` 或 `master` 分支
- 创建Pull Request到 `main` 或 `master` 分支

### 手动触发
1. 访问GitHub仓库页面
2. 点击 "Actions" 标签
3. 选择要运行的工作流（推荐选择 "Build Stable APK"）
4. 点击 "Run workflow" 按钮
5. 确认运行

## 下载APK

1. 构建完成后，访问GitHub仓库的 "Actions" 页面
2. 点击最新的成功构建记录
3. 在页面底部的 "Artifacts" 部分找到APK文件
4. 点击下载（通常名为 `my-app-debug-apk`）
5. 解压下载的zip文件，获得APK

## 构建环境配置

### 软件版本
- **Flutter**: 3.24.0 (stable)
- **Java**: 17 (Zulu distribution)
- **Gradle**: 8.6
- **Android Gradle Plugin**: 8.4.0
- **运行环境**: Ubuntu Latest

### 优化配置
- JVM内存: 4GB
- 禁用Gradle守护进程以提高稳定性
- 启用构建缓存加速后续构建
- 30分钟构建超时保护

## 故障排除

### 构建失败
1. 检查Actions页面的构建日志
2. 查看具体的错误信息
3. 常见问题:
   - 依赖冲突: 检查pubspec.yaml
   - 内存不足: 已优化JVM配置
   - 网络问题: Actions会自动重试

### APK无法安装
1. 确保手机允许安装未知来源应用
2. 检查APK文件完整性
3. 尝试重新下载APK

## 本地开发建议

虽然GitHub Actions解决了APK构建问题，但本地开发仍然重要：

1. **代码编辑**: 继续使用Android Studio或VS Code
2. **快速测试**: 使用Flutter热重载功能
3. **调试**: 使用Flutter Inspector和调试工具
4. **最终构建**: 使用GitHub Actions生成发布版APK

## 成本和限制

- GitHub Actions对公共仓库免费
- 私有仓库有月度免费额度
- 每次构建大约消耗10-15分钟
- APK文件保留30天

## 下一步优化

1. **发布版本**: 配置release APK构建
2. **自动签名**: 添加APK签名配置
3. **多平台**: 支持iOS构建
4. **自动发布**: 集成到应用商店发布流程

---

**注意**: 这种方案完美解决了本地Gradle同步问题，让您专注于应用开发而不是环境配置。