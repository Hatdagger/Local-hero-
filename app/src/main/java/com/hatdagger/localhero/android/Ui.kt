package com.hatdagger.localhero.android

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.TextView

object Palette {
    const val BG = 0xFF0D0F14.toInt()
    const val SURFACE = 0xFF171A22.toInt()
    const val SURFACE_HI = 0xFF222633.toInt()
    const val TEXT = 0xFFEEF0F5.toInt()
    const val TEXT_DIM = 0xFF8B92A3.toInt()
    const val ON_ACCENT = 0xFF0D0F14.toInt()
    const val GOLD = 0xFFFFB547.toInt()     // library / main
    const val TEAL = 0xFF2FD3B0.toInt()     // mixes
    const val VIOLET = 0xFFA78BFA.toInt()   // playlists
    const val CORAL = 0xFFFF6B6B.toInt()    // tidy
    const val BLUE = 0xFF5AA9FF.toInt()

    fun alpha(c: Int, a: Int) = Color.argb(a, Color.red(c), Color.green(c), Color.blue(c))
}

class Ui(private val ctx: Context) {
    private val density = ctx.resources.displayMetrics.density
    fun dp(v: Int) = (v * density).toInt()

    enum class Style { FILLED, TONAL, OUTLINE, GHOST }

    fun rounded(fill: Int, radiusDp: Int, stroke: Int = 0, strokeDp: Int = 0) = GradientDrawable().apply {
        setColor(fill); cornerRadius = dp(radiusDp).toFloat()
        if (strokeDp > 0) setStroke(dp(strokeDp), stroke)
    }

    fun ripple(content: Drawable?, accent: Int): Drawable =
        RippleDrawable(ColorStateList.valueOf(Palette.alpha(accent, 70)), content, rounded(Color.WHITE, 16))

    fun text(s: String = "", sizeSp: Float = 14f, color: Int = Palette.TEXT, bold: Boolean = false, lines: Int = 0) = TextView(ctx).apply {
        text = s; textSize = sizeSp; setTextColor(color)
        if (bold) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        if (lines > 0) { maxLines = lines; ellipsize = TextUtils.TruncateAt.END }
    }

    fun button(label: String, accent: Int, style: Style = Style.TONAL, onClick: () -> Unit): Button = Button(ctx).apply {
        text = label; isAllCaps = false; textSize = 14f
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        stateListAnimator = null; elevation = 0f
        minHeight = dp(42); minimumHeight = dp(42); minWidth = 0; minimumWidth = 0
        setPadding(dp(14), dp(4), dp(14), dp(4))
        applyStyle(this, accent, style)
        setOnClickListener { onClick() }
    }

    fun applyStyle(b: Button, accent: Int, style: Style) {
        val fill: Int; val stroke: Int; val fg: Int
        when (style) {
            Style.FILLED -> { fill = accent; stroke = 0; fg = Palette.ON_ACCENT }
            Style.TONAL -> { fill = Palette.alpha(accent, 45); stroke = 0; fg = Palette.TEXT }
            Style.OUTLINE -> { fill = Color.TRANSPARENT; stroke = Palette.alpha(accent, 150); fg = accent }
            Style.GHOST -> { fill = Color.TRANSPARENT; stroke = 0; fg = Palette.TEXT_DIM }
        }
        b.background = ripple(rounded(fill, 21, stroke, if (stroke != 0) 1 else 0), accent)
        b.setTextColor(fg)
    }

    /** Round icon-ish button using a text glyph. */
    fun glyph(g: String, accent: Int, sizeDp: Int = 48, filled: Boolean = false, onClick: () -> Unit) = TextView(ctx).apply {
        text = g; gravity = Gravity.CENTER; textSize = sizeDp / 2.6f
        setTextColor(if (filled) Palette.ON_ACCENT else Palette.TEXT)
        background = ripple(GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(if (filled) accent else Palette.alpha(accent, 35)) }, accent)
        layoutParams = LinearLayout.LayoutParams(dp(sizeDp), dp(sizeDp)).apply { setMargins(dp(6), 0, dp(6), 0) }
        setOnClickListener { onClick() }
    }

    fun card(accent: Int): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(Palette.alpha(accent, 30), Palette.SURFACE)).apply {
            cornerRadius = dp(18).toFloat(); setStroke(dp(1), Palette.alpha(accent, 60))
        }
        setPadding(dp(14), dp(12), dp(14), dp(12))
    }

    fun row(vararg views: View, gravity: Int = Gravity.CENTER_VERTICAL) = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL; this.gravity = gravity
        views.forEach { addView(it) }
    }

    fun column(vararg views: View) = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        views.forEach { addView(it) }
    }

    fun spacer(wDp: Int = 0, hDp: Int = 0) = View(ctx).apply { layoutParams = LinearLayout.LayoutParams(dp(wDp), dp(hDp)) }
    fun weight(v: View, w: Float = 1f): View { v.layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, w); return v }
    fun margins(v: View, l: Int = 0, t: Int = 0, r: Int = 0, b: Int = 0): View {
        val lp = (v.layoutParams as? LinearLayout.LayoutParams) ?: LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        lp.setMargins(dp(l), dp(t), dp(r), dp(b)); v.layoutParams = lp; return v
    }
}

