import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/desktop/widgets/dragable_divider.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:flutter_hbb/desktop/widgets/list_search_action_listener.dart';
import 'package:flutter_hbb/desktop/widgets/menu_button.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:flutter_hbb/web/dummy.dart'
    if (dart.library.html) 'package:flutter_hbb/web/web_unique.dart';

import '../../consts.dart';
import '../../desktop/widgets/material_mod_popup_menu.dart' as mod_menu;
import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../widgets/popup_menu.dart';

/// status of location bar
enum LocationStatus {
  /// normal bread crumb bar
  bread,

  /// show path text field
  pathLocation,

  /// show file search bar text field
  fileSearchBar
}

/// The status of currently focused scope of the mouse
/// A row of the file lists.
const double _rowHeight = 36.0;

enum MouseFocusScope {
  /// Mouse is in local field.
  local,

  /// Mouse is in remote field.
  remote,

  /// Mouse is not in local field, remote neither.
  none
}

class FileManagerPage extends StatefulWidget {
  FileManagerPage(
      {Key? key,
      required this.id,
      required this.password,
      this.loginMethod = '',
      required this.isSharedPassword,
      this.tabController,
      this.connToken,
      this.forceRelay})
      : super(key: key);
  final String id;
  final String? password;
  final String loginMethod;
  final bool? isSharedPassword;
  final bool? forceRelay;
  final String? connToken;
  final DesktopTabController? tabController;
  final SimpleWrapper<State<FileManagerPage>?> _lastState = SimpleWrapper(null);

  FFI get ffi => (_lastState.value! as _FileManagerPageState)._ffi;

  @override
  State<StatefulWidget> createState() {
    final state = _FileManagerPageState();
    _lastState.value = state;
    return state;
  }
}

class _FileManagerPageState extends State<FileManagerPage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final _mouseFocusScope = Rx<MouseFocusScope>(MouseFocusScope.none);

  final _dropMaskVisible = false.obs; // TODO impl drop mask
  final _overlayKeyState = OverlayKeyState();
  final _uniqueKey = UniqueKey();

  late FFI _ffi;

  FileModel get model => _ffi.fileModel;
  JobController get jobController => model.jobController;

  @override
  void initState() {
    super.initState();
    _ffi = FFI(null);
    _ffi.start(widget.id,
        isFileTransfer: true,
        password: widget.password,
        loginMethod: widget.loginMethod,
        isSharedPassword: widget.isSharedPassword,
        connToken: widget.connToken,
        forceRelay: widget.forceRelay);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ffi.dialogManager
          .showLoading(translate('Connecting...'), onCancel: closeConnection);
    });
    Get.put<FFI>(_ffi, tag: 'ft_${widget.id}');
    WakelockManager.enable(_uniqueKey);
    if (isWeb) {
      _ffi.ffiModel.updateEventListener(_ffi.sessionId, widget.id);
    }
    debugPrint("File manager page init success with id ${widget.id}");
    _ffi.dialogManager.setOverlayState(_overlayKeyState);
    // Call onSelected in post frame callback, since we cannot guarantee that the callback will not call setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.tabController?.onSelected?.call(widget.id);
    });
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    model.close().whenComplete(() {
      _ffi.close();
      _ffi.dialogManager.dismissAll();
      WakelockManager.disable(_uniqueKey);
      Get.delete<FFI>(tag: 'ft_${widget.id}');
    });
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      jobController.jobTable.refresh();
    }
  }

  Widget willPopScope(Widget child) {
    if (isWeb) {
      return WillPopScope(
        onWillPop: () async {
          clientClose(_ffi.sessionId, _ffi);
          return false;
        },
        child: child,
      );
    } else {
      return child;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Overlay(key: _overlayKeyState.key, initialEntries: [
      OverlayEntry(builder: (_) {
        return willPopScope(Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    if (!isWeb)
                      Expanded(
                          child: dropArea(FileManagerView(
                              model.localController, _ffi, _mouseFocusScope))),
                    if (!isWeb) sendColumn(),
                    Expanded(
                        child: dropArea(FileManagerView(
                            model.remoteController, _ffi, _mouseFocusScope))),
                  ],
                ).paddingAll(12),
              ),
              statusLine(),
            ],
          ),
        ));
      })
    ]);
  }

  // Files from the computer dropped on the other side are sent there; the
  // side shows where they go while they hover.
  Widget dropArea(FileManagerView fileView) {
    final isLocal = fileView.controller.isLocal;
    // rows dragged from the other side (FileDrag)
    final pane = DragTarget<FileDrag>(
      onWillAcceptWithDetails: (d) => d.data.isLocal != isLocal,
      onAcceptWithDetails: (d) {
        final from =
            d.data.isLocal ? model.localController : model.remoteController;
        final items = SelectedItems(isLocal: d.data.isLocal);
        for (final e in d.data.entries) {
          items.add(e);
        }
        from.sendFiles(items, from.getOtherSideDirectoryData());
        from.selectedItems.clear();
      },
      builder: (context, candidates, rejected) => Stack(
        children: [
          fileView,
          if (candidates.isNotEmpty)
            Positioned.fill(child: dropMask(fileView.controller)),
        ],
      ),
    );
    return DropTarget(
        onDragDone: (detail) {
          _dropMaskVisible.value = false;
          handleDragDone(detail, isLocal);
        },
        onDragEntered: (enter) {
          if (!isLocal) _dropMaskVisible.value = true;
        },
        onDragExited: (exit) {
          _dropMaskVisible.value = false;
        },
        child: Stack(
          children: [
            pane,
            if (!isLocal)
              Obx(() => _dropMaskVisible.value
                  ? Positioned.fill(child: dropMask(fileView.controller))
                  : Offstage()),
          ],
        ));
  }

  Widget dropMask(FileController there) {
    final dir = there.directory.value.path;
    final parts = PathUtil.split(dir, there.options.value.isWindows);
    final name = parts.isEmpty ? null : parts.last;
    return IgnorePointer(
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: MyTheme.accent.withOpacity(0.08),
          border: Border.all(color: MyTheme.accent, width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: MyTheme.accent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.arrow_downward_rounded, color: Colors.white, size: 18),
            SizedBox(width: 8),
            Text(
                translate(there.isLocal ? 'ft-drop-here' : 'ft-drop')
                    .replaceAll('{}', name ?? dir),
                style: TextStyle(color: Colors.white)),
          ]),
        ),
      ),
    );
  }

  /// Between the two sides: send what is chosen on one side to the other.
  Widget sendColumn() {
    Widget go(FileController c, IconData icon, String label) {
      return Obx(() {
        final ok = SelectedItems.valid(c.selectedItems.items);
        final ink = Theme.of(context).textTheme.bodySmall?.color;
        return Tooltip(
          message: label,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: ok
                ? () {
                    c.sendFiles(c.selectedItems, c.getOtherSideDirectoryData());
                    c.selectedItems.clear();
                  }
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Column(children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ok ? MyTheme.accent : Theme.of(context).hoverColor,
                  ),
                  child: Icon(icon,
                      color: ok ? Colors.white : Theme.of(context).disabledColor),
                ),
                SizedBox(height: 4),
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        color: ok ? ink : Theme.of(context).disabledColor)),
              ]),
            ),
          ),
        );
      });
    }

    return SizedBox(
      width: 76,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          go(model.localController, Icons.arrow_forward_rounded,
              translate('Send')),
          SizedBox(height: 18),
          go(model.remoteController, Icons.arrow_back_rounded,
              translate('ft-receive')),
        ],
      ),
    );
  }

  /// One line at the bottom for all the transfers: each one shows where it
  /// goes, in that folder (FileManagerView.incoming).
  Widget statusLine() {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Obx(() {
        final jobs = jobController.jobTable
            .where((j) => j.type == JobType.transfer)
            .toList();
        final active = jobs.where(isActiveTransfer).toList();
        final failed = jobs.where((j) => j.state == JobState.error).toList();
        if (active.isNotEmpty) {
          final total = active.fold<int>(0, (a, j) => a + j.totalSize);
          final done = active.fold<int>(0, (a, j) => a + j.finishedSize);
          final speed = active.fold<double>(0, (a, j) => a + j.speed);
          final parts = [
            '${readableFileSize(done.toDouble())} / ${readableFileSize(total.toDouble())}',
            if (speed > 0) '${readableFileSize(speed)}/s',
            if (speed > 0) timeLeft((total - done) / speed),
          ];
          return Row(children: [
            Text(
                translate('ft-busy')
                    .replaceAll('{}', active.length.toString()),
                style: TextStyle(fontWeight: FontWeight.w500)),
            SizedBox(width: 12),
            SizedBox(
              width: 220,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: total > 0 ? done / total : null,
                  minHeight: 6,
                  color: MyTheme.accent,
                  backgroundColor: Theme.of(context).hoverColor,
                ),
              ),
            ),
            SizedBox(width: 12),
            Expanded(
                child: Text(parts.join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: muted))),
            TextButton(
              onPressed: () {
                for (final j in active) {
                  dropJob(model, j);
                }
              },
              child: Text(translate('Cancel all'),
                  style: TextStyle(color: Colors.red[700])),
            ),
          ]);
        }
        if (failed.isNotEmpty) {
          return Row(children: [
            Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    color: Colors.red[600], shape: BoxShape.circle)),
            SizedBox(width: 10),
            Expanded(
                child: Text(
                    translate('ft-failed')
                        .replaceAll('{}', failed.length.toString()),
                    style: TextStyle(fontSize: 13))),
            if (!isWeb)
              TextButton(
                onPressed: () {
                  for (final j in failed) {
                    retry(model, j);
                  }
                },
                child: Text(translate('Retry all')),
              ),
            TextButton(
              onPressed: () => jobController.jobTable
                  .removeWhere((j) => j.state == JobState.error),
              child: Text(translate('Clear')),
            ),
          ]);
        }
        return Row(children: [
          Expanded(
              child: Text(translate('ft-hint'),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: muted))),
        ]);
      }),
    );
  }

  void handleDragDone(DropDoneDetails details, bool isLocal) {
    if (isLocal) {
      // ignore local
      return;
    }
    final items = SelectedItems(isLocal: false);
    for (var file in details.files) {
      final f = File(file.path);
      items.add(Entry()
        ..path = file.path
        ..name = file.name
        ..size = FileSystemEntity.isDirectorySync(f.path) ? 0 : f.lengthSync());
    }
    final otherSideData = model.localController.directoryData();
    model.remoteController.sendFiles(items, otherSideData);
  }
}

