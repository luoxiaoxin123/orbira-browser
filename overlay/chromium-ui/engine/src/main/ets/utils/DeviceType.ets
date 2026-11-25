/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import deviceInfo from '@ohos.deviceInfo';
import display from '@ohos.display';

export enum DeviceType {
  PHONE = 'phone',
  TABLET = 'tablet',
  PC = 'pc'
}

export enum UIProfile {
  PHONE = 'phone',
  TABLET = 'tablet',
  PC = 'pc'
}

export enum UIFamily {
  AURA_PC = 'aura_pc',
  AURA_TABLET = 'aura_tablet',
  MOBILE_PHONE = 'mobile_phone',
  MOBILE_LARGE = 'mobile_large'
}

export enum WindowPolicy {
  FULLSCREEN = 'fullscreen',
  WINDOWED = 'windowed'
}

export enum InputProfile {
  TOUCH = 'touch',
  MIXED = 'mixed',
  REMOTE = 'remote'
}

export enum DeviceClass {
  PHONE = 'phone',
  FOLDABLE = 'foldable',
  TABLET = 'tablet',
  TWO_IN_ONE = '2in1',
  TV = 'tv',
  CAR = 'car'
}

export interface DeviceIdentity {
  deviceType: string;
  marketName: string;
  productModel: string;
  isFoldable: boolean;
  foldStatus: number;
}

export interface WindowStateSnapshot {
  inFreeWindowMode: boolean;
  windowStatus: number;
  // 应用窗口自身尺寸（vp）。设备路由按它区分「平板横屏/大自由窗 = 桌面 UI」
  // 与「平板竖屏/竖屏比例小窗 = 手机 UI」——display.* 是整机分辨率，分屏/自由
  // 窗下应用只占其中一部分，必须用 windowRect 才行。
  windowWidthVp?: number;
  windowHeightVp?: number;
}

export interface DeviceRoutingContext {
  identity: DeviceIdentity;
  windowState?: WindowStateSnapshot;
}

export interface DeviceRouting {
  uiProfile: UIProfile;
  uiFamily: UIFamily;
  windowPolicy: WindowPolicy;
  inputProfile: InputProfile;
  deviceClass: DeviceClass;
  fullscreenRequested: boolean;
  identity: DeviceIdentity;
}

// The surfaces a shell can take over today. Ask the engine to add one when
// the shell has written its own; until then Chromium draws it.
export type ShellSurface =
  // Long-press and right-click menus; the shell gets contextMenuRequested.
  | 'contextMenu'
  // The download bubble and shelf; the shell follows downloadUpdated.
  | 'downloadUi'
  // Permission questions; the shell gets sitePermissionRequested.
  | 'permissionPrompt';

// 1.0.143: one extra command-line switch handed to the engine at startup.
// ArkTS has no object-literal types (arkts-no-obj-literals-as-types), so the
// shape has to be a declared interface rather than written inline.
export interface AuraCommandLineSwitch {
  key: string;
  value?: string;
}

