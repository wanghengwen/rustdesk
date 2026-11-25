// UI strings of the npf pages: English keys, Simplified Chinese first.
//
// RustDesk's own translations live in Rust (src/lang/*.rs); these pages keep
// their strings here so that they work without touching the Rust tables and
// can be rendered in tests without the native library. [npfTr] falls back to
// the English key when a language has no entry.

import 'package:flutter/widgets.dart';

/// This program's name (ouDesk: the remote desktop of the product ouLink, npf's
/// docs/design/naming.md).
const String kNpfProductName = 'ouDesk';

class NpfLang {
  /// true: Simplified Chinese; false: English. Set by the backend from
  /// RustDesk's language option at start.
  static bool zh = true;
}

/// Translates [key] and fills `{name}` placeholders from [args].
String npfTr(String key, [Map<String, Object?> args = const {}]) {
  var s = NpfLang.zh ? (_zh[key] ?? key) : key;
  args.forEach((k, v) => s = s.replaceAll('{$k}', '${v ?? ''}'));
  return s;
}

/// Like [npfTr], as spans: the placeholders named in [bold] are bold.
List<InlineSpan> npfTrSpans(String key, Map<String, Object?> args,
    {Set<String> bold = const {}, TextStyle? boldStyle}) {
  final s = NpfLang.zh ? (_zh[key] ?? key) : key;
  final spans = <InlineSpan>[];
  final re = RegExp(r'\{(\w+)\}');
  var at = 0;
  for (final m in re.allMatches(s)) {
    if (m.start > at) spans.add(TextSpan(text: s.substring(at, m.start)));
    final name = m.group(1)!;
    final v = '${args[name] ?? ''}';
    spans.add(TextSpan(
        text: v,
        style: bold.contains(name)
            ? (boldStyle ?? const TextStyle(fontWeight: FontWeight.w700))
            : null));
    at = m.end;
  }
  if (at < s.length) spans.add(TextSpan(text: s.substring(at)));
  return spans;
}

/// Every key has a Chinese entry (checked by test/npf/npf_lang_test.dart).
Map<String, String> get npfZhTable => _zh;