class FileManagerView extends StatefulWidget {
  final FileController controller;
  final FFI _ffi;
  final Rx<MouseFocusScope> _mouseFocusScope;

  FileManagerView(this.controller, this._ffi, this._mouseFocusScope);

  @override
  State<StatefulWidget> createState() => _FileManagerViewState();
}

class _FileManagerViewState extends State<FileManagerView> {
  final _locationStatus = LocationStatus.bread.obs;
  final _locationNode = FocusNode();
  final _locationBarKey = GlobalKey();
  final _searchText = "".obs;
  final _breadCrumbScroller = ScrollController();
  final _keyboardNode = FocusNode();
  final _listSearchBuffer = TimeoutStringBuffer();
  final _nameColWidth = 0.0.obs;
  final _modifiedColWidth = 0.0.obs;
  final _sizeColWidth = 0.0.obs;
  final _fileListScrollController = ScrollController();
  final _globalHeaderKey = GlobalKey();

  /// [_lastClickTime], [_lastClickEntry] help to handle double click
  var _lastClickTime =
      DateTime.now().millisecondsSinceEpoch - bind.getDoubleClickTime() - 1000;
  Entry? _lastClickEntry;

  double? _windowWidthPrev;
  double _fileTransferMinimumWidth = 0.0;

  FileController get controller => widget.controller;
  bool get isLocal => widget.controller.isLocal;
  FFI get _ffi => widget._ffi;
  SelectedItems get selectedItems => controller.selectedItems;

  /// transfers seen done (job id: when), to mark their files for a moment
  final _doneAt = <int, int>{};
  Worker? _jobsWorker;

  @override
  void initState() {
    super.initState();
    final jobs = _ffi.fileModel.jobController.jobTable;
    for (final j in jobs) {
      if (j.state == JobState.done) _doneAt[j.id] = 0;
    }
    _jobsWorker = ever(jobs, (_) => _sawJobs());
    // register location listener
    _locationNode.addListener(onLocationFocusChanged);
    controller.directory.listen((e) => breadCrumbScrollToEnd());
  }

  @override
  void dispose() {
    _jobsWorker?.dispose();
    _locationNode.removeListener(onLocationFocusChanged);
    _locationNode.dispose();
    _keyboardNode.dispose();
    _breadCrumbScroller.dispose();
    _fileListScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _handleColumnPorportions();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          headTools(),
          conflictPrompt(),
          incoming(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                    child: MouseRegion(
                  onEnter: (evt) {
                    widget._mouseFocusScope.value = isLocal
                        ? MouseFocusScope.local
                        : MouseFocusScope.remote;
                    _keyboardNode.requestFocus();
                  },
                  onExit: (evt) =>
                      widget._mouseFocusScope.value = MouseFocusScope.none,
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: _onFileListKeyEvent,
                    child: _buildFileList(context, _fileListScrollController),
                  ),
                ))
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _handleColumnPorportions() {
    final windowWidthNow = MediaQuery.of(context).size.width;
    if (_windowWidthPrev == null) {
      _windowWidthPrev = windowWidthNow;
      final defaultColumnWidth = windowWidthNow * 0.115;
      _fileTransferMinimumWidth = defaultColumnWidth / 3;
      _nameColWidth.value = defaultColumnWidth;
      _modifiedColWidth.value = defaultColumnWidth;
      _sizeColWidth.value = defaultColumnWidth;
    }

    if (_windowWidthPrev != windowWidthNow) {
      final difference = windowWidthNow / _windowWidthPrev!;
      _windowWidthPrev = windowWidthNow;
      _fileTransferMinimumWidth *= difference;
      _nameColWidth.value *= difference;
      _modifiedColWidth.value *= difference;
      _sizeColWidth.value *= difference;
    }
  }

  void onLocationFocusChanged() {
    debugPrint("focus changed on local");
    if (_locationNode.hasFocus) {
      // ignore
    } else {
      // lost focus, change to bread
      if (_locationStatus.value != LocationStatus.fileSearchBar) {
        _locationStatus.value = LocationStatus.bread;
      }
    }
  }

