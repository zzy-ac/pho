import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/state_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:img_syncer/global.dart';
import 'package:img_syncer/logger/logger.dart';
import 'package:img_syncer/sync/background_runner.dart';
import 'package:img_syncer/sync/bg_task_scheduler.dart';

Timer? autoSyncTimer;

Future<void> reloadAutoSyncTimer() async {
  if (autoSyncTimer != null) {
    autoSyncTimer!.cancel();
  }
  // iOS 不使用 Timer.periodic：由系统 BGProcessingTask 调度后台同步。
  // 但仍需读 backgroundSyncEnabled：用户未开后台同步时不提交 BG task，
  // 与 Android 路径行为一致（避免每次启动都无条件 schedule）。
  // scheduleBgTaskViaChannel 内部已捕获异常，模拟器上的 .unavailable 不会冒泡。
  if (Platform.isIOS) {
    final prefs = await SharedPreferences.getInstance();
    final backgroundSyncEnable =
        prefs.getBool('backgroundSyncEnabled') ?? false;
    if (!backgroundSyncEnable) return;
    await scheduleBgTaskViaChannel();
    return;
  }
  final prefs = await SharedPreferences.getInstance();
  final backgroundSyncEnable = prefs.getBool('backgroundSyncEnabled') ?? false;
  if (!backgroundSyncEnable) return;
  final backgroundSyncInterval =
      Duration(minutes: prefs.getInt('backgroundSyncInterval') ?? 60 * 12);
  print("backgroundSyncInterval: $backgroundSyncInterval");
  autoSyncTimer = Timer.periodic(backgroundSyncInterval, (timer) async {
    print("start auto sync");
    if (settingModel.localFolder == "" || !settingModel.isRemoteStorageSetted) {
      return;
    }
    final wifiOnly = prefs.getBool('backgroundSyncWifiOnly') ?? true;
    if (wifiOnly) {
      final results = await Connectivity().checkConnectivity();
      if (!results.contains(ConnectivityResult.wifi)) {
        return;
      }
    }
    if (stateModel.isUploading() || stateModel.isDownloading()) return;
    await refreshUnsynchronizedPhotos();
    final Map<String, bool> uploadedIds = {};
    for (final id in stateModel.syncedIDs) {
      uploadedIds[id] = true;
    }
    final entities = await getPhotos();
    final all = entities.map((e) => Asset(local: e)).toList();
    // 重置中断标志：后台定时同步独立于手动 sync 的 stop 状态。
    stateModel.needStopSync = false;
    // 过滤逻辑（视频/图片跳过、日期边界、扩展名白名单）由 runSyncOnce
    // 内部调用 shouldSyncAsset 统一处理，替代原 sync_timer 内联 if 过滤段。
    // 行为变更：日期上界从原 +1day 宽限对齐为 canonical（无 offset）；
    // 新增按扩展名白名单过滤（原内联段无此检查）。
    await runSyncOnce(
      storage: storageClient,
      assets: all,
      uploadedIds: uploadedIds,
      parallelCount: settingModel.parallelCount,
      shouldStop: () => stateModel.needStopSync,
      refreshUnSync: true,
    );
  });
}

Future<List<AssetEntity>> getPhotos() async {
  List<AssetEntity> all = [];
  final re = await requestPermission();
  if (!re) return all;
  final List<AssetPathEntity> paths =
      await PhotoManager.getAssetPathList(type: RequestType.common);
  for (var path in paths) {
    if (path.name == settingModel.localFolder) {
      final newpath = await path.fetchPathProperties(
          filterOptionGroup: FilterOptionGroup(
        orders: [
          const OrderOption(
            type: OrderOptionType.createDate,
            asc: false,
          ),
        ],
      ));
      int assetOffset = 0;
      int assetPageSize = 100;
      while (true) {
        final List<AssetEntity> assets = await newpath!.getAssetListRange(
            start: assetOffset, end: assetOffset + assetPageSize);
        if (assets.isEmpty) {
          break;
        }
        all.addAll(assets);
        assetOffset += assetPageSize;
      }
      break;
    }
  }
  return all;
}

/// 打开应用自动同步：应用启动后自动将未同步的照片同步到云端。
/// 由设置页的「打开应用自动同步」开关（settingModel.autoSyncOnLaunch）控制，
/// 仅在用户开启开关且已配置网络存储时生效。
Future<void> runAutoSyncOnLaunch() async {
  try {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return;
    }
    if (!settingModel.autoSyncOnLaunch) return;
    if (settingModel.localFolder.isEmpty || !settingModel.isRemoteStorageSetted) {
      return;
    }
    // 等待启动时 Global.init 触发的本地相册刷新完成，避免拿到空列表导致
    // refreshUnsynchronizedPhotos 误清空 syncedIDs 后全量重传。
    for (var i = 0; i < 150; i++) {
      if (assetModel.isLocalRefreshing) {
        await Future.delayed(const Duration(milliseconds: 100));
      } else {
        break;
      }
    }
    if (assetModel.localAssets.isEmpty) {
      // 本地相册尚未加载则先刷新本地（refreshLocal 末尾会刷新未同步集合）
      await assetModel.refreshLocal(true);
    } else {
      await refreshUnsynchronizedPhotos();
    }
    final Map<String, bool> uploadedIds = {};
    for (final id in stateModel.syncedIDs) {
      uploadedIds[id] = true;
    }
    final entities = await getPhotos();
    final all = entities.map((e) => Asset(local: e)).toList();
    // 重置中断标志：启动自动同步独立于手动 sync 的 stop 状态。
    stateModel.needStopSync = false;
    await runSyncOnce(
      storage: storageClient,
      assets: all,
      uploadedIds: uploadedIds,
      parallelCount: settingModel.parallelCount,
      shouldStop: () => stateModel.needStopSync,
      refreshUnSync: true,
    );
  } catch (e) {
    logger.addLog("auto sync on launch failed: $e");
  }
}
