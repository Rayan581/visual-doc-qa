import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

void main() {
  runApp(const DocChatApp());
}

// ─── Color System ────────────────────────────────────────────────────────────
class C {
  static const bg0      = Color(0xFF0C0D0F); // deepest background
  static const bg1      = Color(0xFF111318); // panel background
  static const bg2      = Color(0xFF181C23); // elevated surface
  static const bg3      = Color(0xFF1F242E); // card / input surface
  static const border   = Color(0xFF2A3040); // subtle border
  static const borderHi = Color(0xFF3D4860); // hover border

  static const amber    = Color(0xFFD4943A); // primary accent
  static const amberLo  = Color(0x22D4943A); // amber fill low opacity
  static const amberMid = Color(0x55D4943A);

  static const text0    = Color(0xFFE8E4DC); // primary text — warm white
  static const text1    = Color(0xFFAAA49A); // secondary text
  static const text2    = Color(0xFF6B6760); // muted text

  static const green    = Color(0xFF4CAF7D); // success
  static const red      = Color(0xFFD44B3A); // error
  static const blue     = Color(0xFF4A7EC7); // info

  static const scanLine = Color(0x06FFFFFF); // CRT scan-line overlay
}

// ─── Text Styles ─────────────────────────────────────────────────────────────
class TS {
  static const mono = TextStyle(fontFamily: 'monospace');

  static TextStyle label({double size = 11, Color color = C.text2, FontWeight fw = FontWeight.w500}) =>
      TextStyle(fontFamily: 'monospace', fontSize: size, color: color, fontWeight: fw, letterSpacing: 1.2);

  static TextStyle body({double size = 13.5, Color color = C.text0}) =>
      TextStyle(fontFamily: 'monospace', fontSize: size, color: color, height: 1.65);

  static TextStyle heading({double size = 15, Color color = C.text0}) =>
      TextStyle(fontFamily: 'monospace', fontSize: size, color: color, fontWeight: FontWeight.w600, letterSpacing: 0.3);
}

// ─── Data ────────────────────────────────────────────────────────────────────
enum MsgRole { user, assistant, system }

class ChatMsg {
  final MsgRole  role;
  final String   text;
  final int?     page;
  final int?     totalPages;
  final String?  strategy;
  final double?  inferenceTime;
  final DateTime time;

  ChatMsg({
    required this.role,
    required this.text,
    this.page,
    this.totalPages,
    this.strategy,
    this.inferenceTime,
  }) : time = DateTime.now();
}

// ─── App Root ────────────────────────────────────────────────────────────────
class DocChatApp extends StatelessWidget {
  const DocChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DocChat — Document Intelligence',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: C.bg0,
        colorScheme: const ColorScheme.dark(primary: C.amber, surface: C.bg1),
        scrollbarTheme: ScrollbarThemeData(
          thumbColor: WidgetStateProperty.all(C.border),
          radius: const Radius.circular(4),
          thickness: WidgetStateProperty.all(4),
        ),
      ),
      home: const MainShell(),
    );
  }
}

// ─── Main Shell (split layout) ───────────────────────────────────────────────
class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with TickerProviderStateMixin {
  static const _backend = 'http://127.0.0.1:8000';

  // State
  final List<ChatMsg>         _msgs        = [];
  final TextEditingController _q           = TextEditingController();
  final ScrollController      _scroll      = ScrollController();
  final FocusNode             _focus       = FocusNode();

  Uint8List? _fileBytes;
  String?    _fileName;
  int?       _fileSize;
  bool     _online    = false;
  bool     _loading   = false;
  String   _strategy  = 'smart';
  String?  _device;
  bool     _pdfSupport = false;