  Widget headTools() {
    var uploadButtonTapPosition = RelativeRect.fill;
    RxBool isUploadFolder =
        (bind.mainGetLocalOption(key: 'upload-folder-button') == 'Y').obs;
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    Widget tool(String tip, String svg, GestureTapCallback? onPressed) =>
        MenuButton(
          tooltip: translate(tip),
          onPressed: onPressed,
          child: SvgPicture.asset(
            svg,
            colorFilter: svgColor(Theme.of(context).tabBarTheme.labelColor),
          ),
          color: Theme.of(context).cardColor,
          hoverColor: Theme.of(context).hoverColor,
        );
    return Column(
      children: [
        // which computer, and what to do in this folder
        Row(
          children: [
            Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                  color: MyTheme.accent,
                ),
                padding: EdgeInsets.all(6.0),
                child: FutureBuilder<String>(
                    future: bind.sessionGetPlatform(
                        sessionId: _ffi.sessionId, isRemote: !isLocal),
                    builder: (context, snapshot) {
                      if (snapshot.hasData && snapshot.data!.isNotEmpty) {
                        return getPlatformImage('${snapshot.data}', size: 20);
                      } else {
                        return SizedBox();
                      }
                    })),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      isLocal
                          ? translate("Local Computer")
                          : translate("Remote Computer"),
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                      isLocal
                          ? (isWeb ? '' : Platform.localHostname)
                          : _ffi.ffiModel.pi.hostname,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: muted)),
                ],
              ),
            ),
            MenuButton(
              tooltip: translate('Create Folder'),
                      onPressed: () {
                        final name = TextEditingController();
                        String? errorText;
                        _ffi.dialogManager.show((setState, close, context) {
                          name.addListener(() {
                            if (errorText != null) {
                              setState(() {
                                errorText = null;
                              });
                            }
                          });
                          submit() {
                            if (name.value.text.isNotEmpty) {
                              if (!PathUtil.validName(name.value.text,
                                  controller.options.value.isWindows)) {
                                setState(() {
                                  errorText = translate("Invalid folder name");
                                });
                                return;
                              }
                              controller.createDir(PathUtil.join(
                                controller.directory.value.path,
                                name.value.text,
                                controller.options.value.isWindows,
                              ));
                              close();
                            }
                          }

                          cancel() => close(false);
                          return CustomAlertDialog(
                            title: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SvgPicture.asset("assets/folder_new.svg",
                                    colorFilter: svgColor(MyTheme.accent)),
                                Text(
                                  translate("Create Folder"),
                                ).paddingOnly(
                                  left: 10,
                                ),
                              ],
                            ),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextFormField(
                                  decoration: InputDecoration(
                                    labelText: translate(
                                      "Please enter the folder name",
                                    ),
                                    errorText: errorText,
                                  ),
                                  controller: name,
                                  autofocus: true,
                                ).workaroundFreezeLinuxMint(),
                              ],
                            ),
                            actions: [
                              dialogButton(
                                "Cancel",
                                icon: Icon(Icons.close_rounded),
                                onPressed: cancel,
                                isOutline: true,
                              ),
                              dialogButton(
                                "Ok",
                                icon: Icon(Icons.done_rounded),
                                onPressed: submit,
                              ),
                            ],
                            onSubmit: submit,
                            onCancel: cancel,
                          );
                        });
                      },
              child: SvgPicture.asset(
                "assets/folder_new.svg",
                colorFilter:
                    svgColor(Theme.of(context).tabBarTheme.labelColor),
              ),
              color: Theme.of(context).cardColor,
              hoverColor: Theme.of(context).hoverColor,
            ),
            Obx(() => tool(
                'Delete',
                "assets/trash.svg",
                SelectedItems.valid(selectedItems.items)
                    ? () async {
                        await (controller.removeAction(selectedItems));
                        selectedItems.clear();
                      }
                    : null)),
            menu(isLocal: isLocal),
          ],
        ).paddingOnly(bottom: 10),
        // where: back, up, the path, search, refresh
          Row(
            children: [
              Row(
                children: [
                  MenuButton(
                    tooltip: translate('Back'),
                    padding: EdgeInsets.only(
                      right: 3,
                    ),
                    child: RotatedBox(
                      quarterTurns: 2,
                      child: SvgPicture.asset(
                        "assets/arrow.svg",
                        colorFilter:
                            svgColor(Theme.of(context).tabBarTheme.labelColor),
                      ),
                    ),
                    color: Theme.of(context).cardColor,
                    hoverColor: Theme.of(context).hoverColor,
                    onPressed: () {
                      selectedItems.clear();
                      controller.goBack();
                    },
                  ),
                  MenuButton(
                    tooltip: translate('Parent directory'),
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SvgPicture.asset(
                        "assets/arrow.svg",
                        colorFilter:
                            svgColor(Theme.of(context).tabBarTheme.labelColor),
                      ),
                    ),
                    color: Theme.of(context).cardColor,
                    hoverColor: Theme.of(context).hoverColor,
                    onPressed: () {
                      selectedItems.clear();
                      controller.goToParentDirectory();
                    },
                  ),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.all(
                        Radius.circular(8.0),
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 2.5),
                      child: GestureDetector(
                        onTap: () {
                          _locationStatus.value =
                              _locationStatus.value == LocationStatus.bread
                                  ? LocationStatus.pathLocation
                                  : LocationStatus.bread;
                          Future.delayed(Duration.zero, () {
                            if (_locationStatus.value ==
                                LocationStatus.pathLocation) {
                              _locationNode.requestFocus();
                            }
                          });
                        },
                        child: Obx(
                          () => Container(
                            child: Row(
                              children: [
                                Expanded(
                                    child: _locationStatus.value ==
                                            LocationStatus.bread
                                        ? buildBread()
                                        : buildPathLocation()),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Obx(() {
                switch (_locationStatus.value) {
                  case LocationStatus.bread:
                    return MenuButton(
                      tooltip: translate('Search'),
                      onPressed: () {
                        _locationStatus.value = LocationStatus.fileSearchBar;
                        Future.delayed(
                            Duration.zero, () => _locationNode.requestFocus());
                      },
                      child: SvgPicture.asset(
                        "assets/search.svg",
                        colorFilter:
                            svgColor(Theme.of(context).tabBarTheme.labelColor),
                      ),
                      color: Theme.of(context).cardColor,
                      hoverColor: Theme.of(context).hoverColor,
                    );
                  case LocationStatus.pathLocation:
                    return MenuButton(
                      onPressed: null,
                      child: SvgPicture.asset(
                        "assets/close.svg",
                        colorFilter:
                            svgColor(Theme.of(context).tabBarTheme.labelColor),
                      ),
                      color: Theme.of(context).disabledColor,
                      hoverColor: Theme.of(context).hoverColor,
                    );
                  case LocationStatus.fileSearchBar:
                    return MenuButton(
                      tooltip: translate('Clear'),
                      onPressed: () {
                        onSearchText("", isLocal);
                        _locationStatus.value = LocationStatus.bread;
                      },
                      child: SvgPicture.asset(
                        "assets/close.svg",
                        colorFilter:
                            svgColor(Theme.of(context).tabBarTheme.labelColor),
                      ),
                      color: Theme.of(context).cardColor,
                      hoverColor: Theme.of(context).hoverColor,
                    );
                }
              }),
              MenuButton(
                tooltip: translate('Refresh File'),
                padding: EdgeInsets.only(
                  left: 3,
                ),
                onPressed: () {
                  controller.refresh();
                },
                child: SvgPicture.asset(
                  "assets/refresh.svg",
                  colorFilter:
                      svgColor(Theme.of(context).tabBarTheme.labelColor),
                ),
                color: Theme.of(context).cardColor,
                hoverColor: Theme.of(context).hoverColor,
              ),
            ],
          ),
        // quick places
        Row(
          children: [
            Expanded(child: places()),
              if (isWeb)
                Obx(() => ElevatedButton.icon(
                      style: ButtonStyle(
                        padding: MaterialStateProperty.all<EdgeInsetsGeometry>(
                            isLocal
                                ? EdgeInsets.only(left: 10)
                                : EdgeInsets.only(right: 10)),
                        backgroundColor: MaterialStateProperty.all(
                          selectedItems.items.isEmpty
                              ? MyTheme.accent80
                              : MyTheme.accent,
                        ),
                      ),
                      onPressed: () =>
                          {webselectFiles(is_folder: isUploadFolder.value)},
                      label: InkWell(
                        hoverColor: Colors.transparent,
                        splashColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                        focusColor: Colors.transparent,
                        onTapDown: (e) {
                          final x = e.globalPosition.dx;
                          final y = e.globalPosition.dy;
                          uploadButtonTapPosition =
                              RelativeRect.fromLTRB(x, y, x, y);
                        },
                        onTap: () async {
                          final value = await showMenu<bool>(
                              context: context,
                              position: uploadButtonTapPosition,
                              items: [
                                PopupMenuItem<bool>(
                                  value: false,
                                  child: Text(translate('Upload files')),
                                ),
                                PopupMenuItem<bool>(
                                  value: true,
                                  child: Text(translate('Upload folder')),
                                ),
                              ]);
                          if (value != null) {
                            isUploadFolder.value = value;
                            bind.mainSetLocalOption(
                                key: 'upload-folder-button',
                                value: value ? 'Y' : '');
                            webselectFiles(is_folder: value);
                          }
                        },
                        child: Icon(Icons.arrow_drop_down),
                      ),
                      icon: Text(
                        translate(isUploadFolder.isTrue
                            ? 'Upload folder'
                            : 'Upload files'),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: Colors.white,
                        ),
                      ).marginOnly(left: 8),
                    )).marginOnly(left: 16),
              if (isWeb)
              Obx(() => ElevatedButton.icon(
                    style: ButtonStyle(
                      padding: MaterialStateProperty.all<EdgeInsetsGeometry>(
                          isLocal
                              ? EdgeInsets.only(left: 10)
                              : EdgeInsets.only(right: 10)),
                      backgroundColor: MaterialStateProperty.all(
                        selectedItems.items.isEmpty
                            ? MyTheme.accent80
                            : MyTheme.accent,
                      ),
                    ),
                    onPressed: SelectedItems.valid(selectedItems.items)
                        ? () {
                            final otherSideData =
                                controller.getOtherSideDirectoryData();
                            controller.sendFiles(selectedItems, otherSideData);
                            selectedItems.clear();
                          }
                        : null,
                    icon: isLocal
                        ? Text(
                            translate('Send'),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: selectedItems.items.isEmpty
                                  ? Theme.of(context).brightness ==
                                          Brightness.light
                                      ? MyTheme.grayBg
                                      : MyTheme.darkGray
                                  : Colors.white,
                            ),
                          )
                        : isWeb
                            ? Offstage()
                            : RotatedBox(
                                quarterTurns: 2,
                                child: SvgPicture.asset(
                                  "assets/arrow.svg",
                                  colorFilter: svgColor(
                                      selectedItems.items.isEmpty
                                          ? Theme.of(context).brightness ==
                                                  Brightness.light
                                              ? MyTheme.grayBg
                                              : MyTheme.darkGray
                                          : Colors.white),
                                  alignment: Alignment.bottomRight,
                                ),
                              ),
                    label: isLocal
                        ? SvgPicture.asset(
                            "assets/arrow.svg",
                            colorFilter: svgColor(selectedItems.items.isEmpty
                                ? Theme.of(context).brightness ==
                                        Brightness.light
                                    ? MyTheme.grayBg
                                    : MyTheme.darkGray
                                : Colors.white),
                          )
                        : Text(
                            translate(isWeb ? 'Download' : 'Receive'),
                            style: TextStyle(
                              color: selectedItems.items.isEmpty
                                  ? Theme.of(context).brightness ==
                                          Brightness.light
                                      ? MyTheme.grayBg
                                      : MyTheme.darkGray
                                  : Colors.white,
                            ),
                          ),
                  )),
          ],
        ).marginOnly(top: 8.0, bottom: 6.0),
      ],
    );
  }

  /// The usual folders of that computer, a click away.
  Widget places() {
    return Obx(() {
      final o = controller.options.value;
      final home = o.home;
      final cur = controller.directory.value.path;
      final homeParts = PathUtil.split(home, o.isWindows);
      final List<(String, String)> xs = [
        if (home.isNotEmpty) ...[
          (homeParts.isEmpty ? home : homeParts.last, home),
          (translate('Desktop'), PathUtil.join(home, 'Desktop', o.isWindows)),
          (
            translate('Documents'),
            PathUtil.join(home, 'Documents', o.isWindows)
          ),
          (
            translate('Downloads'),
            PathUtil.join(home, 'Downloads', o.isWindows)
          ),
        ],
        (o.isWindows ? translate('This PC') : '/', '/'),
      ];
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: xs.map((x) {
            final on = x.$2 == cur;
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () {
                  selectedItems.clear();
                  controller.openDirectory(x.$2);
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: on ? MyTheme.accent.withOpacity(0.12) : null,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                        color: on
                            ? MyTheme.accent.withOpacity(0.4)
                            : Theme.of(context).dividerColor),
                  ),
                  child: Text(x.$1,
                      style: TextStyle(
                          fontSize: 12, color: on ? MyTheme.accent : null)),
                ),
              ),
            );
          }).toList(),
        ),
      );
    });
  }

  void _sawJobs() {
    final now = DateTime.now().millisecondsSinceEpoch;
    var fresh = false;
    for (final j in _ffi.fileModel.jobController.jobTable) {
      if (j.type == JobType.transfer &&
          j.state == JobState.done &&
          j.err.isEmpty &&
          !_doneAt.containsKey(j.id)) {
        _doneAt[j.id] = now;
        fresh = true;
      }
    }
    if (fresh) {
      Timer(const Duration(milliseconds: 3200), () {
        if (mounted) setState(() {});
      });
    }
  }

  /// The paths written by transfers that ended a moment ago.
  Set<String> _justDone() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      for (final j in _ffi.fileModel.jobController.jobTable)
        if (j.to.isNotEmpty &&
            j.state == JobState.done &&
            now - (_doneAt[j.id] ?? 0) < 3000)
          j.to
    };
  }

  /// A file there already that a transfer to this side asks about: what to
  /// do, here rather than in a dialog.
  Widget conflictPrompt() {
    return Obx(() {
      final c = _ffi.fileModel.conflict.value;
      if (c == null || c.toRemote == isLocal) return Offstage();
      final name = PathUtil.split(c.path, controller.options.value.isWindows);
      void answer(bool? resp) {
        if (!c.answer.isCompleted) c.answer.complete(resp);
      }

      Widget button(String label, bool? resp, {bool primary = false}) =>
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: primary
                ? ElevatedButton(
                    onPressed: () => answer(resp),
                    child: Text(translate(label)))
                : OutlinedButton(
                    onPressed: () => answer(resp),
                    child: Text(translate(label))),
          );
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: Colors.amber.withOpacity(0.12),
          border: Border.all(color: Colors.amber.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                translate('ft-exists')
                    .replaceAll('{}', name.isEmpty ? c.path : name.last),
                style: TextStyle(fontWeight: FontWeight.w600)),
            if (c.identical)
              Text(translate('identical_file_tip'),
                      style: TextStyle(fontSize: 12))
                  .marginOnly(top: 2),
            SizedBox(height: 8),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 6,
              children: [
                button('Replace', true, primary: true),
                button('Skip', null),
                button('Cancel transfer', false),
                Obx(() => Row(mainAxisSize: MainAxisSize.min, children: [
                      Checkbox(
                          value: c.remember.value,
                          onChanged: (v) => c.remember.value = v ?? false),
                      Text(translate('Do this for all conflicts'),
                          style: TextStyle(fontSize: 12)),
                    ])),
              ],
            ),
          ],
        ),
      );
    });
  }

  /// The transfers coming into this folder, at the top with their progress.
  Widget incoming() {
    return Obx(() {
      final isWin = controller.options.value.isWindows;
      final dir = controller.directory.value.path;
      final jobs = _ffi.fileModel.jobController.jobTable
          .where((j) =>
              j.type == JobType.transfer &&
              j.isRemoteToLocal == isLocal &&
              (isActiveTransfer(j) || j.state == JobState.error) &&
              j.to.isNotEmpty &&
              j.to == PathUtil.join(dir, j.fileName, isWin))
          .toList();
      if (jobs.isEmpty) return Offstage();
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: 4 * 52.0),
        child: ListView(
          shrinkWrap: true,
          children: jobs.map(incomingRow).toList(),
        ),
      ).marginOnly(bottom: 4);
    });
  }

  Widget incomingRow(JobProgress j) {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    final failed = j.state == JobState.error;
    final String text;
    if (failed) {
      text = j.err.isEmpty
          ? translate('Failed')
          : '${translate('Failed')}: ${translate(j.err)}';
    } else if (j.state == JobState.none) {
      text = translate('Waiting');
    } else {
      text = [
        j.percentText,
        if (j.speed > 0) '${readableFileSize(j.speed)}/s',
        if (j.speed > 0 && j.totalSize > j.finishedSize)
          timeLeft((j.totalSize - j.finishedSize) / j.speed),
      ].join(' · ');
    }
    return Container(
      height: 50,
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: failed
            ? Colors.red.withOpacity(0.08)
            : MyTheme.accent.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          extOf(j.fileName).isEmpty
              ? Icon(Icons.folder_rounded, color: kFolderColor, size: 28)
              : extBadge(j.fileName, 28),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Tooltip(
                  waitDuration: Duration(milliseconds: 500),
                  message: j.to,
                  child: Text(j.fileName,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                SizedBox(height: 5),
                failed
                    ? Text(text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: Colors.red[700]))
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: j.percent,
                          minHeight: 4,
                          color: MyTheme.accent,
                          backgroundColor: Theme.of(context).hoverColor,
                        ),
                      ),
              ],
            ),
          ),
          if (!failed)
            Text(text, style: TextStyle(fontSize: 12, color: muted))
                .marginOnly(left: 12),
          if (failed && !isWeb)
            TextButton(
              onPressed: () => retry(_ffi.fileModel, j),
              child: Text(translate('Retry')),
            ),
          IconButton(
            tooltip: translate(failed ? 'Remove' : 'Cancel'),
            iconSize: 18,
            onPressed: () => dropJob(_ffi.fileModel, j),
            icon: Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget menu({bool isLocal = false}) {
    var menuPos = RelativeRect.fill;

    final List<MenuEntryBase<String>> items = [
      MenuEntrySwitch<String>(
        switchType: SwitchType.scheckbox,
        text: translate("Show Hidden Files"),
        getter: () async {
          return controller.options.value.showHidden;
        },
        setter: (bool v) async {
          controller.toggleShowHidden();
        },
        padding: kDesktopMenuPadding,
        dismissOnClicked: true,
      ),
      MenuEntryButton(
          childBuilder: (style) => Text(translate("Select All"), style: style),
          proc: () => setState(() =>
              selectedItems.selectAll(controller.directory.value.entries)),
          padding: kDesktopMenuPadding,
          dismissOnClicked: true),
      MenuEntryButton(
          childBuilder: (style) =>
              Text(translate("Unselect All"), style: style),
          proc: () => selectedItems.clear(),
          padding: kDesktopMenuPadding,
          dismissOnClicked: true)
    ];

    return Listener(
      onPointerDown: (e) {
        final x = e.position.dx;
        final y = e.position.dy;
        menuPos = RelativeRect.fromLTRB(x, y, x, y);
      },
      child: MenuButton(
        tooltip: translate('More'),
        onPressed: () => mod_menu.showMenu(
          context: context,
          position: menuPos,
          items: items
              .map(
                (e) => e.build(
                  context,
                  MenuConfig(
                      commonColor: CustomPopupMenuTheme.commonColor,
                      height: CustomPopupMenuTheme.height,
                      dividerHeight: CustomPopupMenuTheme.dividerHeight),
                ),
              )
              .expand((i) => i)
              .toList(),
          elevation: 8,
        ),
        child: SvgPicture.asset(
          "assets/dots.svg",
          colorFilter: svgColor(Theme.of(context).tabBarTheme.labelColor),
        ),
        color: Theme.of(context).cardColor,
        hoverColor: Theme.of(context).hoverColor,
      ),
    );
  }

  Widget _buildFileList(
      BuildContext context, ScrollController scrollController) {
    final fd = controller.directory.value;
    final entries = fd.entries;
    Rx<Entry?> rightClickEntry = Rx(null);

    return ListSearchActionListener(
      node: _keyboardNode,
      buffer: _listSearchBuffer,
      onNext: (buffer) {
        debugPrint("searching next for $buffer");
        assert(buffer.length == 1);
        assert(selectedItems.items.length <= 1);
        var skipCount = 0;
        if (selectedItems.items.isNotEmpty) {
          final index = entries.indexOf(selectedItems.items.first);
          if (index < 0) {
            return;
          }
          skipCount = index + 1;
        }
        var searchResult = entries
            .skip(skipCount)
            .where((element) => element.name.toLowerCase().startsWith(buffer));
        if (searchResult.isEmpty) {
          // cannot find next, lets restart search from head
          debugPrint("restart search from head");
          searchResult = entries.where(
              (element) => element.name.toLowerCase().startsWith(buffer));
        }
        if (searchResult.isEmpty) {
          selectedItems.clear();
          return;
        }
        _jumpToEntry(isLocal, searchResult.first, scrollController,
            _rowHeight);
      },
      onSearch: (buffer) {
        debugPrint("searching for $buffer");
        final selectedEntries = selectedItems;
        final searchResult = entries
            .where((element) => element.name.toLowerCase().startsWith(buffer));
        selectedEntries.clear();
        if (searchResult.isEmpty) {
          selectedItems.clear();
          return;
        }
        _jumpToEntry(isLocal, searchResult.first, scrollController,
            _rowHeight);
      },
      child: Obx(() {
        final entries = controller.directory.value.entries;
        // what goes from here to the other side now: a label on its row
        final sending = <String, JobProgress>{
          for (final j in _ffi.fileModel.jobController.jobTable)
            if (isActiveTransfer(j) && j.isRemoteToLocal != isLocal)
              j.jobName: j
        };
        final justDone = _justDone();
        final filteredEntries = _searchText.isNotEmpty
            ? entries.where((element) {
                return element.name.contains(_searchText.value);
              }).toList(growable: false)
            : entries;
        // Keep rows lazy so large directories only build visible list items.
        final rows = filteredEntries.map((entry) {
          final sizeStr =
              entry.isFile ? readableFileSize(entry.size.toDouble()) : "";
          final lastModifiedStr = entry.isDrive
              ? " "
              : "${entry.lastModified().toString().replaceAll(".000", "")}   ";
          var secondaryPosition = RelativeRect.fromLTRB(0, 0, 0, 0);
          onTap() {
            _keyboardNode.requestFocus();
            final items = selectedItems;
            // handle double click
            if (_checkDoubleClick(entry)) {
              controller.openDirectory(entry.path);
              items.clear();
              return;
            }
            _onSelectedChanged(items, filteredEntries, entry, isLocal);
          }

          onSecondaryTap() {
            final items = [
              if (!entry.isDrive &&
                  versionCmp(_ffi.ffiModel.pi.version, "1.3.0") >= 0)
                mod_menu.PopupMenuItem(
                  child: Text(translate("Rename")),
                  height: CustomPopupMenuTheme.height,
                  onTap: () {
                    controller.renameAction(entry, isLocal);
                  },
                )
            ];
            if (items.isNotEmpty) {
              rightClickEntry.value = entry;
              final future = mod_menu.showMenu(
                context: context,
                position: secondaryPosition,
                items: items,
              );
              future.then((value) {
                rightClickEntry.value = null;
              });
              future.onError((error, stackTrace) {
                rightClickEntry.value = null;
              });
            }
          }

          onSecondaryTapDown(details) {
            secondaryPosition = RelativeRect.fromLTRB(
                details.globalPosition.dx,
                details.globalPosition.dy,
                details.globalPosition.dx,
                details.globalPosition.dy);
          }

          // dragged to the other side: what is chosen there, or this one
          final drag = FileDrag(isLocal, entry, selectedItems);
          return Draggable<FileDrag>(
            data: drag,
            maxSimultaneousDrags: entry.isDrive ? 0 : 1,
            feedback: Builder(
                builder: (_) => dragFeedback(drag.entries.length, entry)),
            child: Padding(
            padding: EdgeInsets.symmetric(vertical: 1),
            child: Obx(() => Container(
                decoration: BoxDecoration(
                  color: selectedItems.items.contains(entry)
                      ? MyTheme.accent.withOpacity(0.12)
                      : Theme.of(context).cardColor,
                  borderRadius: BorderRadius.all(
                    Radius.circular(5.0),
                  ),
                  border: rightClickEntry.value == entry
                      ? Border.all(
                          color: MyTheme.button,
                          width: 1.0,
                        )
                      : null,
                ),
                key: ValueKey(entry.name),
                height: _rowHeight,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Expanded(
                      child: InkWell(
                        child: Row(
                          children: [
                            GestureDetector(
                              child: Obx(
                                () => Container(
                                    width: _nameColWidth.value,
                                    child: Tooltip(
                                      waitDuration: Duration(milliseconds: 500),
                                      message: entry.name,
                                      child: Row(children: [
                                        entry.isDrive
                                            ? Image(
                                                    image: iconHardDrive,
                                                    fit: BoxFit.scaleDown,
                                                    color: Theme.of(context)
                                                        .iconTheme
                                                        .color
                                                        ?.withOpacity(0.7))
                                                .paddingAll(4)
                                            : entry.isFile
                                                ? extBadge(entry.name, 24)
                                                : Icon(Icons.folder_rounded,
                                                    color: kFolderColor,
                                                    size: 26),
                                        SizedBox(width: 8),
                                        Expanded(
                                            child: Text(entry.name.nonBreaking,
                                                overflow:
                                                    TextOverflow.ellipsis)),
                                        if (sending[entry.path] != null)
                                          sendingLabel(sending[entry.path]!),
                                        if (justDone.contains(entry.path))
                                          doneLabel(),
                                      ]),
                                    )),
                              ),
                              onTap: onTap,
                              onSecondaryTap: onSecondaryTap,
                              onSecondaryTapDown: onSecondaryTapDown,
                            ),
                            SizedBox(
                              width: 2.0,
                            ),
                            GestureDetector(
                              child: Obx(
                                () => SizedBox(
                                  width: _modifiedColWidth.value,
                                  child: Tooltip(
                                      waitDuration: Duration(milliseconds: 500),
                                      message: lastModifiedStr,
                                      child: Text(
                                        lastModifiedStr,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: MyTheme.darkGray,
                                        ),
                                      )),
                                ),
                              ),
                              onTap: onTap,
                              onSecondaryTap: onSecondaryTap,
                              onSecondaryTapDown: onSecondaryTapDown,
                            ),
                            // Divider from header.
                            SizedBox(
                              width: 2.0,
                            ),
                            Expanded(
                              // width: 100,
                              child: GestureDetector(
                                child: Tooltip(
                                  waitDuration: Duration(milliseconds: 500),
                                  message: sizeStr,
                                  child: Text(
                                    sizeStr,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: MyTheme.darkGray),
                                  ),
                                ),
                                onTap: onTap,
                                onSecondaryTap: onSecondaryTap,
                                onSecondaryTapDown: onSecondaryTapDown,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ))),
          ));
        });

        return Column(
          children: [
            // Header
            Row(
              children: [
                Expanded(child: _buildFileBrowserHeader(context)),
              ],
            ),
            // Body
            if (rows.isEmpty && _searchText.isEmpty)
              Expanded(
                child: Center(
                  child: Text(translate('This folder is empty'),
                      style: TextStyle(color: MyTheme.darkGray)),
                ),
              )
            else
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemExtent: _rowHeight,
                itemBuilder: (context, index) {
                  return rows.elementAt(index);
                },
                itemCount: rows.length,
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget doneLabel() {
    return Container(
      margin: const EdgeInsets.only(left: 6, right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.check_rounded, size: 12, color: Colors.green[800]),
        SizedBox(width: 3),
        Text(translate('ft-done'),
            style: TextStyle(fontSize: 11, color: Colors.green[800])),
      ]),
    );
  }

  Widget dragFeedback(int n, Entry entry) {
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      color: Theme.of(context).cardColor,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          entry.isFile
              ? extBadge(entry.name, 22)
              : Icon(Icons.folder_rounded, color: kFolderColor, size: 22),
          SizedBox(width: 8),
          Text(n > 1
              ? translate('ft-items').replaceAll('{}', n.toString())
              : entry.name),
        ]),
      ),
    );
  }

  Widget sendingLabel(JobProgress j) {
    return Container(
      margin: const EdgeInsets.only(left: 6, right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: MyTheme.accent.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
          translate('ft-sending')
              .replaceAll('{}', (j.percent * 100).toStringAsFixed(0)),
          style: TextStyle(fontSize: 11, color: MyTheme.accent)),
    );
  }

  onSearchText(String searchText, bool isLocal) {
    selectedItems.clear();
    _searchText.value = searchText;
  }

  void _jumpToEntry(bool isLocal, Entry entry,
      ScrollController scrollController, double rowHeight) {
    final entries = controller.directory.value.entries;
    final index = entries.indexOf(entry);
    if (index == -1) {
      debugPrint("entry is not valid: ${entry.path}");
    }
    final selectedEntries = selectedItems;
    final searchResult = entries.where((element) => element == entry);
    selectedEntries.clear();
    if (searchResult.isEmpty) {
      return;
    }
    final offset = min(
        max(scrollController.position.minScrollExtent,
            entries.indexOf(searchResult.first) * rowHeight),
        scrollController.position.maxScrollExtent);
    scrollController.jumpTo(offset);
    selectedEntries.add(searchResult.first);
    debugPrint("focused on ${searchResult.first.name}");
  }

  KeyEventResult _onFileListKeyEvent(FocusNode node, KeyEvent event) {
    // A focused child such as a sort header keeps its default keys, e.g.
    // Enter to sort.
    if (!_keyboardNode.hasPrimaryFocus) return KeyEventResult.ignored;
    for (final binding in _fileListKeyBindings().entries) {
      if (binding.key.accepts(event, HardwareKeyboard.instance)) {
        binding.value();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Map<ShortcutActivator, VoidCallback> _fileListKeyBindings() {
    int all() => controller.directory.value.entries.length;
    return {
      const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
          _moveSelectionByKey(-1, false),
      const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
          _moveSelectionByKey(1, false),
      const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): () =>
          _moveSelectionByKey(-1, true),
      const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true): () =>
          _moveSelectionByKey(1, true),
      // Unhandled, they would move keyboard focus to the other pane.
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () {},
      const SingleActivator(LogicalKeyboardKey.arrowRight): () {},
      const SingleActivator(LogicalKeyboardKey.pageUp): () =>
          _moveSelectionByKey(_pageDelta(false), false),
      const SingleActivator(LogicalKeyboardKey.pageDown): () =>
          _moveSelectionByKey(_pageDelta(true), false),
      const SingleActivator(LogicalKeyboardKey.home): () =>
          _moveSelectionByKey(-all(), false),
      const SingleActivator(LogicalKeyboardKey.end): () =>
          _moveSelectionByKey(all(), false),
      const SingleActivator(LogicalKeyboardKey.pageUp, shift: true): () =>
          _moveSelectionByKey(_pageDelta(false), true),
      const SingleActivator(LogicalKeyboardKey.pageDown, shift: true): () =>
          _moveSelectionByKey(_pageDelta(true), true),
      const SingleActivator(LogicalKeyboardKey.home, shift: true): () =>
          _moveSelectionByKey(-all(), true),
      const SingleActivator(LogicalKeyboardKey.end, shift: true): () =>
          _moveSelectionByKey(all(), true),
      const SingleActivator(LogicalKeyboardKey.enter): _openSelectedDirectory,
      const SingleActivator(LogicalKeyboardKey.numpadEnter):
          _openSelectedDirectory,
    };
  }

  void _openSelectedDirectory() {
    final items = selectedItems.items;
    if (items.length != 1 || items.first.isFile) return;
    controller.openDirectory(items.first.path);
    selectedItems.clear();
  }

  List<Entry> _filteredEntries() {
    final entries = controller.directory.value.entries;
    return _searchText.isNotEmpty
        ? entries.where((element) {
            return element.name.contains(_searchText.value);
          }).toList(growable: false)
        : entries;
  }

  int _pageDelta(bool down) {
    final entries = _filteredEntries();
    final items = selectedItems.items;
    final index = items.isEmpty ? -1 : entries.indexOf(items.last);
    final position = _fileListScrollController.position;
    final first = (position.pixels / _rowHeight).ceil();
    final last = ((position.pixels + position.viewportDimension) /
                _rowHeight)
            .floor() -
        1;
    return pageDelta(
        index >= 0 ? index : (down ? -1 : entries.length), first, last, down);
  }

  void _moveSelectionByKey(int delta, bool extend) {
    final filteredEntries = _filteredEntries();
    final selection =
        navigateSelection(filteredEntries, selectedItems.items, delta, extend);
    if (selection.isEmpty) return;
    selectedItems.items.assignAll(selection.where((e) => !e.isDrive));
    final position = _fileListScrollController.position;
    final top =
        filteredEntries.indexOf(selection.last) * _rowHeight;
    final bottom = top + _rowHeight;
    if (top < position.pixels) {
      _fileListScrollController.jumpTo(top);
    } else if (bottom > position.pixels + position.viewportDimension) {
      _fileListScrollController.jumpTo(bottom - position.viewportDimension);
    }
  }

  void _onSelectedChanged(SelectedItems selectedItems, List<Entry> entries,
      Entry entry, bool isLocal) {
    final isCtrlDown = RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.controlLeft) ||
        RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.controlRight);
    final isShiftDown = RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.shiftLeft) ||
        RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.shiftRight);
    if (isCtrlDown) {
      if (selectedItems.items.contains(entry)) {
        selectedItems.remove(entry);
      } else {
        selectedItems.add(entry);
      }
    } else if (isShiftDown) {
      final List<int> indexGroup = [];
      for (var selected in selectedItems.items) {
        indexGroup.add(entries.indexOf(selected));
      }
      indexGroup.add(entries.indexOf(entry));
      indexGroup.removeWhere((e) => e == -1);
      final maxIndex = indexGroup.reduce(max);
      final minIndex = indexGroup.reduce(min);
      selectedItems.clear();
      entries
          .getRange(minIndex, maxIndex + 1)
          .forEach((e) => selectedItems.add(e));
    } else {
      selectedItems.clear();
      selectedItems.add(entry);
    }
    setState(() {});
  }

  bool _checkDoubleClick(Entry entry) {
    final current = DateTime.now().millisecondsSinceEpoch;
    final elapsed = current - _lastClickTime;
    _lastClickTime = current;
    if (_lastClickEntry == entry) {
      if (elapsed < bind.getDoubleClickTime()) {
        return true;
      }
    } else {
      _lastClickEntry = entry;
    }
    return false;
  }

  void _onDrag(double dx, RxDouble column1, RxDouble column2) {
    if (column1.value + dx <= _fileTransferMinimumWidth ||
        column2.value - dx <= _fileTransferMinimumWidth) {
      return;
    }
    column1.value += dx;
    column2.value -= dx;
    column1.value = max(_fileTransferMinimumWidth, column1.value);
    column2.value = max(_fileTransferMinimumWidth, column2.value);
  }

  Widget _buildFileBrowserHeader(BuildContext context) {
    final padding = EdgeInsets.all(1.0);
    return SizedBox(
      key: _globalHeaderKey,
      height: kDesktopFileTransferHeaderHeight,
      child: Row(
        children: [
          Obx(
            () => headerItemFunc(
                _nameColWidth.value, SortBy.name, translate("Name")),
          ),
          DraggableDivider(
            axis: Axis.vertical,
            onPointerMove: (dx) =>
                _onDrag(dx, _nameColWidth, _modifiedColWidth),
            padding: padding,
          ),
          Obx(
            () => headerItemFunc(_modifiedColWidth.value, SortBy.modified,
                translate("Modified")),
          ),
          DraggableDivider(
              axis: Axis.vertical,
              onPointerMove: (dx) =>
                  _onDrag(dx, _modifiedColWidth, _sizeColWidth),
              padding: padding),
          Expanded(
              child: headerItemFunc(
                  _sizeColWidth.value, SortBy.size, translate("Size")))
        ],
      ),
    );
  }

  Widget headerItemFunc(double? width, SortBy sortBy, String name) {
    final headerTextStyle =
        Theme.of(context).dataTableTheme.headingTextStyle ?? TextStyle();
    return ObxValue<Rx<bool?>>(
        (ascending) => InkWell(
              onTap: () {
                if (ascending.value == null) {
                  ascending.value = true;
                } else {
                  ascending.value = !ascending.value!;
                }
                controller.changeSortStyle(sortBy,
                    isLocal: isLocal, ascending: ascending.value!);
              },
              child: SizedBox(
                width: width,
                height: kDesktopFileTransferHeaderHeight,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: headerTextStyle,
                        overflow: TextOverflow.ellipsis,
                      ).marginOnly(left: 4),
                    ),
                    ascending.value != null
                        ? Icon(
                            ascending.value!
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                          )
                        : SizedBox()
                  ],
                ),
              ),
            ), () {
      if (controller.sortBy.value == sortBy) {
        return controller.sortAscending.obs;
      } else {
        return Rx<bool?>(null);
      }
    }());
  }

  Widget buildBread() {
    final items = getPathBreadCrumbItems(isLocal, (list) {
      var path = "";
      for (var item in list) {
        path = PathUtil.join(path, item, controller.options.value.isWindows);
      }
      controller.openDirectory(path);
    });

    return items.isEmpty
        ? Offstage()
        : Row(
            key: _locationBarKey,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
                Expanded(
                  child: Listener(
                    // handle mouse wheel
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent) {
                        final sc = _breadCrumbScroller;
                        final scale = isWindows ? 2 : 4;
                        sc.jumpTo(sc.offset + e.scrollDelta.dy / scale);
                      }
                    },
                    child: BreadCrumb(
                      items: items,
                      divider: const Icon(Icons.keyboard_arrow_right_rounded),
                      overflow: ScrollableOverflow(
                        controller: _breadCrumbScroller,
                      ),
                    ),
                  ),
                ),
                ActionIcon(
                  message: "",
                  icon: Icons.keyboard_arrow_down_rounded,
                  onTap: () async {
                    final renderBox = _locationBarKey.currentContext
                        ?.findRenderObject() as RenderBox;
                    _locationBarKey.currentContext?.size;

                    final size = renderBox.size;
                    final offset = renderBox.localToGlobal(Offset.zero);

                    final x = offset.dx;
                    final y = offset.dy + size.height + 1;

                    final isPeerWindows = controller.options.value.isWindows;
                    final List<MenuEntryBase> menuItems = [
                      MenuEntryButton(
                          childBuilder: (TextStyle? style) => isPeerWindows
                              ? buildWindowsThisPC(context, style)
                              : Text(
                                  '/',
                                  style: style,
                                ),
                          proc: () {
                            controller.openDirectory('/');
                          },
                          dismissOnClicked: true),
                      MenuEntryDivider()
                    ];
                    if (isPeerWindows) {
                      var loadingTag = "";
                      if (!isLocal) {
                        loadingTag = _ffi.dialogManager.showLoading("Waiting");
                      }
                      try {
                        final showHidden = controller.options.value.showHidden;
                        final fd = await controller.fileFetcher
                            .fetchDirectory("/", isLocal, showHidden);
                        for (var entry in fd.entries) {
                          menuItems.add(MenuEntryButton(
                              childBuilder: (TextStyle? style) =>
                                  Row(children: [
                                    Image(
                                        image: iconHardDrive,
                                        fit: BoxFit.scaleDown,
                                        color: Theme.of(context)
                                            .iconTheme
                                            .color
                                            ?.withOpacity(0.7)),
                                    SizedBox(width: 10),
                                    Text(
                                      entry.name,
                                      style: style,
                                    )
                                  ]),
                              proc: () {
                                controller.openDirectory('${entry.name}\\');
                              },
                              dismissOnClicked: true));
                        }
                        menuItems.add(MenuEntryDivider());
                      } catch (e) {
                        debugPrint("buildBread fetchDirectory err=$e");
                      } finally {
                        if (!isLocal) {
                          _ffi.dialogManager.dismissByTag(loadingTag);
                        }
                      }
                    }
                    mod_menu.showMenu(
                        context: context,
                        position: RelativeRect.fromLTRB(x, y, x, y),
                        elevation: 4,
                        items: menuItems
                            .map((e) => e.build(
                                context,
                                MenuConfig(
                                    commonColor:
                                        CustomPopupMenuTheme.commonColor,
                                    height: CustomPopupMenuTheme.height,
                                    dividerHeight:
                                        CustomPopupMenuTheme.dividerHeight,
                                    boxWidth: size.width)))
                            .expand((i) => i)
                            .toList());
                  },
                  iconSize: 20,
                )
              ]);
  }

  List<BreadCrumbItem> getPathBreadCrumbItems(
      bool isLocal, void Function(List<String>) onPressed) {
    final path = controller.directory.value.path;
    final breadCrumbList = List<BreadCrumbItem>.empty(growable: true);
    final isWindows = controller.options.value.isWindows;
    if (isWindows && path == '/') {
      breadCrumbList.add(BreadCrumbItem(
          content: TextButton(
                  child: buildWindowsThisPC(context),
                  style: ButtonStyle(
                      minimumSize: MaterialStateProperty.all(Size(0, 0))),
                  onPressed: () => onPressed(['/']))
              .marginSymmetric(horizontal: 4)));
    } else {
      final list = PathUtil.split(path, isWindows);
      breadCrumbList.addAll(
        list.asMap().entries.map(
              (e) => BreadCrumbItem(
                content: TextButton(
                  child: Text(e.value),
                  style: ButtonStyle(
                    minimumSize: MaterialStateProperty.all(
                      Size(0, 0),
                    ),
                  ),
                  onPressed: () => onPressed(
                    list.sublist(0, e.key + 1),
                  ),
                ).marginSymmetric(horizontal: 4),
              ),
            ),
      );
    }
    return breadCrumbList;
  }

  breadCrumbScrollToEnd() {
    Future.delayed(Duration(milliseconds: 200), () {
      if (_breadCrumbScroller.hasClients) {
        _breadCrumbScroller.animateTo(
            _breadCrumbScroller.position.maxScrollExtent,
            duration: Duration(milliseconds: 200),
            curve: Curves.fastLinearToSlowEaseIn);
      }
    });
  }

  Widget buildPathLocation() {
    final text = _locationStatus.value == LocationStatus.pathLocation
        ? controller.directory.value.path
        : _searchText.value;
    final textController = TextEditingController(text: text)
      ..selection = TextSelection.collapsed(offset: text.length);
    return Row(
      children: [
        SvgPicture.asset(
          _locationStatus.value == LocationStatus.pathLocation
              ? "assets/folder.svg"
              : "assets/search.svg",
          colorFilter: svgColor(Theme.of(context).tabBarTheme.labelColor),
        ),
        Expanded(
          child: TextField(
            focusNode: _locationNode,
            decoration: InputDecoration(
              border: InputBorder.none,
              isDense: true,
              prefix: Padding(
                padding: EdgeInsets.only(left: 4.0),
              ),
            ),
            controller: textController,
            onSubmitted: (path) {
              controller.openDirectory(path);
            },
            onChanged: _locationStatus.value == LocationStatus.fileSearchBar
                ? (searchText) => onSearchText(searchText, isLocal)
                : null,
          ).workaroundFreezeLinuxMint(),
        )
      ],
    );
  }

  // openDirectory(String path, {bool isLocal = false}) {
  //   model.openDirectory(path, isLocal: isLocal);
  // }
}

