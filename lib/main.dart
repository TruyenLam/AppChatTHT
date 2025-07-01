import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

enum ChatMode { gemini, qaSupabase }

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");

  runApp(const ChatBotApp());
}

class ChatBotApp extends StatelessWidget {
  const ChatBotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ChatBot Gemini & Gradio QA',
      debugShowCheckedModeBanner: false,
      home: const ChatScreen(),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
    );
  }
}

class AssistMessage {
  final String data;
  final bool isRequested;
  AssistMessage.request({required this.data}) : isRequested = true;
  AssistMessage.response({required this.data}) : isRequested = false;
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<AssistMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  bool _isLoading = false;
  ChatMode _selectedMode = ChatMode.qaSupabase;

  // Gemini
  GenerativeModel? _model;
  ChatSession? _chatSession;
  String? _error;

  // QA Supabase API endpoint
  final String gradioApi =
      "http://192.168.3.118/trainer/gradio_api/call/qa_on_supabase_db";

  @override
  void initState() {
    super.initState();
    _initGemini();
  }

  Future<void> _initGemini() async {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null || apiKey.isEmpty) {
      setState(() {
        _error = 'Không tìm thấy GEMINI_API_KEY trong .env';
      });
      return;
    }
    try {
      _model = GenerativeModel(
        model: 'gemini-1.5-flash-latest',
        apiKey: apiKey,
        safetySettings: [
          SafetySetting(HarmCategory.harassment, HarmBlockThreshold.none),
          SafetySetting(HarmCategory.hateSpeech, HarmBlockThreshold.none),
          SafetySetting(HarmCategory.sexuallyExplicit, HarmBlockThreshold.none),
          SafetySetting(HarmCategory.dangerousContent, HarmBlockThreshold.none),
        ],
      );
      _chatSession = _model!.startChat();

      setState(() {
        _messages.add(
          AssistMessage.response(data: 'Hi there! How can I help you today?'),
        );
      });
    } catch (e) {
      setState(() {
        _error = 'Lỗi khi khởi tạo Gemini: $e';
      });
    }
  }

  Future<void> _sendMessage(String userInput) async {
    if (_isLoading) return;
    setState(() {
      _messages.add(AssistMessage.request(data: userInput));
      _isLoading = true;
    });

    if (_selectedMode == ChatMode.gemini) {
      await _sendGemini(userInput);
    } else {
      await _sendQASupabase(userInput);
    }
    setState(() => _isLoading = false);
  }

  Future<void> _sendGemini(String userInput) async {
    if (_chatSession == null) {
      setState(() {
        _messages.add(AssistMessage.response(
            data: "Lỗi: Chưa khởi tạo được Gemini API."
        ));
      });
      return;
    }

    try {
      final response = await _chatSession!.sendMessage(Content.text(userInput));
      final geminiReply = response.text ?? "Không có phản hồi từ Gemini.";
      setState(() {
        _messages.add(AssistMessage.response(data: geminiReply));
      });
    } catch (e) {
      setState(() {
        _messages.add(AssistMessage.response(
            data: 'Đã xảy ra lỗi: $e'
        ));
      });
    }
  }

  Future<void> _sendQASupabase(String userInput) async {
    try {
      // Bước 1: POST lấy event_id
      final resp = await http.post(
        Uri.parse(gradioApi),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({"data": [userInput]}),
      );
      if (resp.statusCode != 200) {
        throw Exception('POST Gradio lỗi: ${resp.body}');
      }
      final respJson = jsonDecode(resp.body);
      String? eventId;
      if (respJson is Map && respJson.containsKey('event_id')) {
        eventId = respJson['event_id'];
      } else if (respJson is List && respJson.isNotEmpty) {
        eventId = respJson[0];
      }
      if (eventId == null) throw Exception('Không lấy được event_id');

      // Bước 2: GET lấy kết quả (dạng SSE: event: data\ndata: {...})
      final resultResp = await http.get(
        Uri.parse('$gradioApi/$eventId'),
      );
      if (resultResp.statusCode != 200) {
        throw Exception('Lỗi lấy kết quả QA: ${resultResp.body}');
      }

      // Xử lý SSE: lấy dòng bắt đầu bằng "data:"
      final lines = resultResp.body.split('\n');
      String? jsonLine;
      for (var line in lines) {
        if (line.startsWith('data: ')) {
          jsonLine = line.replaceFirst('data: ', '');
          break;
        }
      }
      jsonLine ??= resultResp.body.trim();

      final resultJson = jsonDecode(jsonLine);

      String answer = "";
      List<dynamic> filePaths = [];
      if (resultJson is Map && resultJson.containsKey('data')) {
        answer = resultJson['data'][0] ?? "";
        if (resultJson['data'].length > 1) {
          filePaths = resultJson['data'][1] ?? [];
        }
      } else if (resultJson is List && resultJson.isNotEmpty) {
        answer = resultJson[0]?.toString() ?? "";
        if (resultJson.length > 1) filePaths = resultJson[1] ?? [];
      } else {
        answer = "Dữ liệu trả về không hợp lệ: $resultJson";
      }

      // Convert filePaths thành markdown link đẹp
      String fileLinks = "";
      if (filePaths.isNotEmpty) {
        List<String> links = [];
        for (var f in filePaths) {
          if (f is Map && f.containsKey('url')) {
            String fileName = f['orig_name']?.toString()
                ?? f['file_name']?.toString()
                ?? f['url']?.toString().split('/').last
                ?? 'file';
            String fileUrl = f['url'].toString();

            // ✅ Encode url để tránh lỗi khi có space/ký tự đặc biệt
            String encodedUrl = Uri.encodeFull(fileUrl);
            links.add('- [${fileName}](${encodedUrl})');
          } else if (f is String && (f.startsWith('http') || f.contains('/'))) {
            String fileName = f.split('/').last;
            String encodedUrl = Uri.encodeFull(f);
            links.add('- [$fileName]($encodedUrl)');
          }
        }
        if (links.isNotEmpty) {
          fileLinks = "\n\n📎 **File liên quan:**\n" + links.join('\n');
        }
      }

      setState(() {
        _messages.add(AssistMessage.response(data: "$answer$fileLinks"));
      });
    } catch (e) {
      setState(() {
        _messages.add(AssistMessage.response(
            data: "Lỗi: $e"
        ));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('ChatBot Gemini & Gradio QA')),
        body: Center(child: Text(_error!, style: const TextStyle(color: Colors.red))),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFFF7F0F7),
      appBar: AppBar(
        title: const Text('ChatBot Gemini & Gradio QA'),
        backgroundColor: Colors.deepPurple.shade200,
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: DropdownButton<ChatMode>(
              value: _selectedMode,
              underline: const SizedBox(),
              dropdownColor: Colors.white,
              items: const [
                DropdownMenuItem(
                  value: ChatMode.gemini,
                  child: Text("Gemini AI"),
                ),
                DropdownMenuItem(
                  value: ChatMode.qaSupabase,
                  child: Text("QA Supabase"),
                ),
              ],
              onChanged: (mode) {
                if (mode != null && !_isLoading) {
                  setState(() {
                    _selectedMode = mode;
                  });
                }
              },
            ),
          ),
          const SizedBox(width: 16)
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            color: _selectedMode == ChatMode.qaSupabase
                ? Colors.green.shade50
                : Colors.deepPurple.shade50,
            child: Row(
              children: [
                Icon(
                  _selectedMode == ChatMode.qaSupabase
                      ? Icons.cloud
                      : Icons.bolt,
                  color: _selectedMode == ChatMode.qaSupabase
                      ? Colors.green
                      : Colors.deepPurple,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  "Chế độ: ${_selectedMode == ChatMode.gemini ? "Gemini AI" : "QA Supabase"}",
                  style: TextStyle(
                    color: _selectedMode == ChatMode.qaSupabase
                        ? Colors.green.shade800
                        : Colors.deepPurple.shade800,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (context, i) {
                final m = _messages[i];
                final isUser = m.isRequested;
                return Align(
                  alignment: isUser
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 700),
                    margin: EdgeInsets.only(
                      top: 4,
                      bottom: 4,
                      left: isUser ? 50 : 0,
                      right: isUser ? 0 : 50,
                    ),
                    child: Card(
                      color: isUser
                          ? Colors.deepPurple[100]
                          : Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(18),
                          topRight: const Radius.circular(18),
                          bottomLeft: Radius.circular(isUser ? 18 : 0),
                          bottomRight: Radius.circular(isUser ? 0 : 18),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14.0),
                        // HIỂN THỊ MARKDOWN
                        child: MarkdownBody(
                          data: m.data,
                          selectable: true,
                          onTapLink: (text, url, title) async {
                            if (url != null) {
                              await launchUrl(Uri.parse(url));
                            }
                          },
                          styleSheet: MarkdownStyleSheet(
                            p: TextStyle(
                              fontSize: 16,
                              color: isUser
                                  ? Colors.deepPurple[900]
                                  : Colors.black87,
                            ),
                            a: TextStyle(
                              color: Colors.blue[700],
                              decoration: TextDecoration.underline,
                            ),
                            codeblockDecoration: BoxDecoration(
                              color: Colors.grey[100],
                              borderRadius: BorderRadius.circular(8.0),
                            ),
                            blockquote: const TextStyle(
                              color: Colors.grey,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_isLoading)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _selectedMode == ChatMode.gemini
                        ? 'Gemini đang trả lời...'
                        : 'Đang truy vấn Supabase...',
                    style: const TextStyle(fontSize: 15),
                  ),
                ],
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: !_isLoading,
                      onSubmitted: (input) {
                        if (input.trim().isNotEmpty && !_isLoading) {
                          _sendMessage(input.trim());
                          _controller.clear();
                        }
                      },
                      decoration: InputDecoration(
                        hintText: _selectedMode == ChatMode.qaSupabase
                            ? "Nhập câu hỏi tìm kiếm trên Supabase..."
                            : "Nhập tin nhắn với Gemini...",
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            vertical: 14, horizontal: 18),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                      textInputAction: TextInputAction.send,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: !_isLoading
                        ? () {
                      final input = _controller.text;
                      if (input.trim().isNotEmpty) {
                        _sendMessage(input.trim());
                        _controller.clear();
                      }
                    }
                        : null,
                    color: Colors.deepPurple,
                    splashRadius: 22,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
