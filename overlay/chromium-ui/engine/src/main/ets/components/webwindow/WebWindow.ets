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

import display from '@ohos.display';
import { common } from '@kit.AbilityKit';
import { dragController, promptAction, window, NodeContent } from '@kit.ArkUI';
import { unifiedDataChannel, uniformTypeDescriptor } from '@kit.ArkData';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { i18n } from '@kit.LocalizationKit';
import { AuraStartupConfig, CHROMIUM_HOME_URL } from '../../utils/DeviceType';
import { UIManager } from '../../utils/UIManager';
import {
  SequencedBrowserCommand,
  SequencedBrowserCommandBatch
} from '../../utils/BrowserCommandChannel';
import {
  INativeContext,
  AuxiliaryWindowState,
  BrowserCommandPayload,
  BrowserRuntimeEvent,
  BrowserStateSnapshot,
  DroppedFileRef,
  KeyEventPayload,
  NativeContext,
  PointerEventPayload,
  WindowRect
} from './NativeContext';

interface PointInPage {
  x: number;
  y: number;
}

export interface WebWindowOptions {
  xComponentId?: string;
  surfaceReadyStorageKey?: string;
  manageWindowDecor?: boolean;
  url?: string;
  profileId?: string;
  startupConfigText?: string;
  routingRevision?: number;
  appVisible?: boolean;
  themeFontId?: string;
  themeFontRevision?: number;
  browserCommandText?: string;
  browserCommandRevision?: number;
  colorSchemeCmdText?: string;
  colorSchemeCmdRev?: number;
  auxiliaryDismissWidget?: number;
  auxiliaryDismissRevision?: number;
  onBrowserState?: (state: BrowserStateSnapshot) => void;
  onRuntimeEvent?: (event: BrowserRuntimeEvent) => void;
  onWindowStatus?: (status: number) => void;
  onAuxiliaryWindowState?: (state: AuxiliaryWindowState) => void;
  onPageLoadStart?: (url: string) => void;
  onPageLoadFinish?: (url: string) => void;
  onTitleReceive?: (title: string) => void;
  onError?: (error: Error) => void;
}

const ICU_DATA_RAWFILE_PATH: string = 'chromium/icudtl.dat';
const RUNTIME_VERSION_RAWFILE_PATH: string = 'chromium/runtime.version';
const COMMON_RUNTIME_RAWFILES: string[] = [
  'chrome_100_percent.pak',
  'chrome_200_percent.pak',
  'headless_command_resources.pak',
  'icudtl.dat',
  'resources.pak',
  'snapshot_blob.bin'
];

@ComponentV2
export struct WebWindow {
  @Param xComponentId: string = 'aura_shell';
  @Param surfaceReadyStorageKey: string = 'auraSurfaceReady';
  @Param manageWindowDecor: boolean = true;
  @Param url: string = CHROMIUM_HOME_URL;
  @Param profileId: string = 'local';
  @Param startupConfigText: string = '';
  @Param routingRevision: number = 0;
  @Param appVisible: boolean = true;
  @Param themeFontId: string = '';
  @Param themeFontRevision: number = 0;
  @Param browserCommandText: string = '';
  @Param browserCommandRevision: number = 0;
  @Param auxiliaryDismissWidget: number = 0;
  @Param auxiliaryDismissRevision: number = 0;
  @Param onBrowserState?: (state: BrowserStateSnapshot) => void = undefined;
  @Param onRuntimeEvent?: (event: BrowserRuntimeEvent) => void = undefined;
  @Param onWindowStatus?: (status: number) => void = undefined;
  @Param onAuxiliaryWindowState?: (state: AuxiliaryWindowState) => void = undefined;
  @Param onPageLoadStart?: (url: string) => void = undefined;
  @Param onPageLoadFinish?: (url: string) => void = undefined;
  @Param onTitleReceive?: (title: string) => void = undefined;
  @Param onError?: (error: Error) => void = undefined;

  // 独立通道：系统深色 / 设置面板切外观时下发 setColorScheme 命令。与
  // refreshSystemState 共用的 browserCommand 通道分开，避免两者紧邻下发时
  // 后者覆盖前者、丢失配色命令（引擎只在启动时应用一次，运行时必须显式下发）。
  // 本组件是 @ComponentV2，AppStorage 的 @StorageLink 只能由 V1 父组件持有后
  // 经 @Param 传入，不能在这里直接声明。
  @Param colorSchemeCmdText: string = '';
  @Param colorSchemeCmdRev: number = 0;

  @Local currentUrl: string = CHROMIUM_HOME_URL;
  private lockSurfaceRotation: boolean = false;

  private readonly xComponentController: XComponentController = new XComponentController();
  private nativeContext: NativeContext | null = null;
  private activeWindow: window.Window | null = null;
  private surfaceReady: boolean = false;
  private icuRawFdOpen: boolean = false;
  private icuDataFd: number = -1;
  private icuDataOffset: number = 0;
  private icuDataLength: number = 0;
  private hasWindowOrigin: boolean = false;
  private windowOriginX: number = 0;
  private windowOriginY: number = 0;
  // Where the XComponent sits inside the window, in px. A shell that draws
  // its own bars above or below the page gives this component less than the
  // whole window; Chromium must lay the page out in this box, not the window.
  private hasComponentArea: boolean = false;
  private componentOffsetXPx: number = 0;
  private componentOffsetYPx: number = 0;
  private componentWidthPx: number = 0;
  private componentHeightPx: number = 0;
  private focusRecoveryTimers: number[] = [];
  private rotationSyncTimer: number = -1;
  private boundsSettleTimer: number = -1;
  private lastExecutedBrowserCommandRevision: number = 0;
  // For commands from a BrowserCommandChannel: which channel, and the last
  // command of it run. See BrowserCommandChannel.
  private browserCommandChannel: string = '';
  private lastExecutedBrowserCommandSeq: number = 0;
  private lastAuxiliaryDismissRevision: number = 0;
  private lastPwaWindowActive: number = -1;
  private lastActivationEpoch: number = 0;
  private lastFocusedTarget: 'webContents' | 'sidePanel' = 'webContents';
  private lastSidePanelEntryId: string = '';
  // Where a file dragged into a page is copied to. The sending app's URI is
  // readable only while the drop is being handled, so the file has to be
  // taken now; what the page and the shell get afterwards is an ordinary
  // path of ours. Emptied on every launch by the engine.
  private droppedFileDir: string = '';
  private droppedFileSequence: number = 0;
  // What the drag preview says while the page's own drag is out. HarmonyOS
  // draws the preview from this component, so it has to be a real one.
  @Local dragOutLabel: string = '';
  // The picture being dragged out, as a file:// URI, empty when what is
  // being dragged is not one.
  @Local dragOutImage: string = '';

  aboutToAppear() {
    this.currentUrl = this.url && this.url.trim().length > 0 ? this.url : CHROMIUM_HOME_URL;
    this.updateXComponentMode(this.readStartupConfig());
    this.setSurfaceReady(false);
    this.initWindowListeners();
  }

  aboutToDisappear() {
    this.destroyNativeContext();
    this.removeWindowListeners();
  }

  @Monitor('routingRevision')
  private onRoutingRevisionChange(_monitor: IMonitor): void {
    const startupConfig = this.readStartupConfig();
    this.updateXComponentMode(startupConfig);
    if (!this.nativeContext) {
      return;
    }

    this.configureSurfaceRotation();
    this.applyDisplayMetrics(startupConfig);
    this.nativeContext.UpdateConfiguration(startupConfig);
  }

  @Monitor('url')
  private onUrlChange(_monitor: IMonitor): void {
    const nextUrl = this.url && this.url.trim().length > 0 ? this.url : CHROMIUM_HOME_URL;
    if (nextUrl !== this.currentUrl) {
      this.loadUrl(nextUrl);
    }
  }

  @Monitor('appVisible')
  private onAppVisibilityChange(_monitor: IMonitor): void {
    if (!this.nativeContext) {
      return;
    }

    this.nativeContext.OnVisibilityChanged(this.appVisible);
    this.nativeContext.OnFocusChanged(this.appVisible);
    if (this.appVisible) {
      this.notifyCurrentBounds();
      // Let the activating pointer sequence finish before restoring focus.
      this.restoreXComponentFocus(80);
    }
  }

  @Monitor('themeFontRevision')
  private onThemeFontRevisionChange(_monitor: IMonitor): void {
    this.nativeContext?.OnThemeFontChanged(this.themeFontId);
  }

  @Monitor('browserCommandRevision')
  private onBrowserCommandRevisionChange(_monitor: IMonitor): void {
    this.executePendingBrowserCommand();
  }

  @Monitor('colorSchemeCmdRev')
  private onColorSchemeCmdChange(_monitor: IMonitor): void {
    this.executePendingColorSchemeCommand();
  }

