import 'package:chatmcp/utils/toast.dart';
import 'package:http/http.dart' as http;
import 'base_llm_client.dart';
import 'dart:convert';
import 'model.dart';
import 'package:logging/logging.dart';
import 'package:chatmcp/utils/file_content.dart';

class FoundryClient extends BaseLLMClient {
  final String apiKey;
  final String baseUrl;
  final String apiVersion;
  final String modelVersion = '2023-03-15-preview';
  final Map<String, String> _headers;

  FoundryClient({
    required this.apiKey,
    String? apiVersion,
    String? baseUrl,
  })  : baseUrl = (baseUrl == null || baseUrl.isEmpty) ? 'https://YOUR_RESOURCE_NAME.openai.azure.com' : baseUrl,
        apiVersion = apiVersion ?? 'preview',
        _headers = {
          'Content-Type': 'application/json; charset=utf-8',
          'api-key': apiKey,
        };

  @override
  Future<LLMResponse> chatCompletion(CompletionRequest request) async {
    final body = {
      'model': request.model,
      'messages': chatMessageToOpenAIMessage(request.messages),
    };

    addModelSettingsToBody(body, request.modelSetting);

    if (request.tools != null && request.tools!.isNotEmpty) {
      body['tools'] = request.tools!;
      body['tool_choice'] = 'auto';
    }

    final bodyStr = jsonEncode(body);
    Logger.root.fine('OpenAI request: $bodyStr');

    final endpoint = apiVersion == "preview"
        ? "${getEndpoint(baseUrl, '/openai/v1/chat/completions')}?api-version=$apiVersion"
        : "${getEndpoint(baseUrl, '/openai/deployments/${request.model}/chat/completions')}?api-version=$apiVersion";

    try {
      final httpClient = BaseLLMClient.createHttpClient();
      final response = await httpClient.post(
        Uri.parse(endpoint),
        headers: _headers,
        body: jsonEncode(body),
      );

      final responseBody = utf8.decode(response.bodyBytes);
      Logger.root.fine('OpenAI response: $responseBody');

      if (response.statusCode >= 400) {
        throw Exception('HTTP ${response.statusCode}: $responseBody');
      }

      final jsonData = jsonDecode(responseBody);

      final message = jsonData['choices'][0]['message'];

      // Parse tool calls
      final toolCalls = message['tool_calls']
          ?.map<ToolCall>((t) => ToolCall(
                id: t['id'],
                type: t['type'],
                function: FunctionCall(
                  name: t['function']['name'],
                  arguments: t['function']['arguments'],
                ),
              ))
          ?.toList();

      return LLMResponse(
        content: message['content'],
        toolCalls: toolCalls,
      );
    } catch (e) {
      throw await handleError(e, 'Foundry', endpoint, bodyStr);
    }
  }

  @override
  Stream<LLMResponse> chatStreamCompletion(CompletionRequest request) async* {
    final body = {
      'model': request.model,
      'messages': chatMessageToOpenAIMessage(request.messages),
      'stream': true,
    };

    addModelSettingsToBody(body, request.modelSetting);

    Logger.root.fine("debug log:openai stream body: ${jsonEncode(body)}");

    final endpoint = apiVersion == "preview"
        ? "${getEndpoint(baseUrl, '/openai/v1/chat/completions')}?api-version=$apiVersion"
        : "${getEndpoint(baseUrl, '/openai/deployments/${request.model}/chat/completions')}?api-version=$apiVersion";

    try {
      final request = http.Request('POST', Uri.parse(endpoint));
      request.headers.addAll(_headers);
      request.body = jsonEncode(body);

      final httpClient = BaseLLMClient.createHttpClient();
      final response = await httpClient.send(request);

      if (response.statusCode >= 400) {
        final responseBody = await response.stream.bytesToString();
        Logger.root.fine('OpenAI response: $responseBody');

        throw Exception('HTTP ${response.statusCode}: $responseBody');
      }

      final stream = response.stream.transform(utf8.decoder).transform(const LineSplitter());

      await for (final line in stream) {
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6);
        if (data.isEmpty || data == '[DONE]') continue;

        try {
          final json = jsonDecode(data);

          if (json['choices'] == null || json['choices'].isEmpty) {
            continue;
          }

          final delta = json['choices'][0]['delta'];
          if (delta == null) continue;

          final toolCalls = delta['tool_calls']
              ?.map<ToolCall>((t) => ToolCall(
                    id: t['id'] ?? '',
                    type: t['type'] ?? '',
                    function: FunctionCall(
                      name: t['function']?['name'] ?? '',
                      arguments: t['function']?['arguments'] ?? '{}',
                    ),
                  ))
              ?.toList();

          if (delta['content'] != null || toolCalls != null) {
            yield LLMResponse(
              content: delta['content'],
              toolCalls: toolCalls,
            );
          }
        } catch (e) {
          Logger.root.severe('Failed to parse event data: $data $e');
          continue;
        }
      }
    } catch (e) {
      throw await handleError(e, 'Foundry', endpoint, jsonEncode(body));
    }
  }

  @override
  Future<List<String>> models() async {
    if (apiKey.isEmpty) {
      ToastUtils.error('API key not set, skipping model list fetch');
      return [];
    }

    try {
      final httpClient = BaseLLMClient.createHttpClient();
      final response = await httpClient.get(
        Uri.parse("${getEndpoint(baseUrl, "/openai/deployments")}?api-version=$modelVersion"),
        headers: _headers,
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }

      final data = jsonDecode(response.body);

      // Filter out models o1-mini and o1-preview, because of unsupported system message
      final models = (data['data'] as List)
          .where((m) => m['status'] == 'succeeded' && m['model'] != 'o1-mini' && m['model'] != 'o1-preview')
          .map((m) => m['id'].toString())
          .toList();

      return models;
    } catch (e, trace) {
      Logger.root.severe('Failed to get model list: $e, trace: $trace');
      throw LLMException(
        name: 'Foundry',
        endpoint: Uri.parse("${getEndpoint(baseUrl, "/openai/deployments")}?api-version=$modelVersion").toString(),
        requestBody: '',
        originalError: e,
      );
    }
  }
}

List<Map<String, dynamic>> chatMessageToOpenAIMessage(List<ChatMessage> messages) {
  return messages.map((message) {
    final json = <String, dynamic>{
      'role': message.role.value,
    };

    // If there is both text content and files, use array format
    if (message.content != null || message.files != null) {
      final List<Map<String, dynamic>> contentParts = [];

      // Add file content
      if (message.files != null) {
        for (final file in message.files!) {
          if (isImageFile(file.fileType)) {
            contentParts.add({
              'type': 'image_url',
              'image_url': {
                "url": "data:${file.fileType};base64,${file.fileContent}",
              },
            });
          }
          if (isTextFile(file.fileType)) {
            contentParts.add({
              'type': 'text',
              'text': file.fileContent,
            });
          }
        }
      }

      // Add text content
      if (message.content != null) {
        contentParts.add({
          'type': 'text',
          'text': message.content,
        });
      }

      // If there is only one text content and no files, use simple string format
      if (contentParts.length == 1 && message.files == null) {
        json['content'] = message.content;
      } else {
        json['content'] = contentParts;
      }
    }

    // Add tool call related fields
    if (message.role == MessageRole.tool && message.name != null && message.toolCallId != null) {
      json['name'] = message.name!;
      json['tool_call_id'] = message.toolCallId!;
    }

    if (message.toolCalls != null) {
      json['tool_calls'] = message.toolCalls;
    }

    return json;
  }).toList();
}
