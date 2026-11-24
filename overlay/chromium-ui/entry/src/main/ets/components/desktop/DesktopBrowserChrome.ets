/*
 * 平板 / 桌面浏览器 chrome（aura_tablet / aura_pc 家族）—— 外壳自绘的
 * Chrome 式三件套：标签条 + 工具栏（前进后退/刷新/主页 + 地址栏）+ 菜单。
 *
 * 与 MobileBrowserOverlay 的分工（ AuraShell.build 里二选一）：
 *   · mobile_phone      → MobileBrowserOverlay（手机顶栏 + dock）；
 *   · aura_tablet/aura_pc → 本组件。页面视口由 AuraShell.sendBrowserControls
 *     的 top 内距压到工具栏之下，本组件叠在同区自绘（与手机 chrome 同机制）。
 *
 * 复用面（“能复用已有的就复用”）：
 *   · 引擎命令/事件协议   —— activateTab/closeTabById/newTab/navigate/autocomplete/
 *                          findInPage/setZoom/print/home/addBookmark 等，全部走
 *                          现有 BrowserCommandPayload（onCommand 回调）。
 *   · favicon             —— mobile/FaviconKit 请求-缓存-回包链（auraFavicons）。
 *   · 地址栏联想          —— 'auraAutocomplete' 回包 + autocomplete 命令（引擎本地
 *                          历史/书签/打开标签补全），行渲染同手机。
 *   · 小锁快捷面板        —— mobile/SiteQuickPanel 原样嵌入弹层。
 *   · 菜单/面板页         —— 书签/历史/下载/密码/扩展/设置全部 router.pushUrl 到
 *                          pages/panels/*（面板经 BrowserCommandBus 回发命令）。
 *   · 无痕                —— IncognitoSwitch（重启切 profile，引擎单 profile 限制）。
 *   · 右键/长按菜单       —— 由 AuraShell 的 showContextMenuSheet 统一兜底。
 *   · 返回键              —— MobileBackRouter（先收弹层，再回退页面历史）。
 */
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import router from '@ohos.router';
import {
  AutocompleteItem,
  BrowserCommandPayload,
  BrowserStateSnapshot,
  BrowserTabState
} from 'engine';
import { AuraSiteIcon } from '../mobile/AuraKit';
import {
  faviconData,
  hostOf,
  ingestFavicons,
  requestFavicons,
  snapshotFavicons
} from '../mobile/FaviconKit';
import { normalizeAddress, searchUrlFor } from '../mobile/ShellUtils';
import { SiteQuickPanel } from '../mobile/SiteQuickPanel';
import { MobileBackRouter } from '../mobile/MobileBackRouter';
import { BrowserCommandBus } from '../../bus/BrowserCommandBus';
import { isNewTabUrl } from '../../utils/NewTabUrl';
import { IncognitoSwitch, SavedTab } from '../../utils/IncognitoSwitch';

// 视觉常量（vp）。工具栏总高 = 标签条 + 工具行 + 进度条，AuraShell 的
// setBrowserControls top 用它把网页视口压到 chrome 之下。
export const DESKTOP_TAB_STRIP_VP: number = 40;
export const DESKTOP_TOOLBAR_VP: number = 52;
export const DESKTOP_PROGRESS_VP: number = 2;
export const DESKTOP_FIND_BAR_VP: number = 46;
const TAB_CHIP_HEIGHT_VP: number = 32;
const TAB_MIN_WIDTH_VP: number = 104;
const TAB_MAX_WIDTH_VP: number = 220;
const TOOLBAR_BUTTON_VP: number = 36;
const OMNIBOX_HEIGHT_VP: number = 38;
const OMNIBOX_MAX_WIDTH_VP: number = 980;
const MENU_CARD_WIDTH_VP: number = 236;
const SITE_CARD_WIDTH_VP: number = 312;
const SUGGEST_MAX_ROWS: number = 8;

// AppStorage 键：外壳层（AuraShell）读它下发 setBrowserControls 的 top——
// 本组件把当前实际 chrome 高（含状态栏余量与页内查找条）报出去，高度变化
// 时外壳重发内距，网页视口始终精确落在工具栏之下。
const DESKTOP_INSET_KEY: string = 'auraDesktopChromeInset';

// 'auraAutocomplete' 回包（AuraShell 转存，同手机链路）。
interface AutocompletePayload {
  requestId: number;
  items: AutocompleteItem[];
  done: boolean;
}

// 'auraFindResult' 回包（AuraShell 转存，同手机链路）。
interface FindResultSummary {
  matches?: number;
  activeMatch?: number;
}

