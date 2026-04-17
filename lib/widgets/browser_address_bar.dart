import 'package:flutter/material.dart';

class BrowserAddressBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSubmitted;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onRefresh;
  final VoidCallback onHome;
  final bool canGoBack;
  final bool canGoForward;
  final bool isLoading;
  final double progress;

  const BrowserAddressBar({
    Key? key,
    required this.controller,
    required this.onSubmitted,
    required this.onBack,
    required this.onForward,
    required this.onRefresh,
    required this.onHome,
    this.canGoBack = false,
    this.canGoForward = false,
    this.isLoading = false,
    this.progress = 0.0,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isLoading)
          LinearProgressIndicator(
            value: progress,
            minHeight: 2,
            backgroundColor: Colors.transparent,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            border: Border(bottom: BorderSide(color: Colors.grey[300]!)),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.home_outlined),
                onPressed: onHome,
              ),
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                onPressed: canGoBack ? onBack : null,
              ),
              IconButton(
                icon: const Icon(Icons.arrow_forward_ios, size: 20),
                onPressed: canGoForward ? onForward : null,
              ),
              Expanded(
                child: Container(
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      hintText: '搜索或输入网址',
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16.0),
                      suffixIcon: isLoading
                          ? Container(
                              padding: const EdgeInsets.all(10),
                              width: 20,
                              height: 20,
                              child: const CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              icon: const Icon(Icons.refresh, size: 20),
                              onPressed: onRefresh,
                            ),
                    ),
                    onSubmitted: (_) => onSubmitted(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ],
    );
  }
}
