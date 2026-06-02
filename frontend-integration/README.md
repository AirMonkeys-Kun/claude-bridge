# 前端集成 — ServiceManager.vue

## 概述

`ServiceManager.vue` 是服务管理面板的前端组件，嵌入在 `App.vue` 的标签页中，提供可视化的服务启停管理和环境变量切换。

## 文件位置

- `D:\zebbingo\projects\stt-test-tool-frontend\src\components\ServiceManager.vue`
- `D:\zebbingo\projects\stt-test-tool-frontend\src\App.vue`

## 功能

1. **服务状态面板** — 显示 4 个服务的运行状态、PID、端口、日志
2. **套件操作** — 一键启动/停止/重启 all / chatbot / stt 三套套件
3. **单个服务操作** — 每个服务卡片上的启动/停止/重启按钮
4. **环境变量显示** — 点击展开查看服务的当前环境变量值
5. **Profile 切换** — bot_runner 和 mqtt_worker 可切换 local/cloud profile
6. **日志查看** — 点击展开实时日志

## 后端 API 调用

```
mount() → GET /api/services          ← 获取服务状态
mount() → GET /api/services/annotations ← 获取注释和 profile 信息
toggleEnv(id) → GET /api/services/{id}/env ← 懒加载环境变量
switchProfile(group, profile) → POST /api/services/{id}/profiles ← 切换 profile
```

## 构建说明

前端有 **两份副本**：

| 位置 | 用途 |
|------|------|
| `D:\zebbingo\projects\stt-test-tool-frontend\` | 开发编辑（Windows 编辑器直接访问） |
| `/home/administrator/projects/stt-test-tool-frontend/` | WSL 构建环境（`pnpm run build`） |

**⚠️ 两者是独立副本，没有同步机制。** 修改后需要手动复制或通过 symlink 解决。

## 推荐修复

将 WSL 里的前端目录替换为 symlink 指向 D 盘：

```bash
mv /home/administrator/projects/stt-test-tool-frontend /home/administrator/projects/stt-test-tool-frontend.bak
ln -s /mnt/d/zebbingo/projects/stt-test-tool-frontend /home/administrator/projects/stt-test-tool-frontend
```
