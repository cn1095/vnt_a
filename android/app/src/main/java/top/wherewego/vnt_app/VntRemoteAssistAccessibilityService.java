package top.wherewego.vnt_app;

import android.accessibilityservice.AccessibilityService;
import android.view.accessibility.AccessibilityEvent;

/**
 * 远程协助无障碍服务占位。
 * 后续真正执行鼠标、点击、滑动、输入等控制动作时，通过该服务注入无障碍手势。
 */
public class VntRemoteAssistAccessibilityService extends AccessibilityService {
    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        // 当前阶段只用于权限检测和后续远控能力预留。
    }

    @Override
    public void onInterrupt() {
        // 无障碍服务被系统中断时无需额外处理。
    }
}
