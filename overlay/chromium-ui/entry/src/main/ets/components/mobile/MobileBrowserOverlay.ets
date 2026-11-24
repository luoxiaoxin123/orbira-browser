import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { AVCastPicker, AVCastPickerColorMode, AVCastPickerStyle } from '@kit.AVSessionKit';
import { hdsEffect, hdsMaterial, HdsTabs, HdsTabsFloatingStyle } from '@kit.UIDesignKit';
import { inputMethod } from '@kit.IMEKit';
import { http } from '@kit.NetworkKit';
import { curves, promptAction } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import router from '@ohos.router';
import display from '@ohos.display';
import { showSystemPasteDialog } from './SystemPasteDialog';
import { ScanService } from './ScanService';
import { TabThumbnailStore } from '../../utils/TabThumbnailStore';
import { isNewTabUrl as isNewTabUrlShared } from '../../utils/NewTabUrl';
import {
  AutocompleteItem,
  BrowserCommandPayload,
  BrowserStateSnapshot,
  BrowserTabState,
  ContextMenuAction,
  TabThumbnail,
  openDownloadedFile
} from 'engine';
import { HuaweiShareAdapter } from 'engine';
import { GripSide, HoldingHandRouter } from './HoldingHandRouter';
import { SiteQuickPanel } from './SiteQuickPanel';
import { BrowserCommandBus } from '../../bus/BrowserCommandBus';
import { CurrentTabCastSession } from './CurrentTabCastSession';
import {
  ContextMenuItem,
  ContextMenuModel,
  EMPTY_CONTEXT_MENU_MODEL,
  parseContextMenuModel,
  shellCopyTextFor
} from './ContextMenuSheet';
import { MobileBackRouter } from './MobileBackRouter';
import { normalizeAddress, searchUrlFor } from './ShellUtils';
import { ShellUiPrefs } from '../../utils/appearance/ShellUiPrefs';
import { IncognitoSwitch, SavedTab } from '../../utils/IncognitoSwitch';

// App 内下载通知条（snackbar）的数据契约。AuraShell 在 downloadUpdated
// 事件里把单条下载项转存进 AppStorage（auraDownloadEvent），本组件消费。
// 与 DownloadItem 同名字段语义一致（见 engine ShellServiceTypes）。
interface DownloadEventPayload {
  id: string;
  fileName: string;
  url: string;
  state: string;
  filePath: string;
  mimeType: string;
  dangerous: boolean;
  failReason: string;
  revision: number;
}

// 通知条状态。start=开始下载 / done=完成 / failed=失败 /
// dangerous=危险文件（引擎标 dangerous，只提示不动作）。
// 用 enum 不用字面量联合：ArkTS 不支持索引访问类型（DownloadSnackState['kind']
// 报 arkts-no-aliases-by-index，10605028），枚举与工程 MobileEdgeAction 同款。
enum DownloadSnackKind {
  START = 'start',
  DONE = 'done',
  FAILED = 'failed',
  DANGEROUS = 'dangerous'
}

interface DownloadSnackState {
  id: string;
  name: string;
  kind: DownloadSnackKind;
  filePath: string;
  mimeType: string;
  isCrx: boolean;
}

// 空态常量：downloadSnack 恒非空（可见性由 downloadSnackVisible 控制）——
// @Builder 内直接解引用，避开可空 @State 在构建函数里的解析坑。
const EMPTY_DOWNLOAD_SNACK: DownloadSnackState = {
  id: '',
  name: '',
  kind: DownloadSnackKind.START,
  filePath: '',
  mimeType: '',
  isCrx: false
};

// 通知条固定高 52vp（内容限一行，动作按钮紧凑）；与 dock 的间距。
const DOWNLOAD_SNACK_HEIGHT_VP: number = 52;
const DOWNLOAD_SNACK_GAP_VP: number = 8;

export const TOP_BAR_EXTENT_VP: number = 48;
export const CHROME_DOCK_EXTENT_VP: number = 48;
export const CHROME_DOCK_FLOAT_MARGIN_VP: number = 16;
// Dock height 48 + container top breathing 12: the bar must travel far
// enough to fully leave the screen when the page scrolls (controlsRatio 0).
export const BOTTOM_DOCK_EXTENT_VP: number = 60;

// The glass bar itself (the Row inside the dock's container): the material
// plate and the painted fallback must agree on it exactly.
// 48vp：同一台手机截图实测，胶囊
// 167px ≈ 48vp，我们的 62 画出来 218px，并排就是"太粗"。
const DOCK_BAR_HEIGHT_VP: number = 48;
const DOCK_BAR_RADIUS_VP: number = 24;
const DOCK_SIDE_MARGIN_VP: number = 36;
// HdsTabs 的 barWidth 按 tabs 宽度断点选档（<440 / 440~600 / >840）。手机竖屏
// ≈386、横屏 ≈849 分居两端，断点切换若沿用旧档，bar 会停在另一方向的宽度上
// （竖屏下比屏幕宽、圆角被裁 = dock 卡成长条）。故横竖屏各一个分支重建。
const DOCK_PLATE_WIDE_BREAKPOINT_VP: number = 600;
const DOCK_SLOT_WIDTH_VP: number = 65;

function resolveDockBottomMarginVp(safeVp: number): number {
  return Number.isFinite(safeVp) ? Math.max(safeVp, 0) : 0;
}

// 底栏常驻（“滚动时隐藏底部栏”关）时它永久盖住的高度：与收起行程同一套几何。
// AuraShell 用它给网页报底部视口内距，页面末尾才能滚到 dock 上方。
export function dockCoveredHeightVp(bottomSafeVp: number): number {
  return BOTTOM_DOCK_EXTENT_VP + resolveDockBottomMarginVp(bottomSafeVp);
}

// 各家"联想词"接口响应 → 建议词数组（纯字符串解析，规避 ArkTS 的动态 JSON
// 限制）。支持三种形态：
//   百度   window.baidu.sug({q:"…",p:false,s:["a","b"]})  （或 cb({…})）
//   必应   api.bing.com/osjson.aspx      → ["q",["a","b"]]
//   谷歌   suggestqueries.google.com     → ["q",["a","b"]]
//   搜狗   window.sogou.sug(["q",["a","b"],…])
export function parseSuggestionWords(raw: string): string[] {
  const out: string[] = [];
  const text = raw.trim();
  if (text.length === 0) {
    return out;
  }
  let inner = '';
  // 百度 sugrec 形态：{"q":"x","g":[{"type":"sug","sa":"…","q":"联想词"}…]}
  // —— 逐个抽 `"q":"…"`（跳过第一处回显，它没有对象包裹）。标记用 `"g":`
  // 连冒号匹配：bing 的 `["g",…]`（搜单字母 g）不会误触发。
  const gIndex = text.indexOf('"g":');
  if (gIndex >= 0) {
    let cursor = gIndex + 4;
    while (out.length < 8) {
      const qKey = text.indexOf('"q":"', cursor);
      if (qKey < 0) {
        break;
      }
      const valueStart = qKey + 5;
      const valueEnd = text.indexOf('"', valueStart);
      if (valueEnd < 0) {
        break;
      }
      const word = text.substring(valueStart, valueEnd);
      if (word.length > 0 && out.indexOf(word) < 0) {
        out.push(word);
      }
      cursor = valueEnd + 1;
    }
    return out;
  }
  const first = text.indexOf('[');
  const last = text.lastIndexOf(']');
  if (first >= 0 && last > first) {
    const outer = text.substring(first, last + 1);
    const second = outer.indexOf('[', 1);
    if (second >= 0) {
      // 数组形态（bing `["q",["a","b"]]` / google / sogou）：取内层数组。
      const close = outer.indexOf(']', second + 1);
      inner = close > second ? outer.substring(second + 1, close) : '';
    } else {
      // 平数组形态（baidu `{…,s:["a","b"]}` 且词里无 '['）：外层即词表。
      inner = outer.substring(1, outer.length - 1);
    }
  }
  if (inner.length === 0) {
    return out;
  }
  const parts = inner.split('","');
  for (let i = 0; i < parts.length; i++) {
    let word = parts[i].trim();
    if (word.startsWith('"')) {
      word = word.substring(1);
    }
    if (word.endsWith('"')) {
      word = word.substring(0, word.length - 1);
    }
    if (word.length > 0 && out.indexOf(word) < 0 && out.length < 8) {
      out.push(word);
    }
  }
  return out;
}

// The tab grid: two columns ten vp apart, each card 208 tall of which the
// title row takes 36. The picture therefore fills TAB_THUMB_HEIGHT_VP of a
// card (grid width - gap) / 2 wide -- the shape getTabThumbnails is asked to
// capture, so a portrait card shows more of the page than the engine's
// default 4:3 would.
const TAB_GRID_COLUMNS: number = 2;
const TAB_GRID_GAP_VP: number = 10;
const TAB_CARD_HEIGHT_VP: number = 208;
const TAB_CARD_TITLE_VP: number = 36;
export const TAB_THUMB_HEIGHT_VP: number = TAB_CARD_HEIGHT_VP - TAB_CARD_TITLE_VP;
// 列表排布时每行的缩略图（宽 × 高，vp）。行高 64，图 64×46 留出行内留白；
// 请求 getTabThumbnails 时用这两个值算 aspect，一行就正好铺满不裁。
const TAB_LIST_THUMB_WIDTH_VP: number = 64;
const TAB_LIST_THUMB_HEIGHT_VP: number = 46;
// ⋮ 菜单卡片：258 上下、贴着屏幕右侧，左边留出底下网页的宽度。
// 引擎（SearchProvider）给出的搜索建议达到这个条数，就不再补发外壳那条在线
// HTTP —— 常态下省掉每次输入 400~600ms 的 DNS+TLS 握手。
// 取 3：低于 3 条时候选明显偏少，补一发把列表补齐。
const ONLINE_SUGGEST_MIN_ENGINE_ROWS: number = 3;

const MENU_CARD_WIDTH_VP: number = 258;
// 长按菜单卡片（v13）：与 ⋮ 卡片同宽同款，锚在按压点旁边。
const CONTEXT_MENU_CARD_WIDTH_VP: number = 258;

enum MobileEdgeAction {
  BACK = 'back',
  MENU = 'menu'
}

const PRIMARY_ACTION_KEY: string = 'mobilePrimaryAction';
const FOLLOW_GRIP_KEY: string = 'mobileFollowGrip';
const LAST_GRIP_SIDE_KEY: string = 'mobileLastGripSide';

// findResult payload parked in AppStorage by AuraShell.
interface FindResultSummary {
  matches?: number;
  activeMatch?: number;
  revision?: number;
}

// 地址栏联想的回包（AuraShell 转存到 'auraAutocomplete'）。done 为 true 表示
// 该 requestId 推送完毕（可能多次推送）。
interface AutocompletePayload {
  requestId: number;
  items: AutocompleteItem[];
  done: boolean;
}

// 下拉刷新（引擎 pullToRefresh 事件转存到 'auraPullRefresh'，见 AuraShell）。
// 距离单位 vp，阈值语义见 engine ShellServiceTypes.PullToRefreshEvent。
interface PullRefreshPayload {
  state: string;
  threshold?: number;
  distance?: number;
  refresh?: boolean;
  at?: number;
}

let cachedDockMaterialAvailable: boolean | undefined = undefined;

function isDockMaterialAvailable(): boolean {
  if (cachedDockMaterialAvailable !== undefined) {
    return cachedDockMaterialAvailable;
  }
  try {
    const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
    cachedDockMaterialAvailable = types.some((type: hdsMaterial.MaterialType): boolean =>
      type !== hdsMaterial.MaterialType.NONE);
  } catch (error) {
    cachedDockMaterialAvailable = false;
  }
  return cachedDockMaterialAvailable;
}