/// Selection after a navigation key moves it by [delta] rows. A shift range is
/// returned ordered from its anchor to the moved end, so the first and last
/// items of [selected] stand for those two ends on the next press without
/// separate state.
@visibleForTesting
List<Entry> navigateSelection(
    List<Entry> entries, List<Entry> selected, int delta, bool extend) {
  if (entries.isEmpty) return [];
  final current = selected.isEmpty ? -1 : entries.indexOf(selected.last);
  // With nothing selected, moving down starts above the first row and moving
  // up below the last one, as the Sciter grid did.
  final lead = current >= 0 ? current : (delta > 0 ? -1 : entries.length);
  final next = (lead + delta).clamp(0, entries.length - 1);
  if (!extend || current < 0) return [entries[next]];
  final first = entries.indexOf(selected.first);
  final anchor = first < 0 ? current : first;
  final step = next < anchor ? -1 : 1;
  return [for (var i = anchor; i != next + step; i += step) entries[i]];
}

/// Rows a PageUp/PageDown press moves from [lead] while rows [first]..[last]
/// are fully visible: to that edge first, then a page further, as list views
/// do.
@visibleForTesting
int pageDelta(int lead, int first, int last, bool down) {
  final page = max(1, last - first);
  if (down) return lead < last ? last - lead : page;
  return lead > first ? first - lead : -page;
}

