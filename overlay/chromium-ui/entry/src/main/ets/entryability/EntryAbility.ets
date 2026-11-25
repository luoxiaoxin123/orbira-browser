import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want, errorManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { window } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import display from '@ohos.display';
import defaultAppManager from '@ohos.bundle.defaultAppManager';
import bundleManager from '@ohos.bundle.bundleManager';
import { CHROMIUM_HOME_URL, DeviceRouting, DeviceRoutingPolicy, WindowPolicy, WindowStateSnapshot } from 'engine';
import { UIManager, handleDownloadNotificationWant, handleNotificationWant } from 'engine';
import {
  CrossDeviceEntryAdapter,
  CrossDeviceSessionSnapshot
} from '../utils/crossdevice/CrossDeviceEntryAdapter';
import {
  BrowserProfileService,
  BrowserProfileState
} from '../utils/profile/BrowserProfileService';
import { AppearanceSettings, ColorModeSetting } from '../utils/appearance/AppearanceSettings';
import { IncognitoSwitch } from '../utils/IncognitoSwitch';
import { ShellUiPrefs } from '../utils/appearance/ShellUiPrefs';
import { ThemeSchemePush } from '../bus/ThemeSchemePush';

const DOMAIN = 0x0000;
const AURA_INCOGNITO_KEY = 'auraIncognito';
const AURA_SURFACE_READY_KEY = 'auraSurfaceReady';
const AURA_APP_VISIBLE_KEY = 'auraAppVisible';
const AURA_THEME_FONT_ID_KEY = 'auraThemeFontId';
const AURA_THEME_FONT_REVISION_KEY = 'auraThemeFontRevision';
const AURA_COLOR_SCHEME_KEY = 'auraColorScheme';
const AURA_FORCE_DARK_OVERRIDE_KEY = 'auraForceDarkOverride';
const AURA_FORCE_DARK_REVISION_KEY = 'auraForceDarkRevision';
// 「Vulkan 渲染加速」：启动时读取一次的 GPU 后端开关（默认 false=GLES）。
const AURA_VULKAN_ENABLED_KEY = 'auraVulkanEnabled';
// 「WebGPU 加速」：启动时读取一次的开关（默认 false）。
const AURA_WEBGPU_ENABLED_KEY = 'auraWebGpuEnabled';
const AURA_ONBOARDING_READY_KEY = 'auraOnboardingReady';
const AURA_ONBOARDING_COMPLETE_KEY = 'auraOnboardingComplete';
const AURA_PROFILE_ID_KEY = 'auraProfileId';
const AURA_PROFILE_KIND_KEY = 'auraProfileKind';
const AURA_SYNC_MODE_KEY = 'auraSyncMode';
const AURA_BROWSER_COMMAND_TEXT_KEY = 'auraBrowserCommandText';
const AURA_BROWSER_COMMAND_REVISION_KEY = 'auraBrowserCommandRevision';
const HUAWEI_WALLET_APP_LINK = 'wallet://com.huawei.wallet/';
const CDP_PAGE_LIST_URL = 'http://127.0.0.1:9222/json/list';

interface CdpPageTarget {
  type?: string;
  url?: string;
  title?: string;
}

interface BrowserSystemStateCommand {
  command: string;
  huaweiWalletAvailable: boolean;
  known: boolean;
  isDefault?: boolean;
}

export default class EntryAbility extends UIAbility {
  private startupWant: Want | null = null;
  private mainWindow: window.Window | null = null;
  private lastRoutingSignature: string = '';
  private lastThemeFontId: string = '';
  private lastColorScheme: 'light' | 'dark' = 'light';
  private lastFoldStatus: number = -1;
  private routingRefreshTimer: number = -1;

  private readonly foldStatusChanged = (foldStatus: display.FoldStatus): void => {
    this.lastFoldStatus = Number(foldStatus);
    this.refreshRouting('foldStatusChange', this.lastFoldStatus);
    this.scheduleRoutingRefresh('foldStatusSettled', 180);
  };

