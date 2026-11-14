import 'dart:async';
import 'dart:convert' as convert;
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RootspaceApp());
}

class VaultService {
  static final VaultService instance = VaultService._init();
  VaultService._init();

  static const String _messagesKey = 'rootspace_messages_store_v4';
  static const String _squareKey = 'rootspace_square_store_v1';
  static const String _contactsKey = 'rootspace_contacts_store_v4';
  static const String _deviceIdKey = 'rootspace_device_id';
  static const String _handleKey = 'rootspace_user_handle';

  Future<String> getDeviceId() async {
    if (kIsWeb) {
      return "Node_${DateTime.now().millisecondsSinceEpoch % 10000}";
    }
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString(_deviceIdKey);
    if (deviceId == null) {
      deviceId = "Device_${DateTime.now().millisecondsSinceEpoch % 10000}";
      await prefs.setString(_deviceIdKey, deviceId);
    }
    return deviceId;
  }

  Future<String> getSovereignHandle() async {
    final prefs = await SharedPreferences.getInstance();
    String? handle = prefs.getString(_handleKey);
    if (handle == null) {
      final randInt = Random().nextInt(0xFFFF);
      final suffix = randInt.toRadixString(16).padLeft(4, '0');
      handle = "@ariko#$suffix";
      await prefs.setString(_handleKey, handle);
    }
    return handle;
  }

  Future<void> saveContact(String peerId, String sovereignHandle) async {
    final prefs = await SharedPreferences.getInstance();
    final rawContacts = prefs.getStringList(_contactsKey) ?? [];

    final contactsMap = <String, String>{};
    for (final contactValue in rawContacts) {
      try {
        final decoded = convert.jsonDecode(contactValue);
        if (decoded is! Map<String, dynamic>) continue;
        final id = decoded['id']?.toString();
        final sovereign = decoded['sovereign']?.toString();
        if (id != null && sovereign != null) {
          contactsMap[id] = sovereign;
        }
      } catch (_) {
        continue;
      }
    }

    contactsMap[peerId] = sovereignHandle;

    final updatedRaw = contactsMap.entries
        .map((entry) => convert.jsonEncode({
              'id': entry.key,
              'sovereign': entry.value,
            }))
        .toList();

    await prefs.setStringList(_contactsKey, updatedRaw);
  }

  Future<List<Map<String, String>>> loadContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final rawContacts = prefs.getStringList(_contactsKey) ?? [];

    final contacts = <Map<String, String>>[];
    for (final item in rawContacts) {
      try {
        final decoded = convert.jsonDecode(item);
        if (decoded is! Map<String, dynamic>) continue;
        final id = decoded['id']?.toString();
        final sovereign = decoded['sovereign']?.toString();
        if (id != null && sovereign != null) {
          contacts.add({'id': id, 'sovereign': sovereign});
        }
      } catch (_) {
        continue;
      }
    }

    return contacts;
  }

  Future<void> saveMessage(String threadKey, Map<String, dynamic> msg) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> history = prefs.getStringList(_messagesKey) ?? [];
    msg["thread_key"] = threadKey;
    history.add(convert.jsonEncode(msg));
    await prefs.setStringList(_messagesKey, history);
  }

  Future<List<Map<String, dynamic>>> loadAllMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList(_messagesKey) ?? [];

    final messages = <Map<String, dynamic>>[];
    for (final item in history) {
      try {
        final decoded = convert.jsonDecode(item);
        if (decoded is! Map<String, dynamic>) continue;
        if (decoded['timestamp'] == null) {
          decoded['timestamp'] = DateTime.now().toIso8601String();
        }
        messages.add(decoded);
      } catch (_) {
        continue;
      }
    }

    return messages;
  }

  Future<void> saveSquareAction(Map<String, dynamic> action) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> squareStore = prefs.getStringList(_squareKey) ?? [];
    squareStore.add(convert.jsonEncode(action));
    await prefs.setStringList(_squareKey, squareStore);
  }

  Future<List<Map<String, dynamic>>> loadSquareActions() async {
    final prefs = await SharedPreferences.getInstance();
    final squareStore = prefs.getStringList(_squareKey) ?? [];

    final actions = <Map<String, dynamic>>[];
    for (final item in squareStore) {
      try {
        final decoded = convert.jsonDecode(item);
        if (decoded is Map<String, dynamic>) {
          actions.add(decoded);
        }
      } catch (_) {
        continue;
      }
    }

    return actions;
  }

  Future<void> clearVault() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_messagesKey);
    await prefs.remove(_squareKey);
    await prefs.remove(_contactsKey);
  }
}

