import 'dart:io';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/models.dart';
import '../core/message_presentation.dart';
import '../core/normalize.dart';
import 'app.dart';

class MessageContent extends ConsumerStatefulWidget {
  final Message message;
  final VoidCallback? onDownload;
  final bool foldLongText;
  const MessageContent(
    this.message, {
    super.key,
    this.onDownload,
    this.foldLongText = false,
  });
  @override
  ConsumerState<MessageContent> createState() => _MessageContentState();
}

class _MessageContentState extends ConsumerState<MessageContent> {
  bool expanded = false;
  bool reloading = false;
  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    if (messageRecalled(m)) return const Text('消息已撤回');
    if (m.text.trim() == '[Invalid text JSON]' &&
        ref.read(workspaceProvider).account(m.accountId).platform == 'feishu') {
      return TextButton.icon(
        icon: const Icon(Icons.refresh),
        label: Text(reloading ? '正在重新读取…' : '消息内容暂不可用，点击重新读取'),
        onPressed: reloading
            ? null
            : () async {
                setState(() => reloading = true);
                try {
                  await guarded(
                    context,
                    () => ref.read(workspaceProvider).reloadMessage(m),
                  );
                } finally {
                  if (mounted) setState(() => reloading = false);
                }
              },
      );
    }
    final resource = findResourceId(m.extra['raw']);
    final imageMessage = ['image', 'picture', '2'].contains(messageKind(m));
    final presentation = messagePresentation(m);
    final text = presentation.text;
    final references = messageImageReferences(text);
    if (references.isNotEmpty) {
      final parts = <Widget>[];
      var offset = 0;
      for (final reference in references) {
        final before = text.substring(offset, reference.start);
        if (before.trim().isNotEmpty) {
          parts.add(_renderText(m, before, presentation.markdown));
        }
        parts.add(
          _InlineMessageImage(
            message: m,
            resourceId: reference.resourceId,
            key: ValueKey(
              '${m.key}:${reference.start}:${reference.resourceId}',
            ),
          ),
        );
        offset = reference.end;
      }
      final after = text.substring(offset);
      if (after.trim().isNotEmpty) {
        parts.add(_renderText(m, after, presentation.markdown));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: parts,
      );
    }
    if (imageMessage && resource.isNotEmpty) {
      return _InlineMessageImage(message: m, resourceId: resource);
    }
    if (messageKind(m) == 'file') {
      final details = attachmentDetails(m.extra['raw']);
      final name = '${details['name'] ?? (m.text.isEmpty ? '文件附件' : m.text)}';
      final size = details['size'] as int?;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_outlined, size: 32),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name),
                if (size != null && size >= 0)
                  Text(
                    size < 1024
                        ? '$size B'
                        : size < 1024 * 1024
                        ? '${(size / 1024).toStringAsFixed(1)} KB'
                        : '${(size / (1024 * 1024)).toStringAsFixed(1)} MB',
                  ),
                if (resource.isEmpty) const Text('附件暂不可下载'),
              ],
            ),
          ),
          if (resource.isNotEmpty)
            IconButton(
              tooltip: '保存文件',
              onPressed: widget.onDownload,
              icon: const Icon(Icons.download_outlined),
            ),
        ],
      );
    }
    return _renderText(m, text, presentation.markdown);
  }

  Widget _renderText(Message m, String text, bool markdown) {
    if (widget.foldLongText) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final painter = TextPainter(
            text: TextSpan(
              text: text,
              style: const TextStyle(fontSize: 14, height: 1.43),
            ),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 12,
          )..layout(maxWidth: constraints.maxWidth);
          final long = painter.didExceedMaxLines;
          painter.dispose();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (long && !expanded)
                Text(
                  text,
                  maxLines: 12,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, height: 1.43),
                )
              else
                _fullText(m, text, markdown),
              if (long)
                SelectionContainer.disabled(
                  child: TextButton(
                    onPressed: () => setState(() => expanded = !expanded),
                    child: Text(expanded ? '收起长消息' : '展开完整消息'),
                  ),
                ),
            ],
          );
        },
      );
    }
    return _fullText(m, text, markdown);
  }

  Widget _fullText(Message m, String text, bool markdown) {
    if (markdown) {
      return MarkdownBody(
        data: text,
        selectable: false,
        builders: {'pre': _WrappingCodeBlock()},
        styleSheet: MarkdownStyleSheet(
          tableColumnWidth: const FlexColumnWidth(),
          p: const TextStyle(fontSize: 14, height: 1.43),
          blockSpacing: 6,
          listIndent: 20,
        ),
        imageBuilder: (_, _, _) => const Text('[图片，请查看消息附件]'),
        onTapLink: (_, href, _) {
          final uri = Uri.tryParse(href ?? '');
          if (uri != null && ['https', 'http'].contains(uri.scheme)) {
            launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
      );
    }
    final kind = switch (messageKind(m)) {
      'file' => '文件',
      'audio' || 'voice' => '语音',
      'video' || 'media' => '视频',
      'interactive' || 'card' => '卡片（内容摘要）',
      'sticker' => '表情',
      'text' => '',
      _ => '暂不支持完整展示的消息：${messageKind(m)}',
    };
    return Text(
      [
        if (kind.isNotEmpty) '[$kind]',
        if (text.isNotEmpty) text,
        if (text.isEmpty && kind.isEmpty) '[空消息]',
      ].join('\n'),
      style: const TextStyle(fontSize: 14, height: 1.43),
    );
  }
}

class _InlineMessageImage extends ConsumerStatefulWidget {
  final Message message;
  final String resourceId;
  const _InlineMessageImage({
    super.key,
    required this.message,
    required this.resourceId,
  });
  @override
  ConsumerState<_InlineMessageImage> createState() =>
      _InlineMessageImageState();
}

class _InlineMessageImageState extends ConsumerState<_InlineMessageImage> {
  Future<String>? image;
  @override
  void didUpdateWidget(covariant _InlineMessageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.key != widget.message.key ||
        oldWidget.resourceId != widget.resourceId) {
      image = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = ref.read(workspaceProvider);
    image ??= w.cachedAttachment(
      Message.fromJson({...widget.message.toJson(), 'kind': 'image'}),
      widget.resourceId,
    );
    return SelectionContainer.disabled(
      child: FutureBuilder<String>(
        future: image,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return TextButton.icon(
              onPressed: () => setState(() {
                image = null;
              }),
              icon: const Icon(Icons.refresh),
              label: const Text('图片加载失败，点击重试'),
            );
          }
          if (!snapshot.hasData) {
            return const SizedBox(
              width: 180,
              height: 80,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return InkWell(
            onTap: () => showDialog<void>(
              context: context,
              builder: (context) => Dialog(
                child: Stack(
                  children: [
                    InteractiveViewer(
                      child: Center(
                        child: Image.file(
                          File(snapshot.data!),
                          errorBuilder: (_, _, _) =>
                              const Text('图片文件不可用，请关闭预览后重试'),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 8,
                      top: 8,
                      child: IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            child: Image.file(
              File(snapshot.data!),
              width: 300,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => TextButton.icon(
                onPressed: () async {
                  await FileImage(File(snapshot.data!)).evict();
                  if (mounted) setState(() => image = null);
                },
                icon: const Icon(Icons.refresh),
                label: const Text('图片文件不可用，点击重试'),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Code participates in the message selection area and wraps within the bubble.
class _WrappingCodeBlock extends MarkdownElementBuilder {
  @override
  Widget visitText(md.Text text, TextStyle? preferredStyle) => Padding(
    padding: const EdgeInsets.all(8),
    child: Text(
      text.text,
      style: (preferredStyle ?? const TextStyle()).copyWith(
        fontFamily: 'monospace',
      ),
      softWrap: true,
    ),
  );
}

class SenderAvatar extends StatelessWidget {
  final String name, url, path;
  final double radius;
  final IconData? fallbackIcon;
  const SenderAvatar({
    super.key,
    required this.name,
    required this.url,
    this.path = '',
    this.radius = 16,
    this.fallbackIcon,
  });
  @override
  Widget build(BuildContext context) {
    final fallback = CircleAvatar(
      radius: radius,
      child: fallbackIcon != null
          ? Icon(fallbackIcon)
          : Text(
              name.isEmpty ? '?' : String.fromCharCode(name.runes.first),
              style: const TextStyle(fontSize: 12),
            ),
    );
    if (path.isNotEmpty) {
      return ClipOval(
        child: Image.file(
          File(path),
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
        ),
      );
    }
    if (Uri.tryParse(url)?.scheme != 'https') return fallback;
    return ClipOval(
      child: Image.network(
        url,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}
