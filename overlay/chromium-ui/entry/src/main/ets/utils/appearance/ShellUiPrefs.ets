/*
 * 外壳自己的界面偏好（preferences 持久化），与引擎 prefs 无关。
 * 目前只有一项：上滑隐藏状态栏（地址栏收起时一起隐藏，网页铺满全屏）。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE_NAME = 'shell_ui_prefs';
const KEY_HIDE_STATUS_BAR = 'hideStatusBarOnScroll';
const KEY_HIDE_TOP_BAR = 'hideTopBarOnScroll';
const KEY_HIDE_DOCK = 'hideDockOnScroll';
const KEY_EXTERNAL_APP_LINKS = 'externalAppLinks';
// 标签页切换页的排布：'grid'（两列卡片 + 缩略图）或 'list'（单行列表）。
const KEY_TAB_LAYOUT = 'tabLayout';
// 主页风格：'minimal'（保留原主页布局 + 顶部地址栏/状态栏）或
// 'chrome'（地址栏融进 dock 工具栏，无独立顶栏）。默认 'minimal'。
const KEY_HOME_STYLE = 'homeStyle';
// Chrome 风格下 dock 的位置：'bottom'（默认，底部）或 'top'（顶部）。
const KEY_DOCK_POSITION = 'dockPosition';
// 1.0.111「网址主页」：用户设置的自定义主页网址（空 = 用内置新标签页）。
// 1.0.120 起它是「网址列表」里当前勾选的那一个，仍单独存一份 —— 主页键、
// 冷启动都用它，不必再去解析列表。
const KEY_HOME_URL = 'homeUrl';
// 1.0.119「启动页」：冷启动默认打开『网址主页』还是『内置启动页』。
const KEY_STARTUP_PAGE = 'startupPage';
// 1.0.120「自定义网址」：可保存多组网址，每行一个（\n 分隔）。
// 不用 JSON —— URL 里不可能出现换行，一行一条最省事，也免去 ArkTS 侧的
// JSON 反序列化类型体操。
const KEY_HOME_URLS = 'homeUrls';
// 1.0.143「Vulkan 渲染加速」开关。默认关（false → 走 GLES），以规避部分机型
// （如 Pura80）滑动掉帧；开启则引擎走 ANGLE Vulkan 后端。开关在启动时读取一次，
// 改动需重启应用才能生效。
const KEY_VULKAN_ENABLED = 'vulkanEnabled';
// 1.0.146「WebGPU 加速」开关。默认关（false）。开启后页面可用 navigator.gpu，
// 走引擎已编入的 Dawn/WebGPU（ohos-dawn-webgpu.patch）。外壳注入命令行即开，
// 无需重编；与 ANGLE 后端（gles/vulkan）互不干扰。改动需重启应用才能生效。
const KEY_WEBGPU_ENABLED = 'webgpuEnabled';
// 1.0.190「桌面版网站」按站点持久化：被用户强制设为桌面版的站点 host 列表
// （\n 分隔，复用 URL 列表的解析/拼接，避免 ArkTS 侧 JSON 体操）。再打开这些
// 站点会自动用桌面形状 UA（去 Mobile），不用每次手动切。
const KEY_DESKTOP_SITES = 'desktopSites';
// 「默认使用桌面版网站」开着时，读者从菜单明确切回移动版的站点（单站例外）。
const KEY_MOBILE_SITES = 'mobileSites';
// 全局默认 UA：'mobile'（默认，手机浏览体验）或 'desktop'（所有站点用桌面 UA）。
const KEY_UA_DEFAULT = 'uaDefault';
// 读者是否在设置里亲手碰过「默认使用桌面版网站」开关：false 时平板/桌面家族
// 按形态默认桌面版；true 后以用户选择为准（平板横屏也能明确关回手机默认）。
const KEY_UA_DEFAULT_SET = 'uaDefaultSet';
// 冷启动时标签徽标的初值：上次退出时的标签数。会话恢复期间徽标冻结在这个值上，
// 免得从 0 一路数到实际数量。用同步 API，保证首帧就能拿到。
const KEY_LAST_TAB_COUNT = 'lastTabCount';

export class ShellUiPrefs {
  static async loadHideStatusBar(context: common.Context): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return Boolean(await store.get(KEY_HIDE_STATUS_BAR, false));
    } catch (error) {
      return false;
    }
  }

  static async saveHideStatusBar(context: common.Context, value: boolean): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_HIDE_STATUS_BAR, value);
      await store.flush();
    } catch (error) {
    }
  }

  static async loadHideTopBar(context: common.Context): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return Boolean(await store.get(KEY_HIDE_TOP_BAR, true));
    } catch (error) {
      return true;
    }
  }

  static async saveHideTopBar(context: common.Context, value: boolean): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_HIDE_TOP_BAR, value);
      await store.flush();
    } catch (error) {
    }
  }

  static async loadHideDock(context: common.Context): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return Boolean(await store.get(KEY_HIDE_DOCK, true));
    } catch (error) {
      return true;
    }
  }

  static async saveHideDock(context: common.Context, value: boolean): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_HIDE_DOCK, value);
      await store.flush();
    } catch (error) {
    }
  }

  // 网页里的外链（知乎/B站等已转成对应 scheme 的 intent）是否交给本机应用打开。
  // 默认开：浏览器常见的就是这个行为。关掉后一律留在浏览器里打开 fallbackUrl。
  static async loadExternalAppLinks(context: common.Context): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return Boolean(await store.get(KEY_EXTERNAL_APP_LINKS, true));
    } catch (error) {
      return true;
    }
  }

  static async saveExternalAppLinks(context: common.Context, value: boolean): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_EXTERNAL_APP_LINKS, value);
      await store.flush();
    } catch (error) {
    }
  }

  // 标签页排布。只认 'list'，其余一律按 'grid'（写脏值时不至于画不出来）。
  static async loadTabLayout(context: common.Context): Promise<string> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const value = await store.get(KEY_TAB_LAYOUT, 'grid');
      return value === 'list' ? 'list' : 'grid';
    } catch (error) {
      return 'grid';
    }
  }

  static async saveTabLayout(context: common.Context, value: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_TAB_LAYOUT, value === 'list' ? 'list' : 'grid');
      await store.flush();
    } catch (error) {
    }
  }

  // 主页风格。只认 'chrome'，其余一律回退 'minimal'（写脏值不至于画出不认识的主页）。
  static async loadHomeStyle(context: common.Context): Promise<string> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const value = await store.get(KEY_HOME_STYLE, 'minimal');
      return value === 'chrome' ? 'chrome' : 'minimal';
    } catch (error) {
      return 'minimal';
    }
  }

  static async saveHomeStyle(context: common.Context, value: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_HOME_STYLE, value === 'chrome' ? 'chrome' : 'minimal');
      await store.flush();
    } catch (error) {
    }
  }

  // Chrome 风格下 dock 位置。只认 'top'，其余一律回退 'bottom'。
  static async loadDockPosition(context: common.Context): Promise<string> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const value = await store.get(KEY_DOCK_POSITION, 'bottom');
      return value === 'top' ? 'top' : 'bottom';
    } catch (error) {
      return 'bottom';
    }
  }

  static async saveDockPosition(context: common.Context, value: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_DOCK_POSITION, value === 'top' ? 'top' : 'bottom');
      await store.flush();
    } catch (error) {
    }
  }

  // 1.0.111「网址主页」：自定义主页网址。空串 = 未设置（主页键回内置新标签页）。
  static async loadHomeUrl(context: common.Context): Promise<string> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const value = await store.get(KEY_HOME_URL, '');
      return typeof value === 'string' ? value : '';
    } catch (error) {
      return '';
    }
  }

  static async saveHomeUrl(context: common.Context, value: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_HOME_URL, value);
      await store.flush();
    } catch (error) {
    }
  }

  // 1.0.119「启动页」：冷启动默认打开『网址主页』(auraHomeUrl) 还是『内置启动页』
  // (chrome://newtab)。'homeUrl' = 打开设置的网址主页（未设置则回退内置）；
  // 'builtin' = 内置新标签页。默认 'builtin'。
  static async loadStartupPage(context: common.Context): Promise<string> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const value = await store.get(KEY_STARTUP_PAGE, 'builtin');
      return value === 'homeUrl' ? 'homeUrl' : 'builtin';
    } catch (error) {
      return 'builtin';
    }
  }

  static async saveStartupPage(context: common.Context, value: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_STARTUP_PAGE, value === 'homeUrl' ? 'homeUrl' : 'builtin');
      await store.flush();
    } catch (error) {
    }
  }

  // 1.0.120「自定义网址」：多组网址列表。存的是 \n 分隔的一行一条；
  // 解析时逐行 trim、丢空行、去重（顺序保留）。
  static parseUrlList(raw: string): string[] {
    const out: string[] = [];
    if (!raw || raw.length === 0) {
      return out;
    }
    const lines: string[] = raw.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const item: string = lines[i].trim();
      if (item.length > 0 && out.indexOf(item) < 0) {
        out.push(item);
      }
    }
    return out;
  }

  static joinUrlList(list: string[]): string {
    return list.join('\n');
  }

  static async loadHomeUrls(context: common.Context): Promise<string[]> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const raw = await store.get(KEY_HOME_URLS, '');
      const list: string[] = ShellUiPrefs.parseUrlList(typeof raw === 'string' ? raw : '');
      if (list.length > 0) {
        return list;
      }
      // 1.0.120 向后兼容：1.0.111~1.0.119 只存了单个 homeUrl，列表为空时
      // 用它兜底，用户升上来不会看到「一个网址都没有」。
      const single = await store.get(KEY_HOME_URL, '');
      return ShellUiPrefs.parseUrlList(typeof single === 'string' ? single : '');
    } catch (error) {
      return [];
    }
  }

  // 列表与「当前勾选」一起写：勾选项必须落在列表内，否则回落到第一条。
  static async saveHomeUrlList(context: common.Context, list: string[], active: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const resolved: string = ShellUiPrefs.resolveActive(list, active);
      await store.put(KEY_HOME_URLS, ShellUiPrefs.joinUrlList(list));
      await store.put(KEY_HOME_URL, resolved);
      await store.flush();
    } catch (error) {
    }
  }

  // 勾选项归一：在列表内则用它，否则用第一条，列表为空则空串。
  static resolveActive(list: string[], active: string): string {
    if (active && active.length > 0 && list.indexOf(active) >= 0) {
      return active;
    }
    return list.length > 0 ? list[0] : '';
  }

  // 1.0.143「Vulkan 渲染加速」：默认关（走 GLES，规避部分机型滑动掉帧）。
  static async loadVulkanEnabled(context: common.Context): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return Boolean(await store.get(KEY_VULKAN_ENABLED, false));
    } catch (error) {
      return false;
    }
  }

  static async saveVulkanEnabled(context: common.Context, value: boolean): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_VULKAN_ENABLED, value);
      await store.flush();
    } catch (error) {
    }
  }

  // 1.0.146「WebGPU 加速」：默认关（稳定性/兼容性考虑）。开关在启动时读取一次。
  static async loadWebGpuEnabled(context: common.Context): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return Boolean(await store.get(KEY_WEBGPU_ENABLED, false));
    } catch (error) {
      return false;
    }
  }

  static async saveWebGpuEnabled(context: common.Context, value: boolean): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_WEBGPU_ENABLED, value);
      await store.flush();
    } catch (error) {
    }
  }

  // 1.0.190「桌面版网站」站点名单：\n 分隔的 host 列表（与网址主页共用解析）。
  static async loadDesktopSites(context: common.Context): Promise<string[]> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const raw = await store.get(KEY_DESKTOP_SITES, '');
      return ShellUiPrefs.parseUrlList(typeof raw === 'string' ? raw : '');
    } catch (error) {
      return [];
    }
  }

  // 写前对 host 去重、丢空行、保顺序（parseUrlList 已做），调用方负责传入干净数组。
  static async saveDesktopSites(context: common.Context, list: string[]): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_DESKTOP_SITES, ShellUiPrefs.joinUrlList(list));
      await store.flush();
    } catch (error) {
    }
  }

  static async loadMobileSites(context: common.Context): Promise<string[]> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const raw = await store.get(KEY_MOBILE_SITES, '');
      return ShellUiPrefs.parseUrlList(typeof raw === 'string' ? raw : '');
    } catch (error) {
      return [];
    }
  }

  static async saveMobileSites(context: common.Context, list: string[]): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_MOBILE_SITES, ShellUiPrefs.joinUrlList(list));
      await store.flush();
    } catch (error) {
    }
  }

  // 1.0.190 全局默认 UA。只认 'desktop'，其余一律回退 'mobile'（写脏值不至于
  // 让整个浏览器变成桌面版）。改动在下次导航生效，无需重启。
  static async loadUaDefault(context: common.Context): Promise<string> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const value = await store.get(KEY_UA_DEFAULT, 'mobile');
      return value === 'desktop' ? 'desktop' : 'mobile';
    } catch (error) {
      return 'mobile';
    }
  }

  static async saveUaDefault(context: common.Context, value: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_UA_DEFAULT, value === 'desktop' ? 'desktop' : 'mobile');
      await store.flush();
    } catch (error) {
    }
  }

  // 读者是否亲手设置过全局 UA 默认（见 KEY_UA_DEFAULT_SET）。
  static async loadUaDefaultSet(context: common.Context): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return Boolean(await store.get(KEY_UA_DEFAULT_SET, false));
    } catch (error) {
      return false;
    }
  }

  static async saveUaDefaultSet(context: common.Context, value: boolean): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_UA_DEFAULT_SET, value);
      await store.flush();
    } catch (error) {
    }
  }

  static loadLastTabCountSync(context: common.Context): number {
    try {
      const store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      const value = Number(store.getSync(KEY_LAST_TAB_COUNT, 1));
      return value > 0 && value < 1000 ? Math.floor(value) : 1;
    } catch (error) {
      return 1;
    }
  }

  static saveLastTabCountSync(context: common.Context, count: number): void {
    try {
      const store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      store.putSync(KEY_LAST_TAB_COUNT, count);
      store.flushSync();
    } catch (error) {
    }
  }
}
