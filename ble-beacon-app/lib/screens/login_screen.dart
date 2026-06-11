import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.forceRegister = false});

  /// Если `true` — экран всегда показывает регистрацию (используется при сбросе аккаунта).
  final bool forceRegister;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _loginCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _passConfirmCtrl = TextEditingController();
  bool _obscure = true;
  bool _obscureConfirm = true;
  bool _loading = false;
  bool _registerMode = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _detectMode();
  }

  Future<void> _detectMode() async {
    if (widget.forceRegister) {
      setState(() => _registerMode = true);
      return;
    }
    final hasUser = await AuthService.instance.hasUser();
    final savedLogin = await AuthService.instance.savedLogin();
    if (!mounted) return;
    setState(() {
      _registerMode = !hasUser;
      if (savedLogin != null) _loginCtrl.text = savedLogin;
    });
  }

  @override
  void dispose() {
    _loginCtrl.dispose();
    _passCtrl.dispose();
    _passConfirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final login = _loginCtrl.text.trim();
    final pass = _passCtrl.text;
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      if (_registerMode) {
        if (pass != _passConfirmCtrl.text) {
          setState(() => _error = 'Пароли не совпадают');
          return;
        }
        await AuthService.instance.register(login, pass);
      } else {
        final ok = await AuthService.instance.login(login, pass);
        if (!ok) {
          setState(() => _error = 'Неверный логин или пароль');
          return;
        }
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } on ArgumentError catch (e) {
      setState(() => _error = e.message?.toString() ?? e.toString());
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight:
                  MediaQuery.of(context).size.height - MediaQuery.of(context).padding.vertical,
            ),
            child: Column(
              children: [
                const SizedBox(height: 48),
                Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        AppColors.primary.withValues(alpha: 0.3),
                        AppColors.background,
                      ],
                    ),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.bluetooth_searching,
                    size: 80,
                    color: AppColors.primaryLight,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'BLE BEACON',
                  style: TextStyle(
                    color: AppColors.onSurface,
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 6,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _registerMode
                      ? 'Создайте учётную запись'
                      : 'Войдите в систему управления',
                  style: const TextStyle(
                    color: AppColors.onSurfaceMuted,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 36),
                TextField(
                  controller: _loginCtrl,
                  enabled: !_loading,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(color: AppColors.onSurface, fontSize: 16),
                  decoration: const InputDecoration(
                    labelText: 'Логин',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passCtrl,
                  enabled: !_loading,
                  obscureText: _obscure,
                  textInputAction: _registerMode
                      ? TextInputAction.next
                      : TextInputAction.done,
                  style: const TextStyle(color: AppColors.onSurface, fontSize: 16),
                  decoration: InputDecoration(
                    labelText: 'Пароль',
                    prefixIcon: const Icon(Icons.vpn_key_outlined),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility,
                        color: AppColors.onSurfaceMuted,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  onSubmitted: _registerMode ? null : (_) => _submit(),
                ),
                if (_registerMode) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passConfirmCtrl,
                    enabled: !_loading,
                    obscureText: _obscureConfirm,
                    textInputAction: TextInputAction.done,
                    style: const TextStyle(color: AppColors.onSurface, fontSize: 16),
                    decoration: InputDecoration(
                      labelText: 'Повторите пароль',
                      prefixIcon: const Icon(Icons.vpn_key_outlined),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureConfirm ? Icons.visibility_off : Icons.visibility,
                          color: AppColors.onSurfaceMuted,
                        ),
                        onPressed: () =>
                            setState(() => _obscureConfirm = !_obscureConfirm),
                      ),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.danger.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.danger.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: AppColors.danger, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: const TextStyle(color: AppColors.danger),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: PrimaryGradientButton(
                    label: _loading
                        ? 'Подождите...'
                        : (_registerMode ? 'Зарегистрироваться' : 'Войти'),
                    icon: _registerMode
                        ? Icons.person_add_alt
                        : Icons.login,
                    onPressed: _loading ? null : _submit,
                  ),
                ),
                const SizedBox(height: 16),
                if (!_registerMode)
                  TextButton(
                    onPressed: _loading ? null : _confirmReset,
                    child: const Text(
                      'Сбросить аккаунт',
                      style: TextStyle(color: AppColors.onSurfaceMuted),
                    ),
                  ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        title: const Text(
          'Сбросить аккаунт?',
          style: TextStyle(color: AppColors.onSurface),
        ),
        content: const Text(
          'Логин и пароль будут удалены. Сохранённые пресеты останутся.',
          style: TextStyle(color: AppColors.onSurfaceMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              minimumSize: const Size(80, 40),
            ),
            child: const Text('Сбросить'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AuthService.instance.reset();
      _passCtrl.clear();
      _passConfirmCtrl.clear();
      if (mounted) setState(() => _registerMode = true);
    }
  }
}