/** One line in a list. */
sealed class Item {
    data class Header(val text: String, val accent: Int = Palette.TEXT_DIM) : Item()
    class Entry(
        val title: String,
        val sub: String = "",
        val trailing: String = "",
        val accent: Int = Palette.GOLD,
        val checked: Boolean? = null,       // non-null shows a checkbox
        val highlight: Boolean = false,
        val onCheck: ((Boolean) -> Unit)? = null,
        val onLong: (() -> Unit)? = null,
        val onClick: (() -> Unit)? = null,
    ) : Item()
    class Custom(val view: View) : Item()
}

/** A simple list adapter that recycles entry rows. Works fine for libraries with thousands of songs. */
class ItemAdapter(private val ctx: Context, private val ui: Ui) : BaseAdapter() {
    var items: List<Item> = emptyList()
        set(v) { field = v; notifyDataSetChanged() }

    override fun getCount() = items.size
    override fun getItem(p: Int) = items[p]
    override fun getItemId(p: Int) = p.toLong()
    override fun getViewTypeCount() = 2
    override fun getItemViewType(p: Int) = when (items[p]) { is Item.Header -> 0; is Item.Entry -> 1; is Item.Custom -> -1 /* IGNORE */ }
    override fun isEnabled(p: Int) = items[p] is Item.Entry

    private class Holder(val box: CheckBox, val title: TextView, val sub: TextView, val trailing: TextView)

    override fun getView(p: Int, convert: View?, parent: ViewGroup): View {
        return when (val it = items[p]) {
            is Item.Custom -> it.view.also { v -> (v.parent as? ViewGroup)?.takeIf { g -> g !== parent }?.removeView(v) }
            is Item.Header -> ((convert as? TextView)?.takeIf { c -> c.tag == "h" } ?: ui.text("", 12f, it.accent, bold = true).apply {
                tag = "h"; setPadding(ui.dp(16), ui.dp(18), ui.dp(16), ui.dp(6)); isAllCaps = true; letterSpacing = 0.08f
            }).apply { text = it.text; setTextColor(it.accent) }
            is Item.Entry -> {
                val v = (convert as? LinearLayout)?.takeIf { c -> c.tag is Holder } ?: makeEntry()
                val h = v.tag as Holder
                h.title.text = it.title
                h.sub.text = it.sub; h.sub.visibility = if (it.sub.isEmpty()) View.GONE else View.VISIBLE
                h.trailing.text = it.trailing
                h.title.setTextColor(if (it.highlight) it.accent else Palette.TEXT)
                h.box.setOnCheckedChangeListener(null)
                if (it.checked != null) {
                    h.box.visibility = View.VISIBLE; h.box.isChecked = it.checked
                    h.box.buttonTintList = ColorStateList.valueOf(it.accent)
                    h.box.setOnCheckedChangeListener { _, c -> it.onCheck?.invoke(c) }
                } else h.box.visibility = View.GONE
                v.setOnClickListener { _ -> if (it.checked != null && it.onClick == null) h.box.toggle() else it.onClick?.invoke() }
                v.setOnLongClickListener { _ -> it.onLong?.let { l -> l(); true } ?: false }
                v.background = ui.ripple(null, it.accent)
                v
            }
        }
    }

    private fun makeEntry(): LinearLayout {
        val box = CheckBox(ctx).apply { isFocusable = false }
        val title = ui.text("", 15f, Palette.TEXT, lines = 1)
        val sub = ui.text("", 12.5f, Palette.TEXT_DIM, lines = 1)
        val col = ui.column(title, sub)
        val trailing = ui.text("", 12.5f, Palette.TEXT_DIM).apply { setPadding(ui.dp(10), 0, 0, 0) }
        return ui.row(box, ui.weight(col), trailing).apply {
            setPadding(ui.dp(16), ui.dp(9), ui.dp(16), ui.dp(9))
            minimumHeight = ui.dp(56)
            tag = Holder(box, title, sub, trailing)
        }
    }
}
