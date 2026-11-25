import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/npf/npf_backend.dart';
import 'package:flutter_hbb/npf/npf_backend_stub.dart';
import 'package:flutter_hbb/npf/npf_lang.dart';
import 'package:flutter_hbb/npf/npf_model.dart';
import 'package:flutter_hbb/npf/npf_quality.dart';
import 'package:flutter_hbb/npf/npf_states.dart';
import 'package:flutter_hbb/npf/npf_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the state contract parses, numbers as strings', () {
    final s = NpfState.parse('''{"node":"512330087","name":"我的笔记本","online":true,
      "account":null,"assist":{"code":null,"why":"no_owner"},
      "peers":[{"number":"528316774","name":"台式机","mine":true,"online":true,
        "path":"p2p","rtt_ms":"18","services":[{"res":"desktop","title":"远程桌面",
        "svc":"","proto":"rustdesk/1","up":true,"can":["view","control"]}],"until":null}],
      "incoming":[{"id":"7","peer":{"number":"903552118","name":"","role":null,
        "temp":true,"via":"K7QM-4XPR-9TWD"},"can":["view"],"allowed":["view"],"since":"1794100000"}],
      "outgoing":[{"id":"1","peer":"528316774","res":"desktop","since":1,"path":"relay","rtt_ms":70}],
      "quota":{"used":"1048576","limit":"209715200"}}''');
    expect(s.node, '512330087');
    expect(s.signedIn, isFalse);
    expect(s.assist.code, isNull);
    expect(s.assist.why, 'no_owner');
    expect(s.peers.single.rttMs, 18);
    expect(s.peers.single.desktop?.can, ['view', 'control']);
    expect(s.incoming.single.peer.temp, isTrue);
    expect(s.incoming.single.since, 1794100000);
    expect(s.outgoing.single.peer.number, '528316774');
    expect(s.quota?.limit, 200 << 20);
    expect(NpfState.parse('not json').node, '');
  });

  test('the stub data parses', () async {
    final b = StubNpfBackend();
    final s = NpfState.parse(await b.stateJson());
    expect(s.mine.length, 4);
    expect(s.shared.length, 3);
    final share = await b.shareData();
    expect(share.people.map((p) => p.name), ['李四', '王五']);
    expect(share.admins.single.name, 'zh***@example.com');
    expect(share.machines.single.name, '出口路由器');
    final dl = share.resource('dl')!;
    expect(share.people.first.canOf(dl), ['use']);
    expect(share.people.last.canOf(dl), isEmpty);
    expect(share.people.first.canOf(share.resource('cam-91c0')!), isEmpty);
  });

  test('features: view is the base', () {
    const f = ['view', 'control', 'file', 'terminal'];
    expect(npfToggleCap(f, [], 'file'), ['view', 'file']);
    expect(npfToggleCap(f, ['view', 'file'], 'view'), isEmpty);
    expect(npfToggleCap(f, ['view', 'file'], 'file'), ['view']);
  });

  test('signal bars', () {
    expect(npfBars(online: false, rttMs: 10), 0);
    expect(npfBars(online: true, path: 'p2p', rttMs: 18), 3);
    expect(npfBars(online: true, path: 'relay', rttMs: 64), 2);
    expect(npfBars(online: true, path: 'relay', rttMs: 168), 1);
  });

  test('quality from RustDesk strings', () {
    final q = NpfSessionQuality.fromRustDesk(
        speed: '537.60kB/s', delay: '32', codecFormat: 'H264', path: 'p2p');
    expect(q.rttMs, 32);
    expect(q.rateText, '4.3 Mbps');
    expect(q.codec, 'H.264');
  });

  test('messages from the Rust side', () {
    expect(NpfConnState.fromMsgBox('error', 'Connection Error', 'npf:quota:200 MiB')?.kind,
        NpfStateKind.quota);
    expect(NpfConnState.fromMsgBox('wait-remote-accept-nook', '', '')?.kind,
        NpfStateKind.wait);
    expect(NpfConnState.fromMsgBox('error', 'Connection Error', 'Remote desktop is offline')?.kind,
        NpfStateKind.offline);
    expect(NpfConnState.fromMsgBox('error', 'Connection Error', 'npf:need_account')?.kind,
        NpfStateKind.needAccount);
    expect(NpfConnState.fromMsgBox('error', 'Connection Error', 'Timeout'), isNull);
  });

  test('the connection manager info', () {
    final i = NpfCmInfo.fromJson({
      'number': '903552118',
      'role': null,
      'temp': true,
      'can': ['view', 'control'],
      'asked': '1794100000'
    })!;
    expect(i.temp, isTrue);
    expect(i.asked, 1794100000);
    expect(i.who, '903 552 118');
    expect(NpfCmInfo.fromJson(null), isNull);
  });

  test("npf's share/list parses: a row is a person, keys' rows apart", () {
    final d = NpfShareData.fromJson(jsonDecode('''{"rev":3,
      "resources":[{"name":"desktop","title":"","type":"app","svc":"rustdesk",
        "access":"all","state":"on","by":"app/rustdesk",
        "caps":["view","control","file","terminal"],"up":true},
        {"name":"nas","title":"NAS","type":"tcp","svc":"","access":"admin",
         "state":"admin_only","by":"admin"}],
      "members":[{"id":1786300000,"account":"3156","login":"zh***@example.com",
        "label":null,"role":"admin","since":1786300000,"until":null,"scope":null,
        "online":true,"using":[]},
        {"id":1794100000,"account":"2087","login":"li***@qq.com","label":"李四",
         "role":"member","since":1794100000,"until":null,
         "scope":[{"res":"desktop","can":null}],"online":true,"using":["desktop"]},
        {"id":1794100001,"account":"2311","login":"139****0021","label":null,
         "role":"member","since":1794100001,"until":1796700000,
         "scope":[{"res":"desktop","can":["view"]}],"online":false,"using":[]},
        {"id":1780000000,"machine":true,"key":"q0Zt3cX9mVb2LrPw8yHn4kEaUs6JdGfT1oIxCvBz5Q8",
         "fp":"7f3a9c21d0e45b86","label":null,"role":"admin","since":1780000000,
         "until":null,"scope":null,"online":false,"using":[]}],
      "guests":[{"label":"","number":"903552118","using":[]}],
      "codes":[{"locator":"ABCD","label":"王五","uses":1,"expires":1794186400,
        "scope":[{"res":"desktop","can":null}],"temp":false,"member_ttl_s":0}]}''') as Map<String, dynamic>);
    final desk = d.resource('desktop')!;
    expect(desk.isDesktop, isTrue);
    expect(d.resource('nas')!.adminOnly, isTrue);
    // the owner is not a row: the admins are accounts, the configured peer is not one
    expect(d.admins.single.id, 1786300000);
    expect(d.admins.single.name, 'zh***@example.com');
    // a person each: by the label given here, else the login name
    expect(d.people.map((w) => w.id), [1794100000, 1794100001]);
    expect(d.people.map((w) => w.name), ['李四', '139****0021']);
    expect(d.people.first.login, 'li***@qq.com');
    expect(d.people.first.canOf(desk), ['view', 'control', 'file', 'terminal']);
    expect(d.people.last.canOf(desk), ['view']);
    expect(d.people.last.until, 1796700000);
    final peer = d.machines.single;
    expect(peer.machine, isTrue);
    expect(peer.name, '7f3a9c21d0e45b86');
    expect(d.codes.single.scope!.single.can.length, 4);

    // rows without a label (and without a key) stay apart
    final two = NpfShareData.fromJson(jsonDecode('''{"members":[
      {"id":7,"account":"31","role":"member","scope":null},
      {"id":8,"account":"32","role":"member","scope":null}]}''') as Map<String, dynamic>);
    expect(two.people.map((w) => w.id), [7, 8]);
    expect(two.people.map((w) => w.name), ['账户 31', '账户 32']);
  });

  test('member/set and member/remove name a row by its id', () async {
    final b = StubNpfBackend();
    final m = NpfModel(b);
    await m.refreshShare();
    final wang = m.share.people.last;
    await m.memberSet(wang.id, const [NpfGrant('web3000', [])], null);
    expect(b.calls, contains('memberSet ${wang.id}'));
    expect(m.share.people.last.scope!.single.res, 'web3000');
    await m.memberRemove(m.share.machines.single.id);
    expect(m.share.machines, isEmpty);
    expect(m.share.people.length, 2);
  });

  test('every string has Chinese', () {
    final keys = <String>{};
    final re = RegExp(r"""npfTr(?:Spans)?\(\s*'((?:[^'\\]|\\.)*)'""");
    final re2 = RegExp(r'''npfTr(?:Spans)?\(\s*"((?:[^"\\]|\\.)*)"''');
    for (final f in Directory('lib/npf').listSync().whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      for (final m in [...re.allMatches(src), ...re2.allMatches(src)]) {
        keys.add(m.group(1)!.replaceAll("\\'", "'"));
      }
    }
    // keys passed through variables
    for (final f in Directory('lib/npf').listSync().whereType<File>()) {
      final src = f.readAsStringSync();
      for (final m in RegExp(r"""^\s+'([A-Z<][^']*)',?$""", multiLine: true)
          .allMatches(src)) {
        if (f.path.endsWith('npf_lang.dart')) continue;
        keys.add(m.group(1)!);
      }
    }
    final missing = keys.where((k) => !npfZhTable.containsKey(k)).toList();
    expect(missing, isEmpty);
  });
}
