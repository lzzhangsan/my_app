import 'package:flutter/material.dart';

class CreateFolderDialog extends StatefulWidget {
  final Function(String) onCreate;

  const CreateFolderDialog({required this.onCreate, super.key});

  @override
  _CreateFolderDialogState createState() => _CreateFolderDialogState();
}

class _CreateFolderDialogState extends State<CreateFolderDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('创建文件夹'),
      content: TextField(
        controller: _controller,
        decoration: const InputDecoration(
          labelText: '文件夹名称',
          border: OutlineInputBorder(),
        ),
        autofocus: true,
        onSubmitted: (value) {
          final name = value.trim();
          if (name.isNotEmpty) {
            Navigator.pop(context);
            widget.onCreate(name);
          }
        },
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.pop(context);
          },
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            final name = _controller.text.trim();
            if (name.isNotEmpty) {
              FocusManager.instance.primaryFocus?.unfocus();
              Navigator.pop(context);
              widget.onCreate(name);
            }
          },
          child: const Text('创建'),
        ),
      ],
    );
  }
}
 