export interface AuraStartupConfig {
  // Opt in while Chromium presenter/device integration is being qualified.
  // The original compositor remains the default until end-to-end testing.
  enableVideoOverlays?: boolean;
  startUrl: string;
  uiProfile: 'phone' | 'tablet' | 'pc';
  uiFamily: 'aura_pc' | 'aura_tablet' | 'mobile_phone' | 'mobile_large';
  // Who draws the browser. 'shell' means this app does, and Chromium draws
  // only the page: no tab strip, toolbar, location bar, bookmark bar, app
  // menu, download or permission UI. 'native' means Chromium draws them.
  //
  // Omitted, it follows uiFamily the way it always did -- 'shell' on
  // mobile_phone, 'native' elsewhere. A tablet that wants its own UI with a
  // tablet's user agent has to say so, because those two things are
  // otherwise decided together.
  //
  // Read once at startup and fixed for the run: unfolding a foldable changes
  // uiFamily and must not put Chromium's tab strip back on screen.
  browserChrome?: 'shell' | 'native';
  // Which of Chromium's own dialogs and bubbles the shell has taken over.
  // Hiding the frame says nothing about these: a shell adopts them one at a
  // time, and Chromium keeps drawing the rest so a feature the shell has not
  // reached yet does not simply vanish.
  //
  // A phone that passes nothing still gets all three, which is what it has
  // always had.
  shellSurfaces?: ShellSurface[];
  windowMode: 'fullscreen' | 'windowed';
  deviceClass: 'phone' | 'foldable' | 'tablet' | '2in1' | 'tv' | 'car';
  marketName: string;
  productModel: string;
  isFoldable: boolean;
  foldStatus: number;
  displayWidth?: number;
  displayHeight?: number;
  displayDensity?: number;
  userDataDir?: string;
  printOutputDir?: string;
  resourcesDir?: string;
  applicationLocale?: string;
  colorScheme: 'light' | 'dark';
  icuDataFd?: number;
  icuDataOffset?: number;
  icuDataLength?: number;
  jitless: boolean;
  // Opt in to the OHOS JIT compatibility request after a failed memory probe.
  // jitless always wins. Omitted/false keeps probe-only startup.
  jitCompatibility?: boolean;
  // Off the GPU when the GPU's fences do not work. Unset lets the engine
  // decide, which is what a device should do; set only to run the
  // comparison the other way without a rebuild.
  gpuRasterization?: boolean;
  // The last resort: draw the page without the GPU at all. Unset lets the
  // engine decide, which is what a device should do.
  gpuCompositing?: boolean;
  // Chromium's frame-rate counter, drawn over the page and over its own
  // UI. For checking a 120Hz panel is driven at 120 and that a still page
  // stops asking for frames.
  showFrameRate?: boolean;
  // Which of ANGLE's backends draws. Unset or 'gles' is ANGLE on
  // HarmonyOS's own EGL/GLES, which is what a device should use; 'vulkan'
  // is for measuring Vulkan against it. Read once, at startup.
  // 1.0.144: this carries the "Vulkan 渲染加速" setting. It is the only path
  // that reaches the GPU process: the engine turns it into --use-angle=, and
  // "use-angle" is on the GPU process switch allowlist.
  angleBackend?: 'gles' | 'vulkan';
  // Where the GPU runs. Unset or 'in-process' keeps it in the browser
  // process; 'separate' gives it a process of its own on a tablet or 2in1,
  // so a GPU fault takes down that process and not the browser. Ignored on
  // a phone on the default path; available with experimentalPhoneFork.
  // Read once, at startup.
  gpuProcess?: 'in-process' | 'separate';
  // EXPERIMENTAL, default false. Start a same-UID fork server before ChromeMain
  // on phone/foldable; gpuProcess selects GPU placement. Requires a cold restart.
  // This provides no renderer security sandbox. Startup fails on conflicts.
  experimentalPhoneFork?: boolean;
  // What Skia draws with in the GPU process. Unset or 'gl' is GL; 'vulkan'
  // is Vulkan, for comparing the two. Only with gpuProcess 'separate', and
  // ignored otherwise. Phone fork uses shared NativeBuffers (ANGLE stays GLES).
  // Vulkan failure falls back to GL for this app session; cold restart retries.
  skiaBackend?: 'gl' | 'vulkan';
  // What the app menu's way back to this shell's UI is called. Not sending
  // it is how a shell says it does not want that item -- a phone has no
  // setting to come back to, and a shell drawing the browser itself has
  // its own settings a tap away. Read once, at startup.
  shellUiMenuLabel?: string;
  // The product's name, used where Chromium would name itself to the
  // reader -- "... has been added to Chromium" after installing an
  // extension. Read once, at startup.
  productName?: string;
  fullscreenRequested: boolean;
  // Who draws long-press menus. 'shell': the engine sends contextMenuRequested
  // and the shell draws the menu. 'native': Chromium's own menu. Unset, phones
  // use 'shell' and other devices 'native'.
  contextMenu?: 'shell' | 'native';
  // Who draws download UI. 'shell': no Chromium download bubble or shelf; the
  // shell follows downloadUpdated events. Unset, as contextMenu.
  downloadUi?: 'shell' | 'native';
  // Where downloads are saved, when the shell already knows at startup (a URI
  // it kept from an earlier run). Usually it does not: HarmonyOS hands out the
  // directory only once the UI is up, so shells send setDownloadDirectory
  // instead (see ShellDownloadDirectory).
  downloadDirectoryUri?: string;
  windowRole?: 'browser' | 'pwa';
  targetWidget?: number;
  pwaAppId?: string;
  // 附加命令行开关。注意：GPU 进程的命令行是从浏览器进程按白名单拷过去的
  // (content/browser/gpu/gpu_process_host.cc 的 kSwitchNames)，白名单外的键
  // 在 GPU 进程读不到，闸门再严也是空转。
  additionalSwitches?: AuraCommandLineSwitch[];
}

