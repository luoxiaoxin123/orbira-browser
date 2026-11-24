/*
 * 手机主页（新标签页覆盖层）v2 —— 1.0.79 主页改造。
 *
 * 17.1 快捷方式 → 书签：磁贴数据源改为书签树里「首页」文件夹（手机书签根下）。
 *   进入时自动发现该文件夹（缺失即创建）；老的手动快捷方式一次性迁入；
 *   添加/编辑/删除都走书签命令（addBookmark / updateBookmark / removeBookmarks）。
 * 17.2 主页布局（原「主页设置」，1.0.88 改名）：右上角齿轮 → 背景图上传（照片选择器 → 拷进沙箱）、
 *   Logo·搜索框·书签区 的上下位移与显隐（preferences 持久化，HomePrefs）。
 *
 * 请求通道说明：getBookmarks 回包经 AuraShell 落 'auraPanelBookmarkList'，
 * 书签面板共用同一存储 —— 主页用 700000 起的独立序号段 + 父层校验过滤自己的
 * 回包；面板在别处操作书签会发 bookmarkCreated/bookmarksChanged（'auraPanelEvent'），
 * 主页借此刷新磁贴。
 */
import { AutocompleteItem, BookmarkNode, BrowserCommandPayload, FaviconImage } from 'engine';
import { common } from '@kit.AbilityKit';
import { promptAction, display, curves, window } from '@kit.ArkUI';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { normalizeAddress } from './ShellUtils';
// 底部 dock 的占位高度（单一真源在 MobileBrowserOverlay，避免两处各写一份常量）。
import { dockCoveredHeightVp } from './MobileBrowserOverlay';
import { ScanService } from './ScanService';
import { HomeShortcut, HomeShortcuts } from '../../utils/appearance/HomeShortcuts';
import { HomeCustom, HomePrefs, HomeToneCache, defaultHomeCustom } from '../../utils/appearance/HomePrefs';
import { HomeCache, HomeCacheData } from '../../utils/appearance/HomeCache';
import { hilog } from '@kit.PerformanceAnalysisKit';

// 书签「首页」文件夹的标题（同时作为目录名使用）。
const HOME_FOLDER_TITLE: string = '首页';
// 主页的请求序号段（书签面板从 0 起；以此区分谁的回包）。
const HOME_SEQ_BASE: number = 700000;
// 主页搜索框联想的序号段（与书签段、面板段都错开，回包只认自己这一段）。
const HOME_SUGGEST_SEQ_BASE: number = 950000;
// 主页序号在这段里循环（[700000, 900000)），始终高于书签面板的 600000 上限。
const HOME_SEQ_SPAN: number = 200000;
// 模块级序号抬升：每次挂载 +1000（同 BookmarksPanel 的 panelSeqBump）。
// 原因：AppStorage.setOrCreate 存的是 JSON 字符串，**内容完全相同就不算变化
// → @Watch 不触发**。主页每次按主页键都会销毁重建，homeSeq 若从 700000 重来，
// 请求号与上一轮撞车 → 回包 JSON 与上次逐字节相同 → 引擎回了包但主页收不到，
// 磁贴一直空着，要等 1.6s 超时重试才补上（表现为「书签不显示/延迟出现」）。
let homeSeqBump: number = HOME_SEQ_BASE;
// 发现链 / 磁贴刷新的兜底时间。
const CHAIN_TIMEOUT_MS: number = 1600;
const REFRESH_DEBOUNCE_MS: number = 260;
const MAX_CHAIN_RETRIES: number = 6;
// 「首页」文件夹回包为空的额外重试次数。引擎刚起步（书签模型还没加载完）会先
// 回空列表；原来只重试一次，引擎稍慢就会把假空当真，还会把缓存写空——下次冷
// 启动没有「上次不空」的判据，更容易再空。多给几次，等引擎把书签模型读完。
const EMPTY_TILES_MAX_RETRIES: number = 3;
// 长按菜单卡宽度（与 ⋮ 卡/网页长按卡同一家族）。
const MENU_CARD_VP: number = 190;
const MENU_CARD_H: number = 204;
// 页面顶部常驻工具条的占高（vp）：简约风格是「主页 / 标签数 / ⋮」，Chrome
// 风格是上置 dock。真机 dump 到该行 168px ≈ 56vp。主页内容不能落进这条带里。
const TOP_CHROME_EXTENT_VP: number = 56;
// 磁贴底板边长（vp）。底板是磁贴的「托盘」，图标画在它里面。
const TILE_ICON_VP: number = 46;
// 磁贴底板圆角（约边长 28%，与原 54/15 的比例一致）。
const TILE_ICON_RADIUS: number = 13;
// favicon 在底板里的**绘制**边长（vp）。这是「图标糊」的根治点：
// 引擎按 sizeVp×deviceScaleFactor 生成 PNG（overlay/chrome/browser/ui/ohos/
// shell_favicons_ohos.cc: size_px = clamp(sizeVp) × PrimaryDisplayScale()），
// 站点只给 16/32px 的 favicon 时会被拉大 —— 画得越大越糊（46vp 满铺 =
// 138px，会发虚）；24vp 又与首字母占位块比例失衡。取 30vp 兼顾清晰度与磁贴比例。
const TILE_FAVICON_VP: number = 30;
// 底板里 favicon 的圆角（按边长约 25% 收）；首字母占位色块沿用同一圆角，
// 保证「有图标 / 无图标」内部轮廓一致。
const TILE_FAVICON_RADIUS: number = 8;
// 向引擎请求的尺寸（vp）= 绘制尺寸 × 2：站点声明了 touch / web-manifest 大图
// 时能拿到真像素再**缩着画**（Interpolation.High），比放大清楚；没有大图的
// 站点退化为和以前一样的放大，那一档靠上面的小绘制尺寸兜住。
const TILE_FAVICON_REQUEST_VP: number = TILE_FAVICON_VP * 2;
// 冷启动缓存里 favicon base64 的字符上限（512KB）。写缓存时只保留首页磁贴
// 用到的图标（见 serializeFavicons），体积远小于全量书签；这里再留一道兜底，
// 正常用量不会触及。超限不再整个丢弃图标，而是按磁贴顺序截断保留。
const MAX_CACHE_FAVICONS_CHARS: number = 524288;
// 壁纸分区取样（占可见壁纸高度的比例），按消费者落点划分：
//   顶带 0~14%   → 状态栏 + Chrome 风格顶栏
//   中带 18~68%  → Logo、搜索框、书签磁贴
//   底带 84~100% → 底部 dock
// 顶/底亮度常相反，单一信号必错一区。
const TONE_TOP_END: number = 0.14;
const TONE_MID_START: number = 0.18;
const TONE_MID_END: number = 0.68;
const TONE_BOTTOM_START: number = 0.84;
// 统计用的缩略图宽度（px）。几十列足够取中位数，解码与遍历都便宜。
const TONE_THUMB_W: number = 40;
// 深色模式在壁纸上压一层 30% surface_primary(#1D1D1F) 暗纱（见 build 里的纱幕），
// 前景实际压的是**叠完纱**的颜色，判色必须按合成后的亮度算，否则深色模式偏亮。
const TONE_DARK_SCRIM_ALPHA: number = 0.30;
const TONE_DARK_SCRIM_LUM: number = 0.114;
// 回主页的进场缩放。用不透明的放大回落而非淡入，避免任何透明帧
// 把下层网页或引擎白 NTP 透出来。
const HOME_ENTER_SCALE: number = 1.05;

// favicon 请求合批窗口（ms）。同一帧里几十个磁贴
// 各自 want() → 攒一拍合成**一次** getFavicons（引擎一次最多 100 个 url，
// 见 shell_favicons_ohos.cc kMaxUrlsPerRequest）。
const FAVICON_BATCH_MS: number = 60;
// 引擎一次 getFavicons 的上限；超过就分片（分片回包会累积进同一个 map）。
const FAVICON_BATCH_MAX: number = 100;
// 无 favicon 时的占位图标色：按主机名稳定取色 + 白字首字母。色块只占
// TILE_FAVICON_VP，外层托盘仍与其余磁贴共用毛玻璃，外边缘完全一致。
const PLACEHOLDER_TINTS: string[] = [
  '#4285F4', '#0F9D58', '#DB4437', '#F4B400',
  '#7B61FF', '#00897B', '#E8710A', '#546E7A'
];

interface BookmarkListPayload {
  requestId?: number;
  parentId?: string;
  nodes?: BookmarkNode[];
}

interface PanelEventPayload {
  kind?: string;
  revision?: number;
}

// 引擎 autocomplete 回包（与地址栏共用同一条命令与同一个存储键，
// 各按自己的 requestId 过滤）。
interface HomeAutocompletePayload {
  requestId?: number;
  items?: AutocompleteItem[];
  done?: boolean;
}

// 首页默认书签（首次运行时种入「首页」文件夹）。
interface HomeSeedSite {
  title: string;
  url: string;
}

function formatOffset(value: number): string {
  return value > 0 ? `+${value}` : `${value}`;
}

// 默认书签去重用的归一化键：去 scheme / 前导 www. / 尾斜杠 / path，只留主机名。
// 让 https://www.baidu.com、https://baidu.com/、http://baidu.com 视为同一站点。
function seedKey(url: string): string {
  let host = url.trim().toLowerCase();
  const schemeIndex = host.indexOf('://');
  if (schemeIndex >= 0) {
    host = host.substring(schemeIndex + 3);
  }
  const slashIndex = host.indexOf('/');
  if (slashIndex >= 0) {
    host = host.substring(0, slashIndex);
  }
  if (host.startsWith('www.')) {
    host = host.substring(4);
  }
  return host;
}

function initialOf(node: BookmarkNode): string {
  const title = node.title.trim();
  if (title.length > 0) {
    return title.substring(0, 1).toUpperCase();
  }
  const url = (node.url ?? '').trim();
  const schemeIndex = url.indexOf('://');
  const host = schemeIndex >= 0 ? url.substring(schemeIndex + 3) : url;
  return host.length > 0 ? host.substring(0, 1).toUpperCase() : '?';
}

// 主机名（小写）。占位色与 favicon 请求都按它归一 —— 同一站点的不同页面
// 用同一块色板，色块不会随页面跳来跳去。
function hostOf(node: BookmarkNode): string {
  const url = (node.url ?? '').trim();
  const schemeIndex = url.indexOf('://');
  let host = schemeIndex >= 0 ? url.substring(schemeIndex + 3) : url;
  const slash = host.indexOf('/');
  if (slash >= 0) {
    host = host.substring(0, slash);
  }
  return host.toLowerCase();
}

// 无 favicon 的占位图标色：主机名哈希 → 稳定落在 PLACEHOLDER_TINTS 上。
function placeholderTint(node: BookmarkNode): string {
  const host = hostOf(node);
  let hash = 0;
  for (let i = 0; i < host.length; i += 1) {
    hash = (hash * 31 + host.charCodeAt(i)) % 1000003;
  }
  const index = hash % PLACEHOLDER_TINTS.length;
  return PLACEHOLDER_TINTS[index];
}

// 只把 http(s) 交给引擎问图标：chrome:// file:// data: 之类永远没有 favicon，
// 白占一次 requests 的额度（FaviconStore.want() 同样是这道门）。
function isFetchableUrl(url: string): boolean {
  return url.startsWith('http://') || url.startsWith('https://');
}