class RootspaceApp extends StatelessWidget {
  const RootspaceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rootspace',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.teal,
        scaffoldBackgroundColor: const Color(0xFF121212),
        cardColor: const Color(0xFF1E1E1E),
      ),
      home: const MainNavigator(),
    );
  }
}

class MainNavigator extends StatefulWidget {
  const MainNavigator({super.key});

  @override
  State<MainNavigator> createState() => _MainNavigatorState();
}

class _MainNavigatorState extends State<MainNavigator> {
  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  bool _isConnected = false;

  String _myDeviceId = "Loading...";
  String _mySovereignHandle = "@loading#0000";

  List<Map<String, String>> _knownContacts = [];
  List<String> _onlinePeerIds = [];
  List<Map<String, dynamic>> _allMessages = [];
  List<Map<String, dynamic>> _squareActions = [];

  String? _activeChatPeerId;
  String? _activeChatPeerHandle;
  bool _isPublicSquareOpen = false;

  String? _generatedPairCode;
  final TextEditingController _pairCodeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initializeNode();
  }

  Future<void> _initializeNode() async {
    _myDeviceId = await VaultService.instance.getDeviceId();
    _mySovereignHandle = await VaultService.instance.getSovereignHandle();
    setState(() {});

    await _loadVaultData();
    _connectWebSocket();
  }

  Future<void> _loadVaultData() async {
    final msgs = await VaultService.instance.loadAllMessages();
    final contacts = await VaultService.instance.loadContacts();
    final square = await VaultService.instance.loadSquareActions();
    setState(() {
      _allMessages = msgs;
      _knownContacts = contacts;
      _squareActions = square;
    });
  }

  String _buildSocketUrl() {
    final host = defaultTargetPlatform == TargetPlatform.android ? '10.0.2.2' : 'localhost';
    final encodedHandle = Uri.encodeComponent(_mySovereignHandle);
    return 'ws://$host:8080/ws?device_id=${Uri.encodeComponent(_myDeviceId)}&sovereign=$encodedHandle';
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        _connectWebSocket();
      }
    });
  }

  Future<void> _connectWebSocket() async {
    try {
      _channel?.sink.close();
      _channel = WebSocketChannel.connect(Uri.parse(_buildSocketUrl()));
      if (!mounted) return;
      setState(() => _isConnected = true);

      _channel!.stream.listen(
        (data) async {
          if (!mounted) return;

          try {
            final decoded = convert.jsonDecode(data);
            if (decoded is! Map<String, dynamic>) return;

            final type = decoded['type'] ?? 'chat';

            if (type == 'peers') {
              final peersList = List<String>.from(decoded['peers'] ?? []);
              final activeIds = <String>[];
              for (final peer in peersList) {
                if (peer.contains('(') && peer.contains(')')) {
                  final id = peer.split(' ').first;
                  final sovereign = peer.substring(peer.indexOf('(') + 1, peer.indexOf(')'));
                  if (id != _myDeviceId) {
                    activeIds.add(id);
                    await VaultService.instance.saveContact(id, sovereign);
                  }
                }
              }

              if (!mounted) return;
              setState(() => _onlinePeerIds = activeIds);
              await _loadVaultData();
              return;
            }

            if (type == 'pair_created') {
              if (!mounted) return;
              setState(() => _generatedPairCode = decoded['code']);
              return;
            }

            if (type == 'pair_success') {
              final matchedId = decoded['sender_id']?.toString();
              final matchedSovereign = decoded['sovereign']?.toString();
              if (matchedId == null || matchedSovereign == null) return;

              await VaultService.instance.saveContact(matchedId, matchedSovereign);
              await _loadVaultData();
              _showSnackBar('⚡ Linked successfully with $matchedSovereign');

              if (!mounted) return;
              Navigator.of(context, rootNavigator: true).pop();
              setState(() {
                _activeChatPeerId = matchedId;
                _activeChatPeerHandle = matchedSovereign;
                _isPublicSquareOpen = false;
                _generatedPairCode = null;
              });
              return;
            }

            if (type == 'pair_error') {
              _showSnackBar('❌ ${decoded['content'] ?? 'Pairing failed'}');
              return;
            }

            if (type == 'square_action') {
              await VaultService.instance.saveSquareAction(decoded);
              await _loadVaultData();
              return;
            }

            final senderId = decoded['sender_id']?.toString() ?? 'Unknown';
            final senderSovereign = decoded['sovereign']?.toString() ?? senderId;

            if (senderId == _myDeviceId || senderId == 'Me') return;

            await VaultService.instance.saveContact(senderId, senderSovereign);

            final msgRecord = {
              'sender_id': senderSovereign,
              'content': decoded['content']?.toString() ?? '',
              'timestamp': DateTime.now().toIso8601String(),
            };

            await VaultService.instance.saveMessage(senderId, msgRecord);
            await _loadVaultData();
          } catch (_) {
            debugPrint('Failed to decode websocket payload');
          }
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _isConnected = false);
          _scheduleReconnect();
        },
        onError: (error) {
          if (!mounted) return;
          setState(() => _isConnected = false);
          debugPrint('Socket error: $error');
          _scheduleReconnect();
        },
      );
    } catch (e) {
      debugPrint('Connection error: $e');
      if (!mounted) return;
      setState(() => _isConnected = false);
      _scheduleReconnect();
    }
  }

  void _sendDirectMessage(String content, String targetId) async {
    if (content.trim().isEmpty || _channel == null) return;

    final timestamp = DateTime.now().toIso8601String();
    final payload = {
      "type": "chat",
      "target_id": targetId,
      "sender_id": _myDeviceId,
      "sovereign": _mySovereignHandle,
      "content": content,
    };

    _channel!.sink.add(convert.jsonEncode(payload));

    final msgRecord = {
      "sender_id": "Me",
      "content": content,
      "timestamp": timestamp,
    };

    await VaultService.instance.saveMessage(targetId, msgRecord);
    await _loadVaultData();
  }

  void _sendSquareAction(Map<String, dynamic> actionPayload) {
    if (_channel == null) return;
    actionPayload["type"] = "square_action";
    actionPayload["sender_id"] = _myDeviceId;
    actionPayload["sovereign"] = _mySovereignHandle;
    actionPayload["timestamp"] = DateTime.now().toIso8601String();

    _channel!.sink.add(convert.jsonEncode(actionPayload));
  }

  void _requestPairCode() {
    if (_channel == null) return;
    _channel!.sink.add(convert.jsonEncode({
      "type": "create_pair_code",
      "sender_id": _myDeviceId,
    }));
  }

  void _submitPairCode(String code) {
    if (code.length != 6 || _channel == null) return;
    _channel!.sink.add(convert.jsonEncode({
      "type": "join_pair_code",
      "sender_id": _myDeviceId,
      "code": code,
    }));
    _pairCodeController.clear();
  }

  void _openPairingDialog() {
    if (!mounted) return;
    _generatedPairCode = null;
    showDialog(
      context: context,
      builder: (context) => StateSetterDialog(
        onRequestPairCode: _requestPairCode,
        onSubmitPairCode: () => _submitPairCode(_pairCodeController.text.trim()),
        pairCodeController: _pairCodeController,
        getPairCode: () => _generatedPairCode,
      ),
    );
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
    );
  }

  Future<void> _clearVaultData() async {
    await VaultService.instance.clearVault();
    await _loadVaultData();
    _showSnackBar("🧹 Local Vault Cleared");
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _pairCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isPublicSquareOpen) {
      return PublicSquareScreen(
        myHandle: _mySovereignHandle,
        squareActions: _squareActions,
        onSendAction: _sendSquareAction,
        onBack: () => setState(() => _isPublicSquareOpen = false),
      );
    }

    if (_activeChatPeerId != null) {
      return ChatRoomScreen(
        title: _activeChatPeerHandle ?? _activeChatPeerId!,
        threadKey: _activeChatPeerId!,
        messages: _allMessages,
        onSendMessage: (content) => _sendDirectMessage(content, _activeChatPeerId!),
        onBack: () => setState(() {
          _activeChatPeerId = null;
          _activeChatPeerHandle = null;
        }),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_mySovereignHandle,
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.tealAccent)),
            Text('Node ID: $_myDeviceId',
                style: const TextStyle(fontSize: 10, color: Colors.white54)),
          ],
        ),
        backgroundColor: const Color(0xFF1F1F1F),
        actions: [
          IconButton(
            icon: const Icon(Icons.phonelink_ring, color: Colors.tealAccent),
            tooltip: 'Pair Remote Peer',
            onPressed: _openPairingDialog,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
            tooltip: 'Clear Vault',
            onPressed: _clearVaultData,
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isConnected ? Colors.green : Colors.red,
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: Colors.teal,
              child: Icon(Icons.public, color: Colors.white),
            ),
            title: const Text("Public Square",
                style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text("Decentralized community feed with votes & reactions"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              setState(() {
                _isPublicSquareOpen = true;
              });
            },
          ),
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text("SECURE CONTACT VAULT",
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.tealAccent,
                    letterSpacing: 1.2)),
          ),
          if (_knownContacts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24.0),
              child: Center(
                child: Text(
                  "No contacts in vault yet.\nPair with a peer or open another tab!",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
            ),
          ..._knownContacts.map((contact) {
            final contactId = contact["id"]!;
            final contactSov = contact["sovereign"]!;
            final isOnline = _onlinePeerIds.contains(contactId);

            final contactMsgs = _allMessages.where((m) => m["thread_key"] == contactId).toList();
            final lastMsg = contactMsgs.isNotEmpty ? contactMsgs.last["content"] : "No messages yet";

            return ListTile(
              leading: Stack(
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.teal.shade800,
                    child: Text(contactSov.isNotEmpty ? contactSov.substring(1, 3).toUpperCase() : "RS",
                        style: const TextStyle(fontSize: 12, color: Colors.white)),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isOnline ? Colors.green : Colors.grey,
                        border: Border.all(color: const Color(0xFF121212), width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              title: Text(contactSov, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(lastMsg, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 13)),
              trailing: const Icon(Icons.chat_bubble_outline, size: 18),
              onTap: () {
                setState(() {
                  _activeChatPeerId = contactId;
                  _activeChatPeerHandle = contactSov;
                });
              },
            );
          }),
        ],
      ),
    );
  }
}