Widget buildWindowsThisPC(BuildContext context, [TextStyle? textStyle]) {
  final color = Theme.of(context).iconTheme.color?.withOpacity(0.7);
  return Row(children: [
    Icon(Icons.computer, size: 20, color: color),
    SizedBox(width: 10),
    Text(translate('This PC'), style: textStyle)
  ]);
}

/// A transfer not over yet: shown in its folder and in the bottom line.
bool isActiveTransfer(JobProgress j) =>
    j.type == JobType.transfer &&
    (j.state == JobState.inProgress || j.state == JobState.none);

String timeLeft(double seconds) {
  final t = seconds < 60
      ? translate('ft-sec').replaceAll('{}', max(1, seconds.round()).toString())
      : translate('ft-min').replaceAll('{}', (seconds / 60).ceil().toString());
  return translate('ft-left').replaceAll('{}', t);
}

/// A file's kind by its extension: the colors of its badge.
(Color, Color) extColors(String ext) {
  switch (ext) {
    case 'doc':
    case 'docx':
      return (Color(0xFF175CD3), Color(0xFFEFF8FF));
    case 'xls':
    case 'xlsx':
    case 'csv':
      return (Color(0xFF067647), Color(0xFFECFDF3));
    case 'pdf':
      return (Color(0xFFB42318), Color(0xFFFEF3F2));
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'gif':
    case 'webp':
    case 'heic':
    case 'bmp':
    case 'svg':
      return (Color(0xFF6941C6), Color(0xFFF4F3FF));
    case 'mp4':
    case 'mov':
    case 'mkv':
    case 'avi':
    case 'mp3':
    case 'm4a':
    case 'wav':
      return (Color(0xFFC11574), Color(0xFFFDF2FA));
    case 'zip':
    case 'rar':
    case '7z':
    case 'gz':
    case 'tar':
      return (Color(0xFFB54708), Color(0xFFFFFAEB));
    default:
      return (Color(0xFF344054), Color(0xFFF2F4F7));
  }
}

