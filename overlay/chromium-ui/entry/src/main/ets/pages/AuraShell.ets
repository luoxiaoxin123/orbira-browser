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

import { common, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { inputMethod } from '@kit.IMEKit';
import { ShellUiPrefs } from '../utils/appearance/ShellUiPrefs';
import { isNewTabUrl } from '../utils/NewTabUrl';
import { SearchEnginesPrefs } from '../utils/appearance/SearchEnginesPrefs';
import { IncognitoSwitch, SavedTab } from '../utils/IncognitoSwitch';
import { WebWindow, PictureInPictureSurface } from 'engine';
import { MobileBrowserOverlay, TOP_BAR_EXTENT_VP, CHROME_DOCK_EXTENT_VP, CHROME_DOCK_FLOAT_MARGIN_VP, dockCoveredHeightVp } from '../components/mobile/MobileBrowserOverlay';
import { MobileBackRouter } from '../components/mobile/MobileBackRouter';
import { DesktopBrowserChrome } from '../components/desktop/DesktopBrowserChrome';
import { HomeSurface } from '../components/mobile/HomeSurface';
import { CurrentTabCastSession } from '../components/mobile/CurrentTabCastSession';
import {
  buildContextMenuModel,
  ContextMenuModel,
  parseContextMenuModel,
  showContextMenuSheet,
  updateContextMenuModel
} from '../components/mobile/ContextMenuSheet';
import { BrowserOnboarding } from '../components/onboarding/BrowserOnboarding';
import {
  AuxiliaryWindowState,
  BrowserCommandPayload,
  BrowserRuntimeEvent,
  BrowserStateSnapshot,
  BrowserTabState,
  DeveloperModeEvent
} from 'engine';
import { CHROMIUM_HOME_URL } from 'engine';
import { HuaweiKnockShareSession, HuaweiShareAdapter } from 'engine';
import { HarmonyFilePickerAdapter, HarmonyFilePickerResult } from 'engine';
import { PermissionRequestAdapter, PermissionRequestResultPayload } from 'engine';
import {
  AboutInfoEvent,
  AutocompleteResultsEvent,
  BookmarkExportDoneEvent,
  BookmarkImportDoneEvent,
  BrowserCommandChannel,
  DownloadListEvent,
  DownloadNotifier,
  DownloadUpdatedEvent,
  ExtensionActionsEvent,
  ExtensionDetailsEvent,
  ExtensionReloadLandedEvent,
  FaviconsEvent,
  HistoryResultsEvent,
  BookmarkListEvent,
  PageFullscreenChangedEvent,
  PasswordCommandResultEvent,
  PasswordRevealedEvent,
  PasswordsExportedEvent,
  PasswordsImportedEvent,
  PrefsEvent,
  PullToRefreshEvent,
  RecentBookmarksEvent,
  RecentlyClosedEvent,
  SavedPasswordsEvent,
  SearchEngine,
  SearchEnginesEvent,
  ShellDownloadDirectory,
  SiteSettingsEvent,
  TabThumbnailsEvent,
  TopSitesEvent,
  shellEvent
} from 'engine';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SystemPrintAdapter } from 'engine';
import { ChromiumSystemAction, SystemIntegrationAdapter } from 'engine';
import { PwaWindowLauncher } from '../utils/PwaWindowLauncher';
import {
  AUXILIARY_WINDOW_MARGIN_VP,
  AuxiliaryWindowView,
  layoutAuxiliaryWindow,
  ScreenSizeVp
} from 'engine';
import { BrowserProfileState } from '../utils/profile/BrowserProfileService';

// extensionInstallFailed / extensionCommandFailed have no shell-service
// interface; they carry Chromium's own sentence for the reader to show.
interface ExtensionNoticePayload {
  message?: string;
  reason?: string;
  // extensionCommandFailed: which command failed -- notFound means different
  // things per command (no options page vs no such extension).
  command?: string;
}

// 上手兜底触发位移（vp）：手指在页面区划过这么多、且引擎全程没动过顶栏比例，
// 才由外壳接手——收 dock，或把已被收起的顶栏放回来（见 onSwipeControlsTouch）。
// 取得比顶栏高度小，避免"要划很久才有反应"。
const SWIPE_TRIGGER_VP: number = 28;
// 判据：引擎是否在本次手势里自己动过顶栏比例（动过说明页面真的在滚 → 让位）。
const CONTROLS_RATIO_EPS: number = 0.02;
// 键盘避让区报的 bottomRect 比页面实际该留出的高度小一截，需要额外补偿。
// 该常数为实测标定值；各站页面底部留白不同，个别站点仍可能差几 vp。
const KEYBOARD_INSET_EXTRA_VP: number = 85;
// 前进/后退的同色遮盖只在「落点是主页」时铺：那一次引擎会先画原生 NTP 磁贴，
// 而壳层主页层要等 url 变成 newtab 才挂。网页↔网页交给引擎硬切——换页空档
// 由引擎侧 gutter 色兜底，深色下与页面底色一致，观感等价硬切。
const HISTORY_NAV_COVER_HOME_ONLY: boolean = true;

// 判据统一放在 ../utils/NewTabUrl：主页层、顶栏、扩展面板共用一份。
// 注意本文件里的 backUrl/forwardUrl 为空表示「没有历史条目」，不能按主页
// 处理；共享函数只判 URL 形态，空串语义留给调用方。

const EMPTY_BROWSER_STATE: BrowserStateSnapshot = {
  version: 1,
  mobileUi: false,
  uiFamily: '',
  ready: false,
  tabCount: 0,
  activeTabIndex: -1,
  sidePanelVisible: false,
  sidePanelEntryId: '',
  focusedTarget: 'webContents',
  activationEpoch: 0,
  tabs: [],
  url: CHROMIUM_HOME_URL,
  domain: '',
  title: 'Orbira',
  loading: false,
  canGoBack: false,
  canGoForward: false,
  isPwaWindow: false,
  pwaAppId: '',
  pwaStartUrl: ''
};

@Entry
@Component
struct AuraShell {
  @StorageLink('auraRoutingRevision') @Watch('onRoutingRevisionForThemeReload') routingRevision: number = 0;
  @StorageLink('auraThemeReloadPending') themeReloadPending: boolean = false;
  // 强制深色 pref 由 setPref 下发，PrefWatcher 即时重绘已打开的标签页。
  // revision 用于在配色不变、仅覆盖态变化时也触发一次同步。
  @StorageLink('auraColorScheme') @Watch('onForceDarkSyncStateChanged') colorScheme: string = 'light';
  @StorageLink('auraForceDarkOverride') @Watch('onForceDarkSyncStateChanged') forceDarkOverride: string = 'follow';
  @StorageLink('auraForceDarkRevision') @Watch('onForceDarkSyncStateChanged') forceDarkRevision: number = 0;
  // 命令通道刚接上时首条 setPref 可能丢失，用 prefsChanged 回执确认生效，
  // 未收到就按当前状态延时补发。
  private forceDarkStartupSynced: boolean = false;
  private forceDarkStartupRetryTimers: number[] = [];
  private lastForceDarkPrefSent: boolean | undefined = undefined;
  @StorageLink('auraStartupConfig') startupConfigText: string = '';
  @StorageLink('auraStartUrl') startUrl: string = CHROMIUM_HOME_URL;
  @StorageLink('auraAppVisible') @Watch('onAppVisibleChanged') appVisible: boolean = true;
  // 上滑时隐藏状态栏: address bar collapses -> the status bar hides with it
  // and the page fills the screen (the 外观 toggle). Hysteresis keeps
  // the system bar from flapping at the collapse boundary.
  @StorageLink('auraBrowserControlsRatio') @Watch('onControlsRatioMoved') scrolledRatio: number = 1;
  @StorageLink('auraHideStatusBarOnScroll') @Watch('onHideStatusBarPrefChanged') hideStatusBarOnScroll: boolean = false;
  // 滚动时隐藏地址栏（设置-外观）：默认开；关掉时 minTop 抬到顶栏全高，
  // 顶栏常显、不随滚动收起（引擎把 ratio 锁在 1）。
  @StorageLink('auraHideTopBarOnScroll') @Watch('onHideTopBarPrefChanged') hideTopBarOnScroll: boolean = true;
  // 页面滚不动时顶栏永远收不起来，页内元素的命中坐标会整体偏下。该页必须
  // 与「设置里手动关掉本开关」走完全相同的路径：只抬 minTop 会留下「开关开着
  // 但地址栏不藏」的混合态，视口内距少让出一条顶栏高度，底部内容被切。
  // 放进 AppStorage 是为了让顶栏组件也读到同一个有效状态。
  @StorageLink('auraTopBarPinnedForPage') @Watch('onPageTopBarPinChanged') topBarPinnedForPage: boolean = false;
  private topBarPinnedUrl: string = '';
  // 当前活动页是否「整页一张 fixed 铺满视口的 cover 背景图」（必应首页/结果页）。
  // 这类页面被探针钉住时，补偿档会从 topSafe 翻到 TOP_BAR_EXTENT_VP+topSafe，
  // fixed 背景图随之缩一圈；所以只禁止钉住、保持设置档恒定，补偿本身仍照常下发。
  // 每次探针回报与换页都刷新，不留跨页残留。
  private probeOnBingCover: boolean = false;
  // 地址栏编辑态（MobileBrowserOverlay 同步）：编辑时控件被钉住，上滑兜底让位。
  @StorageLink('auraAddressEditing') addressEditing: boolean = false;
  // “滚动时隐藏底部栏”（dock）：默认开（两栏跟手同收）；关掉后 dock 常驻，
  // 页面底部为它让出高度（见 applyDockViewportInset）。
  @StorageLink('auraHideDockOnScroll') @Watch('onHideDockPrefChanged') hideDockOnScroll: boolean = true;
  // 主页风格与 Chrome 风格 dock 位置；变化时重发浏览器控件 inset。
  @StorageLink('auraHomeStyle') @Watch('onHomeStyleChanged') homeStyle: string = 'minimal';
  @StorageLink('auraDockPosition') @Watch('onDockPositionChanged') dockPosition: string = 'bottom';
  // 网页外链是否交给本机应用打开（知乎/B站等 scheme）。默认开；关掉后
  // externalUrlRequested 一律走 fallbackUrl，留在浏览器里。
  @StorageLink('auraExternalAppLinks') externalAppLinks: boolean = true;
  @StorageLink('auraPopupHomeHold') @Watch('onPopupHomeHoldChanged') popupHomeHold: number = 0;
  // 「点扩展 → 跳转」期间的全屏同色遮盖。点击瞬间铺上，盖住 onClose 回主页
  // 那一帧和扩展页首帧前的空白；popup 上屏或扩展页加载完时撤掉。
  // 只由 ExtensionPanel.runExtension() 置位，其它任何路径都不会触发。
  @StorageLink('auraExtensionJumpCover') @Watch('onExtensionJumpCoverChanged')
  extensionJumpCover: number = 0;
  @StorageLink('auraExtensionJumpPopup') extensionJumpPopup: boolean = false;
  private extensionJumpTimer: number = -1;
  private popupHoldTimer: number = -1;

  private onPopupHomeHoldChanged(): void {
    hilog.info(0x0000, 'ExtPanel', 'popupHomeHold -> %{public}d', this.popupHomeHold);
    if (this.popupHomeHold > 0) {
      // 让位时刻 = 转场结束、popup 已上屏：撤掉跳转遮盖，弹窗即可见。
      if (this.extensionJumpCover > 0) {
        AppStorage.setOrCreate('auraExtensionJumpCover', 0);
      }
      if (this.popupHoldTimer !== -1) {
        clearTimeout(this.popupHoldTimer);
      }
      this.popupHoldTimer = setTimeout((): void => {
        this.popupHoldTimer = -1;
        if (this.popupHomeHold > 0) {
          AppStorage.setOrCreate('auraPopupHomeHold', 0);
        }
        // 10 分钟：见字段注释。这里恢复的是「主页层」，popup 本身由用户或
        // 引擎关闭，走到这一支说明关闭事件没送达。
      }, 600000);
    } else if (this.popupHoldTimer !== -1) {
      clearTimeout(this.popupHoldTimer);
      this.popupHoldTimer = -1;
    }
  }

  // 跳转遮盖的兜底。真正的撤罩由 popup 让位事件（上）或扩展页加载完成
  // （onBrowserState）提前触发；这里只防事件丢失把遮盖卡死。
  private onExtensionJumpCoverChanged(): void {
    if (this.extensionJumpTimer !== -1) {
      clearTimeout(this.extensionJumpTimer);
      this.extensionJumpTimer = -1;
    }
    if (this.extensionJumpCover <= 0) {
      return;
    }
    // 无 popup（扩展页跳转）点击当帧就收面板页，转场期间设置页已完成 commit，
    // 兜底留 450ms 足够；有 popup 仍等 300ms 让位。
    const fallback: number = this.extensionJumpPopup ? 360 : 450;
    this.extensionJumpTimer = setTimeout((): void => {
      this.extensionJumpTimer = -1;
      AppStorage.setOrCreate('auraExtensionJumpCover', 0);
    }, fallback);
  }
  private statusBarHiddenByScroll: boolean = false;
  // 网页自己进了全屏（video / requestFullscreen）。引擎把页面铺满自己的区域，
  // 外围的状态栏与条带要让开：隐藏系统栏 + 控件高度清零（见 setPageFullscreen）。
  private pageFullscreen: boolean = false;
  // 顶栏是否已「完全收起」（贴状态栏底模式的静息态）。视口底部内距按它
  // 追加 topSafe 补偿——否则滚到页尾最后 ~topSafe 够不到（见 applyDockViewportInset
  // 与 computeTopBarHiddenForInset）。
  private topBarHiddenForInset: boolean = false;
  // 键盘避让高度（EntryAbility 写；RESIZE 模式为 0，不重复扣减）。键盘弹起时底部
  // 内距必须换成它——setViewportInsets 是替换式，留着 dock 的值会把键盘 inset
  // 盖掉，页内固定底栏（评论输入条等）会跑到键盘后面被遮。
  @StorageLink('auraKeyboardVp') @Watch('onKeyboardVpChanged') keyboardVpForInset: number = 0;
  // 桌面 chrome 自报的总高（vp）：DesktopBrowserChrome 挂载、收起页内查找条、
  // 安全区变化时更新；@Watch 把新 inset 下发给引擎（sendBrowserControls 的
  // top），让网页视口始终精确落在工具栏之下。
  @StorageLink('auraDesktopChromeInset') @Watch('onDesktopChromeInsetChanged')
  private desktopChromeInset: number = 0;
  @StorageLink('auraThemeFontId') themeFontId: string = '';
  @StorageLink('auraThemeFontRevision') themeFontRevision: number = 0;
  @StorageLink('auraOnboardingReady') onboardingReady: boolean = false;
  @StorageLink('auraOnboardingComplete') onboardingComplete: boolean = false;
  @StorageLink('auraProfileId') profileId: string = 'local';
  @StorageLink('auraProfileKind') profileKind: string = 'local';
  @StorageLink('auraSyncMode') syncMode: string = 'off';
  // 无痕会话：EntryAbility 从启动 want 里读出来（进/出无痕都靠重启应用，见
  // utils/IncognitoSwitch.ets）。置位时 WebWindow 挂到 incognito 这个
  // profile 上，用的是一整套独立的用户数据目录。
  @StorageLink('auraIncognito') incognito: boolean = false;
  // v8a diagnostic: the last ArkTS-level crash (written by EntryAbility's
  // crash recorder). Non-empty switches the shell into the crash report
  // page, which keeps the normal UI off the screen so a crash loop can be
  // read and copied out instead of repeated.
  @State private crashReport: string = '';
  @State private browserState: BrowserStateSnapshot = EMPTY_BROWSER_STATE;
  // 从主页（快捷方式/搜索框）发起导航后，把主页浮层按住到新页面真正画出来：
  // URL 一离开 chrome://newtab 就撤浮层的话，会露出垫在下面的引擎原生新
  // 标签页（白底磁贴，实测会闪一下）。loading true->false 即加载完成；
  // 回到主页立即放手；8 秒超时兜底（页面卡死时不再捂着主页）。
  @State private homeHold: boolean = false;
  private homeHoldSawLoading: boolean = false;
  private homeHoldTimer: number = -1;
  // 兜底定时器的续命次数（加载中不撤防，见 holdHomeForPaint 注释）。
  private homeHoldExtensions: number = 0;
  // 「秒开页」的快速撤防确认（见 onBrowserState 的 homeHold 分支）。
  private homeHoldQuickTimer: number = -1;
  // 从主页点书签/磁贴后等渲染器上帧的首帧宽限，避免 loading=false 立刻撤防
  // 露出引擎历史里那张原生 NTP 磁贴页。
  private homeHoldGraceTimer: number = -1;
  // 离开主页后的 120ms 内顶栏仍按主页态画，与主页 180ms 淡出对齐。
  // homeExitInkTimer 负责同一时刻把状态栏图标色交回主题色。
  @State private homeExitHold: boolean = false;
  private homeExitHoldTimer: number = -1;
  private homeExitInkTimer: number = -1;
  @State private homeReturnCover: boolean = false;
  // 「回主页又弹回原网页」的自愈重试：兜底撤防时若引擎还没把 tab 带回新标签
  // 页，重发一次 home。只重试一次，防引擎真不可用时永久捂住主页层。
  private homeRetryDone: boolean = false;
  private homeReturnTimer: number = -1;
  @State private navCover: boolean = false;
  private navCoverTimer: number = -1;
  // 起防那一刻的 url：只有 url 离开了它，才算新页面已切换过来（主页键从某个
  // 网页跳自定义主页时，起防瞬间 url 本来就不是 newtab，必须靠这个判据）。
  private navCoverFromUrl: string = '';
  private navCoverFromTabIndex: number = -1;
  // 要去的那个网址：url 直接等于它也算到了（原地按主页键重载时 url 不变，
  // 只靠「离开 fromUrl」会一直挂到兜底，白盖 1.6s）。
  private navCoverTargetUrl: string = '';
  // navCover 期间是否见过 loading（= 目标页确实在加载，等它结束才
  // 算画出来）。与 homeHoldSawLoading 同一套判据。
  private navCoverSawLoading: boolean = false;
  // 首帧宽限定器——url 已切到目标却没报过 loading 时，等一小会儿
  // 让渲染器上帧再撤防（见 onBrowserState 的 navCover 分支）。
  private navCoverGraceTimer: number = -1;
  // 兜底续命次数（仍在加载时不撤防，见 armNavCover 注释）。
  private navCoverExtensions: number = 0;
  // 历史导航的遮盖只顶住主页层撤掉到引擎旧帧接管这一小段。
  // 不按 loading 续命：长连接页面会持续报 loading。
  private navCoverHistoryNav: boolean = false;
  private navCoverQuick: boolean = false;
  // 遮盖淡出时长：历史导航用短淡出，普通导航用较长值。
  private navCoverFadeMs: number = 200;
  // 统一的「离开主页 / 切到未加载标签」过渡态：命令侧判定入口、
  // 状态回包侧判定落地，过渡期铺与外壳同色的底。
  // 与 navCover 互斥，避免双重定时。
  @State private homeTransition: boolean = false;
  private homeTransitionTimer: number = -1;
  private homeTransitionGraceTimer: number = -1;
  private homeTransitionFromUrl: string = '';
  private homeTransitionFromTabIndex: number = -1;
  // 切到需重新加载的标签时，撤防要等引擎报加载结束；瞬时切换不等。
  private homeTransitionWaitsLoading: boolean = false;
  // 从主页出发的历史导航：目标页还在加载时遮盖续命的次数，封顶防卡死。
  private homeTransitionExtensions: number = 0;
  // 主页键（自定义网址主页）导航落地后主动收一次输入法。
  // 很多站点的搜索框带 autofocus（cn.bing.com 的 sb_form_q 就是
  // `type="search" ... autofocus`），页面一提交就自己抢焦点、把键盘顶起来
  // —— 用户只是按了个主页键，却被塞了一个键盘。这是网页自身行为，外壳挡
  // 不住它聚焦，只能在导航落地后把键盘收回去。
  // 时机复用 navCover 的落地判据（首帧宽限结束 = 新页真画出来了），不另起
  // 一套定时器，免得两处判据漂移。
  private navCoverHideIme: boolean = false;
  private imeHideTimers: number[] = [];
  // 回主页后补发「控件全展开」的延时定时器（见 restoreTopControlsForHome）。
  private homeControlsTimer: number = -1;
  // 引擎原生新标签页落地的**标题**（中文包是「新建标签页」）。导航失败时引擎
  // 画面上停着它、而 state.url 报的是失败的待定地址，只能靠标题认人
  // （见 isNewTabPage）。
  private newTabTitleSeen: string = '';
  @StorageLink('auraBrowserCommandText') browserCommandText: string = '';
  @StorageLink('auraBrowserCommandRevision') browserCommandRevision: number = 0;
  // 独立通道：配色命令不与刷新系统状态的 browserCommand 通道共用，避免紧邻下发
  // 互相覆盖。本组件是 @Component（V1），持有 @StorageLink 后经 @Param 传给
  // @ComponentV2 的 WebWindow。
  @StorageLink('auraColorSchemeCommandText') colorSchemeCmdText: string = '';
  @StorageLink('auraColorSchemeCommandRevision') colorSchemeCmdRev: number = 0;
  @State private auxiliaryWindows: AuxiliaryWindowView[] = [];
  @State private screenSizeVp: ScreenSizeVp = { width: 0, height: 0 };
  @State private activeAuxiliaryWidget: number = 0;
  @State private auxiliaryDismissWidget: number = 0;
  @State private auxiliaryDismissRevision: number = 0;
  private readonly currentTabCastSession: CurrentTabCastSession = new CurrentTabCastSession();
  private readonly knockShareSession: HuaweiKnockShareSession = new HuaweiKnockShareSession();
  private launchingPwaWidgets: number[] = [];
  // One-shot: the tabs saved on the way into incognito come back once.
  private savedTabsChecked: boolean = false;