@Component
export struct MobileBrowserOverlay {
  @StorageLink('auraColorScheme') colorScheme: string = 'light';
  // Safe-area insets (status bar / navigation pill) in vp, from EntryAbility.
  @StorageProp('auraTopSafeVp') topSafeVp: number = 0;
  @StorageProp('auraBottomSafeVp') bottomSafeVp: number = 0;
  @StorageProp('auraKeyboardVp') keyboardVp: number = 0;
  // 网页自己进了全屏（video / requestFullscreen），由 AuraShell 写进 AppStorage。
  // 全屏时状态栏已被藏起来，外壳不能再按"有状态栏"垫底（见状态栏垫底层）。
  @StorageProp('auraPageFullscreen') pageFullscreen: boolean = false;
  @Prop @Watch('onBrowserStateChanged') browserState: BrowserStateSnapshot;
  // 冷启动恢复会话期间，AuraShell 会把标签计数冻结在恢复前的值（-1 表示不冻结）。
  // 引擎是逐个把标签加回来的，直接跟 tabCount 会让徽标「从 1 数到 N」。
  @Prop badgeTabCount: number = -1;
  // 引擎那边**其实正停在自己的新标签页**（导航失败没提交，browserState.url 还
  // 挂着那个连不上的地址，画面却是原生新标签页 + 外壳已用 HomeSurface 盖住）。
  // 由 AuraShell 判定后传下来（见 AuraShell.isNewTabPage）；这里据此把顶栏、
  // 命中区、菜单文案都按「主页」处理，否则会出现「主页 + 一条 github.com 地址栏」。
  @Prop engineHomeCover: boolean = false;
  // 用户按了主页键/返回回主页的意图（= AuraShell.homeReturnCover）。
  // url 要等引擎导航提交才变 newtab，只看 url 会在转场里错画成网页态。
  @Prop homeIntent: boolean = false;
  // 离开主页后的 120ms 内顶栏延后切网页态，与主页 180ms 淡出对齐。
  @Prop homeExitHold: boolean = false;
  // 无痕会话（重启进来的那一种，见 utils/IncognitoSwitch.ets）。
  @Prop incognito: boolean = false;
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};

  // @Watch 收键盘：见 onMenuVisibleChanged / dismissKeyboardForOverlay。
  @State @Watch('onMenuVisibleChanged') private menuVisible: boolean = false;
  @State @Watch('onEditingAddressChanged') private editingAddress: boolean = false;
  // Fix B/E（点搜索跳一下）：提交地址栏导航后保持编辑态与键盘，等导航 commit
  // 并出首帧后再收起（最后统一回弹顶栏）。实测地址栏提交时"键盘收起动画"
  // （~550ms）与"导航 commit"（提交后 260~420ms）重叠竞争，破坏 Chromium
  // paint holding；而页内搜索（键盘保持到导航后）不跳。
  private pendingControlsRebound: boolean = false;
  private controlsReboundSawLoading: boolean = false;
  private reboundTimer: number = 0;
  private reboundSettleTimer: number = 0;
  private reboundFromUrl: string = '';
  // Fix F：'both' 的延迟恢复定时器——导航后先保持 'shown'（冻结浏览器
  // 控件），等新页面首帧稳定再交还控制权，避免视口重算打断 paint holding。
  private controlsRestoreTimer: number = 0;
  @State private addressDraft: string = '';
  @State private primaryAction: MobileEdgeAction = MobileEdgeAction.BACK;
  @State private followGrip: boolean = true;
  @State private lastGripSide: GripSide = GripSide.LEFT;
  // Which dock button is being pressed (by label), for the springy press
  // feedback. Hand-rolled "jelly": unlike the system interactive material,
  // the under-damped spring works on any device and target API level.
  @State private pressedDock: string = '';
  // 顶栏圆形按钮的按压态。这些钮在「页面内容区」，HarmonyOS 7 收紧沉浸光感
  // 生效范围后拿不到系统 interactive 的材质形变，所以自己写一个弹性缩放补上
  // （dock 走 HdsTabs 有系统手感，这里是给悬浮顶栏用的）。
  @State private pressedRound: string = '';
  // Which page the sheet shows: the tabs menu only now; kept as the reset
  // value while the sheet opens or closes.
  @State private sheetPage: string = 'tabs';
  // The ⋮ menu is a floating card above the dock, not a
  // sheet; the sheet hosts the tab switcher only.
  // @Watch 收键盘：见 onMenuCardVisibleChanged / dismissKeyboardForOverlay。
  @State @Watch('onMenuCardVisibleChanged') private menuCardVisible: boolean = false;
  // 小锁快捷面板：浏览态点锁图标弹出（当前站点快捷开关）。
  @State private siteQuickVisible: boolean = false;
  // 「自定义网址」入口菜单（长按 dock 主页图标弹出，自绘卡片）。
  @State private homeTileMenuVisible: boolean = false;
  // 刷新键的「停止」变体——延迟 700ms 出现（见 syncStopVariant）。
  @State private showStopVariant: boolean = false;
  private stopVariantTimer: number = -1;
  // 「网址主页」：设置/修改自定义主页网址的表单（自定义网址入口）。
  @State private homeUrlFormVisible: boolean = false;
  @State private homeUrlDraft: string = '';
  // 「自定义网址」：已保存的多组网址 + 当前勾选（主页键/冷启动用它）。
  // 列表只在这里和 ShellUiPrefs 之间流动，AppStorage 里存一份 \n 分隔串供
  // 设置面板显示条数。
  @State private homeUrlList: string[] = [];
  @State private homeUrlActive: string = '';
  @StorageLink('auraContextMenu') contextMenuJson: string = '';
  // 页内查找 (findInPage): a small bar under the top area.
  @State private findVisible: boolean = false;
  // App 内下载通知条（见 DownloadSnackState / DownloadSnackLayer）。
  // 数据源 = AuraShell 转存的 auraDownloadEvent；同一下载的连续进度事件不
  // 重复弹（id+kind 去重），状态跃迁（inProgress→completed/failed）更新同一条。
  @State private downloadSnackVisible: boolean = false;
  @State private downloadSnack: DownloadSnackState = EMPTY_DOWNLOAD_SNACK;
  private downloadSnackTimer: number = -1;
  // 已经提示过「开始下载」的下载 id。同一 id 的进度事件不再重弹通知条
  // （进度事件每秒多次，靠可见性判断会无限重弹）。
  private downloadSnackAnnouncedId: string = '';
  @StorageLink('auraDownloadEvent') @Watch('onDownloadEventChanged')
  private downloadEventJson: string = '';
  @State private findQuery: string = '';
  @StorageLink('auraFindResult') findResultJson: string = '';
  @StorageLink('auraTabThumbnails') @Watch('onTabThumbnailsChanged') tabThumbnailsJson: string = '';
  @State private tabThumbnails: Map<string, string> = new Map();
  // What to ask getTabThumbnails for: the card's width, and the card's width
  // over its picture's height. Measured once the grid has laid itself out, so
  // the first request -- made on the tap that opens the switcher -- falls back
  // to the engine's own 4:3 and is re-asked for as soon as there is a size.
  @State private tabThumbWidthVp: number = 160;
  @State private tabThumbAspect: number = 0;
  // 缩略图兜底：带 aspect 的请求（新引擎才有这个参数）迟迟不回时，退成不带
  // aspect 的最简请求再问一次；老引擎（我们现在的 build-34534541 就早于
  // aspect 那个改动）只能认这一档。
  private thumbnailRetryTimer: number = 0;
  // 标签页排布：'grid' 两列卡片 / 'list' 单行列表（preferences 持久化）。
  @State private tabLayout: string = 'grid';
  // 0..1, from the engine: how much of the top bar the page is showing.
  // 1 keeps both bars in place; 0 has scrolled both fully away. Applied
  // straight from the storage link so one engine update is one render pass.
  @StorageLink('auraBrowserControlsRatio') controlsRatioRaw: number = 1;
  // “滚动时隐藏底部栏”（设置-外观）：默认开；关掉后 dock 常驻不随滚动收起。
  @StorageLink('auraHideDockOnScroll') hideDockOnScroll: boolean = true;
  // 「上滑时隐藏状态栏」（设置-外观）：关着时顶栏收起后网页停在状态栏底
  // （引擎 minTop=topSafe，AuraShell.sendBrowserControls），状态栏那一条由本层
  // 的常驻垫底显示页面底色（见 build() 与 topBarHideProgress）。
  @StorageLink('auraHideStatusBarOnScroll') hideStatusBarOnScroll: boolean = false;
  // 主页风格（'minimal' | 'chrome'）与 Chrome 风格下 dock 位置（'bottom' | 'top'）。
  @StorageLink('auraHomeStyle') homeStyle: string = 'minimal';
  @StorageLink('auraDockPosition') dockPosition: string = 'bottom';
  // 壁纸三带判色由 HomeSurface 透出：顶带给状态栏/顶栏，底带给底部 dock。
  // 顶/底亮度常相反，不能用同一个信号。
  @StorageProp('auraWallpaperTopIsLight') wallpaperTopIsLight: boolean = true;
  @StorageProp('auraWallpaperBottomIsLight') wallpaperBottomIsLight: boolean = true;
  // 只有壁纸真的铺在主页上时，顶栏/dock 图标才按壁纸判色；无壁纸时一律
  // 回落系统图标色，否则残留的深色壁纸判据会把图标画成白色、在浅色 dock 上消失。
  @StorageProp('auraWallpaperPresent') wallpaperPresent: boolean = false;
  // auraRequestMenuOpen 信号随主页右上角菜单按钮一并去除（入口冗余：
  // 简约底栏 dock / Chrome 风格 dock 均有 ⋮ 菜单槽位）。
  // “滚动时隐藏地址栏”：dockRatio() 用它判断组合（常驻地址栏时 dock 走触摸）。
  @StorageLink('auraHideTopBarOnScroll') hideTopBarOnScroll: boolean = true;
  // 该页被判为「滚不动」时 AuraShell 置位：与手动关掉上面的开关同一档，
  // 顶栏比例下限、dock 取值都必须跟着切，否则顶栏与页面各用一套基准。
  @StorageLink('auraTopBarPinnedForPage') topBarPinnedForPage: boolean = false;
  // 「地址栏常驻 + 收起 dock」组合：引擎比例被锁死，dock 改由 AuraShell 的
  // 触摸观察层驱动（1 = 全显）。见 AuraShell.onDockObserverTouch。
  @StorageLink('auraTouchDockRatio') touchDockRatio: number = 1;
  // 「页面不滚动」时由外壳直接收放 dock（地址栏钉住），见
  // AuraShell.onSwipeControlsTouch：引擎不产比例，这里改读触摸值。
  @StorageLink('auraSwipeDockRatioOn') swipeDockRatioOn: boolean = false;
  // Chrome 底置 dock 的跟手收起系数（触摸驱动；引擎底置无 controlsRatio，见 AuraShell.onChromeBottomDockTouch）。
  @StorageLink('auraChromeBottomRatio') chromeBottomRatioRaw: number = 1;
  // A' 面板页化（Phase 3）：路由页（设置页「添加主页网址」）经此信号请求 overlay
  // 弹出网址管理表单——路由页与浏览器壳不在同一组件树，用 AppStorage 计数器桥接。
  @StorageLink('auraRequestAddHomeTile') @Watch('onRequestAddHomeTile') requestAddHomeTileSignal: number = 0;
  // 下拉刷新：引擎（Chromium）自己判定「页面已到顶 + 不是内层滚动 +
  // overscroll-behavior 放行」，也自己 reload，外壳只画指示器 —— 事件由 AuraShell
  // 转存（见 engine ShellServiceTypes.PullToRefreshEvent）。
  // 'idle' 无 / 'pull' 手指还在拉（跟手放大）/ 'refreshing' 松手够远了（转圈等 reset）。
  @StorageLink('auraPullRefresh') @Watch('onPullRefreshChanged') pullRefreshJson: string = '';
  @State private pullPhase: string = 'idle';
  @State private pullDistance: number = 0;
  @State private pullThreshold: number = 64;
  // 刷新中兜底：引擎理论上会推 reset，漏了也不能一直转圈。
  private pullIdleTimer: number = 0;

  private readonly holdingHandRouter: HoldingHandRouter = new HoldingHandRouter();
  private readonly currentTabCastSession: CurrentTabCastSession = new CurrentTabCastSession();
  // Floating-chrome styling note: the dock's system immersive material (沉浸
  // 光感) is drawn through HDS -- a real
  // HdsTabs whose tabBar entries ARE the dock buttons (DockMaterialPlate
  // below). uiMaterial was the first attempt and is scoped far tighter
  // (bottom TabBar inside a horizontal Tabs only); on device it rendered
  // nothing. HDS renders anywhere. The top bar stays painted.
  private readonly dockMaterialActive: boolean = isDockMaterialAvailable();
  // 视口高度（vp），首次布局即上报；dock 条带的响应区以它为底边基准。
  @State private viewportHeightVp: number = 0;
  // 视口宽度（vp）：页面切换帘幕（见 navVeilShift）的位移基准。
  @State private viewportWidthVp: number = 0;
  // 材质板是否处于「宽屏」（横屏）档。仅用作承载材质板的分支开关：跨过
  // 断点时销毁重建 HdsTabs，逼它按当前 tabs 宽度重新选 barWidth 档位
  // （见 DOCK_PLATE_WIDE_BREAKPOINT_VP 的说明）。
  @State private dockPlateWide: boolean = false;
  @State private navVeilShift: number = 1;
  private lastNavVeilUrl: string = '';
  private navVeilTimer: number = -1;

  private loadBarHeight: number = 2;
  private loadBarMin: number = 0.08;
  private loadBarGrowMs: number = 200;
  // 是否挂载细条（由 loading 驱动；卸载走 if 根节点的淡出 transition）。
  @State private loadBarShown: boolean = false;
  // 当前目标进度 0..1（恒 >= loadBarMin，卸载后复位）。
  @State private loadBarWidth: number = 0.08;
  // 收尾定时器：灌满 100% 停留一小会儿再收掉。
  private loadBarFadeTimer: number = 0;

  // 地址栏联想（引擎 autocomplete 命令）：编辑地址栏、输入非空文本时，在
  // 胶囊下方弹建议列表（历史 / 书签 / 搜索 / 打开的标签 / 网址，全部本地
  // 生成、不出网）。引擎对同一 requestId 流式推多包 —— 只认最新一次请求。
  @StorageLink('auraAutocomplete') @Watch('onAutocompleteChanged') autocompleteJson: string = '';
  @State private suggestItems: AutocompleteItem[] = [];
  // 在线联想词（默认搜索引擎的下拉建议接口，按输入实时拉取）。
  @State private onlineSuggestWords: string[] = [];
  @State private suggestVisible: boolean = false;
  private autocompleteSeq: number = 0;
  private autocompletePending: number = -1;
  // 已经「上过屏」的 requestId：首包判断用（同一轮只立即上屏一次，后续包合并刷）。
  private suggestShownFor: number = -1;
  // 合并刷新：攒最新一份 120ms 刷一次，避免每个 provider 包都重建整张卡。
  private suggestFlushTimer: number = -1;
  private suggestQueuedItems: AutocompleteItem[] = [];
  private addressSuggestText: string = '';
  private addressSuggestTimer: number = -1;
  private suggestHttpSeq: number = 0;

  private keyboardRecoveryTimers: number[] = [];
  private readonly addressController: TextInputController = new TextInputController();
  private addressSelectionStart: number = 0;
  private addressBase: string = '';
  private addressEdited: boolean = false;
  private addressSelectionEnd: number = 0;
  private addressEditEpoch: number = 0;
  private requestSeq: number = 0;

  aboutToAppear(): void {
    const storedAction = String(AppStorage.get(PRIMARY_ACTION_KEY) ?? MobileEdgeAction.BACK);
    this.primaryAction = storedAction === MobileEdgeAction.MENU ?
      MobileEdgeAction.MENU : MobileEdgeAction.BACK;
    this.followGrip = Boolean(AppStorage.get(FOLLOW_GRIP_KEY) ?? true);
    const storedSide = String(AppStorage.get(LAST_GRIP_SIDE_KEY) ?? GripSide.LEFT);
    this.lastGripSide = storedSide === GripSide.RIGHT ? GripSide.RIGHT : GripSide.LEFT;
    if (this.followGrip) {
      this.startHoldingHandAwareness();
    }
    // The entry page's onBackPress asks this before letting the system back
    // gesture exit the app.
    MobileBackRouter.handler = (): boolean => this.handleSystemBack();
    // A' 面板页化：面板（可能已是独立路由页）经此总线把浏览器命令发回壳。
    BrowserCommandBus.setHandler((command: BrowserCommandPayload): void => {
      this.issueCommand(command);
    });
    // The cast session starts when the cast picker opens, not here. HarmonyOS
    // allows one AVSession per ability, and an idle one held from launch left
    // the engine's media session (control center card) unable to exist.
    // 标签页排布（网格 / 列表），preferences 持久化。
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context) {
      ShellUiPrefs.loadTabLayout(context).then((value: string): void => {
        this.tabLayout = value;
      });
    }
  }

  aboutToDisappear(): void {
    MobileBackRouter.handler = undefined;
    if (this.downloadSnackTimer !== -1) {
      clearTimeout(this.downloadSnackTimer);
      this.downloadSnackTimer = -1;
    }
    if (this.thumbnailRetryTimer !== 0) {
      clearTimeout(this.thumbnailRetryTimer);
      this.thumbnailRetryTimer = 0;
    }
    this.clearKeyboardRecoveryTimers();
    if (this.reboundTimer !== 0) {
      clearTimeout(this.reboundTimer);
      this.reboundTimer = 0;
    }
    if (this.reboundSettleTimer !== 0) {
      clearTimeout(this.reboundSettleTimer);
      this.reboundSettleTimer = 0;
    }
    if (this.controlsRestoreTimer !== 0) {
      clearTimeout(this.controlsRestoreTimer);
      this.controlsRestoreTimer = 0;
    }
    if (this.loadBarFadeTimer !== 0) {
      clearTimeout(this.loadBarFadeTimer);
      this.loadBarFadeTimer = 0;
    }
    this.holdingHandRouter.stop();
    this.currentTabCastSession.stop().catch((error: Error) => {
      console.error('Failed to stop current-tab cast session:', error);
    });
  }

  // The page's onBackPress asks this first: dismiss chrome the user can see
  // (address editing, the tab menu, a full-screen shell page), then page
  // history, and only leave the app when there is nothing of ours to unwind.
  private handleSystemBack(): boolean {
    // 长按菜单是最上面的一层：先它。
    if (this.contextMenuJson.length > 0) {
      this.dismissContextMenu();
      return true;
    }
    if (this.editingAddress) {
      // 编辑中：联想列表先关（第一下），再一下才退出编辑态。
      if (this.suggestVisible) {
        this.hideAddressSuggest();
        return true;
      }
      this.clearKeyboardRecoveryTimers();
      this.editingAddress = false;
      return true;
    }
    if (this.findVisible) {
      this.closeFindBar();
      return true;
    }
    if (this.menuCardVisible) {
      this.closeMenuCard();
      return true;
    }
    if (this.menuVisible) {
      this.closeMenuSheet();
      return true;
    }
    // Back on the home surface there is nothing left of ours to unwind --
    // the gesture ends the app instead of paging further back through
    // history that was left behind when "home" was pressed.
    if (this.isHomeSurface()) {
      // 扩展 popup 让位中：返回键先恢复主页层，而不是退出应用。
      if ((AppStorage.get('auraPopupHomeHold') as number ?? 0) > 0) {
        AppStorage.setOrCreate('auraPopupHomeHold', 0);
        return true;
      }
      return false;
    }
    if (this.browserState.canGoBack) {
      this.issueCommand({ command: 'back' });
      return true;
    }
    // 再按一次返回 = 回主页，进度条同样立刻收（理由见 pressHome）。
    this.hideLoadBarNow();
    this.issueCommand({ command: 'home' });
    return true;
  }

  private onBrowserStateChanged(): void {
    this.maybeKeepThumbnail();
    // A' 面板页化：把当前 URL/标题同步进 AppStorage，供路由页（书签/扩展等）
    // 通过 @StorageLink 读取，替代原来从 overlay 直接传 @Prop 的耦合。
    // 只在值真正变化时写入 —— 本回调随引擎状态推送触发，高频空写会白跑一遍
    // AppStorage 的订阅比较，帧敏感期（滚动/转场）没必要。
    const currentUrlValue: string = this.browserState.url ?? '';
    if (((AppStorage.get('auraCurrentUrl') as string) ?? '') !== currentUrlValue) {
      AppStorage.setOrCreate('auraCurrentUrl', currentUrlValue);
    }
    const currentTitleValue: string = this.browserState.title ?? '';
    if (((AppStorage.get('auraCurrentTitle') as string) ?? '') !== currentTitleValue) {
      AppStorage.setOrCreate('auraCurrentTitle', currentTitleValue);
    }
    // 当前活动标签的稳定 id：网站设置面板的「清除该站数据」要让引擎按 tabId
    // 定位标签（clearPageSiteData 只认 tabId，不认 origin 字符串；state 里
    // 没有 navigationId 这种键）。路由页（SiteSettingsPanelPage）拿不到
    // browserState，只能走 AppStorage 桥。
    const tabsList: BrowserTabState[] = this.browserState.tabs ?? [];
    const activeIdx: number = this.browserState.activeTabIndex ?? 0;
    const activeTabId: string = (activeIdx >= 0 && activeIdx < tabsList.length)
      ? (tabsList[activeIdx].id ?? '') : '';
    if (((AppStorage.get('auraActiveTabId') as string) ?? '') !== activeTabId) {
      AppStorage.setOrCreate('auraActiveTabId', activeTabId);
    }
    // 扩展 popup 让位期间导航离开了主页 → 让位结束，恢复 HomeSurface。
    if ((AppStorage.get('auraPopupHomeHold') as number ?? 0) > 0 &&
      !this.isNewTabUrl(currentUrlValue)) {
      AppStorage.setOrCreate('auraPopupHomeHold', 0);
    }
    // 页面切换帘幕：顶层 URL 变化就放一次（地址栏提交 / 点链接 / 切标签 /
    // 前进后退都算）——把引擎换页那一瞬的底色空档盖成柔和过渡。
    const navUrl: string = this.browserState.url ?? '';
    if (navUrl.length > 0) {
      // 主页（新标签页）不扫帘幕：HomeSurface 有自己的显示/淡入与 homeHold
      // 淡入上）。离开主页同样跳过 —— 由 homeHold 捂住到新页面画出来。
      const goingHome: boolean = this.isNewTabUrl(navUrl);
      const leavingHome: boolean = this.isNewTabUrl(this.lastNavVeilUrl);
      if (this.lastNavVeilUrl.length > 0 && navUrl !== this.lastNavVeilUrl) {
        // URL 真正变了：地址栏联想已无意义（提交 / 点链接 / 切标签都算）。
        if (this.suggestVisible) {
          this.hideAddressSuggest();
        }
      }
      this.lastNavVeilUrl = navUrl;
    }
    // 加载进度条——读取引擎真实 loadProgress。它只是
    // 指示、不覆盖内容，因此既不延长白屏、也不参与切页过渡。
    this.syncLoadBar();
    // Fix B/E：提交导航后保持编辑态与键盘，等导航 commit（url 变化）并留出
    // 首帧余量（250ms）再收起；loading true→false 与 1.5s 兜底为保险。
    if (this.pendingControlsRebound) {
      if (this.browserState.loading) {
        this.controlsReboundSawLoading = true;
      }
      if (this.reboundSettleTimer === 0 && this.reboundFromUrl.length > 0 &&
        this.browserState.url !== this.reboundFromUrl) {
        // 导航已 commit：给新页面首帧留 ~250ms，再收键盘/回弹。
        this.reboundSettleTimer = setTimeout((): void => {
          this.reboundSettleTimer = 0;
          this.flushControlsRebound();
        }, 250);
      }
      if (!this.browserState.loading && this.controlsReboundSawLoading) {
        this.flushControlsRebound();
      }
    }
    this.currentTabCastSession.update(this.browserState);
    this.maybeActivatePendingNewTab();
    // 刷新键「停止」变体的延迟切换（见 syncStopVariant）。
    this.syncStopVariant(this.browserState.loading);
  }

  private syncStopVariant(loading: boolean): void {
    if (loading) {
      if (this.showStopVariant || this.stopVariantTimer !== -1) {
        return;
      }
      this.stopVariantTimer = setTimeout((): void => {
        this.stopVariantTimer = -1;
        if (this.browserState.loading) {
          this.showStopVariant = true;
        }
      }, 700);
    } else {
      if (this.stopVariantTimer !== -1) {
        clearTimeout(this.stopVariantTimer);
        this.stopVariantTimer = -1;
      }
      if (this.showStopVariant) {
        this.showStopVariant = false;
      }
    }
  }

  // Fix B/E：提交导航后延迟收起编辑态/键盘并回弹顶栏。理想路径由
  // onBrowserStateChanged 在导航 commit + 首帧余量后执行；1.5s 兜底
  // 强制回弹（同 URL 未触发加载等）。
  private reboundControlsAfterPaint(): void {
    this.pendingControlsRebound = true;
    this.controlsReboundSawLoading = false;
    this.reboundFromUrl = this.browserState.url;
    if (this.reboundTimer !== 0) {
      clearTimeout(this.reboundTimer);
    }
    if (this.reboundSettleTimer !== 0) {
      clearTimeout(this.reboundSettleTimer);
      this.reboundSettleTimer = 0;
    }
    this.reboundTimer = setTimeout((): void => {
      this.reboundTimer = 0;
      this.flushControlsRebound();
    }, 1500);
  }

  private cancelControlsRebound(): void {
    // Fix F：延迟的 'both' 也要撤——否则用户重新编辑后被它打断 'shown'。
    if (this.controlsRestoreTimer !== 0) {
      clearTimeout(this.controlsRestoreTimer);
      this.controlsRestoreTimer = 0;
    }
    if (!this.pendingControlsRebound) {
      return;
    }
    this.pendingControlsRebound = false;
    this.controlsReboundSawLoading = false;
    this.reboundFromUrl = '';
    if (this.reboundTimer !== 0) {
      clearTimeout(this.reboundTimer);
      this.reboundTimer = 0;
    }
    if (this.reboundSettleTimer !== 0) {
      clearTimeout(this.reboundSettleTimer);
      this.reboundSettleTimer = 0;
    }
  }

  private flushControlsRebound(): void {
    if (!this.pendingControlsRebound) {
      return;
    }
    this.pendingControlsRebound = false;
    this.controlsReboundSawLoading = false;
    this.reboundFromUrl = '';
    if (this.reboundTimer !== 0) {
      clearTimeout(this.reboundTimer);
      this.reboundTimer = 0;
    }
    if (this.reboundSettleTimer !== 0) {
      clearTimeout(this.reboundSettleTimer);
      this.reboundSettleTimer = 0;
    }
    // Fix H：地址栏已在提交瞬间归位（第 1 拍），此处不再动编辑态。
    // Fix F：'both' 再推迟 500ms——新页面首帧稳定前保持 'shown'（冻结浏览器
    // 控件）。实测在 paint holding（旧画面保持）窗口内发 'both' 会触发视口
    // 重算、打断 hold，旧画面消失（黑屏）直到新页首帧；页内搜索（从不发
    // 控件命令）因此不跳。
    this.restoreControlsSoon();
  }

  // Fix F：把 chrome 控制权（'both'）推迟 500ms 交还。用于任何"导航刚
  // 提交/刚完成"的窗口——保持 'shown' 不打扰引擎的旧画面保持（paint
  // holding）。重编辑时由 cancelControlsRebound 撤销。
  private restoreControlsSoon(): void {
    if (this.controlsRestoreTimer !== 0) {
      clearTimeout(this.controlsRestoreTimer);
    }
    this.controlsRestoreTimer = setTimeout((): void => {
      this.controlsRestoreTimer = 0;
      this.issueCommand({ command: 'setBrowserControlsState', state: 'both', animate: true });
    }, 500);
  }

  private onTabThumbnailsChanged(): void {
    // 面板没开时不必去翻磁盘：这些图只有标签网格/列表要画。开着才补读。
    this.parseThumbnails(this.menuVisible);
  }

  private parseThumbnails(withDisk: boolean = false): void {
    const context = this.getUIContext().getHostContext() as common.Context | undefined;
    const tabs: BrowserTabState[] = this.browserState.tabs ?? [];
    const map: Map<string, string> = new Map();
    try {
      const items: TabThumbnail[] = JSON.parse(this.tabThumbnailsJson) as TabThumbnail[];
      for (const item of items) {
        if (item.id && item.id.length > 0 && item.pngBase64 && item.pngBase64.length > 0) {
          const dataUrl: string = `data:image/png;base64,${item.pngBase64}`;
          map.set(item.id, dataUrl);
          // 落盘：恢复出来的标签会拿到新 id，只有 URL 还能把它和这张图对上。
          for (const tab of tabs) {
            if ((tab.id ?? '') === item.id && (tab.url ?? '').length > 0) {
              this.rememberThumb(context, tab.url, dataUrl, item.pngBase64);
              break;
            }
          }
        }
      }
    } catch (error) {
    }
    // 引擎只对当前标签截图、后台标签只能给内存里的旧图，而内存缓存进程一死
    // 就空（恢复会话后满屏「已休眠」正是这个）。磁盘里有的先补上：
    // 有图就画上次的样子，比一片占位更能认出是哪个标签。
    // 磁盘是同步 IO，跑在 UI 线程上：先查内存，且只有面板打开时才真正读盘。
    for (const tab of tabs) {
      const id: string = tab.id ?? '';
      if (id.length === 0 || map.has(id)) {
        continue;
      }
      const url: string = tab.url ?? '';
      // 主页标签不读缩略图：引擎截的是底层 chrome://newtab 的原生磁贴，
      // 壳层自绘主页不在 WebContents 里；旧磁盘缓存里也可能存着这张磁贴图。
      if (this.isNewTabUrl(url)) {
        continue;
      }
      let cached: string = this.thumbDiskCache.get(url) ?? '';
      if (cached.length === 0 && withDisk) {
        cached = TabThumbnailStore.load(context, url);
        if (cached.length > 0) {
          this.thumbDiskCache.set(url, cached);
        }
      }
      if (cached.length > 0) {
        map.set(id, cached);
      }
    }
    this.tabThumbnails = map;
  }

  private tabBadgeText(): string {
    const count: number = this.badgeTabCount >= 0
      ? this.badgeTabCount
      : this.browserState.tabCount;
    return count > 99 ? '99+' : count.toString();
  }

  // 新图既落盘也进内存：同一个 URL 之后再显示就不用读盘了。
  private rememberThumb(context: common.Context | undefined, url: string,
    dataUrl: string, pngBase64: string): void {
    // 主页标签的截图只会是引擎原生 NTP 磁贴（壳层自绘层不在 WebContents 里），
    // 不落盘也不进内存缓存，否则会话恢复后这张磁贴图会被重新贴回卡片。
    if (this.isNewTabUrl(url)) {
      return;
    }
    // 缓存只服务于打开面板那几屏，条数很小；超了就整体丢弃，不做精细淘汰。
    if (this.thumbDiskCache.size > 32) {
      this.thumbDiskCache.clear();
    }
    this.thumbDiskCache.set(url, dataUrl);
    TabThumbnailStore.save(context, url, pngBase64);
  }

  private thumbnailFor(tab: BrowserTabState): string {
    // 主页标签一律走自绘占位，不用引擎截图（见 rememberThumb 注释）。
    if (this.isNewTabUrl(tab.url ?? '')) {
      return '';
    }
    if (tab.id && tab.id.length > 0) {
      const value = this.tabThumbnails.get(tab.id);
      if (value) {
        return value;
      }
    }
    return '';
  }

  // 主页标签的自绘缩略图占位。引擎截图截不到壳层 ArkUI 主页，只能给出底层
  // chrome://newtab 的原生磁贴；这里画一个与真实主页同构的简化版，
  // 让标签总览里的「新标签页」卡片看起来就是我们的主页。
  @Builder
  private HomeTabPlaceholder() {
    Column({ space: 14 }) {
      Text('Orbira')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Row() {
        Text('搜索或输入网址')
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('76%')
      .height(26)
      .padding({ left: 12 })
      .borderRadius(13)
      .backgroundColor($r('app.color.surface_secondary'))
      Row({ space: 16 }) {
        Column().width(20).height(20).borderRadius(10)
          .backgroundColor($r('app.color.surface_secondary'))
        Column().width(20).height(20).borderRadius(10)
          .backgroundColor($r('app.color.surface_secondary'))
        Column().width(20).height(20).borderRadius(10)
          .backgroundColor($r('app.color.surface_secondary'))
        Column().width(20).height(20).borderRadius(10)
          .backgroundColor($r('app.color.surface_secondary'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.browser_canvas'))
    .justifyContent(FlexAlign.Center)
  }

  // 列表视图里的小缩略图只用品牌字标，保持紧凑不挤成一团。
  @Builder
  private HomeTabPlaceholderCompact() {
    Column() {
      Text('Orbira')
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.browser_canvas'))
    .justifyContent(FlexAlign.Center)
  }

  private thumbKeepTimer: number = 0;
  private thumbKeptKey: string = '';
  // URL → data URL。缩略图磁盘缓存的内存副本，避免每次回包都去同步读盘。
  private thumbDiskCache: Map<string, string> = new Map();

  // 每个标签切到前台后都留一张缩略图：引擎只在标签是当前标签时才有 surface
  // 可截，后台标签只能回内存里的旧图；不主动截，恢复出来的标签永远没有图。
  // 防抖 1.5s（等页面画完），同一个 `id|url` 只截一次。
  private maybeKeepThumbnail(): void {
    if (this.browserState.loading) {
      return;
    }
    const tabs: BrowserTabState[] = this.browserState.tabs ?? [];
    const index: number = this.browserState.activeTabIndex ?? -1;
    if (index < 0 || index >= tabs.length) {
      return;
    }
    const tab: BrowserTabState = tabs[index];
    // 主页标签没有值得保留的截图，别为它发请求、更别把原生磁贴图落盘。
    if (this.isNewTabUrl(tab.url ?? '')) {
      return;
    }
    const id: string = tab.id ?? '';
    if (id.length === 0) {
      return;
    }
    const key: string = `${id}|${tab.url ?? ''}`;
    if (key === this.thumbKeptKey || this.thumbKeepTimer !== 0) {
      return;
    }
    this.thumbKeepTimer = setTimeout((): void => {
      this.thumbKeepTimer = 0;
      this.thumbKeptKey = key;
      this.requestThumbnailFor(id);
    }, 1500);
  }

  private requestThumbnailFor(id: string): void {
    this.requestSeq += 1;
    if (this.tabThumbAspect > 0) {
      this.issueCommand({
        command: 'getTabThumbnails',
        requestId: this.requestSeq,
        ids: [id],
        widthVp: this.tabThumbWidthVp,
        aspect: this.tabThumbAspect
      });
    } else {
      this.issueCommand({
        command: 'getTabThumbnails',
        requestId: this.requestSeq,
        ids: [id],
        widthVp: this.tabThumbWidthVp
      });
    }
  }

  private requestTabThumbnails(): void {
    TabThumbnailStore.prune(this.getUIContext().getHostContext() as common.Context | undefined);
    this.parseThumbnails(true);
    const ids: string[] = [];
    for (const tab of this.browserState.tabs) {
      // 主页标签由壳层自绘占位，不向引擎请求截图（省一次无用的 surface 拷贝）。
      if (tab.id && tab.id.length > 0 && !this.isNewTabUrl(tab.url ?? '')) {
        ids.push(tab.id);
      }
    }
    if (ids.length === 0) {
      if (this.thumbnailRetryTimer !== 0) {
        clearTimeout(this.thumbnailRetryTimer);
        this.thumbnailRetryTimer = 0;
      }
      return;
    }
    this.requestSeq += 1;
    // The engine (from build-443425d6) takes an optional card aspect; older
    // engines ignore it and answer with the same 4:3 picture as before.
    if (this.tabThumbAspect > 0) {
      this.issueCommand({
        command: 'getTabThumbnails',
        requestId: this.requestSeq,
        ids: ids,
        widthVp: this.tabThumbWidthVp,
        aspect: this.tabThumbAspect
      });
    } else {
      this.issueCommand({
        command: 'getTabThumbnails',
        requestId: this.requestSeq,
        ids: ids,
        widthVp: this.tabThumbWidthVp
      });
    }
    // 兜底：2s 后仍一张都没有，就用最简参数（不带 aspect、默认宽度）再问一次。
    // 老引擎不认 aspect/widthVp 时可能完全不回包——这一档是它唯一能认的。
    if (this.thumbnailRetryTimer !== 0) {
      clearTimeout(this.thumbnailRetryTimer);
    }
    this.thumbnailRetryTimer = setTimeout((): void => {
      this.thumbnailRetryTimer = 0;
      if (this.tabThumbnails.size > 0) {
        return;
      }
      this.requestSeq += 1;
      this.issueCommand({
        command: 'getTabThumbnails',
        requestId: this.requestSeq,
        ids: ids
      });
    }, 2000);
  }

  // Once the grid has a size, ask for pictures shaped like its cards: a card
  // taller than it is wide then shows more than the top few lines of a page.
  private measureTabGrid(area: Area): void {
    const gridWidth: number = Number(area.width);
    if (gridWidth <= 0) {
      return;
    }
    const cardWidth: number =
      (gridWidth - TAB_GRID_GAP_VP * (TAB_GRID_COLUMNS - 1)) / TAB_GRID_COLUMNS;
    const aspect: number = Math.min(Math.max(cardWidth / TAB_THUMB_HEIGHT_VP, 0.4), 2.5);
    if (Math.abs(aspect - this.tabThumbAspect) < 0.02) {
      return;
    }
    this.tabThumbAspect = aspect;
    this.tabThumbWidthVp = Math.max(80, Math.round(cardWidth));
    this.requestTabThumbnails();
  }

  private closeMenuCard(): void {
    this.menuCardVisible = false;
  }

  // A' 面板页化（Phase 3）：路由页信号 → 打开网址管理表单。
  private onRequestAddHomeTile(): void {
    this.requestAddHomeTile();
  }

  // 请求「自定义网址」——收起入口菜单、打开网址管理表单。
  // （用户澄清语义）：「网址主页」= 让某个网址成为主页——按下主页键就
  // 打开这个页面（不是把网址加进主页磁贴）。
  // 支持多组网址 —— 表单里可以反复添加，勾选中的那一条才是当前主页。
  private requestAddHomeTile(): void {
    this.homeTileMenuVisible = false;
    const list: string[] = ShellUiPrefs.parseUrlList(
      (AppStorage.get('auraHomeUrls') as string) ?? '');
    const saved: string = (AppStorage.get('auraHomeUrl') as string) ?? '';
    this.homeUrlList = list;
    this.homeUrlActive = ShellUiPrefs.resolveActive(list, saved);
    this.homeUrlDraft = '';
    this.homeUrlFormVisible = true;
  }

  // 追加一条网址（自动补 scheme、去重），并把它设为当前主页。
  private addHomeUrlEntry(): void {
    const raw: string = this.homeUrlDraft.trim();
    if (raw.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请先输入网址', duration: 1500 });
      return;
    }
    const url: string = normalizeAddress(raw);
    const next: string[] = [];
    for (let i = 0; i < this.homeUrlList.length; i++) {
      if (this.homeUrlList[i] !== url) {
        next.push(this.homeUrlList[i]);
      }
    }
    next.push(url);
    this.homeUrlList = next;
    this.homeUrlActive = url;
    this.homeUrlDraft = '';
    this.persistHomeUrlList();
    this.getUIContext().getPromptAction().showToast({ message: '已添加并设为主页', duration: 1500 });
  }

  private removeHomeUrlEntry(url: string): void {
    const next: string[] = [];
    for (let i = 0; i < this.homeUrlList.length; i++) {
      if (this.homeUrlList[i] !== url) {
        next.push(this.homeUrlList[i]);
      }
    }
    this.homeUrlList = next;
    this.persistHomeUrlList();
  }

  private selectHomeUrlEntry(url: string): void {
    if (this.homeUrlActive === url) {
      return;
    }
    this.homeUrlActive = url;
    this.persistHomeUrlList();
  }

  // 列表与「当前主页」一起落盘：AppStorage 的两份给设置面板/主页键读，
  // preferences 的两份给冷启动读。列表空了 = 主页键回内置新标签页。
  private persistHomeUrlList(): void {
    const list: string[] = this.homeUrlList;
    const active: string = ShellUiPrefs.resolveActive(list, this.homeUrlActive);
    this.homeUrlActive = active;
    AppStorage.setOrCreate('auraHomeUrls', ShellUiPrefs.joinUrlList(list));
    AppStorage.setOrCreate('auraHomeUrl', active);
    const context = this.getUIContext().getHostContext() as common.Context | undefined;
    if (context) {
      ShellUiPrefs.saveHomeUrlList(context, list, active);
    }
  }

  private closeHomeUrlForm(): void {
    this.homeUrlFormVisible = false;
  }


  private contextMenuModelOrDefault(): ContextMenuModel {
    return parseContextMenuModel(this.contextMenuJson) ?? EMPTY_CONTEXT_MENU_MODEL;
  }

  private clearContextMenu(): void {
    AppStorage.setOrCreate('auraContextMenu', '');
  }

  private chooseContextMenuAction(model: ContextMenuModel, action: ContextMenuAction): void {
    const copyText: string | undefined = shellCopyTextFor(model, action);
    this.clearContextMenu();
    if (copyText !== undefined) {
      // Shell-side copy: the engine's own copies flash a native "copied"
      // toast pinned at the window top, which an immersive window clips in
      // half (see shellCopyTextFor). Dismissed, so the engine never acts.
      this.copyPlainText(copyText);
      this.issueCommand({ command: 'contextMenuDismissed', requestId: model.requestId });
      return;
    }
    if (action === 'openLinkInNewTab' || action === 'openImageInNewTab' ||
      action === 'openMediaInNewTab') {
      // Chromium opens these in a background tab and stays put. Remember the
      // tab set; the first state snapshot carrying an unknown id is the new
      // tab, and that is the page the reader asked to go to.
      this.armPendingNewTabSwitch();
    }
    this.issueCommand({ command: 'contextMenuAction', requestId: model.requestId, action: action });
  }

  private copyPlainText(text: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).catch((error: Error): void => {
        console.error('Failed to copy text:', error.message);
      });
    } catch (error) {
      console.error('Failed to copy text');
    }
    this.getUIContext().getPromptAction().showToast({ message: '已复制', duration: 1500 });
  }

  // ---- 后台开标签后自动切过去（长按菜单 open*InNewTab）----

  // Tab ids at the moment the action was sent; the new tab is whichever id
  // shows up later that is not in here.
  private pendingNewTabSwitch: boolean = false;
  private pendingNewTabIds: Set<string> = new Set<string>();
  private pendingNewTabTimer: number = -1;

  private armPendingNewTabSwitch(): void {
    this.pendingNewTabIds = new Set<string>();
    for (const tab of this.browserState.tabs) {
      const id: string | undefined = tab.id;
      if (id !== undefined && id.length > 0) {
        this.pendingNewTabIds.add(id);
      }
    }
    this.pendingNewTabSwitch = true;
    if (this.pendingNewTabTimer >= 0) {
      clearTimeout(this.pendingNewTabTimer);
    }
    // Safety: if no new tab ever appears (the action failed), stop watching.
    this.pendingNewTabTimer = setTimeout((): void => {
      this.pendingNewTabSwitch = false;
      this.pendingNewTabTimer = -1;
    }, 10000);
  }

  private maybeActivatePendingNewTab(): void {
    if (!this.pendingNewTabSwitch) {
      return;
    }
    for (const tab of this.browserState.tabs) {
      const id: string | undefined = tab.id;
      if (id !== undefined && id.length > 0 && !this.pendingNewTabIds.has(id)) {
        this.pendingNewTabSwitch = false;
        if (this.pendingNewTabTimer >= 0) {
          clearTimeout(this.pendingNewTabTimer);
          this.pendingNewTabTimer = -1;
        }
        this.issueCommand({ command: 'activateTab', index: tab.index });
        return;
      }
    }
  }

  private dismissContextMenu(): void {
    const model: ContextMenuModel | undefined = parseContextMenuModel(this.contextMenuJson);
    this.clearContextMenu();
    if (model !== undefined) {
      this.issueCommand({ command: 'contextMenuDismissed', requestId: model.requestId });
    }
  }

  // 系统安全粘贴：浏览器进程拿不到明文剪贴板，走系统对话框取一次文本再
  // 插回（insertText）。先收菜单再弹对话框，避免两层浮层同时在场。
  private pasteFromContextMenu(model: ContextMenuModel): void {
    const ui: UIContext = this.getUIContext();
    this.clearContextMenu();
    setTimeout((): void => {
      showSystemPasteDialog(ui,
        (text: string): void => {
          this.issueCommand({ command: 'insertText', requestId: model.requestId, text: text });
        },
        (): void => {
          this.issueCommand({ command: 'contextMenuDismissed', requestId: model.requestId });
        });
    }, 0);
  }

  private deviceWidthVp(): number {
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      if (info.densityPixels > 0 && info.width > 0) {
        return info.width / info.densityPixels;
      }
    } catch (error) {
    }
    return 360;
  }

  private deviceHeightVp(): number {
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      if (info.densityPixels > 0 && info.height > 0) {
        return info.height / info.densityPixels;
      }
    } catch (error) {
    }
    return this.viewportHeightVp > 0 ? this.viewportHeightVp : 780;
  }

  // 卡片高度估算（定位用）：头部（有链接文字时多一行）+ 分隔线 + 每项
  // 48 + 底部留 6。与渲染保持一致即可，误差几 vp 无碍——定位有夹取。
  private contextMenuCardHeightVp(model: ContextMenuModel): number {
    const header: number = model.subtitle.length > 0 ? 61 : 42;
    const rows: number = model.items.length + (model.systemPaste ? 1 : 0);
    return header + 1 + rows * 48 + 6;
  }

  private contextMenuListMaxHeightVp(model: ContextMenuModel): number {
    const header: number = model.subtitle.length > 0 ? 61 : 42;
    return Math.max(96, this.deviceHeightVp() * 0.56 - header - 7);
  }

  private contextMenuPosition(model: ContextMenuModel): Position {
    const screenW: number = this.deviceWidthVp();
    const screenH: number = this.deviceHeightVp();
    const cardW: number = CONTEXT_MENU_CARD_WIDTH_VP;
    const maxCardH: number = Math.max(160, screenH * 0.56);
    const cardH: number = Math.min(this.contextMenuCardHeightVp(model), maxCardH);
    const margin: number = 12;
    let left: number = model.x - 14;
    left = Math.min(Math.max(left, margin), Math.max(margin, screenW - cardW - margin));
    // 优先弹在按压点下方；下方放不下翻到上方；再夹进安全区。
    let top: number = model.y + 14;
    if (top + cardH > screenH - margin) {
      top = model.y - 14 - cardH;
    }
    const minTop: number = Math.max(this.topSafeVp + 8, margin);
    top = Math.min(Math.max(top, minTop), Math.max(minTop, screenH - cardH - margin));
    return { x: left, y: top };
  }

  @Builder
  private ContextMenuLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 一张透明点击层：点到卡片外面就收起来（⋮ 菜单卡同款做法）。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          this.dismissContextMenu();
        })

      this.ContextMenuCard(this.contextMenuModelOrDefault())
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(1),
      TransitionEffect.opacity(0).animation({ duration: 300, curve: Curve.Friction })
    ))
  }

  @Builder
  private ContextMenuCard(model: ContextMenuModel) {
    Column() {
      Column({ space: 2 }) {
        Text(model.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (model.subtitle.length > 0) {
          Text(model.subtitle)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 18, right: 16, top: 12, bottom: 10 })

      Divider()
        .color($r('app.color.divider'))
        .margin({ left: 18, right: 0 })

      Scroll() {
        Column() {
          ForEach(model.items, (item: ContextMenuItem): void => {
            this.ContextMenuRow(item.label, (): void => {
              this.chooseContextMenuAction(model, item.action);
            })
          }, (item: ContextMenuItem): string => item.action)
          if (model.systemPaste) {
            this.ContextMenuRow('粘贴', (): void => {
              this.pasteFromContextMenu(model);
            })
          }
        }
        .width('100%')
        .padding({ bottom: 6 })
      }
      .width('100%')
      .constraintSize({ maxHeight: this.contextMenuListMaxHeightVp(model) })
      // Scroll 默认垂直居中，内容不满时必须显式 TopStart。
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
    .width(CONTEXT_MENU_CARD_WIDTH_VP)
    .borderRadius(22)
    .backgroundColor($r('app.color.menu_glass'))
    .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
    .clip(true)
    .position(this.contextMenuPosition(model))
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(0)
        .combine(TransitionEffect.scale({ x: 0.9, y: 0.9 })),
      TransitionEffect.opacity(0)
        .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
    ).animation({ curve: curves.springMotion(0.3, 0.72) }))
  }

  @Builder
  private ContextMenuRow(label: string, action: () => void) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(48)
    .padding({ left: 18, right: 16 })
    .onClick(action)
  }

  private closeFindBar(): void {
    this.findVisible = false;
    this.findQuery = '';
    this.issueCommand({ command: 'stopFind' });
  }

  private onDownloadEventChanged(): void {
    if (this.downloadEventJson.length === 0) {
      return;
    }
    let ev: DownloadEventPayload;
    try {
      ev = JSON.parse(this.downloadEventJson) as DownloadEventPayload;
    } catch (error) {
      return;
    }
    const name: string = ev.fileName.length > 0 ? ev.fileName : ev.url;
    if (name.length === 0) {
      return;
    }
    if (ev.state === 'inProgress') {
      if (this.downloadSnackAnnouncedId === ev.id) {
        return;
      }
      this.downloadSnackAnnouncedId = ev.id;
      this.showDownloadSnack(ev.id, name, DownloadSnackKind.START, ev.filePath, ev.mimeType);
      return;
    }
    if (ev.state === 'completed') {
      const kind: DownloadSnackKind = ev.dangerous ?
        DownloadSnackKind.DANGEROUS : DownloadSnackKind.DONE;
      this.showDownloadSnack(ev.id, name, kind, ev.filePath, ev.mimeType);
      return;
    }
    if (ev.state === 'failed') {
      this.showDownloadSnack(ev.id, name, DownloadSnackKind.FAILED, ev.filePath, ev.mimeType);
    }
  }

  private showDownloadSnack(id: string, name: string, kind: DownloadSnackKind,
    filePath: string, mimeType: string): void {
    if (this.downloadSnackTimer !== -1) {
      clearTimeout(this.downloadSnackTimer);
      this.downloadSnackTimer = -1;
    }
    this.downloadSnack = {
      id: id,
      name: name,
      kind: kind,
      filePath: filePath,
      mimeType: mimeType,
      isCrx: name.toLowerCase().endsWith('.crx')
    };
    this.downloadSnackVisible = true;
    // 自动消失：开始 4s（完成/失败/危险 6s，留足点动作按钮的时间）。
    const ttl: number = kind === DownloadSnackKind.START ? 4000 : 6000;
    this.downloadSnackTimer = setTimeout((): void => {
      this.downloadSnackTimer = -1;
      this.downloadSnackVisible = false;
    }, ttl);
  }

  private dismissDownloadSnack(): void {
    if (this.downloadSnackTimer !== -1) {
      clearTimeout(this.downloadSnackTimer);
      this.downloadSnackTimer = -1;
    }
    this.downloadSnackVisible = false;
  }

  // 通知条贴 dock 同侧（与 dock 条带相邻，响应区才能合并成单条连续带——
  // 七连败定论：多 region 先 push 的被引擎丢弃）。简约风格 dock 恒底置；
  // Chrome 风格随 chromeDockAtTop()。
  private downloadSnackDockAtTop(): boolean {
    return this.homeStyle === 'chrome' && this.chromeDockAtTop();
  }

  // 通知条固定高 52vp（内容限一行，动作按钮紧凑）。底置：贴在 dock 容器
  // 上沿再上 8vp；顶置：贴在顶置 dock 下沿再下 8vp。
  private downloadSnackTopVp(): number {
    if (this.downloadSnackDockAtTop()) {
      const chromeTop: number = CHROME_DOCK_EXTENT_VP + this.topSafeVp +
        CHROME_DOCK_FLOAT_MARGIN_VP;
      return chromeTop + DOWNLOAD_SNACK_GAP_VP;
    }
    if (this.homeStyle === 'chrome') {
      const chromeBottom: number = CHROME_DOCK_EXTENT_VP + this.bottomSafeVp +
        CHROME_DOCK_FLOAT_MARGIN_VP;
      return Math.max(0, this.viewportHeightVp - chromeBottom -
        DOWNLOAD_SNACK_GAP_VP -
        DOWNLOAD_SNACK_HEIGHT_VP);
    }
    const dockBottom: number = BOTTOM_DOCK_EXTENT_VP + resolveDockBottomMarginVp(this.bottomSafeVp);
    return Math.max(0, this.viewportHeightVp - dockBottom -
      DOWNLOAD_SNACK_GAP_VP -
      DOWNLOAD_SNACK_HEIGHT_VP);
  }

  private downloadSnackBottomVp(): number {
    return this.downloadSnackTopVp() + DOWNLOAD_SNACK_HEIGHT_VP;
  }

  // 「打开」：交给系统选应用（与下载面板 / 通知点击同一路径）。
  private openDownloadedSnackFile(): void {
    if (this.downloadSnack.filePath.length === 0) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    openDownloadedFile(context, this.downloadSnack.filePath, this.downloadSnack.mimeType);
  }

  // 「安装」（.crx）：与下载面板 installCrx 同一路径——拷进沙箱再交给引擎。
  private installDownloadedSnackCrx(): void {
    if (this.downloadSnack.filePath.length === 0) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    try {
      const source = fs.openSync(this.downloadSnack.filePath, fs.OpenMode.READ_ONLY);
      const destPath = `${context.filesDir}/imported-extension.crx`;
      fs.copyFileSync(source.fd, destPath);
      fs.closeSync(source);
      this.issueCommand({ command: 'installExtensionFromFile', path: destPath });
      this.getUIContext().getPromptAction().showToast({
        message: '已开始安装，可在扩展页查看结果',
        duration: 2000
      });
      this.dismissDownloadSnack();
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({
        message: '无法读取这个扩展程序安装包',
        duration: 2000
      });
    }
  }

  private findNext(forward: boolean): void {
    if (this.findQuery.trim().length === 0) {
      return;
    }
    this.issueCommand({ command: 'findInPage', text: this.findQuery, forward: forward });
  }

  private toggleBookmark(): void {
    const url = this.browserState.url;
    if (url.length === 0 || this.isNewTabUrl(url)) {
      return;
    }
    this.issueCommand({
      command: 'addBookmark',
      url: url,
      title: this.browserState.title && this.browserState.title.length > 0 ?
        this.browserState.title : this.displayDomain()
    });
    this.menuCardVisible = false;
    this.getUIContext().getPromptAction().showToast({ message: '已加入书签', duration: 2000 });
  }

  private findMatches(): number {
    try {
      const data = JSON.parse(this.findResultJson) as FindResultSummary;
      return data.matches ?? 0;
    } catch (error) {
      return 0;
    }
  }

  private findActiveMatch(): number {
    try {
      const data = JSON.parse(this.findResultJson) as FindResultSummary;
      return data.activeMatch ?? 0;
    } catch (error) {
      return 0;
    }
  }

  // Google 风格 dock：主页 / 地址栏胶囊 / 标签页 / 菜单 一行排布，可置于顶或底。
  // 地址栏胶囊复用顶栏同款编辑/浏览两态（同 id 复用焦点恢复逻辑）；为不与顶栏的
  // 返回/刷新重复，浏览态只显示锁 + 域名，点按进入编辑。
  @Builder
  private GoogleDock() {
    if (this.chromeDockAtTop()) {
      this.GoogleDockTop();
    } else {
      this.GoogleDockBottom();
    }
  }

  // Chrome dock 跟手收起系数（0~1，夹取）。@Builder 体内首行不能写局部变量，
  // 抽到方法里供 translate 内联调用。
  private chromeDockRatio(): number {
    // 顶置回读引擎 controlsRatio（sendBrowserControls chrome 顶置分支
    // 恢复 top 预留 + minTop=0，引擎原产收起比例，网页同步上顶——传统通栏
    // 跟手隐藏）；底置引擎把 top 锁死不产 ratio，仍读触摸驱动键
    // auraChromeBottomRatio（键名带 Bottom 是历史命名，只驱动底置）。
    const raw: number = this.dockPosition === 'top'
      ? this.controlsRatioRaw
      : this.chromeBottomRatioRaw;
    return Number.isFinite(raw) ? Math.min(Math.max(raw, 0), 1) : 1;
  }

  private isTopBarCollapsing(): boolean {
    return this.hideTopBarOnScroll && !this.topBarPinnedForPage;
  }

  private topBarRatioFloor(): number {
    if (!this.isTopBarCollapsing() || this.hideStatusBarOnScroll || this.topSafeVp <= 0) {
      return 0;
    }
    return this.topSafeVp / (TOP_BAR_EXTENT_VP + this.topSafeVp);
  }

  // Chrome 风格 dock 的“有效位置”——主页恒在顶部（且只留主页/标签页/
  // 菜单三个槽位，无地址胶囊）；网页界面才按设置区分顶/底。dock 派发、菜单卡
  // 对齐、触摸响应区三处都用它，避免主页与设置不一致。
  private chromeDockAtTop(): boolean {
    return this.isHomeSurface() || this.dockPosition === 'top';
  }

  // 顶栏收起“归一化”进度（0=全显，1=全隐）：把引擎 ratio 的 [floor,1] 映射到
  // [0,1]，顶栏才能在引擎的下限处刚好完全隐入（网页同步停在状态栏底）。
  // floor=0（设置开着 / 不收起）时与按 1-ratio 的旧行为逐值相同。
  private topBarHideProgress(): number {
    if (this.isHomeSurface()) {
      return 0;
    }
    const raw: number = Number.isFinite(this.controlsRatioRaw) ? this.controlsRatioRaw : 1;
    const r: number = Math.min(Math.max(raw, 0), 1);
    const floor: number = this.topBarRatioFloor();
    const span: number = 1 - floor;
    return span > 0 ? Math.min(Math.max((1 - r) / span, 0), 1) : (1 - r);
  }

  // 进度条 y 与顶栏收起进度同源：全显贴地址栏下沿，全隐贴状态栏下沿，中间插值。
  // 顶栏位置仍完全由引擎 ratio 驱动，不用覆盖值钉住（会让上滑隐藏失灵）。
  private loadBarY(): number {
    const topY: number = this.topSafeVp;
    // Chrome 风格 dock 置底时顶部没有地址栏（引擎只留状态栏那一条），
    // 若按地址栏下沿定位，蓝条会悬在网页中间 —— 直接贴状态栏下沿。
    if (this.homeStyle === 'chrome' && !this.chromeDockAtTop()) {
      return topY;
    }
    const bottomY: number = this.topSafeVp + TOP_BAR_EXTENT_VP + 3 - this.loadBarHeight;
    const hidden: number = this.topBarHideProgress();
    return bottomY - (bottomY - topY) * hidden;
  }

  private topBarReserveVp(): number {
    if (this.topSafeVp <= 0) {
      return 0;
    }
    const raw: number = Number.isFinite(this.controlsRatioRaw) ? this.controlsRatioRaw : 1;
    const ratio: number = Math.min(Math.max(raw, 0), 1);
    if (this.homeStyle === 'chrome' && !this.chromeDockAtTop()) {
      // 底置：引擎只留状态栏那一条（AuraShell 底置 top=topSafe）——「上滑时隐藏
      // 状态栏」开着且收起完成时 ratio→0，网页铺满物理顶，垫底同步收为 0。
      // 多出的 2vp 随 ratio 一起缩（同顶置多铺 3vp 的手法），压住引擎预留区下沿
      // 那条 ≈1px 圆整缝，又不会在沉浸态给页顶留一条线。
      return (this.topSafeVp + 2) * ratio;
    }
    return (TOP_BAR_EXTENT_VP + this.topSafeVp + 3) * ratio;
  }

  // 下拉刷新事件（AuraShell 转存的 JSON）→ 指示器状态机。
  private onPullRefreshChanged(): void {
    if (this.pullRefreshJson.length === 0) {
      return;
    }
    let payload: PullRefreshPayload;
    try {
      payload = JSON.parse(this.pullRefreshJson) as PullRefreshPayload;
    } catch (error) {
      return;
    }
    if (this.pullIdleTimer !== 0) {
      clearTimeout(this.pullIdleTimer);
      this.pullIdleTimer = 0;
    }
    const state: string = payload.state;
    if (state === 'start') {
      // threshold = 松手能触发刷新的距离；引擎没给就按 64vp 兜底。
      const threshold: number = payload.threshold ?? 0;
      this.pullThreshold = threshold > 8 ? threshold : 64;
      this.pullDistance = 0;
      this.pullPhase = 'pull';
      return;
    }
    if (state === 'pull') {
      this.pullDistance = payload.distance ?? 0;
      if (this.pullPhase !== 'refreshing') {
        this.pullPhase = 'pull';
      }
      return;
    }
    if (state === 'release') {
      if (payload.refresh === true) {
        // 松手且够远：引擎自己开始 reload，指示器停在原地转圈，等 reset 收掉。
        this.pullPhase = 'refreshing';
        this.pullDistance = this.pullThreshold;
        this.pullIdleTimer = setTimeout((): void => {
          this.pullIdleTimer = 0;
          this.pullPhase = 'idle';
          this.pullDistance = 0;
        }, 8000);
      } else {
        this.pullPhase = 'idle';
        this.pullDistance = 0;
      }
      return;
    }
    // reset（或任何未知状态）：收起。
    this.pullPhase = 'idle';
    this.pullDistance = 0;
  }

  // 下拉进度 0~1（按阈值归一）：指示器的缩放/透明度用它。
  private pullProgress(): number {
    if (this.pullPhase === 'refreshing') {
      return 1;
    }
    const threshold: number = this.pullThreshold > 8 ? this.pullThreshold : 64;
    return Math.min(Math.max(this.pullDistance / threshold, 0), 1);
  }

  // 指示器落点（vp）：贴在网页顶边（= 引擎预留区下沿）下方一点；下拉中随距离再
  // 走约一半行程（Chrome 手机版手感），刷新中转圈时停在原地。
  private pullIndicatorTopVp(): number {
    const base: number = Math.max(this.topBarReserveVp(), this.topSafeVp) + 10;
    const travel: number = this.pullPhase === 'refreshing'
      ? 16
      : Math.min(this.pullDistance * 0.5, 44);
    return base + travel;
  }

  // 下拉刷新指示器：圆底 + 系统转圈（LoadingProgress）。纯指示、不参与命中，
  // 顶部条带的滑动照常下发到网页。
  @Builder
  private PullRefreshIndicator() {
    Column() {
      LoadingProgress()
        .width(26)
        .height(26)
        .color($r('app.color.accent_primary'))
        .scale({ x: 0.6 + 0.4 * this.pullProgress(), y: 0.6 + 0.4 * this.pullProgress() })
        .opacity(0.35 + 0.65 * this.pullProgress())
        .animation({ duration: 140, curve: Curve.FastOutSlowIn })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .position({ x: 0, y: this.pullIndicatorTopVp() })
    .animation({ duration: 160, curve: Curve.FastOutSlowIn })
    .hitTestBehavior(HitTestMode.None)
    // 退场动效挂在 if 分支根节点（挂子节点会被整树原子删除，收尾会闪一下）。
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.IDENTITY,
      TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.FastOutSlowIn })
    ))
  }

  // dock 四个槽位（主页 / 地址胶囊 / 标签页 / 菜单），顶/底两种容器共用。
  @Builder
  private GoogleDockButtons() {
    // 主页
    Button({ type: ButtonType.Circle, stateEffect: false }) {
      Image($r('app.media.aura_home'))
        .width(22)
        .height(22)
        .fillColor(this.chromeDockIconColor())
    }
    .width(40)
    .height(40)
    .backgroundColor(Color.Transparent)
    .scale(this.roundScale('dockHome'))
    .onTouch((event: TouchEvent): void => {
      this.handleRoundTouch(event, 'dockHome');
    })
    .accessibilityText('主页')
    .onClick((): void => {
      this.pressHome();
    })
    .gesture(LongPressGesture({ repeat: false, duration: 450 })
      .onAction((): void => {
        this.homeTileMenuVisible = true;
      }))

    // 主页恒在顶部且不放地址胶囊（主页自带搜索框）——只留 主页/标签页/
    // 菜单 三个槽位；网页界面才显示胶囊并按设置区分顶/底。
    if (this.isHomeSurface()) {
      Blank()
        .layoutWeight(1)
    } else {
      // 地址栏胶囊（编辑/浏览两态）
      this.DockAddressCapsule()
    }

    // 标签页
    Button({ type: ButtonType.Circle, stateEffect: false }) {
      Text(this.tabBadgeText())
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.chromeDockIconColor())
        .textAlign(TextAlign.Center)
        .width(22)
        .height(20)
        .borderRadius(6)
        .border({ width: 1.8, color: this.chromeDockIconColor() })
    }
    .width(40)
    .height(40)
    .backgroundColor(Color.Transparent)
    .scale(this.roundScale('dockTabs'))
    .onTouch((event: TouchEvent): void => {
      this.handleRoundTouch(event, 'dockTabs');
    })
    .accessibilityText('标签页')
    .onClick((): void => {
      this.requestTabThumbnails();
      this.menuVisible = true;
    })

    // 菜单
    Button({ type: ButtonType.Circle, stateEffect: false }) {
      Image($r('app.media.aura_more'))
        .width(22)
        .height(22)
        .fillColor(this.chromeDockIconColor())
    }
    .width(40)
    .height(40)
    .backgroundColor(Color.Transparent)
    .scale(this.roundScale('dockMenu'))
    .onTouch((event: TouchEvent): void => {
      this.handleRoundTouch(event, 'dockMenu');
    })
    .accessibilityText('菜单')
    .onClick((): void => {
      this.menuCardVisible = true;
    })
  }

  // 主页态顶栏（Chrome 顶栏 / 简约风格顶部那条）图标色：压在壁纸**顶带**上，
  // 认顶带判据。非主页态回落系统 icon_primary，网页界面行为不变。
  private chromeDockIconColor(): ResourceColor {
    if (this.isHomeSurface() && this.wallpaperPresent) {
      return this.wallpaperTopIsLight ? '#202124' : '#F5F5F5';
    }
    return $r('app.color.icon_primary');
  }

  // 主页态**底部** dock 图标色：压壁纸底带，认底带判据。顶置 dock 用上面那个。
  private bottomDockIconColor(): ResourceColor {
    if (this.isHomeSurface() && this.wallpaperPresent) {
      return this.wallpaperBottomIsLight ? '#202124' : '#F5F5F5';
    }
    return $r('app.color.icon_primary');
  }

  // 同上，但给「经典风格」的材质 dock 用：那个 dock 是独立 struct，
  // 颜色只能以字符串 @Prop 传进去（空串 = 让它回落 icon_primary）。
  private bottomDockInkHex(): string {
    if (this.isHomeSurface() && this.wallpaperPresent) {
      return this.wallpaperBottomIsLight ? '#202124' : '#F5F5F5';
    }
    return '';
  }

  @Builder
  private GoogleDockTop() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 主页态不铺条带底，让壁纸直接铺到状态栏，图标靠 chromeDockIconColor() 反色。
      // 网页态（dock 置顶）才铺实色主表面色遮住网页内容；纯装饰、不参与命中。
      if (!this.isHomeSurface()) {
        Column()
          .width('100%')
          .height(this.topSafeVp + CHROME_DOCK_EXTENT_VP + 3)
          .backgroundColor($r('app.color.surface_primary'))
          .hitTestBehavior(HitTestMode.None)
      }

      Row({ space: 8 }) {
        this.GoogleDockButtons()
      }
      .width('100%')
      .height(CHROME_DOCK_EXTENT_VP)
      .padding({ top: 8, left: 16, right: 16 })
      .position({ x: 0, y: this.topSafeVp })
    }
    .width('100%')
    .height(this.topSafeVp + CHROME_DOCK_EXTENT_VP)
    // 关掉裁剪：滚动隐藏时整条 translate 上移，子节点不被本 Stack 边界裁切。
    .clip(false)
    // 自身透明、子节点（按钮/地址胶囊）照常拦截——条带区的滑动下发到网页。
    .hitTestBehavior(HitTestMode.Transparent)
    // 滚动隐藏：整条上移离屏，行程=整条高（含多铺 3vp）——完全隐入无残留。
    // 收起进度按引擎下限归一化（见 topBarHideProgress）——「上滑时隐藏
    // 状态栏」关着时引擎下限=topSafe，直接用 1-ratio 会卡在半隐。
    // 加 160ms 隐式动画——收起/展开是可见的滑出滑入，不是瞬间跳变。
    .translate({ y: -(this.topBarHideProgress()) * (this.topSafeVp + CHROME_DOCK_EXTENT_VP + 3) })
    .animation({ duration: 160, curve: Curve.FastOutSlowIn })
  }

  @Builder
  private GoogleDockBottom() {
    Stack() {
      // 材质板：系统沉浸光感（HdsTabs 底置浮动条是系统唯一真渲染材质的容器路
      // 径）。它自己按 barBottomMargin 摆位，几何与下面的内容层逐值一致。
      if (this.dockMaterialActive) {
        // 横屏/竖屏各走一个独立分支：跨断点时 HdsTabs 整棵销毁重建，逼它按
        // 当前 tabs 宽度重新选 barWidth 档位，避免沿用另一方向的宽度
        // （见 DOCK_PLATE_WIDE_BREAKPOINT_VP）。
        if (this.dockPlateWide) {
          this.ChromeDockPlate()
        } else {
          this.ChromeDockPlate()
        }
      }

      Column() {
        Stack({ alignContent: Alignment.TopStart }) {
          // 自绘兜底底（无材质设备）：与材质板同一几何 —— 左右由外层 padding 给，
          // 高度就是条带高。
          if (!this.dockMaterialActive) {
            Column()
              .width('100%')
              .height('100%')
              .borderRadius(DOCK_BAR_RADIUS_VP)
              .backgroundColor($r('app.color.glass_tint'))
              .border({ width: 0.5, color: $r('app.color.divider') })
              .shadow({ radius: 18, color: $r('app.color.shadow'), offsetY: 6 })
              .hitTestBehavior(HitTestMode.None)
          }

          if (this.editingAddress) {
            Row() {
              this.ChromeBarAddressEditor()
            }
            .width('100%')
            .height('100%')
            .padding({ left: 10, right: 10 })
          } else {
            // 排布优化（用户：图标和地址排布不均匀）：图标间统一 2vp
            // 呼吸、左右留白收窄到 8 且左右对称；地址胶囊在剩余宽度里均分并
            // 自身居中 —— 四个图标视觉等距，域名居中且拿到最大可用宽度。
            Row({ space: 2 }) {
              this.ChromeBarIconButton($r('app.media.aura_home'), '主页', true, 'dockHome',
                (): void => {
                  this.pressHome();
                })
              this.ChromeBarAddress()
              // 图标变体走 showStopVariant（延迟切换，快速加载不闪 X）；
              // 点击行为仍按真实 loading 判断。
              this.ChromeBarIconButton(this.showStopVariant ?
                $r('app.media.aura_close') : $r('app.media.aura_reload'),
                this.showStopVariant ? '停止' : '刷新', true, 'dockReload', (): void => {
                  this.issueCommand({ command: this.browserState.loading ? 'stop' : 'reload' });
                })
              this.ChromeBarTabCount()
              this.ChromeBarIconButton($r('app.media.aura_more'), '菜单', true, 'dockMenu',
                (): void => {
                  this.menuCardVisible = true;
                })
            }
            .width('100%')
            .height('100%')
            .padding({ left: 8, right: 8 })
          }
        }
        .width('100%')
        .height(CHROME_DOCK_EXTENT_VP)
        // 自身透明：条带空白处的滑动照常下发网页（按钮自身仍是 Default，拦点击）。
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .padding({
        bottom: resolveDockBottomMarginVp(this.bottomSafeVp),
        left: CHROME_DOCK_FLOAT_MARGIN_VP,
        right: CHROME_DOCK_FLOAT_MARGIN_VP
      })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height(CHROME_DOCK_EXTENT_VP + this.bottomSafeVp + CHROME_DOCK_FLOAT_MARGIN_VP)
    // 滚动隐藏地址栏：ratio→0 时整条 dock 下滑离屏（底置隐藏走触摸驱动，见
    // AuraShell.onChromeBottomDockTouch / auraChromeBottomRatio）。
    .translate({ y: (1 - this.chromeDockRatio()) * (CHROME_DOCK_EXTENT_VP + this.bottomSafeVp + CHROME_DOCK_FLOAT_MARGIN_VP) })
  }

  // Chrome 底置材质板。无参 @Builder：内部的宽度/边距每次挂载与刷新都现读
  // state（按值传参的 @Builder 会定死初值，不随状态变化）。
  @Builder
  private ChromeDockPlate() {
    ChromeBarMaterialPlate({
      barWidthVp: this.chromeBarWidthVp(),
      barHeightVp: CHROME_DOCK_EXTENT_VP,
      sideMarginVp: CHROME_DOCK_FLOAT_MARGIN_VP,
      bottomMarginVp: resolveDockBottomMarginVp(this.bottomSafeVp)
    })
  }

  // 材质板宽度（vp）= 视口宽 - 左右留白。必须用 viewportWidthVp（onAreaChange
  // 量到的布局宽），display 只作首帧兜底 —— 转屏瞬间 display 与布局有时序差，
  // 以它为准会让 bar 停在旧方向的宽度上。
  private dockBarWidthVp(sideMarginVp: number): number {
    const margins: number = sideMarginVp * 2;
    if (this.viewportWidthVp > margins + 32) {
      return Math.max(1, this.viewportWidthVp - margins);
    }
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      if (info.densityPixels > 0 && info.width > 0) {
        const vpWidth: number = info.width / info.densityPixels;
        if (Number.isFinite(vpWidth) && vpWidth > margins + 32) {
          return Math.max(1, vpWidth - margins);
        }
      }
    } catch (error) {
      // 取不到就交给下面的设计宽度兜底。
    }
    return 328;
  }

  private chromeBarWidthVp(): number {
    return this.dockBarWidthVp(CHROME_DOCK_FLOAT_MARGIN_VP);
  }

  // 底栏通用圆钮：真 Button（Default 命中 = 不穿透）+ 手写弹簧按压（同顶栏圆钮）。
  @Builder
  private ChromeBarIconButton(icon: Resource, label: string, usable: boolean,
    key: string, action: () => void) {
    Button({ type: ButtonType.Circle, stateEffect: false }) {
      Image(icon)
        .width(22)
        .height(22)
        .fillColor($r('app.color.icon_primary'))
    }
    .width(36)
    .height(36)
    .backgroundColor(Color.Transparent)
    .opacity(usable ? 1 : 0.35)
    .enabled(usable)
    .scale(this.roundScale(key))
    .onTouch((event: TouchEvent): void => {
      this.handleRoundTouch(event, key);
    })
    .accessibilityText(label)
    .hitTestBehavior(HitTestMode.Default)
    .onClick(action)
  }

  // 底栏中段：锁 + 域名（整块是一个 Button：阻断点穿；点按进编辑态=搜索框）。
  // Chrome 手机版样式：整体左对齐（锁贴左、省略号贴右），不做域名居中。
  @Builder
  private ChromeBarAddress() {
    Row({ space: 6 }) {
      // 锁图标：点按打开"网站设置"（方案A），不再进入编辑态。
      Button({ type: ButtonType.Normal, stateEffect: false }) {
        Row({ space: 6 }) {
          if (this.browserState.loading) {
            LoadingProgress()
              .width(15)
              .height(15)
              .color($r('app.color.accent_primary'))
          } else {
            Image($r('app.media.aura_lock'))
              .width(15)
              .height(15)
              .fillColor($r('app.color.icon_secondary'))
          }
        }
        .height(40)
        .padding({ right: 4 })
      }
      .height(40)
      .backgroundColor(Color.Transparent)
      .clip(true)
      .accessibilityText('网站设置')
      .hitTestBehavior(HitTestMode.Default)
      .onClick((): void => this.openSiteSettings())

      // 域名：Button 内容必须包一层 width('100%') 的 Row（同 TopBarContent
      // 2492-2513 的成熟写法）——Button 默认居中内容，裸 Text 的
      // textAlign(Start) 只在自己盒子里生效，域名会被居中而非靠左。
      Button({ type: ButtonType.Normal, stateEffect: false }) {
        Row({ space: 6 }) {
          Text(this.displayDomain())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Start)
            .layoutWeight(1)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .height(40)
      .backgroundColor(Color.Transparent)
      .clip(true)
      .accessibilityText('地址栏')
      .hitTestBehavior(HitTestMode.Default)
      .onClick((): void => this.beginAddressEdit())
    }
    .layoutWeight(1)
    .height(40)
    .padding({ left: 6, right: 6 })
    .backgroundColor(Color.Transparent)
    .clip(true)
  }

  // 底栏右侧：标签页计数徽标（沿用顶置 dock 那枚方框数字）。
  @Builder
  private ChromeBarTabCount() {
    Button({ type: ButtonType.Circle, stateEffect: false }) {
      Text(this.tabBadgeText())
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.chromeDockIconColor())
        .textAlign(TextAlign.Center)
        .width(22)
        .height(20)
        .borderRadius(6)
        .border({ width: 1.8, color: this.chromeDockIconColor() })
    }
    .width(36)
    .height(36)
    .backgroundColor(Color.Transparent)
    .scale(this.roundScale('dockTabs'))
    .onTouch((event: TouchEvent): void => {
      this.handleRoundTouch(event, 'dockTabs');
    })
    .accessibilityText('标签页')
    .hitTestBehavior(HitTestMode.Default)
    .onClick((): void => {
      this.requestTabThumbnails();
      this.menuVisible = true;
    })
  }

  // 底栏编辑态：搜索框（输入 + 关闭）。与顶栏编辑态同一套行为（草稿、联想、
  // 键盘回收、提交），只是整条替换掉按钮行。
  @Builder
  private ChromeBarAddressEditor() {
    TextInput({ text: this.addressDraft, placeholder: '搜索或输入网址',
      controller: this.addressController })
      .id('mobile_address_input')
      .onBlur((): void => {
        this.onAddressInputBlur();
      })
      .layoutWeight(1)
      .height(40)
      .fontSize(16)
      .fontColor($r('app.color.text_primary'))
      .placeholderColor($r('app.color.text_secondary'))
      .backgroundColor(Color.Transparent)
          .padding({ left: 14, right: 10 })
          .enterKeyType(EnterKeyType.Go)
      .onChange((value: string): void => {
        const next: string = this.onAddressInput(value);
        this.addressDraft = next;
        // 单纯聚焦/回显不算输入：别一进地址栏就弹联想列表——那层透明捕获层会
        // 吃掉第一次点按，表现为「取消要点两次」。
        if (!this.addressEdited) {
          this.hideAddressSuggest();
          return;
        }
        this.scheduleAddressSuggest(next);
      })
      .onTextSelectionChange((start: number, end: number): void => {
        this.addressSelectionStart = start;
        this.addressSelectionEnd = end;
      })
      .onSubmit((): void => {
        this.submitAddress();
      })
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Text('取消')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.accent_primary'))
    }
    .width(52)
    .height(36)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .hitTestBehavior(HitTestMode.Default)
    .onClick((): void => {
      this.cancelAddressEdit();
    })
  }

  // 取消地址编辑（顶栏/底栏共用）：收起联想、清键盘回收定时器；若刚才提交过
  // 导航（回弹在途）则延迟交还控件，否则立即交还——两边行为必须一致。
  private cancelAddressEdit(): void {
    this.clearKeyboardRecoveryTimers();
    this.hideAddressSuggest();
    // 先把输入框从编辑态摘出来（收起选区/光标），再关面板 —— 选区还在时第一次
    // 点按会被输入框吃掉，表现为「取消要点两次」。
    try {
      this.addressController.stopEditing();
    } catch (error) {
    }
    const navigating: boolean = this.pendingControlsRebound || this.controlsRestoreTimer !== 0;
    this.cancelControlsRebound();
    // 先退出编辑态（UI 立即收起搜索面板），再异步交还浏览器控件——避免引擎
    // 命令滞后或异常时面板卡住、叉点不动。
    this.editingAddress = false;
    try {
      inputMethod.getController().hideTextInput().catch((): void => {});
    } catch (error) {
    }
    if (navigating) {
      this.restoreControlsSoon();
    } else {
      try {
        this.issueCommand({ command: 'setBrowserControlsState', state: 'both', animate: true });
      } catch (error) {
      }
    }
  }

  private onMenuVisibleChanged(): void {
    if (this.menuVisible) {
      this.dismissKeyboardForOverlay();
    }
  }

  private onMenuCardVisibleChanged(): void {
    if (this.menuCardVisible) {
      this.dismissKeyboardForOverlay();
    }
  }

  private dismissKeyboardForOverlay(): void {
    if (this.editingAddress) {
      this.cancelAddressEdit();
      return;
    }
    // 非编辑态也可能有残留键盘（刚提交过导航、联想面板刚收），统一再关一次，
    // 成本只有一次 IPC。
    try {
      inputMethod.getController().hideTextInput().catch((): void => {});
    } catch (error) {
    }
  }

  private onAddressInputBlur(): void {
    if (!this.editingAddress) {
      return;
    }
    const epoch: number = this.addressEditEpoch;
    setTimeout((): void => {
      if (this.editingAddress && this.addressEditEpoch === epoch) {
        this.cancelAddressEdit();
      }
    }, 60);
  }

  // dock 内地址栏胶囊：浏览态显示锁 + 域名（点按编辑），编辑态显示输入框 + 关闭。
  @Builder
  private DockAddressCapsule() {
    if (this.editingAddress) {
      Row({ space: 6 }) {
        TextInput({ text: this.addressDraft, placeholder: '搜索或输入网址',
          controller: this.addressController })
          .id('mobile_address_input')
          .onBlur((): void => {
            this.onAddressInputBlur();
          })
          .layoutWeight(1)
          .height(40)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .padding({ left: 16, right: 12 })
          .enterKeyType(EnterKeyType.Go)
          // 同上：不用 selectAll，改「首字符替换整条」（见 onAddressInput）。
          .onChange((value: string) => {
            const next: string = this.onAddressInput(value);
            this.addressDraft = next;
            // 单纯聚焦/回显不算输入：别一进地址栏就弹联想列表——那层透明捕获层
            // 会吃掉第一次点按，表现为「取消要点两次」。
            if (!this.addressEdited) {
              this.hideAddressSuggest();
              return;
            }
            this.scheduleAddressSuggest(next);
          })
          .onTextSelectionChange((start: number, end: number): void => {
            this.addressSelectionStart = start;
            this.addressSelectionEnd = end;
          })
          .onSubmit((): void => {
            this.submitAddress();
          })
        // 与另两处编辑态统一为「取消」文字按钮 + cancelAddressEdit()，
        // 不再三处各写一份内联取消逻辑（同款「取消」，命中更稳）。
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Text('取消')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accent_primary'))
        }
        .width(48)
        .height(36)
        .padding(0)
        .margin({ right: 2 })
        .backgroundColor(Color.Transparent)
        .hitTestBehavior(HitTestMode.Default)
        .onClick((): void => {
          this.cancelAddressEdit();
        })
      }
      .layoutWeight(1)
      .height(40)
      .padding({ left: 8, right: 8 })
      .borderRadius(20)
      .backgroundColor($r('app.color.glass_tint'))
      .border({ width: 0.5, color: $r('app.color.divider') })
    } else {
        Row({ space: 6 }) {
          // 锁图标：点按打开"网站设置"（方案A），不再进入编辑态。
          Button({ type: ButtonType.Normal, stateEffect: false }) {
            if (this.browserState.loading) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color($r('app.color.accent_primary'))
            } else {
              Image($r('app.media.aura_lock'))
                .width(15)
                .height(15)
                .fillColor($r('app.color.icon_secondary'))
            }
          }
          .height(40)
          .padding({ left: 6 })
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.Default)
          .accessibilityText('网站设置')
          .onClick((): void => this.openSiteSettings())

          // 域名：Button 内容包一层 width('100%') 的 Row（同 TopBarContent）——
          // Button 默认居中内容，裸 Text 的 textAlign(Start) 不生效。
          Button({ type: ButtonType.Normal, stateEffect: false }) {
            Row({ space: 6 }) {
              Text(this.displayDomain())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .textAlign(TextAlign.Start)
                .layoutWeight(1)
            }
            .width('100%')
          }
          .layoutWeight(1)
          .height(40)
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.Default)
          .accessibilityText('地址栏')
          .onClick((): void => this.beginAddressEdit())
        }
        .layoutWeight(1)
        .height(40)
        .padding({ left: 10, right: 12 })
        .borderRadius(20)
        .backgroundColor($r('app.color.glass_tint'))
        .border({ width: 0.5, color: $r('app.color.divider') })
    }
  }

  build() {
    Stack() {
      // 页面切换帘幕：最底层（引擎之上、chrome 之下）。URL 变化时横向扫过，
      // 不参与命中（滑动/点击照常下发到网页）。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.surface_primary'))
        .translate({ x: this.navVeilShift * this.pageWidthVp() })
        .hitTestBehavior(HitTestMode.None)

      if (!this.isHomeSurface() && !this.pageFullscreen &&
        this.topBarReserveVp() > 0.5 && this.topBarHideProgress() < 0.95) {
        Column()
          .width('100%')
          .height(this.topBarReserveVp())
          .backgroundColor($r('app.color.surface_primary'))
          .position({ x: 0, y: 0 })
          .hitTestBehavior(HitTestMode.None)
      }

      Column() {
        if (this.homeStyle === 'chrome') {
          // Chrome 风格：地址栏融进 dock，单一浮层条带（顶或底）。
          this.GoogleDock()
        } else {
          // The home surface (new tab) already carries a search box; the
          // address bar would duplicate it right above, so it only shows
          // while browsing actual pages.
          if (!this.isHomeSurface()) {
            this.TopAddressBar()
          }
          this.BottomDock()
        }
      }
      .width('100%')
      .height('100%')
      // Chrome 风格按 dock 位置钉到顶或底；简约风格主页只留 dock 钉到尾部。
      // The floating bars carry their own safe-area padding, so this layer
      // carries none of its own.
      .justifyContent(this.homeStyle === 'chrome' ?
        (this.chromeDockAtTop() ? FlexAlign.Start : FlexAlign.End) :
        (this.isHomeSurface() ? FlexAlign.End : FlexAlign.SpaceBetween))
      .hitTestBehavior(HitTestMode.Transparent)
      // 网页全屏（video / requestFullscreen）期间**整条 chrome 不显示**：
      // 引擎在页面滚动/触摸时会把浏览器控件重新"显示"（controlsRatio 回 1），
      // 外壳若还画着条带，地址栏就会在全屏视频上滑出来（用户实测：全屏播放时
      // 滑动会冒出地址栏）。Visibility.None 既不出现在布局里，也不参与命中。
      .visibility(this.pageFullscreen ? Visibility.None : Visibility.Visible)
      .bindSheet($$this.menuVisible, this.MenuSheet, {
        height: SheetSize.LARGE,
        showClose: false,
        enableOutsideInteractive: false,
        maskColor: Color.Transparent
      })

      // 状态栏实色垫底：主页图层在场时不画，否则会「上面白、下面壁纸」。
      if (!this.hideStatusBarOnScroll && !this.isHomeSurface() &&
        this.topSafeVp > 0 && !this.pageFullscreen) {
        Column()
          .width('100%')
          .height(this.topSafeVp + 2)
          .backgroundColor($r('app.color.surface_primary'))
          .position({ x: 0, y: 0 })
          .hitTestBehavior(HitTestMode.None)
      }

      // 进度条独立于顶栏绘制，y 跟随顶栏收起进度；画在状态栏垫底之上。
      if (this.loadBarShown && !this.isHomeSurface() && !this.pageFullscreen) {
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width(`${Math.min(Math.max(this.loadBarWidth, this.loadBarMin), 1) * 100}%`)
            .height(this.loadBarHeight)
            // 只圆右端：自左向右生长的细条；左端贴着屏幕边。
            .borderRadius({ topRight: this.loadBarHeight, bottomRight: this.loadBarHeight })
            .backgroundColor($r('app.color.accent_primary'))
            // 宽度变化由属性动画接管（同步 200ms / EaseOut）。
            .animation({ duration: this.loadBarGrowMs, curve: Curve.EaseOut })
        }
        .width('100%')
        .height(this.loadBarHeight)
        .clip(true)
        .position({ x: 0, y: this.loadBarY() })
        // 不加 transition：其时长在节点创建时求值一次，之后不重算，
        // 无法按 isHomeSurface() 动态改成 0。退场由 hideLoadBarNow() 直接卸载；
        // y 不加属性动画，避免滚动时反复重启导致滞后。纯指示、不参与命中。
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.pullPhase !== 'idle' && !this.isHomeSurface()) {
        this.PullRefreshIndicator()
      }

      // 地址栏联想列表：挂在 bars 之后（绘制在顶栏之上，不遮 bars 自身），
      // 全屏捕获层由 responseRegion 的全屏分支保证命中（见 buildChromeTouch
      // Regions —— 联想在场时整屏归 overlay，顺带挡住网页）。
      if (this.suggestListActive()) {
        this.AddressSuggestLayer()
      }

      // 页内查找 bar sits under the status area, above everything else.
      if (this.findVisible) {
        this.FindBar()
      }

      if (this.menuCardVisible) {
        Stack({ alignContent: Alignment.Bottom }) {
          // 浅遮罩：点按收起。18% 黑——页面仍可见，聚焦感比全透明强。
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0, 0, 0, 0.18)')
            .onClick(() => {
              this.closeMenuCard();
            })

          this.MenuBottomSheet()
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0).animation({ duration: 220, curve: Curve.FastOutSlowIn }),
          TransitionEffect.opacity(0).animation({ duration: 240, curve: Curve.Friction })
        ))
      }

      // 小锁快捷面板（底部卡）：结构同 ⋮ 菜单 sheet —— 全屏浅遮罩 + 贴底卡。
      if (this.siteQuickVisible) {
        Stack({ alignContent: Alignment.Bottom }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0, 0, 0, 0.18)')
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => {
              this.siteQuickVisible = false;
            })

          Column() {
            SiteQuickPanel({
              host: this.displayDomain(),
              tabId: (AppStorage.get('auraActiveTabId') as string) ?? '',
              onCommand: (command: BrowserCommandPayload): void => {
                this.issueCommand(command);
              },
              onClose: (): void => {
                this.siteQuickVisible = false;
              },
              onOpenSiteSettings: (): void => {
                router.pushUrl({ url: 'pages/panels/SiteSettingsPanelPage' }).catch((error: Error): void => {
                  console.error('openSiteSettings pushUrl failed:', error);
                });
              }
            })
          }
          .width('100%')
          .borderRadius({ topLeft: 20, topRight: 20 })
          .backgroundColor($r('app.color.card_background'))
          .clip(true)
          .onClick((): void => {})
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0).animation({ duration: 220, curve: Curve.FastOutSlowIn }),
          TransitionEffect.opacity(0).animation({ duration: 240, curve: Curve.Friction })
        ))
      }

      // 「自定义网址」入口菜单（长按 dock 主页图标弹出）。
      if (this.homeTileMenuVisible) {
        this.HomeTileMenu()
      }

      // 「网址主页」设置表单（两个入口共用）。
      if (this.homeUrlFormVisible) {
        this.HomeUrlFormOverlay()
      }

      // 长按菜单（v13）：贴着按压点弹的自绘卡片；点卡片外 / 按返回收起来。
      // 数据来自 AuraShell 写进 AppStorage 的 ContextMenuModel。
      if (this.contextMenuJson.length > 0) {
        this.ContextMenuLayer()
      }

      if (this.downloadSnackVisible) {
        this.DownloadSnackLayer()
      }
    }
    .width('100%')
    .height('100%')
    // 视口高度/宽度（vp）：dock 条带的响应区以高度为底边基准；面板开合
    // 动效以宽度为位移基准。首次布局即上报，转屏 / 窗口变化时更新。
    .onAreaChange((_old: Area, next: Area): void => {
      const measured: number = Number(next.height);
      if (Number.isFinite(measured) && measured > 0 &&
          Math.abs(measured - this.viewportHeightVp) > 0.5) {
        this.viewportHeightVp = measured;
      }
      const measuredWidth: number = Number(next.width);
      if (Number.isFinite(measuredWidth) && measuredWidth > 0 &&
          Math.abs(measuredWidth - this.viewportWidthVp) > 0.5) {
        this.viewportWidthVp = measuredWidth;
      }
      // 横竖屏档位：跨断点会让承载材质板的 if 分支翻转一次，HdsTabs 随之
      // 销毁重建并重新量宽度/选 barWidth 档（见 DOCK_PLATE_WIDE_BREAKPOINT_VP）。
      // 赋同值不触发刷新，稳态下没有额外重建。
      if (Number.isFinite(measuredWidth) && measuredWidth > 0) {
        this.dockPlateWide = measuredWidth >= DOCK_PLATE_WIDE_BREAKPOINT_VP;
      }
    })
    .responseRegion(this.buildChromeTouchRegions())
    .hitTestBehavior(this.resolveChromeHitTestMode())
  }

  private buildChromeTouchRegions(): Array<Rectangle> {
    const regions: Array<Rectangle> = [];
    // 网页全屏：外壳不画条带，也就没有要拦的条区 —— 整屏交给网页，
    // 否则顶部/底部那两条响应区会吃掉视频的点击与滑动。
    if (this.pageFullscreen) {
      return regions;
    }
    // 模态层（七页面板 / ⋮ 悬浮菜单卡 / 长按菜单 / 地址栏联想列表）在场：
    // 整屏归它，直接全屏响应区，顺带把网页挡在后面（菜单卡/联想列表点外
    // 收起时不再误点页面）。
    if (this.menuCardVisible || this.homeTileMenuVisible ||
      this.homeUrlFormVisible || this.contextMenuJson.length > 0 || this.suggestListActive() ||
      this.siteQuickVisible) {
      const full: Rectangle = { x: 0, y: 0, width: '100%', height: '100%' };
      regions.push(full);
      return regions;
    }
    if (this.findVisible) {
      // 查找栏底沿 = 顶边距 + 卡高 48 + 余量 4。
      const findBottom: number = this.findBarTopMarginVp() + 48 + 4;
      // 顶部有 chrome（chrome 顶置 / 简约网页页）→ chrome 与查找栏连续，
      // 一条 region 从屏幕顶到查找栏底；chrome 底置时两者不连续（查找栏在
      // 顶、dock 在底），只保查找栏一条（查找期间 dock 暂让位，可接受）。
      const chromeOnTop: boolean = this.homeStyle === 'chrome'
        ? this.chromeDockAtTop() : !this.isHomeSurface();
      if (chromeOnTop) {
        regions.push({ x: 0, y: 0, width: '100%', height: findBottom });
      } else {
        regions.push({ x: 0, y: this.findBarTopMarginVp(), width: '100%', height: 52 });
      }
      return regions;
    }
    if (this.downloadSnackVisible) {
      if (this.viewportHeightVp <= 0) {
        regions.push({ x: 0, y: 0, width: '100%', height: '100%' });
        return regions;
      }
      if (this.downloadSnackDockAtTop()) {
        // 顶置：屏幕顶 → snackbar 底沿（含顶置 dock）。
        regions.push({ x: 0, y: 0, width: '100%', height: this.downloadSnackBottomVp() });
      } else {
        // 底置：snackbar 顶沿 → 屏幕底（含底置 dock）。
        regions.push({
          x: 0,
          y: this.downloadSnackTopVp(),
          width: '100%',
          height: Math.max(1, this.viewportHeightVp - this.downloadSnackTopVp())
        });
      }
      return regions;
    }
    // Chrome 风格：整条 dock 占据顶或底，作为唯一可交互条带（不再有独立顶栏）。
    if (this.homeStyle === 'chrome') {
      if (this.chromeDockAtTop()) {
        // 顶置通宽条带：响应区随收起进度收缩（与条带 translate 同一归一化进度，
        // 见 topBarHideProgress），完全收起时不占区域——收起后那一带照常可点可滑。
        const shown: number = (1 - this.topBarHideProgress()) *
          (CHROME_DOCK_EXTENT_VP + 3 + this.topSafeVp);
        if (shown > 0.5) {
          regions.push({ x: 0, y: 0, width: '100%', height: shown });
        }
      } else if (this.viewportHeightVp > 0) {
        const chromeH: number = CHROME_DOCK_EXTENT_VP + this.bottomSafeVp;
        regions.push({
          x: 0,
          y: this.viewportHeightVp - chromeH - CHROME_DOCK_FLOAT_MARGIN_VP,
          width: '100%',
          height: chromeH + CHROME_DOCK_FLOAT_MARGIN_VP
        });
      }
      return regions;
    }

    // 顶栏条带：新标签页没有顶栏，不占（否则首页顶部会出现一条死区）。
    // 按归一化收起进度（见 topBarHideProgress）——「上滑时隐藏状态栏」
    // 关着时引擎下限=topSafe，直接用 ratio 响应区会卡在半隐。
    if (!this.isHomeSurface()) {
      const topShown: number = (1 - this.topBarHideProgress()) * (TOP_BAR_EXTENT_VP + this.topSafeVp);
      if (topShown > 0.5) {
        const top: Rectangle = { x: 0, y: 0, width: '100%', height: topShown };
        regions.push(top);
      }
    }
    // dock 条带：底边贴视口底，高度 = 收起比例 × 全高。
    if (this.viewportHeightVp > 0) {
      const dockShown: number = this.dockRatio() * (BOTTOM_DOCK_EXTENT_VP + resolveDockBottomMarginVp(this.bottomSafeVp));
      if (dockShown > 0.5 && dockShown < this.viewportHeightVp) {
        const dock: Rectangle = {
          x: 0,
          y: this.viewportHeightVp - dockShown,
          width: '100%',
          height: dockShown
        };
        regions.push(dock);
      }
    }
    return regions;
  }

  // dock 的显隐系数：“滚动时隐藏底部栏”关掉后恒为 1（常驻）；开着时即顶栏
  // 收起比例（两栏默认跟手同收）。例外：地址栏也设为常驻时引擎比例被锁死
  // （恒 1），dock 改用触摸观察层的位移（AuraShell 维护，1 = 全显）。
  private dockRatio(): number {
    if (this.isHomeSurface()) {
      return 1;
    }
    if (!this.hideDockOnScroll) {
      return 1;
    }
    // 引擎不产比例（页面不滚动）时，外壳用触摸直接收放 dock 并置这一位。
    if (!this.isTopBarCollapsing() || this.swipeDockRatioOn) {
      const touch: number = Number.isFinite(this.touchDockRatio) ? this.touchDockRatio : 1;
      return Math.min(Math.max(touch, 0), 1);
    }
    const raw: number = Number.isFinite(this.controlsRatioRaw) ? this.controlsRatioRaw : 1;
    const r: number = Math.min(Math.max(raw, 0), 1);
    // 减去引擎下限（minTop=topSafe 时收起终点是 topSafe/top 而不是 0，
    // 见 topBarRatioFloor），否则 dock 会停在半隐；floor=0 时与旧行为逐值相同。
    const floor: number = this.topBarRatioFloor();
    const span: number = 1 - floor;
    return span > 0 ? Math.min(Math.max((r - floor) / span, 0), 1) : r;
  }

  // 根命中模式：模态层（七页面板 / ⋮ 菜单卡 / 长按菜单）在场 → Default +
  // 全屏响应区，整屏阻断、交给模态层自身处理点击；正常浏览 → Transparent，
  // 页面区直达 XComponent（消除 dock/顶栏全宽条带矩形对滑动起始段的拦截——
  // 修复"手指滑出一段页面才滚"），dock/顶栏的按钮、地址栏等控件自身是
  // Default 子节点，仍正常拦截点击。
  private resolveChromeHitTestMode(): HitTestMode {
  const modal: boolean = this.menuCardVisible || this.contextMenuJson.length > 0 ||
    this.siteQuickVisible || this.suggestListActive() || this.findVisible ||
    this.downloadSnackVisible;
  return modal ? HitTestMode.Default : HitTestMode.Transparent;
  }

  @Builder
  private EdgeButton(action: MobileEdgeAction) {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph(action === MobileEdgeAction.BACK ?
        $r('sys.symbol.chevron_backward') : $r('sys.symbol.more'))
        .fontSize(24)
        .fontColor([ $r('app.color.icon_primary') ])
    }
    .width(52)
    .height(52)
    .backgroundColor($r('app.color.surface_floating'))
    .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 4 })
    .visualEffect(this.buildBubbleEffect())
    .opacity(action === MobileEdgeAction.BACK && !this.browserState.canGoBack ? 0.52 : 1)
    .enabled(action !== MobileEdgeAction.BACK || this.browserState.canGoBack)
    .accessibilityText(action === MobileEdgeAction.BACK ? '返回' : '菜单')
    .onClick(() => this.handleEdgeAction(action))
  }

  // 悬浮地址胶囊：只有「胶囊 + 扩展圆钮」两块玻璃，周围留边、悬浮在页面上，
  // 没有通宽色带（色带会把胶囊和屏幕边连成一条，不再是悬浮动画）。
  // 材质用 glass_tint 半透明纯色：网页走 SURFACE 独立图层，模糊采不到它的内容，
  // 契约 §8 明确"网页上方不要叠模糊控件"，所以不用 backgroundBlurStyle。
  // 条区总高 = 引擎通过 setBrowserControls top 保留的高度
  // （TOP_BAR_EXTENT_VP + 顶部安全区），页面顶边从条区下沿开始。
  @Builder
  private TopAddressBar() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.isHomeSurface()) {
        // 网页态铺不透明同色带遮住网页顶部；主页态让壁纸直接透出状态栏，
        // 地址胶囊自带底色，无需额外遮挡。
        Column()
          .width('100%')
          .height(this.topSafeVp + TOP_BAR_EXTENT_VP + 3)
          .backgroundColor($r('app.color.surface_primary'))
          .hitTestBehavior(HitTestMode.None)
      }

      Row({ space: 8 }) {
        // Main pill: back chevron + lock + URL + reload, all in one capsule.
        Row() {
          this.TopBarContent()
        }
        .layoutWeight(1)
        .height(40)
        .borderRadius(20)
        .backgroundColor($r('app.color.glass_tint'))
        .border({ width: 0.5, color: $r('app.color.divider') })
        .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 4 })

      }
      .width('100%')
      .padding({ top: this.topSafeVp + 8, left: 16, right: 16 })
    }
    .width('100%')
    .height(this.topSafeVp + TOP_BAR_EXTENT_VP)
    // 自身响应 + 不阻塞兄弟/下层（与原来的全宽 Row 同一命中语义），
    // 保证顶部条区的滑动仍能下发到网页。
    .hitTestBehavior(HitTestMode.Transparent)
    .translate({ y: -(this.topBarHideProgress()) * (TOP_BAR_EXTENT_VP + this.topSafeVp + 2) })
    .animation({ duration: 160, curve: Curve.FastOutSlowIn })
  }

  @Builder
  private TopBarContent() {
      if (this.editingAddress) {
        TextInput({ text: this.addressDraft, placeholder: '搜索或输入网址',
          controller: this.addressController })
          .id('mobile_address_input')
          .onBlur((): void => {
            this.onAddressInputBlur();
          })
          .layoutWeight(1)
          .height(40)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .padding({ left: 16, right: 12 })
          .enterKeyType(EnterKeyType.Go)
          // 同上：不用 selectAll，改「首字符替换整条」（见 onAddressInput）。
          .onChange((value: string) => {
            const next: string = this.onAddressInput(value);
            this.addressDraft = next;
            // 单纯聚焦/回显不算输入：别一进地址栏就弹联想列表——那层透明捕获层
            // 会吃掉第一次点按，表现为「取消要点两次」。
            if (!this.addressEdited) {
              this.hideAddressSuggest();
              return;
            }
            this.scheduleAddressSuggest(next);
          })
          .onTextSelectionChange((start: number, end: number): void => {
            this.addressSelectionStart = start;
            this.addressSelectionEnd = end;
          })
          .onSubmit(() => {
            this.submitAddress();
          })
        // 与底置编辑态统一——去掉系统 PasteButton（授权浮层拖死整屏
        // 点击），圆叉换成「取消」文字按钮（命中稳定）；取消逻辑
        // 汇流到 cancelAddressEdit()（含键盘收回与异常隔离）。
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Text('取消')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accent_primary'))
        }
        .width(52)
        .height(36)
        .padding(0)
        .margin({ right: 5 })
        .backgroundColor(Color.Transparent)
        .hitTestBehavior(HitTestMode.Default)
        .onClick((): void => {
          this.cancelAddressEdit();
        })
      } else {
        // 地址栏不再放返回键（与底栏「返回」重复）。底栏保留 返回+前进。
        Row({ space: 6 }) {
          // 锁图标：点按打开"网站设置"（方案A），不再进入编辑态。
          Button({ type: ButtonType.Normal, stateEffect: false }) {
            if (this.browserState.loading) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color($r('app.color.accent_primary'))
            } else {
              Image($r('app.media.aura_lock'))
                .width(15)
                .height(15)
                .fillColor($r('app.color.icon_secondary'))
            }
          }
          .height(40)
          .padding({ left: 6 })
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.Default)
          .accessibilityText('网站设置')
          .onClick(() => this.openSiteSettings())

          Button({ type: ButtonType.Normal, stateEffect: true }) {
            Row({ space: 6 }) {
              if (this.incognito) {
                Text('无痕')
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(6)
                  .backgroundColor($r('app.color.surface_secondary'))
              }
              Text(this.displayDomain())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .textAlign(TextAlign.Start)
                .layoutWeight(1)
            }
            .width('100%')
          }
          .layoutWeight(1)
          .height(40)
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.Default)
          .accessibilityText('地址栏')
          .onClick(() => this.beginAddressEdit())
        }
        .layoutWeight(1)
        .height(40)
        .padding({ left: 6, right: 6 })
        .backgroundColor(Color.Transparent)

        Button({ type: ButtonType.Circle, stateEffect: true }) {
          Image(this.showStopVariant ?
            $r('app.media.aura_close') : $r('app.media.aura_reload'))
            .width(20)
            .height(20)
            .fillColor($r('app.color.icon_primary'))
        }
        .width(38)
        .height(38)
        .margin({ right: 3 })
        .backgroundColor(Color.Transparent)
        .scale(this.roundScale('barReload'))
        .onTouch((event: TouchEvent): void => {
          this.handleRoundTouch(event, 'barReload');
        })
        .accessibilityText(this.showStopVariant ? '停止' : '刷新')
        .onClick(() => {
          this.issueCommand({ command: this.browserState.loading ? 'stop' : 'reload' });
        })
      }
  }

  // ---- 地址栏联想列表 ----

  private suggestAboveBottomBar(): boolean {
    return this.homeStyle === 'chrome' && !this.chromeDockAtTop() && !this.isHomeSurface();
  }

  // 底置条带上沿的 y（vp）——联想卡贴它的上方、捕获层也画到它为止。
  // 抽成方法：@Builder 体内不能写局部变量（ArkTS 红线，见 ref/04）。
  private suggestBarTopVp(): number {
    const total: number = CHROME_DOCK_EXTENT_VP + this.bottomSafeVp + CHROME_DOCK_FLOAT_MARGIN_VP;
    return this.viewportHeightVp > total ? this.viewportHeightVp - total : 0;
  }

  // 联想卡滚动控制器：底置时视口要停在底部（见 pinSuggestScrollToBottom）。
  private suggestScroller: Scroller = new Scroller();

  // 贴底滚动不能放在 onAreaChange 里同步做（布局中改布局会二次测量、打字顿挫），
  // 排到下一帧并去重。
  private suggestPinTimer: number = -1;

  // 底置形态把滚动视口钉到底部；顶置/竖屏直接返回，行为一点不变。
  private pinSuggestScrollToBottom(): void {
    if (!this.suggestAboveBottomBar()) {
      return;
    }
    if (this.suggestPinTimer >= 0) {
      return;
    }
    this.suggestPinTimer = setTimeout((): void => {
      this.suggestPinTimer = -1;
      try {
        this.suggestScroller.scrollEdge(Edge.Bottom);
      } catch (error) {
      }
    }, 0);
  }

  // 联想行渲染顺序：地址栏在底时倒序 —— 卡片贴地址栏往上长，视线从地址栏往上
  // 扫，suggestRows() 的第一条（搜索"输入"）应排在最下面。顶置/竖屏保持原序。
  private suggestRowsForLayout(): AutocompleteItem[] {
    const rows: AutocompleteItem[] = this.suggestRows();
    if (!this.suggestAboveBottomBar()) {
      return rows;
    }
    return rows.slice().reverse();
  }

  // 联想卡高度上限（vp）。卡片最多 8 行 ≈370vp，横屏 + 键盘弹起时可用高度只剩
  // 两三百 vp，不设上限会溢出屏幕或被键盘盖住；超出的行由卡内滚动承接。
  private suggestCardMaxHeightVp(): number {
    const viewport: number = this.viewportHeightVp > 0 ? this.viewportHeightVp : 780;
    // 键盘若仍是浮层（窗口没被压缩）就从可用高里再刨掉它；RESIZE 模式下
    // viewport 已含压缩结果、keyboardVp 为 0，不会二次扣减。
    const usable: number = Math.max(160, viewport - Math.max(this.keyboardVp, 0));
    if (this.suggestAboveBottomBar()) {
      // 地址栏在下：卡片贴着条带上沿往上长，天花板是条带上沿。
      const barTop: number = this.suggestBarTopVp();
      const ceiling: number = barTop > 0 ? Math.min(barTop, usable) : usable;
      // 卡片是从容器**底边往上长**的，顶部必须再留出状态栏 + 呼吸位，
      // 否则横屏视口矮时会一直长到状态栏上面去（用户实测：Chrome 风格地址栏
      // 在下时联想卡「顶出屏幕上边」）。14 = 容器底 padding 6 + 顶部呼吸 8。
      const topReserve: number = Math.max(this.topSafeVp, 0) + 14;
      return Math.max(96, ceiling - topReserve);
    }
    // 地址栏在上：卡片从条带下沿往下长。
    const top: number = this.topSafeVp + TOP_BAR_EXTENT_VP + 6;
    return Math.max(96, usable - top - 8);
  }

  @Builder
  private AddressSuggestLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.suggestAboveBottomBar() && this.suggestBarTopVp() > 0) {
        Column()
          .width('100%')
          .height(this.suggestBarTopVp())
          .position({ x: 0, y: 0 })
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.hideAddressSuggest();
          })

        Column() {
          this.SuggestCard()
        }
        .width('100%')
        .height(this.suggestBarTopVp())
        .justifyContent(FlexAlign.End)
        .padding({ left: 16, right: 16, bottom: 6 })
      } else {
        // 捕获层从顶栏下沿才开始：点地址栏本体（改光标/取消）不受影响，
        // 点列表外任意处才收起联想（保持编辑态与键盘）。
        Column()
          .width('100%')
          .height('100%')
          .position({ x: 0, y: this.topSafeVp + TOP_BAR_EXTENT_VP })
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.hideAddressSuggest();
          })

        Row() {
          this.SuggestCard()
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        // 贴在胶囊下沿：安全区 + 条高(48) + 6 间隙。
        .position({ x: 0, y: this.topSafeVp + TOP_BAR_EXTENT_VP + 6 })
      }
    }
    .width('100%')
    .height('100%')
    // 快进快出：键盘弹起动画期间不抢戏；退场（点外收起/提交）略慢于进场。
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(0).animation({ duration: 120, curve: Curve.Friction }),
      TransitionEffect.opacity(0).animation({ duration: 160, curve: Curve.Friction })
    ))
  }

  // 联想卡本体（顶置贴下沿 / 底置贴上沿两处共用同一张卡）。
  @Builder
  private SuggestCard() {
    // 外壳从 Column 换成 Scroll：横屏 + 键盘占位时可用高度不足（见
    // suggestCardMaxHeightVp），卡片按上限收缩、超出的行进卡内滚动，
    // 而不是被裁掉。圆角/底色/阴影/裁剪跟着挪到 Scroll 上，外观不变。
    Scroll(this.suggestScroller) {
      Column() {
        // 键里**不能带 index**：首行「搜索 “输入”」每敲一个字就变，带 index 会让
        // 整张卡（8 行 + 图标）全部销毁重建 —— 打字时列表一顿一顿就是这个。
        // 用 type|url|title 作键，只有真正变了那一行重建。
        ForEach(this.suggestRowsForLayout(), (item: AutocompleteItem, index: number) => {
          this.AddressSuggestRow(item, index)
        }, (item: AutocompleteItem, index: number): string =>
          `${item.type}|${item.url}|${item.title}`)
      }
      .width('100%')
      // 内容尺寸变化（打字、候选增减）时底置形态重新贴底，保证紧挨地址栏的
      // 那条始终可见；顶置/竖屏该调用直接返回，行为不变。
      .onAreaChange((_old: Area, _next: Area): void => {
        this.pinSuggestScrollToBottom();
      })
    }
    .width('100%')
    .constraintSize({ maxHeight: this.suggestCardMaxHeightVp() })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .borderRadius(16)
    .backgroundColor($r('app.color.menu_glass'))
    // 阴影半径 24 → 12：每次重排都要重新模糊一遍，浮层上这块最费。
    .shadow({ radius: 12, color: $r('app.color.shadow'), offsetY: 6 })
    .clip(true)
  }

  @Builder
  private AddressSuggestRow(item: AutocompleteItem, index: number) {
    Column() {
      Row({ space: 12 }) {
        Image(this.suggestIcon(item.type))
          .width(20)
          .height(20)
          .fillColor($r('app.color.icon_secondary'))
        Column({ space: 1 }) {
          Text(item.title.length > 0 ? item.title : item.url)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (item.description.length > 0) {
            Text(item.description)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .height(item.description.length > 0 ? 54 : 46)
      .padding({ left: 16, right: 16 })
      .onClick((): void => {
        this.applyAddressSuggestion(item);
      })
      // 长按联想项 = 复制该条网址（写剪贴板无需权限）+ toast。补上
      // 用户要的「带出来的网址按压激活复制」；「粘贴」走输入框自身的长按
      // 系统菜单。手势与 onClick 并存：轻点跳转、长按复制，互不干扰。
      .gesture(LongPressGesture({ repeat: false, duration: 450 })
        .onAction((): void => {
          this.copySuggestText(item);
        }))

      if (index < this.suggestRows().length - 1) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 48 })
      }
    }
    .width('100%')
    // 新行淡入、旧行不播退场：候选分两三批到达，之前每批都是瞬间撑高，观感上
    // 一层一层地跳。退场设 0 是因为整份替换时多行同时淡出会闪。
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 130, curve: Curve.EaseOut }),
      TransitionEffect.OPACITY.animation({ duration: 0 })
    ))
  }

  // 简约 dock 材质板。无参 @Builder：宽度/底距每次现读 state，
  // 不随挂载时的初值定死。
  @Builder
  private DockPlate() {
    DockMaterialPlate({
      canGoBack: this.browserState.canGoBack,
      canGoForward: this.browserState.canGoForward,
      tabCount: this.badgeTabCount >= 0
        ? this.badgeTabCount
        : this.browserState.tabCount,
      barWidthVp: this.dockBarWidthVp(DOCK_SIDE_MARGIN_VP),
      barHeightVp: DOCK_BAR_HEIGHT_VP,
      sideMarginVp: DOCK_SIDE_MARGIN_VP,
      bottomMarginVp: resolveDockBottomMarginVp(this.bottomSafeVp),
      // 材质板是独立 struct，跨 struct 调方法会 10505001；颜色以字符串传入，
      // 空串表示回落系统 icon_primary。
      dockInkHex: this.bottomDockInkHex(),
      onDockSlot: (slot: string): void => {
        this.handleDockSlot(slot);
      }
    })
  }

  @Builder
  private BottomDock() {
    Stack() {
      if (this.dockMaterialActive) {
        // 同 Chrome 底置：横竖屏各一个分支，跨断点重建 HdsTabs
        // （见 DOCK_PLATE_WIDE_BREAKPOINT_VP）。
        if (this.dockPlateWide) {
          this.DockPlate()
        } else {
          this.DockPlate()
        }
      } else {
        // 保底路径（无材质设备）：同一胶囊几何，半透明纯色玻璃 + 按钮行。
        Column() {
          Row() {
            this.BottomDockContent()
          }
          .width('100%')
          .height(DOCK_BAR_HEIGHT_VP)
          .borderRadius(DOCK_BAR_RADIUS_VP)
          .backgroundColor($r('app.color.glass_tint'))
          .border({ width: 0.5, color: $r('app.color.divider') })
          .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 4 })
          // System point-light press effect (HDS hdsEffect, API 20+, every
          // device): a soft light spot under the finger that follows it
          // across the bar.
          .visualEffect(this.buildDockLightEffect())
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .padding({ top: 12, left: 16, right: 16, bottom: resolveDockBottomMarginVp(this.bottomSafeVp) })
      }
    }
    .width('100%')
    .height(BOTTOM_DOCK_EXTENT_VP + resolveDockBottomMarginVp(this.bottomSafeVp))
    // 同顶栏：行程要含 dock 的底距（原始安全区），否则 ratio→0 时 dock
    // 仍留一条缝。
    .translate({ y: (1 - this.dockRatio()) * (BOTTOM_DOCK_EXTENT_VP + resolveDockBottomMarginVp(this.bottomSafeVp)) })
  }

  // dock 一个按钮的语义动作——材质路径由 HdsTabs 的 onTabBarClick 分发到
  // 这里；保底路径的按钮仍直连各自的 onClick。禁用态在两边都做守卫。
  private handleDockSlot(slot: string): void {
    if (slot === '返回') {
      if (this.browserState.canGoBack) {
        this.issueCommand({ command: 'back' });
      }
    } else if (slot === '前进') {
      if (this.browserState.canGoForward) {
        this.issueCommand({ command: 'forward' });
      }
    } else if (slot === '主页') {
      this.pressHome();
    } else if (slot === '标签页') {
      this.requestTabThumbnails();
      this.menuVisible = true;
    } else if (slot === '菜单') {
      this.menuCardVisible = true;
    }
  }

  private buildDockLightEffect(): VisualEffect {
    return new hdsEffect.HdsEffectBuilder()
      .pointLight({
        sourceType: hdsEffect.PointLightSourceType.SOFT,
        illuminatedType: hdsEffect.PointLightIlluminatedType.CONTENT
      })
      .buildEffect();
  }

  @Builder
  private BottomDockContent() {
      this.DockSymbolButton($r('sys.symbol.chevron_backward'), '返回', this.browserState.canGoBack,
        (): void => {
          this.issueCommand({ command: 'back' });
        })
      this.DockSymbolButton($r('sys.symbol.chevron_forward'), '前进', this.browserState.canGoForward,
        (): void => {
          this.issueCommand({ command: 'forward' });
        })
      // 'home' is the engine's own command for chrome://newtab (also what the
      // keyboard's home key maps to), so the tab lands on the shell's home
      // surface without pushing a duplicate of the current URL.
      this.DockButton($r('app.media.aura_home'), '主页', true,
        (): void => {
          this.pressHome();
        })

      Button({ type: ButtonType.Normal, stateEffect: true }) {
        // 去字后只剩计数徽标。
        Text(this.tabBadgeText())
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.bottomDockIconColor())
          .textAlign(TextAlign.Center)
          .width(22)
          .height(20)
          .borderRadius(6)
          .border({ width: 1.8, color: this.bottomDockIconColor() })
      }
      .layoutWeight(1)
      .height(DOCK_BAR_HEIGHT_VP)
      .backgroundColor(Color.Transparent)
      .scale({ x: this.pressedDock === '标签页' ? 0.82 : 1, y: this.pressedDock === '标签页' ? 0.82 : 1 })
      .accessibilityText('标签页')
      .onTouch((event: TouchEvent): void => {
        this.handleDockTouch(event, '标签页');
      })
      .onClick((): void => {
        this.requestTabThumbnails();
        this.menuVisible = true;
      })

      this.DockButton($r('app.media.aura_more'), '菜单', true,
        (): void => {
          this.menuCardVisible = true;
        })
  }

  @Builder
  private DockButton(icon: Resource, label: string, usable: boolean, action: () => void) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Image(icon)
        .width(22)
        .height(22)
        .fillColor(this.bottomDockIconColor())
    }
    .layoutWeight(1)
    .height(DOCK_BAR_HEIGHT_VP)
    .backgroundColor(Color.Transparent)
    .opacity(usable ? 1 : 0.4)
    .enabled(usable)
    .scale({ x: this.pressedDock === label ? 0.82 : 1, y: this.pressedDock === label ? 0.82 : 1 })
    .accessibilityText(label)
    .onTouch((event: TouchEvent): void => {
      this.handleDockTouch(event, label);
    })
    .onClick(action)
  }

  // 与 DockButton 同构，但图标用系统符号（chevron 方向键），与面板/HDS 返回钮一致。
  @Builder
  private DockSymbolButton(symbol: Resource, label: string, usable: boolean, action: () => void) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      SymbolGlyph(symbol)
        .fontSize(22)
        .fontColor([ this.bottomDockIconColor() ])
    }
    .layoutWeight(1)
    .height(DOCK_BAR_HEIGHT_VP)
    .backgroundColor(Color.Transparent)
    .opacity(usable ? 1 : 0.4)
    .enabled(usable)
    .scale({ x: this.pressedDock === label ? 0.82 : 1, y: this.pressedDock === label ? 0.82 : 1 })
    .accessibilityText(label)
    .onTouch((event: TouchEvent): void => {
      this.handleDockTouch(event, label);
    })
    .onClick(action)
  }

  // Press -> quick shrink; release -> under-damped spring back, the
  // "jelly" gravity-motion feel. Hand-rolled on purpose: the system
  // interactive material never applies to free-floating bars.
  private handleDockTouch(event: TouchEvent, label: string): void {
    if (event.type === TouchType.Down) {
      animateTo({ duration: 90, curve: Curve.FastOutSlowIn }, (): void => {
        this.pressedDock = label;
      });
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      animateTo({ curve: curves.springMotion(0.3, 0.7) }, (): void => {
        this.pressedDock = '';
      });
    }
  }

  // 顶栏圆钮的按压弹性：按下快收、松手用欠阻尼弹簧回弹（就是 dock 那套「果冻」
  // 的手感）。之所以手写：顶栏在页面内容区，systemMaterial 的 interactive
  // 形变在这里不生效（HarmonyOS 7 生效范围，见 GlassMaterial.ets）。
  private handleRoundTouch(event: TouchEvent, id: string): void {
    if (event.type === TouchType.Down) {
      animateTo({ duration: 90, curve: Curve.FastOutSlowIn }, (): void => {
        this.pressedRound = id;
      });
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      animateTo({ curve: curves.springMotion(0.3, 0.7) }, (): void => {
        this.pressedRound = '';
      });
    }
  }

  private roundScale(id: string): ScaleOptions {
    const s: number = this.pressedRound === id ? 0.86 : 1;
    return { x: s, y: s };
  }

  @Builder
  private MenuSheet() {
    Column() {
      this.TabsView()
    }
    .width('100%')
    .height('100%')
    // Transparent on purpose: with the app-level UIMaterial switch enabled
    // (module.json5, target API 26+), bindSheet draws its own ULTRA_THICK
    // system material behind this content -- a solid fill here would hide
    // it. See UI-DESIGN-SPEC.md section 8.5.
    .backgroundColor(Color.Transparent)
  }

  @Builder
  private TabsView() {
    Column() {
      Row({ space: 2 }) {
        Text(`${this.browserState.tabCount} 个标签`)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        // 排布切换：网格 / 列表（preferences 持久化，切完按新尺寸重取缩略图）。
        Button({ type: ButtonType.Circle, stateEffect: false }) {
          Image(this.tabLayout === 'list' ?
            $r('app.media.aura_view_grid') : $r('app.media.aura_view_list'))
            .width(20)
            .height(20)
            .fillColor($r('app.color.icon_primary'))
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.tabLayout === 'list' ? '换成网格' : '换成列表')
        .onClick((): void => {
          this.toggleTabLayout();
        })
        // 全部删除：留一个新的标签页（见 confirmCloseAllTabs）。
        Button({ type: ButtonType.Circle, stateEffect: false }) {
          Image($r('app.media.aura_trash'))
            .width(20)
            .height(20)
            .fillColor($r('app.color.icon_primary'))
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .accessibilityText('关闭全部标签页')
        .onClick((): void => {
          this.confirmCloseAllTabs();
        })
      }
      .width('100%')
      .height(52)

      if (this.tabLayout === 'list') {
        this.TabList()
      } else {
        this.TabGrid()
      }


      Row({ space: 10 }) {
        Button('新建标签页')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_accent'))
          .backgroundColor($r('app.color.accent_primary'))
          .borderRadius(22)
          .onClick(() => {
            this.closeMenuSheet();
            this.issueCommand({ command: 'newTab' });
          })
        Button('完成')
          .height(44)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.surface_secondary'))
          .borderRadius(22)
          .padding({ left: 24, right: 24 })
          .onClick(() => {
            this.closeMenuSheet();
          })
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text('最近关闭的标签页')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        Text('›')
          .fontSize(16)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .height(40)
      .onClick(() => {
        this.openRecentPanel();
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 16 })
    // Transparent: the bindSheet's system material (ULTRA_THICK under the
    // app-level ENABLE switch) must show through -- a solid fill here
    // covered it entirely. See UI-DESIGN-SPEC.md section 8.3.
    .backgroundColor(Color.Transparent)
  }

  // 标签的稳定标识。引擎 JSON 里的 id 未必是字符串，一律 String() 归一化；
  // index 会随邻居关掉或会话恢复追加而漂移，不能拿来做组件 key 或删除依据。
  private stableTabId(tab: BrowserTabState): string {
    const raw: string | undefined = tab.id;
    return raw === undefined ? '' : String(raw);
  }

  private tabKey(tab: BrowserTabState): string {
    const id: string = this.stableTabId(tab);
    return id.length > 0 ? id : `idx-${tab.index}`;
  }

  private closeTabOf(tab: BrowserTabState): void {
    const id: string = this.stableTabId(tab);
    if (id.length > 0) {
      this.issueCommand({ command: 'closeTabById', id: id });
      return;
    }
    this.issueCommand({ command: 'closeTab', index: tab.index });
  }

  // 网格排布：两列卡片，缩略图按卡片形状取（见 measureTabGrid）。
  @Builder
  private TabGrid() {
    Grid() {
      ForEach(this.browserState.tabs, (tab: BrowserTabState) => {
        GridItem() {
          Column() {
            Row() {
              Text(tab.title && tab.title.length > 0 ? tab.title : '新标签页')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontSize(13)
                .fontWeight(tab.active ? FontWeight.Medium : FontWeight.Regular)
                .fontColor(tab.active ?
                  $r('app.color.accent_primary') : $r('app.color.text_primary'))
                .layoutWeight(1)
              Button({ type: ButtonType.Circle }) {
                Image($r('app.media.chromium_close'))
                  .width(16)
                  .height(16)
                  .fillColor($r('app.color.icon_secondary'))
              }
              .width(30)
              .height(30)
              .backgroundColor(Color.Transparent)
              .accessibilityText('关闭标签页')
              .onClick((): void => {
                this.closeTabOf(tab);
              })
            }
            .width('100%')
            .height(36)
            .padding({ left: 10, right: 4 })

            Stack() {
              if (this.thumbnailFor(tab).length > 0) {
                Image(this.thumbnailFor(tab))
                  // 以前没有尺寸，Image 按图片固有像素大小画（在
                  // Stack 里既不对齐也可能画成 0），显式铺满卡片 + Cover。
                  .width('100%')
                  .height('100%')
                  .objectFit(ImageFit.Cover)
                  // 已休眠的标签留着上一次的缩略图，稍微压暗表示页面已不在内存里。
                  .opacity(tab.discarded === true ? 0.8 : 1)
              } else if (this.isNewTabUrl(tab.url ?? '')) {
                // 主页标签画自绘占位，不用引擎那张原生 NTP 磁贴截图。
                this.HomeTabPlaceholder()
              } else {
                // 没抓到快照（后台标签被回收等）：别把整条 URL 糊上来，
                // 用页面标题占位更可读。
                Text(tab.title.length > 0 ? tab.title : this.shortUrl(tab.url))
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .textAlign(TextAlign.Center)
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .padding(10)
              }
              // 引擎为省内存丢弃了这个标签（或从上次会话恢复后还没打开过）：
              // 标题、图标、前进后退记录都还在，点开时自动重新加载。契约
              // 要求显示为加载中而不是空白，所以盖一层"已休眠"。
              if (tab.discarded === true) {
                // 只轻轻压一层：太重会看不出后面是哪个站点。
                Column()
                  .width('100%')
                  .height('100%')
                  .backgroundColor($r('app.color.surface_primary'))
                  .opacity(0.35)
                // 文案压在自己的小底板上，不跟着遮罩一起变淡。
                Column({ space: 2 }) {
                  Text('已休眠')
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Text('点击重新加载')
                    .fontSize(10)
                    .fontColor($r('app.color.text_secondary'))
                }
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor($r('app.color.surface_primary'))
                .borderRadius(12)
                .opacity(0.92)
              }
            }
            .width('100%')
            .layoutWeight(1)
            .backgroundColor($r('app.color.surface_secondary'))
          }
          .width('100%')
          .height(208)
          .clip(true)
          .borderRadius(14)
          .border({
            width: tab.active ? 2 : 0.5,
            color: tab.active ? $r('app.color.accent_primary') : $r('app.color.divider')
          })
          .backgroundColor($r('app.color.surface_primary'))
          .onClick(() => {
            // Switch first, then dismiss: the reader expects to land on
            // the page they tapped, with the sheet gone. 引擎优先按稳定 id
            // 找标签，index 只作老引擎的兜底。
            this.issueCommand({
              command: 'activateTab',
              id: this.stableTabId(tab),
              index: tab.index
            });
            this.closeMenuSheet();
          })
        }
      }, (tab: BrowserTabState): string => this.tabKey(tab))
    }
    .columnsTemplate('1fr 1fr')
    .columnsGap(10)
    .rowsGap(10)
    .width('100%')
    .layoutWeight(1)
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      this.measureTabGrid(newArea);
    })
  }

  // 列表排布：一行一个标签 —— 左 64×46 缩略图、中间标题 + 网址、右边关闭钮。
  // 缩略图请求尺寸与行内图一致（见 toggleTabLayout）。
  @Builder
  private TabList() {
    Scroll() {
      Column({ space: 8 }) {
        ForEach(this.browserState.tabs, (tab: BrowserTabState) => {
          this.TabListRow(tab)
        }, (tab: BrowserTabState): string => this.tabKey(tab))
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    // 与面板列表同一条手感：列表回弹显式打开（见 §4 面板动效三件套）。
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  @Builder
  private TabListRow(tab: BrowserTabState) {
    Row({ space: 10 }) {
      Stack() {
        if (this.thumbnailFor(tab).length > 0) {
          Image(this.thumbnailFor(tab))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            // 已休眠的标签留着上一次的缩略图，稍微压暗表示页面已不在内存里。
            .opacity(tab.discarded === true ? 0.8 : 1)
            .draggable(false)
        } else if (this.isNewTabUrl(tab.url ?? '')) {
          this.HomeTabPlaceholderCompact()
        } else {
          Text(tab.title.length > 0 ? tab.title.substring(0, 1).toUpperCase() : '?')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .width(TAB_LIST_THUMB_WIDTH_VP)
      .height(TAB_LIST_THUMB_HEIGHT_VP)
      .borderRadius(8)
      .backgroundColor($r('app.color.surface_secondary'))
      .clip(true)

      Column({ space: 2 }) {
        Text(tab.title && tab.title.length > 0 ? tab.title : '新标签页')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize(14)
          .fontWeight(tab.active ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(tab.active ?
            $r('app.color.accent_primary') : $r('app.color.text_primary'))
          .width('100%')
          .textAlign(TextAlign.Start)
        // 引擎丢了这个标签（省内存 / 恢复后还没打开过）：点开时自动重新加载。
        Text(tab.discarded === true ? '已休眠 · 点击重新加载' : this.shortUrl(tab.url))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button({ type: ButtonType.Circle, stateEffect: false }) {
        Image($r('app.media.chromium_close'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.icon_secondary'))
      }
      .width(30)
      .height(30)
      .backgroundColor(Color.Transparent)
      .accessibilityText('关闭标签页')
      .onClick((): void => {
        this.closeTabOf(tab);
      })
    }
    .width('100%')
    .height(64)
    .padding({ left: 10, right: 4 })
    .borderRadius(12)
    .border({
      width: tab.active ? 2 : 0.5,
      color: tab.active ? $r('app.color.accent_primary') : $r('app.color.divider')
    })
    .backgroundColor($r('app.color.surface_primary'))
    .onClick((): void => {
      this.issueCommand({
        command: 'activateTab',
        id: this.stableTabId(tab),
        index: tab.index
      });
      this.closeMenuSheet();
    })
  }

  // 网格 / 列表切换：写完偏好就按新的图大小重取缩略图（同一份回包按 id 存，
  // 换了尺寸必须重新问一次，否则列表里是网格尺寸的图、反之亦然）。
  private toggleTabLayout(): void {
    const next: string = this.tabLayout === 'list' ? 'grid' : 'list';
    this.tabLayout = next;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context) {
      ShellUiPrefs.saveTabLayout(context, next);
    }
    if (next === 'list') {
      this.tabThumbWidthVp = TAB_LIST_THUMB_WIDTH_VP;
      this.tabThumbAspect = TAB_LIST_THUMB_WIDTH_VP / TAB_LIST_THUMB_HEIGHT_VP;
    } else {
      // 网格：把 aspect 归零，等 onAreaChange 量出卡片宽度再定（measureTabGrid）。
      this.tabThumbAspect = 0;
      this.tabThumbWidthVp = 160;
    }
    this.requestTabThumbnails();
  }

  // 全部删除：留一个新的标签页。关掉最后一个标签页会把窗口（连应用）一起
  // 关掉，所以先留索引 0、把它送回主页，再从后往前关其余的 —— 逆序关，索引
  // 不会因为前面的删除而错位。
  private confirmCloseAllTabs(): void {
    const count: number = this.browserState.tabCount;
    if (count <= 0) {
      return;
    }
    this.getUIContext().getPromptAction().showDialog({
      title: '关闭全部标签页',
      message: `将关闭 ${count} 个标签页，并留下一个新的标签页。`,
      buttons: [
        { text: '取消', color: '#5F6368' },
        { text: '关闭', color: '#E24B4A' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index !== 1) {
        return;
      }
      this.closeAllTabs(count);
    }).catch((error: Error): void => {
      console.error('Failed to show close-all dialog:', error);
    });
  }

  private closeAllTabs(count: number): void {
    // 关完所有标签页会落回主页，进度条一并收掉，别让它挂在新出现的白底主页上。
    this.hideLoadBarNow();
    this.issueCommand({ command: 'activateTab', index: 0 });
    this.issueCommand({ command: 'home' });
    for (let index: number = count - 1; index >= 1; index -= 1) {
      this.issueCommand({ command: 'closeTab', index: index });
    }
    this.closeMenuSheet();
  }

  @Builder
  private HomeUrlFormOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.modal_scrim'))
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0).animation({ duration: 260, curve: Curve.Friction }),
          TransitionEffect.opacity(0).animation({ duration: 380, curve: Curve.Friction })
        ))
        .onClick((): void => {
          this.closeHomeUrlForm();
        })

      Row() {
        Column({ space: 14 }) {
          Text('自定义网址')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text('可以添加多组网址；打勾的那一条就是主页，按主页键和冷启动都打开它。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          // 新增一行：输入 + 添加。回车或点「添加」都行，反复添加即可攒成列表。
          Row({ space: 10 }) {
            TextInput({ text: this.homeUrlDraft, placeholder: 'https://…' })
              .layoutWeight(1)
              .height(46)
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.surface_secondary'))
              .borderRadius(12)
              .onChange((value: string): void => {
                this.homeUrlDraft = value;
              })
              .onSubmit((): void => {
                this.addHomeUrlEntry();
              })
            Row() {
              Text('添加')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.on_accent'))
                .maxLines(1)
            }
            .justifyContent(FlexAlign.Center)
            .width(74)
            .height(46)
            .borderRadius(12)
            .backgroundColor($r('app.color.accent_primary'))
            .onClick((): void => {
              this.addHomeUrlEntry();
            })
          }
          .width('100%')

          if (this.homeUrlList.length === 0) {
            Text('还没有网址。添加后点一下就能把它设为主页。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ top: 6, bottom: 6 })
          } else {
            Scroll() {
              Column({ space: 8 }) {
                ForEach(this.homeUrlList, (item: string): void => {
                  this.HomeUrlEntryRow(item, item === this.homeUrlActive);
                }, (item: string): string => {
                  return `${item}|${item === this.homeUrlActive ? '1' : '0'}`;
                })
              }
              .width('100%')
            }
            .width('100%')
            .constraintSize({ maxHeight: 234 })
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          }

          Row() {
            Text('完成')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height(44)
          .borderRadius(12)
          .backgroundColor($r('app.color.surface_secondary'))
          .onClick((): void => {
            this.closeHomeUrlForm();
          })
        }
        .width('100%')
        .padding(20)
        .borderRadius(22)
        .backgroundColor($r('app.color.menu_glass'))
        .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0)
            .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }))
            .animation({ curve: curves.springMotion(0.3, 0.75) }),
          TransitionEffect.opacity(0)
            .combine(TransitionEffect.scale({ x: 0.95, y: 0.95 }))
            .animation({ duration: 320, curve: Curve.FastOutSlowIn })
        ))
      }
      .padding({ left: 24, right: 24 })
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  // 一行网址：左半区点按 = 设为当前主页（打勾），右侧垃圾桶 = 删除。
  // 两个可点区是兄弟节点，不做嵌套 onClick —— 嵌套时内层点击会不会被外层
  // 一起收走有版本差异，分开摆最稳。
  @Builder
  private HomeUrlEntryRow(url: string, active: boolean) {
    Row({ space: 10 }) {
      Row({ space: 10 }) {
        if (active) {
          Image($r('app.media.aura_check'))
            .width(18)
            .height(18)
            .flexShrink(0)
            .fillColor($r('app.color.accent_primary'))
        } else {
          Column()
            .width(18)
            .height(18)
            .flexShrink(0)
            .borderRadius(9)
            .border({ width: 1.5, color: $r('app.color.divider') })
        }
        Text(url)
          .fontSize(14)
          .fontColor(active ? $r('app.color.accent_primary') : $r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .layoutWeight(1)
      .onClick((): void => {
        this.selectHomeUrlEntry(url);
      })

      Row() {
        Image($r('app.media.aura_trash'))
          .width(18)
          .height(18)
          .fillColor($r('app.color.text_secondary'))
      }
      .width(32)
      .height(32)
      .flexShrink(0)
      .justifyContent(FlexAlign.Center)
      .onClick((): void => {
        this.removeHomeUrlEntry(url);
      })
    }
    .width('100%')
    .padding({ left: 12, right: 6, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor($r('app.color.surface_secondary'))
  }

  // 「自定义网址」入口菜单——长按 dock 主页图标弹出的小卡片。
  // 自绘（menu_glass，与 ⋮ 卡同一家族：系统 bindMenu 会拖死整屏点击，本应用
  // 封死）；点卡片外任意处收起。模态在场时整屏归 overlay（见
  // buildChromeTouchRegions 的模态分支），点外不误触网页。
  @Builder
  private HomeTileMenu() {
    Stack({ alignContent: (this.homeStyle === 'chrome' && this.chromeDockAtTop())
      ? Alignment.TopStart : Alignment.BottomStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          this.homeTileMenuVisible = false;
        })

      Column() {
        this.MenuItem($r('app.media.aura_globe'), '自定义网址', '', (): void => {
          this.requestAddHomeTile();
        })
      }
      .width(MENU_CARD_WIDTH_VP)
      .borderRadius(22)
      .backgroundColor($r('app.color.menu_glass'))
      .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
      // 贴条带下沿（顶置）/ 上沿（底置），左对齐——菜单锚在主页图标附近。
      .margin(this.homeStyle === 'chrome' && this.chromeDockAtTop()
        ? { left: 16, top: CHROME_DOCK_EXTENT_VP + this.topSafeVp + 8 }
        : { left: 16, bottom: 82 + this.bottomSafeVp })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.opacity(0)
          .combine(TransitionEffect.translate({ y: 16 }))
          .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 })),
        TransitionEffect.opacity(0)
          .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
      ).animation({ curve: curves.springMotion(0.3, 0.72) }))
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private MenuBottomSheet() {
    Column({ space: 0 }) {
      Row() {
        Column()
          .width(36)
          .height(4)
          .borderRadius(2)
          .backgroundColor($r('app.color.icon_secondary'))
      }
      .width('100%')
      .height(28)
      .justifyContent(FlexAlign.Center)
      .hitTestBehavior(HitTestMode.Default)
      .onClick((): void => this.closeMenuCard())

      if (!this.isHomeSurface()) {
        this.MenuHeader()
        this.MenuSeparator()
      }

      // 功能网格 5×2（通栏 ≈66vp/格，图标 22 + 12sp 文字从容放下）。
      Column({ space: 8 }) {
        Row({ space: 6 }) {
          this.PanelEntryButton('书签', $r('app.media.chromium_bookmark'), (): void => {
            this.openBookmarksPanel();
          })
          this.PanelEntryButton('历史', $r('app.media.chromium_history'), (): void => {
            this.openHistoryPanel();
          })
          this.PanelEntryButton('下载', $r('app.media.chromium_download'), (): void => {
            this.openDownloadsPanel();
          })
          this.PanelEntryButton('扩展', $r('app.media.aura_extensions'), (): void => {
            this.openExtensionPanelPage();
          })
          this.PanelEntryButton('设置', $r('app.media.chromium_settings'), (): void => {
            this.openSettingsPanelPage();
          })
        }
        .width('100%')

        if (!this.isHomeSurface()) {
          Row({ space: 6 }) {
            this.PanelEntryButton('主页', $r('app.media.aura_home'), (): void => {
              this.closeMenuCard();
              this.pressHome();
            })
            this.PanelEntryButton('分享', $r('app.media.aura_share'), (): void => {
              this.closeMenuCard();
              this.shareCurrentPage();
            })
            this.PanelEntryButton('查找', $r('app.media.chromium_search'), (): void => {
              this.closeMenuCard();
              this.findVisible = true;
            })
            this.PanelEntryButton('打印', $r('app.media.chromium_print'), (): void => {
              this.closeMenuCard();
              this.issueCommand({ command: 'print' });
            })
            // 文案随当前页反转：移动版页显示「桌面版」（点了切过去），桌面版页
            // 显示「移动版」。引擎已在 state.requestDesktopSite 里报了这个状态
            // （IsRequestingDesktopSite → NavigationEntry::GetIsOverridingUserAgent）。
            this.PanelEntryButton(
              this.browserState.requestDesktopSite === true ? '移动版' : '桌面版',
              $r('app.media.aura_desktop'), (): void => {
                this.closeMenuCard();
                this.toggleDesktopSite();
              })
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 6, bottom: 10 })

      this.MenuSeparator()

      // 按页状态列表：加入书签 / 阅读模式（引擎可用时）/ 无痕开关。
      if (!this.isHomeSurface()) {
        // 引擎的状态里没有"当前页是否已收藏"这项（native 有 bookmarked，
        // 但 HAR 的 BrowserStateSnapshot 还没声明），所以这一项只做加入。
        this.MenuItem($r('app.media.chromium_bookmark'), '加入书签', '',
          (): void => {
            this.closeMenuCard();
            this.toggleBookmark();
          })
        if (this.browserState.readerModeAvailable === true) {
          this.MenuItem($r('app.media.aura_reader'), '阅读模式',
            this.browserState.inReaderMode === true ? '开' : '', (): void => {
              this.closeMenuCard();
              this.issueCommand({ command: 'toggleReaderMode' });
            })
        }
        // 资源嗅探：列出当前页面被引擎识别出的媒体/图片资源并支持下载。
        this.MenuItem($r('app.media.aura_sniff'), '资源嗅探', '', (): void => {
          this.closeMenuCard();
          this.openResourceSniffPanel();
        })
      }
      if (this.incognito) {
        this.MenuItem($r('app.media.aura_incognito'), '退出无痕', '', (): void => {
          this.closeMenuCard();
          this.leaveIncognito();
        })
      } else {
        this.MenuItem($r('app.media.aura_incognito'), '新建无痕标签页', '', (): void => {
          this.closeMenuCard();
          this.enterIncognito();
        })
      }
    }
    .width('100%')
    .borderRadius({ topLeft: 22, topRight: 22, bottomLeft: 0, bottomRight: 0 })
    .backgroundColor($r('app.color.menu_glass'))
    // 底部安全区：贴屏幕底沿（含底部横条），盖住 chrome-bottom 悬浮 dock。
    .padding({ bottom: this.bottomSafeVp })
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.translate({ y: 420 }).animation({ duration: 300, curve: Curve.FastOutSlowIn }),
      TransitionEffect.opacity(1)
    ))
  }

  // 第一行：连接状态。锁形图标 + 域名 + " · 连接安全/不安全"，行尾一枚刷新
  // 钮（地址栏没空位了，刷新收进菜单首行：紧挨"当前网址"语义最顺，也不打乱
  // 下方菜单项分组与底部五个入口）。
  @Builder
  private MenuHeader() {
    Row({ space: 10 }) {
      Image($r('app.media.aura_lock'))
        .width(18)
        .height(18)
        .fillColor(this.isConnectionSecure() ?
          $r('app.color.text_primary') : $r('app.color.icon_secondary'))
        .hitTestBehavior(HitTestMode.Default)
        .accessibilityText('网站设置')
        .onClick((): void => {
          this.closeMenuCard();
          this.openSiteSettings();
        })
      Text(this.isConnectionSecure() ?
        `${this.menuDomainText()} · 连接安全` : `${this.menuDomainText()} · 不安全`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Button({ type: ButtonType.Circle, stateEffect: false }) {
        Image(this.browserState.loading ?
          $r('app.media.aura_close') : $r('app.media.aura_reload'))
          .width(18)
          .height(18)
          .fillColor($r('app.color.text_secondary'))
      }
      .width(30)
      .height(30)
      .backgroundColor(Color.Transparent)
      .accessibilityText(this.browserState.loading ? '停止' : '刷新')
      .hitTestBehavior(HitTestMode.Default)
      .onClick((): void => {
        this.closeMenuCard();
        this.issueCommand({ command: this.browserState.loading ? 'stop' : 'reload' });
      })
    }
    .width('100%')
    .height(44)
    .padding({ left: 18, right: 10 })
  }

  @Builder
  private MenuSeparator() {
    Divider()
      .color($r('app.color.divider'))
      .margin({ left: 18, right: 0 })
  }

  private isConnectionSecure(): boolean {
    return this.browserState.url.startsWith('https://');
  }

  private isHomeSurface(): boolean {
    // homeIntent 兜住 url 未提交的窗口；homeExitHold 让顶部跟主页淡出同拍切换。
    return this.homeIntent || this.homeExitHold || this.engineHomeCover ||
      this.isNewTabUrl(this.browserState.url);
  }

  // 主页键统一入口。**已经在主页时**先让主页自己复位（清空搜索框 + 收起联想 +
  // 收掉键盘）：引擎侧 'home' 命令对已经停在 newtab 的标签页是空操作，所以以前
  // 在主页输入内容、联想弹着的时候按主页键「没有任何反应」。
  private pressHome(): void {
    if (this.isHomeSurface()) {
      const seq: number = Number(AppStorage.get('auraHomeReset') ?? 0);
      AppStorage.setOrCreate('auraHomeReset', seq + 1);
      // 已停在 newtab 时不再发 home：引擎会重载 NTP 并把 url 短暂报成上一页。
      if (this.isNewTabUrl(this.browserState.url)) {
        return;
      }
    } else {
      // 按用户意图立刻收进度条，不等 url 提交（否则会走满格停留淡出，压在主页上）。
      this.hideLoadBarNow();
    }
    this.issueCommand({ command: 'home' });
  }

  // 立刻卸载进度条：清掉收尾计时器，避免它稍后误收下一次加载；并复位宽度。
  private hideLoadBarNow(): void {
    if (this.loadBarFadeTimer !== 0) {
      clearTimeout(this.loadBarFadeTimer);
      this.loadBarFadeTimer = 0;
    }
    if (!this.loadBarShown) {
      return;
    }
    this.loadBarShown = false;
    this.loadBarWidth = this.loadBarMin;
  }

  private menuDomainText(): string {
    if (this.isHomeSurface()) {
      return '新标签页';
    }
    return this.displayDomain();
  }

  // 一项菜单：图标 + 文字 +（可选的）右侧"开"。整行都可点。
  @Builder
  private MenuItem(icon: Resource, label: string, trailing: string, action: () => void) {
    Row({ space: 14 }) {
      Image(icon)
        .width(21)
        .height(21)
        .fillColor($r('app.color.icon_primary'))
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
      Blank()
      if (trailing.length > 0) {
        Text(trailing)
          .fontSize(13)
          .fontColor($r('app.color.accent_primary'))
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 18, right: 16 })
    .onClick(action)
  }

  // 进无痕：手机上没有第二个渲染进程可用，先把标签存下来再用另一个 profile
  // 重启应用（引擎据此换一整套用户数据目录）。存不下就不进，免得回来时标签
  // 全丢——这是有意的取舍。
  private async enterIncognito(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    const saved: SavedTab[] = [];
    for (const tab of this.browserState.tabs) {
      if (tab.url && tab.url.length > 0 && !this.isNewTabUrl(tab.url)) {
        saved.push({ url: tab.url, title: tab.title ?? '' });
      }
    }
    const ok = await IncognitoSwitch.saveTabs(context, saved);
    if (!ok) {
      this.getUIContext().getPromptAction().showToast({ message: '保存标签失败，已取消进入无痕', duration: 2500 });
      return;
    }
    IncognitoSwitch.restart(context, true, '');
  }

  // 退出无痕：重启回普通 profile；无痕那套目录由 EntryAbility 在普通启动时
  // 整个删掉（IncognitoSwitch.sweepIncognitoProfile）。
  private leaveIncognito(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    IncognitoSwitch.restart(context, false, '');
  }

  // 桌面版网站是每个标签自己的状态，读 requestDesktopSite 再取反。
  private toggleDesktopSite(): void {
    if (this.isHomeSurface()) {
      return;
    }
    const enabled = !(this.browserState.requestDesktopSite === true);
    this.persistDesktopSite(enabled);
    this.issueCommand({ command: 'setRequestDesktopSite', enabled: enabled });
    this.getUIContext().getPromptAction().showToast({
      message: enabled ? '已请求桌面版网站' : '已回到移动版网站',
      duration: 2000
    });
  }

  // 将当前标签的 host 加入或移出桌面版网站名单，并落盘 + 同步 AppStorage
  // （WebWindow 据此在下次导航前自动下发桌面 UA）。
  private persistDesktopSite(enabled: boolean): void {
    const url: string = this.browserState?.url ?? '';
    const host: string = this.hostOf(url);
    if (!host) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    const raw = String(AppStorage.get('auraDesktopSites') ?? '');
    const list: string[] = ShellUiPrefs.parseUrlList(raw);
    const idx: number = list.indexOf(host);
    if (enabled) {
      if (idx < 0) {
        list.push(host);
      }
    } else {
      if (idx >= 0) {
        list.splice(idx, 1);
      }
    }
    const joined: string = ShellUiPrefs.joinUrlList(list);
    AppStorage.setOrCreate('auraDesktopSites', joined);
    if (context) {
      ShellUiPrefs.saveDesktopSites(context, list);
    }
    // 全局「默认使用桌面版网站」开着时，从桌面名单里移除这个 host 毫无作用
    // （它本来就不在名单里，引擎按 everywhere 对所有 http(s) 页返回桌面）。
    // 真正让单页回到移动版的是这份例外名单：引擎 IsDesktopSiteHost() 里优先判定，
    // 外壳 WebWindow 导航前也按它拦住桌面 UA 注入。
    // 派生键：平板/桌面家族形态默认桌面版时也算「全局开着」，单站「回到移动版」
    // 才写进例外名单（AuraShell.refreshUaDefaultEffective 发布）。
    const allSites: boolean = String(AppStorage.get('auraUaDefaultEffective') ??
      AppStorage.get('auraUaDefault') ?? 'mobile') === 'desktop';
    const mobileList: string[] = ShellUiPrefs.parseUrlList(
      String(AppStorage.get('auraMobileSites') ?? ''));
    const mobileIdx: number = mobileList.indexOf(host);
    if (!enabled && allSites) {
      if (mobileIdx < 0) {
        mobileList.push(host);
      }
    } else if (mobileIdx >= 0) {
      mobileList.splice(mobileIdx, 1);
    }
    const mobileJoined: string = ShellUiPrefs.joinUrlList(mobileList);
    AppStorage.setOrCreate('auraMobileSites', mobileJoined);
    if (context) {
      ShellUiPrefs.saveMobileSites(context, mobileList);
    }
    // 同步给引擎：引擎按这份名单在每次导航时决定 UA，脚本后台新开的标签也靠它。
    this.issueCommand({
      command: 'setDesktopSites',
      sites: joined,
      allSites: allSites,
      mobileSites: mobileJoined
    });
  }

  // 无依赖地从 URL 取出 host（去协议/路径/端口/userinfo），http(s) 之外的非常规
  // scheme 返回空串，避免误匹配桌面名单。
  private hostOf(url: string): string {
    if (!url || url.length === 0) {
      return '';
    }
    let rest: string = url;
    const protoIdx: number = rest.indexOf('://');
    if (protoIdx >= 0) {
      rest = rest.substring(protoIdx + 3);
    } else {
      const colon: number = rest.indexOf(':');
      if (colon >= 0) {
        rest = rest.substring(colon + 1);
      }
    }
    let end: number = rest.length;
    const slash: number = rest.indexOf('/');
    const q: number = rest.indexOf('?');
    const hPos: number = rest.indexOf('#');
    if (slash >= 0 && slash < end) {
      end = slash;
    }
    if (q >= 0 && q < end) {
      end = q;
    }
    if (hPos >= 0 && hPos < end) {
      end = hPos;
    }
    let host: string = rest.substring(0, end);
    const port: number = host.lastIndexOf(':');
    if (port >= 0) {
      host = host.substring(0, port);
    }
    const at: number = host.lastIndexOf('@');
    if (at >= 0) {
      host = host.substring(at + 1);
    }
    return host;
  }

  // 查找栏顶边距：贴在当前顶部 chrome 之下（chrome 顶置 dock / 简约顶栏），
  // 主页界面与 chrome 底置时顶部无 chrome，只留状态栏。查找栏是瞬态浮层，
  // 按 chrome 全高锚定（滚动收起时上方留空页，可接受，避免浮层跟着晃）。
  private findBarTopMarginVp(): number {
    const topChromeH: number = this.homeStyle === 'chrome'
      ? (this.chromeDockAtTop() ? CHROME_DOCK_EXTENT_VP : 0)
      : (this.isHomeSurface() ? 0 : TOP_BAR_EXTENT_VP);
    return this.topSafeVp + topChromeH + 8;
  }

  @Builder
  private DownloadSnackLayer() {
    Column() {
      Row({ space: 10 }) {
        // 状态图标：开始=转圈；完成=对勾；失败/危险=叉。
        if (this.downloadSnack.kind === DownloadSnackKind.START) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color($r('app.color.accent_primary'))
        } else {
          Image(this.downloadSnack.kind === DownloadSnackKind.DONE ?
            $r('app.media.aura_check') : $r('app.media.aura_close'))
            .width(18)
            .height(18)
            .fillColor(this.downloadSnack.kind === DownloadSnackKind.DONE ?
              $r('app.color.accent_primary') : $r('app.color.icon_secondary'))
        }

        // 前缀（固定不缩）+ 文件名（layoutWeight 1，一行省略）。
        Text(this.downloadSnack.kind === DownloadSnackKind.START ? '开始下载 ' :
          (this.downloadSnack.kind === DownloadSnackKind.FAILED ? '下载失败 ' :
            (this.downloadSnack.kind === DownloadSnackKind.DANGEROUS ? '下载需要确认 ' : '下载完成 ')))
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
        Text(this.downloadSnack.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 动作钮：完成且 .crx=安装；完成且普通文件=打开；失败=重试；
        // 危险文件只提示不动作（保留/丢弃去下载页选）。
        if (this.downloadSnack.kind === DownloadSnackKind.DONE && this.downloadSnack.isCrx) {
          this.DownloadSnackAction($r('app.media.aura_extensions'), '安装',
            (): void => {
              this.installDownloadedSnackCrx();
            })
        } else if (this.downloadSnack.kind === DownloadSnackKind.DONE) {
          this.DownloadSnackAction($r('app.media.aura_download'), '打开',
            (): void => {
              this.openDownloadedSnackFile();
            })
        } else if (this.downloadSnack.kind === DownloadSnackKind.FAILED) {
          this.DownloadSnackAction($r('app.media.aura_reload'), '重试',
            (): void => {
              this.issueCommand({
                command: 'downloadAction',
                id: this.downloadSnack.id,
                action: 'retry'
              });
              this.dismissDownloadSnack();
            })
        }

        // ✕：只关通知条，不动下载本身。
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          Image($r('app.media.aura_close'))
            .width(16)
            .height(16)
            .fillColor($r('app.color.icon_secondary'))
        }
        .width(32)
        .height(32)
        .backgroundColor(Color.Transparent)
        .hitTestBehavior(HitTestMode.Default)
        .accessibilityText('关闭')
        .onClick((): void => {
          this.dismissDownloadSnack();
        })
      }
      .height(DOWNLOAD_SNACK_HEIGHT_VP)
      .padding({ left: 14, right: 6 })
      .backgroundColor($r('app.color.surface_floating'))
      .borderRadius(16)
      .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 4 })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .position({ x: 0, y: this.downloadSnackTopVp() })
    .hitTestBehavior(HitTestMode.Default)
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.translate({ y: 24 }).animation({ duration: 300, curve: Curve.FastOutSlowIn }),
      TransitionEffect.opacity(0).animation({ duration: 240, curve: Curve.Friction })
    ))
  }

  // 通知条里的紧凑动作钮（图标 + 文字，浅底胶囊）。
  @Builder
  private DownloadSnackAction(icon: Resource, label: string, action: () => void) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: 4 }) {
        Image(icon)
          .width(16)
          .height(16)
          .fillColor($r('app.color.accent_primary'))
        Text(label)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent_primary'))
      }
      .padding({ left: 8, right: 8 })
      .height(28)
      .backgroundColor($r('app.color.surface_secondary'))
      .borderRadius(14)
      .justifyContent(FlexAlign.Center)
    }
    .width(72)
    .height(32)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .hitTestBehavior(HitTestMode.Default)
    .onClick(action)
  }

  @Builder
  private FindBar() {
    Row({ space: 6 }) {
      Image($r('app.media.chromium_search'))
        .width(18)
        .height(18)
        .fillColor($r('app.color.icon_secondary'))
        .margin({ left: 6 })

      TextInput({ text: this.findQuery, placeholder: '在页面中查找' })
        .layoutWeight(1)
        .height(36)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .backgroundColor($r('app.color.surface_secondary'))
        .borderRadius(18)
        .enterKeyType(EnterKeyType.Done)
        .onChange((value: string) => {
          this.findQuery = value;
          if (value.trim().length > 0) {
            this.issueCommand({ command: 'findInPage', text: value });
          }
        })
        .onSubmit(() => {
          this.findNext(true);
        })

      Text(this.findMatches() > 0 ? `${this.findActiveMatch()}/${this.findMatches()}` : '')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))

      Button({ type: ButtonType.Circle }) {
        Text('↑')
          .fontSize(16)
          .fontColor($r('app.color.icon_primary'))
      }
      .width(34)
      .height(34)
      .backgroundColor(Color.Transparent)
      .accessibilityText('上一个')
      .onClick(() => {
        this.findNext(false);
      })

      Button({ type: ButtonType.Circle }) {
        Text('↓')
          .fontSize(16)
          .fontColor($r('app.color.icon_primary'))
      }
      .width(34)
      .height(34)
      .backgroundColor(Color.Transparent)
      .accessibilityText('下一个')
      .onClick(() => {
        this.findNext(true);
      })

      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.chromium_close'))
          .width(18)
          .height(18)
          .fillColor($r('app.color.icon_secondary'))
      }
      .width(34)
      .height(34)
      .backgroundColor(Color.Transparent)
      .accessibilityText('结束查找')
      .onClick(() => {
        this.closeFindBar();
      })
    }
    .width('100%')
    .height(48)
    // position 绝对定位（绕开根 Stack 默认 Center 对齐），贴 chrome 下沿；
    // 与 buildChromeTouchRegions 的 findVisible 窄带同一 y。
    .position({ x: 0, y: this.findBarTopMarginVp() })
    .padding({ left: 12, right: 8 })
    .borderRadius(12)
    .backgroundColor($r('app.color.surface_floating'))
    .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 4 })
    .hitTestBehavior(HitTestMode.Default)
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(0)
        .combine(TransitionEffect.translate({ y: -24 })),
      TransitionEffect.opacity(0).animation({ duration: 200, curve: Curve.Friction })
    ))
  }

  @Builder
  private CommandButton(label: string, icon: Resource, command: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        Image(icon)
          .width(22)
          .height(22)
          .fillColor($r('app.color.icon_primary'))
        Text(label)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .layoutWeight(1)
    .height(58)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface_secondary'))
    .onClick(() => this.issueCommand({ command }))
  }

  @Builder
  private PanelEntryButton(label: string, icon: Resource, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        Image(icon)
          .width(22)
          .height(22)
          .fillColor($r('app.color.icon_primary'))
        Text(label)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .layoutWeight(1)
    .height(58)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface_secondary'))
    .onClick(action)
  }

  @Builder
  private ShareButton() {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        Image($r('app.media.aura_share'))
          .width(22)
          .height(22)
          .fillColor($r('app.color.icon_primary'))
        Text('华为分享')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .layoutWeight(1)
    .height(58)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface_secondary'))
    .onClick(() => this.shareCurrentPage())
  }

  @Builder
  private CastButton() {
    AVCastPicker({
      normalColor: this.colorScheme === 'dark' ? '#F5F5F5' : '#202124',
      activeColor: this.colorScheme === 'dark' ? '#5B8CFF' : '#0A59F7',
      pickerStyle: AVCastPickerStyle.STYLE_PANEL,
      colorMode: AVCastPickerColorMode.AUTO,
      sessionType: 'video',
      customPicker: this.CastPickerContent
    })
      .layoutWeight(1)
      .height(58)
  }

  @Builder
  private CastPickerContent() {
    Column({ space: 4 }) {
      Image($r('app.media.aura_cast'))
        .width(22)
        .height(22)
        .fillColor($r('app.color.icon_primary'))
      Text('投放')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .height(58)
    .justifyContent(FlexAlign.Center)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface_secondary'))
  }

  private buildBubbleEffect(): VisualEffect {
    return new hdsEffect.HdsEffectBuilder()
      .pressShadow(hdsEffect.PressShadowType.BLEND_GRADIENT)
      .buildEffect();
  }

  private leftAction(): MobileEdgeAction {
    if (this.lastGripSide === GripSide.LEFT) {
      return this.primaryAction;
    }
    return this.secondaryAction();
  }

  private rightAction(): MobileEdgeAction {
    if (this.lastGripSide === GripSide.RIGHT) {
      return this.primaryAction;
    }
    return this.secondaryAction();
  }

  private secondaryAction(): MobileEdgeAction {
    return this.primaryAction === MobileEdgeAction.BACK ?
      MobileEdgeAction.MENU : MobileEdgeAction.BACK;
  }

  private handleEdgeAction(action: MobileEdgeAction): void {
    if (action === MobileEdgeAction.BACK) {
      this.issueCommand({ command: 'back' });
    } else {
      this.sheetPage = 'tabs';
      this.menuVisible = true;
    }
  }

  private closeMenuSheet(): void {
    this.menuVisible = false;
    this.sheetPage = 'tabs';
  }

  // 扫一扫: system scanner, result goes through the same address/search
  // rules as typed input (URL opens, text searches).
  private async startScan(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    const value = await ScanService.scanOnce(context);
    if (value.length > 0) {
      this.issueCommand({ command: 'navigate', url: normalizeAddress(value) });
    }
  }

  // 视口宽度（vp）兜底：页面切换帘幕的位移基准。
  private pageWidthVp(): number {
    return this.viewportWidthVp > 0 ? this.viewportWidthVp : 360;
  }

  private openExtensionPanelPage(): void {
    this.menuVisible = false;
    this.menuCardVisible = false;
    this.sheetPage = 'tabs';
    router.pushUrl({ url: 'pages/panels/ExtensionPanelPage' }).catch((error: Error): void => {
      console.error('openExtensionPanelPage pushUrl failed:', error);
    });
  }

  private openSettingsPanelPage(): void {
    this.menuVisible = false;
    this.menuCardVisible = false;
    this.sheetPage = 'tabs';
    router.pushUrl({ url: 'pages/panels/SettingsPanelPage' }).catch((error: Error): void => {
      console.error('openSettingsPanelPage pushUrl failed:', error);
    });
  }

  // A' 面板页化（试点）：历史改为独立路由页。先收起菜单，再 router.pushUrl
  // 压栈；返回由系统手势/返回键经 router 自动 pop（HistoryPanelPage 的 onBack/onClose 也指向 router.back）。
  private openHistoryPanel(): void {
    this.menuVisible = false;
    this.menuCardVisible = false;
    router.pushUrl({ url: 'pages/panels/HistoryPanelPage' }).catch((error: Error): void => {
      console.error('openHistoryPanel pushUrl failed:', error);
    });
  }

  // A' 面板页化（Phase 2）：书签/下载/最近改为独立路由页，系统 router 栈接管。
  private openBookmarksPanel(): void {
    this.menuVisible = false;
    this.menuCardVisible = false;
    this.sheetPage = 'tabs';
    router.pushUrl({ url: 'pages/panels/BookmarksPanelPage' }).catch((error: Error): void => {
      console.error('openBookmarksPanel pushUrl failed:', error);
    });
  }

  private openDownloadsPanel(): void {
    this.menuVisible = false;
    this.menuCardVisible = false;
    this.sheetPage = 'tabs';
    router.pushUrl({ url: 'pages/panels/DownloadsPanelPage' }).catch((error: Error): void => {
      console.error('openDownloadsPanel pushUrl failed:', error);
    });
  }

  // 资源嗅探：独立路由页，列出当前页被引擎识别出的媒体/图片资源。
  private openResourceSniffPanel(): void {
    this.menuVisible = false;
    this.menuCardVisible = false;
    this.sheetPage = 'tabs';
    router.pushUrl({ url: 'pages/panels/ResourceSniffPanelPage' }).catch((error: Error): void => {
      console.error('openResourceSniffPanel pushUrl failed:', error);
    });
  }

  // 方案A：地址栏锁图标进入"网站设置"（针对当前浏览站逐类设权限）。
  private openSiteSettings(): void {
    this.menuVisible = false;
    this.menuCardVisible = false;
    // 浏览态（有真实网页）先开「站点快捷面板」：广告拦截/防钓鱼单站开关 +
    // 清除该站数据 + 网站设置入口；主页/新标签没有站点语义，直接进完整页。
    const url: string = this.browserState.url ?? '';
    if (url.length > 0 && !this.isNewTabUrl(url)) {
      this.siteQuickVisible = true;
      return;
    }
    router.pushUrl({ url: 'pages/panels/SiteSettingsPanelPage' }).catch((error: Error): void => {
      console.error('openSiteSettings pushUrl failed:', error);
    });
  }

  private openRecentPanel(): void {
    this.menuVisible = false;
    this.menuCardVisible = false;
    this.sheetPage = 'tabs';
    router.pushUrl({ url: 'pages/panels/RecentPanelPage' }).catch((error: Error): void => {
      console.error('openRecentPanel pushUrl failed:', error);
    });
  }

  private playNavVeil(): void {
    if (this.navVeilTimer !== -1) {
      return;
    }
    animateTo({ duration: 150, curve: Curve.Friction }, (): void => {
      this.navVeilShift = 0;
    });
    this.navVeilTimer = setTimeout((): void => {
      animateTo({ duration: 270, curve: Curve.Friction }, (): void => {
        this.navVeilShift = -1;
      });
      setTimeout((): void => {
        // 复位到屏外右侧（此刻不可见），供下次扫入。
        this.navVeilShift = 1;
        this.navVeilTimer = -1;
      }, 290);
    }, 160);
  }

  // 根据引擎 loading / loadProgress 驱动 2vp 加载细条。
  // 引擎契约（NativeContext）：loadProgress 为 0..1，空闲时恒为 1。
  private syncLoadBar(): void {
    const loading: boolean = this.browserState.loading === true;
    if (loading) {
      if (this.loadBarFadeTimer !== 0) {
        clearTimeout(this.loadBarFadeTimer);
        this.loadBarFadeTimer = 0;
      }
      if (!this.loadBarShown) {
        // 先以最小可见宽度挂载：首次渲染不会触发属性动画，后续变化才动。
        this.loadBarWidth = this.loadBarMin;
        this.loadBarShown = true;
      }
      const raw: number = this.browserState.loadProgress ?? 0;
      // 未真正结束前不露满格（封顶 0.92），收尾那一下才灌到 100%。
      this.loadBarWidth = Math.min(Math.max(raw, this.loadBarMin), 0.92);
      return;
    }
    if (!this.loadBarShown) {
      return;
    }
    // 已在主页直接收，不灌满也不停留（兜住关标签页/新建标签页等路径）。
    if (this.isHomeSurface()) {
      this.hideLoadBarNow();
      return;
    }
    // 加载结束：灌满 → 稍作停留 → 卸载（淡出由 if 根节点 transition 负责）。
    this.loadBarWidth = 1;
    if (this.loadBarFadeTimer === 0) {
      this.loadBarFadeTimer = setTimeout((): void => {
        this.loadBarFadeTimer = 0;
        this.loadBarShown = false;
        this.loadBarWidth = this.loadBarMin;
      }, 180);
    }
  }

  private displayDomain(): string {
    if (this.isNewTabUrl(this.browserState.url)) {
      return '新标签页';
    }
    if (this.browserState.domain && this.browserState.domain.length > 0) {
      return this.browserState.domain;
    }
    return this.browserState.title && this.browserState.title.length > 0 ?
      this.browserState.title : 'Orbira';
  }

  private shortUrl(url: string): string {
    if (!url || this.isNewTabUrl(url)) {
      return '新标签页';
    }
    return url.replace(/^https?:\/\//, '');
  }


  private isNewTabUrl(url: string): boolean {
    // 当前页 url 为空 = 主页态；历史落点 url 为空则是「没有历史条目」，
    // 语义不同，所以空串判定留在本方法，URL 形态交给共享判据。
    return url.length === 0 || isNewTabUrlShared(url);
  }

  private beginAddressEdit(): void {
    // 如果有待定的导航后回弹，重新编辑时取消它，避免旧定时器把正在
    // 编辑的地址栏切回浏览态。
    this.cancelControlsRebound();
    this.hideAddressSuggest();
    this.addressEditEpoch += 1;
    this.addressDraft = this.browserState.url.startsWith('chrome://') ? '' : this.browserState.url;
    // 「首字符替换整条」的基准（见 addressBase 注释）：此后第一次输入即换掉整条。
    this.addressBase = this.addressDraft;
    this.addressEdited = false;
    this.addressSelectionStart = 0;
    this.addressSelectionEnd = this.addressDraft.length;
    this.editingAddress = true;
    this.clearKeyboardRecoveryTimers();
    // Pin both bars while the keyboard is up (SHELL_CONTRACT.md, "手机：滚动
    // 时收起地址栏和 dock", step 5).
    this.issueCommand({ command: 'setBrowserControlsState', state: 'shown', animate: true });
    this.keyboardRecoveryTimers.push(setTimeout((): void => {
      if (!this.editingAddress) {
        return;
      }
      try {
        this.getUIContext().getFocusController().requestFocus('mobile_address_input');
        inputMethod.getController().showTextInput().catch((error: Error): void => {
          console.error('Failed to show the address keyboard:', error);
        });
      } catch (error) {
      }
    }, 0));
    // 后续定时器只补聚焦（键盘偶发不弹出时兜底），不再动选区，免得用户已输入
    // 又被全选覆盖。
    [80, 220, 450].forEach((delay: number): void => {
      this.keyboardRecoveryTimers.push(setTimeout((): void => {
        if (!this.editingAddress) {
          return;
        }
        try {
          this.getUIContext().getFocusController().requestFocus('mobile_address_input');
        } catch (error) {
        }
        if (delay === 80 && !this.addressEdited) {
          this.selectAllAddressText();
        }
      }, delay));
    });
  }

  // 选中地址栏里的整条网址。setTextSelection 是一次性动作，不挂常驻选区属性，
  // 因此不会出现「常驻选区吞掉第一次点按」的老问题。
  private selectAllAddressText(): void {
    const length: number = this.addressDraft.length;
    if (length === 0) {
      return;
    }
    try {
      this.addressController.setTextSelection(0, length);
    } catch (error) {
      console.error('select address text failed:', error);
    }
  }

  private submitAddress(): void {
    this.clearKeyboardRecoveryTimers();
    this.hideAddressSuggest();
    const target = normalizeAddress(this.addressDraft);
    if (target.length > 0) {
      this.issueCommand({ command: 'navigate', url: target });
      // Fix H（提交节奏对齐）：提交瞬间地址栏立即切回浏览态（显示新
      // URL），键盘随之收起——这是"第 1 拍"的即时反馈；旧画面与页面切换
      // 留给引擎（'both' 由 Fix F 延迟交还，不打扰旧画面保持）。分两拍正是
      // 目标：先地址栏归位，稍后页面才切换，变化不挤在一帧。
      this.editingAddress = false;
      this.reboundControlsAfterPaint();
    } else {
      this.editingAddress = false;
      this.issueCommand({ command: 'setBrowserControlsState', state: 'both', animate: true });
    }
  }

  // ---- 地址栏联想 ----

  // 地址栏输入：没动过之前，敲第一个字符（或退格）就替换/清空整条网址——替代
  // 常驻全选，既保留「直接打字换新网址」的手感，又不留选中态（选中菜单会吃掉
  // 第一次点按，害得「取消」要点两次）。
  private onAddressInput(value: string): string {
    if (this.addressEdited || this.addressBase.length === 0) {
      return value;
    }
    if (value === this.addressBase) {
      return value; // 只是光标/选区变化，没真改内容
    }
    if (value.length > this.addressBase.length && value.startsWith(this.addressBase)) {
      this.addressEdited = true;
      return value.substring(this.addressBase.length);
    }
    if (value.length < this.addressBase.length && this.addressBase.startsWith(value)) {
      this.addressEdited = true;
      return ''; // 退格删到比原网址短 = 整条删掉
    }
    this.addressEdited = true;
    return value;
  }

  // 输入变化：轻防抖（130ms）后向引擎要联想（本地自动补全，回包流式）。
  // 非空即让列表可见（先落一条「搜索」兜底行），引擎结果到了再补齐。
  private scheduleAddressSuggest(text: string): void {
    if (this.addressSuggestTimer !== -1) {
      clearTimeout(this.addressSuggestTimer);
      this.addressSuggestTimer = -1;
    }
    const query = text.trim();
    if (query.length === 0) {
      this.hideAddressSuggest();
      return;
    }
    this.suggestVisible = true;
    if (query === this.addressSuggestText) {
      return;
    }
    this.addressSuggestText = query;
    this.onlineSuggestWords = [];
    this.autocompletePending = -1;
    // 新的一轮输入：恢复到「还没上屏」，让引擎第一包立刻替换掉旧列表。
    this.suggestShownFor = -1;
    this.cancelSuggestFlush();
    this.addressSuggestTimer = setTimeout((): void => {
      this.addressSuggestTimer = -1;
      if (!this.editingAddress) {
        return;
      }
      // 本地自动补全（历史/书签/打开标签/网址，引擎侧完成）。
      this.autocompleteSeq += 1;
      this.autocompletePending = this.autocompleteSeq;
      this.issueCommand({
        command: 'autocomplete',
        requestId: this.autocompleteSeq,
        text: query
      });
      // 在线联想词不再在这里发：改为「引擎结果不足时才补发」
      // （见 maybeFetchOnlineSuggest）。这样引擎能出建议时，连第一次输入都
      // 不用等那条 HTTP（约 600ms）。
      // 90 → 60ms：防抖只是把连打合并，引擎侧本来就有 Stop 旧请求的机制，
      // 60ms 足够合并一次连打，但首包能早 30ms 出来。
    }, 60);
  }

  // 收起联想（提交 / 取消编辑 / 点列表外 / 页面已跳走）。
  private hideAddressSuggest(): void {
    if (this.addressSuggestTimer !== -1) {
      clearTimeout(this.addressSuggestTimer);
      this.addressSuggestTimer = -1;
    }
    this.autocompletePending = -1;
    this.suggestHttpSeq += 1;
    this.cancelSuggestFlush();
    this.suggestShownFor = -1;
    this.addressSuggestText = '';
    this.suggestItems = [];
    this.onlineSuggestWords = [];
    this.suggestVisible = false;
    // 收起 = 本轮编辑结束（在线词已在 query 变化时清过，这里不再重复处理）。
  }

  // 引擎回包：只认最新 requestId（旧包丢弃）；同 id 的多包照单全收（流式）。
  private onAutocompleteChanged(): void {
    if (this.autocompleteJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.autocompleteJson) as AutocompletePayload;
      if (payload.requestId !== this.autocompletePending) {
        return;
      }
      // 归一化字段（引擎侧可选字段落空时保证渲染层拿到的是字符串）。
      const normalized: AutocompleteItem[] = [];
      for (const parsed of payload.items ?? []) {
        normalized.push({
          type: parsed.type,
          title: typeof parsed.title === 'string' ? parsed.title : '',
          url: typeof parsed.url === 'string' ? parsed.url : '',
          description: typeof parsed.description === 'string' ? parsed.description : ''
        } as AutocompleteItem);
      }
      if (normalized.length === 0) {
        return;
      }
      if (payload.done === true) {
        this.cancelSuggestFlush();
        this.suggestItems = normalized;
        this.suggestShownFor = payload.requestId;
        // 最后一批到齐：引擎建议不够用时才补发在线请求（常态下省掉一次
        // DNS+TLS 握手，约 400~600ms）。见 maybeFetchOnlineSuggest。
        this.maybeFetchOnlineSuggest(normalized);
        return;
      }
      if (this.suggestShownFor !== payload.requestId) {
        this.cancelSuggestFlush();
        this.suggestItems = normalized;
        this.suggestShownFor = payload.requestId;
        return;
      }
      this.suggestQueuedItems = normalized;
      if (this.suggestFlushTimer !== -1) {
        return;
      }
      this.suggestFlushTimer = setTimeout((): void => {
        this.suggestFlushTimer = -1;
        if (this.suggestQueuedItems.length > 0) {
          this.suggestItems = this.suggestQueuedItems;
          this.suggestQueuedItems = [];
        }
        // 120 → 160ms：中间包本来就会多次到达，窗口放宽能把「本地首包之后
        // 的零星刷新」并成一次，少一层高度跳变（首包仍然是立即上屏，不增加
        // 弹出延迟）。
      }, 160);
    } catch (error) {
    }
  }

  // 取消待合并的刷新（新请求 / 收起列表时调用，避免旧包把新结果盖回去）。
  private cancelSuggestFlush(): void {
    if (this.suggestFlushTimer !== -1) {
      clearTimeout(this.suggestFlushTimer);
      this.suggestFlushTimer = -1;
    }
    this.suggestQueuedItems = [];
  }

  // 列表是否真的该显示：在"联想模式"、有输入、有行（搜索行/在线词/本地项）。
  // URL 型输入在引擎给不出匹配时不弹（不显示空卡）。
  private suggestListActive(): boolean {
    return this.suggestVisible && this.editingAddress &&
      this.addressSuggestText.length > 0 && this.suggestRows().length > 0;
  }

  // 「像在搜词」而非「像网址」——决定是否发在线联想 + 加首行「搜索」。
  // 与 normalizeAddress 的判定同规则：带 scheme = 网址；含空格或无点 = 搜词。
  private looksLikeUrl(text: string): boolean {
    const input = text.trim();
    if (input.length === 0) {
      return false;
    }
    if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(input)) {
      return true;
    }
    if (/\s/.test(input) || !input.includes('.')) {
      return false;
    }
    return true;
  }

  private searchSuggestRow(word: string): AutocompleteItem {
    return {
      type: 'search',
      title: word === this.addressSuggestText ? `搜索 “${word}”` : word,
      url: searchUrlFor(word),
      description: ''
    } as AutocompleteItem;
  }

  // 列表内容（自上而下）：
  //   1. 「搜索 “输入”」—— 搜索型输入的第一动作，永远在首行；
  //   2. 在线联想词（默认引擎建议接口，最多 5 条）；
  //   3. 引擎本地补全（历史/书签/打开标签/网址；引擎给的 search 类目跳过，
  //      与首行重复）。
  // 总行数 ≤ 8，键盘弹起时列表不会越过半屏。
  private suggestRows(): AutocompleteItem[] {
    const rows: AutocompleteItem[] = [];
    const query = this.addressSuggestText;
    const searchLike = !this.looksLikeUrl(query);
    const seen: Set<string> = new Set<string>();
    if (searchLike && query.length > 0) {
      rows.push(this.searchSuggestRow(query));
      seen.add(query);
    }
    if (searchLike) {
      for (const item of this.suggestItems) {
        if (item.type !== 'search') {
          continue;
        }
        const title: string = item.title.trim();
        if (title.length === 0 || seen.has(title)) {
          continue;
        }
        if (rows.length >= 8) {
          break;
        }
        rows.push(this.searchSuggestRow(title));
        seen.add(title);
      }
      for (const word of this.onlineSuggestWords) {
        if (rows.length >= 8) {
          break;
        }
        // 百度/搜狗常在首位回显查询词 —— 与首行「搜索」/引擎行重复，跳过。
        if (word.length === 0 || seen.has(word)) {
          continue;
        }
        rows.push(this.searchSuggestRow(word));
        seen.add(word);
      }
    }
    const localCap = searchLike ? 3 : 6;
    let local = 0;
    for (const item of this.suggestItems) {
      if (item.type === 'search') {
        continue;
      }
      if (local >= localCap || rows.length >= 8) {
        break;
      }
      rows.push(item);
      local += 1;
    }
    return rows;
  }

  // 在线联想词：按默认搜索引擎选建议接口（失败静默——列表仍有本地行兜底）。
  private onlineSuggestEndpoint(query: string): string {
    const template = String(AppStorage.get('auraSearchUrlTemplate') ?? '');
    const encoded = encodeURIComponent(query);
    if (template.includes('baidu')) {
      return `https://suggestion.baidu.com/su?wd=${encoded}&ie=utf-8&oe=utf-8&cb=aura`;
    }
    if (template.includes('bing')) {
      return `https://api.bing.com/osjson.aspx?query=${encoded}`;
    }
    if (template.includes('google')) {
      return `https://suggestqueries.google.com/complete/search?client=firefox&q=${encoded}`;
    }
    if (template.includes('sogou')) {
      return `https://sugg.sogou.com/sugg/ajaj_json.jsp?key=${encoded}&type=web&ori=yes&pr=web`;
    }
    return '';
  }

  // 引擎最后一批到齐后调用：引擎建议不够用时才补发在线请求。引擎的 TYPE_SEARCH
  // 走浏览器网络栈（连接热），常态就够用；外壳那条 HTTP 每次都要重做 DNS+TLS
  // 握手（约 400~600ms），只在引擎给得少时才发。
  private maybeFetchOnlineSuggest(engineItems: AutocompleteItem[]): void {
    // 已有在线词（上一发还没被 query 变化清掉）就不重复请求。
    if (this.onlineSuggestWords.length > 0) {
      return;
    }
    let searchRows: number = 0;
    for (const item of engineItems) {
      if (item.type === 'search') {
        searchRows += 1;
      }
    }
    if (searchRows >= ONLINE_SUGGEST_MIN_ENGINE_ROWS) {
      return;
    }
    this.fetchOnlineSuggest(this.addressSuggestText);
  }

  private fetchOnlineSuggest(query: string): void {
    if (this.looksLikeUrl(query)) {
      return;
    }
    const endpoint = this.onlineSuggestEndpoint(query);
    if (endpoint.length === 0) {
      return;
    }
    this.suggestHttpSeq += 1;
    const seq = this.suggestHttpSeq;
    // 每次按键都建一个 HttpRequest，用完必须 destroy：不释放的话输入过程中会
    // 持续堆对象，配合列表重排更容易出现掉帧。
    const client: http.HttpRequest = http.createHttp();
    client.request(endpoint, {
      method: http.RequestMethod.GET,
      connectTimeout: 4000,
      readTimeout: 4000
    }).then((response: http.HttpResponse): void => {
      client.destroy();
      // 过期回包（已继续输入 / 已离开编辑 / 已收起列表）直接丢弃。
      if (seq !== this.suggestHttpSeq || query !== this.addressSuggestText ||
        !this.editingAddress || !this.suggestVisible) {
        return;
      }
      this.onlineSuggestWords = parseSuggestionWords(String(response.result ?? ''));
    }).catch((error: Error): void => {
      client.destroy();
      if (seq === this.suggestHttpSeq) {
        this.onlineSuggestWords = [];
      }
    });
  }

  private suggestIcon(type: string): Resource {
    if (type === 'search') {
      return $r('app.media.aura_search');
    }
    if (type === 'bookmark') {
      return $r('app.media.aura_bookmark');
    }
    if (type === 'history') {
      return $r('app.media.aura_clock');
    }
    if (type === 'openTab') {
      return $r('app.media.aura_window');
    }
    return $r('app.media.aura_globe');
  }

  // 点选联想：直接导航（引擎回包的 url 已是绝对地址），节奏与 submitAddress
  // 的"两拍"一致 —— 立即收起地址栏回浏览态，页面切换留给引擎。
  private applyAddressSuggestion(item: AutocompleteItem): void {
    this.hideAddressSuggest();
    this.clearKeyboardRecoveryTimers();
    const target = item.url.length > 0 ? item.url : normalizeAddress(item.title);
    if (target.length === 0) {
      return;
    }
    this.addressDraft = target;
    this.issueCommand({ command: 'navigate', url: target });
    this.editingAddress = false;
    this.reboundControlsAfterPaint();
  }

  private clearKeyboardRecoveryTimers(): void {
    this.keyboardRecoveryTimers.forEach((timer: number): void => clearTimeout(timer));
    this.keyboardRecoveryTimers = [];
  }

  private onEditingAddressChanged(): void {
    // 同步给外壳：编辑态下浏览器控件是被钉住的（beginAddressEdit 发 shown），
    // AuraShell 的「上滑兜底收顶栏」必须让位，否则会把正在输入的地址栏收掉。
    AppStorage.setOrCreate('auraAddressEditing', this.editingAddress);
    if (this.editingAddress) {
      return;
    }
    this.clearKeyboardRecoveryTimers();
    try {
      inputMethod.getController().hideTextInput().catch((error: Error): void => {
        console.warn('Failed to hide the address keyboard: %{public}s', JSON.stringify(error));
      });
    } catch (error) {
    }
  }

  // 长按联想项：把该条网址写进系统剪贴板（写操作不需要任何权限）+ toast。
  // 空网址退回标题；两者都空则忽略。
  private copySuggestText(item: AutocompleteItem): void {
    const text: string = item.url.length > 0 ? item.url : item.title;
    if (text.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then((): void => {
        this.getUIContext().getPromptAction().showToast({ message: '已复制网址', duration: 1500 });
      }).catch((): void => {
      });
    } catch (error) {
    }
  }

  private issueCommand(command: BrowserCommandPayload): void {
    // 取证：reload/home/navigate 会杀掉进行中的导航（磁贴弹回家族），
    this.onCommand(command);
  }

  private setPrimaryAction(action: MobileEdgeAction): void {
    this.primaryAction = action;
    AppStorage.setOrCreate(PRIMARY_ACTION_KEY, action);
  }

  private setFollowGrip(value: boolean): void {
    this.followGrip = value;
    AppStorage.setOrCreate(FOLLOW_GRIP_KEY, value);
    if (value) {
      this.startHoldingHandAwareness();
    } else {
      this.holdingHandRouter.stop();
    }
  }

  private startHoldingHandAwareness(): void {
    this.holdingHandRouter.start((side: GripSide): void => {
      this.lastGripSide = side;
      AppStorage.setOrCreate(LAST_GRIP_SIDE_KEY, side);
    });
  }

  private shareCurrentPage(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    HuaweiShareAdapter.sharePage(context, this.browserState.url, this.browserState.title)
      .catch((error: Error) => {
        console.error('Huawei Share failed:', error);
      });
  }
}

