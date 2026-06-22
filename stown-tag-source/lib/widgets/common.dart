import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../screens/login_screen.dart';
import '../theme.dart';

/// Универсальный выход из учётной записи: показывает диалог подтверждения,
/// после согласия дёргает [AuthService.logout] и заменяет стек на [LoginScreen].
/// Передайте [onBeforeLogout] чтобы остановить сканирование/вещание.
Future<void> performLogout(
  BuildContext context, {
  Future<void> Function()? onBeforeLogout,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surfaceElevated,
      title: const Text(
        'Выйти из аккаунта?',
        style: TextStyle(color: AppColors.onSurface),
      ),
      content: const Text(
        'Сессия будет завершена, потребуется ввести пароль снова.',
        style: TextStyle(color: AppColors.onSurfaceMuted),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.danger,
            minimumSize: const Size(80, 40),
          ),
          child: const Text('Выйти'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  if (onBeforeLogout != null) {
    try {
      await onBeforeLogout();
    } catch (_) {}
  }
  await AuthService.instance.logout();
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (_) => false,
  );
}

/// Подпись секции в стиле STOWN (uppercase, muted, letter-spaced).
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: AppColors.onSurfaceMuted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
      );
}

/// Тонкий разделитель в стиле STOWN.
class ThinDivider extends StatelessWidget {
  const ThinDivider({super.key});
  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: AppColors.divider);
}

/// Карточка-контейнер в стиле STOWN (тёмный фон, скруглённые края).
class StownCard extends StatelessWidget {
  const StownCard({super.key, required this.child, this.padding, this.onTap});
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: content,
      ),
    );
  }
}

/// Цветной шейп с лейблом типа метки (iBeacon / Eddystone / ...).
class KindBadge extends StatelessWidget {
  const KindBadge({super.key, required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      );
}

/// Большая кнопка-градиент как в STOWN.
class PrimaryGradientButton extends StatelessWidget {
  const PrimaryGradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            gradient: color == null
                ? primaryGradient
                : LinearGradient(colors: [color!, color!.withValues(alpha: 0.7)]),
            borderRadius: BorderRadius.circular(16),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, color: Colors.white, size: 22),
                const SizedBox(width: 10),
              ],
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
