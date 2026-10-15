# Doctor-archery-Training · 博士的射击训练

> Godot 4.7.2 制作的 2D 俯视角射击 + 肉鸽原型 Demo

---

## 环境要求

- **Godot 4.7.2 或更高版本**
- 请使用**标准版**（非 .NET 版）Godot
- 渲染后端：`gl_compatibility`（已在 `project.godot` 中配置，低配机器可跑）

## 运行方法

1. 下载并安装 [Godot 4.7.2](https://godotengine.org/download)
2. 打开 Godot → `导入` → 选择本项目根目录的 `project.godot`
3. 按 `F5` 运行（主场景为 `scenes/title_screen.tscn`）

## 操作说明

| 按键 | 功能 |
|---|---|
| `W` `A` `S` `D` / 方向键 | 移动 |
| 鼠标移动 | 瞄准 |
| 鼠标左键 / `M` | 射击 |
| `Q` | 切换元素状态 |
| `空格` | 切换元素 |
| `N` / 鼠标右键 | 阿米亚护盾 |
| `Esc` | 暂停菜单 |

## 项目结构

```
├── project.godot            项目配置（主场景、输入映射、autoload）
├── export_presets.cfg       Windows 导出预设
├── 26_16x16.ico应用图标（导出时使用）
├── 222383898-1-16.ogv      复活动画视频（被 scripts/game_over.gd 引用）
│
├── assets/icons/            UI 图标（4 个 SVG + 对应 .import）
│   ├── icon_burn.svg        燃烧
│   ├── icon_frost.svg       冰冻
│   ├── icon_immune.svg      免疫
│   └── icon_wet.svg         潮湿
│
├── scenes/                  场景文件（13 个 .tscn）
│   ├── title_screen.tscn    主场景：标题界面
│   ├── main.tscn            游戏主场景
│   ├── player.tscn          玩家角色
│   ├── target.tscn          目标敌人
│   ├── arrow.tscn           箭矢
│   ├── amiya.tscn           阿米亚单位
│   ├── hud.tscn             抬头显示
│   ├── crosshair.tscn       准心
│   ├── buff_ui.tscn         状态效果 UI
│   ├── settings_panel.tscn  设置面板
│   ├── pause_menu.tscn      暂停菜单
│   ├── wall.tscn            墙体
│   └── game_over.tscn       游戏结束界面
│
├── scripts/                 GDScript 脚本（29 个 .gd）
│   ├── main.gd              主场景逻辑
│   ├── player.gd            玩家控制
│   ├── target.gd            目标敌人 AI（最大文件，43KB）
│   ├── game_manager.gd      游戏流程管理
│   ├── audio_manager.gd     音频管理（autoload）
│   ├── settings_manager.gd  设置管理（autoload）
│   ├── settings_data.gd     设置数据存储
│   ├── run_state.gd         运行状态（autoload）
│   ├── flow_state.gd        心流状态（autoload）
│   ├── buff_manager.gd      状态效果管理
│   ├── buff_ui.gd状态效果 UI 逻辑
│   ├── shop_panel.gd        商店面板
│   ├── spawner.gd           刷怪器
│   ├── game_over.gd         游戏结束与复活逻辑
│   ├── title_screen.gd      标题界面逻辑
│   ├── pause_menu.gd        暂停菜单逻辑
│   ├── settings_panel.gd    设置面板逻辑
│   ├── amiya.gd             阿米亚逻辑
│   ├── arrow.gd             箭矢逻辑
│   ├── crosshair.gd         准心逻辑
│   ├── crosshair_draw.gd    准星绘制
│   ├── hud.gd               HUD 逻辑
│   ├── wall.gd              墙体逻辑
│   ├── charge_bar.gd充能条
│   ├── center_fix.gd        居中修复工具
│   │
│   ├── 【全局 class_name 脚本，无需在场景中挂载也能用】
│   ├── damage_number.gd伤害数字飘字
│   ├── hit_stop.gd          顿帧
│   ├── screen_shake.gd      屏幕震动
│   ├── hit_flash.gd         受击闪白
│   └── hit_flash.gdshader   闪白着色器
│
└── tests/                   测试脚本（10 个 test_*.gd）
    ├── test_amiya.gd        test_arrow.gd
    ├── test_bounds_cover.gd test_buff.gd
    ├── test_element.gd      test_mouse_click.gd
    ├── test_moving_target.gd test_settings.gd
    └── test_ui_center.gd    test_wave.gd
```

## ⚠️ 音效说明（重要）

本项目使用的音效资源（`sound-effect/` 目录）**因版权原因未包含在仓库中**，
因此克隆本项目后游戏**没有音效**。

### 如何补齐音效

1. **自行准备**：把音效文件放入 `sound-effect/` 目录，命名与目录结构参考下表
2. **引用路径由 `scripts/audio_manager.gd` 中的常量指定**：

   ```gdscript
   const DIR_SFX:= "res://sound-effect/sound-fight/"      # 战斗音效
   const DIR_VOICE   := "res://sound-effect/sounds-amiya/" # 阿米亚语音
   ```

3. 放入文件后，在 Godot 编辑器中会自动生成 `.import` 文件，**`.import` 文件需要一并提交**

### 合规音效来源建议

| 来源 | 说明 |
|---|---|
| [Freesound](https://freesound.org) | 筛选 **CC0**（公共领域贡献）或 **CC-BY** 协议，可商用 |
| [Kenney](https://kenney.nl/assets) | 大量 CC0 游戏素材包，音效与图片均有 |
| [BFXR / SFXR** | 程序化生成音效，完全无版权问题，适合打击/射击类 |
| 自己用 Audacity 录制 | 100% 自主可控 |

> **CC-BY** 协议要求署名原作者，请遵守。

## 打包发布

项目已配置好 Windows 导出预设：

- Godot → `项目` → `导出` → 选 `Windows Desktop` → `导出项目`
- 导出路径：`./博士的射击训练demo2.exe`（在 `export_presets.cfg` 中定义）
- 打包结果（`build/`、`.exe`、`.pck`）**不会提交到仓库**，需要时本地重新导出即可

## 许可协议

代码部分采用 [MIT](https://opensource.org/licenses/MIT) 协议。

音频、视频等媒体资源因版权原因不随本仓库分发，使用者需自行准备合规素材。

## 相关链接

- Godot 引擎：https://godotengine.org
- Godot 文档：https://docs.godotengine.org
- GDScript 语法：https://docs.godotengine.org/zh-cn/stable/tutorials/scripting/gdscript/gdscript_basics.html