export const CHROMIUM_HOME_URL: string = 'chrome://newtab/';

// 1.0.143: the switch the engine's GPU process looks for. Present, it keeps
// ANGLE on EGL/GLES and never asks for Vulkan; absent, the engine follows its
// own (upstream) Vulkan path. Must match IsOhosPhoneVulkanEnabled() in
// overlay/ui/ozone/platform/ohos/ohos_phone_gpu_channel.cc.
export const OHOS_DISABLE_VULKAN_SWITCH: string = 'ohos-disable-vulkan';

const TV_MARKET_KEYWORDS: string[] = [
  'MATETV',
  '\u667a\u6167\u5c4f',
  'SMART SCREEN'
];
const MATEPAD_KEYWORDS: string[] = [ 'MATEPAD' ];
const MATEBOOK_KEYWORDS: string[] = [ 'MATEBOOK' ];

// 桌面 chrome（标签条+工具栏）放得下需要的最小窗口宽度，对应华为响应式断点
// md（600vp）：比它窄时桌面标签条不可用，回手机单栏布局。
const DESKTOP_CHROME_MIN_WIDTH_VP: number = 600;

function normalizeText(value: string): string {
  return (value ?? '').trim().toUpperCase();
}

export class DeviceRoutingPolicy {
  static readIdentity(foldStatusOverride?: number): DeviceIdentity {
    const foldStatus = foldStatusOverride === undefined ?
      DeviceRoutingPolicy.getFoldStatus() : foldStatusOverride;
    return {
      deviceType: deviceInfo.deviceType ?? 'phone',
      marketName: deviceInfo.marketName ?? '',
      productModel: deviceInfo.productModel ?? '',
      isFoldable: DeviceRoutingPolicy.isFoldable(),
      foldStatus
    };
  }

  static resolve(windowState?: WindowStateSnapshot, foldStatusOverride?: number): DeviceRouting {
    return DeviceRoutingPolicy.resolveFromIdentity(
      DeviceRoutingPolicy.readIdentity(foldStatusOverride), windowState);
  }

  static resolveFromContext(context: DeviceRoutingContext): DeviceRouting {
    return DeviceRoutingPolicy.resolveFromIdentity(context.identity, context.windowState);
  }

  static resolveFromIdentity(identity: DeviceIdentity, windowState?: WindowStateSnapshot): DeviceRouting {
    const deviceClass = DeviceRoutingPolicy.resolveDeviceClass(identity);
    const uiProfile = DeviceRoutingPolicy.resolveUiProfile(identity, windowState);
    const uiFamily = DeviceRoutingPolicy.resolveUiFamily(identity, deviceClass, uiProfile, windowState);
    const inputProfile = DeviceRoutingPolicy.resolveInputProfile(deviceClass, uiProfile);
    const windowPolicy = DeviceRoutingPolicy.resolveWindowPolicy(identity, windowState);

    return {
      uiProfile,
      uiFamily,
      windowPolicy,
      inputProfile,
      deviceClass,
      fullscreenRequested: windowPolicy === WindowPolicy.FULLSCREEN,
      identity
    };
  }