// 归一化 url：比较书签去重/迁移时跨 "https://x.com" 与 "https://x.com/" 匹配。
function normUrl(url: string): string {
  if (!url || url.length === 0) {
    return url;
  }
  let s = url.trim();
  const idx = s.indexOf('://');
  if (idx >= 0) {
    s = s.substring(0, idx).toLowerCase() + s.substring(idx);
  }
  if (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

// 主页布局弹层的两类行必须走 @Component + @Prop：@Builder 按值传参时
// 动态内容不会刷新 UI。
@Component
struct HomeSettingToggleRow {
  icon: Resource = $r('app.media.aura_display');
  label: string = '';
  @Prop isOn: boolean = true;
  onToggle: (on: boolean) => void = (_on: boolean): void => {};

  build() {
    Row({ space: 12 }) {
      Image(this.icon)
        .width(20)
        .height(20)
        .fillColor($r('app.color.icon_primary'))
      Text(this.label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor($r('app.color.accent_primary'))
        .onChange((on: boolean): void => {
          this.onToggle(on);
        })
    }
    .width('100%')
    .height(46)
  }
}

@Component
struct HomePositionSliderRow {
  label: string = '';
  @Prop posOffset: number = 0;
  min: number = 0;
  max: number = 260;
  onMoved: (value: number, end: boolean) => void = (_value: number, _end: boolean): void => {};

  build() {
    Row({ space: 10 }) {
      Text(this.label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .width(58)
      // step 必须为 1：值域 380，step 4 会让位置按 4vp 阶梯跳，拖动时肉眼可见跳格。
      Slider({ value: this.posOffset, min: this.min, max: this.max, step: 1 })
        .layoutWeight(1)
        .selectedColor($r('app.color.accent_primary'))
        .onChange((value: number, mode: SliderChangeMode): void => {
          const end = mode === SliderChangeMode.End || mode === SliderChangeMode.Click;
          this.onMoved(Math.round(value), end);
        })
      Text(formatOffset(this.posOffset))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width(40)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .height(44)
  }
}

@Component
export struct HomeSurface {
  @StorageLink('auraPanelBookmarkList') @Watch('onBookmarkListChanged') bookmarkListJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  @StorageLink('auraFavicons') @Watch('onFaviconsChanged') faviconsJson: string = '';
  // 主页搜索框联想：与地址栏同一条 autocomplete 通道（存储键 'auraAutocomplete'），
  // 用独立序号段 + requestId 过滤自己的回包，互不串。
  @StorageLink('auraAutocomplete') @Watch('onHomeAutocomplete') autocompleteJson: string = '';
  @State private suggestItems: AutocompleteItem[] = [];
  private suggestPending: number = -1;
  private suggestSeq: number = HOME_SUGGEST_SEQ_BASE;
  private suggestTimer: number = -1;
  // 已经「上过屏」的 requestId：首包判断用（同一轮只立即上屏一次，后续包合并刷）。
  private suggestShownFor: number = -1;
  // 合并刷新的定时器与暂存（避免每个 provider 包都重建整张卡）。
  private suggestFlushTimer: number = -1;
  private suggestQueued: AutocompleteItem[] = [];
  // 无痕会话：主页换成无痕的标题与说明，书签磁贴与主页布局入口都不出现。
  @Prop incognito: boolean = false;
  // 主页层此刻是否在屏上。状态栏只在壁纸可见时按顶带反色；网页态顶栏是实色，
  // 必须走主题色。与 AuraShell 的 .visibility(homeSurfaceVisible()) 同源同帧。
  @Prop @Watch('onHomeVisibleChanged') homeVisible: boolean = true;
  // 嵌入模式（平板/桌面 chrome 下方内嵌）：内容顶距换成外层 chrome 总高
  // （标签条+工具栏+状态栏余量），顶部渐变纱不再画（那一条归 chrome 管），
  // 壁纸也不再给状态栏反色（标签条是不透明实底，壁纸顶带被它盖住）。
  @Prop embedded: boolean = false;
  // 桌面 chrome 总高（vp），由 AuraShell 注入；仅 embedded 时生效。
  @Prop topInsetVp: number = 0;
  // 状态栏避让由本组件内部承担：surface_primary 背景能铺满状态栏条带。
  @StorageProp('auraTopSafeVp') topSafeVp: number = 0;
  // 底部安全区与风格：简约风格的 dock 悬浮在主页底部、会盖住滚动内容的下沿
  // （chrome 风格主页的 dock 钉在顶部，底部没有遮挡）。滚动内容末尾要按它让位，
  // 否则滚到底时最后一行磁贴正好压在 dock 下面（用户报「横屏滑下去看不到磁贴、
  // dock 挡住」）。
  @StorageProp('auraBottomSafeVp') bottomSafeVp: number = 0;
  @StorageProp('auraHomeStyle') homeStyle: string = 'minimal';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};

  // -- 磁贴数据（书签「首页」文件夹） ------------------------------------------
  @State private tiles: BookmarkNode[] = [];
  // 当前配色（'light'/'dark'），接 AppStorage：浅色模式不铺壁纸薄纱、深色模式保留暗纱。
  @StorageLink('auraColorScheme') @Watch('onColorSchemeChanged') colorScheme: string = 'light';
  // 文件夹**全量**子节点（含子文件夹）——引擎 moveBookmarks 的 index 是全量
  // 位次，排序换算要用它；磁贴渲染只取其中的 url 节点。
  private fullNodes: BookmarkNode[] = [];
  @State private homeFolderId: string = '';
  // 主页默认书签（谷歌/必应/百度/GitHub）是否已一次性种入「首页」文件夹。
  @State private homeBookmarksSeeded: boolean = false;
  // seeded 标志位是否已从偏好读回来。读回来之前一律不种：书签回包可能先到，
  // 那时 homeBookmarksSeeded 还是 false，会被当成"没种过"而补回用户删掉的站。
  private homeSeedLoaded: boolean = false;
  @State private tilesError: boolean = false;
  // 绘制用的 url → data URL（引擎 PNG 转成的 data URL）。
  @State private favicons: Map<string, string> = new Map();
  // 累积的 url → PNG base64。分片请求会分批回包，这份是**并集**（渲染 map 由它
  // 重建；回包只覆盖自己那一片，不能直接替换）。
  private faviconBase64: Map<string, string> = new Map();
  // 已经问过引擎的 url（含取不到的）。FaviconStore.settled：命中
  // 即不再重复问，避免每次书签刷新都重发同一批请求。
  private faviconAsked: Set<string> = new Set();
  // 本轮等待合批的 url（pending）。
  private faviconQueued: Set<string> = new Set();
  private faviconBatchTimer: number = -1;

  // -- 主页布局 ----------------------------------------------------------------
  @State private custom: HomeCustom = defaultHomeCustom();
  @State @Watch('onWallpaperPresenceChanged') private bgUri: string = '';
  // 壁纸首帧是否已画出（Image.onComplete）。有壁纸时底色透明，
  // 图未解码就显示会透出下层网页；等首帧到位后整层一次性硬切上屏。
  @State private bgPainted: boolean = false;
  private bgPaintTimer: number = -1;
  private bgPaintDelayTimer: number = -1;
  private enterScaleTimer: number = -1;
  // 偏好（含壁纸路径）是否读回。挂载首帧 custom 仍是默认值，
  // 此时放行会误判成「无壁纸」而露出一帧白底主页。
  @State private customLoaded: boolean = false;
  private customLoadTimer: number = -1;
  // 进场缩放，稳态恒 1；壁纸首帧到位后由 HOME_ENTER_SCALE 回落到 1。
  @State private enterScale: number = 1;
  // 是否已有判色结论（缓存命中或解码完成，含"确认没有壁纸/判定失败回落主题"）。
  // 壁纸画出来但还没判色时不下发状态栏，否则会先按默认黑、再翻白地闪一次。
  private toneApplied: boolean = false;
  // 壁纸三带亮度（-1 表示未分析）与各自的「是否偏亮」判定：
  //   · wallpaperTopIsLight    → 状态栏 + 顶栏图标
  //   · wallpaperIsLight       → 中带（Logo/搜索框/书签文字/毛玻璃）
  //   · wallpaperBottomIsLight → 底部 dock 图标
  @State private wallpaperLum: number = -1;
  @State private wallpaperIsLight: boolean = true;
  @State private wallpaperTopIsLight: boolean = true;
  @State private wallpaperBottomIsLight: boolean = true;
  // 顶/底带原始亮度：只进日志和调阈值用，不必参与刷新（不放 @State）。
  private wallpaperTopLum: number = -1;
  private wallpaperBottomLum: number = -1;
  // 上次的判色结论（落盘）。解码异步，挂载期先吃缓存，避免图标色先反再翻正。
  private cachedTonePath: string = '';
  private cachedToneTop: boolean = true;
  private cachedToneMid: boolean = true;
  private cachedToneBottom: boolean = true;
  private cachedToneReady: boolean = false;
  // 亮度分析序号：快速连换壁纸时只让最后一次结果落状态。
  private wallpaperToneSeq: number = 0;
  // 系统状态栏图标色去重（-1 未设 / 0 黑图标 / 1 白图标），避免重复下发窗口属性。
  private lastStatusBarLightIcon: number = -1;
  @State private showSettings: boolean = false;
  // 1.0.97：仅拖动位置滑块时弹窗才转高透（松手恢复近实底）——拖的时候要能
  // 看见后边主页的实时位置变化，静止时保持可读性。
  @State private layoutDragging: boolean = false;
  // 1.0.91 设置-主页设置「自定义主页布局」经此信号请求打开主页布局弹层。
  @StorageLink('auraOpenHomeLayout') @Watch('onOpenHomeLayout') openHomeLayoutSignal: number = 0;
  // 已在主页时按主页键：overlay 这里自增，主页收到后清空搜索框 + 收起联想
  // （Chrome 里在新建标签页按主页键就是重开一个新标签页）。
  @StorageLink('auraHomeReset') @Watch('onHomeResetRequest') homeResetSignal: number = 0;
  // 整页隐藏/显示（AuraShell 的 onPageHide/onPageShow 写）。
  // 卸载时区分「整页被藏」与「被网页顶掉」；页面重新可见时强制重下发状态栏色，
  // 因为系统可能已还原成桌面配色，而本地去重仍记着上次的值。
  @StorageLink('auraShellPageHidden') @Watch('onShellPageShown') shellPageHidden: boolean = false;
  // 主页正在被网页顶掉（AuraShell 在淡出过半时发）：把状态栏交回主题色。
  @StorageLink('auraHomeExitInk') @Watch('onHomeExitInk') homeExitInk: number = 0;
  // 主页搜索框的输入控制器：清空时要连系统键盘一起收掉（stopEditing）。
  private homeInputController: TextInputController = new TextInputController();
  // （1.0.111 移除 auraOpenHomeTile 信号：「网址主页」语义纠正为"设置自定义主页
  // 网址"，表单落在 overlay 层，与主页磁贴/书签无关。）

  // -- 添加/编辑书签弹层 --------------------------------------------------------
  @State private showAddBookmark: boolean = false;
  @State private editingId: string = '';
  @State private newBookmarkTitle: string = '';
  @State private newBookmarkUrl: string = '';

  // -- 长按菜单 ----------------------------------------------------------------
  @State private menuTitle: string = '';
  @State private menuId: string = '';
  @State private menuX: number = 0;
  @State private menuY: number = 0;
  private menuPressX: number = 0;
  private menuPressY: number = 0;

  // 右上角齿轮的果冻按压态（与顶栏圆钮同款 hand-rolled jelly；内容区拿不到
  // 系统 interactive 形变，见 MobileBrowserOverlay.handleRoundTouch）。
  @State private pressedGear: boolean = false;

  @State private query: string = '';
  // 窗宽/窗高（vp）：主页所有锚点都基于它们。
  // 必须是 @State + 跟根节点 onAreaChange 更新；只在 aboutToAppear 读一次
  // display 尺寸，横竖屏切换后会仍按旧值排版。
  @State private windowW: number = 360;
  @State private windowH: number = 780;

  // -- 书签发现链状态 ----------------------------------------------------------
  // step: idle | root | mobile | tiles | creating | done
  private step: string = 'idle';
  private waitingSeq: number = 0;
  private waitingParent: string = '';
  private homeSeq: number = HOME_SEQ_BASE;
  private mobileId: string = '';
  private chainTimer: number = -1;
  private chainRetries: number = 0;
  private refreshTimer: number = -1;
  private migratedChecked: boolean = false;
  // 冷启动缓存（文件）：tiles 与 favicon 各存一份原始 JSON，读到的第一帧即可
  // 渲染（用户报「冷启动书签加载慢」——原本要等 根→手机书签→首页 三次往返）。
  private cacheTilesJson: string = '';
  private cacheFaviconsJson: string = '';
  // 本轮磁贴是否来自「持久化的首页文件夹 id 直取」。直取失败（id 失效：书签被
  // 清空/换机）时不认死理，回退完整发现链重建。
  private fastTilePath: boolean = false;
  // 本轮发现链里是否已建过「首页」文件夹（防列表暂未反映时重复创建）。
  private createdInChain: boolean = false;
  // 「首页」文件夹回包为空时已重试的次数。引擎刚起步（书签模型还没加载完）会先
  // 回一个空列表，若此时把空结果当真，缓存会被写空、磁贴就空了；最多重试
  // EMPTY_TILES_MAX_RETRIES 次，仍空就认（用户确实把书签删光了）。
  private emptyTilesRetries: number = 0;

  aboutToAppear(): void {
    const dsp = display.getDefaultDisplaySync();
    this.windowW = dsp.width / dsp.densityPixels;
    this.windowH = dsp.height / dsp.densityPixels;
    // 请求号跨挂载抬一段：避免回包 JSON 与上一轮逐字节相同（AppStorage 认为没变
    // → @Watch 不触发），磁贴要等超时重试才出现。
    homeSeqBump = HOME_SEQ_BASE + ((homeSeqBump - HOME_SEQ_BASE + 1000) % HOME_SEQ_SPAN);
    this.homeSeq = homeSeqBump;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    // 第一件事：把上次的磁贴与图标画出来（同步读文件，不等引擎回包）。
    this.applyCache(context);
    // 种子解析：@StorageLink 初值不触发 @Watch，挂载时需手动补吃一次。
    this.onFaviconsChanged();
    // 判色缓存与偏好串行读：先拿到缓存，applyBackgroundPath 才能命中它并
    // 跳过主线程上的读文件 + 解码（有壁纸时每次挂载重解码会掉帧）。
    HomePrefs.loadTone(context).then((tone: HomeToneCache): void => {
      this.cachedTonePath = tone.path;
      this.cachedToneTop = tone.top;
      this.cachedToneMid = tone.mid;
      this.cachedToneBottom = tone.bottom;
      this.cachedToneReady = true;
      HomePrefs.loadCustom(context).then((value: HomeCustom): void => {
        this.custom = value;
        this.customLoaded = true;
        this.applyBackgroundPath(value.bgPath);
      });
    });
    // 兜底：偏好读不回来时也不能让主页整层一直不显示（bgLayerReady 第一道门）。
    if (this.customLoadTimer !== -1) {
      clearTimeout(this.customLoadTimer);
    }
    this.customLoadTimer = setTimeout((): void => {
      this.customLoadTimer = -1;
      this.customLoaded = true;
    }, 600);
    // 冷启动快速路径：上次已定位到「首页」文件夹，直接取它一层子节点（**一次
    // 往返**），不必再走 根→手机书签→首页 的三次往返（用户报「冷启动书签加载
    // 慢」）。id 失效时链式超时会回退完整发现（见 armChainTimer）。
    HomePrefs.loadFolderId(context).then((id: string): void => {
      if (id.length === 0) {
        this.refreshBookmarks();
        return;
      }
      this.homeFolderId = id;
      this.fastTilePath = true;
      this.requestChildren(id, 'tiles');
    });
    // 种子：设置面板里点的「自定义主页布局」可能先于 HomeSurface 挂载发出信号，
    // @Watch 初值不触发，挂载时补开一次并消费信号（无痕不打开）。
    HomePrefs.loadSeeded(context).then((seeded: boolean): void => {
      this.homeBookmarksSeeded = seeded;
      this.homeSeedLoaded = true;
      // 偏好可能晚于书签回包：标志位到位后补判一次，避免漏种/误种。
      this.maybeSeedDefaultBookmarks();
    });
    const pendingLayout: number = (AppStorage.get('auraOpenHomeLayout') as number) ?? 0;
    if (pendingLayout > 0 && !this.incognito) {
      this.showSettings = true;
    }
    AppStorage.set('auraOpenHomeLayout', 0);
    // 挂载时不按主题色抢发状态栏：壁纸解码异步，会先在旧网页上闪一下图标色。
    // 下发时机交给壁纸首帧（onComplete）+ syncStatusBarIcons 的门禁。
  }

  aboutToDisappear(): void {
    this.clearChainTimer();
    if (this.refreshTimer !== -1) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
    if (this.faviconBatchTimer !== -1) {
      clearTimeout(this.faviconBatchTimer);
      this.faviconBatchTimer = -1;
    }
    if (this.bgPaintTimer !== -1) {
      clearTimeout(this.bgPaintTimer);
      this.bgPaintTimer = -1;
    }
    if (this.bgPaintDelayTimer !== -1) {
      clearTimeout(this.bgPaintDelayTimer);
      this.bgPaintDelayTimer = -1;
    }
    if (this.enterScaleTimer !== -1) {
      clearTimeout(this.enterScaleTimer);
      this.enterScaleTimer = -1;
    }
    if (this.customLoadTimer !== -1) {
      clearTimeout(this.customLoadTimer);
      this.customLoadTimer = -1;
    }
    // 离开主页时把状态栏图标色交回主题色（网页顶栏是实色）。
    // 整页被藏（切后台/退出）时不改，避免退场动画里闪一下。
    if (AppStorage.get<boolean>('auraShellPageHidden') !== true) {
      this.setStatusBarLightIcon(this.colorScheme === 'dark', true);
    }
    this.lastStatusBarLightIcon = -1;
  }

  // -- 冷启动缓存（HomeCache）---------------------------------------------------

  // 回填上次的磁贴与图标：有就立刻可画，没有就静默跳过。**不动 step**——回包
  // 处理链按自己的节奏推进（inFlight 只看 root/mobile/tiles），缓存只负责
  // 「第一帧别空着」。
  private applyCache(context: common.UIAbilityContext | undefined): void {
    const cached: HomeCacheData = HomeCache.load(context);
    if (cached.tilesJson.length > 0) {
      try {
        const nodes: BookmarkNode[] = JSON.parse(cached.tilesJson) as BookmarkNode[];
        if (nodes.length > 0) {
          this.fullNodes = nodes;
          this.rebuildTiles();
          // 记住「上次这份文件夹不是空的」：后面若收到空回包就能判断那是可疑的
          // 假空（引擎书签模型还没就位），而不是用户把书签删光了。
          this.cacheTilesJson = cached.tilesJson;
        }
      } catch (error) {
      }
    }
    if (cached.faviconsJson.length > 0 && cached.faviconSizeVp === TILE_FAVICON_REQUEST_VP) {
      this.applyFaviconsJson(cached.faviconsJson, false);
    }
  }

  // 写缓存：tiles 与 favicon 各自到达时更新对应的那段，再整体落盘（两个字段
  // 都在内存里，避免读-改-写）。
  private persistCache(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    // favicon 只序列化首页磁贴用到的、且在 serializeFavicons 内按上限截断，
    // 这里直接用其结果：不再因为"总量超限"把整个图标缓存清空（那会让每次
    // 冷启动都先画字母块）。
    const data: HomeCacheData = {
      tilesJson: this.cacheTilesJson,
      faviconsJson: this.cacheFaviconsJson,
      faviconSizeVp: TILE_FAVICON_REQUEST_VP
    };
    HomeCache.save(context, data);
  }

  // -- 背景图 ------------------------------------------------------------------

  private applyBackgroundPath(path: string): void {
    // 路径一变化就作废旧分析，避免上一张图的异步结果覆盖新图的结论。
    this.wallpaperToneSeq++;
    if (this.bgPaintDelayTimer !== -1) {
      clearTimeout(this.bgPaintDelayTimer);
      this.bgPaintDelayTimer = -1;
    }
    if (this.enterScaleTimer !== -1) {
      clearTimeout(this.enterScaleTimer);
      this.enterScaleTimer = -1;
    }
    if (path.length === 0) {
      this.bgUri = '';
      this.enterScale = 1;
      this.resetWallpaperTone();
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        this.bgUri = '';
        this.enterScale = 1;
        this.resetWallpaperTone();
        return;
      }
      this.bgUri = fileUri.getUriFromPath(path);
    } catch (error) {
      this.bgUri = '';
      this.enterScale = 1;
      this.resetWallpaperTone();
      return;
    }
    // 新壁纸还没画出来：关闭整层显示，等 Image 的 onComplete 再打开（见 bgLayerReady）。
    this.enterScale = HOME_ENTER_SCALE;
    this.bgPainted = false;
    if (this.bgPaintTimer !== -1) {
      clearTimeout(this.bgPaintTimer);
    }
    // 兜底：图坏了/onComplete 不来，也不能让主页永远不显示。
    this.bgPaintTimer = setTimeout((): void => {
      this.bgPaintTimer = -1;
      this.openHomeLayer();
    }, 400);
    // 这张图已判过：沿用缓存结论，不读文件、不解码。换图后路径不匹配自动失效。
    if (this.cachedToneReady && this.cachedTonePath === path) {
      this.applyCachedTone();
      return;
    }
    this.analyzeWallpaperTone();
  }

  // 壁纸首帧到位：整层硬切上屏 + 状态栏一次性跟上 + 放大回落。
  // 只有 scale 走 animateTo，透明度不参与动画，避免透明帧。
  private openHomeLayer(): void {
    if (this.bgPainted) {
      return;
    }
    // 先让放大态真正画出一帧再回落：节点刚变可见时没有可插值的上一帧，
    // 同一帧改 scale 会直接落到终值（动画看不到）。
    this.bgPainted = true;
    this.syncStatusBarIcons(true);
    if (this.enterScaleTimer !== -1) {
      clearTimeout(this.enterScaleTimer);
    }
    this.enterScaleTimer = setTimeout((): void => {
      this.enterScaleTimer = -1;
      animateTo({ duration: 200, curve: Curve.EaseOut }, (): void => {
        this.enterScale = 1;
      });
    }, 16);
  }

  // 主页整层能不能显示。三个门：
  // ① 偏好读回来（否则 bgUri 还是空，会被误判成"没壁纸"）；
  // ② 没壁纸/无痕 → 直接显示（纯色底由主题铺，本来就不透明）；
  // ③ 有壁纸 → 等 Image 真正画出首帧（onComplete 后再等一帧，见下）。
  private bgLayerReady(): boolean {
    if (!this.customLoaded) {
      return false;
    }
    if (this.incognito || this.bgUri.length === 0) {
      return true;
    }
    return this.bgPainted;
  }

  private async pickBackground(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    try {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result = await new photoAccessHelper.PhotoViewPicker().select(options);
      const uris: string[] = result.photoUris ?? [];
      if (uris.length === 0) {
        return;
      }
      const dest = `${context.filesDir}/home_bg_${Date.now()}.jpg`;
      const source = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      fs.copyFileSync(source.fd, dest);
      fs.closeSync(source);
      const old = this.custom.bgPath;
      if (old.length > 0 && old !== dest) {
        try {
          fs.unlinkSync(old);
        } catch (error) {
        }
      }
      this.custom.bgPath = dest;
      this.applyBackgroundPath(dest);
      HomePrefs.saveCustom(context, this.custom);
      this.getUIContext().getPromptAction().showToast({ message: '背景已更新', duration: 1500 });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: '选择图片失败', duration: 1500 });
    }
  }

  private removeBackground(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    const old = this.custom.bgPath;
    if (old.length > 0) {
      try {
        fs.unlinkSync(old);
      } catch (error) {
      }
    }
    this.custom.bgPath = '';
    this.bgUri = '';
    // 作废旧分析并收掉尚未结束的进场动画，避免清图后停留在缩放态。
    this.wallpaperToneSeq++;
    this.enterScale = 1;
    if (this.bgPaintTimer !== -1) {
      clearTimeout(this.bgPaintTimer);
      this.bgPaintTimer = -1;
    }
    if (this.bgPaintDelayTimer !== -1) {
      clearTimeout(this.bgPaintDelayTimer);
      this.bgPaintDelayTimer = -1;
    }
    if (this.enterScaleTimer !== -1) {
      clearTimeout(this.enterScaleTimer);
      this.enterScaleTimer = -1;
    }
    this.resetWallpaperTone();
    HomePrefs.saveCustom(context, this.custom);
  }

  // 清除判色结论，前景回落系统深浅色。
  private resetWallpaperTone(): void {
    this.wallpaperLum = -1;
    this.wallpaperTopLum = -1;
    this.wallpaperBottomLum = -1;
    const themeLight: boolean = this.colorScheme === 'light';
    this.wallpaperIsLight = themeLight;
    this.wallpaperTopIsLight = themeLight;
    this.wallpaperBottomIsLight = themeLight;
    // 这是"明确没有判色结论、就用主题色"的收口，标记为已决，允许下发。
    this.toneApplied = true;
    this.publishWallpaperTone();
    // reset 本身就是结论，直接下发，不再过「壁纸未就绪」门禁。
    this.setStatusBarLightIcon(this.colorScheme === 'dark', true);
  }

  // 三带结论一次性广播。状态栏由 HomeSurface 自己消费；顶栏/dock 图标在
  // overlay 层，只能走 AppStorage（跨 struct 调方法会 10505001）。
  private publishWallpaperTone(): void {
    AppStorage.setOrCreate('auraWallpaperIsLight', this.wallpaperIsLight);
    AppStorage.setOrCreate('auraWallpaperTopIsLight', this.wallpaperTopIsLight);
    AppStorage.setOrCreate('auraWallpaperBottomIsLight', this.wallpaperBottomIsLight);
    this.publishWallpaperPresence();
  }

  // 有没有壁纸是「图标该不该按壁纸反色」的前提。状态栏判据里本来就有
  // 这道门禁，但顶栏/dock 图标在 overlay 层，只能靠 AppStorage 同步这个事实。
  private onWallpaperPresenceChanged(): void {
    this.publishWallpaperPresence();
  }

  private publishWallpaperPresence(): void {
    AppStorage.setOrCreate('auraWallpaperPresent',
      this.bgUri.length > 0 && !this.incognito);
  }

  // 把落盘结论套到当前状态（同一张壁纸才认），供挂载期与解码失败时兜底。
  private applyCachedTone(): boolean {
    if (!this.cachedToneReady || this.cachedTonePath.length === 0) {
      return false;
    }
    if (this.incognito || this.custom.bgPath !== this.cachedTonePath) {
      return false;
    }
    this.wallpaperTopIsLight = this.cachedToneTop;
    this.wallpaperIsLight = this.cachedToneMid;
    this.wallpaperBottomIsLight = this.cachedToneBottom;
    this.toneApplied = true;
    this.publishWallpaperTone();
    // 这里不下发状态栏：套缓存可能早于 bgUri 赋值，按主题色发一次会闪。
    // 统一下发时机是「壁纸首帧 + 已有结论」。
    return true;
  }

  // 按 W3C 相对亮度比较黑字/白字对比度，取大者；固定阈值会把中灰壁纸判错。
  private prefersDarkInk(lum: number): boolean {
    if (lum < 0) {
      return this.colorScheme === 'light';
    }
    // 深色模式的暗纱会压暗壁纸：按合成后的底色判定。
    const base: number = this.colorScheme === 'dark'
      ? lum * (1 - TONE_DARK_SCRIM_ALPHA) + TONE_DARK_SCRIM_ALPHA * TONE_DARK_SCRIM_LUM
      : lum;
    const linear: number = base <= 0.03928 ? base / 12.92 : Math.pow((base + 0.055) / 1.055, 2.4);
    const contrastBlack: number = (linear + 0.05) / 0.05;
    const contrastWhite: number = 1.05 / (linear + 0.05);
    return contrastBlack >= contrastWhite;
  }

  // 一条横向带的中位亮度（Rec.709 luma，0~1）。中位数可避免小面积高光抬升均值。
  private bandMedianLum(view: Uint8Array, width: number, y0: number, y1: number): number {
    const rows: number = Math.floor(view.length / (width * 4));
    const start: number = Math.max(0, Math.min(y0, rows));
    const end: number = Math.max(start, Math.min(y1, rows));
    const vals: number[] = [];
    for (let y = start; y < end; y++) {
      const base: number = y * width * 4;
      for (let x = 0; x < width; x++) {
        const i: number = base + x * 4;
        vals.push((0.2126 * view[i] + 0.7152 * view[i + 1] + 0.0722 * view[i + 2]) / 255);
      }
    }
    if (vals.length === 0) {
      return -1;
    }
    vals.sort((a: number, b: number): number => a - b);
    return vals[Math.floor(vals.length / 2)];
  }

  // 解码小缩略图并返回 [top, mid, bottom] 亮度；失败抛出，由调用方换通道或沿用缓存。
  private async measureBands(source: image.ImageSource): Promise<number[]> {
    // 壁纸按 Cover 铺满，可见区是原图居中裁出的一块；分区必须按可见区换算。
    let srcW: number = 0;
    let srcH: number = 0;
    try {
      const meta: image.ImageInfo = await source.getImageInfo();
      srcW = meta.size.width;
      srcH = meta.size.height;
    } catch (error) {
      hilog.warn(0x0000, 'AuraShell', 'wallpaper meta failed: %{public}s', JSON.stringify(error));
    }
    // 按原图比例缩略（不压成正方形）：行号直接对应原图行，分区换算不用再纠偏。
    let thumbH: number = TONE_THUMB_W;
    if (srcW > 0 && srcH > 0) {
      thumbH = Math.max(8, Math.min(256, Math.round(TONE_THUMB_W * srcH / srcW)));
    }
    const pixel = await source.createPixelMap({
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      desiredSize: { width: TONE_THUMB_W, height: thumbH }
    });
    const out: number[] = [];
    try {
      const info = pixel.getImageInfoSync();
      const w: number = info.size.width;
      const h: number = info.size.height;
      const buffer = new ArrayBuffer(w * h * 4);
      await pixel.readPixelsToBuffer(buffer);
      const view = new Uint8Array(buffer);
      // Cover 裁切后的可见行区间：图比屏更「瘦高」时上下裁，按屏宽/屏高换算。
      const screenAspect: number =
        (this.windowW > 0 && this.windowH > 0) ? this.windowW / this.windowH : w / h;
      let visRows: number = h;
      let row0: number = 0;
      if (w / h < screenAspect) {
        visRows = Math.max(1, Math.min(h, Math.round(w / screenAspect)));
        row0 = Math.floor((h - visRows) / 2);
      }
      out.push(this.bandMedianLum(view, w, row0,
        row0 + Math.max(1, Math.ceil(visRows * TONE_TOP_END))));
      out.push(this.bandMedianLum(view, w,
        row0 + Math.floor(visRows * TONE_MID_START),
        row0 + Math.max(1, Math.ceil(visRows * TONE_MID_END))));
      out.push(this.bandMedianLum(view, w,
        row0 + Math.floor(visRows * TONE_BOTTOM_START), row0 + visRows));
      hilog.info(0x0000, 'AuraShell', 'wallpaper thumb %{public}dx%{public}d src=%{public}dx%{public}d vis=%{public}d',
        w, h, srcW, srcH, visRows);
    } finally {
      try {
        pixel.release();
      } catch (error) {
      }
    }
    return out;
  }

  private async analyzeWallpaperTone(): Promise<void> {
    if (this.bgUri.length === 0) {
      this.resetWallpaperTone();
      return;
    }
    const seq: number = this.wallpaperToneSeq;
    let bands: number[] = [];
    // 优先读文件字节解码；URI 作为第二条通道（部分 HEIF/超大图只能走 URI）。
    const path: string = this.custom.bgPath;
    let raw: ArrayBuffer | undefined = undefined;
    let fd: number = -1;
    try {
      fd = fs.openSync(path, fs.OpenMode.READ_ONLY).fd;
      const size: number = fs.statSync(path).size;
      raw = new ArrayBuffer(size);
      fs.readSync(fd, raw);
    } catch (error) {
      raw = undefined;
      hilog.warn(0x0000, 'AuraShell', 'wallpaper read bytes failed: %{public}s', JSON.stringify(error));
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (error) {
        }
      }
    }
    if (raw !== undefined && raw.byteLength > 0) {
      let source: image.ImageSource | undefined = undefined;
      try {
        source = image.createImageSource(raw);
        bands = await this.measureBands(source);
        hilog.info(0x0000, 'AuraShell', 'wallpaper tone decode=bytes bytes=%{public}d', raw.byteLength);
      } catch (error) {
        hilog.warn(0x0000, 'AuraShell', 'wallpaper tone bytes decode failed: %{public}s',
          JSON.stringify(error));
      } finally {
        if (source !== undefined) {
          try {
            source.release();
          } catch (error) {
          }
        }
      }
    }
    if (bands.length < 3 && seq === this.wallpaperToneSeq) {
      let source: image.ImageSource | undefined = undefined;
      try {
        source = image.createImageSource(this.bgUri);
        bands = await this.measureBands(source);
        hilog.info(0x0000, 'AuraShell', 'wallpaper tone decode=uri');
      } catch (error) {
        hilog.warn(0x0000, 'AuraShell', 'wallpaper tone uri decode failed: %{public}s',
          JSON.stringify(error));
      } finally {
        if (source !== undefined) {
          try {
            source.release();
          } catch (error) {
          }
        }
      }
    }
    if (seq !== this.wallpaperToneSeq) {
      return;
    }
    if (bands.length >= 3) {
      const topLum: number = bands[0];
      const midLum: number = bands[1];
      const bottomLum: number = bands[2];
      this.wallpaperTopLum = topLum;
      this.wallpaperLum = midLum;
      this.wallpaperBottomLum = bottomLum;
      this.wallpaperTopIsLight = this.prefersDarkInk(topLum);
      this.wallpaperIsLight = this.prefersDarkInk(midLum);
      this.wallpaperBottomIsLight = this.prefersDarkInk(bottomLum);
      this.toneApplied = true;
      this.publishWallpaperTone();
      // 落盘给下次挂载兜底（换壁纸后 path 不匹配自动失效）。
      this.cachedTonePath = this.custom.bgPath;
      this.cachedToneTop = this.wallpaperTopIsLight;
      this.cachedToneMid = this.wallpaperIsLight;
      this.cachedToneBottom = this.wallpaperBottomIsLight;
      this.cachedToneReady = true;
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
      HomePrefs.saveTone(ctx, {
        path: this.cachedTonePath,
        top: this.cachedToneTop,
        mid: this.cachedToneMid,
        bottom: this.cachedToneBottom
      } as HomeToneCache);
      hilog.info(0x0000, 'AuraShell',
        'wallpaper tone top=%{public}s mid=%{public}s bottom=%{public}s light=%{public}s/%{public}s/%{public}s',
        topLum.toFixed(3), midLum.toFixed(3), bottomLum.toFixed(3),
        this.wallpaperTopIsLight ? 'T' : 'F',
        this.wallpaperIsLight ? 'T' : 'F',
        this.wallpaperBottomIsLight ? 'T' : 'F');
      this.syncStatusBarIcons(true);
      return;
    }
    // 两条通道都失败时沿用上次结论，不回落主题色。
    hilog.warn(0x0000, 'AuraShell', 'wallpaper tone unavailable, cached=%{public}s',
      this.cachedToneReady ? 'yes' : 'no');
    if (this.applyCachedTone()) {
      // 沿用上次结论也算"有结论"：这里补一次下发（applyCachedTone 自己不再发）。
      this.syncStatusBarIcons(true);
    } else {
      this.resetWallpaperTone();
    }
  }

  // 状态栏图标色由窗口属性指定。EntryAbility 按系统深浅色下发；
  // 主页有壁纸时由这里按顶带亮度反色。
  private setStatusBarLightIcon(lightIcon: boolean, force: boolean = false): void {
    const target: number = lightIcon ? 1 : 0;
    if (!force && target === this.lastStatusBarLightIcon) {
      return;
    }
    this.lastStatusBarLightIcon = target;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    const schemeDark: boolean = this.colorScheme === 'dark';
    window.getLastWindow(context).then((win: window.Window): void => {
      try {
        win.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          statusBarContentColor: lightIcon ? '#FFFFFF' : '#000000',
          isStatusBarLightIcon: lightIcon,
          navigationBarColor: '#00000000',
          navigationBarContentColor: schemeDark ? '#FFFFFF' : '#000000',
        });
        hilog.info(0x0000, 'AuraShell', 'status bar icon target=%{public}s',
          lightIcon ? 'white' : 'black');
      } catch (error) {
        hilog.warn(0x0000, 'AuraShell', 'status bar icon color failed: %{public}s',
          JSON.stringify(error));
      }
    }).catch((error: Error): void => {
      hilog.warn(0x0000, 'AuraShell', 'status bar window lookup failed: %{public}s',
        JSON.stringify(error));
    });
  }

  private syncStatusBarIcons(force: boolean = false): void {
    // 无痕状态可能变化而 bgUri 不变，补一次下发覆盖这条路径。
    this.publishWallpaperPresence();
    // 网页态（主页层不可见）一律按主题色：顶栏是实色，不跟壁纸走。
    // 嵌入态（桌面 chrome 盖住状态栏那一条）同样不看壁纸：标签条是不透明实底。
    const useWallpaper: boolean = this.homeVisible && !this.embedded &&
      this.bgUri.length > 0 && !this.incognito;
    // 壁纸未画出/未判色时不下发：此刻画面可能仍是旧网页或偏好还没读回。
    // custom.bgPath 也算「有壁纸」，避免 bgUri 尚未赋值时按主题色抢发。
    const wallpaperPending: boolean = !this.incognito &&
      (this.bgUri.length > 0 || this.custom.bgPath.length > 0);
    if (wallpaperPending && (!this.bgPainted || !this.toneApplied)) {
      return;
    }
    // 状态栏只压在壁纸顶带上，认 wallpaperTopIsLight。
    this.setStatusBarLightIcon(useWallpaper ? !this.wallpaperTopIsLight : (this.colorScheme === 'dark'),
      force);
  }

  private onColorSchemeChanged(): void {
    this.syncStatusBarIcons(true);
  }

  // 页面重新可见：状态栏可能已被系统按桌面重设过，无条件重下一次（force 绕过去重）。
  // 重下发的取值仍由 syncStatusBarIcons 按主页是否可见决定。
  private onShellPageShown(): void {
    if (this.shellPageHidden) {
      return;
    }
    this.lastStatusBarLightIcon = -1;
    this.syncStatusBarIcons(true);
  }

  // 回到主页补一次反色：主页层常驻后壁纸首帧不再触发 openHomeLayer，
  // 而离场时状态栏已交还主题色。离场方向不在这里处理，仍由 auraHomeExitInk
  // 的 120ms 交还时序负责，避免壁纸上提前闪黑图标。
  private onHomeVisibleChanged(): void {
    if (this.homeVisible) {
      this.syncStatusBarIcons(true);
    }
  }

  // 主页被网页顶掉时把状态栏交回主题色，必须在网页顶栏上屏前完成，
  // 否则白图标在浅色顶栏上会消失。
  private onHomeExitInk(): void {
    if (this.incognito) {
      return;
    }
    this.setStatusBarLightIcon(this.colorScheme === 'dark', true);
  }

  // 有壁纸时按中带亮度反色，无壁纸/无痕回落系统色；顶带、底带另有消费者。
  private homeFgText(): ResourceColor {
    if (this.bgUri.length > 0 && !this.incognito) {
      return this.wallpaperIsLight ? '#202124' : '#F5F5F5';
    }
    return $r('app.color.text_primary');
  }

  private homeFgTextSecondary(): ResourceColor {
    if (this.bgUri.length > 0 && !this.incognito) {
      return this.wallpaperIsLight ? '#5F6368' : '#B7BAC0';
    }
    return $r('app.color.text_secondary');
  }

  // 书签小字直接压在壁纸上、底下没有托盘：给足黑白对比，并叠反向描边阴影抗花壁纸。
  private homeTileLabel(): ResourceColor {
    if (this.bgUri.length > 0 && !this.incognito) {
      return this.wallpaperIsLight ? '#2B2F33' : '#FFFFFF';
    }
    return $r('app.color.text_secondary');
  }

  private homeTileLabelShadow(): ShadowOptions {
    if (this.bgUri.length > 0 && !this.incognito) {
      // 亮底给浅色描边（防深色笔画糊进暗部），暗底给深色投影（防亮部吃字）。
      return this.wallpaperIsLight
        ? { radius: 6, color: '#66FFFFFF', offsetX: 0, offsetY: 1 }
        : { radius: 6, color: '#73000000', offsetX: 0, offsetY: 1 };
    }
    return { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 };
  }

  // Logo 深/浅两版只差星球本体。有壁纸时按中带亮度显式选版，
  // 不走 resources/dark 的主题自动切换（深壁纸配浅主题会糊进背景）。
  private homeLogoRes(): Resource {
    if (this.bgUri.length > 0 && !this.incognito) {
      return this.wallpaperIsLight
        ? $r('app.media.orbira_logo_onlight')
        : $r('app.media.orbira_logo_ondark');
    }
    return $r('app.media.orbira_logo');
  }

  // 有壁纸时用低不透明度+高模糊的真磨砂玻璃；无壁纸回落系统 glass_tint。
  private homeGlass(): ResourceColor {
    if (this.bgUri.length > 0 && !this.incognito) {
      return this.wallpaperIsLight ? '#73F7F7F8' : '#7329292C';
    }
    return $r('app.color.glass_tint');
  }

  private persistCustom(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    HomePrefs.saveCustom(context, this.custom);
  }

  // -- 书签发现链：根 -> 手机书签 -> 「首页」文件夹（缺则建）-> 磁贴 -------------

  private nextSeq(): number {
    this.homeSeq += 1;
    return this.homeSeq;
  }

  private clearChainTimer(): void {
    if (this.chainTimer !== -1) {
      clearTimeout(this.chainTimer);
      this.chainTimer = -1;
    }
  }

  private armChainTimer(): void {
    this.clearChainTimer();
    this.chainTimer = setTimeout((): void => {
      this.chainTimer = -1;
      if (this.chainRetries >= MAX_CHAIN_RETRIES) {
        // 直取持久化的「首页」文件夹 id 失败（id 失效：书签被清空 / 换机 / 重装）：
        // 不认死理，回到完整发现链重建。
        if (this.fastTilePath && this.step === 'tiles') {
          this.fastTilePath = false;
          this.chainRetries = 0;
          this.emptyTilesRetries = 0;
          this.homeFolderId = '';
          this.requestRoot();
          return;
        }
        this.tilesError = true;
        this.step = 'done';
        return;
      }
      this.chainRetries += 1;
      if (this.step === 'root') {
        this.requestRoot();
      } else if (this.step === 'mobile' && this.mobileId.length > 0) {
        this.requestChildren(this.mobileId, 'mobile');
      } else if (this.step === 'tiles' && this.homeFolderId.length > 0) {
        this.requestChildren(this.homeFolderId, 'tiles');
      } else if (this.step === 'creating' && this.mobileId.length > 0) {
        this.step = 'mobile';
        this.requestChildren(this.mobileId, 'mobile');
      }
    }, CHAIN_TIMEOUT_MS);
  }

  /** 全链重启（进入主页 / 手动重试）。 */
  private refreshBookmarks(): void {
    this.chainRetries = 0;
    this.tilesError = false;
    this.createdInChain = false;
    // 新一轮发现链，空回包的重试预算也要归零；否则上一轮残留到上限后，
    // 这一轮的空回包会被直接接受，不再等引擎把书签模型读完。
    this.emptyTilesRetries = 0;
    // 只要已知「首页」文件夹 id 就直取（一次往返）——不再要求 step === 'done'：
    // 书签在别处被改动后的刷新、以及冷启动，走的都是这条最短路径。
    if (this.homeFolderId.length > 0) {
      this.requestChildren(this.homeFolderId, 'tiles');
      return;
    }
    this.requestRoot();
  }

  private requestRoot(): void {
    this.step = 'root';
    this.waitingParent = '';
    this.waitingSeq = this.nextSeq();
    this.onCommand({ command: 'getBookmarks', requestId: this.waitingSeq });
    this.armChainTimer();
  }

  private requestChildren(parentId: string, step: string): void {
    this.step = step;
    this.waitingParent = parentId;
    this.waitingSeq = this.nextSeq();
    this.onCommand({ command: 'getBookmarks', requestId: this.waitingSeq, parentId: parentId });
    this.armChainTimer();
  }

  private onBookmarkListChanged(): void {
    if (this.bookmarkListJson.length === 0) {
      return;
    }
    const inFlight = this.step === 'root' || this.step === 'mobile' || this.step === 'tiles';
    if (!inFlight) {
      return;
    }
    // 便宜的先做：主页与书签面板共用 'auraPanelBookmarkList'，面板的每次操作
    // （翻页/搜索/编辑）也会把整份书签树推过来。先按 requestId 段粗筛，不是主页
    // 的回包直接丢——别为它解析整棵树（书签多时 JSON.parse 是毫秒级开销）。
    // 主页序号段 700000-899999，引擎序列化无空格，两种写法都兼容；命中的仍会
    // 在解析后按 reqId 再校验一次，这里只做便宜的门。
    if (this.bookmarkListJson.indexOf('"requestId":7') < 0 &&
        this.bookmarkListJson.indexOf('"requestId": 7') < 0) {
      return;
    }
    let payload: BookmarkListPayload;
    try {
      payload = JSON.parse(this.bookmarkListJson) as BookmarkListPayload;
    } catch (error) {
      return;
    }
    const reqId = payload.requestId ?? -1;
    // 只认主页序号段的回包；宽松匹配（序号一致，或父层一致）——防两条回包挤在
    // 同一帧、@Watch 只见后一条（书签面板同时刷新时）而漏掉自己的。
    if (reqId < HOME_SEQ_BASE) {
      return;
    }
    if (reqId !== this.waitingSeq && (payload.parentId ?? '') !== this.waitingParent) {
      return;
    }
    this.clearChainTimer();
    const nodes: BookmarkNode[] = payload.nodes ?? [];

    if (this.step === 'root') {
      let mobile = '';
      for (const node of nodes) {
        if (node.rootType === 'mobile') {
          mobile = node.id;
          break;
        }
      }
      if (mobile.length === 0) {
        this.failChainStep();
        return;
      }
      this.mobileId = mobile;
      this.requestChildren(mobile, 'mobile');
      return;
    }

    if (this.step === 'mobile') {
      let folderId = '';
      for (const node of nodes) {
        if (node.type === 'folder' &&
          (node.title === HOME_FOLDER_TITLE || node.id === this.homeFolderId)) {
          folderId = node.id;
          break;
        }
      }
      if (folderId.length === 0) {
        // 本轮已建过一次还是没找到：收尾报错，避免重复创建文件夹。
        if (this.createdInChain) {
          this.tilesError = true;
          this.step = 'done';
          return;
        }
        // 文件夹还没建：建一个，等 bookmarkCreated 事件后回本层找 id。
        this.createdInChain = true;
        this.step = 'creating';
        this.waitingParent = this.mobileId;
        this.waitingSeq = this.nextSeq();
        this.onCommand({
          command: 'createBookmarkFolder',
          parentId: this.mobileId,
          title: HOME_FOLDER_TITLE,
          requestId: this.waitingSeq
        });
        this.armChainTimer();
        return;
      }
      this.setHomeFolder(folderId);
      this.requestChildren(folderId, 'tiles');
      return;
    }

    if (this.step === 'tiles') {
      // 可疑的空回包：上次的「首页」文件夹不是空的（缓存里还有内容），引擎多半
      // 只是书签模型还没加载完就先回了空列表。别当真——不落缓存、不收尾，等
      // 超时重发（最多 EMPTY_TILES_MAX_RETRIES 次，仍空才认）。
      if (nodes.length === 0 && this.cacheTilesJson.length > 0 &&
          this.emptyTilesRetries < EMPTY_TILES_MAX_RETRIES) {
        this.emptyTilesRetries += 1;
        hilog.info(0x0000, 'HomeSurface',
          'empty tiles reply, retry %{public}d/%{public}d (cache %{public}d chars)',
          this.emptyTilesRetries, EMPTY_TILES_MAX_RETRIES, this.cacheTilesJson.length);
        this.armChainTimer();
        return;
      }
      if (nodes.length === 0 && this.cacheTilesJson.length > 0) {
        hilog.warn(0x0000, 'HomeSurface',
          'empty tiles accepted after %{public}d retries; cache kept',
          this.emptyTilesRetries);
      }
      this.emptyTilesRetries = 0;
      this.fullNodes = nodes;
      this.rebuildTiles();
      this.step = 'done';
      this.fastTilePath = false;
      // 落缓存：写的是**全量子节点**（与 fullNodes 一致），下次冷启动第一帧
      // 就能画出磁贴，且排序换算照样可用。
      // 空回包且缓存非空时不覆盖：那可能是引擎未就绪的假空，写成 [] 会把下次
      // 冷启动的第一帧也变空，形成「越空越空」的循环。
      if (nodes.length > 0 || this.cacheTilesJson.length === 0) {
        this.cacheTilesJson = JSON.stringify(nodes);
      }
      this.persistCache();
      this.requestFavicons();
      this.maybeMigrate();
      // 首次运行且首页文件夹为空：种入谷歌/必应/百度/GitHub 四个默认书签。
      this.maybeSeedDefaultBookmarks();
      return;
    }
  }

  // 主页默认书签：首次运行把谷歌/必应/百度/GitHub 补进「首页」文件夹——按归一化 URL
  // 去重（已有同名站点跳过，不产生重复磁贴），补完置 seeded 标志位，用户之后删掉
  // 也不会被反复补回。
  private maybeSeedDefaultBookmarks(): void {
    // 偏好没读回来之前不种：回包先到时 homeBookmarksSeeded 还是 false，
    // 会被当成"没种过"而把用户删掉的默认站补回来。
    if (!this.homeSeedLoaded || this.homeBookmarksSeeded || this.homeFolderId.length === 0) {
      return;
    }
    const existing: string[] = [];
    for (const node of this.fullNodes) {
      if (node.type === 'url') {
        existing.push(seedKey(node.url ?? ''));
      }
    }
    const defaults: HomeSeedSite[] = [
      { title: '谷歌', url: 'https://www.google.com' },
      { title: '必应', url: 'https://www.bing.com' },
      { title: '百度', url: 'https://www.baidu.com' },
      { title: 'GitHub', url: 'https://github.com' }
    ];
    for (const site of defaults) {
      if (existing.indexOf(seedKey(site.url)) >= 0) {
        continue;
      }
      this.onCommand({
        command: 'addBookmark',
        url: site.url,
        title: site.title,
        parentId: this.homeFolderId,
        requestId: this.nextSeq()
      });
    }
    this.homeBookmarksSeeded = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    HomePrefs.saveSeeded(context, true);
  }

  /** 从全量子节点里取 url 磁贴（保持引擎回包顺序 = 文件夹位次）。 */
  private rebuildTiles(): void {
    const urls: BookmarkNode[] = [];
    for (const node of this.fullNodes) {
      if (node.type === 'url' && (node.url ?? '').length > 0) {
        urls.push(node);
      }
    }
    this.tiles = urls;
  }

  /**
   * 上移/下移磁贴：走引擎 moveBookmarks 在**同一文件夹**内换位次（引擎原生
   * 支持插入 index，越界自动钳制）。注意 index 是「全部子节点」的位次——
   * 子文件夹也占位，所以目标位次要按全量列表里相邻 url 节点的落点来算。
   * 本地先乐观换序（即时反馈），引擎 bookmarksChanged 回来后再校正。
   */
  private moveTile(id: string, dir: number): void {
    if (this.homeFolderId.length === 0 || this.fullNodes.length === 0) {
      return;
    }
    let idx = -1;
    for (let i = 0; i < this.fullNodes.length; i++) {
      if (this.fullNodes[i].id === id) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      return;
    }
    let j = idx + dir;
    while (j >= 0 && j < this.fullNodes.length && this.fullNodes[j].type !== 'url') {
      j += dir;
    }
    if (j < 0 || j >= this.fullNodes.length) {
      return;
    }
    const target = j;
    const nodes = this.fullNodes.slice();
    const moved = nodes[idx];
    nodes.splice(idx, 1);
    nodes.splice(target, 0, moved);
    this.fullNodes = nodes;
    this.rebuildTiles();
    // 引擎 moveBookmarks 走 Chromium BookmarkModel::Move 语义：同父、目标 index
    // 大于源 index 时引擎会把 index 自动 -1（先移除源再插入）。所以「下移」要
    // 补 +1 抵消，否则下移会被引擎当成原位、等于没动（这就是「下移不起作用」的根因）；
    // 「上移」送相邻 index 即可。本地已先乐观换序，引擎刷新后校正。
    const sendIndex = dir > 0 ? target + 1 : target;
    this.onCommand({
      command: 'moveBookmarks',
      ids: [id],
      parentId: this.homeFolderId,
      index: sendIndex,
      requestId: this.nextSeq()
    });
  }

  private failChainStep(): void {
    if (this.chainRetries >= MAX_CHAIN_RETRIES) {
      this.tilesError = true;
      this.step = 'done';
      return;
    }
    this.chainRetries += 1;
    this.requestRoot();
  }

  private setHomeFolder(id: string): void {
    this.homeFolderId = id;
    AppStorage.setOrCreate('auraHomeFolderId', id);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    HomePrefs.saveFolderId(context, id);
  }

  /** 面板在别处动了书签：轻量刷新磁贴（防抖合流多次变更）。 */
  private onPanelEvent(): void {
    if (this.panelEventJson.length === 0) {
      return;
    }
    let kind = '';
    try {
      kind = (JSON.parse(this.panelEventJson) as PanelEventPayload).kind ?? '';
    } catch (error) {
      return;
    }
    if (kind !== 'bookmarkCreated' && kind !== 'bookmarksChanged') {
      return;
    }
    if (this.step === 'creating') {
      // 刚建的「首页」文件夹就绪：回手机书签层把它找出来。
      if (this.mobileId.length > 0) {
        this.requestChildren(this.mobileId, 'mobile');
      } else {
        this.requestRoot();
      }
      return;
    }
    if (this.step !== 'done' && this.step !== 'idle') {
      return;
    }
    if (this.refreshTimer !== -1) {
      clearTimeout(this.refreshTimer);
    }
    this.refreshTimer = setTimeout((): void => {
      this.refreshTimer = -1;
      if (this.homeFolderId.length > 0) {
        this.requestChildren(this.homeFolderId, 'tiles');
      } else {
        this.requestRoot();
      }
    }, REFRESH_DEBOUNCE_MS);
  }

  // -- 老快捷方式一次性迁入「首页」文件夹 ---------------------------------------

  private maybeMigrate(): void {
    if (this.migratedChecked) {
      return;
    }
    this.migratedChecked = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    HomePrefs.loadMigrated(context).then((done: boolean): void => {
      if (done) {
        return;
      }
      HomeShortcuts.load(context).then((olds: HomeShortcut[]): void => {
        const have: Set<string> = new Set();
        for (const tile of this.tiles) {
          have.add(normUrl(tile.url ?? ''));
        }
        let added = 0;
        for (const item of olds) {
          if (item.url.length === 0 || have.has(normUrl(item.url))) {
            continue;
          }
          have.add(normUrl(item.url));
          this.onCommand({
            command: 'addBookmark',
            url: item.url,
            title: item.title,
            parentId: this.homeFolderId,
            requestId: this.nextSeq()
          });
          added += 1;
        }
        HomePrefs.saveMigrated(context, true);
        if (added > 0) {
          this.getUIContext().getPromptAction()
            .showToast({ message: `已将 ${added} 个原快捷方式迁入书签「首页」`, duration: 2000 });
        }
      });
    });
  }

  // -- 图标 --------------------------------------------------------------------
  //
  // 取图标这一层对齐 FaviconStore 的做法：
  //   ① 只问 http(s)（want() 里那道门）；
  //   ② settled / pending 两个集合去重，命中过就不再问；
  //   ③ 攒一拍合批（BATCH_DELAY_MS）后**一次**发出去，回包后统一派发。
  // 我们的差异：settled 只在内存里，冷启动的第一帧由文件缓存（HomeCache）兜。

  private requestFavicons(): void {
    if (this.tiles.length === 0) {
      return;
    }
    // 上一轮没取到的 url 放回队列再问一次（命中的永不重问）。没有这一步的话，
    // 「先建书签、后访问站点」的磁贴要等重启才补上图标。
    const misses: string[] = [];
    this.faviconAsked.forEach((url: string): void => {
      if (!this.faviconBase64.has(url)) {
        misses.push(url);
      }
    });
    for (const url of misses) {
      this.faviconAsked.delete(url);
    }
    let queued = 0;
    for (const node of this.tiles) {
      const url = (node.url ?? '').trim();
      if (!isFetchableUrl(url)) {
        continue;
      }
      if (this.faviconAsked.has(url) || this.faviconQueued.has(url)) {
        continue;
      }
      this.faviconQueued.add(url);
      queued += 1;
    }
    if (queued === 0 || this.faviconBatchTimer !== -1) {
      return;
    }
    this.faviconBatchTimer = setTimeout((): void => {
      this.faviconBatchTimer = -1;
      this.flushFavicons();
    }, FAVICON_BATCH_MS);
  }

  // 把这一拍攒下的 url 发出去；超过引擎的单次上限（100）就分片，回包累积。
  private flushFavicons(): void {
    const urls: string[] = Array.from(this.faviconQueued);
    this.faviconQueued.clear();
    if (urls.length === 0) {
      return;
    }
    // 先记 settled：命中不命中都只问一次（引擎只回命中的，未回的就是没有）。
    for (const url of urls) {
      this.faviconAsked.add(url);
    }
    for (let start = 0; start < urls.length; start += FAVICON_BATCH_MAX) {
      const slice = urls.slice(start, start + FAVICON_BATCH_MAX);
      this.onCommand({
        command: 'getFavicons', requestId: this.nextSeq(), urls: slice,
        sizeVp: TILE_FAVICON_REQUEST_VP
      });
    }
  }

  private onFaviconsChanged(): void {
    // 引擎回包：解析 + 落缓存（下次冷启动第一帧就能画出来）。
    this.applyFaviconsJson(this.faviconsJson, true);
  }

  private applyFaviconsJson(json: string, persist: boolean): void {
    if (json.length === 0) {
      return;
    }
    try {
      const items: FaviconImage[] = JSON.parse(json) as FaviconImage[];
      for (const item of items) {
        if (item.url && item.url.length > 0 && item.pngBase64 && item.pngBase64.length > 0) {
          this.faviconBase64.set(item.url, item.pngBase64);
        }
      }
      this.rebuildFavicons();
      if (persist) {
        this.cacheFaviconsJson = this.serializeFavicons();
        this.persistCache();
      }
    } catch (error) {
    }
  }

  // 累积的 base64 → 绘制用的 data URL map（赋值新对象才会触发重绘）。
  private rebuildFavicons(): void {
    const map: Map<string, string> = new Map();
    this.faviconBase64.forEach((base64: string, url: string): void => {
      map.set(url, `data:image/png;base64,${base64}`);
    });
    this.favicons = map;
  }

  // 序列化冷启动要用的 favicon。只保留**当前首页磁贴**用到的 url：
  // 引擎回包会把面板/历史问过的图标也并进 faviconBase64，全量落盘很容易超
  // 上限而被整个丢弃（表现为每次冷启动都先出字母块、图标才慢慢到）。磁贴
  // 才是首帧要命中的目标，按磁贴顺序写入并在上限处截断，剩余图标下次联网
  // 会自动补回，不影响正确性。
  private serializeFavicons(): string {
    const wanted: Set<string> = new Set();
    for (const node of this.fullNodes) {
      if (node.type === 'url') {
        const url: string = node.url ?? '';
        if (url.length > 0) {
          wanted.add(url);
        }
      }
    }
    const items: FaviconImage[] = [];
    let chars: number = 2; // "[]"
    let truncated: boolean = false;
    wanted.forEach((url: string): void => {
      if (truncated) {
        return;
      }
      const base64: string | undefined = this.faviconBase64.get(url);
      if (base64 === undefined || base64.length === 0) {
        return;
      }
      const item: FaviconImage = { url: url, pngBase64: base64 };
      const entryChars: number = JSON.stringify(item).length + 1; // +1 = 逗号
      if (chars + entryChars > MAX_CACHE_FAVICONS_CHARS) {
        truncated = true;
        return;
      }
      items.push(item);
      chars += entryChars;
    });
    return JSON.stringify(items);
  }

  private faviconFor(node: BookmarkNode): string {
    const url = node.url ?? '';
    if (url.length > 0) {
      const value = this.favicons.get(url);
      if (value) {
        return value;
      }
    }
    return '';
  }

  // -- 行为 --------------------------------------------------------------------

  private submitQuery(): void {
    const target = normalizeAddress(this.query);
    this.query = '';
    this.clearSuggest();
    if (target.length > 0) {
      this.onCommand({ command: 'navigate', url: target });
    }
  }

  // 主页搜索框联想：输入即问引擎（与地址栏同一条 autocomplete 命令）。
  // 只有非空输入才发，130ms 防抖——和地址栏一样的手感。
  private requestSuggest(text: string): void {
    if (this.suggestTimer !== -1) {
      clearTimeout(this.suggestTimer);
      this.suggestTimer = -1;
    }
    if (text.trim().length === 0) {
      this.suggestPending = -1;
      this.suggestItems = [];
      return;
    }
    // 新输入 = 新的一轮：恢复到「还没上屏」，这样引擎第一包能立刻把卡弹出来。
    this.suggestShownFor = -1;
    this.suggestTimer = setTimeout((): void => {
      this.suggestTimer = -1;
      this.suggestSeq += 1;
      if (this.suggestSeq > HOME_SUGGEST_SEQ_BASE + HOME_SEQ_SPAN) {
        this.suggestSeq = HOME_SUGGEST_SEQ_BASE + 1;
      }
      this.suggestPending = this.suggestSeq;
      this.onCommand({ command: 'autocomplete', requestId: this.suggestSeq, text: text });
      // 1.0.4：防抖 130 → 90ms。上游还有 130ms 才发请求，加上引擎各 provider
      // 耗时，用户感知就是「慢半拍」；90ms 仍足够合并连打。
    }, 90);
  }

  // 引擎回包：只认最新 requestId（旧包丢弃）。
  private onHomeAutocomplete(): void {
    if (this.autocompleteJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.autocompleteJson) as HomeAutocompletePayload;
      if (payload.requestId !== this.suggestPending) {
        return;
      }
      const items: AutocompleteItem[] = [];
      for (const parsed of payload.items ?? []) {
        items.push({
          type: parsed.type,
          title: typeof parsed.title === 'string' ? parsed.title : '',
          url: typeof parsed.url === 'string' ? parsed.url : '',
          description: typeof parsed.description === 'string' ? parsed.description : ''
        } as AutocompleteItem);
      }
      // 引擎对一次输入会推 2~5 包（每个 provider 各推一包，done 只在最后那包
      // 为 true）。全等 done 才有内容 → 弹窗得等最慢的 provider（搜索建议要走
      // 网络，几百毫秒），用户感知就是「弹出来慢」。
      // 所以分两段：**首包立刻上屏**（本地 provider 最快，先把卡弹出来），
      // 后续包不直接重建，攒最新一份 120ms 合并刷一次；done 到了立即刷。
      // 空包一律不落 UI，包括「done=true 但结果为空」那种：引擎的
      // AutocompleteController::Start() 会先 Stop 上一次请求，Stop 同步冲出一包
      // 「空结果 + done=true」，且带着**新**的 requestId。照单清空就会把卡片刷成
      // 只剩一行兜底行（观感「偶尔不展开」）。保留上一份列表更稳。
      if (items.length === 0) {
        return;
      }
      if (payload.done === true) {
        this.cancelSuggestFlush();
        this.suggestItems = items;
        this.suggestShownFor = payload.requestId;
        return;
      }
      if (this.suggestShownFor !== payload.requestId) {
        this.cancelSuggestFlush();
        this.suggestItems = items;
        this.suggestShownFor = payload.requestId;
        return;
      }
      this.suggestQueued = items;
      if (this.suggestFlushTimer !== -1) {
        return;
      }
      this.suggestFlushTimer = setTimeout((): void => {
        this.suggestFlushTimer = -1;
        if (this.suggestQueued.length > 0) {
          this.suggestItems = this.suggestQueued;
          this.suggestQueued = [];
        }
      }, 120);
    } catch (error) {
    }
  }

  private clearSuggest(): void {
    if (this.suggestTimer !== -1) {
      clearTimeout(this.suggestTimer);
      this.suggestTimer = -1;
    }
    this.cancelSuggestFlush();
    this.suggestPending = -1;
    this.suggestShownFor = -1;
    this.suggestItems = [];
  }

  // 取消待合并的刷新（新请求 / 收起列表时调用，避免旧包把新结果盖回去）。
  private cancelSuggestFlush(): void {
    if (this.suggestFlushTimer !== -1) {
      clearTimeout(this.suggestFlushTimer);
      this.suggestFlushTimer = -1;
    }
    this.suggestQueued = [];
  }

  private suggestActive(): boolean {
    return this.query.trim().length > 0 && this.suggestItems.length > 0;
  }

  private openSuggestion(item: AutocompleteItem): void {
    const target: string = item.url.length > 0 ? item.url : normalizeAddress(item.title);
    this.clearSuggest();
    this.query = '';
    if (target.length > 0) {
      this.onCommand({ command: 'navigate', url: target });
    }
  }

  @Builder
  private HomeSuggestCard() {
    Column() {
      ForEach(this.suggestItems, (item: AutocompleteItem, index: number) => {
        Column() {
          Row({ space: 10 }) {
            Image(item.type === 'search' ?
              $r('app.media.chromium_search') : $r('app.media.aura_clock'))
              .width(16)
              .height(16)
              .fillColor($r('app.color.icon_secondary'))
            Column({ space: 2 }) {
              Text(item.title.length > 0 ? item.title : item.url)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              if (item.url.length > 0) {
                Text(item.url)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .onClick((): void => {
            this.openSuggestion(item);
          })

          if (index < this.suggestItems.length - 1) {
            Divider()
              .color($r('app.color.divider'))
              .margin({ left: 40 })
          }
        }
        .width('100%')
      }, (item: AutocompleteItem, index: number): string =>
        `${item.type}|${item.url}|${item.title}`)
    }
    .width('100%')
    .borderRadius(16)
    .backgroundColor($r('app.color.card_background'))
    .clip(true)
    .shadow({ radius: 10, color: $r('app.color.shadow'), offsetY: 4 })
    .margin({ top: 8 })
    // 轻微淡入：卡片是随首个回包插入的，硬切会像"闪一下"。
    .transition(TransitionEffect.OPACITY.animation({ duration: 110, curve: Curve.Friction }))
  }

  private openBookmark(node: BookmarkNode): void {
    const url = node.url ?? '';
    if (url.length > 0) {
      this.onCommand({ command: 'navigate', url: url });
    }
  }

  private async startScan(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    const value = await ScanService.scanOnce(context);
    if (value.length > 0) {
      this.onCommand({ command: 'navigate', url: normalizeAddress(value) });
    }
  }

  // 右上角齿轮的果冻按压：按下快收 0.85，松手用欠阻尼弹簧振荡回弹。
  // 参数比顶栏圆钮（0.3/0.7）更小阻尼 —— 用户要「q 弹、按住拉变形」：
  // 官方 springMotion(response, dampingFraction)，0.3/0.5=多次振荡很强、
  // 0.5/0.7=适度自然，往小调振荡越多越弹（1.0.83 调为 0.25/0.55）。
  private handleGearTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      animateTo({ duration: 80, curve: Curve.FastOutSlowIn }, (): void => {
        this.pressedGear = true;
      });
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      animateTo({ curve: curves.springMotion(0.25, 0.55) }, (): void => {
        this.pressedGear = false;
      });
    }
  }

  private gearScale(): ScaleOptions {
    const s: number = this.pressedGear ? 0.85 : 1;
    return { x: s, y: s };
  }

  // -- 长按菜单 ----------------------------------------------------------------

  private showBookmarkActions(node: BookmarkNode): void {
    const cardW = MENU_CARD_VP;
    this.menuX = Math.min(Math.max(this.menuPressX - cardW / 2, 12),
      Math.max(12, this.windowW - cardW - 12));
    this.menuY = Math.min(Math.max(this.menuPressY + 8, 12), Math.max(12, this.windowH - MENU_CARD_H - 96));
    this.menuTitle = node.title;
    this.menuId = node.id;
  }

  private beginEditFromMenu(): void {
    const id = this.menuId;
    this.menuId = '';
    this.menuTitle = '';
    let title = '';
    let url = '';
    for (const node of this.tiles) {
      if (node.id === id) {
        title = node.title;
        url = node.url ?? '';
        break;
      }
    }
    this.editingId = id;
    this.newBookmarkTitle = title;
    this.newBookmarkUrl = url;
    this.showAddBookmark = true;
  }

  private deleteFromMenu(): void {
    const id = this.menuId;
    const title = this.menuTitle;
    this.menuId = '';
    this.menuTitle = '';
    if (id.length === 0) {
      return;
    }
    this.getUIContext().getPromptAction().showDialog({
      title: '删除书签',
      message: title.length > 0 ? title : '该网址',
      buttons: [
        { text: '取消', color: '#5F6368' },
        { text: '删除', color: '#E24B4A' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index !== 1) {
        return;
      }
      this.onCommand({ command: 'removeBookmarks', ids: [id], requestId: this.nextSeq() });
      this.getUIContext().getPromptAction().showToast({ message: '已删除', duration: 1500 });
    }).catch((error: Error): void => {
    });
  }

  private closeBookmarkForm(): void {
    this.showAddBookmark = false;
    this.editingId = '';
    this.newBookmarkTitle = '';
    this.newBookmarkUrl = '';
  }

  private confirmBookmarkForm(): void {
    const url = normalizeAddress(this.newBookmarkUrl.trim());
    if (url.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请输入网址', duration: 1500 });
      return;
    }
    const title = this.newBookmarkTitle.trim();
    const editing = this.editingId.length > 0;
    if (editing) {
      this.onCommand({
        command: 'updateBookmark',
        id: this.editingId,
        title: title,
        url: url,
        requestId: this.nextSeq()
      });
    } else {
      this.onCommand({
        command: 'addBookmark',
        url: url,
        title: title,
        parentId: this.homeFolderId,
        requestId: this.nextSeq()
      });
    }
    this.closeBookmarkForm();
    this.getUIContext().getPromptAction()
      .showToast({ message: editing ? '已保存' : '已添加到主页', duration: 1500 });
  }

  // 书签磁贴：圆角毛玻璃托盘 + favicon（缺失时同尺寸首字母色块）+ 标题。
  // 单击打开，长按编辑/删除。站点图标常只有 16/32px，画满 46vp 会糊，
  // 故只画 TILE_FAVICON_VP；占位色块同几何，保证外边缘一致。
  @Builder
  private BookmarkTile(node: BookmarkNode) {
    Column({ space: 7 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.faviconFor(node).length > 0) {
          Image(this.faviconFor(node))
            .width(TILE_FAVICON_VP)
            .height(TILE_FAVICON_VP)
            .borderRadius(TILE_FAVICON_RADIUS)
            // Contain 而非 Cover：favicon 若为横条 logo（部分站点给的是宽图），
            // Cover 会把两侧裁掉；Contain 等比完整显示。
            .objectFit(ImageFit.Contain)
            // 请求尺寸是绘制的 2 倍 → 这里是**缩小**采样，High 插值清晰。
            .interpolation(ImageInterpolation.High)
            // Image 默认 draggable(true)：长按图标会启动拖拽、抢占磁贴的
            // LongPressGesture（长按文字正常、长按图标无反应的根因）。
            .draggable(false)
        } else {
          // 占位色块与 favicon 同几何，只染内部小色块，托盘保持一致。
          Column() {
            Text(initialOf(node))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .width('100%')
          }
          .width(TILE_FAVICON_VP)
          .height(TILE_FAVICON_VP)
          .borderRadius(TILE_FAVICON_RADIUS)
          .backgroundColor(placeholderTint(node))
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width(TILE_ICON_VP)
      .height(TILE_ICON_VP)
      .borderRadius(TILE_ICON_RADIUS)
      .backgroundColor(this.homeGlass())
      // 磁贴不叠 backdropBlur：每个磁贴一层模糊会让滚动/转场开销随数量线性增长。
      // 半透明底色已能透出壁纸，磨砂质感由搜索框等固定层提供。

              Text(node.title.length > 0 ? node.title : (node.url ?? ''))
                .fontSize(12)
                .fontColor(this.homeTileLabel())
                .textShadow(this.homeTileLabelShadow())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Center)
        .width('100%')
    }
    .width('25%')
    .padding({ top: 14 })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down && event.touches.length > 0) {
        this.menuPressX = event.touches[0].windowX;
        this.menuPressY = event.touches[0].windowY;
      }
    })
    // GestureGroup 显式声明「单击=打开 / 长按=菜单」，避免 tap 手势抢占长按。
    .gesture(GestureGroup(GestureMode.Exclusive,
      LongPressGesture({ repeat: false })
        .onAction((): void => {
          this.showBookmarkActions(node);
        }),
      TapGesture({ count: 1 })
        .onAction((): void => {
          this.openBookmark(node);
        })
    ))
  }

  // 主页书签磁贴：4 列 Flex 布局。本 SDK 无 Grid 拖拽重排 API，放弃拖拽、
  // 回归稳定的长按菜单 + 添加（下移修复见 moveTile：sendIndex 下移 +1）。
  @Builder
  private BookmarkGrid() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.tiles, (node: BookmarkNode, index: number) => {
        this.BookmarkTile(node)
      }, (node: BookmarkNode): string =>
        `${node.id}|${node.title}|${node.url ?? ''}`)

      // 「添加书签」磁贴：点开添加表单（预填当前页）。
      Column({ space: 7 }) {
        Column() {
          Image($r('app.media.aura_plus'))
            .width(22)
            .height(22)
            // 跟壁纸判色走：深色主题 + 亮壁纸时主题浅灰会糊进浅色托盘。
            .fillColor(this.homeFgTextSecondary())
        }
        .width(TILE_ICON_VP)
        .height(TILE_ICON_VP)
        .borderRadius(TILE_ICON_RADIUS)
        .backgroundColor(this.homeGlass())
        // 与其它磁贴一致不叠 backdropBlur，避免观感不一致与额外采样开销。
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        Text('添加')
          .fontSize(12)
          .fontColor(this.homeTileLabel())
          .textShadow(this.homeTileLabelShadow())
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      .width('25%')
      .padding({ top: 14 })
      .onClick(() => {
        this.editingId = '';
        this.newBookmarkTitle = '';
        this.newBookmarkUrl = '';
        this.showAddBookmark = true;
      })
    }
    .width('100%')

    if (this.tiles.length === 0) {
      Text('书签「首页」文件夹还是空的\n在「书签」中进入「首页」文件夹，或点「+」添加')
        .fontSize(12)
        .fontColor(this.homeTileLabel())
        .textShadow(this.homeTileLabelShadow())
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ top: 10 })
    }
  }

  // 长按书签的自绘菜单卡（menu_glass 实底 + 圆角 22 + 阴影，行高 48）。
  @Builder
  private BookmarkMenuOverlay() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .onClick(() => {
          this.menuId = '';
          this.menuTitle = '';
        })

      Column() {
        this.MenuRow($r('app.media.aura_chevron'), '上移', (): void => {
          const id = this.menuId;
          this.menuId = '';
          this.menuTitle = '';
          this.moveTile(id, -1);
        }, -90)
        this.MenuRow($r('app.media.aura_chevron'), '下移', (): void => {
          const id = this.menuId;
          this.menuId = '';
          this.menuTitle = '';
          this.moveTile(id, 1);
        }, 90)
        this.MenuRow($r('app.media.aura_edit'), '编辑', (): void => {
          this.beginEditFromMenu();
        }, 0)
        this.MenuRow($r('app.media.aura_trash'), '删除', (): void => {
          this.deleteFromMenu();
        }, 0)
      }
      .width(MENU_CARD_VP)
      .padding({ top: 6, bottom: 6 })
      .borderRadius(22)
      .backgroundColor($r('app.color.menu_glass'))
      .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
      .position({ x: this.menuX, y: this.menuY })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.opacity(0)
          .combine(TransitionEffect.scale({ x: 0.9, y: 0.9 })),
        TransitionEffect.opacity(0)
          .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
      ).animation({ curve: curves.springMotion(0.3, 0.72) }))
    }
    .width('100%')
    .height('100%')
    // 退场动效必须挂在 if 分支根节点上：挂子节点会随整子树被原子删除，
    // 退场动画播不出来。
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(1),
      TransitionEffect.opacity(0).animation({ duration: 300, curve: Curve.Friction })
    ))
  }

  @Builder
  private MenuRow(icon: Resource, label: string, action: () => void, iconAngle: number) {
    Row({ space: 14 }) {
      Image(icon)
        .width(21)
        .height(21)
        .fillColor($r('app.color.icon_primary'))
        .rotate({ angle: iconAngle })
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
      Blank()
    }
    .width('100%')
    .height(48)
    .padding({ left: 18, right: 16 })
    .onClick(action)
  }

  // 添加/编辑书签弹层（menu_glass 实底 + 遮罩盖满全屏）。
  @Builder
  private BookmarkFormOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.modal_scrim'))
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0).animation({ duration: 260, curve: Curve.Friction }),
          TransitionEffect.opacity(0).animation({ duration: 380, curve: Curve.Friction })
        ))
        .onClick(() => {
          this.closeBookmarkForm();
        })

      Row() {
        Column({ space: 14 }) {
          // 1.0.111：文案回滚为「书签」——这个表单是主页磁贴（书签「首页」文件
          // 夹）的添加/编辑；「网址主页」是另一回事（overlay 层的设置表单）。
          Text(this.editingId.length > 0 ? '编辑书签' : '添加书签')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          if (this.editingId.length === 0) {
            Text('保存在书签「首页」文件夹，会显示在主页')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }

          Column({ space: 6 }) {
            Text('名称')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            TextInput({ text: this.newBookmarkTitle, placeholder: '网站名称（可留空）' })
              .height(46)
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.surface_secondary'))
              .borderRadius(12)
              .onChange((value: string): void => {
                this.newBookmarkTitle = value;
              })
          }
          .width('100%')

          Column({ space: 6 }) {
            Text('网址')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            TextInput({ text: this.newBookmarkUrl, placeholder: 'https://…' })
              .height(46)
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.surface_secondary'))
              .borderRadius(12)
              .onChange((value: string): void => {
                this.newBookmarkUrl = value;
              })
          }
          .width('100%')

          Row({ space: 12 }) {
            Row() {
              Text('取消')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
            }
            .justifyContent(FlexAlign.Center)
            .layoutWeight(1)
            .height(44)
            .borderRadius(12)
            .backgroundColor($r('app.color.surface_secondary'))
            .onClick(() => {
              this.closeBookmarkForm();
            })

            Row() {
              Text(this.editingId.length > 0 ? '保存' : '添加')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.on_accent'))
            }
            .justifyContent(FlexAlign.Center)
            .layoutWeight(1)
            .height(44)
            .borderRadius(12)
            .backgroundColor($r('app.color.accent_primary'))
            .onClick(() => {
              this.confirmBookmarkForm();
            })
          }
          .width('100%')
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
      .padding({ left: 44, right: 44 })
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(1),
      TransitionEffect.opacity(0).animation({ duration: 340, curve: Curve.Friction })
    ))
  }

  // -- 主页布局 ----------------------------------------------------------------

  @Builder
  private HomeSettingsOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.modal_scrim'))
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0).animation({ duration: 260, curve: Curve.Friction }),
          TransitionEffect.opacity(0).animation({ duration: 380, curve: Curve.Friction })
        ))
        .onClick(() => {
          this.showSettings = false;
        })

      Row() {
        Column({ space: 10 }) {
          Row() {
            Text('主页布局')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Blank()
            // Logo 显隐决定长按入口是否可用，隐藏时指路设置页。
            Text(this.custom.showLogo
              ? '长按主页 Logo 可再开此面板'
              : 'Logo 已隐藏，可从 设置 › 主页设置 进入')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')

          Scroll() {
            Column({ space: 6 }) {
              // -- 背景 --
              Row({ space: 10 }) {
                if (this.bgUri.length > 0) {
                  Image(this.bgUri)
                    .width(74)
                    .height(46)
                    .borderRadius(10)
                    .objectFit(ImageFit.Cover)
                    .interpolation(ImageInterpolation.High)
                } else {
                  Column() {
                    Text('默认')
                      .fontSize(12)
                      .fontColor($r('app.color.text_secondary'))
                  }
                  .width(74)
                  .height(46)
                  .borderRadius(10)
                  .backgroundColor($r('app.color.surface_secondary'))
                  .justifyContent(FlexAlign.Center)
                }
                Row() {
                  Text('选择图片')
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                }
                .justifyContent(FlexAlign.Center)
                .height(36)
                .padding({ left: 14, right: 14 })
                .borderRadius(18)
                .backgroundColor($r('app.color.surface_secondary'))
                .onClick(() => {
                  this.pickBackground();
                })
                Row() {
                  Text('移除背景')
                    .fontSize(14)
                    .fontColor(this.custom.bgPath.length > 0
                      ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                }
                .justifyContent(FlexAlign.Center)
                .height(36)
                .padding({ left: 14, right: 14 })
                .borderRadius(18)
                .backgroundColor($r('app.color.surface_secondary'))
                .onClick(() => {
                  this.removeBackground();
                })
              }
              .width('100%')
              .margin({ top: 4 })

              // -- 显示 --
              Text('显示')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .margin({ top: 8 })
              HomeSettingToggleRow({
                icon: $r('app.media.aura_display'), label: 'Logo 区', isOn: this.custom.showLogo,
                onToggle: (on: boolean): void => {
                  this.custom.showLogo = on;
                  this.persistCustom();
                  // 关掉 Logo 会自锁长按入口，提示设置页那条路。
                  if (!on) {
                    this.getUIContext().getPromptAction().showToast({
                      message: 'Logo 已隐藏；以后可从 设置 › 主页设置 进入布局',
                      duration: 2200
                    });
                  }
                }
              })
              HomeSettingToggleRow({
                icon: $r('app.media.aura_bookmark'), label: '书签区', isOn: this.custom.showTiles,
                onToggle: (on: boolean): void => {
                  this.custom.showTiles = on;
                  this.persistCustom();
                }
              })

              // -- 位置 --
              Text('位置（上下微调）')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .margin({ top: 8 })
              HomePositionSliderRow({
                label: 'Logo', posOffset: this.custom.logoOffset, min: -120, max: 260,
                onMoved: (value: number, end: boolean): void => {
                  this.custom.logoOffset = value;
                  this.layoutDragging = !end;
                  if (end) {
                    this.persistCustom();
                  }
                }
              })
              HomePositionSliderRow({
                label: '搜索框', posOffset: this.custom.searchOffset, min: -40, max: 260,
                onMoved: (value: number, end: boolean): void => {
                  this.custom.searchOffset = value;
                  this.layoutDragging = !end;
                  if (end) {
                    this.persistCustom();
                  }
                }
              })
              HomePositionSliderRow({
                label: '书签区', posOffset: this.custom.tilesOffset, min: -40, max: 260,
                onMoved: (value: number, end: boolean): void => {
                  this.custom.tilesOffset = value;
                  this.layoutDragging = !end;
                  if (end) {
                    this.persistCustom();
                  }
                }
              })

              Row() {
                Text('恢复默认布局')
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
              }
              .width('100%')
              .height(42)
              .justifyContent(FlexAlign.Center)
              .borderRadius(12)
              .backgroundColor($r('app.color.surface_secondary'))
              .margin({ top: 8 })
              .onClick(() => {
                this.custom.logoOffset = 0;
                this.custom.searchOffset = 0;
                this.custom.tilesOffset = 0;
                this.custom.showLogo = true;
                this.custom.showSearch = true;
                this.custom.showTiles = true;
                this.persistCustom();
              })
            }
            .width('100%')
          }
          .width('100%')
          .constraintSize({ maxHeight: Math.max(300, this.windowH * 0.52) })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })

          Row() {
            Text('完成')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_accent'))
          }
          .width('100%')
          .height(44)
          .justifyContent(FlexAlign.Center)
          .borderRadius(12)
          .backgroundColor($r('app.color.accent_primary'))
          .onClick(() => {
            this.showSettings = false;
          })
        }
        .width('100%')
        .padding(20)
        .borderRadius(22)
        // 1.0.97：平时近实底（可读），仅拖动位置滑块时转 60% 玻璃（float_bar_bg），
        // 松手恢复——拖的时候要能看见后边主页实时变化，静止时不要透。
        .backgroundColor(this.layoutDragging ?
          $r('app.color.float_bar_bg') : $r('app.color.menu_glass'))
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
      .padding({ left: 26, right: 26 })
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(1),
      TransitionEffect.opacity(0).animation({ duration: 340, curve: Curve.Friction })
    ))
  }

  // 设置-主页设置「自定义主页布局」入口触发：打开主页布局弹层（无痕不打开）。
  // 消费信号后置 0，避免 HomeSurface 卸载重挂时因信号残留被 aboutToAppear 种子误开。
  private onOpenHomeLayout(): void {
    if (!this.incognito) {
      this.showSettings = true;
    }
    AppStorage.set('auraOpenHomeLayout', 0);
  }

  // 长按 Logo 打开主页布局；Logo 被隐藏时该入口失效，仍可从设置页进入。
  private openHomeLayoutPanel(): void {
    if (this.incognito) {
      return;
    }
    this.showSettings = true;
  }

  // （1.0.111：onOpenHomeTile 随信号一并移除。）

  // 已在主页时按了主页键：清空搜索框、收起联想、收掉系统键盘（缺这三步就是
  // 「按主页键没反应」——引擎侧 home 对已在 newtab 的标签页是空操作）。
  private onHomeResetRequest(): void {
    this.homeInputController.stopEditing();
    this.query = '';
    this.clearSuggest();
  }

  // 首页内容组的顶部锚点占位（1.0.180）：把 Logo 行中心钉在 22% 窗高
  // （设计稿 440×956 实测 21.9%）；Logo 关闭时改为把搜索框中心钉在 33.5%
  // （实测 33.6%）。减去的 24 = 行半高（Logo 行与搜索框都是 48 高）。
  // 「Logo」微调 logoOffset 叠加在锚点之上，负值可上移。
  // 内容顶距：嵌入态用外层 chrome 总高，独立态用状态栏安全区。
  private topInset(): number {
    return this.embedded ? this.topInsetVp : this.topSafeVp;
  }

  private homeTopBlankVp(): number {
    const anchor: number = (this.custom.showLogo || this.incognito) ? 0.22 : 0.335;
    const anchored: number = this.windowH * anchor - this.topInset() - 24 + this.custom.logoOffset;
    // 下限：页面最上面常驻一条 56vp 的工具条（简约风格的主页/标签数/⋮，或
    // Chrome 风格的上置 dock），Blank 再小也不能把首行塞到它下面去 —— 横屏时
    // 窗高只有 ~419vp，算出来的 Blank 本来就只 68vp，一旦 windowH 被读小，
    // 整行 Logo 会钻到工具条背后、只露出图底部一条弧线（2026-10-27 实测）。
    return Math.max(TOP_CHROME_EXTENT_VP + 8, anchored);
  }

  // 滚动内容末尾的呼吸位 = 24 + 悬浮 dock 的实占高度。简约 dock 浮在主页最下层，
  // 不让位的话滚到底时最后一行磁贴正好停在 dock 底下；chrome 风格 dock 钉在顶部，
  // 不需要让位。顺带让内容能真正超出视口 —— 横屏磁贴少时内容比视口还短，
  // Scroll 的 alwaysEnabled 弹簧只会回弹、停不住。
  private homeBottomBreathVp(): number {
    // 嵌入态没有悬浮 dock（桌面 chrome 在顶部），只留基础呼吸位。
    const dock: number = this.embedded || this.homeStyle === 'chrome' ?
      0 : dockCoveredHeightVp(this.bottomSafeVp);
    return 24 + dock;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 背景图（设置了才铺；无痕不铺）。hitTestBehavior None：纯装饰层。
      if (this.bgUri.length > 0 && !this.incognito) {
        Image(this.bgUri)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.High)
          .hitTestBehavior(HitTestMode.None)
          // onComplete 只代表解码完成，再等一帧让首帧真正落下才放开整层；
          // onError 也必须放开，避免图坏时主页一直不显示。
          .onComplete((): void => {
            if (this.bgPaintDelayTimer !== -1) {
              clearTimeout(this.bgPaintDelayTimer);
            }
            this.bgPaintDelayTimer = setTimeout((): void => {
              this.bgPaintDelayTimer = -1;
              this.openHomeLayer();
            }, 16);
          })
          .onError((): void => {
            this.openHomeLayer();
          })
        // 暗纱只在深色模式保留（压暗亮壁纸保证白字可读）；
        // 浅色模式不铺，避免洗白壁纸，文字靠控件底色与阴影兜底。
        if (this.colorScheme === 'dark') {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor($r('app.color.surface_primary'))
            .opacity(0.30)
            .hitTestBehavior(HitTestMode.None)
        }
      }

      Column() {
        // 主页内容进 Scroll：横屏可用高有限，Logo + 搜索框 + 两行磁贴几乎占满，
        // 固定布局会把超出的书签裁掉。
        // 锚点不变：Blank 仍是滚动内容的第一段，未滚动时位置不变。
        Scroll() {
          Column() {
            // 1.0.180：内容组按设计稿锚定——顶部是**按窗高算出的固定占位**
            // （Logo 行/搜索框的中心 22% / 33.5% 窗高，见 homeTopBlankVp）。
            // 内容高过视口时整组随 Scroll 上移，不再像以前那样被裁掉。
            // （1.0.178 的上下对半劈会把内容压到窗高 36% 一带，低于设计稿。）
            // 主页布局弹层的「Logo」微调叠加在锚点上：锚点是固定基数，负值
            // 可上移（1.0.178 弹性占位时代负值无效，那套限制随本次移除）。
            Blank()
              .height(this.homeTopBlankVp())

            if (this.custom.showLogo || this.incognito) {
              // 外层 Row 撑满整行以扩大长按命中区，视觉仍居中不变。
              Row() {
                Row({ space: 8 }) {
                  if (this.incognito) {
                    Image($r('app.media.aura_incognito'))
                      .width(26)
                      .height(26)
                      .fillColor($r('app.color.text_primary'))
                  } else {
                    // 浏览器 logo（颜色按壁纸中带选版，见 homeLogoRes）。
                    Image(this.homeLogoRes())
                      .width(42)
                      .height(30)
                      .draggable(false)
                  }
                  Text(this.incognito ? '无痕浏览' : 'Orbira')
                    .fontSize(34)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.homeFgText())
                }
                // 只绑长按、不绑点击：点 Logo 无副作用，误触也安全。
                .gesture(LongPressGesture({ repeat: false, duration: 500 })
                  .onAction((): void => {
                    this.openHomeLayoutPanel();
                  }))
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
            }

            // Logo 行中心 ↔ 搜索框中心的锚点差 = 11.5% 窗高（设计稿 22% → 33.5%
            // 实测），减去两行半高（24 + 24）即为此处间隙；「搜索框」微调
            // searchOffset 照旧叠加。行高变化时两个锚点各偏半个误差，可接受。
            Blank()
              .height(Math.max(0, this.windowH * 0.115 - 48 + this.custom.searchOffset))

            if (this.custom.showSearch || this.incognito) {
              Row({ space: 10 }) {
                Image($r('app.media.chromium_search'))
                  .width(20)
                  .height(20)
                  .fillColor(this.homeFgTextSecondary())
                TextInput({ text: this.query, placeholder: '搜索或输入网址', controller: this.homeInputController })
                  .layoutWeight(1)
                  .height(48)
                  .fontSize(15)
                  .fontColor(this.homeFgText())
                  .placeholderColor(this.homeFgTextSecondary())
                  .backgroundColor(Color.Transparent)
                  .enterKeyType(EnterKeyType.Go)
                  .onChange((value: string) => {
                    this.query = value;
                    // 与地址栏一致：输入即弹联想。
                    this.requestSuggest(value);
                  })
                  .onSubmit(() => {
                    this.submitQuery();
                  })
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  Image($r('app.media.chromium_scan'))
                    .width(20)
                    .height(20)
                    .fillColor(this.homeFgTextSecondary())
                }
                .width(36)
                .height(36)
                .backgroundColor(Color.Transparent)
                .accessibilityText('扫一扫')
                .onClick(() => {
                  this.startScan();
                })
              }
              .width('100%')
              .height(48)
              .borderRadius(24)
              .backgroundColor(this.homeGlass())
              // 拖动滑块时搜索框每帧移动，backdropBlur 会逐帧重采样背后像素；
              // 拖动期间关掉，静止时恢复（结果可缓存，无逐帧开销）。
              .backdropBlur(this.layoutDragging ? 0 : 20)
              .padding({ left: 16, right: 10 })
              .margin({ top: 0 })
            }

            // 联想列表：紧贴搜索框下方的一张卡（输入期间顶掉下面的磁贴，
            // 和地址栏联想一样是「盖住内容」而不是把内容推下去）。
            if (this.suggestActive()) {
              this.HomeSuggestCard()
            }

            if (this.incognito) {
              Text('无痕标签页不会保存浏览记录、Cookie 和表单数据；下载的文件和书签会保留。')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .textAlign(TextAlign.Center)
                .maxLines(3)
                .width('100%')
                .padding({ left: 12, right: 12 })
                .margin({ top: 16 })
            }

            Blank()
              .height(Math.max(0, 18 + this.custom.tilesOffset))

            if (!this.incognito && this.custom.showTiles) {
              if (this.tilesError) {
                Row({ space: 10 }) {
                  Text('书签加载失败')
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                  Text('重试')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.accent_primary'))
                    .onClick(() => {
                      this.refreshBookmarks();
                    })
                }
                .width('100%')
                .height(40)
                .justifyContent(FlexAlign.Center)
              } else {
                // 联想期间只做 Visibility.None（节点留着），不要用 if 把整块磁贴
                // 拆掉 —— 那会连图标一起销毁重建，第一次弹联想时明显一顿。
                Column() {
                  this.BookmarkGrid()
                }
                .width('100%')
                .visibility(this.suggestActive() ? Visibility.None : Visibility.Visible)
              }
            }

            // 底部呼吸（替代原弹性占位）：底色由外层 Column 负责，
            // 内容比视口短时不必撑满。高度含悬浮 dock 的让位（见
            // homeBottomBreathVp）——不然滚到底时最后一行磁贴被 dock 盖住。
            Blank()
              .height(this.homeBottomBreathVp())
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        // 必须显式顶端对齐：Scroll 在「内容比视口短」时默认居中，主页内容本来
        // 就比视口矮（竖屏 ~516 vs 832vp），不写这行整组会被下移半个差值
        // （用户实测「改完竖屏靠下了」）。项目里其余 Scroll 也都带这行。
        .align(Alignment.TopStart)
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.topInset(), left: 24, right: 24 })
      .backgroundColor(this.bgUri.length > 0 && !this.incognito
        ? Color.Transparent : $r('app.color.surface_primary'))

      // 顶部渐变纱幕只在无自定义壁纸时保留：纯色背景滚动时兜住状态栏下的内容。
      // 有壁纸时让壁纸直接透出状态栏。嵌入态不画——那一条区域归桌面 chrome。
      if (!this.embedded && !(this.bgUri.length > 0 && !this.incognito)) {
        Column()
          .width('100%')
          .height(this.topSafeVp + 8)
          // 模糊半径越大滚动采样越贵，取 12 兼顾观感与开销。
          .backdropBlur(12)
          .hitTestBehavior(HitTestMode.None)
        Column()
          .width('100%')
          .height(this.topSafeVp + 48)
          .linearGradient({
            angle: 180,
            colors: [
              [$r('app.color.home_scrim'), 0.0],
              // 模糊带的下沿（topSafe + 8）处仍是实底，模糊边缘不会露出硬线。
              [$r('app.color.home_scrim'),
                Math.max(0.02, (this.topSafeVp + 8) / (this.topSafeVp + 48))],
              [$r('app.color.home_scrim_fade'), 1.0]
            ]
          })
          .hitTestBehavior(HitTestMode.None)
      }

      // 1.0.96：主页右上角菜单按钮已去掉——简约风格底栏 dock 自带 ⋮ 菜单
      // （返回/前进/主页/标签页/菜单），Chrome 风格 dock 也有菜单槽位，主页
      // 页面再放一个是冗余入口。连带清理 MobileBrowserOverlay.onRequestMenuOpen
      // （auraRequestMenuOpen 信号已无发送方）。

      // 长按书签的自绘菜单卡。
      if (this.menuId.length > 0) {
        this.BookmarkMenuOverlay()
      }

      // 添加/编辑书签弹层。
      if (this.showAddBookmark) {
        this.BookmarkFormOverlay()
      }

      // 主页布局弹层。
      if (this.showSettings) {
        this.HomeSettingsOverlay()
      }
    }
    .width('100%')
    .height('100%')
    // 壁纸首帧前整层不显示，避免透明底透出下层网页；硬切上屏，不加淡入。
    .opacity(this.bgLayerReady() ? 1 : 0)
    // 放大进场永远盖满屏，不产生透明帧。
    .scale({ x: this.enterScale, y: this.enterScale })
    // 旋转/分屏/窗口尺寸变化都从这里重算锚点，但**不能直接用这一帧的 area**。
    // 实测（2026-10-27 横屏 logo 只剩一条弧线）：转屏时 onAreaChange 先以
    // 「宽度已变、高度还是键盘压矮后的值」的中间帧回调一次 —— 竖屏 419×920、
    // 键盘占 210vp 时，那一帧是 920×209，把它记成 windowH 后锚点全部错位：
    // Blank 从 68vp 塌到 22vp，Logo 行整条钻到顶部工具条背后。
    // 所以：宽度变了 → 用**物理屏**尺寸重算（display 会跟随方向），不采信中间帧；
    //       同宽下窗高变大（键盘收起 / 转屏收尾）→ 跟进；变小（键盘弹出）→ 忽略。
    .onAreaChange((_old: Area, now: Area): void => {
      const w: number = Number(now.width);
      const h: number = Number(now.height);
      if (w <= 0 || h <= 0) {
        return;
      }
      if (Math.abs(w - this.windowW) > 0.5) {
        this.windowW = w;
        if (this.embedded) {
          // 嵌入态（桌面 chrome 下 / 自由窗）：display 是整机物理高，不能用它
          // 算锚点（自由窗里它比窗口本身高得多）——用本组件实测高再扣掉 chrome
          // 高，锚点落在 chrome 之下的内容区（Chrome 的 NTP 锚点也按内容区算）。
          this.windowH = Math.max(0, h - this.topInsetVp);
          return;
        }
        let screenH: number = 0;
        try {
          const dsp = display.getDefaultDisplaySync();
          screenH = dsp.height / dsp.densityPixels;
        } catch (error) {
          screenH = 0;
        }
        this.windowH = screenH > 0 ? screenH : h;
        return;
      }
      // 嵌入态这条也要扣 chrome 高：windowH 的语义是「chrome 之下的内容区高」。
      const contentH: number = this.embedded ? Math.max(0, h - this.topInsetVp) : h;
      if (contentH > this.windowH + 0.5) {
        this.windowH = contentH;
      }
    })
  }
}
