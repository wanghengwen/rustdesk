// Demo data of the prototype (the sample people and devices), for tests and
// for looking at the pages before the Rust side is wired. The sharing calls
// change the data in memory.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'npf_backend.dart';
import 'npf_model.dart';

class StubNpfBackend extends NpfBackend {
  StubNpfBackend({DateTime? now, this.liveIn = true, this.liveOut = false})
      : _now = now ?? DateTime(2026, 11, 8, 10, 28);

  final DateTime _now;
  bool liveIn; // someone controls this computer
  bool liveOut; // I control the desktop of "家里的台式机"
  String assistWhy = ''; // '' = a code; off | offline | no_owner
  bool renewed = false;
  final calls = <String>[]; // what the pages asked for, for tests
  final _changed = StreamController<void>.broadcast();

  int get _t => _now.millisecondsSinceEpoch ~/ 1000;

  @override
  DateTime now() => _now;

  @override
  Stream<void> get stateChanged => _changed.stream;

  void changed() => _changed.add(null);

  static Map<String, dynamic> _svc(String res, String title,
          {String svc = '', String proto = '', List<String> can = const []}) =>
      {
        'res': res,
        'title': title,
        'svc': svc,
        'proto': proto,
        'up': true,
        'can': can
      };

  static const _desk = ['view', 'control', 'file', 'terminal'];

  @override
  Future<String> stateJson() async {
    final t = _t;
    return jsonEncode({
      'node': '512330087',
      'name': '我的笔记本',
      'online': assistWhy != 'offline',
      'account': {'name': 'zhangsan'},
      'assist': assistWhy.isEmpty
          ? {
              'code': renewed ? 'P3HW-7KZC-2MQN' : 'K7QM-4XPR-9TWD',
              'expires': renewed ? t + 4 * 3600 : t + 3 * 3600 + 52 * 60
            }
          : {'code': null, 'why': assistWhy},
      'peers': [
        {
          'number': '528316774',
          'name': '家里的台式机',
          'mine': true,
          'online': true,
          'path': 'p2p',
          'rtt_ms': 18,
          'services': [
            _svc('desktop', '远程桌面', proto: 'rustdesk/1', can: _desk)
          ],
        },
        {
          'number': '640221958',
          'name': '办公室笔记本',
          'mine': true,
          'online': true,
          'path': 'relay',
          'rtt_ms': 64,
          'services': [
            _svc('desktop', '远程桌面', proto: 'rustdesk/1', can: _desk)
          ],
        },
        {
          'number': '771045263',
          'name': '家里的 NAS',
          'mine': true,
          'online': true,
          'path': 'p2p',
          'rtt_ms': 9,
          'services': [
            _svc('dsm', 'NAS 管理', svc: 'web', proto: 'https'),
            _svc('photos', '相册', svc: 'web', proto: 'http'),
            _svc('ssh', 'SSH', svc: 'ssh', proto: 'ssh'),
          ],
        },
        {
          'number': '388910542',
          'name': '爸妈家电脑',
          'mine': true,
          'online': false,
          'path': null,
          'rtt_ms': null,
          'services': [
            _svc('desktop', '远程桌面',
                proto: 'rustdesk/1', can: ['view', 'control', 'file'])
          ],
        },
        {
          'number': '903117460',
          'name': '李四的电脑',
          'mine': false,
          'online': true,
          'path': 'relay',
          'rtt_ms': 71,
          'services': [
            _svc('desktop', '远程桌面',
                proto: 'rustdesk/1', can: ['view', 'control'])
          ],
        },
        {
          'number': '415770329',
          'name': '王五家的 NAS',
          'mine': false,
          'online': true,
          'path': 'p2p',
          'rtt_ms': 22,
          'until': t + 30 * 86400,
          'services': [
            _svc('photos', '照片墙', svc: 'web', proto: 'http'),
            _svc('dl', '下载文件夹', svc: 'web', proto: 'http'),
          ],
        },
        {
          'number': '415770330',
          'name': '王五家的门口摄像头',
          'mine': false,
          'online': true,
          'path': 'p2p',
          'rtt_ms': 22,
          'services': [
            _svc('cam-3f2a', '门口摄像头',
                svc: 'camera', proto: 'rtsp', can: ['view', 'ptz', 'zoom'])
          ],
        },
      ],
      'incoming': [
        if (liveIn)
          {
            'id': 'in-1',
            'peer': {
              'number': '903552118',
              'name': '张三的电脑',
              'role': null,
              'temp': true,
              'via': 'K7QM-4XPR-9TWD'
            },
            'can': _desk,
            'allowed': ['view', 'control'],
            'since': t - 252,
          }
      ],
      'outgoing': [
        if (liveOut)
          {
            'id': 'out-1',
            'peer': {'number': '528316774', 'name': '家里的台式机'},
            'res': 'desktop',
            'since': t - 600,
            'path': 'p2p',
            'rtt_ms': 18,
          }
      ],
      'quota': {'used': 146 << 20, 'limit': 200 << 20},
    });
  }