  static createAuraStartupConfig(
    startUrl: string,
    windowState?: WindowStateSnapshot,
    foldStatusOverride?: number,
    colorScheme: 'light' | 'dark' = 'light',
    vulkanEnabled: boolean = false,
    webgpuEnabled: boolean = false
  ): AuraStartupConfig {
    const routing = DeviceRoutingPolicy.resolve(windowState, foldStatusOverride);
    const config: AuraStartupConfig = {
      startUrl: startUrl && startUrl.trim().length > 0 ? startUrl : CHROMIUM_HOME_URL,
      uiProfile: routing.uiProfile,
      uiFamily: routing.uiFamily,
      windowMode: routing.windowPolicy,
      deviceClass: routing.deviceClass,
      marketName: routing.identity.marketName,
      productModel: routing.identity.productModel,
      isFoldable: routing.identity.isFoldable,
      foldStatus: routing.identity.foldStatus,
      colorScheme,
      // 本外壳在所有设备形态上都自绘浏览器 chrome。不显式给 'shell' 时引擎
      // 按 uiFamily 默认值决定，实测会自行画出原生标签条：主页顶部露出一排
      // 被裁掉下半截的标签卡（用户看到的"左上角截断图标"）。
      browserChrome: 'shell',
      // 同样强制外壳画长按/右键菜单，不要引擎的原生菜单（功能不全）。
      contextMenu: 'shell',
      jitless: false,
      // 157 新增字段（155 的 ArkTS 接口没有）。引擎启动时 ProbeOhosJitMemory
      // 探测 JIT CodeRange，本字段决定探测失败时是否请求系统放宽兼容性。
      // 说明：真机落盘实测本机探测本就成功（before_avail=1/after_avail=1,
      // fallback_applied=0, js_flags 为空），JIT 从未降级 —— 所以它不是
      // "凤凰掉帧"的原因（该结论此前写在这里，是错的，已改正）。保留 true
      // 只是因为语义正确（允许必要时请求兼容），对性能无副作用。
      jitCompatibility: true,
      // ★ 157 手机端关键：本机（Pura80 / API 26）**没有 libchild_process.so**，
      // 引擎的 SupportsNativeChildProcess() 于是走 device_class 回退，
      // phone 被判为不支持 → BuildArgumentsLocked 只能加 --single-process，
      // renderer 与 browser 同进程抢 CPU。
      // 真机 trace 实测（15s，凤凰滑动）：线程累计 CPU
      // Chrome_InProcRe 31.08s vs Compositor 3.97s / VizCompositorTh 3.11s
      // （8 倍差）；且 H:WM_51294_RequestNextVSync 只有 1077 次 ≈ 72fps，
      // 而 ArkUI 主线程与 WM vsync 都是 ~120fps —— 瓶颈就在 renderer。
      // 引擎自带 fork server：libnweb_render.so 里 ChromiumNativeChildMain /
      // NativeChildProcess_MainProc 等符号齐全，启用后改走
      // --renderer-process-limit=16 + --ohos-phone-fork，获得独立 renderer
      // 子进程（同 UID、无沙箱）。真机实测：资源密集的文章页（广告/推荐流）
      // 在 fork 下加载慢、加载完成后滑动仍持续卡，单进程则正常 —— renderer
      // 与 browser 的逐帧跨进程提交在重页面上是瓶颈。默认单进程；
      // auraDiagPhoneFork 设 true 可重新启用做 A/B。
      experimentalPhoneFork: Boolean(AppStorage.get('auraDiagPhoneFork') ?? false),
      fullscreenRequested: routing.fullscreenRequested
    };
    // 1.0.144「Vulkan 渲染加速」：默认关 → ANGLE 走 HarmonyOS 自带的 EGL/GLES，
    // 规避部分机型（如 Pura80）滑动掉帧；开启则让 ANGLE 走 Vulkan。启动时读取
    // 一次，改完需重启。
    //
    // 走 angleBackend 而不是 additionalSwitches：GPU 进程的命令行是从浏览器
    // 进程按白名单拷过去的（content/browser/gpu/gpu_process_host.cc 的
    // kSwitchNames），自定义键进不去，闸门读不到就等于空转。1.0.143 就是踩了
    // 这个坑——包里能查到字符串，但开关拨了没反应。
    config.angleBackend = vulkanEnabled ? 'vulkan' : 'gles';
    // 1.0.146「WebGPU 加速」：外壳注入 --enable-unsafe-webgpu 即开，无需重编。
    // 引擎侧 Dawn/WebGPU 已编进当前 .so（patches/ohos-dawn-webgpu.patch），WebGPU
    // 走 Dawn 自带的 Vulkan（libvulkan.so），与 ANGLE 后端（gles/vulkan 那条）互不干扰。
    // 它进 additionalSwitches 而非白名单键：手机是 in-process-gpu，
    // gpu_preferences.enable_unsafe_webgpu 走 mojo 传到 GPU 侧，外壳注入即可生效。
    const extraSwitches: AuraCommandLineSwitch[] = [];
    // 顺带拦住 GPU 进程的原生 Vulkan（skiaBackend 那条路）。手机上它本来不启用
    // （要 gpuProcess='separate'），留着做保险，等那条路真启用时不会失控。
    if (!vulkanEnabled) {
      const disableVulkan: AuraCommandLineSwitch = { key: OHOS_DISABLE_VULKAN_SWITCH };
      extraSwitches.push(disableVulkan);
    }
    if (webgpuEnabled) {
      const enableWebGpu: AuraCommandLineSwitch = { key: 'enable-unsafe-webgpu' };
      extraSwitches.push(enableWebGpu);
    }
    // EXPERIMENTAL：窗口恢复可见后延迟显示（毫秒）。0 = 关闭、走上游时序；
    // 实测 300ms 反而更差（与用户开始滑动重合），保持 0。引擎侧读
    // --ohos-delayed-resume-ms（见 DelayedResumeDelay）。
    const RESUME_DELAY_MS: number = 0;
    if (RESUME_DELAY_MS > 0) {
      const resumeDelay: AuraCommandLineSwitch = {
        key: 'ohos-delayed-resume-ms',
        value: RESUME_DELAY_MS.toString()
      };
      extraSwitches.push(resumeDelay);
    }
    if (extraSwitches.length > 0) {
      config.additionalSwitches = extraSwitches;
    }
    return config;
  }

