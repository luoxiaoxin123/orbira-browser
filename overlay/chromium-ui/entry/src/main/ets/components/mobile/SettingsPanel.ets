/*
 * 手机自绘设置页。
 * 数据流：getPrefs / getSearchEngines / getAboutInfo -> 对应事件
 * （AuraShell 转存到 'auraPanelPrefs' / 'auraPanelEngines' / 'auraPanelAbout'）。
 * setPref 成功后引擎推 prefsChanged（转存到 'auraPanelEvent'），本页据此重拉。
 */
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import bundleManager from '@ohos.bundle.bundleManager';
import deviceInfo from '@ohos.deviceInfo';
import { AppearanceSettings, ColorModeSetting, ForceDarkOverride } from '../../utils/appearance/AppearanceSettings';
import { ThemeSchemePush } from '../../bus/ThemeSchemePush';
import { glassBottomInsetVp, glassHeaderInsetVp } from './GlassPage';
import { curves } from '@kit.ArkUI';
import {
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  hdsMaterial,
  ScrollEffectType
} from '@kit.UIDesignKit';
import { ShellUiPrefs } from '../../utils/appearance/ShellUiPrefs';
import { SearchEnginesPrefs } from '../../utils/appearance/SearchEnginesPrefs';
import { HuaweiAccountInfo } from '../../utils/account/HuaweiAccountService';
import { HuaweiAccountView } from './AccountPanel';
import { AdBlockPanel } from './AdBlockPanel';
import { AuraNavIconRow, AuraSectionLabel, AuraSearchBar } from './AuraKit';
import { searchTemplateForSite } from './ShellUtils';
import {
  BrowsingDataType,
  BrowsingDataTimeRange,
  BrowserCommandPayload,
  SearchEngine,
  ShellPrefKey,
  ShellPrefValue
} from 'engine';

interface BrowsingDataCountsPayload {
  event?: string;
  historyCount?: number;
  cacheBytes?: number;
  siteCount?: number;
  passwordCount?: number;
  formDataCount?: number;
  siteSettingsCount?: number;
}

interface PrefRow {
  key: ShellPrefKey;
  label: string;
}

const PREF_ROWS: PrefRow[] = [
  { key: 'blockThirdPartyCookies', label: '阻止第三方 Cookie' },
  { key: 'javascriptEnabled', label: '启用 JavaScript' },
  { key: 'popupsBlocked', label: '拦截弹窗' },
  { key: 'doNotTrack', label: '发送"请勿追踪"请求' },
  { key: 'preloadPages', label: '预加载网页' },
  // 实际文案随主题派生（见 forceDarkLabel），这里只是列表数据的占位值。
  { key: 'forceDarkWebContents', label: '网页强制深色' },
  { key: 'downloadAskWhereToSave', label: '下载前询问' }
];

interface RangeRow {
  key: BrowsingDataTimeRange;
  label: string;
}

interface ClearTypeRow {
  key: BrowsingDataType;
  label: string;
}

const CLEAR_RANGES: RangeRow[] = [
  { key: 'lastHour', label: '过去 1 小时' },
  { key: 'lastDay', label: '过去 24 小时' },
  { key: 'lastWeek', label: '过去 7 天' },
  { key: 'last4Weeks', label: '过去 4 周' },
  { key: 'all', label: '全部时间' }
];

// 「清除浏览数据」页的数据类型清单：每类各占一行、各带勾选框，
// 右侧显示该时间范围内的实际数量。
const CLEAR_TYPE_ROWS: ClearTypeRow[] = [
  { key: 'history', label: '浏览记录' },
  { key: 'cookies', label: 'Cookie 和网站数据' },
  { key: 'cache', label: '缓存的图片和文件' },
  { key: 'passwords', label: '已保存的密码' },
  { key: 'formData', label: '自动填充表单数据' },
  { key: 'siteSettings', label: '网站设置' },
  { key: 'downloads', label: '下载记录' }
];

const CLEAR_TYPES_DEFAULT: BrowsingDataType[] = ['history', 'cookies', 'cache', 'downloads'];

// 「法律许可」页内联文本。应用自身按 Chromium BSD 3-Clause 发布
// （复制自仓库 LICENSE，与上游一致）；Apache-2.0 / MIT / MPL / LGPL 等是捆绑进
// 来的第三方组件各自携带的许可，只在此页简述并指向完整清单，不粘贴全文。
const APP_LICENSE_TEXT: string = `Copyright 2015 The Chromium Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
  * Neither the name of Google LLC nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.`;

// 去掉此段硬编码的内核版本（原 'Chromium 150.0.7871.114'，实际引擎
// 已 154，会误导）——版本号只在「版权声明」段动态显示（getAboutInfo）。
const THIRD_PARTY_LICENSE_NOTE: string = `除应用自身采用上述 BSD 3-Clause 许可外，所捆绑的第三方组件按其各自许可发布，主要包括：

· WebView / 引擎封装层：Apache License 2.0
· FFmpeg（静态链接）：BSD-2-Clause、BSD-3-Clause、ISC、LGPL-2.1+，以及 MIT 组件
· Blink / WebKit 相关文件：BSD、LGPL-2、LGPL-2.1
· Hunspell：MPL-1.1
· Symphonia（Rust 音频库）：MPL-2.0
· 广告过滤引擎与规则：adblock-rust / adblock-resources（MPL-2.0）；uBlock Origin 的 scriptlets 与替代资源（GPL-3.0）；EasyList / EasyList China / EasyPrivacy 过滤规则（CC-BY-SA 3.0）
· 可选的威胁情报列表：HaGeZi DNS Blocklists（GPL-3.0）、PhishDestroy Destroylist（MIT，© 2019 PhishDestroy）

上述组件的许可文本与署名已随安装包分发，位于应用资源 resources/rawfile/licenses/
（BSD-3-Clause-Chromium.txt、OPEN_SOURCE_NOTICES.md、Apache-2.0.txt、MPL-2.0.txt、
MPL-1.1.txt、LGPL-2.1.txt、BLINK-WEBKIT-LICENSES.txt、adblock-rust-*.txt、
adblock-resources-LICENSE.txt、GPL-3.0.txt、CC-BY-SA-3.0.txt）。Chromium 完整的第三方许可清单约 20MB，未随包分发。`;

interface PrefToggleItem {
  key: ShellPrefKey;
  label: string;
  value: boolean;
}

// 设置项检索：把散在各分区里的条目集中登记一次（名称 + 关键词 + 分区 +
// 打开方式）。搜索只过滤这个清单，不改动既有分区 UI。
interface SettingsEntry {
  id: string;
  // 匹配范围：标题 + 副标题 + 关键词（同义词、英文、别称）。
  title: string;
  subtitle: string;
  keywords: string[];
  section: string;
  // 点击后如何到达：直接跳二级页、由外壳打开独立页，或是某个开关。
  kind: 'page' | 'shell' | 'toggle' | 'externalToggle';
}

const SETTINGS_ENTRIES: SettingsEntry[] = [
  { id: 'searchEngine', title: '搜索引擎', subtitle: '选择默认搜索引擎',
    keywords: ['engine', 'search', '默认', '百度', 'google', '必应', '搜狗'], section: '常规', kind: 'page' },
  { id: 'extensions', title: '扩展程序', subtitle: '管理已安装的扩展',
    keywords: ['extension', '插件', 'addon'], section: '常规', kind: 'shell' },

  { id: 'sitePermissions', title: '网站权限', subtitle: '各网站的相机、定位等权限',
    keywords: ['permission', '权限', '相机', '定位', '麦克风'], section: '隐私与安全', kind: 'shell' },
  { id: 'externalAppLinks', title: '允许跳转本机应用', subtitle: '知乎、B站这类链接交给对应应用打开',
    keywords: ['external', '跳转', '应用', 'scheme', '知乎', 'B站', 'bilibili', '外部'],
    section: '隐私与安全', kind: 'externalToggle' },
  { id: 'passwords', title: '密码', subtitle: '查看和管理已保存的密码',
    keywords: ['password', '密码', '账号', '登录', 'vault'], section: '隐私与安全', kind: 'shell' },
  { id: 'blockThirdPartyCookies', title: '阻止第三方 Cookie', subtitle: '',
    keywords: ['cookie', '第三方', '追踪', '隐私'], section: '隐私与安全', kind: 'toggle' },
  { id: 'popupsBlocked', title: '拦截弹窗', subtitle: '',
    keywords: ['popup', '弹窗', '拦截', '广告'], section: '隐私与安全', kind: 'toggle' },
  { id: 'doNotTrack', title: '发送"请勿追踪"请求', subtitle: '',
    keywords: ['dnt', '请勿追踪', '追踪', '隐私'], section: '隐私与安全', kind: 'toggle' },
  { id: 'adblock', title: '广告拦截', subtitle: '内置规则过滤网页广告与追踪脚本',
    keywords: ['adblock', '广告', '拦截', '过滤', '屏蔽', 'easylist', '规则'],
    section: '隐私与安全', kind: 'page' },
  { id: 'clearBrowsingData', title: '清除浏览数据', subtitle: '历史记录、Cookie、缓存等',
    keywords: ['clear', '清除', '清理', '历史', '缓存', 'cache', 'history'],
    section: '隐私与安全', kind: 'page' },

  { id: 'darkMode', title: '深色模式', subtitle: '浅色、深色或跟随系统',
    keywords: ['dark', '深色', '夜间', '主题', 'theme', '外观'], section: '外观', kind: 'page' },
  { id: 'home', title: '主页设置', subtitle: '主页风格、自定义主页布局与网址主页',
    keywords: ['home', '主页', '首页', '主页布局', '主页风格', '自定义', '布局', '磁贴', '网址', 'chrome 风格', '经典风格', '简约'],
    section: '外观', kind: 'page' },
  { id: 'hideStatusBarOnScroll', title: '上滑时隐藏状态栏', subtitle: '地址栏收起时一起隐藏，网页铺满全屏',
    keywords: ['状态栏', '全屏', '隐藏', '上滑'], section: '外观', kind: 'toggle' },
  { id: 'hideTopBarOnScroll', title: '滚动时隐藏地址栏', subtitle: '向下滚动时收起顶部地址栏',
    keywords: ['地址栏', '顶栏', '滚动', '隐藏'], section: '外观', kind: 'toggle' },
  { id: 'hideDockOnScroll', title: '滚动时隐藏底部栏', subtitle: '向下滚动时收起底部栏',
    keywords: ['底部栏', 'dock', '滚动', '隐藏'], section: '外观', kind: 'toggle' },
  { id: 'zoom', title: '网页缩放', subtitle: '整页一起放大或缩小',
    keywords: ['zoom', '缩放', '字体', '放大', '缩小', 'textScale'], section: '外观', kind: 'page' },
  { id: 'forceDarkWebContents', title: '网页强制深色', subtitle: '',
    keywords: ['dark', '深色', '网页', '强制', '关闭', '恢复', '原色', '浅色'],
    section: '外观', kind: 'toggle' },

  { id: 'downloadAskWhereToSave', title: '下载前询问', subtitle: '安装包和未知文件总是询问',
    keywords: ['download', '下载', '询问', '保存位置'], section: '下载', kind: 'toggle' },

  { id: 'javascriptEnabled', title: '启用 JavaScript', subtitle: '',
    keywords: ['javascript', 'js', '脚本'], section: '高级', kind: 'toggle' },
  { id: 'preloadPages', title: '预加载网页', subtitle: '',
    keywords: ['preload', '预加载', '预读', '加速'], section: '高级', kind: 'toggle' },
  { id: 'vulkanEnabled', title: 'Vulkan 渲染加速', subtitle: '实验性：开启后部分机型可能滑动掉帧，建议保持关闭；改动需重启生效',
    keywords: ['vulkan', 'gpu', '渲染', '加速', '掉帧', '卡顿', 'gles', '性能', 'skia'],
    section: '高级', kind: 'toggle' },
  { id: 'webgpuEnabled', title: 'WebGPU 加速', subtitle: '实验性：开启后网页可用 GPU 计算/渲染（navigator.gpu）；改动需重启生效',
    keywords: ['webgpu', 'gpu', '渲染', '加速', 'vulkan', 'd3d', 'compute', '计算', '图形'],
    section: '高级', kind: 'toggle' },

  { id: 'about', title: '关于 Orbira', subtitle: '版本、内核与开源协议',
    keywords: ['about', '关于', '版本', 'version', '星轨', '开源', '简介', '项目', 'github', 'chromium-hmos'], section: '关于', kind: 'page' }
];

