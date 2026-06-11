import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Локальная авторизация: логин + пароль (SHA-256 со случайной солью)
/// хранится в [SharedPreferences]. При первом запуске нужно создать аккаунт.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const _kLogin = 'auth_login';
  static const _kPassHash = 'auth_pass_hash';
  static const _kSalt = 'auth_salt';
  static const _kLoggedIn = 'auth_logged_in';

  final _rng = Random.secure();

  /// Проверяет, зарегистрирован ли пользователь.
  Future<bool> hasUser() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_kPassHash) && prefs.containsKey(_kSalt);
  }

  /// Возвращает сохранённый логин (если есть) — чтобы префиллить поле.
  Future<String?> savedLogin() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kLogin);
  }

  /// Активна ли сессия — пользователь не выходил после прошлого входа.
  Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kLoggedIn) ?? false;
  }

  /// Регистрирует аккаунт: сохраняет логин и хэш пароля с новой солью.
  Future<void> register(String login, String password) async {
    if (login.trim().isEmpty) {
      throw ArgumentError('Логин не может быть пустым');
    }
    if (password.length < 4) {
      throw ArgumentError('Пароль должен быть минимум 4 символа');
    }
    final salt = _generateSalt();
    final hash = _hash(password, salt);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLogin, login.trim());
    await prefs.setString(_kSalt, salt);
    await prefs.setString(_kPassHash, hash);
    await prefs.setBool(_kLoggedIn, true);
  }

  /// Проверяет логин + пароль. Возвращает `true` при успехе и сохраняет
  /// флаг авторизации.
  Future<bool> login(String login, String password) async {
    final prefs = await SharedPreferences.getInstance();
    final savedLogin = prefs.getString(_kLogin);
    final salt = prefs.getString(_kSalt);
    final savedHash = prefs.getString(_kPassHash);
    if (savedLogin == null || salt == null || savedHash == null) {
      return false;
    }
    if (savedLogin != login.trim()) return false;
    final attempt = _hash(password, salt);
    if (attempt != savedHash) return false;
    await prefs.setBool(_kLoggedIn, true);
    return true;
  }

  /// Сбрасывает флаг авторизации (логин/пароль остаются для повторного входа).
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLoggedIn, false);
  }

  /// Полный сброс аккаунта.
  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLogin);
    await prefs.remove(_kSalt);
    await prefs.remove(_kPassHash);
    await prefs.remove(_kLoggedIn);
  }

  String _generateSalt({int bytes = 16}) {
    final list = List<int>.generate(bytes, (_) => _rng.nextInt(256));
    return base64Encode(list);
  }

  String _hash(String password, String salt) {
    final bytes = utf8.encode(salt + password);
    return sha256.convert(bytes).toString();
  }
}