  // Animations
  late AnimationController _pulseCtrl;
  late Animation<double>   _pulseAnim;
  late AnimationController _scanCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.4, end: 1.0).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _scanCtrl  = AnimationController(vsync: this, duration: const Duration(seconds: 8))..repeat();
    _checkBackend();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _scanCtrl.dispose();
    _q.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ── Backend health ──────────────────────────────────────────────────────
  Future<void> _checkBackend() async {
    try {
      final r = await http.get(Uri.parse('$_backend/health')).timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        setState(() {
          _online     = j['status'] == 'ok';
          _device     = j['device'] as String?;
          _pdfSupport = j['pdf_support'] as bool? ?? false;
        });
      } else {
        setState(() => _online = false);
      }
    } catch (_) {
      setState(() => _online = false);
    }
  }

  // ── File pick ───────────────────────────────────────────────────────────
  Future<void> _pickFile() async {
    final extensions = ['png', 'jpg', 'jpeg', 'tiff', 'bmp', 'webp'];
    if (_pdfSupport) extensions.insert(0, 'pdf');

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final pickedFile = result.files.first;
    Uint8List? bytes = pickedFile.bytes;

    if (bytes == null && pickedFile.path != null) {
      bytes = await File(pickedFile.path!).readAsBytes();
    }

    if (bytes == null) {
      _addSys('Failed to load file content.');
      return;
    }

    setState(() {
      _fileBytes = bytes;
      _fileName  = pickedFile.name;
      _fileSize  = pickedFile.size;
    });

    _addSys('Document loaded: $_fileName  (${_fmtBytes(pickedFile.size)})');
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)}KB';
    return '${(b / 1048576).toStringAsFixed(1)}MB';
  }

  // ── Send query ──────────────────────────────────────────────────────────
  Future<void> _send() async {
    final q = _q.text.trim();
    if (q.isEmpty || _loading) return;

    if (_fileBytes == null) {
      _addSys('No document loaded. Upload a document to begin analysis.');
      return;
    }
    if (!_online) {
      _addSys('Backend offline. Start the server:  python backend.py');
      return;
    }

    _q.clear();
    _addMsg(ChatMsg(role: MsgRole.user, text: q));
    setState(() => _loading = true);

    try {
      final req = http.MultipartRequest('POST', Uri.parse('$_backend/ask'));
      req.fields['question'] = q;
      req.fields['strategy'] = _strategy;
      req.files.add(http.MultipartFile.fromBytes(
        'file',
        _fileBytes!,
        filename: _fileName,
      ));

      final streamed = await req.send().timeout(const Duration(seconds: 300));
      final body     = await streamed.stream.bytesToString();

      if (streamed.statusCode == 200) {
        final j = jsonDecode(body) as Map<String, dynamic>;
        _addMsg(ChatMsg(
          role:          MsgRole.assistant,
          text:          j['answer'] as String? ?? 'No answer returned.',
          page:          j['page'] as int?,
          totalPages:    j['total_pages'] as int?,
          strategy:      j['strategy'] as String?,
          inferenceTime: (j['inference_time'] as num?)?.toDouble(),
        ));
      } else {
        final detail = _parseErr(body);
        _addSys('Error: $detail');
      }
    } on SocketException {
      _addSys('Cannot reach backend. Is it running?');
    } catch (e) {
      _addSys('Error: $e');
    } finally {
      setState(() => _loading = false);
      _focus.requestFocus();
    }
  }

  String _parseErr(String body) {
    try { return (jsonDecode(body) as Map)['detail']?.toString() ?? body; }
    catch (_) { return body; }
  }

  void _addSys(String text) => _addMsg(ChatMsg(role: MsgRole.system, text: text));

  void _addMsg(ChatMsg msg) {
    setState(() => _msgs.add(msg));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
      }
    });
  }

  // ── Build ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg0,
      body: Column(children: [
        _TopBar(
          online:     _online,
          device:     _device,
          strategy:   _strategy,
          loading:    _loading,
          pulseAnim:  _pulseAnim,
          onRecheck:  _checkBackend,
          onStrategy: (s) => setState(() => _strategy = s),
        ),
        Expanded(
          child: Row(children: [
            // ── Left: document panel
            _DocumentPanel(
              hasFile:    _fileBytes != null,
              fileName:   _fileName,
              fileSize:   _fileSize,
              pdfSupport: _pdfSupport,
              online:     _online,
              onPick:     _pickFile,
              onClear:    () => setState(() { _fileBytes = _fileName = _fileSize = null; }),
            ),
            // ── Divider
            Container(width: 1, color: C.border),
            // ── Right: query terminal
            Expanded(
              flex: 3,
              child: _QueryTerminal(
                msgs:      _msgs,
                scroll:    _scroll,
                qCtrl:     _q,
                focus:     _focus,
                loading:   _loading,
                hasFile:   _fileBytes != null,
                onSend:    _send,
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ─── Top Bar ─────────────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final bool              online;
  final String?           device;
  final String            strategy;
  final bool              loading;
  final Animation<double> pulseAnim;
  final VoidCallback      onRecheck;
  final ValueChanged<String> onStrategy;

  const _TopBar({
    required this.online,
    required this.device,
    required this.strategy,
    required this.loading,
    required this.pulseAnim,
    required this.onRecheck,
    required this.onStrategy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: C.bg1,
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(children: [
        // Logo mark
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            border: Border.all(color: C.amber, width: 1.5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Icon(Icons.document_scanner_outlined, color: C.amber, size: 16),
        ),
        const SizedBox(width: 12),
        Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('DOCCHAT', style: TS.label(size: 12, color: C.amber, fw: FontWeight.w700)),
          Text('DOCUMENT INTELLIGENCE', style: TS.label(size: 9, color: C.text2)),
        ]),

        const SizedBox(width: 32),
        // Strategy selector
        _StrategyToggle(strategy: strategy, onChanged: onStrategy, loading: loading),

        const Spacer(),

        // Device badge
        if (device != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: C.bg3, borderRadius: BorderRadius.circular(4), border: Border.all(color: C.border)),
            child: Row(children: [
              Icon(device == 'cuda' ? Icons.memory : Icons.computer, size: 11, color: C.text2),
              const SizedBox(width: 5),
              Text(device!.toUpperCase(), style: TS.label(size: 10, color: C.text2)),
            ]),
          ),
          const SizedBox(width: 10),
        ],

        // Status indicator
        GestureDetector(
          onTap: onRecheck,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: AnimatedBuilder(
              animation: pulseAnim,
              builder: (_, __) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: online ? const Color(0xFF0D2018) : const Color(0xFF1F0D0A),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: online ? C.green.withOpacity(0.5) : C.red.withOpacity(0.5)),
                ),
                child: Row(children: [
                  Container(
                    width: 6, height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: online ? C.green.withOpacity(pulseAnim.value) : C.red,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    online ? 'ONLINE' : 'OFFLINE',
                    style: TS.label(size: 10, color: online ? C.green : C.red),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

// ─── Strategy Toggle ─────────────────────────────────────────────────────────
class _StrategyToggle extends StatelessWidget {
  final String strategy;
  final ValueChanged<String> onChanged;
  final bool loading;

  const _StrategyToggle({required this.strategy, required this.onChanged, required this.loading});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: C.bg0, borderRadius: BorderRadius.circular(4), border: Border.all(color: C.border)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _btn('smart', 'SMART', Icons.bolt_outlined),
        _btn('all',   'ALL PAGES', Icons.search_outlined),
      ]),
    );
  }

  Widget _btn(String val, String label, IconData icon) {
    final active = strategy == val;
    return GestureDetector(
      onTap: loading ? null : () => onChanged(val),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color:  active ? C.amberLo : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: active ? C.amber.withOpacity(0.6) : Colors.transparent),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 11, color: active ? C.amber : C.text2),
          const SizedBox(width: 5),
          Text(label, style: TS.label(size: 10, color: active ? C.amber : C.text2, fw: active ? FontWeight.w700 : FontWeight.w400)),
        ]),
      ),
    );
  }
}

// ─── Document Panel (left) ───────────────────────────────────────────────────
class _DocumentPanel extends StatefulWidget {
  final bool         hasFile;
  final String?      fileName;
  final int?         fileSize;
  final bool         pdfSupport;
  final bool         online;
  final VoidCallback onPick;
  final VoidCallback onClear;

  const _DocumentPanel({
    required this.hasFile,
    required this.fileName,
    required this.fileSize,
    required this.pdfSupport,
    required this.online,
    required this.onPick,
    required this.onClear,
  });

  @override
  State<_DocumentPanel> createState() => _DocumentPanelState();
}

class _DocumentPanelState extends State<_DocumentPanel> with SingleTickerProviderStateMixin {
  bool _hover = false;
  late AnimationController _shimmerCtrl;
  late Animation<double>   _shimmerAnim;

  @override
  void initState() {
    super.initState();
    _shimmerCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
    _shimmerAnim = Tween<double>(begin: -1.0, end: 2.0).animate(CurvedAnimation(parent: _shimmerCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    super.dispose();
  }

  String get _ext => widget.fileName?.split('.').last.toUpperCase() ?? '';

  Color get _extColor {
    switch (_ext) {
      case 'PDF':  return C.red;
      case 'PNG':
      case 'JPG':
      case 'JPEG': return C.blue;
      case 'TIFF': return C.amber;
      default:     return C.text1;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      color: C.bg1,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Panel header
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.border))),
          child: Row(children: [
            const Icon(Icons.folder_outlined, size: 13, color: C.text2),
            const SizedBox(width: 7),
            Text('DOCUMENT', style: TS.label(size: 11, color: C.text2)),
          ]),
        ),

        Expanded(
          child: !widget.hasFile ? _emptyState() : _loadedState(),
        ),

        // Footer: supported formats
        Container(
          padding: const EdgeInsets.all(12),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: C.border))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ACCEPTED FORMATS', style: TS.label(size: 9, color: C.text2)),
            const SizedBox(height: 6),
            Wrap(spacing: 4, runSpacing: 4, children: [
              if (widget.pdfSupport) _fmtChip('PDF', C.red),
              _fmtChip('PNG', C.blue),
              _fmtChip('JPG', C.blue),
              _fmtChip('TIFF', C.amber),
              _fmtChip('BMP', C.text2),
              _fmtChip('WEBP', C.text2),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _fmtChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(label, style: TS.label(size: 9, color: color)),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        const SizedBox(height: 24),
        // Drop zone
        MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit:  (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.online ? widget.onPick : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 160,
              decoration: BoxDecoration(
                color:  _hover ? C.amberLo : C.bg2,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _hover ? C.amber.withOpacity(0.7) : C.border,
                  width: _hover ? 1.5 : 1,
                ),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                // Animated document icon
                AnimatedBuilder(
                  animation: _shimmerAnim,
                  builder: (_, __) {
                    return ShaderMask(
                      shaderCallback: (rect) => LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        stops: [
                          (_shimmerAnim.value - 0.5).clamp(0, 1),
                          _shimmerAnim.value.clamp(0, 1),
                          (_shimmerAnim.value + 0.5).clamp(0, 1),
                        ],
                        colors: [C.text2, _hover ? C.amber : C.text1, C.text2],
                      ).createShader(rect),
                      child: Icon(
                        Icons.upload_file_outlined,
                        size: 40,
                        color: Colors.white,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  widget.online ? 'UPLOAD DOCUMENT' : 'BACKEND OFFLINE',
                  style: TS.label(size: 10, color: widget.online ? (_hover ? C.amber : C.text1) : C.red),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.online ? 'Click to select a file' : 'Start backend server first',
                  style: TS.body(size: 11, color: C.text2),
                ),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 20),

        // Instructions
        _instructionStep('01', 'Upload a document\n(image or PDF)'),
        const SizedBox(height: 10),
        _instructionStep('02', 'Type your question\nin the query terminal'),
        const SizedBox(height: 10),
        _instructionStep('03', 'UDOP extracts the\nanswer intelligently'),
      ]),
    );
  }

  Widget _instructionStep(String num, String text) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 24, height: 24,
        decoration: BoxDecoration(
          color: C.amberLo,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: C.amber.withOpacity(0.3)),
        ),
        child: Center(child: Text(num, style: TS.label(size: 9, color: C.amber))),
      ),
      const SizedBox(width: 10),
      Expanded(child: Text(text, style: TS.body(size: 12, color: C.text1))),
    ]);
  }

  Widget _loadedState() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // File card
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: C.bg2,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: C.amber.withOpacity(0.25)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Ext + name row
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: _extColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: _extColor.withOpacity(0.4)),
                ),
                child: Text(_ext, style: TS.label(size: 10, color: _extColor)),
              ),
              const Spacer(),
              GestureDetector(
                onTap: widget.onClear,
                child: const Icon(Icons.close, size: 14, color: C.text2),
              ),
            ]),
            const SizedBox(height: 10),
            Text(
              widget.fileName ?? '',
              style: TS.body(size: 12, color: C.text0),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            if (widget.fileSize != null)
              Row(children: [
                const Icon(Icons.data_usage_outlined, size: 11, color: C.text2),
                const SizedBox(width: 5),
                Text(_fmtSafe(widget.fileSize!), style: TS.label(size: 10, color: C.text2)),
              ]),
          ]),
        ),

        const SizedBox(height: 14),
        // Ready indicator
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: C.green.withOpacity(0.07),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: C.green.withOpacity(0.3)),
          ),
          child: Row(children: [
            const Icon(Icons.check_circle_outline, size: 12, color: C.green),
            const SizedBox(width: 7),
            Text('READY FOR ANALYSIS', style: TS.label(size: 10, color: C.green)),
          ]),
        ),

        const SizedBox(height: 20),
        // Tips section
        Text('ANALYSIS TIPS', style: TS.label(size: 9, color: C.text2)),
        const SizedBox(height: 10),
        _tip(Icons.bolt_outlined, 'Smart mode (default) is 3–5× faster for multi-page docs.'),
        const SizedBox(height: 7),
        _tip(Icons.find_in_page_outlined, 'All-pages mode searches every page for maximum accuracy.'),
        const SizedBox(height: 7),
        _tip(Icons.crop_outlined, 'Clear, high-contrast scans yield the best results.'),
      ]),
    );
  }

  String _fmtSafe(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }

  Widget _tip(IconData icon, String text) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 11, color: C.amber.withOpacity(0.6)),
      const SizedBox(width: 7),
      Expanded(child: Text(text, style: TS.body(size: 11, color: C.text2))),
    ]);
  }
}

