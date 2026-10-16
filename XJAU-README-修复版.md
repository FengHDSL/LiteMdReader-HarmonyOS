<div align="center">

<img src="docs/icon.png" width="160" alt="新农助手 Logo" />

# 新农助手（XJAU-Helper）

**新农大助手 · HarmonyOS 原生应用**

一款为新疆农业大学学生打造的鸿蒙原生校园工具，集成登录、课表、成绩、考试、学业情况、校历信息、通知公告、空闲教室查询、农大新闻等常用功能于一体。注：非学校官方应用！非学校官方应用！

[![Version](https://img.shields.io/badge/version-1.4.1-blue)](https://github.com/FengHDSL/XJAU-Helper/releases/tag/v1.4.1)
[![HarmonyOS](https://img.shields.io/badge/HarmonyOS%20NEXT%20(API%2026)-orange)](https://developer.huawei.com/consumer/cn/harmonyos/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Release](https://img.shields.io/badge/download-HAP-success)](https://github.com/FengHDSL/XJAU-Helper/raw/release-assets/XJAU-Helper_v1.4.1.hap)

</div>

---

## 📦 下载安装

- **GitHub Release**：[XJAU-Helper_v1.4.1.hap](https://github.com/FengHDSL/XJAU-Helper/raw/release-assets/XJAU-Helper_v1.4.1.hap)（[Release 页](https://github.com/FengHDSL/XJAU-Helper/releases/tag/v1.4.1)）
- **GitHub**：[XJAU-Helper](https://github.com/FengHDSL/XJAU-Helper)
- **Gitee**：[XJAU-Helper](https://gitee.com/pandasoos/XJAU-Helper)
- **HAP Store资源站**：[新农助手](https://www.sydxky.cn/detail.php?id=796)
- **华为应用市场（邀测）**：[华为邀测](https://appgallery.huawei.com/link/invite-test-wap?taskId=1f7d34de07e40ed40bd5156b8d38c1bd&invitationCode=7ykq2YFTIFF)，邀测邀请码：`7ykq2YFTIFF`

---

## 应用截图

### 手机端

<table align="center">
  <tr>
    <td><img src="docs/screenshots/phone/01.jpg" width="180" /></td>
    <td><img src="docs/screenshots/phone/02.jpg" width="180" /></td>
    <td><img src="docs/screenshots/phone/03.jpg" width="180" /></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/phone/04.jpg" width="180" /></td>
    <td><img src="docs/screenshots/phone/05.jpg" width="180" /></td>
    <td><img src="docs/screenshots/phone/06.jpg" width="180" /></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/phone/07.jpg" width="180" /></td>
    <td><img src="docs/screenshots/phone/08.jpg" width="180" /></td>
    <td><img src="docs/screenshots/phone/09.jpg" width="180" /></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/phone/10.jpg" width="180" /></td>
    <td></td>
    <td></td>
  </tr>
</table>

### 平板 / 大屏（横屏）

<table align="center">
  <tr>
    <td><img src="docs/screenshots/pad/01.jpg" width="420" /></td>
    <td><img src="docs/screenshots/pad/02.jpg" width="420" /></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/pad/03.jpg" width="420" /></td>
    <td><img src="docs/screenshots/pad/04.jpg" width="420" /></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/pad/05.jpg" width="420" /></td>
    <td><img src="docs/screenshots/pad/06.jpg" width="420" /></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/pad/07.jpg" width="420" /></td>
    <td><img src="docs/screenshots/pad/08.jpg" width="420" /></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/pad/09.jpg" width="420" /></td>
    <td><img src="docs/screenshots/pad/10.jpg" width="420" /></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/pad/11.jpg" width="420" /></td>
    <td></td>
  </tr>
</table>

## 功能特性

### 核心功能

| 功能 | 说明 |
|------|------|
|  登录  | 学号密码登录（RSA PKCS#1 v1.5 加密），历史账号一键填充，服务端验证码 + 网页版登录兜底 + 忘记密码跳转学校官网 |
| 课程表 | 周视图课表，周次/学期切换；课程详情（教师、教室、节次、周次、属性着色）；支持更换背景/网格/纯色背景/表头颜色/格子高度/圆角/边框/文字等超多设置项；**左右滑动切换上一周/下一周**；支持手动调节开学时间 |
| 考试查询 | 考试时间、地点、座位号查询，最近考试倒计时，按剩余天数分级配色（红紧急 / 黄中等 / 绿充足）；支持导入系统日历 |
| 成绩查询 | 学期成绩列表与平均分 / GPA 展示（按学校「课程及学分」办法自动换算） |
| 学业情况 | GPA、学分完成度、课程分类统计、学历预警；对接教务处官网「学期校历」文章通知 |
| 日历 | 按月分块的正常日历样式，左右滑动查看月份，未开学/学期外日期灰色显示；支持手动调节开学 / 结束时间与自定义学期标题 |
| 空闲教室查询 | 数据对接教务系统空闲教室查询页面，支持按校区/楼号/场地类别/时间筛选 |
| 农大新闻 | 对接新闻网官网「农大要闻 / 综合新闻 / 教学科研 / 媒体农大」四大板块，支持站内搜索、收藏、分享、下拉刷新、滚动翻页 |
| 外部链接页 | 应用内 WebView 浏览教务处官网/教务系统/新闻网任意页面，右上角**复制链接/分享**胶囊按钮（链接自动变成网页标题） |

### 桌面卡片

| 卡片 | 尺寸 | 功能 |
|------|------|------|
| 课程预告 | 2×2 | 今日/明日课程预览，点击切换 |
| 考试倒计时 | 2×2 | 最近考试天数与详情 |

### 个性化设置

- **主题色**：支持中国红、天空蓝、农大绿三色主题
- **深色模式**：自动跟随系统深色模式开关
- **沉浸光感**：卡片/按钮/输入框/半模态的系统材质，不可用时自动降级毛玻璃
- **课表样式**：自定义网格、表头、边框、底色、格子高度、圆角、文字大小与对齐
- **课程颜色**：每门课程独立颜色，支持一键分配色
- **背景图**：支持自定义课表背景图，自动做明暗分析与对比度适配

---

## 技术栈

| 类别 | 技术 |
|------|------|
| 平台 | HarmonyOS NEXT（最低要求 API 24，即 HarmonyOS 6.1；已适配 API 26 正式版） |
| 语言 | ArkTS / ArkUI |
| 网络 | @ohos.net.http（正方教务系统 + 教务处官网）、Remote Communication Kit rcp（CAS 认证，手动跟随 302 以收集 Cookie） |
| 存储 | @ohos.data.preferences（本地缓存）+ AppStorage（跨页面状态广播） |
| UI | HDS Design Kit（沉浸式悬浮底栏）、系统颜色资源适配深色模式、Swiper 日历左右滑动 |
| 加密 | RSA PKCS#1 v1.5（教务登录）、AES-128-CBC（统一身份认证 CAS 密码） |
| 分享 | @kit.ShareKit systemShare（外部链接页分享面板） |
| 动画 | animateTo + TransitionEffect（登录页历史账号展开过渡、卡片出现消失、粒子消散） |

---

## 构建

```text
1. 安装 DevEco Studio 26.0.0 及以上版本（API 26 SDK；API ≥26 版本号用点分格式）
2. Clone 本仓库，用 DevEco Studio 打开
3. 使用华为账号 Auto-Sign 签名后连接设备或启动模拟器，点击运行
```

> 💡 仓库默认 `JwApi.USE_MOCK = true`：未登录时内置「功能浏览」模式，使用本地模拟数据体验全部界面（带全屏水印提醒，**模拟数据不包含任何真实个人信息**）。接真实数据前把 `entry/src/main/ets/api/JwApi.ets` 里的 `USE_MOCK` 置为 `false`。

---

## 项目结构

```text
XJAU-Helper/
├── AppScope/                       # 应用级配置（bundleName、图标）
├── docs/                           # README 资源（图标、截图）
├── entry/src/main/ets/
│   ├── api/                        # 数据接口层（唯一数据出口）
│   │   ├── JwApi.ets               #   正方教务全部数据接口（课表/成绩/考试/学业/空教室）
│   │   ├── CasApi.ets              #   统一身份认证 CAS 登录（原生 rcp，不依赖 WebView）
│   │   ├── SelectApi.ets           #   快捷选课/抢课（新正方 PartDisplay 流程）
│   │   ├── NewsApi.ets             #   农大新闻网解析
│   │   └── HttpClient.ets          #   轻量 HTTP 封装
│   ├── common/                     # 工具与全局状态
│   │   ├── Constants.ets           #   全局常量：入口 URL、CAS 地址、作息、色板
│   │   ├── AppState.ets            #   运行时状态（登录态、学期、路由栈）
│   │   ├── DataStore.ets           #   @ohos.data.preferences 持久化
│   │   ├── ThemeUtil.ets           #   主题色与 WCAG 对比度字色
│   │   ├── ResponsiveUtil.ets      #   手机/平板双布局判定（单一事实源）
│   │   ├── SystemMaterial.ets      #   沉浸光感材质判定
│   │   ├── GlassMaterial.ets       #   灰字（次要文字色）广播
│   │   ├── AppearanceStore.ets     #   外观设置存储与派生色
│   │   ├── RsaUtil.ets             #   教务登录 RSA 加密
│   │   ├── AesUtil.ets             #   CAS 密码 AES 加密
│   │   ├── WallpaperTone.ets       #   壁纸明暗分析
│   │   └── ...                     #   日历/节次/课表配置/日志/防窥等工具
│   ├── model/                      # 数据模型定义
│   ├── view/                       # 页面（MainView/HomeView/ScheduleView/ScoreView 等 30 个）
│   │   └── common/                 # 通用组件（MaterialCard/MaterialButton/DissolveBurst 等 13 个）
│   ├── widgets/pages/              # 桌面卡片（课程预告/考试倒计时）
│   └── pages/                      # 入口（EntryAbility 对应页 + 卡片入口）
├── config/
│   └── jw_api_config.json          # 教务接口配置中心（baseUrl + 全部 endpoints）
└── build-profile.json5             # 工程配置
```

---

## 应用架构与实现逻辑

### 数据层（api/）

- **`JwApi` 是唯一数据出口**，所有教务数据（课表、成绩、考试、学业、空教室、选课）都从这里取。接口 URL 集中在 [`config/jw_api_config.json`](config/jw_api_config.json)（baseUrl + endpoints），`JwApi` 启动时读取，便于换学校时只改配置不动代码。
- **登录三通道**（`LoginView` 分模式调度）：
  1. **教务直登**（original）：`RsaUtil` 用 `login_getPublicKey.html` 下发的公钥做 RSA PKCS#1 v1.5 加密，POST `login_slogin.html`，成功后自动重登录以拉全 Cookie；
  2. **服务大厅 CAS**（service，默认）：`CasApi` 走原生 rcp，**手动跟随 302**（`autoRedirect: false`）以便按路径收集每一跳的 Cookie（`authserver` → `rhmh` → 教务 `jziotlogin` SSO 桥接）；CAS 密码用 `AesUtil` 的 AES-128-CBC 加密（密钥取自登录页 JS 中的 `pwdDefaultEncryptSalt`）；需要验证码时抛 `CasCaptchaRequiredError`，UI 自动切到网页版；
  3. **网页版兜底**：内嵌 WebView 打开 CAS 登录页，人工登录后共享 Cookie。
- **登录态维持**：冷启动以 `CASTGC` Cookie 存在为第一信号，静默重放 SSO 桥接 URL 刷新教务会话，再全量刷新数据；竞态用 `AppState.sessionReady` 保护（页面等待登录完成再拉数据）。
- **学期码**：正方 `xqm` 参数规则固定（1→3、2→12、3→16），由 `JwApi.xqmOf()` 统一换算。

### 状态与 UI 体系（common/）

- **跨页面状态广播**：配置类状态全部走 `AppStorage` + `@StorageProp`。注意 ArkUI 按「属性表达式」登记依赖——`@StorageProp` 的值必须**直接参与属性表达式**（如 `GlassMaterial.graySecondary(this.grayTick, 默认色)` 把订阅值当参数传入）才能实时刷新，只写恒真表达式是无效的。
- **响应式布局**：`ResponsiveUtil.isWideLayout`（宽 ≥600vp 且横向）是唯一判定源；每个页面挂双 `mediaquery` 得到 `isLandscape`，竖屏单列、横屏双列。
- **沉浸光感（系统材质）**：`MaterialCard` / `MaterialButton` / 半模态面板统一走「材质承载层」结构——`MaterialCarrier` 在内容下方兄弟层画 `systemMaterial`，材质不可用时自动降级毛玻璃。三个判定入口：`materialAvailable()`（设备支持）、`materialActive()`（受全局沉浸开关）、`MaterialCardLayer({ layerForce: true })`（强制常驻）。含 `TextInput` 的卡片必须用 Stack 兄弟结构承载材质。
- **灰字（次要文字色）广播**：`GlassMaterial` 以 `页面key|角色` 为键广播 `grayTick`，切主题/换壁纸后全页次要文字自动变色；壁纸管线在明暗分析完成后重算自动灰字色。
- **主题与对比度**：`ThemeUtil.onColor(bg)` 按 WCAG 亮度自动取黑/白字色；深色模式优先用系统资源 `$r('sys.color.font_primary')`。
- **壁纸明暗**：`WallpaperTone.analyze()` 在导入壁纸后计算平均亮度，派生对比度遮罩色；「自动灰字」基于该结果。
- **粒子消散**：`view/common/DissolveBurst.ets` 是可复用组件——`trigger` 序号自增时从卡片中心爆开一圈主题色粒子（角度均分、距离/大小/延迟带差异），620ms 飞散淡出，`hitTestBehavior(None)` 不挡交互；用于删除登录记录、清空日志等场景的过场反馈。

### 页面层（view/）

- 30 个页面文件按「视图 = 页面」组织，页面间传值走 `AppState` 静态字段（非持久数据）+ `DataStore`（持久数据）；二级页路由集中在 `Constants.ets` 的 `ROUTE_*` 常量。
- 常用页面：`HomeView`（首页聚合）、`ScheduleView`（课表）、`ScoreView`（成绩）、`ExamPage`（考试）、`AcademicPage`（学业）、`NewsPage`（新闻）、`MineView`（我的）。

### 桌面卡片（widgets/pages/）

- 卡片运行在**独立进程**，收不到主进程的 `AppStorage` 广播——卡片自读取 `DataStore` 持久化数据（课程预告/考试倒计时），数据由主进程刷新时写盘。

---

## 移植到其他学校（正方 V9）适配指南

本 App 面向正方教务 V9（`/jwglxt` 体系）学校。移植主要改「配置与常量」，逻辑层基本不用动。

### 1. 改工程标识

- `AppScope/app.json5`：改 `bundleName`（反域名格式）与应用名。

### 2. 改接口配置中心

[`config/jw_api_config.json`](config/jw_api_config.json) 集中了教务全部端点：

```json
{
  "baseUrl": "https://jwxt.xjau.edu.cn",
  "endpoints": {
    "loginPage": "/jwglxt/xtgl/login_slogin.html",
    "loginPublicKey": "/jwglxt/xtgl/login_getPublicKey.html",
    "course": "/jwglxt/kbcx/xskbcx_cxXsgrkb.html",
    "score": "/jwglxt/cjcx/cjcx_cxDgXscj.html",
    "exam": "/jwglxt/kwgl/kscx_cxXsksxxIndex.html",
    "academic": "/jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html",
    "emptyRoomPage": "/jwglxt/cdjy/cdjy_cxKxcdlb.html",
    "...": "..."
  },
  "jwcListUrl": "https://jwc.xjau.edu.cn/jxrl_3318/list.htm"
}
```

**抓包方法**：浏览器登录你学校教务 → F12 → Network 面板 → 逐个打开课表/成绩/考试页 → 把对应请求的 URL 填进 `endpoints`。正方 V9 各校端点路径通常一致，主要是换域名；若个别页面 404，在浏览器里从菜单入口实际访问一次拿到真实路径。

### 3. 改入口与认证常量

`entry/src/main/ets/common/Constants.ets`：

| 常量 | 用途 | 改法 |
|------|------|------|
| `WEB_LOGIN_URL` / `WEB_PORTAL_URL` | 网页版登录/教务首页 | 换学校教务域名 |
| `SERVICE_HALL_URL` | 服务大厅（如有） | 换学校大厅地址，没有可指向教务首页 |
| `CAS_LOGIN_URL` 相关 | 统一身份认证 | 从学校 CAS 登录页复制 `service=` 参数 |
| `JWC_LIST_URL` 等 | 教务处官网（校历/通知） | 换学校教务处栏目页 |
| `Constants.ets` 其余 | 作息时间、快捷入口 | 按学校作息调整 |

> 正方登录 RSA 公钥是**动态下发**的（`login_getPublicKey.html`），无需写死；CAS 的 AES 盐值 `pwdDefaultEncryptSalt` 从学校 `authserver` 登录页 JS 里获取，若你的学校 CAS 未开启前端加密则无需处理。

### 4. 切换真实数据

- `entry/src/main/ets/api/JwApi.ets`：`USE_MOCK` 置为 `false`。
- `NewsApi.ets`：新闻网域名与栏目 URL 按学校调整。
- 校历为预置数据（客户端解析学校 PDF 不可靠），每次校历更新需随版本更新资源文件。

### 5. 常见问题与修复

| 问题 | 原因 | 修复 |
|------|------|------|
| 登录返回空/乱码 | 学校网关对非浏览器请求做 TLS 指纹风控 | 用「网页版登录」模式（WebView 内核 100% 通过），或等待风控自动解除 |
| CAS 登录要求验证码 | 同 IP 高频登录触发 | 正常流程：`CasCaptchaRequiredError` 会自动切网页版登录 |
| 课表没有周六周日 | 学校课表返回的周次格式差异 | `JwApi` 的 `parseWeeks` 已兼容单值（如「7周」）；如还有差异对照抓包字段调整解析 |
| 数据字段对不上 | 各校正方版本细节差异 | 对照浏览器抓包 JSON 修正 `Models.ets` 字段映射 |
| 深色模式字色异常 | 硬编码色值 | 用 `$r('sys.color.font_primary')` 或 `ThemeUtil.onColor()` |
| 卡片不更新 | 桌面卡片独立进程 | 检查主进程是否把数据写进 `DataStore`（卡片只读持久化数据） |

### 6. ArkTS 开发高频坑（适配开发时避让）

- `@StorageProp` 订阅值必须直接参与属性表达式才会实时刷新（见上文「状态与 UI 体系」）；
- `layoutWeight` 只用于横向容器内的子节点做整宽分配，竖向 Column 子节点挂它会撑高元素；
- 正则字面量含 `"` 需改用 `new RegExp` 字符串构造；`for...of` 遍历 `ESObject[]` 会编译报错，用索引循环；
- `bindSheet` 同一组件多次绑定仅最后一个生效，且第二参数须为 `@Builder`；
- 明文 `http://` 会被禁用升 https，自建服务需自备证书。

---

## 已知限制

- **教务接口依赖学校系统**：真实数据依赖学校教务系统与教务处官网链接，若学校调整功能网址，需同步更新配置
- **功能浏览模式**：未登录时使用本地模拟数据（含占位头像/学院/班级/学号），仅用于界面体验，请勿用于真实数据查询
- **客户端 PDF 解析**：校历 PDF 表头为矢量图，客户端无法可靠自动转换；目前由预置数据提供，校历更新需要版本发布
- **教务接口风控**：学校网关可能对非浏览器请求做概率性拦截（间歇性），遇风控时可改用「网页版登录」模式或等待 24 小时自动解除

---

## AI 辅助开发

本项目由 AI 辅助完成开发：

- **架构**：通过与 AI 协作完成正方教务系统功能探索与字段映射
- **代码实现**：ArkTS 业务逻辑、UI 交互、跨页面状态管理由 AI 辅助编写与重构
- **调试与修复**：编译错误排查（ArkTS 严格规范）、正则解析、空教室导出 Excel 解析等问题由 AI 辅助定位与修复
- **工程清理**：废弃 API/资源/代码扫描与清理由 AI 辅助完成

开发者负责需求决策、功能边界、产品体验与最终验证；AI 负责实现探索、代码编写与迭代优化。**仅供学习交流使用，严禁用于商业用途！**

---

## 致谢

本项目沉浸光感（系统材质卡片体系）、外观设置与粒子消散等动效的设计思路参考了 [**miha_hm**](https://github.com/MrCashmere/miha_hm)（鸿米家，HarmonyOS NEXT 米家控制应用，GPL-3.0），感谢该项目的开源分享。

本项目桌面卡片、界面布局与交互实现参考了 [**HiXD**](https://github.com/PollenWang6/HiXD)（西安电子科技大学校园助手），感谢该项目的开源分享与 UI 设计思路。

本项目教务系统接口探索参考了 [**Traintime PDA / XDYou**](https://github.com/BenderBlog/traintime_pda)（MPL-2.0），感谢该项目的接口探索工作。

本项目「学业情况-总体成绩」与「快捷选课（BETA）」的功能实现参考了 [**zhengfang-apk**](https://github.com/znjhahaha/zhengfang-apk)（正方教务助手），感谢该项目的接口与流程探索。

---

## License

本项目基于 MIT 协议开源，详见 [LICENSE](LICENSE)。