  static buildRoutingSignature(routing: DeviceRouting): string {
    return [
      routing.uiProfile,
      routing.uiFamily,
      routing.windowPolicy,
      routing.inputProfile,
      routing.deviceClass,
      routing.identity.deviceType,
      routing.identity.marketName,
      routing.identity.productModel,
      routing.identity.foldStatus.toString()
    ].join('|');
  }

  static isFoldable(): boolean {
    try {
      return display.isFoldable();
    } catch (error) {
      return false;
    }
  }

  static getFoldStatus(): number {
    if (!DeviceRoutingPolicy.isFoldable()) {
      return -1;
    }

    try {
      return Number(display.getFoldStatus());
    } catch (error) {
      return -1;
    }
  }

  static isExpandedFold(identity?: DeviceIdentity): boolean {
    const source = identity ?? DeviceRoutingPolicy.readIdentity();
    if (!source.isFoldable) {
      return false;
    }

    const folded = display.FoldStatus.FOLD_STATUS_FOLDED;
    const unknown = display.FoldStatus.FOLD_STATUS_UNKNOWN;

    if (source.foldStatus === -1 || source.foldStatus === unknown) {
      return false;
    }

    return source.foldStatus !== folded;
  }

  private static resolveUiProfile(identity: DeviceIdentity, windowState?: WindowStateSnapshot): UIProfile {
    if (DeviceRoutingPolicy.isMateBook(identity) || identity.deviceType === '2in1' || identity.deviceType === 'desktop') {
      return UIProfile.PC;
    }

    if (DeviceRoutingPolicy.isTv(identity) || DeviceRoutingPolicy.isCar(identity)) {
      return UIProfile.TABLET;
    }

    // 平板形态（MatePad / tablet / 展开态折叠屏）按窗口形状分流：
    // 横屏或够宽的自由窗给桌面布局，竖屏或竖屏比例小窗回手机 UI。
    if (DeviceRoutingPolicy.isMatePad(identity) || identity.deviceType === 'tablet' ||
      DeviceRoutingPolicy.isExpandedFold(identity)) {
      return DeviceRoutingPolicy.isCompactWindow(windowState) ? UIProfile.PHONE : UIProfile.TABLET;
    }

    return UIProfile.PHONE;
  }