// The dock's system immersive material (沉浸光感), driven exactly the way
// It is driven as a real HdsTabs whose five tabBar entries ARE the five
// dock buttons. The earlier revision used a bare single-tab backplate with
// the buttons stacked on top of it; on device the material's geometry
// followed that empty bar, so the capsule looked too tall and a haze ring
// bled around both rounded ends -- and with hitTest None touches never
// reached the material either, so the press light never fired. The same layout
// on a stock system dock shows none of that, and the system shell explains why:
// five TabContents, each with a tabBar builder rendering a real button,
// clicks distributed centrally from onTabBarClick.
//
// The three flags that make the floating material appear (official guide:
// all three at once, or the material silently does not render):
// barOverlap true + vertical false + barPosition End.
//
// gradientMask pins the material's fade region to exactly "bar + the strip
// below it". Left unset, the mask
// falls back to "component height + tabBar + 32vp", a tall rectangle
// bleeding above the capsule. barBackgroundColor / barBackgroundBlurStyle
// are deliberately never set: the official guide says they cover the
// material ("避免遮挡材质效果").
//
// barWidth is set explicitly. A first revision passed no barWidth (none set
// either) and the floating bar measured itself from its tab
// items -- but our items are percent-sized, so the measurement collapsed
// to nothing and the whole plate (material AND buttons) vanished. Now the
// bar gets the concrete width on all three breakpoints AND every tab item
// carries an intrinsic DOCK_SLOT_WIDTH_VP, so either measurement path
// lands on the intended capsule.
@Component
struct DockMaterialPlate {
  @Prop canGoBack: boolean = false;
  @Prop canGoForward: boolean = false;
  @Prop tabCount: number = 0;
  @Prop barWidthVp: number = 328;
  @Prop barHeightVp: number = 48;
  @Prop sideMarginVp: number = 16;
  @Prop bottomMarginVp: number = 0;
  // 图标/徽标颜色（主页态按壁纸底带反色）。空串 = 回落系统 icon_primary：
  // 网页态的 dock 与壁纸无关，必须保持主题色。用字符串而不是 ResourceColor
  // 联合类型，是为了 @Prop 跨组件传递稳（联合类型在 @Prop 里易踩类型收窄）。
  @Prop dockInkHex: string = '';
  onDockSlot: (slot: string) => void = (_slot: string): void => {};
  // 按压中的按钮（弹簧缩放用）；只在本子树内使用，无需跨组件共享。
  @State private pressedSlot: string = '';

