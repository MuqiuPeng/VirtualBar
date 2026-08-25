# VirtualBar

VirtualBar 是一个面向 macOS 14 及以上版本的虚拟菜单栏 POC。

## 当前实现

VirtualBar 在系统菜单栏中只保留一个切换按钮和一个隐藏 spacer。第三方菜单栏图标被 spacer 折叠后，点击 VirtualBar 按钮会出现一个紧凑的虚拟 Bar。虚拟 Bar 中展示的是通过 ScreenCaptureKit 获取的实时图标图像，点击时通过 Accessibility 对原始第三方 status item 执行 `AXPress`。

虚拟 Bar 不再按原始屏幕坐标摆放图标，而是采用紧凑单行布局。内容超过 520pt 时可横向滚动，因此不会因为原始图标位于刘海后方或屏幕外而把虚拟 Bar 撑出屏幕。

当前 UI 使用纯三个实心点作为 VirtualBar 图标，不带外圈。虚拟 Bar 图标为 34pt、点击区域为 40pt，面板高度为 48pt，最大宽度为 520pt。每个按钮都有 hover 和 pressed 强调色背景反馈；面板使用无标题无边框且不可调整尺寸的窗口、12pt 连续圆角、零边框宽度和无系统窗口阴影，并关闭窗口内容与按钮的焦点环。

虚拟 Bar 以 VirtualBar 菜单栏按钮为锚点，并在原位置基础上向右偏移 28pt。右键点击 VirtualBar 图标后选择 `Settings…` 可以打开设置窗口。设置窗口支持勾选进入虚拟 Bar 的图标、拖拽调整顺序、刷新当前第三方图标以及恢复系统自然顺序。

图标显示状态和顺序使用稳定的 item identity 持久化，不使用列表下标。第三方 item 动态新增时会按系统自然顺序补入，临时消失的 item 不会删除已有偏好，重新出现后会恢复其显示状态和顺序。

点击任一虚拟图标后：

1. 虚拟 Bar 同步关闭。
2. spacer 暂时归零，让原始 status item 回到自然位置。
3. VirtualBar 重新解析该 item 的实时 window identity 和 frame。
4. 对原始 item 执行 `AXPress`。
5. 持续监测目标进程新出现的菜单或 Popover 窗口。
6. 只有目标界面真正关闭后才重新折叠第三方图标。

这避免了旧实现中菜单刚打开就因为 spacer 被立即恢复而失焦消失的问题。监测到界面后没有固定的短超时，菜单可以一直保持；只有其窗口消失并连续稳定一秒后才回收布局。如果某个应用无法暴露可监测窗口，VirtualBar 会保留展开状态至少 20 秒。

目标界面失焦时也会自动回收。VirtualBar 同时监测目标弹层之外的全局鼠标点击和前台应用切换；外部交互发生后等待 250ms，再恢复 spacer。点击目标菜单或 Popover 内部不会触发回收，因为点击位置会和目标进程新增窗口的实时 frame 做命中判断。

点击结果会区分弹层和普通窗口跳转。菜单或 Popover 窗口继续按完整生命周期保持；如果目标应用进入前台，或者新增的是普通应用窗口，并且 600ms 内没有发现弹层窗口，则视为窗口跳转已经完成并立即恢复 spacer。这样打开 Notion 一类主窗口的入口不会继续占用展开后的菜单栏空间。

`AXPress` 返回 `AXError.cannotComplete` 时不再立即判定为失败。状态栏菜单进入同步 tracking loop 后经常无法及时回应 AX 请求，但动作已经投递且菜单已经出现；VirtualBar 会继续进入窗口生命周期监测，避免错误地立刻恢复 spacer。

旧分页遮罩和 menu bar curtain 已从运行代码中移除，虚拟 Bar 不会在菜单栏上绘制深色覆盖区域。

## 能力边界

- 普通第三方 status item：支持捕获和 Accessibility 激活。
- 系统 Control Center：不纳入虚拟 Bar。
- Live Activity：不纳入虚拟 Bar。
- 单个第三方 status item 的跨进程坐标写入：公开 API 和 Accessibility 均不支持。
- 菜单锚点仍由第三方应用自己的真实 status item 决定，VirtualBar 不伪造菜单。

## 权限

- Accessibility 用于激活原始第三方 status item。
- Screen Recording 用于捕获真实图标。未授权时使用所属应用图标作为回退。

如果 Accessibility 尚未生效，VirtualBar 会保持真实图标展开，不会先把它们隐藏。

## 构建运行

```bash
Scripts/build-app.sh debug
open .build/debug/VirtualBar.app
```

运行日志写入 `/tmp/virtualbar.log`。关键日志包括虚拟 Bar 是否已关闭、目标界面是否被检测到、目标界面何时真正关闭以及 spacer 何时重新折叠。