class PublicSquareScreen extends StatefulWidget {
  final String myHandle;
  final List<Map<String, dynamic>> squareActions;
  final ValueChanged<Map<String, dynamic>> onSendAction;
  final VoidCallback onBack;

  const PublicSquareScreen({
    super.key,
    required this.myHandle,
    required this.squareActions,
    required this.onSendAction,
    required this.onBack,
  });

  @override
  State<PublicSquareScreen> createState() => _PublicSquareScreenState();
}

class _PublicSquareScreenState extends State<PublicSquareScreen> {
  final TextEditingController _postController = TextEditingController();

  void _publishPost() {
    final text = _postController.text.trim();
    if (text.isEmpty) return;

    final msgId = "msg_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999)}";
    widget.onSendAction({
      "action": "post",
      "message_id": msgId,
      "content": text,
    });
    _postController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, Map<String, dynamic>> postsMap = {};
    final Map<String, List<Map<String, dynamic>>> repliesMap = {};
    final Map<String, int> votesMap = {};
    final Map<String, List<String>> userVotes = {};
    final Map<String, Map<String, int>> reactionsMap = {};

    for (var act in widget.squareActions) {
      final actionType = act["action"];
      final msgId = act["message_id"];
      if (msgId == null) continue;

      if (actionType == "post") {
        postsMap[msgId] = act;
      } else if (actionType == "reply") {
        repliesMap.putIfAbsent(msgId, () => []).add(act);
      } else if (actionType == "vote") {
        final vType = act["vote_type"];
        final sender = act["sender_id"] ?? "";
        
        userVotes[msgId] ??= [];
        if (!userVotes[msgId]!.contains(sender)) {
          userVotes[msgId]!.add(sender);
          votesMap[msgId] = (votesMap[msgId] ?? 0) + (vType == "upvote" ? 1 : -1);
        }
      } else if (actionType == "reaction") {
        final rType = act["reaction_type"];
        reactionsMap.putIfAbsent(msgId, () => {"like": 0, "super_like": 0, "resonate": 0});
        reactionsMap[msgId]![rType] = (reactionsMap[msgId]![rType] ?? 0) + 1;
      }
    }

    final sortedPosts = postsMap.values.toList()
      ..sort((a, b) => (b["timestamp"] ?? "").compareTo(a["timestamp"] ?? ""));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
        title: const Text("🌐 Public Square (Community Feed)"),
        backgroundColor: const Color(0xFF1F1F1F),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: const Color(0xFF181818),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _postController,
                    decoration: const InputDecoration(
                      hintText: 'Broadcast to Public Square...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                  icon: const Icon(Icons.send, size: 16),
                  label: const Text('Post'),
                  onPressed: _publishPost,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: sortedPosts.isEmpty
                ? const Center(
                    child: Text("Public Square is quiet. Broadcast the first thought!",
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                  )
                : ListView.builder(
                    itemCount: sortedPosts.length,
                    itemBuilder: (context, index) {
                      final post = sortedPosts[index];
                      final msgId = post["message_id"];
                      final author = post["sovereign"] ?? "Anonymous";
                      final content = post["content"] ?? "";
                      final score = votesMap[msgId] ?? 0;
                      final postReplies = repliesMap[msgId] ?? [];
                      final reactions = reactionsMap[msgId] ?? {"like": 0, "super_like": 0, "resonate": 0};

                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        color: const Color(0xFF1E1E1E),
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(author, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.tealAccent, fontSize: 13)),
                                  Text(_formatTime(post["timestamp"]), style: const TextStyle(fontSize: 10, color: Colors.white54)),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(content, style: const TextStyle(fontSize: 16)),
                              const SizedBox(height: 12),
                              const Divider(height: 1, color: Colors.white10),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      IconButton(
                                        icon: const Icon(Icons.arrow_upward, size: 18, color: Colors.greenAccent),
                                        onPressed: () => widget.onSendAction({"action": "vote", "message_id": msgId, "vote_type": "upvote"}),
                                        constraints: const BoxConstraints(),
                                        padding: EdgeInsets.zero,
                                      ),
                                      const SizedBox(width: 4),
                                      Text("$score", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                      const SizedBox(width: 4),
                                      IconButton(
                                        icon: const Icon(Icons.arrow_downward, size: 18, color: Colors.redAccent),
                                        onPressed: () => widget.onSendAction({"action": "vote", "message_id": msgId, "vote_type": "downvote"}),
                                        constraints: const BoxConstraints(),
                                        padding: EdgeInsets.zero,
                                      ),
                                    ],
                                  ),
                                  Row(
                                    children: [
                                      InkWell(
                                        onTap: () => widget.onSendAction({"action": "reaction", "message_id": msgId, "reaction_type": "like"}),
                                        child: Padding(
                                          padding: const EdgeInsets.all(4.0),
                                          child: Row(children: [
                                            const Icon(Icons.favorite, size: 16, color: Colors.pinkAccent),
                                            const SizedBox(width: 2),
                                            Text("${reactions['like']}", style: const TextStyle(fontSize: 12)),
                                          ]),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      InkWell(
                                        onTap: () => widget.onSendAction({"action": "reaction", "message_id": msgId, "reaction_type": "super_like"}),
                                        child: Padding(
                                          padding: const EdgeInsets.all(4.0),
                                          child: Row(children: [
                                            const Icon(Icons.star, size: 16, color: Colors.amberAccent),
                                            const SizedBox(width: 2),
                                            Text("${reactions['super_like']}", style: const TextStyle(fontSize: 12)),
                                          ]),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      InkWell(
                                        onTap: () => widget.onSendAction({"action": "reaction", "message_id": msgId, "reaction_type": "resonate"}),
                                        child: Padding(
                                          padding: const EdgeInsets.all(4.0),
                                          child: Row(children: [
                                            const Icon(Icons.repeat, size: 16, color: Colors.tealAccent),
                                            const SizedBox(width: 2),
                                            Text("${reactions['resonate']}", style: const TextStyle(fontSize: 12)),
                                          ]),
                                        ),
                                      ),
                                    ],
                                  ),
                                  TextButton.icon(
                                    icon: const Icon(Icons.chat_bubble_outline, size: 16),
                                    label: Text("${postReplies.length} Replies"),
                                    onPressed: () => _openThreadModal(context, msgId, post, postReplies),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _openThreadModal(
    BuildContext context,
    String msgId,
    Map<String, dynamic> post,
    List<Map<String, dynamic>> replies,
  ) {
    final TextEditingController replyController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          left: 16,
          right: 16,
          top: 24,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Thread by ${post['sovereign']}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.tealAccent)),
              const SizedBox(height: 6),
              Text(post['content'], style: const TextStyle(fontSize: 15)),
              const Divider(height: 24),
              const Text("Replies & Comments", style: TextStyle(fontSize: 12, color: Colors.white54, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Expanded(
                child: replies.isEmpty
                    ? const Center(child: Text("No comments yet. Start the conversation!", style: TextStyle(color: Colors.white38, fontSize: 12)))
                    : ListView.builder(
                        itemCount: replies.length,
                        itemBuilder: (context, index) {
                          final rep = replies[index];
                          return Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2C2C2C),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(rep["sovereign"] ?? "Anonymous", style: const TextStyle(fontSize: 10, color: Colors.orangeAccent)),
                                const SizedBox(height: 2),
                                Text(rep["content"] ?? "", style: const TextStyle(fontSize: 14)),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: replyController,
                      decoration: const InputDecoration(
                        hintText: 'Write a reply...',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send, color: Colors.teal),
                    onPressed: () {
                      if (replyController.text.trim().isNotEmpty) {
                        widget.onSendAction({
                          "action": "reply",
                          "message_id": msgId,
                          "content": replyController.text.trim(),
                        });
                        replyController.clear();
                        Navigator.pop(context);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(String? isoString) {
    if (isoString == null) return "";
    try {
      final dt = DateTime.parse(isoString);
      return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    } catch (_) {
      return "";
    }
  }
}

class ChatRoomScreen extends StatefulWidget {
  final String title;
  final String threadKey;
  final List<Map<String, dynamic>> messages;
  final ValueChanged<String> onSendMessage;
  final VoidCallback onBack;

  const ChatRoomScreen({
    super.key,
    required this.title,
    required this.threadKey,
    required this.messages,
    required this.onSendMessage,
    required this.onBack,
  });

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final threadMessages =
        widget.messages.where((m) => m["thread_key"] == widget.threadKey).toList();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
        title: Text(widget.title, style: const TextStyle(fontSize: 16)),
        backgroundColor: const Color(0xFF1F1F1F),
      ),
      body: Column(
        children: [
          Expanded(
            child: threadMessages.isEmpty
                ? const Center(
                    child: Text("No direct messages here yet. Say hello!",
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: threadMessages.length,
                    itemBuilder: (context, index) {
                      final msg = threadMessages[index];
                      final sender = msg["sender_id"] ?? "Unknown";
                      final isMe = sender == "Me";

                      String timeStr = "";
                      if (msg["timestamp"] != null) {
                        try {
                          final dt = DateTime.parse(msg["timestamp"]);
                          timeStr = "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
                        } catch (_) {}
                      }

                      return Align(
                        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                          padding: const EdgeInsets.all(12),
                          constraints: BoxConstraints(maxWidth: screenWidth * 0.75, minWidth: 100),
                          decoration: BoxDecoration(
                            color: isMe ? Colors.teal.shade800 : const Color(0xFF2C2C2C),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.max,
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(isMe ? "Me" : sender, style: TextStyle(fontSize: 10, color: isMe ? Colors.teal.shade200 : Colors.orange.shade200)),
                                  if (timeStr.isNotEmpty) ...[
                                    const SizedBox(width: 16),
                                    Text(timeStr, style: const TextStyle(fontSize: 9, color: Colors.white54)),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(msg["content"] ?? "", style: const TextStyle(fontSize: 16)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            color: const Color(0xFF1F1F1F),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _msgController,
                    onSubmitted: (val) {
                      widget.onSendMessage(val);
                      _msgController.clear();
                      _scrollToBottom();
                    },
                    decoration: const InputDecoration(
                      hintText: 'Type a sovereign message...',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.teal),
                  onPressed: () {
                    widget.onSendMessage(_msgController.text);
                    _msgController.clear();
                    _scrollToBottom();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class StateSetterDialog extends StatelessWidget {
  final VoidCallback onRequestPairCode;
  final VoidCallback onSubmitPairCode;
  final TextEditingController pairCodeController;
  final ValueGetter<String?> getPairCode;

  const StateSetterDialog({
    super.key,
    required this.onRequestPairCode,
    required this.onSubmitPairCode,
    required this.pairCodeController,
    required this.getPairCode,
  });

  @override
  Widget build(BuildContext context) {
    return StatefulBuilder(
      builder: (context, setDialogState) {
        final pairCode = getPairCode();
        return AlertDialog(
          title: const Text('Remote 6-Digit Pair Protocol'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Share a temporary 6-digit code with a remote peer to exchange sovereign addresses.',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                icon: const Icon(Icons.key, color: Colors.white),
                label: const Text('Generate 6-Digit Code'),
                onPressed: () {
                  onRequestPairCode();
                  Future.delayed(const Duration(milliseconds: 300), () {
                    setDialogState(() {});
                  });
                },
              ),
              if (pairCode != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.teal.shade900,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    pairCode,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 4,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Text("Tell your remote peer to enter this code.",
                    style: TextStyle(fontSize: 10, color: Colors.white54)),
              ],
              const Divider(height: 32),
              TextField(
                controller: pairCodeController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, letterSpacing: 3),
                decoration: const InputDecoration(
                  labelText: 'Enter Remote Peer Code',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: onSubmitPairCode,
              child: const Text('Connect Peer'),
            ),
          ],
        );
      },
    );
  }
}