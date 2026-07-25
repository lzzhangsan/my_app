# 91cg1.com 站点结构实测（2026-07-25）

基于真实页面 HTML + 浏览器 DOM 测量，不是猜的。

## 1. 关键词搜索页

- URL：`https://www.91cg1.com/search/{urlencode(关键词)}/`
  - 例：`https://www.91cg1.com/search/%E6%AF%8D%E5%AD%90/`
- 主题：Mirages（Typecho）
- 结果卡片：
  - 容器：`div.post-card`，id 形如 `post-card-118954`
  - 一页约 **30** 张卡片 / 30 个 `<article>`
  - 标题：`h2.post-card-title`
  - 进详情链接：`a[href*="/archives/{数字}/"]`
- 分页：有 `page-navigator`
- 注意：首张卡片常是推广/置顶感内容（a00 会跳过第一张）
- 年龄弹窗：首次进入可能有「我年满18岁 - 进入」

## 2. 视频详情页（关键）

- URL：`https://www.91cg1.com/archives/{数字}/`
  - 例：`https://www.91cg1.com/archives/111216/`
- **首屏不是播放器**：标题下方先是大段广告 banner（实测标题到播放器之间约 23 张图、3万+ 字符广告区）
- 页面总高度（实测该帖）：约 **22865 px**
- 真正播放器位置（实测）：距页面顶部约 **13407 px**
  - 也就是：必须往下滚大约 **半页以上** 才能看到播放器
- 播放器技术：
  - 容器：`div.dplayer`（插件 `DPlayer` + `hls.min.js`）
  - 属性里带：
    - `data-video_id`
    - `data-video_title`
    - `data-config`（JSON，内含 HLS 地址）
  - 初始化后会出现真正的 `<video class="dplayer-video ...">`
  - `video.currentSrc` 常见为 `blob:https://www.91cg1.com/...`
  - 真实下载源在 `data-config.video.url`，形如：
    - `https://op.vkjyoi.cn/videos5/.../*.m3u8?auth_key=...`
  - **有前贴片广告**：`data-config` 里存在 `pre_ads`
- 静态 HTML 里常常 **没有** 现成 `<video>` 标签；要等 DPlayer 脚本跑起来才有

## 3. 为什么会出现「列表 ↔ 详情」空转

对照上述结构，错误自动化常见原因：

1. 进详情后只看首屏 / 只抓当前可见 `video` → 抓不到（或只抓到 spinner/广告图）
2. 没滚到 `div.dplayer`（约 13000px 处）就判定失败并 `goBack`
3. 用 DOM click 卡片时，站点脚本/广告可能吞掉点击，页面实际没进详情
4. 把 `spinner.svg`、banner 图当成视频地址去下

## 4. 正确智能下载应对齐的步骤（按真实结构）

1. 打开搜索页，收集有序 `.post-card a[href*="/archives/"]`（建议跳过第一张）
2. **直接 load** 详情 URL（比依赖 click 更稳）
3. 详情页：`document.querySelector('.dplayer')`，`scrollIntoView`；必要时多次 `scrollBy`，直到播放器在视口
4. 等 DPlayer 生成 `<video>`；优先取 `data-config` 里的 `.m3u8`，或等播放后的媒体地址
5. 触发下载（长按播放器 / 直链下 m3u8）
6. 回到原搜索 URL，处理下一张卡片

## 5. 实测样本摘要

| 项目 | 值 |
|------|-----|
| 搜索页卡片选择器 | `.post-card` |
| 详情播放器选择器 | `.dplayer` / `video.dplayer-video` |
| 播放器大约偏移 | ~13407px（该样本） |
| 源类型 | HLS `.m3u8`（带 auth_key） |
| 前贴片 | `pre_ads: true` |
