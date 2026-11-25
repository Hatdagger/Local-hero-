package __PACKAGE__

import android.annotation.TargetApi
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.os.Build
import android.util.SparseArray
import android.view.MotionEvent
import android.view.PointerIcon
import android.widget.FrameLayout

/**
 * Wraps the whole desktop and swaps Android's mouse pointers for our own
 * classic-style ones: whatever pointer the desktop (or a web page) asks for,
 * the matching classic pointer is drawn instead.
 */
@TargetApi(Build.VERSION_CODES.N)
class XpCursorFrame(context: Context) : FrameLayout(context) {
    override fun onResolvePointerIcon(event: MotionEvent, pointerIndex: Int): PointerIcon? {
        val wanted = super.onResolvePointerIcon(event, pointerIndex)
        return try {
            XpCursors.replace(context, wanted)
        } catch (e: Exception) {
            wanted
        }
    }
}

@TargetApi(Build.VERSION_CODES.N)
object XpCursors {
    private const val ARROW = 0
    private const val TEXT = 1
    private const val HAND = 2
    private const val EW = 3
    private const val NS = 4
    private const val NWSE = 5
    private const val NESW = 6
    private const val MOVE = 7
    private const val WAIT = 8
    private const val NO = 9
    private const val CROSS = 10

    private val ours = SparseArray<PointerIcon>()
    private var system: List<Pair<PointerIcon, Int>>? = null

    /** Which of our pointers stands in for each Android pointer. */
    private val mapping = listOf(
        PointerIcon.TYPE_TEXT to TEXT,
        PointerIcon.TYPE_VERTICAL_TEXT to TEXT,
        PointerIcon.TYPE_HAND to HAND,
        PointerIcon.TYPE_HORIZONTAL_DOUBLE_ARROW to EW,
        PointerIcon.TYPE_VERTICAL_DOUBLE_ARROW to NS,
        PointerIcon.TYPE_TOP_LEFT_DIAGONAL_DOUBLE_ARROW to NWSE,
        PointerIcon.TYPE_TOP_RIGHT_DIAGONAL_DOUBLE_ARROW to NESW,
        PointerIcon.TYPE_ALL_SCROLL to MOVE,
        PointerIcon.TYPE_WAIT to WAIT,
        PointerIcon.TYPE_NO_DROP to NO,
        PointerIcon.TYPE_CROSSHAIR to CROSS,
    )

    fun replace(ctx: Context, wanted: PointerIcon?): PointerIcon {
        if (wanted != null && wanted == PointerIcon.getSystemIcon(ctx, PointerIcon.TYPE_NULL)) return wanted
        val sys = system ?: mapping.map { (t, k) -> PointerIcon.getSystemIcon(ctx, t) to k }.also { system = it }
        var kind = ARROW
        if (wanted != null) {
            for ((icon, k) in sys) {
                if (icon == wanted) {
                    kind = k
                    break
                }
            }
        }
        return ours.get(kind) ?: make(ctx, kind).also { ours.put(kind, it) }
    }