  @override
  Future<void> assistRenew() async {
    calls.add('assistRenew');
    renewed = !renewed;
  }

  @override
  Future<List<NpfRecent>> recent() async => [
        NpfRecent(
            id: '903552118',
            at: DateTime(_now.year, _now.month, _now.day - 1, 20, 14)
                    .millisecondsSinceEpoch ~/
                1000),
      ];

  @override
  Future<void> connect(BuildContext context, String text) async =>
      calls.add('connect $text');

  @override
  Future<void> connectPeer(BuildContext context, NpfPeer peer,
          {NpfAction action = NpfAction.desktop, NpfService? service}) async =>
      calls.add('connectPeer ${peer.number} ${action.name} ${service?.res}');

  @override
  Future<void> disconnectIncoming(String id) async {
    calls.add('disconnectIncoming $id');
    liveIn = false;
    changed();
  }

  @override
  Future<void> endOutgoing(String id) async {
    calls.add('endOutgoing $id');
    liveOut = false;
    changed();
  }

  @override
  Future<void> showOutgoing(String id) async => calls.add('showOutgoing $id');

  // ---- sharing

  late List<Map<String, dynamic>> _resources = [
    {
      'name': 'desktop',
      'title': '远程桌面',
      'type': 'desktop',
      'svc': '',
      'access': 'all',
      'state': 'on',
      'caps': _desk
    },
    {
      'name': 'cam-3f2a',
      'title': '门口摄像头',
      'type': 'camera',
      'svc': '海康 · ONVIF',
      'access': 'all',
      'state': 'on',
      'caps': ['view', 'ptz', 'zoom', 'talk']
    },
    {
      'name': 'cam-91c0',
      'title': '客厅摄像头',
      'type': 'camera',
      'svc': '小米 · RTSP',
      'access': 'admin',
      'state': 'admin_only',
      'caps': ['view', 'ptz', 'zoom', 'talk'],
      'new': true
    },
    {
      'name': 'dl',
      'title': '下载文件夹',
      'type': 'folder',
      'svc': 'D:\\下载 · 只读',
      'access': 'all',
      'state': 'on',
      'caps': <String>[]
    },
    {
      'name': 'web3000',
      'title': '测试网页',
      'type': 'web',
      'svc': '本机 3000 端口',
      'access': 'all',
      'state': 'on',
      'caps': <String>[]
    },
  ];

  late List<Map<String, dynamic>> _members = [
    {
      'id': 1786300000,
      'account': '3156',
      'login': 'zh***@example.com',
      'role': 'admin',
      'since': _t - 90 * 86400,
      'until': null,
      'scope': null,
      'online': true,
      'using': <String>[]
    },
    {
      'id': 1793700000,
      'account': '2087',
      'login': 'li***@qq.com',
      'label': '李四',
      'role': 'member',
      'since': _t - 5 * 86400,
      'until': null,
      'scope': _liScope,
      'online': true,
      'using': ['desktop'],
    },
    {
      'id': 1793270000,
      'account': '2311',
      'login': '139****0021',
      'label': '王五',
      'role': 'member',
      'since': _t - 11 * 86400,
      'until': _t + 30 * 86400,
      'scope': [
        {
          'res': 'cam-3f2a',
          'can': ['view', 'ptz', 'zoom']
        },
        {'res': 'web3000', 'can': <String>[]},
      ],
      'online': false,
      'using': <String>[],
    },
    {
      'id': 1780000000,
      'machine': true,
      'key': 'q0Zt3cX9mVb2LrPw8yHn4kEaUs6JdGfT1oIxCvBz5Q8',
      'fp': '7f3a9c21d0e45b86',
      'label': '出口路由器',
      'role': 'member',
      'since': _t - 160 * 86400,
      'until': null,
      'scope': [
        {'res': 'web3000', 'can': <String>[]},
      ],
      'online': false,
      'using': <String>[],
    },
  ];

