// Golden screenshots of the scheme C pages with the stub backend:
//   flutter test --update-goldens test/npf/
// The PNGs land in test/npf/goldens/.

import 'package:flutter/material.dart';
import 'package:flutter_hbb/npf/npf_backend.dart';
import 'package:flutter_hbb/npf/npf_backend_stub.dart';
import 'package:flutter_hbb/npf/npf_cm.dart';
import 'package:flutter_hbb/npf/npf_desk_modes.dart';
import 'package:flutter_hbb/npf/npf_desk_ui.dart';
import 'package:flutter_hbb/npf/npf_home_page.dart';
import 'package:flutter_hbb/npf/npf_lang.dart';
import 'package:flutter_hbb/npf/npf_model.dart';
import 'package:flutter_hbb/npf/npf_quality.dart';
import 'package:flutter_hbb/npf/npf_share_page.dart';
import 'package:flutter_hbb/npf/npf_states.dart';
import 'package:flutter_hbb/npf/npf_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'npf_test_util.dart';

// the main window below RustDesk's tab bar (prototype boards: 1040 × 720,
// of which 36 are the title bar)
const kPage = Size(1040, 684);
const kCm = Size(300, 490); // kConnectionManagerWindowSizeClosedChat

void main() {
  setUpAll(() async {
    NpfLang.zh = true;
    await loadNpfTestFont();
    mockClipboard();
  });

  NpfModel modelOf(StubNpfBackend b) {
    final m = NpfModel(b);
    NpfModel.instance = m;
    NpfBackend.instance = b;
    return m;
  }

  group('CHome', () {
    testWidgets('my devices, someone controls me', (tester) async {
      final m = modelOf(StubNpfBackend(liveIn: true));
      await pumpNpf(tester, NpfHomePage(model: m, onInvite: () {}), size: kPage);
      await expectLater(find.byType(NpfHomePage),
          matchesGoldenFile('goldens/chome_mine_bar_in.png'));
    });

    testWidgets('my devices, no bars', (tester) async {
      final m = modelOf(StubNpfBackend(liveIn: false));
      await pumpNpf(tester, NpfHomePage(model: m, onInvite: () {}), size: kPage);
      await expectLater(find.byType(NpfHomePage),
          matchesGoldenFile('goldens/chome_mine.png'));
    });

    testWidgets('shared with me, both bars', (tester) async {
      final m = modelOf(StubNpfBackend(liveIn: true, liveOut: true));
      await pumpNpf(
          tester, NpfHomePage(model: m, onInvite: () {}, initialTab: NpfHomeTab.shared),
          size: kPage);
      await expectLater(find.byType(NpfHomePage),
          matchesGoldenFile('goldens/chome_shared_bars.png'));
    });

    testWidgets('recent, no assist code (no owner)', (tester) async {
      final b = StubNpfBackend(liveIn: false)..assistWhy = 'no_owner';
      final m = modelOf(b);
      await pumpNpf(
          tester, NpfHomePage(model: m, onInvite: () {}, initialTab: NpfHomeTab.recent),
          size: kPage);
      await expectLater(find.byType(NpfHomePage),
          matchesGoldenFile('goldens/chome_recent_no_owner.png'));
    });

    testWidgets('tabs, renew and connect', (tester) async {
      final b = StubNpfBackend(liveIn: true);
      final m = modelOf(b);
      await pumpNpf(tester, NpfHomePage(model: m, onInvite: () {}), size: kPage);
      expect(find.text('K7QM-4XPR-9TWD'), findsOneWidget);
      expect(find.text('1 小时 52 分后自动更换'), findsOneWidget);
      await tester.tap(find.text('换一个'));
      await settle(tester);
      expect(find.text('P3HW-7KZC-2MQN'), findsOneWidget);
      await tester.tap(find.text('共享给我的 3'));
      await settle(tester);
      expect(find.text('李四的电脑'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'k7qm-4xpr-9twd');
      await tester.tap(find.text('连接'));
      await settle(tester);
      expect(b.calls, contains('connect k7qm-4xpr-9twd'));
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.text('连接'));
      await settle(tester);
      expect(find.text('这不像协助码、邀请码或设备编号'), findsOneWidget);
      await tester.tap(find.text('断开'));
      await settle(tester);
      expect(b.calls, contains('disconnectIncoming in-1'));
      expect(find.text('断开'), findsNothing);
    });
  });

  group('CShare', () {
    testWidgets('by service', (tester) async {
      final m = modelOf(StubNpfBackend());
      await pumpNpf(tester, NpfSharePage(model: m), size: kPage);
      await expectLater(find.byType(NpfSharePage),
          matchesGoldenFile('goldens/cshare_service.png'));
    });

    testWidgets('by person', (tester) async {
      final m = modelOf(StubNpfBackend());
      await pumpNpf(
          tester,
          NpfSharePage(
              model: m,
              initialView: NpfShareView.person,
              initialPerson: '1793700000'),
          size: const Size(1040, 1000));
      await expectLater(find.byType(NpfSharePage),
          matchesGoldenFile('goldens/cshare_person.png'));
    });

    testWidgets('cell editor and the confirmation', (tester) async {
      final b = StubNpfBackend();
      final m = modelOf(b);
      await pumpNpf(tester, NpfSharePage(model: m), size: kPage);
      // 李四 × 远程桌面: "看、控制"
      await tester.tap(find.text('看、控制'));
      await settle(tester, ink: true);
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/cshare_edit.png'));
      // he is using it: dropping "control" asks first
      await tester.tap(find.text('控制键盘鼠标'));
      await settle(tester, ink: true);
      expect(find.text('会断开李四这次连接'), findsOneWidget);
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/cshare_confirm.png'));
      await tester.tap(find.text('断开并修改'));
      await settle(tester);
      expect(b.calls, contains('memberSet 1793700000'));
    });

    testWidgets('removing a person: all of their computers and phones',
        (tester) async {
      final b = StubNpfBackend();
      final m = modelOf(b);
      await pumpNpf(
          tester,
          NpfSharePage(
              model: m,
              initialView: NpfShareView.person,
              initialPerson: '1793700000'),
          size: const Size(1040, 1000));
      await tester.tap(find.text('移除李四'));
      await settle(tester);
      expect(
          find.text(
              '他的所有电脑和手机都不再能连接这台电脑，正在用的远程桌面会马上断开。之后他用不了这台电脑的任何服务，要再给他用得重新邀请。'),
          findsOneWidget);
      await tester.tap(find.text('移除').last);
      await settle(tester);
      expect(b.calls, contains('memberRemove 1793700000'));
      expect(m.share.people.map((w) => w.name), ['王五']);
    });

    testWidgets('invite', (tester) async {
      final b = StubNpfBackend();
      final m = modelOf(b);
      await pumpNpf(tester, NpfSharePage(model: m), size: const Size(1040, 760));
      await tester.tap(find.text('邀请别人…'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), '赵六');
      await tester.tap(find.text('远程桌面').last);
      await settle(tester);
      await tester.tap(find.text('门口摄像头').last);
      await settle(tester);
      await tester.tap(find.text('30 天').last);
      await settle(tester, ink: true);
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/cshare_invite.png'));
      await tester.tap(find.text('生成邀请码'));
      await settle(tester, ink: true);
      expect(b.calls, contains('shareNew 赵六 desktop,cam-3f2a'));
      expect(find.text('H6ZP-3KTA-8WQC'), findsOneWidget);
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/cshare_invite_code.png'));
    });
  });

  group('CIncoming', () {
    final b = StubNpfBackend();
    final asked = b.now().millisecondsSinceEpoch ~/ 1000 - 2;
    Widget card(NpfCmInfo info, {bool authorized = false}) => NpfCmCard(
        backend: b,
        client: NpfCmClient(
            connId: 7,
            peerId: info.number,
            name: info.name,
            authorized: authorized,
            info: info));
    final member = NpfCmInfo(
        number: '903117460',
        name: '李四的电脑',
        role: 'member',
        label: '李四',
        can: const ['view', 'control'],
        joined: DateTime(2026, 11, 3).millisecondsSinceEpoch ~/ 1000,
        asked: asked);
    final assist = NpfCmInfo(
        number: '903552118',
        temp: true,
        via: 'K7QM-4XPR-9TWD',
        can: const ['view', 'control', 'file', 'terminal'],
        asked: asked);

    testWidgets('member', (tester) async {
      await pumpNpf(tester, card(member), size: kCm);
      await expectLater(find.byType(NpfCmCard),
          matchesGoldenFile('goldens/cincoming_member.png'));
      await tester.tap(find.text('同意'));
      await settle(tester);
      expect(b.calls, contains('cmApprove 7 view,control'));
    });

    testWidgets('assist', (tester) async {
      await pumpNpf(tester, card(assist), size: kCm);
      await expectLater(find.byType(NpfCmCard),
          matchesGoldenFile('goldens/cincoming_assist.png'));
      await tester.tap(find.text('传文件'));
      await settle(tester);
      await tester.tap(find.text('同意'));
      await settle(tester);
      expect(b.calls, contains('cmApprove 7 view,control,file'));
    });

    testWidgets('being controlled', (tester) async {
      final live = NpfCmInfo(
          number: assist.number,
          temp: true,
          via: assist.via,
          can: assist.can,
          allowed: const ['view', 'control'],
          since: asked - 6);
      await pumpNpf(tester, card(live, authorized: true), size: kCm);
      await expectLater(find.byType(NpfCmCard),
          matchesGoldenFile('goldens/cincoming_live.png'));
    });

    testWidgets('voice call', (tester) async {
      final live = NpfCmInfo(
          number: member.number,
          name: member.name,
          role: 'member',
          label: member.label,
          can: member.can,
          allowed: const ['view', 'control'],
          since: asked - 6);
      NpfCmCard voice(NpfCmVoice v) => NpfCmCard(
          backend: b,
          client: NpfCmClient(
              connId: 7, authorized: true, info: live, voice: v));
      await pumpNpf(tester, voice(NpfCmVoice.incoming), size: kCm);
      await expectLater(find.byType(NpfCmCard),
          matchesGoldenFile('goldens/cincoming_voice_call.png'));
      await tester.tap(find.text('接听'));
      await settle(tester);
      expect(b.calls, contains('cmVoiceAnswer 7 true'));
      await pumpNpf(tester, voice(NpfCmVoice.connected), size: kCm);
      await expectLater(find.byType(NpfCmCard),
          matchesGoldenFile('goldens/cincoming_voice_on.png'));
      await tester.tap(find.text('挂断'));
      await settle(tester);
      expect(b.calls, contains('cmVoiceEnd 7'));
    });
  });

  // the session toolbar and its panels (oudesk-ui.md 7), with the rows a
  // Windows peer gives
  group('Desk toolbar', () {
    const direct = NpfSessionQuality(rttMs: 12, kbps: 4300, path: 'p2p');
    const panelWidth = 880.0;
    Widget grip(Axis axis) => axis == Axis.horizontal
        ? const SizedBox(
            width: 22,
            child: Icon(Icons.drag_indicator, size: 20, color: NpfDesk.dim))
        : const SizedBox(
            height: 22,
            child: Icon(Icons.drag_handle, size: 20, color: NpfDesk.dim));

    List<NpfDeskOption<int>> screens({bool long = false}) => [
          for (var i = 0; i < 2; i++)
            NpfDeskOption(
                i,
                Text(long
                    ? npfTr('Screen {n}', {'n': i + 1})
                    : '${i + 1}')),
          NpfDeskOption(-1, Text(npfTr('All'))),
        ];

    Widget bar(NpfDeskCat? open,
            {int display = 0, bool busy = false, Axis axis = Axis.horizontal}) =>
        NpfDeskBar(
            axis: axis,
            grip: grip(axis),
            leading: const NpfQualityPill(q: direct),
            displays: screens(),
            display: display,
            onDisplay: (_) {},
            cats: NpfDeskCat.values,
            open: open,
            tags: {
              NpfDeskCat.picture:
                  NpfPictureModes.modeName(NpfPictureMode.office)
            },
            onCat: (_) {},
            actions: [
              NpfDeskBarAction(NpfDeskIcons.folder, '', () {}),
              NpfDeskBarAction(NpfDeskIcons.chat, '', () {}),
              NpfDeskBarAction(NpfDeskIcons.phone, '', () {},
                  color: busy ? NpfDesk.green : null),
              if (busy)
                NpfDeskBarAction(NpfDeskIcons.record, '', () {},
                    color: NpfDesk.red,
                    dot: axis == Axis.horizontal,
                    label:
                        axis == Axis.horizontal ? const Text('05:12') : null),
            ],
            window: [
              NpfDeskBarAction(NpfDeskIcons.fullscreen, '', () {}),
              NpfDeskBarAction(NpfDeskIcons.up, '', () {}),
            ],
            onEnd: () {});

    Widget page(Widget bar, [Widget? under]) => Container(
        color: const Color(0xFF2B4A63),
        alignment: Alignment.topCenter,
        padding: const EdgeInsets.only(top: 6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          bar,
          const SizedBox(height: 8),
          if (under != null) under,
        ]));

    testWidgets('control', (tester) async {
      await pumpNpf(
          tester,
          page(
              bar(NpfDeskCat.control),
              NpfDeskPanel(width: panelWidth, left: [
                NpfDeskLabel(npfTr('This computer')),
                NpfDeskBigButtons([
                  NpfDeskBig(NpfDeskIcons.cad, 'Ctrl+Alt+Del', () {}),
                  NpfDeskBig(NpfDeskIcons.lock, npfTr('Lock'), () {}),
                  NpfDeskBig(NpfDeskIcons.windows, npfTr('Task view'), () {}),
                  NpfDeskBig(NpfDeskIcons.desktop, npfTr('Show desktop'), () {}),
                  NpfDeskBig(
                      NpfDeskIcons.refresh, npfTr('Refresh picture'), () {}),
                  NpfDeskBig(
                      NpfDeskIcons.key, npfTr('Type the password'), () {}),
                ]),
                NpfDeskSmallButtons([
                  NpfDeskSmall(
                      NpfDeskIcons.clip, const Text('发送剪贴板按键'), () {}),
                  NpfDeskSmall(
                      NpfDeskIcons.power, const Text('重启远程设备'), () {},
                      danger: true),
                  NpfDeskSmall(NpfDeskIcons.swap, const Text('反转访问方向'), () {}),
                  NpfDeskSmall(NpfDeskIcons.edit,
                      Text(npfTr('Change the saved password')), () {}),
                ]),
                NpfDeskSwitchRow(
                    label: Text(npfTr('Block their keyboard and mouse')),
                    note: npfTr(
                        'The person at the computer cannot use it meanwhile'),
                    value: false,
                    onChanged: (_) {}),
                NpfDeskSwitchRow(
                    label: Text(npfTr('Lock it when the session ends')),
                    note: npfTr('The computer goes back to its lock screen'),
                    value: true,
                    onChanged: (_) {}),
              ], right: [
                NpfDeskLabel(npfTr('My mouse')),
                NpfDeskSwitchRow(
                    label: Text(npfTr('View only')),
                    note: npfTr(
                        'Only the picture: my mouse and keyboard are not sent'),
                    value: false,
                    onChanged: (_) {}),
                NpfDeskSwitchRow(
                    label: const Text('显示远程光标'),
                    value: true,
                    onChanged: (_) {}),
                NpfDeskSwitchRow(
                    label: const Text('相对鼠标模式'),
                    value: false,
                    onChanged: (_) {}),
                NpfDeskSwitchRow(
                    label: const Text('鼠标滚轮反向'),
                    value: false,
                    onChanged: (_) {}),
                NpfDeskSwitchRow(
                    label: const Text('交换鼠标左右键'),
                    value: false,
                    onChanged: null),
                NpfDeskLabel(npfTr('How my keyboard is sent')),
                NpfDeskSegment<String>(options: [
                  NpfDeskOption('map', Text(npfTr('Map'))),
                  NpfDeskOption('translate', Text(npfTr('Translate'))),
                  NpfDeskOption('legacy', Text(npfTr('Legacy'))),
                ], value: 'map', onChanged: (_) {}),
                NpfDeskNote(npfTr(
                    'Map: a key is the key at the same place. For shortcuts and games.')),
              ])),
          size: const Size(1280, 800),
          brightness: Brightness.dark);
      await expectLater(
          find.byType(Scaffold), matchesGoldenFile('goldens/desk_control.png'));
    });

    testWidgets('picture', (tester) async {
      const has = {'h264', 'h265', 'av1'};
      const inField = EdgeInsets.fromLTRB(0, 3, 8, 3);
      final p = NpfPictureModes.preset(NpfPictureMode.office, has)!;
      await pumpNpf(
          tester,
          page(
              bar(NpfDeskCat.picture),
              NpfDeskPanel(width: panelWidth, maxHeight: 640, left: [
                NpfDeskLabel(npfTr('Mode')),
                NpfDeskCards<NpfPictureMode>(cards: [
                  for (final m in const [
                    NpfPictureMode.office,
                    NpfPictureMode.hd,
                    NpfPictureMode.game
                  ])
                    NpfDeskCard(m, NpfPictureModes.modeName(m),
                        NpfPictureModes.modeLine(m, has))
                ], value: NpfPictureModes.of(p, has), onChanged: (_) {}),
                NpfDeskNote(NpfPictureModes.modeNote(NpfPictureMode.office)),
                NpfDeskField(
                    npfTr('Quality'),
                    NpfDeskSegment<String>(
                        padding: inField,
                        options: [
                          for (final q in const [
                            'low',
                            'balanced',
                            'best',
                            'custom'
                          ])
                            NpfDeskOption(
                                q, Text(NpfPictureModes.qualityName(q)))
                        ],
                        value: p.quality,
                        onChanged: (_) {})),
                NpfDeskField(
                    npfTr('Frame rate'),
                    NpfDeskSegment<int>(
                        padding: inField,
                        options: [
                          for (final f in NpfPictureModes.rates)
                            NpfDeskOption(f, Text(npfTr('{n} fps', {'n': f})))
                        ],
                        value: p.fps,
                        onChanged: (_) {})),
                NpfDeskField(
                    npfTr('Codec'),
                    NpfDeskSegment<String>(
                        padding: inField,
                        options: [
                          for (final c in NpfPictureModes.codecs(has))
                            NpfDeskOption(c, Text(NpfPictureModes.codecName(c)))
                        ],
                        value: p.codec,
                        onChanged: (_) {})),
                NpfDeskSwitchRow(
                    label: const Text('真彩模式（4:4:4）'),
                    note: npfTr(
                        'Small text and thin lines are clearer. With VP9 or AV1 only'),
                    value: false,
                    onChanged: (_) {}),
              ], right: [
                NpfDeskLabel(npfTr('Scale')),
                NpfDeskSegment<String>(options: const [
                  NpfDeskOption('adaptive', Text('适应窗口')),
                  NpfDeskOption('original', Text('原始尺寸')),
                  NpfDeskOption('custom', Text('自定义缩放')),
                ], value: 'adaptive', onChanged: (_) {}),
                NpfDeskSelectRow<String>(
                    label: const Text('分辨率'),
                    options: const [('a', '2560x1440'), ('b', '1920x1080')],
                    value: 'a',
                    onChanged: (_) {}),
                NpfDeskLabel(npfTr('Screens')),
                NpfDeskSegment<int>(
                    options: screens(long: true),
                    value: 0,
                    onChanged: (_) {}),
                NpfDeskStepRow(
                    label: Text(npfTr('Virtual screens')),
                    note: npfTr('Screens the computer does not really have'),
                    value: 0,
                    onLess: null,
                    onMore: () {}),
                NpfDeskSwitchRow(
                    label: Text(npfTr('Each screen in its own window')),
                    note:
                        npfTr('For when this side has several monitors too'),
                    value: false,
                    onChanged: (_) {}),
                NpfDeskSwitchRow(
                    label: const Text('隐私模式'),
                    note: npfTr(
                        'Their screen goes dark: nobody there sees what I do'),
                    value: false,
                    onChanged: (_) {}),
              ])),
          size: const Size(1280, 800),
          brightness: Brightness.dark);
      await expectLater(
          find.byType(Scaffold), matchesGoldenFile('goldens/desk_picture.png'));
    });

    testWidgets('tools, in a call and recording', (tester) async {
      await pumpNpf(
          tester,
          page(
              bar(NpfDeskCat.tools, busy: true),
              NpfDeskPanel(width: panelWidth, left: [
                NpfDeskLabel(npfTr('The person at the computer')),
                NpfDeskStateCard(
                    color: NpfDesk.green,
                    label: Text('${npfTr('In a call')}  05:12'),
                    actions: [
                      NpfDeskButton(npfTr('Hang up'),
                          danger: true, onTap: () {})
                    ]),
                NpfDeskSelectRow<String>(
                    icon: NpfDeskIcons.mic,
                    label: Text(npfTr('Microphone')),
                    options: const [('a', '麦克风阵列 (Realtek Audio)')],
                    value: 'a',
                    onChanged: (_) {}),
                NpfDeskSelectRow<String>(
                    icon: NpfDeskIcons.speaker,
                    label: Text(npfTr('Speaker')),
                    options: [('', npfTr('As the system'))],
                    value: '',
                    onChanged: (_) {}),
                NpfDeskActionRow(
                    icon: NpfDeskIcons.chat,
                    label: const Text('文字聊天'),
                    onTap: () {}),
                NpfDeskLabel(npfTr('A record')),
                NpfDeskSwitchRow(
                    label: Text(npfTr('Record the session')),
                    note: npfTr(
                        'A video of this session, kept on this computer'),
                    value: true,
                    onChanged: (_) {}),
                NpfDeskActionRow(
                    label: Text(npfTr('Screenshot')),
                    note:
                        npfTr('Their screen as it is now, to copy or save'),
                    trailing: const NpfDeskIcon(NpfDeskIcons.shot,
                        size: 17, color: NpfDesk.dim),
                    onTap: () {}),
              ], right: [
                const SizedBox(height: 6),
                NpfDeskBigButtons([
                  NpfDeskBig(NpfDeskIcons.folder, '传输文件', () {}),
                  NpfDeskBig(NpfDeskIcons.terminal, '终端', () {}),
                  NpfDeskBig(NpfDeskIcons.camera, '查看摄像头', () {}),
                ]),
                NpfDeskLabel(npfTr('Sound and clipboard')),
                NpfDeskSwitchRow(
                    label: Text(npfTr("Play the computer's sound")),
                    value: true,
                    onChanged: (_) {}),
                NpfDeskSwitchRow(
                    label: Text(npfTr('Sync the clipboard')),
                    note:
                        npfTr('Text copied on one side pastes on the other'),
                    value: true,
                    onChanged: (_) {}),
                NpfDeskSwitchRow(
                    label: const Text('允许复制粘贴文件'),
                    note: npfTr(
                        'Copy files on one side, paste them on the other'),
                    value: false,
                    onChanged: (_) {}),
              ])),
          size: const Size(1280, 800),
          brightness: Brightness.dark);
      await expectLater(
          find.byType(Scaffold), matchesGoldenFile('goldens/desk_tools.png'));
    });

    testWidgets('no panel: collapsed, all the screens, narrow, at a side',
        (tester) async {
      Widget handle(Axis axis) => NpfDeskHandle(
          axis: axis,
          grip: grip(axis),
          leading: const NpfQualityPill(q: direct),
          busy: [
            NpfDeskBusy(Text(npfTr('View only')), color: NpfDesk.accent),
            NpfDeskBusy(Text('${npfTr('Recording')} 05:12'),
                color: NpfDesk.red),
            NpfDeskBusy(Text('${npfTr('In a call')} 03:40'),
                color: NpfDesk.green),
          ],
          expandTip: '',
          onExpand: () {});
      await pumpNpf(
          tester,
          Container(
              color: const Color(0xFF2B4A63),
              padding: const EdgeInsets.all(6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                bar(null, axis: Axis.vertical, busy: true),
                const SizedBox(width: 8),
                handle(Axis.vertical),
                const SizedBox(width: 24),
                Expanded(
                    child: Column(children: [
                  handle(Axis.horizontal),
                  const SizedBox(height: 24),
                  bar(null, display: -1, busy: true),
                  const SizedBox(height: 8),
                  NpfDeskChips([
                    NpfDeskChip(npfTr('Privacy screen')),
                    NpfDeskChip(npfTr('Their input is blocked'),
                        color: NpfDesk.yellow),
                    NpfDeskChip(npfTr('View only')),
                  ]),
                  const SizedBox(height: 24),
                  // a window too narrow for it: the middle scrolls, the end stays
                  SizedBox(width: 520, child: bar(NpfDeskCat.picture)),
                ])),
              ])),
          size: const Size(1280, 480),
          brightness: Brightness.dark);
      await expectLater(
          find.byType(Scaffold), matchesGoldenFile('goldens/desk_states.png'));
    });
  });

  group('Session', () {
    Widget session(NpfSessionQuality q) => Container(
          color: const Color(0xFF2B4A63),
          alignment: Alignment.topCenter,
          padding: const EdgeInsets.only(top: 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final t in ['显示器', '操作', '聊天', '文件', '画质'])
                  Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(t, style: npfText(13))),
                NpfQualityPill(q: q, open: true),
                const SizedBox(width: 4),
                NpfButton('断开',
                    kind: NpfButtonKind.dangerSoft,
                    height: 32,
                    fontSize: 13,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    onTap: () {}),
              ]),
            ),
            const SizedBox(height: 8),
            NpfQualityPopover(q: q),
          ]),
        );

    testWidgets('direct', (tester) async {
      final q = NpfSessionQuality.fromRustDesk(
          speed: '537.60kB/s', delay: '32', fps: '30', codecFormat: 'H264',
          path: 'p2p');
      await pumpNpf(tester, session(q), size: const Size(760, 420));
      await expectLater(find.byType(Scaffold),
          matchesGoldenFile('goldens/session_direct.png'));
    });

    testWidgets('relay', (tester) async {
      final q = NpfSessionQuality.fromRustDesk(
          speed: '204.80kB/s', delay: '168', fps: '24', codecFormat: 'H264',
          path: 'relay', quota: const NpfQuota(146 << 20, 200 << 20));
      await pumpNpf(tester, session(q), size: const Size(760, 480));
      await expectLater(find.byType(Scaffold),
          matchesGoldenFile('goldens/session_relay.png'));
    });
  });

  testWidgets('States', (tester) async {
    final kinds = NpfStateKind.values;
    await pumpNpf(
        tester,
        Container(
          color: NpfPalette.light.bg,
          padding: const EdgeInsets.all(28),
          child: Wrap(spacing: 14, runSpacing: 14, children: [
            for (final k in kinds)
              SizedBox(
                  width: 345,
                  height: 170,
                  child: NpfStateCard(
                      state: NpfConnState.of(k, name: '爸妈家电脑'))),
          ]),
        ),
        size: const Size(760, 1044));
    await expectLater(
        find.byType(Scaffold), matchesGoldenFile('goldens/states.png'));
  });
}