  // 配色命令在 Ability 启动/回前台对账时就会写入 AppStorage，那时本组件可能
  // 还没挂载、nativeContext 尚未建立；@Monitor 只认变化，挂载时的初值不会触发。
  // 因此缓存待执行命令，在 onLoad 建好 nativeContext 后补放一次，避免冷启动或
  // 后台恢复时丢掉整条配色命令（引擎按值去重，重复执行无害）。
  private pendingColorSchemeCommand: string = '';

  private executePendingColorSchemeCommand(): void {
    const text = this.colorSchemeCmdText;
    if (text && text.trim().length > 0) {
      this.pendingColorSchemeCommand = text;
    }
    if (!this.nativeContext || this.pendingColorSchemeCommand.length === 0) {
      return;
    }
    this.nativeContext.ExecuteBrowserCommand(this.pendingColorSchemeCommand);
    this.pendingColorSchemeCommand = '';
  }

  @Monitor('auxiliaryDismissRevision')
  private onAuxiliaryDismissRevisionChange(_monitor: IMonitor): void {
    this.executePendingAuxiliaryDismiss();
  }

  @Builder
  dragOutPreview() {
    if (this.dragOutImage.length > 0) {
      // Dragging a picture: show the picture. HarmonyOS draws whatever this
      // builder produces under the finger.
      Image(this.dragOutImage)
        .objectFit(ImageFit.Contain)
        .constraintSize({ maxWidth: 160, maxHeight: 160 })
        .borderRadius(8)
    } else {
      Text(this.dragOutLabel)
      .fontSize(14)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .constraintSize({ maxWidth: 240 })
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor('#F0FFFFFF')
      .borderRadius(8)
    }
  }