const Map<String, String> _zh = {
  // shell
  'Home': '首页',
  'Share': '共享',
  'Settings': '设置',
  'About {name}': '关于 {name}',
  'Today {t}': '今天 {t}',
  'Yesterday {t}': '昨天 {t}',
  'today': '今天',
  'yesterday': '昨天',
  '{d} days ago': '{d} 天前',
  // home: left
  'Let others connect to me': '让别人连我',
  'Tell the helper your assist code': '把协助码告诉帮你的人',
  'Changes automatically in {left}': '{left}后自动更换',
  'Changes soon': '即将更换',
  'Copy': '复制',
  'Copied': '已复制',
  'New code': '换一个',
  'Remote desktop only, your other shares stay hidden':
      '只能远程桌面，看不到你的其他共享',
  'You approve every connection': '每次连接都要你点同意',
  'Let someone use it long-term': '长期让某人使用',
  'Pick what they may use and get an invite code': '选好给他用的东西，生成一个邀请码',
  'Invite someone…': '邀请别人…',
  'Number {number}': '编号 {number}',
  'Online': '在线',
  'Offline': '离线',
  'Connecting to the platform…': '正在连接平台…',
  'Assist codes are off': '协助码已关闭',
  'Turn it on in settings to let a helper connect': '在设置里打开，别人才能用协助码连你',
  'No assist code while offline': '连不上平台，暂时没有协助码',
  'It comes back by itself once the network is back': '网络恢复后会自动出现',
  'This computer has no owner account yet': '这台电脑还没有绑定账户',
  'Sign in to issue assist codes': '登录账户后才能发协助码',
  'Sign in': '登录',
  '{h} h {m} min': '{h} 小时 {m} 分',
  '{h} h': '{h} 小时',
  '{m} min': '{m} 分钟',
  // home: right
  'Connect to others': '我去连别人',
  "Their assist code, invite code or device number": '对方的协助码、邀请码或设备编号',
  'Connect': '连接',
  'This is not an assist code, an invite code or a device number':
      '这不像协助码、邀请码或设备编号',
  'My devices': '我的设备',
  'Shared with me': '共享给我的',
  'Recent': '最近',
  'Devices paired with the pairing password or on the same account: you can use and manage them fully':
      '用配对口令或同一账户下的设备：你能完全使用，也能管理它们',
  'Shared with you by invite code: only what they gave you':
      '别人用邀请码共享给你的：只能用他给你的那几样',
  'Computers you helped with an assist code: cannot be reconnected directly':
      '用协助码帮过别人的记录：不能直接再连',
  'No devices yet: pair one with its pairing password, or sign in on both':
      '还没有设备：用配对口令配对，或者两台都登录同一账户',
  'Nothing shared with you yet: ask the owner for an invite code and type it above':
      '还没有人共享给你：找对方要一个邀请码，填在上面',
  'Nothing yet': '还没有记录',
  'My device': '我的设备',
  'Shared with you': '共享给你',
  'Shared with you · {caps}': '共享给你 · {caps}',
  'until {date}': '到 {date}',
  'The share has expired, ask them for a new code': '共享已到期，找他要新码',
  'Good': '很好',
  'Fair': '一般',
  'Poor': '较差',
  'direct': '直连',
  'via server': '经服务器',
  '{q} · {path} {rtt} ms': '{q} · {path} {rtt} ms',
  '{q} · {path}': '{q} · {path}',
  'Remote desktop': '远程桌面',
  'Files': '文件',
  'Terminal': '终端',
  'Open {title}': '打开 {title}',
  'View camera': '看画面',
  'More actions': '更多操作',
  'Copy device number': '复制设备编号',
  'Port forwarding': '端口转发',
  'Not running': '没有运行',
  'Needs a new assist code to connect again': '要新的协助码才能再连',
  'An assist code is good for that one time only': '协助码只管那一次',
  'Helped with an assist code': '用协助码帮过',
  // top bars
  '{name} is controlling this computer': '{name} 正在控制这台电脑',
  'by assist code': '用的是协助码',
  'invited': '被邀请的人',
  'my device': '我的设备',
  'Disconnect': '断开',
  'Connected to the remote desktop of {name}': '正在连接 {name} 的远程桌面',
  'Connected to {res} of {name}': '正在连接 {name} 的{res}',
  'Back to the window': '回到窗口',
  'End': '结束',
  // share page
  'Who this computer is shared with, and what': '这台电脑共享给谁、共享了什么',
  '{name} · click a cell to pick what they may use; changes apply at once':
      '{name} · 点格子选他能用哪些功能；改了马上生效',
  'By service': '按服务',
  'By person': '按人',
  'Shared services': '共享的服务',
  'Owner and admins': '所有者与管理员',
  'Can use everything': '什么都能用',
  'Account {id}': '账户 {id}',
  'Assist code': '协助码',
  'Temporary · nobody now': '临时 · 现在没人',
  'Temporary · in use': '临时 · 正在用',
  'My devices only': '只给我的设备',
  'All': '全部',
  'None': '不给',
  'Can use': '能用',
  'Pick when connecting': '连接时选',
  'Using {res}': '正在用{res}',
  'New': '新',
  'Just installed · my devices only for now': '刚装好 · 先只给我的设备',
  'Unused invite codes': '还没用掉的邀请码',
  'No unused invite codes': '没有还没用掉的邀请码',
  'Revoke': '作废',
  'for {n} person/people': '给 {n} 人',
  '{left} left': '还剩 {left}',
  '{d} d': '{d} 天',
  '<b>Owner and admins</b>: can use everything and manage this computer':
      '<b>所有者与管理员</b>：什么都能用，还能管理这台电脑',
  '<b>Invited people</b>: only the features ticked in their cells; <g>●</g> means in use':
      '<b>被邀请的人</b>：只能用格子里给的功能；<g>●</g> 表示正在用',
  '<b>Assist code</b>: remote desktop only, one connection; you pick the features when you approve':
      '<b>协助码</b>：只有远程桌面，只管一次连接，你点同意时再选功能',
  '<b>New</b>: a service just installed, my devices only until you decide':
      '<b>新</b>：刚装好的服务，先只给我的设备，你决定给谁',
  '{name} may use which features of {res}': '{name}能用{res}的哪些功能',
  '{name} · {res}': '{name} · {res}',
  'In use · removing a feature ends this connection': '正在用 · 去掉功能会断开他这次连接',
  'Changes apply at once': '改了马上生效',
  'Note: {note}': '注意：{note}',
  '"{base}" is the base: without it nothing else works.':
      '「{base}」是基础：不给它，其余的也用不了。',
  'Done': '完成',
  'This ends the connection of {name}': '会断开{name}这次连接',
  '{name} is using {res}. Without "{caps}" this connection ends; after reconnecting the new permissions apply.':
      '{name}正在用{res}。去掉「{caps}」后，他这次连接会断开，重新连上后按新的权限使用。',
  '{name} is using {res}. With "my devices only" the connection ends at once and the service disappears for them.':
      '{name}正在用{res}。改成只给我的设备后，他会马上断开，也看不到这项服务了。',
  'End and change': '断开并修改',
  'Not now': '先不改',
  '{name}: {notes}': '{name}{notes}',
  // by person
  'Temporary · remote desktop only': '临时 · 只有远程桌面',
  'Everything · {n} admin(s)': '什么都能用 · {n} 个管理员',
  'Configured peers': '配置的对端',
  'Machine to machine · {n}': '机器对机器 · {n} 个',
  'The owner is the account logged in on this computer; admins are accounts that gave its pairing password. From any of their computers and phones they can use everything and manage this computer.':
      '所有者是登录在这台电脑上的账户；管理员是填过它的配对口令的账户。他们在自己的任何一台电脑、手机上都能使用全部服务，还能管理这台电脑。',
  "No admins. To add one, let them type this computer's number and pairing password on their own computer or phone.":
      '还没有管理员。要加一个，让他在自己的电脑或手机上输入这台电脑的编号和配对口令。',
  'Machine to machine: devices paired by key (an exit router, another NAS, a node set up at start), not people.':
      '机器对机器：按密钥配对的设备（出口路由器、另一台 NAS、启动时配置的节点），不是人。',
  'Paired {date}': '{date}配对',
  'Joined {date}': '{date}加入',
  'What {name} may use': '{name} 能用什么',
  'Invite code · joined {date}': '邀请码 · {date}加入',
  'Remove {name}': '移除{name}',
  'How long': '能用多久',
  'Until {date}, then removed automatically': '到 {date}，之后自动移除',
  'Always, until you remove them': '一直，直到你移除他',
  'Always': '一直',
  '30 days': '30 天',
  '7 days': '7 天',
  '30 days from today': '从今天起 30 天',
  '7 days from today': '从今天起 7 天',
  'In use': '正在用',
  'This is kept with their account: they connect from any of their computers and phones, a new one needs no new code.':
      '这些记在他的账户上：他在自己的任何一台电脑、手机上都能连接，换了新手机也不用再发码。',
  'Temporary code · a new one every 2 hours · one connection only, no member stays':
      '临时码 · 每 2 小时换新 · 只管当次连接，不会留下成员',
  'Remote desktop only. Every time someone connects with the assist code you pick what they get this time (view, control, files, terminal).':
      '只能用远程桌面。每次有人用协助码连上来，你点同意时选这次给他哪些功能（看屏幕、控制、传文件、终端）。',
  'After disconnecting they need a new assist code to connect again.':
      '断开以后，对方要新的协助码才能再连。',
  'Remove {name}?': '移除{name}？',
  'None of their computers and phones can connect to this computer any more{live}. Then they cannot use any service of this computer; to share again, invite them again.':
      '他的所有电脑和手机都不再能连接这台电脑{live}。之后他用不了这台电脑的任何服务，要再给他用得重新邀请。',
  ', {res} in use ends at once': '，正在用的{res}会马上断开',
  'They are using it and are disconnected at once. ': '他正在使用，会马上断开。',
  'This configured peer can no longer connect to this computer; it must pair again.':
      '这个配置的对端不再能连接这台电脑；要再连得重新配对。',
  'An admin (gave the pairing password): none of their computers and phones can connect to or manage this computer any more. If they still know the pairing password they can come back; change it if needed.':
      '他是管理员（填过配对口令）：移除后他的所有电脑和手机都不再能连接和管理这台电脑。他还知道配对口令的话可以再加回来，必要时换一个口令。',
  "Removed on this computer; their account's list is updated once it reaches the server":
      '已在这台电脑上移除；连上服务器后，他账户里的列表才会更新',
  'Remove': '移除',
  // invite
  'Invite someone · what they may use': '邀请别人 · 给他用什么',
  'For whom': '给谁',
  'e.g. Zhao Liu (only you see it, to tell people apart)': '比如：赵六（只有你看得到，用来认人）',
  'My devices only, cannot be shared': '只给我的设备，不能邀请',
  'How long they may use it': '他能用多久',
  'A picked service is view-only by default; light up more features to give more. "How long" counts from the day they connect and removes them automatically, e.g. 30 days for a contractor.':
      '选了服务默认只能看，要多给就点亮后面的功能。「他能用多久」从他连上那天算，到期自动移除，比如给装修师傅 30 天。',
  'Cancel': '取消',
  'Create invite code': '生成邀请码',
  'Send the invite code to them': '把邀请码发给对方',
  'May use: {what}': '能用：{what}',
  '(nothing picked)': '（什么都没选）',
  '(nothing)': '（什么都没有）',
  'Logged in to their account, they type it in "Connect to others" on their computer or phone':
      '对方登录账户后，在自己电脑或手机的「我去连别人」里输入它',
  'This code is shown only once; after closing the full code cannot be seen again.':
      '这个码只显示这一次，关掉后看不到完整的码。',
  'Valid for {left} · {uses} use(s)': '{left}内有效 · 能用 {uses} 次',
  'Valid for {left} · void after one use': '{left}内有效 · 1 人用过就作废',
  'they may use it always': '他一直能用',
  'they may use it for {d} days after connecting': '他连上后能用 {d} 天',
  'Creating…': '正在生成…',
  'Failed: {err}': '没有成功：{err}',
  'Not available yet': '暂不可用',
  // features
  'view': '看',
  'control': '控制',
  'file': '传文件',
  'terminal': '终端',
  'ptz': '云台',
  'zoom': '变焦',
  'talk': '对讲',
  'View screen': '看屏幕',
  'Control keyboard and mouse': '控制键盘鼠标',
  'Transfer files': '传文件',
  'View and listen': '看画面、听声音',
  'Turn the camera': '转动云台',
  'Zoom': '变焦',
  'Talk': '对讲',
  'View only, no input': '只能看，不能动',
  'Includes the clipboard': '还包括剪贴板',
  'Can send and receive files on your computer': '能在你电脑上收发文件',
  'Can run commands on your computer': '能在你电脑上执行命令',
  'Live picture': '直播画面',
  'Up, down, left, right, presets': '上下左右转、转到预置位',
  'Closer, farther': '拉近、拉远',
  'Can speak into your home through the camera': '能通过摄像头对家里说话',
  'This screen': '这台电脑的屏幕',
  // incoming (CM)
  '{name} wants to connect to this computer': '{name} 想连接这台电脑',
  '{name} wants to transfer files with this computer': '{name} 想和这台电脑传文件',
  '{name} wants to open a terminal on this computer': '{name} 想打开这台电脑的终端',
  '{name} wants to view the camera of this computer': '{name} 想看这台电脑的摄像头',
  '{name} wants to use port forwarding on this computer': '{name} 想用这台电脑的端口转发',
  'Assist code {code} · temporary, this time only': '用协助码 {code} · 临时，只管这一次',
  'Assist code · temporary, this time only': '用协助码 · 临时，只管这一次',
  'Invited person · joined {date}': '被邀请的人 · {date}加入',
  'Invited person': '被邀请的人',
  'Owner or admin of this computer · may use everything':
      '这台电脑的所有者或管理员 · 什么都能用',
  'With the assist code they may use all of remote desktop; you decide now what to give':
      '协助码能用远程桌面的全部功能，由你这次决定给哪些',
  'What you gave them on the share page: {caps}': '你在共享页给他的：{caps}',
  'Allow this time': '这次允许',
  'You did not give it': '你没给他',
  'Always on': '总是有',
  'Files and terminal start unticked; give them when needed.': '传文件、终端默认不勾，需要时再给。',
  'Only less than on the share page; to give more, change the share page.':
      '这里只能比共享页给的少；要多给，去共享页改。',
  'Rejected automatically in {s} s': '{s} 秒后自动拒绝',
  'Reject': '拒绝',
  'Accept': '同意',
  'Being controlled': '正在被控制',
  'Assist code · needs a new code to connect again': '协助码 · 断开后要新码才能再连',
  'Invited person · you accepted': '被邀请的人 · 你点了同意',
  'Allowed this time: {caps}': '这次能：{caps}',
  'Chat': '聊天',
  'Voice call request': '语音通话请求',
  'Answer': '接听',
  'In a voice call': '语音通话中',
  'Hang up': '挂断',
  'Disconnected': '已断开',
  'Close': '关闭',
  // session quality
  'Connection quality': '连接质量',
  'Direct (peer to peer)': '直连（点对点）',
  'Relay (via the platform server)': '中转（经平台服务器）',
  'Relay (via the platform server, WebSocket)': '中转（经平台服务器，WebSocket）',
  'Round trip': '往返时间',
  'Bitrate': '码率',
  'Frame loss': '丢帧',
  'Frame rate': '帧率',
  'Codec': '编码',
  'The two computers are connected directly, without a server and without counting traffic. When the network gets worse only late frames are dropped, nothing stalls, and the picture gets less sharp.':
      '两台电脑直接相连，不经服务器，也不计流量。网络变差时只丢迟到的画面、不卡住，并自动降低清晰度。',
  'Without a direct path the platform relays the traffic, still end-to-end encrypted. Relay traffic counts against your account; it switches back once direct works again.':
      '打不通直连时经平台中转，端到端加密不变。中转流量记在你的账户上；直连恢复后自动切回。',
  'Relay quota this month': '本月中转额度',
  'Upgrade plan': '升级套餐',
  'Their network does not allow a direct connection; relayed, the picture is less sharp to stay smooth.':
      '对方网络不允许直连，已改走中转，画面清晰度自动降低以保持流畅。',
  'View quota': '查看额度',
  'Measuring…': '正在测量…',
  // states
  'Waiting for them to accept': '等待对方同意',
  'Connected to {name}, waiting for them to click "Accept". Cancelled automatically if they do not answer within 30 seconds.':
      '已连上{name}，正在等对方点「同意」。对方 30 秒内没有回应会自动取消。',
  'No direct path; sign in to use the relay': '无法直连，登录后可经中转',
  'Neither network allows a direct connection. After signing in the platform can relay it, still end-to-end encrypted.':
      '你和对方的网络都不允许直接相连。登录账户后可以经平台中转，端到端加密不变。',
  'Try again': '再试一次',
  'Relay quota used up this month': '本月中转额度已用完',
  'This connection needs the relay and this month\'s {limit} are used up. Upgrade, or wait until one side changes network and can connect directly.':
      '这次连接需要中转，本月 {limit} 已用完。升级套餐，或等对方换个网络后直连。',
  'View usage': '查看用量',
  'They are offline': '对方离线',
  '{name} is offline. It shows as online again once it is on and connected.':
      '{name}离线了。对方开机联网后会自动出现在线状态。',
  'OK': '好的',
  'Wrong or expired assist code': '协助码不对或已过期',
  'Assist codes change every 2 hours and are valid for 4. Ask them for the latest code on the left of their main window.':
      '协助码每 2 小时换新、4 小时内有效。请对方看一下主窗口左侧最新的码。',
  'Type again': '重新输入',
  'They rejected the connection': '对方拒绝了连接',
  'They clicked "Reject", or turned remote access off.': '对方点了「拒绝」，或者关闭了远程访问。',
  'The share has expired': '共享已到期',
  'What they shared with you has expired. Ask them for a new invite code.':
      '对方共享给你的已经到期。找他要一个新的邀请码。',
  'Not shared with you': '对方没有共享给你',
  'Log in to an account first': '先登录账户',
  'This computer or phone is not logged in to an account, so it cannot connect to other devices. Log in, then try again.':
      '这台电脑或手机还没有登录账户，不能去连别的设备。登录后再试一次。',
  'They did not give you this feature. Ask them to change it on their share page.':
      '对方没有给你这项功能。可以请他在共享页里改。',
  'the other computer': '对方',
  // the session toolbar and its panels (npf_desk_ui.dart, remote_toolbar_npf.dart)
  'Control': '控制',
  'Picture': '画面',
  'Tools': '工具',
  'Auto': '自动',
  'Sharp': '清晰',
  'Smooth': '流畅',
  'Custom': '自定义',
  'Balanced': '均衡',
  'Office': '办公',
  'HD': '高清',
  'Game': '游戏',
  'Documents and help: a balanced picture at 30 frames, the least traffic.':
      '文档、表格、远程协助：均衡画质，30 帧，最省流量。',
  'Pictures, design and video: the sharpest picture at 60 frames.':
      '看图、设计、看视频：最清晰的画质，60 帧。',
  'The least delay: a smooth picture at 60 frames.': '跟手优先：流畅画质，60 帧，延迟最低。',
  'Your own quality, frame rate and codec.': '画质、帧率、编码是你自己设的。',
  '{n} fps': '{n} 帧',
  'Recording': '录制中',
  'Calling': '呼叫中',
  'In a call': '通话中',
  'Privacy screen': '隐私屏',
  'Their input is blocked': '已禁止对方操作',
  'View only': '只看不控',
  'Refresh picture': '刷新画面',
  'Screenshot': '截图',
  'Show desktop': '显示桌面',
  'Lock screen': '锁定屏幕',
  'Mission Control': '调度中心',
  'Spotlight': '聚焦搜索',
  'Activities': '活动视图',
  'Lock': '锁定电脑',
  'Task view': '任务视图',
  'Sync the clipboard': '同步剪贴板',
  'Scale': '缩放',
  'When the picture is larger than the window': '画面比窗口大时',
  'Mode · custom': '模式 · 自定义',
  'Mode': '模式',
  'Input source': '输入来源',
  'Calling… click to cancel': '正在呼叫…点这里取消',
  'In a call · click to hang up': '通话中 · 点这里挂断',
  'Microphone': '麦克风',
  'Record the session': '录制会话',
  "Play the computer's sound": '播放对方电脑的声音',
  'Recording · click to stop': '录制中 · 点这里停止',
  'This computer': '对这台电脑',
  'Type the password': '输入系统密码',
  'Change the saved password': '改保存的系统密码',
  'Block their keyboard and mouse': '屏蔽对方的键盘和鼠标',
  'The person at the computer cannot use it meanwhile': '这期间电脑前的人动不了它',
  'Lock it when the session ends': '结束时锁定电脑',
  'The computer goes back to its lock screen': '断开后电脑回到锁屏',
  'My mouse': '我的鼠标',
  'Only the picture: my mouse and keyboard are not sent': '只看画面，我的鼠标和键盘不发过去',
  'How my keyboard is sent': '我的键盘怎么发过去',
  'Map': '映射',
  'Translate': '翻译',
  'Legacy': '传统',
  'Map: a key is the key at the same place. For shortcuts and games.':
      '映射：按键按位置对应，适合快捷键和游戏。',
  'Translate: the characters typed are sent. For keyboards of different layouts.':
      '翻译：发送打出来的字符，适合两边键盘布局不同。',
  'Legacy: the old way, when the other two fail.': '传统：老方式，前两种不好用时再试。',
  'Quality': '画质',
  'Small text and thin lines are clearer. With VP9 or AV1 only':
      '小字和细线更清楚，只在 VP9、AV1 下可用',
  'Screens': '屏幕',
  'Screen {n}': '屏幕 {n}',
  'Virtual screens': '虚拟屏',
  'Screens the computer does not really have': '给电脑加几块它没有的屏幕',
  'Each screen in its own window': '多屏分开显示',
  'A number above opens that screen in a window of its own':
      '点上面的数字，那块屏幕在自己的窗口里打开',
  'For when this side has several monitors too': '我这边也有多个显示器时用',
  'Not with all the screens shown: choose one first': '看全部屏幕时不能用，先选一块屏幕',
  'Their screen goes dark: nobody there sees what I do': '对方屏幕变黑，那边的人看不到我在做什么',
  'The person at the computer': '和电脑前的人',
  'Call': '呼叫',
  'Connects once they accept': '对方接听后接通',
  'Speaker': '扬声器',
  'As the system': '跟随系统',
  'A record': '记录',
  'A video of this session, kept on this computer': '把这次会话录成视频，存在这台电脑上',
  'Their screen as it is now, to copy or save': '对方屏幕现在的样子，可以复制或保存',
  'Sound and clipboard': '声音和剪贴板',
  'Text copied on one side pastes on the other': '一边复制的文字，另一边可以粘贴',
  'Copy files on one side, paste them on the other': '一边复制文件，另一边粘贴',
};