  private static resolveUiFamily(identity: DeviceIdentity, deviceClass: DeviceClass,
    uiProfile: UIProfile, windowState?: WindowStateSnapshot): UIFamily {
    if (uiProfile === UIProfile.PC || deviceClass === DeviceClass.TWO_IN_ONE) {
      return UIFamily.AURA_PC;
    }

    if (deviceClass === DeviceClass.TV || deviceClass === DeviceClass.CAR) {
      return UIFamily.MOBILE_LARGE;
    }

    // 与 resolveUiProfile 同一条规则：紧凑窗口下整套路成手机 UI，uiFamily 也
    // 要落到 mobile_phone（UA、触点交互、外壳分工都跟它走）。
    if (DeviceRoutingPolicy.isExpandedFold(identity)) {
      // 展开态接近方形：横屏比例给大屏桌面 UI，竖屏比例回手机 UI。
      return DeviceRoutingPolicy.isCompactWindow(windowState) ? UIFamily.MOBILE_PHONE : UIFamily.AURA_TABLET;
    }

    if (DeviceRoutingPolicy.isMatePad(identity) || identity.deviceType === 'tablet') {
      return DeviceRoutingPolicy.isCompactWindow(windowState) ? UIFamily.MOBILE_PHONE : UIFamily.AURA_TABLET;
    }

    if (deviceClass === DeviceClass.FOLDABLE) {
      return UIFamily.MOBILE_PHONE;
    }

    return identity.deviceType === 'phone' ? UIFamily.MOBILE_PHONE : UIFamily.AURA_TABLET;
  }

  // 「紧凑窗口」判定：平板/展开折叠屏上区分桌面 UI 与手机 UI 的唯一依据。
  //   · 竖屏或竖屏比例（高 ≥ 宽）→ 紧凑 → 手机 UI；
  //   · 横屏但宽度不足 600vp（分屏窄条/小自由窗）→ 紧凑 → 手机 UI；
  //   · 尺寸未知 → 非紧凑（保持这些设备既有的大屏默认）。
  private static isCompactWindow(windowState?: WindowStateSnapshot): boolean {
    if (!windowState) {
      return false;
    }
    const width = windowState.windowWidthVp ?? 0;
    const height = windowState.windowHeightVp ?? 0;
    if (width <= 0 || height <= 0) {
      return false;
    }
    return height >= width || width < DESKTOP_CHROME_MIN_WIDTH_VP;
  }

  private static resolveWindowPolicy(identity: DeviceIdentity, windowState?: WindowStateSnapshot): WindowPolicy {
    const inFreeWindowMode = windowState?.inFreeWindowMode ?? false;

    if (identity.deviceType === 'phone' && !DeviceRoutingPolicy.isExpandedFold(identity)) {
      return WindowPolicy.FULLSCREEN;
    }

    if (DeviceRoutingPolicy.isTv(identity)) {
      return WindowPolicy.FULLSCREEN;
    }

    if (DeviceRoutingPolicy.isMateBook(identity) || identity.deviceType === '2in1' || identity.deviceType === 'desktop') {
      return WindowPolicy.WINDOWED;
    }

    if (DeviceRoutingPolicy.isCar(identity)) {
      return WindowPolicy.FULLSCREEN;
    }

    if (DeviceRoutingPolicy.isMatePad(identity)) {
      return inFreeWindowMode ? WindowPolicy.WINDOWED : WindowPolicy.FULLSCREEN;
    }

    if (identity.deviceType === 'tablet' || DeviceRoutingPolicy.isExpandedFold(identity)) {
      return inFreeWindowMode ? WindowPolicy.WINDOWED : WindowPolicy.FULLSCREEN;
    }

    return WindowPolicy.FULLSCREEN;
  }