  aboutToAppear(): void {
    // 按页顶栏常显档是会话内的临时状态，冷启动一律从「未钉住」起。
    AppStorage.setOrCreate('auraTopBarPinnedForPage', false);
    this.startKnockShare();
    this.useSystemDownloadDirectory();
    this.readCrashReport();
    // @StorageLink 初值不触发 @Watch：冷启动必须补发一次强制深色 pref，
    // 否则首个页面会一直用引擎默认值（浅色）直到用户手动切一次主题。
    // 这一条常因命令通道尚未接上被引擎吞掉，所以再挂一轮带回执的延时补发。
    // @StorageLink 初值不触发 @Watch：冷启动手动补一次（内部会武装带回执的
    // 延时补发），否则首个页面会一直用引擎落盘的旧配色直到手动切一次主题。
    this.onForceDarkSyncStateChanged();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context) {
      // 同步读：首帧就把徽标设成上次退出时的标签数，恢复会话期间不再跳动。
      this.savedTabCountContext = context;
      const tabCountSeed: number = ShellUiPrefs.loadLastTabCountSync(context);
      this.tabBadgeHold = tabCountSeed;
      this.lastSavedTabCount = tabCountSeed;
      ShellUiPrefs.loadHideStatusBar(context).then((value: boolean): void => {
        AppStorage.setOrCreate('auraHideStatusBarOnScroll', value);
      });
      ShellUiPrefs.loadHideTopBar(context).then((value: boolean): void => {
        AppStorage.setOrCreate('auraHideTopBarOnScroll', value);
      });
      ShellUiPrefs.loadHideDock(context).then((value: boolean): void => {
        AppStorage.setOrCreate('auraHideDockOnScroll', value);
      });
      ShellUiPrefs.loadExternalAppLinks(context).then((value: boolean): void => {
        AppStorage.setOrCreate('auraExternalAppLinks', value);
      });
      ShellUiPrefs.loadHomeStyle(context).then((value: string): void => {
        AppStorage.setOrCreate('auraHomeStyle', value);
      });
      ShellUiPrefs.loadDockPosition(context).then((value: string): void => {
        AppStorage.setOrCreate('auraDockPosition', value);
      });
      // 「网址主页」：自定义主页网址（空 = 内置新标签页）。
      ShellUiPrefs.loadHomeUrl(context).then((value: string): void => {
        AppStorage.setOrCreate('auraHomeUrl', value);
      });
      // 「启动页」：冷启动默认打开网址主页还是内置启动页。
      ShellUiPrefs.loadStartupPage(context).then((value: string): void => {
        AppStorage.setOrCreate('auraStartupPage', value);
      });
      // 「自定义网址」：多组网址列表（设置面板显示条数/勾选项用）。
      ShellUiPrefs.loadHomeUrls(context).then((list: string[]): void => {
        AppStorage.setOrCreate('auraHomeUrls', ShellUiPrefs.joinUrlList(list));
        if (AppStorage.get('auraHomeUrl') === '' && list.length > 0) {
          AppStorage.setOrCreate('auraHomeUrl', list[0]);
        }
      });
      // 「桌面版网站」站点名单与全局 UA 默认：启动期灌入 AppStorage，
      // 供 WebWindow 在导航前推导桌面 UA、设置面板展示/管理。
      ShellUiPrefs.loadDesktopSites(context).then((list: string[]): void => {
        AppStorage.setOrCreate('auraDesktopSites', ShellUiPrefs.joinUrlList(list));
      });
      // 单站「回到移动版」例外名单：与桌面站名单同路持久化，启动期灌进 AppStorage，
      // 供 WebWindow 导航前推导 UA、菜单切换时增删。
      ShellUiPrefs.loadMobileSites(context).then((list: string[]): void => {
        AppStorage.setOrCreate('auraMobileSites', ShellUiPrefs.joinUrlList(list));
      });
      ShellUiPrefs.loadUaDefault(context).then((value: string): void => {
        AppStorage.setOrCreate('auraUaDefault', value);
      });
    }
    // 冷启动预热（见 navCover 注释）。
    this.armNavCover(this.startUrl ?? '');
  }

  // 要跳去某个真网址（冷启动的网址主页 / 主页键的自定义主页）→ 起防，
  // 铺一层同色底顶住，等目标页首帧提交再淡出。
  private armNavCover(target: string, quick: boolean = false): void {
    if (target.length === 0 || isNewTabUrl(target)) {
      this.navCover = false;
      this.navCoverQuick = false;
      return;
    }
    this.navCover = true;
    this.navCoverSawLoading = false;
    this.navCoverExtensions = 0;
    this.navCoverHistoryNav = false;
    this.navCoverQuick = quick;
    this.navCoverFadeMs = quick ? 100 : 200;
    this.navCoverHideIme = false;
    // 记下起防时的 url：撤防判据是「url 离开了它」，而不是「url 不是 newtab」
    // —— 从网页按主页键时，起防那一刻 url 本来就不是 newtab，用后者会立刻撤防。
    this.navCoverFromUrl = this.browserState.url ?? '';
    this.navCoverTargetUrl = target;
    this.navCoverFromTabIndex = this.browserState.activeTabIndex ?? -1;
    this.armNavCoverTimer(quick ? 500 : 1600);
  }

  // 前进/后退的遮盖只顶「落点是主页」那一次：引擎会先画自己的原生 NTP
  //（满屏磁贴），而壳层主页层要等 url 变成 newtab 才挂，中间会露磁贴。
  // 网页 ↔ 网页不需要盖：换页空档由引擎侧 gutter 色与 paint-hold 处理。
  // 遮盖必须短：不按 loading 续命，固定硬上限 + 短淡出。
  private armNavCoverForHistoryNav(targetUrl: string): void {
    if (!HISTORY_NAV_COVER_HOME_ONLY || !isNewTabUrl(targetUrl)) {
      return;
    }
    this.navCover = true;
    this.navCoverSawLoading = false;
    this.navCoverExtensions = 0;
    this.navCoverHistoryNav = true;
    this.navCoverQuick = false;
    this.navCoverFadeMs = 60;
    this.navCoverHideIme = false;
    this.navCoverFromUrl = this.browserState.url ?? '';
    this.navCoverTargetUrl = '';
    this.navCoverFromTabIndex = this.browserState.activeTabIndex ?? -1;
    // 回主页这一侧：引擎 commit 原生 NTP 到状态快照回来要 20~70ms，旧值
    // 250ms 上限实测只留下约 100ms 有效遮盖，抖动时会漏 1 帧磁贴。放宽到
    // 400ms；主页层一挂上 NavCoverView 就不再铺，延长不会带来白屏副作用。
    this.armNavCoverTimer(400);
  }

  // 过渡态：铺同色底盖住 commit 到首帧的空窗。已有显式遮盖时不重复起。
  // 不按 loading 续命，固定硬上限，落地后由首帧宽限提前收口。
  private beginHomeTransition(waitsLoading: boolean = false): void {
    if (!this.isMobilePhoneUi() || this.navCover || this.homeTransition) {
      return;
    }
    this.homeTransition = true;
    this.homeTransitionWaitsLoading = waitsLoading;
    this.homeTransitionExtensions = 0;
    this.homeTransitionFromUrl = this.browserState.url ?? '';
    this.homeTransitionFromTabIndex = this.browserState.activeTabIndex ?? -1;
    this.navCoverFadeMs = 100;
    if (this.homeTransitionGraceTimer >= 0) {
      clearTimeout(this.homeTransitionGraceTimer);
      this.homeTransitionGraceTimer = -1;
    }
    this.armHomeTransitionTimer(waitsLoading ? 300 : 250);
  }

  // 从主页前进/后退到网页时，url 一变就撤会露出引擎上一帧（原生 NTP 磁贴）：
  // 历史里主页那条就是引擎自带的新标签页。目标页还在加载就续命，封顶 8 次
  // 防引擎卡死时永远盖着；loading=false 由状态回调的落地判据提前收口。
  private armHomeTransitionTimer(ms: number): void {
    if (this.homeTransitionTimer >= 0) {
      clearTimeout(this.homeTransitionTimer);
    }
    this.homeTransitionTimer = setTimeout((): void => {
      this.homeTransitionTimer = -1;
      if (!this.homeTransition) {
        return;
      }
      if (this.homeTransitionWaitsLoading && this.browserState.loading &&
          this.homeTransitionExtensions < 8) {
        this.homeTransitionExtensions += 1;
        this.armHomeTransitionTimer(600);
        return;
      }
      this.releaseHomeTransition();
    }, ms);
  }

  // 落地后不立刻撤：loading=false 只代表提交完成，渲染器未必已上帧，此时撤防
  // 露出的正是引擎底板。补一小段首帧宽限，复用历史导航那套已验证的判据。
  private scheduleHomeTransitionRelease(): void {
    if (!this.homeTransition || this.homeTransitionGraceTimer >= 0) {
      return;
    }
    if (this.homeTransitionWaitsLoading && this.browserState.loading) {
      return;
    }
    this.homeTransitionGraceTimer = setTimeout((): void => {
      this.homeTransitionGraceTimer = -1;
      this.releaseHomeTransition();
    }, 120);
  }

  private releaseHomeTransition(): void {
    // 同 releaseNavCover：落到主页时不要白纱淡出（主页自带放大进场）。
    if (this.isNewTabPage()) {
      this.navCoverFadeMs = 0;
    }
    this.homeTransition = false;
    this.homeTransitionWaitsLoading = false;
    this.homeTransitionExtensions = 0;
    if (this.homeTransitionTimer >= 0) {
      clearTimeout(this.homeTransitionTimer);
      this.homeTransitionTimer = -1;
    }
    if (this.homeTransitionGraceTimer >= 0) {
      clearTimeout(this.homeTransitionGraceTimer);
      this.homeTransitionGraceTimer = -1;
    }
  }

  // 打开「已休眠」标签专用遮盖：与 homeTransition 物理隔离，不影响前进/后退。
  // 参与 build() 的渲染条件（DiscardedCoverView），必须是响应式状态：
  // 普通字段变化不触发重渲染，release 后全屏遮盖会残留到下一次状态刷新。
  @State private discardedCover: boolean = false;
  private discardedCoverIndex: number = -1;
  private discardedCoverSawLoading: boolean = false;
  private discardedCoverTimer: number = -1;
  private discardedCoverGraceTimer: number = -1;

  private beginDiscardedCover(command: BrowserCommandPayload, discarded: boolean): void {
    if (!this.isMobilePhoneUi() || this.discardedCover || !discarded) {
      return;
    }
    this.discardedCover = true;
    this.discardedCoverIndex = command.index ?? -1;
    this.discardedCoverSawLoading = false;
    if (this.discardedCoverGraceTimer >= 0) {
      clearTimeout(this.discardedCoverGraceTimer);
      this.discardedCoverGraceTimer = -1;
    }
    if (this.discardedCoverTimer >= 0) {
      clearTimeout(this.discardedCoverTimer);
    }
    this.discardedCoverTimer = setTimeout((): void => {
      this.discardedCoverTimer = -1;
      this.releaseDiscardedCover();
    }, 13000);
  }

  private releaseDiscardedCover(): void {
    this.discardedCover = false;
    this.discardedCoverIndex = -1;
    this.discardedCoverSawLoading = false;
    if (this.discardedCoverTimer >= 0) {
      clearTimeout(this.discardedCoverTimer);
      this.discardedCoverTimer = -1;
    }
    if (this.discardedCoverGraceTimer >= 0) {
      clearTimeout(this.discardedCoverGraceTimer);
      this.discardedCoverGraceTimer = -1;
    }
  }

  // 冷重载网络慢、首帧更晚，给足宽限；见 loading 结束后才撤，正好遮住深色空窗。
  private scheduleDiscardedCoverRelease(): void {
    if (!this.discardedCover || this.discardedCoverGraceTimer >= 0) {
      return;
    }
    this.discardedCoverGraceTimer = setTimeout((): void => {
      this.discardedCoverGraceTimer = -1;
      this.releaseDiscardedCover();
    }, 300);
  }

  // 只在两类命令下起过渡态：当前在主页且要离开主页、或切到已休眠标签。
  // 普通标签切换是瞬时切帧，不铺底。
  // home 不在此列：引擎对已在 newtab 的标签是空操作，url 不变会让
  // leftOrigin 判据永不命中；回主页由 homeReturnCover 兜底，
  // 自定义网址主页会转成 navigate 并走 armNavCover。
  private maybeBeginHomeTransition(command: BrowserCommandPayload): void {
    if (this.homeHold || this.homeReturnCover) {
      return;
    }
    const name: string = command.command;
    if (name !== 'navigate' && name !== 'activateTab' && name !== 'back' &&
      name !== 'forward') {
      return;
    }
    if (name === 'activateTab') {
      const tabs: BrowserTabState[] = this.browserState.tabs ?? [];
      const requestedIndex: number = command.index ?? -1;
      const requestedId: string = String(command.id ?? '');
      let hit: boolean = false;
      let discarded: boolean = false;
      tabs.forEach((tab: BrowserTabState): void => {
        const tabId: string = String(tab.id ?? '');
        if ((requestedId.length > 0 && tabId === requestedId) ||
          (requestedIndex >= 0 && tab.index === requestedIndex)) {
          hit = true;
          discarded = tab.discarded === true;
        }
      });
      const fromHome: boolean = this.isNewTabPage();
      // 快照没找到目标标签时无法判断是否要重载，按需要遮盖处理。
      const needCover: boolean = discarded || fromHome || !hit;
      if (needCover) {
        if (discarded) {
          this.beginDiscardedCover(command, discarded);
        } else {
          this.beginHomeTransition(discarded);
        }
      }
      return;
    }
    if (this.isNewTabPage()) {
      // 从主页前进/后退到网页：等新页首帧再撤遮盖，别露出历史里那张原生磁贴页。
      this.beginHomeTransition(name === 'back' || name === 'forward');
    }
  }

  private armNavCoverTimer(ms: number): void {
    if (this.navCoverTimer >= 0) {
      clearTimeout(this.navCoverTimer);
    }
    this.navCoverTimer = setTimeout((): void => {
      this.navCoverTimer = -1;
      if (!this.navCover) {
        return;
      }
      // 历史导航到期直接撤防，不按 loading 续命。
      if (this.navCoverHistoryNav || this.navCoverQuick) {
        this.releaseNavCover();
        return;
      }
      // 仍在加载就续命：github 这类连不上的站点要 20s+ 才 commit，固定撤防会把
      // 引擎底板露出好几秒。封顶 8 次（≈14s）防引擎卡死时永远盖着。
      if (this.browserState.loading && this.navCoverExtensions < 8) {
        this.navCoverExtensions += 1;
        this.armNavCoverTimer(1600);
        return;
      }
      this.releaseNavCover();
    }, ms);
  }

  private releaseNavCover(): void {
    if (!this.navCover) {
      return;
    }
    // 落到主页时不铺白纱淡出（主页自带放大进场），两条返回路径观感才一致；
    // 网页之间的过渡仍保留淡出。
    if (this.isNewTabPage()) {
      this.navCoverFadeMs = 0;
    }
    this.navCover = false;
    this.navCoverSawLoading = false;
    this.navCoverHistoryNav = false;
    this.navCoverQuick = false;
    if (this.navCoverTimer >= 0) {
      clearTimeout(this.navCoverTimer);
      this.navCoverTimer = -1;
    }
    if (this.navCoverGraceTimer >= 0) {
      clearTimeout(this.navCoverGraceTimer);
      this.navCoverGraceTimer = -1;
    }
    // 主页键导航落地即收键盘（见 navCoverHideIme 注释）。
    if (this.navCoverHideIme) {
      this.navCoverHideIme = false;
      this.hideImeAfterHomeNav();
    }
  }

  private hideImeAfterHomeNav(): void {
    [0, 180, 420].forEach((delay: number): void => {
      this.imeHideTimers.push(setTimeout((): void => {
        if (this.addressEditing) {
          this.clearImeHideTimers();
          return;
        }
        try {
          inputMethod.getController().hideTextInput().catch((): void => {});
        } catch (error) {
        }
      }, delay));
    });
  }

  private clearImeHideTimers(): void {
    this.imeHideTimers.forEach((timer: number): void => clearTimeout(timer));
    this.imeHideTimers = [];
  }

  // 落地后不立刻撤防，再留一小段首帧宽限，避免撤在首帧之前露出引擎底板。
  // 幂等；历史导航用短宽限，不按 loading 续期。
  private armNavCoverGrace(): void {
    if (this.navCoverGraceTimer >= 0 || !this.navCover) {
      return;
    }
    // 历史导航要把主页层挂载算进去：引擎先把 url 切到 newtab，
    // 壳层下一拍才挂 HomeSurface；普通导航等首帧画稳再撤。
    // 历史导航落地后再多留一拍：等主页层真正上屏，别在 commit 与状态快照
    // 之间的缝隙撤掉同色底。
    const wait: number = this.navCoverHistoryNav ? 160 : (this.navCoverQuick ? 120 : 260);
    this.navCoverGraceTimer = setTimeout((): void => {
      this.navCoverGraceTimer = -1;
      this.releaseNavCover();
    }, wait);
  }

  private onControlsRatioMoved(): void {
    this.updateStatusBarForScroll(this.scrolledRatio);
    this.syncDockInsetForControlsMove();
    // 引擎开始产比例 = 页面真的在滚 → 把 dock 交还引擎驱动，否则触摸收起的
    // dock 会在页面恢复滚动后卡在收起位（见 onSwipeControlsTouch）。
    if (this.swipeDockTaken && !this.swipeDockDriving) {
      this.releaseSwipeDock();
    }
  }

  // 切主题后的一次性重载：多数站点只在新页面加载时才读配色（必应、百度实测
  // 都要刷一次才跟），而引擎要在新配置到达后才知道换色 —— 所以不能切完就
  // reload，要等"携带新配色的配置真正下发"这一刻（路由 revision 翻新）。
  // 这条 revision 也会被折叠/旋转/窗口变化顶起来，靠 pending 标志只认切主题
  // 那一次；标志挂空了就什么都不做。兜底在 SettingsPanel（配置没到则定时补发）。
  private onRoutingRevisionForThemeReload(): void {
    if (!this.themeReloadPending) {
      return;
    }
    AppStorage.setOrCreate('auraThemeReloadPending', false);
    this.executeBrowserCommand({ command: 'reload' });
  }

  // 把外观主题同步到 Blink 的强制深色 pref。只靠 prefers-color-scheme 无法让
  // 百度、必应这类不实现深色媒体查询的站点变暗；这个开关由引擎的 PrefWatcher
  // 立即应用到所有已打开的标签页。设置里的手动覆盖优先于自动值。
  private onForceDarkSyncStateChanged(): void {
    const forced: boolean = this.forceDarkOverride === 'on' ? true
      : this.forceDarkOverride === 'off' ? false
        : this.colorScheme === 'dark';
    const changed: boolean = this.lastForceDarkPrefSent !== forced;
    this.sendForceDarkPref();
    if (changed) {
      this.rearmForceDarkStartupSync();
    }
  }

  // 按当前覆盖态与主题现算并发一次。补发也走这里，但不再触发重挂，
  // 否则定时器回调会递归地反复武装自己。
  private sendForceDarkPref(forceSend: boolean = false): void {
    const forced: boolean = this.forceDarkOverride === 'on' ? true
      : this.forceDarkOverride === 'off' ? false
        : this.colorScheme === 'dark';
    if (!forceSend && this.lastForceDarkPrefSent === forced) {
      return;
    }
    this.lastForceDarkPrefSent = forced;
    this.executeBrowserCommand({
      command: 'setPref',
      key: 'forceDarkWebContents',
      value: forced
    });
  }

  // 命令通道尚未接上时首条会被吞掉，按 600/1200/2400ms 补发三轮；
  // 每次现算，收到引擎回执即停。
  private rearmForceDarkStartupSync(): void {
    this.clearForceDarkStartupRetryTimers();
    this.forceDarkStartupSynced = false;
    [600, 1200, 2400].forEach((delay: number): void => {
      const timer: number = setTimeout((): void => {
        if (this.forceDarkStartupSynced) {
          return;
        }
        this.sendForceDarkPref(true);
      }, delay);
      this.forceDarkStartupRetryTimers.push(timer);
    });
  }

  private clearForceDarkStartupRetryTimers(): void {
    this.forceDarkStartupRetryTimers.forEach((timer: number): void => clearTimeout(timer));
    this.forceDarkStartupRetryTimers = [];
  }

  // 主页风格变化：Chrome 风格无独立顶栏、dock 常驻，需重发浏览器控件 inset。
  private onHomeStyleChanged(): void {
    this.sendBrowserControls();
    this.applyDockViewportInset();
  }

  // dock 位置（顶/底）变化：同样重发 inset。
  private onDockPositionChanged(): void {
    this.sendBrowserControls();
    this.applyDockViewportInset();
  }

  private onHideStatusBarPrefChanged(): void {
    if (!this.hideStatusBarOnScroll) {
      this.applyStatusBarHidden(false);
      this.statusBarHiddenByScroll = false;
    } else {
      this.updateStatusBarForScroll(this.scrolledRatio);
    }
    this.sendBrowserControls();
    // 视口底部内距跟着重算（底置 dock 的底距、以及页尾死角都与收起终点相关，
    // 直接重算重发，不走带滞回的 syncDockInsetForControlsMove）。
    this.applyDockViewportInset();
  }

  // “滚动时隐藏地址栏”开关变化：重发浏览器控件高度（minTop = 全高即常显），
  // 并立即把顶栏动画展开/交还给滚动。
  private onHideTopBarPrefChanged(): void {
    this.sendBrowserControls();
    // 切档前先把 dock 交还引擎，避免触摸值压着比例（见 releaseSwipeDock）。
    if (this.swipeDockTaken) {
      this.releaseSwipeDock();
    }
    if (!this.isTopBarCollapsing()) {
      // 刚切入「地址栏常驻」：dock 的触摸驱动从当前可见度续上，避免跳变。
      const seeded: number = Math.min(Math.max(this.scrolledRatio, 0), 1);
      this.touchDockHidden = (1 - seeded) * Math.max(1,
        dockCoveredHeightVp(Number(AppStorage.get('auraBottomSafeVp') ?? 0)));
      this.setTouchDockRatio(seeded);
    }
    // 必须**直接重发**，不能只交给 syncDockInsetForControlsMove()：那条路只在
    // 「完全收起」标志翻转时才发，而 Chrome 底置档的 computeTopBarHiddenForInset()
    // 恒返回 false（见上），标志永远不翻转 —— 于是这个开关改了、applyDockViewportInset
    // 里读它的分支（底置 dockCover、顶置 topBarPushVp）却全按旧值算，页面内距不更新。
    // 用户实测：Chrome 底置 + 地址栏固定（本开关关着）时页面没抬高，就是这条。
    this.topBarHiddenForInset = this.computeTopBarHiddenForInset();
    this.applyDockViewportInset();
  }

  // 「有效」隐藏开关：页面被钉住时取 false，与设置里手动关开关完全同档。
  // 几何、内距、触摸驱动一律读这里，不允许直接读 hideTopBarOnScroll，
  // 否则就会出现「引擎以为常显、外壳仍按可收起」的混合态。
  private isTopBarCollapsing(): boolean {
    return this.hideTopBarOnScroll && !this.topBarPinnedForPage;
  }

  // 只对必应自家域名的首页/结果页返回 true（host 为 bing.com 或 *.bing.com，
  // 路径 / /search /index.html）。理由见 probeOnBingCover 注释。
  private isBingCoverPage(url: string): boolean {
    const lower: string = url.toLowerCase();
    const schemeAt: number = lower.indexOf('://');
    if (schemeAt < 0) {
      return false;
    }
    const afterScheme: string = lower.substring(schemeAt + 3);
    const slashAt: number = afterScheme.indexOf('/');
    let host: string = slashAt < 0 ? afterScheme : afterScheme.substring(0, slashAt);
    const at: number = host.indexOf('@');
    if (at >= 0) {
      host = host.substring(at + 1);
    }
    const portAt: number = host.indexOf(':');
    if (portAt >= 0) {
      host = host.substring(0, portAt);
    }
    if (host !== 'bing.com' && !(host.length > 5 && host.endsWith('.bing.com'))) {
      return false;
    }
    const pathPart: string = slashAt < 0 ? '/' : afterScheme.substring(slashAt);
    let end: number = pathPart.length;
    const queryAt: number = pathPart.indexOf('?');
    if (queryAt >= 0 && queryAt < end) {
      end = queryAt;
    }
    const hashAt: number = pathPart.indexOf('#');
    if (hashAt >= 0 && hashAt < end) {
      end = hashAt;
    }
    const pathname: string = pathPart.substring(0, end);
    return pathname === '/' || pathname === '/search' || pathname === '/index.html';
  }

  // 钉住状态翻转 = 手动切了一次设置开关：browser controls、dock 交还、
  // 收起标志、视口内距整套重算。少算任何一项，页面底部都会少让出顶栏高度。
  private onPageTopBarPinChanged(): void {
    this.onHideTopBarPrefChanged();
  }

  // 页面位置探针回报：只在「滚不动」的页面上把顶栏切到常显档。同一页内只许
  // 钉住、不许放开 —— 页面高度在加载/滚动中会变，反复重发控件会让页面瞬移；
  // 换页（url / 标签变化）由状态快照回调解除。
  private updatePageTopBarPin(url: string, scrollable: number, scrollY: number): void {
    // 每次探针都刷新封面页判定位：换页即翻转，不依赖 pin 档变化触发，
    // 以避免上一页的判定位残留到新页面。
    const bingCover: boolean = this.isBingCoverPage(url);
    if (bingCover !== this.probeOnBingCover) {
      this.probeOnBingCover = bingCover;
      this.applyDockViewportInset();
    }
    // 必应封面页禁止钉住：钉住会把补偿档从 topSafe 翻到 84+topSafe，整张
    // fixed 背景图（.img_cont / background-size:cover）缩一圈。保持设置档恒定，
    // 补偿按 154/155 常量照发 —— 图片不跳，页脚最后一行也不会被裁。
    if (bingCover) {
      if (this.topBarPinnedForPage) {
        this.topBarPinnedUrl = '';
        this.topBarPinnedForPage = false;
      }
      return;
    }
    // 新标签页本来就没有可滚动内容，会被探针报成「滚不动」；钉住顶栏
    // 会把它带进网页态几何，主页底部处理就变了。
    if (this.isNewTabPage() || isNewTabUrl(url)) {
      if (this.topBarPinnedForPage) {
        this.topBarPinnedForPage = false;
      }
      return;
    }
    // 只采信页面停在顶部时的读数：顶栏收起会改变 innerHeight，滚动停下时
    // 量到的文档余量偏小，会把知乎这类正常页面误判成「滚不动」。
    const pin: boolean = scrollable === 0 && scrollY === 0;
    const samePage: boolean = url.length > 0 && url === this.topBarPinnedUrl;
    if (samePage && this.topBarPinnedForPage && !pin) {
      return;
    }
    if (url.length > 0) {
      this.topBarPinnedUrl = url;
    }
    if (this.topBarPinnedForPage === pin) {
      return;
    }
    // @Watch 负责把整套几何重算一遍（等价于手动切开关）。
    this.topBarPinnedForPage = pin;
  }

  // 把顶栏的 browser controls（高度 + 收起许可）发给引擎：启动、设置开关
  // 切换、启动后的兜底重发共用这一份。
  private sendBrowserControls(): void {
    if (this.pageFullscreen) {
      this.executeBrowserCommand({
        command: 'setBrowserControls',
        top: 0,
        minTop: 0,
        bottom: 0
      });
      this.executeBrowserCommand({
        command: 'setBrowserControlsState',
        state: 'hidden',
        animate: false
      });
      return;
    }
    if (!this.isMobilePhoneUi()) {
      // 平板/桌面 chrome：常驻、不随滚动收起。top 把网页视口压到工具栏之下，
      // chrome 自己叠在同区自绘（DesktopBrowserChrome 把实际高度写进
      // auraDesktopChromeInset，含状态栏余量与可选的页内查找条）。
      const top: number = Number(AppStorage.get('auraDesktopChromeInset') ?? 0);
      this.executeBrowserCommand({
        command: 'setBrowserControls',
        top: top,
        minTop: top,
        bottom: 0
      });
      this.executeBrowserCommand({
        command: 'setBrowserControlsState',
        state: 'shown',
        animate: false
      });
      return;
    }
    const topSafe = Number(AppStorage.get('auraTopSafeVp') ?? 0);
    if (this.homeStyle === 'chrome') {
      if (this.dockPosition === 'top') {
        const top = CHROME_DOCK_EXTENT_VP + topSafe;
        const collapsing: boolean = this.isTopBarCollapsing();
        // 同简约分支——「上滑时隐藏状态栏」关着时收起下限=topSafe，
        // 收起后网页停在状态栏底（那一条由外壳常驻垫底显示页面底色）。
        this.executeBrowserCommand({
          command: 'setBrowserControls',
          top: top,
          minTop: collapsing ? (this.hideStatusBarOnScroll ? 0 : topSafe) : top,
          bottom: 0
        });
        this.executeBrowserCommand({
          command: 'setBrowserControlsState',
          state: collapsing ? 'both' : 'shown',
          animate: true
        });
      } else {
        const bottomCollapsing: boolean = this.hideStatusBarOnScroll;
        this.executeBrowserCommand({
          command: 'setBrowserControls',
          top: topSafe,
          minTop: bottomCollapsing ? 0 : topSafe,
          bottom: 0
        });
        this.executeBrowserCommand({
          command: 'setBrowserControlsState',
          state: bottomCollapsing ? 'both' : 'shown',
          animate: true
        });
      }
      return;
    }
    const top = TOP_BAR_EXTENT_VP + topSafe;
    const collapsing: boolean = this.isTopBarCollapsing();
    const immersive: boolean = this.hideStatusBarOnScroll;
    const minTop: number = collapsing ? (immersive ? 0 : topSafe) : top;
    this.executeBrowserCommand({
      command: 'setBrowserControls',
      top: top,
      minTop: minTop,
      bottom: 0
    });
    this.executeBrowserCommand({
      command: 'setBrowserControlsState',
      state: collapsing ? 'both' : 'shown',
      animate: true
    });
  }

  // 进入主页时把顶栏强制展开。
  // 根因（用户实测「偶尔通过后退回到主页时，主页不显示工具栏」）：从网页后退
  // 回 chrome://newtab 时，引擎的 browser controls 可能仍停在收起态
  // （ratio 0）；而新标签页没有可滚动内容，引擎不会自己把它放回来 —— 顶栏与
  // dock 就一直停在收起位置。这里在 url 落到新标签页的那一帧显式要求 shown，
  // 并把外壳的 ratio 复位（顶栏位移 + 状态栏恢复都挂在它上面）。
  private restoreTopControlsForHome(): void {
    this.executeBrowserCommand({
      command: 'setBrowserControlsState',
      state: 'shown',
      animate: true
    });
    this.lastControlsRatio = 1;
    AppStorage.setOrCreate('auraBrowserControlsRatio', 1);
    // chrome 风格的 dock 位移挂触摸键，主页回归一并复位，避免上次在
    // 网页里上滑隐藏后回到主页 dock 不回来。
    AppStorage.setOrCreate('auraChromeBottomRatio', 1);
    if (this.homeControlsTimer !== -1) {
      clearTimeout(this.homeControlsTimer);
    }
    this.homeControlsTimer = setTimeout((): void => {
      this.homeControlsTimer = -1;
      this.executeBrowserCommand({
        command: 'setBrowserControlsState',
        state: 'shown',
        animate: true
      });
      this.lastControlsRatio = 1;
      AppStorage.setOrCreate('auraBrowserControlsRatio', 1);
      AppStorage.setOrCreate('auraChromeBottomRatio', 1);
    }, 260);
  }

  // “滚动时隐藏底部栏”开关变化：dock 常驻时把它永久盖住的高度报给引擎，
  // 页面末尾才能滚到它上方；随滚动收起时还原为 0。
  private onHideDockPrefChanged(): void {
    // 关掉「滚动时隐藏底部栏」后 dock 常驻，触摸值不再有意义，先交还引擎。
    if (!this.hideDockOnScroll && this.swipeDockTaken) {
      this.releaseSwipeDock();
    }
    this.applyDockViewportInset();
  }

  // 键盘避让高度变化：弹起/收起都要重发底部内距（弹起换成键盘高，收起回到 dock）。
  private onKeyboardVpChanged(): void {
    this.applyDockViewportInset();
  }

  private onDesktopChromeInsetChanged(): void {
    // 无条件重发：桌面挂载时下发新的 top；退回手机时该键被清零，重发走回
    // 手机分支的几何（同值重发幂等，引擎按值去重）。
    this.sendBrowserControls();
    this.applyDockViewportInset();
  }

  private lastTopPushSent: number = -1;

  private topBarPushVp(): number {
    const topSafe = Number(AppStorage.get('auraTopSafeVp') ?? 0);
    if (topSafe <= 0) {
      return 0;
    }
    if (this.homeStyle === 'chrome' && this.dockPosition === 'bottom') {
      return this.hideStatusBarOnScroll ? 0 : topSafe;   // 底置沿用 1.0.111 的常量
    }
    // 常显档必须补 TOP_BAR_EXTENT_VP+topSafe：minTop 让 renderer 视口底部恒少这一截，
    // 补偿须为常量；按滚动比例动态下发会导致视口频繁 resize 与页面跳动。
    // 必应封面页的整图缩放单独在探针里禁止钉住解决，此处不可扣减补偿，
    // 否则页脚最后一行会被裁切（真机反馈：必应页面最下边少一行字）。
    if (!this.isTopBarCollapsing()) {
      return TOP_BAR_EXTENT_VP + topSafe;
    }
    return this.hideStatusBarOnScroll ? 0 : topSafe;
  }

  private applyDockViewportInset(): void {
    if (this.pageFullscreen) {
      // 网页全屏：底部也不留任何内距，视口就是整屏。
      this.lastTopPushSent = 0;
      this.executeBrowserCommand({
        command: 'setViewportInsets',
        bottom: 0
      });
      return;
    }
    const bottomSafe = Number(AppStorage.get('auraBottomSafeVp') ?? 0);
    const topSafe = Number(AppStorage.get('auraTopSafeVp') ?? 0);
    if (!this.isMobilePhoneUi()) {
      // 桌面 chrome 没有底部 dock；键盘弹起时底部内距仍要按键盘高让位。
      const desktopKeyboardVp: number = Number(AppStorage.get('auraKeyboardVp') ?? 0);
      this.lastTopPushSent = 0;
      this.executeBrowserCommand({
        command: 'setViewportInsets',
        bottom: desktopKeyboardVp > 0 ? desktopKeyboardVp + KEYBOARD_INSET_EXTRA_VP : 0
      });
      return;
    }
    // 与 ratio 事件同步一次标志（幂等）：设置类变更路径直接调用本函数时，
    // 也把标志刷新到当前模式。
    this.topBarHiddenForInset = this.computeTopBarHiddenForInset();
    let bottom: number;
    if (this.homeStyle === 'chrome') {
      if (this.dockPosition === 'bottom') {
        const dockCover: number = this.isTopBarCollapsing() ? 0 : dockCoveredHeightVp(bottomSafe);
        bottom = dockCover + (this.hideStatusBarOnScroll ? 0 : topSafe);
      } else {
        bottom = this.topBarPushVp();
      }
    } else {
      // 简约/经典：dock 可收起（「滚动时隐藏底部栏」开）→ 页面恒铺满，dock 浮在
      // 内容之上：既没有「页面底端与 dock 之间的空档」，也没有 dock 滑走、inset
      // 归零导致的视口跳变。dock 常驻（关）→ 让出 dock 高度，否则最后一行永久被盖。
      // 备注：错误页不可滚动、dock 恒浮在页内按钮上，实测该档「重新加载」仍可点；
      // 若某些不可滚动页面出现点不到，再按 URL（chrome-error）单独让位。
      const dockAlways: number = dockCoveredHeightVp(bottomSafe);
      bottom = (this.hideDockOnScroll ? 0 : dockAlways) + this.topBarPushVp();
    }
    this.lastTopPushSent = this.topBarPushVp();
    // 键盘弹起：底部内距改用键盘高度（替换式下发，留 dock 的值会盖掉系统 inset）。
    // 避让区报的高度比「页面该留出的高度」略小（实测页内固定底栏最下面一行表情
    // 被键盘上沿切掉一半），补一条 KEYBOARD_INSET_EXTRA_VP 的余量。
    const keyboardVp: number = Number(AppStorage.get('auraKeyboardVp') ?? 0);
    if (keyboardVp > 0) {
      bottom = keyboardVp + KEYBOARD_INSET_EXTRA_VP;
    }
    this.executeBrowserCommand({
      command: 'setViewportInsets',
      bottom: bottom
    });
  }

  // 顶栏显隐态翻转时同步一次底部视口内距（幂等：只在翻转点重发）。
  private syncDockInsetForControlsMove(): void {
    const next: boolean = this.computeTopBarHiddenForInset();
    if (next !== this.topBarHiddenForInset) {
      this.topBarHiddenForInset = next;
      this.applyDockViewportInset();
    }
  }

  // 「顶栏完全收起（贴状态栏底静息）」判定，带滞回防抖。阈值与引擎对齐：
  // 引擎收起完成的判据是 renderer ratio ≤ 下限 + 0.001（见 aura_shell_runtime_bridge
  // 的 OnAuraShellTopControlsShownRatio），下限 = topSafe/(条高+topSafe)。进入取
  // 0.0005（略严于引擎，避免「视口已缩、引擎尚未 hidden」的重复扣除窗口），退出取
  // 0.001（与引擎 not-hidden 翻转点重合，防止展开瞬间多留 topSafe 露底部空档）。
  private computeTopBarHiddenForInset(): boolean {
    if (!this.isMobilePhoneUi()) {
      return false;
    }
    if (this.homeStyle === 'chrome' && this.dockPosition === 'bottom') {
      // 底置不靠这个标志（applyDockViewportInset 已直接给 topSafe）。
      return false;
    }
    if (!this.isTopBarCollapsing() || this.hideStatusBarOnScroll) {
      return false;
    }
    const topSafe = Number(AppStorage.get('auraTopSafeVp') ?? 0);
    const topVp: number = TOP_BAR_EXTENT_VP + topSafe;
    if (topSafe <= 0 || topVp <= 0) {
      return false;
    }
    const floor: number = topSafe / topVp;
    const raw: number = Number.isFinite(this.scrolledRatio) ? this.scrolledRatio : 1;
    const r: number = Math.min(Math.max(raw, 0), 1);
    if (this.topBarHiddenForInset) {
      return r < floor + 0.001;
    }
    return r <= floor + 0.0005;
  }

  // ---- 「地址栏常驻 + 滚动隐藏底栏」组合：触摸驱动的 dock ----
  // 地址栏常驻时引擎把收起比例锁死（minTop = top），dock 拿不到滚动信号；
  // dock 是纯外壳浮层，这里用页面区的触摸位移直接驱动（观察层见 build）。
  private touchDockTracking: boolean = false;
  private touchDockLastY: number = 0;
  private touchDockTravel: number = 1;
  private touchDockHidden: number = 0;
  private touchDockRatioValue: number = 1;

  private touchDockModeActive(): boolean {
    return this.isMobilePhoneUi() && !this.isTopBarCollapsing() &&
      this.hideDockOnScroll && !this.isNewTabPage();
  }

  private onDockObserverTouch(event: TouchEvent): void {
    if (!this.touchDockModeActive()) {
      return;
    }
    if (event.type === TouchType.Down) {
      const touch = event.touches.length > 0 ? event.touches[0] : undefined;
      if (touch === undefined) {
        return;
      }
      this.touchDockTracking = true;
      this.touchDockLastY = touch.y;
      this.touchDockTravel = Math.max(1,
        dockCoveredHeightVp(Number(AppStorage.get('auraBottomSafeVp') ?? 0)));
      this.touchDockHidden = (1 - this.touchDockRatioValue) * this.touchDockTravel;
      return;
    }
    if (!this.touchDockTracking) {
      return;
    }
    if (event.type === TouchType.Move) {
      const touch = event.touches.length > 0 ? event.touches[0] : undefined;
      if (touch === undefined) {
        return;
      }
      if (event.touches.length !== 1) {
        // 多指（缩放等）：不驱动 dock，只把基准跟到手。
        this.touchDockLastY = touch.y;
        return;
      }
      const dy = touch.y - this.touchDockLastY;
      this.touchDockLastY = touch.y;
      const next = Math.min(Math.max(this.touchDockHidden - dy, 0), this.touchDockTravel);
      if (Math.abs(next - this.touchDockHidden) >= 0.5) {
        this.touchDockHidden = next;
        this.setTouchDockRatio(1 - this.touchDockHidden / this.touchDockTravel);
      }
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.touchDockTracking = false;
      const settleHidden = this.touchDockHidden >= this.touchDockTravel * 0.5 ?
        this.touchDockTravel : 0;
      this.touchDockHidden = settleHidden;
      animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, (): void => {
        this.setTouchDockRatio(1 - settleHidden / this.touchDockTravel);
      });
      return;
    }
  }

  private setTouchDockRatio(ratio: number): void {
    this.touchDockRatioValue = ratio;
    AppStorage.setOrCreate('auraTouchDockRatio', ratio);
  }

  private touchChromeBottomTracking: boolean = false;
  private touchChromeBottomStartY: number = 0;
  private touchChromeBottomTravel: number = 1;
  private touchChromeBottomHidden: number = 0;

  private touchChromeBottomActive(): boolean {
    return this.isMobilePhoneUi() && this.homeStyle === 'chrome' &&
      this.dockPosition === 'bottom' && this.isTopBarCollapsing() &&
      !this.addressEditing && !this.isNewTabPage() &&
      !this.homeHold && !this.homeReturnCover;
  }

  private onChromeBottomDockTouch(event: TouchEvent): void {
    if (!this.touchChromeBottomActive()) {
      this.touchChromeBottomTracking = false;
      return;
    }
    const touch = event.touches.length > 0 ? event.touches[0] : undefined;
    if (touch === undefined) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.touchChromeBottomTracking = true;
      this.touchChromeBottomStartY = touch.y;
      // 底置行程 = 悬浮 dock 全高（48 + 离底留白 + 底部安全区），与
      // GoogleDockBottom 的 translate 行程一致（顶置不走本驱动，见 active 条件）。
      this.touchChromeBottomTravel = Math.max(1,
        CHROME_DOCK_EXTENT_VP + CHROME_DOCK_FLOAT_MARGIN_VP +
        Number(AppStorage.get('auraBottomSafeVp') ?? 0));
      const curRaw = Number(AppStorage.get('auraChromeBottomRatio') ?? 1);
      const cur = Number.isFinite(curRaw) ? Math.min(Math.max(curRaw, 0), 1) : 1;
      this.touchChromeBottomHidden = (1 - cur) * this.touchChromeBottomTravel;
      return;
    }
    if (!this.touchChromeBottomTracking) {
      return;
    }
    if (event.type === TouchType.Move) {
      if (event.touches.length !== 1) {
        // 多指（缩放等）：不驱动，只把基准跟到手。
        this.touchChromeBottomStartY = touch.y;
        return;
      }
      const dy = touch.y - this.touchChromeBottomStartY;
      this.touchChromeBottomStartY = touch.y;
      // 手指上滑(dy<0) → 隐藏底置 dock（hidden 增大）；下滑(dy>0) → 显示（hidden 减小）。
      const next = Math.min(Math.max(this.touchChromeBottomHidden - dy, 0), this.touchChromeBottomTravel);
      if (Math.abs(next - this.touchChromeBottomHidden) >= 0.5) {
        this.touchChromeBottomHidden = next;
        this.setTouchChromeBottomRatio(1 - this.touchChromeBottomHidden / this.touchChromeBottomTravel);
      }
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.touchChromeBottomTracking = false;
      const settleHidden = this.touchChromeBottomHidden >= this.touchChromeBottomTravel * 0.5 ?
        this.touchChromeBottomTravel : 0;
      this.touchChromeBottomHidden = settleHidden;
      animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, (): void => {
        this.setTouchChromeBottomRatio(1 - settleHidden / this.touchChromeBottomTravel);
      });
      return;
    }
  }

  private setTouchChromeBottomRatio(ratio: number): void {
    AppStorage.setOrCreate('auraChromeBottomRatio', ratio);
  }

  // ---- 页面不滚动时的手势兜底：顶栏不放、只收 dock ----
  // 顶栏显隐平时由引擎做：页面滚动 → 引擎动 browser controls，并把
  // browserControlsRatio 报给外壳。有些页面（弹登录/建议浮层、modal 锁了 body
  // 滚动、本身不足一屏）**根本不发生滚动**，引擎拿不到输入 → ratio 恒为 1。
  // 这类页面顶栏保持不动（外壳也不再主动收起：引擎的控件动画会和整屏布局的
  // 重排叠在一起），只把 dock 交给触摸驱动——dock 是浮层，位移不牵动布局。
  // 若顶栏曾由真实滚动收起、之后页面才锁滚，这里负责把它放回来。
  // 与上面 dock 触摸驱动互斥：那边要求「地址栏常驻」，这边要求「允许收起顶栏」。
  private swipeTracking: boolean = false;
  private swipeStartY: number = 0;
  private swipeRatioAtStart: number = 1;
  private swipeEngineDrove: boolean = false;
  private swipeHandled: boolean = false;
  // 「页面不滚动」时只收 dock（地址栏钉住）：dock 是浮层，「滚动时隐藏底部栏」
  // 开着时底部内距恒 0 → 位移不改变任何布局，不会出现「收起 + 整页重排」的顿挫。
  private swipeDockTaken: boolean = false;    // 已把 dock 交给触摸驱动
  private swipeDockDriving: boolean = false;  // 本次手势正在驱动
  private swipeDockStartRatio: number = 1;    // 手势起点时的 dock 比例
  private swipeDockValue: number = 1;         // 当前比例（0=收起，1=全显）
  private swipeDockTravel: number = 1;        // 收起行程（vp）

  private swipeControlsActive(): boolean {
    return this.isMobilePhoneUi() && this.isTopBarCollapsing() && !this.addressEditing &&
      !this.isNewTabPage() && !this.homeHold && !this.homeReturnCover;
  }

  private onSwipeControlsTouch(event: TouchEvent): void {
    // Chrome 底置的滚动隐藏走触摸驱动（onChromeBottomDockTouch），不适用本兜底；
    // Chrome 顶置与简约同款：地址栏由引擎比例驱动，非滚动页面仍需要本兜底。
    if (this.homeStyle === 'chrome' && this.dockPosition !== 'top') {
      return;
    }
    if (!this.swipeControlsActive()) {
      this.swipeTracking = false;
      return;
    }
    const touch = event.touches.length > 0 ? event.touches[0] : undefined;
    if (touch === undefined) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.swipeTracking = true;
      this.swipeStartY = touch.y;
      this.swipeRatioAtStart = this.scrolledRatio;
      this.swipeEngineDrove = false;
      this.swipeHandled = false;
      this.swipeDockDriving = false;
      return;
    }
    if (!this.swipeTracking) {
      return;
    }
    if (event.type === TouchType.Move) {
      if (event.touches.length !== 1) {
        // 多指（缩放等）：不驱动，只把起点跟到手。
        this.swipeStartY = touch.y;
        this.swipeRatioAtStart = this.scrolledRatio;
        this.swipeHandled = false;
        return;
      }
      // 引擎自己在动 → 页面确实在滚，交还控制权，本次手势不再插手。
      if (Math.abs(this.scrolledRatio - this.swipeRatioAtStart) > CONTROLS_RATIO_EPS) {
        this.swipeEngineDrove = true;
        // 前半段可能已按「只收 dock」驱动过（引擎比例晚一两帧才到），马上交还，
        // 否则触摸值会压着引擎比例、dock 卡在中间位置。
        if (this.swipeDockTaken) {
          this.swipeDockDriving = false;
          this.releaseSwipeDock();
        }
        return;
      }
      if (this.swipeHandled || this.swipeEngineDrove) {
        return;
      }
      const up: number = this.swipeStartY - touch.y; // 正数 = 手指上滑
      // 归一化进度（0=全显，1=全隐）判定，不用引擎原始 ratio：minTop=topSafe 时
      // 收起终点的 ratio 是 topSafe/(48+topSafe)（≈0.38）而非 0，若按
      // 「ratio<=0.1 才展开」判定，内层滚动/不足一屏的页面一旦收起就再也放不出来。
      // 分母与 MobileBrowserOverlay 的顶栏 floor 保持一致。
      const topSafe: number = Number(AppStorage.get('auraTopSafeVp') ?? 0);
      const floor: number =
        (!this.isTopBarCollapsing() || this.hideStatusBarOnScroll || topSafe <= 0)
          ? 0 : topSafe / (TOP_BAR_EXTENT_VP + topSafe);
      const rawRatio: number =
        Number.isFinite(this.scrolledRatio) ? this.scrolledRatio : 1;
      const clamped: number = Math.min(Math.max(rawRatio, 0), 1);
      const span: number = 1 - floor;
      const hideProgress: number = span > 0
        ? Math.min(Math.max((1 - clamped) / span, 0), 1)
        : (1 - clamped);
      // 页面不滚动时**地址栏钉住、只收 dock**：这类页面引擎拿不到根滚动、不产
      // 比例，若由外壳 setBrowserControlsState 收放地址栏，引擎动画会和整屏布局
      // 的重排叠在一起、途中顿一下。dock 是浮层（底部内距恒 0），只改 translate，
      // 零重排——上滑收、下滑放都是平滑的，地址栏始终不动。
      if (this.swipeDockOnlyOn()) {
        if (this.swipeDockDriving || up >= SWIPE_TRIGGER_VP) {
          this.driveSwipeDock(up - SWIPE_TRIGGER_VP, hideProgress);
          return;
        }
        if (up <= -SWIPE_TRIGGER_VP && this.swipeDockTaken) {
          this.driveSwipeDock(up + SWIPE_TRIGGER_VP, hideProgress);
          return;
        }
      }
      // 顶栏已被真实滚动收起、之后页面又不再滚动：下滑把它放回来，否则收不回来。
      if (up <= -SWIPE_TRIGGER_VP && hideProgress >= 0.9) {
        this.swipeHandled = true;
        this.executeBrowserCommand({
          command: 'setBrowserControlsState', state: 'shown', animate: true });
      }
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.swipeTracking = false;
      this.settleSwipeDock();
    }
  }

  // 「页面不滚动」时只收 dock 的模式：简约/经典底置（Chrome 底置另有触摸驱动
  // onChromeBottomDockTouch，Chrome 顶置由引擎比例驱动，都不走这里）。
  private swipeDockOnlyOn(): boolean {
    return this.isMobilePhoneUi() && this.hideDockOnScroll &&
      this.homeStyle !== 'chrome' && !this.isNewTabPage() &&
      !this.addressEditing && !this.homeHold && !this.homeReturnCover;
  }

  // 只改 dock 的收起比例（0=收起，1=全显）。地址栏、视口内距、页面布局全不动。
  private driveSwipeDock(travelled: number, hideProgress: number): void {
    if (!this.swipeDockDriving) {
      this.swipeDockDriving = true;
      this.swipeDockTravel = Math.max(1,
        dockCoveredHeightVp(Number(AppStorage.get('auraBottomSafeVp') ?? 0)));
      // 起点取 dock 的实际位置：已由触摸收起时从当前值继续，否则由顶栏显隐进度
      // 反推（顶栏全显 → 1，全隐 → 0）。
      this.swipeDockStartRatio = this.swipeDockTaken ?
        this.swipeDockValue : Math.min(Math.max(1 - hideProgress, 0), 1);
      if (!this.swipeDockTaken) {
        this.swipeDockTaken = true;
        AppStorage.setOrCreate('auraSwipeDockRatioOn', true);
      }
    }
    const ratio: number = Math.min(Math.max(
      this.swipeDockStartRatio - travelled / this.swipeDockTravel, 0), 1);
    this.swipeDockValue = ratio;
    AppStorage.setOrCreate('auraTouchDockRatio', ratio);
  }

  // 松手：过半收到底（离屏），否则放回原位。dock 是浮层，这一步同样不动布局。
  private settleSwipeDock(): void {
    if (!this.swipeDockDriving) {
      return;
    }
    this.swipeDockDriving = false;
    const settle: number = this.swipeDockValue >= 0.5 ? 1 : 0;
    this.swipeDockValue = settle;
    animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, (): void => {
      AppStorage.setOrCreate('auraTouchDockRatio', settle);
    });
  }

  // 把 dock 交还引擎驱动（页面开始滚动 / 换页时），避免触摸值长期压着比例。
  private releaseSwipeDock(): void {
    this.swipeDockTaken = false;
    this.swipeDockDriving = false;
    this.swipeDockValue = 1;
    AppStorage.setOrCreate('auraSwipeDockRatioOn', false);
    AppStorage.setOrCreate('auraTouchDockRatio', 1);
  }

  // Collapsed address bar -> hide the status bar too; scrolling back restores
  // it. **不再**向引擎重发 setBrowserControls：保留高度与状态栏显隐无关
  // （top/minTop 是常量，见 sendBrowserControls），而同值重发同样会让引擎
  // 把顶栏控件重置为"全展开"——页面在状态栏出现的那一帧瞬移整整一条高度
  // 系统栏图标显隐，不牵动任何布局。
  private updateStatusBarForScroll(ratio: number): void {
    if (!this.hideStatusBarOnScroll || !this.isMobilePhoneUi()) {
      return;
    }
    if (ratio <= 0.1 && !this.statusBarHiddenByScroll) {
      this.statusBarHiddenByScroll = true;
      this.applyStatusBarHidden(true);
    } else if (ratio >= 0.4 && this.statusBarHiddenByScroll) {
      this.statusBarHiddenByScroll = false;
      this.applyStatusBarHidden(false);
    }
  }

  private applyStatusBarHidden(hidden: boolean): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    // 网页全屏期间状态栏归全屏逻辑管，滚动显隐不能把它又打开。
    if (this.pageFullscreen) {
      return;
    }
    window.getLastWindow(context).then((win: window.Window): void => {
      win.setSpecificSystemBarEnabled('status', !hidden);
    }).catch((error: Error) => {
      hilog.warn(0x0000, 'AuraShell', 'Status bar toggle failed: %{public}s', JSON.stringify(error));
    });
  }

  // 网页全屏开关：进 → 藏系统栏（状态栏 + 导航条）、控件高度清零、视口铺满；
  // 出 → 按当前设置把状态栏/控件还回去。
  private setPageFullscreen(on: boolean): void {
    if (this.pageFullscreen === on) {
      return;
    }
    this.pageFullscreen = on;
    AppStorage.setOrCreate('auraPageFullscreen', on);
    this.applyFullscreenSystemBars(on);
    this.sendBrowserControls();
    this.applyDockViewportInset();
  }

  private applyFullscreenSystemBars(on: boolean): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    window.getLastWindow(context).then((win: window.Window): void => {
      try {
        if (on) {
          win.setSpecificSystemBarEnabled('status', false);
          win.setSpecificSystemBarEnabled('navigationIndicator', false);
        } else {
          win.setSpecificSystemBarEnabled('status', !this.statusBarHiddenByScroll);
          win.setSpecificSystemBarEnabled('navigationIndicator', true);
        }
      } catch (error) {
        hilog.warn(0x0000, 'AuraShell', 'Fullscreen system bar toggle failed: %{public}s',
          JSON.stringify(error));
      }
    }).catch((error: Error) => {
      hilog.warn(0x0000, 'AuraShell', 'Fullscreen window lookup failed: %{public}s',
        JSON.stringify(error));
    });
  }


  // v8a diagnostic: read / clear / copy the crash file EntryAbility wrote.
  private crashReportPath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    return context ? `${context.filesDir}/aura-crash.txt` : '';
  }

  private readCrashReport(): void {
    try {
      const path = this.crashReportPath();
      if (path.length === 0) {
        return;
      }
      const text = fs.readTextSync(path);
      this.crashReport = text && text.length > 0 ? text : '';
    } catch (error) {
      // No file: the ordinary first-launch case.
      this.crashReport = '';
    }
  }

  private clearCrashReport(): void {
    try {
      const path = this.crashReportPath();
      if (path.length > 0) {
        fs.unlinkSync(path);
      }
    } catch (error) {
    }
    this.crashReport = '';
  }

  private copyCrashReport(): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.crashReport);
      pasteboard.getSystemPasteboard().setData(data).catch((error: Error): void => {
        console.error('Failed to copy the crash report:', error.message);
      });
    } catch (error) {
      console.error('Failed to copy the crash report');
    }
  }

  // Downloads go to Download/<bundle>, where the Files app shows them. The
  // directory can only be had once this page is up, after Chromium started.
  private downloadNotifier: DownloadNotifier | undefined = undefined;
  // 下载列表接口（downloadList）回包的 item 常不带 filePath，而实时
  // downloadUpdated 事件才带。这里累积 id→filePath，写下载页数据时回填，
  // 使「下载页 → 安装 .crx」能拿到正确路径（下载条用实时事件无需补）。
  private downloadFilePaths: Record<string, string> = {};

  private useSystemDownloadDirectory(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.downloadNotifier = new DownloadNotifier(context);
    ShellDownloadDirectory.prepare(context).then((uri: string): void => {
      if (uri.length > 0) {
        this.executeBrowserCommand({ command: 'setDownloadDirectory', uri: uri });
      }
    });
  }

  onPageShow(): void {
    // 页面重新可见；HomeSurface 据此区分「整页被藏」与「被网页顶掉」。
    AppStorage.setOrCreate('auraShellPageHidden', false);
    this.startKnockShare();
    // 不能在这里清 popup 让位态：点扩展时先设让位、再收起面板页回到本页，
    // 最后才由引擎弹 popup；清掉会让主页层盖住 popup。只记录状态供排查。
  }

  onPageHide(): void {
    AppStorage.setOrCreate('auraShellPageHidden', true);
    this.knockShareSession.stop();
  }

  aboutToDisappear(): void {
    PermissionRequestAdapter.stopObservingLocation();
    this.knockShareSession.stop();
    if (this.navCoverTimer >= 0) {
      clearTimeout(this.navCoverTimer);
      this.navCoverTimer = -1;
    }
    if (this.navCoverGraceTimer >= 0) {
      clearTimeout(this.navCoverGraceTimer);
      this.navCoverGraceTimer = -1;
    }
    if (this.extensionJumpTimer >= 0) {
      clearTimeout(this.extensionJumpTimer);
      this.extensionJumpTimer = -1;
    }
    // 过渡态的两个定时器随页面销毁一起清掉，避免悬空回调改已卸载状态。
    if (this.homeTransitionTimer >= 0) {
      clearTimeout(this.homeTransitionTimer);
      this.homeTransitionTimer = -1;
    }
    if (this.homeTransitionGraceTimer >= 0) {
      clearTimeout(this.homeTransitionGraceTimer);
      this.homeTransitionGraceTimer = -1;
    }
    if (this.homeHoldGraceTimer >= 0) {
      clearTimeout(this.homeHoldGraceTimer);
      this.homeHoldGraceTimer = -1;
    }
    if (this.homeControlsTimer >= 0) {
      clearTimeout(this.homeControlsTimer);
      this.homeControlsTimer = -1;
    }
    if (this.homeExitInkTimer !== -1) {
      clearTimeout(this.homeExitInkTimer);
      this.homeExitInkTimer = -1;
    }
    if (this.homeExitHoldTimer !== -1) {
      clearTimeout(this.homeExitHoldTimer);
      this.homeExitHoldTimer = -1;
    }
    if (this.discardedCoverTimer >= 0) {
      clearTimeout(this.discardedCoverTimer);
      this.discardedCoverTimer = -1;
    }
    if (this.discardedCoverGraceTimer >= 0) {
      clearTimeout(this.discardedCoverGraceTimer);
      this.discardedCoverGraceTimer = -1;
    }
    this.clearImeHideTimers();
    this.clearForceDarkStartupRetryTimers();
    this.currentTabCastSession.stop().catch((error: Error): void => {
      console.error('Failed to stop current-tab cast session:', error);
    });
  }

  // 无痕回来之后把普通会话的标签放回去。进无痕时存下的那份在这里取用一次，
  // 取完即清（IncognitoSwitch.takeSavedTabs）；无痕会话自己不留这些标签。
  private restoreSavedTabs(): void {
    if (this.savedTabsChecked) {
      return;
    }
    this.savedTabsChecked = true;
    if (this.incognito) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.Context | undefined;
    if (!context) {
      return;
    }
    IncognitoSwitch.takeSavedTabs(context).then((tabs: SavedTab[]): void => {
      if (tabs.length === 0) {
        return;
      }
      for (const tab of tabs) {
        this.executeBrowserCommand({ command: 'newTab', url: tab.url, background: true });
      }
      // The engine starts on a new tab; the first restored one sits at index 1.
      this.executeBrowserCommand({ command: 'activateTab', index: 1 });
    });
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.crashReport.length > 0) {
        this.CrashReportView()
      } else if (!this.onboardingReady) {
        LoadingProgress()
          .width(40)
          .height(40)
          .color($r('app.color.accent_primary'))
          .align(Alignment.Center)
      } else if (!this.onboardingComplete) {
        BrowserOnboarding({
          onComplete: (state: BrowserProfileState): void => {
            this.profileId = state.profileId;
            this.profileKind = state.profileKind;
            this.syncMode = state.syncMode;
            this.onboardingComplete = state.onboardingComplete;
          }
        })
      } else {
        WebWindow({
        url: this.startUrl,
        // Incognito is its own profile directory; the ordinary session keeps
        // whatever profile the onboarding chose.
        profileId: this.incognito ? IncognitoSwitch.profileId(true) : this.profileId,
        startupConfigText: this.startupConfigText,
        routingRevision: this.routingRevision,
        appVisible: this.appVisible,
        themeFontId: this.themeFontId,
        themeFontRevision: this.themeFontRevision,
        browserCommandText: this.browserCommandText,
        browserCommandRevision: this.browserCommandRevision,
        colorSchemeCmdText: this.colorSchemeCmdText,
        colorSchemeCmdRev: this.colorSchemeCmdRev,
        auxiliaryDismissWidget: this.auxiliaryDismissWidget,
        auxiliaryDismissRevision: this.auxiliaryDismissRevision,
        onBrowserState: (state: BrowserStateSnapshot): void => {
          // 无 popup 扩展（调姬助手）由扩展自己导航到 chrome-extension:// 页。
          // 点击当帧就收了面板页，转场期靠这层同色底护住；等它 commit 且
          // 加载结束就撤底，只留一帧（16ms）给首帧绘制；
          // 事件不来时由 onExtensionJumpCoverChanged 的兜底定时器收口。
          if (this.extensionJumpCover > 0 && !this.extensionJumpPopup) {
            const jumpUrl: string = state.url ?? '';
            if (jumpUrl.startsWith('chrome-extension://') && !state.loading) {
              if (this.extensionJumpTimer !== -1) {
                clearTimeout(this.extensionJumpTimer);
              }
              this.extensionJumpTimer = setTimeout((): void => {
                this.extensionJumpTimer = -1;
                AppStorage.setOrCreate('auraExtensionJumpCover', 0);
              }, 16);
            }
          }
          if (this.navCover) {
            const nowUrl: string = state.url ?? '';
            if (state.loading) {
              // 目标页正在加载：记住「见过 loading」。必须放在 url 判据**之前**：
              // 待定导航期间引擎可能还报着旧 url（GetVisibleURL 的语义），若把
              // loading 记在 url 变化的分支里就永远记不到，只能等兜底定时器。
              this.navCoverSawLoading = true;
            }
            const moved: boolean = nowUrl.length > 0 && nowUrl !== this.navCoverFromUrl;
            const landed: boolean = this.navCoverTargetUrl.length > 0 && nowUrl === this.navCoverTargetUrl;
            const tabSwitched: boolean = (state.activeTabIndex ?? -1) !== this.navCoverFromTabIndex;
            if (this.navCoverHistoryNav) {
              // 历史导航不等 loading 结束：长连接页面会持续报 loading，
              // 以 url 离开起防值作为落地判据，硬上限仅作兜底。
              if (moved || landed || tabSwitched) {
                this.armNavCoverGrace();
              }
            } else if (this.navCoverQuick) {
              if (moved || landed || tabSwitched || this.navCoverSawLoading) {
                this.armNavCoverGrace();
              }
            } else if (!state.loading && (this.navCoverSawLoading || moved || landed)) {
              // 普通导航维持原判据：loading 结束且确实到过，才起首帧宽限。
              this.armNavCoverGrace();
            }
          }
          // 过渡态落地判据：url 离开起防值即视为已提交，再留首帧宽限。
          if (this.homeTransition) {
            const transitionUrl: string = state.url ?? '';
            const leftOrigin: boolean = transitionUrl.length > 0 &&
              transitionUrl !== this.homeTransitionFromUrl;
            const transitionSwitched: boolean =
              (state.activeTabIndex ?? -1) !== this.homeTransitionFromTabIndex;
            if ((leftOrigin || transitionSwitched) &&
              (!this.homeTransitionWaitsLoading || !state.loading)) {
              this.scheduleHomeTransitionRelease();
            }
          }
          // 打开已休眠标签的遮盖：独立状态机，与 homeTransition / 前进后退互不干扰。
          if (this.discardedCover &&
            (state.activeTabIndex ?? -1) === this.discardedCoverIndex) {
            if (state.loading) {
              this.discardedCoverSawLoading = true;
            }
            if (!state.loading) {
              this.scheduleDiscardedCoverRelease();
            }
          }
          const wasNewTab: boolean = this.isNewTabPage();
          const prevUrl: string = this.browserState.url;
          const prevTabIndex: number = this.browserState.activeTabIndex ?? -1;
          this.browserState = state;
          // 换页/换标签：解除上一页的顶栏常显档，别把「关了隐藏开关」带到新页。
          // @Watch 会把内距、dock 与 browser controls 整套重算回 1.1.9。
          const pageChanged: boolean = (state.url ?? '') !== prevUrl ||
            (state.activeTabIndex ?? -1) !== prevTabIndex;
          if (this.topBarPinnedForPage && pageChanged) {
            this.topBarPinnedUrl = '';
            this.topBarPinnedForPage = false;
          }
          // 必应封面页判定位提前到「换页这一刻」：只等探针（load 后 600ms）的话，
          // 背景图会先按上一页的补偿档画一帧、探针到达再缩，视觉上被拉一下。
          // 解钉必须放在内距下发之前，否则第一帧仍是旧档（84vp）再落回 36。
          // 这里定档后第一次下发就是最终值，全程零二次布局。
          const coverNow: boolean = this.isBingCoverPage(state.url ?? '');
          if (coverNow !== this.probeOnBingCover) {
            this.probeOnBingCover = coverNow;
            this.applyDockViewportInset();
          }
          // 关掉重复主页标签后，等标签数真的回落再放开徽标：否则会先显示
          // 恢复后的「多一个」数量，再跳回实际数量。
          if (this.badgeWaitForCount >= 0 &&
            state.tabCount === this.badgeWaitForCount) {
            this.badgeWaitForCount = -1;
            this.releaseTabBadge();
          }
          // 徽标冻结只在启动窗口内；窗口结束后把真实标签数同步落盘，
          // 供下一次冷启动的第一帧直接显示。恢复期间不写，免得把中间值存进去。
          if (this.tabBadgeHold < 0 && state.tabCount !== this.lastSavedTabCount) {
            this.lastSavedTabCount = state.tabCount;
            if (this.savedTabCountContext) {
              ShellUiPrefs.saveLastTabCountSync(this.savedTabCountContext, state.tabCount);
            }
          }
          this.maybeRestoreLastSession(state);
          // 会话恢复出来的标签是重新加载的：地址栏已经换成真网址，页面区要等
          // 首帧才有内容，中间露的是引擎底板（黑）。这段用同色底顶住。
          if (this.restoreCoverPending) {
            const restoredUrl: string = state.url ?? '';
            if (restoredUrl.length > 0 && !isNewTabUrl(restoredUrl) &&
              !restoredUrl.startsWith('chrome')) {
              this.restoreCoverPending = false;
              this.armNavCover(restoredUrl);
            }
          }
          // 换页/换标签：触摸收起的 dock 复位（否则新页面会停在收起位）。
          if (this.swipeDockTaken && (state.url ?? '') !== prevUrl) {
            this.releaseSwipeDock();
          }
          // 记下引擎原生新标签页的标题：失败导航后要靠它认出「画面还停在
          // 新标签页」（见 isNewTabPage）。
          if (isNewTabUrl(state.url ?? '')) {
            const seen = (state.title ?? '').trim();
            if (seen.length > 0) {
              this.newTabTitleSeen = seen;
            }
          }
          if (this.isNewTabPage() && !wasNewTab) {
            // 刚落到主页（含「后退回主页」这条路径）：顶栏可能还停在收起态，
            // 引擎不会自己放回来（新标签页没有可滚动内容）—— 见方法注释。
            this.restoreTopControlsForHome();
          }
          if (this.homeReturnCover && this.isNewTabPage()) {
            // 主页已真正落地：撤防（挂载条件回落到 isNewTabPage，不会闪）。
            this.releaseHomeReturnCover();
          }
        if (this.homeHold) {
          if (this.isNewTabPage()) {
            // 停加载/历史导航回落到新标签页时可能一次 loading 都没报过；
            // 只要引擎确实停在 NTP 就立刻撤掉淡出，别让透明的主页层
            // 露出引擎原生磁贴页。
            this.releaseHomeHold(true);
          } else if (state.loading) {
            this.homeHoldSawLoading = true;
          } else if (this.homeHoldSawLoading) {
            // loading=false 只代表提交完成，渲染器未必已上帧；立刻撤会露出
            // 引擎历史里那张原生 NTP 磁贴页（点书签 / 主页磁贴）。
            this.scheduleHomeHoldRelease();
          } else if (this.homeHoldQuickTimer === -1) {
            this.homeHoldQuickTimer = setTimeout((): void => {
              this.homeHoldQuickTimer = -1;
              if (!this.homeHold || this.isNewTabPage()) {
                return;
              }
              if (!this.browserState.loading) {
                this.scheduleHomeHoldRelease();
                return;
              }
              const pendingUrl: string = this.browserState.url ?? '';
              if (pendingUrl.startsWith('chrome-extension://') ||
                pendingUrl.startsWith('chrome://')) {
                this.homeHoldQuickTimer = setTimeout((): void => {
                  this.homeHoldQuickTimer = -1;
                  if (this.homeHold && !this.isNewTabPage()) {
                    this.releaseHomeHold();
                  }
                }, 800);
              }
            }, 250);
          }
        }
          if (!this.systemPermissionReported) {
            this.systemPermissionReported = true;
            this.reportSystemPermissionState();
          }
          if (state.ready) {
            this.configureBrowserControls();
            this.restoreSavedTabs();
            this.syncDesktopSites();
          }
          this.currentTabCastSession.update(state);
          this.knockShareSession.update(state);
        },
        onRuntimeEvent: (event: BrowserRuntimeEvent): void => {
          this.handleRuntimeEvent(event);
        },
        onAuxiliaryWindowState: (state: AuxiliaryWindowState): void => {
          this.handleAuxiliaryWindowState(state);
        }
        })
          .width('100%')
          .height('100%')
        // 主页退场时先铺同色垫底盖住引擎清屏到首帧的空窗，再让主页淡出。
        // 顺序固定：垫底在下、HomeSurface 在上，否则淡出露不出垫底。
        // 主页态与整个离开/返回过渡期都垫一层不透明同色底：引擎 WebContents
        // 在主页态显示的是原生 NTP 磁贴页，只要有一帧没垫住就会漏出来。
        // 不能挂在 homeSurfaceVisible() 上——state 切到目标网址的那一拍它正好
        // 变 false，正是断档的那一帧。但扩展 popup 让位期间必须例外：那时
        // popupHomeHold > 0 会主动撤掉主页层给 popup 让路，这里再铺满实底
        // 就会把整个界面盖成白屏（popup 的关闭事件可能迟到，兜底是 10 分钟）。
        if (this.isMobilePhoneUi() && this.popupHomeHold <= 0 &&
            (this.homeHold || this.isNewTabPage() || this.homeTransition ||
              this.navCover || this.homeReturnCover)) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor($r('app.color.browser_canvas'))
            .hitTestBehavior(HitTestMode.None)
        }
        // 主页层常驻：网页态用 Visibility.None 藏起，避免回主页时重建 +
        // 重新解码壁纸造成中间空帧；Image 一直持有已解码壁纸，当帧即可上屏。
        // homeHold 的 180ms 淡出仍由 opacity 负责。
        if (this.isMobilePhoneUi()) {
          HomeSurface({
            homeVisible: this.homeSurfaceVisible(),
            incognito: this.incognito,
            onCommand: (command: BrowserCommandPayload): void => {
              if (command.command === 'navigate' && this.isNewTabPage()) {
                this.holdHomeForPaint();
              }
              this.executeBrowserCommand(command);
            }
          })
            .width('100%')
            .height('100%')
            .visibility(this.homeSurfaceVisible() ? Visibility.Visible : Visibility.None)
            .opacity(this.homeHold && !this.isNewTabPage() ? 0 : 1)
            // 不能用 .animation()：它对按住/放开一视同仁，回主页会多一次淡入。
            // 淡出由 holdHomeForPaint() 的 animateTo 显式驱动，放开瞬时生效。
            // 淡出期间不吃触摸，避免点击落到旧主页。
            .hitTestBehavior(this.homeHold ? HitTestMode.None : HitTestMode.Default)
        }
        if (this.isMobilePhoneUi() && this.needsHomeBackdrop() && !this.homeSurfaceVisible()) {
          // 预热层盖住引擎清屏到新页首帧之间的底板。与主页层用独立 if，
          // 避免起防那一帧两层皆空露出原生 NTP。
          // 主页层在场时一律不叠：这块盖在主页之上，会叠出整屏蒙白。
          this.NavCoverView()
        }
        // 平板/桌面主页：同一个 HomeSurface 以嵌入态复用（内容顶距 = chrome
        // 总高），新标签页时盖住引擎原生 NTP。常驻挂载、Visibility 控制显隐，
        // 与手机同款（避免回主页时重建 + 重解码壁纸的空帧）。
        if (this.isDesktopAuraUi()) {
          HomeSurface({
            embedded: true,
            topInsetVp: this.desktopChromeInset,
            homeVisible: this.isNewTabPage(),
            incognito: this.incognito,
            onCommand: (command: BrowserCommandPayload): void => {
              this.executeBrowserCommand(command);
            }
          })
            .width('100%')
            .height('100%')
            .visibility(this.isNewTabPage() ? Visibility.Visible : Visibility.None)
        }
        if (this.discardedCover) {
          this.DiscardedCoverView()
        }
        // 触摸观察层：Transparent 全屏节点——自己收得到页面区触摸，又不阻塞
        // 下面的网页（与 bars 包裹容器同一机制）；overlay 在其上先处理，
        // modal / 条带命中时触摸到不了这里。只读，不消费。
        // 两个用途，启用条件互斥（各自方法内部判断）：
        //  · onDockObserverTouch：「地址栏常驻 + 收起 dock」组合，用位移驱动 dock。
        //  · onSwipeControlsTouch：页面不滚动（弹窗锁滚 / 短页面）时，上滑兜底
        //    收放顶栏——引擎拿不到滚动输入，只能外壳补这一刀。
        Column()
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.Transparent)
          .onTouch((event: TouchEvent): void => {
            this.onDockObserverTouch(event);
            this.onSwipeControlsTouch(event);
            this.onChromeBottomDockTouch(event);
          })
        if (this.isMobilePhoneUi()) {
          MobileBrowserOverlay({
            browserState: this.browserState,
            // 恢复会话期间冻结标签计数，避免徽标从 1 逐个涨到实际数量。
            badgeTabCount: this.tabBadgeHold,
            // 引擎其实停在自己的新标签页（失败导航）时告诉顶栏层，让它按主页
            // 处理（不画地址栏、菜单显示"新标签页"、顶部不留条带命中区）。
            engineHomeCover: this.engineHomeCovered(),
            // 回主页的意图（按主页键/返回）。顶栏只有把它算进「是否主页」才
            // 不会在转场里冒出一条上一页的地址栏（见 overlay 里的注释）。
            homeIntent: this.homeReturnCover,
            // 离开主页后的 120ms 内顶栏仍按主页态画，跟着 180ms 淡出走。
            homeExitHold: this.homeExitHold,
            incognito: this.incognito,
            onCommand: (command: BrowserCommandPayload): void => {
              // Back is asked of the page before it is asked of the tab. A
              // <dialog>, a popover, fullscreen or a page with a CloseWatcher
              // of its own expects back to close that rather than leave the
              // page, which is what back does in every other browser. The
              // engine answers backHandled; only a no goes on to the tab.
              if (command.command === 'back') {
                this.executeBrowserCommand({
                  command: 'handleBack', requestId: ++this.backRequestId });
                return;
              }
              if (command.command === 'homeSurface') {
                this.beginHomeReturnCover();
                this.executeBrowserCommand({ command: 'home' });
                return;
              }
              if (command.command === 'home') {
                const startupPage: string = (AppStorage.get('auraStartupPage') as string) ?? 'builtin';
                const customHome: string = (AppStorage.get('auraHomeUrl') as string) ?? '';
                if (startupPage === 'homeUrl' && customHome.length > 0) {
                  this.armNavCover(customHome, true);
                  this.navCoverHideIme = true;
                  this.executeBrowserCommand({ command: 'navigate', url: customHome });
                  return;
                }
                // 主页键：立刻把主页层铺上，盖住引擎回主页那一瞬的白底
                //（见 homeReturnCover 注释）。
                this.beginHomeReturnCover();
              }
              if (command.command === 'navigate') {
                const navUrl: string = command.url ?? '';
                if (navUrl.length > 0 && !isNewTabUrl(navUrl) && this.isNewTabPage()) {
                  this.armNavCover(navUrl);
                }
              }
              this.executeBrowserCommand(command);
            }
          })
        }
        // 平板/桌面 chrome（aura_tablet / aura_pc）：标签条+工具栏+地址栏由
        // DesktopBrowserChrome 自绘，叠在页面之上；网页视口由
        // sendBrowserControls 的 top 内距压到工具栏之下（与手机同一套
        // setBrowserControls 机制）。放在辅助窗口层之下：引擎弹出的原生
        // 浮窗（扩展 popup 等）仍在最上层。
        if (this.isDesktopAuraUi() && this.addressEditing) {
          // 地址栏编辑态：垫一层全窗透明拦截。点网页区（TextInput 的 onBlur
          // 对 XComponent 不生效）先把编辑态收掉——Chrome 点外侧退出的行为。
          // 渲染在 DesktopBrowserChrome 之前，z 序在 chrome 之下，不挡工具栏。
          Row()
            .width('100%')
            .height('100%')
            .backgroundColor(Color.Transparent)
            .onClick((): void => {
              this.addressEditing = false;
            })
        }
        if (this.isDesktopAuraUi()) {
          DesktopBrowserChrome({
            browserState: this.browserState,
            incognito: this.incognito,
            onCommand: (command: BrowserCommandPayload): void => {
              // 与手机同一约定：返回键先问页面（弹层/全屏页优先处理），
              // 页面不管才落到标签历史回退。
              if (command.command === 'back') {
                this.executeBrowserCommand({
                  command: 'handleBack', requestId: ++this.backRequestId });
                return;
              }
              // 主页键：尊重「启动页=自定义网址」设置（与手机 overlay 同分支）。
              if (command.command === 'home') {
                const startupPage: string = (AppStorage.get('auraStartupPage') as string) ?? 'builtin';
                const customHome: string = (AppStorage.get('auraHomeUrl') as string) ?? '';
                if (startupPage === 'homeUrl' && customHome.length > 0) {
                  this.executeBrowserCommand({ command: 'navigate', url: customHome });
                  return;
                }
              }
              this.executeBrowserCommand(command);
            }
          })
            // 顶层 Stack 的 alignContent 是 Bottom，.align 对自定义组件不生效，
            // chrome 会整列掉到底部——用 position 钉在窗口左上角才稳。
            .position({ x: 0, y: 0 })
        }
        if (this.auxiliaryWindows.length > 0) {
          this.AuxiliaryWindowLayer()
        }
        // 点扩展后的跳转同色底：点击当帧铺上，护住 router 转场期间露出的
        // 主页 / 当前网页 / 扩展页首帧前的空白。撤底走 200ms 淡出而不是直接
        // 移除，否则新页会在旧页滑出未完成时整块跳出；不铺时组件不存在，
        // 不占合成层，对其余路径零开销。
        if (this.extensionJumpCover > 0) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor($r('app.color.browser_canvas'))
            .transition(TransitionEffect.opacity(0).animation({ duration: 200, curve: Curve.Friction }))
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.browser_canvas'))
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      this.onScreenSizeChanged(Number(newValue.width), Number(newValue.height));
    })
  }

  // v8a diagnostic: the crash report page. Plain components only -- it must
  // render even when nothing else can. Copy hands the text to the clipboard
  // so it can be pasted out; clear removes the record and lets the shell run
  // normally again (a fresh crash writes a fresh record).
  @Builder
  private CrashReportView() {
    Column({ space: 14 }) {
      Text('上次启动发生异常')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('下面是最近一次异常的信息，复制后发给开发者；清除后即可继续使用。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Scroll() {
        Text(this.crashReport)
          .fontSize(11)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
      .padding(12)
      .borderRadius(8)
      .backgroundColor($r('app.color.surface_secondary'))
      Row({ space: 12 }) {
        Button('复制错误信息')
          .fontSize(15)
          .layoutWeight(1)
          .height(46)
          .onClick((): void => {
            this.copyCrashReport();
          })
        Button('清除并继续')
          .fontSize(15)
          .layoutWeight(1)
          .height(46)
          .onClick((): void => {
            this.clearCrashReport();
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor($r('app.color.surface_primary'))
  }

  // Close the topmost modal window on back, the way a phone dismisses a
  // dialog. Chromium's windows carry their own Cancel and Stop buttons, so
  // the shell no longer adds a close button of its own; this is the one
  // system gesture that still means "dismiss".
  onBackPress(): boolean {
    for (let index = this.auxiliaryWindows.length - 1; index >= 0; index--) {
      const view = this.auxiliaryWindows[index];
      if (view.modal) {
        this.requestAuxiliaryWindowDismiss(view.state.widget);
        return true;
      }
    }
    // The browser chrome unwinds first: address editing, the tab menu, a
    // full-screen shell page, then page history. Only when there is nothing
    // of ours left does the gesture fall through to leaving the app.
    const overlayBack = MobileBackRouter.handler;
    if (overlayBack && overlayBack()) {
      return true;
    }
    return false;
  }

  // The 60-second password window dies in the background: the engine watches
  // the lock screen itself, but the shell must report app backgrounding.
  // The watch itself hangs on the appVisible storage link declared above.
  private onAppVisibleChanged(): void {
    if (!this.appVisible) {
      this.executeBrowserCommand({ command: 'passwordAuthReset' });
    }
  }

  private startKnockShare(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    this.knockShareSession.start(context).catch((error: Error): void => {
      console.error(`Failed to start HarmonyOS knock share: ${error.message}`);
    });
  }

  // Each auxiliary window is drawn at its own size, clamped to the screen, and
  // hangs from the top centre. Nothing wraps the XComponent: its box is exactly
  // the size the window reported, because the surface size is fed back to the
  // widget as its bounds and anything added here would shrink it every round.
  //
  // Only a modal window -- the media source picker -- gets a scrim that blocks
  // the page. A non-modal one, such as the "sharing your screen / stop" bar,
  // covers only its own box and the page around it stays usable.
  @Builder
  private AuxiliaryWindowLayer() {
    if (this.auxiliaryWindows.some((view: AuxiliaryWindowView): boolean => view.modal)) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.modal_scrim'))
        .hitTestBehavior(HitTestMode.Block)
    }
    ForEach(this.auxiliaryWindows, (view: AuxiliaryWindowView) => {
      Stack() {
        if (view.state.pictureInPicture === true) {
          PictureInPictureSurface({
            componentId: view.state.componentId,
            widget: view.state.widget
          })
            .width('100%')
            .height('100%')
        } else {
          XComponent({
            id: view.state.componentId,
            type: XComponentType.SURFACE,
            libraryname: 'web_engine'
          })
            .id(view.state.componentId)
            .width('100%')
            .height('100%')
            // A SURFACE XComponent's own background is opaque black by default,
            // and it shows through wherever the buffer is transparent. Popups
            // paint their margin transparent (rounded corners, the arrow, the
            // shadow), so without this each one sat in a black rectangle.
            .backgroundColor(Color.Transparent)
            // A popup anchored to the page -- the autofill list under a field
            // -- is not activatable in Chromium either. Taking focus here moved
            // it off the page's XComponent, which closed the keyboard the user
            // was typing with and could leave it unable to reopen.
            .focusable(view.state.anchored !== true)
            .defaultFocus(view.state.widget === this.activeAuxiliaryWidget)
        }
      }
      // Read through this.auxiliaryWindows rather than `view`: the item is keyed
      // by component id so that a resize does not recreate the surface, which
      // means the builder keeps the `view` it was first given.
      .width(this.auxiliaryWidthVp(view.state.widget))
      .height(this.auxiliaryHeightVp(view.state.widget))
      .position({
        x: this.auxiliaryLeftVp(view.state.widget),
        y: this.auxiliaryTopVp(view.state.widget)
      })
      // Popups Chromium anchors to the page draw their own shadow and border.
      .shadow(view.state.anchored === true || view.state.pictureInPicture === true ? { radius: 0 } :
        { radius: 16, color: $r('app.color.shadow'), offsetY: 4 })
      // Default, not Block: Block keeps the touch test away from this Stack's
      // own children, and the Stack is not a touch target itself, so every
      // press inside the window came back "Touch test result is empty" and
      // never reached the XComponent -- the Stop button did nothing. Default
      // lets the XComponent take the press and still keeps it from the page
      // beneath this box.
    }, (view: AuxiliaryWindowView): string => view.state.componentId)
  }

  private findAuxiliaryWindow(widget: number): AuxiliaryWindowView | undefined {
    return this.auxiliaryWindows.find(
      (view: AuxiliaryWindowView): boolean => view.state.widget === widget);
  }

  private auxiliaryWidthVp(widget: number): number {
    return this.findAuxiliaryWindow(widget)?.widthVp ?? 0;
  }

  private auxiliaryHeightVp(widget: number): number {
    return this.findAuxiliaryWindow(widget)?.heightVp ?? 0;
  }

  private auxiliaryLeftVp(widget: number): number {
    return this.findAuxiliaryWindow(widget)?.leftVp ?? 0;
  }

  private auxiliaryTopVp(widget: number): number {
    return this.findAuxiliaryWindow(widget)?.topVp ?? AUXILIARY_WINDOW_MARGIN_VP;
  }

  private onScreenSizeChanged(width: number, height: number): void {
    if (width <= 0 || height <= 0 ||
      (width === this.screenSizeVp.width && height === this.screenSizeVp.height)) {
      return;
    }
    this.screenSizeVp = { width: width, height: height };
    // A rotation or a window resize changes the clamp, so every window is laid
    // out again against the new screen.
    this.auxiliaryWindows = this.auxiliaryWindows.map(
      (view: AuxiliaryWindowView): AuxiliaryWindowView => this.layoutAuxiliary(view.state, view.modal, view));
  }

  private layoutAuxiliary(
    state: AuxiliaryWindowState,
    modal: boolean,
    previous?: AuxiliaryWindowView
  ): AuxiliaryWindowView {
    const ui = this.getUIContext();
    // Before the first layout pass there is no screen size yet; the window's
    // own size stands in, and onScreenSizeChanged clamps it once one arrives.
    const screen: ScreenSizeVp = this.screenSizeVp.width > 0 ? this.screenSizeVp : {
      width: ui.px2vp(state.width) + 2 * AUXILIARY_WINDOW_MARGIN_VP,
      height: ui.px2vp(state.height) * 2
    };
    return layoutAuxiliaryWindow(state, modal, screen,
      (px: number): number => ui.px2vp(px), previous);
  }

  // Commands are batched rather than written straight to the state pair, so
  // that two sent from one handler both arrive. See BrowserCommandChannel.
  private readonly commandChannel: BrowserCommandChannel =
    new BrowserCommandChannel((text: string): void => {
      this.browserCommandText = text;
      this.browserCommandRevision += 1;
    });

  private executeBrowserCommand(command: BrowserCommandPayload): void {
    // 取证：进引擎前的最终漏斗。back/forward 的落点由引擎快照里的
    // backUrl/forwardUrl 给出，只有落点是主页才铺底（见
    // armNavCoverForHistoryNav 的注释）；网页↔网页交给引擎硬切。
    if (command.command === 'back' && this.browserState.canGoBack) {
      this.armNavCoverForHistoryNav(this.browserState.backUrl ?? '');
    } else if (command.command === 'forward' && this.browserState.canGoForward) {
      this.armNavCoverForHistoryNav(this.browserState.forwardUrl ?? '');
    }
    // 统一兜底：显式遮盖已起的路径内部会跳过，只补没有遮盖的路径
    //（主要是切到已休眠标签）。
    this.maybeBeginHomeTransition(command);
    this.commandChannel.send(command);
  }

  private lastSessionRestoreAsked: boolean = false;
  // 已请求恢复会话、还在等恢复出来的标签给出真网址（用来起预热层）。
  private restoreCoverPending: boolean = false;
  // 冷启动要落在主页：等恢复出来的标签报出网址，再决定是原地留着还是另开主页标签。
  private coldStartHomePending: boolean = false;
  // 标签页徽标要显示的数字：-1 表示跟着 browserState.tabCount 走。
  // 首帧先显示上次退出时的标签数（壳层同步持久化），恢复会话期间一直冻结在
  // 这个值上：引擎是一个个把标签加回来的，直接跟 tabCount 会看到「数一遍」。
  @State private tabBadgeHold: number = -1;
  private lastSavedTabCount: number = -1;
  private savedTabCountContext: common.Context | undefined = undefined;
  // 关掉恢复出来的重复主页标签后，等状态里的标签数落到这个值再放开徽标；
  // 否则会先闪一下「多一个」的数量再跳回来。
  private badgeWaitForCount: number = -1;

  private holdTabBadge(): void {
    if (this.tabBadgeHold < 0) {
      this.tabBadgeHold = this.browserState.tabCount;
    }
  }

  private releaseTabBadge(delayMs: number = 0): void {
    const release = (): void => {
      this.tabBadgeHold = -1;
      // 窗口结束时把真实数量同步落盘，下次冷启动首帧就能直接显示它。
      const count: number = this.browserState.tabCount;
      if (count > 0 && count !== this.lastSavedTabCount && this.savedTabCountContext) {
        this.lastSavedTabCount = count;
        ShellUiPrefs.saveLastTabCountSync(this.savedTabCountContext, count);
      }
    };
    if (delayMs <= 0) {
      release();
      return;
    }
    setTimeout(release, delayMs);
  }

  // 冷启动落点：恢复是后台的，活动标签本来就是启动时那个主页，原地不动。
  // 万一引擎没支持后台恢复（旧版 .so），恢复的网页会被激活，这里再补开一个
  // 主页标签并关掉空白起始标签，保证落点仍是主页。
  private landOnHomeIfNeeded(retry: number = 0): void {
    if (!this.coldStartHomePending) {
      return;
    }
    const url: string = this.browserState.url ?? '';
    const currentTabs: BrowserTabState[] = this.browserState.tabs ?? [];
    if ((url.length === 0 ||
      currentTabs.length < this.lastSessionRestoredCount + 1) && retry < 3) {
      // 状态还没跟上（标签列表还没把恢复出来的标签收齐），再等一小会儿；
      // 最多 ~1.6s，之后由 6s 兜底收尾。
      setTimeout((): void => {
        this.landOnHomeIfNeeded(retry + 1);
      }, 400);
      return;
    }
    this.coldStartHomePending = false;
    // 后台恢复生效时启动标签一直留在前台。它可能是内置主页，也可能是
    // 「启动时打开自定义网页」设的网址 —— 两者都是用户要的落点，不能因为
    // URL 不是 newtab 就当成「恢复的网页抢了前台」去补开内置主页。
    const activeIndex: number = this.browserState.activeTabIndex ?? -1;
    const stayedOnStartTab: boolean = this.coldStartTabIndex >= 0 &&
      activeIndex === this.coldStartTabIndex;
    this.coldStartTabIndex = -1;
    if (stayedOnStartTab || url.length === 0 ||
      isNewTabUrl(url) || url.startsWith('chrome')) {
      this.restoreCoverPending = false;
      // 万一还有重复的主页标签（旧引擎或 URL 没被识别），合并掉；若真的
      // 关了一个，徽标要等标签数回落再放开，避免先显示多一个的数量。
      if (!this.closeDuplicateHomeTab()) {
        this.releaseTabBadge(200);
      }
      return;
    }
    // 走到这里说明活动标签被恢复的网页换掉了（旧引擎路径），补开主页。
    this.restoreCoverPending = false;
    this.executeBrowserCommand({ command: 'newTab', background: false });
    if (this.restoreStartTabWasNew) {
      this.restoreStartTabWasNew = false;
      this.executeBrowserCommand({
        command: 'closeTab',
        index: this.restoreStartTabIndex
      });
    }
    this.releaseTabBadge(200);
  }

  // 兜底：引擎恢复时已经跳过启动页占位标签，旧引擎或 URL 未识别时仍可能
  // 多出一个主页标签。只关掉一个，额外开的新标签页仍保留。
  // 返回 true 表示确实发了 closeTab，徽标释放要等这次状态回落。
  private closeDuplicateHomeTab(): boolean {
    if (!this.restoreStartTabWasNew) {
      return false;
    }
    this.restoreStartTabWasNew = false;
    const tabs: BrowserTabState[] = this.browserState.tabs ?? [];
    for (const tab of tabs) {
      const index: number = tab.index ?? -1;
      if (index >= 0 && index !== this.restoreStartTabIndex &&
        isNewTabUrl(tab.url ?? '')) {
        this.badgeWaitForCount = this.browserState.tabCount - 1;
        this.executeBrowserCommand({ command: 'closeTab', index: index });
        // 状态万一没回来也不能一直冻结；状态先到时这个定时器会自然空转。
        setTimeout((): void => {
          if (this.badgeWaitForCount >= 0) {
            this.badgeWaitForCount = -1;
            this.releaseTabBadge();
          }
        }, 1000);
        return true;
      }
    }
    return false;
  }
  // 引擎的恢复是「追加」到当前窗口（chrome::AddRestoredTab 用 tabs->count()
  // 作索引）：启动时那个空白新标签页会留在 index 0，恢复的页面排在它后面，
  // 看起来就像「重开后又自动新建了一个标签页」。记下它，等
  // lastSessionRestored 确认恢复成功后再关；恢复失败时绝不能关（否则空窗口）。
  private restoreStartTabWasNew: boolean = false;
  private restoreStartTabIndex: number = -1;
  // 冷启动时前台那个标签的位置。「启动时打开自定义网页」时它的 URL 是网址，
  // 不能只看 URL 是不是 newtab 来判断后台恢复有没有抢前台。
  private coldStartTabIndex: number = -1;
  // 恢复出来的标签数，用来判断状态里的标签列表是否已经收齐。
  private lastSessionRestoredCount: number = 0;

  private maybeRestoreLastSession(state: BrowserStateSnapshot): void {
    if (this.lastSessionRestoreAsked || state.lastSessionRestorable !== true) {
      // 这次不是崩溃恢复（正常启动），没有恢复窗口，徽标直接跟真实值。
      if (state.lastSessionRestorable !== true && this.tabBadgeHold >= 0) {
        this.releaseTabBadge();
      }
      return;
    }
    this.lastSessionRestoreAsked = true;
    // 记下冷启动前台标签的位置：后台恢复生效时它会一直是活动标签。
    // 极早期的快照可能还没给出 activeTabIndex，退回用唯一的那个起始标签。
    const startActive: number = state.activeTabIndex ?? -1;
    const startTabs: BrowserTabState[] = state.tabs ?? [];
    const firstIndex: number = startTabs.length > 0
      ? (startTabs[0].index ?? -1) : -1;
    this.coldStartTabIndex = startActive >= 0 ? startActive : firstIndex;
    // 恢复出来的标签会重新加载，页面区在首帧之前是黑的：等它报出真网址就起防。
    this.restoreCoverPending = true;
    // 冷启动的落点固定是主页：网页就另开一个主页标签，主页则原地不动。
    this.coldStartHomePending = true;
    // 首帧已经把徽标冻结在上次的标签数上；这里只作兜底（context 没拿到时）。
    this.holdTabBadge();
    // 恢复失败/迟迟没状态时别把用户后来的导航当成冷启动落点。
    setTimeout((): void => {
      this.coldStartHomePending = false;
      this.coldStartTabIndex = -1;
      this.badgeWaitForCount = -1;
      this.releaseTabBadge();
    }, 6000);
    const tabs = state.tabs;
    if (tabs && tabs.length === 1 && isNewTabUrl(tabs[0].url ?? '')) {
      this.restoreStartTabWasNew = true;
      this.restoreStartTabIndex = tabs[0].index;
    }
    const restore = (): void => {
      this.executeBrowserCommand({
        command: 'restoreLastSession',
        restore: true,
        mainWindowOnly: true,
        // 恢复的标签全部放在后台，当前这个主页标签保持活动：既不会先把网页
        // 顶到前台再切回主页（闪一下），也不用等恢复完再补开主页（有延迟）。
        background: true
      });
    };
    restore();
    setTimeout(restore, 800);
  }

  // Counts handleBack requests, so a late answer to an earlier one is not
  // acted on twice.
  private backRequestId: number = 0;

  private handleRuntimeEvent(event: BrowserRuntimeEvent): void {
    // 页面位置探针：只在「滚不动」的页面上钉住顶栏，修页内按钮命中偏下；
    // 可滚动页面（知乎/搜狐/贴吧等）的几何一律保持 1.1.9。
    if (event.event === 'pageScrollSettled' || event.event === 'pageContinuation') {
      this.updatePageTopBarPin(event.url ?? '', event.scrollable ?? 1, event.scrollY ?? 0);
    }
    // The page had first refusal on the back gesture and did not take it, so
    // the tab goes back after all. An answer to an older request is ignored:
    // the reader may have pressed back twice before the first one came.
    if (event.event === 'backHandled') {
      if ((event.requestId ?? 0) === this.backRequestId &&
        !(event.handled ?? false)) {
        this.executeBrowserCommand({ command: 'back' });
      }
      return;
    }
    if (event.event === 'lastSessionRestored') {
      const restored: number = event.count ?? 0;
      this.lastSessionRestoredCount = restored;
      // 徽标要等落点判定和「合并重复主页标签」都做完再放开，否则会先显示
      // 恢复后的数量、关掉重复标签后又跳一次。
      // 恢复是后台的，启动时那个标签就是主页，不能在这里关掉（关了会把后台
      // 恢复出来的网页顶成活动标签）。只有下面判定「没走后台恢复」时才补关。
      if (restored > 0) {
        setTimeout((): void => {
          this.landOnHomeIfNeeded();
        }, 400);
      } else {
        // 没有可恢复的网页标签（上次就停在主页）：主页一直在前台，不需要预热层。
        this.coldStartHomePending = false;
        this.coldStartTabIndex = -1;
        this.restoreCoverPending = false;
        this.badgeWaitForCount = -1;
        this.releaseTabBadge();
      }
      return;
    }
    if (event.event === 'pwaInstalled' && this.isDesktopAuraUi()) {
      AlertDialog.show({
        title: '\u5b89\u88c5\u5b8c\u6210',
        message: '\u606d\u559c\u60a8\uff0c\u60a8\u5df2\u7ecf\u5c06\u5b83\u4f5c\u4e3a\u5c0f\u7a0b\u5e8f\u5b89\u88c5\u5230\u672c\u673a\u4e86\u3002\u60a8\u53ef\u4ee5\u6dfb\u52a0\u670d\u52a1\u5361\u7247\uff0c\u5728\u684c\u9762\u663e\u793a\u5c0f\u7a0b\u5e8f\uff01',
        confirm: {
          value: '\u5b8c\u6210',
          action: (): void => {
          }
        }
      });
      return;
    }

    if (event.event === 'downloadUpdated') {
      const updated = shellEvent<DownloadUpdatedEvent>(event);
      this.downloadNotifier?.update(updated);
      // App 内下载通知条数据源（snackbar 挂在 MobileBrowserOverlay：
      // 开始下载 → 下载完成[.crx→安装 / 其他→打开] → 失败）。系统通知栏仍由
      // DownloadNotifier 负责，这里是 App 内浮层通道。revision 保证内容变化
      // 必触发 @Watch（AppStorage 逐字节相同不算变，见 auraFindResult 先例）。
      AppStorage.setOrCreate('auraDownloadEvent', JSON.stringify({
        id: updated.id ?? '',
        fileName: updated.fileName ?? '',
        url: updated.url ?? '',
        state: updated.state ?? '',
        filePath: updated.filePath ?? '',
        mimeType: updated.mimeType ?? '',
        dangerous: updated.dangerous === true,
        failReason: updated.failReason ?? '',
        revision: Date.now()
      }));
      if (updated.id && updated.id.length > 0) {
        this.downloadFilePaths[updated.id] = updated.filePath ?? '';
      }
      // The downloads page watches this tick and re-lists (throttled) so
      // progress on it moves while a download is running.
      AppStorage.setOrCreate('auraPanelDownloadsTick', Date.now());
      return;
    }

    if (event.event === 'downloadList') {
      const list = shellEvent<DownloadListEvent>(event).items ?? [];
      // 列表项的 filePath 常缺失（见 downloadFilePaths 注释）：用累积的
      // id→filePath 回填，确保下载页「安装 .crx」能取到真实路径。
      for (const it of list) {
        const id: string = it.id ?? '';
        const fp: string = it.filePath ?? '';
        if (fp.length === 0 && id.length > 0 && this.downloadFilePaths[id]) {
          it.filePath = this.downloadFilePaths[id];
        }
      }
      AppStorage.setOrCreate('auraPanelDownloads', JSON.stringify(list));
      return;
    }

    // 资源嗅探：引擎拦截媒体/图片子资源并归类后，经以下事件与外壳通信。
    // resourceList：listResources 的回包（含 resources 列表）；resourceActionResult：
    // downloadResource / clearResources 的回执；resourcesChanged：页面继续加载时
    // 引擎广播“有新增资源”，外壳据此重拉一次列表。
    if (event.event === 'resourceList') {
      AppStorage.setOrCreate('auraPanelResourceList', JSON.stringify(event));
      return;
    }
    if (event.event === 'resourceActionResult') {
      AppStorage.setOrCreate('auraPanelEvent', JSON.stringify(event));
      return;
    }
    if (event.event === 'resourcesChanged') {
      AppStorage.setOrCreate('auraPanelResourceTick', Date.now());
      return;
    }

    if (event.event === 'tabThumbnails') {
      AppStorage.setOrCreate('auraTabThumbnails',
        JSON.stringify(shellEvent<TabThumbnailsEvent>(event).items ?? []));
      return;
    }

    if (event.event === 'favicons') {
      AppStorage.setOrCreate('auraFavicons',
        JSON.stringify(shellEvent<FaviconsEvent>(event).items ?? []));
      return;
    }

    if (event.event === 'findResult') {
      AppStorage.setOrCreate('auraFindResult', JSON.stringify({
        matches: event.matches ?? 0,
        activeMatch: event.activeMatch ?? 0,
        revision: Date.now()
      }));
      return;
    }

    if (event.event === 'recentlyClosed') {
      AppStorage.setOrCreate('auraPanelRecent',
        JSON.stringify(shellEvent<RecentlyClosedEvent>(event).items ?? []));
      return;
    }

    if (event.event === 'savedPasswords') {
      const sp = shellEvent<SavedPasswordsEvent>(event);
      // 必须连同 requestId 一起存回（对齐 bookmarkList 的 {requestId,nodes}），
      // 否则面板 onPasswordsPayload 的 seq 校验永远对不上、回包被丢弃、卡"加载中"。
      AppStorage.setOrCreate('auraPanelPasswords',
        JSON.stringify({ requestId: sp.requestId ?? -1, items: sp.items ?? [] }));
      return;
    }
    if (event.event === 'passwordRevealed') {
      const revealed = shellEvent<PasswordRevealedEvent>(event);
      AppStorage.setOrCreate('auraPanelPasswordSecret',
        JSON.stringify({ requestId: revealed.requestId, id: revealed.id,
          password: revealed.password, note: revealed.note }));
      return;
    }
    if (event.event === 'passwordCommandResult') {
      const result = shellEvent<PasswordCommandResultEvent>(event);
      AppStorage.setOrCreate('auraPanelPasswordResult',
        JSON.stringify({ command: result.command, ok: result.ok, reason: result.reason ?? '' }));
      return;
    }
    // 密码导入 / 导出回包。面板用它决定保存框、结果提示
    // 与沙箱缓存清理。
    if (event.event === 'passwordsImported') {
      const imported = shellEvent<PasswordsImportedEvent>(event);
      AppStorage.setOrCreate('auraPanelPasswordIo', JSON.stringify({
        kind: 'import',
        requestId: imported.requestId,
        ok: imported.ok,
        imported: imported.imported ?? 0,
        skipped: imported.skipped ?? 0,
        failed: imported.failed ?? 0,
        reason: imported.reason ?? ''
      }));
      return;
    }
    if (event.event === 'passwordsExported') {
      const exported = shellEvent<PasswordsExportedEvent>(event);
      AppStorage.setOrCreate('auraPanelPasswordIo', JSON.stringify({
        kind: 'export',
        requestId: exported.requestId,
        ok: exported.ok,
        imported: 0,
        skipped: 0,
        failed: 0,
        count: exported.count ?? 0,
        reason: exported.reason ?? ''
      }));
      return;
    }
    // 书签导入 / 导出回包。
    if (event.event === 'bookmarkImportDone') {
      const done = shellEvent<BookmarkImportDoneEvent>(event);
      AppStorage.setOrCreate('auraPanelBookmarkIo', JSON.stringify({
        kind: 'import',
        requestId: done.requestId,
        ok: done.ok,
        bookmarkCount: done.bookmarkCount ?? 0,
        folderCount: done.folderCount ?? 0,
        skippedCount: done.skippedCount ?? 0,
        error: done.error ?? ''
      }));
      return;
    }
    if (event.event === 'bookmarkExportDone') {
      const done = shellEvent<BookmarkExportDoneEvent>(event);
      AppStorage.setOrCreate('auraPanelBookmarkIo', JSON.stringify({
        kind: 'export',
        requestId: done.requestId,
        ok: done.ok,
        bookmarkCount: done.bookmarkCount ?? 0,
        folderCount: done.folderCount ?? 0,
        skippedCount: 0,
        error: done.error ?? ''
      }));
      return;
    }
    if (event.event === 'siteSettings') {
      const settings = shellEvent<SiteSettingsEvent>(event);
      AppStorage.setOrCreate('auraPanelSiteSettings',
        JSON.stringify({ requestId: settings.requestId, items: settings.items ?? [] }));
      return;
    }

    if (event.event === 'browserChromeRequested') {
      // 引擎在运行时询问"谁画浏览器 chrome"。我们全程自绘，强制 shell 模式，
      // 否则引擎会按设备类型默认画出原生标签条（主页左上角那排被裁掉的图标）。
      this.executeBrowserCommand({ command: 'setBrowserChrome', mode: 'shell' });
      return;
    }

    if (event.event === 'browserControlsRatio') {
      this.sawControlsRatio = true;
      const ratio = event.ratio ?? 1;
      if (ratio !== this.lastControlsRatio) {
        const prev: number = this.lastControlsRatio;
        this.lastControlsRatio = ratio;
        AppStorage.setOrCreate('auraBrowserControlsRatio', ratio);
      }
      return;
    }

    // 下拉刷新：引擎自己判定「页面已到顶 + 不是内层滚动 + overscroll-behavior
    // 允许」并负责 reload，外壳只负责把指示器画出来（见 engine ShellServiceTypes
    // 的 PullToRefreshEvent）。整包转存，由 MobileBrowserOverlay 渲染：
    // start→阈值 / pull→已拉距离 / release→是否真的刷新 / reset→收起。
    if (event.event === 'pullToRefresh') {
      const pull = shellEvent<PullToRefreshEvent>(event);
      AppStorage.setOrCreate('auraPullRefresh', JSON.stringify({
        state: pull.state,
        threshold: pull.threshold ?? 0,
        distance: pull.distance ?? 0,
        refresh: pull.refresh ?? false,
        at: Date.now()
      }));
      return;
    }

    // Profile data for the shell's own pages (bookmarks / history / settings).
    // The payloads are parked in AppStorage and the mobile panels read them
    // through @StorageLink (see components/mobile/PanelBridge.ets).
    if (event.event === 'recentBookmarks') {
      AppStorage.setOrCreate('auraPanelBookmarks',
        JSON.stringify(shellEvent<RecentBookmarksEvent>(event).nodes ?? []));
      return;
    }
    // 分层书签树（getBookmarks/searchBookmarks 的回包）——书签页的文件夹
    // 导航/搜索基于它（bookmarkApiVersion 1-3 的稳定命令）。
    if (event.event === 'bookmarkList') {
      const listed = shellEvent<BookmarkListEvent>(event);
      AppStorage.setOrCreate('auraPanelBookmarkList', JSON.stringify({
        requestId: listed.requestId,
        parentId: listed.parentId ?? '',
        nodes: listed.nodes ?? []
      }));
      return;
    }
    if (event.event === 'historyResults') {
      AppStorage.setOrCreate('auraPanelHistory',
        JSON.stringify(shellEvent<HistoryResultsEvent>(event).items ?? []));
      return;
    }
    // 网页全屏（video / requestFullscreen）：契约要求外壳收起自己的条带并把
    // 窗口切沉浸（见 ShellServiceTypes.PageFullscreenChangedEvent），否则
    // 状态栏还占着一条、页面视口少一截，画面只能缩在黑边里。
    if (event.event === 'pageFullscreenChanged') {
      this.setPageFullscreen(shellEvent<PageFullscreenChangedEvent>(event).fullscreen === true);
      return;
    }
    // 地址栏联想（autocomplete 命令的回包）：引擎会按同一 requestId 流式推
    // 多次（本地历史/书签/搜索建议），直到 done 为 true。外壳整包转存，由
    // MobileBrowserOverlay 按"最新 requestId"过滤后渲染。
    if (event.event === 'autocompleteResults') {
      const auto = shellEvent<AutocompleteResultsEvent>(event);
      AppStorage.setOrCreate('auraAutocomplete', JSON.stringify({
        requestId: auto.requestId,
        items: auto.items ?? [],
        done: auto.done ?? true
      }));
      return;
    }
    if (event.event === 'prefs') {
      AppStorage.setOrCreate('auraPanelPrefs',
        JSON.stringify(shellEvent<PrefsEvent>(event).values ?? []));
      return;
    }
    // 广告拦截：getAdBlockState / setAdBlock* / updateAdBlockSources 的回包
    // （adBlockState / adBlockConfigResult），以及引擎主动推的 adBlockStateChanged。
    // 原样转给「设置 → 广告拦截」面板，由它自己解析 sources / revision / contextId。
    if (event.event === 'adBlockState' ||
      event.event === 'adBlockConfigResult' ||
      event.event === 'adBlockStateChanged') {
      AppStorage.setOrCreate('auraPanelAdBlock', JSON.stringify(event));
      return;
    }
    // 小锁快捷面板：广告拦截/防钓鱼的「单站」回包（读-改-写协议的两半）。
    // 原样转存，SiteQuickPanel 自己解析（两个开关各自的 contextId/revision/
    // navigationId 都在回包里，写回时原样带上）。
    if (event.event === 'adBlockPageState' ||
      event.event === 'adBlockSiteResult' ||
      event.event === 'siteProtectionState' ||
      event.event === 'siteProtectionConfigResult') {
      AppStorage.setOrCreate('auraPanelSiteQuick', JSON.stringify(event));
      return;
    }
    if (event.event === 'searchEngines') {
      const engines = shellEvent<SearchEnginesEvent>(event).items ?? [];
      AppStorage.setOrCreate('auraPanelEngines', JSON.stringify(engines));
      // Keep the home surface and the address bar searching the way the
      // settings page shows: the default engine's resolved template.
      const ctx = this.getUIContext().getHostContext() as common.Context | undefined;
      SearchEnginesPrefs.loadDefaultId(ctx).then((id: string): void => {
        let template = '';
        if (id.length > 0 && !id.startsWith('custom:')) {
          const hit = engines.find((e: SearchEngine): boolean => e.id === id);
          if (hit && hit.searchUrl && hit.searchUrl.length > 0) {
            template = hit.searchUrl;
          }
        }
        // 没命中再退回引擎上报的默认项（通常是 Bing）。
        if (template.length === 0) {
          for (const engine of engines) {
            if (engine.isDefault && engine.searchUrl && engine.searchUrl.length > 0) {
              template = engine.searchUrl;
              break;
            }
          }
        }
        if (template.length > 0) {
          AppStorage.setOrCreate('auraSearchUrlTemplate', template);
        }
        // 持久化默认是「自定义引擎」（引擎列表里不会出现），覆盖模板，
        // 保证重启后自定义默认搜索引擎仍然生效。
        if (id.startsWith('custom:')) {
          SearchEnginesPrefs.loadCustom(ctx).then((list: SearchEngine[]): void => {
            const hit = list.find((e: SearchEngine): boolean => e.id === id);
            if (hit && hit.searchUrl && hit.searchUrl.length > 0) {
              AppStorage.setOrCreate('auraSearchUrlTemplate', hit.searchUrl);
            }
          });
        }
      });
      return;
    }
    if (event.event === 'topSites') {
      AppStorage.setOrCreate('auraTopSites',
        JSON.stringify(shellEvent<TopSitesEvent>(event).items ?? []));
      return;
    }
    if (event.event === 'extensionActions') {
      AppStorage.setOrCreate('auraPanelExtensions',
        JSON.stringify(shellEvent<ExtensionActionsEvent>(event).items ?? []));
      return;
    }
    if (event.event === 'extensionDetails') {
      AppStorage.setOrCreate('auraPanelExtensionDetails',
        JSON.stringify(shellEvent<ExtensionDetailsEvent>(event)));
      return;
    }
    if (event.event === 'extensionActionsChanged') {
      AppStorage.setOrCreate('auraPanelEvent',
        JSON.stringify({ kind: 'extensionActionsChanged', revision: Date.now() }));
      return;
    }
    // 扩展「重新载入」的收到回执：引擎重载是异步的，这条只证明命令到达了
    // native，是否落地看随后的 extensionActionsChanged。
    if (event.event === 'extensionReloadReceived') {
      AppStorage.setOrCreate('auraPanelEvent',
        JSON.stringify({ kind: 'extensionReloadReceived', revision: Date.now() }));
      return;
    }
    // 扩展「重新载入」的落地回执：重载调用没有返回值，引擎只能把重载之后
    // 观察到的状态报回来，由外壳据此判断到底卡在哪一支。
    if (event.event === 'extensionReloadLanded') {
      const landed = shellEvent<ExtensionReloadLandedEvent>(event);
      AppStorage.setOrCreate('auraPanelEvent',
        JSON.stringify({
          kind: 'extensionReloadLanded',
          enabled: landed.enabled === true,
          blocked: landed.blocked === true,
          stuckReloading: landed.stuckReloading === true,
          pathExists: landed.pathExists === true,
          revision: Date.now()
        }));
      return;
    }
    // 原生扩展 popup 关闭：立刻收回主页盖层，不必再等兜底超时
    // （@Watch('onPopupHomeHoldChanged') 见 popupHomeHold 声明处）。
    if (event.event === 'extensionPopupClosed') {
      hilog.info(0x0000, 'ExtPanel', 'extensionPopupClosed received, hold -> 0');
      // 关闭时刻留戳：让位是转场结束后才置位的（ExtensionPanel.runExtension），
      // 置位前要比一下，避免 popup 早关后又被置位、主页层挂到 10 分钟兜底。
      AppStorage.setOrCreate('auraPopupClosedAt', Date.now());
      AppStorage.setOrCreate('auraPopupHomeHold', 0);
      // popup 早关时别让跳转遮盖留到兜底超时。
      AppStorage.setOrCreate('auraExtensionJumpCover', 0);
      return;
    }
    if (event.event === 'developerMode') {
      // 扩展页标题栏的「开发者模式」开关：引擎 profile pref 的回音。
      // 存 AppStorage 供 ExtensionPanel 读；setDeveloperMode 成功后引擎
      // 会立即回这个事件，所以开关状态永远以引擎为准。
      // revision 让 JSON 每次字节必变：同名同值回包（重开面板的
      // getDeveloperMode）不 otherwise 就唤不醒 @StorageLink 的 @Watch。
      const mode = shellEvent<DeveloperModeEvent>(event);
      AppStorage.setOrCreate('auraDeveloperMode',
        JSON.stringify({
          enabled: mode.enabled === true,
          available: mode.available !== false,
          revision: Date.now()
        }));
      return;
    }
    if (event.event === 'extensionInstallFailed') {
      const notice = shellEvent<ExtensionNoticePayload>(event);
      AppStorage.setOrCreate('auraPanelEvent',
        JSON.stringify({
          kind: 'extensionInstallFailed',
          revision: Date.now(),
          message: notice.message ?? '',
          reason: notice.reason ?? ''
        }));
      return;
    }
    if (event.event === 'extensionCommandFailed') {
      const notice = shellEvent<ExtensionNoticePayload>(event);
      AppStorage.setOrCreate('auraPanelEvent',
        JSON.stringify({
          kind: 'extensionCommandFailed',
          revision: Date.now(),
          message: notice.message ?? '',
          reason: notice.reason ?? '',
          command: notice.command ?? ''
        }));
      return;
    }
    if (event.event === 'aboutInfo') {
      const about = shellEvent<AboutInfoEvent>(event);
      AppStorage.setOrCreate('auraPanelAbout',
        JSON.stringify({ chromiumVersion: about.chromiumVersion ?? '' }));
      return;
    }
    if (event.event === 'browsingDataCounts') {
      AppStorage.setOrCreate('auraBrowsingDataCounts', JSON.stringify(event));
      return;
    }
    if (event.event === 'bookmarkCreated' ||
      event.event === 'bookmarksChanged' || event.event === 'historyChanged' ||
      event.event === 'prefsChanged' || event.event === 'clearBrowsingDataDone' ||
      event.event === 'savedPasswordsChanged') {
      // setPref 写入成功后引擎广播 prefsChanged{keys:[key]}：拿它当冷启动
      // 强制深色「已生效」的回执，收到就停掉补发，避免后续重绘被打断。
      if (event.event === 'prefsChanged' && !this.forceDarkStartupSynced &&
        JSON.stringify(event).indexOf('forceDarkWebContents') >= 0) {
        this.forceDarkStartupSynced = true;
        this.clearForceDarkStartupRetryTimers();
      }
      AppStorage.setOrCreate('auraPanelEvent',
        JSON.stringify({ kind: event.event, revision: Date.now() }));
      return;
    }

    if (event.event === 'contextMenuRequested') {
      // 手机：启动配置里 contextMenu 是 'shell'，引擎不弹自己的菜单，由外壳
      // 画。v13 起手机画自绘卡片——model 序列化进 AppStorage，
      // MobileBrowserOverlay 渲染；平板 / 2in1 还没有那块 UI，维持系统动作
      // 面板。没有可显示项时立刻回一条 dismissed，引擎在等这一条。
      if (this.isMobilePhoneUi()) {
        const model: ContextMenuModel | undefined = buildContextMenuModel(event);
        if (model === undefined) {
          this.executeBrowserCommand({ command: 'contextMenuDismissed', requestId: event.requestId ?? 0 });
        } else {
          AppStorage.setOrCreate('auraContextMenu', JSON.stringify(model));
        }
      } else {
        showContextMenuSheet(this.getUIContext(), event, (command: BrowserCommandPayload): void => {
          this.executeBrowserCommand(command);
        });
      }
      return;
    }

    if (event.event === 'contextMenuActionsChanged') {
      // 菜单还开着时补点亮某项（例如"复制指向所选文字的链接"要等渲染器
      // 生成文字片段）。只更新同一 requestId 的那张卡；没有卡就忽略。
      const current: ContextMenuModel | undefined =
        parseContextMenuModel(AppStorage.get<string>('auraContextMenu') ?? '');
      if (current !== undefined && current.requestId === (event.requestId ?? 0)) {
        const updated: ContextMenuModel | undefined = updateContextMenuModel(current, event);
        if (updated === undefined) {
          AppStorage.setOrCreate('auraContextMenu', '');
          this.executeBrowserCommand({ command: 'contextMenuDismissed', requestId: current.requestId });
        } else {
          AppStorage.setOrCreate('auraContextMenu', JSON.stringify(updated));
        }
      }
      return;
    }

    if (event.event === 'pageDragStarted') {
      // 手指开始拖动（长按后移开，或在页面里拖东西）：把还开着的长按菜单
      // 收掉。引擎在等一条回复。
      const dragged: ContextMenuModel | undefined =
        parseContextMenuModel(AppStorage.get<string>('auraContextMenu') ?? '');
      if (dragged !== undefined) {
        AppStorage.setOrCreate('auraContextMenu', '');
        this.executeBrowserCommand({ command: 'contextMenuDismissed', requestId: dragged.requestId });
      }
      return;
    }

    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      if (event.event === 'filePickerRequested') {
        this.completeFilePicker({
          requestId: event.requestId ?? 0,
          paths: [],
          fileTypeIndex: event.fileTypeIndex ?? 0,
          canceled: true
        });
      }
      return;
    }
    if (event.event === 'systemPrintReady' && event.filePath) {
      SystemPrintAdapter.printPdf(context, event.filePath).catch((error: Error): void => {
        console.error('System print failed:', error);
      });
    } else if (event.event === 'shareRequested' && event.url) {
      HuaweiShareAdapter.sharePage(context, event.url, event.title ?? event.url)
        .catch((error: Error): void => {
          console.error('Huawei Share failed:', error);
        });
    } else if (event.event === 'castRequested') {
      this.currentTabCastSession.openPicker(context, this.browserState)
        .catch((error: Error): void => {
          console.error('HarmonyOS cast picker failed:', error);
        });
    } else if (event.event === 'filePickerRequested') {
      HarmonyFilePickerAdapter.show(context, event)
        .then((result: HarmonyFilePickerResult): void => {
          this.completeFilePicker(result);
        })
        .catch((error: Error): void => {
          console.error('HarmonyOS file picker failed:', error);
          this.completeFilePicker({
            requestId: event.requestId ?? 0,
            paths: [],
            fileTypeIndex: event.fileTypeIndex ?? 0,
            canceled: true
          });
        });
    } else if (event.event === 'permissionsRequested') {
      PermissionRequestAdapter.request(context, event)
        .then((result: PermissionRequestResultPayload): void => {
          this.completePermissionRequest(result);
        })
        .catch((error: Error): void => {
          console.error('HarmonyOS permission request failed:', error);
          this.completePermissionRequest({
            requestId: event.requestId ?? 0,
            granted: [],
            denied: event.permissions ?? []
          });
        });
    } else if (event.event === 'systemActionRequested' && event.action) {
      SystemIntegrationAdapter.handle(context, event.action as ChromiumSystemAction)
        .catch((error: Error): void => {
          console.error(`HarmonyOS system action failed: ${error.message}`);
        });
    } else if (event.event === 'externalUrlRequested') {
      this.handleExternalUrl(context, event);
    } else if (event.event === 'systemPrintFailed') {
      console.error(`Chromium PDF generation failed: ${event.reason ?? 'unknown'}`);
    }
  }

  /**
   * 网页里的外链（引擎已把 Android intent 转成对应 scheme，如 zhihu://、
   * bilibili://）。先问用户要不要离开浏览器，再用系统把它交给本机应用；
   * 用户拒绝或本机没有应用接得住，就退回浏览器打开 fallbackUrl。
   *
   * 不要拿 bundleManager.canOpenLink 来判断"有没有应用接得住"：它只认本应用
   * module.json5 的 querySchemes 里声明过的 scheme，碰到 zhihu://、bilibili://
   * 这种没声明的会直接抛 17700056，被 catch 吞掉后永远判成"没人接得住"，
   * 于是跳转永远不发生（点"打开 App"没反应就是这么来的）。能不能交出去，
   * 让 startAbility/openLink 自己报错更可靠。
   */
  private handleExternalUrl(context: common.UIAbilityContext, event: BrowserRuntimeEvent): void {
    const fallbackUrl: string = event.fallbackUrl ?? '';
    const target: string = (event.url ?? '').trim();

    // 开关关掉：一律留在浏览器里，不打扰用户。
    if (!this.externalAppLinks || target.length === 0) {
      this.openInBrowser(fallbackUrl);
      return;
    }

    // 标题用发起页的域名（引擎的 initiator 是 origin），和本机浏览器一致，
    // 读者一眼能看出是哪个网页想跳出去。
    const sourceHost: string = this.externalLinkSourceHost(event.initiator ?? '');
    AlertDialog.show({
      title: `${sourceHost}想打开其它应用`,
      message: '允许后会离开 Orbira，在对应的应用里继续。',
      primaryButton: {
        value: '取消',
        action: (): void => {
          // 用户不想跳：有 fallback 就留在浏览器里打开它。
          this.openInBrowser(fallbackUrl);
        }
      },
      secondaryButton: {
        value: '允许',
        action: (): void => {
          this.launchExternalApp(context, target, fallbackUrl);
        }
      }
    });
  }

  /**
   * 交给系统打开：https 链接走系统 App Linking（域名校验过的），其余 scheme
   * 走隐式 want 的 viewData —— 目标应用 skills 声明的就是 action + uri。
   * 报错说明本机没应用接得住，再让系统只按 uri 路由一次兜底，最后才留在
   * 浏览器里打开 fallbackUrl。
   */
  private launchExternalApp(context: common.UIAbilityContext, target: string, fallbackUrl: string): void {
    const isWebLink: boolean = target.startsWith('http://') || target.startsWith('https://');
    const want: Want = { action: 'ohos.want.action.viewData', uri: target };
    const attempt: Promise<void> = isWebLink
      ? context.openLink(target, { appLinkingOnly: true, hideFailureTipDialog: true })
      : context.startAbility(want);
    attempt.catch((): void => {
      context.openLink(target, { appLinkingOnly: false, hideFailureTipDialog: true })
        .catch((error: Error): void => {
          console.error(`No app takes external link ${target}: ${error.message}`);
          // 本机确实没有应用接得住（例如没装知乎）：退回网页版。
          this.openInBrowser(fallbackUrl);
        });
    });
  }

  // 发起页的域名（引擎的 initiator 形如 https://zhuanlan.zhihu.com）。
  // 浏览器自己发起的链接（设置里的 mailto:）没有 origin，返回空串给标题兜底。
  private externalLinkSourceHost(initiator: string): string {
    const value: string = initiator.trim();
    if (value.length === 0) {
      return '';
    }
    const withoutScheme: string = value.replace(/^[a-z][a-z0-9+.-]*:\/\//i, '');
    const cut: number = withoutScheme.search(/[/?#]/);
    const host: string = cut < 0 ? withoutScheme : withoutScheme.substring(0, cut);
    return host.length > 0 ? `${host} ` : '';
  }

  private openInBrowser(url: string): void {
    if (url.length === 0) {
      return;
    }
    this.executeBrowserCommand({ command: 'navigate', url: url });
  }

  private completeFilePicker(result: HarmonyFilePickerResult): void {
    this.executeBrowserCommand({
      command: 'filePickerResult',
      requestId: result.requestId,
      paths: result.paths,
      fileTypeIndex: result.fileTypeIndex,
      canceled: result.canceled
    });
  }

  // Tells the engine the top bar's extent once the surface is live
  // (SHELL_CONTRACT.md, "手机：滚动时收起地址栏和 dock", step 2). The engine
  // then drives its scroll-away and reports browserControlsRatio events to
  // move both bars.
  //
  // The dock is deliberately NOT sent as bottom controls (bottom: 0). A
  // non-zero bottom is counted into the top controls, so the engine takes
  // that strip out of the renderer's size: the page then ends above the dock
  // and the strip behind it is never page paint -- the opaque block behind
  // the floating dock. With 0 the page draws to the bottom of the window and
  // the dock floats over it; it still hides and returns with the top bar on
  // the same ratio, which the engine reports the same way either way.
  private configureBrowserControls(): void {
    if (this.browserControlsConfigured) {
      return;
    }
    this.browserControlsConfigured = true;
    // The fullscreen-immersive window draws under the status bar, so the
    // page's reserved extent includes it (EntryAbility stores it in vp).
    // minTop 0 keeps the page free to start at the very top, unless the
    // "hide the address bar on scroll" toggle is off: then minTop holds
    // the full height and the bar never collapses (engine ratio locked 1).
    this.sendBrowserControls();
    // 底部不再报任何高度（连手势条也不报）。内核会把这里的 bottom 从**布局**
    // 尺寸里整段扣掉（ohos-browser-controls.patch → OhosReservedHeight →
    // GetRequestedRendererSizeDevicePx），网页于是根本不往那一条画——手势条
    // 区"空一块"就是这么来的。传 0 后网页画满整窗到底，手势条只是浮在网页
    // 上的系统指示器；dock 默认同理（bottom 0 + 自绘浮层，不替网页占位），
    // 例外：dock 设为常驻（不随滚动收起）时它永久盖住一条，那一条要报进去，
    // 否则页面最后一行永远看不到——见 applyDockViewportInset。
    this.applyDockViewportInset();
    // Pull the search engines once, so the home surface and the address bar
    // search the same way the settings page shows before it has been opened.
    this.requestSearchEngines();
    this.scheduleBrowserControlsRetry(1);
  }

  private requestSearchEngines(): void {
    this.searchEnginesRequestSeq += 1;
    this.executeBrowserCommand({
      command: 'getSearchEngines',
      requestId: this.searchEnginesRequestSeq
    });
  }

  private desktopSitesRetries: number = 0;

  private desktopSitesSynced: boolean = false;

  private syncDesktopSites(): void {
    // 只在启动时跑一轮：onBrowserState 每次状态更新都会进 ready 分支，
    // 不加闸门会不断重排重试，形成命令洪水（页面反复加载、脚本卡死）。
    // 重试耗尽同样要停：名单为空（没配桌面站点、总开关也没开）时闸门永远
    // 落不下来，缺这一条会每次状态轮询都白跑一遍。
    if (this.desktopSitesSynced || this.desktopSitesRetries >= 3) {
      return;
    }
    const sites: string = String(AppStorage.get('auraDesktopSites') ?? '');
    const allSites: boolean =
      String(AppStorage.get('auraUaDefault') ?? 'mobile') === 'desktop';
    // 不在这里 return：名单是异步从 preferences 读进来的，第一次调用时可能还是
    // 空的。始终留着重试，等它读出来再送一次。
    if (sites.length > 0 || allSites) {
      this.executeBrowserCommand({
        command: 'setDesktopSites',
        sites: sites,
        allSites: allSites,
        mobileSites: String(AppStorage.get('auraMobileSites') ?? '')
      });
      // 闸门只在名单真的发出去之后才落。放在发送判断之前会让重试的第二跳被
      // 开头闸门挡死：名单异步读出前闸门已关，迟到的名单永远补发不了。
      this.desktopSitesSynced = true;
    }
    if (this.desktopSitesRetries < 3) {
      this.desktopSitesRetries += 1;
      setTimeout((): void => {
        this.syncDesktopSites();
      }, 1500);
    }
  }

  // 启动兜底重发：每 1.5s 检查一次、最多 8 次（约 12s）。重发全部幂等，
  // 且只会在"配置未生效"时发生（此状态下本就没有收起动作，不会打断用户）。
  private scheduleBrowserControlsRetry(attempt: number): void {
    if (attempt > 8) {
      return;
    }
    setTimeout((): void => {
      if (this.sawControlsRatio) {
        return;
      }
      this.sendBrowserControls();
      this.applyDockViewportInset();
      this.requestSearchEngines();
      this.scheduleBrowserControlsRetry(attempt + 1);
    }, 1500);
  }

  // Chromium resolves a site's geolocation request against the app's own
  // permission before prompting, so it needs to know that permission. Reported
  // once the native side is live, and again after any request that could have
  // changed it.
  private reportSystemPermissionState(): void {
    // Subscribing here rather than at startup keeps the two together: the
    // report is only useful once the native side can receive it, and the
    // subscription exists to send the same report again when the user changes
    // the permission somewhere this shell cannot see.
    PermissionRequestAdapter.observeLocation((): void => {
      this.reportSystemPermissionState();
    });
    const state = PermissionRequestAdapter.locationState();
    hilog.info(0x0000, 'OhosPerm', 'reporting systemPermissionState=%{public}s', state);
    this.executeBrowserCommand({
      command: 'systemPermissionState',
      location: state
    });
  }

  private systemPermissionReported: boolean = false;
  private browserControlsConfigured: boolean = false;
  // 引擎开始上报收起比例 = 启动时的 browser controls 配置确实生效了。
  // 见 scheduleBrowserControlsRetry：收不到就兜底重发。
  private sawControlsRatio: boolean = false;
  private lastControlsRatio: number = -1;
  private searchEnginesRequestSeq: number = 0;

  private completePermissionRequest(result: PermissionRequestResultPayload): void {
    this.reportSystemPermissionState();
    this.executeBrowserCommand({
      command: 'permissionResult',
      requestId: result.requestId,
      granted: result.granted,
      denied: result.denied
    });
  }

  private handleAuxiliaryWindowState(state: AuxiliaryWindowState): void {
    if (state.windowRole === 'pwa') {
      this.handlePwaWindowState(state);
      return;
    }
    if (!this.isFullscreenWindow() && state.pictureInPicture !== true &&
      this.findAuxiliaryWindow(state.widget)?.state.pictureInPicture !== true) {
      return;
    }

    const previous = this.findAuxiliaryWindow(state.widget);
    const remaining = this.auxiliaryWindows.filter(
      (view: AuxiliaryWindowView): boolean => view.state.widget !== state.widget
    );
    if (state.visible && !state.destroyed) {
      const modal = state.modal ?? previous?.modal ?? false;
      remaining.push(this.layoutAuxiliary(state, modal, previous));
      remaining.sort((left: AuxiliaryWindowView, right: AuxiliaryWindowView): number =>
        left.state.stackingOrder - right.state.stackingOrder);
    }

    this.auxiliaryWindows = remaining;
    const focusable = remaining.filter(
      (view: AuxiliaryWindowView): boolean => view.state.anchored !== true);
    this.activeAuxiliaryWidget =
      focusable.length > 0 ? focusable[focusable.length - 1].state.widget : 0;
  }

  private handlePwaWindowState(state: AuxiliaryWindowState): void {
    if (state.destroyed || !state.visible) {
      this.launchingPwaWidgets = this.launchingPwaWidgets.filter(
        (widget: number): boolean => widget !== state.widget);
      return;
    }
    if (this.launchingPwaWidgets.includes(state.widget)) {
      return;
    }

    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    this.launchingPwaWidgets.push(state.widget);
    PwaWindowLauncher.launch(context, state, this.startupConfigText, this.profileId)
      .catch((error: Error): void => {
        this.launchingPwaWidgets = this.launchingPwaWidgets.filter(
          (widget: number): boolean => widget !== state.widget);
        console.error('Failed to launch the PWA system window:', error);
        this.requestAuxiliaryWindowDismiss(state.widget);
      });
  }

  private requestAuxiliaryWindowDismiss(widget: number): void {
    if (widget <= 0) {
      return;
    }
    this.auxiliaryDismissWidget = widget;
    this.auxiliaryDismissRevision += 1;
  }

  private holdHomeForPaint(): void {
    // 淡出用显式 animateTo，避免 .animation() 在释放时也做淡入。
    animateTo({ duration: 180, curve: Curve.EaseOut }, (): void => {
      this.homeHold = true;
    });
    this.homeHoldSawLoading = false;
    this.homeHoldExtensions = 0;
    if (this.homeHoldQuickTimer !== -1) {
      clearTimeout(this.homeHoldQuickTimer);
      this.homeHoldQuickTimer = -1;
    }
    if (this.homeHoldGraceTimer !== -1) {
      clearTimeout(this.homeHoldGraceTimer);
      this.homeHoldGraceTimer = -1;
    }
    this.armHomeHoldTimer(8000);
    // 顶部装饰（状态栏/地址栏）跟着主页淡出一起走：延迟 120ms 再切成网页态，
    // 与 180ms 淡出重合，避免「地址栏先出来、网页区后到」的割裂。
    this.armHomeExitHold();
    // 状态栏图标色在淡出过半（120ms）时交回主题色：太早会在壁纸上闪黑图标，
    // 太晚白图标会在浅色网页顶栏上消失。
    if (this.homeExitInkTimer !== -1) {
      clearTimeout(this.homeExitInkTimer);
    }
    this.homeExitInkTimer = setTimeout((): void => {
      this.homeExitInkTimer = -1;
      const seq: number = Number(AppStorage.get('auraHomeExitInk') ?? 0);
      AppStorage.setOrCreate('auraHomeExitInk', seq + 1);
    }, 120);
  }

  private armHomeHoldTimer(ms: number): void {
    if (this.homeHoldTimer !== -1) {
      clearTimeout(this.homeHoldTimer);
    }
    this.homeHoldTimer = setTimeout((): void => {
      this.homeHoldTimer = -1;
      if (!this.homeHold) {
        return;
      }
      if (this.browserState.loading && this.homeHoldExtensions < 8) {
        this.homeHoldExtensions += 1;
        this.armHomeHoldTimer(6000);
        return;
      }
      this.releaseHomeHold();
    }, ms);
  }

  // 顶部装饰随主页淡出一起切：120ms 后放开，顶栏才按网页态画地址栏。
  private armHomeExitHold(): void {
    this.homeExitHold = true;
    if (this.homeExitHoldTimer !== -1) {
      clearTimeout(this.homeExitHoldTimer);
    }
    this.homeExitHoldTimer = setTimeout((): void => {
      this.homeExitHoldTimer = -1;
      this.homeExitHold = false;
    }, 120);
  }

  // 取消顶栏延迟切态。只能在回主页时调：releaseHomeHold 在导航完成时也会跑，
  // 放那里会提前取消掉延迟。
  private cancelHomeExitHold(): void {
    if (this.homeExitHoldTimer !== -1) {
      clearTimeout(this.homeExitHoldTimer);
      this.homeExitHoldTimer = -1;
    }
    this.homeExitHold = false;
  }

  // cancelExitInk 只在「回主页 / 导航被撤销」时传 true：那时主页仍可见，
  // 交还主题色会让壁纸上闪一下黑图标。导航确实进了网页时不能取消，否则
  // 状态栏会一直停在壁纸反色上，白图标压在浅色网页顶栏。
  // 落地后再留一小段首帧宽限，与 homeTransition 的判据一致。
  private scheduleHomeHoldRelease(): void {
    if (!this.homeHold || this.homeHoldGraceTimer !== -1) {
      return;
    }
    this.homeHoldGraceTimer = setTimeout((): void => {
      this.homeHoldGraceTimer = -1;
      if (this.homeHold) {
        this.releaseHomeHold();
      }
    }, 120);
  }

  private releaseHomeHold(cancelExitInk: boolean = false): void {
    this.homeHold = false;
    if (this.homeHoldGraceTimer !== -1) {
      clearTimeout(this.homeHoldGraceTimer);
      this.homeHoldGraceTimer = -1;
    }
    if (cancelExitInk && this.homeExitInkTimer !== -1) {
      clearTimeout(this.homeExitInkTimer);
      this.homeExitInkTimer = -1;
    }
    if (this.homeHoldTimer !== -1) {
      clearTimeout(this.homeHoldTimer);
      this.homeHoldTimer = -1;
    }
    if (this.homeHoldQuickTimer !== -1) {
      clearTimeout(this.homeHoldQuickTimer);
      this.homeHoldQuickTimer = -1;
    }
  }

  // 主页键：立即铺主页层（见 homeReturnCover 注释）。1.2s 兜底撤防，防止
  // 引擎没响应 home 命令时主页层一直盖着。
  private beginHomeReturnCover(): void {
    // 回主页必须立刻可见：网页未加载完就按主页键时 homeHold 可能仍为 true，
    // 不撤会露出下面的白底垫层，并多一次半透明淡入。
    this.releaseHomeHold(true);
    // 已经在回主页的路上了：顶栏的「延迟切网页态」立刻取消，别让它再晚 120ms。
    this.cancelHomeExitHold();
    this.homeReturnCover = true;
    if (this.homeReturnTimer !== -1) {
      clearTimeout(this.homeReturnTimer);
    }
    this.homeReturnTimer = setTimeout((): void => {
      this.homeReturnTimer = -1;
      if (!this.homeReturnCover) {
        return;
      }
      if (!this.isNewTabPage() && !this.homeRetryDone) {
        this.homeRetryDone = true;
        this.executeBrowserCommand({ command: 'home' });
        this.beginHomeReturnCover();
        return;
      }
      this.homeRetryDone = false;
      this.homeReturnCover = false;
    }, 1200);
  }

  private releaseHomeReturnCover(): void {
    this.homeReturnCover = false;
    this.homeRetryDone = false;
    if (this.homeReturnTimer !== -1) {
      clearTimeout(this.homeReturnTimer);
      this.homeReturnTimer = -1;
    }
  }

  private isNewTabPage(): boolean {
    return isNewTabUrl(this.browserState.url ?? '') || this.engineHomeCovered();
  }

  // 内置启动主页层要不要挂。在原来的 isNewTabPage() 基础上多一条
  // 冷启动预热判据：本次启动目标是真网址、且还没被引擎提交上来时，browserState
  // 仍是 EMPTY_BROWSER_STATE（url = chrome://newtab），照旧判定会先闪一帧内置
  // 启动页。预热期返回 false，交给 NavCoverView 那块同色底顶着。
  private homeSurfaceVisible(): boolean {
    if (this.popupHomeHold > 0) {
      return false;
    }
    // 引擎确实停在新标签页时主页层必须在场，且不能被转场状态藏掉：
    // 少挂一帧就会露出引擎的原生磁贴页。回主页、前进后退、停止加载
    // 都靠这一条收口，不再让 navCover 的判定参与主页态。
    if (this.isNewTabPage()) {
      return true;
    }
    if (this.homeHold || this.homeReturnCover) {
      return true;
    }
    if (this.navCover && !this.navCoverHistoryNav) {
      return false;
    }
    return false;
  }

  // 主页层缺席时是否要铺同色底。过渡态（离开/返回主页、历史导航落点）铺，盖住
  // 引擎原生 NTP 磁贴页到首帧的空窗；主页态本身不透明、popup 让位期不铺。
  private needsHomeBackdrop(): boolean {
    return this.navCover || this.homeTransition;
  }

  // 导航预热层。用 browser_canvas（外壳底同色）铺满，淡出时不会
  // 出现第二种颜色；退场动画挂在 if 分支根节点上才播得出来。
  @Builder
  private NavCoverView() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.browser_canvas'))
      // 历史导航用短淡出：切换不该因为过渡动画再等 200ms。值在起防时定，
      // releaseNavCover 不清它，这样淡出这一帧读到的仍是本次起防设定的时长。
      // 出现时硬切不透明：双向 opacity 会在插入那一帧淡入，正好露出引擎
      // 还没换掉的原生 NTP 磁贴。只在移除时淡出。
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.opacity(1),
        TransitionEffect.opacity(0).animation({ duration: this.navCoverFadeMs, curve: Curve.Friction })
      ))
  }

  // 打开已休眠标签的遮盖：复用 browser_canvas 同色底，与 NavCoverView 画法一致，
  // 但由独立的 discardedCover 状态驱动，和 homeTransition / navCover 互不干扰。
  @Builder
  private DiscardedCoverView() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.browser_canvas'))
      .transition(TransitionEffect.opacity(0).animation({ duration: 100, curve: Curve.Friction }))
  }

  private engineHomeCovered(): boolean {
    const url = this.browserState.url ?? '';
    if (isNewTabUrl(url)) {
      return false;
    }
    if (this.browserState.loading || this.browserState.canGoBack) {
      return false;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return false;
    }
    const title = (this.browserState.title ?? '').trim();
    if (title.length === 0) {
      return true;
    }
    return this.newTabTitleSeen.length > 0 && title === this.newTabTitleSeen;
  }

  private isMobilePhoneUi(): boolean {
    if (!this.startupConfigText || this.startupConfigText.trim().length === 0) {
      return this.browserState.uiFamily === 'mobile_phone';
    }

    try {
      const startupConfig = JSON.parse(this.startupConfigText) as Record<string, Object>;
      return String(startupConfig['uiFamily'] ?? '') === 'mobile_phone';
    } catch (error) {
      return this.browserState.uiFamily === 'mobile_phone';
    }
  }

  private isDesktopAuraUi(): boolean {
    if (!this.startupConfigText || this.startupConfigText.trim().length === 0) {
      return this.browserState.uiFamily === 'aura_pc' ||
        this.browserState.uiFamily === 'aura_tablet';
    }
    try {
      const startupConfig = JSON.parse(this.startupConfigText) as Record<string, Object>;
      const uiFamily = String(startupConfig['uiFamily'] ?? '');
      return uiFamily === 'aura_pc' || uiFamily === 'aura_tablet';
    } catch (error) {
      return this.browserState.uiFamily === 'aura_pc' ||
        this.browserState.uiFamily === 'aura_tablet';
    }
  }

  private isFullscreenWindow(): boolean {
    if (!this.startupConfigText || this.startupConfigText.trim().length === 0) {
      return this.isMobilePhoneUi();
    }
    try {
      const startupConfig = JSON.parse(this.startupConfigText) as Record<string, Object>;
      return String(startupConfig['windowMode'] ?? '') === 'fullscreen';
    } catch (error) {
      return this.isMobilePhoneUi();
    }
  }
}