@Component
export struct SettingsPanel {
  @StorageLink('auraPanelPrefs') @Watch('onPrefsPayload') prefsJson: string = '';
  @StorageLink('auraPanelEngines') @Watch('onEnginesPayload') enginesJson: string = '';
  @StorageLink('auraPanelAbout') @Watch('onAboutPayload') aboutJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  @StorageLink('auraBrowsingDataCounts') @Watch('onBrowsingCounts') browsingCountsJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onOpenExtensions: () => void = (): void => {};
  onOpenSitePermissions: () => void = (): void => {};
  onOpenPasswords: () => void = (): void => {};
  // 「主页设置 → 自定义主页布局」需先收起设置面板、再打开主页布局弹层
  // （HomeSurface 在设置面板打开时未挂载 / 被遮挡，直发信号无效）。
  onOpenHomeLayout: () => void = (): void => {};
  // 「主页设置右上角 → 添加网址主页」同一条路子——先收起面板、回主页，
  // 再由信号在 HomeSurface 上打开添加表单。
  onAddHomeTile: () => void = (): void => {};

  private pathStack: NavPathStack = new NavPathStack();
  // 设置检索：常驻搜索框，输入即就地过滤设置项（不单独开搜索页）。
  @State private searchText: string = '';
  // 搜索框随设置列表滚走后，标题栏右侧浮现搜索按钮（点它回顶 + 聚焦）。
  @State private searchFabVisible: boolean = false;