    private fun make(ctx: Context, kind: Int): PointerIcon {
        val s = ctx.resources.displayMetrics.density.coerceIn(1f, 4f)
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = 0xFFFFFFFF.toInt() }
        val black = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = 0xFF000000.toInt() }
        val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            color = 0xFF000000.toInt()
            strokeWidth = 1.1f
            strokeJoin = Paint.Join.MITER
        }
        val halo = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            color = 0xFFFFFFFF.toInt()
            strokeWidth = 2.4f
            strokeJoin = Paint.Join.MITER
        }

        fun poly(vararg p: Float): Path = Path().apply {
            moveTo(p[0], p[1])
            var i = 2
            while (i < p.size) {
                lineTo(p[i], p[i + 1])
                i += 2
            }
            close()
        }

        // White shape with a black outline (the arrow, the hand).
        fun outlined(w: Float, h: Float, hx: Float, hy: Float, path: Path) =
            icon(s, w, h, hx, hy) { c ->
                c.drawPath(path, fill)
                c.drawPath(path, line)
            }

        // Black shape with a white rim (the resize arrows).
        fun solid(w: Float, h: Float, hx: Float, hy: Float, rotate: Float, path: Path) =
            icon(s, w, h, hx, hy) { c ->
                c.rotate(rotate, hx, hy)
                c.drawPath(path, halo)
                c.drawPath(path, black)
            }

        val twoWay = poly(0f, 4f, 4f, 0f, 4f, 3f, 14f, 3f, 14f, 0f, 18f, 4f, 14f, 8f, 14f, 5f, 4f, 5f, 4f, 8f)

        return when (kind) {
            TEXT -> icon(s, 9f, 18f, 4.5f, 9f) { c ->
                val p = Path().apply {
                    moveTo(1f, 1f); lineTo(4f, 1f); lineTo(4.5f, 1.5f); lineTo(5f, 1f); lineTo(8f, 1f)
                    moveTo(4.5f, 1.5f); lineTo(4.5f, 16.5f)
                    moveTo(1f, 17f); lineTo(4f, 17f); lineTo(4.5f, 16.5f); lineTo(5f, 17f); lineTo(8f, 17f)
                }
                c.drawPath(p, halo.apply { style = Paint.Style.STROKE })
                c.drawPath(p, line)
            }
            HAND -> outlined(
                17f, 20f, 6.5f, 1f,
                poly(5f, 2f, 6.5f, 0.6f, 8f, 2f, 8f, 8f, 10f, 7.4f, 11.5f, 8.2f, 13f, 8.4f, 14.6f, 9.6f, 15.4f, 11f,
                    15.4f, 15f, 13.6f, 18.6f, 6f, 18.6f, 1.6f, 13f, 1.2f, 11.4f, 2.4f, 10.6f, 5f, 12.4f),
            )
            EW -> solid(19f, 9f, 9f, 4f, 0f, twoWay)
            NS -> solid(19f, 19f, 9.5f, 9.5f, 90f, Path(twoWay).apply { offset(0.5f, 5.5f) })
            NWSE -> solid(19f, 19f, 9.5f, 9.5f, 45f, Path(twoWay).apply { offset(0.5f, 5.5f) })
            NESW -> solid(19f, 19f, 9.5f, 9.5f, -45f, Path(twoWay).apply { offset(0.5f, 5.5f) })
            MOVE -> icon(s, 21f, 21f, 10.5f, 10.5f) { c ->
                val p = Path(poly(0f, 4f, 4f, 0f, 4f, 3f, 16f, 3f, 16f, 0f, 20f, 4f, 16f, 8f, 16f, 5f, 4f, 5f, 4f, 8f))
                p.offset(0.5f, 6.5f)
                for (r in listOf(0f, 90f)) {
                    c.save()
                    c.rotate(r, 10.5f, 10.5f)
                    c.drawPath(p, halo)
                    c.drawPath(p, black)
                    c.restore()
                }
            }
            WAIT -> outlined(
                12f, 19f, 6f, 9f,
                poly(1f, 1f, 11f, 1f, 11f, 3f, 7f, 9f, 11f, 15f, 11f, 18f, 1f, 18f, 1f, 15f, 5f, 9f, 1f, 3f),
            )
            NO -> icon(s, 19f, 19f, 9.5f, 9.5f) { c ->
                val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    style = Paint.Style.STROKE; color = 0xFFC00000.toInt(); strokeWidth = 2.5f
                }
                c.drawCircle(9.5f, 9.5f, 7.5f, halo)
                c.drawCircle(9.5f, 9.5f, 7f, ring)
                c.drawLine(4.5f, 4.5f, 14.5f, 14.5f, ring)
            }
            CROSS -> icon(s, 19f, 19f, 9.5f, 9.5f) { c ->
                c.drawLine(9.5f, 1f, 9.5f, 18f, halo)
                c.drawLine(1f, 9.5f, 18f, 9.5f, halo)
                c.drawLine(9.5f, 1f, 9.5f, 18f, line)
                c.drawLine(1f, 9.5f, 18f, 9.5f, line)
            }
            // The classic arrow.
            else -> outlined(
                13f, 20f, 1f, 1f,
                poly(1f, 1f, 1f, 17f, 5f, 13f, 8f, 19f, 10.2f, 18f, 7.4f, 12f, 12.4f, 12f),
            )
        }
    }

    private fun icon(s: Float, w: Float, h: Float, hx: Float, hy: Float, draw: (Canvas) -> Unit): PointerIcon {
        val pad = 1f
        val bmp = Bitmap.createBitmap(
            ((w + pad * 2) * s).toInt().coerceAtLeast(1),
            ((h + pad * 2) * s).toInt().coerceAtLeast(1),
            Bitmap.Config.ARGB_8888,
        )
        val c = Canvas(bmp)
        c.scale(s, s)
        c.translate(pad, pad)
        draw(c)
        return PointerIcon.create(bmp, (hx + pad) * s, (hy + pad) * s)
    }
}