  private readonly slots: string[] = ['返回', '前进', '主页', '标签页', '菜单'];

  build() {
    HdsTabs({ barPosition: BarPosition.End, index: 0 }) {
      ForEach(this.slots, (slot: string): void => {
        TabContent() {
          // 页面本体在 WebWindow 里；TabContent 只是 tab 的存在凭据。
          Column()
            .width('100%')
            .height('100%')
        }
        .tabBar(this.DockSlotBar(slot))
      }, (slot: string): string => slot)
    }
    .vertical(false)
    .scrollable(false)
    .barMode(BarMode.Fixed)
    .barOverlap(true)
    .animationDuration(0)
    .barHeight(this.barHeightVp)
    .barFloatingStyle(this.resolveFloatingStyle())
    .onTabBarClick((index: number): void => {
      if (index < 0 || index >= this.slots.length) {
        return;
      }
      const slot: string = this.slots[index];
      if (slot === '返回' && !this.canGoBack) {
        return;
      }
      if (slot === '前进' && !this.canGoForward) {
        return;
      }
      this.onDockSlot(slot);
    })
    .width('100%')
    .height('100%')
    .clip(true)
  }

  @Builder
  private DockSlotBar(slot: string) {
    Column() {
      if (slot === '标签页') {
        Text(this.tabCount > 99 ? '99+' : this.tabCount.toString())
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.slotInk())
          .textAlign(TextAlign.Center)
          .width(22)
          .height(20)
          .borderRadius(6)
          .border({ width: 1.8, color: this.slotInk() })
      } else {
        if (slot === '返回' || slot === '前进') {
          SymbolGlyph(slot === '返回' ?
            $r('sys.symbol.chevron_backward') : $r('sys.symbol.chevron_forward'))
            .fontSize(22)
            .fontColor([ this.slotInk() ])
        } else {
          Image(this.slotIcon(slot))
            .width(22)
            .height(22)
            .fillColor(this.slotInk())
        }
      }
    }
    // 固有宽度 65 是防塌缩保险（浮动条自动测量路径要靠它；barWidth 已
    // 显式给，两条测量路径都要能立起来）。高度交给槽位（100%），内容
    // 由 justifyContent 垂直居中——这是对齐的关键。
    .width(DOCK_SLOT_WIDTH_VP)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .opacity(this.slotUsable(slot) ? 1 : 0.4)
    .enabled(this.slotUsable(slot))
    .scale({ x: this.pressedSlot === slot ? 0.82 : 1, y: this.pressedSlot === slot ? 0.82 : 1 })
    .accessibilityText(slot)
    .onTouch((event: TouchEvent): void => {
      this.handleSlotTouch(event, slot);
    })
  }

  // dock 图标的实际颜色：主页有壁纸时用父组件传进来的底带反色结果，
  // 其余情况（网页态 / 无壁纸）回落系统 icon_primary。
  private slotInk(): ResourceColor {
    return this.dockInkHex.length > 0 ? this.dockInkHex : $r('app.color.icon_primary');
  }

  private slotUsable(slot: string): boolean {
    if (slot === '返回') {
      return this.canGoBack;
    }
    if (slot === '前进') {
      return this.canGoForward;
    }
    return true;
  }

  private slotIcon(slot: string): Resource {
    if (slot === '返回') {
      return $r('sys.symbol.chevron_backward');
    }
    if (slot === '前进') {
      return $r('sys.symbol.chevron_forward');
    }
    if (slot === '主页') {
      return $r('app.media.aura_home');
    }
    return $r('app.media.aura_more');
  }

  // Press -> quick shrink; release -> under-damped spring back ("jelly").
  // 禁用槽位（返回/前进不可用）不做按压动画——以前靠 Button.enabled 挡
  // 触摸，换成 Column 后在这里守。
  private handleSlotTouch(event: TouchEvent, slot: string): void {
    if (!this.slotUsable(slot)) {
      return;
    }
    if (event.type === TouchType.Down) {
      animateTo({ duration: 90, curve: Curve.FastOutSlowIn }, (): void => {
        this.pressedSlot = slot;
      });
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      animateTo({ curve: curves.springMotion(0.3, 0.7) }, (): void => {
        this.pressedSlot = '';
      });
    }
  }

  private resolveFloatingStyle(): HdsTabsFloatingStyle {
    const width: number = Math.max(1, this.barWidthVp);
    const style: HdsTabsFloatingStyle = {
      barSideMargin: this.sideMarginVp,
      barBottomMargin: this.bottomMarginVp,
      // The concrete capsule width. Without it the floating bar falls back
      // to measuring its items, and percent-sized items measure to zero.
      barWidth: {
        smallWidth: width,
        mediumWidth: width,
        largeWidth: width
      },
      // ADAPTIVE lets the system pick the material strength for the device.
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      },
      // The fade region: from the bar down past the home-indicator strip to
      // the layer's bottom edge (= the screen edge). maskHeight = bar +
      // bottom margin, matching the dock's own mask height.
      gradientMask: {
        maskColor: $r('app.color.dock_mask'),
        maskHeight: this.barHeightVp + this.bottomMarginVp
      }
    };
    return style;
  }
}