  // 搜索框滚走后，点标题栏搜索按钮平滑回顶并聚焦搜索框（主列表与过滤列表共用）。
  // 聚焦必须延迟到回顶动画结束之后：requestFocus 唤起输入法会触发重布局，
  // 打断进行中的回顶弹簧动画 —— 实测列表停在半路，搜索框压在视口上方露不出来。
  // 两个输入框只聚焦当前可见的那个（隐藏组件 requestFocus 无效）。
  private scrollToSearch(): void {
    this.mainScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: 320, curve: curves.springMotion(0.34, 0.84) } });
    this.filteredScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: 320, curve: curves.springMotion(0.34, 0.84) } });
    setTimeout((): void => {
      if (this.searchText.trim().length === 0) {
        this.getUIContext().getFocusController().requestFocus('settings_main_search');
      } else {
        this.getUIContext().getFocusController().requestFocus('settings_filtered_search');
      }
    }, 480);
  }
  // 渐变模糊滚动效果按官方要求 bindToScrollable。
  private mainScroller: Scroller = new Scroller();
  private enginesScroller: Scroller = new Scroller();
  private filteredScroller: Scroller = new Scroller();
  private aboutScroller: Scroller = new Scroller();
  // 「法律许可」子页滚动容器。
  private legalScroller: Scroller = new Scroller();
  private appearanceScroller: Scroller = new Scroller();
  private homeScroller: Scroller = new Scroller();
  private zoomScroller: Scroller = new Scroller();
  // 广告拦截页（内容由 AdBlockPanel 自渲染，Scroller 由本组件持有后传入，
  // 否则 bindToScrollable 拿不到实例，标题栏没有渐变模糊）。
  private adblockScroller: Scroller = new Scroller();
  private clearScroller: Scroller = new Scroller();
  @State private toggleItems: PrefToggleItem[] = [];
  // 搜索引擎：baseEngines = 引擎返回的（不含自定义）；customEngines = 用户自定义
  // （preferences 持久化）；engines = 二者合并后用于显示（含持久化的默认勾选）。
  @State private baseEngines: SearchEngine[] = [];
  @State private customEngines: SearchEngine[] = [];
  @State private engines: SearchEngine[] = [];
  @State private defaultEngineId: string = '';
  // 添加自定义引擎弹层
  @State private showAddEngine: boolean = false;
  @State private newEngineName: string = '';
  @State private newEngineUrl: string = '';
  @State private chromiumVersion: string = '';
  @State private appVersion: string = '';
  @State private appVersionCode: string = '';
  @State private osVersion: string = '';
  @State private clearRange: BrowsingDataTimeRange = 'last4Weeks';
  @State private clearing: boolean = false;
  // 已勾选的数据类型（默认 history/cookies/cache/downloads，见 CLEAR_TYPES_DEFAULT）。
  @State private clearTypes: BrowsingDataType[] = CLEAR_TYPES_DEFAULT.slice();
  @State private browsingHistoryCount: number = -1;
  @State private browsingCacheBytes: number = -1;
  @State private browsingSiteCount: number = -1;
  @State private browsingPasswordCount: number = -1;
  @State private browsingFormDataCount: number = -1;
  @State private browsingSiteSettingsCount: number = -1;
  @State private colorModeSetting: ColorModeSetting = 'system';
  // 解析后的实际配色（'system' 时由 ability 按系统 colorMode 算出）。网页强制深色
  // 的开关是「相对当前主题默认值的偏离」，必须知道当前实际深浅才能决定文案与显示值。
  @StorageLink('auraColorScheme') actualColorScheme: string = 'light';
  // 开关显示以壳层的覆盖态为准（用户意图），不用引擎 pref 反推：冷启动时引擎
  // pref 可能还没同步到当前主题默认值，用绝对值会把「引擎值 ≠ 主题默认」误判成
  // 「用户手动偏离」，导致深色主题下开关默认显示打开。
  @StorageLink('auraForceDarkOverride') forceDarkOverride: string = 'follow';
  @State private textScalePercent: number = 100;
  @StorageLink('auraHideStatusBarOnScroll') hideStatusBarOnScroll: boolean = false;
  @StorageLink('auraHideTopBarOnScroll') hideTopBarOnScroll: boolean = true;
  @StorageLink('auraHideDockOnScroll') hideDockOnScroll: boolean = true;
  @StorageLink('auraExternalAppLinks') externalAppLinks: boolean = true;
  @StorageLink('auraHuaweiAccount') accountJson: string = '';
  // 主页风格（'minimal' | 'chrome'）与 Chrome 风格下 dock 位置（'bottom' | 'top'）。
  @StorageLink('auraHomeStyle') homeStyle: string = 'minimal';
  @StorageLink('auraDockPosition') dockPosition: string = 'bottom';
  // 「启动页」：冷启动打开网址主页('homeUrl')还是内置启动页('builtin')。
  @StorageLink('auraStartupPage') startupPage: string = 'builtin';
  @StorageLink('auraHomeUrl') homeUrl: string = '';
  // 「自定义网址」：多组网址（\n 分隔字符串，见 ShellUiPrefs.parseUrlList）。
  // 存字符串而不是数组——ArkTS 里 @StorageLink 换数组要整份新建才不会漏刷新，
  // 字符串最省心，解析一次即可。
  @StorageLink('auraHomeUrls') homeUrlsRaw: string = '';
  // 「Vulkan 渲染加速」：默认 false=走 GLES（规避部分机型滑动掉帧）；
  // 开启则引擎走 ANGLE Vulkan 后端。启动时读取一次，改动需重启生效。
  @StorageLink('auraVulkanEnabled') vulkanEnabled: boolean = false;
  // 「WebGPU 加速」：默认 false。开启后页面可用 navigator.gpu。
  // 与 ANGLE 后端（gles/vulkan）互不干扰，外壳注入命令行即开，改动需重启生效。
  @StorageLink('auraWebGpuEnabled') webgpuEnabled: boolean = false;
  // 「桌面版网站」：全局 UA 默认（'mobile' | 'desktop'）与站点名单
  // （\n 分隔的 host）。两者决定 WebWindow 是否在该站点用桌面形状 UA。
  @StorageLink('auraUaDefault') uaDefault: string = 'mobile';
  // 派生值（AuraShell 发布）：平板/桌面家族未亲手设过开关时按形态默认 desktop。
  @StorageLink('auraUaDefaultEffective') uaDefaultEffective: string = '';
  @StorageLink('auraDesktopSites') desktopSitesRaw: string = '';
  private desktopSitesScroller: Scroller = new Scroller();
  private requestSeq: number = 0;
  private retryTimer: number = -1;

  aboutToAppear(): void {
    // A @Watch callback does not run for the value a @StorageLink is created
    // with, and a byte-identical engine reply raises no change either, so a
    // re-opened settings page would otherwise stay half empty. Seed the view
    // from the stored payload first, then refresh it from the engine.
    this.onPrefsPayload();
    this.onEnginesPayload();
    this.onAboutPayload();
    this.loadAppVersion();
    this.reloadPrefs();
    this.reloadEngines();
    this.reloadAbout();
    this.loadColorModeSetting();
    // 载入自定义搜索引擎与持久化默认项（外壳侧管理，不依赖引擎回包）。
    const ctx = this.hostContext();
    SearchEnginesPrefs.loadDefaultId(ctx).then((id: string): void => {
      this.defaultEngineId = id;
      this.applyMergedEngines();
    });
    SearchEnginesPrefs.loadCustom(ctx).then((list: SearchEngine[]): void => {
      this.customEngines = list;
      this.applyMergedEngines();
    });
    // 确保「启动页」与「网址主页」设置项有最新值可显示。
    if (ctx) {
      ShellUiPrefs.loadStartupPage(ctx).then((value: string): void => {
        AppStorage.setOrCreate('auraStartupPage', value);
      });
      ShellUiPrefs.loadHomeUrl(ctx).then((value: string): void => {
        AppStorage.setOrCreate('auraHomeUrl', value);
      });
      // 多组网址列表也要有值，否则进入这一页看到的是「未添加」。
      ShellUiPrefs.loadHomeUrls(ctx).then((list: string[]): void => {
        AppStorage.setOrCreate('auraHomeUrls', ShellUiPrefs.joinUrlList(list));
        if (AppStorage.get('auraHomeUrl') === '' && list.length > 0) {
          AppStorage.setOrCreate('auraHomeUrl', list[0]);
        }
      });
      // Vulkan 开关从持久化读回（EntryAbility 启动时已写入默认值，
      // 这里在用户打开设置页时刷新为最新）。
      ShellUiPrefs.loadVulkanEnabled(ctx).then((value: boolean): void => {
        AppStorage.setOrCreate('auraVulkanEnabled', value);
      });
      // WebGPU 开关同上，从持久化读回最新值。
      ShellUiPrefs.loadWebGpuEnabled(ctx).then((value: boolean): void => {
        AppStorage.setOrCreate('auraWebGpuEnabled', value);
      });
    }
    // One retry in case the first round was sent before the engine answered.
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (this.toggleItems.length === 0) {
        this.reloadPrefs();
      }
      if (this.engines.length === 0) {
        this.reloadEngines();
      }
      if (this.chromiumVersion.length === 0) {
        this.reloadAbout();
      }
    }, 1500);
  }

  aboutToDisappear(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  private reloadPrefs(): void {
    this.requestSeq += 1;
    // No `keys`: the engine returns every preference it supports.
    this.onCommand({ command: 'getPrefs', requestId: this.requestSeq });
  }

  private reloadEngines(): void {
    this.requestSeq += 1;
    this.onCommand({ command: 'getSearchEngines', requestId: this.requestSeq });
  }

  private reloadAbout(): void {
    this.requestSeq += 1;
    this.onCommand({ command: 'getAboutInfo', requestId: this.requestSeq });
  }

  // 华为账号入口隐藏后，下面三个方法暂无调用方；保留以便随时恢复入口。
  // private accountInfo(): HuaweiAccountInfo {
  //   if (this.accountJson.length === 0) {
  //     return { signedIn: false, openID: '', unionID: '' };
  //   }
  //   try {
  //     const value = JSON.parse(this.accountJson) as HuaweiAccountInfo;
  //     return {
  //       signedIn: value.signedIn === true,
  //       openID: String(value.openID ?? ''),
  //       unionID: String(value.unionID ?? '')
  //     };
  //   } catch (error) {
  //     return { signedIn: false, openID: '', unionID: '' };
  //   }
  // }
  //
  // private accountTitle(): string {
  //   return this.accountInfo().signedIn ? '已登录华为账号' : '华为账号';
  // }
  //
  // private accountSubtitle(): string {
  //   return this.accountInfo().signedIn ? '已登录' : '登录后同步书签和密码';
  // }

  private onPrefsPayload(): void {
    if (this.prefsJson.length === 0) {
      return;
    }
    try {
      const values = JSON.parse(this.prefsJson) as ShellPrefValue[];
      const map = new Map<string, boolean>();
      values.forEach((item: ShellPrefValue): void => {
        map.set(item.key, item.value === true);
      });
      const next: PrefToggleItem[] = PREF_ROWS.map((row: PrefRow): PrefToggleItem => ({
        key: row.key,
        label: row.label,
        value: map.get(row.key) ?? false
      }));
      this.toggleItems = next;
      values.forEach((item: ShellPrefValue): void => {
        if (item.key === 'textScale' && typeof item.value === 'number') {
          this.textScalePercent = item.value;
        }
      });
    } catch (error) {
    }
  }

  private onEnginesPayload(): void {
    if (this.enginesJson.length === 0) {
      return;
    }
    try {
      const engines = JSON.parse(this.enginesJson) as SearchEngine[];
      this.baseEngines = engines;
      if (this.defaultEngineId.length === 0) {
        let found: string = '';
        for (const engine of engines) {
          if (engine.isDefault) {
            found = engine.id;
            break;
          }
        }
        if (found.length === 0) {
          for (const engine of engines) {
            const id = engine.id.toLowerCase();
            const name = engine.name.toLowerCase();
            if (id === 'bing' || name === 'bing') {
              found = engine.id;
              break;
            }
          }
        }
        if (found.length === 0 && engines.length > 0) {
          found = engines[0].id;
        }
        this.defaultEngineId = found;
        SearchEnginesPrefs.saveDefaultId(this.hostContext(), found);
      }
      this.applyMergedEngines();
    } catch (error) {
    }
  }

  // ArkTS 严格模式禁对象展开（arkts-no-spread），手动拷贝字段并覆写 isDefault。
  private cloneEngineWithDefault(e: SearchEngine, isDefault: boolean): SearchEngine {
    return {
      id: e.id,
      name: e.name,
      keyword: e.keyword,
      url: e.url,
      searchUrl: e.searchUrl,
      isDefault: isDefault
    };
  }

  // 引擎列表 + 用户自定义 合并；默认勾选跟随持久化的 defaultEngineId（可指向自定义项）。
  private applyMergedEngines(): void {
    const list: SearchEngine[] = [];
    for (const e of this.baseEngines) {
      list.push(this.cloneEngineWithDefault(e, e.id === this.defaultEngineId));
    }
    for (const c of this.customEngines) {
      list.push(this.cloneEngineWithDefault(c, c.id === this.defaultEngineId));
    }
    this.engines = list;
  }

  private isEngineProtected(engine: SearchEngine): boolean {
    const id = engine.id.toLowerCase();
    const name = engine.name.toLowerCase();
    return id.includes('google') || id.includes('bing') ||
      name.includes('google') || name.includes('bing');
  }

  private hostContext(): common.Context | undefined {
    return this.getUIContext().getHostContext() as common.Context | undefined;
  }

  // 删除自定义引擎（仅自定义可删；内置 Bing/Google 受保护）。
  private async deleteCustom(engine: SearchEngine): Promise<void> {
    const list = this.customEngines.filter((e) => e.id !== engine.id);
    this.customEngines = list;
    const context = this.hostContext();
    await SearchEnginesPrefs.saveCustom(context, list);
    if (this.defaultEngineId === engine.id) {
      this.defaultEngineId = '';
      SearchEnginesPrefs.saveDefaultId(context, '');
      this.reloadEngines();
    } else {
      this.applyMergedEngines();
    }
  }

  // 从「添加」弹层确认新增自定义搜索引擎。网址支持三种填法：
  //   ① 只填域名，如 www.baidu.com / baidu.com —— 内置表推导（百度/必应/谷歌等）；
  //   ② 带 {searchTerms} 的完整模板 —— 直接用；
  //   ③ Chrome 桌面风格的 %s —— 归一成 {searchTerms} 后用。
  // 推导/归一结果回显到输入框，让用户看见最终存的到底是什么。
  private async confirmAddEngine(): Promise<void> {
    const name = this.newEngineName.trim();
    const rawUrl = this.newEngineUrl.trim();
    const resolved = searchTemplateForSite(rawUrl);
    const url = resolved.template;
    if (url !== rawUrl) {
      this.newEngineUrl = url;
    }
    if (name.length === 0 || url.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请填写名称和搜索网址', duration: 1500 });
      return;
    }
    if (!url.includes('{searchTerms}')) {
      this.getUIContext().getPromptAction()
        .showToast({ message: '搜索网址需包含 {searchTerms} 或 %s，或只填域名如 baidu.com', duration: 2600 });
      return;
    }
    const id = `custom:${Date.now().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`;
    const engine: SearchEngine = {
      id: id,
      name: name,
      keyword: name,
      url: url,
      searchUrl: url,
      isDefault: false
    };
    const list = this.customEngines.slice();
    list.push(engine);
    this.customEngines = list;
    await SearchEnginesPrefs.saveCustom(this.hostContext(), list);
    this.newEngineName = '';
    this.newEngineUrl = '';
    this.showAddEngine = false;
    this.applyMergedEngines();
    this.getUIContext().getPromptAction()
      .showToast({
        message: resolved.exact ? '已添加，可在列表中选择为默认'
          : '已按通用 /search?q= 规则生成，若不正确可删除后重填',
        duration: resolved.exact ? 1800 : 2600
      });
  }

  // 选中即生效、停留本页（与深色模式 / 网页缩放一致）：乐观地把对勾立刻挪到当前项，
  // 消除切换引擎时等 400ms 回包才出现的「对勾慢慢跳过去」卡顿。
  private chooseEngine(engine: SearchEngine): void {
    const id = engine.id;
    const next: SearchEngine[] = [];
    for (const e of this.engines) {
      next.push(this.cloneEngineWithDefault(e, e.id === id));
    }
    this.engines = next;
    this.defaultEngineId = id;
    SearchEnginesPrefs.saveDefaultId(this.hostContext(), id);

    // 自定义引擎：引擎没有 add/set 命令，直接覆盖搜索模板，让地址栏/主页搜索生效。
    if (id.startsWith('custom:')) {
      const url = engine.searchUrl ?? engine.url;
      if (url.length > 0) {
        AppStorage.setOrCreate('auraSearchUrlTemplate', url);
      }
      return;
    }
    this.onCommand({ command: 'setDefaultSearchEngine', id: id });
    setTimeout((): void => {
      this.reloadEngines();
    }, 400);
  }

  // 主设置页「搜索引擎」行显示当前默认引擎名称（替代已移除的 defaultEngineName 字段）。
  private defaultEngineLabel(): string {
    for (const e of this.engines) {
      if (e.id === this.defaultEngineId) {
        return e.name;
      }
    }
    return '—';
  }

  private onAboutPayload(): void {
    if (this.aboutJson.length === 0) {
      return;
    }
    try {
      const about = JSON.parse(this.aboutJson) as Record<string, Object>;
      this.chromiumVersion = String(about['chromiumVersion'] ?? '');
    } catch (error) {
    }
  }

  // 关于页需要的本机信息：app 版本/构建号（来自自身包信息）、系统版本
  // （来自 deviceInfo）。两者都是同步只读，失败也不影响页面其余部分。
  private loadAppVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = info.versionName ?? '';
      this.appVersionCode = String(info.versionCode ?? '');
    } catch (error) {
      this.appVersion = '';
      this.appVersionCode = '';
    }
    try {
      this.osVersion = deviceInfo.osFullName ?? '';
    } catch (error) {
      this.osVersion = '';
    }
  }

  private openExternalLink(url: string): void {
    this.onCommand({ command: 'newTab', url: url, background: false });
    this.onBack();
  }

  private onPanelEvent(): void {
    if (this.panelEventJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.panelEventJson) as Record<string, Object>;
      const kind = String(payload['kind'] ?? '');
      if (kind === 'prefsChanged') {
        this.reloadPrefs();
      } else if (kind === 'clearBrowsingDataDone') {
        this.clearing = false;
        AlertDialog.show({
          title: '已清除',
          message: '所选时间范围内的浏览数据已删除。',
          confirm: {
            value: '好的',
            action: (): void => {
            }
          }
        });
        this.popPage();
      }
    } catch (error) {
    }
  }

  // 「网页强制深色」只有一个含义：不响应深色模式的网页要不要由浏览器强制反色。
  // 早先按主题翻转文案（深色下写成「关闭网页强制深色」）是双重否定，已废弃；
  // 浅色主题下这一项整体不显示（见 entryVisible 与外观页渲染处），避免留下
  // 「开关关着却看不出为什么不生效」的死项。
  private isDarkScheme(): boolean {
    return this.actualColorScheme === 'dark';
  }

  private forceDarkLabel(): string {
    return '网页强制深色';
  }

  private forceDarkSubtitle(): string {
    return this.isDarkScheme()
      ? '不响应深色模式的网页将以深色显示'
      : '仅深色模式下生效';
  }

  // 开关显示的是「强制深色当前是否生效」，不是「是否偏离主题默认值」：
  // follow 时跟主题（深色开 / 浅色关），on/off 是用户显式选择。
  private forceDarkActive(): boolean {
    if (this.forceDarkOverride === 'on') {
      return true;
    }
    if (this.forceDarkOverride === 'off') {
      return false;
    }
    return this.isDarkScheme();
  }

  private setForceDarkActive(on: boolean): void {
    this.setPref('forceDarkWebContents', on);
  }

  private entryTitle(entry: SettingsEntry): string {
    return entry.id === 'forceDarkWebContents' ? this.forceDarkLabel() : entry.title;
  }

  private entrySubtitle(entry: SettingsEntry): string {
    return entry.id === 'forceDarkWebContents' ? this.forceDarkSubtitle() : entry.subtitle;
  }

  private setPref(key: ShellPrefKey, value: boolean): void {
    // 受控 Toggle 程序置位也会触发 onChange：值没真变就直接返回，避免乒乓。
    // forceDark 比的是「强制深色当前是否生效」：冷启动引擎 pref 可能还没同步，
    // 拿 prefValue 比较会把用户首次拨动误判成「值没变」而吞掉。
    if (key === 'forceDarkWebContents') {
      if (this.forceDarkActive() === value) {
        return;
      }
    } else if (this.prefValue(key) === value) {
      return;
    }
    const next: PrefToggleItem[] = [];
    this.toggleItems.forEach((item: PrefToggleItem): void => {
      next.push({
        key: item.key,
        label: item.label,
        value: item.key === key ? value : item.value
      });
    });
    this.toggleItems = next;
    if (key === 'forceDarkWebContents') {
      // 拨回「当前主题默认值」就直接恢复跟随，而不是留一个恰好等于默认的
      // 绝对覆盖值；主题变化时 applyColorSchemePush 也会把覆盖态重置为 follow。
      const defaultForced: boolean = this.isDarkScheme();
      const override: ForceDarkOverride = value === defaultForced ? 'follow'
        : (value ? 'on' : 'off');
      AppStorage.setOrCreate('auraForceDarkOverride', override);
      const revision = Number(AppStorage.get('auraForceDarkRevision') ?? 0);
      AppStorage.setOrCreate('auraForceDarkRevision', revision + 1);
      const context = this.getUIContext().getHostContext() as common.Context | undefined;
      if (context) {
        // 带上写入时的配色：跨主题冷启动时该覆盖态应自动失效，
        // 避免上次深色主题内手动拨的 'on' 在浅色下把网页强制拉深。
        AppearanceSettings.saveForceDarkOverride(context, override,
          this.isDarkScheme() ? 'dark' : 'light');
      }
      return;
    }
    this.onCommand({ command: 'setPref', key: key, value: value });
  }

  private loadColorModeSetting(): void {
    const context = this.getUIContext().getHostContext() as common.Context | undefined;
    if (!context) {
      return;
    }
    AppearanceSettings.load(context).then((mode: ColorModeSetting): void => {
      this.colorModeSetting = mode;
    });
  }

  private colorModeLabel(): string {
    if (this.colorModeSetting === 'dark') {
      return '深色';
    }
    return this.colorModeSetting === 'light' ? '浅色' : '跟随系统';
  }

  // ---- 设置检索 ----

  private searchQuery(): string {
    return this.searchText.trim().toLowerCase();
  }

  // 设置项「智能显隐」。「上滑时隐藏状态栏」只在**真正起作用**时显示：
  //  · Chrome 底置：地址栏在屏幕下方、顶端无地址栏阻拦，状态栏显隐由
  //    sendBrowserControls 底置分支的 bottomCollapsing(=hideStatusBarOnScroll) 独立
  //    决定，与「滚动隐藏地址栏」开关无关（见 AuraShell 底置分支 "底置没有顶栏可让，
  //    所以不挂 hideTopBarOnScroll"）→ 恒显示，不受该开关影响；
  //  · 其余（简约 / Chrome 顶置）：状态栏隐藏依赖「滚动隐藏地址栏」开着（collapsing
  //    为真、引擎才进入可收起态），关着时地址栏常驻、无收起那一刻，开关无意义 → 隐藏。
  private hideStatusBarRowVisible(): boolean {
    // Chrome 底置：该开关始终可作用，恒显示。
    if (this.homeStyle === 'chrome' && this.dockPosition === 'bottom') {
      return true;
    }
    if (!this.hideTopBarOnScroll) {
      return false;
    }
    return true;   // 简约 / Chrome 顶置：需「滚动隐藏地址栏」开着
  }

  // 与主设置页共用同一判据，保证搜索结果里也不会冒出被隐藏的项。
  private entryVisible(entry: SettingsEntry): boolean {
    // 浅色主题下 auto-dark 是空操作（默认就不强制），这一项不参与展示，
    // 保证搜索结果与外观页看到的是同一套项。
    if (entry.id === 'forceDarkWebContents') {
      return this.isDarkScheme();
    }
    return entry.id !== 'hideStatusBarOnScroll' || this.hideStatusBarRowVisible();
  }

  private matchedEntries(): SettingsEntry[] {
    const query = this.searchQuery();
    // 先按当前风格/开关过滤掉不起作用的项（与主设置页保持一致）。
    const pool: SettingsEntry[] = SETTINGS_ENTRIES.filter(
      (entry: SettingsEntry): boolean => this.entryVisible(entry));
    if (query.length === 0) {
      return pool;
    }
    const hits: SettingsEntry[] = [];
    pool.forEach((entry: SettingsEntry): void => {
      const haystack: string =
        `${this.entryTitle(entry)} ${this.entrySubtitle(entry)} ${entry.section} ${entry.keywords.join(' ')}`.toLowerCase();
      if (haystack.indexOf(query) >= 0) {
        hits.push(entry);
      }
    });
    return hits;
  }

  private entryValue(entry: SettingsEntry): boolean {
    if (entry.id === 'forceDarkWebContents') {
      return this.forceDarkActive();
    }
    if (entry.kind === 'externalToggle') {
      return this.externalAppLinks;
    }
    if (entry.id === 'hideStatusBarOnScroll') {
      return this.hideStatusBarOnScroll;
    }
    if (entry.id === 'hideTopBarOnScroll') {
      return this.hideTopBarOnScroll;
    }
    if (entry.id === 'hideDockOnScroll') {
      return this.hideDockOnScroll;
    }
    // Vulkan 开关是外壳侧偏好，不走引擎 prefs。
    if (entry.id === 'vulkanEnabled') {
      return this.vulkanEnabled;
    }
    // WebGPU 开关同属外壳侧偏好。
    if (entry.id === 'webgpuEnabled') {
      return this.webgpuEnabled;
    }
    return this.prefValue(entry.id as ShellPrefKey);
  }

  private toggleEntry(entry: SettingsEntry, value: boolean): void {
    const context = this.getUIContext().getHostContext() as common.Context | undefined;
    if (entry.id === 'forceDarkWebContents') {
      this.setForceDarkActive(value);
      return;
    }
    if (entry.kind === 'externalToggle') {
      AppStorage.setOrCreate('auraExternalAppLinks', value);
      if (context) {
        ShellUiPrefs.saveExternalAppLinks(context, value);
      }
      return;
    }
    if (entry.id === 'hideStatusBarOnScroll') {
      AppStorage.setOrCreate('auraHideStatusBarOnScroll', value);
      if (context) {
        ShellUiPrefs.saveHideStatusBar(context, value);
      }
      return;
    }
    if (entry.id === 'hideTopBarOnScroll') {
      AppStorage.setOrCreate('auraHideTopBarOnScroll', value);
      if (context) {
        ShellUiPrefs.saveHideTopBar(context, value);
      }
      return;
    }
    if (entry.id === 'hideDockOnScroll') {
      AppStorage.setOrCreate('auraHideDockOnScroll', value);
      if (context) {
        ShellUiPrefs.saveHideDock(context, value);
      }
      return;
    }
    // Vulkan 开关持久化到 ShellUiPrefs + AppStorage（重启后由引擎启动配置读取）。
    if (entry.id === 'vulkanEnabled') {
      this.vulkanEnabled = value;
      AppStorage.setOrCreate('auraVulkanEnabled', value);
      if (context) {
        ShellUiPrefs.saveVulkanEnabled(context, value);
      }
      return;
    }
    // WebGPU 开关同理。外壳注入命令行即开，无需重编。
    if (entry.id === 'webgpuEnabled') {
      this.webgpuEnabled = value;
      AppStorage.setOrCreate('auraWebGpuEnabled', value);
      if (context) {
        ShellUiPrefs.saveWebGpuEnabled(context, value);
      }
      return;
    }
    this.setPref(entry.id as ShellPrefKey, value);
  }

  // 搜索结果点击：开关就地切换，其余跳到对应页。
  private openEntry(entry: SettingsEntry): void {
    if (entry.kind === 'toggle' || entry.kind === 'externalToggle' ||
      (entry.kind === 'page' && (entry.id === 'hideStatusBarOnScroll' ||
        entry.id === 'hideTopBarOnScroll' || entry.id === 'hideDockOnScroll')) ||
      entry.id === 'vulkanEnabled' || entry.id === 'webgpuEnabled') {
      this.toggleEntry(entry, !this.entryValue(entry));
      return;
    }
    if (entry.id === 'searchEngine') {
      this.openSubPage('engines');
    } else if (entry.id === 'clearBrowsingData') {
      this.openSubPage('clear');
    } else if (entry.id === 'darkMode') {
      this.openSubPage('appearance');
    } else if (entry.id === 'home') {
      this.openSubPage('home');
    } else if (entry.id === 'zoom') {
      this.openSubPage('zoom');
    } else if (entry.id === 'passwords') {
      this.onOpenPasswords();
    } else if (entry.id === 'sitePermissions') {
      this.onOpenSitePermissions();
    } else if (entry.id === 'extensions') {
      this.onOpenExtensions();
    } else if (entry.id === 'about') {
      this.openSubPage('about');
    }
  }

  // 从搜索结果进入二级页：清掉搜索词，落到对应二级页（返回后显示完整设置）。
  private openSubPage(target: string): void {
    this.searchText = '';
    if (target === 'clear') {
      this.refreshBrowsingCounts();
    }
    this.pushPage(target);
  }

  private chooseColorMode(mode: ColorModeSetting): void {
    this.colorModeSetting = mode;
    const context = this.getUIContext().getHostContext() as common.Context | undefined;
    if (!context) {
      return;
    }
    // The engine re-colours web content when the new startup config actually
    // reaches it -- AuraShell watches the routing revision for that moment and
    // reloads the page then. This flag is what turns that reload on; the timer
    // below only covers the case where the configuration never arrives, so a
    // colour switch can never leave the page stale until a manual reload.
    AppStorage.setOrCreate('auraThemeReloadPending', true);
    AppearanceSettings.save(context, mode).then((): void => {
      AppearanceSettings.apply(context, mode);
      const scheme: 'light' | 'dark' = mode === 'dark' ? 'dark'
        : mode === 'light' ? 'light'
        : ((context as common.UIAbilityContext).config.colorMode
          === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ? 'dark' : 'light');
      ThemeSchemePush.dispatch(scheme);
    });
    setTimeout((): void => {
      if (AppStorage.get<boolean>('auraThemeReloadPending') === true) {
        AppStorage.setOrCreate('auraThemeReloadPending', false);
        this.onCommand({ command: 'reload' });
      }
    }, 2500);
  }

  private clearData(): void {
    if (this.clearTypes.length === 0) {
      return;
    }
    this.clearing = true;
    this.requestSeq += 1;
    this.onCommand({
      command: 'clearBrowsingData',
      requestId: this.requestSeq,
      types: this.clearTypes.slice(),
      timeRange: this.clearRange
    });
  }

  // 进入「清除浏览数据」页或切换时间范围时，向引擎拉取各类型数据占用概览。
  private refreshBrowsingCounts(): void {
    this.requestSeq += 1;
    this.onCommand({
      command: 'getBrowsingDataCounts',
      requestId: this.requestSeq,
      timeRange: this.clearRange
    });
  }

  // 引擎回包（browsingDataCounts）写进 AppStorage 后由 @Watch 触发；-1 = 未知。
  private onBrowsingCounts(): void {
    if (this.browsingCountsJson.length === 0) {
      return;
    }
    let payload: object | null = null;
    try {
      payload = JSON.parse(this.browsingCountsJson) as BrowsingDataCountsPayload;
    } catch (error) {
      return;
    }
    if (payload === null || (payload as BrowsingDataCountsPayload).event !== 'browsingDataCounts') {
      return;
    }
    const p = payload as BrowsingDataCountsPayload;
    this.browsingHistoryCount = p.historyCount ?? -1;
    this.browsingCacheBytes = p.cacheBytes ?? -1;
    this.browsingSiteCount = p.siteCount ?? -1;
    this.browsingPasswordCount = p.passwordCount ?? -1;
    this.browsingFormDataCount = p.formDataCount ?? -1;
    this.browsingSiteSettingsCount = p.siteSettingsCount ?? -1;
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    const kb = bytes / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB`;
    }
    const mb = kb / 1024;
    if (mb < 1024) {
      return `${mb.toFixed(1)} MB`;
    }
    const gb = mb / 1024;
    return `${gb.toFixed(2)} GB`;
  }

  private clearTypeChecked(key: BrowsingDataType): boolean {
    return this.clearTypes.indexOf(key) >= 0;
  }

  private toggleClearType(key: BrowsingDataType): void {
    const next: BrowsingDataType[] = [];
    let found: boolean = false;
    for (const item of this.clearTypes) {
      if (item === key) {
        found = true;
      } else {
        next.push(item);
      }
    }
    if (!found) {
      next.push(key);
    }
    this.clearTypes = next;
  }

  // 每行右侧的数量；引擎算不出来（-1）就不显示数字，只留类别名。
  private clearCountLabel(key: BrowsingDataType): string {
    if (key === 'history') {
      return this.browsingHistoryCount >= 0 ? `${this.browsingHistoryCount} 条` : '';
    }
    if (key === 'cookies') {
      return this.browsingSiteCount >= 0 ? `${this.browsingSiteCount} 个网站` : '';
    }
    if (key === 'cache') {
      return this.browsingCacheBytes >= 0 ? this.formatBytes(this.browsingCacheBytes) : '';
    }
    if (key === 'passwords') {
      return this.browsingPasswordCount >= 0 ? `${this.browsingPasswordCount} 条` : '';
    }
    if (key === 'formData') {
      return this.browsingFormDataCount >= 0 ? `${this.browsingFormDataCount} 项` : '';
    }
    if (key === 'siteSettings') {
      return this.browsingSiteSettingsCount >= 0 ?
        `${this.browsingSiteSettingsCount} 个网站` : '';
    }
    return '';
  }

  // 二级页标题按路由名取（name = pushPathByName 传入的路由名）。
  private subPageTitle(name: string): string {
    if (name === 'adblock') {
      return '广告拦截';
    }
    if (name === 'clear') {
      return '清除浏览数据';
    }
    if (name === 'engines') {
      return '搜索引擎';
    }
    if (name === 'appearance') {
      return '深色模式';
    }
    if (name === 'zoom') {
      return '网页缩放';
    }
    if (name === 'account') {
      return '华为账号';
    }
    if (name === 'about') {
      return '关于';
    }
    if (name === 'legal') {
      return '法律许可';
    }
    if (name === 'home') {
      return '主页设置';
    }
    if (name === 'desktopSites') {
      return '桌面版网站';
    }
    return '设置';
  }

  // 二级页滚动容器：绑官方渐变模糊滚动效果（各页自己的 Scroller）。
  private subPageScrollers(name: string): Scroller[] {
    if (name === 'clear') {
      return [this.clearScroller];
    }
    if (name === 'engines') {
      return [this.enginesScroller];
    }
    if (name === 'appearance') {
      return [this.appearanceScroller];
    }
    if (name === 'zoom') {
      return [this.zoomScroller];
    }
    if (name === 'adblock') {
      return [this.adblockScroller];
    }
    if (name === 'about') {
      return [this.aboutScroller];
    }
    if (name === 'legal') {
      return [this.legalScroller];
    }
    if (name === 'home') {
      return [this.homeScroller];
    }
    if (name === 'desktopSites') {
      return [this.desktopSitesScroller];
    }
    return [];
  }

  // 返回：栈里有二级页就 pop（系统自动反向转场）；栈空 = 已在主面板，真正退出设置。
  private popPage(): void {
    if (this.pathStack.size() > 0) {
      this.pathStack.pop();
    }
  }

  // 推入二级页。转场由系统 push-pop 默认接管，不再手写位移/淡出。
  private pushPage(target: string): void {
    this.pathStack.pushPathByName(target, '');
  }

  @Builder
  private SectionLabel(title: string, tightTop: boolean = false) {
    Text(title)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .margin({ top: tightTop ? 4 : 18, bottom: 8 })
  }

  @Builder
  private CardDivider() {
    Divider()
      .color($r('app.color.divider'))
      .margin({ left: 50 })
  }

  private prefValue(key: ShellPrefKey): boolean {
    let found = false;
    this.toggleItems.forEach((item: PrefToggleItem): void => {
      if (item.key === key) {
        found = item.value;
      }
    });
    return found;
  }

  @Builder
  private ToggleRow(icon: Resource, label: string, key: ShellPrefKey) {
    Row({ space: 12 }) {
      Image(icon)
        .width(22)
        .height(22)
        .fillColor($r('app.color.icon_primary'))
      Column({ space: 2 }) {
        // 文案与显示值在 builder 内现读 state：按值传入会在挂载时定死，
        // 主题切换后不刷新。
        Text(key === 'forceDarkWebContents' ? this.forceDarkLabel() : label)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
        if (key === 'forceDarkWebContents' && this.forceDarkSubtitle().length > 0) {
          Text(this.forceDarkSubtitle())
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch,
        isOn: key === 'forceDarkWebContents'
          ? this.forceDarkActive() : this.prefValue(key) })
        .onChange((isOn: boolean) => {
          if (key === 'forceDarkWebContents') {
            this.setForceDarkActive(isOn);
          } else {
            this.setPref(key, isOn);
          }
        })
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16 })
  }

  // 设置检索页：一个输入框 + 命中清单。开关项就地切换（带当前状态），
  // 常驻搜索框：始终显示在设置列表顶部，输入即就地过滤（不单独开搜索页）。
  @Builder
  private SearchBar(searchInputId: string) {
    AuraSearchBar({
      placeholder: '搜索设置项',
      text: this.searchText,
      showClear: true,
      inputId: searchInputId,
      onInput: (value: string): void => {
        this.searchText = value;
        this.searchFabVisible = false;
      },
      onClear: (): void => {
        this.searchText = '';
      }
    })
      .margin({ bottom: 8 })
  }

  @Builder
  private SearchResultRow(entry: SettingsEntry) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(this.entryTitle(entry))
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
        if (this.entrySubtitle(entry).length > 0) {
          Text(this.entrySubtitle(entry))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        Text(entry.section)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (entry.kind === 'toggle' || entry.kind === 'externalToggle' ||
        entry.id === 'hideStatusBarOnScroll' || entry.id === 'hideTopBarOnScroll' ||
        entry.id === 'hideDockOnScroll' || entry.id === 'vulkanEnabled') {
        Toggle({ type: ToggleType.Switch, isOn: this.entryValue(entry) })
          .onChange((isOn: boolean): void => {
            this.toggleEntry(entry, isOn);
          })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor($r('app.color.card_background'))
    .margin({ bottom: 8 })
    .onClick((): void => {
      this.openEntry(entry);
    })
  }

  @Builder
  private MainView() {
    Column() {
      Scroll(this.mainScroller) {
        Column() {
          this.SearchBar('settings_main_search')
          // 华为账号入口：按要求隐藏（同步/登录能力暂不面向用户开放）。
          // 恢复方式：把下面整段注释打开即可，二级页 AccountPanel 代码保留未删。
          // this.SectionLabel('华为账号', true)
          // Column() {
          //   AuraNavIconRow({
          //     icon: $r('app.media.aura_account'),
          //     title: this.accountTitle(),
          //     subtitle: this.accountSubtitle(),
          //     showDivider: false,
          //     onTap: (): void => {
          //       this.pushPage('account');
          //     }
          //   })
          // }
          // .width('100%')
          // .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          // .borderRadius(16)
          // .backgroundColor($r('app.color.card_background'))
          // .clip(true)

          this.SectionLabel('常规', true)
          Column() {
            SettingsNavRow({
              icon: $r('app.media.aura_search'),
              label: '搜索引擎',
              value: this.defaultEngineLabel(),
              onTap: (): void => {
                this.pushPage('engines');
              }
            })
            this.CardDivider()
            SettingsNavRow({
              icon: $r('app.media.aura_extensions'),
              label: '扩展程序',
              value: '',
              onTap: (): void => {
                this.onOpenExtensions();
              }
            })
          }
          .width('100%')
          .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)


          this.SectionLabel('外观')
          Column() {
            SettingsNavRow({
              icon: $r('app.media.aura_moon'),
              label: '深色模式',
              value: this.colorModeLabel(),
              onTap: (): void => {
                this.pushPage('appearance');
              }
            })
            this.CardDivider()
            SettingsNavRow({
              icon: $r('app.media.aura_home'),
              label: '主页设置',
              value: this.homeStyle === 'chrome' ? 'Chrome 风格' : '经典风格',
              onTap: (): void => {
                this.pushPage('home');
              }
            })
            if (this.homeStyle === 'chrome') {
              // Chrome 风格：地址栏融进 dock，此处显示 dock 上/下 + 滚动隐藏地址栏；
              // 隐藏底栏设置（地址栏即 dock，无独立底栏）与顶栏滚动设置。
              this.CardDivider()
              this.HomeDockPositionRow()
              this.CardDivider()
              this.ShellToggleRow($r('app.media.aura_topbar'), '滚动时隐藏地址栏', '',
                this.hideTopBarOnScroll, (isOn: boolean): void => {
                  AppStorage.setOrCreate('auraHideTopBarOnScroll', isOn);
                  const context = this.getUIContext().getHostContext() as common.Context | undefined;
                  if (context) {
                    ShellUiPrefs.saveHideTopBar(context, isOn);
                  }
                })
              // 与简约风格对齐——该开关在 Chrome 风格同样生效（收起后
              // 网页贴顶沉浸 / 停在状态栏底两种几何，见 AuraShell.sendBrowserControls）。
              // 仅**顶置**且「滚动时隐藏地址栏」开着时显示（底置或常驻时它
              // 不起作用 → 隐藏该行，免得拨了没反应）。
              if (this.hideStatusBarRowVisible()) {
                this.CardDivider()
                this.ShellToggleRow($r('app.media.aura_eye'), '上滑时隐藏状态栏', '',
                  this.hideStatusBarOnScroll, (isOn: boolean): void => {
                    AppStorage.setOrCreate('auraHideStatusBarOnScroll', isOn);
                    const context = this.getUIContext().getHostContext() as common.Context | undefined;
                    if (context) {
                      ShellUiPrefs.saveHideStatusBar(context, isOn);
                    }
                  })
              }
            } else {
              this.CardDivider()
              this.ShellToggleRow($r('app.media.aura_topbar'), '滚动时隐藏地址栏', '',
                this.hideTopBarOnScroll, (isOn: boolean): void => {
                  AppStorage.setOrCreate('auraHideTopBarOnScroll', isOn);
                  const context = this.getUIContext().getHostContext() as common.Context | undefined;
                  if (context) {
                    ShellUiPrefs.saveHideTopBar(context, isOn);
                  }
                })
              this.CardDivider()
              this.ShellToggleRow($r('app.media.aura_dock'), '滚动时隐藏底部栏', '',
                this.hideDockOnScroll, (isOn: boolean): void => {
                  AppStorage.setOrCreate('auraHideDockOnScroll', isOn);
                  const context = this.getUIContext().getHostContext() as common.Context | undefined;
                  if (context) {
                    ShellUiPrefs.saveHideDock(context, isOn);
                  }
                })
              // 仅「滚动时隐藏地址栏」开着时显示（关着时地址栏常驻、没有
              // 收起这一刻，该开关不起作用）。
              if (this.hideStatusBarRowVisible()) {
                this.CardDivider()
                this.ShellToggleRow($r('app.media.aura_eye'), '上滑时隐藏状态栏', '',
                  this.hideStatusBarOnScroll, (isOn: boolean): void => {
                    AppStorage.setOrCreate('auraHideStatusBarOnScroll', isOn);
                    const context = this.getUIContext().getHostContext() as common.Context | undefined;
                    if (context) {
                      ShellUiPrefs.saveHideStatusBar(context, isOn);
                    }
                  })
              }
            }
            this.CardDivider()
            SettingsNavRow({
              icon: $r('app.media.aura_zoom'),
              label: '网页缩放',
              value: `${this.textScalePercent}%`,
              onTap: (): void => {
                this.pushPage('zoom');
              }
            })
            // 只在深色主题下出现：浅色主题不存在「强制深色」这件事，
            // 显示出来只会是一条关着又看不出原因的项。
            if (this.isDarkScheme()) {
              this.CardDivider()
              // label 参数会被 builder 内的动态文案覆盖，见 forceDarkLabel。
              this.ToggleRow($r('app.media.aura_display'), '网页强制深色', 'forceDarkWebContents')
            }
          }
          .width('100%')
          .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          this.SectionLabel('网站')
          Column() {
            SettingsNavRow({
              icon: $r('app.media.aura_globe'),
              label: '网站权限',
              value: '',
              onTap: (): void => {
                this.onOpenSitePermissions();
              }
            })
            this.CardDivider()
            this.ShellToggleRow($r('app.media.aura_open_in_new'), '允许跳转本机应用',
              '',
              this.externalAppLinks, (isOn: boolean): void => {
                AppStorage.setOrCreate('auraExternalAppLinks', isOn);
                const context = this.getUIContext().getHostContext() as common.Context | undefined;
                if (context) {
                  ShellUiPrefs.saveExternalAppLinks(context, isOn);
                }
              })
            this.CardDivider()
            // 展示与下发都用派生键：平板/桌面家族在读者没亲手碰过开关时
            // 按形态默认桌面版（isOn 显示为开）；亲手拨动后写显式标志，
            // 之后永远以用户选择为准（横屏平板也能明确关回手机默认）。
            this.ShellToggleRow($r('app.media.aura_desktop'), '默认使用桌面版网站', '所有网站以桌面版打开',
              (this.uaDefaultEffective || this.uaDefault) === 'desktop', (isOn: boolean): void => {
                const value: string = isOn ? 'desktop' : 'mobile';
                AppStorage.setOrCreate('auraUaDefault', value);
                AppStorage.setOrCreate('auraUaDefaultSet', true);
                AppStorage.setOrCreate('auraUaDefaultEffective', value);
                const ctx = this.getUIContext().getHostContext() as common.Context | undefined;
                if (ctx) {
                  ShellUiPrefs.saveUaDefault(ctx, value);
                  ShellUiPrefs.saveUaDefaultSet(ctx, true);
                }
                // 立即作用于当前标签：切换 UA 后重载，与桌面版开关的原生行为一致。
                this.onCommand({
                  command: 'setDesktopSites',
                  sites: String(AppStorage.get('auraDesktopSites') ?? ''),
                  allSites: isOn,
                  mobileSites: String(AppStorage.get('auraMobileSites') ?? '')
                });
                this.onCommand({ command: 'setRequestDesktopSite', enabled: isOn });
                this.onCommand({ command: 'reload' });
              })
            this.CardDivider()
            SettingsNavRow({
              icon: $r('app.media.aura_view_list'),
              label: '已设为桌面版的网站',
              value: this.desktopSiteCountLabel(),
              onTap: (): void => {
                this.pushPage('desktopSites');
              }
            })
          }
          .width('100%')
          .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          this.SectionLabel('隐私与安全')
          Column() {
            SettingsNavRow({
              icon: $r('app.media.aura_lock'),
              label: '密码',
              value: '',
              onTap: (): void => {
                this.onOpenPasswords();
              }
            })
            this.CardDivider()
            SettingsNavRow({
              icon: $r('app.media.aura_block'),
              label: '广告拦截',
              value: '',
              onTap: (): void => {
                this.pushPage('adblock');
              }
            })
            this.CardDivider()
            this.ToggleRow($r('app.media.aura_cookie'), '阻止第三方 Cookie', 'blockThirdPartyCookies')
            this.CardDivider()
            this.ToggleRow($r('app.media.aura_window'), '拦截弹窗', 'popupsBlocked')
            this.CardDivider()
            this.ToggleRow($r('app.media.aura_block'), '发送"请勿追踪"请求', 'doNotTrack')
            this.CardDivider()
            SettingsNavRow({
              icon: $r('app.media.aura_trash'),
              label: '清除浏览数据',
              value: '',
              danger: true,
              onTap: (): void => {
                this.pushPage('clear');
              }
            })
          }
          .width('100%')
          .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          this.SectionLabel('高级')
          Column() {
            this.ToggleRow($r('app.media.aura_code'), '启用 JavaScript', 'javascriptEnabled')
            this.CardDivider()
            this.ToggleRow($r('app.media.aura_bolt'), '预加载网页', 'preloadPages')
            this.CardDivider()
            // 「Vulkan 渲染加速」：外壳侧偏好，不走引擎 prefs。经 angleBackend
            // 切换 ANGLE 后端：关 = gles-egl（默认，稳），开 = vulkan（实验性）。
            // 启动时读取一次，改动需重启生效。
            this.ShellToggleRow($r('app.media.aura_gpu'), 'Vulkan 渲染加速',
              '实验性：开启后部分机型可能滑动掉帧，建议保持关闭；改动需重启应用后生效',
              this.vulkanEnabled, (on: boolean): void => {
                this.vulkanEnabled = on;
                AppStorage.setOrCreate('auraVulkanEnabled', on);
                const context = this.getUIContext().getHostContext() as common.Context | undefined;
                if (context) {
                  ShellUiPrefs.saveVulkanEnabled(context, on);
                }
              })
            this.CardDivider()
            // 「WebGPU 加速」：外壳侧偏好，不走引擎 prefs。外壳注入
            // --enable-unsafe-webgpu 即开（引擎侧 Dawn/WebGPU 已编入），与 ANGLE 后端互
            // 不干扰。默认关（稳定性/兼容性考虑）。图标用立方体，区别于 Vulkan 的芯片。
            // 启动时读取一次，改动需重启生效。
            this.ShellToggleRow($r('app.media.aura_webgpu'), 'WebGPU 加速',
              '实验性：开启后网页可用 GPU 计算/渲染（navigator.gpu）；改动需重启应用后生效',
              this.webgpuEnabled, (on: boolean): void => {
                this.webgpuEnabled = on;
                AppStorage.setOrCreate('auraWebGpuEnabled', on);
                const context = this.getUIContext().getHostContext() as common.Context | undefined;
                if (context) {
                  ShellUiPrefs.saveWebGpuEnabled(context, on);
                }
              })
            this.CardDivider()
            this.ToggleRow($r('app.media.aura_download'), '下载前询问', 'downloadAskWhereToSave')
          }
          .width('100%')
          .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          this.SectionLabel('关于')
          Column() {
            SettingsNavRow({
              icon: $r('app.media.aura_info'),
              label: '关于 Orbira',
              value: '',
              onTap: (): void => {
                this.pushPage('about');
              }
            })
          }
          .width('100%')
          .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

        }
        .width('100%')
        .padding({ top: glassHeaderInsetVp(), bottom: glassBottomInsetVp() })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      // Scroll centers content shorter than the viewport by default (the
      // universal `align` attribute defaults to Alignment.Center), which
      // showed up as a big gap under the header. Pin it to the top.
      .align(Alignment.TopStart)
      .onDidScroll(() => {
        // 搜索框随设置列表滚走后，标题栏右侧浮现搜索按钮（点它回顶 + 聚焦）。
        const off = this.mainScroller.currentOffset().yOffset;
        const show = off > glassHeaderInsetVp() + 20;
        if (show !== this.searchFabVisible) {
          this.searchFabVisible = show;
        }
      })
      .visibility(this.searchQuery().length === 0 ? Visibility.Visible : Visibility.None)

      Scroll(this.filteredScroller) {
        Column() {
          this.SearchBar('settings_filtered_search')
          ForEach(this.matchedEntries(), (entry: SettingsEntry) => {
            this.SearchResultRow(entry)
          }, (entry: SettingsEntry): string => entry.id)

          if (this.matchedEntries().length === 0) {
            Text('没有找到相关设置项')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 32 })
          }
        }
        .width('100%')
        .padding({ top: glassHeaderInsetVp(), bottom: glassBottomInsetVp() })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .align(Alignment.TopStart)
      .onDidScroll(() => {
        // 搜索框随过滤列表滚走后，标题栏右侧浮现搜索按钮（点它回顶 + 聚焦）。
        const off = this.filteredScroller.currentOffset().yOffset;
        const show = off > glassHeaderInsetVp() + 20;
        if (show !== this.searchFabVisible) {
          this.searchFabVisible = show;
        }
      })
      .visibility(this.searchQuery().length === 0 ? Visibility.None : Visibility.Visible)
    }
    .width('100%')
    .height('100%')
  }

  // 时间范围行：右侧单选圈（选中 = 实心 accent + 白勾），整行可点。
  @Builder
  private ClearRangeRow(row: RangeRow) {
    Row() {
      Text(row.label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
      Blank()
      Stack() {
        if (row.key === this.clearRange) {
          Text('✓')
            .fontSize(13)
            .fontColor($r('app.color.on_accent'))
        }
      }
      .width(22)
      .height(22)
      .borderRadius(11)
      .backgroundColor(row.key === this.clearRange ?
        $r('app.color.accent_primary') : Color.Transparent)
      .border({
        width: 1.5,
        color: row.key === this.clearRange ?
          $r('app.color.accent_primary') : $r('app.color.divider')
      })
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16 })
    .onClick(() => {
      if (row.key !== this.clearRange) {
        this.clearRange = row.key;
        this.refreshBrowsingCounts();
      }
    })
  }

  // 数据类型行：左侧勾选框 + 名称 + 右侧该时间范围内的实际数量。
  @Builder
  private ClearTypeRow(row: ClearTypeRow) {
    Row({ space: 12 }) {
      Stack() {
        if (this.clearTypeChecked(row.key)) {
          Text('✓')
            .fontSize(13)
            .fontColor($r('app.color.on_accent'))
        }
      }
      .width(22)
      .height(22)
      .borderRadius(11)
      .backgroundColor(this.clearTypeChecked(row.key) ?
        $r('app.color.accent_primary') : Color.Transparent)
      .border({
        width: 1.5,
        color: this.clearTypeChecked(row.key) ?
          $r('app.color.accent_primary') : $r('app.color.divider')
      })

      Text(row.label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.clearCountLabel(row.key).length > 0) {
        Text(this.clearCountLabel(row.key))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16 })
    .onClick(() => {
      this.toggleClearType(row.key);
    })
  }

  @Builder
  private ClearView() {
    Column() {
      // 时间范围与数据类型各成一张卡：范围单选在右、类型勾选在左且各带
      // 数量。「清除数据」钮留在滚动容器外，仍然钉在底部。
      Scroll(this.clearScroller) {
        Column() {
          Text('按所选时间范围清除勾选的数据类型。书签和已下载的文件本身不受影响。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 4, bottom: 12 })

          // 时间范围
          Column() {
            ForEach(CLEAR_RANGES, (row: RangeRow, index: number) => {
              Column() {
                this.ClearRangeRow(row)
                if (index < CLEAR_RANGES.length - 1) {
                  Divider()
                    .color($r('app.color.divider'))
                    .margin({ left: 16 })
                }
              }
              .width('100%')
            }, (row: RangeRow): string => `${row.key}|${this.clearRange}`)
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)
          .margin({ bottom: 12 })

          // 数据类型（数量随范围/回包变化，键里带上，避免旧行不重跑）
          Column() {
            ForEach(CLEAR_TYPE_ROWS, (row: ClearTypeRow, index: number) => {
              Column() {
                this.ClearTypeRow(row)
                if (index < CLEAR_TYPE_ROWS.length - 1) {
                  Divider()
                    .color($r('app.color.divider'))
                    .margin({ left: 50 })
                }
              }
              .width('100%')
            }, (row: ClearTypeRow): string => `${row.key}|${this.clearTypeChecked(row.key) ? 1 : 0}|${this.clearCountLabel(row.key)}`)
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)
        }
        .width('100%')
        // 同 HomeStyleView —— 内缩放滚动内容上，别压在外层（会丢顶部渐变模糊）。
        .padding({ top: glassHeaderInsetVp() })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .align(Alignment.TopStart)

      Button(this.clearing ? '清除中…' : '清除数据')
        .margin({ bottom: glassBottomInsetVp() })
        .width('100%')
        .height(46)
        .fontSize(16)
        .fontColor($r('app.color.on_accent'))
        .backgroundColor($r('app.color.danger'))
        .borderRadius(10)
        .enabled(!this.clearing && this.clearTypes.length > 0)
        .opacity(this.clearing || this.clearTypes.length === 0 ? 0.5 : 1)
        .onClick(() => {
          this.clearData();
        })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private EnginesView() {
    Column() {
      if (this.engines.length === 0) {
        Column() {
          Text('加载中…')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll(this.enginesScroller) {
          Column() {
            AuraSectionLabel({ text: '选择默认搜索引擎', tightTop: true })

            Column() {
              ForEach(this.engines, (engine: SearchEngine, index: number) => {
                Column() {
                  Row({ space: 12 }) {
                    Image($r('app.media.aura_search'))
                      .width(22)
                      .height(22)
                      .fillColor($r('app.color.icon_primary'))
                    Text(engine.name)
                      .fontSize(16)
                      .fontColor($r('app.color.text_primary'))
                    Blank()
                    // 自定义引擎可删除（Bing / Google 受保护不可删）。
                    if (!this.isEngineProtected(engine)) {
                      Image($r('app.media.aura_trash'))
                        .width(20)
                        .height(20)
                        .fillColor($r('app.color.icon_secondary'))
                        .onClick(() => {
                          this.deleteCustom(engine);
                        })
                    }
                    if (engine.isDefault) {
                      Text('✓')
                        .fontSize(16)
                        .fontColor($r('app.color.accent_primary'))
                    }
                  }
                  .width('100%')
                  .constraintSize({ minHeight: 56 })
                  .padding({ left: 16, right: 16 })
                  .onClick(() => {
                    this.chooseEngine(engine);
                  })

                  if (index < this.engines.length - 1) {
                    Divider()
                      .color($r('app.color.divider'))
                      .margin({ left: 50 })
                  }
                }
                .width('100%')
                // 键值带上 isDefault：ForEach 键值不变会复用旧组件而不重跑
                // item builder，换默认引擎后 ✓ 会停在旧项上。
              }, (engine: SearchEngine): string => `${engine.id}|${engine.isDefault ? 1 : 0}`)
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor($r('app.color.card_background'))
            .clip(true)

            // 添加自定义搜索引擎。
            Row() {
              Button({ type: ButtonType.Normal }) {
                Row({ space: 6 }) {
                  Image($r('app.media.aura_plus'))
                    .width(18)
                    .height(18)
                    .fillColor($r('app.color.accent_primary'))
                  Text('添加搜索引擎')
                    .fontSize(15)
                    .fontColor($r('app.color.accent_primary'))
                }
              }
              .width('100%')
              .height(48)
              .backgroundColor(Color.Transparent)
              .border({ width: 1, color: $r('app.color.divider'), style: BorderStyle.Dashed })
              .borderRadius(12)
              .onClick(() => {
                this.showAddEngine = true;
              })
            }
            .width('100%')
            .padding({ top: 12 })

            // 添加弹层（内联卡片，避免模态遮挡二级页头部）。
            if (this.showAddEngine) {
              this.AddEngineDialog()
            }

            Text('默认搜索引擎用于地址栏和主页的搜索。Bing / Google 受保护不可删除，其他可自由增删。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 4, right: 4, top: 10 })
          }
          .width('100%')
          // 大标题带：见 MainView 同款注释。
          .padding({ top: glassHeaderInsetVp() })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private AddEngineDialog() {
    Column({ space: 10 }) {
      Row() {
        Text('添加搜索引擎')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Image($r('app.media.aura_close'))
          .width(18)
          .height(18)
          .fillColor($r('app.color.icon_primary'))
          .onClick(() => {
            this.showAddEngine = false;
            this.newEngineName = '';
            this.newEngineUrl = '';
          })
      }
      .width('100%')

      TextInput({ placeholder: '名称，如 必应', text: this.newEngineName })
        .width('100%')
        .height(44)
        .backgroundColor($r('app.color.surface_secondary'))
        .borderRadius(10)
        .onChange((v: string): void => {
          this.newEngineName = v;
        })

      TextInput({ placeholder: '域名如 baidu.com，或含 {searchTerms} 的网址', text: this.newEngineUrl })
        .width('100%')
        .height(44)
        .backgroundColor($r('app.color.surface_secondary'))
        .borderRadius(10)
        .onChange((v: string): void => {
          this.newEngineUrl = v;
        })

      Text('填域名即可自动生成（如 baidu.com）；完整网址的占位符用 {searchTerms} 或 %s')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Row({ space: 12 }) {
        Button('取消', { type: ButtonType.Normal })
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface_secondary'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.showAddEngine = false;
            this.newEngineName = '';
            this.newEngineUrl = '';
          })
        Button('添加', { type: ButtonType.Normal })
          .layoutWeight(1)
          .backgroundColor($r('app.color.accent_primary'))
          .fontColor($r('app.color.on_accent'))
          .onClick(() => {
            this.confirmAddEngine();
          })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor($r('app.color.card_background'))
    .margin({ top: 12 })
  }

  @Builder
  private ColorModeRow(mode: ColorModeSetting, label: string) {
    Row() {
      Text(label)
        .fontSize(16)
        .fontColor(this.colorModeSetting === mode ?
          $r('app.color.accent_primary') : $r('app.color.text_primary'))
      Blank()
      if (this.colorModeSetting === mode) {
        Text('✓')
          .fontSize(16)
          .fontColor($r('app.color.accent_primary'))
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16 })
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      this.chooseColorMode(mode);
    })
  }

  @Builder
  private AppearanceView() {
    Column() {
      // 改成由 Scroll 承载内容（Spring 回弹 + alwaysEnabled）——内容
      // 不足一屏时也能像主面板一样上拉回弹。顶部内边距仍留在外层，静态位置不变。
      Scroll(this.appearanceScroller) {
        Column() {
          Text('深色模式下，浏览器界面和网页一起变暗。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 4, bottom: 12 })

          Column() {
            this.ColorModeRow('system', '跟随系统')
            Divider()
              .color($r('app.color.divider'))
              .margin({ left: 16, right: 16 })
            this.ColorModeRow('light', '浅色')
            Divider()
              .color($r('app.color.divider'))
              .margin({ left: 16, right: 16 })
            this.ColorModeRow('dark', '深色')
          }
          .width('100%')
          .padding({ top: 4, bottom: 4 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)
          .margin({ top: 4 })
        }
        .width('100%')
        // 同 HomeStyleView —— 内缩放滚动内容上，别压在外层（会丢顶部渐变模糊）。
        .padding({ top: glassHeaderInsetVp() })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
  }

  // 外壳偏好（非引擎 prefs）：上滑隐藏状态栏，AppStorage + preferences 持久化。
  @Builder
  private ShellToggleRow(icon: Resource, label: string, subtitle: string, checked: boolean,
    onToggle: (on: boolean) => void) {
    Row({ space: 12 }) {
      Image(icon)
        .width(22)
        .height(22)
        .fillColor($r('app.color.icon_primary'))
      Column({ space: 2 }) {
        Text(label)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: checked })
        .onChange((isOn: boolean) => {
          onToggle(isOn);
        })
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  // 网页缩放：整页默认缩放（textScale，50–200）。
  @Builder
  private ZoomView() {
    Column() {
      // 同「深色模式」页——挂 Scroll + Spring 回弹（档位不足一屏也有反馈）。
      Scroll(this.zoomScroller) {
        Column() {
          Text('整页一起放大或缩小，对所有网页生效。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 4, bottom: 12 })

          Column() {
            ForEach([50, 75, 80, 90, 100, 125, 150, 175, 200], (scale: number) => {
              Row() {
                Text(`${scale}%`)
                  .fontSize(16)
                  .fontColor(scale === this.textScalePercent ?
                    $r('app.color.accent_primary') : $r('app.color.text_primary'))
                  .fontWeight(scale === this.textScalePercent ? FontWeight.Medium : FontWeight.Regular)
                Blank()
                if (scale === this.textScalePercent) {
                  Text('✓')
                    .fontSize(16)
                    .fontColor($r('app.color.accent_primary'))
                }
              }
              .width('100%')
              .constraintSize({ minHeight: 56 })
              .padding({ left: 16, right: 16 })
              .onClick(() => {
                this.setPrefNumber('textScale', scale);
              })
              if (scale !== 200) {
                Divider()
                  .color($r('app.color.divider'))
                  .margin({ left: 16 })
              }
            }, (scale: number): string => scale.toString())
          }
          .width('100%')
          .padding({ top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)
        }
        .width('100%')
        // 同 HomeStyleView —— 内缩放滚动内容上，别压在外层（会丢顶部渐变模糊）。
        .padding({ top: glassHeaderInsetVp() })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
  }

  private setPrefNumber(key: ShellPrefKey, value: number): void {
    this.textScalePercent = value;
    this.onCommand({ command: 'setPref', key: key, value: value });
    setTimeout((): void => {
      this.reloadPrefs();
    }, 400);
  }

  // 关于页：应用简介 + 内核 / 开源协议信息。
  @Builder
  private AboutView() {
    Column() {
      Scroll(this.aboutScroller) {
        Column() {
          // Hero：软件图标 + 名称 + 标语
          Column() {
            // 应用图标本体（navy 底），深浅色模式下都清晰
            Image($r('app.media.foreground'))
              .width(88)
              .height(88)
              .borderRadius(22)
              .shadow({ radius: 16, color: '#00000014', offsetX: 0, offsetY: 6 })
            Text('Orbira 星轨浏览器')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .margin({ top: 18 })
            Text('基于 Chromium 的鸿蒙浏览器')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 6 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .margin({ top: 40, bottom: 28 })

          // 信息卡（与设置主列表同款全宽卡片）
          Column() {
            this.InfoRow('当前版本', this.appVersion.length > 0 ? this.appVersion : '—')
            this.CardDivider()
            this.InfoRow('内核版本', this.chromiumVersion.length > 0 ? `Chromium ${this.chromiumVersion}` : '—')
            this.CardDivider()
            this.InfoLinkRow('法律许可', 'BSD-3-Clause', (): void => {
              this.pushPage('legal');
            })
          }
          .width('100%')
          .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          // 简介（段落单独留 16 阅读 gutter）
          Text('Orbira 是面向 HarmonyOS 的 Chromium 适配浏览器，由开源项目 chromium-hmos 构建，' +
            '把桌面级的浏览体验带到鸿蒙设备。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 24, bottom: 20 })
            .padding({ left: 16, right: 16 })
            .lineHeight(22)

          // 页脚：构建号 + 系统版本
          Text(this.aboutFooter())
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .opacity(0.7)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 28 })
        }
        .width('100%')
        // 同 HomeStyleView —— 内缩放滚动内容上，别压在外层（会丢顶部渐变模糊）。
        .padding({ top: glassHeaderInsetVp() })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
  }

  // 「法律许可」子页。应用自身许可（BSD 3-Clause 全文）+ 版权声明 +
  // 第三方组件许可简述。文本来自仓库 LICENSE / OPEN_SOURCE_NOTICES.md，与上游一致。
  @Builder
  private LegalSectionTitle(title: string) {
    Text(title)
      .fontSize(15)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.text_primary'))
      .width('100%')
      .padding({ left: 16, right: 16, top: 22, bottom: 10 })
  }

  @Builder
  private LegalView() {
    Column() {
      Scroll(this.legalScroller) {
        Column() {
          this.LegalSectionTitle('版权声明')
          Text('Orbira 星轨浏览器（基于 Chromium 的鸿蒙浏览器）\n' +
            'Copyright © 2015 The Chromium Authors. All rights reserved.\n' +
            // 内核版本改为动态读取（getAboutInfo → chromiumVersion，
            // 与下方「关于」页的内核版本行同源）。原硬编码 150.0.7871.114，
            // 实际引擎已基于 154，装机反馈「法律页显示 150」。
            `基于 Chromium ${this.chromiumVersion.length > 0 ? this.chromiumVersion : '—'} 构建。`)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .lineHeight(22)
            .padding({ left: 16, right: 16 })
            .textAlign(TextAlign.Start)

          this.CardDivider()

          this.LegalSectionTitle('应用程序许可（BSD 3-Clause）')
          Text(APP_LICENSE_TEXT)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .lineHeight(20)
            .padding({ left: 16, right: 16 })
            .textAlign(TextAlign.Start)

          this.CardDivider()

          this.LegalSectionTitle('第三方组件许可')
          Text(THIRD_PARTY_LICENSE_NOTE)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .lineHeight(22)
            .padding({ left: 16, right: 16 })
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        // 内容内缩放，别压外层（会丢顶部渐变模糊）。
        .padding({ top: glassHeaderInsetVp() })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
  }

  private aboutFooter(): string {
    const parts: string[] = [];
    if (this.appVersionCode.length > 0) {
      parts.push(`构建 ${this.appVersionCode}`);
    }
    if (this.osVersion.length > 0) {
      parts.push(this.osVersion);
    }
    return parts.join(' · ');
  }

  @Builder
  private InfoRow(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
      Blank()
      Text(value)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  @Builder
  private InfoLinkRow(label: string, value: string, action: () => void) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
      Blank()
      Text(value)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
      Image($r('app.media.aura_chevron'))
        .width(16)
        .height(16)
        .fillColor($r('app.color.icon_secondary'))
        .opacity(0.65)
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .onClick(action)
  }

  // 主页设置子页：双风格缩略图选择。
  @Builder
  private HomeStyleView() {
    Column() {
      Scroll(this.homeScroller) {
        Column({ space: 16 }) {
          this.SectionLabel('选择主页风格', true)
          Row({ space: 12 }) {
            this.HomeStyleCard('minimal', '经典风格', '保留顶部地址栏与状态栏，底部独立 dock', $r('app.media.home_style_minimal'))
            this.HomeStyleCard('chrome', 'Chrome 风格', '地址栏融入 dock，主页更聚焦', $r('app.media.home_style_chrome'))
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          // 「启动页」：冷启动打开内置启动页还是已设置的网址主页。
          this.SectionLabel('启动行为', true)
          Column() {
            this.StartupPageRow()
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          // 「地址栏位置」从此子页去掉——外观区已有同项（上/下分段），
          // 主页设置只留风格选择 + 自定义入口，避免同一设置两处出现。

          this.SectionLabel('主页自定义', true)
          Column() {
            SettingsNavRow({
              icon: $r('app.media.aura_tune'),
              label: '自定义主页布局',
              value: '',
              onTap: (): void => {
                this.onCommand({ command: 'homeSurface' });
                this.onOpenHomeLayout();
              }
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          Text('切换后即时生效，主页与浏览界面都会跟随。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 16, right: 16 })
        }
        .width('100%')
        .padding({ top: glassHeaderInsetVp() })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private HomeStyleCard(value: string, title: string, desc: string, thumb: Resource) {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Image(thumb)
          .width('100%')
          .aspectRatio(0.571)
          .borderRadius(12)
      }
      .width('100%')
      .padding(this.homeStyle === value ? 3 : 1)
      .backgroundColor(this.homeStyle === value ?
        $r('app.color.accent_primary') : $r('app.color.divider'))
      .borderRadius(this.homeStyle === value ? 15 : 13)
      Row({ space: 6 }) {
        if (this.homeStyle === value) {
          Image($r('app.media.aura_check'))
            .width(16)
            .height(16)
            .fillColor($r('app.color.accent_primary'))
        }
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.homeStyle === value ? $r('app.color.accent_primary') : $r('app.color.text_primary'))
      }
      Text(desc)
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .onClick((): void => {
      if (this.homeStyle === value) {
        return;
      }
      this.homeStyle = value;
      AppStorage.setOrCreate('auraHomeStyle', value);
      const context = this.getUIContext().getHostContext() as common.Context | undefined;
      if (context) {
        ShellUiPrefs.saveHomeStyle(context, value);
      }
    })
  }

  // Chrome 风格下 dock 位置（上 / 下）分段选择。
  @Builder
  private HomeDockPositionRow() {
    Row({ space: 12 }) {
      Image($r('app.media.aura_dock'))
        .width(22)
        .height(22)
        .fillColor($r('app.color.icon_primary'))
      Column({ space: 2 }) {
        Text('地址栏位置')
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Row({ space: 0 }) {
        this.DockPosPill('上', 'top')
        this.DockPosPill('下', 'bottom')
      }
      .backgroundColor($r('app.color.surface_secondary'))
      .borderRadius(10)
      .padding(2)
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  @Builder
  private DockPosPill(label: string, value: string) {
    Text(label)
      .fontSize(14)
      .fontColor(this.dockPosition === value ? Color.White : $r('app.color.text_primary'))
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .borderRadius(8)
      .backgroundColor(this.dockPosition === value ? $r('app.color.accent_primary') : Color.Transparent)
      .onClick((): void => {
        if (this.dockPosition === value) {
          return;
        }
        this.dockPosition = value;
        AppStorage.setOrCreate('auraDockPosition', value);
        const context = this.getUIContext().getHostContext() as common.Context | undefined;
        if (context) {
          ShellUiPrefs.saveDockPosition(context, value);
        }
      })
  }

  @Builder
  private StartupPageRow() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Image($r('app.media.aura_home'))
          .width(22)
          .height(22)
          .flexShrink(0)
          .fillColor($r('app.color.icon_primary'))
        Column({ space: 2 }) {
          Text('启动页')
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text(this.startupPageHint())
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 0 }) {
        this.StartupPagePill('内置启动页', 'builtin')
        this.StartupPagePill('网址主页', 'homeUrl')
      }
      .width('100%')
      .backgroundColor($r('app.color.surface_secondary'))
      .borderRadius(10)
      .padding(2)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  // 多组网址（\n 分隔）解析成列表，用于文案里的条数与「未添加」判定。
  private homeUrlList(): string[] {
    return ShellUiPrefs.parseUrlList(this.homeUrlsRaw);
  }

  private startupPageHint(): string {
    if (this.startupPage !== 'homeUrl') {
      return '启动软件与按下主页键时，打开内置启动页（新标签页）';
    }
    const list: string[] = this.homeUrlList();
    const active: string = this.homeUrl.length > 0 ? this.homeUrl
      : (list.length > 0 ? list[0] : '');
    if (active.length === 0) {
      return '尚未添加网址，点右上角「自定义网址」添加';
    }
    if (list.length > 1) {
      return `启动软件与按下主页键时打开：${active}（共 ${list.length} 个，右上角可切换）`;
    }
    return `启动软件与按下主页键时打开：${active}`;
  }

  @Builder
  private StartupPagePill(label: string, value: string) {
    Text(label)
      .fontSize(14)
      .textAlign(TextAlign.Center)
      .fontColor(this.startupPage === value ? Color.White : $r('app.color.text_primary'))
      // 两段等宽、去掉左右内边距：不再由文字长度决定宽度，也就不会把邻居挤扁。
      .padding({ top: 9, bottom: 9 })
      .layoutWeight(1)
      .borderRadius(8)
      .backgroundColor(this.startupPage === value ? $r('app.color.accent_primary') : Color.Transparent)
      .onClick((): void => {
        if (this.startupPage === value) {
          return;
        }
        this.startupPage = value;
        AppStorage.setOrCreate('auraStartupPage', value);
        const context = this.getUIContext().getHostContext() as common.Context | undefined;
        if (context) {
          ShellUiPrefs.saveStartupPage(context, value);
        }
      })
  }

  @Builder
  private buildSubPageDestination(name: string, _param: Object): void {
    HdsNavDestination() {
      Column() {
        if (name === 'clear') {
          this.ClearView()
        } else if (name === 'engines') {
          this.EnginesView()
        } else if (name === 'appearance') {
          this.AppearanceView()
        } else if (name === 'zoom') {
          this.ZoomView()
        } else if (name === 'account') {
          HuaweiAccountView()
        } else if (name === 'about') {
          this.AboutView()
        } else if (name === 'legal') {
          this.LegalView()
        } else if (name === 'home') {
          this.HomeStyleView()
        } else if (name === 'desktopSites') {
          this.DesktopSitesView()
        } else if (name === 'adblock') {
          AdBlockPanel({
            scroller: this.adblockScroller,
            onCommand: (command: BrowserCommandPayload): void => {
              this.onCommand(command);
            }
          })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .titleBar({
      content: {
        title: { mainTitle: this.subPageTitle(name) },
        backIcon: {
          icon: $r('sys.symbol.chevron_backward'),
          isEnabled: true,
          action: (): void => {
            this.popPage();
          }
        },
        // 「主页设置」右上角 = 自定义网址主页（支持多组网址）。
        // 非该页传 undefined（而非空数组——空数组会被 HDS 当作"有菜单但零项"）。
        menu: name === 'home'
          ? {
            value: [
              {
                content: {
                  icon: $r('app.media.aura_globe'),
                  label: '自定义网址',
                  action: (): void => {
                    this.onAddHomeTile();
                  }
                }
              }
            ]
          }
          : undefined
      },
      style: {
        // 官方渐变模糊滚动效果 + 沉浸光感材质（与主面板标题栏同一套）。
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: false
    })
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .hideBackButton(false)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindToScrollable(this.subPageScrollers(name))
    .backgroundColor($r('app.color.page_background'))
    .onBackPressed((): boolean => {
      this.popPage();
      return true;
    })
  }

  // 「已设为桌面版的网站」管理页：列出被强制桌面版的 host，可逐个移除。
  @Builder
  private DesktopSitesView() {
    Column() {
      Scroll(this.desktopSitesScroller) {
        Column() {
          AuraSectionLabel({ text: '这些网站会以桌面版打开', tightTop: true })
          if (ShellUiPrefs.parseUrlList(this.desktopSitesRaw).length === 0) {
            Column() {
              Text('还没有站点。\n在浏览器菜单里对某个网站开启「桌面版网站」即可加入此处，' +
                '重开该站仍会显示桌面版。')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            ForEach(ShellUiPrefs.parseUrlList(this.desktopSitesRaw), (host: string): void => {
              Row({ space: 12 }) {
                Image($r('app.media.aura_desktop'))
                  .width(22)
                  .height(22)
                  .fillColor($r('app.color.icon_primary'))
                Text(host)
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .maxLines(1)
                Button('移除')
                  .height(32)
                  .fontSize(13)
                  .onClick((): void => {
                    this.removeDesktopSite(host);
                  })
              }
              .width('100%')
              .constraintSize({ minHeight: 56 })
              .padding({ left: 16, right: 16 })
              .borderRadius(10)
              .backgroundColor($r('app.color.surface_secondary'))
            }, (host: string): string => host)
          }
        }
        .width('100%')
        .padding({ top: glassHeaderInsetVp() })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
  }

  private desktopSiteCountLabel(): string {
    const n: number = ShellUiPrefs.parseUrlList(this.desktopSitesRaw).length;
    return n > 0 ? `${n} 个网站` : '';
  }

  private removeDesktopSite(host: string): void {
    const list: string[] = ShellUiPrefs.parseUrlList(this.desktopSitesRaw);
    const idx: number = list.indexOf(host);
    if (idx >= 0) {
      list.splice(idx, 1);
    }
    const joined: string = ShellUiPrefs.joinUrlList(list);
    AppStorage.setOrCreate('auraDesktopSites', joined);
    const ctx = this.getUIContext().getHostContext() as common.Context | undefined;
    if (ctx) {
      ShellUiPrefs.saveDesktopSites(ctx, list);
    }
    this.onCommand({
      command: 'setDesktopSites',
      sites: joined,
      allSites: String(AppStorage.get('auraUaDefault') ?? 'mobile') === 'desktop',
      mobileSites: String(AppStorage.get('auraMobileSites') ?? '')
    });
  }

build() {
    // 面板自己持有 HdsNavigation + NavPathStack（与 ExtensionPanel
    // 同套路）。主面板是 Navigation 内容、常驻挂载 —— 二级页返回时
    // 主列表滚动位置天然保留；二级页作为 NavDestination 推入，系统默认走
    // 原生鸿蒙层级转场（干净减速、零过冲、无回弹），无需任何转场配置。
    HdsNavigation(this.pathStack) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          this.MainView()
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16 })
    }
    .titleBar({
      content: {
        title: { mainTitle: '设置' },
        backIcon: {
          icon: $r('sys.symbol.chevron_backward'),
          isEnabled: true,
          action: (): void => {
            this.onBack();
          }
        },
        menu: this.searchFabVisible ? {
          value: [
            {
              content: {
                icon: $r('app.media.chromium_search'),
                label: '回到搜索',
                action: (): void => {
                  this.scrollToSearch();
                }
              }
            }
          ]
        } : undefined
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: false
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .mode(NavigationMode.Stack)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindToScrollable([this.mainScroller, this.filteredScroller])
    .backgroundColor($r('app.color.page_background'))
    .navDestination(this.buildSubPageDestination)
    .width('100%')
    .height('100%')
  }
}

@Component
struct SettingsNavRow {
  icon: Resource = $r('app.media.aura_info');
  label: string = '';
  @Prop value: string = '';
  danger: boolean = false;
  onTap: () => void = (): void => {};

  build() {
    Row({ space: 12 }) {
      Image(this.icon)
        .width(22)
        .height(22)
        .fillColor(this.danger ? $r('app.color.danger') : $r('app.color.icon_primary'))
      Text(this.label)
        .fontSize(16)
        .fontColor(this.danger ? $r('app.color.danger') : $r('app.color.text_primary'))
      Blank()
      if (this.value.length > 0) {
        Text(this.value)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      Image($r('app.media.aura_chevron'))
        .width(16)
        .height(16)
        .fillColor($r('app.color.icon_secondary'))
        .opacity(0.65)
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .onClick(() => {
      this.onTap();
    })
  }
}