// ─── Query Terminal (right) ───────────────────────────────────────────────────
class _QueryTerminal extends StatelessWidget {
  final List<ChatMsg>         msgs;
  final ScrollController      scroll;
  final TextEditingController qCtrl;
  final FocusNode             focus;
  final bool                  loading;
  final bool                  hasFile;
  final VoidCallback          onSend;

  const _QueryTerminal({
    required this.msgs,
    required this.scroll,
    required this.qCtrl,
    required this.focus,
    required this.loading,
    required this.hasFile,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // Terminal header
      Container(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
        height: 44,
        decoration: const BoxDecoration(
          color: C.bg2,
          border: Border(bottom: BorderSide(color: C.border)),
        ),
        child: Row(children: [
          const Icon(Icons.terminal, size: 13, color: C.text2),
          const SizedBox(width: 7),
          Text('QUERY TERMINAL', style: TS.label(size: 11, color: C.text2)),
          const Spacer(),
          Text('${msgs.where((m) => m.role == MsgRole.assistant).length} RESULTS', style: TS.label(size: 9, color: C.text2)),
        ]),
      ),

      // Messages
      Expanded(
        child: msgs.isEmpty
            ? _emptyTerminal()
            : ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                itemCount: msgs.length,
                itemBuilder: (_, i) => _MsgBubble(msg: msgs[i]),
              ),
      ),

      // Typing indicator
      if (loading) const _TypingBar(),

      // Input bar
      _InputBar(ctrl: qCtrl, focus: focus, loading: loading, hasFile: hasFile, onSend: onSend),
    ]);
  }

  Widget _emptyTerminal() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.search_off_outlined, size: 36, color: C.border),
        const SizedBox(height: 12),
        Text('NO QUERIES YET', style: TS.label(size: 11, color: C.text2)),
        const SizedBox(height: 6),
        Text(
          hasFile ? 'Type a question about your document below.' : 'Load a document to begin.',
          style: TS.body(size: 12, color: C.text2),
          textAlign: TextAlign.center,
        ),
      ]),
    );
  }
}

