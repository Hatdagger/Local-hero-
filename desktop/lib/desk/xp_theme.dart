import 'package:flutter/material.dart';

/// Colours and small controls in the classic desktop style (our own
/// artwork, drawn in code).
class Xp {
  static const face = Color(0xFFECE9D8); // dialog background
  static const frame = Color(0xFF0831D9);
  static const frameInactive = Color(0xFF7A96DF);
  static const titleTop = Color(0xFF0A5BE8);
  static const titleBottom = Color(0xFF0846C9);
  static const titleTopInactive = Color(0xFF9DB9EB);
  static const titleBottomInactive = Color(0xFF7B98DA);
  static const selection = Color(0xFF316AC5);
  static const fieldBorder = Color(0xFF7F9DB9);
  static const buttonBorder = Color(0xFF003C74);
  static const taskTop = Color(0xFF3A81F3);
  static const taskBottom = Color(0xFF1F57D2);
  static const trayTop = Color(0xFF16A0F1);
  static const trayBottom = Color(0xFF0D7DD8);
  static const startTop = Color(0xFF4FAA42);
  static const startBottom = Color(0xFF2B7F25);
  static const flash = Color(0xFFF39A28);
  static const menuBlue = Color(0xFFD3E5FA);
  static const imMine = Color(0xFFD00000);
  static const imTheirs = Color(0xFF1030C8);

  static const text = TextStyle(fontSize: 13, color: Colors.black, height: 1.25);
  static const textBold = TextStyle(fontSize: 13, color: Colors.black, fontWeight: FontWeight.bold, height: 1.25);
  static const textGrey = TextStyle(fontSize: 13, color: Color(0xFF808080), height: 1.25);

  static ThemeData theme() => ThemeData(
        useMaterial3: false,
        scaffoldBackgroundColor: Colors.transparent,
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: Colors.black,
          selectionColor: Color(0xFF99B4E8),
        ),
        popupMenuTheme: const PopupMenuThemeData(
          color: Colors.white,
          elevation: 3,
          textStyle: text,
          shape: RoundedRectangleBorder(side: BorderSide(color: Color(0xFFACA899))),
        ),
        checkboxTheme: CheckboxThemeData(
          fillColor: WidgetStateProperty.resolveWith((s) => Colors.white),
          checkColor: WidgetStateProperty.all(const Color(0xFF21A121)),
          side: const BorderSide(color: Color(0xFF1C5180)),
          shape: const RoundedRectangleBorder(),
        ),
      );
}

/// A push button with the rounded, slightly shiny look.
class XpButton extends StatelessWidget {
  const XpButton({super.key, required this.label, this.onPressed, this.isDefault = false, this.minWidth = 75});
  final String label;
  final VoidCallback? onPressed;
  final bool isDefault;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          constraints: BoxConstraints(minWidth: minWidth, minHeight: 23),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: enabled ? Xp.buttonBorder : const Color(0xFFC9C7BA)),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFFFFFFF), Color(0xFFECEBE6), Color(0xFFD6D0C5)],
            ),
            boxShadow: isDefault && enabled
                ? const [BoxShadow(color: Color(0xFF7DA2CE), spreadRadius: 1)]
                : null,
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: Xp.text.copyWith(color: enabled ? Colors.black : const Color(0xFFA19F94))),
        ),
      ),
    );
  }
}

/// A white text box with the thin blue-grey border.
class XpField extends StatelessWidget {
  const XpField({
    super.key,
    required this.controller,
    this.focusNode,
    this.obscure = false,
    this.autofocus = false,
    this.onSubmitted,
    this.onChanged,
    this.minLines,
    this.maxLines = 1,
    this.hint,
    this.textInputAction,
    this.onEditingComplete,
  });
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool obscure;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onEditingComplete;
  final int? minLines;
  final int? maxLines;
  final String? hint;
  final TextInputAction? textInputAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Xp.fieldBorder)),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        obscureText: obscure,
        autofocus: autofocus,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        onEditingComplete: onEditingComplete,
        minLines: minLines,
        maxLines: maxLines,
        textInputAction: textInputAction,
        style: Xp.text,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 4),
          hintText: hint,
          hintStyle: Xp.textGrey,
        ),
      ),
    );
  }
}