  private overlayContent: NodeContent = new NodeContent();
  private overlayNative: INativeContext | null = null;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      XComponent({
        id: this.xComponentId,
        // SURFACE gives Chromium its own layer in the system compositor, which
        // can hand it to the display hardware. TEXTURE routed every frame
        // through this app's UI thread and had the compositor redraw it on
        // the GPU: ~5.7 ms of extra latency and a full-screen draw per frame.
        type: XComponentType.SURFACE,
        libraryname: 'web_engine',
        controller: this.xComponentController
      })
        .id(this.xComponentId)
        .width('100%')
        .height('100%')
        .focusable(true)
        .defaultFocus(true)
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          this.handleComponentAreaChange(newArea);
        })
        .onLoad(() => {
          this.configureSurfaceRotation();
          this.initNativeContext();
        })
        .onDestroy(() => {
          this.destroyNativeContext();
        })
        .onFocus(() => {
          this.nativeContext?.OnFocusChanged(this.appVisible);
        })
        .onBlur(() => {
          this.nativeContext?.OnFocusChanged(false);
        })
        .onAxisEvent((event: AxisEvent) => {
          this.dispatchAxisEvent(event);
        })
        // Without allowDrop the system shows a no-entry badge and onDrop
        // never fires. These are the types a page can do something with; a
        // drag of anything else is refused by the system before it gets here.
        .allowDrop([
          uniformTypeDescriptor.UniformDataType.PLAIN_TEXT,
          uniformTypeDescriptor.UniformDataType.HYPERLINK,
          uniformTypeDescriptor.UniformDataType.HTML,
          uniformTypeDescriptor.UniformDataType.FILE,
          uniformTypeDescriptor.UniformDataType.FOLDER,
          uniformTypeDescriptor.UniformDataType.IMAGE,
          uniformTypeDescriptor.UniformDataType.VIDEO,
          uniformTypeDescriptor.UniformDataType.AUDIO,
          uniformTypeDescriptor.UniformDataType.PDF
        ])
        .onDragEnter((event: DragEvent) => {
          this.dispatchDragStage('enter', event);
        })
        .onDragMove((event: DragEvent) => {
          this.dispatchDragStage('move', event);
        })
        .onDragLeave((event: DragEvent) => {
          this.dispatchDragStage('leave', event);
        })
        .onDrop((event: DragEvent) => {
          this.dispatchDrop(event);
        })
        .onKeyEventDispatch((event: KeyEvent): boolean => {
          return this.dispatchKeyEvent(event);
        })
      Column() {
        ContentSlot(this.overlayContent)
      }
      .width('100%')
      .height('100%')
      .clip(true)
      // This subtree only presents pixels. None skips the Column itself but
      // still lets the native ContentSlot child consume hits over XComponent.
      // Exclude the whole subtree so Chromium keeps touch, mouse and axis input.
      .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
    }
    .width('100%')
    .height('100%')
  }

  private initNativeContext(): void {
    try {
      const context = this.xComponentController.getXComponentContext();
      if (!context) {
        this.reportError(new Error('Failed to get XComponent context'));
        return;
      }

      const startupConfig = this.readStartupConfig();
      if (startupConfig.enableVideoOverlays === true) {
        this.overlayNative = context as INativeContext;
        this.overlayNative.AttachOverlayContent?.(this.xComponentId, this.overlayContent);
      }
      this.updateXComponentMode(startupConfig);
      this.applyDisplayMetrics(startupConfig);
      this.attachUserDataDirectory(startupConfig);
      this.droppedFileDir =
        startupConfig.userDataDir ? `${startupConfig.userDataDir}/dropped` : '';
      this.prepareRuntimeAssets(startupConfig);
      this.attachIcuDataDescriptor(startupConfig);
      this.surfaceReady = false;
      this.setSurfaceReady(false);
      // Success is logged, not toasted: shells ship this, and users should not see bring-up steps.
      console.info('WebWindow: 1/2 onLoad fired (libweb_engine.so loaded)');
      this.nativeContext = new NativeContext(this.xComponentId);
      const abilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.nativeContext.init(
        context as INativeContext,
        abilityContext,
        startupConfig,
        (action: string): void => this.handleWindowAction(action),
        (stateJson: string): void => this.handleBrowserState(stateJson),
        (stateJson: string): void => this.handleAuxiliaryWindowState(stateJson)
      );
      this.executePendingBrowserCommand();
      this.executePendingAuxiliaryDismiss();
      // 挂载前写入的配色命令在这里补放：Ability 的启动/回前台对账可能早于
      // WebWindow 挂载，@Monitor 不会因初值触发，冷启动靠这一步落地。
      this.executePendingColorSchemeCommand();
      this.nativeContext.OnSurfaceCreated();
      this.notifyWindowId();
      this.nativeContext.OnThemeFontChanged(this.themeFontId);
      this.nativeContext.OnVisibilityChanged(this.appVisible);
      this.nativeContext.OnFocusChanged(this.appVisible);
      this.notifyCurrentBounds();
      this.requestXComponentFocus();
      const swallowed = this.nativeContext.takeLastError();
      if (swallowed) {
        this.showDiagnostic(`2/2 初始化失败: ${swallowed}`);
      } else {
        console.info('WebWindow: 2/2 engine initialized');
      }
    } catch (error) {
      this.closeIcuDataDescriptor();
      this.reportError(this.normalizeError(error));
    }
  }

  private destroyNativeContext(): void {
    this.overlayNative?.DetachOverlayContent?.(this.xComponentId);
    this.overlayNative = null;
    if (this.nativeContext) {
      this.setSurfaceReady(false);
      this.surfaceReady = false;
      this.nativeContext.OnVisibilityChanged(false);
      this.nativeContext.OnSurfaceDestroyed();
      this.nativeContext.destroy();
      this.nativeContext = null;
    }

    this.closeIcuDataDescriptor();
  }

  private requestXComponentFocus(): void {
    try {
      this.getUIContext().getFocusController().requestFocus(this.xComponentId);
    } catch (error) {
    }
  }

  private restoreXComponentFocus(delayMs: number = 0): void {
    if (!this.nativeContext || !this.appVisible) {
      return;
    }

    this.clearFocusRecoveryTimers();
    this.focusRecoveryTimers.push(setTimeout((): void => {
      if (!this.nativeContext || !this.appVisible) {
        return;
      }
      this.requestXComponentFocus();
      this.nativeContext.OnFocusChanged(true);
      this.requestNativeInputRecovery();
    }, delayMs));
  }

  private requestNativeInputRecovery(): void {
    if (!this.nativeContext || !this.appVisible) {
      return;
    }
    const command: BrowserCommandPayload = {
      command: 'recoverInput',
      activationEpoch: this.lastActivationEpoch,
      focusedTarget: this.lastFocusedTarget,
      sidePanelEntryId: this.lastSidePanelEntryId
    };
    this.nativeContext.ExecuteBrowserCommand(JSON.stringify(command));
  }

  private clearFocusRecoveryTimers(): void {
    this.focusRecoveryTimers.forEach((timer: number): void => clearTimeout(timer));
    this.focusRecoveryTimers = [];
  }

  private attachIcuDataDescriptor(config: AuraStartupConfig): void {
    if (!this.icuRawFdOpen) {
      const hostContext = this.getUIContext().getHostContext() as common.Context | undefined;
      if (!hostContext) {
        throw new Error('Failed to get host context for Chromium ICU data');
      }

      const descriptor = hostContext.resourceManager.getRawFdSync(ICU_DATA_RAWFILE_PATH);
      this.icuDataFd = Number(descriptor.fd);
      this.icuDataOffset = Number(descriptor.offset);
      this.icuDataLength = Number(descriptor.length);
      if (this.icuDataFd < 0 || this.icuDataOffset < 0 || this.icuDataLength <= 0) {
        hostContext.resourceManager.closeRawFdSync(ICU_DATA_RAWFILE_PATH);
        throw new Error('Chromium ICU rawfile descriptor is invalid');
      }
      this.icuRawFdOpen = true;
    }

    config.icuDataFd = this.icuDataFd;
    config.icuDataOffset = this.icuDataOffset;
    config.icuDataLength = this.icuDataLength;
  }

  private attachUserDataDirectory(config: AuraStartupConfig): void {
    const hostContext = this.getUIContext().getHostContext() as common.Context | undefined;
    if (!hostContext || !hostContext.filesDir) {
      throw new Error('Failed to get Chromium user data directory');
    }
    const safeProfileId = this.profileId.trim().replace(/[^a-zA-Z0-9._-]/g, '_').substring(0, 96) || 'local';
    if (safeProfileId === 'local') {
      // Preserve the legacy path so existing users keep their current profile.
      config.userDataDir = `${hostContext.filesDir}/chromium-profile`;
    } else {
      const profilesDir = `${hostContext.filesDir}/chromium-profiles`;
      if (!fileIo.accessSync(profilesDir)) {
        fileIo.mkdirSync(profilesDir, true);
      }
      config.userDataDir = `${profilesDir}/${safeProfileId}`;
    }
    config.printOutputDir = `${hostContext.filesDir}/chromium-print`;
  }

  private prepareRuntimeAssets(config: AuraStartupConfig): void {
    const hostContext = this.getUIContext().getHostContext() as common.Context | undefined;
    if (!hostContext || !hostContext.filesDir) {
      throw new Error('Failed to get Chromium runtime directory');
    }

    const runtimeVersion = this.readRuntimeAssetVersion(hostContext);
    // Each manifest owns its extracted files. A -> B -> A must not reuse A's
    // old completion marker while the shared directory still contains B.
    // Isolation also keeps an interrupted extraction from changing another
    // version's completed runtime, including versions using the legacy path.
    const runtimeDir = `${hostContext.filesDir}/chromium-runtime/${runtimeVersion}`;
    const localesDir = `${runtimeDir}/locales`;
    if (!fileIo.accessSync(runtimeDir)) {
      fileIo.mkdirSync(runtimeDir, true);
    }
    if (!fileIo.accessSync(localesDir)) {
      fileIo.mkdirSync(localesDir, true);
    }

    const markerPath = `${runtimeDir}/.complete-${runtimeVersion}`;
    if (!fileIo.accessSync(markerPath)) {
      for (const fileName of COMMON_RUNTIME_RAWFILES) {
        this.extractRawFile(
          hostContext,
          `chromium/${fileName}`,
          `${runtimeDir}/${fileName}`
        );
      }
      // A signed application may carry an optional public phishing snapshot.
      // Remove the previous version when the new package omits it; otherwise
      // an old extracted file could silently survive an app upgrade.
      const rawFiles = hostContext.resourceManager.getRawFileListSync('chromium');
      for (const rulesName of ['v8_context_snapshot.bin', 'ohos_phishing_rules.json', 'ohos_phishing_updates.json']) {
        const rulesPath = `${runtimeDir}/${rulesName}`;
        if (rawFiles.some((name: string): boolean =>
          name === rulesName || name === `chromium/${rulesName}`)) {
          this.extractRawFile(hostContext, `chromium/${rulesName}`, rulesPath);
        } else if (fileIo.accessSync(rulesPath)) {
          fileIo.unlinkSync(rulesPath);
        }
      }
      this.writeFile(markerPath, runtimeVersion);
    }
    // A runtime directory created by an older shell can carry a completion
    // marker while missing v8_context_snapshot.bin: the 155-era shell never
    // unpacked it, and the marker then blocks the whole extraction block.
    // The engine needs this file in resourcesDir at startup (V8 snapshot),
    // so repair it even when the marker says the directory is complete.
    const contextSnapshotPath = `${runtimeDir}/v8_context_snapshot.bin`;
    if (!fileIo.accessSync(contextSnapshotPath)) {
      const snapshotRawFiles = hostContext.resourceManager.getRawFileListSync('chromium');
      if (snapshotRawFiles.some((name: string): boolean =>
        name === 'v8_context_snapshot.bin' || name === 'chromium/v8_context_snapshot.bin')) {
        this.extractRawFile(hostContext, 'chromium/v8_context_snapshot.bin', contextSnapshotPath);
      }
    }

    const localeFiles = hostContext.resourceManager.getRawFileListSync('chromium/locales');
    const applicationLocale = this.resolveChromiumLocale(localeFiles);
    const localeDestination = `${localesDir}/${applicationLocale}.pak`;
    const localeMarkerPath = `${runtimeDir}/.locale-${applicationLocale}-${runtimeVersion}`;
    if (!fileIo.accessSync(localeMarkerPath)) {
      this.extractRawFile(
        hostContext,
        `chromium/locales/${applicationLocale}.pak`,
        localeDestination
      );
      this.writeFile(localeMarkerPath, runtimeVersion);
    }

    config.resourcesDir = runtimeDir;
    config.applicationLocale = applicationLocale;
  }

  private readRuntimeAssetVersion(hostContext: common.Context): string {
    const content = hostContext.resourceManager.getRawFileContentSync(RUNTIME_VERSION_RAWFILE_PATH);
    let version = '';
    for (let index = 0; index < content.byteLength; index++) {
      version += String.fromCharCode(content[index]);
    }
    version = version.trim();
    if (!/^[0-9a-f]{64}$/.test(version)) {
      throw new Error('Chromium runtime version manifest is invalid');
    }
    return version;
  }

  private resolveChromiumLocale(localeFiles: string[]): string {
    const availableLocales: string[] = localeFiles
      .map((fileName: string): string => {
        const leafName = fileName.substring(fileName.lastIndexOf('/') + 1);
        return leafName.endsWith('.pak') ? leafName.substring(0, leafName.length - 4) : leafName;
      })
      .filter((locale: string): boolean => !locale.includes('_'));
    const systemLocale = i18n.System.getSystemLanguage().replace('_', '-');
    const candidates: string[] = [ systemLocale ];
    if (systemLocale.startsWith('zh-Hans')) {
      candidates.push('zh-CN');
    } else if (systemLocale.startsWith('zh-Hant')) {
      candidates.push('zh-TW');
    }
    candidates.push(systemLocale.split('-')[0]);
    candidates.push('en-US');

    for (const candidate of candidates) {
      if (availableLocales.includes(candidate)) {
        return candidate;
      }
    }
    return 'en-US';
  }

  private extractRawFile(
    hostContext: common.Context,
    rawFilePath: string,
    destinationPath: string
  ): void {
    const content = hostContext.resourceManager.getRawFileContentSync(rawFilePath);
    const buffer = content.buffer.slice(
      content.byteOffset,
      content.byteOffset + content.byteLength
    ) as ArrayBuffer;
    const file = fileIo.openSync(
      destinationPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY
    );
    try {
      const bytesWritten = fileIo.writeSync(file.fd, buffer);
      if (bytesWritten !== content.byteLength) {
        throw new Error(`Short write while extracting ${rawFilePath}`);
      }
    } finally {
      fileIo.closeSync(file);
    }
  }

  private writeFile(path: string, content: string): void {
    const file = fileIo.openSync(
      path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY
    );
    try {
      fileIo.writeSync(file.fd, content);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private closeIcuDataDescriptor(): void {
    if (!this.icuRawFdOpen) {
      return;
    }

    try {
      const hostContext = this.getUIContext().getHostContext() as common.Context | undefined;
      hostContext?.resourceManager.closeRawFdSync(ICU_DATA_RAWFILE_PATH);
    } catch (error) {
      console.error('Failed to close Chromium ICU rawfile descriptor:', error);
    }
    this.icuRawFdOpen = false;
    this.icuDataFd = -1;
    this.icuDataOffset = 0;
    this.icuDataLength = 0;
  }

  private initWindowListeners(): void {
    try {
      const hostContext = this.getUIContext().getHostContext() as common.Context | undefined;
      if (!hostContext) {
        return;
      }

      window.getLastWindow(hostContext).then((win: window.Window) => {
        this.activeWindow = win;
        this.lastPwaWindowActive = -1;
        this.applyPwaWindowDecor(Boolean(AppStorage.get('auraPwaWindowActive') ?? false));
        this.notifyWindowId();
        this.notifyCurrentBounds();
        this.notifyWindowStatus();
        try {
          win.on('freeWindowModeChange', (): void => this.notifyWindowId());
        } catch (error) {
          // Older systems retain the conservative foreground-tab fallback.
        }
        win.on('windowSizeChange', (size: window.Size) => {
          this.handleWindowSizeChange(size);
        });
        win.on('windowEvent', (event: window.WindowEventType) => {
          this.handleWindowEvent(event);
        });
        try {
          win.on('windowStatusChange', (status: window.WindowStatusType): void => {
            this.onWindowStatus?.(Number(status));
            this.restoreXComponentFocus(80);
          });
        } catch (statusChangeError) {
          try {
            win.on('windowStatusDidChange', (status: window.WindowStatusType): void => {
              this.onWindowStatus?.(Number(status));
              this.restoreXComponentFocus(80);
            });
          } catch (statusDidChangeError) {
          }
        }
        try {
          win.on('windowRectChange', (options: window.RectChangeOptions) => {
            this.handleWindowRectChange(options);
          });
        } catch (error) {
          // Some device classes expose only windowSizeChange.
        }
        try {
          win.on('rotationChange', (info: window.RotationChangeInfo) => {
            if (info.type !== window.RotationChangeType.WINDOW_DID_ROTATE) {
              return;
            }
            if (this.rotationSyncTimer >= 0) {
              clearTimeout(this.rotationSyncTimer);
            }
            this.rotationSyncTimer = setTimeout(() => {
              this.rotationSyncTimer = -1;
              this.configureSurfaceRotation();
              this.notifyCurrentBounds();
              this.scheduleBoundsSettle();
            }, 0);
          });
        } catch (error) {
          // API 19+ rotation callbacks are unavailable on some device classes.
        }
      }).catch((error: Error) => {
        this.reportError(error);
      });
    } catch (error) {
      this.reportError(this.normalizeError(error));
    }
  }

  private notifyWindowId(): void {
    if (!this.nativeContext || !this.activeWindow) {
      return;
    }

    try {
      const windowId = Number(this.activeWindow.getWindowProperties().id);
      if (windowId > 0) {
        let freeWindowMode: boolean = false;
        try {
          freeWindowMode = this.activeWindow.isInFreeWindowMode();
        } catch (error) {
          // API 22+: unknown support must not open an unusable fullscreen popup.
        }
        this.nativeContext.OnWindowIdChanged(windowId, freeWindowMode);
      }
    } catch (error) {
    }
  }

  private removeWindowListeners(): void {
    if (!this.activeWindow) {
      return;
    }

    try {
      this.activeWindow.off('windowSizeChange');
    } catch (error) {
    }
    try {
      this.activeWindow.off('freeWindowModeChange');
    } catch (error) {
    }
    try {
      this.activeWindow.off('windowRectChange');
    } catch (error) {
    }
    try {
      this.activeWindow.off('windowEvent');
    } catch (error) {
    }
    try {
      this.activeWindow.off('windowStatusChange');
    } catch (error) {
    }
    try {
      this.activeWindow.off('windowStatusDidChange');
    } catch (error) {
    }
    try {
      this.activeWindow.off('rotationChange');
    } catch (error) {
    }

    this.clearFocusRecoveryTimers();
    if (this.rotationSyncTimer >= 0) {
      clearTimeout(this.rotationSyncTimer);
      this.rotationSyncTimer = -1;
    }
    if (this.boundsSettleTimer >= 0) {
      clearTimeout(this.boundsSettleTimer);
      this.boundsSettleTimer = -1;
    }

    this.activeWindow = null;
    this.lastPwaWindowActive = -1;
  }

  private handleWindowAction(action: string): void {
    if (action === 'close') {
      // A second browser window (aura_win_, e.g. incognito) is hosted in the
      // same UIAbility as the first: ending the ability for it quit the whole
      // app with exit code 0 whenever incognito was left. Only the window the
      // ability exists for -- the main one, or a PWA in its own ability --
      // ends it. The shell learns that the second window went away from its
      // window state, as it learnt that it came.
      if (this.xComponentId.startsWith('aura_win_')) {
        console.info(`WebWindow: ${this.xComponentId} closed; the ability stays`);
        return;
      }
      const hostContext = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
      hostContext?.terminateSelf().catch((error: Error) => {
        this.reportError(error);
      });
      return;
    }

    if (!this.activeWindow) {
      return;
    }

    let operation: Promise<void> | undefined;
    try {
      switch (action) {
        case 'enterFullscreen':
          operation = this.activeWindow.setWindowLayoutFullScreen(true);
          break;
        case 'exitFullscreen':
          operation = this.activeWindow.setWindowLayoutFullScreen(false);
          break;
        case 'maximize':
          operation = this.activeWindow.maximize();
          break;
        case 'minimize':
          operation = this.activeWindow.minimize();
          break;
        case 'restore':
          // Free-window mode may already have opened this ability floating.
          // recover() then rejects with a repeated-operation error, which is
          // not a popup creation failure.
          if (this.activeWindow.getWindowStatus() === window.WindowStatusType.FLOATING) {
            return;
          }
          operation = this.activeWindow.recover();
          break;
        case 'startMoving':
          operation = this.activeWindow.startMoving();
          break;
        default:
          return;
      }
    } catch (error) {
      this.reportError(this.normalizeError(error));
      if (action === 'restore') {
        this.fallbackPopupToTab();
      }
      return;
    }

    operation.catch((error: Error) => {
      this.reportError(error);
      if (action === 'restore') {
        this.fallbackPopupToTab();
      }
    });
  }

  private fallbackPopupToTab(): void {
    if (this.xComponentId.startsWith('aura_win_')) {
      this.nativeContext?.ExecuteBrowserCommand(JSON.stringify({ command: 'fallbackWebPopupToTab' }));
    }
  }

  private handleWindowSizeChange(size: window.Size): void {
    if (!this.nativeContext) {
      return;
    }

    this.restoreXComponentFocus(80);
    this.notifyWindowStatus();

    if (this.activeWindow) {
      try {
        const properties = this.activeWindow.getWindowProperties();
        this.updateSurfaceRect(this.surfaceRectInWindow(
          Number(properties.windowRect.left),
          Number(properties.windowRect.top),
          Number(size.width),
          Number(size.height)));
        this.scheduleBoundsSettle();
        return;
      } catch (error) {
      }
    }

    this.updateSurfaceRect({
      x: this.hasWindowOrigin ? this.windowOriginX : 0,
      y: this.hasWindowOrigin ? this.windowOriginY : 0,
      width: size.width,
      height: size.height
    });
    this.scheduleBoundsSettle();
  }

  private handleWindowRectChange(options: window.RectChangeOptions): void {
    if (!this.nativeContext) {
      return;
    }

    this.restoreXComponentFocus(80);
    this.notifyWindowStatus();

    this.updateSurfaceRect(this.surfaceRectInWindow(
      Number(options.rect.left),
      Number(options.rect.top),
      Number(options.rect.width),
      Number(options.rect.height)));
    this.scheduleBoundsSettle();
  }

  // The rect reported right at a window size/rotation event can still carry
  // the old orientation's component size -- onAreaChange lands a layout pass
  // later. Re-report once the layout has settled so the surface always ends
  // at the real bounds; a missed pass once left the page stretched until the
  // app was restarted.
  private scheduleBoundsSettle(): void {
    if (this.boundsSettleTimer >= 0) {
      clearTimeout(this.boundsSettleTimer);
    }
    this.boundsSettleTimer = setTimeout((): void => {
      this.boundsSettleTimer = -1;
      this.notifyCurrentBounds();
    }, 150);
  }

  private handleWindowEvent(event: window.WindowEventType): void {
    if (!this.nativeContext) {
      return;
    }

    if (event === window.WindowEventType.WINDOW_ACTIVE ||
      event === window.WindowEventType.WINDOW_SHOWN) {
      this.notifyWindowId();
      this.notifyCurrentBounds();
      this.restoreXComponentFocus(80);
      return;
    }
    if (event === window.WindowEventType.WINDOW_INACTIVE ||
      event === window.WindowEventType.WINDOW_HIDDEN) {
      this.nativeContext.OnFocusChanged(false);
    }
  }

  private notifyCurrentBounds(): void {
    if (!this.nativeContext || !this.activeWindow) {
      return;
    }

    try {
      const properties = this.activeWindow.getWindowProperties();
      this.updateSurfaceRect(this.surfaceRectInWindow(
        Number(properties.windowRect.left),
        Number(properties.windowRect.top),
        Number(properties.windowRect.width),
        Number(properties.windowRect.height)));
    } catch (error) {
      this.reportError(this.normalizeError(error));
    }
  }

  // The component's box in screen px: the window origin plus the component's
  // offset in it. The native side reads touch positions relative to the
  // component and root positions in screen coordinates, so both stay right
  // as long as this origin is where the component really is. Until the first
  // layout pass reports an area, the whole window stands in, as before.
  private surfaceRectInWindow(windowLeft: number, windowTop: number,
    windowWidth: number, windowHeight: number): WindowRect {
    if (!this.hasComponentArea) {
      return { x: windowLeft, y: windowTop, width: windowWidth, height: windowHeight };
    }
    return {
      x: windowLeft + this.componentOffsetXPx,
      y: windowTop + this.componentOffsetYPx,
      width: this.componentWidthPx,
      height: this.componentHeightPx
    };
  }

  private handleComponentAreaChange(area: Area): void {
    const ui = this.getUIContext();
    const offsetX = Math.round(ui.vp2px(Number(area.globalPosition.x ?? 0)));
    const offsetY = Math.round(ui.vp2px(Number(area.globalPosition.y ?? 0)));
    const width = Math.round(ui.vp2px(Number(area.width)));
    const height = Math.round(ui.vp2px(Number(area.height)));
    if (width <= 0 || height <= 0) {
      return;
    }
    if (this.hasComponentArea && offsetX === this.componentOffsetXPx &&
      offsetY === this.componentOffsetYPx && width === this.componentWidthPx &&
      height === this.componentHeightPx) {
      return;
    }
    this.hasComponentArea = true;
    this.componentOffsetXPx = offsetX;
    this.componentOffsetYPx = offsetY;
    this.componentWidthPx = width;
    this.componentHeightPx = height;
    this.notifyCurrentBounds();
  }

  // Where this component sits in the window, in vp. The shell reports its
  // bubble anchors (setAnchorRects) in the window's coordinates, and
  // Chromium's window is this component, not the whole window; without the
  // offset a 2in1's tab strip and toolbar were counted twice and bubbles
  // opened below their buttons.
  //
  // Sent with every surface update rather than only when the area changes:
  // the first area change comes before the engine is there to hear it, and
  // the area rarely changes after that, so the offset never arrived.
  private notifySurfaceOffset(): void {
    if (!this.nativeContext || !this.hasComponentArea) {
      return;
    }
    const ui = this.getUIContext();
    const payload: BrowserCommandPayload = {
      command: 'setSurfaceOffset',
      x: ui.px2vp(this.componentOffsetXPx),
      y: ui.px2vp(this.componentOffsetYPx)
    };
    this.nativeContext.ExecuteBrowserCommand(JSON.stringify(payload));
  }

  private notifyWindowStatus(): void {
    if (!this.activeWindow || !this.onWindowStatus) {
      return;
    }
    try {
      this.onWindowStatus(Number(this.activeWindow.getWindowStatus()));
    } catch (error) {
    }
  }

  private applyPwaWindowDecor(active: boolean): void {
    if (!this.manageWindowDecor) {
      return;
    }
    const marker = active ? 1 : 0;
    AppStorage.setOrCreate('auraPwaWindowActive', active);
    if (!this.activeWindow || this.lastPwaWindowActive === marker) {
      return;
    }
    this.lastPwaWindowActive = marker;
    try {
      const config = this.readStartupConfig();
      this.activeWindow.setWindowDecorVisible(!active && config.windowMode === 'windowed');
    } catch (error) {
    }
  }

  private updateSurfaceRect(rect: WindowRect): void {
    if (!this.nativeContext) {
      return;
    }
    // A mid-rotation rect can report a zero size while the window manager
    // swaps orientations (WMSLayout: "width or height should greater than
    // 0"). Zeroing the surface kills it; the settle pass follows with the
    // real bounds anyway, so the transient one is just dropped.
    if (rect.width <= 0 || rect.height <= 0) {
      return;
    }

    this.hasWindowOrigin = true;
    this.windowOriginX = rect.x;
    this.windowOriginY = rect.y;
    this.nativeContext.OnSurfaceChanged(rect, this.getDisplayDensity());
    this.markSurfaceReady();
    this.notifySurfaceOffset();
  }

  private configureSurfaceRotation(): void {
    try {
      // 2in1: keep the surface geometry stable while the container
      // compensates for the unfolded fold-display layer orientation.
      // Elsewhere the surface follows the window, and Chromium re-lays out
      // at the new size on rotation.
      this.xComponentController.setXComponentSurfaceRotation({ lock: this.lockSurfaceRotation });
    } catch (error) {
      console.warn('Failed to configure XComponent surface rotation:', error);
    }
  }

  private updateXComponentMode(config: AuraStartupConfig): void {
    this.lockSurfaceRotation = config.deviceClass === '2in1';
  }

  private markSurfaceReady(): void {
    if (this.surfaceReady) {
      return;
    }

    this.surfaceReady = true;
    this.setSurfaceReady(true);
  }

  private setSurfaceReady(ready: boolean): void {
    if (this.surfaceReadyStorageKey.trim().length > 0) {
      AppStorage.setOrCreate(this.surfaceReadyStorageKey, ready);
    }
  }

  // The page's box inside the window, in vp. A shell with its own top bar
  // gives this component less than the window, and the engine lays the page
  // out in this box, so a drag position has to be measured from its corner.
  private dragPointInPage(event: DragEvent): PointInPage {
    const ui = this.getUIContext();
    const offsetX = this.hasComponentArea ? ui.px2vp(this.componentOffsetXPx) : 0;
    const offsetY = this.hasComponentArea ? ui.px2vp(this.componentOffsetYPx) : 0;
    const point: PointInPage = {
      x: Number(event.getWindowX()) - offsetX,
      y: Number(event.getWindowY()) - offsetY
    };
    return point;
  }

  private dispatchDragStage(stage: 'enter' | 'move' | 'leave', event: DragEvent): void {
    if (!this.nativeContext) {
      return;
    }

    const point = this.dragPointInPage(event);
    const payload: BrowserCommandPayload = {
      command: 'dragEvent',
      stage: stage,
      x: point.x,
      y: point.y
    };
    if (stage === 'enter') {
      // While the finger is down HarmonyOS says only which types are coming,
      // and Blink shows the page only the type list too -- a drag's names and
      // bytes stay hidden until it is dropped. So a placeholder of each type
      // is exactly as much as anyone is allowed to see, and it is what makes
      // the page's dragenter fire with the right `types`.
      this.describeDragTypes(event, payload);
    }
    this.nativeContext.ExecuteBrowserCommand(JSON.stringify(payload));
  }

  private describeDragTypes(event: DragEvent, payload: BrowserCommandPayload): void {
    try {
      const summary: Record<string, number> = event.getSummary().summary;
      const types: string[] = Object.keys(summary);
      for (const type of types) {
        if (type === uniformTypeDescriptor.UniformDataType.PLAIN_TEXT) {
          payload.text = ' ';
        } else if (type === uniformTypeDescriptor.UniformDataType.HYPERLINK) {
          payload.urls = ['about:blank'];
        } else if (type === uniformTypeDescriptor.UniformDataType.HTML) {
          payload.html = ' ';
        } else if (!payload.files) {
          const placeholder: DroppedFileRef = {
            path: `${this.droppedFileDir}/pending/file`
          };
          payload.files = [placeholder];
        }
      }
    } catch (error) {
      // A summary the system would not give us is not worth failing over:
      // the drop still carries the real thing.
      console.warn(`WebWindow: no drag summary: ${this.normalizeError(error).message}`);
    }
  }

  private dispatchDrop(event: DragEvent): void {
    if (!this.nativeContext) {
      event.setResult(DragResult.DRAG_FAILED);
      return;
    }

    const point = this.dragPointInPage(event);
    const payload: BrowserCommandPayload = {
      command: 'dragEvent',
      stage: 'drop',
      x: point.x,
      y: point.y
    };
    const urls: string[] = [];
    const files: DroppedFileRef[] = [];
    try {
      const records: unifiedDataChannel.UnifiedRecord[] = event.getData().getRecords();
      let targetDir: string = '';
      for (const record of records) {
        // By type, not by instanceof. getRecords() hands back UnifiedRecord
        // objects and UDMF's own documentation says to read getType() and
        // cast -- instanceof against the subclasses matched nothing, which
        // is why no file was ever copied and the drop arrived empty.
        const type: string = record.getType();
        if (type === uniformTypeDescriptor.UniformDataType.PLAIN_TEXT) {
          payload.text = (record as unifiedDataChannel.PlainText).textContent;
        } else if (type === uniformTypeDescriptor.UniformDataType.HYPERLINK) {
          urls.push((record as unifiedDataChannel.Hyperlink).url);
        } else if (type === uniformTypeDescriptor.UniformDataType.HTML) {
          const markup = record as unifiedDataChannel.HTML;
          payload.html = markup.htmlContent;
          if (!payload.text && markup.plainContent) {
            payload.text = markup.plainContent;
          }
        } else {
          // Everything else that carries a file: general.file and every type
          // derived from it -- image, video, audio, folder, and the concrete
          // formats a file manager sends (general.jpeg, com.adobe.pdf, ...).
          // Asking for a uri rather than listing types keeps a format nobody
          // thought of from being dropped on the floor.
          const uri: string = this.fileUriOfRecord(record);
          if (uri.length === 0) {
            continue;
          }
          if (!targetDir) {
            targetDir = this.prepareDropDirectory();
          }
          const copied = this.copyDroppedFile(uri, targetDir);
          if (copied) {
            files.push(copied);
          }
        }
      }
    } catch (error) {
      console.error(`WebWindow: reading the drop failed: ${this.normalizeError(error).message}`);
    }
    if (urls.length > 0) {
      payload.urls = urls;
    }
    if (files.length > 0) {
      payload.files = files;
    }
    // A HEIC has to be turned into something Chromium can draw before the
    // drop is announced, because the announcement is what makes the shell
    // open it. Only then, and only for those files, is the drop delayed.
    if (files.some((file: DroppedFileRef) => this.needsTranscoding(file))) {
      this.transcodeForViewing(files)
        .then(() => {
          this.nativeContext?.ExecuteBrowserCommand(JSON.stringify(payload));
        });
    } else {
      this.nativeContext.ExecuteBrowserCommand(JSON.stringify(payload));
    }
    // The engine took delivery. Whether the page itself wanted it is a
    // separate question, answered by the dropNotHandled event -- telling the
    // system it failed here would only play the snap-back animation at a
    // reader whose file we did in fact accept.
    event.setResult(DragResult.DROP_ENABLED);
  }

  // Chromium has no HEIC decoder in any build -- the format is patented and
  // Chrome leans on the platform for it, which on Android means Android's
  // decoder and here means HarmonyOS's. A photo dragged out of the gallery is
  // a HEIC, so without this it arrives as a broken image.
  private needsTranscoding(file: DroppedFileRef): boolean {
    return file.mimeType === 'image/heic' || file.mimeType === 'image/heif';
  }

  private async transcodeForViewing(files: DroppedFileRef[]): Promise<void> {
    for (const file of files) {
      if (!this.needsTranscoding(file)) {
        continue;
      }
      const target = `${file.path}.jpg`;
      let source: image.ImageSource | null = null;
      let packer: image.ImagePacker | null = null;
      let handle: fileIo.File | null = null;
      try {
        source = image.createImageSource(file.path);
        packer = image.createImagePacker();
        handle = fileIo.openSync(target,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        await packer.packToFile(source, handle.fd, { format: 'image/jpeg', quality: 92 });
        file.viewPath = target;
      } catch (error) {
        // Leave viewPath unset: the shell then has the original, and a
        // picture it cannot show is better than no drop at all.
        console.error(`WebWindow: could not transcode ${file.name}: ${this.normalizeError(error).message}`);
      } finally {
        if (handle) {
          try {
            fileIo.closeSync(handle);
          } catch (error) {
          }
        }
        packer?.release();
        source?.release();
      }
    }
  }

  // The file a record points at, or '' when it points at none.
  //
  // A file manager may send general.file, or a concrete type such as
  // general.jpeg or com.adobe.pdf; all of them carry the uri the same way.
  // The cast is what UDMF asks for -- the object is the right shape even
  // when its declared class is the base one.
  private fileUriOfRecord(record: unifiedDataChannel.UnifiedRecord): string {
    // Image, Video, Audio and Folder each name their uri after themselves;
    // general.file and the concrete formats a file manager sends
    // (general.jpeg, com.adobe.pdf, ...) call it plain `uri`. Anything not
    // named here is still a File as far as its uri goes, which is what keeps
    // a format nobody thought of from being dropped on the floor.
    const type: string = record.getType();
    if (type === uniformTypeDescriptor.UniformDataType.IMAGE) {
      return this.asUri((record as unifiedDataChannel.Image).imageUri);
    }
    if (type === uniformTypeDescriptor.UniformDataType.VIDEO) {
      return this.asUri((record as unifiedDataChannel.Video).videoUri);
    }
    if (type === uniformTypeDescriptor.UniformDataType.AUDIO) {
      return this.asUri((record as unifiedDataChannel.Audio).audioUri);
    }
    if (type === uniformTypeDescriptor.UniformDataType.FOLDER) {
      return this.asUri((record as unifiedDataChannel.Folder).folderUri);
    }
    return this.asUri((record as unifiedDataChannel.File).uri);
  }

  // A uri we can actually copy from, or '' -- a record whose type we guessed
  // wrong about has no uri at all, and that is a record to skip, not a throw
  // that costs the rest of the drop.
  private asUri(value: string | undefined): string {
    return typeof value === 'string' ? value : '';
  }

  // One directory per drop, so two files of the same name from two drops do
  // not collide and a page cannot be handed a path it saw before.
  private prepareDropDirectory(): string {
    if (!this.droppedFileDir) {
      throw new Error('No directory to copy dropped files into');
    }
    this.droppedFileSequence += 1;
    const dir = `${this.droppedFileDir}/${Date.now().toString(36)}-${this.droppedFileSequence}`;
    fileIo.mkdirSync(dir, true);
    return dir;
  }

  private copyDroppedFile(uri: string, targetDir: string): DroppedFileRef | null {
    let source: fileIo.File | null = null;
    try {
      const name = this.safeDroppedFileName(new fileUri.FileUri(uri).name);
      const target = `${targetDir}/${name}`;
      source = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      fileIo.copyFileSync(source.fd, target);
      const copied: DroppedFileRef = {
        path: target,
        name: name,
        mimeType: this.mimeTypeForName(name),
        size: fileIo.statSync(target).size
      };
      return copied;
    } catch (error) {
      console.error(`WebWindow: could not copy a dropped file: ${this.normalizeError(error).message}`);
      return null;
    } finally {
      if (source) {
        try {
          fileIo.closeSync(source);
        } catch (error) {
        }
      }
    }
  }

  // The name comes from another app. It becomes a path component here and a
  // file name the page is shown, so it keeps only what a name may contain.
  private safeDroppedFileName(name: string): string {
    const trimmed = (name ?? '').replace(/[\/\\:*?"<>|\u0000]/g, '_').trim();
    if (!trimmed || trimmed === '.' || trimmed === '..') {
      return 'file';
    }
    return trimmed.substring(0, 120);
  }

  private mimeTypeForName(name: string): string {
    const dot = name.lastIndexOf('.');
    const extension = dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
    const known: Record<string, string> = {
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'bmp': 'image/bmp',
      'svg': 'image/svg+xml',
      'heic': 'image/heic',
      'heif': 'image/heif',
      'pdf': 'application/pdf',
      'txt': 'text/plain',
      'md': 'text/plain',
      'csv': 'text/csv',
      'html': 'text/html',
      'htm': 'text/html',
      'json': 'application/json',
      'xml': 'text/xml',
      'mp3': 'audio/mpeg',
      'wav': 'audio/wav',
      'm4a': 'audio/mp4',
      'ogg': 'audio/ogg',
      'mp4': 'video/mp4',
      'webm': 'video/webm',
      'mkv': 'video/x-matroska',
      'mov': 'video/quicktime'
    };
    return known[extension] ?? 'application/octet-stream';
  }

  // The page started dragging something. Chromium cannot ask HarmonyOS for
  // a drag itself -- that has to come from the UI thread, with a component to
  // draw the preview from -- so it asked us, and is now blocked waiting for
  // the answer. Every path out of here ends in finishPageDragOut.
  private startPageDragOut(event: BrowserRuntimeEvent): void {
    const text: string = event.text ?? '';
    const url: string = event.url ?? '';
    const html: string = event.html ?? '';
    const filePath: string = event.filePath ?? '';
    const data = new unifiedDataChannel.UnifiedData();
    let carried = false;
    if (filePath.length > 0) {
      // A picture. First, so an app that takes the first record it
      // understands gets the image rather than its address -- dragging a
      // photo into a chat should send the photo.
      const picture = new unifiedDataChannel.Image();
      picture.imageUri = fileUri.getUriFromPath(filePath);
      data.addRecord(picture);
      carried = true;
    }
    if (url.length > 0) {
      const link = new unifiedDataChannel.Hyperlink();
      link.url = url;
      link.description = text;
      data.addRecord(link);
      carried = true;
    }
    if (html.length > 0) {
      const markup = new unifiedDataChannel.HTML();
      markup.htmlContent = html;
      markup.plainContent = text;
      data.addRecord(markup);
      carried = true;
    }
    if (text.length > 0) {
      // Last, so an app that takes the first record it understands gets the
      // link or the markup rather than the bare text.
      const plain = new unifiedDataChannel.PlainText();
      plain.textContent = text;
      data.addRecord(plain);
      carried = true;
    }
    if (!carried) {
      this.finishPageDragOut(false);
      return;
    }

    this.dragOutImage =
      filePath.length > 0 ? `file://${filePath}` : '';
    this.dragOutLabel = url.length > 0 ? url : text;
    const info: dragController.DragInfo = {
      // The first finger: the one that has been held down since the long
      // press that started this. A mouse reports 0 too.
      pointerId: 0,
      data: data
    };
    try {
      this.getUIContext().getDragController()
        .executeDrag(() => {
          this.dragOutPreview();
        }, info)
        .then((result: dragController.DragEventParam) => {
          this.finishPageDragOut(result.event.getResult() === DragResult.DRAG_SUCCESSFUL);
        })
        .catch((error: Object) => {
          console.error(`WebWindow: the page's drag failed: ${this.normalizeError(error).message}`);
          this.finishPageDragOut(false);
        });
    } catch (error) {
      console.error(`WebWindow: could not start the page's drag: ${this.normalizeError(error).message}`);
      this.finishPageDragOut(false);
    }
  }

  private finishPageDragOut(dropped: boolean): void {
    this.dragOutLabel = '';
    this.dragOutImage = '';
    const payload: BrowserCommandPayload = {
      command: 'pageDragFinished',
      // HarmonyOS says whether it was taken, not what was done with it, and
      // a drag out of a page is a copy in every case we can start.
      operation: dropped ? 'copy' : 'none'
    };
    this.nativeContext?.ExecuteBrowserCommand(JSON.stringify(payload));
    const ended: BrowserRuntimeEvent = {
      version: 1,
      event: 'pageDragEnded',
      dropped: dropped
    };
    this.onRuntimeEvent?.(ended);
  }

  private dispatchAxisEvent(event: AxisEvent): void {
    if (!this.nativeContext) {
      return;
    }

    const payload: PointerEventPayload = {
      action: Number(event.action),
      pointerType: 'wheel',
      dispatchSource: 'arkui',
      pointerId: 0,
      button: 0,
      sourceTool: 0,
      x: Number(event.x),
      y: Number(event.y),
      rootX: Number(event.globalDisplayX ?? event.displayX),
      rootY: Number(event.globalDisplayY ?? event.displayY),
      rootWindowRelative: false,
      deltaX: Number(event.getHorizontalAxisValue()),
      deltaY: -Number(event.getVerticalAxisValue()),
      timestamp: Number(event.timestamp)
    };
    this.nativeContext.DispatchPointerEvent(payload);
  }

  private dispatchKeyEvent(event: KeyEvent): boolean {
    if (!this.nativeContext) {
      return false;
    }

    const payload: KeyEventPayload = {
      action: Number(event.type),
      keyCode: Number(event.keyCode),
      keyText: String(event.keyText),
      dispatchSource: 'arkui',
      sourceTool: Number(event.keySource),
      timestamp: Number(event.timestamp)
    };
    return this.nativeContext.DispatchKeyEvent(payload);
  }

  // 1.0.197：当前活动标签是否已在请求桌面版（以引擎回报的 requestDesktopSite
  // 为准）。所有下发都以它为基线，同值不重发，避免命令刷屏；切标签后由状态回
  // 报自动校正。
  private currentDesktopSite: boolean = false;
  // 已自动修正过的 host：每个 host 只补一次，防止服务端重定向造成 reload 循环。
  private desktopHealHosts: string[] = [];
  // 最近一次引擎回报的 URL（currentUrl 只由外壳命令更新，不反映页面内跳转）。
  private lastStateUrl: string = '';

  loadUrl(url: string): void {
    this.currentUrl = url;
    if (!this.nativeContext) {
      this.showDiagnostic('导航失败: native context 未创建 (onLoad 未触发?)');
      return;
    }
    // 导航前按「全局默认 + 站点名单」推导并下发桌面 UA：命中则引擎用桌面形状
    // UA（去 Mobile），WPS 这类按 UA 分流的活动页才能显示桌面组件；未命中则
    // 用手机形状 UA，保持手机浏览体验。
    this.applyDesktopUserAgent(url);
    this.nativeContext.Navigate(url);
  }

  // 是否应为该 URL 请求桌面版网站：全局默认 desktop 一律 true；否则看 host 是否
  // 在持久化的桌面版网站名单里（精确匹配）。
  private shouldUseDesktopSite(url: string): boolean {
    // 内部页永远不按桌面站点处理：桌面版默认开着时这里的无条件 true 会把
    // chrome://、chrome-extension:// 也算进名单，驱动 UA 注入与自愈对内部页
    // 动手（见 maybeHealDesktopSite 的注释）。与引擎侧护栏同一约定。
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return false;
    }
    // 单站「回到移动版」例外优先于全局开关：与引擎 IsDesktopSiteHost() 同一约定，
    // 否则全局桌面版开着时外壳会在这里把 UA 又推回桌面，页面与按钮各说各话。
    const mobileRaw = String(AppStorage.get('auraMobileSites') ?? '');
    const targetHost: string = this.hostOf(url);
    if (mobileRaw.length > 0 && targetHost.length > 0) {
      const excluded: string[] = mobileRaw.split('\n');
      for (let i = 0; i < excluded.length; i++) {
        if (excluded[i].trim() === targetHost) {
          return false;
        }
      }
    }
    // 派生键优先：平板/桌面家族在读者没亲手设过开关时按形态默认桌面版
    // （AuraShell.refreshUaDefaultEffective 发布，见 auraUaDefaultSet）。
    const def = String(AppStorage.get('auraUaDefaultEffective') ??
      AppStorage.get('auraUaDefault') ?? 'mobile');
    if (def === 'desktop') {
      return true;
    }
    const raw = String(AppStorage.get('auraDesktopSites') ?? '');
    if (raw.length === 0) {
      return false;
    }
    const host: string = this.hostOf(url);
    if (!host) {
      return false;
    }
    const list: string[] = raw.split('\n');
    for (let i = 0; i < list.length; i++) {
      const item: string = list[i].trim();
      if (item.length > 0 && item === host) {
        return true;
      }
    }
    return false;
  }

  // 无依赖地从一个 URL 取出 host（去掉协议/路径/端口/userinfo），避免引入 URL
  // 模块；http(s) 之外的非常规 scheme 返回空串，不会误匹配桌面名单。
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
    const h: number = rest.indexOf('#');
    if (slash >= 0 && slash < end) {
      end = slash;
    }
    if (q >= 0 && q < end) {
      end = q;
    }
    if (h >= 0 && h < end) {
      end = h;
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

  // 把桌面 UA 偏好应用到当前标签（在导航前调用）；状态未变则跳过，避免命令刷屏。
  private applyDesktopUserAgent(url: string): void {
    const want: boolean = this.shouldUseDesktopSite(url);
    if (want === this.currentDesktopSite) {
      return;
    }
    this.currentDesktopSite = want;
    this.nativeContext?.ExecuteBrowserCommand(
      JSON.stringify({ command: 'setRequestDesktopSite', enabled: want }));
  }

  private executePendingBrowserCommand(): void {
    if (!this.nativeContext || this.browserCommandRevision <= 0 ||
      this.browserCommandRevision === this.lastExecutedBrowserCommandRevision ||
      !this.browserCommandText || this.browserCommandText.trim().length === 0) {
      return;
    }

    const sequenced: SequencedBrowserCommandBatch | undefined =
      this.parseSequencedBrowserCommands(this.browserCommandText);
    if (!sequenced) {
      if (this.nativeContext.ExecuteBrowserCommand(
        this.injectDesktopUserAgentText(this.browserCommandText))) {
        this.lastExecutedBrowserCommandRevision = this.browserCommandRevision;
      }
      return;
    }

    // Run only the commands this window has not run yet: the channel writes
    // every recent one each time, so a write that replaced another before
    // this monitor ran still carries the commands it held.
    if (sequenced.channel !== this.browserCommandChannel) {
      this.browserCommandChannel = sequenced.channel;
      this.lastExecutedBrowserCommandSeq = 0;
    }
    const fresh: SequencedBrowserCommand[] = sequenced.sequencedCommands.filter(
      (entry: SequencedBrowserCommand): boolean => entry.seq > this.lastExecutedBrowserCommandSeq);
    if (fresh.length === 0) {
      this.lastExecutedBrowserCommandRevision = this.browserCommandRevision;
      return;
    }
    const commands: BrowserCommandPayload[] =
      fresh.map((entry: SequencedBrowserCommand): BrowserCommandPayload => entry.command);
    const withDesktopUa: BrowserCommandPayload[] = this.injectDesktopUserAgent(commands);
    const text: string = JSON.stringify(
      withDesktopUa.length === 1 ? withDesktopUa[0] : withDesktopUa);
    if (this.nativeContext.ExecuteBrowserCommand(text)) {
      this.lastExecutedBrowserCommandRevision = this.browserCommandRevision;
      this.lastExecutedBrowserCommandSeq = fresh[fresh.length - 1].seq;
    }
  }

  // 外壳导航走命令通道（navigate 直发引擎），不经过 loadUrl —— 因此在命令发出
  // 前按持久化名单注入桌面 UA，保证 navigate 的首次请求就是桌面形状。
  // newTab 不在此列：命令发出时新标签尚未成为当前标签，注入会落到旧标签上。
  private injectDesktopUserAgent(commands: BrowserCommandPayload[]): BrowserCommandPayload[] {
    const out: BrowserCommandPayload[] = [];
    // 同步一次名单：引擎在每次导航时按它决定 UA，脚本后台新开的标签也靠它。
    let sitesSent: boolean = false;
    for (let i = 0; i < commands.length; i++) {
      const cmd: BrowserCommandPayload = commands[i];
      const target: string = cmd.command === 'navigate' ? (cmd.url ?? '') :
        (cmd.command === 'reload' ? this.lastStateUrl : '');
      if (target.length > 0) {
        if (!sitesSent) {
          sitesSent = true;
          out.push({
            command: 'setDesktopSites',
            sites: String(AppStorage.get('auraDesktopSites') ?? ''),
            allSites: String(AppStorage.get('auraUaDefaultEffective') ??
              AppStorage.get('auraUaDefault') ?? 'mobile') === 'desktop',
            mobileSites: String(AppStorage.get('auraMobileSites') ?? '')
          });
        }
        const want: boolean = this.shouldUseDesktopSite(target);
        if (want !== this.currentDesktopSite) {
          out.push({ command: 'setRequestDesktopSite', enabled: want });
          this.currentDesktopSite = want;
        }
      }
      out.push(cmd);
    }
    return out;
  }

  private injectDesktopUserAgentText(text: string): string {
    try {
      if (text.trim().startsWith('[')) {
        const list: BrowserCommandPayload[] = JSON.parse(text) as BrowserCommandPayload[];
        return JSON.stringify(this.injectDesktopUserAgent(list));
      }
      const single: BrowserCommandPayload = JSON.parse(text) as BrowserCommandPayload;
      return JSON.stringify(this.injectDesktopUserAgent([single]));
    } catch (error) {
      return text;
    }
  }

  // 引擎内部导航（链接点击、脚本新建标签、服务端重定向）不经过外壳命令通道，
  // 导航前注入管不到。这里在状态回报后兜底：当前标签落在桌面名单里的站点、却
  // 仍以手机 UA 请求时，补发一次 setRequestDesktopSite 并重载；每个 host 只修一
  // 次，防止重定向来回造成 reload 循环。
  private maybeHealDesktopSite(state: BrowserStateSnapshot): void {
    if (!this.nativeContext) {
      return;
    }
    const url: string = state.url ?? '';
    if (url.length === 0 || state.requestDesktopSite === true) {
      return;
    }
    // 内部页（chrome://、chrome-extension://）永远以设备 UA 渲染，与引擎侧
    // ApplyUserAgentToWebContents 的护栏同一约定。桌面版默认开着时
    // shouldUseDesktopSite 对它们也返回 true —— 自愈于是对扩展页补发
    // setRequestDesktopSite + reload，把刚提交的导航顶掉：桌面版开着时
    // 「扩展磁贴要点两次」「地址栏跳一下」的最终源头（2026-10-21 日志：
    // 每次导航提交后 30~90ms 一条裸 reload，绕过命令通道无日志）。
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return;
    }
    if (!this.shouldUseDesktopSite(url)) {
      return;
    }
    const host: string = this.hostOf(url);
    if (!host || this.desktopHealHosts.indexOf(host) >= 0) {
      return;
    }
    this.desktopHealHosts.push(host);
    this.currentDesktopSite = true;
    this.nativeContext.ExecuteBrowserCommand(
      JSON.stringify({ command: 'setRequestDesktopSite', enabled: true }));
    this.nativeContext.ExecuteBrowserCommand(
      JSON.stringify({ command: 'reload' }));
  }

  // A BrowserCommandChannel's write, or undefined for anything else -- a
  // single command or a plain array written by a shell without the channel.
  private parseSequencedBrowserCommands(text: string): SequencedBrowserCommandBatch | undefined {
    if (!text.startsWith('{"channel"')) {
      return undefined;
    }
    try {
      const batch: SequencedBrowserCommandBatch = JSON.parse(text) as SequencedBrowserCommandBatch;
      if (typeof batch.channel !== 'string' || !Array.isArray(batch.sequencedCommands)) {
        return undefined;
      }
      return batch;
    } catch (error) {
      return undefined;
    }
  }

  private executePendingAuxiliaryDismiss(): void {
    if (!this.nativeContext || this.auxiliaryDismissWidget <= 0 ||
      this.auxiliaryDismissRevision <= 0 ||
      this.auxiliaryDismissRevision === this.lastAuxiliaryDismissRevision) {
      return;
    }

    if (this.nativeContext.DismissAuxiliaryWindow(this.auxiliaryDismissWidget)) {
      this.lastAuxiliaryDismissRevision = this.auxiliaryDismissRevision;
    }
  }

  private handleBrowserState(stateJson: string): void {
    if (!stateJson || stateJson.trim().length === 0) {
      return;
    }

    try {
      const parsed = JSON.parse(stateJson) as BrowserRuntimeEvent | BrowserStateSnapshot;
      const runtimeEvent = parsed as BrowserRuntimeEvent;
      if (runtimeEvent.event) {
        this.onRuntimeEvent?.(runtimeEvent);
        if (runtimeEvent.event === 'pageDragStarted') {
          // Chromium is waiting inside StartDrag for this to come back, so
          // it goes out even if the shell ignored the event.
          this.startPageDragOut(runtimeEvent);
        }
        if (runtimeEvent.event === 'pwaMenuClosed') {
          this.restoreXComponentFocus();
        }
        return;
      }
      const state = parsed as BrowserStateSnapshot;
      // 引擎回报的当前标签状态是下发基线；页面内跳转只有这里能看到。
      this.currentDesktopSite = state.requestDesktopSite === true;
      this.lastStateUrl = state.url ?? '';
      this.maybeHealDesktopSite(state);
      const nextActivationEpoch = Number(state.activationEpoch ?? 0);
      const nextFocusedTarget: 'webContents' | 'sidePanel' =
        state.focusedTarget === 'sidePanel' ? 'sidePanel' : 'webContents';
      const nextSidePanelEntryId = state.sidePanelEntryId ?? '';
      const browserTargetChanged = nextActivationEpoch > 0 &&
        nextActivationEpoch !== this.lastActivationEpoch;
      this.lastActivationEpoch = nextActivationEpoch;
      this.lastFocusedTarget = nextFocusedTarget;
      this.lastSidePanelEntryId = nextSidePanelEntryId;
      this.applyPwaWindowDecor(state.isPwaWindow);
      this.onBrowserState?.(state);
      if (browserTargetChanged) {
        this.restoreXComponentFocus();
      }
    } catch (error) {
      console.error('Failed to parse Chromium browser state:', error);
    }
  }

  private handleAuxiliaryWindowState(stateJson: string): void {
    if (!this.onAuxiliaryWindowState || !stateJson || stateJson.trim().length === 0) {
      return;
    }

    try {
      const state = JSON.parse(stateJson) as AuxiliaryWindowState;
      // Popups (aura_aux_), browser windows of their own (aura_win_: a new
      // window, a new incognito window, a tab dragged out) and installed web
      // apps (aura_pwa_) all reach the shell this way. Passing only popups
      // dropped every new browser window: the shell never made its surface,
      // and the engine, waiting for it, gave up on GPU compositing.
      const componentId: string = state.componentId ?? '';
      if (state.widget > 0 && (componentId.startsWith('aura_aux_') ||
        componentId.startsWith('aura_win_') || componentId.startsWith('aura_pwa_'))) {
        this.onAuxiliaryWindowState(state);
      }
    } catch (error) {
      console.error('Failed to parse Chromium auxiliary window state:', error);
    }
  }

  private readStartupConfig(): AuraStartupConfig {
    if (this.startupConfigText && this.startupConfigText.trim().length > 0) {
      try {
        const parsedConfig = JSON.parse(this.startupConfigText) as AuraStartupConfig;
        return parsedConfig;
      } catch (error) {
      }
    }

    return UIManager.buildAuraStartupConfig(this.currentUrl);
  }

  private getDisplayDensity(): number {
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      const densityPixels = Number(defaultDisplay.densityPixels ?? 0);
      if (densityPixels > 0) {
        return densityPixels;
      }

      const densityDpi = Number(defaultDisplay.densityDPI ?? 0);
      return densityDpi > 0 ? densityDpi / 160.0 : 1.0;
    } catch (error) {
      return 1.0;
    }
  }

  private applyDisplayMetrics(config: AuraStartupConfig): void {
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      config.displayWidth = Number(defaultDisplay.width);
      config.displayHeight = Number(defaultDisplay.height);
      config.displayDensity = this.getDisplayDensity();
    } catch (error) {
      config.displayWidth = 1920;
      config.displayHeight = 1080;
      config.displayDensity = 1.0;
    }
  }

  private normalizeError(error: Object): Error {
    if (error instanceof Error) {
      return error;
    }

    return new Error(String(error));
  }

  private reportError(error: Error): void {
    console.error('WebWindow error:', error);
    this.showDiagnostic(`引擎错误: ${error.message}`);
    if (this.onError) {
      this.onError(error);
    }
  }

  // Every failure in this component used to reach console.error only, which on
  // a device is indistinguishable from the engine simply doing nothing, so
  // failures are surfaced as toasts. The bring-up progress messages that used
  // to share this path are logged instead.
  private showDiagnostic(message: string): void {
    try {
      promptAction.showToast({ message: message, duration: 5000 });
    } catch (e) {
      console.error('showToast failed:', e);
    }
  }
}
