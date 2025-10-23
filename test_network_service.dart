import 'package:flutter/material.dart';
import 'package:my_app/services/network_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Test NetworkService initialization
  final networkService = NetworkService();
  await networkService.initialize();

  print('NetworkService initialized successfully');

  // Test a simple GET request
  try {
    final response = await networkService.dio.get('https://httpbin.org/get');
    print('GET request successful: ${response.statusCode}');
  } catch (e) {
    print('GET request failed: $e');
  }

  // Test HEAD request (like in _resolveFinalUrl)
  try {
    final response = await networkService.dio.head('https://httpbin.org/get');
    print('HEAD request successful: ${response.statusCode}');
  } catch (e) {
    print('HEAD request failed: $e');
  }

  print('NetworkService integration test completed');
}