/// Text with one letter underlined (menu mnemonics).
class Mnemonic extends StatelessWidget {
  const Mnemonic(this.label, this.index, {super.key, this.style = Xp.text});
  final String label;
  final int index;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    if (index < 0 || index >= label.length) return Text(label, style: style);
    return Text.rich(TextSpan(style: style, children: [
      TextSpan(text: label.substring(0, index)),
      TextSpan(text: label[index], style: const TextStyle(decoration: TextDecoration.underline)),
      TextSpan(text: label.substring(index + 1)),
    ]));
  }
}

/// Label + checkbox in one row.
class XpCheck extends StatelessWidget {
  const XpCheck({super.key, required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 22,
          height: 22,
          child: Checkbox(
            value: value,
            onChanged: (v) => onChanged(v ?? false),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: Xp.text),
      ]),
    );
  }
}

/// A menu popup panel (white with a shadow).
class XpMenuPanel extends StatelessWidget {
  const XpMenuPanel({super.key, required this.children, this.width = 190});
  final List<Widget> children;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border.fromBorderSide(BorderSide(color: Color(0xFFACA899))),
        boxShadow: [BoxShadow(color: Color(0x66000000), offset: Offset(2, 2), blurRadius: 3)],
      ),
      padding: const EdgeInsets.all(2),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

/// One row in a menu.
class XpMenuItem extends StatefulWidget {
  const XpMenuItem({
    super.key,
    required this.label,
    this.mnemonic = -1,
    this.onTap,
    this.shortcut,
    this.bold = false,
    this.highlighted = false,
    this.icon,
  });
  final String label;
  final int mnemonic;
  final VoidCallback? onTap;
  final String? shortcut;
  final bool bold;
  final bool highlighted;
  final IconData? icon;

  @override
  State<XpMenuItem> createState() => _XpMenuItemState();
}

class _XpMenuItemState extends State<XpMenuItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final hi = enabled && (_hover || widget.highlighted);
    final color = !enabled ? const Color(0xFFACA899) : (hi ? Colors.white : Colors.black);
    final style = Xp.text.copyWith(color: color, fontWeight: widget.bold ? FontWeight.bold : null);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: hi ? Xp.selection : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(children: [
            SizedBox(
              width: 22,
              child: widget.icon == null ? null : Icon(widget.icon, size: 16, color: color),
            ),
            Expanded(child: Mnemonic(widget.label, widget.mnemonic, style: style)),
            if (widget.shortcut != null) Text(widget.shortcut!, style: style),
          ]),
        ),
      ),
    );
  }
}

class XpMenuSeparator extends StatelessWidget {
  const XpMenuSeparator({super.key});

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 2), color: const Color(0xFFACA899));
}

/// One entry in a window's menu bar menu. A null [onTap] greys it out;
/// a null label is a separator line.
class MenuBarEntry {
  final String? label;
  final VoidCallback? onTap;
  final String? shortcut;
  final bool checked;
  const MenuBarEntry(this.label, this.onTap, {this.shortcut, this.checked = false});
  const MenuBarEntry.separator()
      : label = null,
        onTap = null,
        shortcut = null,
        checked = false;
}

/// The File / Edit / ... strip under a window's title bar.
class XpMenuBar extends StatelessWidget {
  const XpMenuBar({super.key, required this.menus});
  final List<(String, List<MenuBarEntry>)> menus;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Xp.face,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(children: [
        for (final (title, items) in menus)
          PopupMenuButton<int>(
            tooltip: '',
            offset: const Offset(0, 22),
            padding: EdgeInsets.zero,
            onSelected: (i) => items[i].onTap?.call(),
            itemBuilder: (_) => [
              for (var i = 0; i < items.length; i++)
                if (items[i].label == null)
                  const PopupMenuDivider(height: 7)
                else
                  PopupMenuItem<int>(
                    value: i,
                    height: 28,
                    enabled: items[i].onTap != null,
                    child: SizedBox(
                      width: 190,
                      child: Row(children: [
                        SizedBox(width: 18, child: items[i].checked ? const Icon(Icons.check, size: 15) : null),
                        Expanded(
                            child: Text(items[i].label!,
                                style: _menuText.copyWith(color: items[i].onTap == null ? const Color(0xFFACA899) : null))),
                        if (items[i].shortcut != null) Text(items[i].shortcut!, style: _menuText),
                      ]),
                    ),
                  ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              child: Text(title, style: _menuText),
            ),
          ),
      ]),
    );
  }
}

const _menuText = Xp.text;