// ─── Message Bubble ───────────────────────────────────────────────────────────
class _MsgBubble extends StatefulWidget {
  final ChatMsg msg;
  const _MsgBubble({required this.msg});
  @override
  State<_MsgBubble> createState() => _MsgBubbleState();
}

class _MsgBubbleState extends State<_MsgBubble> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _fadeAnim;
  late Animation<Offset>   _slideAnim;

  @override
  void initState() {
    super.initState();
    _ctrl      = AnimationController(vsync: this, duration: const Duration(milliseconds: 350));
    _fadeAnim  = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    final dx   = widget.msg.role == MsgRole.user ? 0.05 : -0.03;
    _slideAnim = Tween<Offset>(begin: Offset(dx, 0.02), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.forward();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnim,
      child: SlideTransition(
        position: _slideAnim,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _buildContent(),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final msg = widget.msg;

    if (msg.role == MsgRole.system) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: C.bg3,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: C.border),
          ),
          child: Text(msg.text, style: TS.body(size: 11.5, color: C.text2), textAlign: TextAlign.center),
        ),
      );
    }

    final isUser = msg.role == MsgRole.user;

    return Column(
      crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        // Role label + time
        Padding(
          padding: EdgeInsets.only(
            left:  isUser ? 0 : 4,
            right: isUser ? 4 : 0,
            bottom: 5,
          ),
          child: Row(
            mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              if (!isUser) ...[
                Container(
                  width: 18, height: 18,
                  decoration: BoxDecoration(color: C.amberLo, borderRadius: BorderRadius.circular(3), border: Border.all(color: C.amber.withOpacity(0.4))),
                  child: const Icon(Icons.auto_awesome_outlined, size: 10, color: C.amber),
                ),
                const SizedBox(width: 6),
              ],
              Text(isUser ? 'YOU' : 'UDOP', style: TS.label(size: 9, color: isUser ? C.blue : C.amber)),
              const SizedBox(width: 8),
              Text(_fmtTime(msg.time), style: TS.label(size: 9, color: C.text2)),
              if (isUser) ...[
                const SizedBox(width: 6),
                Container(
                  width: 18, height: 18,
                  decoration: BoxDecoration(color: C.blue.withOpacity(0.1), borderRadius: BorderRadius.circular(3), border: Border.all(color: C.blue.withOpacity(0.4))),
                  child: const Icon(Icons.person_outline, size: 10, color: C.blue),
                ),
              ],
            ],
          ),
        ),

        // Message box
        Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.55,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isUser ? const Color(0xFF131926) : const Color(0xFF14160F),
            borderRadius: BorderRadius.only(
              topLeft:     Radius.circular(isUser ? 8 : 2),
              topRight:    Radius.circular(isUser ? 2 : 8),
              bottomLeft:  const Radius.circular(8),
              bottomRight: const Radius.circular(8),
            ),
            border: Border.all(
              color: isUser ? C.blue.withOpacity(0.2) : C.amber.withOpacity(0.2),
            ),
          ),
          child: SelectableText(
            msg.text,
            style: TS.body(size: 13.5, color: C.text0),
          ),
        ),

        // Metadata tag (for assistant messages with multi-page info)
        if (!isUser && msg.inferenceTime != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 6),
            child: _MetaTag(msg: msg),
          ),
      ],
    );
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2,'0')}:${t.minute.toString().padLeft(2,'0')}:${t.second.toString().padLeft(2,'0')}';
}