@Component
export struct DesktopBrowserChrome {
  @StorageProp('auraTopSafeVp') @Watch('onChromeInsetVarsChanged') topSafeVp: number = 0;
  @StorageProp('auraPageFullscreen') @Watch('onChromeInsetVarsChanged') pageFullscreen: boolean = false;
  @StorageLink('auraAutocomplete') @Watch('onAutocompleteChanged') autocompleteJson: string = '';
  @StorageLink('auraFavicons') @Watch('onFaviconsChanged') faviconsJson: string = '';
  @StorageLink('auraFindResult') findResultJson: string = '';
  @Prop @Watch('onBrowserStateChanged') browserState: BrowserStateSnapshot;
  @Prop incognito: boolean = false;
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};

  // 地址栏编辑态。与手机同一个 'auraAddressEditing' 键：外壳层靠它在网页
  // 与 chrome 之间垫一层透明拦截，点地址栏之外就退出编辑（onBlur 对
  // XComponent 不生效——触摸不走路径上的 ArkUI 焦点体系）。
  @StorageLink('auraAddressEditing') @Watch('onEditingAddressChanged')
  private editingAddress: boolean = false;
  @State private addressDraft: string = '';
  @State private addressBase: string = '';
  @State private addressEdited: boolean = false;
  // 联想下拉。
  @State private suggestVisible: boolean = false;
  @State private suggestItems: AutocompleteItem[] = [];
  @State private addressSuggestText: string = '';
  private autocompleteSeq: number = 0;
  private autocompletePending: number = -1;
  private addressSuggestTimer: number = -1;
  private lastActiveTabIndex: number = -1;
  // 弹层开关（bindPopup 锚定各自按钮）。
  @State private menuVisible: boolean = false;
  @State private siteQuickVisible: boolean = false;
  @State private findVisible: boolean = false;
  @State private findQuery: string = '';
  // 布局量（onAreaChange 采集）：chrome 总宽（算标签宽/联想卡宽）、omnibox 宽。
  @State private chromeWidthVp: number = 0;
  @State private omniboxWidthVp: number = 0;
  // favicon 快照（ingest 累积缓存后整份快照）。
  @State private favicons: Map<string, string> = new Map();
  private readonly addressController: TextInputController = new TextInputController();

  aboutToAppear(): void {
    // 返回键：先收弹层（联想/菜单/小锁/查找/编辑态），再回退页面历史；
    // 与 MobileBrowserOverlay 共用同一个 MobileBackRouter 单点注册。
    MobileBackRouter.handler = (): boolean => this.handleSystemBack();
    // 面板路由页（pages/panels/*）经 BrowserCommandBus 把命令发回壳层——
    // 手机由 MobileBrowserOverlay 注册，桌面形态 overlay 不挂载，在这里注册。
    BrowserCommandBus.setHandler((command: BrowserCommandPayload): void => {
      this.issueCommand(command);
    });
    // 首拍同步一次 chrome 高度（aboutToAppear 时 onAreaChange 还没跑）。
    this.publishInset();
  }

  aboutToDisappear(): void {
    if (MobileBackRouter.handler !== undefined) {
      MobileBackRouter.handler = undefined;
    }
    this.issueCommand({ command: 'stopFind' });
    AppStorage.setOrCreate(DESKTOP_INSET_KEY, 0);
  }

  private issueCommand(command: BrowserCommandPayload): void {
    this.onCommand(command);
  }

  // ---- 通用小工具 ----

  private tabs(): BrowserTabState[] {
    return this.browserState?.tabs ?? [];
  }

  private activeTab(): BrowserTabState | undefined {
    const list = this.tabs();
    const idx = this.browserState?.activeTabIndex ?? 0;
    return (idx >= 0 && idx < list.length) ? list[idx] : undefined;
  }

  private currentUrl(): string {
    return this.browserState?.url ?? '';
  }

  private isHomeTab(): boolean {
    const url = this.currentUrl();
    return url.length === 0 || isNewTabUrl(url);
  }

  private displayAddress(): string {
    const url = this.currentUrl();
    if (url.length === 0) {
      return '';
    }
    if (isNewTabUrl(url)) {
      return '';
    }
    return url;
  }

  private tabTitle(tab: BrowserTabState): string {
    const title = (tab.title ?? '').trim();
    if (title.length > 0) {
      return title;
    }
    const url = tab.url ?? '';
    if (url.length === 0 || isNewTabUrl(url)) {
      return '新标签页';
    }
    const host = hostOf(url);
    return host.length > 0 ? host : '新标签页';
  }

  // 标签条内每个标签卡的宽度：均分可用宽后夹在 [min, max]，Chrome 同款策略。
  private tabChipWidth(): number {
    const count = this.tabs().length;
    const strip = this.chromeWidthVp > 0 ? this.chromeWidthVp : 840;
    // 扣掉「+」钮与两侧留白后的可用宽。
    const usable = Math.max(120, strip - 64);
    const each = usable / Math.max(1, count);
    return Math.max(TAB_MIN_WIDTH_VP, Math.min(TAB_MAX_WIDTH_VP, Math.floor(each)));
  }

  private secureSite(): boolean {
    return this.currentUrl().startsWith('https://');
  }

  // ---- chrome 高度上报 ----

  // chrome 渲染总高（状态栏余量 + 标签条 + 工具行 + 进度条 + 可选查找条）。
  private chromeInsetVp(): number {
    if (this.pageFullscreen) {
      return 0;
    }
    return this.topSafeVp + DESKTOP_TAB_STRIP_VP + DESKTOP_TOOLBAR_VP +
      DESKTOP_PROGRESS_VP + (this.findVisible ? DESKTOP_FIND_BAR_VP : 0);
  }

  private publishInset(): void {
    const next = this.chromeInsetVp();
    if ((AppStorage.get(DESKTOP_INSET_KEY) as number ?? 0) !== next) {
      AppStorage.setOrCreate(DESKTOP_INSET_KEY, next);
    }
  }

  // 状态栏余量 / 网页全屏变化都要重报 chrome 高——两者都参与 chromeInsetVp。
  private onChromeInsetVarsChanged(): void {
    this.publishInset();
  }

  private onBrowserStateChanged(): void {
    // 面板路由页经 AppStorage 桥拿当前页信息（与 MobileBrowserOverlay 同名键）。
    const url = this.currentUrl();
    if (((AppStorage.get('auraCurrentUrl') as string) ?? '') !== url) {
      AppStorage.setOrCreate('auraCurrentUrl', url);
    }
    const title = this.browserState?.title ?? '';
    if (((AppStorage.get('auraCurrentTitle') as string) ?? '') !== title) {
      AppStorage.setOrCreate('auraCurrentTitle', title);
    }
    const tabId = this.activeTab()?.id ?? '';
    if (((AppStorage.get('auraActiveTabId') as string) ?? '') !== tabId) {
      AppStorage.setOrCreate('auraActiveTabId', tabId);
    }
    // favicon：标签条/地址栏站点图标走同一条请求链（合批+重试由 FaviconKit 管）。
    const urls: string[] = [];
    for (const tab of this.tabs()) {
      if (tab.url && tab.url.length > 0) {
        urls.push(tab.url);
      }
    }
    if (url.length > 0) {
      urls.push(url);
    }
    requestFavicons(urls, (command: BrowserCommandPayload): void => this.issueCommand(command));
    // 切了标签还在编辑旧页的地址栏说不通——Chrome 切标签退出 omnibox 编辑。
    const activeIndex: number = this.browserState?.activeTabIndex ?? -1;
    if (activeIndex !== this.lastActiveTabIndex) {
      this.lastActiveTabIndex = activeIndex;
      this.editingAddress = false;
    }
    // 换页/换标签时收起与上一页绑定的浮层。
    this.publishInset();
  }

  private onFaviconsChanged(): void {
    if (this.faviconsJson.length === 0) {
      return;
    }
    ingestFavicons(this.faviconsJson);
    this.favicons = snapshotFavicons();
  }

  // ---- 返回键路由 ----

  private handleSystemBack(): boolean {
    if (this.editingAddress) {
      if (this.suggestVisible) {
        this.hideAddressSuggest();
        return true;
      }
      this.cancelAddressEdit();
      return true;
    }
    if (this.findVisible) {
      this.closeFindBar();
      return true;
    }
    if (this.menuVisible || this.siteQuickVisible) {
      this.menuVisible = false;
      this.siteQuickVisible = false;
      return true;
    }
    if (this.isHomeTab()) {
      return false;
    }
    if (this.browserState.canGoBack) {
      this.issueCommand({ command: 'back' });
      return true;
    }
    return false;
  }

  // ---- 地址栏（omnibox） ----

  private beginAddressEdit(): void {
    this.hideAddressSuggest();
    const url = this.currentUrl();
    this.addressDraft = url.startsWith('chrome://') ? '' : url;
    // 首字符替换整条：第一次输入即换掉整条网址（同手机地址栏手感）。
    this.addressBase = this.addressDraft;
    this.addressEdited = false;
    this.editingAddress = true;
    setTimeout((): void => {
      if (!this.editingAddress) {
        return;
      }
      try {
        this.getUIContext().getFocusController().requestFocus('desktop_address_input');
      } catch (error) {
      }
    }, 0);
    // 全选一次（一次性动作，不留常驻选区）。
    setTimeout((): void => {
      if (!this.editingAddress || this.addressEdited || this.addressDraft.length === 0) {
        return;
      }
      try {
        this.addressController.setTextSelection(0, this.addressDraft.length);
      } catch (error) {
      }
    }, 80);
  }

  private cancelAddressEdit(): void {
    this.hideAddressSuggest();
    try {
      this.addressController.stopEditing();
    } catch (error) {
    }
    this.editingAddress = false;
  }

  // 编辑态被外部（AuraShell 的点外侧拦截层）关掉时收尾：收联想、松键盘。
  private onEditingAddressChanged(): void {
    if (this.editingAddress) {
      return;
    }
    this.hideAddressSuggest();
    try {
      this.addressController.stopEditing();
    } catch (error) {
    }
  }

  private submitAddress(): void {
    this.hideAddressSuggest();
    const target = normalizeAddress(this.addressDraft);
    this.editingAddress = false;
    if (target.length > 0) {
      this.issueCommand({ command: 'navigate', url: target });
    }
  }

  private onAddressInput(value: string): string {
    if (this.addressEdited || this.addressBase.length === 0) {
      return value;
    }
    if (value === this.addressBase) {
      return value;
    }
    if (value.length > this.addressBase.length && value.startsWith(this.addressBase)) {
      this.addressEdited = true;
      return value.substring(this.addressBase.length);
    }
    if (value.length < this.addressBase.length && this.addressBase.startsWith(value)) {
      this.addressEdited = true;
      return '';
    }
    this.addressEdited = true;
    return value;
  }

  // 输入防抖 60ms 后向引擎要本地联想（与手机同一 requestId 协议、同一回包键）。
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
    this.autocompletePending = -1;
    this.addressSuggestTimer = setTimeout((): void => {
      this.addressSuggestTimer = -1;
      if (!this.editingAddress) {
        return;
      }
      this.autocompleteSeq += 1;
      this.autocompletePending = this.autocompleteSeq;
      this.issueCommand({
        command: 'autocomplete',
        requestId: this.autocompleteSeq,
        text: query
      });
    }, 60);
  }

  private hideAddressSuggest(): void {
    if (this.addressSuggestTimer !== -1) {
      clearTimeout(this.addressSuggestTimer);
      this.addressSuggestTimer = -1;
    }
    this.autocompletePending = -1;
    this.addressSuggestText = '';
    this.suggestItems = [];
    this.suggestVisible = false;
  }

  private onAutocompleteChanged(): void {
    if (this.autocompleteJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.autocompleteJson) as AutocompletePayload;
      if (payload.requestId !== this.autocompletePending) {
        return;
      }
      const normalized: AutocompleteItem[] = [];
      for (const parsed of payload.items ?? []) {
        normalized.push({
          type: parsed.type,
          title: typeof parsed.title === 'string' ? parsed.title : '',
          url: typeof parsed.url === 'string' ? parsed.url : '',
          description: typeof parsed.description === 'string' ? parsed.description : ''
        } as AutocompleteItem);
      }
      this.suggestItems = normalized;
    } catch (error) {
    }
  }

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

  // 联想行：首行恒为「搜索“输入”」（搜索型输入时），其后引擎本地补全项。
  private suggestRows(): AutocompleteItem[] {
    const rows: AutocompleteItem[] = [];
    const query = this.addressSuggestText;
    const searchLike = !this.looksLikeUrl(query);
    const seen: Set<string> = new Set<string>();
    if (searchLike && query.length > 0) {
      rows.push({
        type: 'search',
        title: `搜索 “${query}”`,
        url: searchUrlFor(query),
        description: ''
      } as AutocompleteItem);
      seen.add(query);
    }
    for (const item of this.suggestItems) {
      if (rows.length >= SUGGEST_MAX_ROWS) {
        break;
      }
      if (item.type === 'search' && seen.has(item.title)) {
        continue;
      }
      rows.push(item);
      const key = item.url.length > 0 ? item.url : item.title;
      seen.add(key);
    }
    return rows;
  }

  private suggestListActive(): boolean {
    return this.suggestVisible && this.editingAddress &&
      this.addressSuggestText.length > 0 && this.suggestRows().length > 0;
  }

  private applyAddressSuggestion(item: AutocompleteItem): void {
    this.hideAddressSuggest();
    const target = item.url.length > 0 ? item.url : normalizeAddress(item.title);
    if (target.length === 0) {
      return;
    }
    this.addressDraft = target;
    this.editingAddress = false;
    this.issueCommand({ command: 'navigate', url: target });
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

  // ---- 页内查找 ----

  private openFindBar(): void {
    this.findVisible = true;
    this.publishInset();
    setTimeout((): void => {
      try {
        this.getUIContext().getFocusController().requestFocus('desktop_find_input');
      } catch (error) {
      }
    }, 0);
  }

  private closeFindBar(): void {
    this.findVisible = false;
    this.findQuery = '';
    this.issueCommand({ command: 'stopFind' });
    this.publishInset();
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

  private findNext(forward: boolean): void {
    if (this.findQuery.trim().length === 0) {
      return;
    }
    this.issueCommand({ command: 'findInPage', text: this.findQuery, forward: forward });
  }

  // ---- 页级动作 ----

  private toggleBookmark(): void {
    const url = this.currentUrl();
    if (url.length === 0 || this.isHomeTab()) {
      return;
    }
    if (this.browserState.bookmarked === true) {
      // 已收藏 → 摘星（引擎服务命令按 URL 精确删）。
      this.issueCommand({ command: 'removeBookmarkByUrl', url: url });
      this.getUIContext().getPromptAction().showToast({ message: '已移出书签', duration: 2000 });
      return;
    }
    const title = (this.browserState.title ?? '').trim();
    this.issueCommand({
      command: 'addBookmark',
      url: url,
      title: title.length > 0 ? title : hostOf(url)
    });
    this.getUIContext().getPromptAction().showToast({ message: '已加入书签', duration: 2000 });
  }

  private toggleDesktopSite(): void {
    if (this.isHomeTab()) {
      return;
    }
    const enabled = !(this.browserState.requestDesktopSite === true);
    this.issueCommand({ command: 'setRequestDesktopSite', enabled: enabled });
    this.getUIContext().getPromptAction().showToast({
      message: enabled ? '已请求桌面版网站' : '已回到移动版网站',
      duration: 2000
    });
  }

  private toggleZoom(delta: number): void {
    const current = this.browserState.zoomPercent ?? 100;
    const next = Math.max(25, Math.min(500, Math.round(current + delta)));
    this.issueCommand({ command: 'setZoom', percent: next });
  }

  private shareCurrentPage(): void {
    if (this.isHomeTab()) {
      return;
    }
    this.issueCommand({ command: 'share' });
  }

  private pressHome(): void {
    if (this.isHomeTab()) {
      // 已在主页：主页键改派复位信号（清空主页搜索框/收起联想），与手机一致。
      const seq: number = Number(AppStorage.get('auraHomeReset') ?? 0);
      AppStorage.setOrCreate('auraHomeReset', seq + 1);
      return;
    }
    this.issueCommand({ command: 'home' });
  }

  // ---- 无痕（复用重启切 profile 机制） ----

  private async enterIncognito(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    const saved: SavedTab[] = [];
    for (const tab of this.tabs()) {
      if (tab.url && tab.url.length > 0 && !isNewTabUrl(tab.url)) {
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

  private leaveIncognito(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    IncognitoSwitch.restart(context, false, '');
  }

  // ---- 面板路由页（与手机同一批） ----

  private openPanelPage(page: string): void {
    router.pushUrl({ url: page }).catch((error: Error): void => {
      console.error(`openPanelPage ${page} failed:`, error);
    });
  }

  // ---- 渲染 ----

  build() {
    Column() {
      if (!this.pageFullscreen) {
        this.TabStrip()
        this.Toolbar()
        if (this.findVisible) {
          this.FindBar()
        }
        // if 块整体挂不上 transition，FindBar 自身的根节点带了插删动画。
        // 加载进度条（无加载时为 2px 占位分隔线，高度恒定，视口不跳）。
        // 与手机端同一画法的 Row 宽度动画。
        Stack({ alignContent: Alignment.Start }) {
          Divider()
            .color($r('app.color.divider'))
          if (this.browserState.loading) {
            Row()
              .width(`${Math.min(Math.max(this.browserState.loadProgress ?? 0, 0.08), 1) * 100}%`)
              .height(DESKTOP_PROGRESS_VP)
              .borderRadius({ topRight: DESKTOP_PROGRESS_VP, bottomRight: DESKTOP_PROGRESS_VP })
              .backgroundColor($r('app.color.accent_primary'))
              .animation({ duration: 200, curve: Curve.EaseOut })
          }
        }
        .width('100%')
        .height(DESKTOP_PROGRESS_VP)
        .clip(true)
      }
    }
    .width('100%')
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      // Area 的单位就是 vp，直接用。
      const width = Math.round(Number(newValue.width));
      if (width > 0 && width !== this.chromeWidthVp) {
        this.chromeWidthVp = width;
      }
      this.publishInset();
    })
  }

  // ---- 标签条 ----

  @Builder
  private TabStrip() {
    Row({ space: 2 }) {
      Scroll() {
        Row({ space: 2 }) {
          ForEach(this.tabs(), (tab: BrowserTabState, index: number) => {
            this.TabChip(tab, index)
          }, (tab: BrowserTabState, index: number): string =>
            // ArkUI 的 ForEach 对相同 key 直接复用旧节点、不重跑
            // itemGenerator——只把稳定的 id/index 编进 key，芯片会一直渲染
            // 捕获时的旧快照（标题停在「新标签页」、激活色落在旧卡上），
            // 连点击闭包里的 tab 都是旧的。可变字段全部进 key，任何
            // 一项变了就整卡重建，渲染与手势拿到的都是当下状态。
            `${(tab.id && tab.id.length > 0) ? tab.id : `idx${index}`}` +
            `|${tab.url}|${tab.title}|${tab.active === true}` +
            `|${tab.loading === true}|${tab.discarded === true}`)

          // 新建标签：Chrome 的「+」跟在最后一个标签后面，标签加宽时一起滑过去。
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            Image($r('app.media.chromium_add'))
              .width(18)
              .height(18)
              .fillColor($r('app.color.icon_primary'))
          }
          .width(30)
          .height(30)
          .backgroundColor(Color.Transparent)
          .accessibilityText('新建标签页')
          .onClick((): void => {
            this.issueCommand({ command: 'newTab' });
          })
          .margin({ left: 4 })
        }
        .padding({ left: 8, right: 6 })
        .alignItems(VerticalAlign.Bottom)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .height('100%')
      .align(Alignment.Start)
    }
    .width('100%')
    .height(this.topSafeVp + DESKTOP_TAB_STRIP_VP)
    .padding({ top: this.topSafeVp })
    .backgroundColor($r('app.color.surface_secondary'))
  }

  @Builder
  private TabChip(tab: BrowserTabState, index: number) {
    Stack({ alignContent: Alignment.Center }) {
      // 激活手势挂在 Button 上：实测 Scroll+ForEach 里中间层 Row/Stack 的
      // onClick 与子手势共存时整卡不响应，而 ×、+ 这类「叶子控件手势」
      // 一直好使——整卡干脆就是一个 Button。
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        Row({ space: 6 }) {
          // 加载中：小转轮顶替 favicon（Chrome 的 tab spinner）。只认「真实
          // 网址 + 正在加载」——新建的主页标签 discarded=true 但并没在加载，
          // 拿它当条件会让转轮永远停不下。
          if (tab.loading === true && !isNewTabUrl(tab.url ?? '')) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color($r('app.color.icon_secondary'))
          } else {
            AuraSiteIcon({
              url: tab.url ?? '',
              iconData: faviconData(tab.url ?? '', this.favicons),
              iconSize: 16
            })
              // 休眠标签图标减半透明（Chrome 的 dimmed favicon）。
              .opacity(tab.discarded === true ? 0.55 : 1)
          }
          Text(this.tabTitle(tab))
            .fontSize(12)
            .fontColor(tab.active === true ?
              $r('app.color.text_primary') : $r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 10, right: 28 })
        // 让命中直接落在 Button 自身——内容 Row 不再参与命中。
        .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .padding(0)
      .borderRadius({ topLeft: 8, topRight: 8, bottomLeft: 0, bottomRight: 0 })
      .backgroundColor(Color.Transparent)
      .accessibilityText(`${this.tabTitle(tab)}${tab.active === true ? '，当前标签页' : ''}`)
      .onClick((): void => {
        if (tab.active === true) {
          return;
        }
        // 按 id 点名最稳：index 在邻居关闭/挪动后会漂（C++ 侧注释同此约定）。
        if (tab.id && tab.id.length > 0) {
          this.issueCommand({ command: 'activateTabById', id: tab.id });
        } else {
          this.issueCommand({ command: 'activateTab', index: index });
        }
      })
      // × 是 Button 右侧叠放的兄弟节点：包装 Row 自己透明于命中
      // （Transparent），× 仍可独立点中，其余区域全部落给激活 Button。
      Row() {
        Image($r('app.media.aura_close'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.icon_secondary'))
          .accessibilityText('关闭标签页')
          .onClick((): void => {
            if (tab.id && tab.id.length > 0) {
              this.issueCommand({ command: 'closeTabById', id: tab.id });
            } else {
              this.issueCommand({ command: 'closeTab', index: index });
            }
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .padding({ right: 8 })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width(this.tabChipWidth())
    .height(TAB_CHIP_HEIGHT_VP)
    .margin({ top: 4 })
    // Chrome 式：激活卡白底上圆角，与下方工具栏同色连成一片；非激活卡留在
    // 标签条底色上，用一条描边线把它和底区分开，不再靠纯文字深浅辨认。
    .borderRadius({ topLeft: 8, topRight: 8, bottomLeft: 0, bottomRight: 0 })
    .border(tab.active === true ? {
      width: { left: 1, top: 1, right: 1, bottom: 0 },
      color: $r('app.color.divider')
    } : {
      width: 1,
      color: $r('app.color.divider')
    })
    // Chrome 式：激活卡纯白，与下方工具栏（同为 surface_primary）连成一片
    // 浮出来；非激活卡吃标签条底色（surface_secondary，#F2F3F5 与白底差出
    // 明显一档）——原来用 surface_floating 只差 8 个色阶，根本分不清。
    .backgroundColor(tab.active === true ?
      $r('app.color.surface_primary') : $r('app.color.surface_secondary'))
    // 插删不再用 .transition——实测它挂在与手势同级的节点上会把 Scroll 里
    // 子项的点击整个吞掉；保留 .animation 做宽度和激活配色的平滑过渡。
    .animation({ duration: 160, curve: Curve.FastOutSlowIn })
  }

  // ---- 工具栏 ----

  @Builder
  private Toolbar() {
    Row({ space: 4 }) {
      this.NavButton($r('app.media.chromium_back'), '后退',
        this.browserState.canGoBack, (): void => {
          this.issueCommand({ command: 'back' });
        })
      this.NavButton($r('app.media.chromium_forward'), '前进',
        this.browserState.canGoForward, (): void => {
          this.issueCommand({ command: 'forward' });
        })
      this.NavButton(
        this.browserState.loading ? $r('app.media.chromium_close') : $r('app.media.chromium_reload'),
        this.browserState.loading ? '停止' : '重新加载',
        true, (): void => {
          this.issueCommand({ command: this.browserState.loading ? 'stop' : 'reload' });
        })
      this.NavButton($r('app.media.chromium_home'), '主页', true, (): void => {
        this.pressHome();
      })

      this.Omnibox()

      // 分享当前页。
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Image($r('app.media.chromium_share'))
          .width(19)
          .height(19)
          .fillColor($r('app.color.icon_primary'))
      }
      .width(TOOLBAR_BUTTON_VP)
      .height(TOOLBAR_BUTTON_VP)
      .backgroundColor(Color.Transparent)
      .accessibilityText('分享')
      .onClick((): void => {
        this.shareCurrentPage();
      })

      // 下载。
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Image($r('app.media.chromium_download'))
          .width(19)
          .height(19)
          .fillColor($r('app.color.icon_primary'))
      }
      .width(TOOLBAR_BUTTON_VP)
      .height(TOOLBAR_BUTTON_VP)
      .backgroundColor(Color.Transparent)
      .accessibilityText('下载内容')
      .onClick((): void => {
        this.openPanelPage('pages/panels/DownloadsPanelPage');
      })

      // 更多（⋮）：Chrome 式下拉菜单，绑定自身弹层。
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Image($r('app.media.chromium_more'))
          .width(19)
          .height(19)
          .fillColor($r('app.color.icon_primary'))
      }
      .width(TOOLBAR_BUTTON_VP)
      .height(TOOLBAR_BUTTON_VP)
      .backgroundColor(Color.Transparent)
      .accessibilityText('更多操作')
      .bindPopup(this.menuVisible, {
        builder: this.MenuCard,
        placement: Placement.Bottom,
        popupColor: Color.Transparent,
        enableArrow: false,
        onStateChange: (event): void => {
          this.menuVisible = event.isVisible;
        }
      })
      .onClick((): void => {
        this.menuVisible = !this.menuVisible;
      })
      .margin({ right: 4 })
    }
    .width('100%')
    .height(DESKTOP_TOOLBAR_VP)
    .padding({ left: 8, right: 4 })
    .backgroundColor($r('app.color.surface_primary'))
  }

  @Builder
  private NavButton(icon: Resource, label: string, enabled: boolean, action: () => void) {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      Image(icon)
        .width(19)
        .height(19)
        .fillColor(enabled ? $r('app.color.icon_primary') : $r('app.color.icon_secondary'))
        .opacity(enabled ? 1 : 0.45)
    }
    .width(TOOLBAR_BUTTON_VP)
    .height(TOOLBAR_BUTTON_VP)
    .backgroundColor(Color.Transparent)
    .enabled(enabled)
    .accessibilityText(label)
    .onClick(action)
  }

  // 地址栏胶囊：锁/站点图标 + 网址（点击进入编辑全选）+ 收藏星。
  @Builder
  private Omnibox() {
    Stack() {
      // 浏览态底：域名 + 站点信息锁（点击锁开「连接与站点」卡）。
      Row({ space: 8 }) {
        // 小锁：点开 SiteQuickPanel（手机同款面板，嵌进弹层卡）。
        Row() {
          Image(this.secureSite() ? $r('app.media.aura_lock') : $r('app.media.aura_info'))
            .width(15)
            .height(15)
            .fillColor(this.secureSite() ? $r('app.color.icon_primary') : $r('app.color.icon_secondary'))
        }
        .width(28)
        .height(28)
        .borderRadius(14)
        .justifyContent(FlexAlign.Center)
        .bindPopup(this.siteQuickVisible, {
          builder: this.SiteQuickCard,
          placement: Placement.Bottom,
          popupColor: Color.Transparent,
          enableArrow: false,
          onStateChange: (event): void => {
            this.siteQuickVisible = event.isVisible;
          }
        })
        .onClick((): void => {
          this.siteQuickVisible = !this.siteQuickVisible;
        })

        if (!this.editingAddress) {
          Text(this.displayAddress().length > 0 ? hostOf(this.displayAddress()) : '搜索或输入网址')
            .fontSize(14)
            .fontColor(this.displayAddress().length > 0 ?
              $r('app.color.text_primary') : $r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        } else {
          TextInput({ text: this.addressDraft, placeholder: '搜索或输入网址',
            controller: this.addressController })
            .id('desktop_address_input')
            .layoutWeight(1)
            .height(36)
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_secondary'))
            .backgroundColor(Color.Transparent)
            .padding(0)
            .enterKeyType(EnterKeyType.Go)
            .onChange((value: string): void => {
              const next: string = this.onAddressInput(value);
              this.addressDraft = next;
              if (!this.addressEdited) {
                this.hideAddressSuggest();
                return;
              }
              this.scheduleAddressSuggest(next);
            })
            .onSubmit((): void => {
              this.submitAddress();
            })
            .onBlur((): void => {
              // 失焦延迟收：点联想行那一拍 onClick 要先于 cancel 生效。
              setTimeout((): void => {
                if (this.editingAddress && !this.suggestVisible) {
                  this.cancelAddressEdit();
                }
              }, 120);
            })
        }

        // 收藏星：已收藏画实色（accent）提示状态，未收藏画描边；再点摘星。
        if (!this.editingAddress && !this.isHomeTab()) {
          Image($r('app.media.chromium_bookmark'))
            .width(18)
            .height(18)
            .fillColor(this.browserState.bookmarked === true ?
              $r('app.color.accent_primary') : $r('app.color.icon_secondary'))
            .animation({ duration: 160, curve: Curve.FastOutSlowIn })
            .accessibilityText(this.browserState.bookmarked === true ? '已收藏，点击移出书签' : '加入书签')
            .onClick((): void => {
              this.toggleBookmark();
            })
            .margin({ right: 4 })
        }
      }
      .width('100%')
      .height(OMNIBOX_HEIGHT_VP)
      .padding({ left: 6, right: 10 })
      .borderRadius(OMNIBOX_HEIGHT_VP / 2)
      .backgroundColor(this.editingAddress ?
        $r('app.color.surface_primary') : $r('app.color.surface_secondary'))
      .border({
        width: this.editingAddress ? 1.5 : 0,
        color: $r('app.color.accent_primary')
      })
      .onClick((): void => {
        if (!this.editingAddress) {
          this.beginAddressEdit();
        }
      })
      // 联想下拉锚定整条胶囊（Placement.Bottom = 正下方）。
      .bindPopup(this.suggestListActive(), {
        builder: this.SuggestCard,
        placement: Placement.Bottom,
        popupColor: Color.Transparent,
        enableArrow: false,
        onStateChange: (event): void => {
          if (!event.isVisible) {
            this.suggestVisible = false;
          }
        }
      })
      .onAreaChange((_oldValue: Area, newValue: Area): void => {
        const width = Math.round(Number(newValue.width));
        if (width > 0 && width !== this.omniboxWidthVp) {
          this.omniboxWidthVp = width;
        }
      })
    }
    .layoutWeight(1)
    .height(OMNIBOX_HEIGHT_VP)
    .margin({ left: 8, right: 8 })
    .constraintSize({ maxWidth: OMNIBOX_MAX_WIDTH_VP })
  }

  // ---- 弹层卡（bindPopup builder） ----

  @Builder
  private SuggestCard() {
    Column() {
      ForEach(this.suggestRows(), (item: AutocompleteItem, index: number) => {
        Row({ space: 12 }) {
          Image(this.suggestIcon(item.type))
            .width(18)
            .height(18)
            .fillColor($r('app.color.icon_secondary'))
          Column({ space: 2 }) {
            Text(item.title.length > 0 ? item.title : item.url)
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            if (item.url.length > 0 && item.title.length > 0) {
              Text(item.url)
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
        .constraintSize({ minHeight: 44 })
        .padding({ left: 14, right: 12, top: 5, bottom: 5 })
        .borderRadius(8)
        .onClick((): void => {
          this.applyAddressSuggestion(item);
        })
      }, (item: AutocompleteItem, index: number): string => `${index}:${item.url}:${item.title}`)
    }
    .width(this.omniboxWidthVp > 0 ? this.omniboxWidthVp : 520)
    .padding({ top: 6, bottom: 6, left: 4, right: 4 })
    .borderRadius(16)
    .backgroundColor($r('app.color.menu_glass'))
    .shadow({ radius: 24, color: $r('app.color.shadow'), offsetY: 6 })
    .margin({ top: 6 })
  }

  @Builder
  private SiteQuickCard() {
    Column() {
      SiteQuickPanel({
        host: hostOf(this.currentUrl()),
        tabId: this.activeTab()?.id ?? '',
        onCommand: (command: BrowserCommandPayload): void => {
          this.issueCommand(command);
        },
        onClose: (): void => {
          this.siteQuickVisible = false;
        },
        onOpenSiteSettings: (): void => {
          this.siteQuickVisible = false;
          this.openPanelPage('pages/panels/SiteSettingsPanelPage');
        }
      })
    }
    .width(SITE_CARD_WIDTH_VP)
    .borderRadius(18)
    .backgroundColor($r('app.color.menu_glass'))
    .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
    .margin({ top: 6 })
  }

  @Builder
  private MenuCard() {
    Scroll() {
      Column({ space: 0 }) {
      this.MenuRow($r('app.media.chromium_add'), '新建标签页', '', (): void => {
        this.issueCommand({ command: 'newTab' });
      })
      if (this.incognito) {
        this.MenuRow($r('app.media.aura_incognito'), '退出无痕模式', '', (): void => {
          this.leaveIncognito();
        })
      } else {
        this.MenuRow($r('app.media.aura_incognito'), '新建无痕标签页', '', (): void => {
          this.enterIncognito();
        })
      }
      this.MenuDivider()
      this.MenuRow($r('app.media.chromium_history'), '历史记录', '', (): void => {
        this.openPanelPage('pages/panels/HistoryPanelPage');
      })
      this.MenuRow($r('app.media.chromium_download'), '下载内容', '', (): void => {
        this.openPanelPage('pages/panels/DownloadsPanelPage');
      })
      this.MenuRow($r('app.media.chromium_bookmark'), '书签管理器', '', (): void => {
        this.openPanelPage('pages/panels/BookmarksPanelPage');
      })
      this.MenuRow($r('app.media.aura_person'), '密码', '', (): void => {
        this.openPanelPage('pages/panels/PasswordsPanelPage');
      })
      this.MenuRow($r('app.media.chromium_extensions'), '扩展程序', '', (): void => {
        this.openPanelPage('pages/panels/ExtensionPanelPage');
      })
      this.MenuDivider()
      // 缩放：Chrome 菜单内嵌 -/+ 行。
      Row({ space: 8 }) {
        Image($r('app.media.aura_zoom'))
          .width(20)
          .height(20)
          .fillColor($r('app.color.icon_primary'))
        Text(`缩放 ${this.browserState.zoomPercent ?? 100}%`)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text('−')
          .fontSize(18)
          .fontColor($r('app.color.text_primary'))
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
          .borderRadius(15)
          .onClick((): void => {
            this.toggleZoom(-10);
          })
        Text('+')
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
          .borderRadius(15)
          .onClick((): void => {
            this.toggleZoom(10);
          })
      }
      .width('100%')
      .height(44)
      .padding({ left: 16, right: 10 })
      this.MenuDivider()
      this.MenuRow($r('app.media.chromium_search'), '在页面中查找', '', (): void => {
        this.openFindBar();
      })
      this.MenuRow($r('app.media.chromium_print'), '打印', '', (): void => {
        this.issueCommand({ command: 'print' });
      })
      this.MenuRow($r('app.media.chromium_share'), '分享', '', (): void => {
        this.shareCurrentPage();
      })
      if (!this.isHomeTab()) {
        this.MenuRow($r('app.media.aura_desktop'),
          this.browserState.requestDesktopSite === true ? '移动版网站' : '桌面版网站', '',
          (): void => {
            this.toggleDesktopSite();
          })
        this.MenuRow($r('app.media.chromium_bookmark'), '加入书签', '', (): void => {
          this.toggleBookmark();
        })
        if (this.browserState.readerModeAvailable === true) {
          this.MenuRow($r('app.media.aura_reader'), '阅读模式',
            this.browserState.inReaderMode === true ? '开' : '', (): void => {
              this.issueCommand({ command: 'toggleReaderMode' });
            })
        }
      }
      this.MenuDivider()
      this.MenuRow($r('app.media.chromium_settings'), '设置', '', (): void => {
        this.openPanelPage('pages/panels/SettingsPanelPage');
      })
      }
      .width(MENU_CARD_WIDTH_VP)
      .padding({ top: 8, bottom: 8 })
    }
    .scrollBar(BarState.Off)
    .constraintSize({ maxHeight: this.menuMaxHeightVp() })
    .borderRadius(18)
    .backgroundColor($r('app.color.menu_glass'))
    .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
    .margin({ top: 4 })
  }

  // 菜单整张约 640vp 高，矮窗装不下会被裁掉底部「设置」：包 Scroll +
  // 按屏高限高（留工具栏与上下边距），超高即可滚动够到最后一项。
  private menuMaxHeightVp(): number {
    try {
      const heightVp: number =
        this.getUIContext().px2vp(display.getDefaultDisplaySync().height);
      return Math.max(280, heightVp - this.topSafeVp - DESKTOP_TOOLBAR_VP - 24);
    } catch (error) {
      return 560;
    }
  }

  @Builder
  private MenuRow(icon: Resource, label: string, trailing: string, action: () => void) {
    Row({ space: 12 }) {
      Image(icon)
        .width(20)
        .height(20)
        .fillColor($r('app.color.icon_primary'))
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      if (trailing.length > 0) {
        Text(trailing)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .height(44)
    .padding({ left: 16, right: 16 })
    .onClick((): void => {
      this.menuVisible = false;
      action();
    })
  }

  @Builder
  private MenuDivider() {
    Divider()
      .color($r('app.color.divider'))
      .margin({ top: 6, bottom: 6 })
  }

  // ---- 页内查找条（Chrome 右上浮条的等价物，收进 chrome 行内） ----

  @Builder
  private FindBar() {
    Row({ space: 8 }) {
      Blank()
      Row({ space: 6 }) {
        Image($r('app.media.chromium_search'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.icon_secondary'))
        TextInput({ text: this.findQuery, placeholder: '在页面中查找' })
          .id('desktop_find_input')
          .width(220)
          .height(34)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .enterKeyType(EnterKeyType.Done)
          .onChange((value: string): void => {
            this.findQuery = value;
            if (value.trim().length > 0) {
              this.issueCommand({ command: 'findInPage', text: value });
            }
          })
          .onSubmit((): void => {
            this.findNext(true);
          })
        Text(this.findMatches() > 0 ? `${this.findActiveMatch()}/${this.findMatches()}` : '')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        Text('↑')
          .fontSize(16)
          .fontColor($r('app.color.icon_primary'))
          .accessibilityText('上一个')
          .onClick((): void => {
            this.findNext(false);
          })
        Text('↓')
          .fontSize(16)
          .fontColor($r('app.color.icon_primary'))
          .accessibilityText('下一个')
          .onClick((): void => {
            this.findNext(true);
          })
        Image($r('app.media.aura_close'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.icon_secondary'))
          .accessibilityText('结束查找')
          .onClick((): void => {
            this.closeFindBar();
          })
      }
      .height(38)
      .padding({ left: 12, right: 10 })
      .borderRadius(19)
      .backgroundColor($r('app.color.surface_secondary'))
      .margin({ right: 12 })
    }
    .width('100%')
    .height(DESKTOP_FIND_BAR_VP)
    .backgroundColor($r('app.color.surface_primary'))
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(0)
        .combine(TransitionEffect.translate({ y: -12 }))
        .animation({ duration: 160, curve: Curve.FastOutSlowIn }),
      TransitionEffect.opacity(0)
        .animation({ duration: 120, curve: Curve.Friction })
    ))
  }
}