String extOf(String name) {
  final i = name.lastIndexOf('.');
  return i > 0 && i < name.length - 1 ? name.substring(i + 1).toLowerCase() : '';
}

/// A file's icon: its extension on a tinted square.
Widget extBadge(String name, double size) {
  final ext = extOf(name);
  final (fg, bg) = extColors(ext);
  final text = ext.isEmpty ? '' : ext.toUpperCase();
  return Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration:
        BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size / 4)),
    child: Text(text.length > 4 ? text.substring(0, 4) : text,
        maxLines: 1,
        style: TextStyle(
            fontSize: size * 0.3, fontWeight: FontWeight.w600, color: fg)),
  );
}

const Color kFolderColor = Color(0xFFF5B544);

/// A row dragged from one side, to send to the other: with what is chosen
/// there when it is among it.
class FileDrag {
  final bool isLocal;
  final Entry entry;
  final SelectedItems chosen;
  FileDrag(this.isLocal, this.entry, this.chosen);

  List<Entry> get entries => chosen.items.contains(entry)
      ? chosen.items.where((e) => !e.isDrive).toList()
      : [entry];
}

/// A transfer given up (cancelled, or a failed one removed); a question
/// about it goes with it.
void dropJob(FileModel model, JobProgress j) {
  final c = model.conflict.value;
  if (c != null && c.id == j.id && !c.answer.isCompleted) {
    c.answer.complete(false);
  }
  model.jobController.cancelJob(j.id);
  model.jobController.jobTable.removeWhere((x) => x.id == j.id);
}

/// A failed transfer sent again, hidden files as the side it comes from shows.
void retry(FileModel model, JobProgress j) {
  final from = j.isRemoteToLocal ? model.remoteController : model.localController;
  model.jobController.retryTransfer(j, from.options.value.showHidden);
}