  private static resolveInputProfile(deviceClass: DeviceClass, uiProfile: UIProfile): InputProfile {
    if (deviceClass === DeviceClass.TV || deviceClass === DeviceClass.CAR) {
      return InputProfile.REMOTE;
    }

    if (uiProfile === UIProfile.PC || deviceClass === DeviceClass.TWO_IN_ONE) {
      return InputProfile.MIXED;
    }

    return InputProfile.TOUCH;
  }

  private static resolveDeviceClass(identity: DeviceIdentity): DeviceClass {
    if (DeviceRoutingPolicy.isTv(identity)) {
      return DeviceClass.TV;
    }

    if (DeviceRoutingPolicy.isCar(identity)) {
      return DeviceClass.CAR;
    }

    if (identity.deviceType === '2in1' || identity.deviceType === 'desktop' || DeviceRoutingPolicy.isMateBook(identity)) {
      return DeviceClass.TWO_IN_ONE;
    }

    if (identity.isFoldable) {
      return DeviceClass.FOLDABLE;
    }

    if (identity.deviceType === 'tablet') {
      return DeviceClass.TABLET;
    }

    return DeviceClass.PHONE;
  }

  private static isTv(identity: DeviceIdentity): boolean {
    if (identity.deviceType === 'tv') {
      return true;
    }

    const marketName = normalizeText(identity.marketName);
    return TV_MARKET_KEYWORDS.some((keyword: string) => marketName.includes(keyword));
  }

  private static isCar(identity: DeviceIdentity): boolean {
    return identity.deviceType === 'car';
  }

  private static isMatePad(identity: DeviceIdentity): boolean {
    const name = `${normalizeText(identity.marketName)} ${normalizeText(identity.productModel)}`;
    return MATEPAD_KEYWORDS.some((keyword: string) => name.includes(keyword));
  }

  private static isMateBook(identity: DeviceIdentity): boolean {
    const name = `${normalizeText(identity.marketName)} ${normalizeText(identity.productModel)}`;
    return MATEBOOK_KEYWORDS.some((keyword: string) => name.includes(keyword));
  }

}

export class DeviceTypeDetector {
  static getDeviceType(): DeviceType {
    const routing = DeviceRoutingPolicy.resolve();
    switch (routing.uiProfile) {
      case UIProfile.PC:
        return DeviceType.PC;
      case UIProfile.TABLET:
        return DeviceType.TABLET;
      case UIProfile.PHONE:
      default:
        return DeviceType.PHONE;
    }
  }

  static getUIProfile(): UIProfile {
    return DeviceRoutingPolicy.resolve().uiProfile;
  }

  static isPhone(): boolean {
    return DeviceTypeDetector.getDeviceType() === DeviceType.PHONE;
  }

  static isTablet(): boolean {
    return DeviceTypeDetector.getDeviceType() === DeviceType.TABLET;
  }

  static isPC(): boolean {
    return DeviceTypeDetector.getDeviceType() === DeviceType.PC;
  }

  static isTV(): boolean {
    return DeviceRoutingPolicy.resolve().deviceClass === DeviceClass.TV;
  }

  static isAuto(): boolean {
    return DeviceRoutingPolicy.resolve().deviceClass === DeviceClass.CAR;
  }

  static isFoldable(): boolean {
    return DeviceRoutingPolicy.isFoldable();
  }
}