@Component
struct ChromeBarMaterialPlate {
  @Prop barWidthVp: number = 328;
  @Prop barHeightVp: number = 48;
  @Prop sideMarginVp: number = 12;
  @Prop bottomMarginVp: number = 0;

  private readonly slots: string[] = ['a', 'b', 'c', 'd', 'e'];

  build() {
    HdsTabs({ barPosition: BarPosition.End, index: 0 }) {
      ForEach(this.slots, (slot: string): void => {
        TabContent() {
          // 页面本体在 WebWindow 里；TabContent 只是 tab 的存在凭据。
          Column()
            .width('100%')
            .height('100%')
        }
        .tabBar(this.EmptySlot(slot))
      }, (slot: string): string => slot)
    }
    .vertical(false)
    .scrollable(false)
    .barMode(BarMode.Fixed)
    .barOverlap(true)
    .animationDuration(0)
    .barHeight(this.barHeightVp)
    .barFloatingStyle(this.resolveFloatingStyle())
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  // 空槽位：只要固有宽度（防塌缩），不画任何东西。
  @Builder
  private EmptySlot(slot: string) {
    Column()
      .width(DOCK_SLOT_WIDTH_VP)
      .height('100%')
      .accessibilityText(slot)
  }

  private resolveFloatingStyle(): HdsTabsFloatingStyle {
    const width: number = Math.max(1, this.barWidthVp);
    const style: HdsTabsFloatingStyle = {
      barSideMargin: this.sideMarginVp,
      barBottomMargin: this.bottomMarginVp,
      barWidth: {
        smallWidth: width,
        mediumWidth: width,
        largeWidth: width
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      },
      gradientMask: {
        maskColor: $r('app.color.dock_mask'),
        maskHeight: this.barHeightVp + this.bottomMarginVp
      }
    };
    return style;
  }
}