  private readonly windowRotationChanged = (info: window.RotationChangeInfo): void => {
    if (info.type === window.RotationChangeType.WINDOW_DID_ROTATE) {
      this.scheduleRoutingRefresh('rotationDidChange', 80);
    }
  };

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // A tap on a web notification that launched the app from cold; the
    // engine delivers the click once it is up.
    handleNotificationWant(want);
    // A tap on a "download complete" notification: open the file; the
    // browser still starts behind it.
    handleDownloadNotificationWant(this.context, want);
    // v8a diagnostic: record the last ArkTS-level crash into the app sandbox
    // so the shell can surface it on the next launch (AuraShell's crash
    // report mode). Native crashes do not surface here.
    this.registerCrashRecorder();
    this.startupWant = want;
    // 无痕模式：手机上没有第二个渲染进程，进无痕靠的是"用另一个 profileId
    // 重启应用"（见 utils/IncognitoSwitch.ets）。启动参数在这里落地，界面层
    // 据此把 WebWindow 挂到 incognito 这个 profile 上。
    this.applyIncognitoWant(want);
    const initialThemeFontId = this.context.config.fontId ?? '';
    this.lastThemeFontId = initialThemeFontId;
    const savedColorMode: ColorModeSetting = AppearanceSettings.loadSync(this.context);
    AppearanceSettings.apply(this.context, savedColorMode);
    this.lastColorScheme = savedColorMode === 'system'
      ? this.resolveColorScheme(this.context.config.colorMode)
      : (savedColorMode === 'dark' ? 'dark' : 'light');
    // 设置面板切完外观经 ThemeSchemePush 把新配色直接递回来：不依赖
    // onConfigurationUpdate 对 setColorMode 的回调（它不保证按时到达）。
    // 面板只会在 UI 起来后出现，这里注册总是赶得上。
    ThemeSchemePush.setHandler((scheme: 'light' | 'dark'): void => {
      this.applyColorSchemePush(scheme);
    });
    // 系统切深色由 UIAbility 的 onConfigurationUpdate 覆盖（那里比对
    // newConfig.colorMode 后走 applyColorSchemePush）；设置面板切外观由
    // ThemeSchemePush 直接回调覆盖。两条路径都汇到 applyColorSchemePush，
    // 由它显式下发 setColorScheme 命令让引擎重刷 live 网页配色。
    AppStorage.setOrCreate(AURA_APP_VISIBLE_KEY, true);
    AppStorage.setOrCreate(AURA_THEME_FONT_ID_KEY, initialThemeFontId);
    AppStorage.setOrCreate(AURA_THEME_FONT_REVISION_KEY, 0);
    AppStorage.setOrCreate(AURA_COLOR_SCHEME_KEY, this.lastColorScheme);
    // 网页强制深色的手动覆盖态：冷启动从 preferences 读回，并带上本次生效的配色。
    // 系统定时自动切主题常发生在后台，配置回调可能丢失，「主题变化就重置覆盖态」
    // 那条不会执行；带配色校验后，跨主题的残留覆盖态会自动失效，不会在浅色下
    // 把网页重新拉深。
    AppStorage.setOrCreate(AURA_FORCE_DARK_OVERRIDE_KEY,
      AppearanceSettings.loadForceDarkOverrideSync(this.context, this.lastColorScheme));
    AppStorage.setOrCreate(AURA_FORCE_DARK_REVISION_KEY, 0);
    // 冷启动也先落一份配色命令文本：WebWindow 在 onLoad 建好 nativeContext 后会
    // 重放一次，避免命令在组件挂载前写入而无人消费。引擎按值去重，重复下发无害。
    this.dispatchColorSchemeCommand(this.lastColorScheme);
    // Vulkan 开关默认关（GLES，规避部分机型滑动掉帧）。冷启动真正读到
    // 的值在 onWindowStageCreate 里从 preferences 读取后再覆盖此默认值。
    AppStorage.setOrCreate(AURA_VULKAN_ENABLED_KEY, false);
    // WebGPU 开关默认关。冷启动真正读到的值在 onWindowStageCreate 里覆盖。
    AppStorage.setOrCreate(AURA_WEBGPU_ENABLED_KEY, false);
    AppStorage.setOrCreate(AURA_ONBOARDING_READY_KEY, false);
    AppStorage.setOrCreate(AURA_ONBOARDING_COMPLETE_KEY, false);
    AppStorage.setOrCreate(AURA_PROFILE_ID_KEY, 'local');
    AppStorage.setOrCreate(AURA_PROFILE_KIND_KEY, 'local');
    AppStorage.setOrCreate(AURA_SYNC_MODE_KEY, 'off');
    AppStorage.setOrCreate('auraPwaWindowActive', false);
    AppStorage.setOrCreate(AURA_BROWSER_COMMAND_TEXT_KEY, '');
    AppStorage.setOrCreate(AURA_BROWSER_COMMAND_REVISION_KEY, 0);
    hilog.info(DOMAIN, 'AuraShell', 'Initial theme font configuration: %{public}s', initialThemeFontId);
    // The saved appearance choice was already applied synchronously above,
    // before the window was created; nothing is left to do here.
    this.restoreBrowserProfile();
  }

  // v8a diagnostic helpers: the crash file lives in the app sandbox; the
  // shell reads it on its next launch and shows the crash report page.
  private registerCrashRecorder(): void {
    try {
      errorManager.setDefaultErrorHandler((errObject: Error): void => {
        this.writeCrashRecord(`${errObject.message}\n${errObject.stack ?? ''}`);
      });
    } catch (error) {
      hilog.warn(DOMAIN, 'AuraShell', 'Crash recorder unavailable on this system');
    }
  }

  // Synchronous on purpose: this runs inside the crash path, where there is
  // no time for async work. Appends nothing -- the last crash wins.
  private writeCrashRecord(message: string): void {
    try {
      const path = `${this.context.filesDir}/aura-crash.txt`;
      const file = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const body = message.length > 4000 ? message.substring(0, 4000) : message;
      fs.writeSync(file.fd, `${new Date().toISOString()}\n${body}\n`);
      fs.closeSync(file);
    } catch (error) {
    }
  }

  onDestroy(): void {
    AppStorage.setOrCreate(AURA_APP_VISIBLE_KEY, false);
    this.unregisterRuntimeObservers();
  }

  onForeground(): void {
    AppStorage.setOrCreate(AURA_APP_VISIBLE_KEY, true);
    // 系统定时自动切主题多半发生在后台/锁屏，配置回调不保证到达；回前台必须
    // 无条件对账一次，否则壳层已变浅、引擎仍按深色的落盘 pref 渲染网页。
    this.reconcileColorScheme('foreground');
    this.refreshSystemState();
  }

  onBackground(): void {
    AppStorage.setOrCreate(AURA_APP_VISIBLE_KEY, false);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    const fontId = newConfig.fontId ?? '';
    if (fontId !== this.lastThemeFontId) {
      this.lastThemeFontId = fontId;
      AppStorage.setOrCreate(AURA_THEME_FONT_ID_KEY, fontId);
      const revision = Number(AppStorage.get(AURA_THEME_FONT_REVISION_KEY) ?? 0);
      AppStorage.setOrCreate(AURA_THEME_FONT_REVISION_KEY, revision + 1);
      hilog.info(DOMAIN, 'AuraShell', 'Theme font configuration changed: %{public}s', fontId);
    }

    const colorScheme = this.resolveColorScheme(newConfig.colorMode);
    if (colorScheme !== this.lastColorScheme) {
      this.applyColorSchemePush(colorScheme);
      hilog.info(DOMAIN, 'AuraShell', 'Color scheme changed: %{public}s', colorScheme);
    }
  }

  async onContinue(wantParam: Record<string, Object>): Promise<AbilityConstant.OnContinueResult> {
    const snapshot = await this.captureContinuationSnapshot();
    CrossDeviceEntryAdapter.writeContinuation(wantParam, snapshot);
    hilog.info(DOMAIN, 'AuraShell', 'Prepared cross-device continuation for %{public}s', snapshot.url);
    return AbilityConstant.OnContinueResult.AGREE;
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    // A notification tap only brings the browser forward. It carries no URL,
    // so letting it through would navigate the page to the home page.
    if (handleNotificationWant(want) || handleDownloadNotificationWant(this.context, want)) {
      return;
    }
    this.startupWant = want;
    this.applyIncognitoWant(want);
    // 无链接的再次拉起按「启动页」设置决定打开网址主页还是内置启动页。
    this.resolveStartupUrl(want).then((startUrl: string): void => {
      AppStorage.setOrCreate('auraStartUrl', startUrl);
      if (this.mainWindow) {
        this.refreshRouting('newWant');
      }
    });
  }

  // Reads the incognito flag off the launch want and parks it where the UI
  // layer reads it. An ordinary launch also sweeps the incognito profile
  // directory: leaving incognito is what those saved cookies and history
  // were waiting for.
  private applyIncognitoWant(want: Want | undefined): void {
    const incognito = IncognitoSwitch.incognitoFromWant(want);
    if (!incognito) {
      IncognitoSwitch.sweepIncognitoProfile(this.context);
    }
    AppStorage.setOrCreate(AURA_INCOGNITO_KEY, incognito);
    hilog.info(DOMAIN, 'AuraShell', 'Incognito launch: %{public}s', incognito ? 'true' : 'false');
  }

  private async resolveStartupUrl(want: Want | undefined): Promise<string> {
    const resolved = CrossDeviceEntryAdapter.resolveLaunchUrl(want);
    if (resolved !== CHROMIUM_HOME_URL) {
      return resolved;
    }
    try {
      const startupPage = await ShellUiPrefs.loadStartupPage(this.context);
      if (startupPage === 'homeUrl') {
        const homeUrl = await ShellUiPrefs.loadHomeUrl(this.context);
        if (homeUrl && homeUrl.length > 0) {
          return homeUrl;
        }
        // 单个值缺失时用多组网址列表的第一条兜底（旧版本数据 / 只
        // 写了列表没写活动项的情况）。
        const list: string[] = await ShellUiPrefs.loadHomeUrls(this.context);
        if (list.length > 0) {
          return list[0];
        }
      }
    } catch (error) {
      hilog.error(DOMAIN, 'AuraShell', 'Failed to read startup page pref: %{public}s', JSON.stringify(error));
    }
    return CHROMIUM_HOME_URL;
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const uiPath = UIManager.loadUI();
    // 启动 URL 依赖异步读取「启动页」偏好，先拿到再装载 UI，避免首帧用错 URL。
    this.resolveStartupUrl(this.startupWant ?? undefined).then((startUrl: string): void => {
      AppStorage.setOrCreate('auraStartUrl', startUrl);
      AppStorage.setOrCreate('auraRoutingRevision', 0);
      AppStorage.setOrCreate('auraRouting', '');
      // Vulkan 开关必须在引擎启动配置序列化「之前」读出来——引擎只在启动
      // 时读一次配置，晚了就得等下次冷启动。这里与 startUrl 一并异步拿到再序列化。
      // WebGPU 开关同理，与 Vulkan 一并读取、一并序列化进启动配置。
      ShellUiPrefs.loadVulkanEnabled(this.context).then((vulkanEnabled: boolean): void => {
        ShellUiPrefs.loadWebGpuEnabled(this.context).then((webgpuEnabled: boolean): void => {
          AppStorage.setOrCreate(AURA_VULKAN_ENABLED_KEY, vulkanEnabled);
          AppStorage.setOrCreate(AURA_WEBGPU_ENABLED_KEY, webgpuEnabled);
          AppStorage.setOrCreate('auraStartupConfig',
            UIManager.serializeAuraStartupConfig(startUrl, undefined, undefined, this.lastColorScheme, vulkanEnabled, webgpuEnabled));
          AppStorage.setOrCreate(AURA_SURFACE_READY_KEY, false);
        }).catch((innerError: Error): void => {
          hilog.error(DOMAIN, 'AuraShell', 'Failed to read webgpu pref: %{public}s', JSON.stringify(innerError));
          AppStorage.setOrCreate(AURA_VULKAN_ENABLED_KEY, vulkanEnabled);
          AppStorage.setOrCreate(AURA_WEBGPU_ENABLED_KEY, false);
          AppStorage.setOrCreate('auraStartupConfig',
            UIManager.serializeAuraStartupConfig(startUrl, undefined, undefined, this.lastColorScheme, vulkanEnabled, false));
          AppStorage.setOrCreate(AURA_SURFACE_READY_KEY, false);
        });
      }).catch((error: Error): void => {
        hilog.error(DOMAIN, 'AuraShell', 'Failed to read vulkan pref: %{public}s', JSON.stringify(error));
        AppStorage.setOrCreate('auraStartupConfig',
          UIManager.serializeAuraStartupConfig(startUrl, undefined, undefined, this.lastColorScheme, false, false));
        AppStorage.setOrCreate(AURA_SURFACE_READY_KEY, false);
      });

      windowStage.loadContent(uiPath, (err) => {
        if (err && err.code) {
          hilog.error(DOMAIN, 'AuraShell', 'Failed to load UI content: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, 'AuraShell', 'Loaded UI content: %{public}s', uiPath);
      });

      windowStage.getMainWindow().then((win: window.Window) => {
        this.mainWindow = win;
        this.lastFoldStatus = DeviceRoutingPolicy.getFoldStatus();
        this.configureChromiumOwnedFrame(win);
        this.refreshRouting('initial', this.lastFoldStatus);
        this.registerRuntimeObservers(win);
      }).catch((error: Error) => {
        hilog.error(DOMAIN, 'AuraShell', 'Failed to get main window: %{public}s', JSON.stringify(error));
      });
    });
  }

  onWindowStageDestroy(): void {
    AppStorage.setOrCreate(AURA_SURFACE_READY_KEY, false);
    this.unregisterRuntimeObservers();
  }

  private registerRuntimeObservers(win: window.Window): void {
    try {
      win.on('windowSizeChange', (_size: window.Size) => {
        this.refreshRouting('windowSizeChange', this.lastFoldStatus);
        this.scheduleRoutingRefresh('windowSizeSettled', 120);
      });
    } catch (error) {
      hilog.warn(DOMAIN, 'AuraShell', 'Window size observer is unavailable: %{public}s', JSON.stringify(error));
    }

    try {
      win.on('windowStatusChange', (_status: window.WindowStatusType) => {
        this.refreshRouting('windowStatusChange');
      });
    } catch (statusChangeError) {
      try {
        win.on('windowStatusDidChange', (_status: window.WindowStatusType) => {
          this.refreshRouting('windowStatusDidChange');
        });
      } catch (statusDidChangeError) {
        hilog.warn(DOMAIN, 'AuraShell', 'Window status observers are unavailable: %{public}s / %{public}s',
          JSON.stringify(statusChangeError), JSON.stringify(statusDidChangeError));
      }
    }

    try {
      win.on('freeWindowModeChange', (_enabled: boolean) => {
        this.refreshRouting('freeWindowModeChange');
      });
    } catch (error) {
      hilog.info(DOMAIN, 'AuraShell', 'Free-window observer is unavailable: %{public}s', JSON.stringify(error));
    }

    try {
      win.on('rotationChange', this.windowRotationChanged);
    } catch (error) {
      hilog.info(DOMAIN, 'AuraShell', 'Rotation observer is unavailable: %{public}s', JSON.stringify(error));
    }

    // 键盘避让区 → AppStorage('auraKeyboardVp')：贴底浮层要按「键盘上方」的
    // 可用高度收缩。窗口若被压缩（RESIZE）这里收到 0，不会与视口高重复扣减。
    try {
      win.on('avoidAreaChange', (options: window.AvoidAreaOptions): void => {
        if (options.type !== window.AvoidAreaType.TYPE_KEYBOARD) {
          return;
        }
        this.publishKeyboardInset(options.area.bottomRect);
      });
    } catch (error) {
      hilog.info(DOMAIN, 'AuraShell', 'Keyboard avoid-area observer is unavailable: %{public}s',
        JSON.stringify(error));
    }

    if (DeviceRoutingPolicy.isFoldable()) {
      try {
        display.on('foldStatusChange', this.foldStatusChanged);
      } catch (error) {
        hilog.error(DOMAIN, 'AuraShell', 'Failed to register fold listener: %{public}s', JSON.stringify(error));
      }
    }
  }

  private configureChromiumOwnedFrame(win: window.Window): void {
    try {
      win.setWindowDecorVisible(false);
    } catch (error) {
      hilog.warn(DOMAIN, 'AuraShell', 'Window decor control is unavailable: %{public}s', JSON.stringify(error));
    }

    win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_UNSPECIFIED).catch((error: Error) => {
      hilog.warn(DOMAIN, 'AuraShell', 'Preferred orientation control is unavailable: %{public}s',
        JSON.stringify(error));
    });
  }

  private unregisterRuntimeObservers(): void {
    if (this.mainWindow) {
      try {
        this.mainWindow.off('windowSizeChange');
      } catch (error) {
      }
      try {
        this.mainWindow.off('windowStatusChange');
      } catch (error) {
      }
      try {
        this.mainWindow.off('windowStatusDidChange');
      } catch (error) {
      }
      try {
        this.mainWindow.off('freeWindowModeChange');
      } catch (error) {
      }
      try {
        this.mainWindow.off('rotationChange', this.windowRotationChanged);
      } catch (error) {
      }
      try {
        this.mainWindow.off('avoidAreaChange');
      } catch (error) {
      }
    }

    try {
      display.off('foldStatusChange', this.foldStatusChanged);
    } catch (error) {
    }

    if (this.routingRefreshTimer >= 0) {
      clearTimeout(this.routingRefreshTimer);
      this.routingRefreshTimer = -1;
    }

    this.mainWindow = null;
  }

  private scheduleRoutingRefresh(reason: string, delayMs: number): void {
    if (this.routingRefreshTimer >= 0) {
      clearTimeout(this.routingRefreshTimer);
    }
    this.routingRefreshTimer = setTimeout(() => {
      this.routingRefreshTimer = -1;
      const foldStatus = DeviceRoutingPolicy.getFoldStatus();
      this.lastFoldStatus = foldStatus;
      this.refreshRouting(reason, foldStatus);
    }, delayMs);
  }

  private refreshRouting(reason: string, foldStatusOverride?: number): void {
    if (!this.mainWindow) {
      return;
    }

    if (reason !== 'initial' && reason !== 'colorModeChange' && !this.isSurfaceReady()) {
      hilog.info(DOMAIN, 'AuraShell', 'Skip routing refresh before first surface frame: %{public}s', reason);
      return;
    }

    const windowState = this.captureWindowState(this.mainWindow);
    const foldStatus = foldStatusOverride ?? this.lastFoldStatus;
    const routing = UIManager.getRouting(windowState, foldStatus);
    const startUrl = (AppStorage.get('auraStartUrl') as string) || CHROMIUM_HOME_URL;
    const vulkanEnabled = Boolean(AppStorage.get(AURA_VULKAN_ENABLED_KEY) ?? false);
    const webgpuEnabled = Boolean(AppStorage.get(AURA_WEBGPU_ENABLED_KEY) ?? false);
    const routingSignature = `${DeviceRoutingPolicy.buildRoutingSignature(routing)}|${this.lastColorScheme}`;

    this.applyWindowPolicy(this.mainWindow, routing);
    AppStorage.setOrCreate('auraRouting', JSON.stringify(routing));
    AppStorage.setOrCreate('auraStartupConfig',
      UIManager.serializeAuraStartupConfig(startUrl, windowState, foldStatus, this.lastColorScheme, vulkanEnabled, webgpuEnabled));

    if (routingSignature !== this.lastRoutingSignature) {
      this.lastRoutingSignature = routingSignature;
      const currentRevision = Number(AppStorage.get('auraRoutingRevision') ?? 0);
      AppStorage.setOrCreate('auraRoutingRevision', currentRevision + 1);
    }

    hilog.info(DOMAIN, 'AuraShell', 'Routing refreshed from %{public}s: %{public}s', reason, routingSignature);
  }

  private isSurfaceReady(): boolean {
    return Boolean(AppStorage.get(AURA_SURFACE_READY_KEY) ?? false);
  }

  private resolveColorScheme(colorMode?: ConfigurationConstant.ColorMode): 'light' | 'dark' {
    return colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ? 'dark' : 'light';
  }

  // 设置面板切完外观后的直接下发：重序列化启动配置 + 顶起 revision。
  // refreshRouting 的签名含 lastColorScheme，配色变了必 bump；WebWindow 的
  // @Monitor('routingRevision') 由此把新配置喂给引擎（EnsureStarted →
  // UpdateAuraShellColorScheme → 窗口 ColorMode 覆盖 + 页面重算）。若系统回调
  // 随后也到，resolveColorScheme 算出同一个值 → 签名不变 → 不再 bump，天然幂等。
  private applyColorSchemePush(scheme: 'light' | 'dark'): void {
    this.lastColorScheme = scheme;
    AppStorage.setOrCreate(AURA_COLOR_SCHEME_KEY, scheme);
    // 主题变了：把网页强制深色的手动覆盖态清回「跟随」，否则用户手动关过一次
    // 之后再切主题也不会自动跟随。AuraShell 监听这个键重新下发 setPref。
    // 同步写盘（带新配色）：只写 AppStorage 的话，磁盘上残留的 'on' 会在下次
    // 冷启动被读回、在浅色主题下把网页重新拉深。
    AppStorage.setOrCreate(AURA_FORCE_DARK_OVERRIDE_KEY, 'follow');
    AppearanceSettings.saveForceDarkOverride(this.context, 'follow', scheme);
    const forceDarkRevision = Number(AppStorage.get(AURA_FORCE_DARK_REVISION_KEY) ?? 0);
    AppStorage.setOrCreate(AURA_FORCE_DARK_REVISION_KEY, forceDarkRevision + 1);
    this.refreshRouting('colorModeChange');
    this.dispatchColorSchemeCommand(scheme);
    hilog.info(DOMAIN, 'AuraShell', 'Color scheme pushed from settings: %{public}s', scheme);
  }

  private reconcileColorScheme(reason: string): void {
    const raw = this.context.config.colorMode;
    const explicit: boolean =
      raw === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ||
      raw === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    if (explicit) {
      const resolved = this.resolveColorScheme(raw);
      if (resolved !== this.lastColorScheme) {
        this.applyColorSchemePush(resolved);
        hilog.info(DOMAIN, 'AuraShell', 'Color scheme reconciled (%{public}s): %{public}s', reason, resolved);
        return;
      }
    }
    // 配色没变（或系统给的是 NOT_SET）也要重推：引擎的 auto-dark pref 是持久化的，
    // 上次切换时若命令被吞就会一直保持旧值。bump revision 触发 AuraShell 的
    // @Watch 重新下发 setPref；命令通道显式重发 setColorScheme 让 live 网页重算。
    // 引擎侧 UpdateAuraShellColorScheme 与 PrefWatcher 都按值去重，重复下发幂等。
    const forceDarkRevision = Number(AppStorage.get(AURA_FORCE_DARK_REVISION_KEY) ?? 0);
    AppStorage.setOrCreate(AURA_FORCE_DARK_REVISION_KEY, forceDarkRevision + 1);
    this.dispatchColorSchemeCommand(this.lastColorScheme);
    hilog.info(DOMAIN, 'AuraShell', 'Color scheme re-pushed (%{public}s): %{public}s',
      reason, this.lastColorScheme);
  }

  private restoreBrowserProfile(): void {
    BrowserProfileService.load(this.context)
      .then(async (state: BrowserProfileState): Promise<void> => {
        let resolved: BrowserProfileState = state;
        // 首次安装不再弹「选择浏览器资料的保存方式」——直接默认
        // 本机 Profile（数据只留本机不上传），静默完成 onboarding；账号绑定
        // 留给日后的同步设置入口，不在启动路径上打断用户。
        if (!state.onboardingComplete) {
          resolved = await BrowserProfileService.completeLocalOnboarding(this.context);
        }
        AppStorage.setOrCreate(AURA_ONBOARDING_COMPLETE_KEY, resolved.onboardingComplete);
        AppStorage.setOrCreate(AURA_PROFILE_ID_KEY, resolved.profileId);
        AppStorage.setOrCreate(AURA_PROFILE_KIND_KEY, resolved.profileKind);
        AppStorage.setOrCreate(AURA_SYNC_MODE_KEY, resolved.syncMode);
        AppStorage.setOrCreate(AURA_ONBOARDING_READY_KEY, true);
      })
      .catch((error: Error): void => {
        hilog.error(DOMAIN, 'AuraShell', 'Failed to restore browser profile: %{public}s',
          JSON.stringify(error));
        AppStorage.setOrCreate(AURA_ONBOARDING_READY_KEY, true);
      });
  }

  private refreshSystemState(): void {
    let huaweiWalletAvailable = false;
    try {
      huaweiWalletAvailable = bundleManager.canOpenLink(HUAWEI_WALLET_APP_LINK);
    } catch (error) {
      hilog.info(DOMAIN, 'AuraShell', 'Huawei Wallet link is unavailable: %{public}s',
        JSON.stringify(error));
    }
    defaultAppManager.isDefaultApplication(defaultAppManager.ApplicationType.BROWSER)
      .then((isDefault: boolean): void => {
        this.dispatchBrowserCommand({
          command: 'systemCapabilities',
          huaweiWalletAvailable,
          known: true,
          isDefault
        });
      })
      .catch((error: Error): void => {
        hilog.warn(DOMAIN, 'AuraShell', 'Default browser state is unavailable: %{public}s',
          JSON.stringify(error));
        this.dispatchBrowserCommand({
          command: 'systemCapabilities',
          huaweiWalletAvailable,
          known: false
        });
      });
  }

  private dispatchBrowserCommand(command: BrowserSystemStateCommand): void {
    AppStorage.setOrCreate(AURA_BROWSER_COMMAND_TEXT_KEY, JSON.stringify(command));
    const revision = Number(AppStorage.get(AURA_BROWSER_COMMAND_REVISION_KEY) ?? 0);
    AppStorage.setOrCreate(AURA_BROWSER_COMMAND_REVISION_KEY, revision + 1);
  }

  // 运行时配色下发：经独立的浏览器命令通道把配色直接递给引擎，避免与 refreshSystemState
  // 共用通道时相互覆盖丢失。系统切深色 / 设置面板切外观最终都汇聚到 applyColorSchemePush。
  // 引擎侧 UpdateConfiguration → Initialize 的重调只把 state.color_scheme 原样应用、
  // 并不会重新写入它（该写入只在启动入口发生过一次），所以必须显式用 setColorScheme
  // 命令告诉引擎，否则 live 网页永远不跟随变暗。命令写入独立通道
  // auraColorSchemeCommandText / auraColorSchemeCommandRevision，由 WebWindow 的
  // colorSchemeCmdRev 监视器转发给引擎。
  private dispatchColorSchemeCommand(scheme: 'light' | 'dark'): void {
    AppStorage.setOrCreate('auraColorSchemeCommandText',
      JSON.stringify({ command: 'setColorScheme', scheme: scheme }));
    const revision = Number(AppStorage.get('auraColorSchemeCommandRevision') ?? 0);
    AppStorage.setOrCreate('auraColorSchemeCommandRevision', revision + 1);
  }

  private captureWindowState(win: window.Window): WindowStateSnapshot {
    let inFreeWindowMode = false;
    let windowStatus = 0;
    let windowWidthVp = 0;
    let windowHeightVp = 0;

    try {
      inFreeWindowMode = !!win.isInFreeWindowMode();
    } catch (error) {
    }

    try {
      windowStatus = Number(win.getWindowStatus());
    } catch (error) {
    }

    // 应用窗口自身的 vp 尺寸：设备路由靠它分「平板横屏/大自由窗 = 桌面 UI」
    // 与「竖屏/竖屏比例小窗 = 手机 UI」。windowRect 是 px，用窗口自己的
    // UIContext 折 vp（跟随窗口所在屏的密度，不取主屏兜底值）。
    try {
      const rect = win.getWindowProperties().windowRect;
      const uiContext = win.getUIContext();
      windowWidthVp = Math.round(uiContext.px2vp(rect.width));
      windowHeightVp = Math.round(uiContext.px2vp(rect.height));
    } catch (error) {
    }

    return {
      inFreeWindowMode,
      windowStatus,
      windowWidthVp,
      windowHeightVp
    };
  }

  private applyWindowPolicy(win: window.Window, routing: DeviceRouting): void {
    try {
      // Chromium owns browser chrome, but HarmonyOS remains the sole owner of
      // desktop caption controls. Fullscreen/mobile states have no caption.
      const pwaWindowActive = Boolean(AppStorage.get('auraPwaWindowActive') ?? false);
      win.setWindowDecorVisible(
        routing.windowPolicy === WindowPolicy.WINDOWED && !pwaWindowActive);
    } catch (error) {
      hilog.warn(DOMAIN, 'AuraShell', 'Window decor update is unavailable: %{public}s', JSON.stringify(error));
    }

    // 导航过渡"闪黑"柔化：跨站导航时显示层重建有一瞬空档，系统会露出
    // 窗口背景——默认纯黑在深色主题下十分扎眼。这里把窗口背景对齐主题
    // 底色（深色 #1D1D1F / 浅色 #FFFFFF），空档帧变成"闪一下界面底色"。
    try {
      win.setWindowBackgroundColor(this.lastColorScheme === 'dark' ? '#1D1D1F' : '#FFFFFF');
    } catch (error) {
      hilog.warn(DOMAIN, 'AuraShell', 'Window background color update is unavailable: %{public}s', JSON.stringify(error));
    }

    try {
      if (this.lastColorScheme === 'dark') {
        win.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          statusBarContentColor: '#FFFFFF',
          navigationBarColor: '#00000000',
          navigationBarContentColor: '#FFFFFF',
          isStatusBarLightIcon: true,
        });
      } else {
        win.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          statusBarContentColor: '#000000',
          navigationBarColor: '#00000000',
          navigationBarContentColor: '#000000',
          isStatusBarLightIcon: false,
        });
      }
    } catch (error) {
      hilog.warn(DOMAIN, 'AuraShell', 'System bar properties update is unavailable: %{public}s', JSON.stringify(error));
    }

    const pageFullscreen: boolean = AppStorage.get<boolean>('auraPageFullscreen') === true;
    const systemBarVisible: boolean = !pageFullscreen;

    if (routing.windowPolicy === WindowPolicy.FULLSCREEN) {
      // Immersive layout: the shell draws BEHIND the status bar and the
      // navigation pill (their heights reach the shell as avoid-area insets),
      // so both stay visible like on any system app.
      win.setWindowLayoutFullScreen(true).catch(() => {
      });
      try {
        win.setSpecificSystemBarEnabled('status', systemBarVisible);
        win.setSpecificSystemBarEnabled('navigationIndicator', systemBarVisible);
      } catch (error) {
      }
      this.updateSafeAreaInsets(win, true);
    } else {
      win.setWindowLayoutFullScreen(false).catch(() => {
      });
      try {
        win.setSpecificSystemBarEnabled('status', systemBarVisible);
        win.setSpecificSystemBarEnabled('navigationIndicator', systemBarVisible);
      } catch (error) {
      }
      this.updateSafeAreaInsets(win, false);
    }
  }

  // In fullscreen-immersive layout the shell draws under the status bar and
  // the navigation pill, so the mobile chrome needs their heights as vp
  // insets (AppStorage 'auraTopSafeVp' / 'auraBottomSafeVp'). Non-fullscreen
  // windows get the system's own insets, so the values reset to zero.
  // 键盘占用高度（px → vp）写入 AppStorage，供外壳挑浮层高度用。
  // 取 bottomRect：OHOS 把软键盘报在底部避让区里。
  private publishKeyboardInset(rect: window.Rect): void {
    try {
      const disp = display.getDefaultDisplaySync();
      const density = disp.densityPixels;
      if (density <= 0) {
        return;
      }
      AppStorage.setOrCreate('auraKeyboardVp', Math.max(0, Math.round(rect.height / density)));
      // 诊断：bottomRect 是否含输入法工具栏（及候选/表情区）无法从 SDK 文档判断，
      // 页面侧只能靠 KEYBOARD_INSET_EXTRA_VP 补差。这里留下系统原始数值，便于换
      // 设备/换输入法后按日志重新标定，不必再靠截图猜。
      hilog.info(DOMAIN, 'AuraShell',
        'keyboard rect top=%{public}d height=%{public}d screenPx=%{public}d density=%{public}f',
        rect.top, rect.height, disp.height, density);
    } catch (error) {
      AppStorage.setOrCreate('auraKeyboardVp', 0);
    }
  }

  private updateSafeAreaInsets(win: window.Window, fullscreen: boolean): void {
    if (!fullscreen) {
      AppStorage.setOrCreate('auraTopSafeVp', 0);
      AppStorage.setOrCreate('auraBottomSafeVp', 0);
      return;
    }
    try {
      const density = display.getDefaultDisplaySync().densityPixels;
      if (density <= 0) {
        return;
      }
      let topPx = 0;
      let bottomPx = 0;
      try {
        topPx = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
      } catch (error) {
      }
      try {
        bottomPx = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR)
          .bottomRect.height;
      } catch (error) {
      }
      AppStorage.setOrCreate('auraTopSafeVp', Math.round(topPx / density));
      AppStorage.setOrCreate('auraBottomSafeVp', Math.round(bottomPx / density));
    } catch (error) {
      hilog.warn(DOMAIN, 'AuraShell', 'Avoid area read failed: %{public}s', JSON.stringify(error));
    }
  }

  private async captureContinuationSnapshot(): Promise<CrossDeviceSessionSnapshot> {
    const fallbackUrl = (AppStorage.get('auraStartUrl') as string) || CHROMIUM_HOME_URL;
    const request = http.createHttp();
    try {
      const response = await request.request(CDP_PAGE_LIST_URL, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        connectTimeout: 1500,
        readTimeout: 1500
      });
      if (Number(response.responseCode) === 200 && typeof response.result === 'string') {
        const targets = JSON.parse(response.result) as CdpPageTarget[];
        for (const target of targets) {
          if (target.type === 'page' && target.url) {
            return {
              url: target.url,
              title: target.title ?? '',
              capturedAt: Date.now()
            };
          }
        }
      }
    } catch (error) {
      hilog.warn(DOMAIN, 'AuraShell', 'CDP snapshot unavailable during continuation: %{public}s',
        JSON.stringify(error));
    } finally {
      request.destroy();
    }
    return {
      url: fallbackUrl,
      title: '',
      capturedAt: Date.now()
    };
  }
}