// ─── Meta Tag ────────────────────────────────────────────────────────────────
class _MetaTag extends StatelessWidget {
  final ChatMsg msg;
  const _MetaTag({required this.msg});

  @override
  Widget build(BuildContext context) {
    final strat = msg.strategy ?? '';
    final multi = (msg.totalPages ?? 1) > 1;

    return Wrap(spacing: 6, children: [
      if (msg.inferenceTime != null)
        _chip(Icons.timer_outlined, '${msg.inferenceTime!.toStringAsFixed(1)}s', C.text2),
      if (multi)
        _chip(Icons.auto_stories_outlined, 'p.${msg.page}/${msg.totalPages}', C.blue),
      if (strat.isNotEmpty)
        _chip(Icons.science_outlined, strat.replaceAll('→', '→'), C.amber.withOpacity(0.8)),
    ]);
  }

  Widget _chip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 10, color: color),
        const SizedBox(width: 4),
        Text(label, style: TS.label(size: 9, color: color)),
      ]),
    );
  }
}

// ─── Typing Bar ───────────────────────────────────────────────────────────────
class _TypingBar extends StatefulWidget {
  const _TypingBar();
  @override
  State<_TypingBar> createState() => _TypingBarState();
}

class _TypingBarState extends State<_TypingBar> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(children: [
        Container(
          width: 20, height: 20,
          decoration: BoxDecoration(color: C.amberLo, borderRadius: BorderRadius.circular(3), border: Border.all(color: C.amber.withOpacity(0.4))),
          child: const Icon(Icons.auto_awesome_outlined, size: 10, color: C.amber),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: const Color(0xFF14160F),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: C.amber.withOpacity(0.2)),
          ),
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) {
              return Row(mainAxisSize: MainAxisSize.min, children: [
                Text('ANALYZING', style: TS.label(size: 9, color: C.amber.withOpacity(0.7))),
                const SizedBox(width: 10),
                ...List.generate(3, (i) {
                  final t   = (_ctrl.value - i * 0.2).clamp(0.0, 1.0);
                  final op  = (t < 0.5 ? t * 2 : (1 - t) * 2).clamp(0.15, 1.0);
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    width: 5, height: 5,
                    decoration: BoxDecoration(
                      color: C.amber.withOpacity(op),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  );
                }),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

// ─── Input Bar ────────────────────────────────────────────────────────────────
class _InputBar extends StatefulWidget {
  final TextEditingController ctrl;
  final FocusNode             focus;
  final bool                  loading;
  final bool                  hasFile;
  final VoidCallback          onSend;

  const _InputBar({
    required this.ctrl,
    required this.focus,
    required this.loading,
    required this.hasFile,
    required this.onSend,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(() => setState(() => _focused = widget.focus.hasFocus));
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.hasFile && !widget.loading;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        color: C.bg1,
        border: Border(top: BorderSide(color: C.border)),
      ),
      child: Row(children: [
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: C.bg3,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _focused && enabled ? C.amber.withOpacity(0.6) : C.border,
                width: _focused && enabled ? 1.5 : 1.0,
              ),
            ),
            child: TextField(
                controller: widget.ctrl,
                focusNode:  widget.focus,
                enabled:    enabled,
                style: TS.body(size: 13.5, color: enabled ? C.text0 : C.text2),
                decoration: InputDecoration(
                  hintText: enabled
                      ? 'Ask a question about the document…'
                      : widget.hasFile
                          ? 'Waiting for analysis to complete…'
                          : 'Upload a document to begin…',
                  hintStyle:   TS.body(size: 13, color: C.text2),
                  border:      InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
                maxLines:        null,
                minLines:        1,
                keyboardType:    TextInputType.multiline,
                textInputAction: TextInputAction.send,
                onSubmitted:     (_) => widget.onSend(),
              ),
          ),
        ),
        const SizedBox(width: 10),
        // Send button
        GestureDetector(
          onTap: enabled && widget.ctrl.text.trim().isNotEmpty ? widget.onSend : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: enabled ? C.amber.withOpacity(0.15) : C.bg3,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: enabled ? C.amber.withOpacity(0.5) : C.border),
            ),
            child: widget.loading
                ? Padding(
                    padding: const EdgeInsets.all(13),
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: C.amber.withOpacity(0.7)),
                  )
                : Icon(
                    Icons.send_outlined,
                    size: 18,
                    color: enabled ? C.amber : C.text2,
                  ),
          ),
        ),
      ]),
    );
  }
}