  static final _liScope = [
    {
      'res': 'desktop',
      'can': ['view', 'control']
    },
    {
      'res': 'cam-3f2a',
      'can': ['view']
    },
    {'res': 'dl', 'can': <String>[]},
  ];

  late List<Map<String, dynamic>> _codes = [
    {
      'locator': 'Q8RT',
      'label': '',
      'uses': 1,
      'expires': _t + 21 * 3600,
      'scope': [
        {
          'res': 'desktop',
          'can': ['view']
        },
        {
          'res': 'cam-3f2a',
          'can': ['view']
        },
      ],
      'member_ttl_s': null,
    }
  ];

  @override
  Future<NpfShareData> shareData() async => NpfShareData.fromJson(jsonDecode(
      jsonEncode(
          {'resources': _resources, 'members': _members, 'codes': _codes})));

  @override
  Future<NpfNewCode> shareNew(
      List<NpfGrant> resources, String label, int? memberTtlS) async {
    calls.add('shareNew $label ${resources.map((g) => g.res).join(',')}');
    _codes = [
      ..._codes,
      {
        'locator': 'H6ZP',
        'label': label,
        'uses': 1,
        'expires': _t + 24 * 3600,
        'scope': resources.map((g) => g.toJson()).toList(),
        'member_ttl_s': memberTtlS,
      }
    ];
    return NpfNewCode('H6ZP-3KTA-8WQC', expires: _t + 24 * 3600, uses: 1);
  }

  @override
  Future<void> memberSet(int id, List<NpfGrant> resources, int? until) async {
    calls.add('memberSet $id');
    _members = _members.map((m) {
      if (m['id'] != id) return m;
      return {
        ...m,
        'scope': resources.map((g) => g.toJson()).toList(),
        'until': until
      };
    }).toList();
  }

  @override
  Future<void> memberRemove(int id) async {
    calls.add('memberRemove $id');
    _members = _members.where((m) => m['id'] != id).toList();
  }

  @override
  Future<void> resourceSet(String name, String access, bool on) async {
    calls.add('resourceSet $name $access $on');
    _resources = _resources
        .map((r) => r['name'] != name
            ? r
            : {
                ...r,
                'access': access,
                'state': !on ? 'off' : (access == 'admin' ? 'admin_only' : 'on')
              })
        .toList();
  }

  @override
  Future<void> shareRevoke(String locator) async {
    calls.add('shareRevoke $locator');
    _codes = _codes.where((c) => c['locator'] != locator).toList();
  }

  // ---- connection manager
  @override
  Future<void> cmApprove(NpfCmClient c, List<String> allowed) async =>
      calls.add('cmApprove ${c.connId} ${allowed.join(',')}');

  @override
  Future<void> cmReject(NpfCmClient c) async => calls.add('cmReject ${c.connId}');

  @override
  Future<void> cmDisconnect(NpfCmClient c) async =>
      calls.add('cmDisconnect ${c.connId}');

  @override
  Future<void> cmChat(NpfCmClient c) async => calls.add('cmChat ${c.connId}');

  @override
  Future<void> cmClose(NpfCmClient c) async => calls.add('cmClose ${c.connId}');

  @override
  Future<void> cmVoiceAnswer(NpfCmClient c, bool accept) async =>
      calls.add('cmVoiceAnswer ${c.connId} $accept');

  @override
  Future<void> cmVoiceEnd(NpfCmClient c) async => calls.add('cmVoiceEnd ${c.connId}');

  @override
  Future<void> signIn(BuildContext context) async => calls.add('signIn');

  @override
  Future<void> openSettings() async => calls.add('openSettings');

  @override
  Future<void> upgradePlan() async => calls.add('upgradePlan');
}
